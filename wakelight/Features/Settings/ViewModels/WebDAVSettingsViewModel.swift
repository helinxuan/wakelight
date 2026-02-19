import Foundation
import Combine

@MainActor
final class WebDAVSettingsViewModel: ObservableObject {
    @Published var baseURL: String = "http://192.168.0.112:5005/"
    @Published var username: String = "helinxuan"
    @Published var password: String = ""
    @Published var rootPath: String = ""
    @Published var isTesting: Bool = false
    @Published var testResult: String?
    @Published var isSuccess: Bool = false
    @Published var isSaving: Bool = false

    private let repo: WebDAVProfileRepository
    private let keychain = KeychainStore.shared

    init(repo: WebDAVProfileRepository) {
        self.repo = repo
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
            let profileId = UUID()
            print("[WebDAV] 生成 Profile ID: \(profileId)")
            let passwordKey = "webdav.profile.\(profileId.uuidString).password"

            let profile = WebDAVProfile(
                id: profileId,
                name: "WebDAV Server",
                baseURLString: baseURL,
                username: username,
                passwordKey: passwordKey,
                rootPath: WebDAVPath.normalizeDirectory(rootPath),
                createdAt: Date(),
                updatedAt: Date()
            )

            print("[WebDAV] 正在写入 Keychain...")
            try keychain.setString(password, forKey: passwordKey)
            
            print("[WebDAV] 正在写入数据库...")
            try await repo.upsert(profile: profile)

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

        } catch {
            print("[WebDAV] 保存过程中发生异常: \(error.localizedDescription)")
            testResult = "保存失败: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
