import Foundation

struct AppConfig {
    /// 同一地点内，相邻照片时间差超过该阈值则切分为新一次到访。
    /// 默认 12 小时。
    var visitSplitThreshold: TimeInterval = 12 * 60 * 60

    static let `default` = AppConfig()
}
