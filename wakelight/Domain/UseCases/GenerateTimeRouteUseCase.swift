import Foundation
import GRDB

struct GenerateTimeRouteUseCase {
    private let db: DatabaseWriter

    init(db: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.db = db
    }

    func run() async throws -> [TimeRouteNode] {
        try await db.read { db in
            let storyNodes = try StoryNode
                .order(Column("createdAt").asc)
                .fetchAll(db)

            var nodes: [TimeRouteNode] = []

            for (index, story) in storyNodes.enumerated() {
                let cluster = try PlaceCluster
                    .filter(Column("id") == story.placeClusterId)
                    .fetchOne(db)

                let locationName = cluster?.detailedAddress ?? cluster?.cityName

                // 尝试加载记录的 VisitLayer
                let storyLayerIds = story.subVisitLayerIds
                var layers: [VisitLayer] = []
                
                if !storyLayerIds.isEmpty {
                    // 优先按记录的 ID 加载
                    layers = try VisitLayer.fetchAll(db, keys: storyLayerIds)
                }
                
                // 【核心兜底逻辑】如果按 ID 加载不到任何内容，说明数据断链了
                if layers.isEmpty {
                    print("DEBUG: DATA_LINK_BROKEN - Story \(story.id) recorded IDs not found. Attempting to recover via placeClusterId...")
                    // 自动找回该地点下的所有故事关联记忆
                    layers = try VisitLayer
                        .filter(Column("placeClusterId") == story.placeClusterId)
                        .filter(Column("isStoryNode") == true)
                        .order(Column("startAt").asc)
                        .fetchAll(db)
                    
                    if layers.isEmpty {
                        // 如果还是没有，找回该地点下任何记忆（最后的倔强）
                        layers = try VisitLayer
                            .filter(Column("placeClusterId") == story.placeClusterId)
                            .order(Column("startAt").asc)
                            .fetchAll(db)
                    }
                }
                
                let firstLayer = layers.sorted(by: { $0.startAt < $1.startAt }).first
                
                // 打印最终结果，方便调试
                if let matched = firstLayer {
                    print("DEBUG: TimeRouteNode Generated - storyId=\(story.id) visitLayerId=\(matched.id) recovered=\(storyLayerIds.contains(matched.id) == false)")
                } else {
                    print("DEBUG: FATAL - No VisitLayer found for story \(story.id) even after recovery attempts.")
                }

                let node = TimeRouteNode(
                    id: UUID(),
                    visitLayerId: firstLayer?.id ?? (storyLayerIds.first ?? UUID()),
                    sortOrder: index,
                    displayTitle: firstLayer != nil ? self.formatDateRange(start: firstLayer!.startAt, end: firstLayer!.endAt) : "未知时间",
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
