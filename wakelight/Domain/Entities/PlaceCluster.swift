import Foundation
import GRDB

enum FogState: String, Codable {
    case locked
    case partial
    case revealed
}

struct PlaceCluster: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "placeCluster"

    var id: UUID
    var centerLatitude: Double
    var centerLongitude: Double
    var geohash: String

    /// 城市名（仅城市语义，如“成都”）
    var cityName: String? = nil

    /// 详细地址（行政区/道路等地址语义）
    var detailedAddress: String? = nil

    /// POI 名称（地标/商户/景点语义）
    var poiName: String? = nil

    /// POI 类型（如“商务住宅;住宅区;住宅小区”）
    var poiType: String? = nil

    var photoCount: Int
    var visitCount: Int
    var fogState: FogState
    var hasStory: Bool
    var lastVisitedAt: Date?
}
