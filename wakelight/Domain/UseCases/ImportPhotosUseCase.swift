import Foundation
import Photos
import GRDB

final class ImportPhotosUseCase {
    private let permissionService: PhotosPermissionServiceProtocol
    private let importService: PhotosImportServiceProtocol
    private let writer: DatabaseWriter

    /// Upsert a batch of PHAssets into `PhotoAsset` table.
    /// - Important: This does NOT perform global deletion sync. Deletions should be handled by a dedicated cleanup path.
    private func upsert(assets: [PHAsset], scanAt: Date, importedAt: Date, onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        if assets.isEmpty {
            await onProgress?(0, 0)
            return 0
        }

        let total = assets.count
        await onProgress?(0, total)

        var processed = 0

        for asset in assets {
            let localId = asset.localIdentifier
            let creationDate = asset.creationDate
            let latitude = asset.location?.coordinate.latitude
            let longitude = asset.location?.coordinate.longitude
            let modificationDate = asset.modificationDate

            try await writer.write { db in
                // 增量导入：localIdentifier 唯一，支持并发下的幂等更新
                if var existing = try PhotoAsset.filter(Column("localIdentifier") == localId).fetchOne(db) {
                    let hasChanged = (existing.creationDate != creationDate) ||
                                     (existing.latitude != latitude) ||
                                     (existing.longitude != longitude) ||
                                     (existing.modificationDate != modificationDate) ||
                                     (existing.mediaType?.rawValue != (asset.mediaType == .video ? "video" : "photo"))

                    existing.lastSeenAt = scanAt
                    if hasChanged {
                        existing.creationDate = creationDate
                        existing.latitude = latitude
                        existing.longitude = longitude
                        existing.modificationDate = modificationDate
                        
                        // Update new metadata fields
                        existing.mediaType = asset.mediaType == .video ? .video : .photo
                        existing.uti = asset.value(forKey: "uniformTypeIdentifier") as? String
                        existing.pixelWidth = asset.pixelWidth
                        existing.pixelHeight = asset.pixelHeight
                        existing.duration = asset.mediaType == .video ? asset.duration : nil
                        
                        // Reset cached thumbnail if the source changed
                        existing.thumbnailPath = nil
                        existing.thumbnailUpdatedAt = nil
                    }
                    try existing.update(db)

                    // Generate / backfill disk thumbnail asynchronously
                    let recordId = existing.id
                    let locator = MediaLocator.library(localIdentifier: localId)
                    let mediaType = existing.mediaType ?? .photo
                    Task.detached(priority: .background) {
                        do {
                            let path = try await PhotoThumbnailGenerator.shared.generateThumbnail(for: locator, mediaType: mediaType)
                            try await DatabaseContainer.shared.writer.write { db in
                                if var asset = try PhotoAsset.fetchOne(db, key: recordId) {
                                    asset.thumbnailPath = path
                                    asset.thumbnailUpdatedAt = Date()
                                    try asset.update(db)
                                }
                            }
                        } catch {
                            print("[PhotoImport] Thumbnail generation failed for \(localId): \(error)")
                        }
                    }
                } else {
                    let recordId = UUID()
                    let record = PhotoAsset(
                        id: recordId,
                        localIdentifier: localId,
                        creationDate: creationDate,
                        latitude: latitude,
                        longitude: longitude,

                        mediaType: asset.mediaType == .video ? .video : .photo,
                        uti: asset.value(forKey: "uniformTypeIdentifier") as? String,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        duration: asset.mediaType == .video ? asset.duration : nil,

                        thumbnailPath: nil,
                        thumbnailUpdatedAt: nil,
                        thumbnailCacheKey: nil,

                        modificationDate: modificationDate,
                        lastSeenAt: scanAt,
                        importedAt: importedAt
                    )

                    do {
                        try record.insert(db)

                        // Generate disk thumbnail asynchronously
                        let locator = MediaLocator.library(localIdentifier: localId)
                        let mediaType = record.mediaType ?? .photo
                        Task.detached(priority: .background) {
                            do {
                                let path = try await PhotoThumbnailGenerator.shared.generateThumbnail(for: locator, mediaType: mediaType)
                                try await DatabaseContainer.shared.writer.write { db in
                                    if var asset = try PhotoAsset.fetchOne(db, key: recordId) {
                                        asset.thumbnailPath = path
                                        asset.thumbnailUpdatedAt = Date()
                                        try asset.update(db)
                                    }
                                }
                            } catch {
                                print("[PhotoImport] Thumbnail generation failed for \(localId): \(error)")
                            }
                        }
                    } catch {
                        // 并发竞态：如果另一个任务刚插入了同一个 localIdentifier
                        if let dbError = error as? DatabaseError,
                           dbError.resultCode == .SQLITE_CONSTRAINT,
                           dbError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                            if var existing2 = try PhotoAsset.filter(Column("localIdentifier") == localId).fetchOne(db) {
                                existing2.lastSeenAt = scanAt
                                try existing2.update(db)
                            }
                        } else {
                            throw error
                        }
                    }
                }
            }

            processed += 1
            await onProgress?(processed, total)
        }

        return assets.count
    }

    init(
        permissionService: PhotosPermissionServiceProtocol = PhotosPermissionService(),
        importService: PhotosImportServiceProtocol = PhotosImportService(),
        writer: DatabaseWriter = DatabaseContainer.shared.writer
    ) {
        self.permissionService = permissionService
        self.importService = importService
        self.writer = writer
    }

    /// Incremental import for a specific set of Photos localIdentifiers.
    ///
    /// - This path is intended for `PHPhotoLibraryChangeObserver` callbacks.
    /// - It **does not** perform global deletion sync (because this is not a full scan).
    func run(localIdentifiers: [String], onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        let status = await permissionService.requestAuthorization()
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted, .notDetermined:
            throw ImportPhotosError.permissionDenied
        }

        let ids = Array(Set(localIdentifiers)).filter { !$0.isEmpty }
        if ids.isEmpty {
            await onProgress?(0, 0)
            return 0
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        let scanAt = Date()
        let importedAt = scanAt
        return try await upsert(assets: assets, scanAt: scanAt, importedAt: importedAt, onProgress: onProgress)
    }

    func run(limit: Int? = 200, onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        let status = await permissionService.requestAuthorization()
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            throw ImportPhotosError.permissionDenied
        case .notDetermined:
            throw ImportPhotosError.permissionDenied
        }

        let assets = try await importService.fetchAssets(limit: limit)
        let scanAt = Date()
        let importedAt = scanAt

        let imported = try await upsert(assets: assets, scanAt: scanAt, importedAt: importedAt, onProgress: onProgress)

        // 保持原有“全量扫描后同步删除”的行为：删除本次扫描未见到的本地照片记录
        if !assets.isEmpty {
            try await writer.write { db in
                let deletedCount = try PhotoAsset
                    .filter(Column("localIdentifier") != nil && (Column("lastSeenAt") < scanAt || Column("lastSeenAt") == nil))
                    .deleteAll(db)
                if deletedCount > 0 {
                    print("[PhotoImport] Sync deleted \(deletedCount) missing local assets")
                }
            }
        } else {
            await onProgress?(0, 0)
        }

        return imported
    }
}

enum ImportPhotosError: Error {
    case permissionDenied
}
