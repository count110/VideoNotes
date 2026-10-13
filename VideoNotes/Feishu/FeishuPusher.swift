import Foundation
import CryptoKit

// MARK: - FeishuPusher

/// Sends a user-initiated VideoNotes review to one Feishu/Lark group custom
/// bot. A custom bot webhook can only post to the group where it was created;
/// this client never reads group, member, or account data.
///
/// The webhook is a credential because anybody who owns it can post to the
/// corresponding group. Both it and the optional signing secret therefore live
/// only in the macOS Keychain. The small JSON file beside the existing local
/// app data stores status flags only, so it cannot be used to recover either
/// credential.
final class FeishuPusher {

    static let shared = FeishuPusher()

    // MARK: - Configuration

    struct Config {
        var webhook: String
        var signingSecret: String
        var appID: String
        var appSecret: String
    }

    /// Read-only to callers so Settings can populate its fields without
    /// allowing a credential to bypass `saveConfig`.
    private(set) var config: Config?

    private let configFile: URL
    private static let webhookKey = "feishu-webhook-url"
    private static let signingSecretKey = "feishu-webhook-signing-secret"
    private static let appIDKey = "feishu-app-id"
    private static let appSecretKey = "feishu-app-secret"

    private struct PublicConfiguration: Codable {
        let hasWebhook: Bool
        let hasSigningSecret: Bool
        let hasAppCredentials: Bool
        let version: Int
    }

    private init() {
        let directory = ApplicationStorage.directory
        configFile = directory.appendingPathComponent("feishu_config.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadConfig()
    }

    /// Reloads credentials from Keychain. The companion JSON is deliberately
    /// not consulted for credential values; it merely records non-sensitive UI
    /// state for a future settings experience.
    func loadConfig() {
        let webhook = SecureStore.value(for: Self.webhookKey) ?? ""
        let signingSecret = SecureStore.value(for: Self.signingSecretKey) ?? ""
        let appID = SecureStore.value(for: Self.appIDKey) ?? ""
        let appSecret = SecureStore.value(for: Self.appSecretKey) ?? ""

        guard !webhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            config = nil
            return
        }

        config = Config(
            webhook: webhook,
            signingSecret: signingSecret,
            appID: appID,
            appSecret: appSecret
        )
    }

    /// Saves credentials to Keychain. Passing an empty string removes the
    /// corresponding value from Keychain, which is useful when a user changes
    /// group or disables webhook signing.
    func saveConfig(webhook: String, signingSecret: String, appID: String, appSecret: String) {
        let normalizedWebhook = webhook.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSigningSecret = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = SecureStore.save(normalizedWebhook, for: Self.webhookKey)
        _ = SecureStore.save(normalizedSigningSecret, for: Self.signingSecretKey)
        _ = SecureStore.save(normalizedAppID, for: Self.appIDKey)
        _ = SecureStore.save(normalizedAppSecret, for: Self.appSecretKey)

        // Re-read the Keychain rather than trusting the requested values: if a
        // Keychain write ever fails, the app should not present an unsaved
        // configuration as active.
        loadConfig()
        persistPublicConfiguration()
    }

    var isConfigured: Bool {
        guard let config else { return false }
        return validatedWebhookURL(from: config.webhook) != nil
    }

    // MARK: - Push

    /// Sends one completed video review as a Feishu interactive card.
    ///
    /// `records` and `generatedAt` are metadata for the card only; no history
    /// is loaded implicitly. That keeps every outbound payload explicit at the
    /// call site and preserves the app's user-initiated sharing model.
    func pushVideoReview(
        title: String,
        markdown: String,
        records: [NoteRecord],
        generatedAt: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        pushContentCard(
            headerTitle: "VideoNotes · 视频复盘",
            title: title,
            markdown: markdown,
            records: records,
            generatedAt: generatedAt,
            completion: completion
        )
    }

