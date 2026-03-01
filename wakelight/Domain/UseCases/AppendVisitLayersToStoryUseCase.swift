import Foundation
import GRDB

final class AppendVisitLayersToStoryUseCase {
    private let writer: DatabaseWriter

    init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
    }

    func run(storyNodeId: UUID, visitLayerIds: [UUID]) async throws {
        let ids = Array(Set(visitLayerIds))
        guard !ids.isEmpty else { return }
        let now = Date()

        try await writer.write { db in
            guard var story = try StoryNode.fetchOne(db, key: storyNodeId) else {
                throw AppendVisitLayersToStoryError.storyNotFound
            }

            let layers = try VisitLayer.filter(ids.contains(Column("id"))).fetchAll(db)
            guard layers.count == ids.count else {
                throw AppendVisitLayersToStoryError.visitLayerNotFound
            }

            for var layer in layers {
                layer.isStoryNode = true
                layer.settledAt = now
                try layer.update(db)
            }

            var merged = story.subVisitLayerIds
            for id in ids where !merged.contains(id) {
                merged.append(id)
            }

            story.subVisitLayerIds = merged
            story.coverPhotoId = try Self.resolveCoverPhotoLocator(db: db, visitLayerIds: merged)
            story.updatedAt = now
            try story.update(db)

            let clusterIds = Set(layers.map(\.placeClusterId)).union([story.placeClusterId])
            for clusterId in clusterIds {
                _ = try PlaceCluster
                    .filter(Column("id") == clusterId)
                    .updateAll(db, Column("hasStory").set(to: true))
            }
        }
    }

    private static func resolveCoverPhotoLocator(db: Database, visitLayerIds: [UUID]) throws -> String {
        let links = try VisitLayerPhotoAsset
            .filter(visitLayerIds.contains(Column("visitLayerId")))
            .fetchAll(db)

        let photoAssetIds = Array(Set(links.map(\.photoAssetId)))
        guard !photoAssetIds.isEmpty else {
            throw AppendVisitLayersToStoryError.coverPhotoNotFound
        }

        guard let coverPhotoAssetId = try PhotoAsset
            .filter(photoAssetIds.contains(Column("id")))
            .order(Column("creationDate").desc)
            .fetchOne(db)?
            .id else {
            throw AppendVisitLayersToStoryError.coverPhotoNotFound
        }

        let locators = try PhotoAsset.fetchLocators(db: db, ids: [coverPhotoAssetId])
        guard let coverPhotoId = locators.first?.locatorKey else {
            throw AppendVisitLayersToStoryError.coverPhotoNotFound
        }
        return coverPhotoId
    }
}

enum AppendVisitLayersToStoryError: Error {
    case storyNotFound
    case visitLayerNotFound
    case coverPhotoNotFound
}
