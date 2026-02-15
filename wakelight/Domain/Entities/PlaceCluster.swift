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
    var cityName: String?
    var photoCount: Int
    var visitCount: Int
    var fogState: FogState
    var hasStory: Bool
    var lastVisitedAt: Date?
}
