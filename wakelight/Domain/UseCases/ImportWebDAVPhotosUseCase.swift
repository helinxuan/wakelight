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

    func run(profileId: String? = nil) async throws -> Int {
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
            print("[WebDAVImport] No supported images found")
            return 0
        }

        var importedCount = 0

        // `writer.write` expects a synchronous closure. Do network I/O outside the DB write transaction,
        // then only perform synchronous inserts inside `writer.write`.
        for (idx, item) in imageItems.enumerated() {
            let remotePath = normalize(path: item.href)
            print("[WebDAVImport] [\(idx+1)/\(imageItems.count)] remotePath=\(remotePath) etag=\(item.etag ?? "nil") size=\(item.contentLength.map(String.init) ?? "nil")")

            // Check if already imported (DB read)
            let exists: Bool = try await writer.read { db in
                if let etag = item.etag {
                    return try RemoteMediaAsset
                        .filter(Column("profileId") == profile.id.uuidString)
                        .filter(Column("remotePath") == remotePath)
                        .filter(Column("etag") == etag)
                        .fetchOne(db) != nil
                } else {
                    return try RemoteMediaAsset
                        .filter(Column("profileId") == profile.id.uuidString)
                        .filter(Column("remotePath") == remotePath)
                        .fetchOne(db) != nil
                }
            }
            if exists {
                print("[WebDAVImport]   - Skip: already imported")
                continue
            }

            // Network + CPU work outside transaction
            print("[WebDAVImport]   - Downloading and extracting EXIF...")
            let data = try await client.get(path: remotePath)
            let exif = extractExif(from: data)
            print("[WebDAVImport]   - EXIF: date=\(exif.creationDate.map { "\($0)" } ?? "nil") lat=\(exif.latitude ?? 0) lon=\(exif.longitude ?? 0)")

            // Persist inside a synchronous write
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

            importedCount += 1
        }

        return importedCount
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

        // Skip some common system folders
        if normalizedPath.lowercased().contains("#recycle") || normalizedPath.lowercased().contains("recycle") {
            print("[WebDAVImport] Skip system path: \(normalizedPath)")
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
