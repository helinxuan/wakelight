import Foundation

struct GroupTextSummary: Sendable {
    let totalCount: Int
    let totalAreaRatio: Double
    let avgConfidence: Double?
    let maxConfidence: Double?
    let assetsWithText: Int
    let assetCount: Int
    let avgScreenshotScore: Double
    let assetsWithFace: Int
}

struct GroupTextDecision: Sendable {
    let archiveReason: ImportDecisionReason?
    let debugLabel: String
    let summary: GroupTextSummary
}

struct TextFilterEvidence: Sendable {
    let avgConfidence: Double?
    let maxConfidence: Double?
    let textCount: Int
    let textAreaRatio: Double
    let screenshotScore: Double
    let hasFace: Bool
}

actor ImportTextFilterService {
    static let shared = ImportTextFilterService()

    private let highConfidenceThreshold: Double = 0.90
    private let possibleConfidenceThreshold: Double = 0.75
    private let minTextCount: Int = 3
    private let minTextAreaRatio: Double = 0.02
    private let minAssetsWithText: Int = 2
    private let minPerAssetTextCount: Int = 2
    private let minPerAssetTextAreaRatio: Double = 0.01

    private init() {}

    func evaluate(group: [TextFilterEvidence]) -> GroupTextDecision {
        let totalCount = group.reduce(0) { $0 + $1.textCount }
        let totalAreaRatio = group.reduce(0) { $0 + $1.textAreaRatio }
        let assetsWithText = group.reduce(0) {
            $0 + (($1.textCount >= minPerAssetTextCount && $1.textAreaRatio >= minPerAssetTextAreaRatio) ? 1 : 0)
        }
        let assetCount = group.count
        let assetsWithFace = group.reduce(0) { $0 + ($1.hasFace ? 1 : 0) }
        let avgScreenshotScore = assetCount > 0
            ? group.reduce(0) { $0 + $1.screenshotScore } / Double(assetCount)
            : 0

        let avgConfidences = group.compactMap(\.avgConfidence)
        let maxConfidences = group.compactMap(\.maxConfidence)

        let avgConfidence = avgConfidences.isEmpty ? nil : avgConfidences.reduce(0, +) / Double(avgConfidences.count)
        let maxConfidence = maxConfidences.max()

        let summary = GroupTextSummary(
            totalCount: totalCount,
            totalAreaRatio: totalAreaRatio,
            avgConfidence: avgConfidence,
            maxConfidence: maxConfidence,
            assetsWithText: assetsWithText,
            assetCount: assetCount,
            avgScreenshotScore: avgScreenshotScore,
            assetsWithFace: assetsWithFace
        )

        let enoughTextEvidenceForGroup = totalCount >= minTextCount &&
            totalAreaRatio >= minTextAreaRatio &&
            assetsWithText >= minAssetsWithText

        let singleAssetStrongText = assetCount == 1 &&
            totalCount >= minTextCount &&
            totalAreaRatio >= minTextAreaRatio

        guard enoughTextEvidenceForGroup || singleAssetStrongText else {
            return GroupTextDecision(archiveReason: nil, debugLabel: "TEXT_WEAK", summary: summary)
        }

        if assetsWithFace > 0 {
            return GroupTextDecision(archiveReason: nil, debugLabel: "TEXT_FACE_VETO", summary: summary)
        }

        if let maxConfidence, maxConfidence >= highConfidenceThreshold {
            return GroupTextDecision(archiveReason: .filteredTextHighConfidence, debugLabel: "TEXT_HIGH", summary: summary)
        }

        if let maxConfidence, maxConfidence >= possibleConfidenceThreshold {
            return GroupTextDecision(archiveReason: .filteredTextPossible, debugLabel: "TEXT_POSSIBLE", summary: summary)
        }

        return GroupTextDecision(archiveReason: nil, debugLabel: "TEXT_LOW", summary: summary)
    }
}
