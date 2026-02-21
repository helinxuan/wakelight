import Foundation
import GRDB

struct PhotoAsset: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "photoAsset"

    var id: UUID
    var localIdentifier: String?
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var thumbnailPath: String?
    var modificationDate: Date?
    var lastSeenAt: Date?
    var importedAt: Date
}
