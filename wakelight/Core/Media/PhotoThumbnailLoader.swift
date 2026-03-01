import Foundation
import Photos
import UIKit
import SwiftUI
import GRDB
import AVFoundation

final class PhotoThumbnailLoader {
    static let shared = PhotoThumbnailLoader()

    private actor BackfillRegistry {
        private var inFlight = Set<String>()

        func begin(_ key: String) -> Bool {
            if inFlight.contains(key) { return false }
            inFlight.insert(key)
            return true
        }

        func end(_ key: String) {
            inFlight.remove(key)
        }
    }

    private actor FallbackLoadLimiter {
        private let maxConcurrent: Int
        private var running: Int = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(maxConcurrent: Int) {
            self.maxConcurrent = max(1, maxConcurrent)
        }

        func acquire() async {
            if running < maxConcurrent {
                running += 1
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            running += 1
        }

        func release() {
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            } else {
                running = max(0, running - 1)
            }
        }
    }

    private struct ThumbnailAssetLookup {
        let photoId: UUID
        let mediaType: PhotoAsset.MediaType
        let thumbnailPath: String?
    }

    private let imageManager = PHImageManager.default()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let fullImageCache = NSCache<NSString, UIImage>()
    private let backfillRegistry = BackfillRegistry()
    private let fallbackLoadLimiter = FallbackLoadLimiter(maxConcurrent: 3)

    private init() {
        thumbnailCache.countLimit = 200 // 缓存最近的 200 张缩略图
        fullImageCache.countLimit = 20 // 缓存大图，避免内存溢出
    }

    // MARK: - Public

    /// 加载缩略图，优先从数据库记录的磁盘缓存读取，失败则即时加载并异步补齐磁盘缓存。
    func loadThumbnailWithDiskCache(locatorKey: String, size: CGSize) async -> UIImage? {
        // 1. 通过 locatorKey 解析到对应 PhotoAsset（兼容 library:// 与 webdav://）
        let lookup = try? await lookupAsset(for: locatorKey)

        // 2. 优先读取已落盘缩略图
        if let cachedPath = lookup?.thumbnailPath,
           let cachedImage = UIImage(contentsOfFile: cachedPath) {
            print("[ThumbLoader] source=disk-hit locator=\(locatorKey) path=\(cachedPath)")
            return cachedImage
        }

        if let cachedPath = lookup?.thumbnailPath {
            print("[ThumbLoader] source=disk-miss locator=\(locatorKey) path=\(cachedPath) exists=\(FileManager.default.fileExists(atPath: cachedPath))")
        } else {
            print("[ThumbLoader] source=disk-miss locator=\(locatorKey) reason=no-thumbnailPath")
        }

        // 3. 没找到磁盘缓存，走受限并发的 fallback（避免首轮解码洪峰）
        await fallbackLoadLimiter.acquire()
        let image: UIImage?
        do {
            image = await loadThumbnail(locatorKey: locatorKey, size: size)
        }
        await fallbackLoadLimiter.release()
        print("[ThumbLoader] source=fallback-loader locator=\(locatorKey) success=\(image != nil)")

        // 4. 异步触发后台补齐（将该图落盘，下次就快）
        if image != nil, let locator = MediaLocator.parse(locatorKey) {
            triggerBackfill(locator: locator, locatorKey: locatorKey)
        }

        return image
    }

    /// 触发后台补齐缩略图缓存（同一 locatorKey 去重）
    private func triggerBackfill(locator: MediaLocator, locatorKey: String) {
        Task.detached(priority: .background) {
            let shouldStart = await self.backfillRegistry.begin(locatorKey)
            guard shouldStart else { return }
            defer {
                Task {
                    await self.backfillRegistry.end(locatorKey)
                }
            }

            do {
                guard let lookup = try await self.lookupAsset(for: locatorKey) else {
                    print("[ThumbLoader] Backfill skipped (asset not found): \(locatorKey)")
                    return
                }

                if let existingPath = lookup.thumbnailPath,
                   !existingPath.isEmpty,
                   FileManager.default.fileExists(atPath: existingPath) {
                    return
                }

                let path = try await PhotoThumbnailGenerator.shared.generateThumbnail(for: locator, mediaType: lookup.mediaType)

                try await DatabaseContainer.shared.writer.write { db in
                    if var asset = try PhotoAsset.fetchOne(db, key: lookup.photoId) {
                        asset.thumbnailPath = path
                        asset.thumbnailUpdatedAt = Date()
                        try asset.update(db)
                    }
                }

                print("[ThumbLoader] Backfill success: \(locatorKey)")
            } catch {
                print("[ThumbLoader] Backfill failed: \(error)")
            }
        }
    }

