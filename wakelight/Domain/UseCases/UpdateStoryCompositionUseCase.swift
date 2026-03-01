import Foundation
import GRDB

final class UpdateStoryCompositionUseCase {
    private let writer: DatabaseWriter

    init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
    }

    func run(storyNodeId: UUID, orderedVisitLayerIds: [UUID], summaryText: String) async throws {
        let uniqueOrderedIds = orderedVisitLayerIds.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !uniqueOrderedIds.isEmpty else { throw UpdateStoryCompositionError.emptyStory }

        let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        try await writer.write { db in
            guard var story = try StoryNode.fetchOne(db, key: storyNodeId) else {
                throw UpdateStoryCompositionError.storyNotFound
            }

            let oldIds = Set(story.subVisitLayerIds)
            let newIds = Set(uniqueOrderedIds)
            let addedIds = newIds.subtracting(oldIds)
            let removedIds = oldIds.subtracting(newIds)

            let allLayers = try VisitLayer
                .filter(newIds.contains(Column("id")) || oldIds.contains(Column("id")))
                .fetchAll(db)
            let layerById = Dictionary(uniqueKeysWithValues: allLayers.map { ($0.id, $0) })

            guard uniqueOrderedIds.allSatisfy({ layerById[$0] != nil }) else {
                throw UpdateStoryCompositionError.visitLayerNotFound
            }

            for id in addedIds {
                if var layer = layerById[id] {
                    layer.isStoryNode = true
                    layer.settledAt = now
                    try layer.update(db)
                }
            }

            for id in removedIds {
                if var layer = layerById[id] {
                    layer.isStoryNode = false
                    layer.settledAt = nil
                    try layer.update(db)
                }
            }

            let coverPhotoId = try Self.resolveCoverPhotoLocator(db: db, visitLayerIds: uniqueOrderedIds)

            story.mainSummary = trimmed.isEmpty ? nil : trimmed
            story.subVisitLayerIds = uniqueOrderedIds
            story.coverPhotoId = coverPhotoId
            story.updatedAt = now
            try story.update(db)

            let affectedClusterIds = Set(allLayers.map(\.placeClusterId))
            for clusterId in affectedClusterIds {
                let hasAnyStoryLayer = try VisitLayer
                    .filter(Column("placeClusterId") == clusterId && Column("isStoryNode") == true)
                    .fetchCount(db) > 0
                _ = try PlaceCluster
                    .filter(Column("id") == clusterId)
                    .updateAll(db, Column("hasStory").set(to: hasAnyStoryLayer))
            }
        }
    }

    private static func resolveCoverPhotoLocator(db: Database, visitLayerIds: [UUID]) throws -> String {
        let links = try VisitLayerPhotoAsset
            .filter(visitLayerIds.contains(Column("visitLayerId")))
            .fetchAll(db)

        let photoAssetIds = Array(Set(links.map(\.photoAssetId)))
        guard !photoAssetIds.isEmpty else {
            throw UpdateStoryCompositionError.coverPhotoNotFound
        }

        guard let coverPhotoAssetId = try PhotoAsset
            .filter(photoAssetIds.contains(Column("id")))
            .order(Column("creationDate").desc)
            .fetchOne(db)?
            .id else {
            throw UpdateStoryCompositionError.coverPhotoNotFound
        }

        let locators = try PhotoAsset.fetchLocators(db: db, ids: [coverPhotoAssetId])
        guard let coverPhotoId = locators.first?.locatorKey else {
            throw UpdateStoryCompositionError.coverPhotoNotFound
        }
        return coverPhotoId
    }
}

enum UpdateStoryCompositionError: Error {
    case storyNotFound
    case visitLayerNotFound
    case emptyStory
    case coverPhotoNotFound
}
