import Foundation
import GRDB

struct VisitLayerPhotoAsset: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "visitLayerPhotoAsset"

    var visitLayerId: UUID
    var photoAssetId: UUID
}
