import Foundation

// MARK: - WeChatPusher

/// 微信公众号模板消息推送
///
/// 流程：
/// 1. 使用 AppID + AppSecret 获取 access_token
/// 2. 调用模板消息接口推送到用户 OpenID
///
/// access_token 有效期 2 小时，本地缓存避免重复获取
///
/// 隐私：配置仅存储在本地，不联网（除调用微信 API 外）
///
final class WeChatPusher {

    static let shared = WeChatPusher()

    // MARK: - Config

    struct Config: Codable {
        var appId: String
        var appSecret: String
        var templateId: String
        var openId: String
    }

    var config: Config?

    private let configFile: URL
    private var cachedToken: String?
    private var tokenExpiry: Date?

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("VideoNotes", isDirectory: true)
        configFile = dir.appendingPathComponent("wechat_config.json")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        loadConfig()
    }

    // MARK: - Config Persistence

    func loadConfig() {
        guard let data = try? Data(contentsOf: configFile),
              let decoded = try? JSONDecoder().decode(Config.self, from: data) else {
            return
        }
        if SecureStore.value(for: "wechat-app-secret") == nil, !decoded.appSecret.isEmpty {
            SecureStore.save(decoded.appSecret, for: "wechat-app-secret")
        }
        config = Config(
            appId: decoded.appId,
            appSecret: SecureStore.value(for: "wechat-app-secret") ?? decoded.appSecret,
            templateId: decoded.templateId,
            openId: decoded.openId
        )
        if !decoded.appSecret.isEmpty { persistPublicConfig(config!) }
    }

    func saveConfig(appId: String, appSecret: String, templateId: String, openId: String) {
        let cfg = Config(appId: appId, appSecret: appSecret, templateId: templateId, openId: openId)
        SecureStore.save(appSecret, for: "wechat-app-secret")
        persistPublicConfig(cfg)
        config = cfg
        // 配置变更后清除 token 缓存
        cachedToken = nil
        tokenExpiry = nil
    }

    private func persistPublicConfig(_ config: Config) {
        let publicConfig = Config(
            appId: config.appId,
            appSecret: "",
            templateId: config.templateId,
            openId: config.openId
        )
        if let data = try? JSONEncoder().encode(publicConfig) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    var isConfigured: Bool {
        guard let config = config else { return false }
        return !config.appId.isEmpty
            && !config.appSecret.isEmpty
            && !config.templateId.isEmpty
            && !config.openId.isEmpty
    }

    // MARK: - Push

    /// 推送复盘笔记到微信
    /// - Parameters:
    ///   - title: 标题（如 "VideoNotes 复盘"）
    ///   - content: 笔记内容（Markdown 或纯文本）
    ///   - completion: 回调 (成功?, 错误)
    func push(
        title: String,
        content: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let config = config, isConfigured else {
            completion(.failure(WeChatError.notConfigured))
            return
        }

        // 1. 获取 access_token
        getAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                // 2. 发送模板消息
                self?.sendTemplateMessage(
                    token: token,
                    title: title,
                    content: content,
                    config: config,
                    completion: completion
                )
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Access Token

    private func getAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        // 检查缓存
        if let token = cachedToken,
           let expiry = tokenExpiry,
           expiry > Date() {
            completion(.success(token))
            return
        }

        guard let config = config else {
            completion(.failure(WeChatError.notConfigured))
            return
        }

        let urlString = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=\(config.appId)&secret=\(config.appSecret)"

        guard let url = URL(string: urlString) else {
            completion(.failure(WeChatError.invalidURL))
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(WeChatError.invalidResponse))
                return
            }

            // 检查错误
            if let errcode = json["errcode"] as? Int, errcode != 0 {
                let errmsg = json["errmsg"] as? String ?? "未知错误"
                completion(.failure(WeChatError.apiError(code: errcode, message: errmsg)))
                return
            }

            guard let token = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Int else {
                completion(.failure(WeChatError.invalidResponse))
                return
            }

            // 缓存 token（提前 5 分钟过期）
            self?.cachedToken = token
            self?.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 300))

            completion(.success(token))
        }.resume()
    }

    // MARK: - Template Message

    private func sendTemplateMessage(
        token: String,
        title: String,
        content: String,
        config: Config,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let urlString = "https://api.weixin.qq.com/cgi-bin/message/template/send?access_token=\(token)"

        guard let url = URL(string: urlString) else {
            completion(.failure(WeChatError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 微信模板消息内容长度限制约 200 字符/字段
        // 如果 content 太长，截取前 20000 字符（模板消息实际限制更大）
        let truncatedContent = String(content.prefix(20000))

        // 模板数据
        // 模板格式建议：
        // {{title.DATA}}
        // {{content.DATA}}
        // {{time.DATA}}
        let timeStr = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .short,
            timeStyle: .short
        )

        let body: [String: Any] = [
            "touser": config.openId,
            "template_id": config.templateId,
            "data": [
                "title": ["value": title, "color": "#173177"],
                "content": ["value": truncatedContent, "color": "#333333"],
                "time": ["value": timeStr, "color": "#999999"]
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(WeChatError.invalidResponse))
                return
            }

            if let errcode = json["errcode"] as? Int, errcode != 0 {
                let errmsg = json["errmsg"] as? String ?? "未知错误"
                completion(.failure(WeChatError.apiError(code: errcode, message: errmsg)))
                return
            }

            completion(.success(()))
        }.resume()
    }

    // MARK: - Errors

    enum WeChatError: LocalizedError {
        case notConfigured
        case invalidURL
        case invalidResponse
        case apiError(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "微信未配置，请先设置公众号信息"
            case .invalidURL: return "URL 格式错误"
            case .invalidResponse: return "微信 API 返回格式异常"
            case .apiError(let code, let message): return "微信 API 错误 (\(code)): \(message)"
            }
        }
    }
}
