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
    
    func loadThumbnail(for localIdentifier: String, size: CGSize) async -> UIImage? {
        let cacheKey = "thumb-\(localIdentifier)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true

            var resumed = false

            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in
                guard !resumed else { return }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }

                resumed = true

                if let image = image {
                    self?.thumbnailCache.setObject(image, forKey: cacheKey)
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    func loadFullImage(for localIdentifier: String) async -> UIImage? {
        let cacheKey = "full-\(localIdentifier)" as NSString
        if let cached = fullImageCache.object(forKey: cacheKey) {
            return cached
        }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true

            imageManager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }

                if let image = image {
                    self?.fullImageCache.setObject(image, forKey: cacheKey)
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct ThumbnailView: View {
    let localIdentifier: String
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
        .task(id: "\(localIdentifier)-\(Int(size.width))x\(Int(size.height))") {
            image = await PhotoThumbnailLoader.shared.loadThumbnail(for: localIdentifier, size: size)
        }
    }
}

struct FullImageView: View {
    let localIdentifier: String

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
        .task(id: localIdentifier) {
            isLoading = true
            image = await PhotoThumbnailLoader.shared.loadThumbnail(for: localIdentifier, size: CGSize(width: 800, height: 800))
            if let fullRes = await PhotoThumbnailLoader.shared.loadFullImage(for: localIdentifier) {
                image = fullRes
            }
            isLoading = false
        }
    }
}
