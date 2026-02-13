import Foundation
import GRDB

struct TimeRouteNode: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "timeRouteNode"

    var id: UUID
    var visitLayerId: UUID
    var sortOrder: Int
    var displayTitle: String?
    var displaySummary: String?

    // 关联的 VisitLayer 数据，用于 UI 展示，不直接存入数据库
    var visitLayer: VisitLayer?
    var placeCluster: PlaceCluster?

    enum Columns {
        static let id = Column("id")
        static let visitLayerId = Column("visitLayerId")
        static let sortOrder = Column("sortOrder")
    }
}
