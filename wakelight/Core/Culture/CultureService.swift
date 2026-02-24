import Foundation

/// Extremely lightweight, offline-first culture copy generator.
///
/// MVP scope:
/// - Provide <= 15 Chinese characters short lines
/// - No network / no LLM dependency
/// - Safe to call on the hot path (string picking only)
final class CultureService {
    static let shared = CultureService()

    private init() {}

    enum Category: CaseIterable {
        case poi
        case geo
        case poem
        case city
    }

    struct Context {
        var cityName: String?
        var isStoryPoint: Bool
    }

    /// Return a short line (<= 15 chars preferred). Caller should still rate-limit UI display.
    func shortLine(for context: Context) -> String {
        // Prefer more "special" copy if it's already a story point.
        if context.isStoryPoint {
            return pick(from: storyLines, fallback: "已显影的回忆")
        }

        if let city = context.cityName, !city.isEmpty {
            // Keep within ~15 chars; we avoid longer templates.
            let options = [
                "\(city)：一瞬成诗",
                "\(city)：光落成章",
                "\(city)：此刻在此"
            ]
            return pick(from: options, fallback: "此刻在此")
        }

        // Generic pool
        let roll = Int.random(in: 0..<100)
        if roll < 25 { return pick(from: poiLines, fallback: "不经意的名胜") }
        if roll < 55 { return pick(from: geoLines, fallback: "脚下是地理") }
        if roll < 80 { return pick(from: poemLines, fallback: "一行旧诗") }
        return pick(from: cityLines, fallback: "路过人间")
    }

    // MARK: - Pools (MVP)

    private let storyLines: [String] = [
        "已显影：光有回声",
        "回忆在此发亮",
        "故事已落成"
    ]

    private let poiLines: [String] = [
        "此处自有来历",
        "一处旧景",
        "名胜不语"
    ]

    private let geoLines: [String] = [
        "脚下是地理",
        "山河有纹理",
        "风化了时间"
    ]

    private let poemLines: [String] = [
        "一行旧诗",
        "此地可入诗",
        "把远方写短"
    ]

    private let cityLines: [String] = [
        "路过人间",
        "城市在呼吸",
        "灯火有温度"
    ]

    private func pick(from options: [String], fallback: String) -> String {
        options.randomElement() ?? fallback
    }
}
