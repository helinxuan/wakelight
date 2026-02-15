import Foundation
import GRDB

struct StoryNode: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "storyNode"

    var id: UUID
    var placeClusterId: UUID
    var mainTitle: String?
    var mainSummary: String?
    var coverPhotoId: String
    var subVisitLayerIdsJson: String
    var createdAt: Date
    var updatedAt: Date

    var subVisitLayerIds: [UUID] {
        get {
            guard let data = subVisitLayerIdsJson.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            subVisitLayerIdsJson = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    init(
        id: UUID = UUID(),
        placeClusterId: UUID,
        mainTitle: String? = nil,
        mainSummary: String? = nil,
        coverPhotoId: String,
        subVisitLayerIds: [UUID],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.placeClusterId = placeClusterId
        self.mainTitle = mainTitle
        self.mainSummary = mainSummary
        self.coverPhotoId = coverPhotoId
        let data = (try? JSONEncoder().encode(subVisitLayerIds)) ?? Data()
        self.subVisitLayerIdsJson = String(data: data, encoding: .utf8) ?? "[]"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
