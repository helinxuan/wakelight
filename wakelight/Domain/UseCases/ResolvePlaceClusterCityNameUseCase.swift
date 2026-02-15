import Foundation
import CoreLocation
import GRDB
import MapKit

/// 反向地理编码 PlaceCluster 的城市名/详细地址，并写入数据库缓存。
final class ResolvePlaceClusterCityNameUseCase: @unchecked Sendable {
    private let writer: DatabaseWriter

    private static let memoryCache = NSCache<NSString, NSString>()

    init(
        writer: DatabaseWriter = DatabaseContainer.shared.writer
    ) {
        self.writer = writer
    }

    /// 获取仅城市名（如“成都”），用于顶部标题
    func resolveCityName(for cluster: PlaceCluster) async throws -> String? {
        if let cityName = cluster.cityName, !cityName.isEmpty {
            return cityName
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        if let cityName = try await reverseGeocodeCityName(location: location) {
            try await updateCluster(cluster.id, cityName: cityName)
            return cityName
        }
        return nil
    }

    /// 获取详细地址（如“武侯 · 瑞彩路”），用于列表内容
    func resolveDetailedAddress(for cluster: PlaceCluster) async throws -> String? {
        if let detailed = cluster.detailedAddress, !detailed.isEmpty {
            return detailed
        }

        let cacheKey = "\(cluster.centerLatitude.rounded(toPlaces: 3))_\(cluster.centerLongitude.rounded(toPlaces: 3))_detailed" as NSString
        if let cached = Self.memoryCache.object(forKey: cacheKey) {
            return cached as String
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        
        let detailedName: String?
        if #available(iOS 26.0, *) {
            detailedName = try await reverseGeocodeDetailedNameUsingMapKit(location: location)
        } else {
            detailedName = try await reverseGeocodeDetailedNameUsingCoreLocation(location: location)
        }

        let result = detailedName ?? cluster.cityName
        if let result = result, !result.isEmpty {
            Self.memoryCache.setObject(result as NSString, forKey: cacheKey)
            try await updateCluster(cluster.id, detailedAddress: result)
        }
        return result
    }

    private func updateCluster(_ id: UUID, cityName: String? = nil, detailedAddress: String? = nil) async throws {
        try await writer.write { db in
            if var cluster = try PlaceCluster.fetchOne(db, key: id) {
                var changed = false
                if let cityName = cityName, cluster.cityName != cityName {
                    cluster.cityName = cityName
                    changed = true
                }
                if let detailedAddress = detailedAddress, cluster.detailedAddress != detailedAddress {
                    cluster.detailedAddress = detailedAddress
                    changed = true
                }
                if changed {
                    try cluster.update(db)
                }
            }
        }
    }

    // MARK: - Core Logic

    @available(iOS 26.0, *)
    private func reverseGeocodeDetailedNameUsingMapKit(location: CLLocation) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "zh_CN")
        let items = try await request.mapItems
        guard let item = items.first else { return nil }
        let placemark = item.placemark
        return formatDetailedName(district: placemark.subLocality, street: placemark.thoroughfare, name: placemark.name, city: placemark.locality)
    }

    private func reverseGeocodeDetailedNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
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
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Locale(identifier: "zh_CN")
        let items = try await request.mapItems
        guard let item = items.first else { return nil }
        let candidate = item.placemark.locality ?? item.placemark.administrativeArea
        return candidate?.replacingOccurrences(of: "市", with: "")
    }

    private func reverseGeocodeCityNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
        let geocoder = CLGeocoder()
        return try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { placemarks, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let placemark = placemarks?.first
                let candidate = placemark?.locality ?? placemark?.administrativeArea
                continuation.resume(returning: candidate?.replacingOccurrences(of: "市", with: ""))
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
