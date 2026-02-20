import Foundation
import GRDB

struct WebDAVProfile: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "webdavProfile"

    var id: UUID
    var name: String
    var baseURLString: String
    var username: String
    var passwordKey: String

    /// Legacy single root. Kept for backward compatibility.
    var rootPath: String?

    /// Multi-root support. Stored as JSON in `rootPathsJson`.
    var rootPathsJson: String?

    var createdAt: Date
    var updatedAt: Date

    var baseURL: URL? { URL(string: baseURLString) }

    /// Normalized root directories to import.
    /// - If `rootPathsJson` is present and decodes, it is used.
    /// - Otherwise falls back to legacy `rootPath`.
    var rootPaths: [String] {
        get {
            if let json = rootPathsJson,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded
                    .map { WebDAVPath.normalizeDirectory($0) }
                    .filter { !$0.isEmpty }
            }
            if let rootPath, !rootPath.isEmpty {
                return [WebDAVPath.normalizeDirectory(rootPath)].filter { !$0.isEmpty }
            }
            return []
        }
        set {
            let normalized = Array(Set(newValue.map { WebDAVPath.normalizeDirectory($0) }))
                .filter { !$0.isEmpty }
                .sorted()
            if let data = try? JSONEncoder().encode(normalized) {
                rootPathsJson = String(data: data, encoding: .utf8)
            } else {
                rootPathsJson = nil
            }
            // Keep legacy rootPath roughly in sync for older code paths
            rootPath = normalized.first
        }
    }
}
