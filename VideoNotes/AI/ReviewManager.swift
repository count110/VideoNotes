import Foundation
import Combine

// MARK: - ReviewManager

/// A snapshot of one completed video review. Keeping this separate from the
/// generic `lastReview` prevents a later today/week review from being shown
/// under the wrong video session in History.
struct VideoReviewResult: Identifiable, Hashable {
    let sessionID: UUID
    let title: String
    let markdown: String
    let generatedAt: Date
    let records: [NoteRecord]

    var id: UUID { sessionID }
}

/// A failure tied to the specific video request that produced it. Keeping this
/// distinct from `lastError` prevents an unrelated today/week review error
/// from appearing beneath a video group in History.
struct VideoReviewFailure: Hashable {
    let sessionID: UUID
    let message: String
}

/// The intentionally small set of commands which a bound Feishu relay is
/// allowed to ask this Mac to perform. The relay itself validates that the
/// command came from the one bound group; VideoNotes validates this allow-list
/// again before any local note content is generated or returned.
enum RelayReviewRequest: String {
    case generateCurrentVideoReview = "generate_current_video_review"
    case generateTodayReview = "generate_today_review"
    case sendCurrentVideoReview = "send_current_video_review"
}

/// 复盘管理器
///
/// 串联流程：
/// 1. 从 HistoryStore 获取笔记
/// 2. 调用 AISummarizer 生成复盘
/// 3. 在用户明确要求时调用 FeishuPusher 推送到飞书群
///
/// 同时支持：
/// - 生成复盘但不推送（仅复制到剪贴板）
/// - 选择时间范围（今天/昨天/本周/全部）
///
final class ReviewManager: ObservableObject {

    static let shared = ReviewManager()

    @Published var isGenerating: Bool = false
    @Published var lastReview: String?
    @Published var lastError: String?
    /// One-shot success event for opening the matching dashboard. The result
    /// itself remains available in `videoReviewResults` for later viewing.
    let videoReviewCompleted = PassthroughSubject<VideoReviewResult, Never>()
    let videoReviewFailed = PassthroughSubject<VideoReviewFailure, Never>()
    @Published private(set) var videoReviewResults: [UUID: VideoReviewResult] = [:]

    private init() {}

    // MARK: - Time Range

    enum TimeRange: String, CaseIterable {
        case today
        case yesterday
        case thisWeek
        case all

        var displayName: String {
            switch self {
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .thisWeek: return "本周"
            case .all: return "全部"
            }
        }

        func filter(records: [NoteRecord]) -> [NoteRecord] {
            let calendar = Calendar.current
            let now = Date()

            switch self {
            case .today:
                return records.filter { calendar.isDateInToday($0.createdAt) }
            case .yesterday:
                return records.filter { calendar.isDateInYesterday($0.createdAt) }
            case .thisWeek:
                let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
                return records.filter { $0.createdAt >= weekAgo }
            case .all:
                return records
            }
        }
    }

    // MARK: - Generate & Feishu Push

    /// Generates a review and, as part of this explicit user action, sends it
    /// to the configured Feishu group bot. Reviews are never sent merely
    /// because they were generated or copied locally.
    func generateAndPushToFeishu(timeRange: TimeRange) {
        generate(timeRange: timeRange, pushToFeishu: true)
    }

    /// Generates a review locally without sending it. In the Pro target,
    /// explicit daily reviews are also archived for the local Feishu reader.
    func generateOnly(timeRange: TimeRange) {
        generate(timeRange: timeRange, pushToFeishu: false)
    }

    /// Returns the in-memory result for one explicit video session.
    ///
    /// Results intentionally stay local to the current app run for now: this
    /// lets us provide the visual dashboard without changing the established
    /// note JSON schema or introducing an upgrade/migration risk.
    func videoReview(for sessionID: UUID) -> VideoReviewResult? {
        videoReviewResults[sessionID]
    }

