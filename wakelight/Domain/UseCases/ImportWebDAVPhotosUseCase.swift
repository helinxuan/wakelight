import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

final class ImportWebDAVPhotosUseCase {
    private let profileRepository: WebDAVProfileRepositoryProtocol
    private let writer: DatabaseWriter

    init(
        profileRepository: WebDAVProfileRepositoryProtocol = WebDAVProfileRepository(db: DatabaseContainer.shared.db),
        writer: DatabaseWriter = DatabaseContainer.shared.writer
    ) {
        self.profileRepository = profileRepository
        self.writer = writer
    }

    func run(profileId: String? = nil, onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        print("[WebDAVImport] run(profileId: \(profileId ?? "nil"))")

        let profile: WebDAVProfile
        if let profileId {
            profile = try await profileRepository.fetchProfile(id: profileId)
        } else if let latest = try await profileRepository.fetchLatestProfile() {
            profile = latest
        } else {
            print("[WebDAVImport] No WebDAV profile found")
            return 0
        }

        print("[WebDAVImport] Using profile id=\(profile.id) name=\(profile.name) baseURL=\(profile.baseURLString) rootPath=\(profile.rootPath ?? "/")")

        guard let baseURL = profile.baseURL else {
            print("[WebDAVImport] Invalid baseURL")
            return 0
        }
        let password = try KeychainStore.shared.getString(forKey: profile.passwordKey)
        let client = WebDAVClient(baseURL: baseURL, credentials: WebDAVCredentials(username: profile.username, password: password))

        let rootPath = normalize(path: profile.rootPath ?? "/")
        if rootPath == "/" {
            await PhotoImportManager.shared.reportNonFatalWarning(
                "当前 WebDAV 导入路径是根目录 /（可能还没点击保存）。建议到 设置 → WebDAV 选择照片目录后点击保存，以避免扫描到系统/临时目录。"
            )
        }
        print("[WebDAVImport] Start PROPFIND recursively from \(rootPath)")

        let scanAt = Date()
        let importedAt = scanAt
        let indexedAt = scanAt

        let allItems = try await listRecursively(client: client, path: rootPath)
        print("[WebDAVImport] PROPFIND finished, total items=\(allItems.count)")

        let imageItems = allItems.filter { item in
            guard !item.isCollection else { return false }
            return isSupportedImagePath(item.href)
        }
        print("[WebDAVImport] Filtered image items=\(imageItems.count)")

        if imageItems.isEmpty {
            await onProgress?(0, 0)
            print("[WebDAVImport] No supported images found")
            return 0
        }

        var importedCount = 0

        // 1. Prefetch existing assets
        print("[WebDAVImport] Prefetching existing assets...")
        let existingAssets: [String: RemoteMediaAsset] = try await writer.read { db in
            let assets = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id.uuidString)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: assets.map { ($0.remotePath, $0) })
        }

        // Helper to check if content changed
        let hasItemChanged: @Sendable (RemoteMediaAsset, WebDAVDirectoryItem) -> Bool = { existing, item in
            if let existingEtag = existing.etag, let itemEtag = item.etag, !existingEtag.isEmpty, !itemEtag.isEmpty {
                return existingEtag != itemEtag
            }
            // Fallback: Check lastModified and size
            let sizeChanged = existing.size != item.contentLength
            let dateChanged = existing.lastModified != item.lastModified
            return sizeChanged || dateChanged
        }

        // Items that need download/re-import (new or changed)
        let itemsToImport = imageItems.filter { item in
            let remotePath = normalize(path: item.href)
            if let existing = existingAssets[remotePath] {
                return hasItemChanged(existing, item)
            }
            return true // New item
        }

        // Items that are unchanged but must be marked as seen to avoid deletion
        let unchangedItems = imageItems.filter { item in
            let remotePath = normalize(path: item.href)
            guard let existing = existingAssets[remotePath] else { return false }
            return !hasItemChanged(existing, item)
        }

        if !unchangedItems.isEmpty {
            print("[WebDAVImport] Marking \(unchangedItems.count) unchanged items as seen")
            let unchangedPaths = unchangedItems.map { normalize(path: $0.href) }
            _ = try await writer.write { db in
                try RemoteMediaAsset
                    .filter(Column("profileId") == profile.id.uuidString && unchangedPaths.contains(Column("remotePath")))
                    .updateAll(db, Column("lastSeenAt").set(to: scanAt))
            }
        }

        print("[WebDAVImport] Items to import: \(itemsToImport.count) (unchanged: \(unchangedItems.count), total images: \(imageItems.count))")

        // 2. Concurrent import for changed/new items
        if !itemsToImport.isEmpty {
            let concurrency = 4
            let total = itemsToImport.count
            var completedInSession = 0

            await onProgress?(0, total)

            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = itemsToImport.enumerated().makeIterator()

                for _ in 0..<min(concurrency, total) {
                    if let next = iterator.next() {
                        group.addTask {
                            try await self.importItem(
                                next.element,
                                index: next.offset,
                                total: total,
                                client: client,
                                profile: profile,
                                importedAt: importedAt,
                                indexedAt: indexedAt,
                                scanAt: scanAt
                            )
                        }
                    }
                }

                while let _ = try await group.next() {
                    completedInSession += 1
                    importedCount += 1
                    await onProgress?(completedInSession, total)

                    if let next = iterator.next() {
                        group.addTask {
                            try await self.importItem(
                                next.element,
                                index: next.offset,
                                total: total,
                                client: client,
                                profile: profile,
                                importedAt: importedAt,
                                indexedAt: indexedAt,
                                scanAt: scanAt
                            )
                        }
                    }
                }
            }
        }

        // 3. Sync deletions
        print("[WebDAVImport] Cleaning up missing assets...")
        try await writer.write { db in
            let missing = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id.uuidString && (Column("lastSeenAt") < scanAt || Column("lastSeenAt") == nil))
                .fetchAll(db)

            guard !missing.isEmpty else { return }

            let remoteIds = missing.map { $0.id.uuidString }
            let photoIds = missing.map { $0.photoAssetId.uuidString }

            try RemoteMediaAsset
                .filter(remoteIds.contains(Column("id")))
                .deleteAll(db)

            try PhotoAsset
                .filter(photoIds.contains(Column("id")))
                .deleteAll(db)

            print("[WebDAVImport] Sync deleted \(missing.count) missing remote assets")
        }

        return importedCount
    }

    private func importItem(
        _ item: WebDAVDirectoryItem,
        index: Int,
        total: Int,
        client: WebDAVClient,
        profile: WebDAVProfile,
        importedAt: Date,
        indexedAt: Date,
        scanAt: Date
    ) async throws {
        let remotePath = normalize(path: item.href)
        print("[WebDAVImport] [\(index+1)/\(total)] Downloading: \(remotePath)")

        let data = try await client.get(path: remotePath)
        let exif = extractExif(from: data)

        // Local helper for consistency
        let hasItemChanged: @Sendable (RemoteMediaAsset, WebDAVDirectoryItem) -> Bool = { existing, item in
            if let existingEtag = existing.etag, let itemEtag = item.etag, !existingEtag.isEmpty, !itemEtag.isEmpty {
                return existingEtag != itemEtag
            }
            let sizeChanged = existing.size != item.contentLength
            let dateChanged = existing.lastModified != item.lastModified
            return sizeChanged || dateChanged
        }

        try await writer.write { db in
            if var existing = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id.uuidString && Column("remotePath") == remotePath)
                .fetchOne(db) {

                let oldPhotoId = existing.photoAssetId
                let hasChanged = hasItemChanged(existing, item)

                if hasChanged {
                    let newPhotoId = UUID()
                    let record = PhotoAsset(
                        id: newPhotoId,
                        localIdentifier: nil,
                        creationDate: exif.creationDate,
                        latitude: exif.latitude,
                        longitude: exif.longitude,
                        thumbnailPath: nil,
                        modificationDate: nil,
                        lastSeenAt: scanAt,
                        importedAt: importedAt
                    )
                    try record.insert(db)

                    existing.photoAssetId = newPhotoId
                    existing.etag = item.etag
                    existing.lastModified = item.lastModified
                    existing.size = item.contentLength
                    existing.indexedAt = indexedAt
                    existing.lastSeenAt = scanAt
                    try existing.update(db)

                    _ = try? PhotoAsset.deleteOne(db, key: oldPhotoId.uuidString)
                } else {
                    existing.lastModified = item.lastModified
                    existing.indexedAt = indexedAt
                    existing.lastSeenAt = scanAt
                    try existing.update(db)
                }
                return
            }

            let photoId = UUID()
            let record = PhotoAsset(
                id: photoId,
                localIdentifier: nil,
                creationDate: exif.creationDate,
                latitude: exif.latitude,
                longitude: exif.longitude,
                thumbnailPath: nil,
                modificationDate: nil,
                lastSeenAt: scanAt,
                importedAt: importedAt
            )
            try record.insert(db)

            let remote = RemoteMediaAsset(
                id: UUID(),
                profileId: profile.id,
                remotePath: remotePath,
                etag: item.etag,
                lastModified: item.lastModified,
                size: item.contentLength,
                photoAssetId: photoId,
                indexedAt: indexedAt,
                lastSeenAt: scanAt
            )

            do {
                try remote.insert(db)
            } catch {
                if let dbError = error as? DatabaseError,
                   dbError.resultCode == .SQLITE_CONSTRAINT,
                   dbError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {

                    _ = try? PhotoAsset.deleteOne(db, key: photoId.uuidString)

                    if var existing2 = try RemoteMediaAsset
                        .filter(Column("profileId") == profile.id.uuidString && Column("remotePath") == remotePath)
                        .fetchOne(db) {

                        let oldPhotoId2 = existing2.photoAssetId
                        let hasChanged2 = hasItemChanged(existing2, item)

                        if hasChanged2 {
                            let newPhotoId2 = UUID()
                            let record2 = PhotoAsset(
                                id: newPhotoId2,
                                localIdentifier: nil,
                                creationDate: exif.creationDate,
                                latitude: exif.latitude,
                                longitude: exif.longitude,
                                thumbnailPath: nil,
                                modificationDate: nil,
                                lastSeenAt: scanAt,
                                importedAt: importedAt
                            )
                            try record2.insert(db)

                            existing2.photoAssetId = newPhotoId2
                            existing2.etag = item.etag
                            existing2.lastModified = item.lastModified
                            existing2.size = item.contentLength
                            existing2.indexedAt = indexedAt
                            existing2.lastSeenAt = scanAt
                            try existing2.update(db)

                            _ = try? PhotoAsset.deleteOne(db, key: oldPhotoId2.uuidString)
                        } else {
                            existing2.lastModified = item.lastModified
                            existing2.indexedAt = indexedAt
                            existing2.lastSeenAt = scanAt
                            try existing2.update(db)
                        }
                    }
                } else {
                    throw error
                }
            }
        }
    }

    private func listRecursively(client: WebDAVClient, path: String) async throws -> [WebDAVDirectoryItem] {
        var visited = Set<String>()
        return try await listRecursively(client: client, path: path, visited: &visited)
    }

    private func listRecursively(client: WebDAVClient, path: String, visited: inout Set<String>) async throws -> [WebDAVDirectoryItem] {
        let normalizedPath = normalize(path: path)
        if visited.contains(normalizedPath) { return [] }
        visited.insert(normalizedPath)

        let lower = normalizedPath.lowercased()
        if lower.contains("#recycle") || lower.contains("recycle") { return [] }
        if lower.contains("/tmp_") || lower.contains("tmp_merge") || lower.contains("tmp_mut") { return [] }

        var results: [WebDAVDirectoryItem] = []
        let items = try await client.propfind(path: normalizedPath, depth: "1")

        for item in items {
            let href = normalize(path: item.href)
            if href == normalizedPath { continue }

            results.append(item)

            if item.isCollection {
                let sub = try await listRecursively(client: client, path: href, visited: &visited)
                results.append(contentsOf: sub)
            }
        }

        return results
    }

    private func normalize(path: String) -> String {
        if path.isEmpty { return "/" }
        let p = path.hasPrefix("/") ? path : "/" + path
        return p
    }

    private func isSupportedImagePath(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".heic")
    }

    private struct ExifExtract {
        var creationDate: Date?
        var latitude: Double?
        var longitude: Double?
    }

    private func extractExif(from data: Data) -> ExifExtract {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return ExifExtract(creationDate: nil, latitude: nil, longitude: nil)
        }

        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ExifExtract(creationDate: nil, latitude: nil, longitude: nil)
        }

        var creationDate: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                creationDate = parseExifDate(dateStr)
            }
        }

        var latitude: Double?
        var longitude: Double?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                latitude = (latRef.uppercased() == "S") ? -lat : lat
                longitude = (lonRef.uppercased() == "W") ? -lon : lon
            }
        }

        return ExifExtract(creationDate: creationDate, latitude: latitude, longitude: longitude)
    }

    private func parseExifDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
