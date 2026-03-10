import Foundation
import GRDB
internal import _LocationEssentials

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
        let location = GeoCoordinate(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)

        if let structured = try await reverseGeocodeStructured(location: location),
           let cityName = structured.city?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !cityName.isEmpty {
            try await updateCluster(cluster.id, cityName: cityName)
            return cityName
        }

        if let existing = cluster.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            print("[Geo][CityResolve][FallbackExisting] value=\(existing)")
            return existing
        }

        print("[Geo][CityResolve][Miss] cluster=\(cluster.id) lat=\(cluster.centerLatitude) lng=\(cluster.centerLongitude)")
        return nil
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

        let location = GeoCoordinate(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        if let structured = try await reverseGeocodeStructured(location: location),
           let detailedName = structured.detailed?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !detailedName.isEmpty {
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

        let location = GeoCoordinate(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        if let structured = try await reverseGeocodeStructured(location: location),
           let poiName = structured.poi?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !poiName.isEmpty {
            Self.memoryCache.setObject(poiName as NSString, forKey: cacheKey)
            try await updateCluster(cluster.id, poiName: poiName, poiType: structured.poiType)
            return poiName
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

    private func reverseGeocodeStructured(location: GeoCoordinate) async throws -> ResolvedLocation? {
        print("[Geo][StructuredResolve][Start] lat=\(location.latitude) lng=\(location.longitude)")

        var city: String?
        var detailed: String?

        print("[Geo][StructuredResolve][Try] provider=Amap")
        var amapResult: AmapResolvedResult?
        if let result = try await amapReverseGeocode(location: location) {
            amapResult = result
            city = city ?? result.city
            detailed = detailed ?? result.detailed
            print("[Geo][StructuredResolve][Hit] provider=Amap city=\(city ?? "nil") detailed=\(detailed ?? "nil")")
            if let poiName = result.poi, !poiName.isEmpty {
                print("[Geo][StructuredResolve][Hit] provider=AmapPOI value=\(poiName) type=\(result.poiType ?? "nil")")
            }
        } else {
            print("[Geo][StructuredResolve][Miss] provider=Amap")
        }

        if city == nil || detailed == nil {
            print("[Geo][StructuredResolve][Try] provider=Mapbox")
            if let mapboxResult = try await mapboxReverseGeocode(location: location) {
                city = city ?? mapboxResult.city
                detailed = detailed ?? mapboxResult.detailed
                print("[Geo][StructuredResolve][Hit] provider=Mapbox city=\(city ?? "nil") detailed=\(detailed ?? "nil")")
            } else {
                print("[Geo][StructuredResolve][Miss] provider=Mapbox")
            }
        }

        let poiResult = try await reverseGeocodePOI(location: location, amapResult: amapResult)

        if city == nil, detailed == nil, poiResult == nil {
            print("[Geo][StructuredResolve][Miss] lat=\(location.latitude) lng=\(location.longitude)")
            return nil
        }

        let normalizedCity = normalizeCityCandidate(
            city,
            detailed: detailed,
            subLocality: nil,
            adminArea: nil
        )

        return ResolvedLocation(
            city: normalizedCity,
            detailed: detailed,
            poi: poiResult?.name,
            poiType: poiResult?.type,
            subLocality: nil,
            adminArea: nil
        )
    }

    private func reverseGeocodePOI(location: GeoCoordinate, amapResult: AmapResolvedResult?) async throws -> ResolvedPOI? {
        print("[Geo][POIResolve][PipelineStart] lat=\(location.latitude) lng=\(location.longitude)")

        if let amap = amapResult,
           let name = amap.poi?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           !looksLikeRoadName(name) {
            print("[Geo][POIResolve][Hit] provider=AmapPOI value=\(name) type=\(amap.poiType ?? "nil")")
            return ResolvedPOI(name: name, type: amap.poiType)
        }

        print("[Geo][POIResolve][Try] provider=MapboxTilequeryPOI")
        if let mapboxPOI = try await reverseGeocodePOIUsingMapboxTilequery(location: location) {
            print("[Geo][POIResolve][Hit] provider=MapboxTilequeryPOI value=\(mapboxPOI.name) type=\(mapboxPOI.type ?? "nil")")
            return mapboxPOI
        }
        print("[Geo][POIResolve][Miss] provider=MapboxTilequeryPOI")

        return nil
    }


    private func normalizeCityCandidate(
        _ value: String?,
        detailed: String?,
        subLocality: String?,
        adminArea: String?
    ) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, !looksLikeRoadName(trimmed) {
            return trimmed
        }

        if let subLocality, !subLocality.isEmpty {
            return subLocality
        }

        if let adminArea, !adminArea.isEmpty {
            return adminArea.replacingOccurrences(of: "省", with: "").replacingOccurrences(of: "市", with: "")
        }

        if let detailed, !looksLikeRoadName(detailed) {
            return detailed
        }

        return nil
    }


    private func amapReverseGeocode(location: GeoCoordinate) async throws -> AmapResolvedResult? {
        guard let key = amapWebServiceKey() else {
            print("[Geo][Amap][Skip] AMAP_WEB_SERVICE_KEY missing")
            return nil
        }

        let gcj = GeoCoordinateTransform.wgs84ToGcj02IfNeeded(latitude: location.latitude, longitude: location.longitude)
        let lon = gcj.longitude
        let lat = gcj.latitude

        struct AmapReverseResponse: Decodable {
            struct Regeocode: Decodable {
                struct StringOrArray: Decodable {
                    let value: String?

                    init(from decoder: Decoder) throws {
                        let container = try decoder.singleValueContainer()
                        if let single = try? container.decode(String.self) {
                            value = single
                            return
                        }
                        if let list = try? container.decode([String].self) {
                            value = list.first
                            return
                        }
                        value = nil
                    }
                }

                struct AddressComponent: Decodable {
                    struct NameContainer: Decodable {
                        let name: String?
                        let type: String?

                        init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            name = (try? container.decode(StringOrArray.self, forKey: .name))?.value
                            type = (try? container.decode(StringOrArray.self, forKey: .type))?.value
                        }

                        enum CodingKeys: String, CodingKey { case name, type }
                    }

                    struct StreetNumber: Decodable {
                        let street: String?
                        let number: String?
                        let location: String?
                        let direction: String?
                        let distance: String?

                        init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            street = (try? container.decode(StringOrArray.self, forKey: .street))?.value
                            number = (try? container.decode(StringOrArray.self, forKey: .number))?.value
                            location = (try? container.decode(StringOrArray.self, forKey: .location))?.value
                            direction = (try? container.decode(StringOrArray.self, forKey: .direction))?.value
                            distance = (try? container.decode(StringOrArray.self, forKey: .distance))?.value
                        }

                        enum CodingKeys: String, CodingKey {
                            case street, number, location, direction, distance
                        }
                    }

                    let province: String?
                    let city: String?
                    let district: String?
                    let township: String?
                    let neighborhood: NameContainer?
                    let building: NameContainer?
                    let streetNumber: StreetNumber?

                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        province = (try? container.decode(StringOrArray.self, forKey: .province))?.value
                        city = (try? container.decode(StringOrArray.self, forKey: .city))?.value
                        district = (try? container.decode(StringOrArray.self, forKey: .district))?.value
                        township = (try? container.decode(StringOrArray.self, forKey: .township))?.value
                        neighborhood = try? container.decode(NameContainer.self, forKey: .neighborhood)
                        building = try? container.decode(NameContainer.self, forKey: .building)
                        streetNumber = try? container.decode(StreetNumber.self, forKey: .streetNumber)
                    }

                    enum CodingKeys: String, CodingKey {
                        case province, city, district, township, neighborhood, building, streetNumber
                    }
                }

                struct POI: Decodable {
                    let id: String?
                    let name: String?
                    let type: String?
                    let distance: String?
                    let address: String?
                    let location: String?
                    let direction: String?
                    let businessarea: String?

                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        id = (try? container.decode(StringOrArray.self, forKey: .id))?.value
                        name = (try? container.decode(StringOrArray.self, forKey: .name))?.value
                        type = (try? container.decode(StringOrArray.self, forKey: .type))?.value
                        distance = (try? container.decode(StringOrArray.self, forKey: .distance))?.value
                        address = (try? container.decode(StringOrArray.self, forKey: .address))?.value
                        location = (try? container.decode(StringOrArray.self, forKey: .location))?.value
                        direction = (try? container.decode(StringOrArray.self, forKey: .direction))?.value
                        businessarea = (try? container.decode(StringOrArray.self, forKey: .businessarea))?.value
                    }

                    enum CodingKeys: String, CodingKey {
                        case id, name, type, distance, address, location, direction, businessarea
                    }
                }

                let formatted_address: String?
                let addressComponent: AddressComponent?
                let pois: [POI]?
            }

            let status: String?
            let info: String?
            let regeocode: Regeocode?
        }

        guard var components = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "location", value: "\(lon),\(lat)"),
            URLQueryItem(name: "radius", value: "80"),
            URLQueryItem(name: "extensions", value: "all"),
            URLQueryItem(name: "roadlevel", value: "0")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[Geo][Amap][HTTP] status=\(http.statusCode) lat=\(lat) lng=\(lon)")
                guard (200...299).contains(http.statusCode) else {
                    let snippet = String(data: data.prefix(220), encoding: .utf8) ?? ""
                    print("[Geo][Amap][HTTP][Body] \(snippet)")
                    return nil
                }
            }

            let decoded = try JSONDecoder().decode(AmapReverseResponse.self, from: data)
            guard decoded.status == "1" else {
                print("[Geo][Amap][API][Fail] info=\(decoded.info ?? "unknown")")
                return nil
            }

            let component = decoded.regeocode?.addressComponent
            let city = component?.city?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? component?.province?.trimmingCharacters(in: .whitespacesAndNewlines)

            let detailedCandidates = [
                component?.district,
                component?.township,
                component?.streetNumber?.street,
                component?.streetNumber?.number,
                component?.neighborhood?.name,
                component?.building?.name,
                decoded.regeocode?.formatted_address
            ]

            let detailed = detailedCandidates
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })

            let pois = decoded.regeocode?.pois ?? []
            let poiCandidates = pois
                .compactMap { poi -> ResolvedPOI? in
                    guard let name = poi.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                    guard !looksLikeRoadName(name) else { return nil }
                    let type = poi.type?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ResolvedPOI(name: name, type: type)
                }

            let poi = poiCandidates.first

            if city == nil && detailed == nil && poi == nil {
                return nil
            }

            return AmapResolvedResult(city: city, detailed: detailed, poi: poi?.name, poiType: poi?.type)
        } catch {
            print("[Geo][Amap][Error] lat=\(lat) lng=\(lon) error=\(error)")
            return nil
        }
    }

    private func reverseGeocodePOIUsingMapboxTilequery(location: GeoCoordinate) async throws -> ResolvedPOI? {
        guard let token = mapboxAccessToken() else {
            print("[Geo][MapboxTilequery][Skip] MAPBOX_ACCESS_TOKEN missing")
            return nil
        }

        let lon = location.longitude
        let lat = location.latitude

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

    private func mapboxReverseGeocode(location: GeoCoordinate) async throws -> MapboxResolvedResult? {
        guard let token = mapboxAccessToken() else {
            print("[Geo][Mapbox][Skip] MAPBOX_ACCESS_TOKEN missing")
            return nil
        }

        // 统一走 v5，避免 v6 在 reverse geocoding 参数校验上的 422 兼容问题。
        return try await mapboxReverseGeocodeV5(location: location, token: token)
    }

    private func mapboxReverseGeocodeV5(location: GeoCoordinate, token: String) async throws -> MapboxResolvedResult? {
        let lon = location.longitude
        let lat = location.latitude

        struct V5Response: Decodable {
            struct Feature: Decodable {
                struct ContextItem: Decodable {
                    let id: String?
                    let text: String?
                }

                let place_name: String?
                let text: String?
                let place_type: [String]?
                let context: [ContextItem]?
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

                let contextCity = feature.context?
                    .first(where: { $0.id?.hasPrefix("place") == true || $0.id?.hasPrefix("locality") == true })?
                    .text?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let cityFromFeature: String? = {
                    guard let type = feature.place_type?.first,
                          type == "place" || type == "locality" else { return nil }
                    return feature.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                }()

                let city = contextCity ?? cityFromFeature
                let detailed = feature.place_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? feature.text?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let city, !city.isEmpty {
                    return MapboxResolvedResult(city: city, detailed: detailed)
                }

                if let detailed, !detailed.isEmpty {
                    return MapboxResolvedResult(city: nil, detailed: detailed)
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

private struct GeoCoordinate {
    let latitude: Double
    let longitude: Double
}

private struct ResolvedLocation {
    let city: String?
    let detailed: String?
    let poi: String?
    let poiType: String?
    let subLocality: String?
    let adminArea: String?
}

private struct ResolvedPOI {
    let name: String
    let type: String?
}


private struct AmapResolvedResult {
    let city: String?
    let detailed: String?
    let poi: String?
    let poiType: String?
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
