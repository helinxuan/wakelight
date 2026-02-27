import Foundation
import GRDB
import CryptoKit

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

            // (key -> [photo]) 聚合
            var buckets: [String: [PhotoAsset]] = [:]
            buckets.reserveCapacity(128)

            for p in photos {
                guard let lat = p.latitude, let lon = p.longitude else { continue }
                let key = GeoGrid.key(latitude: lat, longitude: lon)
                buckets[key, default: []].append(p)
            }

            var upserted = 0
            let newKeys = Set(buckets.keys)

            for (key, items) in buckets {
                guard !items.isEmpty else { continue }
                // ... 原有逻辑保持不变 ...
                let centerLat = items.compactMap { $0.latitude }.reduce(0.0, +) / Double(items.count)
                let centerLon = items.compactMap { $0.longitude }.reduce(0.0, +) / Double(items.count)

                let id = UUID(uuidString: UUID.v5String(namespace: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!, name: key)) ?? UUID()

                let cluster = PlaceCluster(
                    id: id,
                    centerLatitude: centerLat,
                    centerLongitude: centerLon,
                    geohash: key,
                    cityName: nil,
                    photoCount: items.count,
                    visitCount: 1,
                    fogState: .revealed,
                    hasStory: false,
                    lastVisitedAt: items.compactMap { $0.creationDate }.max()
                )

                let existing = try PlaceCluster
                    .filter(Column("geohash") == key)
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
