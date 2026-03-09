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
    /// 面向文案生成的清洗后关键词（去机器味、可读性更高）
    let sanitizedKeywords: [String]
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
                sanitizedKeywords: [],
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
        let sanitizedKeywords = sanitizeKeywordsForDiary(topKeywords)
        let sceneSummary = generateSceneSummary(labels: allSceneLabels, keywords: sanitizedKeywords.isEmpty ? topKeywords : sanitizedKeywords)

        return AggregatedImageKeywords(
            topKeywords: topKeywords,
            sanitizedKeywords: sanitizedKeywords,
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
        let cleaned = keywords.compactMap { sanitizeVisionLabel($0) }
        let counts = Dictionary(grouping: cleaned, by: { $0 })
            .mapValues { $0.count }
            .filter { $0.key.count > 1 && $0.key != "文字" }

        let sorted = counts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        return Array(sorted.prefix(topN).map { $0.key })
    }

    /// 对 Vision 分类词做一层轻量清洗，避免把机器标签直接喂给文案生成。
    /// 规则：仅做归一化 + 黑名单过滤，不做中文硬映射。
    private func sanitizeVisionLabel(_ raw: String) -> String? {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        // 直接过滤掉机器感强、语义噪声大的词
        let blocked: Set<String> = [
            "tool", "tools",
            "seat", "seats"
        ]
        if blocked.contains(normalized) {
            return nil
        }

        return normalized
    }

    /// 针对回忆文案的二次清洗：进一步剔除通用机器词，并限制数量。
    private func sanitizeKeywordsForDiary(_ keywords: [String], maxCount: Int = 6) -> [String] {
        let blockedFragments = [
            "artifact", "equipment", "device", "appliance",
            "mechanism", "component", "material", "object"
        ]

        var result: [String] = []
        var seen = Set<String>()

        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if blockedFragments.contains(where: { trimmed.contains($0) }) { continue }
            if seen.contains(trimmed) { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count >= maxCount { break }
        }

        return result
    }

    private func generateSceneSummary(labels: [String], keywords: [String]) -> String {
        let uniqueLabels = Array(Set(labels.compactMap { sanitizeVisionLabel($0) })).prefix(5)
        if uniqueLabels.isEmpty {
            return keywords.prefix(3).joined(separator: "、")
        }
        return uniqueLabels.joined(separator: "、")
    }
}