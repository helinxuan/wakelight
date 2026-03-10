import Foundation

struct AchievementCatalogLoader {
    static func load() -> [Achievement] {
        if let bundled = loadFromBundle(), !bundled.isEmpty {
            return bundled
        }

        // Fallback for development / bundle misconfiguration.
        return [
            Achievement(id: "story_nodes_1", title: "初行者", description: "完成第 1 次故事沉淀", iconName: "sparkles", targetValue: 1),
            Achievement(id: "story_nodes_10", title: "故事家", description: "完成 10 次故事沉淀", iconName: "book.fill", targetValue: 10),
            Achievement(id: "places_5", title: "足迹广布", description: "在 5 个不同的地点留下故事", iconName: "map.fill", targetValue: 5)
        ]
    }

    private static func loadFromBundle() -> [Achievement]? {
        guard let url = Bundle.main.url(forResource: "achievement_rules", withExtension: "json") else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Achievement].self, from: data)
        } catch {
            print("AchievementCatalogLoader decode failed: \(error)")
            return nil
        }
    }
}
