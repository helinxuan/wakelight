import Foundation
import Photos
import Vision
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

        let groups = await groupImportedByScene(records: records)
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

    private func groupByScene(assets: [PHAsset]) async -> [AssetLikeGroup] {
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
                    mediaType: mediaType(for: $0)
                )
            }

        return await clusterBySceneAndFeaturePrint(items: items)
    }

    private func groupImportedByScene(records: [PhotoAsset]) async -> [AssetLikeGroup] {
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
                    mediaType: mediaType(for: record)
                )
            }

        return await clusterBySceneAndFeaturePrint(items: items)
    }

    private func clusterBySceneAndFeaturePrint(items: [AssetLikeItem]) async -> [AssetLikeGroup] {
        var groups: [AssetLikeGroup] = []
        var current: [AssetLikeItem] = []
        var currentFeaturePrints: [String: VNFeaturePrintObservation] = [:]

        for item in items {
            guard let last = current.last else {
                current = [item]
                if let fp = await featurePrintForItem(item: item) {
                    currentFeaturePrints[item.hashKey] = fp
                }
                continue
            }

            let shouldConsiderMerge = shouldMergeByMetadata(lhs: last, rhs: item)
            let merge: Bool

            if shouldConsiderMerge {
                merge = await shouldMergeByFeaturePrint(
                    candidate: item,
                    currentGroupItems: current,
                    currentFeaturePrints: &currentFeaturePrints
                )
            } else {
                merge = false
            }

            if merge {
                current.append(item)
            } else {
                groups.append(AssetLikeGroup(items: current))
                current = [item]
                currentFeaturePrints.removeAll(keepingCapacity: true)
                if let fp = await featurePrintForItem(item: item) {
                    currentFeaturePrints[item.hashKey] = fp
                }
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
        currentFeaturePrints: inout [String: VNFeaturePrintObservation]
    ) async -> Bool {
        guard let candidatePrint = await featurePrintForItem(item: candidate) else {
            return true
        }

        currentFeaturePrints[candidate.hashKey] = candidatePrint

        var minDistance = Float.greatestFiniteMagnitude

        for existing in currentGroupItems {
            let existingPrint: VNFeaturePrintObservation?
            if let cached = currentFeaturePrints[existing.hashKey] {
                existingPrint = cached
            } else {
                existingPrint = await featurePrintForItem(item: existing)
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

        let details = scored.map { item in
            let avgText = String(format: "%.2f", item.textAvgConfidence ?? 0)
            let maxText = String(format: "%.2f", item.textMaxConfidence ?? 0)
            let area = String(format: "%.4f", item.textAreaRatio)
            let shot = String(format: "%.2f", item.screenshotScore)
            let filename = debugFilename(for: item.item)
            let id = item.item.localIdentifier ?? item.item.photoAssetId?.uuidString ?? "-"
            return "file=\(filename) id=\(id) s=\(Int(item.score)) shot=\(shot) face=\(item.hasFace ? 1 : 0) txtAvg=\(avgText) txtMax=\(maxText) txtCnt=\(item.textCount) txtArea=\(area)"
        }.joined(separator: " | ")

        let deltaText = String(format: "%.2f", delta)
        let avgText = String(format: "%.2f", textSummary.avgConfidence ?? 0)
        let maxText = String(format: "%.2f", textSummary.maxConfidence ?? 0)
        let areaText = String(format: "%.4f", textSummary.totalAreaRatio)
        let shotText = String(format: "%.2f", textSummary.avgScreenshotScore)
        print("[Curation][\(label)] gid=\(groupId) cnt=\(scored.count) delta=\(deltaText) textAssets=\(textSummary.assetsWithText)/\(textSummary.assetCount) faceAssets=\(textSummary.assetsWithFace) avgShot=\(shotText) textCount=\(textSummary.totalCount) textAreaRatio=\(areaText) textAvgConfidence=\(avgText) textMaxConfidence=\(maxText) \(details)")
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

    private func featurePrintForItem(item: AssetLikeItem) async -> VNFeaturePrintObservation? {
        guard let image = await loadImage(item: item) else { return nil }
        return featurePrint(for: image)
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
        if let asset = item.phAsset {
            return await loadFromPHAsset(asset)
        }

        guard let locator = item.locator else { return nil }
        do {
            let resource = try await MediaResolver.shared.resolve(locator: locator)
            switch resource {
            case .data(let data):
                return UIImage(data: data)
            case .url(let url):
                return UIImage(contentsOfFile: url.path)
            case .phAsset(let asset):
                return await loadFromPHAsset(asset)
            }
        } catch {
            return nil
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

