import Foundation
import CoreLocation
import GRDB
import MapKit

/// 反向地理编码 PlaceCluster 的城市名，并写入数据库缓存。
final class ResolvePlaceClusterCityNameUseCase: @unchecked Sendable {
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
        let cacheKey = "\(cluster.centerLatitude.rounded(toPlaces: 3))_\(cluster.centerLongitude.rounded(toPlaces: 3))_detailed" as NSString
        if let cached = Self.cityCache.object(forKey: cacheKey) {
            return cached as String
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        
        let detailedName: String?
        if #available(iOS 26.0, *) {
            detailedName = try await reverseGeocodeDetailedNameUsingMapKit(location: location)
        } else {
            detailedName = try await reverseGeocodeDetailedNameUsingCoreLocation(location: location)
        }

        guard let result = detailedName, !result.isEmpty else {
            return cluster.cityName
        }

        Self.cityCache.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    @available(iOS 26.0, *)
    private func reverseGeocodeDetailedNameUsingMapKit(location: CLLocation) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "zh_CN")
        let items = try await request.mapItems
        guard let item = items.first else { return nil }
        // MKMapItem doesn't have these properties directly, must use placemark even if it's deprecated
        let placemark = item.placemark
        return formatDetailedName(district: placemark.subLocality, street: placemark.thoroughfare, name: placemark.name, city: placemark.locality)
    }

    private func reverseGeocodeDetailedNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
        if #available(iOS 26.0, *) {
            return nil
        } else {
            let geocoder = CLGeocoder()
            return try await withCheckedThrowingContinuation { [weak self] continuation in
                geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { placemarks, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let placemark = placemarks?.first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let name = self?.formatDetailedName(district: placemark.subLocality, street: placemark.thoroughfare, name: placemark.name, city: placemark.locality)
                    continuation.resume(returning: name)
                }
            }
        }
        #else
        return nil
        #endif
    }

    private func formatDetailedName(district: String?, street: String?, name: String?, city: String?) -> String? {
        let districtName = district?.replacingOccurrences(of: "区", with: "") ?? ""
        let streetName = street ?? ""
        let poiName = name ?? ""
        
        var components: [String] = []
        if !districtName.isEmpty {
            components.append(districtName)
        }
        
        // 优先显示具体地点名，如果具体名和街道名不重复
        let detail = poiName.isEmpty ? streetName : poiName
        if !detail.isEmpty && detail != districtName && detail != (city ?? "") {
            components.append(detail)
        }
        
        if components.isEmpty {
            return city?.replacingOccurrences(of: "市", with: "")
        }
        return components.joined(separator: " · ")
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
        guard let item = items.first else { return nil }
        let placemark = item.placemark

        let candidate = placemark.locality
            ?? placemark.administrativeArea
            ?? placemark.subAdministrativeArea

        return candidate?.replacingOccurrences(of: "市", with: "")
    }

    private func reverseGeocodeCityNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
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
