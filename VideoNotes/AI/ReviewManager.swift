import Foundation
import Combine

// MARK: - ReviewManager

/// 复盘管理器
///
/// 串联流程：
/// 1. 从 HistoryStore 获取笔记
/// 2. 调用 AISummarizer 生成复盘
/// 3. 调用 WeChatPusher 推送到微信
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

    // MARK: - Generate & Push

    /// 生成复盘并推送到微信
    func generateAndPush(timeRange: TimeRange) {
        generate(timeRange: timeRange, pushToWeChat: true)
    }

    /// 仅生成复盘（复制到剪贴板）
    func generateOnly(timeRange: TimeRange) {
        generate(timeRange: timeRange, pushToWeChat: false)
    }

    // MARK: - Private

    private func generate(timeRange: TimeRange, pushToWeChat: Bool) {
        let records = timeRange.filter(records: HistoryStore.shared.records)

        guard !records.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "选定范围内没有笔记记录"
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isGenerating = true
            self?.lastError = nil
        }

        AISummarizer.shared.generateReview(records: records) { result in
            DispatchQueue.main.async {
                self.isGenerating = false

                switch result {
                case .success(let review):
                    self.lastReview = review
                    ClipboardManager.shared.copy(text: review)

                    if pushToWeChat {
                        self.pushToWeChat(review: review, count: records.count)
                    }

                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func pushToWeChat(review: String, count: Int) {
        let title = "VideoNotes 复盘（\(count) 条笔记）"

        WeChatPusher.shared.push(title: title, content: review) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = "微信推送失败: \(error.localizedDescription)"
                }
            }
        }
    }
}
