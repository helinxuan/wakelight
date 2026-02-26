import Foundation
import GRDB

struct AppDatabase {
    let writer: DatabaseWriter

    init(_ writer: DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// 数据库迁移配置
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1-initial-schema") { db in
            // PhotoAsset (media asset: photo/video)
            try db.create(table: "photoAsset") { t in
                t.column("id", .text).primaryKey()
                t.column("localIdentifier", .text).unique()
                t.column("creationDate", .datetime)
                t.column("latitude", .double)
                t.column("longitude", .double)

                // Cached thumbnails
                t.column("thumbnailPath", .text)
                t.column("thumbnailUpdatedAt", .datetime)
                t.column("thumbnailCacheKey", .text)

                // Media metadata
                t.column("mediaType", .text) // photo | video
                t.column("uti", .text)
                t.column("pixelWidth", .integer)
                t.column("pixelHeight", .integer)
                t.column("duration", .double) // seconds (video only)

                // Curation
                t.column("burstGroupId", .text)
                t.column("bestShotScore", .double)
                t.column("selectionReason", .text)
                t.column("curationBucket", .text)
                t.column("isRecoverableArchived", .boolean)
                t.column("recognizedTextConfidence", .double)

                // Sync / bookkeeping
                t.column("modificationDate", .datetime)
                t.column("lastSeenAt", .datetime) // 用于同步删除
                t.column("importedAt", .datetime).notNull()
            }

            // PlaceCluster
            try db.create(table: "placeCluster") { t in
                t.column("id", .text).primaryKey()
                t.column("centerLatitude", .double).notNull()
                t.column("centerLongitude", .double).notNull()
                t.column("geohash", .text).notNull().indexed()
                t.column("cityName", .text)
                t.column("detailedAddress", .text)
                t.column("photoCount", .integer).notNull().defaults(to: 0)
                t.column("visitCount", .integer).notNull().defaults(to: 0)
                t.column("fogState", .text).notNull().defaults(to: "locked")
                t.column("hasStory", .boolean).notNull().defaults(to: false)
                t.column("lastVisitedAt", .datetime)
            }

            // VisitLayer
            try db.create(table: "visitLayer") { t in
                t.column("id", .text).primaryKey()
                t.column("placeClusterId", .text).notNull().references("placeCluster", onDelete: .cascade)
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime).notNull()
                t.column("userText", .text)
                t.column("isStoryNode", .boolean).notNull().defaults(to: false)
                t.column("tagsJson", .text)
                t.column("voiceNotePath", .text)
                t.column("settledAt", .datetime)
            }

            // StoryNode (must be before timeRouteNode due to FK)
            try db.create(table: "storyNode") { t in
                t.column("id", .text).primaryKey()
                t.column("placeClusterId", .text).notNull().references("placeCluster", onDelete: .cascade)
                t.column("mainTitle", .text)
                t.column("mainSummary", .text)
                t.column("coverPhotoId", .text).notNull()
                t.column("subVisitLayerIdsJson", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // TimeRouteNode
            try db.create(table: "timeRouteNode") { t in
                t.column("id", .text).primaryKey()
                t.column("visitLayerId", .text).notNull().references("visitLayer", onDelete: .cascade)
                t.column("storyId", .text).references("storyNode", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("displayTitle", .text)
                t.column("displaySummary", .text)
            }

            // AchievementProgress
            try db.create(table: "achievementProgress") { t in
                t.column("id", .text).primaryKey()
                t.column("achievementId", .text).notNull().unique()
                t.column("progressValue", .integer).notNull().defaults(to: 0)
                t.column("isUnlocked", .boolean).notNull().defaults(to: false)
                t.column("unlockedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            // AwakenState
            try db.create(table: "awakenState") { t in
                t.column("id", .text).primaryKey()
                t.column("placeClusterId", .text).notNull().unique().references("placeCluster", onDelete: .cascade)
                t.column("energy", .integer).notNull().defaults(to: 0)
                t.column("isHalfRevealed", .boolean).notNull().defaults(to: false)
                t.column("awakenedPointCount", .integer).notNull().defaults(to: 0)
                t.column("lastAwakenedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            // VisitLayerPhotoAsset (join table)
            try db.create(table: "visitLayerPhotoAsset") { t in
                t.column("visitLayerId", .text).notNull().references("visitLayer", onDelete: .cascade)
                t.column("photoAssetId", .text).notNull().references("photoAsset", onDelete: .cascade)
                t.primaryKey(["visitLayerId", "photoAssetId"])
            }

            // WebDAVProfile
            try db.create(table: "webdavProfile") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("baseURLString", .text).notNull()
                t.column("username", .text).notNull()
                t.column("passwordKey", .text).notNull()
                // legacy single root
                t.column("rootPath", .text)
                // new multi roots (JSON string of [String])
                t.column("rootPathsJson", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // RemoteMediaAsset
            try db.create(table: "remoteMediaAsset") { t in
                t.column("id", .text).primaryKey()
                t.column("profileId", .text).notNull().references("webdavProfile", onDelete: .cascade)
                t.column("remotePath", .text).notNull()
                t.column("etag", .text)
                t.column("lastModified", .datetime)
                t.column("size", .integer)
                t.column("photoAssetId", .text).notNull().references("photoAsset", onDelete: .cascade)
                t.column("indexedAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime) // 用于同步删除
                t.column("rawPath", .text)
                t.column("hasJPG", .boolean).notNull().defaults(to: false)
                t.column("isPrimary", .boolean).notNull().defaults(to: true)

                // Live Photo pairing (HEIC + MOV/MP4/M4V)
                t.column("livePhotoVideoPath", .text)
                t.column("livePhotoPhotoPath", .text)

                t.uniqueKey(["profileId", "remotePath"])
            }

            try db.create(index: "idx_remoteMediaAsset_profile_path", on: "remoteMediaAsset", columns: ["profileId", "remotePath"])
            try db.create(index: "idx_remoteMediaAsset_photoAssetId", on: "remoteMediaAsset", columns: ["photoAssetId"])
        }

        return migrator
    }
}

// MARK: - Database Access
extension AppDatabase {
    var reader: DatabaseReader { writer }
}
