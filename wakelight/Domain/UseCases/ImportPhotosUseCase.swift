import Foundation
import Photos
import GRDB

final class ImportPhotosUseCase {
    private let curationService: ImportCurationService
    private let permissionService: PhotosPermissionServiceProtocol
    private let importService: PhotosImportServiceProtocol
    private let writer: DatabaseWriter

    private func upsert(
        assets: [PHAsset],
        decisionsByLocalId: [String: ImportAssetDecision] = [:],
        scanAt: Date,
        importedAt: Date,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> Int {
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
            let decision = decisionsByLocalId[localId]

            try await writer.write { db in
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
                        existing.mediaType = asset.mediaType == .video ? .video : .photo
                        existing.uti = asset.value(forKey: "uniformTypeIdentifier") as? String
                        existing.pixelWidth = asset.pixelWidth
                        existing.pixelHeight = asset.pixelHeight
                        existing.duration = asset.mediaType == .video ? asset.duration : nil
                        existing.thumbnailPath = nil
                        existing.thumbnailUpdatedAt = nil
                    }

                    if let decision {
                        existing.burstGroupId = decision.groupId
                        existing.bestShotScore = decision.score
                        existing.selectionReason = decision.reason.rawValue
                        existing.curationBucket = decision.bucket.rawValue
                        existing.isRecoverableArchived = (decision.bucket == .archived)
                        existing.recognizedTextConfidence = decision.recognizedTextConfidence
                    }

                    try existing.update(db)

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
                        burstGroupId: decision?.groupId,
                        bestShotScore: decision?.score,
                        selectionReason: decision?.reason.rawValue,
                        curationBucket: decision?.bucket.rawValue,
                        isRecoverableArchived: decision.map { $0.bucket == .archived },
                        recognizedTextConfidence: decision?.recognizedTextConfidence,
                        modificationDate: modificationDate,
                        lastSeenAt: scanAt,
                        importedAt: importedAt
                    )

                    do {
                        try record.insert(db)

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
                        if let dbError = error as? DatabaseError,
                           dbError.resultCode == .SQLITE_CONSTRAINT,
                           dbError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                            if var existing2 = try PhotoAsset.filter(Column("localIdentifier") == localId).fetchOne(db) {
                                existing2.lastSeenAt = scanAt
                                if let decision {
                                    existing2.burstGroupId = decision.groupId
                                    existing2.bestShotScore = decision.score
                                    existing2.selectionReason = decision.reason.rawValue
                                    existing2.curationBucket = decision.bucket.rawValue
                                    existing2.isRecoverableArchived = (decision.bucket == .archived)
                                    existing2.recognizedTextConfidence = decision.recognizedTextConfidence
                                }
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
        writer: DatabaseWriter = DatabaseContainer.shared.writer,
        curationService: ImportCurationService = .shared
    ) {
        self.permissionService = permissionService
        self.importService = importService
        self.writer = writer
        self.curationService = curationService
    }

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
        return try await upsert(assets: assets, scanAt: scanAt, importedAt: scanAt, onProgress: onProgress)
    }

    func runWithSummary(limit: Int? = 200, onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ImportCurationSummary {
        let status = await permissionService.requestAuthorization()
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted, .notDetermined:
            throw ImportPhotosError.permissionDenied
        }

        let assets = try await importService.fetchAssets(limit: limit)
        let decisions = await curationService.curate(assets: assets)
        let decisionsByLocalId = Dictionary(uniqueKeysWithValues: decisions.map { ($0.localIdentifier, $0) })

        let scanAt = Date()
        let imported = try await upsert(
            assets: assets,
            decisionsByLocalId: decisionsByLocalId,
            scanAt: scanAt,
            importedAt: scanAt,
            onProgress: onProgress
        )

        if !assets.isEmpty {
            try await writer.write { db in
                _ = try PhotoAsset
                    .filter(Column("localIdentifier") != nil && (Column("lastSeenAt") < scanAt || Column("lastSeenAt") == nil))
                    .deleteAll(db)
            }
        } else {
            await onProgress?(0, 0)
        }

        return ImportCurationSummary(
            totalImported: imported,
            meaningfulKept: decisions.filter { $0.bucket == .keep }.count,
            reviewBucketCount: decisions.filter { $0.bucket == .review }.count,
            filteredArchivedCount: decisions.filter { $0.bucket == .archived }.count,
            decisions: decisions
        )
    }

    func run(limit: Int? = 200, onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        try await runWithSummary(limit: limit, onProgress: onProgress).totalImported
    }
}

enum ImportPhotosError: Error {
    case permissionDenied
}
