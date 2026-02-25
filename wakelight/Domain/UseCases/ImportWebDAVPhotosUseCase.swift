import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreMedia

struct WebDAVImportResult {
    let importedCount: Int
    let deletedPhotoIds: [UUID]
}

final class ImportWebDAVPhotosUseCase {
    private static let debug = false

    private let profileRepository: WebDAVProfileRepositoryProtocol
    private let writer: DatabaseWriter

    init(
        profileRepository: WebDAVProfileRepositoryProtocol = WebDAVProfileRepository(db: DatabaseContainer.shared.db),
        writer: DatabaseWriter = DatabaseContainer.shared.writer
    ) {
        self.profileRepository = profileRepository
        self.writer = writer
    }

    private struct MediaGroup {
        let primary: WebDAVDirectoryItem
        let rawPath: String?
        let hasJPG: Bool
        let livePhotoVideoPath: String?
        let livePhotoPhotoPath: String?
    }

    func run(profileId: String? = nil, onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> WebDAVImportResult {
        print("[WebDAVImport] run(profileId: \(profileId ?? "nil"))")

        let profile: WebDAVProfile
        if let profileId {
            profile = try await profileRepository.fetchProfile(id: profileId)
        } else if let latest = try await profileRepository.fetchLatestProfile() {
            profile = latest
        } else {
            print("[WebDAVImport] No WebDAV profile found")
            return WebDAVImportResult(importedCount: 0, deletedPhotoIds: [])
        }

        print("[WebDAVImport] Using profile id=\(profile.id) name=\(profile.name) baseURL=\(profile.baseURLString) rootPath=\(profile.rootPath ?? "/")")

        guard let baseURL = profile.baseURL else {
            print("[WebDAVImport] Invalid baseURL")
            return WebDAVImportResult(importedCount: 0, deletedPhotoIds: [])
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

        let scanAt = Date().addingTimeInterval(-1)
        let importedAt = Date()
        let indexedAt = Date()

        let allItems = try await listRecursively(client: client, path: rootPath)
        print("[WebDAVImport] PROPFIND finished, total items=\(allItems.count)")

        let mediaItems = allItems.filter { item in
            guard !item.isCollection else { return false }
            return isSupportedMediaPath(item.href)
        }
        print("[WebDAVImport] Filtered media items=\(mediaItems.count)")

        let groupedItems = groupMediaItems(mediaItems)
        print("[WebDAVImport] Grouped into \(groupedItems.count) primary items")

        if groupedItems.isEmpty {
            await onProgress?(0, 0)
            print("[WebDAVImport] No supported media found")
            return WebDAVImportResult(importedCount: 0, deletedPhotoIds: [])
        }

        var importedCount = 0

        try await writer.write { db in
            let dirtyAssets = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id && Column("remotePath").like("%//%"))
                .fetchAll(db)

            for var asset in dirtyAssets {
                let oldPath = asset.remotePath
                let newPath = normalize(path: oldPath)
                if oldPath != newPath {
                    print("[WebDAVImport][Fix] Normalizing \(oldPath) -> \(newPath)")
                    if let _ = try RemoteMediaAsset
                        .filter(Column("profileId") == profile.id && Column("remotePath") == newPath)
                        .fetchOne(db) {
                        try asset.delete(db)
                    } else {
                        asset.remotePath = newPath
                        try asset.update(db)
                    }
                }
            }
        }

        print("[WebDAVImport] Prefetching existing assets...")
        let existingAssets: [String: RemoteMediaAsset] = try await writer.read { db in
            let assets = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: assets.map { ($0.remotePath, $0) })
        }

        let hasItemChanged: @Sendable (RemoteMediaAsset, WebDAVDirectoryItem) -> Bool = { existing, item in
            if let existingEtag = existing.etag, let itemEtag = item.etag, !existingEtag.isEmpty, !itemEtag.isEmpty {
                func normEtag(_ s: String) -> String {
                    s.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "W/\"", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                }
                return normEtag(existingEtag) != normEtag(itemEtag)
            }
            let sizeChanged = existing.size != item.contentLength
            let dateChanged = existing.lastModified != item.lastModified
            return sizeChanged || dateChanged
        }

        let itemsToImport = groupedItems.filter { group in
            let remotePath = normalize(path: group.primary.href)
            if let existing = existingAssets[remotePath] {
                return hasItemChanged(existing, group.primary) || 
                       existing.rawPath != group.rawPath || 
                       existing.hasJPG != group.hasJPG ||
                       existing.livePhotoVideoPath != group.livePhotoVideoPath ||
                       existing.livePhotoPhotoPath != group.livePhotoPhotoPath
            }
            return true
        }

        let unchangedItems = groupedItems.filter { group in
            let remotePath = normalize(path: group.primary.href)
            guard let existing = existingAssets[remotePath] else { return false }
            return !hasItemChanged(existing, group.primary) && 
                   existing.rawPath == group.rawPath && 
                   existing.hasJPG == group.hasJPG &&
                   existing.livePhotoVideoPath == group.livePhotoVideoPath &&
                   existing.livePhotoPhotoPath == group.livePhotoPhotoPath
        }

        if !unchangedItems.isEmpty {
            print("[WebDAVImport] Marking \(unchangedItems.count) unchanged items as seen")
            let unchangedPaths = unchangedItems.map { normalize(path: $0.primary.href) }
            _ = try await writer.write { db in
                try RemoteMediaAsset
                    .filter(Column("profileId") == profile.id && unchangedPaths.contains(Column("remotePath")))
                    .updateAll(db, Column("lastSeenAt").set(to: scanAt))
            }
        }

        print("[WebDAVImport] Items to import: \(itemsToImport.count) (unchanged: \(unchangedItems.count), total primary: \(groupedItems.count))")

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
                            try await self.importGroup(
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
                            try await self.importGroup(
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

        print("[WebDAVImport] Cleaning up missing assets...")
        let deletedPhotoIds: [UUID] = try await writer.write { db in
            let missing = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id && (Column("lastSeenAt") < scanAt || Column("lastSeenAt") == nil))
                .fetchAll(db)

            guard !missing.isEmpty else { return [] }

            let photoIds = missing.map(\.photoAssetId)
            let remoteIds = missing.map(\.id)

            try RemoteMediaAsset
                .filter(remoteIds.contains(Column("id")))
                .deleteAll(db)

            print("[WebDAVImport] Sync deleted missing: remotes=\(remoteIds.count)")
            return photoIds
        }

        return WebDAVImportResult(importedCount: importedCount, deletedPhotoIds: deletedPhotoIds)
    }

    private func importGroup(
        _ group: MediaGroup,
        index: Int,
        total: Int,
        client: WebDAVClient,
        profile: WebDAVProfile,
        importedAt: Date,
        indexedAt: Date,
        scanAt: Date
    ) async throws {
        let primaryItem = group.primary
        let primaryPath = normalize(path: primaryItem.href)

        try await importItem(
            primaryItem,
            index: index,
            total: total,
            client: client,
            profile: profile,
            importedAt: importedAt,
            indexedAt: indexedAt,
            scanAt: scanAt
        )

        // Update pairing info after importItem has ensured the remote record exists/updated.
        try await writer.write { db in
            if var remote = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id && Column("remotePath") == primaryPath)
                .fetchOne(db) {
                remote.rawPath = group.rawPath
                remote.hasJPG = group.hasJPG
                remote.livePhotoVideoPath = group.livePhotoVideoPath
                remote.livePhotoPhotoPath = group.livePhotoPhotoPath
                remote.isPrimary = true
                remote.lastSeenAt = scanAt
                try remote.update(db)
            }
        }
    }