    private func lookupAsset(for locatorKey: String) async throws -> ThumbnailAssetLookup? {
        try await DatabaseContainer.shared.db.reader.read { db in
            if let asset = try PhotoAsset.filter(Column("localIdentifier") == locatorKey).fetchOne(db) {
                return ThumbnailAssetLookup(
                    photoId: asset.id,
                    mediaType: asset.mediaType ?? .photo,
                    thumbnailPath: asset.thumbnailPath
                )
            }

            guard let locator = MediaLocator.parse(locatorKey) else { return nil }

            switch locator {
            case .library(let localIdentifier):
                if let asset = try PhotoAsset.filter(Column("localIdentifier") == localIdentifier).fetchOne(db) {
                    return ThumbnailAssetLookup(
                        photoId: asset.id,
                        mediaType: asset.mediaType ?? .photo,
                        thumbnailPath: asset.thumbnailPath
                    )
                }
                return nil

            case .webdav(let profileIdRaw, let remotePath):
                guard let profileId = UUID(uuidString: profileIdRaw) else { return nil }
                guard let remote = try RemoteMediaAsset
                    .filter(Column("profileId") == profileId && Column("remotePath") == remotePath)
                    .fetchOne(db) else {
                    return nil
                }

                guard let asset = try PhotoAsset.fetchOne(db, key: remote.photoAssetId) else { return nil }
                return ThumbnailAssetLookup(
                    photoId: asset.id,
                    mediaType: asset.mediaType ?? .photo,
                    thumbnailPath: asset.thumbnailPath
                )

            case .file:
                return nil
            }
        }
    }

    func loadThumbnail(locatorKey: String, size: CGSize) async -> UIImage? {
        guard let locator = MediaLocator.parse(locatorKey) else {
            print("[Thumb] parse failed: \(locatorKey)")
            return nil
        }

        if case .webdav(let profileId, let remotePath) = locator {
            print("[Thumb] request webdav thumb profile=\(profileId) path=\(remotePath) size=\(Int(size.width))x\(Int(size.height))")
        }

        let cacheKey = "thumb-\(locator.stableKey)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            print("[ThumbLoader] source=memory-hit locator=\(locator.stableKey)")
            return cached
        }

        let image = await loadThumbnail(locator: locator, size: size)
        if let image {
            thumbnailCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    func loadFullImage(locatorKey: String) async -> UIImage? {
        guard let locator = MediaLocator.parse(locatorKey) else {
            return nil
        }

        let cacheKey = "full-\(locator.stableKey)" as NSString
        if let cached = fullImageCache.object(forKey: cacheKey) {
            return cached
        }

        let image = await loadFullImage(locator: locator)
        if let image {
            fullImageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    // MARK: - Internal

    private func loadThumbnail(locator: MediaLocator, size: CGSize) async -> UIImage? {
        switch locator {
        case .library(let localIdentifier):
            return await loadThumbnailFromPhotos(localIdentifier: localIdentifier, size: size)
        case .webdav, .file:
            do {
                let mediaType = try await lookupMediaType(for: locator.stableKey)
                let resource = try await MediaResolver.shared.resolve(locator: locator)
                switch resource {
                case .data(let data):
                    print("[ThumbLoader] fallback-resource=data-bytes locator=\(locator.stableKey) bytes=\(data.count)")
                    if mediaType == .video {
                        return generateVideoThumbnailFromData(data, size: size)
                    }
                    return UIImage(data: data)
                case .url(let url):
                    let isLocal = url.isFileURL
                    print("[ThumbLoader] fallback-resource=url locator=\(locator.stableKey) isFileURL=\(isLocal) path=\(url.path)")
                    if mediaType == .video || isLikelyVideo(path: url.path) {
                        return generateVideoThumbnailFromURL(url, size: size)
                    }
                    return UIImage(contentsOfFile: url.path)
                case .phAsset(let asset):
                    print("[ThumbLoader] fallback-resource=phAsset locator=\(locator.stableKey) localIdentifier=\(asset.localIdentifier)")
                    return await requestImage(for: asset, targetSize: size, contentMode: .aspectFill, delivery: .opportunistic)
                }
            } catch {
                print("[ThumbLoader] fallback-resource=resolve-failed locator=\(locator.stableKey) error=\(error)")
                return nil
            }
        }
    }

    private func loadFullImage(locator: MediaLocator) async -> UIImage? {
        switch locator {
        case .library(let localIdentifier):
            return await loadFullImageFromPhotos(localIdentifier: localIdentifier)
        case .webdav, .file:
            do {
                let resource = try await MediaResolver.shared.resolve(locator: locator)
                switch resource {
                case .data(let data):
                    return UIImage(data: data)
                case .url(let url):
                    return UIImage(contentsOfFile: url.path)
                case .phAsset(let asset):
                    return await requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, delivery: .highQualityFormat)
                }
            } catch {
                return nil
            }
        }
    }

    private func lookupMediaType(for locatorKey: String) async throws -> PhotoAsset.MediaType? {
        try await DatabaseContainer.shared.db.reader.read { db in
            if let asset = try PhotoAsset.filter(Column("localIdentifier") == locatorKey).fetchOne(db) {
                return asset.mediaType
            }

            guard let locator = MediaLocator.parse(locatorKey) else { return nil }

            switch locator {
            case .library(let id):
                return try PhotoAsset.filter(Column("localIdentifier") == id).fetchOne(db)?.mediaType
            case .webdav(let profileIdRaw, let remotePath):
                guard let profileId = UUID(uuidString: profileIdRaw) else { return nil }
                guard let remote = try RemoteMediaAsset
                    .filter(Column("profileId") == profileId && Column("remotePath") == remotePath)
                    .fetchOne(db) else { return nil }
                return try PhotoAsset.fetchOne(db, key: remote.photoAssetId)?.mediaType
            case .file:
                return nil
            }
        }
    }

    private func isLikelyVideo(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v")
    }

    private func generateVideoThumbnailFromURL(_ url: URL, size: CGSize) -> UIImage? {
        let asset = AVURLAsset(url: url)
        return generateVideoThumbnail(from: asset, size: size)
    }

    private func generateVideoThumbnailFromData(_ data: Data, size: CGSize) -> UIImage? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let asset = AVURLAsset(url: tempURL)
            return generateVideoThumbnail(from: asset, size: size)
        } catch {
            return nil
        }
    }

