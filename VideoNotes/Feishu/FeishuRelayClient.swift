import Combine
import Foundation
import Security

// MARK: - Feishu Relay client

/// Connects one locally installed copy of VideoNotes to the server-side
/// Feishu relay.
///
/// The relay, rather than the Mac app, owns the Feishu App ID and App Secret.
/// This client only receives a short-lived pairing code from the user, creates
/// a random device token locally, and keeps that token in macOS Keychain. It
/// never stores a Feishu credential, group identifier, or bot secret.
///
/// After the user explicitly binds the device in a Feishu group, the client
/// uses HTTPS long-polling for a deliberately small command allow-list. Review
/// text is returned to the relay only for a command that came from that bound
/// group; the relay is responsible for posting the reply as the bot.
final class FeishuRelayClient: ObservableObject {

    static let shared = FeishuRelayClient()

    enum ConnectionState: Equatable {
        case notConfigured
        case pairing
        case pairingPending
        case awaitingGroupBinding
        case checking
        case connected
        case reconnecting
        case disconnecting
        case disconnectFailed
        case needsPairing

        var displayName: String {
            switch self {
            case .notConfigured:
                return "尚未连接"
            case .pairing:
                return "正在安全连接…"
            case .pairingPending:
                return "配对尚未完成"
            case .awaitingGroupBinding:
                return "等待飞书群绑定"
            case .checking:
                return "正在检查绑定状态…"
            case .connected:
                return "已连接，正在等待群内指令"
            case .reconnecting:
                return "连接暂时不可用，正在重试…"
            case .disconnecting:
                return "正在从飞书安全断开…"
            case .disconnectFailed:
                return "远程撤销未完成"
            case .needsPairing:
                return "连接已失效，需要重新配对"
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .notConfigured
    @Published private(set) var bindingInstruction: String?
    @Published private(set) var lastError: String?

    /// The relay's public base URL, never including a credential.
    var configuredBaseURL: String? {
        stateQueue.sync { configuration.relayBaseURL }
    }

    var isPaired: Bool {
        stateQueue.sync { activeCredentials() != nil }
    }

    /// True only after the relay has conclusively rejected the saved device
    /// token. The device cannot receive group commands anymore, so Settings
    /// may guide the user straight to a fresh pairing code instead of asking
    /// them to revoke an already-invalid connection.
    var requiresNewPairing: Bool {
        stateQueue.sync { configuration.credentialsRejectedByRelay }
    }

    /// A pairing attempt can be safely retried after a network interruption.
    /// Both the one-time code and its generated token are held in Keychain
    /// until the relay confirms the claim.
    var hasPendingPairing: Bool {
        stateQueue.sync { pendingPairing() != nil }
    }

    private enum BindingStatus: String {
        case awaitingGroupBinding = "awaiting_group_binding"
        case bound
        case pairingExpired = "pairing_expired"
    }

    private enum CommandResultStatus: String, Codable {
        case succeeded
        case failed
    }

    private struct PublicConfiguration: Codable {
        var version: Int
        var relayBaseURL: String?
        var deviceID: String?
        var installationID: String
        var pendingRelayBaseURL: String?
        /// A confirmed 401/403 means this token can no longer receive group
        /// commands. Persisting the fact lets a relaunch accept a fresh,
        /// user-entered pairing code without ever treating the old device as
        /// a live connection.
        var credentialsRejectedByRelay: Bool
        /// Retained if the user asks to disconnect but the relay cannot
        /// confirm revocation. Keeping this bit prevents a later relaunch
        /// from silently resuming group command polling.
        var remoteDisconnectPending: Bool

        init(
            version: Int = 1,
            relayBaseURL: String? = nil,
            deviceID: String? = nil,
            installationID: String = UUID().uuidString,
            pendingRelayBaseURL: String? = nil,
            credentialsRejectedByRelay: Bool = false,
            remoteDisconnectPending: Bool = false
        ) {
            self.version = version
            self.relayBaseURL = relayBaseURL
            self.deviceID = deviceID
            self.installationID = installationID
            self.pendingRelayBaseURL = pendingRelayBaseURL
            self.credentialsRejectedByRelay = credentialsRejectedByRelay
            self.remoteDisconnectPending = remoteDisconnectPending
        }

        enum CodingKeys: String, CodingKey {
            case version
            case relayBaseURL
            case deviceID
            case installationID
            case pendingRelayBaseURL
            case credentialsRejectedByRelay
            case remoteDisconnectPending
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            relayBaseURL = try container.decodeIfPresent(String.self, forKey: .relayBaseURL)
            deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
            installationID = try container.decodeIfPresent(String.self, forKey: .installationID)
                ?? UUID().uuidString
            pendingRelayBaseURL = try container.decodeIfPresent(
                String.self,
                forKey: .pendingRelayBaseURL
            )
            credentialsRejectedByRelay = try container.decodeIfPresent(
                Bool.self,
                forKey: .credentialsRejectedByRelay
            ) ?? false
            remoteDisconnectPending = try container.decodeIfPresent(
                Bool.self,
                forKey: .remoteDisconnectPending
            ) ?? false
        }
    }

    private struct ActiveCredentials {
        let baseURL: URL
        let deviceID: String
        let deviceToken: String
    }

    private struct PendingPairing {
        let baseURL: URL
        let code: String
        let deviceToken: String
    }

    private struct PairingClaimRequest: Encodable {
        let code: String
        let installationID: String
        let deviceName: String
        let deviceToken: String

        enum CodingKeys: String, CodingKey {
            case code
            case installationID = "installation_id"
            case deviceName = "device_name"
            case deviceToken = "device_token"
        }
    }

    private struct PairingClaimResponse: Decodable {
        let deviceID: String
        let bindingStatus: String
        let bindingCommand: String?

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case bindingStatus = "binding_status"
            case bindingCommand = "binding_command"
        }
    }

    private struct DeviceStatusResponse: Decodable {
        struct Binding: Decodable {
            let status: String
        }

        let deviceID: String
        let binding: Binding

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case binding
        }
    }

    private struct CommandEnvelope: Decodable {
        let command: RelayCommand?
    }

    private struct RelayCommand: Decodable {
        let id: String
        let type: String
    }

    private struct CommandResultPayload: Encodable {
        let status: String
        let replyText: String

        enum CodingKeys: String, CodingKey {
            case status
            case replyText = "reply_text"
        }
    }

    /// Only review content and non-secret routing identifiers are persisted.
    /// The Bearer token always remains in Keychain and is reconstructed only
    /// when a result is ready to be uploaded.
    private struct PersistedPendingCommandResult: Codable {
        let version: Int
        let relayBaseURL: String
        let deviceID: String
        let commandID: String
        let status: CommandResultStatus
        let replyText: String

