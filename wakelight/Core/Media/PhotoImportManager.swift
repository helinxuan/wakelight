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

enum ImportPhase: String, Codable {
    case idle
    case photos
    case webdav
    case generateClusters
    case generateVisitLayers
    case done
}

struct ImportProgress: Codable {
    var status: ImportStatus = .idle
    var phase: ImportPhase = .idle

    var totalItems: Int = 0
    var processedItems: Int = 0

    var lastError: String?
    var lastCompletedAt: Date?

    var progress: Double {
        guard totalItems > 0 else { return 0 }
        return Double(processedItems) / Double(totalItems)
    }
}

@MainActor
final class PhotoImportManager: ObservableObject {
    static let shared = PhotoImportManager()

    @Published private(set) var progress = ImportProgress()

    @Published private(set) var isRunning = false
    private var runningTask: Task<Void, Never>?

    // MARK: - Photos Change Observer (Incremental Sync)

    private var pendingPhotosChange: PhotosLibraryObserver.ChangeSet?
    private var photosChangeDebounceTask: Task<Void, Never>?

    private init() {
        loadProgress()
    }

    /// 停止当前正在运行的导入任务
    func cancelImport() {
        guard isRunning else { return }
        print("[ImportManager] Cancelling import...")
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        progress.status = .cancelled
        progress.phase = .idle
        progress.lastError = "已手动停止导入"
        saveProgress()
    }

    /// 非阻塞 UI：用 Task 在后台执行（但仍在 app 进程内运行，不用 BGTaskScheduler）
    func startImportIfNeeded(reason: String) {
        guard !isRunning else {
            print("[ImportManager] Skip startImport (already running). reason=\(reason)")
            return
        }
        startImport(reason: reason)
    }

    /// 默认导入：只同步系统 Photos（用于自动触发：App 启动 / 设置保存等）。
    /// WebDAV 由于可能全量扫描、耗时且耗电，默认不自动触发。
    func startImport(reason: String) {
        startLocalPhotosImport(reason: reason)
    }