    /// Sends one daily learning summary to the configured Feishu group.
    /// The dashboard passes an explicit snapshot, so this method never reads
    /// the history store implicitly or uploads the user's full database.
    func pushDailyLearningSummary(
        summary: DailyLearningSummary,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        pushContentCard(
            headerTitle: "VideoNotes · 每日学习",
            title: "\(summary.dateLabel) 学习看板",
            markdown: summary.feishuMarkdown,
            records: summary.records,
            generatedAt: Date(),
            completion: completion
        )
    }

    private func pushContentCard(
        headerTitle: String,
        title: String,
        markdown: String,
        records: [NoteRecord],
        generatedAt: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        NSLog("[FeishuPush] pushContentCard start, records=%d", records.count)
        guard let config else {
            NSLog("[FeishuPush] FAIL notConfigured")
            complete(.failure(FeishuError.notConfigured), completion: completion)
            return
        }

        guard let webhookURL = validatedWebhookURL(from: config.webhook) else {
            NSLog("[FeishuPush] FAIL invalidWebhookURL: %@", config.webhook)
            complete(.failure(FeishuError.invalidWebhookURL), completion: completion)
            return
        }
        NSLog("[FeishuPush] webhook valid: %@", webhookURL.absoluteString)

        let screenshotPaths = records.compactMap(\.screenshotPath).filter {
            FileManager.default.fileExists(atPath: $0)
        }
        NSLog("[FeishuPush] screenshotPaths=%d", screenshotPaths.count)

        uploadImagesIfNeeded(screenshotPaths, config: config) { imageUploadResult in
            self.sendReview(
                headerTitle: headerTitle,
                title: title,
                markdown: markdown,
                records: records,
                generatedAt: generatedAt,
                screenshotPaths: screenshotPaths,
                imageUploadResult: imageUploadResult,
                webhookURL: webhookURL,
                config: config,
                completion: completion
            )
        }
    }

    private func uploadImagesIfNeeded(
        _ screenshotPaths: [String],
        config: Config,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !screenshotPaths.isEmpty else {
            completion(.success([]))
            return
        }

        let appID = config.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = config.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !appSecret.isEmpty else {
            completion(.success([]))
            return
        }

        FeishuImageUploader.shared.uploadImages(
            at: screenshotPaths,
            appID: appID,
            appSecret: appSecret,
            completion: completion
        )
    }

