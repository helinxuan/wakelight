import Foundation
import Combine
import GRDB

enum ImportStatus: String, Codable {
    case idle
    case importing
    case completed
    case failed
    case cancelled
}

enum SyncPhase: String, Codable {
    case idle
    case photos
    case webdav
    case generateClusters
    case generateVisitLayers
    case done
}

enum CurationPhase: String, Codable {
    case idle
    case preprocess
    case generateClusters
    case generateVisitLayers
    case done
}

struct SyncProgress: Codable {
    var status: ImportStatus = .idle
    var phase: SyncPhase = .idle

    var totalItems: Int = 0
    var processedItems: Int = 0

    var lastNotice: String?
    var lastError: String?
    var lastCompletedAt: Date?

    var progress: Double {
        guard totalItems > 0 else { return 0 }
        let ratio = Double(processedItems) / Double(totalItems)
        return min(1.0, max(0.0, ratio))
    }
}

struct CurationProgress: Codable {
    var status: ImportStatus = .idle
    var phase: CurationPhase = .idle

    var totalItems: Int = 0
    var processedItems: Int = 0

    var meaningfulKept: Int = 0
    var reviewBucketCount: Int = 0
    var filteredArchivedCount: Int = 0

    var lastNotice: String?
    var lastError: String?
    var lastCompletedAt: Date?

    var progress: Double {
        guard totalItems > 0 else { return 0 }
        let ratio = Double(processedItems) / Double(totalItems)
        return min(1.0, max(0.0, ratio))
    }
}

struct ThumbnailBackfillProgress: Codable {
    var total: Int = 0
    var overallPendingTotal: Int = 0
    var completed: Int = 0
    var failed: Int = 0
    var isRunning: Bool = false

    var finishedCount: Int { min(total, max(0, completed + failed)) }
    var pending: Int { max(0, total - finishedCount) }
    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(finishedCount) / Double(total)))
    }
}

final class PhotoImportManager: ObservableObject {
    static let shared = PhotoImportManager()

    private static let debugLogEnabled = true

    @Published private(set) var syncProgress = SyncProgress()
    @Published private(set) var curationProgress = CurationProgress()

    @Published private(set) var isSyncRunning = false
    @Published private(set) var isCurationRunning = false
    @Published private(set) var thumbnailBackfillProgress = ThumbnailBackfillProgress()

    var isRunning: Bool { isSyncRunning || isCurationRunning }

    private enum RunningTaskType {
        case sync
        case curation
    }

    private var runningTaskType: RunningTaskType?
    private var runningTask: Task<Void, Never>?

    private var pendingPhotosChange: PhotosLibraryObserver.ChangeSet?
    private var photosChangeDebounceTask: Task<Void, Never>?
    private var pendingReclusterTask: Task<Void, Never>?