    private func generateVideoThumbnail(from asset: AVAsset, size: CGSize) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let sampleTimeSeconds = durationSeconds.isFinite && durationSeconds > 0 ? min(durationSeconds * 0.33, 2.0) : 0.0
        let time = CMTime(seconds: sampleTimeSeconds, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private func loadThumbnailFromPhotos(localIdentifier: String, size: CGSize) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await requestImage(for: asset, targetSize: size, contentMode: .aspectFill, delivery: .opportunistic)
    }

    private func loadFullImageFromPhotos(localIdentifier: String) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, delivery: .highQualityFormat)
    }

    private func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        delivery: PHImageRequestOptionsDeliveryMode
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = delivery
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true

            var resumed = false

            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                guard !resumed else { return }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }

                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - SwiftUI Views

struct ThumbnailView: View {
    let locatorKey: String
    let size: CGSize
    var showRawBadge: Bool = false
    var showLiveBadge: Bool = false

    @State private var image: UIImage?
    @State private var isVideo = false

    var body: some View {
        ZStack {
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(ProgressView().scaleEffect(0.5))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()

            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: min(size.width, size.height) * 0.42))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(radius: 6)
            } else if showRawBadge || showLiveBadge {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if showLiveBadge {
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(2)
                            }
                            if showRawBadge {
                                Text("RAW")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(2)
                            }
                        }
                        .padding(4)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(4)
        .task(id: "\(locatorKey)-\(Int(size.width))x\(Int(size.height))") {
            await refreshIsVideo()
            image = await PhotoThumbnailLoader.shared.loadThumbnailWithDiskCache(locatorKey: locatorKey, size: size)
        }
    }

    private func refreshIsVideo() async {
        // 1. 尝试从数据库查询
        let type = try? await DatabaseContainer.shared.db.reader.read { db -> PhotoAsset.MediaType? in
            // 先尝试完全匹配 locatorKey (library://... 或 webdav://...)
            if let asset = try PhotoAsset.filter(Column("localIdentifier") == locatorKey).fetchOne(db) {
                return asset.mediaType
            }
            
            // 如果是 library://，尝试提取纯 identifier 再次匹配
            if let locator = MediaLocator.parse(locatorKey),
               case .library(let id) = locator {
                if let asset = try PhotoAsset.filter(Column("localIdentifier") == id).fetchOne(db) {
                    return asset.mediaType
                }
            }
            return nil
        }
        
        await MainActor.run {
            if let type = type {
                self.isVideo = (type == .video)
            } else {
                // 2. 数据库没查到，根据扩展名兜底判断
                let lower = locatorKey.lowercased()
                self.isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v")
            }
        }
    }
}

struct FullImageView: View {
    let locatorKey: String

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Color.clear
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .task(id: locatorKey) {
            isLoading = true
            
            // 1. 优先从磁盘缓存读取缩略图作为极速预览
            image = await PhotoThumbnailLoader.shared.loadThumbnailWithDiskCache(locatorKey: locatorKey, size: CGSize(width: 320, height: 320))
            
            // 2. 如果没能加载到缩略图（比如还没落盘），则尝试加载一个中等尺寸的作为预览（走内存缓存/即时解码）
            if image == nil {
                image = await PhotoThumbnailLoader.shared.loadThumbnail(locatorKey: locatorKey, size: CGSize(width: 800, height: 800))
            }
            
            // 3. 最后加载全量大图
            if let fullRes = await PhotoThumbnailLoader.shared.loadFullImage(locatorKey: locatorKey) {
                image = fullRes
            }
            isLoading = false
        }
    }
}
