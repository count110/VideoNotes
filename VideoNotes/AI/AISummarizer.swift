import Foundation
import Security

// MARK: - Secure credential storage

enum SecureStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.videonotes.app"
    private static let masterAccount = "credentials.v1"
    private static let lock = NSLock()
    private static var migrationAttempted = false

    /// 所有 API / 机器人配置合并进一个 Keychain item，避免多个 item 触发多次钥匙串解锁。
    private static let legacyAccounts = [
        "deepseek-api-key",
        "feishu-webhook-url",
        "feishu-webhook-signing-secret",
        "feishu-app-id",
        "feishu-app-secret",
        "feishu-relay-device-token",
        "feishu-relay-pending-device-token",
        "feishu-relay-pending-pairing-code",
        "feishu-relay-binding-instruction"
    ]

    static func value(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lockedLoad()[account]
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var dictionary = lockedLoad()
        if value.isEmpty {
            dictionary.removeValue(forKey: account)
        } else {
            dictionary[account] = value
        }
        return lockedStore(dictionary)
    }

    // MARK: - Keychain

    private static func lockedLoad() -> [String: String] {
        if let data = copyData(account: masterAccount),
           let dictionary = decodeDictionary(data) {
            return dictionary
        }

        if !migrationAttempted {
            migrationAttempted = true
            var migrated = [String: String]()
            for account in legacyAccounts {
                if let data = copyData(account: account),
                   let value = String(data: data, encoding: .utf8) {
                    migrated[account] = value
                }
            }
            if !migrated.isEmpty {
                _ = lockedStore(migrated)
                return migrated
            }
        }

        return [:]
    }

    private static func lockedStore(_ dictionary: [String: String]) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: masterAccount
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return false
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var insert = identity
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private static func copyData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func decodeDictionary(_ data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: String] else { return nil }
        return dictionary
    }
}

// MARK: - AISummarizer