    private func sendReview(
        headerTitle: String,
        title: String,
        markdown: String,
        records: [NoteRecord],
        generatedAt: Date,
        screenshotPaths: [String],
        imageUploadResult: Result<[String], Error>,
        webhookURL: URL,
        config: Config,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let imageKeys: [String]
        var imageNote: String?

        switch imageUploadResult {
        case .success(let keys):
            imageKeys = keys
            NSLog("[FeishuPush] image upload success, keys=%d", keys.count)
            if !screenshotPaths.isEmpty, keys.isEmpty {
                imageNote = "本次复盘包含 \(screenshotPaths.count) 张截图，但未配置飞书自建应用，图片未发送。"
            }
        case .failure(let error):
            imageKeys = []
            imageNote = "截图发送失败：\(error.localizedDescription)"
            NSLog("[FeishuPush] image upload failure: %@", error.localizedDescription)
        }

        // 按截图路径顺序构建 图片 + 对应笔记 的元素对。
        let screenshots = imageKeys.enumerated().map { index, imageKey -> (imageKey: String, caption: String) in
            let record = records.first { $0.screenshotPath == screenshotPaths[index] }
            return (imageKey, Self.caption(for: record))
        }

        let payload: [String: Any]
        do {
            payload = try makeReviewPayload(
                headerTitle: headerTitle,
                title: title,
                markdown: markdown,
                recordCount: records.count,
                generatedAt: generatedAt,
                screenshots: screenshots,
                imageNote: imageNote,
                signingSecret: config.signingSecret
            )
        } catch {
            complete(.failure(error), completion: completion)
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            // Feishu custom bot webhooks accept request bodies up to 20 KB.
            // Refuse oversized reviews rather than silently cutting off the
            // learner's analysis before it reaches their group.
            guard data.count <= Self.maximumPayloadBytes else {
                NSLog("[FeishuPush] FAIL payloadTooLarge bytes=%d", data.count)
                complete(.failure(FeishuError.payloadTooLarge), completion: completion)
                return
            }
            NSLog("[FeishuPush] posting payload bytes=%d to %@", data.count, webhookURL.absoluteString)

            var request = URLRequest(url: webhookURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            request.timeoutInterval = 30

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    NSLog("[FeishuPush] network error: %@", error.localizedDescription)
                    self.complete(.failure(error), completion: completion)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    NSLog("[FeishuPush] FAIL invalidResponse")
                    self.complete(.failure(FeishuError.invalidResponse), completion: completion)
                    return
                }
                NSLog("[FeishuPush] http status=%d", httpResponse.statusCode)

                let responseBody = data ?? Data()
                let apiResponse = try? JSONDecoder().decode(FeishuAPIResponse.self, from: responseBody)
                if let responseBodyString = String(data: responseBody, encoding: .utf8) {
                    NSLog("[FeishuPush] response body: %@", responseBodyString)
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    self.complete(
                        .failure(
                            FeishuError.httpError(
                                statusCode: httpResponse.statusCode,
                                message: apiResponse?.message
                            )
                        ),
                        completion: completion
                    )
                    return
                }

                guard let apiResponse else {
                    self.complete(.failure(FeishuError.invalidResponse), completion: completion)
                    return
                }

                guard apiResponse.code == 0 else {
                    self.complete(
                        .failure(
                            FeishuError.apiError(
                                code: apiResponse.code,
                                message: apiResponse.message ?? "未知错误"
                            )
                        ),
                        completion: completion
                    )
                    return
                }

                self.complete(.success(()), completion: completion)
            }.resume()
        } catch {
            complete(.failure(FeishuError.payloadEncodingFailed), completion: completion)
        }
    }

    /// Sends a harmless, user-triggered connection check to the configured
    /// group. It never reads any Feishu data and sends no note content.
    func sendTestMessage(completion: @escaping (Result<Void, Error>) -> Void) {
        pushVideoReview(
            title: "VideoNotes 复盘群测试",
            markdown: "已成功连接。之后你可以从视频复盘看板一键发送学习总结。",
            records: [],
            generatedAt: Date(),
            completion: completion
        )
    }

    // MARK: - Payload

    private static let maximumPayloadBytes = 20 * 1024

    /// 图片下方的说明文字：优先显示笔记内容，其次显示视频时间点。
    private static func caption(for record: NoteRecord?) -> String {
        guard let record else { return "截图" }

        let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            return content
        }
        if let seconds = record.videoTimestampSeconds {
            return "视频时间 \(VideoSession.formattedTimestamp(for: seconds))"
        }
        if let timestamp = record.videoTimestamp {
            return "视频时间 \(timestamp)"
        }
        return "截图"
    }

    private func makeReviewPayload(
        headerTitle: String,
        title: String,
        markdown: String,
        recordCount: Int,
        generatedAt: Date,
        screenshots: [(imageKey: String, caption: String)],
        imageNote: String?,
        signingSecret: String
    ) throws -> [String: Any] {
        let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = safeTitle.isEmpty ? "视频复盘" : safeTitle
        let generatedTime = Self.generatedTimeFormatter.string(from: generatedAt)
        let metadata = "基于 \(recordCount) 条原始笔记 · 生成于 \(generatedTime)"
        var reviewContent = "## \(displayTitle)\n\n\(metadata)\n\n\(markdown)"
        if let imageNote {
            reviewContent += "\n\n> \(imageNote)"
        }

        var elements: [[String: Any]] = [
            [
                "tag": "markdown",
                "content": reviewContent,
                "text_align": "left",
                "text_size": "normal_v2",
                "margin": "0px 0px 0px 0px"
            ]
        ]

        for (index, screenshot) in screenshots.enumerated() {
            elements.append([
                "tag": "img",
                "img_key": screenshot.imageKey,
                "alt": [
                    "tag": "plain_text",
                    "content": "截图 \(index + 1)"
                ]
            ])
            elements.append([
                "tag": "markdown",
                "content": "> \(screenshot.caption)",
                "text_size": "normal_v2",
                "margin": "4px 0px 0px 0px"
            ])
        }

        let card: [String: Any] = [
            "schema": "2.0",
            "config": [
                "update_multi": true
            ],
            "header": [
                "template": "blue",
                "title": [
                    "tag": "plain_text",
                    "content": headerTitle
                ]
            ],
            "body": [
                "direction": "vertical",
                "padding": "12px 12px 12px 12px",
                "elements": elements
            ]
        ]

        var payload: [String: Any] = [
            "msg_type": "interactive",
            "card": card
        ]

        let trimmedSigningSecret = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSigningSecret.isEmpty {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            payload["timestamp"] = timestamp
            payload["sign"] = sign(timestamp: timestamp, secret: trimmedSigningSecret)
        }

        return payload
    }

    /// Feishu signs the empty message using HMAC-SHA256 with
    /// `timestamp + "\\n" + secret` as the key, then Base64 encodes it.
    private func sign(timestamp: String, secret: String) -> String {
        let keyData = Data("\(timestamp)\n\(secret)".utf8)
        let key = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(), using: key)
        return Data(signature).base64EncodedString()
    }

    // MARK: - Validation and persistence

    /// Accept only the official custom-bot hook endpoints. In particular, do
    /// not allow a user-supplied arbitrary URL to turn note sharing into an
    /// accidental general-purpose data exfiltration feature.
    private func validatedWebhookURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              Self.allowedHosts.contains(host),
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil || components.query?.isEmpty == true,
              components.fragment == nil else {
            return nil
        }

        let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count == 5,
              pathComponents[0] == "open-apis",
              pathComponents[1] == "bot",
              pathComponents[2] == "v2",
              pathComponents[3] == "hook",
              !pathComponents[4].isEmpty,
              let url = components.url else {
            return nil
        }

        return url
    }

    private static let allowedHosts: Set<String> = [
        "open.feishu.cn",
        "open.larksuite.com"
    ]

    private func persistPublicConfiguration() {
        let currentConfig = config
        let publicConfiguration = PublicConfiguration(
            hasWebhook: currentConfig != nil,
            hasSigningSecret: !(currentConfig?.signingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasAppCredentials: !(currentConfig?.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && !(currentConfig?.appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            version: 1
        )

        if let data = try? JSONEncoder().encode(publicConfiguration) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    private func complete(
        _ result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Always complete asynchronously. UI callers can consistently hop to
        // the main actor, while this type remains usable from non-UI code.
        DispatchQueue.global(qos: .utility).async {
            completion(result)
        }
    }

    private struct FeishuAPIResponse: Decodable {
        let code: Int
        let message: String?

        enum CodingKeys: String, CodingKey {
            case code
            case message = "msg"
        }
    }

    private static let generatedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Errors

    enum FeishuError: LocalizedError {
        case notConfigured
        case invalidWebhookURL
        case payloadEncodingFailed
        case payloadTooLarge
        case invalidResponse
        case httpError(statusCode: Int, message: String?)
        case apiError(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "飞书群机器人尚未配置，请先在设置中粘贴 Webhook"
            case .invalidWebhookURL:
                return "飞书 Webhook 无效，请使用群自定义机器人提供的 HTTPS 地址"
            case .payloadEncodingFailed:
                return "飞书复盘内容无法编码"
            case .payloadTooLarge:
                return "复盘内容超过飞书机器人 20KB 限制，请缩短后重试"
            case .invalidResponse:
                return "飞书返回格式异常"
            case .httpError(let statusCode, let message):
                if let message, !message.isEmpty {
                    return "飞书请求失败（HTTP \(statusCode)）：\(message)"
                }
                return "飞书请求失败（HTTP \(statusCode)）"
            case .apiError(let code, let message):
                return "飞书机器人错误（\(code)）：\(message)"
            }
        }
    }
}
