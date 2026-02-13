import Foundation
import GRDB

final class AchievementService {
    static let shared = AchievementService()
    
    private let writer: DatabaseWriter
    
    let achievements: [Achievement] = [
        Achievement(id: "story_nodes_1", title: "初行者", description: "完成第 1 次故事沉淀", iconName: "sparkles", targetValue: 1),
        Achievement(id: "story_nodes_10", title: "故事家", description: "完成 10 次故事沉淀", iconName: "book.fill", targetValue: 10),
        Achievement(id: "places_5", title: "足迹广布", description: "在 5 个不同的地点留下故事", iconName: "map.fill", targetValue: 5)
    ]
    
    private init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
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
                try? await updateProgress(for: "story_nodes_1", increment: 1)
                try? await updateProgress(for: "story_nodes_10", increment: 1)
                await updateUniquePlacesAchievement()
            }
        case .locationUnlocked:
            break
        }
    }
    
    private func updateProgress(for achievementId: String, increment: Int) async throws {
        try await writer.write { db in
            var progress = try AchievementProgress
                .filter(Column("achievementId") == achievementId)
                .fetchOne(db) ?? AchievementProgress(
                    id: UUID(),
                    achievementId: achievementId,
                    progressValue: 0,
                    isUnlocked: false,
                    unlockedAt: nil,
                    updatedAt: Date()
                )
            
            progress.progressValue += increment
            progress.updatedAt = Date()
            
            if !progress.isUnlocked, let target = achievements.first(where: { $0.id == achievementId })?.targetValue, progress.progressValue >= target {
                progress.isUnlocked = true
                progress.unlockedAt = Date()
            }
            
            try progress.save(db)
        }
    }
    
    private func updateUniquePlacesAchievement() async {
        let achievementId = "places_5"
        try? await writer.write { db in
            let count = try PlaceCluster
                .filter(Column("hasStory") == true)
                .fetchCount(db)
            
            var progress = try AchievementProgress
                .filter(Column("achievementId") == achievementId)
                .fetchOne(db) ?? AchievementProgress(
                    id: UUID(),
                    achievementId: achievementId,
                    progressValue: 0,
                    isUnlocked: false,
                    unlockedAt: nil,
                    updatedAt: Date()
                )
            
            progress.progressValue = count
            progress.updatedAt = Date()
            
            if !progress.isUnlocked, let target = achievements.first(where: { $0.id == achievementId })?.targetValue, progress.progressValue >= target {
                progress.isUnlocked = true
                progress.unlockedAt = Date()
            }
            
            try progress.save(db)
        }
    }
}