    /// Generates a review for one explicit Video Session and copies it locally.
    /// Its visual dashboard owns its separate, user-initiated Feishu action;
    /// generating the dashboard must never send a message by itself.
    func generateVideoReview(sessionID: UUID) {
        guard !isGenerating else { return }

        let records = HistoryStore.shared.records.filter { $0.videoSessionID == sessionID }
        guard !records.isEmpty else {
            let message = "这个视频会话还没有笔记记录"
            lastError = message
            videoReviewFailed.send(
                VideoReviewFailure(sessionID: sessionID, message: message)
            )
            return
        }

        let title = records.compactMap(\.videoTitle).first ?? "视频会话"
        isGenerating = true
        lastError = nil

        AISummarizer.shared.generateVideoReview(sessionTitle: title, records: records) { result in
            DispatchQueue.main.async {
                self.isGenerating = false
                switch result {
                case .success(let review):
                    let videoReview = VideoReviewResult(
                        sessionID: sessionID,
                        title: title,
                        markdown: review,
                        generatedAt: Date(),
                        records: records
                    )
                    // Publish the session-specific result first. History then
                    // receives the completion signal only after it can open the
                    // matching dashboard immediately.
                    self.videoReviewResults[sessionID] = videoReview
                    self.lastReview = review
                    self.videoReviewCompleted.send(videoReview)
                    ClipboardManager.shared.copy(text: review)
                case .failure(let error):
                    let message = error.localizedDescription
                    self.lastError = message
                    self.videoReviewFailed.send(
                        VideoReviewFailure(sessionID: sessionID, message: message)
                    )
                }
            }
        }
    }

    // MARK: - Private

    private func generate(timeRange: TimeRange, pushToFeishu: Bool) {
        guard !isGenerating else { return }

        let records = timeRange.filter(records: HistoryStore.shared.records)
#if VIDEONOTES_ENHANCED
        // Capture the intended calendar day before the asynchronous AI request
        // starts. A request crossing midnight must still be archived under the
        // day the user asked to review.
        let archiveDate = dailyArchiveDate(for: timeRange, referenceDate: Date())
#endif

        guard !records.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "选定范围内没有笔记记录"
            }
            return
        }

        // Check before invoking AI so an explicit "generate and send" action
        // cannot appear to succeed locally when there is no destination for it.
        guard !pushToFeishu || FeishuPusher.shared.isConfigured else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "飞书群机器人尚未配置，请先在设置 → 飞书推送中添加 Webhook。"
            }
            return
        }

        isGenerating = true
        lastError = nil

        AISummarizer.shared.generateReview(records: records) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let review):
                    self.lastReview = review
                    ClipboardManager.shared.copy(text: review)
#if VIDEONOTES_ENHANCED
                    if let archiveDate {
                        self.archiveDailyReview(
                            review,
                            date: archiveDate,
                            noteCount: records.count
                        )
                    }
#endif

                    if pushToFeishu {
                        // Keep this operation active until Feishu confirms the
                        // result, which also prevents a second review request
                        // from racing the outbound payload.
                        self.pushToFeishu(
                            review: review,
                            records: records,
                            generatedAt: Date()
                        )
                    } else {
                        self.isGenerating = false
                    }

                case .failure(let error):
                    self.isGenerating = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

#if VIDEONOTES_ENHANCED
    private func dailyArchiveDate(for timeRange: TimeRange, referenceDate: Date) -> Date? {
        switch timeRange {
        case .today:
            return DailyReviewArchive.date(for: .today, relativeTo: referenceDate)
        case .yesterday:
            return DailyReviewArchive.date(for: .yesterday, relativeTo: referenceDate)
        case .thisWeek, .all:
            return nil
        }
    }

    private func archiveDailyReview(_ review: String, date: Date, noteCount: Int) {
        do {
            let url = try DailyReviewArchive.write(
                markdown: review,
                reviewDate: date,
                noteCount: noteCount
            )
            NSLog("[DailyReviewArchive] 已归档每日复盘：\(url.path)")
        } catch {
            // The AI result is still valid and is already copied/pushed. Keep
            // the failure local rather than turning a successful review into a
            // failed one, while leaving an actionable diagnostic in Console.
            NSLog("[DailyReviewArchive] 保存每日复盘失败：\(error.localizedDescription)")
        }
    }
