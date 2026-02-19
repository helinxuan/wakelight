import Foundation
import GRDB

struct RemoteMediaAsset: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "remoteMediaAsset"

    var id: UUID
    var profileId: UUID
    var remotePath: String
    var etag: String?
    var lastModified: Date?
    var size: Int?
    var photoAssetId: UUID
    var indexedAt: Date
}
