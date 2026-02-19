import Foundation

#if DEBUG
final class WebDAVDebugBootstrap {
    static func bootstrapIfNeeded() {
        Task {
            do {
                let container = DatabaseContainer.shared
                let repo = WebDAVProfileRepository(db: container.db)

                let now = Date()
                let profileId = UUID()
                let passwordKey = "webdav.profile.\(profileId.uuidString).password"

                let profile = WebDAVProfile(
                    id: profileId,
                    name: "Local WebDAV",
                    baseURLString: "http://192.168.0.112:5005/",
                    username: "helinxuan",
                    passwordKey: passwordKey,
                    createdAt: now,
                    updatedAt: now
                )

                try KeychainStore.shared.setString("FRxuan1", forKey: passwordKey)
                try await repo.upsert(profile: profile)

                let reader = WebDAVMediaReader(
                    profileProvider: { id in
                        try await repo.fetchProfile(id: id)
                    },
                    passwordProvider: { p in
                        try KeychainStore.shared.getString(forKey: p.passwordKey)
                    }
                )

                MediaResolver.shared.register(reader: reader)

                let client = WebDAVClient(
                    baseURL: profile.baseURL ?? URL(string: profile.baseURLString)!,
                    credentials: .init(username: profile.username, password: try KeychainStore.shared.getString(forKey: passwordKey))
                )

                let items = try await client.propfind(path: "/", depth: "1")
                print("[WebDAV] PROPFIND / items=\(items.count)")
                for item in items.prefix(10) {
                    print("[WebDAV] href=\(item.href) collection=\(item.isCollection) etag=\(item.etag ?? "-")")
                }
            } catch {
                print("[WebDAV] bootstrap failed: \(error)")
            }
        }
    }
}
#endif
