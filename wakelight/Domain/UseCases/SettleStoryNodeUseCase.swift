import Foundation
import GRDB

final class SettleStoryNodeUseCase {
    private let writer: DatabaseWriter

    init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
    }

    func run(visitLayerId: UUID, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let clusterId: UUID = try await writer.write { db in
            guard var layer = try VisitLayer.fetchOne(db, key: visitLayerId) else {
                throw SettleStoryNodeError.visitLayerNotFound
            }

            layer.userText = trimmed
            layer.isStoryNode = true
            layer.settledAt = Date()
            try layer.update(db)

            guard var cluster = try PlaceCluster.fetchOne(db, key: layer.placeClusterId) else {
                throw SettleStoryNodeError.placeClusterNotFound
            }

            if cluster.hasStory == false {
                cluster.hasStory = true
                try cluster.update(db)
            }
            
            return layer.placeClusterId
        }

        // 事件发出放在事务之后，避免订阅方读到未提交状态
        DomainEventBus.shared.emit(.storySettled(visitLayerId: visitLayerId, placeClusterId: clusterId))
    }
}

enum SettleStoryNodeError: Error {
    case visitLayerNotFound
    case placeClusterNotFound
}
