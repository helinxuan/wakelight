import Foundation
import CoreLocation

enum GeoGrid {
    /// 简化版网格 key：按一定精度将经纬度量化到格子。
    /// 这里用 0.05 度（约 5-6km）作为 MVP 粗粒度聚合。
    static func key(latitude: Double, longitude: Double, precisionDegrees: Double = 0.05) -> String {
        let (latBucket, lonBucket) = bucketIndices(latitude: latitude, longitude: longitude, precisionDegrees: precisionDegrees)
        return key(latBucket: latBucket, lonBucket: lonBucket, precisionDegrees: precisionDegrees)
    }

    static func bucketIndices(latitude: Double, longitude: Double, precisionDegrees: Double) -> (Int, Int) {
        let latBucket = Int((latitude / precisionDegrees).rounded(.down))
        let lonBucket = Int((longitude / precisionDegrees).rounded(.down))
        return (latBucket, lonBucket)
    }

    static func key(latBucket: Int, lonBucket: Int, precisionDegrees: Double) -> String {
        return "\(latBucket)_\(lonBucket)_p\(precisionDegrees)"
    }
}
