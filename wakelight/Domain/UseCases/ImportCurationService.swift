import Foundation
import Photos
import Vision
import UIKit

actor ImportCurationService {
    static let shared = ImportCurationService()

    private let hashService: ImportPerceptualHashService
    private let scoringService: ImportBestShotScoringService

    init(
        hashService: ImportPerceptualHashService = .shared,
        scoringService: ImportBestShotScoringService = .shared
    ) {
        self.hashService = hashService
        self.scoringService = scoringService
    }

    func curate(assets: [PHAsset]) async -> [ImportAssetDecision] {
        guard !assets.isEmpty else { return [] }

        let groups = await groupByScene(assets: assets)
        var results: [ImportAssetDecision] = []

        for group in groups {
            let scored = await score(group: group)
            guard let best = scored.first else { continue }

            if scored.count == 1 {
                results.append(best.toDecision(bucket: .keep, reason: .autoKeep))
                continue
            }

            let second = scored.dropFirst().first
            let delta = best.score - (second?.score ?? 0)

            if best.textConfidence ?? 0 >= 0.92 {
                for item in scored {
                    results.append(item.toDecision(bucket: .archived, reason: .filteredTextHighConfidence))
                }
                continue
            }

            if best.textConfidence ?? 0 >= 0.85 {
                results.append(best.toDecision(bucket: .review, reason: .filteredTextPossible))
                for item in scored.dropFirst() {
                    results.append(item.toDecision(bucket: .archived, reason: .duplicateNearTime))
                }
                continue
            }

            if delta >= 8 {
                results.append(best.toDecision(bucket: .keep, reason: .autoKeep))
                for item in scored.dropFirst() {
                    results.append(item.toDecision(bucket: .archived, reason: .duplicateNearTime))
                }
            } else {
                for item in scored {
                    results.append(item.toDecision(bucket: .review, reason: .needsReview))
                }
            }
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

    private func score(group: [PHAsset]) async -> [ScoredAsset] {
        var scored: [ScoredAsset] = []
        scored.reserveCapacity(group.count)
        let groupId = makeGroupId(for: group)

        for asset in group {
            guard let image = await loadImage(asset: asset) else {
                scored.append(
                    ScoredAsset(asset: asset, groupId: groupId, score: 0, textConfidence: nil)
                )
                continue
            }

            let breakdown = await scoringService.score(asset: asset, image: image)
            scored.append(
                ScoredAsset(
                    asset: asset,
                    groupId: groupId,
                    score: breakdown.total,
                    textConfidence: breakdown.recognizedTextConfidence
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
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
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
    let textConfidence: Double?

    func toDecision(bucket: ImportDecisionBucket, reason: ImportDecisionReason) -> ImportAssetDecision {
        ImportAssetDecision(
            localIdentifier: asset.localIdentifier,
            bucket: bucket,
            reason: reason,
            score: score,
            recognizedTextConfidence: textConfidence,
            groupId: groupId
        )
    }
}
