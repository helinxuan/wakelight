import Foundation
import Vision
import UIKit
import Photos

struct ImageAnalysisResult: Sendable {
    let keywords: [String]
    let dominantColors: [String]
    let sceneLabels: [String]
    let textDetected: Bool
    let faceDetected: Bool
    let confidence: Double
}

struct AggregatedImageKeywords: Sendable {
    let topKeywords: [String]
    let sceneSummary: String
    let hasText: Bool
    let hasFaces: Bool
    let totalAnalyzed: Int
}

actor VisionImageAnalysisService {
    static let shared = VisionImageAnalysisService()

    private init() {}

    func analyzePhotos(locators: [PhotoAssetLocator], maxPhotos: Int = 10) async -> AggregatedImageKeywords {
        guard !locators.isEmpty else {
            return AggregatedImageKeywords(
                topKeywords: [],
                sceneSummary: "无照片",
                hasText: false,
                hasFaces: false,
                totalAnalyzed: 0
            )
        }

        let selectedLocators = Array(locators.prefix(maxPhotos))
        var allKeywords: [String] = []
        var allSceneLabels: [String] = []
        var hasTextInAny = false
        var hasFacesInAny = false

        for locator in selectedLocators {
            if let result = await analyzeSinglePhoto(locator: locator) {
                allKeywords.append(contentsOf: result.keywords)
                allSceneLabels.append(contentsOf: result.sceneLabels)
                hasTextInAny = hasTextInAny || result.textDetected
                hasFacesInAny = hasFacesInAny || result.faceDetected
            }
        }

        let topKeywords = aggregateAndSortKeywords(allKeywords, topN: 12)
        let sceneSummary = generateSceneSummary(labels: allSceneLabels, keywords: topKeywords)

        return AggregatedImageKeywords(
            topKeywords: topKeywords,
            sceneSummary: sceneSummary,
            hasText: hasTextInAny,
            hasFaces: hasFacesInAny,
            totalAnalyzed: selectedLocators.count
        )
    }

    private func analyzeSinglePhoto(locator: PhotoAssetLocator) async -> ImageAnalysisResult? {
        guard let image = await loadImage(from: locator) else {
            return nil
        }

        guard let cgImage = image.cgImage else {
            return nil
        }

        var keywords: [String] = []
        var sceneLabels: [String] = []
        var textDetected = false
        var faceDetected = false
        var totalConfidence: Double = 0
        var requestCount = 0

        return await withCheckedContinuation { continuation in
            let dispatchGroup = DispatchGroup()

            dispatchGroup.enter()
            let classifyRequest = VNClassifyImageRequest { request, error in
                defer { dispatchGroup.leave() }
                guard error == nil,
                      let observations = request.results as? [VNClassificationObservation] else {
                    return
                }

                let topObservations = observations
                    .filter { $0.confidence > 0.35 }
                    .prefix(10)

                for obs in topObservations {
                    let label = obs.identifier.replacingOccurrences(of: "_", with: " ")
                    keywords.append(label)
                    sceneLabels.append(label)
                    totalConfidence += Double(obs.confidence)
                }

                requestCount += 1
            }

            dispatchGroup.enter()
            let textRequest = VNRecognizeTextRequest { request, error in
                defer { dispatchGroup.leave() }
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    return
                }
                textDetected = true
                for obs in observations.prefix(3) {
                    if let topCandidate = obs.topCandidates(1).first {
                        keywords.append("文字: \(topCandidate.string)")
                    }
                }
                requestCount += 1
            }

            dispatchGroup.enter()
            let faceRequest = VNDetectFaceRectanglesRequest { request, error in
                defer { dispatchGroup.leave() }
                guard error == nil,
                      let observations = request.results as? [VNFaceObservation],
                      !observations.isEmpty else {
                    return
                }
                faceDetected = true
                keywords.append("人物")
                requestCount += 1
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([classifyRequest, textRequest, faceRequest])
                } catch {
                    print("[VisionImageAnalysis] Failed to perform request: \(error)")
                }

                dispatchGroup.notify(queue: .main) {
                    let avgConfidence = requestCount > 0 ? totalConfidence / Double(requestCount) : 0
                    continuation.resume(returning: ImageAnalysisResult(
                        keywords: keywords,
                        dominantColors: [],
                        sceneLabels: sceneLabels,
                        textDetected: textDetected,
                        faceDetected: faceDetected,
                        confidence: avgConfidence
                    ))
                }
            }
        }
    }

    private func loadImage(from locator: PhotoAssetLocator) async -> UIImage? {
        let key = locator.locatorKey

        if key.hasPrefix("library://") {
            let localId = String(key.dropFirst("library://".count))
            return await loadFromPhotoLibrary(identifier: localId)
        } else if key.hasPrefix("webdav://") || key.hasPrefix("file://") {
            // 支持 WebDAV 和 本地文件通过 MediaResolver 读取
            guard let mediaLocator = MediaLocator.parse(key) else { return nil }
            do {
                let resource = try await MediaResolver.shared.resolve(locator: mediaLocator)
                switch resource {
                case .data(let data):
                    return UIImage(data: data)
                case .url(let url):
                    return UIImage(contentsOfFile: url.path)
                case .phAsset(let asset):
                    // 理论上 library:// 已经处理，但为了兼容性保留
                    return await loadFromPHAsset(asset)
                }
            } catch {
                print("[VisionImageAnalysis] MediaResolver failed for \(key): \(error)")
                return nil
            }
        }
        return nil
    }

    private func loadFromPhotoLibrary(identifier: String) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        return await loadFromPHAsset(asset)
    }

    private func loadFromPHAsset(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1024, height: 1024),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func aggregateAndSortKeywords(_ keywords: [String], topN: Int) -> [String] {
        let normalized = keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let counts = Dictionary(grouping: normalized, by: { $0 })
            .mapValues { $0.count }
            .filter { $0.key.count > 1 && $0.key != "文字" }

        let sorted = counts.sorted { $0.value > $1.value }
        return Array(sorted.prefix(topN).map { $0.key })
    }

    private func generateSceneSummary(labels: [String], keywords: [String]) -> String {
        let uniqueLabels = Array(Set(labels)).prefix(5)
        if uniqueLabels.isEmpty {
            return keywords.prefix(3).joined(separator: "、")
        }
        return uniqueLabels.joined(separator: "、")
    }
}