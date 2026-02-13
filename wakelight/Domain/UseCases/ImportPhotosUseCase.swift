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

    func run(limit: Int? = 200) async throws -> Int {
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
        if assets.isEmpty { return 0 }

        let importedAt = Date()

        try await writer.write { db in
            for asset in assets {
                let localId = asset.localIdentifier
                let creationDate = asset.creationDate
                let latitude = asset.location?.coordinate.latitude
                let longitude = asset.location?.coordinate.longitude

                // 增量导入：localIdentifier 唯一，重复则忽略（后续可扩展为字段级更新）
                if try PhotoAsset.filter(Column("localIdentifier") == localId).fetchOne(db) == nil {
                    let record = PhotoAsset(
                        id: UUID(),
                        localIdentifier: localId,
                        creationDate: creationDate,
                        latitude: latitude,
                        longitude: longitude,
                        thumbnailPath: nil,
                        importedAt: importedAt
                    )
                    try record.insert(db)
                }
            }
        }

        return assets.count
    }
}

enum ImportPhotosError: Error {
    case permissionDenied
}
