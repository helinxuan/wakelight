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
    /// - parameter preferredLocalFileURL: Optional local file URL to reuse during import, avoiding an extra network fetch.
    /// Returns the thumbnail relative path (file name under cache thumbnails directory).
    func generateThumbnail(
        for locator: MediaLocator,
        mediaType: PhotoAsset.MediaType,
        preferredLocalFileURL: URL? = nil
    ) async throws -> String {
        let relativePath = MediaCache.shared.thumbnailRelativePath(for: locator, size: targetSize)
        let destinationURL = try MediaCache.shared.thumbnailURL(forRelativePath: relativePath)
        
        // If already exists, just return path
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return relativePath        }
        
        let resource: MediaResource
        if let preferredLocalFileURL {
            resource = .url(preferredLocalFileURL)
        } else {
            resource = try await MediaResolver.shared.resolve(locator: locator)
        }

        // WebDAV fallback/curation may resolve remote media to temporary local files.
        // Ensure these temporary files are cleaned up after thumbnail generation.
        defer {
            if case .url(let url) = resource, shouldCleanupTemporaryURL(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        let thumbnail: UIImage
        switch mediaType {
        case .video:
            thumbnail = try await generateVideoThumbnail(from: resource)
        case .photo:
            thumbnail = try await generateImageThumbnail(from: resource)
        }
        
        // Save to disk as JPEG.
        // JPEG has no alpha channel, so flatten transparent sources first to avoid
        // unnecessary RGBA->RGB conversion overhead and runtime warnings.
        let jpegReadyImage = imageHasAlpha(thumbnail)
            ? flattenToOpaqueJPEGImage(thumbnail, backgroundColor: .white)
            : thumbnail

        guard let data = jpegReadyImage.jpegData(compressionQuality: 0.7) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate JPEG data"])
        }
        
        try data.write(to: destinationURL)

        // Enforce disk cache limit (LRU trim)
        try? MediaCache.shared.trimThumbnailsIfNeeded()

        return relativePath
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

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let sampleSeconds: [Double] = {
            if durationSeconds.isFinite && durationSeconds > 0 {
                let middle = durationSeconds / 2.0
                let oneThird = durationSeconds / 3.0
                return [max(0.05, middle), max(0.05, oneThird), 0.05]
            }
            return [0.05]
        }()

        var lastError: Error?
        for second in sampleSeconds {
            do {
                let time = CMTime(seconds: second, preferredTimescale: 600)
                let (cgImage, _) = try await imageWithTimeout(generator: generator, time: time, timeoutSeconds: 12)
                return UIImage(cgImage: cgImage)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(domain: "PhotoThumbnailGenerator", code: -9, userInfo: [NSLocalizedDescriptionKey: "Cannot Decode"])
    }
    
    private func createImageThumbnail(from data: Data) throws -> UIImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            // Avoid decoding/caching full-resolution images into memory.
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create image source or thumbnail"])
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func createImageThumbnail(from url: URL) throws -> UIImage {
        let maxPixelSize = max(targetSize.width, targetSize.height)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Avoid decoding/caching full-resolution images into memory.
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create image source from URL"])
        }

        // Primary path: use ImageIO thumbnail API.
        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgThumb)
        }

        // Fallback path for some RAW files (e.g. certain RW2) where thumbnail extraction may fail.
        // Decode first frame and downscale in memory.
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, fallbackOptions as CFDictionary) else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create thumbnail from URL source"])
        }

        let image = UIImage(cgImage: fullImage)
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1

        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else {
            throw NSError(domain: "PhotoThumbnailGenerator", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid image dimensions"])
        }

        let scale = min(maxPixelSize / width, maxPixelSize / height)
        let resizedSize = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))

        let resized = UIGraphicsImageRenderer(size: resizedSize, format: rendererFormat).image { _ in
            image.draw(in: CGRect(origin: .zero, size: resizedSize))
        }

        return resized
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

            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, info in
                if let asset = asset {
                    continuation.resume(returning: asset)
                    return
                }

                let nsError = info?[PHImageErrorKey] as? NSError
                let message = nsError?.localizedDescription ?? "AVAsset request failed"
                continuation.resume(throwing: NSError(
                    domain: "PhotoThumbnailGenerator",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            }
        }
    }

    private func imageWithTimeout(
        generator: AVAssetImageGenerator,
        time: CMTime,
        timeoutSeconds: Double
    ) async throws -> (CGImage, CMTime) {
        let timeoutNs = UInt64(max(1, Int(timeoutSeconds * 1_000_000_000)))
        let worker = Task.detached(priority: .background) {
            try await generator.image(at: time)
        }

        do {
            let result = try await withThrowingTaskGroup(of: (CGImage, CMTime).self) { group in
                group.addTask {
                    try await worker.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw NSError(
                        domain: "PhotoThumbnailGenerator",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "video frame extraction timeout after \(Int(timeoutSeconds))s"]
                    )
                }

                guard let value = try await group.next() else {
                    throw NSError(domain: "PhotoThumbnailGenerator", code: -10, userInfo: [NSLocalizedDescriptionKey: "video frame extraction timeout"])
                }
                group.cancelAll()
                return value
            }

            worker.cancel()
            return result
        } catch {
            worker.cancel()
            throw error
        }
    }

    private func imageHasAlpha(_ image: UIImage) -> Bool {
        guard let alphaInfo = image.cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private func flattenToOpaqueJPEGImage(_ image: UIImage, backgroundColor: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = image.scale

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func shouldCleanupTemporaryURL(_ url: URL) -> Bool {
        let tmpDir = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target.hasPrefix(tmpDir)
    }
}
