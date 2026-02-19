import Foundation
import Photos
import UIKit
import SwiftUI

final class PhotoThumbnailLoader {
    static let shared = PhotoThumbnailLoader()

    private let imageManager = PHImageManager.default()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let fullImageCache = NSCache<NSString, UIImage>()

    private init() {
        thumbnailCache.countLimit = 200 // 缓存最近的 200 张缩略图
        fullImageCache.countLimit = 20 // 缓存大图，避免内存溢出
    }

    // MARK: - Public

    func loadThumbnail(locatorKey: String, size: CGSize) async -> UIImage? {
        guard let locator = MediaLocator.parse(locatorKey) else {
            return nil
        }

        let cacheKey = "thumb-\(locator.stableKey)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
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
                let resource = try await MediaResolver.shared.resolve(locator: locator)
                switch resource {
                case .data(let data):
                    return UIImage(data: data)
                case .url(let url):
                    return UIImage(contentsOfFile: url.path)
                case .phAsset(let asset):
                    return await requestImage(for: asset, targetSize: size, contentMode: .aspectFill, delivery: .opportunistic)
                }
            } catch {
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

    @State private var image: UIImage?

    var body: some View {
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
        .cornerRadius(4)
        .task(id: "\(locatorKey)-\(Int(size.width))x\(Int(size.height))") {
            image = await PhotoThumbnailLoader.shared.loadThumbnail(locatorKey: locatorKey, size: size)
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
            // 加载一个中等尺寸的作为预览
            image = await PhotoThumbnailLoader.shared.loadThumbnail(locatorKey: locatorKey, size: CGSize(width: 800, height: 800))
            if let fullRes = await PhotoThumbnailLoader.shared.loadFullImage(locatorKey: locatorKey) {
                image = fullRes
            }
            isLoading = false
        }
    }
}
