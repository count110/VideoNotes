import Foundation

// MARK: - NoteRecord

/// 笔记记录数据模型
///
/// 纯数据结构，不依赖任何 UI 框架
/// 持久化由 HistoryStore 负责Swift
///
/// 扩展字段（为未来 AI 总结 / 视频复盘预留）：
/// - videoTitle: 视频标题
/// - videoURL: 视频链接
/// - videoTimestamp: 视频当前播放时间（显示文本，兼容早期 JSON）
/// - videoSessionID / videoTimestampSeconds: Video Session 的稳定关联与排序时间
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

    // 视频扩展字段。所有字段均为 Optional，保证已存在的 JSON 可直接解码。
    var videoTitle: String?
    var videoURL: String?
    var videoTimestamp: String?  // 如 "12:34"
    var videoSessionID: UUID?
    var videoTimestampSeconds: TimeInterval?
    var summary: String?

    // 截图笔记扩展字段。
    // screenshotPath 指向本地 PNG；sourceBundleIdentifier / sourceApplicationName
    // 用于以后跳回原播放器（没有 URL 时至少能重新激活来源 App）。
    var screenshotPath: String?
    var sourceBundleIdentifier: String?
    var sourceApplicationName: String?

    var tags: [String]

    // MARK: - ContentType

    enum ContentType: String, Codable {
        case plainText
        case markdown
        case screenshot
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
        videoSessionID: UUID? = nil,
        videoTimestampSeconds: TimeInterval? = nil,
        summary: String? = nil,
        screenshotPath: String? = nil,
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil,
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
        self.videoSessionID = videoSessionID
        self.videoTimestampSeconds = videoTimestampSeconds
        self.summary = summary
        self.screenshotPath = screenshotPath
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceApplicationName = sourceApplicationName
        self.tags = tags
    }

    // MARK: - Screenshot Clip

    /// 是否为截图笔记。
    /// 兼容只写了 screenshotPath 的旧/手动构造数据。
    var isScreenshotClip: Bool {
        contentType == .screenshot || screenshotPath != nil
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
