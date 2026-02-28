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
        return Double(processedItems) / Double(totalItems)
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
        return Double(processedItems) / Double(totalItems)
    }
}

final class PhotoImportManager: ObservableObject {
    static let shared = PhotoImportManager()

    @Published private(set) var syncProgress = SyncProgress()
    @Published private(set) var curationProgress = CurationProgress()

    @Published private(set) var isSyncRunning = false
    @Published private(set) var isCurationRunning = false

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
    }

    func cancelImport() {
        guard isRunning else { return }
        runningTask?.cancel()
        runningTask = nil

        switch runningTaskType {
        case .sync:
            isSyncRunning = false
            syncProgress.status = .cancelled
            syncProgress.phase = .idle
            syncProgress.lastError = "已手动停止同步"
            saveSyncProgress()
        case .curation:
            isCurationRunning = false
            curationProgress.status = .cancelled
            curationProgress.phase = .idle
            curationProgress.lastError = "已手动停止整理"
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
        guard !isRunning else { return }
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
        guard !isRunning else { return }
        isCurationRunning = true
        runningTaskType = .curation

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            do {
                await self.updateCurationStatus(.importing, phase: .preprocess, resetCounts: true)

                let summary = try await ImportPhotosUseCase().reprocessImportedPhotos { processed, total in
                    Task { @MainActor in
                        PhotoImportManager.shared.reportCurationProgress(processed: processed, total: total, phase: .preprocess)
                    }
                }

                await self.reportCurationSummary(summary)

                await self.updateCurationStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                await self.updateCurationStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeCuration(
                    notice: "预处理完成：保留 \(summary.meaningfulKept) 张，待确认 \(summary.reviewBucketCount) 张，已过滤 \(summary.filteredArchivedCount) 张"
                )
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
        guard !isRunning else { return }
        isSyncRunning = true
        runningTaskType = .sync

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            do {
                await self.updateSyncStatus(.importing, phase: .webdav, resetCounts: true)

                let result = try await ImportWebDAVPhotosUseCase().run(profileId: nil) { processed, total in
                    Task { @MainActor in
                        PhotoImportManager.shared.reportSyncProgress(processed: processed, total: total)
                    }
                }

                if !result.deletedPhotoIds.isEmpty {
                    try await self.cleanupDeletedPhotoAssets(photoIds: result.deletedPhotoIds)
                }

                await self.updateSyncStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                await self.updateSyncStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeSync(notice: "WebDAV 同步完成：已导入 \(result.importedCount) 项")
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

    @MainActor
    private func updateSyncStatus(_ status: ImportStatus, phase: SyncPhase, resetCounts: Bool) {
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
        syncProgress.status = .completed
        syncProgress.phase = .done
        syncProgress.lastCompletedAt = Date()
        syncProgress.lastNotice = notice
        saveSyncProgress()
    }

    @MainActor
    private func completeCuration(notice: String? = nil) {
        curationProgress.status = .completed
        curationProgress.phase = .done
        curationProgress.lastCompletedAt = Date()
        curationProgress.lastNotice = notice
        saveCurationProgress()
    }

    @MainActor
    private func failSync(error: String) {
        syncProgress.status = .failed
        syncProgress.lastError = error
        saveSyncProgress()
    }

    @MainActor
    private func failCuration(error: String) {
        curationProgress.status = .failed
        curationProgress.lastError = error
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

    private let syncProgressKey = "com.wakelight.import.sync.progress"
    private let curationProgressKey = "com.wakelight.import.curation.progress"

    private func saveSyncProgress() {
        if let data = try? JSONEncoder().encode(syncProgress) {
            UserDefaults.standard.set(data, forKey: syncProgressKey)
        }
    }

    private func saveCurationProgress() {
        if let data = try? JSONEncoder().encode(curationProgress) {
            UserDefaults.standard.set(data, forKey: curationProgressKey)
        }
    }

    private func loadProgress() {
        if let data = UserDefaults.standard.data(forKey: syncProgressKey),
           let saved = try? JSONDecoder().decode(SyncProgress.self, from: data) {
            self.syncProgress = saved
        }

        if let data = UserDefaults.standard.data(forKey: curationProgressKey),
           let saved = try? JSONDecoder().decode(CurationProgress.self, from: data) {
            self.curationProgress = saved
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

