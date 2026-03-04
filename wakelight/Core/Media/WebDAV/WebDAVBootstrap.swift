import Foundation

/// 负责 App 启动时自动加载并注册 WebDAV 配置
final class WebDAVBootstrap {
    static let shared = WebDAVBootstrap()
    
    private init() {}
    
    @MainActor
    func bootstrap() async {
        do {
            let container = DatabaseContainer.shared
            let repo = WebDAVProfileRepository(db: container.db)

            // 1. 尝试从数据库加载最近一次使用的 Profile
            guard let profile = try await repo.fetchLatestProfile() else {
                print("[WebDAVBootstrap] 未找到已保存的配置，跳过自动注册")
                return
            }

            print("[WebDAVBootstrap] 发现已保存配置: \(profile.baseURLString), username: \(profile.username)")

            // 2. 构造 MediaReader 并注册到 Resolver
            let reader = WebDAVMediaReader(
                profileProvider: { id in
                    try await repo.fetchProfile(id: id)
                },
                passwordProvider: { p in
                    try KeychainStore.shared.getString(forKey: p.passwordKey)
                }
            )

            MediaResolver.shared.register(reader: reader)
            print("[WebDAVBootstrap] WebDAVMediaReader 自动注册成功")

        } catch {
            print("[WebDAVBootstrap] 自动加载配置失败: \(error.localizedDescription)")
        }
    }
}
