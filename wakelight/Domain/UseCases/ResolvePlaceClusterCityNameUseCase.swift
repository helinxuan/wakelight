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
        print("[Geo][DetailedResolve][Start] cluster=\(cluster.id) lat=\(cluster.centerLatitude) lng=\(cluster.centerLongitude) existing=\(cluster.detailedAddress ?? "nil")")

        if let detailed = cluster.detailedAddress, !detailed.isEmpty {
            if !looksLikeRoadName(detailed) {
                print("[Geo][DetailedResolve][Skip] reason=cluster-has-value value=\(detailed)")
                return detailed
            }
            print("[Geo][DetailedResolve][Bypass] reason=cluster-value-road-like value=\(detailed)")
        }

        let cacheKey = "\(cluster.centerLatitude.rounded(toPlaces: 3))_\(cluster.centerLongitude.rounded(toPlaces: 3))_detailed" as NSString
        if let cached = Self.memoryCache.object(forKey: cacheKey) {
            print("[Geo][DetailedResolve][Skip] reason=memory-cache value=\(cached)")
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
        print("[Geo][DetailedResolve][PipelineStart] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")

        if #available(iOS 26.0, *) {
            print("[Geo][DetailedResolve][Try] provider=MapKit")
            if let mapKitResult = try await reverseGeocodeDetailedNameUsingMapKit(location: location) {
                print("[Geo][DetailedResolve][Hit] provider=MapKit value=\(mapKitResult)")
                return mapKitResult
            }
            print("[Geo][DetailedResolve][Miss] provider=MapKit")

            print("[Geo][DetailedResolve][Try] provider=MKLocalSearch")
            do {
                if let poiResult = try await searchNearbyPOINameUsingLocalSearch(location: location) {
                    print("[Geo][DetailedResolve][Hit] provider=MKLocalSearch value=\(poiResult)")
                    return poiResult
                }
                print("[Geo][DetailedResolve][Miss] provider=MKLocalSearch")
            } catch {
                print("[Geo][DetailedResolve][Error] provider=MKLocalSearch lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
            }
        }

        if #unavailable(iOS 26.0) {
            print("[Geo][DetailedResolve][Try] provider=CoreLocation")
            do {
                if let coreLocationResult = try await reverseGeocodeDetailedNameUsingCoreLocation(location: location) {
                    print("[Geo][DetailedResolve][Hit] provider=CoreLocation value=\(coreLocationResult)")
                    return coreLocationResult
                }
                print("[Geo][DetailedResolve][Miss] provider=CoreLocation")
            } catch {
                print("[Geo][CoreLocation][Detailed][Error] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
            }

            print("[Geo][DetailedResolve][Try] provider=MKLocalSearch")
            do {
                if let poiResult = try await searchNearbyPOINameUsingLocalSearch(location: location) {
                    print("[Geo][DetailedResolve][Hit] provider=MKLocalSearch value=\(poiResult)")
                    return poiResult
                }
                print("[Geo][DetailedResolve][Miss] provider=MKLocalSearch")
            } catch {
                print("[Geo][DetailedResolve][Error] provider=MKLocalSearch lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
            }
        }

        print("[Geo][DetailedResolve][Try] provider=MapboxTilequeryPOI")
        if let mapboxPOI = try await reverseGeocodePOIUsingMapboxTilequery(location: location) {
            print("[Geo][DetailedResolve][Hit] provider=MapboxTilequeryPOI value=\(mapboxPOI)")
            return mapboxPOI
        }
        print("[Geo][DetailedResolve][Miss] provider=MapboxTilequeryPOI")

        print("[Geo][DetailedResolve][Try] provider=Mapbox")
        if let mapboxDetailed = try await reverseGeocodeDetailedNameUsingMapbox(location: location) {
            print("[Geo][DetailedResolve][Hit] provider=Mapbox value=\(mapboxDetailed)")
            return mapboxDetailed
        }

        print("[Geo][DetailedResolve][Miss] provider=Mapbox lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
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

                if let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    if looksLikeRoadName(name) {
                        print("[Geo][MapKit][Detailed][RoadLike] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) name=\(name)")
                    } else {
                        print("[Geo][MapKit][Detailed][Landmark] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) name=\(name)")
                        return name
                    }
                }

                // iOS 26 起 MKMapItem.placemark 废弃，这里仅使用 map item 自身可用字段。
                let landmarkCandidates = [item.name]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if let landmark = landmarkCandidates.first(where: { !looksLikeRoadName($0) }) {
                    print("[Geo][MapKit][Detailed][LandmarkFallback] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) landmark=\(landmark)")
                    return landmark
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
                    self?.logCoreLocationPlacemark(placemark, location: location, locale: locale)
                    let name = self?.formatDetailedName(from: placemark)
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

    private func formatDetailedName(from placemark: CLPlacemark) -> String? {
        let districtName = placemark.subLocality?.replacingOccurrences(of: "区", with: "") ?? ""
        let cityName = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let landmarkCandidates = [
            placemark.name,
            placemark.areasOfInterest?.first,
            placemark.inlandWater,
            placemark.ocean
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 详细地址优先使用地标/POI名称，不使用街道门牌。
        if let landmark = landmarkCandidates.first(where: { candidate in
            candidate != districtName
                && candidate != cityName
                && !looksLikeRoadName(candidate)
        }) {
            return landmark
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

        if #unavailable(iOS 26.0) {
            if let city = try await reverseGeocodeCityNameUsingCoreLocation(location: location) {
                return city
            }
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

                // iOS 26 起 MKMapItem.placemark 废弃，这里从 name 推断城市名。
                if let candidate = cityNameFromMapItemName(item.name) {
                    return candidate
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

    private func cityNameFromMapItemName(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 尝试从 "成都市武侯区"、"成都·武侯"、"成都, 四川" 等名称中提取城市部分。
        let separators = CharacterSet(charactersIn: "·,，/|-")
        let firstPart = trimmed.components(separatedBy: separators).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let normalized = firstPart
            .replacingOccurrences(of: "省", with: "")
            .replacingOccurrences(of: "市", with: "")
            .replacingOccurrences(of: "自治区", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.isEmpty ? nil : normalized
    }

    private func searchNearbyPOINameUsingLocalSearch(location: CLLocation) async throws -> String? {
        let request = MKLocalSearch.Request()
        request.resultTypes = [.pointOfInterest]
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 200,
            longitudinalMeters: 200
        )

        print("[Geo][MKLocalSearch][POI][Start] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
        let response = try await MKLocalSearch(request: request).start()
        let items = response.mapItems

        let sample = items.prefix(3).compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " | ")
        print("[Geo][MKLocalSearch][POI][Candidates] count=\(items.count) sample=\(sample)")

        if let poi = items.first(where: { item in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return false
            }
            return !looksLikeRoadName(name)
        })?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !poi.isEmpty {
            print("[Geo][MKLocalSearch][POI][Hit] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) name=\(poi)")
            return poi
        }

        print("[Geo][MKLocalSearch][POI][Miss] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) count=\(items.count)")
        return nil
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

    private func reverseGeocodePOIUsingMapboxTilequery(location: CLLocation) async throws -> String? {
        guard let token = mapboxAccessToken() else {
            print("[Geo][MapboxTilequery][Skip] MAPBOX_ACCESS_TOKEN missing")
            return nil
        }

        let lon = location.coordinate.longitude
        let lat = location.coordinate.latitude

        struct TilequeryResponse: Decodable {
            struct Feature: Decodable {
                struct Properties: Decodable {
                    let name: String?
                    let category: String?
                    let maki: String?
                }
                let properties: Properties?
            }
            let features: [Feature]
        }

        guard var components = URLComponents(string: "https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/tilequery/\(lon),\(lat).json") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "radius", value: "180"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "layers", value: "poi_label"),
            URLQueryItem(name: "dedupe", value: "true"),
            URLQueryItem(name: "access_token", value: token)
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if let http {
                print("[Geo][MapboxTilequery][HTTP] status=\(http.statusCode) lat=\(lat) lng=\(lon)")
                guard (200...299).contains(http.statusCode) else {
                    let snippet = String(data: data.prefix(220), encoding: .utf8) ?? ""
                    print("[Geo][MapboxTilequery][HTTP][Body] \(snippet)")
                    return nil
                }
            }

            let decoded = try JSONDecoder().decode(TilequeryResponse.self, from: data)
            let names = decoded.features
                .compactMap { $0.properties?.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let sample = names.prefix(3).joined(separator: " | ")
            print("[Geo][MapboxTilequery][POI][Candidates] count=\(names.count) sample=\(sample)")

            if let poi = names.first(where: { !looksLikeRoadName($0) }) {
                print("[Geo][MapboxTilequery][POI][Hit] lat=\(lat) lng=\(lon) name=\(poi)")
                return poi
            }

            print("[Geo][MapboxTilequery][POI][Miss] lat=\(lat) lng=\(lon)")
            return nil
        } catch {
            print("[Geo][MapboxTilequery][Error] lat=\(lat) lng=\(lon) error=\(error)")
            return nil
        }
    }

    private func mapboxReverseGeocode(location: CLLocation) async throws -> MapboxResolvedResult? {
        guard let token = mapboxAccessToken() else {
            print("[Geo][Mapbox][Skip] MAPBOX_ACCESS_TOKEN missing")
            return nil
        }

        // 统一走 v5，避免 v6 在 reverse geocoding 参数校验上的 422 兼容问题。
        return try await mapboxReverseGeocodeV5(location: location, token: token)
    }

    private func mapboxReverseGeocodeV5(location: CLLocation, token: String) async throws -> MapboxResolvedResult? {
        let lon = location.coordinate.longitude
        let lat = location.coordinate.latitude

        struct V5Response: Decodable {
            struct Feature: Decodable {
                let place_name: String?
                let text: String?
                let place_type: [String]?
            }
            let features: [Feature]
        }

        // Mapbox reverse 在 limit 存在时，要求 types 只能是“单个 type”。
        // 这里按粒度从细到粗依次尝试，拿到第一个可用结果就返回。
        let typeCandidates = ["place", "locality", "region", "country"]

        for type in typeCandidates {
            guard var components = URLComponents(string: "https://api.mapbox.com/geocoding/v5/mapbox.places/\(lon),\(lat).json") else {
                continue
            }

            components.queryItems = [
                URLQueryItem(name: "language", value: "zh,en"),
                URLQueryItem(name: "types", value: type),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "access_token", value: token)
            ]

            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                if let http {
                    print("[Geo][MapboxV5][HTTP] status=\(http.statusCode) lat=\(lat) lng=\(lon) type=\(type)")
                    guard (200...299).contains(http.statusCode) else {
                        let snippet = String(data: data.prefix(220), encoding: .utf8) ?? ""
                        print("[Geo][MapboxV5][HTTP][Body] type=\(type) \(snippet)")
                        continue
                    }
                }

                let decoded = try JSONDecoder().decode(V5Response.self, from: data)
                guard let feature = decoded.features.first else { continue }

                let city = feature.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detailed = feature.place_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? feature.text?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let city, !city.isEmpty {
                    return MapboxResolvedResult(city: city, detailed: detailed)
                }
            } catch {
                print("[Geo][MapboxV5][Error] lat=\(lat) lng=\(lon) type=\(type) error=\(error)")
                continue
            }
        }

        return nil
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

    private func logCoreLocationPlacemark(_ placemark: CLPlacemark, location: CLLocation, locale: Locale) {
        let summary = [
            "name=\(placemark.name ?? "nil")",
            "aoi=\(placemark.areasOfInterest?.joined(separator: "|") ?? "nil")",
            "inlandWater=\(placemark.inlandWater ?? "nil")",
            "ocean=\(placemark.ocean ?? "nil")",
            "thoroughfare=\(placemark.thoroughfare ?? "nil")",
            "subThoroughfare=\(placemark.subThoroughfare ?? "nil")",
            "subLocality=\(placemark.subLocality ?? "nil")",
            "locality=\(placemark.locality ?? "nil")",
            "subAdministrativeArea=\(placemark.subAdministrativeArea ?? "nil")",
            "administrativeArea=\(placemark.administrativeArea ?? "nil")",
            "country=\(placemark.country ?? "nil")"
        ].joined(separator: " ")

        print("[Geo][CoreLocation][Placemark][Raw] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) \(summary)")
    }

    private func looksLikeRoadName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let latinRoadMarkers = [" street", " st", " road", " rd", " avenue", " ave", " lane", " ln", " drive", " dr", " boulevard", " blvd", " strasse", " straße", "gata", "weg"]
        let hasLatinRoadMarker = latinRoadMarkers.contains { lowercased.contains($0) }

        let zhRoadMarkers = ["路", "街", "巷", "道", "大道", "胡同", "弄", "段"]
        let hasZhRoadMarker = zhRoadMarkers.contains { trimmed.contains($0) }

        return hasZhRoadMarker || hasLatinRoadMarker
    }

    private func looksLikeStreetAddress(_ value: String) -> Bool {
        looksLikeRoadName(value)
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
