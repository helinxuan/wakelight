import Foundation
import CoreLocation

enum GeoGrid {
    /// 简化版网格 key：按一定精度将经纬度量化到格子。
    /// 这里用 0.05 度（约 5-6km）作为 MVP 粗粒度聚合。
    static func key(latitude: Double, longitude: Double, precisionDegrees: Double = 0.05) -> String {
        let latBucket = Int((latitude / precisionDegrees).rounded(.down))
        let lonBucket = Int((longitude / precisionDegrees).rounded(.down))
        return "\(latBucket)_\(lonBucket)_p\(precisionDegrees)"
    }
}
