import Foundation

// MARK: - NoteRecord

/// 笔记记录数据模型
///
/// 纯数据结构，不依赖任何 UI 框架
/// 持久化由 HistoryStore 负责Swift
///
/// 扩展字段（为未来 AI 总结 / 视频复盘预留）：
/// - videoTitle: 视频标题（未来通过 OCR / API 获取）
/// - videoURL: 视频链接
/// - videoTimestamp: 视频当前播放时间
/// - summary: AI 总结
/// - tags: 用户自定义标签
///
struct NoteRecord: Identifiable, Codable, Hashable {

    let id: UUID
    var content: String
    var contentType: ContentType
    var inputMethod: InputMethod
    var createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool

    // 未来扩展字段（当前为 nil）
    var videoTitle: String?
    var videoURL: String?
    var videoTimestamp: String?  // 如 "12:34"
    var summary: String?
    var tags: [String]

    // MARK: - ContentType

    enum ContentType: String, Codable {
        case plainText
        case markdown
    }

    // MARK: - InputMethod

    /// 输入方式：键盘 / 语音
    enum InputMethod: String, Codable {
        case keyboard
        case voice
    }

    // MARK: - Init

    init(
        content: String,
        contentType: ContentType = .plainText,
        inputMethod: InputMethod = .keyboard,
        isFavorite: Bool = false,
        videoTitle: String? = nil,
        videoURL: String? = nil,
        videoTimestamp: String? = nil,
        summary: String? = nil,
        tags: [String] = []
    ) {
        self.id = UUID()
        self.content = content
        self.contentType = contentType
        self.inputMethod = inputMethod
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isFavorite = isFavorite
        self.videoTitle = videoTitle
        self.videoURL = videoURL
        self.videoTimestamp = videoTimestamp
        self.summary = summary
        self.tags = tags
    }

    // MARK: - Time Group

    /// 时间分组类型
    enum TimeGroup: String, CaseIterable {
        case today
        case yesterday
        case lastWeek
        case older

        var displayName: String {
            switch self {
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .lastWeek: return "7 天内"
            case .older: return "更早"
            }
        }
    }

    /// 根据创建时间计算所属分组
    var timeGroup: TimeGroup {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(createdAt) {
            return .today
        } else if calendar.isDateInYesterday(createdAt) {
            return .yesterday
        } else if now.timeIntervalSince(createdAt) < 7 * 24 * 3600 {
            return .lastWeek
        } else {
            return .older
        }
    }
}
