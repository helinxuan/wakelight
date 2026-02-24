import Foundation

/// Limits concurrent thumbnail generations to avoid OOM when importing large batches (e.g. WebDAV).
actor PhotoThumbnailScheduler {
    static let shared = PhotoThumbnailScheduler(maxConcurrent: 2)

    private let maxConcurrent: Int
    private var runningCount: Int = 0
    private var queue: [Job] = []

    typealias Job = @Sendable () async -> Void

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func schedule(_ job: @escaping Job) {
        queue.append(job)
        runNextIfPossible()
    }

    private func runNextIfPossible() {
        guard runningCount < maxConcurrent, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        runningCount += 1

        Task.detached(priority: .background) { [weak self] in
            await job()
            await self?.jobFinished()
        }
    }

    private func jobFinished() {
        runningCount = max(0, runningCount - 1)
        runNextIfPossible()
    }
}
