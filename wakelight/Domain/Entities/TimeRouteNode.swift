import Foundation
import GRDB

struct TimeRouteNode: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "timeRouteNode"

    var id: UUID
    var visitLayerId: UUID
    var storyId: UUID? // 新增：所属故事 ID
    var sortOrder: Int
    var displayTitle: String?
    var displaySummary: String?
    var displayLocation: String?

    // 关联的数据，用于 UI 展示，不直接存入数据库
    var coverPhotoIdentifier: String?
    var visitLayer: VisitLayer?
    var placeCluster: PlaceCluster?

    enum Columns {
        static let id = Column("id")
        static let visitLayerId = Column("visitLayerId")
        static let storyId = Column("storyId")
        static let sortOrder = Column("sortOrder")
    }
}