#endif

    private func pushToFeishu(
        review: String,
        records: [NoteRecord],
        generatedAt: Date
    ) {
        let title = "VideoNotes 复盘（\(records.count) 条笔记）"

        FeishuPusher.shared.pushVideoReview(
            title: title,
            markdown: review,
            records: records,
            generatedAt: generatedAt
        ) { result in
            DispatchQueue.main.async {
                self.isGenerating = false
                switch result {
                case .success:
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = "飞书推送失败: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Bound Relay Commands

    /// Executes a review request received from the locally paired Feishu
    /// relay. This is deliberately separate from the normal menu actions:
    /// it does not activate VideoNotes, open a window, copy to the clipboard,
    /// or use the manually configured custom-bot webhook. The resulting text
    /// goes back only through the relay that has already verified the bound
    /// Feishu group.
    func executeRelayRequest(
        _ request: RelayReviewRequest,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(.failure(RelayReviewError.unavailable))
                return
            }
            self.executeRelayRequestOnMain(request, completion: completion)
        }
    }

    private func executeRelayRequestOnMain(
        _ request: RelayReviewRequest,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !isGenerating else {
            completion(.failure(RelayReviewError.busy))
            return
        }

        switch request {
        case .generateTodayReview:
            generateTodayRelayReview(completion: completion)
        case .generateCurrentVideoReview, .sendCurrentVideoReview:
            generateCurrentVideoRelayReview(
                sentFromGroup: request == .sendCurrentVideoReview,
                completion: completion
            )
        }
    }

    private func generateTodayRelayReview(
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let records = TimeRange.today.filter(records: HistoryStore.shared.records)
        guard !records.isEmpty else {
            completion(.failure(RelayReviewError.noTodayRecords))
            return
        }

        isGenerating = true
        lastError = nil
        AISummarizer.shared.generateReview(records: records) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.failure(RelayReviewError.unavailable))
                    return
                }
                self.isGenerating = false
                switch result {
                case .success(let review):
                    self.lastReview = review
                    completion(.success("## 今日复盘（\(records.count) 条笔记）\n\n\(review)"))
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    private func generateCurrentVideoRelayReview(
        sentFromGroup: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let sessionID = currentRelayVideoSessionID() else {
            completion(.failure(RelayReviewError.noCurrentVideo))
            return
        }

        let records = HistoryStore.shared.records.filter { $0.videoSessionID == sessionID }
        guard !records.isEmpty else {
            completion(.failure(RelayReviewError.noCurrentVideoNotes))
            return
        }

        let title = records.compactMap(\.videoTitle).first ?? "视频会话"
        isGenerating = true
        lastError = nil

        AISummarizer.shared.generateVideoReview(sessionTitle: title, records: records) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.failure(RelayReviewError.unavailable))
                    return
                }
                self.isGenerating = false

                switch result {
                case .success(let review):
                    let videoReview = VideoReviewResult(
                        sessionID: sessionID,
                        title: title,
                        markdown: review,
                        generatedAt: Date(),
                        records: records
                    )
                    // Keep the result available for the local dashboard but do
                    // not emit `videoReviewCompleted`: a group command must
                    // never make a floating utility app open UI by itself.
                    self.videoReviewResults[sessionID] = videoReview
                    self.lastReview = review
                    let prefix = sentFromGroup
                        ? "## 当前视频复盘 · \(title)"
                        : "## 当前视频复盘 · \(title)"
                    completion(.success("\(prefix)\n\n\(review)"))
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    private func currentRelayVideoSessionID() -> UUID? {
#if VIDEONOTES_ENHANCED
        if let sessionID = EnhancedMediaSessionCoordinator.shared
            .captureContext(at: Date())?.sessionID {
            return sessionID
        }
#endif
        return VideoSessionManager.shared.currentSession?.id
    }
}

private enum RelayReviewError: LocalizedError {
    case unavailable
    case busy
    case noTodayRecords
    case noCurrentVideo
    case noCurrentVideoNotes

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "VideoNotes 当前不可用"
        case .busy:
            return "VideoNotes 正在生成另一份复盘，请稍后再试"
        case .noTodayRecords:
            return "今天还没有可复盘的笔记"
        case .noCurrentVideo:
            return "没有当前视频会话，请先在 Mac 上开始视频会话"
        case .noCurrentVideoNotes:
            return "当前视频会话还没有笔记"
        }
    }
}
