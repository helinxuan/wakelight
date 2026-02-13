import Foundation
import GRDB

import Foundation
import GRDB

struct AppDatabase {
    private let writer: DatabaseWriter
    
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
            
            // 5.2.4 TimeRouteNode (时光模式节点)
            try db.create(table: "timeRouteNode") { t in
                t.column("id", .text).primaryKey()
                t.column("visitLayerId", .text).notNull().references("visitLayer", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("displayTitle", .text)
                t.column("displaySummary", .text)
            }
            
            // 5.2.5 AchievementProgress
            try db.create(table: "achievementProgress") { t in
                t.column("id", .text).primaryKey()
                t.column("achievementId", .text).notNull().unique()
                t.column("progressValue", .integer).notNull().defaults(to: 0)
                t.column("isUnlocked", .boolean).notNull().defaults(to: false)
                t.column("unlockedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }
        }
        
        return migrator
    }
}

// MARK: - Database Access
extension AppDatabase {
    var reader: DatabaseReader { writer }
}
