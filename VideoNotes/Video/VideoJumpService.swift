import AppKit
import Foundation

// MARK: - VideoJumpService

/// 负责把一条笔记跳回它对应的视频时间点。
///
/// 现有项目没有播放器控制 / Accessibility / Player Adapter 层，所以第一版采用：
/// 1. 有 videoURL 时，对已知视频站点（YouTube / Bilibili）或直接视频文件 URL 追加时间戳后打开；
/// 2. 没有 URL 时，重新激活保存笔记时的来源 App；
/// 3. 两者都没有时，复制时间点到剪贴板，给用户一个轻提示。
///
/// 后续如果增加播放器 Adapter，只需要替换本服务内部实现。
final class VideoJumpService {

    static let shared = VideoJumpService()

    private init() {}

    @discardableResult
    func jump(to record: NoteRecord) -> Bool {
        let timestamp = Self.displayTimestamp(for: record)

        if let url = jumpURL(for: record) {
            NSWorkspace.shared.open(url)
            return true
        }

        if let bundleIdentifier = record.sourceBundleIdentifier,
           let sourceApp = NSRunningApplication
               .runningApplications(withBundleIdentifier: bundleIdentifier)
               .first(where: { !$0.isTerminated }) {
            sourceApp.activate(options: [.activateAllWindows])
            ClipToastWindow.show(message: "已回到 \(sourceApp.localizedName ?? "原视频") · \(timestamp)")
            return true
        }

        ClipboardManager.shared.copy(text: timestamp)
        ClipToastWindow.show(message: "已复制时间点 \(timestamp)")
        return false
    }

    // MARK: - URL

    func jumpURL(for record: NoteRecord) -> URL? {
        guard let rawURL = record.videoURL, !rawURL.isEmpty,
              let originalURL = URL(string: rawURL) else {
            return nil
        }

        guard let seconds = record.videoTimestampSeconds, seconds >= 0 else {
            return originalURL
        }

        guard var components = URLComponents(
            url: originalURL,
            resolvingAgainstBaseURL: false
        ) else {
            return originalURL
        }

        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()

        if host.contains("youtube.com") || host.contains("youtu.be") {
            components.queryItems = replacingTQueryItem(
                in: components.queryItems,
                seconds: seconds
            )
            return components.url ?? originalURL
        }

        if host.contains("bilibili.com") {
            components.queryItems = replacingTQueryItem(
                in: components.queryItems,
                seconds: seconds
            )
            return components.url ?? originalURL
        }

        if path.hasSuffix(".mp4")
            || path.hasSuffix(".m4v")
            || path.hasSuffix(".mov")
            || path.hasSuffix(".m3u8") {
            components.fragment = "t=\(Int(seconds))"
            return components.url ?? originalURL
        }

        // 普通网页 URL 不确定追加时间戳是否有效，保持原样打开，避免破坏链接。
        return originalURL
    }

    private func replacingTQueryItem(
        in queryItems: [URLQueryItem]?,
        seconds: TimeInterval
    ) -> [URLQueryItem] {
        var items = queryItems?.filter { $0.name != "t" } ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(seconds))))
        return items
    }

    static func displayTimestamp(for record: NoteRecord) -> String {
        if let seconds = record.videoTimestampSeconds {
            return VideoSession.formattedTimestamp(for: seconds)
        }
        return record.videoTimestamp ?? "--:--"
    }
}
