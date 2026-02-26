import Foundation
import GRDB

struct PhotoAsset: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "photoAsset"

    enum MediaType: String, Codable {
        case photo
        case video
    }

    var id: UUID
    var localIdentifier: String?
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?

    // MARK: - Media metadata (v2)
    var mediaType: MediaType?
    var uti: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?

    // MARK: - Cached thumbnails
    var thumbnailPath: String?
    var thumbnailUpdatedAt: Date?
    var thumbnailCacheKey: String?

    // MARK: - Curation
    var burstGroupId: String?
    var bestShotScore: Double?
    var selectionReason: String?
    var curationBucket: String?
    var isRecoverableArchived: Bool?
    var recognizedTextConfidence: Double?

    // MARK: - Sync / bookkeeping
    var modificationDate: Date?
    var lastSeenAt: Date?
    var importedAt: Date
}
