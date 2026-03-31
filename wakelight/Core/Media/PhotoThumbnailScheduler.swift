import Foundation
import GRDB

actor PhotoThumbnailScheduler {
    static let shared = PhotoThumbnailScheduler(maxConcurrent: 2)

    struct Request: Sendable {
        let photoId: UUID
        let locator: MediaLocator
        let mediaType: PhotoAsset.MediaType
    }

    struct EnqueueResult: Sendable {
        let acceptedCount: Int
        let snapshot: ThumbnailBackfillProgress
    }

    private enum State {
        case pending
        case running
        case completed
        case failed
    }

    private struct Entry {
        let request: Request
        var state: State
    }

    private let maxConcurrent: Int
    private var runningCount: Int = 0
    private var pendingOrder: [UUID] = []
    private var entriesByPhotoId: [UUID: Entry] = [:]
    private var progressObserver: (@Sendable (ThumbnailBackfillProgress) async -> Void)?

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func setProgressObserver(_ observer: (@Sendable (ThumbnailBackfillProgress) async -> Void)?) {
        progressObserver = observer
    }

    func enqueue(_ request: Request) async -> EnqueueResult {
        await enqueue([request])
    }

    func enqueue(_ requests: [Request]) async -> EnqueueResult {
        if runningCount == 0 && pendingOrder.isEmpty && !entriesByPhotoId.isEmpty {
            entriesByPhotoId.removeAll()
        }

        var acceptedCount = 0
        for request in requests {
            guard shouldEnqueue(request) else { continue }
            entriesByPhotoId[request.photoId] = Entry(request: request, state: .pending)
            pendingOrder.append(request.photoId)
            acceptedCount += 1
        }

        let snapshot = makeSnapshot()
        publishProgress(snapshot)
        runNextIfPossible()
        return EnqueueResult(acceptedCount: acceptedCount, snapshot: snapshot)
    }

    func snapshot() -> ThumbnailBackfillProgress {
        makeSnapshot()
    }

    private func shouldEnqueue(_ request: Request) -> Bool {
        guard let existing = entriesByPhotoId[request.photoId] else { return true }

        switch existing.state {
        case .pending, .running, .completed:
            return false
        case .failed:
            return true
        }
    }

    private func runNextIfPossible() {
        while runningCount < maxConcurrent, !pendingOrder.isEmpty {
            let photoId = pendingOrder.removeFirst()
            guard var entry = entriesByPhotoId[photoId] else { continue }
            guard case .pending = entry.state else { continue }

            entry.state = .running
            entriesByPhotoId[photoId] = entry
            runningCount += 1
            publishProgress(makeSnapshot())

            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                let success = await self.perform(entry.request)
                await self.jobFinished(photoId: photoId, success: success)
            }
        }
    }

    private func perform(_ request: Request) async -> Bool {
        do {
            if try await thumbnailExists(photoId: request.photoId) {
                return true
            }

            let path = try await PhotoThumbnailGenerator.shared.generateThumbnail(
                for: request.locator,
                mediaType: request.mediaType
            )

            try await DatabaseContainer.shared.writer.write { db in
                if var asset = try PhotoAsset.fetchOne(db, key: request.photoId) {
                    asset.thumbnailPath = path
                    asset.thumbnailUpdatedAt = Date()
                    try asset.update(db)
                }
            }

            return true
        } catch {
            print("[ThumbQueue] failed photoId=\(request.photoId) error=\(error)")
            return false
        }
    }

    private func thumbnailExists(photoId: UUID) async throws -> Bool {
        try await DatabaseContainer.shared.db.reader.read { db in
            guard let asset = try PhotoAsset.fetchOne(db, key: photoId) else { return false }
            guard let path = asset.thumbnailPath, !path.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private func jobFinished(photoId: UUID, success: Bool) {
        runningCount = max(0, runningCount - 1)
        if var entry = entriesByPhotoId[photoId] {
            entry.state = success ? .completed : .failed
            entriesByPhotoId[photoId] = entry
        }
        publishProgress(makeSnapshot())
        runNextIfPossible()
    }

    private func makeSnapshot() -> ThumbnailBackfillProgress {
        let total = entriesByPhotoId.count
        let completed = entriesByPhotoId.values.filter { $0.state == .completed }.count
        let failed = entriesByPhotoId.values.filter { $0.state == .failed }.count

        return ThumbnailBackfillProgress(
            total: total,
            overallPendingTotal: total,
            completed: completed,
            failed: failed,
            isRunning: runningCount > 0 || pendingOrder.isEmpty == false
        )
    }

    private func publishProgress(_ snapshot: ThumbnailBackfillProgress) {
        guard let progressObserver else { return }
        Task.detached(priority: .utility) {
            await progressObserver(snapshot)
        }
    }
}
