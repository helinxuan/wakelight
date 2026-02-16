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
                
                // 获取地址信息
                let locationName = cluster?.detailedAddress ?? cluster?.cityName
                
                // 获取该故事下所有访次的时间范围
                let layers = try VisitLayer
                    .filter(story.subVisitLayerIds.contains(Column("id")))
                    .order(Column("startAt").asc)
                    .fetchAll(db)
                
                let firstLayer = layers.first
                let lastLayer = layers.last
                
                let dateDisplay: String?
                if let start = firstLayer?.startAt, let end = lastLayer?.endAt {
                    dateDisplay = self.formatDateRange(start: start, end: end)
                } else {
                    dateDisplay = nil
                }
                
                let node = TimeRouteNode(
                    id: UUID(),
                    visitLayerId: story.subVisitLayerIds.first ?? UUID(),
                    sortOrder: index,
                    displayTitle: dateDisplay,
                    displaySummary: story.mainSummary,
                    displayLocation: locationName,
                    coverPhotoIdentifier: story.coverPhotoId,
                    visitLayer: firstLayer,
                    placeCluster: cluster
                )
                nodes.append(node)
            }
            return nodes
        }
    }

    private func formatDateRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        
        if Calendar.current.isDate(start, inSameDayAs: end) {
            formatter.dateFormat = "yyyy年MM月dd日"
            return formatter.string(from: start)
        } else {
            formatter.dateFormat = "MM月dd日"
            let startStr = formatter.string(from: start)
            let endStr = formatter.string(from: end)
            formatter.dateFormat = "yyyy年"
            let yearStr = formatter.string(from: start)
            return "\(yearStr)\(startStr) - \(endStr)"
        }
    }
}
