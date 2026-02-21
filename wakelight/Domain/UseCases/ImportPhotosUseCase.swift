import Foundation
import Photos
import GRDB

final class ImportPhotosUseCase {
    private let permissionService: PhotosPermissionServiceProtocol
    private let importService: PhotosImportServiceProtocol
    private let writer: DatabaseWriter

    init(
        permissionService: PhotosPermissionServiceProtocol = PhotosPermissionService(),
        importService: PhotosImportServiceProtocol = PhotosImportService(),
        writer: DatabaseWriter = DatabaseContainer.shared.writer
    ) {
        self.permissionService = permissionService
        self.importService = importService
        self.writer = writer
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
        if assets.isEmpty {
            await onProgress?(0, 0)
            return 0
        }

        let total = assets.count
        await onProgress?(0, total)

        let scanAt = Date()
        let importedAt = scanAt
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
                    // 如果基本信息（定位/日期）有变化，或者相册资源已修改，则更新现有记录
                    let hasChanged = (existing.creationDate != creationDate) ||
                                     (existing.latitude != latitude) ||
                                     (existing.longitude != longitude) ||
                                     (existing.modificationDate != modificationDate)
                    
                    existing.lastSeenAt = scanAt
                    if hasChanged {
                        existing.creationDate = creationDate
                        existing.latitude = latitude
                        existing.longitude = longitude
                        existing.modificationDate = modificationDate
                        // 深度刷新：清空缩略图路径，后续缩略图生成逻辑应检测 nil 并重建
                        existing.thumbnailPath = nil
                    }
                    try existing.update(db)
                } else {
                    let record = PhotoAsset(
                        id: UUID(),
                        localIdentifier: localId,
                        creationDate: creationDate,
                        latitude: latitude,
                        longitude: longitude,
                        thumbnailPath: nil,
                        modificationDate: modificationDate,
                        lastSeenAt: scanAt,
                        importedAt: importedAt
                    )
                    
                    do {
                        try record.insert(db)
                    } catch {
                        // 并发竞态：如果另一个任务刚插入了同一个 localIdentifier
                        if let dbError = error as? DatabaseError,
                           dbError.resultCode == .SQLITE_CONSTRAINT,
                           dbError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                            // 再次尝试更新 lastSeenAt
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

        // 同步删除：删除本次扫描未见到的本地照片记录
        try await writer.write { db in
            let deletedCount = try PhotoAsset
                .filter(Column("localIdentifier") != nil && (Column("lastSeenAt") < scanAt || Column("lastSeenAt") == nil))
                .deleteAll(db)
            if deletedCount > 0 {
                print("[PhotoImport] Sync deleted \(deletedCount) missing local assets")
            }
        }

        return assets.count
    }
}

enum ImportPhotosError: Error {
    case permissionDenied
}
