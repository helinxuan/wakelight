import Foundation
import GRDB
import CryptoKit
import CoreLocation

/// 从 PhotoAsset 生成 PlaceCluster 的最小用例（MVP：网格聚合）。
final class GeneratePlaceClustersUseCase {
    private let writer: DatabaseWriter

    init(writer: DatabaseWriter = DatabaseContainer.shared.writer) {
        self.writer = writer
    }

    func run() async throws -> Int {
        try await writer.write { db in
            // 仅使用“保留/未标注”照片参与地图聚类；已归档过滤的不应再生成光点
            let photos = try PhotoAsset
                .filter((Column("curationBucket") != ImportDecisionBucket.archived.rawValue) || Column("curationBucket") == nil)
                .fetchAll(db)

            let radiusMeters = AppConfig.default.placeClusterRadiusMeters
            let timeWindow = AppConfig.default.visitSplitThreshold
            let gridPrecision = 0.05 // 约 5-6km，用于粗分桶降低 O(n^2)
            let clusterKeyPrecision = max(radiusMeters / 111_000.0, 0.001) // 约 100-200m 级别精度

            let clusters = buildClusters(
                photos: photos,
                radiusMeters: radiusMeters,
                timeWindow: timeWindow,
                gridPrecision: gridPrecision,
                clusterKeyPrecision: clusterKeyPrecision
            )

            var upserted = 0
            let newKeys = Set(clusters.map { $0.geohash })

            for cluster in clusters {
                let existing = try PlaceCluster
                    .filter(Column("geohash") == cluster.geohash)
                    .fetchOne(db)

                if var existing {
                    existing.centerLatitude = cluster.centerLatitude
                    existing.centerLongitude = cluster.centerLongitude
                    existing.photoCount = cluster.photoCount
                    existing.lastVisitedAt = cluster.lastVisitedAt
                    existing.fogState = cluster.fogState
                    try existing.update(db)
                } else {
                    try cluster.insert(db)
                }

                upserted += 1
            }

            // 同步删除：清理不再有照片的旧光点
            let deletedCount = try PlaceCluster
                .filter(!newKeys.contains(Column("geohash")))
                .deleteAll(db)

            if deletedCount > 0 {
                print("[GenerateClusters] Deleted \(deletedCount) stale clusters with no photos")
            }

            return upserted
        }
    }
}

private extension GeneratePlaceClustersUseCase {
    struct ClusterCandidate {
        let geohash: String
        let centerLatitude: Double
        let centerLongitude: Double
        let photoCount: Int
        let lastVisitedAt: Date?
        let sourcePhotos: [PhotoAsset]
    }

