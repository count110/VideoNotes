import Foundation
import Security

// MARK: - Secure credential storage

enum SecureStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.videonotes.app"

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            SecItemDelete(identity as CFDictionary)
            return true
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var insert = identity
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - AISummarizer

/// AI 复盘笔记生成器
///
/// 使用 DeepSeek API 将零散笔记整理为结构化复盘
///
/// 流程：
/// 1. 从 HistoryStore 获取指定范围的记录
/// 2. 构建提示词，发送给 DeepSeek API
/// 3. 返回带时间线的结构化复盘笔记
///
/// 隐私：DeepSeek API 仅接收笔记文本，不发送用户身份信息
///
final class AISummarizer {

    static let shared = AISummarizer()

    // MARK: - Config

    struct Config {
        var apiKey: String
        var model: String
        var baseURL: String

        static let defaultModel = "deepseek-chat"
        static let defaultBaseURL = "https://api.deepseek.com/v1"
    }

    var config: Config?

    /// 从 ~/Library/Application Support/VideoNotes/config.json 加载
    private let configFile: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("VideoNotes", isDirectory: true)
        configFile = dir.appendingPathComponent("config.json")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        loadConfig()
    }

    // MARK: - Config Persistence

    func loadConfig() {
        let data = try? Data(contentsOf: configFile)
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        let legacyKey = json["apiKey"] ?? ""
        if SecureStore.value(for: "deepseek-api-key") == nil, !legacyKey.isEmpty {
            SecureStore.save(legacyKey, for: "deepseek-api-key")
        }
        config = Config(
            apiKey: SecureStore.value(for: "deepseek-api-key") ?? legacyKey,
            model: json["model"] ?? Config.defaultModel,
            baseURL: json["baseURL"] ?? Config.defaultBaseURL
        )
        if json["apiKey"] != nil {
            persistPublicConfig(model: config?.model ?? Config.defaultModel, baseURL: config?.baseURL ?? Config.defaultBaseURL)
        }
    }

    func saveConfig(apiKey: String, model: String? = nil, baseURL: String? = nil) {
        let resolvedModel = model ?? Config.defaultModel
        let resolvedBaseURL = baseURL ?? Config.defaultBaseURL
        SecureStore.save(apiKey, for: "deepseek-api-key")
        persistPublicConfig(model: resolvedModel, baseURL: resolvedBaseURL)
        config = Config(
            apiKey: apiKey,
            model: resolvedModel,
            baseURL: resolvedBaseURL
        )
    }

    private func persistPublicConfig(model: String, baseURL: String) {
        let dict = ["model": model, "baseURL": baseURL]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    var isConfigured: Bool {
        guard let config = config else { return false }
        return !config.apiKey.isEmpty
    }

    // MARK: - Generate Summary

    /// 生成复盘笔记
    /// - Parameters:
    ///   - records: 要整理的笔记记录
    ///   - completion: 回调 (生成的笔记, 错误)
    func generateReview(
        records: [NoteRecord],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let config = config, !config.apiKey.isEmpty else {
            completion(.failure(AIError.notConfigured))
            return
        }

        guard !records.isEmpty else {
            completion(.failure(AIError.noRecords))
            return
        }

        // 构建提示词
        let prompt = buildPrompt(records: records)

        // 调用 API
        callDeepSeek(prompt: prompt, config: config, completion: completion)
    }

    // MARK: - Prompt

    /// 构建发给 AI 的提示词
    ///
    /// 要求 AI 输出带时间线的结构化复盘笔记
    ///
    private func buildPrompt(records: [NoteRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"

        let notesText = records.enumerated().map { index, record in
            let time = formatter.string(from: record.createdAt)
            return "[\(time)] \(record.content)"
        }.joined(separator: "\n")

        let dateRange = "\(formatter.string(from: records.last!.createdAt)) ~ \(formatter.string(from: records.first!.createdAt))"

        return """
        你是一个专业的学习/观影复盘助手。请将以下笔记整理为一份结构化的复盘笔记。

        ## 笔记时间范围
        \(dateRange)

        ## 原始笔记（共 \(records.count) 条）
        \(notesText)

        ## 输出要求
        请按以下格式输出复盘笔记：

        ### 📋 概要
        用 2-3 句话概括这批笔记的核心主题。

        ### ⏰ 时间线
        按时间顺序列出关键知识点，每条标注时间和内容：
        - [时间] 知识点/笔记内容

        ### 🔑 核心要点
        提炼 3-5 个最重要的要点，每个要点一句话概括。

        ### ❓ 待深入
        列出需要进一步学习或验证的问题。

        ### 💡 启发
        从这些笔记中获得的启发或行动项。

        注意：
        - 保持客观，不要编造笔记中没有的内容
        - 如果笔记内容较少或零散，如实说明
        - 用中文输出
        """
    }

    // MARK: - API Call

    private func callDeepSeek(
        prompt: String,
        config: Config,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let baseURL = URL(string: config.baseURL),
              baseURL.scheme == "https" else {
            completion(.failure(AIError.invalidConfiguration))
            return
        }
        let url = baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": "你是一个专业的复盘笔记整理助手。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 2000
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                completion(.failure(AIError.invalidResponse))
                return
            }

            completion(.success(content))
        }.resume()
    }

    // MARK: - Errors

    enum AIError: LocalizedError {
        case notConfigured
        case noRecords
        case invalidResponse
        case invalidConfiguration

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "AI 未配置，请先设置 DeepSeek API Key"
            case .noRecords: return "没有可整理的笔记记录"
            case .invalidResponse: return "AI 返回格式异常"
            case .invalidConfiguration: return "AI 服务地址无效或不是 HTTPS"
            }
        }
    }
}
