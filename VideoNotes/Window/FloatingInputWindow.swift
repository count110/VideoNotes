import AppKit
import SwiftUI
import QuartzCore

// MARK: - FloatingInputPanel

/// 全局悬浮输入面板
///
/// 修复多全屏窗口切换问题：
///
/// 1. **NSPanel + .nonactivatingPanel** — 天生 floating
/// 2. **collectionBehavior 包含 .moveToActiveSpace** — 窗口跟随用户当前 Space
/// 3. **每次 show() 先 orderOut 再重新定位** — 不复用旧窗口状态
/// 4. **激活顺序：activate → setActivationPolicy → makeKeyAndOrderFront → firstResponder**
/// 5. **屏幕定位：使用鼠标所在屏幕，不读取其他 App 的窗口数据**
/// 6. **重试机制：show() 失败时最多重试 3 次**
/// 7. **窗口不缓存失效状态：每次 show 重置 collectionBehavior 和 level**
///
final class FloatingInputPanel: NSPanel {

    // MARK: - Properties

    private var previousActiveApp: NSRunningApplication?
    private let viewModel = InputViewModel()
    private var showRetryCount = 0
    private let maxShowRetries = 3

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: FloatingInputLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 窗口基础属性
        self.isOpaque = false
        self.backgroundColor = .clear
        // The glass card owns its restrained shadow. A second window-level
        // shadow follows the rectangular transparent panel and creates a dark
        // outline around the entire hit area on bright backgrounds.
        self.hasShadow = false
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false
        self.isFloatingPanel = true
        self.animationBehavior = .none

        // SwiftUI 内容
        let hostView = NSHostingView(rootView:
            FloatingInputView(viewModel: viewModel)
        )
        hostView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hostView

        // 回调
        viewModel.onCommit = { [weak self] text in
            self?.handleCommit(text)
        }
        viewModel.onDismiss = { [weak self] in
            self?.handleDismiss()
        }
    }

    // MARK: - Key Window 支持

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show

    func show() {
        showRetryCount = 0
        showInternal()
    }

    private func showInternal() {
        showRetryCount += 1
        NSLog("📐 [VN] showInternal attempt #\(showRetryCount)")

        // ━━ 1. 记录当前活跃 App；重试时不能把自己覆盖成“前一个 App” ━━
        if showRetryCount == 1 {
            previousActiveApp = NSWorkspace.shared.frontmostApplication
            viewModel.reset()
        }
        NSLog("📐 [VN] 1. frontmostApp: \(previousActiveApp?.localizedName ?? "nil")")

        // ━━ 2. 如果窗口已存在但状态异常，先清除 ━━
        if self.isVisible {
            NSLog("📐 [VN] 2. 窗口已可见，先 orderOut")
            self.orderOut(nil)
        }

        // ━━ 3. 重置窗口属性 ━━
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        self.level = .floating
        NSLog("📐 [VN] 3. collectionBehavior/level 已设置")

        // ━━ 4. 定位窗口 ━━
        positionOnActiveScreen()
        NSLog("📐 [VN] 4. positionOnActiveScreen 完成")

        // ━━ 5. 激活 App ━━
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("📐 [VN] 5. activate 完成")

        // ━━ 6. 显示窗口 ━━
        self.alphaValue = 0
        self.setFrameOrigin(NSPoint(x: self.frame.origin.x, y: self.frame.origin.y - 8))
        self.makeKeyAndOrderFront(nil)
        NSLog("📐 [VN] 6. makeKeyAndOrderFront 完成")

        // ━━ 7. 再次激活 ━━
        NSApp.activate(ignoringOtherApps: true)
        self.makeKey()
        NSLog("📐 [VN] 7. makeKey 完成")

        // ━━ 8. 淡入动画 ━━
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
            self.animator().setFrameOrigin(NSPoint(x: self.frame.origin.x, y: self.frame.origin.y + 8))
        }
        NSLog("📐 [VN] 8. 动画完成")

        // ━━ 9. first responder ━━
        DispatchQueue.main.async { [weak self] in
            self?.makeFirstResponderForKey()
        }

        // ━━ 10. 验证 ━━
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            let isVis = self.isVisible
            let isKey = self.isKeyWindow
            let screen = self.screen?.localizedName ?? "nil"
            NSLog("📐 [VN] 验证: isVisible=\(isVis) isKey=\(isKey) screen=\(screen)")

            if !isVis || !isKey {
                if self.showRetryCount < self.maxShowRetries {
                    NSLog("📐 [VN] 显示失败，重试 #\(self.showRetryCount + 1)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.showInternal()
                    }
                } else {
                    NSLog("📐 [VN] 重试上限，放弃")
                }
            }
        }
    }

    // MARK: - Hide

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            self.viewModel.reset()
            self.restorePreviousApp()
        })
    }

    // MARK: - Toggle

    func toggle() {
        if self.isVisible && self.alphaValue > 0.1 {
            handleDismiss()
        } else {
            show()
        }
    }

    // MARK: - First Responder

    private func makeFirstResponderForKey() {
        guard let contentView = self.contentView else { return }

        // 递归找到 NSTextView
        if let textView = findTextView(in: contentView) {
            self.makeFirstResponder(textView)
            textView.window?.makeKey()
            return
        }

        // 回退：让 hostingView 成为 first responder
        if contentView.acceptsFirstResponder {
            self.makeFirstResponder(contentView)
        }
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Positioning

    /// 定位到用户正在操作的屏幕。
    ///
    /// 不要通过 CGWindowListCopyWindowInfo 读取前台 App 的窗口位置：
    /// macOS 26+ 会把该访问归入“设备控制和数据访问”，导致每次唤出
    /// 输入框时都可能显示系统隐私提示。鼠标位置属于本 App 可安全读取的
    /// 全局状态，也能自然支持外接显示器和全屏视频场景。
    private func positionOnActiveScreen() {
        NSLog("📐 [VN] positionOnActiveScreen 开始")
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else {
            NSLog("📐 [VN] 无可用屏幕")
            return
        }
        NSLog("📐 [VN] 定位到鼠标屏幕: \(targetScreen.localizedName)")

        let screenFrame = targetScreen.visibleFrame
        let windowFrame = self.frame
        let x = screenFrame.midX - windowFrame.width / 2
        // 屏幕下方 1/4 处，不遮挡视频主体
        let y = screenFrame.minY + screenFrame.height * 0.18
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Commit

    private func handleCommit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handleDismiss()
            return
        }

        // 复制到剪贴板
        ClipboardManager.shared.copy(text: trimmed)

        // 保存历史
        HistoryStore.shared.add(content: trimmed)

        // 显示 Toast 后关闭
        viewModel.showToast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.hide()
        }
    }

    // MARK: - Dismiss

    private func handleDismiss() {
        hide()
    }

    // MARK: - Restore Previous App

    private func restorePreviousApp() {
        // 恢复为菜单栏 App
        NSApp.setActivationPolicy(.accessory)

        // 激活之前的 App（视频播放器）
        if let prevApp = previousActiveApp, prevApp.isTerminated == false {
            prevApp.activate(options: [.activateAllWindows])
        }

        previousActiveApp = nil
    }

    // MARK: - ESC

    override func cancelOperation(_ sender: Any?) {
        handleDismiss()
    }
}
