import Foundation
import GRDB

struct VisitLayer: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "visitLayer"

    var id: UUID
    var placeClusterId: UUID
    var startAt: Date
    var endAt: Date
    var userText: String?
    var isStoryNode: Bool
    var tagsJson: String?
    var voiceNotePath: String?
    var settledAt: Date?
}
