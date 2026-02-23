import Foundation
import AVFoundation
import ImageIO
import UIKit
import Photos
import UniformTypeIdentifiers

final class PhotoThumbnailGenerator {
    static let shared = PhotoThumbnailGenerator()
    
    private let targetSize = CGSize(width: 320, height: 320)
    
    private init() {}
    
    /// Generates and caches a thumbnail for the given locator.
    /// Returns the absolute path to the cached thumbnail.
    func generateThumbnail(for locator: MediaLocator, mediaType: PhotoAsset.MediaType) async throws -> String {
        let destinationURL = try MediaCache.shared.thumbnailURL(for: locator, size: targetSize)
        
        // If already exists, just return path
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL.path
        }
        
        let resource = try await MediaResolver.shared.resolve(locator: locator)
        
        let thumbnail: UIImage
        switch mediaType {
        case .video:
            thumbnail = try await generateVideoThumbnail(from: resource)
        case .photo:
            thumbnail = try await generateImageThumbnail(from: resource)
        }
        
        // Save to disk as JPEG
        guard let data = thumbnail.jpegData(compressionQuality: 0.7) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate JPEG data"])
        }
        
        try data.write(to: destinationURL)
        return destinationURL.path
    }
    
    private func generateImageThumbnail(from resource: MediaResource) async throws -> UIImage {
        switch resource {
        case .data(let data):
            return try createImageThumbnail(from: data)
        case .url(let url):
            return try createImageThumbnail(from: url)
        case .phAsset(let asset):
            return try await requestPhotosThumbnail(for: asset)
        }
    }
    
    private func generateVideoThumbnail(from resource: MediaResource) async throws -> UIImage {
        let asset: AVAsset
        var temporaryURL: URL?
        
        switch resource {
        case .data(let data):
            // AVAsset needs a URL, so we write to a temp file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            try data.write(to: tempURL)
            temporaryURL = tempURL
            asset = AVURLAsset(url: tempURL)
        case .url(let url):
            asset = AVURLAsset(url: url)
        case .phAsset(let phAsset):
            asset = try await requestAVAsset(for: phAsset)
        }
        
        defer {
            if let url = temporaryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize
        
        // Middle frame logic
        let duration = try await asset.load(.duration)
        let middleTime = CMTime(seconds: duration.seconds / 2.0, preferredTimescale: 600)
        
        let (cgImage, _) = try await generator.image(at: middleTime)
        return UIImage(cgImage: cgImage)
    }
    
    private func createImageThumbnail(from data: Data) throws -> UIImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create image source or thumbnail"])
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func createImageThumbnail(from url: URL) throws -> UIImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create image source from URL"])
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func requestPhotosThumbnail(for asset: PHAsset) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, info in
                if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: NSError(domain: "PhotoThumbnailGenerator", code: -5, userInfo: [NSLocalizedDescriptionKey: "Photos request failed"]))
                }
            }
        }
    }
    
    private func requestAVAsset(for phAsset: PHAsset) async throws -> AVAsset {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, _ in
                if let asset = asset {
                    continuation.resume(returning: asset)
                } else {
                    continuation.resume(throwing: NSError(domain: "PhotoThumbnailGenerator", code: -6, userInfo: [NSLocalizedDescriptionKey: "AVAsset request failed"]))
                }
            }
        }
    }
}
