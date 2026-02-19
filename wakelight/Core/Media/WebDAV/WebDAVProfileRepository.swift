import Foundation
import GRDB

protocol WebDAVProfileRepositoryProtocol {
    func fetchProfile(id: String) async throws -> WebDAVProfile
    func fetchLatestProfile() async throws -> WebDAVProfile?
    func upsert(profile: WebDAVProfile) async throws
}

final class WebDAVProfileRepository: WebDAVProfileRepositoryProtocol {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func fetchLatestProfile() async throws -> WebDAVProfile? {
        try await db.reader.read { db in
            try WebDAVProfile.order(Column("updatedAt").desc).fetchOne(db)
        }
    }

    func fetchProfile(id: String) async throws -> WebDAVProfile {
        try await db.reader.read { db in
            guard let uuid = UUID(uuidString: id) else {
                throw NSError(domain: "WebDAVProfileRepository", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid profile id"])
            }
            guard let profile = try WebDAVProfile.fetchOne(db, key: uuid) else {
                throw NSError(domain: "WebDAVProfileRepository", code: -404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
            }
            return profile
        }
    }

    func upsert(profile: WebDAVProfile) async throws {
        try await db.writer.write { db in
            try profile.save(db)
        }
    }
}
