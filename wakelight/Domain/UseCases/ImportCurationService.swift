import Foundation
import Photos
import Vision
import UIKit

actor ImportCurationService {
    static let shared = ImportCurationService()

    #if DEBUG
    private let curationDebugLogEnabled = true
    #else
    private let curationDebugLogEnabled = false
    #endif

    private let hashService: ImportPerceptualHashService
    private let scoringService: ImportBestShotScoringService
    private let textFilterService: ImportTextFilterService

    init(
        hashService: ImportPerceptualHashService = .shared,
        scoringService: ImportBestShotScoringService = .shared,
        textFilterService: ImportTextFilterService = .shared
    ) {
        self.hashService = hashService
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
        var results: [ImportAssetDecision] = []
        let total = assets.count
        var processed = 0

        await onProgress?(0, total)

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

            processed += group.count
            await onProgress?(min(processed, total), total)
        }

        return results
    }

    private func groupByScene(assets: [PHAsset]) async -> [[PHAsset]] {
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }

        var groups: [[PHAsset]] = []
        var current: [PHAsset] = []
        var currentHashes: [String: PerceptualHash] = [:]

        for asset in sorted {
            guard let last = current.last else {
                current = [asset]
                if let img = await loadImage(asset: asset),
                   let h = await hashService.hash(localIdentifier: asset.localIdentifier, image: img) {
                    currentHashes[asset.localIdentifier] = h
                }
                continue
            }

            let merge: Bool
            if shouldMergeByMetadata(lhs: last, rhs: asset) {
                if let lhsHash = currentHashes[last.localIdentifier],
                   let img = await loadImage(asset: asset),
                   let rhsHash = await hashService.hash(localIdentifier: asset.localIdentifier, image: img) {
                    let dist = lhsHash.hammingDistance(to: rhsHash)
                    merge = dist <= 10
                    if merge { currentHashes[asset.localIdentifier] = rhsHash }
                } else {
                    merge = true
                }
            } else {
                merge = false
            }

            if merge {
                current.append(asset)
            } else {
                groups.append(current)
                current = [asset]
                currentHashes.removeAll(keepingCapacity: true)
                if let img = await loadImage(asset: asset),
                   let h = await hashService.hash(localIdentifier: asset.localIdentifier, image: img) {
                    currentHashes[asset.localIdentifier] = h
                }
            }
        }

        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func shouldMergeByMetadata(lhs: PHAsset, rhs: PHAsset) -> Bool {
        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        let dt = abs(lhsDate.timeIntervalSince(rhsDate))
        if dt > 8 { return false }

        if let l = lhs.location?.coordinate, let r = rhs.location?.coordinate {
            let dx = l.latitude - r.latitude
            let dy = l.longitude - r.longitude
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
            let filename = debugFilename(for: item.asset)
            return "file=\(filename) id=\(item.asset.localIdentifier) s=\(Int(item.score)) shot=\(shot) face=\(item.hasFace ? 1 : 0) txtAvg=\(avgText) txtMax=\(maxText) txtCnt=\(item.textCount) txtArea=\(area)"
        }.joined(separator: " | ")

        let deltaText = String(format: "%.2f", delta)
        let avgText = String(format: "%.2f", textSummary.avgConfidence ?? 0)
        let maxText = String(format: "%.2f", textSummary.maxConfidence ?? 0)
        let areaText = String(format: "%.4f", textSummary.totalAreaRatio)
        let shotText = String(format: "%.2f", textSummary.avgScreenshotScore)
        print("[Curation][\(label)] gid=\(groupId) cnt=\(scored.count) delta=\(deltaText) textAssets=\(textSummary.assetsWithText)/\(textSummary.assetCount) faceAssets=\(textSummary.assetsWithFace) avgShot=\(shotText) textCount=\(textSummary.totalCount) textAreaRatio=\(areaText) textAvgConfidence=\(avgText) textMaxConfidence=\(maxText) \(details)")
    }

    private func debugFilename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let name = resources.first?.originalFilename, !name.isEmpty {
            return name
        }
        return "-"
    }

    private func score(group: [PHAsset]) async -> [ScoredAsset] {
        var scored: [ScoredAsset] = []
        scored.reserveCapacity(group.count)
        let groupId = makeGroupId(for: group)

        for asset in group {
            guard let image = await loadImage(asset: asset) else {
                scored.append(
                    ScoredAsset(asset: asset, groupId: groupId, score: 0, textAvgConfidence: nil, textMaxConfidence: nil, textCount: 0, textAreaRatio: 0, screenshotScore: 0, hasFace: false)
                )
                continue
            }

            let breakdown = await scoringService.score(asset: asset, image: image)
            scored.append(
                ScoredAsset(
                    asset: asset,
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

    private func makeGroupId(for group: [PHAsset]) -> String {
        guard let first = group.first else { return UUID().uuidString }
        let ts = Int((first.creationDate ?? .distantPast).timeIntervalSince1970)
        return "grp_\(ts)_\(first.localIdentifier.hashValue)"
    }

    private func loadImage(asset: PHAsset) async -> UIImage? {
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
}

private struct ScoredAsset {
    let asset: PHAsset
    let groupId: String
    let score: Double
    let textAvgConfidence: Double?
    let textMaxConfidence: Double?
    let textCount: Int
    let textAreaRatio: Double
    let screenshotScore: Double
    let hasFace: Bool

    func toDecision(bucket: ImportDecisionBucket, reason: ImportDecisionReason) -> ImportAssetDecision {
        ImportAssetDecision(
            localIdentifier: asset.localIdentifier,
            bucket: bucket,
            reason: reason,
            score: score,
            recognizedTextConfidence: textAvgConfidence,
            groupId: groupId
        )
    }
}
