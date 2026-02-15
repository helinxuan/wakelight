import Foundation
import Photos
import UIKit
import SwiftUI

final class PhotoThumbnailLoader {
    static let shared = PhotoThumbnailLoader()
    
    private let imageManager = PHImageManager.default()
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 200 // 缓存最近的 200 张缩略图
    }
    
    func loadThumbnail(for localIdentifier: String, size: CGSize) async -> UIImage? {
        if let cached = cache.object(forKey: localIdentifier as NSString) {
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
                    self?.cache.setObject(image, forKey: localIdentifier as NSString)
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