    func buildClusters(
        photos: [PhotoAsset],
        radiusMeters: Double,
        timeWindow: TimeInterval,
        gridPrecision: Double,
        clusterKeyPrecision: Double
    ) -> [PlaceCluster] {
        let indexed = photos.enumerated().compactMap { index, photo -> (Int, PhotoAsset)? in
            guard photo.latitude != nil, photo.longitude != nil else { return nil }
            return (index, photo)
        }

        let n = indexed.count
        guard n > 0 else { return [] }

        var parent = Array(0..<n)

        func find(_ x: Int) -> Int {
            if parent[x] != x { parent[x] = find(parent[x]) }
            return parent[x]
        }

        func union(_ a: Int, _ b: Int) {
            let pa = find(a)
            let pb = find(b)
            if pa != pb { parent[pb] = pa }
        }

        var buckets: [String: [Int]] = [:]
        buckets.reserveCapacity(128)

        for (i, (_, photo)) in indexed.enumerated() {
            guard let lat = photo.latitude, let lon = photo.longitude else { continue }
            let (latBucket, lonBucket) = GeoGrid.bucketIndices(latitude: lat, longitude: lon, precisionDegrees: gridPrecision)
            let key = GeoGrid.key(latBucket: latBucket, lonBucket: lonBucket, precisionDegrees: gridPrecision)

            if let localId = photo.localIdentifier,
               localId.contains("IMG_0172") || localId.contains("11F129CD-C098-4757-9A86-EDF0D6356735") {
                print("[ClusterDebug] hit target localIdentifier=\(localId) lat=\(lat) lon=\(lon) creation=\(String(describing: photo.creationDate)) bucket=\(key)")
            }

            buckets[key, default: []].append(i)
        }

        for (key, indices) in buckets {
            let parts = key.split(separator: "_")
            guard parts.count >= 2, let latBucket = Int(parts[0]), let lonBucket = Int(parts[1]) else { continue }

            for latOffset in -1...1 {
                for lonOffset in -1...1 {
                    let neighborKey = GeoGrid.key(
                        latBucket: latBucket + latOffset,
                        lonBucket: lonBucket + lonOffset,
                        precisionDegrees: gridPrecision
                    )
                    guard let neighborIndices = buckets[neighborKey] else { continue }

                    for i in indices {
                        for j in neighborIndices where j > i {
                            let photoA = indexed[i].1
                            let photoB = indexed[j].1
                            guard let latA = photoA.latitude, let lonA = photoA.longitude,
                                  let latB = photoB.latitude, let lonB = photoB.longitude else { continue }

                            if let dateA = photoA.creationDate, let dateB = photoB.creationDate {
                                let timeDiff = abs(dateA.timeIntervalSince(dateB))
                                if timeDiff > timeWindow { continue }
                            }

                            let distance = CLLocation(latitude: latA, longitude: lonA)
                                .distance(from: CLLocation(latitude: latB, longitude: lonB))

                            if distance < radiusMeters {
                                if let localId = photoA.localIdentifier,
                                   localId.contains("IMG_0172") || localId.contains("11F129CD-C098-4757-9A86-EDF0D6356735") {
                                    print("[ClusterDebug] union target with other id=\(String(describing: photoB.localIdentifier)) dist=\(distance) timeWindow=\(timeWindow)")
                                }
                                if let localId = photoB.localIdentifier,
                                   localId.contains("IMG_0172") || localId.contains("11F129CD-C098-4757-9A86-EDF0D6356735") {
                                    print("[ClusterDebug] union other id=\(String(describing: photoA.localIdentifier)) with target dist=\(distance) timeWindow=\(timeWindow)")
                                }
                                union(i, j)
                            }
                        }
                    }
                }
            }
        }

        var groups: [Int: [PhotoAsset]] = [:]
        groups.reserveCapacity(128)

        for i in 0..<n {
            let root = find(i)
            groups[root, default: []].append(indexed[i].1)
        }

        let candidates = groups.values.map { group in
            let lat = group.compactMap { $0.latitude }.reduce(0.0, +) / Double(group.count)
            let lon = group.compactMap { $0.longitude }.reduce(0.0, +) / Double(group.count)
            let center = CLLocation(latitude: lat, longitude: lon)

            let representative = group.min { lhs, rhs in
                guard let latL = lhs.latitude, let lonL = lhs.longitude,
                      let latR = rhs.latitude, let lonR = rhs.longitude else { return false }
                let distL = CLLocation(latitude: latL, longitude: lonL).distance(from: center)
                let distR = CLLocation(latitude: latR, longitude: lonR).distance(from: center)
                return distL < distR
            }

            if let rep = representative,
               let localId = rep.localIdentifier,
               localId.contains("IMG_0172") || localId.contains("11F129CD-C098-4757-9A86-EDF0D6356735") {
                print("[ClusterDebug] rep target chosen lat=\(String(describing: rep.latitude)) lon=\(String(describing: rep.longitude)) centerLat=\(lat) centerLon=\(lon) count=\(group.count)")
            }

            let centerLat = representative?.latitude ?? lat
            let centerLon = representative?.longitude ?? lon
            let geohash = GeoGrid.key(latitude: centerLat, longitude: centerLon, precisionDegrees: clusterKeyPrecision)

            return ClusterCandidate(
                geohash: geohash,
                centerLatitude: centerLat,
                centerLongitude: centerLon,
                photoCount: group.count,
                lastVisitedAt: group.compactMap { $0.creationDate }.max(),
                sourcePhotos: group
            )
        }

        return candidates.map { candidate in
            let id = UUID(uuidString: UUID.v5String(namespace: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!, name: candidate.geohash)) ?? UUID()

            return PlaceCluster(
                id: id,
                centerLatitude: candidate.centerLatitude,
                centerLongitude: candidate.centerLongitude,
                geohash: candidate.geohash,
                cityName: nil,
                detailedAddress: nil,
                poiName: nil,
                poiType: nil,
                photoCount: candidate.photoCount,
                visitCount: 1,
                fogState: .revealed,
                hasStory: false,
                lastVisitedAt: candidate.lastVisitedAt
            )
        }
    }
}

private extension UUID {
    /// 生成一个稳定的 UUID v5 字符串（SHA1 name-based），避免引入额外依赖。
    /// 注意：这里只返回字符串形式，外部再用 UUID(uuidString:) 解析。
    static func v5String(namespace: UUID, name: String) -> String {
        // RFC 4122 UUIDv5
        var ns = namespace.uuid
        let nsData = Data(bytes: &ns, count: MemoryLayout.size(ofValue: ns))
        let nameData = Data(name.utf8)

        var data = Data()
        data.append(nsData)
        data.append(nameData)

        let hash = Insecure.SHA1.hash(data: data)
        let bytes = Array(hash)

        var uuidBytes = bytes.prefix(16)
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80

        let hex = uuidBytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))\(hex.dropFirst(8).prefix(4))\(hex.dropFirst(12).prefix(4))\(hex.dropFirst(16).prefix(4))\(hex.dropFirst(20))"
    }
}
