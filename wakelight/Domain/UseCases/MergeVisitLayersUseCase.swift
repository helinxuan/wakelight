import Foundation
import GRDB

final class MergeVisitLayersUseCase {
    private let writer: DatabaseWriter

    init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
    }

    func run(visitLayerIds: [UUID], summaryText: String, title: String? = nil) async throws -> UUID {
        let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard visitLayerIds.count >= 2 else { throw MergeVisitLayersError.notEnoughLayers }
        guard !trimmed.isEmpty else { throw MergeVisitLayersError.emptySummary }

        let now = Date()

        let (storyId, _, emittedVisitLayerId, allInvolvedClusterIds): (UUID, UUID, UUID, Set<UUID>) = try await writer.write { db in
            let layers = try VisitLayer
                .filter(visitLayerIds.contains(Column("id")))
                .fetchAll(db)

            guard layers.count == visitLayerIds.count else {
                throw MergeVisitLayersError.visitLayerNotFound
            }

            guard let firstClusterId = layers.first?.placeClusterId else {
                throw MergeVisitLayersError.visitLayerNotFound
            }

            // 允许跨地点合并，选取包含 VisitLayer 数量最多的集群作为故事的主归属点
            let clusterCounts = layers.reduce(into: [UUID: Int]()) { $0[$1.placeClusterId, default: 0] += 1 }
            let primaryClusterId = clusterCounts.max(by: { $0.value < $1.value })?.key ?? firstClusterId

            let orderedLayers = layers.sorted(by: { $0.startAt < $1.startAt })
            let orderedLayerIds = orderedLayers.map { $0.id }

            // Pick a cover photo (stable strategy): latest PhotoAsset.creationDate among selected layers
            let linkRows = try VisitLayerPhotoAsset
                .filter(orderedLayerIds.contains(Column("visitLayerId")))
                .fetchAll(db)

            let photoAssetIds = Array(Set(linkRows.map { $0.photoAssetId }))
            guard !photoAssetIds.isEmpty else {
                throw MergeVisitLayersError.coverPhotoNotFound
            }

            let coverPhotoId = try PhotoAsset
                .filter(photoAssetIds.contains(Column("id")))
                .order(Column("creationDate").desc)
                .fetchOne(db)
                .map { $0.localIdentifier }

            guard let coverPhotoId else {
                throw MergeVisitLayersError.coverPhotoNotFound
            }

            let story = StoryNode(
                placeClusterId: primaryClusterId,
                mainTitle: title,
                mainSummary: trimmed,
                coverPhotoId: coverPhotoId,
                subVisitLayerIds: orderedLayerIds,
                createdAt: now,
                updatedAt: now
            )

            try story.insert(db)

            // Mark all layers as settled story chapters
            for var layer in layers {
                layer.isStoryNode = true
                layer.settledAt = now
                try layer.update(db)
            }

            // 更新所有涉及到的集群状态
            let allInvolvedClusterIds = Set(layers.map { $0.placeClusterId })
            for cid in allInvolvedClusterIds {
                if var cluster = try PlaceCluster.fetchOne(db, key: cid) {
                    if cluster.hasStory == false {
                        cluster.hasStory = true
                        try cluster.update(db)
                    }
                }
            }

            // Keep existing event semantics: emit a visitLayerId (not storyId)
            let emittedVisitLayerId = orderedLayers.first!.id
            return (story.id, primaryClusterId, emittedVisitLayerId, allInvolvedClusterIds)
        }

        DomainEventBus.shared.emit(.storySettled(visitLayerId: emittedVisitLayerId, placeClusterIds: Array(allInvolvedClusterIds)))
        return storyId
    }
}

enum MergeVisitLayersError: Error {
    case notEnoughLayers
    case emptySummary
    case visitLayerNotFound
    case crossClusterMergeNotSupported
    case coverPhotoNotFound
}