        enum CodingKeys: String, CodingKey {
            case version
            case relayBaseURL = "relay_base_url"
            case deviceID = "device_id"
            case commandID = "command_id"
            case status
            case replyText = "reply_text"
        }
    }

    /// A durable receipt of a leased command. It is intentionally separate
    /// from the result payload so a crash while AI is generating cannot cause
    /// a second review to be generated on relaunch.
    private struct PersistedInFlightCommand: Codable {
        let version: Int
        let relayBaseURL: String
        let deviceID: String
        let commandID: String
        let commandType: String

        enum CodingKeys: String, CodingKey {
            case version
            case relayBaseURL = "relay_base_url"
            case deviceID = "device_id"
            case commandID = "command_id"
            case commandType = "command_type"
        }
    }

    private enum RemoteCommandState: String {
        case pending
        case leased
        case completed
        case expired
        case revoked
    }

    private struct CommandStatusResponse: Decodable {
        struct Command: Decodable {
            let id: String
            let state: String
        }

        let command: Command
    }

    private struct PendingCommandResult {
        let record: PersistedPendingCommandResult
        let credentials: ActiveCredentials

        var commandID: String { record.commandID }
        var status: CommandResultStatus { record.status }
        var replyText: String { record.replyText }
    }

    private let stateQueue = DispatchQueue(
        label: "com.videonotes.feishu-relay",
        qos: .utility
    )
    private let session = URLSession.shared
    private let configFile: URL
    private let pendingResultFile: URL
    private let inFlightCommandFile: URL

    private var configuration: PublicConfiguration
    private var isStarted = false
    private var bindingStatus: BindingStatus?
    private var claimTask: URLSessionDataTask?
    private var statusTask: URLSessionDataTask?
    private var pollTask: URLSessionDataTask?
    private var resultTask: URLSessionDataTask?
    private var commandStatusTask: URLSessionDataTask?
    private var disconnectTask: URLSessionDataTask?
    private var statusWorkItem: DispatchWorkItem?
    private var pollWorkItem: DispatchWorkItem?
    private var resultRetryWorkItem: DispatchWorkItem?
    private var commandRecoveryWorkItem: DispatchWorkItem?
    private var claimRequestID: UUID?
    private var statusRequestID: UUID?
    private var pollRequestID: UUID?
    private var resultRequestID: UUID?
    private var commandStatusRequestID: UUID?
    private var disconnectRequestID: UUID?
    /// Identifies the one ReviewManager callback that is still allowed to
    /// create a durable command result. URLSession tasks can be cancelled,
    /// but ReviewManager work cannot; invalidating this ID prevents a review
    /// that finishes after disconnect/rejection from reviving the old device.
    private var reviewExecutionID: UUID?
    private var pendingCommandResult: PendingCommandResult?
    private var inFlightCommand: PersistedInFlightCommand?
    private var resultRetryAttempt = 0
    private var isDisconnecting = false
    private static let deviceTokenKey = "feishu-relay-device-token"
    private static let pendingDeviceTokenKey = "feishu-relay-pending-device-token"
    private static let pendingPairingCodeKey = "feishu-relay-pending-pairing-code"
    private static let bindingInstructionKey = "feishu-relay-binding-instruction"
    private static let maximumReplyCodePoints = 12_000
    private static let statusCheckInterval: TimeInterval = 12

    private init() {
        let directory = ApplicationStorage.directory
        configFile = directory.appendingPathComponent("feishu_relay_config.json")
        pendingResultFile = directory.appendingPathComponent(
            "feishu_relay_pending_result.json"
        )
        inFlightCommandFile = directory.appendingPathComponent(
            "feishu_relay_in_flight_command.json"
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        configuration = Self.loadConfiguration(from: configFile) ?? PublicConfiguration()
        inFlightCommand = Self.loadPersistedRecord(
            PersistedInFlightCommand.self,
            from: inFlightCommandFile
        )
        if !FileManager.default.fileExists(atPath: configFile.path) {
            _ = persistConfiguration()
        }

        if configuration.remoteDisconnectPending,
           activeCredentials() != nil {
            connectionState = .disconnectFailed
            lastError = "上次断开未获 Relay 确认。请重试“断开此 Mac”。"
        } else if activeCredentials() != nil,
           let instruction = SecureStore.value(for: Self.bindingInstructionKey),
           !instruction.isEmpty {
            connectionState = .awaitingGroupBinding
            bindingInstruction = instruction
        }
    }

    // MARK: - Lifecycle

    /// Starts checking the relay only after an explicit pairing has completed.
    /// An unpaired app makes no relay request on launch.
    func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isStarted else { return }
            self.isStarted = true
            self.startIfReady()
        }
    }

