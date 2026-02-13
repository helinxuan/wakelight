import Foundation
import Combine
import GRDB

@MainActor
final class BadgeWallViewModel: ObservableObject {
    struct Item: Identifiable {
        var id: String { achievement.id }
        let achievement: Achievement
        let progress: AchievementProgress?

        var progressValue: Int { progress?.progressValue ?? 0 }
        var isUnlocked: Bool { progress?.isUnlocked ?? false }
        var unlockedAt: Date? { progress?.unlockedAt }
    }

    @Published var items: [Item] = []

    private var cancellables = Set<AnyCancellable>()
    private let reader: DatabaseReader
    private let achievements: [Achievement]

    init(
        reader: DatabaseReader = DatabaseContainer.shared.db.reader,
        achievements: [Achievement] = AchievementService.shared.achievements
    ) {
        self.reader = reader
        self.achievements = achievements
        observe()
    }

    private func observe() {
        ValueObservation
            .tracking { db in
                try AchievementProgress.fetchAll(db)
            }
            .publisher(in: reader)
            .sink { completion in
                if case .failure(let error) = completion {
                    print("BadgeWall observe error: \(error)")
                }
            } receiveValue: { [weak self] progressRows in
                guard let self else { return }
                let dict = Dictionary(uniqueKeysWithValues: progressRows.map { ($0.achievementId, $0) })
                self.items = self.achievements.map { ach in
                    Item(achievement: ach, progress: dict[ach.id])
                }
            }
            .store(in: &cancellables)
    }
}
