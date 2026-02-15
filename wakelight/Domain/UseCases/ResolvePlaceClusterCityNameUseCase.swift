import Foundation
import CoreLocation
import GRDB
import MapKit

/// 反向地理编码 PlaceCluster 的城市名，并写入数据库缓存。
final class ResolvePlaceClusterCityNameUseCase {
    private let writer: DatabaseWriter

    private static let cityCache = NSCache<NSString, NSString>()

    init(
        writer: DatabaseWriter = DatabaseContainer.shared.writer
    ) {
        self.writer = writer
    }

    func run(clusterId: UUID) async throws -> String? {
        let cluster = try await writer.read { db in
            try PlaceCluster.fetchOne(db, key: clusterId)
        }

        guard let cluster else { return nil }
        return try await run(cluster: cluster)
    }

    func run(clusters: [PlaceCluster]) async -> String? {
        for cluster in clusters {
            if let name = try? await run(cluster: cluster) {
                return name
            }
        }
        return nil
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
        if #available(iOS 26.0, *) {
            return try await reverseGeocodeCityNameUsingMapKit(location: location)
        } else {
            return try await reverseGeocodeCityNameUsingCoreLocation(location: location)
        }
    }

    @available(iOS 26.0, *)
    private func reverseGeocodeCityNameUsingMapKit(location: CLLocation) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return nil
        }
        request.preferredLocale = Locale(identifier: "zh_CN")

        let items = try await request.mapItems
        let placemark = items.first?.placemark

        let candidate = placemark?.locality
            ?? placemark?.administrativeArea
            ?? placemark?.subAdministrativeArea

        return candidate?.replacingOccurrences(of: "市", with: "")
    }

    private func reverseGeocodeCityNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
        // 只有在 iOS 26 以下才使用这个逻辑，避免编译器在 iOS 26 target 下产生 deprecation 警告
        if #available(iOS 26.0, *) {
            return nil 
        } else {
            let geocoder = CLGeocoder()
            return try await withCheckedThrowingContinuation { continuation in
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
        #else
        return nil
        #endif
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
