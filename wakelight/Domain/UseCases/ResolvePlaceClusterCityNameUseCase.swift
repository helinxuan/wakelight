import Foundation
import CoreLocation
import GRDB

/// 反向地理编码 PlaceCluster 的城市名，并写入数据库缓存。
final class ResolvePlaceClusterCityNameUseCase {
    private let writer: DatabaseWriter
    private let geocoder: CLGeocoder

    private static let cityCache = NSCache<NSString, NSString>()

    init(
        writer: DatabaseWriter = DatabaseContainer.shared.writer,
        geocoder: CLGeocoder = CLGeocoder()
    ) {
        self.writer = writer
        self.geocoder = geocoder
    }

    func run(clusterId: UUID) async throws -> String? {
        let cluster = try await writer.read { db in
            try PlaceCluster.fetchOne(db, key: clusterId)
        }

        guard let cluster else { return nil }
        return try await run(cluster: cluster)
    }

    func run(cluster: PlaceCluster) async throws -> String? {
        if let existing = cluster.cityName, !existing.isEmpty {
            return existing
        }

        let cacheKey = "\(cluster.centerLatitude.rounded(toPlaces: 3))_\(cluster.centerLongitude.rounded(toPlaces: 3))" as NSString
        if let cached = Self.cityCache.object(forKey: cacheKey) {
            return cached as String
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        let cityName = try await reverseGeocodeCityName(location: location)

        guard let cityName, !cityName.isEmpty else { return nil }

        Self.cityCache.setObject(cityName as NSString, forKey: cacheKey)

        _ = try await writer.write { db in
            if var toUpdate = try PlaceCluster.fetchOne(db, key: cluster.id) {
                if toUpdate.cityName == nil {
                    toUpdate.cityName = cityName
                    try toUpdate.update(db)
                }
            }
        }

        return cityName
    }

    private func reverseGeocodeCityName(location: CLLocation) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let placemark = placemarks?.first
                let candidate = placemark?.locality
                    ?? placemark?.administrativeArea
                    ?? placemark?.subAdministrativeArea

                let name = candidate?.replacingOccurrences(of: "市", with: "")
                continuation.resume(returning: name)
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
