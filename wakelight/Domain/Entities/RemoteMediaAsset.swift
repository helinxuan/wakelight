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
    var lastSeenAt: Date?

    // Pairing info for RAW+JPG
    var rawPath: String?
    var hasJPG: Bool
    var isPrimary: Bool

    // Pairing info for Live Photo (HEIC + MOV/MP4/M4V)
    var livePhotoVideoPath: String?
    var livePhotoPhotoPath: String?
}
