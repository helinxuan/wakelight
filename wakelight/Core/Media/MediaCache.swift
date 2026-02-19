import Foundation
import CoreGraphics

protocol MediaCacheProtocol {
    func thumbnailURL(for locator: MediaLocator, size: CGSize) throws -> URL
    func ensureDirectories() throws
}

final class MediaCache: MediaCacheProtocol {
    static let shared = MediaCache()

    private let fileManager: FileManager

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureDirectories() throws {
        _ = try thumbnailsDirectoryURL()
    }

    func thumbnailURL(for locator: MediaLocator, size: CGSize) throws -> URL {
        let key = "thumb|\(locator.stableKey)|\(Int(size.width))x\(Int(size.height))"
        let hashed = Self.fnv1a64Hex(key)
        return try thumbnailsDirectoryURL().appendingPathComponent("\(hashed).jpg")
    }

    private func thumbnailsDirectoryURL() throws -> URL {
        let base = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("thumbnails", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
