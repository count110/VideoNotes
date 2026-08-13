import AppKit

// MARK: - ClipboardManager

/// 剪贴板管理器
///
/// 使用 NSPasteboard 实现系统级剪贴板写入
/// 支持纯文本复制
///
final class ClipboardManager {

    static let shared = ClipboardManager()

    private init() {}

    // MARK: - Copy

    /// 复制文本到剪贴板
    /// - Parameter text: 要复制的文本
    func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Read

    /// 读取当前剪贴板内容
    func read() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}
