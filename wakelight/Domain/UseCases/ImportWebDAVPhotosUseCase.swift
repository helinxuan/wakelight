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
            // 用户可能在设置里选择了目录但没点“保存”，导致仍然用默认根目录扫描。
            // 根目录扫描通常会遇到大量系统/临时目录（例如 ClickHouse 的 tmp_merge_*），可能导致 404。
            // 这里不阻止导入：只给出提示，并继续扫描。
            await PhotoImportManager.shared.reportNonFatalWarning(
                "当前 WebDAV 导入路径是根目录 /（可能还没点击保存）。建议到 设置 → WebDAV 选择照片目录后点击保存，以避免扫描到系统/临时目录。"
            )
        }
        print("[WebDAVImport] Start PROPFIND recursively from \(rootPath)")

        let importedAt = Date()
        let indexedAt = importedAt

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

        // 1. Prefetch existing assets to avoid per-item DB reads
        print("[WebDAVImport] Prefetching existing assets...")
        let existingKeys: Set<String> = try await writer.read { db in
            let assets = try RemoteMediaAsset
                .filter(Column("profileId") == profile.id.uuidString)
                .fetchAll(db)
            let keys = assets.map { "\($0.remotePath)|\($0.etag ?? "")" }
            return Set(keys)
        }

        let itemsToImport = imageItems.filter { item in
            let remotePath = normalize(path: item.href)
            let key = "\(remotePath)|\(item.etag ?? "")"
            return !existingKeys.contains(key)
        }
        print("[WebDAVImport] Items to import: \(itemsToImport.count) (skipped \(imageItems.count - itemsToImport.count))")

        if itemsToImport.isEmpty {
            await onProgress?(imageItems.count, imageItems.count)
            return 0
        }

        // 2. Concurrent download and EXIF extraction with bounded concurrency
        let concurrency = 4
        let total = itemsToImport.count
        var completedInSession = 0

        await onProgress?(0, total)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = itemsToImport.enumerated().makeIterator()

            // Initial batch
            for _ in 0..<min(concurrency, total) {
                if let next = iterator.next() {
                    group.addTask {
                        try await self.importItem(next.element, index: next.offset, total: total, client: client, profile: profile, importedAt: importedAt, indexedAt: indexedAt)
                    }
                }
            }

            while let _ = try await group.next() {
                completedInSession += 1
                importedCount += 1
                await onProgress?(completedInSession, total)

                if let next = iterator.next() {
                    group.addTask {
                        try await self.importItem(next.element, index: next.offset, total: total, client: client, profile: profile, importedAt: importedAt, indexedAt: indexedAt)
                    }
                }
            }
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
        indexedAt: Date
    ) async throws {
        let remotePath = normalize(path: item.href)
        print("[WebDAVImport] [\(index+1)/\(total)] Downloading: \(remotePath)")

        let data = try await client.get(path: remotePath)
        let exif = extractExif(from: data)

        try await writer.write { db in
            let photoId = UUID()
            let record = PhotoAsset(
                id: photoId,
                localIdentifier: nil,
                creationDate: exif.creationDate,
                latitude: exif.latitude,
                longitude: exif.longitude,
                thumbnailPath: nil,
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
                indexedAt: indexedAt
            )
            try remote.insert(db)
        }
    }

    private func listRecursively(client: WebDAVClient, path: String) async throws -> [WebDAVDirectoryItem] {
        var visited = Set<String>()
        return try await listRecursively(client: client, path: path, visited: &visited)
    }

    private func listRecursively(client: WebDAVClient, path: String, visited: inout Set<String>) async throws -> [WebDAVDirectoryItem] {
        let normalizedPath = normalize(path: path)
        if visited.contains(normalizedPath) {
            print("[WebDAVImport] Skip listing already visited path: \(normalizedPath)")
            return []
        }
        visited.insert(normalizedPath)

        // Skip some common system/transient folders
        let lower = normalizedPath.lowercased()
        if lower.contains("#recycle") || lower.contains("recycle") {
            print("[WebDAVImport] Skip system path: \(normalizedPath)")
            return []
        }
        // ClickHouse / database transient folders (can appear/disappear during scan)
        if lower.contains("/tmp_") || lower.contains("tmp_merge") || lower.contains("tmp_mut") {
            print("[WebDAVImport] Skip transient path: \(normalizedPath)")
            return []
        }

        print("[WebDAVImport] PROPFIND depth=1 path=\(normalizedPath)")
        var results: [WebDAVDirectoryItem] = []
        let items = try await client.propfind(path: normalizedPath, depth: "1")
        print("[WebDAVImport] PROPFIND returned \(items.count) items for path=\(normalizedPath)")

        for item in items {
            let href = normalize(path: item.href)

            if href == normalizedPath {
                continue
            }

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
        if path == "/" { return "/" }
        return path.hasPrefix("/") ? path : "/" + path
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
