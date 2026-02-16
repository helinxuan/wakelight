import Foundation
import GRDB

struct GenerateTimeRouteUseCase {
    private let db: DatabaseWriter

    init(db: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.db = db
    }

    func run() async throws -> [TimeRouteNode] {
        try await db.read { db in
            // 1. 加载所有 StoryNode
            let storyNodes = try StoryNode.fetchAll(db)

            var nodesWithStartTime: [(node: TimeRouteNode, startTime: Date)] = []

            for story in storyNodes {
                // 2. 加载该 Story 关联的所有 VisitLayer
                let storyLayerIds = story.subVisitLayerIds
                guard !storyLayerIds.isEmpty else { continue }
                
                let layers = try VisitLayer.fetchAll(db, keys: storyLayerIds)
                
                // 诊断日志：帮助排查日期缺失问题
                #if DEBUG
                print("DEBUG: StoryNode Diagnostic - id=\(story.id) summary=\(story.mainSummary ?? "nil")")
                print("  Expected Layer IDs (\(storyLayerIds.count)): \(storyLayerIds)")
                print("  Found Layers in DB (\(layers.count)): \(layers.map { "\($0.id) (\($0.startAt))" })")
                if layers.count != storyLayerIds.count {
                    let missingIds = Set(storyLayerIds).subtracting(Set(layers.map { $0.id }))
                    print("  !!! MISSING IDs: \(missingIds)")
                }
                #endif

                guard !layers.isEmpty else { continue }
                
                // 3. 确定时间范围
                let sortedLayers = layers.sorted(by: { $0.startAt < $1.startAt })
                let firstLayer = sortedLayers.first!
                let lastLayer = sortedLayers.last!
                
                // 4. 确定锚点 Layer（用户选最新：startAt 最晚）
                let anchorLayer = lastLayer
                
                // 5. 加载位置信息：优先从锚点 Layer 获取，解决“未知地点”问题
                let cluster = try PlaceCluster.fetchOne(db, key: anchorLayer.placeClusterId) ?? PlaceCluster.fetchOne(db, key: story.placeClusterId)
                
                #if DEBUG
                if cluster == nil {
                    print("  !!! CLUSTER NOT FOUND for storyId=\(story.id) clusterId=\(anchorLayer.placeClusterId)")
                } else {
                    print("  Cluster Found: \(cluster?.detailedAddress ?? cluster?.cityName ?? "Unknown Name")")
                }
                #endif

                let locationName = cluster?.detailedAddress ?? cluster?.cityName

                let node = TimeRouteNode(
                    id: UUID(),
                    visitLayerId: anchorLayer.id,
                    storyId: story.id,
                    sortOrder: 0,
                    displayTitle: self.formatDateRange(start: firstLayer.startAt, end: lastLayer.endAt),
                    displaySummary: story.mainSummary,
                    displayLocation: locationName,
                    coverPhotoIdentifier: story.coverPhotoId,
                    visitLayer: anchorLayer,
                    placeCluster: cluster
                )
                nodesWithStartTime.append((node, firstLayer.startAt))
            }

            // 6. 按“故事最早开始时间”全局排序（最早的在前面）
            let sortedNodes = nodesWithStartTime.sorted { $0.startTime < $1.startTime }
            
            var finalNodes: [TimeRouteNode] = []
            for i in sortedNodes.indices {
                var node = sortedNodes[i].node
                node.sortOrder = i
                finalNodes.append(node)
            }

            return finalNodes
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
