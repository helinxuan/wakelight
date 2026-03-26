import Foundation
import Photos
import Vision
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import GRDB

actor ImportCurationService {
    static let shared = ImportCurationService()

    #if DEBUG
    private let curationDebugLogEnabled = true
    #else
    private let curationDebugLogEnabled = false
    #endif

    private let scoringService: ImportBestShotScoringService
    private let textFilterService: ImportTextFilterService

    private let featurePrintDistanceThreshold: Float = 0.7
    private let featurePrintTimeoutSeconds: Double = 6

    // 调试统计：用于观察整理阶段缩略图命中率。
    private var debugThumbHitCount: Int = 0
    private var debugFallbackOriginCount: Int = 0
    private var debugFallbackFailCount: Int = 0
    private var debugLoadAttemptCount: Int = 0
    private var debugFeaturePrintBeginCount: Int = 0
    private var debugDecisionCount: Int = 0

    init(
        scoringService: ImportBestShotScoringService = .shared,
        textFilterService: ImportTextFilterService = .shared
    ) {
        self.scoringService = scoringService
        self.textFilterService = textFilterService
    }

    func curate(
        assets: [PHAsset],
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [ImportAssetDecision] {
        guard !assets.isEmpty else {
            await onProgress?(0, 0)
            return []
        }

        let groups = await groupByScene(assets: assets)
        let decisions = await evaluate(groups: groups, totalCount: assets.count, onProgress: onProgress)
        return decisions.map {
            ImportAssetDecision(
                photoAssetId: nil,
                localIdentifier: $0.localIdentifier,
                bucket: $0.bucket,
                reason: $0.reason,
                score: $0.score,
                recognizedTextConfidence: $0.recognizedTextConfidence,
                groupId: $0.groupId
            )
        }
    }

    func curateImportedPhotos(
        records: [PhotoAsset],
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [ImportAssetDecision] {
        guard !records.isEmpty else {
            await onProgress?(0, 0)
            return []
        }

        // 先上报总量，避免分组阶段较慢时 UI 一直显示 0/0。
        await onProgress?(0, records.count)

        // 重置本次调试统计
        debugThumbHitCount = 0
        debugFallbackOriginCount = 0
        debugFallbackFailCount = 0
        debugLoadAttemptCount = 0

        debugFeaturePrintBeginCount = 0
        debugDecisionCount = 0

        if curationDebugLogEnabled {
            print("[Curation] curateImportedPhotos begin total=\(records.count)")
            print("[Curation][ThumbStats] begin hit=0 fallback=0 fail=0")
        }

        let t0 = Date()
        let groups = await groupImportedByScene(records: records) { processed, total in
            await onProgress?(processed, total)
            if self.curationDebugLogEnabled && (processed == 0 || processed % 50 == 0 || processed == total) {
                print("[Curation][GroupingProgress] \(processed)/\(total)")
            }
        }
        if curationDebugLogEnabled {
            let elapsed = Date().timeIntervalSince(t0)
            let hitRate = debugLoadAttemptCount > 0 ? (Double(debugThumbHitCount) / Double(debugLoadAttemptCount) * 100.0) : 0
            print("[Curation] grouping done groups=\(groups.count) elapsed=\(String(format: "%.2f", elapsed))s")
            print("[Curation][ThumbStats] done attempts=\(debugLoadAttemptCount) hit=\(debugThumbHitCount) fallback=\(debugFallbackOriginCount) fail=\(debugFallbackFailCount) hitRate=\(String(format: "%.1f", hitRate))%")
        }

        let decisions = await evaluate(groups: groups, totalCount: records.count, onProgress: onProgress)
        return decisions.map {
            ImportAssetDecision(
                photoAssetId: $0.photoAssetId,
                localIdentifier: $0.localIdentifier,
                bucket: $0.bucket,
                reason: $0.reason,
                score: $0.score,
                recognizedTextConfidence: $0.recognizedTextConfidence,
                groupId: $0.groupId
            )
        }
    }

    private func evaluate(
        groups: [AssetLikeGroup],
        totalCount: Int,
        onProgress: (@Sendable (Int, Int) async -> Void)?
    ) async -> [DecisionDraft] {
        var results: [DecisionDraft] = []
        var processed = 0

        await onProgress?(0, totalCount)

        for group in groups {
            let scored = await score(group: group)
            guard let best = scored.first else { continue }

            let second = scored.dropFirst().first
            let delta = best.score - (second?.score ?? 0)
            let textEvidence = scored.map {
                TextFilterEvidence(
                    avgConfidence: $0.textAvgConfidence,
                    maxConfidence: $0.textMaxConfidence,
                    textCount: $0.textCount,
                    textAreaRatio: $0.textAreaRatio,
                    screenshotScore: $0.screenshotScore,
                    hasFace: $0.hasFace
                )
            }
            let textDecision = await textFilterService.evaluate(group: textEvidence)

            if let archiveReason = textDecision.archiveReason {
                debugLogDecision(groupId: best.groupId, label: textDecision.debugLabel, scored: scored, delta: delta, textSummary: textDecision.summary)
                for item in scored {
                    results.append(item.toDecision(bucket: .archived, reason: archiveReason))
                }
            } else if scored.count == 1 {
                debugLogDecision(groupId: best.groupId, label: "KEEP_SINGLE", scored: scored, delta: delta, textSummary: textDecision.summary)
                results.append(best.toDecision(bucket: .keep, reason: .autoKeep))
            } else if delta >= 8 {
                debugLogDecision(groupId: best.groupId, label: "KEEP_PLUS_DUP", scored: scored, delta: delta, textSummary: textDecision.summary)
                results.append(best.toDecision(bucket: .keep, reason: .autoKeep))
                for item in scored.dropFirst() {
                    results.append(item.toDecision(bucket: .archived, reason: .duplicateNearTime))
                }
            } else {
                debugLogDecision(groupId: best.groupId, label: "REVIEW", scored: scored, delta: delta, textSummary: textDecision.summary)
                for item in scored {
                    results.append(item.toDecision(bucket: .review, reason: .needsReview))
                }
            }

            processed += group.items.count
            await onProgress?(min(processed, totalCount), totalCount)
        }

        return results
    }

    private func groupByScene(
        assets: [PHAsset],
        onGroupingProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [AssetLikeGroup] {
        let items = assets
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            .map {
                AssetLikeItem(
                    photoAssetId: nil,
                    localIdentifier: $0.localIdentifier,
                    creationDate: $0.creationDate,
                    latitude: $0.location?.coordinate.latitude,
                    longitude: $0.location?.coordinate.longitude,
                    phAsset: $0,
                    locator: nil,
                    thumbnailPath: nil,
                    mediaType: mediaType(for: $0)
                )
            }

        return await clusterBySceneAndFeaturePrint(items: items, onProgress: onGroupingProgress)
    }

    private func groupImportedByScene(
        records: [PhotoAsset],
        onGroupingProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [AssetLikeGroup] {
        let items = records
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            .map { record in
                AssetLikeItem(
                    photoAssetId: record.id,
                    localIdentifier: record.localIdentifier,
                    creationDate: record.creationDate,
                    latitude: record.latitude,
                    longitude: record.longitude,
                    phAsset: nil,
                    locator: buildLocator(record: record),
                    thumbnailPath: record.thumbnailPath,
                    mediaType: mediaType(for: record)
                )
            }

        return await clusterBySceneAndFeaturePrint(items: items, onProgress: onGroupingProgress)
    }

    private func clusterBySceneAndFeaturePrint(
        items: [AssetLikeItem],
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [AssetLikeGroup] {
        var groups: [AssetLikeGroup] = []
        var current: [AssetLikeItem] = []
        var currentFeaturePrints: [String: VNFeaturePrintObservation] = [:]
        // A: 全局缓存，避免跨组重复计算同一素材的 feature print。
        var featurePrintCache: [String: VNFeaturePrintObservation] = [:]

        let total = items.count
        var processed = 0
        await onProgress?(0, total)

        for item in items {
            defer {
                processed += 1
            }

            guard let last = current.last else {
                current = [item]
                if let fp = await featurePrintForItem(item: item, cache: &featurePrintCache) {
                    currentFeaturePrints[item.hashKey] = fp
                }

                if processed == 0 || processed % 20 == 0 || processed + 1 == total {
                    await onProgress?(min(processed + 1, total), total)
                }
                continue
            }

            let shouldConsiderMerge = shouldMergeByMetadata(lhs: last, rhs: item)
            let merge: Bool

            if shouldConsiderMerge {
                // C: 先做轻量门控，降低 feature print 触发频率。
                // 若时间非常接近且坐标非常接近，直接认为同组，跳过昂贵视觉特征。
                let dt = abs((last.creationDate ?? .distantPast).timeIntervalSince(item.creationDate ?? .distantPast))
                let nearTime = dt <= 1.2
                let nearLocation: Bool = {
                    if let lLat = last.latitude, let lLon = last.longitude,
                       let rLat = item.latitude, let rLon = item.longitude {
                        let dx = lLat - rLat
                        let dy = lLon - rLon
                        let d2 = dx * dx + dy * dy
                        return d2 <= 0.0000002
                    }
                    return false
                }()

                if nearTime && (nearLocation || last.mediaType == .video || item.mediaType == .video) {
                    merge = true
                } else {
                    merge = await shouldMergeByFeaturePrint(
                        candidate: item,
                        currentGroupItems: current,
                        currentFeaturePrints: &currentFeaturePrints,
                        featurePrintCache: &featurePrintCache
                    )
                }
            } else {
                merge = false
            }

            if merge {
                current.append(item)
            } else {
                groups.append(AssetLikeGroup(items: current))
                current = [item]
                currentFeaturePrints.removeAll(keepingCapacity: true)
                if let fp = await featurePrintForItem(item: item, cache: &featurePrintCache) {
                    currentFeaturePrints[item.hashKey] = fp
                }
            }

            if processed == 0 || processed % 20 == 0 || processed + 1 == total {
                await onProgress?(min(processed + 1, total), total)
            }
        }

        if !current.isEmpty {
            groups.append(AssetLikeGroup(items: current))
        }

        return groups
    }

    private func shouldMergeByFeaturePrint(
        candidate: AssetLikeItem,
        currentGroupItems: [AssetLikeItem],
        currentFeaturePrints: inout [String: VNFeaturePrintObservation],
        featurePrintCache: inout [String: VNFeaturePrintObservation]
    ) async -> Bool {
        // B: 视频降级——分组阶段不做视频 feature print，交给元数据规则处理。
        if candidate.mediaType == .video {
            return true
        }

        guard let candidatePrint = await featurePrintForItem(item: candidate, cache: &featurePrintCache) else {
            return true
        }

        currentFeaturePrints[candidate.hashKey] = candidatePrint

        var minDistance = Float.greatestFiniteMagnitude

        for existing in currentGroupItems {
            let existingPrint: VNFeaturePrintObservation?
            if let cached = currentFeaturePrints[existing.hashKey] {
                existingPrint = cached
            } else {
                // B: 对比项若是视频，也跳过 feature print。
                if existing.mediaType == .video {
                    continue
                }

                existingPrint = await featurePrintForItem(item: existing, cache: &featurePrintCache)
                if let existingPrint {
                    currentFeaturePrints[existing.hashKey] = existingPrint
                }
            }

            guard let existingPrint,
                  let distance = featurePrintDistance(from: candidatePrint, to: existingPrint) else {
                continue
            }

            minDistance = min(minDistance, distance)
            if distance <= featurePrintDistanceThreshold {
                return true
            }
        }

        return minDistance.isFinite ? minDistance <= featurePrintDistanceThreshold : true
    }

    private func shouldMergeByMetadata(lhs: AssetLikeItem, rhs: AssetLikeItem) -> Bool {
        if lhs.mediaType != rhs.mediaType { return false }

        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        let dt = abs(lhsDate.timeIntervalSince(rhsDate))
        if dt > 8 { return false }

        if let lLat = lhs.latitude, let lLon = lhs.longitude, let rLat = rhs.latitude, let rLon = rhs.longitude {
            let dx = lLat - rLat
            let dy = lLon - rLon
            let d2 = dx * dx + dy * dy
            return d2 <= 0.000001
        }

        return true
    }

    private func debugLogDecision(groupId: String, label: String, scored: [ScoredAsset], delta: Double, textSummary: GroupTextSummary) {
        guard curationDebugLogEnabled else { return }

        debugDecisionCount += 1
        // 仅采样打印，避免大量 SQL(debugDescription) 噪音刷屏。
        guard debugDecisionCount <= 5 || debugDecisionCount % 20 == 0 else { return }

        let deltaText = String(format: "%.2f", delta)
        let avgText = String(format: "%.2f", textSummary.avgConfidence ?? 0)
        let maxText = String(format: "%.2f", textSummary.maxConfidence ?? 0)
        let areaText = String(format: "%.4f", textSummary.totalAreaRatio)
        let shotText = String(format: "%.2f", textSummary.avgScreenshotScore)

        let topFiles = scored.prefix(3).map { item in
            let filename = debugFilename(for: item.item)
            let id = item.item.localIdentifier ?? item.item.photoAssetId?.uuidString ?? "-"
            return "\(filename)#\(id)"
        }.joined(separator: ",")

        print("[Curation][\(label)] #\(debugDecisionCount) gid=\(groupId) cnt=\(scored.count) delta=\(deltaText) textAssets=\(textSummary.assetsWithText)/\(textSummary.assetCount) faceAssets=\(textSummary.assetsWithFace) avgShot=\(shotText) textCount=\(textSummary.totalCount) textAreaRatio=\(areaText) textAvgConfidence=\(avgText) textMaxConfidence=\(maxText) samples=\(topFiles)")
    }

    private func debugFilename(for item: AssetLikeItem) -> String {
        if let asset = item.phAsset {
            let resources = PHAssetResource.assetResources(for: asset)
            if let name = resources.first?.originalFilename, !name.isEmpty {
                return name
            }
        }

        if let locator = item.locator {
            switch locator {
            case .library(let localId):
                return localId
            case .file(let url):
                return url.lastPathComponent
            case .webdav(_, let remotePath):
                return (remotePath as NSString).lastPathComponent
            }
        }

        return item.photoAssetId?.uuidString ?? "-"
    }

    private func mediaType(for record: PhotoAsset) -> PhotoAsset.MediaType {
        if let mediaType = record.mediaType {
            return mediaType
        }
        return .photo
    }

    private func mediaType(for asset: PHAsset) -> PhotoAsset.MediaType {
        switch asset.mediaType {
        case .video:
            return .video
        default:
            return .photo
        }
    }

    private func score(group: AssetLikeGroup) async -> [ScoredAsset] {
        var scored: [ScoredAsset] = []
        scored.reserveCapacity(group.items.count)
        let groupId = makeGroupId(for: group)

        for item in group.items {
            guard let image = await loadImage(item: item) else {
                scored.append(
                    ScoredAsset(item: item, groupId: groupId, score: 0, textAvgConfidence: nil, textMaxConfidence: nil, textCount: 0, textAreaRatio: 0, screenshotScore: 0, hasFace: false)
                )
                continue
            }

            let breakdown = await scoringService.score(image: image)
            scored.append(
                ScoredAsset(
                    item: item,
                    groupId: groupId,
                    score: breakdown.total,
                    textAvgConfidence: breakdown.recognizedTextConfidence,
                    textMaxConfidence: breakdown.recognizedTextMaxConfidence,
                    textCount: breakdown.recognizedTextCount,
                    textAreaRatio: breakdown.recognizedTextAreaRatio,
                    screenshotScore: breakdown.sceneScreenshotScore,
                    hasFace: breakdown.hasFace
                )
            )
        }

        return scored.sorted { $0.score > $1.score }
    }

    private func makeGroupId(for group: AssetLikeGroup) -> String {
        guard let first = group.items.first else { return UUID().uuidString }
        let ts = Int((first.creationDate ?? .distantPast).timeIntervalSince1970)
        return "grp_\(ts)_\(first.hashKey.hashValue)"
    }

    private func featurePrintForItem(
        item: AssetLikeItem,
        cache: inout [String: VNFeaturePrintObservation]
    ) async -> VNFeaturePrintObservation? {
        if let cached = cache[item.hashKey] {
            return cached
        }

        if curationDebugLogEnabled {
            debugFeaturePrintBeginCount += 1
            if debugFeaturePrintBeginCount <= 10 || debugFeaturePrintBeginCount % 100 == 0 {
                let id = item.localIdentifier ?? item.photoAssetId?.uuidString ?? "-"
                let name = debugFilename(for: item)
                print("[Curation][FeaturePrint] begin#\(debugFeaturePrintBeginCount) id=\(id) file=\(name)")
            }
        }

        let result = await withTaskGroup(of: VNFeaturePrintObservation?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                guard let image = await self.loadImage(item: item) else { return nil }
                return await self.featurePrint(for: image)
            }

            group.addTask { [timeout = featurePrintTimeoutSeconds] in
                let nanos = UInt64(max(0.1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()

            if self.curationDebugLogEnabled, first == nil {
                let id = item.localIdentifier ?? item.photoAssetId?.uuidString ?? "-"
                let name = self.debugFilename(for: item)
                print("[Curation][FeaturePrint] timeout-or-failed id=\(id) file=\(name)")
            }

            return first
        }

        if let result {
            cache[item.hashKey] = result
        }
        return result
    }

    private func featurePrint(for image: UIImage) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgImagePropertyOrientation(from: image.imageOrientation), options: [:])

        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    private func featurePrintDistance(from lhs: VNFeaturePrintObservation, to rhs: VNFeaturePrintObservation) -> Float? {
        var distance = Float.zero
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return distance
        } catch {
            return nil
        }
    }

    private func cgImagePropertyOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private func loadImage(item: AssetLikeItem) async -> UIImage? {
        debugLoadAttemptCount += 1

        // 先走已缓存缩略图，减少整理阶段对原图/远端资源的解码与拉取。
        if let thumbnailPath = item.thumbnailPath,
           !thumbnailPath.isEmpty,
           FileManager.default.fileExists(atPath: thumbnailPath),
           let thumb = UIImage(contentsOfFile: thumbnailPath) {
            debugThumbHitCount += 1
            debugLogThumbStatsIfNeeded()
            return thumb
        }

        debugFallbackOriginCount += 1

        if let asset = item.phAsset {
            let image = await loadFromPHAsset(asset)
            if image == nil {
                debugFallbackFailCount += 1
            }
            debugLogThumbStatsIfNeeded()
            return image
        }

        guard let locator = item.locator else {
            debugFallbackFailCount += 1
            debugLogThumbStatsIfNeeded()
            return nil
        }

        do {
            let resource = try await MediaResolver.shared.resolve(locator: locator)

            if item.mediaType == .video {
                let image = try await loadVideoPreview(from: resource)
                if image == nil {
                    debugFallbackFailCount += 1
                }
                debugLogThumbStatsIfNeeded()
                return image
            }

            let image: UIImage?
            switch resource {
            case .data(let data):
                image = UIImage(data: data)
            case .url(let url):
                image = UIImage(contentsOfFile: url.path)
                if shouldCleanupTemporaryURL(url) {
                    try? FileManager.default.removeItem(at: url)
                }
            case .phAsset(let asset):
                image = await loadFromPHAsset(asset)
            }

            if image == nil {
                debugFallbackFailCount += 1
            }
            debugLogThumbStatsIfNeeded()
            return image
        } catch {
            debugFallbackFailCount += 1
            debugLogThumbStatsIfNeeded()
            return nil
        }
    }

    private func loadVideoPreview(from resource: MediaResource) async throws -> UIImage? {
        let avAsset: AVAsset
        var temporaryURL: URL?

        switch resource {
        case .data(let data):
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            try data.write(to: tempURL)
            temporaryURL = tempURL
            avAsset = AVURLAsset(url: tempURL)
        case .url(let url):
            avAsset = AVURLAsset(url: url)
        case .phAsset(let asset):
            avAsset = try await requestAVAsset(for: asset)
        }

        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let duration = try await avAsset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let snapshotTime = durationSeconds.isFinite && durationSeconds > 0
            ? CMTime(seconds: max(0.05, durationSeconds / 2.0), preferredTimescale: 600)
            : CMTime(seconds: 0.05, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)

        let (cgImage, _) = try await generator.image(at: snapshotTime)
        return UIImage(cgImage: cgImage)
    }

    private func requestAVAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: NSError(domain: "ImportCurationService", code: -7, userInfo: [NSLocalizedDescriptionKey: "AVAsset request failed"]))
                }
            }
        }
    }

    private func loadFromPHAsset(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
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

    private func debugLogThumbStatsIfNeeded() {
        guard curationDebugLogEnabled else { return }
        guard debugLoadAttemptCount > 0 else { return }
        guard debugLoadAttemptCount % 500 == 0 else { return }

        let hitRate = Double(debugThumbHitCount) / Double(debugLoadAttemptCount) * 100.0
        print("[Curation][ThumbStats] progress attempts=\(debugLoadAttemptCount) hit=\(debugThumbHitCount) fallback=\(debugFallbackOriginCount) fail=\(debugFallbackFailCount) hitRate=\(String(format: "%.1f", hitRate))%")
    }

    private func shouldCleanupTemporaryURL(_ url: URL) -> Bool {
        let tmpDir = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target.hasPrefix(tmpDir)
    }

    private func buildLocator(record: PhotoAsset) -> MediaLocator? {
        if let localIdentifier = record.localIdentifier, !localIdentifier.isEmpty {
            return .library(localIdentifier: localIdentifier)
        }

        do {
            return try DatabaseContainer.shared.db.reader.read { db in
                guard let remote = try RemoteMediaAsset
                    .filter(Column("photoAssetId") == record.id)
                    .fetchOne(db) else {
                    return nil
                }
                return .webdav(profileId: remote.profileId.uuidString, remotePath: remote.remotePath)
            }
        } catch {
            return nil
        }
    }
}

private struct AssetLikeGroup {
    let items: [AssetLikeItem]
}

private struct AssetLikeItem {
    let photoAssetId: UUID?
    let localIdentifier: String?
    let creationDate: Date?
    let latitude: Double?
    let longitude: Double?
    let phAsset: PHAsset?
    let locator: MediaLocator?
    let thumbnailPath: String?
    let mediaType: PhotoAsset.MediaType

    var hashKey: String {
        if let localIdentifier, !localIdentifier.isEmpty {
            return "library://\(localIdentifier)"
        }
        if let photoAssetId {
            return "photo://\(photoAssetId.uuidString)"
        }
        if let locator {
            return locator.stableKey
        }
        return UUID().uuidString
    }
}

private struct ScoredAsset {
    let item: AssetLikeItem
    let groupId: String
    let score: Double
    let textAvgConfidence: Double?
    let textMaxConfidence: Double?
    let textCount: Int
    let textAreaRatio: Double
    let screenshotScore: Double
    let hasFace: Bool

    func toDecision(bucket: ImportDecisionBucket, reason: ImportDecisionReason) -> DecisionDraft {
        DecisionDraft(
            photoAssetId: item.photoAssetId,
            localIdentifier: item.localIdentifier,
            bucket: bucket,
            reason: reason,
            score: score,
            recognizedTextConfidence: textAvgConfidence,
            groupId: groupId
        )
    }
}

private struct DecisionDraft {
    let photoAssetId: UUID?
    let localIdentifier: String?
    let bucket: ImportDecisionBucket
    let reason: ImportDecisionReason
    let score: Double
    let recognizedTextConfidence: Double?
    let groupId: String?
}

