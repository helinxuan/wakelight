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
            // 5.2.1 PhotoAsset
            try db.create(table: "photoAsset") { t in
                t.column("id", .text).primaryKey()
                t.column("localIdentifier", .text).notNull().unique()
                t.column("creationDate", .datetime)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("thumbnailPath", .text)
                t.column("importedAt", .datetime).notNull()
            }
            
            // 5.2.2 PlaceCluster
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
            
            // 5.2.3 VisitLayer
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

            // 5.2.4 StoryNode (必须在 timeRouteNode 之前创建，因为有外键引用)
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
            
            // 5.2.5 TimeRouteNode (时光模式节点)
            try db.create(table: "timeRouteNode") { t in
                t.column("id", .text).primaryKey()
                t.column("visitLayerId", .text).notNull().references("visitLayer", onDelete: .cascade)
                t.column("storyId", .text).references("storyNode", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("displayTitle", .text)
                t.column("displaySummary", .text)
            }
            
            // 5.2.6 AchievementProgress
            try db.create(table: "achievementProgress") { t in
                t.column("id", .text).primaryKey()
                t.column("achievementId", .text).notNull().unique()
                t.column("progressValue", .integer).notNull().defaults(to: 0)
                t.column("isUnlocked", .boolean).notNull().defaults(to: false)
                t.column("unlockedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            // 5.2.7 AwakenState
            try db.create(table: "awakenState") { t in
                t.column("id", .text).primaryKey()
                t.column("placeClusterId", .text).notNull().unique().references("placeCluster", onDelete: .cascade)
                t.column("energy", .integer).notNull().defaults(to: 0)
                t.column("isHalfRevealed", .boolean).notNull().defaults(to: false)
                t.column("awakenedPointCount", .integer).notNull().defaults(to: 0)
                t.column("lastAwakenedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            // 5.2.8 VisitLayerPhotoAsset (关联表)
            try db.create(table: "visitLayerPhotoAsset") { t in
                t.column("visitLayerId", .text).notNull().references("visitLayer", onDelete: .cascade)
                t.column("photoAssetId", .text).notNull().references("photoAsset", onDelete: .cascade)
                t.primaryKey(["visitLayerId", "photoAssetId"])
            }
        }
        
        return migrator
    }
}

// MARK: - Database Access
extension AppDatabase {
    var reader: DatabaseReader { writer }
}
