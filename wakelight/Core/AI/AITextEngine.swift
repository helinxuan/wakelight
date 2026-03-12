import Foundation
import UIKit

extension UIImage {
    func toAIDataURL() -> AITextImage? {
        guard let data = jpegData(compressionQuality: 0.72) else { return nil }
        let base64 = data.base64EncodedString()
        return .dataURL("data:image/jpeg;base64,\(base64)")
    }
}

/// 统一的 AI 文本生成入口。
///
/// 设计目标：
/// - 尽量对 Feature 暴露一个简单的「给我一句话」接口
/// - 内部负责：缓存、可用性探测、失败降级
/// - 对 Apple `LanguageModel` 框架做轻量封装，避免直接散落在各个 Feature 中
public enum AITextImage: Sendable {
    case remoteURL(String)
    /// Base64 data URL，例如："data:image/png;base64,AAAA..."
    case dataURL(String)
}

public struct AITextRequest {
    /// 针对具体场景的 System Prompt。
    public var systemPrompt: String
    /// 带具体事实/上下文的 User Prompt。
    public var userPrompt: String
    /// 图片输入（可选，支持远端 URL 或 data URL）。
    public var images: [AITextImage]
    /// 用于缓存的键；例如 `"culture:\(geohash6):\(timeBucketId)"`。
    public var cacheKey: String?
    /// 当模型不可用或推理失败时使用的兜底文案。
    public var fallbackText: String
    /// 可选采样参数（为空时使用引擎默认值）。
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?

    public init(
        systemPrompt: String,
        userPrompt: String,
        images: [AITextImage] = [],
        cacheKey: String? = nil,
        fallbackText: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.images = images
        self.cacheKey = cacheKey
        self.fallbackText = fallbackText
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
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

    public enum Provider: String, Sendable {
        case auto
        case siliconFlow
        case doubao
    }

    public struct ProviderSelection: Sendable {
        public var primary: Provider
        public var fallback: [Provider]

        public init(primary: Provider, fallback: [Provider] = []) {
            self.primary = primary
            self.fallback = fallback
        }

        public static let auto = ProviderSelection(primary: .auto)
        public static let siliconFlow = ProviderSelection(primary: .siliconFlow)
        public static let doubao = ProviderSelection(primary: .doubao)
    }

    /// 全局默认调用方，可由调用方自由切换。
    public var providerSelection: ProviderSelection = .auto

    public func setProvider(_ provider: Provider) {
        providerSelection = ProviderSelection(primary: provider)
    }

    private var cache: [String: String] = [:]

    /// 从 Info.plist 中读取硅基流动的 API Key。
    /// 请在工程的 Info.plist 中配置 `SILICONFLOW_API_KEY`（不要提交真实密钥到仓库）。
    private var siliconFlowAPIKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SILICONFLOW_API_KEY") as? String
    }

