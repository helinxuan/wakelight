import Foundation
import GRDB

struct GenerateTimeRouteUseCase {
    private let db: DatabaseWriter

    init(db: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.db = db
    }

    func run() async throws -> [TimeRouteNode] {
        try await db.read { db in
            // 1. 获取所有标记为 StoryNode 的 VisitLayer，并按时间升序排列
            let visitLayers = try VisitLayer
                .filter(Column("isStoryNode") == true)
                .order(Column("startAt").asc)
                .fetchAll(db)

            // 2. 将 VisitLayer 映射为 TimeRouteNode，并填充关联数据
            var nodes: [TimeRouteNode] = []
            for (index, layer) in visitLayers.enumerated() {
                let cluster = try PlaceCluster
                    .filter(Column("id") == layer.placeClusterId)
                    .fetchOne(db)
                
                let node = TimeRouteNode(
                    id: UUID(),
                    visitLayerId: layer.id,
                    sortOrder: index,
                    displayTitle: cluster?.geohash, // 临时使用 geohash 作为标题，后续可优化
                    displaySummary: layer.userText,
                    visitLayer: layer,
                    placeCluster: cluster
                )
                nodes.append(node)
            }
            return nodes
        }
    }
}
