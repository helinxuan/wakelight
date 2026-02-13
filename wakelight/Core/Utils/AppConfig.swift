import Foundation
import SwiftUI

/// 光点样式定义
struct LightPointStyle: Codable {
    var defaultColorHex: String      // 普通光点颜色 (HEX)
    var highlightedColorHex: String  // 精华/故事节点颜色 (HEX)
    var defaultSize: Double          // 普通光点基础尺寸
    var highlightedSize: Double      // 精华光点基础尺寸
    var glowIntensity: Double        // 呼吸光晕强度 (0-1)
}

struct AppConfig {
    /// 同一地点内，相邻照片时间差超过该阈值则切分为新一次到访。
    /// 默认 12 小时。
    var visitSplitThreshold: TimeInterval = 12 * 60 * 60

    /// 当前生效的光点样式
    var lightPointStyle = LightPointStyle(
        defaultColorHex: "#FFFFFF",     // 默认纯白
        highlightedColorHex: "#FFD700", // 精华用金色
        defaultSize: 8.0,
        highlightedSize: 14.0,
        glowIntensity: 0.8
    )

    static let `default` = AppConfig()
}
