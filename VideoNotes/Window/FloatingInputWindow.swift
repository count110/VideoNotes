import AppKit
import SwiftUI
import QuartzCore
import Combine

// MARK: - FloatingInputPanel

/// 全局悬浮输入面板
///
/// 修复多全屏窗口切换问题：
///
/// 1. **NSPanel + .nonactivatingPanel** — 天生 floating
/// 2. **collectionBehavior 包含 .moveToActiveSpace** — 窗口跟随用户当前 Space
/// 3. **显示重试不 orderOut** — 保留 first responder 与输入法候选状态
/// 4. **激活顺序：setActivationPolicy → activate → makeKeyAndOrderFront → firstResponder**
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
    private var stateObservation: AnyCancellable?
    private var targetScreen: NSScreen?
    /// Invalidates delayed show/hide callbacks from an older presentation.
    /// Without this token, a completed fade-out can hide a panel that has
    /// already been reopened, and a stale retry can steal focus mid-composition.
    private var presentationGeneration = 0
    private var commitInProgress = false

    /// 输入框打开前正在使用的 App。输入框打开时按 ⌥C，会优先截这个 App 的窗口，
    /// 避免把输入框自己截进去。
    var previousAppBundleIdentifier: String? {
        previousActiveApp?.bundleIdentifier
    }

    // MARK: - Init

    init() {
        let initialCardWidth = FloatingInputLayout.cardWidth(for: NSScreen.main)
        super.init(
            contentRect: NSRect(
                origin: .zero,
                size: FloatingInputLayout.panelSize(
                    cardWidth: initialCardWidth,
                    state: .writing
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 窗口基础属性
        self.isOpaque = false
        self.backgroundColor = .clear
        // The glass card owns its restrained shadow. The surrounding window
        // is only a transparent canvas for that shape-specific shadow; it must
        // never paint a rectangular surface on bright video or slide content.
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
        // NSHostingView can otherwise retain an opaque layer over the padded
        // shadow canvas. On a white slide that opaque canvas appears as a
        // large rectangular gray frame around the rounded glass card.
        hostView.wantsLayer = true
        hostView.layer?.isOpaque = false
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = hostView
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.isOpaque = false
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        viewModel.setCardWidth(initialCardWidth)
        stateObservation = viewModel.$overlayState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePanelGeometry(animated: self?.isVisible == true)
            }

        // 回调
        viewModel.onCommit = { [weak self] text in
            self?.handleCommit(text)
        }
        viewModel.onDismiss = { [weak self] in
            self?.handleDismiss()
        }
        viewModel.onPasteImage = { [weak self] image in
            self?.handlePastedImage(image)
        }
    }

    // MARK: - Key Window 支持

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show

    func show() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        showRetryCount = 0
        showInternal(generation: generation)
    }

    private func showInternal(generation: Int) {
        guard generation == presentationGeneration else { return }

        // A delayed visibility check may have scheduled a retry just before
        // the editor became first responder. Once that happens, rebuilding the
        // activation sequence can interrupt an IME candidate session even
        // though the panel is already usable. Treat the editor itself as the
        // source of truth and cancel the stale retry.
        if showRetryCount > 0,
           isVisible,
           (textEditorIsFirstResponder || textEditorHasActiveInput) {
            NSLog("📐 [VN] 输入框已获得焦点，取消过期的显示重试")
            return
        }

        showRetryCount += 1
        NSLog("📐 [VN] showInternal attempt #\(showRetryCount)")

        // ━━ 1. 记录当前活跃 App；重试时不能把自己覆盖成“前一个 App” ━━
        if showRetryCount == 1 {
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            // A rapid reopen can happen while the previous fade-out still owns
            // focus. Keep the real video app rather than replacing it with this
            // menu-bar process, so media-source matching remains correct.
            if frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousActiveApp = frontmostApplication
            }
#if VIDEONOTES_ENHANCED
            // Refresh while the source app is still known. The coordinator
            // rejects stale now-playing data from a different application.
            EnhancedMediaSessionCoordinator.shared.refresh(
                expectedSourceBundleIdentifier: previousActiveApp?.bundleIdentifier
            )
#endif
            let captureDate = Date()
            let capturedContext = MediaCaptureResolver.context(
                at: captureDate,
                expectedSourceBundleIdentifier: previousActiveApp?.bundleIdentifier
            )
            let screen = activeScreen()
            targetScreen = screen
            viewModel.prepareForPresentation(
                capturedVideoContext: capturedContext,
                cardWidth: FloatingInputLayout.cardWidth(for: screen)
            )
        }
        NSLog("📐 [VN] 1. frontmostApp: \(previousActiveApp?.localizedName ?? "nil")")

        // ━━ 2. 重置窗口属性 ━━
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        self.level = .floating
        NSLog("📐 [VN] 3. collectionBehavior/level 已设置")

        // Only the first attempt changes geometry. Most importantly, retries
        // never order an already-visible panel out: doing so resigns the text
        // view and destroys Chinese/Japanese/Korean marked text.
        if showRetryCount == 1 {
            positionOnActiveScreen()
            NSLog("📐 [VN] 4. positionOnActiveScreen 完成")
        }

        // ━━ 5. 激活 App ━━
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("📐 [VN] 5. activate 完成")

        // ━━ 6. 显示窗口 ━━
        let wasVisible = self.isVisible
        let shouldAnimateEntrance = !wasVisible || self.alphaValue < 0.99
        if !wasVisible {
            self.alphaValue = 0
            self.setFrameOrigin(NSPoint(x: self.frame.origin.x, y: self.frame.origin.y - 8))
        }
        self.makeKeyAndOrderFront(nil)
        NSLog("📐 [VN] 6. makeKeyAndOrderFront 完成")

        // ━━ 7. 再次激活 ━━
        NSApp.activate(ignoringOtherApps: true)
        self.makeKey()
        NSLog("📐 [VN] 7. makeKey 完成")

        // ━━ 8. 淡入动画 ━━
        if shouldAnimateEntrance {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
                if !wasVisible {
                    self.animator().setFrameOrigin(NSPoint(x: self.frame.origin.x, y: self.frame.origin.y + 8))
                }
            }
        }
        NSLog("📐 [VN] 8. 动画完成")

        // ━━ 9. first responder ━━
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            if !self.textEditorIsFirstResponder {
                self.makeFirstResponderForKey()
            }
        }

        // ━━ 10. 验证 ━━
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  generation == self.presentationGeneration else { return }

            let isVis = self.isVisible
            let isKey = self.isKeyWindow
            let screen = self.screen?.localizedName ?? "nil"
            NSLog("📐 [VN] 验证: isVisible=\(isVis) isKey=\(isKey) screen=\(screen)")

            // `isKeyWindow` can briefly be false for a nonactivating panel in
            // a full-screen Space. If the editor already owns first responder,
            // typing is working and another retry would only disturb it.
            if !isVis || (
                !isKey
                    && !self.textEditorIsFirstResponder
                    && !self.textEditorHasActiveInput
            ) {
                if self.showRetryCount < self.maxShowRetries {
                    NSLog("📐 [VN] 显示失败，重试 #\(self.showRetryCount + 1)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self,
                              generation == self.presentationGeneration else { return }
                        self.showInternal(generation: generation)
                    }
                } else {
                    NSLog("📐 [VN] 重试上限，放弃")
                }
            }
        }
    }

    // MARK: - Hide

    func hide() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self,
                  generation == self.presentationGeneration else { return }
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

    // MARK: - Screenshot Attachment

    /// 把截图附加到当前输入框。用户仍然可以继续输入文字，保存时一起写入笔记。
    func attachScreenshot(path: String, videoContext: MediaCaptureContext?) {
        guard isVisible else { return }
        viewModel.attachedScreenshotPath = path
        viewModel.attachedVideoContext = videoContext
    }

    /// 用户在输入框里按 ⌘V 粘贴截图时触发。保存图片并显示缩略图。
    private func handlePastedImage(_ image: NSImage) {
        NSLog("[VNPasteDiag] step6: handlePastedImage called, saving image")
        guard let path = ScreenshotService.shared.savePastedImage(image) else {
            NSLog("[VNPasteDiag] step6fail: savePastedImage returned nil")
            ClipToastWindow.show(message: "粘贴截图失败")
            return
        }
        NSLog("[VNPasteDiag] step6ok: saved file=\(path.path)")

        let video = MediaCaptureResolver.context(
            at: Date(),
            expectedSourceBundleIdentifier: previousActiveApp?.bundleIdentifier
        )
        viewModel.attachedScreenshotPath = path.path
        viewModel.attachedVideoContext = video
        NSLog("[VNPasteDiag] step7: viewModel.attachedScreenshotPath set=\(viewModel.attachedScreenshotPath ?? "nil")")
        ClipToastWindow.show(message: "截图已附加到输入框")
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

    private var textEditorIsFirstResponder: Bool {
        guard let textView = contentView.flatMap(findTextView(in:)) else {
            return false
        }
        return firstResponder === textView
    }

    private var textEditorHasActiveInput: Bool {
        guard let textView = contentView.flatMap(findTextView(in:)) else {
            return false
        }
        return textView.hasMarkedText() || !textView.string.isEmpty
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
        guard let targetScreen = targetScreen ?? activeScreen() else {
            NSLog("📐 [VN] 无可用屏幕")
            return
        }
        self.targetScreen = targetScreen
        let cardWidth = FloatingInputLayout.cardWidth(for: targetScreen)
        viewModel.setCardWidth(cardWidth)
        NSLog("📐 [VN] 定位到鼠标屏幕: \(targetScreen.localizedName)")
        updatePanelGeometry(animated: false)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func updatePanelGeometry(animated: Bool) {
        guard let targetScreen = targetScreen ?? screen ?? NSScreen.main else { return }

        let size = FloatingInputLayout.panelSize(
            cardWidth: viewModel.cardWidth,
            state: viewModel.overlayState
        )
        let screenFrame = targetScreen.visibleFrame
        let currentFrame = self.frame
        let x = min(
            max(screenFrame.minX + 16, screenFrame.midX - size.width / 2),
            screenFrame.maxX - size.width - 16
        )
        let y = min(
            screenFrame.minY + FloatingInputLayout.windowBottomInset,
            screenFrame.maxY - size.height - 16
        )
        let newFrame = NSRect(
            x: x,
            y: max(screenFrame.minY + 16, y),
            width: size.width,
            height: size.height
        )

        guard currentFrame != newFrame else { return }

        if animated, isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    // MARK: - Commit

    private func handleCommit(_ text: String) {
        guard !commitInProgress else { return }
        // NSTextView is the editing source of truth. Its native string can be
        // one run-loop turn ahead of the SwiftUI binding when an input method
        // has just confirmed a candidate or when the arrow button is clicked.
        // Commit marked text in place and snapshot the editor directly so the
        // last character is never omitted from the saved note.
        let editor = contentView.flatMap(findTextView(in:))
        if editor?.hasMarkedText() == true {
            editor?.unmarkText()
        }
        let currentText = editor?.string ?? text
        viewModel.text = currentText

        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshotPath = viewModel.attachedScreenshotPath
        guard !trimmed.isEmpty || screenshotPath != nil else {
            handleDismiss()
            return
        }

        // 保存历史。优先使用截图时锁定的视频上下文，保证截图时间点不被后续输入耗时影响。
        let noteDate = Date()
        let video = viewModel.attachedVideoContext
            ?? viewModel.capturedVideoContext
            ?? MediaCaptureResolver.context(
                at: noteDate,
                expectedSourceBundleIdentifier: previousActiveApp?.bundleIdentifier
            )
        let timestamp = video.map { VideoSession.formattedTimestamp(for: $0.elapsedTime) } ?? "--:--"
        commitInProgress = true
        editor?.isEditable = false
        let commitGeneration = presentationGeneration
        let finishCopy: (Bool) -> Void = { [weak self] copied in
            guard let self else { return }
            self.commitInProgress = false
            editor?.isEditable = true
            guard self.presentationGeneration == commitGeneration else { return }
            if copied { self.viewModel.showToast(timestamp: timestamp) }
            // Formula copying completes only after rendering and clipboard
            // publication, never after a fixed delay from the Return key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.presentationGeneration == commitGeneration else { return }
                self.hide()
            }
        }

        if trimmed.isEmpty, let screenshotPath {
            // 只截了图、没有文字：保存为纯截图 Clip。
            HistoryStore.shared.addScreenshotClip(
                screenshotPath: screenshotPath,
                videoTitle: video?.title,
                videoURL: video?.url,
                videoSessionID: video?.sessionID,
                videoTimestamp: timestamp == "--:--" ? nil : timestamp,
                videoTimestampSeconds: video?.elapsedTime,
                sourceBundleIdentifier: video?.sourceBundleIdentifier ?? previousActiveApp?.bundleIdentifier,
                sourceApplicationName: video?.sourceApplicationName ?? previousActiveApp?.localizedName
            )
            ClipboardManager.shared.copy(
                text: video.map { VideoSession.formattedTimestamp(for: $0.elapsedTime) } ?? "截图",
                completion: finishCopy
            )
        } else {
            HistoryStore.shared.add(
                content: trimmed,
                videoTitle: video?.title,
                videoURL: video?.url,
                videoSessionID: video?.sessionID,
                videoTimestamp: timestamp == "--:--" ? nil : timestamp,
                videoTimestampSeconds: video?.elapsedTime,
                screenshotPath: screenshotPath,
                sourceBundleIdentifier: video?.sourceBundleIdentifier ?? previousActiveApp?.bundleIdentifier,
                sourceApplicationName: video?.sourceApplicationName ?? previousActiveApp?.localizedName
            )
            ClipboardManager.shared.copy(text: trimmed, completion: finishCopy)
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