    /// Stops long-polling and cancels in-flight requests. Credentials and any
    /// result already generated for a group command stay on disk, so normal
    /// relaunches can safely finish delivery instead of regenerating a review.
    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.cancelNetworkWork()
        }
    }

    // MARK: - Pairing

    /// Claims a relay-issued one-time code. The Mac creates the 32-byte device
    /// token before making the request, so safely retrying this exact claim is
    /// idempotent if a network response is lost.
    func pair(
        relayBaseURL: String,
        pairingCode: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }

            if self.activeCredentials() != nil,
               !self.configuration.credentialsRejectedByRelay {
                self.complete(.failure(RelayError.disconnectRequired), completion: completion)
                return
            }

            guard !self.configuration.remoteDisconnectPending else {
                self.complete(.failure(RelayError.remoteDisconnectPending), completion: completion)
                return
            }

            guard let baseURL = Self.validatedBaseURL(from: relayBaseURL) else {
                self.complete(.failure(RelayError.invalidBaseURL), completion: completion)
                return
            }

            let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, code.count <= 256 else {
                self.complete(.failure(RelayError.invalidPairingCode), completion: completion)
                return
            }

            guard let token = Self.makeDeviceToken() else {
                self.complete(.failure(RelayError.randomTokenGenerationFailed), completion: completion)
                return
            }

            let previousConfiguration = self.configuration
            let previousPendingToken = SecureStore.value(for: Self.pendingDeviceTokenKey)
            let previousPendingCode = SecureStore.value(for: Self.pendingPairingCodeKey)

            // Preserve a retryable pairing tuple before contacting the relay.
            guard SecureStore.save(token, for: Self.pendingDeviceTokenKey) else {
                self.complete(.failure(RelayError.keychainWriteFailed), completion: completion)
                return
            }
            guard SecureStore.save(code, for: Self.pendingPairingCodeKey) else {
                _ = SecureStore.save(
                    previousPendingToken ?? "",
                    for: Self.pendingDeviceTokenKey
                )
                _ = SecureStore.save(
                    previousPendingCode ?? "",
                    for: Self.pendingPairingCodeKey
                )
                self.complete(.failure(RelayError.keychainWriteFailed), completion: completion)
                return
            }

            self.configuration.pendingRelayBaseURL = baseURL.absoluteString
            guard case .success = self.persistConfiguration() else {
                // No relay request has been sent yet. Restore the complete
                // previous pending tuple, rather than leaving orphaned token
                // and code values whose base URL could not survive relaunch.
                self.configuration = previousConfiguration
                _ = SecureStore.save(
                    previousPendingToken ?? "",
                    for: Self.pendingDeviceTokenKey
                )
                _ = SecureStore.save(
                    previousPendingCode ?? "",
                    for: Self.pendingPairingCodeKey
                )
                let state: ConnectionState
                if self.pendingPairing() != nil {
                    state = .pairingPending
                } else if self.configuration.credentialsRejectedByRelay {
                    state = .needsPairing
                } else {
                    state = .notConfigured
                }
                self.publish(
                    state,
                    bindingInstruction: nil,
                    error: RelayError.configurationWriteFailed.localizedDescription
                )
                self.complete(
                    .failure(RelayError.configurationWriteFailed),
                    completion: completion
                )
                return
            }
            self.cancelNetworkWork()
            self.bindingStatus = nil
            self.publish(.pairing, bindingInstruction: nil, error: nil)

            self.claim(
                PendingPairing(baseURL: baseURL, code: code, deviceToken: token),
                completion: completion
            )
        }
    }

    /// Retries a claim that was interrupted after the local token/code had
    /// already been written to Keychain. The relay accepts the same tuple only
    /// for the same installation and token.
    func resumePendingPairing(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard let pending = self.pendingPairing() else {
                self.complete(.failure(RelayError.noPendingPairing), completion: completion)
                return
            }

            self.cancelNetworkWork()
            self.publish(.pairing, bindingInstruction: nil, error: nil)
            self.claim(pending, completion: completion)
        }
    }

    /// Revokes this Mac at the relay before clearing local credentials. Local
    /// state is removed only after the relay returns exactly HTTP 204. This
    /// avoids presenting an unpaired UI while the old device could still
    /// receive commands from the bound Feishu group.
    func disconnect(completion: @escaping (Result<Void, Error>) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isDisconnecting else {
                self.complete(.failure(RelayError.disconnectInProgress), completion: completion)
                return
            }
            guard let credentials = self.activeCredentials() else {
                self.complete(.failure(RelayError.noActiveConnection), completion: completion)
                return
            }
            guard !self.configuration.credentialsRejectedByRelay else {
                self.complete(
                    .failure(RelayError.connectionAlreadyRejected),
                    completion: completion
                )
                return
            }

            let wasRemoteDisconnectPending = self.configuration.remoteDisconnectPending
            self.configuration.remoteDisconnectPending = true
            guard case .success = self.persistConfiguration() else {
                self.configuration.remoteDisconnectPending = wasRemoteDisconnectPending
                self.publish(
                    .disconnectFailed,
                    bindingInstruction: nil,
                    error: "无法安全保存断开状态，尚未向 Relay 发送撤销请求。请检查磁盘后重试。"
                )
                self.complete(
                    .failure(RelayError.configurationWriteFailed),
                    completion: completion
                )
                return
            }

            self.isDisconnecting = true
            self.cancelNetworkWork(invalidateReviewExecution: true)
            self.bindingStatus = nil
            self.publish(.disconnecting, bindingInstruction: nil, error: nil)
            self.revokeRemoteDevice(credentials, completion: completion)
        }
    }

    /// Discards an unclaimed local pairing tuple. This is intentionally
    /// separate from `disconnect`: without a confirmed device ID there is no
    /// remotely bound Mac to revoke yet.
    func cancelPendingPairing(completion: @escaping () -> Void = {}) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.cancelNetworkWork()
            self.configuration.pendingRelayBaseURL = nil
            _ = self.persistConfiguration()
            _ = SecureStore.save("", for: Self.pendingDeviceTokenKey)
            _ = SecureStore.save("", for: Self.pendingPairingCodeKey)
            self.publish(.notConfigured, bindingInstruction: nil, error: nil)
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Lets Settings update the visible binding state without restarting the
    /// app. Command long-polling still begins only after `bound` is confirmed.
    func refreshStatus() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.configuration.remoteDisconnectPending else {
                self.publish(
                    .disconnectFailed,
                    bindingInstruction: nil,
                    error: "上次断开未获 Relay 确认。请重试“断开此 Mac”。"
                )
                return
            }
            guard !self.configuration.credentialsRejectedByRelay else {
                self.publish(
                    .needsPairing,
                    bindingInstruction: nil,
                    error: "Relay 已拒绝当前设备令牌，请使用新的配对码重新连接。"
                )
                return
            }
            guard self.activeCredentials() != nil else {
                self.publish(.notConfigured, bindingInstruction: nil, error: nil)
                return
            }
            self.requestStatus()
        }
    }

    // MARK: - Claiming and status

    private func claim(
        _ pending: PendingPairing,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        claimTask?.cancel()
        let requestID = UUID()
        claimRequestID = requestID

        let body = PairingClaimRequest(
            code: pending.code,
            installationID: configuration.installationID,
            // Avoid sending the user's Mac name to the relay. This stable
            // product label is enough to identify the device in setup logs.
            deviceName: "VideoNotes Mac",
            deviceToken: pending.deviceToken
        )

        guard let request = makeJSONRequest(
            url: endpoint(baseURL: pending.baseURL, path: ["v1", "pairing", "claim"]),
            method: "POST",
            token: nil,
            body: body,
            timeout: 30
        ) else {
            complete(.failure(RelayError.invalidBaseURL), completion: completion)
            return
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async {
                guard self.claimRequestID == requestID else { return }
                self.claimTask = nil
                self.claimRequestID = nil

                if let error {
                    self.handlePairingFailure(error, completion: completion)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    self.handlePairingFailure(RelayError.invalidResponse, completion: completion)
                    return
                }

                guard (200...299).contains(response.statusCode) else {
                    self.handlePairingFailure(
                        self.responseError(statusCode: response.statusCode, data: data),
                        completion: completion
                    )
                    return
                }

                guard let data,
                      let claim = try? JSONDecoder().decode(PairingClaimResponse.self, from: data),
                      !claim.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.handlePairingFailure(RelayError.invalidResponse, completion: completion)
                    return
                }

                self.finishClaim(claim, pending: pending, completion: completion)
            }
        }
        claimTask = task
        task.resume()
    }

    private func finishClaim(
        _ response: PairingClaimResponse,
        pending: PendingPairing,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let previousConfiguration = configuration
        let previousDeviceToken = SecureStore.value(for: Self.deviceTokenKey)
        let previousBindingInstruction = SecureStore.value(for: Self.bindingInstructionKey)

        guard SecureStore.save(pending.deviceToken, for: Self.deviceTokenKey) else {
            // Keep the pending tuple intact; repeating the same claim later
            // returns the same device ID and can finish this local write.
            handlePairingFailure(RelayError.keychainWriteFailed, completion: completion)
            return
        }

        let instruction = response.bindingCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeInstruction = instruction?.isEmpty == false ? instruction! : "绑定 \(pending.code)"
        guard SecureStore.save(safeInstruction, for: Self.bindingInstructionKey) else {
            _ = SecureStore.save(previousDeviceToken ?? "", for: Self.deviceTokenKey)
            handlePairingFailure(RelayError.keychainWriteFailed, completion: completion)
            return
        }

        configuration.relayBaseURL = pending.baseURL.absoluteString
        configuration.deviceID = response.deviceID
        configuration.pendingRelayBaseURL = nil
        configuration.credentialsRejectedByRelay = false
        configuration.remoteDisconnectPending = false
        guard case .success = persistConfiguration() else {
            // The relay claim is idempotent, so roll the in-memory/public
            // activation back and leave the pending Keychain tuple untouched.
            // A retry will receive the same device ID and can finish safely.
            configuration = previousConfiguration
            _ = SecureStore.save(previousDeviceToken ?? "", for: Self.deviceTokenKey)
            _ = SecureStore.save(
                previousBindingInstruction ?? "",
                for: Self.bindingInstructionKey
            )
            handlePairingFailure(
                RelayError.configurationWriteFailed,
                completion: completion
            )
            return
        }
        // A successful fresh pairing deliberately starts with no unconfirmed
        // result from an older device. Those records cannot be safely sent to
        // the new group/device token.
        discardPersistedCommandState()
        _ = SecureStore.save("", for: Self.pendingDeviceTokenKey)
        _ = SecureStore.save("", for: Self.pendingPairingCodeKey)

        bindingStatus = BindingStatus(rawValue: response.bindingStatus)
            ?? .awaitingGroupBinding
        applyBindingStatus(bindingStatus ?? .awaitingGroupBinding)
        complete(.success(()), completion: completion)
    }

    private func handlePairingFailure(
        _ error: Error,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        publish(.pairingPending, bindingInstruction: nil, error: error.localizedDescription)
        complete(.failure(error), completion: completion)
    }

    private func startIfReady() {
        guard !configuration.remoteDisconnectPending else {
            publish(
                .disconnectFailed,
                bindingInstruction: nil,
                error: "上次断开未获 Relay 确认。请重试“断开此 Mac”。"
            )
            return
        }
        guard !configuration.credentialsRejectedByRelay else {
            publish(
                .needsPairing,
                bindingInstruction: nil,
                error: "Relay 已拒绝当前设备令牌，请使用新的配对码重新连接。"
            )
            return
        }
        guard activeCredentials() != nil else {
            if pendingPairing() != nil {
                publish(.pairingPending, bindingInstruction: nil, error: nil)
            } else {
                publish(.notConfigured, bindingInstruction: nil, error: nil)
            }
            return
        }
        requestStatus()
    }

    private func requestStatus() {
        guard !isDisconnecting,
              !configuration.remoteDisconnectPending,
              !configuration.credentialsRejectedByRelay else {
            return
        }

        guard let credentials = activeCredentials() else {
            publish(.notConfigured, bindingInstruction: nil, error: nil)
            return
        }

        statusTask?.cancel()
        let requestID = UUID()
        statusRequestID = requestID
        let instruction = SecureStore.value(for: Self.bindingInstructionKey)
        publish(.checking, bindingInstruction: instruction, error: nil)

        guard let request = makeJSONRequest(
            url: endpoint(
                baseURL: credentials.baseURL,
                // Relay exposes device binding state at the device resource
                // itself: GET /v1/devices/{device_id}.
                path: ["v1", "devices", credentials.deviceID]
            ),
            method: "GET",
            token: credentials.deviceToken,
            body: Optional<String>.none,
            timeout: 30
        ) else {
            handleStatusFailure(RelayError.invalidBaseURL)
            return
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async {
                guard self.statusRequestID == requestID else { return }
                self.statusTask = nil
                self.statusRequestID = nil

                if let error {
                    self.handleStatusFailure(error)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    self.handleStatusFailure(RelayError.invalidResponse)
                    return
                }

                if response.statusCode == 401 || response.statusCode == 403 {
                    self.handleAuthorizationFailure()
                    return
                }

                guard (200...299).contains(response.statusCode),
                      let data,
                      let status = try? JSONDecoder().decode(DeviceStatusResponse.self, from: data),
                      status.deviceID == credentials.deviceID,
                      let bindingStatus = BindingStatus(rawValue: status.binding.status) else {
                    let error = (200...299).contains(response.statusCode)
                        ? RelayError.invalidResponse
                        : self.responseError(statusCode: response.statusCode, data: data)
                    self.handleStatusFailure(error)
                    return
                }

                self.bindingStatus = bindingStatus
                self.applyBindingStatus(bindingStatus)
            }
        }
        statusTask = task
        task.resume()
    }

    private func applyBindingStatus(_ status: BindingStatus) {
        switch status {
        case .awaitingGroupBinding:
            let instruction = SecureStore.value(for: Self.bindingInstructionKey)
            publish(.awaitingGroupBinding, bindingInstruction: instruction, error: nil)
            guard isStarted else { return }
            scheduleStatusCheck(after: Self.statusCheckInterval)

        case .bound:
            _ = SecureStore.save("", for: Self.bindingInstructionKey)
            publish(.connected, bindingInstruction: nil, error: nil)
            guard isStarted,
                  let credentials = activeCredentials() else { return }
            recoverPersistedCommandState(using: credentials)

        case .pairingExpired:
            // The original code is no longer accepted for group binding even
            // though the relay keeps this unbound claim briefly for a lost
            // claim-response retry. Persist the invalidation so Settings can
            // safely offer a fresh code rather than polling forever.
            invalidateConnection(
                message: "群绑定配对码已过期，请使用新的配对码重新连接。"
            )
        }
    }

    private func handleStatusFailure(_ error: Error) {
        let instruction = SecureStore.value(for: Self.bindingInstructionKey)
        publish(.reconnecting, bindingInstruction: instruction, error: error.localizedDescription)
        guard isStarted else { return }
        scheduleStatusCheck(after: Self.statusCheckInterval)
    }

    @discardableResult
    private func handleAuthorizationFailure() -> Bool {
        return invalidateConnection(message: "安全连接已失效，请使用新的配对码重新连接。")
    }

    @discardableResult
    private func invalidateConnection(message: String) -> Bool {
        let previousConfiguration = configuration
        configuration.credentialsRejectedByRelay = true
        // A 401/403 is conclusive evidence that this token cannot receive any
        // more commands. It is therefore also the only safe escape hatch from
        // a pending disconnect whose server-side revocation tombstone expired.
        configuration.remoteDisconnectPending = false
        cancelNetworkWork(invalidateReviewExecution: true)
        guard case .success = persistConfiguration() else {
            // Do not unlock fresh pairing unless rejection is durable. This
            // avoids a newly bound device running alongside state that would
            // relaunch as the old live connection.
            configuration = previousConfiguration
            let state: ConnectionState = previousConfiguration.remoteDisconnectPending
                ? .disconnectFailed
                : .reconnecting
            publish(
                state,
                bindingInstruction: nil,
                error: "Relay 已拒绝当前令牌，但本机无法安全保存该状态。请检查磁盘后重试。"
            )
            return false
        }
        _ = SecureStore.save("", for: Self.bindingInstructionKey)
        publish(
            .needsPairing,
            bindingInstruction: nil,
            error: message
        )
        return true
    }

    // MARK: - Long polling and command execution

    private func startLongPoll(after delay: TimeInterval = 0) {
        guard isStarted,
              !isDisconnecting,
              !configuration.remoteDisconnectPending,
              bindingStatus == .bound,
              pollTask == nil,
              resultTask == nil,
              commandStatusTask == nil,
              pendingCommandResult == nil,
              let credentials = activeCredentials() else {
            return
        }

        if delay > 0 {
            pollWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.startLongPoll()
            }
            pollWorkItem = item
            stateQueue.asyncAfter(deadline: .now() + delay, execute: item)
            return
        }

        guard var components = URLComponents(
            url: endpoint(
                baseURL: credentials.baseURL,
                path: ["v1", "devices", credentials.deviceID, "commands"]
            ),
            resolvingAgainstBaseURL: false
        ) else {
            handleStatusFailure(RelayError.invalidBaseURL)
            return
        }
        components.queryItems = [URLQueryItem(name: "wait_seconds", value: "25")]
        guard let url = components.url,
              let request = makeJSONRequest(
                url: url,
                method: "GET",
                token: credentials.deviceToken,
                body: Optional<String>.none,
                timeout: 35
              ) else {
            handleStatusFailure(RelayError.invalidBaseURL)
            return
        }

        let requestID = UUID()
        pollRequestID = requestID
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async {
                guard self.pollRequestID == requestID else { return }
                self.pollTask = nil
                self.pollRequestID = nil

                if let error {
                    self.handlePollFailure(error)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    self.handlePollFailure(RelayError.invalidResponse)
                    return
                }

                if response.statusCode == 401 || response.statusCode == 403 {
                    self.handleAuthorizationFailure()
                    return
                }

                if response.statusCode == 204 {
                    self.startLongPoll(after: 0.15)
                    return
                }

                guard (200...299).contains(response.statusCode),
                      let data,
                      let envelope = try? JSONDecoder().decode(CommandEnvelope.self, from: data),
                      let command = envelope.command,
                      self.isValid(command: command) else {
                    let error = (200...299).contains(response.statusCode)
                        ? RelayError.invalidResponse
                        : self.responseError(statusCode: response.statusCode, data: data)
                    self.handlePollFailure(error)
                    return
                }

                self.execute(command: command, credentials: credentials)
            }
        }
        pollTask = task
        task.resume()
    }

    private func isValid(command: RelayCommand) -> Bool {
        let id = command.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = command.type.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && id.count <= 256 && !type.isEmpty && type.count <= 128
    }

    private func handlePollFailure(_ error: Error) {
        let instruction = SecureStore.value(for: Self.bindingInstructionKey)
        publish(.reconnecting, bindingInstruction: instruction, error: error.localizedDescription)
        guard isStarted, bindingStatus == .bound else { return }
        startLongPoll(after: Self.statusCheckInterval)
    }

    private func execute(command: RelayCommand, credentials: ActiveCredentials) {
        guard let request = RelayReviewRequest(rawValue: command.type) else {
            submitCommandResult(
                commandID: command.id,
                status: .failed,
                replyText: "该指令暂不受本机 VideoNotes 支持。",
                credentials: credentials
            )
            return
        }

        let receipt = PersistedInFlightCommand(
            version: 1,
            relayBaseURL: credentials.baseURL.absoluteString,
            deviceID: credentials.deviceID,
            commandID: command.id,
            commandType: command.type
        )

        if let existing = inFlightCommand,
           existing.commandID != command.id {
            // There should only ever be one leased command at a time. Keep
            // the original receipt and wait for a verified terminal state
            // instead of accidentally generating a second review.
            publish(
                .reconnecting,
                bindingInstruction: nil,
                error: "正在确认上一条飞书复盘请求的状态。"
            )
            recoverPersistedCommandState(using: credentials)
            return
        }

        if inFlightCommand == nil {
            guard persistInFlightCommand(receipt) else {
                publish(
                    .connected,
                    bindingInstruction: nil,
                    error: "无法安全保存飞书复盘任务，稍后会由 Relay 重新投递。"
                )
                startLongPoll(after: Self.statusCheckInterval)
                return
            }
            inFlightCommand = receipt
        }

        let executionID = UUID()
        reviewExecutionID = executionID

        // ReviewManager owns observable UI state, so it transitions on the
        // main queue. The relay never opens a window, changes focus, or writes
        // the generated review to the clipboard.
        ReviewManager.shared.executeRelayRequest(request) { [weak self] outcome in
            guard let self else { return }
            self.stateQueue.async {
                guard self.reviewExecutionID == executionID,
                      self.canUse(credentials: credentials) else {
                    return
                }
                self.reviewExecutionID = nil
                switch outcome {
                case .success(let reply):
                    self.submitCommandResult(
                        commandID: command.id,
                        status: .succeeded,
                        replyText: reply,
                        credentials: credentials
                    )
                case .failure(let error):
                    self.submitCommandResult(
                        commandID: command.id,
                        status: .failed,
                        replyText: "VideoNotes 无法完成这次复盘：\(error.localizedDescription)",
                        credentials: credentials
                    )
                }
            }
        }
    }

    // MARK: - Command result upload

    private func submitCommandResult(
        commandID: String,
        status: CommandResultStatus,
        replyText: String,
        credentials: ActiveCredentials
    ) {
        guard canUse(credentials: credentials) else { return }

        let record = PersistedPendingCommandResult(
            version: 1,
            relayBaseURL: credentials.baseURL.absoluteString,
            deviceID: credentials.deviceID,
            commandID: commandID,
            status: status,
            replyText: Self.boundedReply(replyText)
        )
        guard persistPendingCommandResult(record) else {
            publish(
                .connected,
                bindingInstruction: nil,
                error: "复盘已生成，但暂时无法安全保存待发送结果。"
            )
            return
        }

        // The result has reached durable storage before its first upload. It
        // is now safe to retire the pre-generation receipt even if the app is
        // terminated while the network request is in flight.
        clearInFlightCommand()
        pendingCommandResult = PendingCommandResult(
            record: record,
            credentials: credentials
        )
        resultRetryAttempt = 0
        postPendingCommandResult()
    }

    private func postPendingCommandResult() {
        guard let pending = pendingCommandResult,
              resultTask == nil,
              canUse(credentials: pending.credentials) else {
            return
        }

        guard let request = makeJSONRequest(
            url: endpoint(
                baseURL: pending.credentials.baseURL,
                path: [
                    "v1",
                    "devices",
                    pending.credentials.deviceID,
                    "commands",
                    pending.commandID,
                    "result"
                ]
            ),
            method: "POST",
            token: pending.credentials.deviceToken,
            body: CommandResultPayload(status: pending.status.rawValue, replyText: pending.replyText),
            timeout: 30
        ) else {
            scheduleResultRetry(after: 5, error: RelayError.invalidBaseURL)
            return
        }

        let requestID = UUID()
        resultRequestID = requestID
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async {
                guard self.resultRequestID == requestID else { return }
                self.resultTask = nil
                self.resultRequestID = nil

                if let error {
                    self.scheduleResultRetry(error: error)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    self.scheduleResultRetry(error: RelayError.invalidResponse)
                    return
                }

                if response.statusCode == 401 || response.statusCode == 403 {
                    self.handleAuthorizationFailure()
                    return
                }

                if (200...299).contains(response.statusCode) {
                    self.clearPendingCommandResult()
                    self.resultRetryAttempt = 0
                    self.publish(.connected, bindingInstruction: nil, error: nil)
                    self.startLongPoll(after: 0.1)
                    return
                }

                // A result that has already become terminal elsewhere should
                // not be retried or cause a duplicate bot message.
                if response.statusCode == 404 || response.statusCode == 409 {
                    self.clearPendingCommandResult()
                    self.resultRetryAttempt = 0
                    self.startLongPoll(after: 0.1)
                    return
                }

                self.scheduleResultRetry(
                    error: self.responseError(statusCode: response.statusCode, data: data)
                )
            }
        }
        resultTask = task
        task.resume()
    }

    private func scheduleResultRetry(after delay: TimeInterval? = nil, error: Error) {
        guard pendingCommandResult != nil else { return }
        resultRetryAttempt += 1
        let computedDelay = delay ?? min(60, pow(2, Double(min(resultRetryAttempt, 6))))
        publish(
            .connected,
            bindingInstruction: nil,
            error: "复盘已生成，正在重试发送到飞书：\(error.localizedDescription)"
        )
        resultRetryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.postPendingCommandResult()
        }
        resultRetryWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + computedDelay, execute: item)
    }

    // MARK: - Recovery after relaunch

    /// Rebuilds any delivery that was already safely written before a prior
    /// process stopped. A completed AI result is always preferred over the
    /// in-flight receipt, so retries use the exact same command ID and text.
    private func recoverPersistedCommandState(using credentials: ActiveCredentials) {
        guard isStarted,
              !isDisconnecting,
              !configuration.remoteDisconnectPending else {
            return
        }

        if pendingCommandResult != nil || resultTask != nil {
            postPendingCommandResult()
            return
        }

        if let record = Self.loadPersistedRecord(
            PersistedPendingCommandResult.self,
            from: pendingResultFile
        ) {
            guard isCompatible(record: record, with: credentials) else {
                publish(
                    .reconnecting,
                    bindingInstruction: nil,
                    error: "发现属于另一条 Relay 连接的待发送复盘，未向当前群发送。"
                )
                startLongPoll(after: Self.statusCheckInterval)
                return
            }

            pendingCommandResult = PendingCommandResult(
                record: record,
                credentials: credentials
            )
            resultRetryAttempt = 0
            postPendingCommandResult()
            return
        }

        if let receipt = inFlightCommand ?? Self.loadPersistedRecord(
            PersistedInFlightCommand.self,
            from: inFlightCommandFile
        ) {
            inFlightCommand = receipt
            guard isCompatible(receipt: receipt, with: credentials) else {
                // A receipt for a previously invalidated device cannot safely
                // be replayed through a newly paired device. It also must not
                // block normal commands for the new, independent connection.
                inFlightCommand = nil
                publish(
                    .reconnecting,
                    bindingInstruction: nil,
                    error: "发现属于另一台已失效连接的复盘任务，未重新生成。"
                )
                startLongPoll(after: 0.1)
                return
            }
            inspectInFlightCommand(receipt, credentials: credentials)
            return
        }

        startLongPoll()
    }

    /// A receipt without a saved result is intentionally never re-run. The
    /// status request distinguishes a completed/expired command from a leased
    /// one, and a live leased/pending command receives a deterministic failure
    /// reply rather than a second, potentially costly AI generation.
    private func inspectInFlightCommand(
        _ receipt: PersistedInFlightCommand,
        credentials: ActiveCredentials
    ) {
        guard commandStatusTask == nil,
              canUse(credentials: credentials) else { return }

        guard let request = makeJSONRequest(
            url: endpoint(
                baseURL: credentials.baseURL,
                path: [
                    "v1",
                    "devices",
                    credentials.deviceID,
                    "commands",
                    receipt.commandID
                ]
            ),
            method: "GET",
            token: credentials.deviceToken,
            body: Optional<String>.none,
            timeout: 30
        ) else {
            scheduleCommandRecovery(after: 5, error: RelayError.invalidBaseURL)
            return
        }

        let requestID = UUID()
        commandStatusRequestID = requestID
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async {
                guard self.commandStatusRequestID == requestID else { return }
                self.commandStatusTask = nil
                self.commandStatusRequestID = nil

                if let error {
                    self.scheduleCommandRecovery(error: error)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    self.scheduleCommandRecovery(error: RelayError.invalidResponse)
                    return
                }

                if response.statusCode == 401 || response.statusCode == 403 {
                    self.handleAuthorizationFailure()
                    return
                }

                // The relay has already pruned this request. The local
                // receipt is terminal and must not prevent later commands.
                if response.statusCode == 404 {
                    self.clearInFlightCommand()
                    self.startLongPoll(after: 0.1)
                    return
                }

                guard (200...299).contains(response.statusCode),
                      let data,
                      let status = try? JSONDecoder().decode(CommandStatusResponse.self, from: data),
                      status.command.id == receipt.commandID,
                      let state = RemoteCommandState(rawValue: status.command.state) else {
                    let failure = (200...299).contains(response.statusCode)
                        ? RelayError.invalidResponse
                        : self.responseError(statusCode: response.statusCode, data: data)
                    self.scheduleCommandRecovery(error: failure)
                    return
                }

                switch state {
                case .completed, .expired, .revoked:
                    self.clearInFlightCommand()
                    self.startLongPoll(after: 0.1)

                case .pending, .leased:
                    // The old process cannot still be running after a new
                    // launch, but it may have stopped between leasing this
                    // command and atomically writing its result. Never issue
                    // another AI request in that ambiguous window.
                    self.submitCommandResult(
                        commandID: receipt.commandID,
                        status: .failed,
                        replyText: "VideoNotes 在生成这次复盘时意外中断，请重新 @VideoNotes 复盘发起一次。",
                        credentials: credentials
                    )
                }
            }
        }
        commandStatusTask = task
        task.resume()
    }

    private func scheduleCommandRecovery(
        after delay: TimeInterval? = nil,
        error: Error
    ) {
        guard let credentials = activeCredentials(),
              let receipt = inFlightCommand,
              isStarted,
              canUse(credentials: credentials) else {
            return
        }

        let retryDelay = delay ?? Self.statusCheckInterval
        publish(
            .reconnecting,
            bindingInstruction: nil,
            error: "正在确认上次飞书复盘的状态：\(error.localizedDescription)"
        )
        commandRecoveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inspectInFlightCommand(receipt, credentials: credentials)
        }
        commandRecoveryWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + retryDelay, execute: item)
    }

    // MARK: - Remote disconnect

    private func revokeRemoteDevice(
        _ credentials: ActiveCredentials,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let request = makeJSONRequest(
            url: endpoint(
                baseURL: credentials.baseURL,
                path: ["v1", "devices", credentials.deviceID]
            ),
            method: "DELETE",
            token: credentials.deviceToken,
            body: Optional<String>.none,
            timeout: 30
        ) else {
            finishDisconnectFailure(RelayError.invalidBaseURL, completion: completion)
            return
        }

        let requestID = UUID()
        disconnectRequestID = requestID
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async {
                guard self.disconnectRequestID == requestID else { return }
                self.disconnectTask = nil
                self.disconnectRequestID = nil

                if let error {
                    self.finishDisconnectFailure(error, completion: completion)
                    return
                }

                guard let response = response as? HTTPURLResponse else {
                    self.finishDisconnectFailure(RelayError.invalidResponse, completion: completion)
                    return
                }

                if response.statusCode == 401 || response.statusCode == 403 {
                    // The relay no longer accepts this token. This is safe to
                    // treat as a completed local disconnect even if a prior
                    // 204 response was lost and its revocation tombstone has
                    // since expired. Other errors keep the retry lock intact.
                    self.isDisconnecting = false
                    let rejectionWasPersisted = self.handleAuthorizationFailure()
                    self.complete(
                        .failure(
                            rejectionWasPersisted
                                ? RelayError.connectionAlreadyRejected
                                : RelayError.configurationWriteFailed
                        ),
                        completion: completion
                    )
                    return
                }

                // A successful remote revoke is deliberately strict. The
                // relay returns 204 for both its first accepted revoke and a
                // same-token retry against its short-lived revocation record.
                guard response.statusCode == 204 else {
                    self.finishDisconnectFailure(
                        self.responseError(statusCode: response.statusCode, data: data),
                        completion: completion
                    )
                    return
                }

                let result = self.finishSuccessfulDisconnect()
                self.complete(result, completion: completion)
            }
        }
        disconnectTask = task
        task.resume()
    }

    private func finishSuccessfulDisconnect() -> Result<Void, Error> {
        let previousConfiguration = configuration
        let previousBindingStatus = bindingStatus
        isDisconnecting = false
        bindingStatus = nil
        configuration.relayBaseURL = nil
        configuration.deviceID = nil
        configuration.pendingRelayBaseURL = nil
        configuration.credentialsRejectedByRelay = false
        configuration.remoteDisconnectPending = false
        guard case .success = persistConfiguration() else {
            // The server is already revoked, but retaining the durable pending
            // marker and token allows an idempotent retry instead of relaunching
            // into an impossible half-cleared local state.
            configuration = previousConfiguration
            bindingStatus = previousBindingStatus
            publish(
                .disconnectFailed,
                bindingInstruction: nil,
                error: "Relay 已撤销此 Mac，但本机暂时无法保存结果。请检查磁盘后重试断开。"
            )
            return .failure(RelayError.configurationWriteFailed)
        }

        _ = SecureStore.save("", for: Self.deviceTokenKey)
        _ = SecureStore.save("", for: Self.pendingDeviceTokenKey)
        _ = SecureStore.save("", for: Self.pendingPairingCodeKey)
        _ = SecureStore.save("", for: Self.bindingInstructionKey)
        // The remote device is now revoked. Any retained result belongs to it
        // and must not be sent through a future, newly paired device.
        discardPersistedCommandState()
        publish(.notConfigured, bindingInstruction: nil, error: nil)
        return .success(())
    }

    private func finishDisconnectFailure(
        _ error: Error,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        isDisconnecting = false
        configuration.remoteDisconnectPending = true
        _ = persistConfiguration()
        publish(
            .disconnectFailed,
            bindingInstruction: nil,
            error: "远程撤销未完成：\(error.localizedDescription)"
        )
        complete(.failure(error), completion: completion)
    }

    // MARK: - Request helpers

    private func endpoint(baseURL: URL, path: [String]) -> URL {
        path.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private func makeJSONRequest<Body: Encodable>(
        url: URL,
        method: String,
        token: String?,
        body: Body?,
        timeout: TimeInterval
    ) -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            guard let data = try? JSONEncoder().encode(body) else { return nil }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        return request
    }

    private func responseError(statusCode: Int, data: Data?) -> Error {
        let message = data.flatMap(Self.apiMessage(from:))
        return RelayError.httpError(statusCode: statusCode, message: message)
    }

    private static func apiMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let value = object["message"] ?? object["detail"] ?? object["error"]
        guard let text = value as? String else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(240))
    }

    // MARK: - Local persistence

    private func activeCredentials() -> ActiveCredentials? {
        guard let rawBaseURL = configuration.relayBaseURL,
              let baseURL = Self.validatedBaseURL(from: rawBaseURL),
              let deviceID = configuration.deviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceID.isEmpty,
              let token = SecureStore.value(for: Self.deviceTokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        return ActiveCredentials(baseURL: baseURL, deviceID: deviceID, deviceToken: token)
    }

    private func pendingPairing() -> PendingPairing? {
        guard let rawBaseURL = configuration.pendingRelayBaseURL,
              let baseURL = Self.validatedBaseURL(from: rawBaseURL),
              let code = SecureStore.value(for: Self.pendingPairingCodeKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty,
              let token = SecureStore.value(for: Self.pendingDeviceTokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return PendingPairing(baseURL: baseURL, code: code, deviceToken: token)
    }

    /// Rejects stale AI and transport callbacks from an old device without
    /// affecting normal retries for the currently active credentials.
    private func canUse(credentials: ActiveCredentials) -> Bool {
        guard !isDisconnecting,
              !configuration.remoteDisconnectPending,
              !configuration.credentialsRejectedByRelay,
              let active = activeCredentials() else {
            return false
        }

        return active.baseURL == credentials.baseURL
            && active.deviceID == credentials.deviceID
            && active.deviceToken == credentials.deviceToken
    }

    private func isCompatible(
        record: PersistedPendingCommandResult,
        with credentials: ActiveCredentials
    ) -> Bool {
        record.version == 1
            && record.relayBaseURL == credentials.baseURL.absoluteString
            && record.deviceID == credentials.deviceID
            && !record.commandID.isEmpty
    }

    private func isCompatible(
        receipt: PersistedInFlightCommand,
        with credentials: ActiveCredentials
    ) -> Bool {
        receipt.version == 1
            && receipt.relayBaseURL == credentials.baseURL.absoluteString
            && receipt.deviceID == credentials.deviceID
            && !receipt.commandID.isEmpty
    }

    @discardableResult
    private func persistPendingCommandResult(
        _ record: PersistedPendingCommandResult
    ) -> Bool {
        persistRecord(record, to: pendingResultFile)
    }

    @discardableResult
    private func persistInFlightCommand(
        _ receipt: PersistedInFlightCommand
    ) -> Bool {
        persistRecord(receipt, to: inFlightCommandFile)
    }

    @discardableResult
    private func persistRecord<Record: Encodable>(_ record: Record, to file: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("[FeishuRelay] 无法保存待处理的群复盘：\(error.localizedDescription)")
            return false
        }
    }

    private static func loadPersistedRecord<Record: Decodable>(
        _ type: Record.Type,
        from file: URL
    ) -> Record? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func clearPendingCommandResult() {
        pendingCommandResult = nil
        removePersistedRecord(at: pendingResultFile)
    }

    private func clearInFlightCommand() {
        inFlightCommand = nil
        removePersistedRecord(at: inFlightCommandFile)
    }

    private func discardPersistedCommandState() {
        pendingCommandResult = nil
        inFlightCommand = nil
        removePersistedRecord(at: pendingResultFile)
        removePersistedRecord(at: inFlightCommandFile)
    }

    private func removePersistedRecord(at file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            // Keeping a result on disk is safer than pretending delivery has
            // completed. It will be retried idempotently on the next launch.
            NSLog("[FeishuRelay] 无法清除已完成的群复盘缓存：\(error.localizedDescription)")
        }
    }

    @discardableResult
    private func persistConfiguration() -> Result<Void, Error> {
        do {
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: configFile, options: .atomic)
            return .success(())
        } catch {
            NSLog("[FeishuRelay] 无法保存非敏感配置：\(error.localizedDescription)")
            return .failure(error)
        }
    }

    private static func loadConfiguration(from file: URL) -> PublicConfiguration? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PublicConfiguration.self, from: data)
    }

    private static func validatedBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil || components.query?.isEmpty == true,
              components.fragment == nil else {
            return nil
        }

        components.scheme = "https"
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") && components.path.count > 1 {
            components.path.removeLast()
        }
        return components.url
    }

    private static func makeDeviceToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func boundedReply(_ text: String) -> String {
        guard text.unicodeScalars.count > maximumReplyCodePoints else { return text }

        let suffix = "\n\n（内容较长，已截断）"
        let allowedScalars = max(0, maximumReplyCodePoints - suffix.unicodeScalars.count)
        var truncated = String()
        for scalar in text.unicodeScalars.prefix(allowedScalars) {
            truncated.unicodeScalars.append(scalar)
        }
        return truncated + suffix
    }

    // MARK: - Scheduling and UI publication

    private func scheduleStatusCheck(after delay: TimeInterval) {
        statusWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.requestStatus()
        }
        statusWorkItem = item
        stateQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels active transport only. It deliberately leaves persisted review
    /// receipts and results intact for recovery after the next launch.
    private func cancelNetworkWork(
        includeDisconnect: Bool = false,
        invalidateReviewExecution: Bool = false
    ) {
        claimTask?.cancel()
        statusTask?.cancel()
        pollTask?.cancel()
        resultTask?.cancel()
        commandStatusTask?.cancel()
        if includeDisconnect {
            disconnectTask?.cancel()
        }
        claimTask = nil
        statusTask = nil
        pollTask = nil
        resultTask = nil
        commandStatusTask = nil
        if includeDisconnect {
            disconnectTask = nil
        }
        claimRequestID = nil
        statusRequestID = nil
        pollRequestID = nil
        resultRequestID = nil
        commandStatusRequestID = nil
        if includeDisconnect {
            disconnectRequestID = nil
        }
        if invalidateReviewExecution {
            reviewExecutionID = nil
        }
        statusWorkItem?.cancel()
        pollWorkItem?.cancel()
        resultRetryWorkItem?.cancel()
        commandRecoveryWorkItem?.cancel()
        statusWorkItem = nil
        pollWorkItem = nil
        resultRetryWorkItem = nil
        commandRecoveryWorkItem = nil
        // In-memory delivery state can be recreated from the on-disk record.
        pendingCommandResult = nil
        resultRetryAttempt = 0
    }

    private func publish(
        _ state: ConnectionState,
        bindingInstruction: String?,
        error: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectionState = state
            self.bindingInstruction = bindingInstruction
            self.lastError = error
        }
    }

    private func complete(
        _ result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    // MARK: - Errors

    enum RelayError: LocalizedError {
        case invalidBaseURL
        case invalidPairingCode
        case randomTokenGenerationFailed
        case keychainWriteFailed
        case configurationWriteFailed
        case noPendingPairing
        case noActiveConnection
        case disconnectInProgress
        case disconnectRequired
        case remoteDisconnectPending
        case connectionAlreadyRejected
        case invalidResponse
        case httpError(statusCode: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Relay 服务地址无效，请使用 HTTPS 地址"
            case .invalidPairingCode:
                return "配对码无效"
            case .randomTokenGenerationFailed:
                return "无法生成安全的设备令牌"
            case .keychainWriteFailed:
                return "无法将安全凭据保存到此 Mac 的钥匙串"
            case .configurationWriteFailed:
                return "无法安全保存 Relay 配置，请检查磁盘后重试"
            case .noPendingPairing:
                return "没有可继续的配对请求"
            case .noActiveConnection:
                return "当前没有可断开的 Relay 连接"
            case .disconnectInProgress:
                return "正在安全断开此 Mac"
            case .disconnectRequired:
                return "请先安全断开当前的 Relay 连接，再连接新的群"
            case .remoteDisconnectPending:
                return "上次远程撤销尚未完成，请先重试断开此 Mac"
            case .connectionAlreadyRejected:
                return "Relay 已拒绝当前设备令牌，请直接使用新的配对码重新连接"
            case .invalidResponse:
                return "Relay 返回格式异常"
            case .httpError(let statusCode, let message):
                if let message, !message.isEmpty {
                    return "Relay 请求失败（HTTP \(statusCode)）：\(message)"
                }
                return "Relay 请求失败（HTTP \(statusCode)）"
            }
        }
    }
}
