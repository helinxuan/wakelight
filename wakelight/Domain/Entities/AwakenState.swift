import Foundation
import GRDB

/// 5.2.6 AwakenState：唤醒过程持久化，用于记录半显影状态等
struct AwakenState: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "awakenState"

    var id: UUID
    var placeClusterId: UUID
    var energy: Int
    var isHalfRevealed: Bool
    var awakenedPointCount: Int
    var lastAwakenedAt: Date?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        placeClusterId: UUID,
        energy: Int = 0,
        isHalfRevealed: Bool = false,
        awakenedPointCount: Int = 0,
        lastAwakenedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.placeClusterId = placeClusterId
        self.energy = energy
        self.isHalfRevealed = isHalfRevealed
        self.awakenedPointCount = awakenedPointCount
        self.lastAwakenedAt = lastAwakenedAt
        self.updatedAt = updatedAt
    }
}
