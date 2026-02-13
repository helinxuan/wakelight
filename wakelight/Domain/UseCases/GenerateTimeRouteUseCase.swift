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
                
                // 获取封面图：该访次内最新的一张照片
                let sql = """
                    SELECT p.localIdentifier 
                    FROM photoAsset p
                    JOIN visitLayerPhotoAsset vlp ON vlp.photoAssetId = p.id
                    WHERE vlp.visitLayerId = ?
                    ORDER BY p.creationDate DESC
                    LIMIT 1
                """
                let coverId = try String.fetchOne(db, sql: sql, arguments: [layer.id])
                
                let node = TimeRouteNode(
                    id: UUID(),
                    visitLayerId: layer.id,
                    sortOrder: index,
                    displayTitle: self.formatDateRange(layer),
                    displaySummary: layer.userText,
                    coverPhotoIdentifier: coverId,
                    visitLayer: layer,
                    placeCluster: cluster
                )
                nodes.append(node)
            }
            return nodes
        }
    }

    private func formatDateRange(_ layer: VisitLayer) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: layer.startAt)
    }
}
