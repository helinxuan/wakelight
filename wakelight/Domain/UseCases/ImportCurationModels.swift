import Foundation

enum ImportDecisionBucket: String, Codable, Sendable {
    case keep
    case review
    case archived
}

enum ImportDecisionReason: String, Codable, Sendable {
    case autoKeep = "auto_keep"
    case needsReview = "needs_review"
    case filteredText = "filtered_text"
    case filteredTextHighConfidence = "filtered_text_high_confidence"
    case filteredTextPossible = "filtered_text_possible"
    case duplicateNearTime = "duplicate_near_time"
    case missingCriticalMetadata = "missing_critical_metadata"
}

struct ImportAssetDecision: Sendable {
    let localIdentifier: String
    let bucket: ImportDecisionBucket
    let reason: ImportDecisionReason
    let score: Double
    let recognizedTextConfidence: Double?
    let groupId: String?
}

struct ImportCurationSummary: Sendable {
    let totalImported: Int
    let meaningfulKept: Int
    let reviewBucketCount: Int
    let filteredArchivedCount: Int
    let decisions: [ImportAssetDecision]
}
