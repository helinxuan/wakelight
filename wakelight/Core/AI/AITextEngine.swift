import Foundation

/// 统一的 AI 文本生成入口。
///
/// 设计目标：
/// - 尽量对 Feature 暴露一个简单的「给我一句话」接口
/// - 内部负责：缓存、可用性探测、失败降级
/// - 对 Apple `LanguageModel` 框架做轻量封装，避免直接散落在各个 Feature 中
public struct AITextRequest {
    /// 针对具体场景的 System Prompt。
    public var systemPrompt: String
    /// 带具体事实/上下文的 User Prompt。
    public var userPrompt: String
    /// 用于缓存的键；例如 `"culture:\(geohash6):\(timeBucketId)"`。
    public var cacheKey: String?
    /// 当模型不可用或推理失败时使用的兜底文案。
    public var fallbackText: String

    public init(
        systemPrompt: String,
        userPrompt: String,
        cacheKey: String? = nil,
        fallbackText: String
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.cacheKey = cacheKey
        self.fallbackText = fallbackText
    }
}

/// AI 文本引擎（统一封装在线/本地 LLM 调用）。
///
/// 为了避免到处散落 LLM 调用逻辑，这里集中做：
/// - 可用性判断（是否有 `LanguageModel`，是否在支持的系统版本）
/// - 简单的本地内存缓存（按 cacheKey）
/// - 失败时自动回退到 fallback 文案
public actor AITextEngine {
    public static let shared = AITextEngine()

    private var cache: [String: String] = [:]

    /// 从 Info.plist 中读取硅基流动的 API Key。
    /// 请在工程的 Info.plist 中配置 `SILICONFLOW_API_KEY`（不要提交真实密钥到仓库）。
    private var siliconFlowAPIKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SILICONFLOW_API_KEY") as? String
    }

    #if DEBUG
    private func log(_ message: String) {
        print("[AITextEngine] \(message)")
    }
    #else
    private func log(_ message: String) { }
    #endif

    private init() {}

    /// 生成一段文本；若远端不可用或发生错误，将返回 fallback 文案。
    ///
    /// - 注意：该方法保证**总是返回非空字符串**，调用方无需再处理错误分支。
    public func generateText(for request: AITextRequest) async -> String {
        if let key = request.cacheKey, let cached = cache[key] {
            log("cache hit for key=\(key)")
            return cached
        }

        var resultText: String = request.fallbackText

        // 直接调用硅基流动 Qwen2.5-7B-Instruct (Free) 在线模型。
        if let remoteText = await generateViaSiliconFlow(for: request) {
            resultText = remoteText
        } else {
            log("Remote AI unavailable or failed; using fallback.")
        }

        if let key = request.cacheKey {
            cache[key] = resultText
            log("cache store for key=\(key)")
        }

        return resultText
    }

    /// 调用硅基流动 Qwen2.5-7B-Instruct (Free) 在线接口。
    ///
    /// - 假设硅基流动兼容 OpenAI Chat Completions 协议：
    ///   POST https://api.siliconflow.cn/v1/chat/completions
    ///   Header: Authorization: Bearer <API_KEY>
    ///   Body: { model: "Qwen/Qwen2.5-7B-Instruct", messages: [...] }
    private func generateViaSiliconFlow(for request: AITextRequest) async -> String? {
        guard let apiKey = siliconFlowAPIKey, !apiKey.isEmpty else {
            log("SiliconFlow API key not configured; skip remote AI.")
            return nil
        }

        guard let url = URL(string: "https://api.siliconflow.cn/v1/chat/completions") else {
            log("Invalid SiliconFlow endpoint URL.")
            return nil
        }

        struct ChatMessage: Encodable {
            let role: String
            let content: String
        }

        struct ChatRequestBody: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double
            let max_tokens: Int?
        }

        struct ChatCompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let messages = [
            ChatMessage(role: "system", content: request.systemPrompt),
            ChatMessage(role: "user", content: request.userPrompt)
        ]

        let body = ChatRequestBody(
            model: "Qwen/Qwen2.5-7B-Instruct",
            messages: messages,
            temperature: 0.7,
            max_tokens: 120
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                log("SiliconFlow HTTP \(http.statusCode): \(snippet)")
                return nil
            }

            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let first = decoded.choices.first else {
                log("SiliconFlow response has no choices.")
                return nil
            }
            let text = first.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                log("SiliconFlow returned empty content.")
                return nil
            }
            log("SiliconFlow success; key=\(request.cacheKey ?? "nil"), text=\"\(text)\"")
            return text
        } catch {
            log("SiliconFlow error: \(error.localizedDescription)")
            return nil
        }
    }
}

