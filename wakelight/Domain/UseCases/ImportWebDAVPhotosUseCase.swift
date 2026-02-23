import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

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

        let imageItems = allItems.filter { item in
            guard !item.isCollection else { return false }
            return isSupportedImagePath(item.href)
        }
        print("[WebDAVImport] Filtered image items=\(imageItems.count)")

        if imageItems.isEmpty {
            await onProgress?(0, 0)
            print("[WebDAVImport] No supported images found")
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

        let itemsToImport = imageItems.filter { item in
            let remotePath = normalize(path: item.href)
            if let existing = existingAssets[remotePath] {
                return hasItemChanged(existing, item)
            }
            return true
        }

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
                    .filter(Column("profileId") == profile.id && unchangedPaths.contains(Column("remotePath")))
                    .updateAll(db, Column("lastSeenAt").set(to: scanAt))
            }
        }

        print("[WebDAVImport] Items to import: \(itemsToImport.count) (unchanged: \(unchangedItems.count), total images: \(imageItems.count))")

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
        var exif = extractExif(from: data)

        // Copy out values used inside the DB write closure to satisfy Swift 6 strict concurrency rules.
        // We will update these if we later find GPS in a sidecar XMP.
        let creationDate = exif.creationDate
        var latitude = exif.latitude
        var longitude = exif.longitude

        // Fallback: if the JPG has no embedded GPS, try the sidecar XMP (e.g. "P1068350.JPG.xmp").
        if latitude == nil || longitude == nil {
            let xmpPath1 = remotePath + ".xmp" // "P1068350.JPG" -> "P1068350.JPG.xmp"
            let xmpPath2: String? = {
                // Also try "P1068350.xmp" (without the .JPG part) for compatibility.
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
                    exif.latitude = lat
                    exif.longitude = lon
                    latitude = lat
                    longitude = lon
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
                        latitude: latitude,
                        longitude: longitude,
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
