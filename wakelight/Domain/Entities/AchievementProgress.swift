import Foundation
import GRDB

struct AchievementProgress: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "achievementProgress"
    
    var id: UUID
    var achievementId: String
    var progressValue: Int
    var isUnlocked: Bool
    var unlockedAt: Date?
    var updatedAt: Date
}