    private init() {
        loadProgress()
        reconcileRestoredProgressIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            await PhotoThumbnailScheduler.shared.setProgressObserver { snapshot in
                await MainActor.run {
                    self.thumbnailBackfillProgress = snapshot
                }
            }
            let snapshot = await PhotoThumbnailScheduler.shared.snapshot()
            await MainActor.run {
                self.thumbnailBackfillProgress = snapshot
            }
        }
        log("init done, restored sync=\(syncProgress.status.rawValue)/\(syncProgress.phase.rawValue), curation=\(curationProgress.status.rawValue)/\(curationProgress.phase.rawValue)")
    }

    private func log(_ message: String) {
        guard Self.debugLogEnabled else { return }
        print("[ImportManager] \(message)")
    }

    func resumeThumbnailBackfillIfNeeded(limit: Int? = nil) {
        Task.detached(priority: .background) {
            _ = await self.backfillThumbnailsIfNeeded(limit: limit)
        }
    }

    @discardableResult
    func backfillThumbnailsIfNeeded(limit: Int? = nil) async -> Int {
        do {
            let requests = try await loadThumbnailBackfillRequests(limit: limit)
            guard !requests.isEmpty else {
                print("[ThumbBackfill] no pending assets")
                return 0
            }

            let result = await PhotoThumbnailScheduler.shared.enqueue(requests)
            print("[ThumbBackfill] enqueue accepted=\(result.acceptedCount) queueTotal=\(result.snapshot.total)")
            return result.acceptedCount
        } catch {
            print("[ThumbBackfill] resume failed: \(error)")
            return 0
        }
    }

    func cancelImport() {
        guard isRunning else {
            log("cancelImport ignored: no running task")
            return
        }
        log("cancelImport requested, taskType=\(String(describing: runningTaskType))")
        runningTask?.cancel()
        runningTask = nil

        switch runningTaskType {
        case .sync:
            isSyncRunning = false
            syncProgress.status = .cancelled
            syncProgress.phase = .idle
            syncProgress.lastNotice = "已手动停止同步"
            syncProgress.lastError = nil
            saveSyncProgress()
        case .curation:
            isCurationRunning = false
            curationProgress.status = .cancelled
            curationProgress.phase = .idle
            curationProgress.lastNotice = "已手动停止整理"
            curationProgress.lastError = nil
            saveCurationProgress()
        case .none:
            break
        }

        runningTaskType = nil
    }

    func startImportIfNeeded(reason: String) {
        guard !isRunning else { return }
        startImport(reason: reason)
    }

    func startImport(reason: String) {
        startLocalPhotosImport(reason: reason)
    }

    func startLocalPhotosImport(reason: String) {
        guard !isRunning else {
            log("startLocalPhotosImport skipped: already running")
            return
        }
        log("startLocalPhotosImport begin, reason=\(reason)")
        isSyncRunning = true
        runningTaskType = .sync

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            await self.updateSyncStatus(.importing, phase: .photos, resetCounts: true)

            do {
                let imported = try await ImportPhotosUseCase().runSyncOnly(
                    limit: nil,
                    onProgress: { processed, total in
                        Task { @MainActor in
                            PhotoImportManager.shared.reportSyncProgress(processed: processed, total: total, phase: .photos)
                        }
                    }
                )

                await self.updateSyncStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                await self.updateSyncStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeSync(notice: "同步完成：本地照片增量已更新（共处理 \(imported) 项）")
            } catch is CancellationError {
                await self.cancelSync(notice: "同步任务已取消")
            } catch {
                await self.failSync(error: error.localizedDescription)
            }

            await MainActor.run {
                self.isSyncRunning = false
                self.runningTask = nil
                self.runningTaskType = nil
            }
        }
    }

    func startPreprocessImportedPhotos(reason: String) {
        guard !isRunning else {
            log("startPreprocessImportedPhotos skipped: already running")
            return
        }
        log("startPreprocessImportedPhotos begin, reason=\(reason)")
        isCurationRunning = true
        runningTaskType = .curation

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            do {
                await self.updateCurationStatus(.importing, phase: .preprocess, resetCounts: true)

                // 整理前先尽量补齐缺失/失效缩略图，提升预处理命中率。
                let prefetched = await self.backfillThumbnailsIfNeeded()
                let thumbSnapshot = await PhotoThumbnailScheduler.shared.snapshot()
                await MainActor.run {
                    self.log("curation preflight thumbnail backfill enqueued=\(prefetched) queueTotal=\(thumbSnapshot.total)")
                }

                let summary = try await ImportPhotosUseCase().reprocessImportedPhotos { processed, total in
                    Task { @MainActor in
                        PhotoImportManager.shared.reportCurationProgress(processed: processed, total: total, phase: .preprocess)
                    }
                }

                // 增量预处理时，summary 只覆盖“本次处理子集”。
                // 这里改为从数据库刷新全局计数，避免列表数字被瞬间重置为 0。
                await self.refreshCurationCountsFromDatabaseNow(fallback: summary)

                await self.updateCurationStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                await self.updateCurationStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeCuration(
                    notice: "预处理完成：保留 \(summary.meaningfulKept) 张，待确认 \(summary.reviewBucketCount) 张，已过滤 \(summary.filteredArchivedCount) 张"
                )
            } catch is CancellationError {
                await self.cancelCuration(notice: "整理任务已取消")
            } catch {
                await self.failCuration(error: error.localizedDescription)
            }

            await MainActor.run {
                self.isCurationRunning = false
                self.runningTask = nil
                self.runningTaskType = nil
            }
        }
    }

    func startWebDAVImport(reason: String) {
        guard !isRunning else {
            log("startWebDAVImport skipped: already running")
            return
        }
        log("startWebDAVImport begin, reason=\(reason)")
        isSyncRunning = true
        runningTaskType = .sync

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            do {
                let result = try await self.performWebDAVImportPipeline()
                await self.completeSync(notice: "WebDAV 同步完成：已导入 \(result.importedCount) 项")
            } catch is CancellationError {
                await self.cancelSync(notice: "WebDAV 同步已取消")
            } catch {
                await self.failSync(error: error.localizedDescription)
            }

            await MainActor.run {
                self.isSyncRunning = false
                self.runningTask = nil
                self.runningTaskType = nil
            }
        }
    }

    func runWebDAVImportInBackgroundIfPossible(reason: String) async -> Bool {
        let canRun = await MainActor.run { !self.isRunning }
        guard canRun else {
            log("runWebDAVImportInBackgroundIfPossible skipped: already running, reason=\(reason)")
            return false
        }
        log("runWebDAVImportInBackgroundIfPossible begin, reason=\(reason)")

        await MainActor.run {
            self.isSyncRunning = true
            self.runningTaskType = .sync
        }

        defer {
            Task { @MainActor in
                self.isSyncRunning = false
                self.runningTaskType = nil
                self.runningTask = nil
            }
        }

        do {
            let result = try await performWebDAVImportPipeline()

            // 顺序要求：导入 -> 缩略图补全 -> 预处理
            let _ = await backfillThumbnailsIfNeeded()

            await completeSync(notice: "WebDAV 后台同步完成：已导入 \(result.importedCount) 项")

            let _ = await runCurationInBackgroundIfPossible(reason: "after-webdav-bg-import")
            return true
        } catch is CancellationError {
            await cancelSync(notice: "WebDAV 后台同步已取消")
            return false
        } catch {
            await failSync(error: error.localizedDescription)
            return false
        }
    }

    func runCurationInBackgroundIfPossible(reason: String) async -> Bool {
        let canRun = await MainActor.run { !self.isRunning }
        guard canRun else {
            log("runCurationInBackgroundIfPossible skipped: already running, reason=\(reason)")
            return false
        }
        log("runCurationInBackgroundIfPossible begin, reason=\(reason)")

        await MainActor.run {
            self.isCurationRunning = true
            self.runningTaskType = .curation
        }

        let pipelineStart = Date()
        let heartbeatTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                let snapshot = await MainActor.run { self.curationProgress }
                self.log("curation heartbeat phase=\(snapshot.phase.rawValue) progress=\(snapshot.processedItems)/\(snapshot.totalItems)")
            }
        }

        defer {
            heartbeatTask.cancel()
            Task { @MainActor in
                self.isCurationRunning = false
                self.runningTaskType = nil
                self.runningTask = nil
            }
        }

        do {
            await updateCurationStatus(.importing, phase: .preprocess, resetCounts: true)
            log("curation step begin: preprocess")
            let preprocessStart = Date()

            // 整理前先尽量补齐缺失/失效缩略图，提升预处理命中率。
            let prefetched = await backfillThumbnailsIfNeeded()
            let thumbSnapshot = await PhotoThumbnailScheduler.shared.snapshot()
            log("curation preflight thumbnail backfill enqueued=\(prefetched) queueTotal=\(thumbSnapshot.total)")

            let summary = try await ImportPhotosUseCase().reprocessImportedPhotos { processed, total in
                Task { @MainActor in
                    PhotoImportManager.shared.reportCurationProgress(processed: processed, total: total, phase: .preprocess)
                }
            }
            log("curation step done: preprocess elapsed=\(Int(Date().timeIntervalSince(preprocessStart)))s")

            await refreshCurationCountsFromDatabaseNow(fallback: summary)

            await updateCurationStatus(.importing, phase: .generateClusters, resetCounts: false)
            log("curation step begin: generateClusters")
            let clustersStart = Date()
            _ = try await GeneratePlaceClustersUseCase().run()
            log("curation step done: generateClusters elapsed=\(Int(Date().timeIntervalSince(clustersStart)))s")

            await updateCurationStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
            log("curation step begin: generateVisitLayers")
            let layersStart = Date()
            _ = try await GenerateVisitLayersUseCase().run()
            log("curation step done: generateVisitLayers elapsed=\(Int(Date().timeIntervalSince(layersStart)))s")

            await completeCuration(
                notice: "后台预处理完成：保留 \(summary.meaningfulKept) 张，待确认 \(summary.reviewBucketCount) 张，已过滤 \(summary.filteredArchivedCount) 张"
            )
            log("runCurationInBackgroundIfPossible done totalElapsed=\(Int(Date().timeIntervalSince(pipelineStart)))s")
            return true
        } catch is CancellationError {
            log("runCurationInBackgroundIfPossible cancelled after=\(Int(Date().timeIntervalSince(pipelineStart)))s")
            await cancelCuration(notice: "后台整理已取消")
            return false
        } catch {
            log("runCurationInBackgroundIfPossible failed after=\(Int(Date().timeIntervalSince(pipelineStart)))s error=\(error.localizedDescription)")
            await failCuration(error: error.localizedDescription)
            return false
        }
    }

    private func performWebDAVImportPipeline() async throws -> WebDAVImportResult {
        await updateSyncStatus(.importing, phase: .webdav, resetCounts: true)

        let result = try await ImportWebDAVPhotosUseCase().run(profileId: nil) { processed, total in
            Task { @MainActor in
                PhotoImportManager.shared.reportSyncProgress(processed: processed, total: total)
            }
        }

        if !result.deletedPhotoIds.isEmpty {
            try await cleanupDeletedPhotoAssets(photoIds: result.deletedPhotoIds)
        }

        await updateSyncStatus(.importing, phase: .generateClusters, resetCounts: false)
        _ = try await GeneratePlaceClustersUseCase().run()

        await updateSyncStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
        _ = try await GenerateVisitLayersUseCase().run()

        // WebDAV 导入后静默补全缩略图（仅补无缩略图项）。
        resumeThumbnailBackfillIfNeeded()

        return result
    }

    @MainActor
    private func updateSyncStatus(_ status: ImportStatus, phase: SyncPhase, resetCounts: Bool) {
        log("updateSyncStatus status=\(status.rawValue) phase=\(phase.rawValue) reset=\(resetCounts)")
        syncProgress.status = status
        syncProgress.phase = phase

        if resetCounts {
            syncProgress.processedItems = 0
            syncProgress.totalItems = 0
        }

        if status == .importing {
            syncProgress.lastError = nil
            syncProgress.lastNotice = nil
        }

        saveSyncProgress()
    }

    @MainActor
    private func updateCurationStatus(_ status: ImportStatus, phase: CurationPhase, resetCounts: Bool) {
        log("updateCurationStatus status=\(status.rawValue) phase=\(phase.rawValue) reset=\(resetCounts)")
        curationProgress.status = status
        curationProgress.phase = phase

        if resetCounts {
            curationProgress.processedItems = 0
            curationProgress.totalItems = 0
            curationProgress.meaningfulKept = 0
            curationProgress.reviewBucketCount = 0
            curationProgress.filteredArchivedCount = 0
        }

        if status == .importing {
            curationProgress.lastError = nil
            curationProgress.lastNotice = nil
        }

        saveCurationProgress()
    }

    @MainActor
    private func completeSync(notice: String? = nil) {
        log("completeSync notice=\(notice ?? "nil")")
        syncProgress.status = .completed
        syncProgress.phase = .done
        syncProgress.lastCompletedAt = Date()
        syncProgress.lastNotice = notice
        syncProgress.lastError = nil

        // 防御性收口：任何完成态都确保运行标记被释放，避免 UI 按钮卡死。
        isSyncRunning = false
        if runningTaskType == .sync {
            runningTaskType = nil
            runningTask = nil
        }

        saveSyncProgress()
    }

    @MainActor
    private func completeCuration(notice: String? = nil) {
        log("completeCuration notice=\(notice ?? "nil")")
        curationProgress.status = .completed
        curationProgress.phase = .done
        curationProgress.lastCompletedAt = Date()
        curationProgress.lastNotice = notice
        curationProgress.lastError = nil

        isCurationRunning = false
        if runningTaskType == .curation {
            runningTaskType = nil
            runningTask = nil
        }

        saveCurationProgress()
    }

    @MainActor
    private func cancelSync(notice: String? = nil) {
        log("cancelSync notice=\(notice ?? "nil")")
        syncProgress.status = .cancelled
        syncProgress.phase = .idle
        syncProgress.lastNotice = notice
        syncProgress.lastError = nil

        isSyncRunning = false
        if runningTaskType == .sync {
            runningTaskType = nil
            runningTask = nil
        }

        saveSyncProgress()
    }

    @MainActor
    private func cancelCuration(notice: String? = nil) {
        log("cancelCuration notice=\(notice ?? "nil")")
        curationProgress.status = .cancelled
        curationProgress.phase = .idle
        curationProgress.lastNotice = notice
        curationProgress.lastError = nil

        isCurationRunning = false
        if runningTaskType == .curation {
            runningTaskType = nil
            runningTask = nil
        }

        saveCurationProgress()
    }

    @MainActor
    private func failSync(error: String) {
        log("failSync error=\(error)")
        syncProgress.status = .failed
        syncProgress.lastError = error

        // 防御性收口：失败态也要释放运行状态，避免超时后界面仍认为任务在运行。
        isSyncRunning = false
        if runningTaskType == .sync {
            runningTaskType = nil
            runningTask = nil
        }

        saveSyncProgress()
    }

    @MainActor
    private func failCuration(error: String) {
        log("failCuration error=\(error)")
        curationProgress.status = .failed
        curationProgress.phase = .idle
        curationProgress.lastError = error

        isCurationRunning = false
        if runningTaskType == .curation {
            runningTaskType = nil
            runningTask = nil
        }

        saveCurationProgress()
    }

    func reportNonFatalWarning(_ message: String) {
        Task { @MainActor in
            if let existing = syncProgress.lastError, !existing.isEmpty {
                syncProgress.lastError = existing + "\n" + "提示: \(message)"
            } else {
                syncProgress.lastError = "提示: \(message)"
            }
            saveSyncProgress()
        }
    }

    @MainActor
    func reportSyncProgress(processed: Int, total: Int, phase: SyncPhase? = nil) {
        if let phase {
            syncProgress.phase = phase
        }
        syncProgress.processedItems = processed
        syncProgress.totalItems = total
    }

    @MainActor
    func reportCurationProgress(processed: Int, total: Int, phase: CurationPhase? = nil) {
        if let phase {
            curationProgress.phase = phase
        }
        curationProgress.processedItems = processed
        curationProgress.totalItems = total

        if total > 0 {
            if processed == 0 || processed % 20 == 0 || processed == total {
                log("curation progress phase=\(curationProgress.phase.rawValue) \(processed)/\(total)")
            }
        } else if processed == 0 {
            log("curation progress phase=\(curationProgress.phase.rawValue) waiting-total")
        }
    }

    @MainActor
    func reportCurationSummary(_ summary: ImportCurationSummary) {
        curationProgress.meaningfulKept = summary.meaningfulKept
        curationProgress.reviewBucketCount = summary.reviewBucketCount
        curationProgress.filteredArchivedCount = summary.filteredArchivedCount
        saveCurationProgress()
    }

    @MainActor
    func refreshCurationCountsFromDatabase() {
        Task.detached(priority: .utility) {
            do {
                let (keep, review, archived) = try await DatabaseContainer.shared.db.reader.read { db in
                    let keep = try PhotoAsset.filter(Column("curationBucket") == ImportDecisionBucket.keep.rawValue).fetchCount(db)
                    let review = try PhotoAsset.filter(Column("curationBucket") == ImportDecisionBucket.review.rawValue).fetchCount(db)
                    let archived = try PhotoAsset.filter(Column("curationBucket") == ImportDecisionBucket.archived.rawValue).fetchCount(db)
                    return (keep, review, archived)
                }

                await MainActor.run {
                    self.curationProgress.meaningfulKept = keep
                    self.curationProgress.reviewBucketCount = review
                    self.curationProgress.filteredArchivedCount = archived
                    self.saveCurationProgress()
                }
            } catch {
                print("[ImportManager] refreshCurationCountsFromDatabase failed: \(error)")
            }
        }
    }

    private func reconcileRestoredProgressIfNeeded() {
        var didChangeSync = false
        var didChangeCuration = false

        if syncProgress.status == .importing && !isSyncRunning {
            syncProgress.status = .cancelled
            syncProgress.phase = .idle
            syncProgress.lastError = nil
            syncProgress.lastNotice = "上次任务中断已停止"
            didChangeSync = true
        }

        if curationProgress.status == .importing && !isCurationRunning {
            curationProgress.status = .cancelled
            curationProgress.phase = .idle
            curationProgress.lastError = nil
            curationProgress.lastNotice = "上次任务中断已停止"
            didChangeCuration = true
        }

        if didChangeSync {
            saveSyncProgress()
            log("reconcile restored sync importing -> cancelled")
        }

        if didChangeCuration {
            saveCurationProgress()
            log("reconcile restored curation importing -> cancelled")
        }
    }

    private func refreshCurationCountsFromDatabaseNow(fallback: ImportCurationSummary? = nil) async {
        do {
            let (keep, review, archived) = try await DatabaseContainer.shared.db.reader.read { db in
                let keep = try PhotoAsset.filter(Column("curationBucket") == ImportDecisionBucket.keep.rawValue).fetchCount(db)
                let review = try PhotoAsset.filter(Column("curationBucket") == ImportDecisionBucket.review.rawValue).fetchCount(db)
                let archived = try PhotoAsset.filter(Column("curationBucket") == ImportDecisionBucket.archived.rawValue).fetchCount(db)
                return (keep, review, archived)
            }

            await MainActor.run {
                self.curationProgress.meaningfulKept = keep
                self.curationProgress.reviewBucketCount = review
                self.curationProgress.filteredArchivedCount = archived
                self.saveCurationProgress()
            }
        } catch {
            print("[ImportManager] refreshCurationCountsFromDatabaseNow failed: \(error)")

            if let fallback {
                await MainActor.run {
                    self.curationProgress.meaningfulKept = fallback.meaningfulKept
                    self.curationProgress.reviewBucketCount = fallback.reviewBucketCount
                    self.curationProgress.filteredArchivedCount = fallback.filteredArchivedCount
                    self.saveCurationProgress()
                }
            }
        }
    }

    private func loadThumbnailBackfillRequests(limit: Int?) async throws -> [PhotoThumbnailScheduler.Request] {
        try await DatabaseContainer.shared.db.reader.read { db in
            let assets = try PhotoAsset
                .order(Column("importedAt").desc)
                .fetchAll(db)

            var scheduledIds: [UUID] = []
            var mediaTypeById: [UUID: PhotoAsset.MediaType] = [:]

            for asset in assets {
                let hasThumbnailReference = !(asset.thumbnailPath?.isEmpty ?? true)

                let fileExists: Bool = {
                    guard let relativePath = asset.thumbnailPath, !relativePath.isEmpty else { return false }
                    guard let url = try? MediaCache.shared.thumbnailURL(forRelativePath: relativePath) else { return false }
                    return FileManager.default.fileExists(atPath: url.path)
                }()

                guard !hasThumbnailReference || !fileExists else { continue }

                scheduledIds.append(asset.id)
                mediaTypeById[asset.id] = asset.mediaType ?? .photo
                if let limit, scheduledIds.count >= limit {
                    break
                }
            }

            let locators = try PhotoAsset.fetchLocators(db: db, ids: scheduledIds)
            let locatorById = Dictionary(uniqueKeysWithValues: locators.map { ($0.photoAssetId, $0.locatorKey) })

            return scheduledIds.compactMap { id -> PhotoThumbnailScheduler.Request? in
                guard let locatorKey = locatorById[id] else { return nil }
                guard let locator = MediaLocator.parse(locatorKey) else { return nil }
                let mediaType = mediaTypeById[id] ?? .photo
                return PhotoThumbnailScheduler.Request(photoId: id, locator: locator, mediaType: mediaType)
            }
        }
    }

    private let syncProgressKey = "com.wakelight.import.sync.progress"
    private let curationProgressKey = "com.wakelight.import.curation.progress"

    private func saveSyncProgress() {
        if let data = try? JSONEncoder().encode(syncProgress) {
            UserDefaults.standard.set(data, forKey: syncProgressKey)
            log("saveSyncProgress status=\(syncProgress.status.rawValue) phase=\(syncProgress.phase.rawValue) error=\(syncProgress.lastError ?? "nil") notice=\(syncProgress.lastNotice ?? "nil")")
        }
    }

    private func saveCurationProgress() {
        if let data = try? JSONEncoder().encode(curationProgress) {
            UserDefaults.standard.set(data, forKey: curationProgressKey)
            log("saveCurationProgress status=\(curationProgress.status.rawValue) phase=\(curationProgress.phase.rawValue) error=\(curationProgress.lastError ?? "nil") notice=\(curationProgress.lastNotice ?? "nil")")
        }
    }

    private func loadProgress() {
        if let data = UserDefaults.standard.data(forKey: syncProgressKey),
           let saved = try? JSONDecoder().decode(SyncProgress.self, from: data) {
            self.syncProgress = saved
            log("loadProgress sync restored status=\(saved.status.rawValue) phase=\(saved.phase.rawValue) error=\(saved.lastError ?? "nil") notice=\(saved.lastNotice ?? "nil")")
        }

        if let data = UserDefaults.standard.data(forKey: curationProgressKey),
           let saved = try? JSONDecoder().decode(CurationProgress.self, from: data) {
            self.curationProgress = saved
            log("loadProgress curation restored status=\(saved.status.rawValue) phase=\(saved.phase.rawValue) error=\(saved.lastError ?? "nil") notice=\(saved.lastNotice ?? "nil")")
        }
    }

    func handlePhotosLibraryChange(_ change: PhotosLibraryObserver.ChangeSet) {
        if var existing = pendingPhotosChange {
            existing.insertedLocalIdentifiers.append(contentsOf: change.insertedLocalIdentifiers)
            existing.changedLocalIdentifiers.append(contentsOf: change.changedLocalIdentifiers)
            existing.removedLocalIdentifiers.append(contentsOf: change.removedLocalIdentifiers)
            pendingPhotosChange = existing
        } else {
            pendingPhotosChange = change
        }

        photosChangeDebounceTask?.cancel()
        photosChangeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.processPendingPhotosChange()
        }
    }

    func scheduleRecluster(reason: String) {
        guard !isRunning else { return }

        pendingReclusterTask?.cancel()
        pendingReclusterTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            do {
                _ = try await GeneratePlaceClustersUseCase().run()
                _ = try await GenerateVisitLayersUseCase().run()
                print("[ImportManager] Incremental recluster finished. reason=\(reason)")
            } catch {
                print("[ImportManager] Incremental recluster failed: \(error). reason=\(reason)")
            }
        }
    }

    private func processPendingPhotosChange() async {
        guard let change = pendingPhotosChange else { return }
        pendingPhotosChange = nil

        if isRunning { return }

        let insertedOrChanged = Array(Set(change.insertedLocalIdentifiers + change.changedLocalIdentifiers))
        let removed = Array(Set(change.removedLocalIdentifiers))

        if !insertedOrChanged.isEmpty {
            Task.detached(priority: .background) {
                do {
                    _ = try await ImportPhotosUseCase().run(localIdentifiers: insertedOrChanged, onProgress: nil)
                    await MainActor.run {
                        PhotoImportManager.shared.scheduleRecluster(reason: "incremental-upsert")
                    }
                } catch {
                    print("[ImportManager] Incremental Photos upsert failed: \(error)")
                }
            }
        }

        if !removed.isEmpty {
            Task.detached(priority: .background) {
                do {
                    let photoIds: [UUID] = try await DatabaseContainer.shared.db.reader.read { db in
                        try PhotoAsset
                            .filter(removed.contains(Column("localIdentifier")))
                            .fetchAll(db)
                            .map { $0.id }
                    }

                    guard !photoIds.isEmpty else { return }
                    try await self.cleanupDeletedPhotoAssets(photoIds: photoIds)

                    await MainActor.run {
                        PhotoImportManager.shared.scheduleRecluster(reason: "incremental-delete")
                    }
                } catch {
                    print("[ImportManager] Incremental Photos delete failed: \(error)")
                }
            }
        }
    }

    func cleanupDeletedPhotoAssets(photoIds: [UUID]) async throws {
        guard !photoIds.isEmpty else { return }

        try await DatabaseContainer.shared.writer.write { db in
            let affectedVisitLayerIds = try VisitLayerPhotoAsset
                .filter(photoIds.contains(Column("photoAssetId")))
                .fetchAll(db)
                .map { $0.visitLayerId }

            let removedLocalIds = try PhotoAsset
                .filter(photoIds.contains(Column("id")))
                .fetchAll(db)
                .compactMap { $0.localIdentifier }

            let deletedLinksCount = try VisitLayerPhotoAsset
                .filter(photoIds.contains(Column("photoAssetId")))
                .deleteAll(db)

            var deletedVisitLayerCount = 0
            if !affectedVisitLayerIds.isEmpty {
                for layerId in Set(affectedVisitLayerIds) {
                    let photoCount = try VisitLayerPhotoAsset
                        .filter(Column("visitLayerId") == layerId)
                        .fetchCount(db)
                    if photoCount == 0 {
                        try VisitLayer.filter(Column("id") == layerId).deleteAll(db)
                        deletedVisitLayerCount += 1
                    }
                }
            }

            let locators = try PhotoAsset.fetchLocators(db: db, ids: photoIds)
            let removedLocatorKeys = locators.map { $0.locatorKey }
            let allMatchKeys = Set(removedLocalIds + removedLocatorKeys)

            let storiesNeedingUpdate = try StoryNode
                .filter(allMatchKeys.contains(Column("coverPhotoId")))
                .fetchAll(db)

            var deletedStoryCount = 0
            var updatedStoryCount = 0
            var affectedPlaceClusterIds = Set<UUID>()

            for var story in storiesNeedingUpdate {
                let visitLayerIds = story.subVisitLayerIds
                if visitLayerIds.isEmpty {
                    affectedPlaceClusterIds.insert(story.placeClusterId)
                    try story.delete(db)
                    deletedStoryCount += 1
                    continue
                }

                let remainingPhotoLinks = try VisitLayerPhotoAsset
                    .filter(visitLayerIds.contains(Column("visitLayerId")))
                    .fetchAll(db)

                let remainingPhotoIds = remainingPhotoLinks.map(\.photoAssetId)

                if remainingPhotoIds.isEmpty {
                    affectedPlaceClusterIds.insert(story.placeClusterId)
                    try story.delete(db)
                    deletedStoryCount += 1
                    continue
                }

                let candidates = try PhotoAsset
                    .filter(remainingPhotoIds.contains(Column("id")))
                    .fetchAll(db)

                if let newCover = candidates
                    .sorted(by: { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) })
                    .first {

                    let newLocators = try PhotoAsset.fetchLocators(db: db, ids: [newCover.id])
                    if let newCoverKey = newLocators.first?.locatorKey {
                        story.coverPhotoId = newCoverKey
                        story.updatedAt = Date()
                        try story.update(db)
                        updatedStoryCount += 1
                    } else {
                        affectedPlaceClusterIds.insert(story.placeClusterId)
                        try story.delete(db)
                        deletedStoryCount += 1
                    }
                } else {
                    affectedPlaceClusterIds.insert(story.placeClusterId)
                    try story.delete(db)
                    deletedStoryCount += 1
                }
            }

            if !affectedPlaceClusterIds.isEmpty {
                for clusterId in affectedPlaceClusterIds {
                    let remainingStoryCount = try StoryNode
                        .filter(Column("placeClusterId") == clusterId)
                        .fetchCount(db)

                    if remainingStoryCount == 0 {
                        _ = try PlaceCluster
                            .filter(Column("id") == clusterId)
                            .updateAll(db, Column("hasStory").set(to: false))
                    }
                }
            }

            let deletedPhotosCount = try PhotoAsset
                .filter(photoIds.contains(Column("id")))
                .deleteAll(db)

            print("[Cleanup] Deleted: photos=\(deletedPhotosCount), links=\(deletedLinksCount), layers=\(deletedVisitLayerCount), storiesDel=\(deletedStoryCount), storiesUpd=\(updatedStoryCount)")
        }
    }
}
