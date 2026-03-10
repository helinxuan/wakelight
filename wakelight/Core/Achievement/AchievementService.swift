import Foundation
import GRDB

final class AchievementService {
    static let shared = AchievementService()

    private let writer: DatabaseWriter
    private let achievementIndex: [String: Achievement]

    let achievements: [Achievement]

    private init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
        self.achievements = AchievementCatalogLoader.load()
        self.achievementIndex = Dictionary(uniqueKeysWithValues: achievements.map { ($0.id, $0) })
        setupSubscriptions()
    }

    private func setupSubscriptions() {
        NotificationCenter.default.addObserver(
            forName: .wakelightDomainEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.object as? DomainEventBus.Event else { return }
            self?.handleEvent(event)
        }
    }

    private func handleEvent(_ event: DomainEventBus.Event) {
        switch event {
        case .storySettled:
            Task {
                try? await applyIncrementRule(achievementId: "story_nodes_1", increment: 1)
                try? await applyIncrementRule(achievementId: "story_nodes_10", increment: 1)
                try? await recalculateUniquePlaceRule(achievementId: "places_5")
            }
        case .locationUnlocked:
            break
        }
    }

    private func applyIncrementRule(achievementId: String, increment: Int) async throws {
        guard achievementIndex[achievementId] != nil else { return }

        let unlockedAchievement = try await writer.write { db -> Achievement? in
            var progress = try fetchOrCreateProgress(db: db, achievementId: achievementId)
            progress.progressValue += increment
            progress.updatedAt = Date()
            let unlocked = unlockIfNeeded(progress: &progress)
            try progress.save(db)
            return unlocked ? achievementIndex[achievementId] : nil
        }

        if let unlockedAchievement {
            postUnlockedNotification(unlockedAchievement)
        }
    }

    private func recalculateUniquePlaceRule(achievementId: String) async throws {
        guard achievementIndex[achievementId] != nil else { return }

        let unlockedAchievement = try await writer.write { db -> Achievement? in
            let placeCount = try PlaceCluster
                .filter(Column("hasStory") == true)
                .fetchCount(db)

            var progress = try fetchOrCreateProgress(db: db, achievementId: achievementId)
            progress.progressValue = placeCount
            progress.updatedAt = Date()
            let unlocked = unlockIfNeeded(progress: &progress)
            try progress.save(db)
            return unlocked ? achievementIndex[achievementId] : nil
        }

        if let unlockedAchievement {
            postUnlockedNotification(unlockedAchievement)
        }
    }

    private func fetchOrCreateProgress(db: Database, achievementId: String) throws -> AchievementProgress {
        if let existing = try AchievementProgress
            .filter(Column("achievementId") == achievementId)
            .fetchOne(db) {
            return existing
        }

        return AchievementProgress(
            id: UUID(),
            achievementId: achievementId,
            progressValue: 0,
            isUnlocked: false,
            unlockedAt: nil,
            updatedAt: Date()
        )
    }

    private func unlockIfNeeded(progress: inout AchievementProgress) -> Bool {
        guard !progress.isUnlocked,
              let target = achievementIndex[progress.achievementId]?.targetValue,
              progress.progressValue >= target else {
            return false
        }

        progress.isUnlocked = true
        progress.unlockedAt = Date()
        return true
    }

    private func postUnlockedNotification(_ achievement: Achievement) {
        NotificationCenter.default.post(
            name: .wakelightAchievementUnlocked,
            object: achievement
        )
    }
}

extension Notification.Name {
    static let wakelightAchievementUnlocked = Notification.Name("wakelightAchievementUnlocked")
}
