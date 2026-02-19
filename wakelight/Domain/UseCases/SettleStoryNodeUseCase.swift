import Foundation
import GRDB

final class SettleStoryNodeUseCase {
    private let writer: DatabaseWriter

    init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
    }

    func run(visitLayerId: UUID, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        let clusterId: UUID = try await writer.write { db in
            guard var layer = try VisitLayer.fetchOne(db, key: visitLayerId) else {
                throw SettleStoryNodeError.visitLayerNotFound
            }

            // 1. 寻找封面图 (取该 Layer 关联的最新的照片)
            let photoAssetIds = try VisitLayerPhotoAsset
                .filter(Column("visitLayerId") == visitLayerId)
                .fetchAll(db)
                .map { $0.photoAssetId }

            guard let coverPhotoId = try PhotoAsset
                .filter(photoAssetIds.contains(Column("id")))
                .order(Column("creationDate").desc)
                .fetchOne(db)?
                .localIdentifier else {
                throw SettleStoryNodeError.coverPhotoNotFound
            }

            // 2. 更新 VisitLayer 状态
            layer.userText = trimmed
            layer.isStoryNode = true
            layer.settledAt = now
            try layer.update(db)

            // 3. 创建对应的 StoryNode，确保它出现在“已成故事”列表中
            let story = StoryNode(
                placeClusterId: layer.placeClusterId,
                mainSummary: trimmed,
                coverPhotoId: coverPhotoId,
                subVisitLayerIds: [layer.id],
                createdAt: now,
                updatedAt: now
            )
            try story.insert(db)

            // 4. 更新集群状态
            guard var cluster = try PlaceCluster.fetchOne(db, key: layer.placeClusterId) else {
                throw SettleStoryNodeError.placeClusterNotFound
            }

            if cluster.hasStory == false {
                cluster.hasStory = true
                try cluster.update(db)
            }
            
            return layer.placeClusterId
        }

        DomainEventBus.shared.emit(.storySettled(visitLayerId: visitLayerId, placeClusterIds: [clusterId]))
    }
}

enum SettleStoryNodeError: Error {
    case visitLayerNotFound
    case placeClusterNotFound
    case coverPhotoNotFound
}
