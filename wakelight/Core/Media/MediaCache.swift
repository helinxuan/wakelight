import Foundation
import CoreGraphics

protocol MediaCacheProtocol {
    func thumbnailURL(for locator: MediaLocator, size: CGSize) throws -> URL
    func ensureDirectories() throws

    /// Total disk usage (bytes) for thumbnails directory.
    func thumbnailsDiskUsageBytes() throws -> UInt64

    /// Trim thumbnail cache to fit within current configured limit.
    func trimThumbnailsIfNeeded() throws

    /// Clear all cached thumbnails.
    func clearThumbnails() throws
}

final class MediaCache: MediaCacheProtocol {
    static let shared = MediaCache()

    /// UserDefaults key for thumbnail cache limit.
    static let thumbnailCacheLimitBytesKey = "wakelight.thumbnailCacheLimitBytes"

    /// Default thumbnail cache limit: 1 GB.
    static let defaultThumbnailCacheLimitBytes: UInt64 = 1_073_741_824

    private let fileManager: FileManager

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Settings

    var thumbnailCacheLimitBytes: UInt64 {
        get {
            let stored = UserDefaults.standard.object(forKey: Self.thumbnailCacheLimitBytesKey) as? NSNumber
            let value = stored?.uint64Value ?? Self.defaultThumbnailCacheLimitBytes
            // Guardrail: avoid 0 or negative (NSNumber) values
            return max(50 * 1024 * 1024, value) // min 50MB
        }
        set {
            UserDefaults.standard.set(NSNumber(value: newValue), forKey: Self.thumbnailCacheLimitBytesKey)
        }
    }

    // MARK: - Public

    func ensureDirectories() throws {
        _ = try thumbnailsDirectoryURL()
    }

    func thumbnailURL(for locator: MediaLocator, size: CGSize) throws -> URL {
        let key = "thumb|\(locator.stableKey)|\(Int(size.width))x\(Int(size.height))"
        let hashed = Self.fnv1a64Hex(key)
        return try thumbnailsDirectoryURL().appendingPathComponent("\(hashed).jpg")
    }

    func thumbnailsDiskUsageBytes() throws -> UInt64 {
        let dir = try thumbnailsDirectoryURL()
        return try directorySizeBytes(dir)
    }

    func trimThumbnailsIfNeeded() throws {
        let dir = try thumbnailsDirectoryURL()
        let limit = thumbnailCacheLimitBytes

        var usage = try directorySizeBytes(dir)
        guard usage > limit else { return }

        // Collect files and their LRU date
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey
        ]

        let fileURLs = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])

        struct Entry {
            let url: URL
            let size: UInt64
            let lruDate: Date
        }

        var entries: [Entry] = []
        entries.reserveCapacity(fileURLs.count)

        for url in fileURLs {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }

            let size = UInt64(values.fileSize ?? 0)
            let lru = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            entries.append(.init(url: url, size: size, lruDate: lru))
        }

        // Oldest first
        entries.sort { $0.lruDate < $1.lruDate }

        for entry in entries {
            guard usage > limit else { break }
            do {
                try fileManager.removeItem(at: entry.url)
                usage = usage > entry.size ? (usage - entry.size) : 0
            } catch {
                // Ignore individual deletion failures
                continue
            }
        }
    }

    func clearThumbnails() throws {
        let dir = try thumbnailsDirectoryURL()
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        // Recreate
        _ = try thumbnailsDirectoryURL()
    }

    // MARK: - Internals

    private func thumbnailsDirectoryURL() throws -> URL {
        let base = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("thumbnails", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func directorySizeBytes(_ dir: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return 0
        }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    private static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}
