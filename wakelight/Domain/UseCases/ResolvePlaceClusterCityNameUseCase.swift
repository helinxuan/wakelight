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
        if let cityName = cluster.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !cityName.isEmpty {
            // 已有中文城市名直接复用；英文/拼音名称尝试刷新为中文，避免 UI 持续显示英文。
            if containsCJKCharacters(cityName) {
                return cityName
            }
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        if let cityName = try await reverseGeocodeCityName(location: location) {
            try await updateCluster(cluster.id, cityName: cityName)
            return cityName
        }

        print("[Geo][CityResolve][Miss] cluster=\(cluster.id) lat=\(cluster.centerLatitude) lng=\(cluster.centerLongitude)")
        return cluster.cityName
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

        let detailedName = try await reverseGeocodeDetailedName(location: location)

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

    private func reverseGeocodeDetailedName(location: CLLocation) async throws -> String? {
        if #available(iOS 26.0, *) {
            if let mapKitResult = try await reverseGeocodeDetailedNameUsingMapKit(location: location) {
                return mapKitResult
            }
        }

        do {
            if let coreLocationResult = try await reverseGeocodeDetailedNameUsingCoreLocation(location: location) {
                return coreLocationResult
            }
        } catch {
            print("[Geo][CoreLocation][Detailed][Error] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
        }

        if let mapboxDetailed = try await reverseGeocodeDetailedNameUsingMapbox(location: location) {
            return mapboxDetailed
        }

        print("[Geo][DetailedResolve][Miss] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
        return nil
    }

    @available(iOS 26.0, *)
    private func reverseGeocodeDetailedNameUsingMapKit(location: CLLocation) async throws -> String? {
        // 优先中文，避免国内地点被解析为英文名（例如 Meishan）。
        let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

        for locale in locales {
            guard let request = MKReverseGeocodingRequest(location: location) else { continue }
            request.preferredLocale = locale
            do {
                let items = try await request.mapItems
                guard let item = items.first else { continue }

                if let name = item.name, !name.isEmpty {
                    return name
                }

                let placemark = item.placemark
                let fallback = [placemark.thoroughfare, placemark.subLocality, placemark.locality, placemark.subAdministrativeArea, placemark.administrativeArea, placemark.country]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let fallback {
                    return fallback
                }
            } catch {
                print("[Geo][MapKit][Detailed][Error] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
                continue
            }
        }

        return nil
    }

    @available(iOS, deprecated: 26.0)
    private func reverseGeocodeDetailedNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
        let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

        for locale in locales {
            let geocoder = CLGeocoder()
            let result: String? = try await withCheckedThrowingContinuation { [weak self] continuation in
                geocoder.reverseGeocodeLocation(location, preferredLocale: locale) { placemarks, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let placemark = placemarks?.first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let name = self?.formatDetailedName(
                        district: placemark.subLocality,
                        name: placemark.name,
                        city: placemark.locality
                    )
                    continuation.resume(returning: name)
                }
            }
            if let result, !result.isEmpty {
                return result
            }
        }

        return nil
        #else
        return nil
        #endif
    }

    private func formatDetailedName(district: String?, name: String?, city: String?) -> String? {
        let districtName = district?.replacingOccurrences(of: "区", with: "") ?? ""
        let poiName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cityName = city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 详细地址优先使用 POI/地标名称，不使用街道门牌。
        if !poiName.isEmpty && poiName != districtName && poiName != cityName {
            return poiName
        }

        if !districtName.isEmpty {
            return districtName
        }

        if !cityName.isEmpty {
            return cityName.replacingOccurrences(of: "市", with: "")
        }

        return nil
    }

    private func reverseGeocodeCityName(location: CLLocation) async throws -> String? {
        if #available(iOS 26.0, *) {
            if let city = try await reverseGeocodeCityNameUsingMapKit(location: location) {
                return city
            }
        }

        if let city = try await reverseGeocodeCityNameUsingCoreLocation(location: location) {
            return city
        }

        if let mapboxCity = try await reverseGeocodeCityNameUsingMapbox(location: location) {
            return mapboxCity
        }

        return nil
    }

    @available(iOS 26.0, *)
    private func reverseGeocodeCityNameUsingMapKit(location: CLLocation) async throws -> String? {
        let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

        for locale in locales {
            guard let request = MKReverseGeocodingRequest(location: location) else { continue }
            request.preferredLocale = locale
            do {
                let items = try await request.mapItems
                guard let item = items.first else { continue }

                let placemark = item.placemark
                let candidate = [placemark.locality, placemark.subAdministrativeArea, placemark.administrativeArea, placemark.country]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }

                if let candidate {
                    return candidate.replacingOccurrences(of: "市", with: "")
                }
            } catch {
                print("[Geo][MapKit][City][Error] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
                continue
            }
        }

        return nil
    }

    @available(iOS, deprecated: 26.0)
    private func reverseGeocodeCityNameUsingCoreLocation(location: CLLocation) async throws -> String? {
        #if canImport(CoreLocation) && !os(watchOS)
        // 先尝试中文，避免国内地点在 CoreLocation 路径下返回英文城市名。
        let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

        for locale in locales {
            let geocoder = CLGeocoder()
            do {
                let candidate: String? = try await withCheckedThrowingContinuation { continuation in
                    geocoder.reverseGeocodeLocation(location, preferredLocale: locale) { placemarks, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        let placemark = placemarks?.first
                        let value = placemark?.locality
                            ?? placemark?.subAdministrativeArea
                            ?? placemark?.administrativeArea
                            ?? placemark?.country
                        continuation.resume(returning: value?.replacingOccurrences(of: "市", with: ""))
                    }
                }
                if let candidate, !candidate.isEmpty {
                    return candidate
                }
            } catch {
                print("[Geo][CoreLocation][City][Error] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
                continue
            }
        }

        return nil
        #else
        return nil
        #endif
    }

    private func reverseGeocodeCityNameUsingMapbox(location: CLLocation) async throws -> String? {
        guard let result = try await mapboxReverseGeocode(location: location) else {
            return nil
        }

        if let city = result.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            print("[Geo][Mapbox][City][Hit] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) city=\(city)")
            return city
        }

        print("[Geo][Mapbox][City][Miss] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
        return nil
    }

    private func reverseGeocodeDetailedNameUsingMapbox(location: CLLocation) async throws -> String? {
        guard let result = try await mapboxReverseGeocode(location: location) else {
            return nil
        }

        if let detailed = result.detailed?.trimmingCharacters(in: .whitespacesAndNewlines), !detailed.isEmpty {
            print("[Geo][Mapbox][Detailed][Hit] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) detailed=\(detailed)")
            return detailed
        }

        print("[Geo][Mapbox][Detailed][Miss] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
        return nil
    }

    private func mapboxReverseGeocode(location: CLLocation) async throws -> MapboxResolvedResult? {
        guard let token = mapboxAccessToken() else {
            print("[Geo][Mapbox][Skip] MAPBOX_ACCESS_TOKEN missing")
            return nil
        }

        let lon = location.coordinate.longitude
        let lat = location.coordinate.latitude

        var components = URLComponents(string: "https://api.mapbox.com/search/geocode/v6/reverse")
        components?.queryItems = [
            URLQueryItem(name: "longitude", value: "\(lon)"),
            URLQueryItem(name: "latitude", value: "\(lat)"),
            URLQueryItem(name: "language", value: "zh,en"),
            // Geocoding v6 的 types 仅支持地理层级类型，不包含 poi；否则会 422。
            URLQueryItem(name: "types", value: "address,street,neighborhood,locality,place,region,country"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "access_token", value: token)
        ]

        guard let url = components?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[Geo][Mapbox][HTTP] status=\(http.statusCode) lat=\(lat) lng=\(lon)")
                guard (200...299).contains(http.statusCode) else {
                    return nil
                }
            }

            let decoded = try JSONDecoder().decode(MapboxGeocodeV6ReverseResponse.self, from: data)

            let city = decoded.features
                .compactMap {
                    $0.properties.context.place?.name
                    ?? $0.properties.context.locality?.name
                    ?? $0.properties.context.region?.name
                    ?? $0.properties.context.country?.name
                }
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

            // v6 reverse 在当前参数下可能不给 POI；详细地址优先语义区域，再回退 name。
            let semanticAreaDetailed = decoded.features
                .compactMap {
                    $0.properties.context.locality?.name
                    ?? $0.properties.context.place?.name
                    ?? $0.properties.context.region?.name
                }
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

            let fallbackNameDetailed = decoded.features
                .compactMap { $0.properties.name }
                .first(where: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !trimmed.isEmpty && !looksLikeStreetAddress(trimmed)
                })

            let detailed = semanticAreaDetailed ?? fallbackNameDetailed

            return MapboxResolvedResult(city: city, detailed: detailed)
        } catch {
            print("[Geo][Mapbox][Error] lat=\(lat) lng=\(lon) error=\(error)")
            return nil
        }
    }

    private func mapboxAccessToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["MAPBOX_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }

        if let plist = Bundle.main.object(forInfoDictionaryKey: "MAPBOX_ACCESS_TOKEN") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private func looksLikeStreetAddress(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let markers = [" street", " st", " road", " rd", " avenue", " ave", " lane", " ln", " drive", " dr", " strasse", " straße", "gata", "weg"]
        let hasMarker = markers.contains { lowercased.contains($0) }
        let hasDigit = value.rangeOfCharacter(from: .decimalDigits) != nil
        return hasMarker && hasDigit
    }

    private func containsCJKCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF,     // CJK Unified Ideographs
                 0x3400...0x4DBF,     // CJK Extension A
                 0xF900...0xFAFF:     // CJK Compatibility Ideographs
                return true
            default:
                return false
            }
        }
    }
}

private struct MapboxResolvedResult {
    let city: String?
    let detailed: String?
}

private struct MapboxGeocodeV6ReverseResponse: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let properties: Properties
    }

    struct Properties: Decodable {
        let name: String?
        let fullAddress: String?
        let featureType: String?
        let context: Context

        enum CodingKeys: String, CodingKey {
            case name
            case fullAddress = "full_address"
            case featureType = "feature_type"
            case context
        }
    }

    struct Context: Decodable {
        let place: Item?
        let locality: Item?
        let region: Item?
        let country: Item?

        struct Item: Decodable {
            let name: String?
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
