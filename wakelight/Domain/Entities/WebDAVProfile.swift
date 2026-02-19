import Foundation
import GRDB

struct WebDAVProfile: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "webdavProfile"

    var id: UUID
    var name: String
    var baseURLString: String
    var username: String
    var passwordKey: String
    var rootPath: String?
    var createdAt: Date
    var updatedAt: Date

    var baseURL: URL? { URL(string: baseURLString) }
}