    /// 仅导入系统 Photos（推荐 & 自动触发的默认行为）
    func startLocalPhotosImport(reason: String) {
        guard !isRunning else { return }
        isRunning = true

        print("[ImportManager] Starting LOCAL photos import. reason=\(reason)")

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            await self.updateStatus(.importing, phase: .photos, resetCounts: true)

            do {
                let photosImported = try await ImportPhotosUseCase().run(limit: nil) { processed, total in
                    PhotoImportManager.shared.reportProgress(processed: processed, total: total)
                }
                print("[ImportManager] Local Photos imported: \(photosImported)")

                // 本地 Photos 导入完成后，继续生成聚类与 VisitLayers
                await self.updateStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                await self.updateStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeImport()
            } catch {
                await self.failImport(error: error.localizedDescription)
            }

            await MainActor.run {
                self.isRunning = false
                self.runningTask = nil
            }
        }
    }

    /// 手动触发：WebDAV 导入（可能全量扫描，耗时/耗电）
    func startWebDAVImport(reason: String) {
        guard !isRunning else { return }
        isRunning = true

        print("[ImportManager] Starting WebDAV import (manual). reason=\(reason)")

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            do {
                await self.updateStatus(.importing, phase: .webdav, resetCounts: true)

                let webdavImported = try await ImportWebDAVPhotosUseCase().run(profileId: nil) { processed, total in
                    PhotoImportManager.shared.reportProgress(processed: processed, total: total)
                }
                print("[ImportManager] WebDAV imported: \(webdavImported)")

                // WebDAV 导入完成后，生成聚类与 VisitLayers
                await self.updateStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                await self.updateStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeImport()
            } catch {
                await self.failImport(error: error.localizedDescription)
            }

            await MainActor.run {
                self.isRunning = false
                self.runningTask = nil
            }
        }
    }

    @MainActor
    private func updateStatus(_ status: ImportStatus, phase: ImportPhase, resetCounts: Bool) {
        progress.status = status
        progress.phase = phase

        if resetCounts {
            progress.processedItems = 0
            progress.totalItems = 0
        }

        if status == .importing {
            progress.lastError = nil
        }

        saveProgress()
    }

    @MainActor
    private func completeImport() {
        progress.status = .completed
        progress.phase = .done
        progress.lastCompletedAt = Date()
        saveProgress()
    }

    @MainActor
    private func recordNonFatalError(_ message: String) {
        // 宽松模式：记录但不中断整体任务
        if let existing = progress.lastError, !existing.isEmpty {
            progress.lastError = existing + "\n" + message
        } else {
            progress.lastError = message
        }
        saveProgress()
    }

    /// “提示/警告”类信息：不会让导入失败，但会在导入页展示出来（复用 progress.lastError）。
    func reportNonFatalWarning(_ message: String) {
        recordNonFatalError("提示: \(message)")
    }

    @MainActor
    private func failImport(error: String) {
        progress.status = .failed
        progress.lastError = error
        saveProgress()
    }

    @MainActor
    func reportProgress(processed: Int, total: Int) {
        progress.processedItems = processed
        progress.totalItems = total
        // 不必每次都保存，减少 IO
    }

    private let progressKey = "com.wakelight.import.progress"

    private func saveProgress() {
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: progressKey)
        }
    }

    // MARK: - Incremental Photos Handling

    /// Called by `PhotosLibraryObserver` (on main actor) when the Photos library changes.
    /// We debounce the incoming changes to avoid thrashing when the system reports many small updates.
    func handlePhotosLibraryChange(_ change: PhotosLibraryObserver.ChangeSet) {
        // Merge into pending set
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
            // Simple debounce: wait a short delay to merge bursts of changes.
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await self?.processPendingPhotosChange()
        }
    }

    private func processPendingPhotosChange() async {
        guard let change = pendingPhotosChange else { return }
        pendingPhotosChange = nil

        // Avoid overlapping with a full import; if a full import is running, we skip incremental.
        if isRunning { return }

        let insertedOrChanged = Array(Set(change.insertedLocalIdentifiers + change.changedLocalIdentifiers))
        let removed = Array(Set(change.removedLocalIdentifiers))

        // Incremental upsert for inserted/changed assets
        if !insertedOrChanged.isEmpty {
            Task.detached(priority: .background) {
                do {
                    _ = try await ImportPhotosUseCase().run(localIdentifiers: insertedOrChanged, onProgress: nil)
                    print("[ImportManager] Incremental Photos upsert: \(insertedOrChanged.count) assets")
                } catch {
                    print("[ImportManager] Incremental Photos upsert failed: \(error)")
                }
            }
        }

        // Deletion cleanup for removed assets
        if !removed.isEmpty {
            Task.detached(priority: .background) {
                do {
                    try await DatabaseContainer.shared.writer.write { db in
                        // 1) Find PhotoAsset ids for the removed localIdentifiers
                        let photos = try PhotoAsset
                            .filter(removed.contains(Column("localIdentifier")))
                            .fetchAll(db)
                        guard !photos.isEmpty else { return }

                        let photoIds = photos.map { $0.id }
                        let removedLocalIds = photos.compactMap { $0.localIdentifier }

                        // 2) Delete VisitLayerPhotoAsset links referencing these photos
                        let deletedLinks = try VisitLayerPhotoAsset
                            .filter(photoIds.contains(Column("photoAssetId")))
                            .deleteAll(db)

                        // 2.1) Handle StoryNode covers and empty stories
                        let storiesNeedingUpdate = try StoryNode
                            .filter(removedLocalIds.contains(Column("coverPhotoId")))
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

                            // Find remaining photos for this story's visit layers
                            let remainingPhotoLinks = try VisitLayerPhotoAsset
                                .filter(visitLayerIds.contains(Column("visitLayerId")))
                                .fetchAll(db)
                            
                            let remainingPhotoIds = remainingPhotoLinks.map(\.photoAssetId)

                            if remainingPhotoIds.isEmpty {
                                // No photos left in any of the story's visit layers
                                affectedPlaceClusterIds.insert(story.placeClusterId)
                                try story.delete(db)
                                deletedStoryCount += 1
                                continue
                            }

                            // Pick a new cover from remaining photos
                            let candidates = try PhotoAsset
                                .filter(remainingPhotoIds.contains(Column("id")))
                                .fetchAll(db)

                            if let newCover = candidates
                                .sorted(by: { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) })
                                .first,
                               let newLocalId = newCover.localIdentifier {
                                
                                story.coverPhotoId = newLocalId
                                story.updatedAt = Date()
                                try story.update(db)
                                updatedStoryCount += 1
                            } else {
                                // Fallback: if no valid localIdentifier found, delete the story
                                affectedPlaceClusterIds.insert(story.placeClusterId)
                                try story.delete(db)
                                deletedStoryCount += 1
                            }
                        }

                        // 2.2) Sync PlaceCluster.hasStory for clusters whose StoryNodes were deleted
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

                        // 3) Delete PhotoAsset rows themselves
                        let deletedPhotos = try PhotoAsset
                            .filter(photoIds.contains(Column("id")))
                            .deleteAll(db)

                        print("[ImportManager] Incremental Photos delete: photos=\(deletedPhotos), links=\(deletedLinks), storiesDeleted=\(deletedStoryCount), storiesUpdated=\(updatedStoryCount)")
                    }
                } catch {
                    print("[ImportManager] Incremental Photos delete failed: \(error)")
                }
            }
        }
    }

    private func loadProgress() {
        if let data = UserDefaults.standard.data(forKey: progressKey),
           let saved = try? JSONDecoder().decode(ImportProgress.self, from: data) {
            self.progress = saved
        }
    }
}
