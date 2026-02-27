import Foundation
import GRDB

/// 在同一 PlaceCluster 内按时间切分 VisitLayer（MVP：阈值切分）。
final class GenerateVisitLayersUseCase {
    private let writer: DatabaseWriter
    private let config: AppConfig

    init(
        writer: DatabaseWriter = DatabaseContainer.shared.writer,
        config: AppConfig = .default
    ) {
        self.writer = writer
        self.config = config
    }

    func run() async throws -> Int {
        try await writer.write { db in
            let clusters = try PlaceCluster.fetchAll(db)
            var totalCreatedOrUpdated = 0

            for cluster in clusters {
                // 仅使用“保留/未标注”照片生成 VisitLayer；已归档过滤的不参与分层
                let allPhotos = try PhotoAsset
                    .filter((Column("curationBucket") != ImportDecisionBucket.archived.rawValue) || Column("curationBucket") == nil)
                    .fetchAll(db)
                let bucketPhotos = allPhotos.filter { p in
                    guard let lat = p.latitude, let lon = p.longitude else { return false }
                    return GeoGrid.key(latitude: lat, longitude: lon) == cluster.geohash
                }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

                if bucketPhotos.isEmpty {
                    print("⚠️ No photos found for cluster: \(cluster.geohash)")
                    continue
                }

                // 先删除该 cluster 既有 VisitLayer（MVP 简化，后续做增量/合并）
                // 同时清理关联表（依赖 visitLayer cascade，但这里先显式清理避免遗留）
                let existingLayers = try VisitLayer
                    .filter(Column("placeClusterId") == cluster.id)
                    .fetchAll(db)
                for l in existingLayers {
                    _ = try VisitLayerPhotoAsset.filter(Column("visitLayerId") == l.id.uuidString).deleteAll(db)
                }
                _ = try VisitLayer.filter(Column("placeClusterId") == cluster.id).deleteAll(db)

                var segments: [(start: Date, end: Date)] = []
                var currentStart: Date?
                var currentEnd: Date?

                for p in bucketPhotos {
                    guard let date = p.creationDate else { continue }

                    if currentStart == nil {
                        currentStart = date
                        currentEnd = date
                        continue
                    }

                    if let end = currentEnd, date.timeIntervalSince(end) > config.visitSplitThreshold {
                        if let s = currentStart, let e = currentEnd {
                            segments.append((s, e))
                        }
                        currentStart = date
                        currentEnd = date
                    } else {
                        currentEnd = date
                    }
                }

                if let s = currentStart, let e = currentEnd {
                    segments.append((s, e))
                }

                var order = 0
                for seg in segments {
                    order += 1
                    let layerId = UUID()
                    let layer = VisitLayer(
                        id: layerId,
                        placeClusterId: cluster.id,
                        startAt: seg.start,
                        endAt: seg.end,
                        userText: nil,
                        isStoryNode: false,
                        tagsJson: nil,
                        voiceNotePath: nil,
                        settledAt: nil
                    )
                    try layer.insert(db)
                    
                    // 绑定属于该访次的照片
                    let photosInLayer = bucketPhotos.filter { p in
                        guard let date = p.creationDate else { return false }
                        return date >= seg.start && date <= seg.end
                    }
                    
                    for photo in photosInLayer {
                        let link = VisitLayerPhotoAsset(visitLayerId: layerId, photoAssetId: photo.id)
                        try link.insert(db)
                    }
                    
                    totalCreatedOrUpdated += 1
                }

                // 更新 visitCount
                var updatedCluster = cluster
                updatedCluster.visitCount = segments.count
                try updatedCluster.update(db)
            }

            return totalCreatedOrUpdated
        }
    }
}
