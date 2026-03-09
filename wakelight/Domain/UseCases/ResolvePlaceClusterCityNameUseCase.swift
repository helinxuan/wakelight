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
            if !looksLikeRoadName(cityName), containsCJKCharacters(cityName) {
                return cityName
            }
            print("[Geo][CityResolve][Bypass] reason=existing-road-or-nonCJK value=\(cityName)")
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        if let cityName = try await reverseGeocodeCityName(location: location), !looksLikeRoadName(cityName) {
            try await updateCluster(cluster.id, cityName: cityName)
            return cityName
        }

        print("[Geo][CityResolve][Miss] cluster=\(cluster.id) lat=\(cluster.centerLatitude) lng=\(cluster.centerLongitude)")
        return cluster.cityName
    }

    /// 获取详细地址（道路/行政区语义，不含 POI）
    func resolveDetailedAddress(for cluster: PlaceCluster) async throws -> String? {
        print("[Geo][DetailedResolve][Start] cluster=\(cluster.id) lat=\(cluster.centerLatitude) lng=\(cluster.centerLongitude) existing=\(cluster.detailedAddress ?? "nil")")

        if let detailed = cluster.detailedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !detailed.isEmpty {
            print("[Geo][DetailedResolve][Skip] reason=cluster-has-value value=\(detailed)")
            return detailed
        }

        let cacheKey = "\(cluster.centerLatitude.rounded(toPlaces: 3))_\(cluster.centerLongitude.rounded(toPlaces: 3))_detailed" as NSString
        if let cached = Self.memoryCache.object(forKey: cacheKey) {
            print("[Geo][DetailedResolve][Skip] reason=memory-cache value=\(cached)")
            return cached as String
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        let detailedName = try await reverseGeocodeDetailedAddressOnly(location: location)

        if let detailedName, !detailedName.isEmpty {
            Self.memoryCache.setObject(detailedName as NSString, forKey: cacheKey)
            try await updateCluster(cluster.id, detailedAddress: detailedName)
            return detailedName
        }

        return nil
    }

    /// 获取 POI 名称（地标/商户/景点语义）
    func resolvePOIName(for cluster: PlaceCluster) async throws -> String? {
        if let poi = cluster.poiName?.trimmingCharacters(in: .whitespacesAndNewlines), !poi.isEmpty {
            return poi
        }

        let cacheKey = "\(cluster.centerLatitude.rounded(toPlaces: 3))_\(cluster.centerLongitude.rounded(toPlaces: 3))_poi" as NSString
        if let cached = Self.memoryCache.object(forKey: cacheKey) {
            return cached as String
        }

        let location = CLLocation(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        if let resolved = try await reverseGeocodePOI(location: location), !resolved.name.isEmpty {
            Self.memoryCache.setObject(resolved.name as NSString, forKey: cacheKey)
            try await updateCluster(cluster.id, poiName: resolved.name, poiType: resolved.type)
            return resolved.name
        }

        return nil
    }

    /// 获取 UI 列表展示地点（优先 POI，其次详细地址，最后城市）
    func resolveDisplayLocation(for cluster: PlaceCluster) async throws -> String? {
        if let poi = try await resolvePOIName(for: cluster), !poi.isEmpty {
            return poi
        }

        if let detailed = try await resolveDetailedAddress(for: cluster), !detailed.isEmpty {
            return detailed
        }

        if let city = try await resolveCityName(for: cluster), !city.isEmpty {
            return city
        }

        return nil
    }

    private func updateCluster(_ id: UUID, cityName: String? = nil, detailedAddress: String? = nil, poiName: String? = nil, poiType: String? = nil) async throws {
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
                if let poiName = poiName, cluster.poiName != poiName {
                    cluster.poiName = poiName
                    changed = true
                }
                if let poiType = poiType, cluster.poiType != poiType {
                    cluster.poiType = poiType
                    changed = true
                }
                if changed {
                    try cluster.update(db)
                }
            }
        }
    }

    // MARK: - Core Logic

    private func reverseGeocodeDetailedAddressOnly(location: CLLocation) async throws -> String? {
        print("[Geo][DetailedResolve][PipelineStart] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")

        if #available(iOS 26.0, *) {
            print("[Geo][DetailedResolve][Try] provider=MapKitAddress")
            if let mapKitResult = try await reverseGeocodeDetailedAddressUsingMapKit(location: location) {
                print("[Geo][DetailedResolve][Hit] provider=MapKitAddress value=\(mapKitResult)")
                return mapKitResult
            }
            print("[Geo][DetailedResolve][Miss] provider=MapKitAddress")
        }

        if #unavailable(iOS 26.0) {
            print("[Geo][DetailedResolve][Try] provider=CoreLocationAddress")
            do {
                if let coreLocationResult = try await reverseGeocodeDetailedAddressUsingCoreLocation(location: location) {
                    print("[Geo][DetailedResolve][Hit] provider=CoreLocationAddress value=\(coreLocationResult)")
                    return coreLocationResult
                }
                print("[Geo][DetailedResolve][Miss] provider=CoreLocationAddress")
            } catch {
                print("[Geo][CoreLocation][Detailed][Error] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
            }
        }

        print("[Geo][DetailedResolve][Try] provider=MapboxAddress")
        if let mapboxDetailed = try await reverseGeocodeDetailedAddressUsingMapbox(location: location) {
            print("[Geo][DetailedResolve][Hit] provider=MapboxAddress value=\(mapboxDetailed)")
            return mapboxDetailed
        }

        print("[Geo][DetailedResolve][Miss] provider=MapboxAddress lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
        return nil
    }

    private func reverseGeocodePOI(location: CLLocation) async throws -> ResolvedPOI? {
        print("[Geo][POIResolve][PipelineStart] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")

        // 暂时禁用高德 POI：当前结果相关性不如 Mapbox，可随时恢复此分支。
        // print("[Geo][POIResolve][Try] provider=AmapPOI")
        // if let amapPOI = try await reverseGeocodePOIUsingAmap(location: location) {
        //     print("[Geo][POIResolve][Hit] provider=AmapPOI value=\(amapPOI.name) type=\(amapPOI.type ?? "nil")")
        //     return amapPOI
        // }
        // print("[Geo][POIResolve][Miss] provider=AmapPOI")

        print("[Geo][POIResolve][Try] provider=MKLocalSearch")
        do {
            if let poi = try await searchNearbyPOINameUsingLocalSearch(location: location) {
                print("[Geo][POIResolve][Hit] provider=MKLocalSearch value=\(poi.name) type=\(poi.type ?? "nil")")
                return poi
            }
            print("[Geo][POIResolve][Miss] provider=MKLocalSearch")
        } catch {
            print("[Geo][POIResolve][Error] provider=MKLocalSearch lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
        }

        print("[Geo][POIResolve][Try] provider=MapboxTilequeryPOI")
        if let mapboxPOI = try await reverseGeocodePOIUsingMapboxTilequery(location: location) {
            print("[Geo][POIResolve][Hit] provider=MapboxTilequeryPOI value=\(mapboxPOI.name) type=\(mapboxPOI.type ?? "nil")")
            return mapboxPOI
        }
        print("[Geo][POIResolve][Miss] provider=MapboxTilequeryPOI")

        return nil
    }

    @available(iOS 26.0, *)
    private func reverseGeocodeDetailedAddressUsingMapKit(location: CLLocation) async throws -> String? {
        let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

        for locale in locales {
            guard let request = MKReverseGeocodingRequest(location: location) else { continue }
            request.preferredLocale = locale
            do {
                let items = try await request.mapItems
                guard let item = items.first else { continue }

                if let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, looksLikeRoadName(name) {
                    print("[Geo][MapKit][Address][Road] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) name=\(name)")
                    return name
                }
            } catch {
                print("[Geo][MapKit][Address][Error] locale=\(locale.identifier) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
                continue
            }
        }

        return nil
    }

    @available(iOS, deprecated: 26.0)
    private func reverseGeocodeDetailedAddressUsingCoreLocation(location: CLLocation) async throws -> String? {
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
                    let address = self?.extractDetailedAddress(from: placemark)
                    continuation.resume(returning: address)
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

    private func extractDetailedAddress(from placemark: CLPlacemark) -> String? {
        if let thoroughfare = placemark.thoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines), !thoroughfare.isEmpty {
            return thoroughfare
        }

        if let subLocality = placemark.subLocality?.trimmingCharacters(in: .whitespacesAndNewlines), !subLocality.isEmpty {
            return subLocality
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

        if looksLikeRoadName(trimmed) {
            print("[Geo][MapKit][City][RoadLikeSkip] value=\(trimmed)")
            return nil
        }

        // 尝试从 "成都市武侯区"、"成都·武侯"、"成都, 四川" 等名称中提取城市部分。
        let separators = CharacterSet(charactersIn: "·,，/|-")
        let firstPart = trimmed.components(separatedBy: separators).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        let normalized = firstPart
            .replacingOccurrences(of: "省", with: "")
            .replacingOccurrences(of: "市", with: "")
            .replacingOccurrences(of: "自治区", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeRoadName(normalized) {
            return nil
        }

        return normalized.isEmpty ? nil : normalized
    }

    private func searchNearbyPOINameUsingLocalSearch(location: CLLocation) async throws -> ResolvedPOI? {
        print("[Geo][MKLocalSearch][POI][Start] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")

        let radiuses: [CLLocationDistance] = [300, 1000, 2500]

        for radius in radiuses {
            do {
                // 先走更通用的 MKLocalSearch.Request，避免部分区域/后端对 MKLocalPointsOfInterestRequest 参数校验失败。
                let request = MKLocalSearch.Request()
                request.resultTypes = [.pointOfInterest]
                request.region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: radius,
                    longitudinalMeters: radius
                )

                let response = try await MKLocalSearch(request: request).start()
                let items = response.mapItems

                let sample = items.prefix(3).compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " | ")
                print("[Geo][MKLocalSearch][POI][Candidates] radius=\(Int(radius)) count=\(items.count) sample=\(sample)")

                if let item = items.first(where: { item in
                    guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                        return false
                    }
                    return !looksLikeRoadName(name)
                }),
                   let poiName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !poiName.isEmpty {
                    let poiType = item.pointOfInterestCategory?.rawValue
                    print("[Geo][MKLocalSearch][POI][Hit] radius=\(Int(radius)) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) name=\(poiName) type=\(poiType ?? "nil")")
                    return ResolvedPOI(name: poiName, type: poiType)
                }
            } catch {
                print("[Geo][MKLocalSearch][POI][Error] radius=\(Int(radius)) lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) error=\(error)")
                continue
            }
        }

        print("[Geo][MKLocalSearch][POI][Miss] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
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

    private func reverseGeocodeDetailedAddressUsingMapbox(location: CLLocation) async throws -> String? {
        guard let result = try await mapboxReverseGeocode(location: location) else {
            return nil
        }

        if let detailed = result.detailed?.trimmingCharacters(in: .whitespacesAndNewlines), !detailed.isEmpty {
            if looksLikeRoadName(detailed) {
                print("[Geo][Mapbox][Address][Hit] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) detailed=\(detailed)")
                return detailed
            }

            print("[Geo][Mapbox][Address][Miss] non-road value lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude) detailed=\(detailed)")
        }

        print("[Geo][Mapbox][Address][Miss] lat=\(location.coordinate.latitude) lng=\(location.coordinate.longitude)")
        return nil
    }

    private func reverseGeocodePOIUsingAmap(location: CLLocation) async throws -> ResolvedPOI? {
        guard let key = amapWebServiceKey() else {
            print("[Geo][AmapPOI][Skip] AMAP_WEB_SERVICE_KEY missing")
            return nil
        }

        let lon = location.coordinate.longitude
        let lat = location.coordinate.latitude

        struct AmapAroundResponse: Decodable {
            struct POI: Decodable {
                let name: String?
                let type: String?
            }
            let status: String?
            let info: String?
            let pois: [POI]?
        }

        guard var components = URLComponents(string: "https://restapi.amap.com/v3/place/around") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "location", value: "\(lon),\(lat)"),
            URLQueryItem(name: "radius", value: "100"),
            URLQueryItem(name: "sortrule", value: "distance"),
            URLQueryItem(name: "offset", value: "8"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "extensions", value: "base")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[Geo][AmapPOI][HTTP] status=\(http.statusCode) lat=\(lat) lng=\(lon)")
                guard (200...299).contains(http.statusCode) else {
                    let snippet = String(data: data.prefix(220), encoding: .utf8) ?? ""
                    print("[Geo][AmapPOI][HTTP][Body] \(snippet)")
                    return nil
                }
            }

            let decoded = try JSONDecoder().decode(AmapAroundResponse.self, from: data)
            guard decoded.status == "1" else {
                print("[Geo][AmapPOI][API][Fail] info=\(decoded.info ?? "unknown")")
                return nil
            }

            let names = (decoded.pois ?? [])
                .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let sample = names.prefix(3).joined(separator: " | ")
            print("[Geo][AmapPOI][Candidates] count=\(names.count) sample=\(sample)")

            let candidates: [ResolvedPOI] = (decoded.pois ?? []).compactMap { poi in
                guard let name = poi.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                guard !looksLikeRoadName(name) else { return nil }
                return ResolvedPOI(name: name, type: poi.type?.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if let best = candidates.max(by: { scoreAmapPOI($0) < scoreAmapPOI($1) }) {
                print("[Geo][AmapPOI][Hit] lat=\(lat) lng=\(lon) name=\(best.name) type=\(best.type ?? "nil") score=\(scoreAmapPOI(best))")
                return best
            }

            print("[Geo][AmapPOI][Miss] lat=\(lat) lng=\(lon)")
            return nil
        } catch {
            print("[Geo][AmapPOI][Error] lat=\(lat) lng=\(lon) error=\(error)")
            return nil
        }
    }

    private func reverseGeocodePOIUsingMapboxTilequery(location: CLLocation) async throws -> ResolvedPOI? {
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

            if let feature = decoded.features.first(where: { feature in
                guard let name = feature.properties?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
                return !looksLikeRoadName(name)
            }),
               let poi = feature.properties?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !poi.isEmpty {
                let type = feature.properties?.category?.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[Geo][MapboxTilequery][POI][Hit] lat=\(lat) lng=\(lon) name=\(poi) type=\(type ?? "nil")")
                return ResolvedPOI(name: poi, type: type)
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

    private func amapWebServiceKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["AMAP_WEB_SERVICE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }

        if let plist = Bundle.main.object(forInfoDictionaryKey: "AMAP_WEB_SERVICE_KEY") as? String {
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

    private func scoreAmapPOI(_ poi: ResolvedPOI) -> Int {
        let type = poi.type ?? ""
        let name = poi.name

        var score = 0

        // 偏好“地标/景点/文化/教育/公园/商业综合体”
        let preferredTypeKeywords = ["风景", "景点", "公园", "广场", "文物", "博物馆", "美术馆", "学校", "大学", "地铁", "商场", "购物", "体育", "文化"]
        if preferredTypeKeywords.contains(where: { type.contains($0) }) {
            score += 80
        }

        // 降权泛生活服务与维修
        let weakTypeKeywords = ["维修", "中介", "快递", "家政", "洗衣", "彩票", "便民", "五金"]
        if weakTypeKeywords.contains(where: { type.contains($0) }) {
            score -= 60
        }

        // 名称里有“学校/公园/广场/博物馆”等再加分
        let preferredNameKeywords = ["学校", "公园", "广场", "博物馆", "美术馆", "商场", "中心", "景区"]
        if preferredNameKeywords.contains(where: { name.contains($0) }) {
            score += 30
        }

        return score
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

private struct ResolvedPOI {
    let name: String
    let type: String?
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
