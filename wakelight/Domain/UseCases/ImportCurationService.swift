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
    private let perceptualHashService: ImportPerceptualHashService

    private let featurePrintDistanceThreshold: Float = 0.7
    private let featurePrintTimeoutSeconds: Double = 6
    private let coarseTimeWindowSeconds: Double = 4
    private let coarseDistanceMeters: Double = 50
    private let fusedPHashWeight: Double = 0.45
    private let fusedFeaturePrintWeight: Double = 0.55
    private let dbscanEpsilon: Double = 0.82
    private let dbscanMinPoints: Int = 2

    // 调试统计：用于观察整理阶段缩略图命中率。
    private var debugThumbHitCount: Int = 0
    private var debugFallbackOriginCount: Int = 0
    private var debugFallbackFailCount: Int = 0
    private var debugLoadAttemptCount: Int = 0
    private var debugFeaturePrintBeginCount: Int = 0
    private var debugDecisionCount: Int = 0

    init(
        scoringService: ImportBestShotScoringService = .shared,
        textFilterService: ImportTextFilterService = .shared,
        perceptualHashService: ImportPerceptualHashService = .shared
    ) {
        self.scoringService = scoringService
        self.textFilterService = textFilterService
        self.perceptualHashService = perceptualHashService
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

        return await clusterByThreeStagePipeline(items: items, onProgress: onGroupingProgress)
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

        return await clusterByThreeStagePipeline(items: items, onProgress: onGroupingProgress)
    }

    private func clusterByThreeStagePipeline(
        items: [AssetLikeItem],
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async -> [AssetLikeGroup] {
        guard !items.isEmpty else {
            await onProgress?(0, 0)
            return []
        }

        // 第一层：时间/GPS 粗分组（必须快）
        let coarseGroups = buildCoarseGroups(items: items)

        // 第二层：仅在粗组内计算 pHash + FeaturePrint。
        var featurePrintCache: [String: VNFeaturePrintObservation] = [:]
        var pHashCache: [String: PerceptualHash] = [:]

        var groups: [AssetLikeGroup] = []
        let total = items.count
        var processed = 0
        await onProgress?(0, total)

        for coarse in coarseGroups {
            let clusters = await clusterWithinCoarseGroup(
                coarse,
                featurePrintCache: &featurePrintCache,
                pHashCache: &pHashCache
            )

            for cluster in clusters where !cluster.isEmpty {
                groups.append(AssetLikeGroup(items: cluster))
            }

            processed += coarse.count
            await onProgress?(min(processed, total), total)
        }

        return groups
    }

    private func buildCoarseGroups(items: [AssetLikeItem]) -> [[AssetLikeItem]] {
        var buckets: [String: [AssetLikeItem]] = [:]
        buckets.reserveCapacity(max(1, items.count / 2))

        for item in items {
            let date = item.creationDate ?? .distantPast
            let timeBucket = Int((date.timeIntervalSince1970 / coarseTimeWindowSeconds).rounded(.down))

            if let lat = item.latitude, let lon = item.longitude {
                let cellSizeDegrees = metersToLatitudeDegrees(coarseDistanceMeters)
                let (latIdx, lonIdx) = GeoGrid.bucketIndices(
                    latitude: lat,
                    longitude: lon,
                    precisionDegrees: cellSizeDegrees
                )

                for dt in -1...1 {
                    for dLat in -1...1 {
                        for dLon in -1...1 {
                            let key = "t\(timeBucket + dt)|\(latIdx + dLat)_\(lonIdx + dLon)"
                            buckets[key, default: []].append(item)
                        }
                    }
                }
            } else {
                for dt in -1...1 {
                    let key = "t\(timeBucket + dt)|nogps"
                    buckets[key, default: []].append(item)
                }
            }
        }

        var seen = Set<String>()
        var groups: [[AssetLikeItem]] = []
        groups.reserveCapacity(buckets.count)

        let sortedKeys = buckets.keys.sorted()
        for key in sortedKeys {
            guard let candidates = buckets[key], !candidates.isEmpty else { continue }
            let unique = candidates.filter { seen.insert($0.hashKey).inserted }
            if !unique.isEmpty {
                groups.append(unique.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) })
            }
        }

        return groups
    }

    private func clusterWithinCoarseGroup(
        _ items: [AssetLikeItem],
        featurePrintCache: inout [String: VNFeaturePrintObservation],
        pHashCache: inout [String: PerceptualHash]
    ) async -> [[AssetLikeItem]] {
        if items.count <= 1 {
            return [items]
        }

        var vectors = Array<SimilarityVector?>(repeating: nil, count: items.count)
        var photoIndices: [Int] = []
        var videoIndices: [Int] = []

        for (idx, item) in items.enumerated() {
            if item.mediaType == .video {
                videoIndices.append(idx)
                continue
            }

            guard let image = await loadImage(item: item) else {
                videoIndices.append(idx)
                continue
            }

            let pHash: PerceptualHash?
            if let cached = pHashCache[item.hashKey] {
                pHash = cached
            } else if let localIdentifier = item.localIdentifier {
                let computed = await perceptualHashService.hash(cacheKey: localIdentifier, image: image)
                if let computed {
                    pHashCache[item.hashKey] = computed
                }
                pHash = computed
            } else {
                pHash = nil
            }

            let featurePrint = await featurePrintForItem(item: item, cache: &featurePrintCache)
            vectors[idx] = SimilarityVector(featurePrint: featurePrint, pHash: pHash)
            photoIndices.append(idx)
        }

        var neighborTable: [[Int]] = Array(repeating: [], count: items.count)
        for i in photoIndices {
            for j in photoIndices where j > i {
                let distance = fusedDistance(vectors[i], vectors[j])
                if distance <= dbscanEpsilon {
                    neighborTable[i].append(j)
                    neighborTable[j].append(i)
                }
            }
        }

        let (clustersByIndex, noiseByIndex) = dbscan(
            indices: photoIndices,
            neighbors: neighborTable,
            minPoints: dbscanMinPoints
        )

        var output: [[AssetLikeItem]] = clustersByIndex.map { cluster in
            cluster.map { items[$0] }
        }

        if !noiseByIndex.isEmpty {
            output.append(noiseByIndex.map { items[$0] })
        }

        for vid in videoIndices {
            output.append([items[vid]])
        }

        return output
    }

    private func dbscan(
        indices: [Int],
        neighbors: [[Int]],
        minPoints: Int
    ) -> (clusters: [[Int]], noise: [Int]) {
        guard !indices.isEmpty else { return ([], []) }

        var visited = Set<Int>()
        var assigned = Set<Int>()
        var clusters: [[Int]] = []
        var noise: [Int] = []

        for point in indices {
            if visited.contains(point) { continue }
            visited.insert(point)

            let pointNeighbors = neighbors[point]
            if pointNeighbors.count + 1 < minPoints {
                noise.append(point)
                continue
            }

            var cluster: [Int] = [point]
            assigned.insert(point)
            var seeds = pointNeighbors
            var seedCursor = 0

            while seedCursor < seeds.count {
                let candidate = seeds[seedCursor]

                if !visited.contains(candidate) {
                    visited.insert(candidate)
                    let candidateNeighbors = neighbors[candidate]
                    if candidateNeighbors.count + 1 >= minPoints {
                        for neighbor in candidateNeighbors where !seeds.contains(neighbor) {
                            seeds.append(neighbor)
                        }
                    }
                }

                if !assigned.contains(candidate) {
                    assigned.insert(candidate)
                    cluster.append(candidate)
                }

                seedCursor += 1
            }

            clusters.append(cluster)
        }

        let noiseSet = Set(noise).subtracting(assigned)
        return (clusters, Array(noiseSet).sorted())
    }

    private func fusedDistance(_ lhs: SimilarityVector?, _ rhs: SimilarityVector?) -> Double {
        guard let lhs, let rhs else { return 1.0 }

        let pHashDistance: Double = {
            guard let leftHash = lhs.pHash, let rightHash = rhs.pHash else { return 1.0 }
            let raw = leftHash.hammingDistance(to: rightHash)
            return min(1.0, max(0.0, Double(raw) / 64.0))
        }()

        let fpDistance: Double = {
            guard let leftFP = lhs.featurePrint, let rightFP = rhs.featurePrint,
                  let raw = featurePrintDistance(from: leftFP, to: rightFP) else {
                return 1.0
            }
            return min(1.0, max(0.0, Double(raw / featurePrintDistanceThreshold)))
        }()

        return fusedPHashWeight * pHashDistance + fusedFeaturePrintWeight * fpDistance
    }

    private func metersToLatitudeDegrees(_ meters: Double) -> Double {
        // 1° 纬度约 111_320 米
        max(0.00001, meters / 111_320.0)
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

private struct SimilarityVector {
    let featurePrint: VNFeaturePrintObservation?
    let pHash: PerceptualHash?
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

