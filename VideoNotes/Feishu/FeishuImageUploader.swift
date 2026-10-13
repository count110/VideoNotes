import Foundation

// MARK: - FeishuImageUploader

/// Uploads local screenshots to Feishu's `im/v1/images` endpoint so an
/// interactive card can embed them with an `img` element.
///
/// This requires a Feishu open-platform custom app (App ID + App Secret).
/// A plain custom-bot webhook cannot upload images; when app credentials are
/// missing the caller falls back to a text-only card.
final class FeishuImageUploader {

    static let shared = FeishuImageUploader()

    private struct TokenResponse: Decodable {
        let code: Int
        let message: String?
        let tenantAccessToken: String?
        let expire: Int?

        enum CodingKeys: String, CodingKey {
            case code, message
            case tenantAccessToken = "tenant_access_token"
            case expire
        }
    }

    private struct ImageUploadResponse: Decodable {
        struct Data: Decodable {
            let imageKey: String?
            enum CodingKeys: String, CodingKey { case imageKey = "image_key" }
        }
        let code: Int
        let message: String?
        let data: Data?
    }

    private enum UploadError: LocalizedError {
        case missingCredentials
        case tokenRequestFailed(String)
        case tokenResponseMissing
        case uploadFailed(String)
        case responseMissingImageKey

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "未配置飞书自建应用 App ID / App Secret"
            case .tokenRequestFailed(let message):
                return "获取飞书 token 失败: \(message)"
            case .tokenResponseMissing:
                return "飞书 token 响应无效"
            case .uploadFailed(let message):
                return "上传截图失败: \(message)"
            case .responseMissingImageKey:
                return "飞书未返回 image_key"
            }
        }
    }

    private init() {}

    /// Uploads all readable images and returns their Feishu `image_key`s.
    func uploadImages(
        at paths: [String],
        appID: String,
        appSecret: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let validPaths = paths.filter { path in
            guard !path.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: path)
        }

        guard !validPaths.isEmpty else {
            completion(.success([]))
            return
        }

        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAppID.isEmpty, !normalizedSecret.isEmpty else {
            completion(.failure(UploadError.missingCredentials))
            return
        }

        fetchTenantAccessToken(appID: normalizedAppID, appSecret: normalizedSecret) { tokenResult in
            switch tokenResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                self.uploadImages(at: validPaths, token: token, completion: completion)
            }
        }
    }

    // MARK: - Token

    private func fetchTenantAccessToken(
        appID: String,
        appSecret: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "app_id": appID,
            "app_secret": appSecret
        ])
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                completion(.failure(UploadError.tokenResponseMissing))
                return
            }
            guard tokenResponse.code == 0, let token = tokenResponse.tenantAccessToken else {
                completion(.failure(
                    UploadError.tokenRequestFailed(tokenResponse.message ?? "code \(tokenResponse.code)")
                ))
                return
            }
            completion(.success(token))
        }.resume()
    }

    // MARK: - Upload

    private func uploadImages(
        at paths: [String],
        token: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        var imageKeys: [String] = []

        func uploadNext(index: Int) {
            guard index < paths.count else {
                completion(.success(imageKeys))
                return
            }

            uploadImage(at: paths[index], token: token) { result in
                switch result {
                case .success(let key):
                    imageKeys.append(key)
                    uploadNext(index: index + 1)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }

        uploadNext(index: 0)
    }

    private func uploadImage(
        at path: String,
        token: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let imageData = FileManager.default.contents(atPath: path) else {
            completion(.failure(UploadError.uploadFailed("无法读取截图文件 \(path)")))
            return
        }

        let url = URL(string: "https://open.feishu.cn/open-apis/im/v1/images")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let boundary = "VideoNotes-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image_type\"\r\n\r\n".data(using: .utf8)!)
        body.append("message\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"clip.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let uploadResponse = try? JSONDecoder().decode(ImageUploadResponse.self, from: data) else {
                completion(.failure(UploadError.responseMissingImageKey))
                return
            }
            guard uploadResponse.code == 0, let imageKey = uploadResponse.data?.imageKey else {
                completion(.failure(
                    UploadError.uploadFailed(uploadResponse.message ?? "code \(uploadResponse.code)")
                ))
                return
            }
            completion(.success(imageKey))
        }.resume()
    }
}