    private func groupMediaItems(_ items: [WebDAVDirectoryItem]) -> [MediaGroup] {
        func extLower(_ path: String) -> String {
            (path as NSString).pathExtension.lowercased()
        }

        func isJPG(_ path: String) -> Bool {
            let e = extLower(path)
            return e == "jpg" || e == "jpeg"
        }

        func isHEIC(_ path: String) -> Bool {
            extLower(path) == "heic"
        }

        func isRAW(_ path: String) -> Bool {
            let e = extLower(path)
            let rawExts = ["rw2", "dng", "nef", "arw", "cr2", "cr3", "orf", "raf"]
            return rawExts.contains(e)
        }

        func isLiveVideo(_ path: String) -> Bool {
            let e = extLower(path)
            return e == "mov" || e == "mp4" || e == "m4v"
        }

        func baseKey(_ href: String) -> String {
            let normalized = normalize(path: href)
            let dir = (normalized as NSString).deletingLastPathComponent
            let file = (normalized as NSString).lastPathComponent
            let stem = ((file as NSString).deletingPathExtension)
            return (dir + "/" + stem).lowercased()
        }

        struct PhotoCandidates {
            var jpgs: [WebDAVDirectoryItem] = []
            var raws: [WebDAVDirectoryItem] = []
            var heics: [WebDAVDirectoryItem] = []
            var liveVideos: [WebDAVDirectoryItem] = []
        }

        var byKey: [String: PhotoCandidates] = [:]
        var passthrough: [MediaGroup] = []

        for item in items {
            let path = normalize(path: item.href)
            let key = baseKey(path)

            if isJPG(path) {
                byKey[key, default: PhotoCandidates()].jpgs.append(item)
            } else if isRAW(path) {
                byKey[key, default: PhotoCandidates()].raws.append(item)
            } else if isHEIC(path) {
                byKey[key, default: PhotoCandidates()].heics.append(item)
            } else if isLiveVideo(path) {
                byKey[key, default: PhotoCandidates()].liveVideos.append(item)
            } else {
                passthrough.append(
                    MediaGroup(
                        primary: item,
                        rawPath: nil,
                        hasJPG: isJPG(path),
                        livePhotoVideoPath: nil,
                        livePhotoPhotoPath: nil
                    )
                )
            }
        }

        var groups: [MediaGroup] = []
        groups.reserveCapacity(passthrough.count + byKey.count)
        groups.append(contentsOf: passthrough)

        for (_, c) in byKey {
            if let heic = c.heics.first, let video = c.liveVideos.first {
                let heicPath = normalize(path: heic.href)
                let videoPath = normalize(path: video.href)

                groups.append(
                    MediaGroup(
                        primary: heic,
                        rawPath: nil,
                        hasJPG: false,
                        livePhotoVideoPath: videoPath,
                        livePhotoPhotoPath: heicPath
                    )
                )
                continue
            }

            if let jpg = c.jpgs.first {
                let rawPath = c.raws.first.map { normalize(path: $0.href) }
                groups.append(
                    MediaGroup(
                        primary: jpg,
                        rawPath: rawPath,
                        hasJPG: true,
                        livePhotoVideoPath: nil,
                        livePhotoPhotoPath: nil
                    )
                )
                continue
            }

            if let raw = c.raws.first {
                groups.append(
                    MediaGroup(
                        primary: raw,
                        rawPath: nil,
                        hasJPG: false,
                        livePhotoVideoPath: nil,
                        livePhotoPhotoPath: nil
                    )
                )
                continue
            }

            if let heic = c.heics.first {
                groups.append(
                    MediaGroup(
                        primary: heic,
                        rawPath: nil,
                        hasJPG: false,
                        livePhotoVideoPath: nil,
                        livePhotoPhotoPath: nil
                    )
                )
                continue
            }

            if let video = c.liveVideos.first {
                groups.append(
                    MediaGroup(
                        primary: video,
                        rawPath: nil,
                        hasJPG: false,
                        livePhotoVideoPath: nil,
                        livePhotoPhotoPath: nil
                    )
                )
            }
        }

        return groups
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
        print("[WebDAVImport] [\(index+1)/\(total)] Processing: \(remotePath)")

        // 1. Skip files larger than 300MB to avoid excessive bandwidth/latency during import pass.
        let maxSizeBytes: Int = 300 * 1024 * 1024
        if let size = item.contentLength, size > maxSizeBytes {
            print("[WebDAVImport] Skipping large file (>300MB): \(remotePath) size=\(size)")
            return
        }

        // 2. Download to a temporary file to extract GPS/metadata without loading full file into memory.
        let fileExtension = (remotePath as NSString).pathExtension
        let tempURL = try await client.downloadToTemporaryFile(path: remotePath, fileExtension: fileExtension)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let metadata = extractMetadata(from: tempURL, fileName: remotePath)

        // Copy out values used inside the DB write closure.
        // Swift 6 strict concurrency: don't capture mutable vars from the outer scope into concurrently-executing closures.
        let creationDate = metadata.creationDate ?? item.lastModified
        var resolvedLatitude = metadata.latitude
        var resolvedLongitude = metadata.longitude

        // Freeze to immutable values before entering any concurrently-executing closures (Swift 6).
        // If we later update resolvedLatitude/resolvedLongitude (e.g. via XMP), we will refresh these before DB writes.
        var finalLatitude: Double? = resolvedLatitude
        var finalLongitude: Double? = resolvedLongitude

        // Fallback: if the file has no embedded GPS, try the sidecar XMP (e.g. "P1068350.JPG.xmp").
        if resolvedLatitude == nil || resolvedLongitude == nil {
            let xmpPath1 = remotePath + ".xmp"
            let xmpPath2: String? = {
                let ext = (remotePath as NSString).pathExtension
                guard !ext.isEmpty else { return nil }
                let withoutExt = (remotePath as NSString).deletingPathExtension
                return withoutExt + ".xmp"
            }()

            let xmpCandidates = [xmpPath1, xmpPath2].compactMap { $0 }

            for xmpPath in xmpCandidates {
                guard let xmpData = try? await client.get(path: xmpPath) else {
                    continue
                }

                guard let xmpString = String(data: xmpData, encoding: .utf8) else {
                    continue
                }

                let xmpGps = parseXmpGps(xmpString)
                if let lat = xmpGps.latitude, let lon = xmpGps.longitude {
                    resolvedLatitude = lat
                    resolvedLongitude = lon
                    finalLatitude = lat
                    finalLongitude = lon
                    break
                }
            }
        }

        let hasItemChanged: @Sendable (RemoteMediaAsset, WebDAVDirectoryItem) -> Bool = { existing, item in
            if let existingEtag = existing.etag, let itemEtag = item.etag, !existingEtag.isEmpty, !itemEtag.isEmpty {
                func normEtag(_ s: String) -> String {
                    s.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "W/\"", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                }
                return normEtag(existingEtag) != normEtag(itemEtag)
            }
            let sizeChanged = existing.size != item.contentLength
            let dateChanged = existing.lastModified != item.lastModified
            return sizeChanged || dateChanged
        }

        try await writer.write { db in
            if var existing = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id && Column("remotePath") == remotePath)
                .fetchOne(db) {

                let oldPhotoId = existing.photoAssetId
                let hasChanged = hasItemChanged(existing, item)

                if hasChanged {
                    let newPhotoId = UUID()
                    let record = PhotoAsset(
                        id: newPhotoId,
                        localIdentifier: nil,
                        creationDate: creationDate,
                        latitude: finalLatitude,
                        longitude: finalLongitude,
                        mediaType: metadata.mediaType,
                        uti: metadata.uti,
                        pixelWidth: metadata.pixelWidth,
                        pixelHeight: metadata.pixelHeight,
                        duration: metadata.duration,
                        thumbnailPath: nil,
                        thumbnailUpdatedAt: nil,
                        thumbnailCacheKey: nil,
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

                    _ = try? PhotoAsset.deleteOne(db, key: oldPhotoId)
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
                creationDate: creationDate,
                latitude: resolvedLatitude,
                longitude: resolvedLongitude,
                mediaType: metadata.mediaType,
                uti: metadata.uti,
                pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight,
                duration: metadata.duration,
                thumbnailPath: nil,
                thumbnailUpdatedAt: nil,
                thumbnailCacheKey: nil,
                modificationDate: nil,
                lastSeenAt: scanAt,
                importedAt: importedAt
            )
            try record.insert(db)

            // Trigger background thumbnail generation for new asset (throttled)
            let locator = MediaLocator.webdav(profileId: profile.id.uuidString, remotePath: remotePath)
            let mediaType = metadata.mediaType
            Task {
                await PhotoThumbnailScheduler.shared.schedule {
                    do {
                        let path = try await PhotoThumbnailGenerator.shared.generateThumbnail(for: locator, mediaType: mediaType)
                        try await DatabaseContainer.shared.writer.write { db in
                            if var asset = try PhotoAsset.fetchOne(db, key: photoId) {
                                asset.thumbnailPath = path
                                asset.thumbnailUpdatedAt = Date()
                                try asset.update(db)
                            }
                        }
                    } catch {
                        print("[WebDAVImport] Thumbnail generation failed for \(remotePath): \(error)")
                    }
                }
            }

            let remote = RemoteMediaAsset(
                id: UUID(),
                profileId: profile.id,
                remotePath: remotePath,
                etag: item.etag,
                lastModified: item.lastModified,
                size: item.contentLength,
                photoAssetId: photoId,
                indexedAt: indexedAt,
                lastSeenAt: scanAt,
                rawPath: nil,
                hasJPG: false,
                isPrimary: true,
                livePhotoVideoPath: nil,
                livePhotoPhotoPath: nil
            )

            do {
                try remote.insert(db)
            } catch {
                if let dbError = error as? DatabaseError,
                   dbError.resultCode == .SQLITE_CONSTRAINT,
                   dbError.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {

                    _ = try? PhotoAsset.deleteOne(db, key: photoId)

                    if var existing2 = try RemoteMediaAsset
                        .filter(Column("profileId") == profile.id && Column("remotePath") == remotePath)
                        .fetchOne(db) {

                        let oldPhotoId2 = existing2.photoAssetId
                        let hasChanged2 = hasItemChanged(existing2, item)

                        if hasChanged2 {
                            let newPhotoId2 = UUID()
                            let record2 = PhotoAsset(
                                id: newPhotoId2,
                                localIdentifier: nil,
                                creationDate: creationDate,
                                latitude: resolvedLatitude,
                                longitude: resolvedLongitude,
                                mediaType: metadata.mediaType,
                                uti: metadata.uti,
                                pixelWidth: metadata.pixelWidth,
                                pixelHeight: metadata.pixelHeight,
                                duration: metadata.duration,
                                thumbnailPath: nil,
                                thumbnailUpdatedAt: nil,
                                thumbnailCacheKey: nil,
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

                            _ = try? PhotoAsset.deleteOne(db, key: oldPhotoId2)
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
        var normalized = p.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        if normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func isSupportedMediaPath(_ href: String) -> Bool {
        let lower = href.lowercased()
        let extensions = [
            // Photos
            ".jpg", ".jpeg", ".png", ".heic", ".tiff",
            // RAW
            ".rw2", ".dng", ".nef", ".arw", ".cr2", ".cr3", ".orf", ".raf",
            // Videos
            ".mp4", ".mov", ".m4v"
        ]
        return extensions.contains { lower.hasSuffix($0) }
    }

    private struct MediaMetadata {
        var creationDate: Date?
        var latitude: Double?
        var longitude: Double?
        var mediaType: PhotoAsset.MediaType
        var uti: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var duration: Double?
    }

    private func extractMetadata(from url: URL, fileName: String) -> MediaMetadata {
        // Note: For video metadata, AVFoundation APIs became async-load based since iOS 16.
        // This helper is intentionally synchronous; we only extract image metadata here.
        // Video duration/size/location will be filled as best-effort where available.

        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let utType = UTType(filenameExtension: fileExtension)
        let uti = utType?.identifier

        let isVideo = utType?.conforms(to: .movie) ?? false || utType?.conforms(to: .video) ?? false
        let mediaType: PhotoAsset.MediaType = isVideo ? .video : .photo

        var metadata = MediaMetadata(
            creationDate: nil,
            latitude: nil,
            longitude: nil,
            mediaType: mediaType,
            uti: uti,
            pixelWidth: nil,
            pixelHeight: nil,
            duration: nil
        )

        if isVideo {
            let asset = AVURLAsset(url: url)

            // Try to extract GPS from multiple metadata keys and spaces
            let metadataItems = AVMetadataItem.metadataItems(from: asset.metadata, withKey: nil, keySpace: nil)

            for item in metadataItems {
                // 1. Common Key Location (ISO 6709)
                if let key = item.commonKey, key == .commonKeyLocation, let locationString = item.stringValue {
                    if let (lat, lon) = parseISO6709(locationString) {
                        metadata.latitude = lat
                        metadata.longitude = lon
                        break
                    }
                }

                // 2. QuickTime Location ISO 6709
                // Use rawValue strings here to avoid SDK differences (some SDKs don't expose typed constants).
                if item.keySpace?.rawValue == "mdta",
                   let key = item.key as? String,
                   key == "com.apple.quicktime.location.ISO6709",
                   let locationString = item.stringValue {
                    if let (lat, lon) = parseISO6709(locationString) {
                        metadata.latitude = lat
                        metadata.longitude = lon
                        break
                    }
                }

                // 3. User Data Location ISO 6709
                // Some SDKs don't have `.userData` typed member; match by rawValue.
                if item.keySpace?.rawValue == "udta",
                   let key = item.key as? String,
                   key == "\u{a9}xyz", // ©xyz is a common user data key for location
                   let locationString = item.stringValue {
                    if let (lat, lon) = parseISO6709(locationString) {
                        metadata.latitude = lat
                        metadata.longitude = lon
                        break
                    }
                }
            }

            // Duration and Size (basic)
            if let duration = try? CMTimeGetSeconds(asset.duration) {
                metadata.duration = duration
            }
            if let track = try? asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                metadata.pixelWidth = Int(abs(size.width))
                metadata.pixelHeight = Int(abs(size.height))
            }

            return metadata
        }

        // For images (including RAW), use ImageIO with URL (don't load into Data)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return metadata
        }

        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            metadata.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
            metadata.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int

            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    metadata.creationDate = parseExifDate(dateStr)
                }
            }

            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
                   let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
                   let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
                   let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                    metadata.latitude = (latRef.uppercased() == "S") ? -lat : lat
                    metadata.longitude = (lonRef.uppercased() == "W") ? -lon : lon
                }
            }
        }

        return metadata
    }

    private func parseISO6709(_ value: String) -> (Double, Double)? {
        // Supports multiple ISO 6709 variants:
        // 1. +DD.DDDD+DDD.DDDD/  (Decimal degrees)
        // 2. +DDMM.MMM+DDDMM.MMM/ (Degrees and decimal minutes)
        // 3. +DDMMSS.SS+DDDMMSS.SS/ (Degrees, minutes and decimal seconds)
        // Note: The last '/' and trailing text are optional.

        let trimmed = value.trimmingCharacters(in: .init(charactersIn: "/ ")).uppercased()

        // Pattern matches two groups of [+-][digits and dots]
        let pattern = "^([+-][0-9.]+)([+-][0-9.]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let r1 = Range(match.range(at: 1), in: trimmed),
              let r2 = Range(match.range(at: 2), in: trimmed) else {
            return nil
        }

        let latStr = String(trimmed[r1])
        let lonStr = String(trimmed[r2])

        func convertToDecimal(_ s: String) -> Double? {
            let sign = s.hasPrefix("-") ? -1.0 : 1.0
            let val = String(s.dropFirst())
            guard let num = Double(val) else { return nil }

            // Determine format based on number of digits before the decimal point
            let parts = val.components(separatedBy: ".")
            let integerPart = parts[0]

            if integerPart.count <= 3 {
                // Case 1: Decimal degrees (e.g., +38.8977)
                return num * sign
            } else if integerPart.count == 4 || integerPart.count == 5 {
                // Case 2: DDMM.MMM or DDDMM.MMM
                let degCount = integerPart.count - 2
                let d = Double(integerPart.prefix(degCount)) ?? 0
                let m = Double(integerPart.suffix(2)) ?? 0
                let decimalM = parts.count > 1 ? Double("0." + parts[1]) : 0
                return (d + (m + decimalM!) / 60.0) * sign
            } else if integerPart.count >= 6 {
                // Case 3: DDMMSS.SS or DDDMMSS.SS
                let degCount = integerPart.count - 4
                let d = Double(integerPart.prefix(degCount)) ?? 0
                let m = Double(integerPart.prefix(degCount + 2).suffix(2)) ?? 0
                let s = Double(integerPart.suffix(2)) ?? 0
                let decimalS = parts.count > 1 ? Double("0." + parts[1]) : 0
                return (d + (m / 60.0) + (s + decimalS!) / 3600.0) * sign
            }
            return num * sign
        }

        if let lat = convertToDecimal(latStr), let lon = convertToDecimal(lonStr) {
            return (lat, lon)
        }
        return nil
    }

    private func parseExifDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func parseXmpGps(_ xmp: String) -> (latitude: Double?, longitude: Double?) {
        func decodeXmlEntities(_ s: String) -> String {
            // Minimal entity decoding sufficient for ExifTool-generated XMP.
            return s
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#34;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }

        func extractAnyAttrValue(_ key: String) -> String? {
            // Match both `exif:GPSLatitude="..."` and `GPSLatitude="..."` anywhere in the document.
            // We purposefully do NOT anchor to tag names because ExifTool typically stores these on rdf:Description.
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "(?:^|[\\s<])(?:[A-Za-z0-9_\\-]+:)?" + escaped + "\\s*=\\s*\"([^\"]*)\""
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
            guard let m = re.firstMatch(in: xmp, range: NSRange(xmp.startIndex..<xmp.endIndex, in: xmp)) else { return nil }
            guard let r1 = Range(m.range(at: 1), in: xmp) else { return nil }
            return decodeXmlEntities(String(xmp[r1])).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func extractAnyTagValue(_ key: String) -> String? {
            // Match `<exif:GPSLatitude>...</exif:GPSLatitude>` or `<GPSLatitude>...</GPSLatitude>`
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "<\\s*(?:[A-Za-z0-9_\\-]+:)?" + escaped + "\\s*>(.*?)<\\s*/\\s*(?:[A-Za-z0-9_\\-]+:)?" + escaped + "\\s*>"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
            guard let m = re.firstMatch(in: xmp, range: NSRange(xmp.startIndex..<xmp.endIndex, in: xmp)) else { return nil }
            guard let r1 = Range(m.range(at: 1), in: xmp) else { return nil }
            return decodeXmlEntities(String(xmp[r1])).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func extractValue(_ key: String) -> String? {
            // Prefer attributes (most common for ExifTool sidecar), then fallback to tag content.
            return extractAnyAttrValue(key) ?? extractAnyTagValue(key)
        }

        func parseDmsOrDecimal(_ raw: String) -> Double? {
            // Supports formats like:
            // - 18 deg 18' 10.74" N
            // - 109 deg 20' 1.20" E
            // - 18.302983 (decimal)
            // - 18,18.17892N  (Panasonic/ExifTool compact format: degrees,minutes.decimal + direction)
            // - 109,20.02008E
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()

            let direction: String? = {
                if upper.contains(" N") || upper.hasSuffix("N") { return "N" }
                if upper.contains(" S") || upper.hasSuffix("S") { return "S" }
                if upper.contains(" E") || upper.hasSuffix("E") { return "E" }
                if upper.contains(" W") || upper.hasSuffix("W") { return "W" }
                if upper.contains("NORTH") { return "N" }
                if upper.contains("SOUTH") { return "S" }
                if upper.contains("EAST") { return "E" }
                if upper.contains("WEST") { return "W" }
                return nil
            }()

            // Panasonic/ExifTool compact: "18,18.17892N" => deg=18, min=18.17892
            if trimmed.contains(","),
               let re = try? NSRegularExpression(pattern: "^\\s*([0-9]+(?:\\.[0-9]+)?)\\s*,\\s*([0-9]+(?:\\.[0-9]+)?)\\s*([NSEW])\\s*$", options: [.caseInsensitive]),
               let m = re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
               let rDeg = Range(m.range(at: 1), in: trimmed),
               let rMin = Range(m.range(at: 2), in: trimmed),
               let rDir = Range(m.range(at: 3), in: trimmed) {
                let deg = Double(trimmed[rDeg])
                let minutes = Double(trimmed[rMin])
                let dir = trimmed[rDir].uppercased()
                if let deg, let minutes {
                    var decimal = deg + (minutes / 60.0)
                    if dir == "S" || dir == "W" { decimal = -decimal }
                    return decimal
                }
            }

            // Pull out numbers. In DMS case we'll use first 3 numbers.
            guard let re = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)", options: []) else { return nil }
            let matches = re.matches(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed))
            let nums: [Double] = matches.prefix(3).compactMap { m in
                guard let r = Range(m.range(at: 1), in: trimmed) else { return nil }
                return Double(trimmed[r])
            }

            if nums.count >= 3 {
                let d = nums[0]
                let m = nums[1]
                let s = nums[2]
                var decimal = d + (m / 60.0) + (s / 3600.0)
                if direction == "S" || direction == "W" { decimal = -decimal }
                return decimal
            }

            if nums.count == 2 {
                // Another common variant: degrees + minutes.decimal
                let d = nums[0]
                let m = nums[1]
                var decimal = d + (m / 60.0)
                if direction == "S" || direction == "W" { decimal = -decimal }
                return decimal
            }

            if nums.count == 1 {
                var decimal = nums[0]
                if direction == "S" || direction == "W" { decimal = -abs(decimal) }
                return decimal
            }

            return nil
        }

        let latRaw = extractValue("GPSLatitude")
        let lonRaw = extractValue("GPSLongitude")

        if Self.debug {
            print("[WebDAVImport][ExifDebug] XMP contains 'GPSLatitude'? \(xmp.localizedCaseInsensitiveContains("GPSLatitude")) 'GPSLongitude'? \(xmp.localizedCaseInsensitiveContains("GPSLongitude"))")
            print("[WebDAVImport][ExifDebug] XMP extracted latRaw=\(String(describing: latRaw)) lonRaw=\(String(describing: lonRaw))")
        }

        let lat = latRaw.flatMap(parseDmsOrDecimal)
        let lon = lonRaw.flatMap(parseDmsOrDecimal)

        if Self.debug {
            print("[WebDAVImport][ExifDebug] XMP parsed lat=\(String(describing: lat)) lon=\(String(describing: lon))")
        }

        return (latitude: lat, longitude: lon)
    }
}
