import Foundation
import GRDB

struct GenerateTimeRouteUseCase {
    private let db: DatabaseWriter

    init(db: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.db = db
    }

    func run() async throws -> [TimeRouteNode] {
        try await db.read { db in
            // 1. 获取所有 StoryNode，并按创建时间或子访次的最早时间升序排列
            let storyNodes = try StoryNode
                .order(Column("createdAt").asc)
                .fetchAll(db)

            // 2. 将 StoryNode 映射为 TimeRouteNode
            var nodes: [TimeRouteNode] = []
            for (index, story) in storyNodes.enumerated() {
                // 获取该故事关联的第一个集群信息
                let cluster = try PlaceCluster
                    .filter(Column("id") == story.placeClusterId)
                    .fetchOne(db)
                
                // 获取该故事下所有访次的最早时间
                let firstLayer = try VisitLayer
                    .filter(story.subVisitLayerIds.contains(Column("id")))
                    .order(Column("startAt").asc)
                    .fetchOne(db)
                
                let node = TimeRouteNode(
                    id: UUID(),
                    visitLayerId: story.subVisitLayerIds.first ?? UUID(), // 保持兼容
                    sortOrder: index,
                    displayTitle: firstLayer.map { self.formatDate(from: $0.startAt) } ?? "精彩时刻",
                    displaySummary: story.mainSummary,
                    coverPhotoIdentifier: story.coverPhotoId,
                    visitLayer: firstLayer, // 取第一个访次作为代表
                    placeCluster: cluster
                )
                nodes.append(node)
            }
            return nodes
        }
    }

    private func formatDate(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter.string(from: date)
    }
}