    /// 从 Info.plist 中读取豆包 Ark 的 API Key。
    /// 请在工程的 Info.plist 中配置 `DOUBAO_API_KEY`（不要提交真实密钥到仓库）。
    private var doubaoAPIKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "DOUBAO_API_KEY") as? String
    }

    #if DEBUG
    private func log(_ message: String) {
        print("[AITextEngine] \(message)")
    }
    #else
    private func log(_ message: String) { }
    #endif

    private init() {}

    /// 先对视觉关键词做预筛选，再用一次轻量 AI 做主题归并。
    /// - Parameters:
    ///   - rawKeywords: 原始或规则清洗后的关键词
    ///   - cacheKey: 可选缓存键（建议与照片集合绑定）
    /// - Returns: 可用于文案提示的 3~6 个主题词
    public func filterVisionKeywords(rawKeywords: [String], cacheKey: String? = nil) async -> [String] {
        let normalized = rawKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty else { return [] }

        // 本地黑名单预过滤（稳定、低成本）
        let blocked: Set<String> = [
            "tool", "tools", "seat", "seats",
            "artifact", "equipment", "device", "appliance",
            "mechanism", "component", "material", "object"
        ]
        let prefiltered = normalized.filter { !blocked.contains($0.lowercased()) }
        guard !prefiltered.isEmpty else { return [] }

        let sortedInput = prefiltered
            .map { $0.lowercased() }
            .sorted()
            .joined(separator: ",")

        let request = AITextRequest(
            systemPrompt: """
            你是“照片关键词清洗器”。
            你会收到机器视觉标签，请筛选为更自然的回忆线索。

            输出规则：
            1. 只输出 JSON，格式：{"themes":["词1","词2",...]}
            2. themes 最少 0 个，最多 6 个
            3. 删除明显机器词与部件词（如 tool/seat/device 等）
            4. 尽量输出中文主题词，简洁自然，不要句子
            5. 不要编造未出现的具体事件
            """,
            userPrompt: "原始关键词：\(prefiltered.joined(separator: "、"))",
            cacheKey: cacheKey ?? "vision_filter_\(sortedInput)",
            fallbackText: "",
            temperature: 0.15,
            topP: 0.8,
            maxTokens: 120
        )

        let raw = await generateText(for: request)
        if let parsed = parseThemesJSON(from: raw), !parsed.isEmpty {
            return Array(parsed.prefix(6))
        }

        // 解析失败时降级：直接返回预过滤后的前 6 个词
        return Array(prefiltered.prefix(6))
    }

    private func parseThemesJSON(from text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func decode(_ data: Data) -> [String]? {
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let themes = json["themes"] as? [String]
            else { return nil }
            return themes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if let directData = trimmed.data(using: .utf8), let themes = decode(directData) {
            return themes
        }

        // 兼容模型返回 ```json ... ``` 包裹
        if let start = trimmed.range(of: "{")?.lowerBound,
           let end = trimmed.range(of: "}", options: .backwards)?.upperBound {
            let jsonSubstring = String(trimmed[start..<end])
            if let data = jsonSubstring.data(using: .utf8), let themes = decode(data) {
                return themes
            }
        }

        return nil
    }

    /// 生成一段文本；若远端不可用或发生错误，将返回 fallback 文案。
    ///
    /// - 注意：该方法保证**总是返回非空字符串**，调用方无需再处理错误分支。
    public func generateText(for request: AITextRequest) async -> String {
        #if DEBUG
        let promptSnippet = request.userPrompt.replacingOccurrences(of: "\n", with: " ")
        log("generateText request: cacheKey=\(request.cacheKey ?? "nil"), userPrompt=\(promptSnippet)")
        #endif
        if let key = request.cacheKey, let cached = cache[key] {
            log("cache hit for key=\(key)")
            return cached
        }

        var resultText: String = request.fallbackText
        var shouldCache = false

        if let remoteText = await generateViaSelectedProvider(for: request) {
            resultText = remoteText
            shouldCache = true
        } else {
            log("Remote AI unavailable or failed; using fallback.")
        }

        // 只缓存真正的 AI 结果，避免把 fallback 缓存住导致后续一直“像没走 AI”。
        if shouldCache, let key = request.cacheKey {
            cache[key] = resultText
            log("cache store for key=\(key)")
        }

        return resultText
    }

    private func generateViaSelectedProvider(for request: AITextRequest) async -> String? {
        let selection = providerSelection
        let candidates: [Provider]

        if selection.primary == .auto {
            candidates = [.doubao, .siliconFlow] + selection.fallback
        } else {
            candidates = [selection.primary] + selection.fallback
        }

        for provider in candidates {
            switch provider {
            case .auto:
                continue
            case .doubao:
                if let text = await generateViaDoubao(for: request) {
                    return text
                }
            case .siliconFlow:
                if let text = await generateViaSiliconFlow(for: request) {
                    return text
                }
            }
        }

        return nil
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
            let top_p: Double
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
            temperature: request.temperature ?? 0.7,
            top_p: request.topP ?? 0.9,
            max_tokens: request.maxTokens
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

    private struct DoubaoResponse: Decodable {
        struct OutputItem: Decodable {
            let type: String
            let text: String?
        }
        struct OutputBlock: Decodable {
            let content: [OutputItem]?
            let text: String?
        }
        let output: [OutputBlock]?
    }

    /// 调用豆包 Ark responses 接口（支持图片输入）。
    ///
    ///   POST https://ark.cn-beijing.volces.com/api/v3/responses
    ///   Header: Authorization: Bearer <API_KEY>
    ///   Body: { model: "doubao-seed-2-0-mini-260215", input: [...] }
    private func generateViaDoubao(for request: AITextRequest) async -> String? {
        guard let apiKey = doubaoAPIKey, !apiKey.isEmpty else {
            log("Doubao API key not configured; skip remote AI.")
            return nil
        }

        guard let url = URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses") else {
            log("Invalid Doubao endpoint URL.")
            return nil
        }

        struct InputItem: Encodable {
            let type: String
            let text: String?
            let image_url: String?
        }

        struct InputMessage: Encodable {
            let role: String
            let content: [InputItem]
        }

        struct DoubaoRequestBody: Encodable {
            struct Thinking: Encodable {
                let type: String
            }

            let model: String
            let input: [InputMessage]
            let temperature: Double?
            let top_p: Double?
            let max_output_tokens: Int?
            let thinking: Thinking?
        }


        var items: [InputItem] = []
        if !request.systemPrompt.isEmpty {
            items.append(InputItem(type: "input_text", text: request.systemPrompt, image_url: nil))
        }
        for image in request.images {
            switch image {
            case .remoteURL(let url):
                items.append(InputItem(type: "input_image", text: nil, image_url: url))
            case .dataURL(let url):
                items.append(InputItem(type: "input_image", text: nil, image_url: url))
            }
        }
        if !request.userPrompt.isEmpty {
            items.append(InputItem(type: "input_text", text: request.userPrompt, image_url: nil))
        }

        let body = DoubaoRequestBody(
            model: "doubao-seed-2-0-mini-260215",
            input: [InputMessage(role: "user", content: items)],
            temperature: request.temperature,
            top_p: request.topP,
            max_output_tokens: request.maxTokens,
            thinking: DoubaoRequestBody.Thinking(type: "disabled")
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
                log("Doubao HTTP \(http.statusCode): \(snippet)")
                return nil
            }

            let decoded = try JSONDecoder().decode(DoubaoResponse.self, from: data)
            let combined = decodeDoubaoText(from: decoded)
            let text = combined.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if text.isEmpty {
                log("Doubao returned empty content.")
                return nil
            }
            log("Doubao success; key=\(request.cacheKey ?? "nil"), text=\"\(text)\"")
            return text
        } catch {
            log("Doubao error: \(error.localizedDescription)")
            return nil
        }
    }

    private func decodeDoubaoText(from response: DoubaoResponse) -> String {
        guard let output = response.output, !output.isEmpty else { return "" }
        var chunks: [String] = []
        for block in output {
            if let text = block.text {
                chunks.append(text)
                continue
            }
            if let content = block.content {
                for item in content {
                    if item.type == "output_text", let text = item.text {
                        chunks.append(text)
                    }
                }
            }
        }
        return chunks.joined()
    }
}

