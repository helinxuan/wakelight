import Foundation
import GRDB

struct PhotoAssetLocator: Codable {
    let photoAssetId: UUID
    let locatorKey: String
    let hasRaw: Bool
    let hasLive: Bool
}

extension PhotoAsset {
    /// 批量获取 PhotoAsset 的 locatorKey
    static func fetchLocators(db: Database, ids: [UUID]) throws -> [PhotoAssetLocator] {
        guard !ids.isEmpty else { return [] }
        
        // 1. 获取基础 PhotoAsset 信息
        let photos = try PhotoAsset.filter(ids.contains(Column("id"))).fetchAll(db)
        let photoMap = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        
        // 2. 获取 RemoteMediaAsset 信息
        let remotes = try RemoteMediaAsset.filter(ids.contains(Column("photoAssetId"))).fetchAll(db)
        let remoteMap = Dictionary(uniqueKeysWithValues: remotes.map { ($0.photoAssetId, $0) })
        
        // 3. 组装 locatorKey
        return ids.compactMap { id in
            guard let photo = photoMap[id] else { return nil }
            
            let key: String
            if let localId = photo.localIdentifier {
                key = "library://\(localId)"
            } else if let remote = remoteMap[id] {
                key = "webdav://\(remote.profileId)/\(remote.remotePath)"
            } else {
                // 如果既没有 localIdentifier 也没有 remoteAsset，可能是坏数据
                return nil
            }
            
            let hasRaw: Bool
            let hasLive: Bool
            if let remote = remoteMap[id] {
                hasRaw = (remote.rawPath != nil)
                hasLive = (remote.livePhotoVideoPath != nil || remote.livePhotoPhotoPath != nil)
            } else {
                hasRaw = false
                hasLive = false
            }

            return PhotoAssetLocator(photoAssetId: id, locatorKey: key, hasRaw: hasRaw, hasLive: hasLive)
        }
    }
}
