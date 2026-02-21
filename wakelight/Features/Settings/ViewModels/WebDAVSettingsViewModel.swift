import Foundation
import Combine

// NOTE:
// This view model relies on app modules in `wakelight/Core/...` and `wakelight/Domain/...`.
// If you see "cannot find type in scope" errors in Xcode, it usually means the file's
// target membership / build phase sources is misconfigured, not that these types are missing.

@MainActor
final class WebDAVSettingsViewModel: ObservableObject {
    @Published var baseURL: String = "http://192.168.0.112:5005/"
    @Published var username: String = "helinxuan"
    @Published var password: String = ""
    @Published var rootPath: String = "" // Added for single root compatibility in UI
    @Published var rootPaths: [String] = []
    @Published var isTesting: Bool = false
    @Published var testResult: String?
    @Published var isSuccess: Bool = false
    @Published var isSaving: Bool = false

    private let repo: WebDAVProfileRepository
    private let keychain = KeychainStore.shared
    private var existingProfile: WebDAVProfile?

    init(repo: WebDAVProfileRepository) {
        self.repo = repo
        Task {
            await loadExistingProfile()
        }
    }

    func loadExistingProfile() async {
        do {
            if let profile = try await repo.fetchLatestProfile() {
                self.existingProfile = profile
                self.baseURL = profile.baseURLString
                self.username = profile.username
                self.rootPaths = profile.rootPaths
                self.rootPath = profile.rootPaths.first ?? ""
                if let savedPassword = try? keychain.getString(forKey: profile.passwordKey) {
                    self.password = savedPassword
                }
                // 如果有现成配置，默认设为可以保存（或者让用户重新测试）
                // 这里为了安全，建议用户还是测试一下，或者我们自动静默测试一下
                // 但为了能让用户看到“已保存”的状态，我们可以先设为 true
                self.isSuccess = true 
            }
        } catch {
            print("[WebDAV] 加载现有配置失败: \(error)")
        }
    }

    func testConnection() async {
        print("[WebDAV] 开始测试连接: baseURL=\(baseURL), username=\(username)")
        isTesting = true
        testResult = "正在测试连接..."
        isSuccess = false

        guard let url = URL(string: baseURL) else {
            print("[WebDAV] 测试失败: URL 格式无效")
            testResult = "错误: 无效的 URL 格式"
            isTesting = false
            return
        }

        let credentials = WebDAVCredentials(username: username, password: password)
        let client = WebDAVClient(baseURL: url, credentials: credentials)

        do {
            print("[WebDAV] 正在发送 PROPFIND 请求...")
            _ = try await client.propfind(path: "/", depth: "0")
            print("[WebDAV] 连接成功！")
            isSuccess = true
            testResult = "连接成功！服务器已响应。"
        } catch let error as WebDAVError {
            print("[WebDAV] 连接捕获到 WebDAVError: \(error)")
            isSuccess = false
            switch error {
            case .httpStatus(let code):
                testResult = "连接失败: HTTP \(code)\n(401 通常表示账号密码错误或 WebDAV 根路径不对)"
            default:
                testResult = "连接失败: \(error)"
            }
        } catch {
            print("[WebDAV] 连接捕获到未知错误: \(error.localizedDescription)")
            isSuccess = false
            testResult = "连接失败: \(error.localizedDescription)"
        }

        isTesting = false
    }

    func save() async {
        print("[WebDAV] 尝试保存配置... 当前 isSuccess=\(isSuccess)")
        guard isSuccess else { 
            print("[WebDAV] 保存终止: isSuccess 为 false")
            return 
        }
        isSaving = true

        do {
            // 如果之前保存过配置，就更新同一个 profile，而不是每次都生成新的。
            // 这样进入设置页时 fetchLatestProfile 才能稳定回填同一份配置。
            let profileId = existingProfile?.id ?? UUID()
            print("[WebDAV] 使用 Profile ID: \(profileId)")
            let passwordKey = existingProfile?.passwordKey ?? "webdav.profile.\(profileId.uuidString).password"

            let now = Date()
            var profile = WebDAVProfile(
                id: profileId,
                name: existingProfile?.name ?? "WebDAV Server",
                baseURLString: baseURL,
                username: username,
                passwordKey: passwordKey,
                rootPath: WebDAVPath.normalizeDirectory(rootPath),
                createdAt: existingProfile?.createdAt ?? now,
                updatedAt: now
            )
            // Store all selected root paths
            profile.rootPaths = rootPaths.isEmpty ? [WebDAVPath.normalizeDirectory(rootPath)] : rootPaths

            print("[WebDAV] 正在写入 Keychain...")
            try keychain.setString(password, forKey: passwordKey)
            
            print("[WebDAV] 正在写入数据库...")
            try await repo.upsert(profile: profile)
            self.existingProfile = profile // 更新本地缓存

            testResult = "保存成功！"
            print("[WebDAV] 保存流程全部完成")

            let reader = WebDAVMediaReader(
                profileProvider: { [weak self] id in
                    guard let self = self else {
                        throw NSError(domain: "WebDAVSettings", code: -1)
                    }
                    return try await self.repo.fetchProfile(id: id)
                },
                passwordProvider: { p in
                    try KeychainStore.shared.getString(forKey: p.passwordKey)
                }
            )
            MediaResolver.shared.register(reader: reader)

            // 保存成功后触发一次后台导入（不阻塞 UI）
            PhotoImportManager.shared.startImportIfNeeded(reason: "webdav_saved")

        } catch {
            print("[WebDAV] 保存过程中发生异常: \(error.localizedDescription)")
            testResult = "保存失败: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