/// AI 复盘笔记生成器
///
/// 使用 DeepSeek API 将零散笔记整理为简洁的自然语言复盘
///
/// 流程：
/// 1. 从 HistoryStore 获取指定范围的记录
/// 2. 构建提示词，发送给 DeepSeek API
/// 3. 返回数段连贯、便于快速回顾的复盘文字
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
        let dir = ApplicationStorage.directory
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

    /// Generates a video-learning review. It is intentionally separate from
    /// the existing time-range review so those summaries retain their current
    /// generic note-taking structure.
    func generateVideoReview(
        sessionTitle: String,
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

        callDeepSeek(
            prompt: buildVideoPrompt(sessionTitle: sessionTitle, records: records),
            config: config,
            completion: completion
        )
    }

    /// Uses the configured HTTPS AI service as a fallback when the user has
    /// not installed the local Codex CLI. The exact same evidence-bounded
    /// prompt is used by LocalCodexClient, so the two paths produce the same
    /// type of subtitle learning analysis.
    func generateSubtitleAnalysis(
        videoTitle: String,
        documents: [VideoSubtitleDocument],
        notes: [NoteRecord],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let config = config, !config.apiKey.isEmpty else {
            completion(.failure(AIError.notConfigured))
            return
        }
        guard !documents.isEmpty else {
            completion(.failure(AIError.noSubtitles))
            return
        }

        callDeepSeek(
            prompt: VideoSubtitleAnalysisPrompt.make(
                videoTitle: videoTitle,
                documents: documents,
                notes: notes
            ),
            config: config,
            completion: completion
        )
    }

    // MARK: - Prompt

    /// 构建考研学习复盘提示词。
    ///
    /// 复盘要成为第二天可以直接拿来复习的资料，而不是学习日志。
    /// 输出结构与本地 Codex 复盘保持一致，便于复制、归档和发送到飞书。
    ///
    private func buildPrompt(records: [NoteRecord]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let sortedRecords = records.sorted { $0.createdAt < $1.createdAt }
        let notesText = sortedRecords.enumerated().map { index, record in
            var line = "\(index + 1). [\(formatter.string(from: record.createdAt))]"
            if let videoTitle = record.videoTitle,
               !videoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                line += " [视频：\(videoTitle)]"
            }
            if let timestamp = record.videoTimestamp,
               !timestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                line += " [视频时间：\(timestamp)]"
            } else if let seconds = record.videoTimestampSeconds {
                line += " [视频时间：\(VideoSession.formattedTimestamp(for: seconds))]"
            }
            if !record.tags.isEmpty {
                line += " [标签：\(record.tags.joined(separator: "、"))]"
            }
            if record.isScreenshotClip {
                line += " [截图笔记]"
            }
            let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
            line += content.isEmpty ? "" : " \(content)"
            return line
        }.joined(separator: "\n")

        let calendar = Calendar.current
        let firstDate = sortedRecords.first?.createdAt ?? Date()
        let lastDate = sortedRecords.last?.createdAt ?? firstDate
        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale(identifier: "zh_CN")
        titleFormatter.dateFormat = "M月d日"
        let reviewTitle: String
        if calendar.isDate(firstDate, inSameDayAs: lastDate) {
            reviewTitle = "\(titleFormatter.string(from: firstDate))学习复盘"
        } else {
            reviewTitle = "\(titleFormatter.string(from: firstDate))-\(titleFormatter.string(from: lastDate))学习复盘"
        }

        return """
        你是考研学习复盘助手。请把下面的 VideoNotes 原始记录整理成一份“第二天打开就能快速复习”的中文 Markdown 学习资料。

        这不是学习日志，也不是 AI 总结报告。正文以知识结构、做题触发信号、解题思维链、错误复盘和待解决问题为核心；原始时间线只作为证据，统一放在最后的附录。只允许重组、压缩和解释原始记录中已经出现的内容，不得凭一般知识补全未记录的公式、条件、题目背景或结论。

        复盘标题必须使用：# \(reviewTitle)

        【证据和不确定性规则】
        1. 原始记录只说到关键词时，只整理到关键词能支持的程度。
        2. 记录中出现“待确认”“含义不清”“条件不完整”或你无法从原文确定的地方，必须保留并写成“【需要回看原视频确认】”，不得猜测。
        3. 不要把没有明确写出的“已掌握”当成已掌握；可以在“还没有彻底搞懂的问题”或“待回看视频确认清单”中保留缺口。
        4. 正文不要按原始时间逐条复述。视频标题和视频时间只在确实需要回看时保留，完整时间线放到附录。
        5. 数学公式使用普通文本或 Unicode 表达，不要输出 LaTeX、代码围栏或反斜杠命令。

        【固定输出结构】
        # \(reviewTitle)

        ## 0. 一页速览
        ### 今天学了什么
        用 3-8 条短句列出今天真正涉及的知识模块，按学科归类，不按时间排列。
        ### 今天最重要的3个收获
        只写 3 条，每条说明“记住什么/做题时怎么用”。
        ### 今天最需要解决的3个问题
        只写 3 条；如果原始记录不足 3 条，明确写“原始记录未提供更多问题”，不要编造。
        ### 明天复习优先级
        列出 3-5 个可执行动作，按优先级排序。
        ### 高频错误提醒
        列出 3-5 条一眼能触发警觉的短句。

        ## 1. 高等数学
        ### 1.1 微分中值定理
        ### 1.2 辅助函数构造
        ### 1.3 泰勒展开
        ### 1.4 极限与有理化
        ### 1.5 极值、拐点与函数图像

        ## 2. 物理化学
        ### 2.1 热力学过程判断总流程
        ### 2.2 恒温可逆与绝热可逆
        ### 2.3 多方过程
        ### 2.4 理想气体混合
        ### 2.5 P-V-T过程
        ### 2.6 节流膨胀
        ### 2.7 可逆相变
        ### 2.8 热力学过程总对照表

        ## 3. 线性代数
        ### 3.1 逆矩阵

        ## 4. 昨天真正踩的坑
        用醒目的“错误卡片”逐条写，每条必须包含：
        ⚠ 错误 01｜简短标题
        我的错误：
        为什么会错：
        正确思维：
        以后看到什么要警觉：

        ## 5. 还没有彻底搞懂的问题
        只收录原始记录中的疑问、信息缺口和未完成判断；每条写“问题｜为什么还没懂｜下一步怎么确认”。

        ## 6. 下一步行动
        只保留 3-6 个真正值得执行的任务，每个任务写清动作和检查标准。

        ## 7. 待回看视频确认清单
        统一用表格，表头必须是：问题｜对应知识点｜原始记录｜需要确认什么｜原视频时间
        原始记录没有时间时写“未提供”，不要补时间。

        ## 8. 附录：原始学习时间线
        按创建时间从早到晚保留原始记录，格式为“时间｜视频/来源｜原文”。这一节是追溯材料，正文其他位置不要铺开时间线。

        【每个重要知识点的统一写法】
        在 1、2、3 章的每个小节下，都必须按下面 6 个小标题组织。即使原始笔记没有涉及，也要写“原始笔记未涉及”，不能自行补课：
        #### ① 这部分在解决什么问题
        #### ② 核心结论
        #### ③ 做题识别信号
        #### ④ 解题思维链
        用“题目条件 → 判断 → 选择方法 → 建立公式/辅助函数 → 推导 → 得出结论”的顺序；没有证据的步骤标注“【需要回看原视频确认】”。
        #### ⑤ 为什么这么做
        解释原始记录能支持的原因，特别是辅助函数为什么从目标式反推、中值定理和泰勒展开如何衔接，以及物化中恒温/恒容/恒压、绝热、可逆、等焓等判断为什么会改变公式。无法确认时不要硬解释。
        #### ⑥ 常见错误
        只整理原始记录真正出现或明确暗示的错误。

        【辅助函数构造必须重点整理】
        把它写成一棵“目标式 → 反推方法”的决策树，而不是一句口号：
        目标式
        ↓
        观察出现哪些 f、f'、f'' 组合
        ↓
        能否直接识别为某个表达式求导后的结果？
        ├─ 能 → 直接还原辅助函数
        └─ 不能 → 是否缺少某阶导数？
                  ├─ 是 → 考虑添项/补项
                  └─ 否 → 是否类似一阶线性微分方程结构？
                            ├─ 是 → 考虑积分因子法
                            └─ 否 → 一个中值点是否足够？必要时构造 c₁、c₂
        只保留原始笔记可以支持的分支；若某分支的适用条件没有记录，在该节点旁标“【需要回看原视频确认】”。明确保留“还原法、罗尔定理逆过程、积分因子、缺失一阶导时补项、制造 c₁/c₂”等原始记录中的说法，但不要声称原笔记已经证明了未写出的通用定理。

        【物理化学必须先给判断流程】
        在 2.1 先画出：拿到热力学题 → 判断系统 → 看初态/终态 → 判断恒温/恒容/恒压 → 判断是否绝热 → 判断是否可逆 → 选择状态方程/过程关系 → 先求 ΔU、ΔH → 再求 q、w。然后再整理各过程。对照表至少要有：过程类型｜判断条件｜是否可逆｜是否绝热｜核心关系｜ΔU怎么求｜ΔH怎么求｜q怎么求｜w怎么求｜常见陷阱。只能填原始记录能确认的格子，其余写“【需要回看原视频确认】”。

        【识别卡片】
        在相关章节中至少整理以下“看到什么 → 想到什么”卡片，并只保留原始记录支持的内容：
        看到：根式极限 → 第一反应：有理化？再检查：是否有平方差
        看到：函数值和导数值 → 第一反应：泰勒展开？再检查：展开阶数
        看到：证明存在 ξ → 第一反应：中值定理；下一问：辅助函数是谁
        看到：热力学过程题 → 第一反应：先判断过程，不要先套公式

        原始笔记（共 \(sortedRecords.count) 条；仅供取证）：
        【原始笔记开始】
        \(notesText)
        【原始笔记结束】

        请只返回 Markdown 正文，不要返回代码围栏，不要解释你执行了什么命令。正文要像学生自己的高质量复习资料：短句、公式单独成行、流程用箭头、差异用表格、错误和待确认内容有明显标记；不要写“本次主要学习了”“综上所述”“进一步加深了理解”等报告腔套话。
        """
    }

    private func buildVideoPrompt(sessionTitle: String, records: [NoteRecord]) -> String {
        let notesText = records
            .sorted {
                ($0.videoTimestampSeconds ?? .greatestFiniteMagnitude)
                    < ($1.videoTimestampSeconds ?? .greatestFiniteMagnitude)
            }
            .map { record in
                let timestamp: String
                if let seconds = record.videoTimestampSeconds {
                    timestamp = VideoSession.formattedTimestamp(for: seconds)
                } else {
                    timestamp = record.videoTimestamp ?? "--:--"
                }
                return "[\(timestamp)] \(record.content)"
            }
            .joined(separator: "\n")

        return """
        你是一名严谨的视频学习复盘助手。只根据用户在视频学习中记录的内容整理复盘，不要编造视频里没有的信息，也不要把任务扩展成闲聊。

        ## 视频标题
        \(sessionTitle)

        ## 按视频时间排序的学习笔记（共 \(records.count) 条）
        \(notesText)

        ## 输出要求
        请用中文，并严格使用以下结构：

        ### 视频内容摘要
        简要说明笔记能反映出的学习主题；信息不足时明确说明。

        ### 核心知识点
        列出用户记录到的知识点，保持与时间点对应。

        ### 用户标记的疑问
        仅提取带有疑问、不确定、需要弄懂、待查等含义的内容；没有则写“未明确标记”。

        ### 易错点
        仅提取笔记中明确提到的易错或容易混淆之处；没有则写“未明确标记”。

        ### 建议重新观看的时间点
        按 [视频时间] 列出最值得回看的片段，并说明依据；只从给出的时间点中选择。

        ### 后续复习建议
        给出 2–4 条基于这些笔记的可执行复习动作。
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
            // The structured review has a fixed outline, process matrices and
            // an appendix. Give the model enough room to complete the
            // learning material without truncating the last sections.
            "max_tokens": 6000
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
        case noSubtitles
        case invalidResponse
        case invalidConfiguration

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "AI 未配置，请先设置 DeepSeek API Key"
            case .noRecords: return "没有可整理的笔记记录"
            case .noSubtitles: return "没有可分析的字幕内容"
            case .invalidResponse: return "AI 返回格式异常"
            case .invalidConfiguration: return "AI 服务地址无效或不是 HTTPS"
            }
        }
    }
}
