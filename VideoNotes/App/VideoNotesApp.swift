import SwiftUI
import AppKit

@main
struct VideoNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var hotkeyManager: GlobalHotkeyManager!
    private var inputPanel: FloatingInputPanel!
    private var historyWindowController: NSWindowController?
    private var dailyDashboardWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var videoSessionMenu: NSMenu?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
#if VIDEONOTES_ENHANCED
        // Both editions register the same global shortcuts. Refuse to start the
        // Enhanced edition while the App Store edition is alive so keystrokes
        // are never delivered unpredictably to two processes.
        guard ensureStandardEditionIsNotRunning() else { return }
#else
        guard ensureEnhancedEditionIsNotRunning() else { return }
#endif
#if VIDEONOTES_ENHANCED
        // The private now-playing bridge exists only in the separately built
        // Enhanced product. Keeping its lifecycle behind the compilation flag
        // prevents the App Store target from referencing it at all.
        EnhancedMediaSessionCoordinator.shared.start()
#endif

        setupStatusItem()
        inputPanel = FloatingInputPanel()

        hotkeyManager = GlobalHotkeyManager()
        hotkeyManager.delegate = self
        hotkeyManager.register()

        // A relay connection is optional. This is a no-op until the user
        // explicitly pairs the Mac in Settings, and it never activates the
        // app or takes focus away from a full-screen video.
        FeishuRelayClient.shared.start()

#if DEBUG
        // UI automation entry points. Excluded entirely from release builds.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-start-session") {
            VideoSessionManager.shared.start(title: "线性代数测试")
        }
        if arguments.contains("--ui-test-clean-session"),
           VideoSessionManager.shared.currentSession?.title == "线性代数测试" {
            VideoSessionManager.shared.endCurrentSession()
            NSLog("[UITest] 已结束遗留的 UI 测试会话")
        }
        if arguments.contains("--ui-test-input") {
            DispatchQueue.main.async { [weak self] in self?.inputPanel.show() }
        }
        if arguments.contains("--ui-test-history") {
            DispatchQueue.main.async { [weak self] in self?.openHistoryWindow() }
        }
        if arguments.contains("--ui-test-settings") {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
        if arguments.contains("--ui-test-codex-review") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSLog("[CodexReviewDiagnostic] start")
                let record = NoteRecord(
                    content: "看到根式极限先考虑有理化；辅助函数要从目标式反推。"
                )
                LocalCodexClient.shared.generateReview(records: [record]) { result in
                    switch result {
                    case .success(let markdown):
                        NSLog("[CodexReviewDiagnostic] SUCCESS chars=%d", markdown.count)
                    case .failure(let error):
                        NSLog("[CodexReviewDiagnostic] FAILURE %@", error.localizedDescription)
                    }
                }
                if arguments.contains("--ui-test-codex-cancel") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        NSLog("[CodexReviewDiagnostic] requesting cancel")
                        LocalCodexClient.shared.cancelCurrentRun()
                    }
                }
            }
        }
        if arguments.contains("--ui-test-paste-flow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runPasteFlowDiagnostic()
            }
        }
        if arguments.contains("--ui-test-subtitle-parser") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.runSubtitleParserDiagnostic()
            }
        }
        if arguments.contains("--ui-test-feishu-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSLog("[FeishuPush] debug test message start")
                FeishuPusher.shared.sendTestMessage { result in
                    switch result {
                    case .success:
                        NSLog("[FeishuPush] debug test message SUCCESS")
                    case .failure(let error):
                        NSLog("[FeishuPush] debug test message FAILURE: %@", error.localizedDescription)
                    }
                }
            }
        }
        if arguments.contains("--ui-test-feishu-review-today") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSLog("[FeishuPush] debug review-today start")
                ReviewManager.shared.generateAndPushToFeishu(timeRange: .today)
            }
        }
        if let exportIndex = arguments.firstIndex(of: "--ui-test-export-pdf"),
           exportIndex + 1 < arguments.count {
            let path = arguments[exportIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                do {
                    let records = HistoryStore.shared.records
                    try DailyNotesPDFExporter().export(records: records, to: URL(fileURLWithPath: path))
                    NSLog("[PDFExport] debug export SUCCESS: %@", path)
                } catch {
                    NSLog("[PDFExport] debug export FAILURE: %@", error.localizedDescription)
                }
            }
        }
#endif
    }

#if !VIDEONOTES_ENHANCED
    /// The editions share global shortcuts, so the launch guard must work in
    /// both directions regardless of which product was opened first.
    private func ensureEnhancedEditionIsNotRunning() -> Bool {
        let enhancedBundleIdentifier = "com.videonotes.app.enhanced"
        let enhancedEditionIsRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: enhancedBundleIdentifier)
            .contains { !$0.isTerminated }

        guard enhancedEditionIsRunning else { return true }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请先退出 VideoNotes Enhanced"
        alert.informativeText = "标准版与增强版使用相同的全局快捷键，不能同时运行。退出增强版后，再打开 VideoNotes。"
        alert.addButton(withTitle: "退出标准版")
        alert.runModal()

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return false
    }
#endif

#if VIDEONOTES_ENHANCED
    /// Returns false after presenting the one actionable launch warning and
    /// scheduling termination. Filtering by PID also keeps this safe if a local
    /// development build temporarily shares the standard bundle identifier.
    private func ensureStandardEditionIsNotRunning() -> Bool {
        let standardBundleIdentifier = "com.videonotes.app"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let standardEditionIsRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: standardBundleIdentifier)
            .contains { $0.processIdentifier != currentPID && !$0.isTerminated }

        guard standardEditionIsRunning else { return true }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请先退出 VideoNotes"
        alert.informativeText = "标准版与增强版使用相同的全局快捷键，不能同时运行。退出标准版后，再打开 VideoNotes Enhanced。"
        alert.addButton(withTitle: "退出增强版")
        alert.runModal()

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return false
    }
#endif

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "doc.text.magnifyingglass",
                accessibilityDescription: "VideoNotes"
            )
            image?.isTemplate = true
            button.image = image
#if VIDEONOTES_ENHANCED
            button.toolTip = "VideoNotes Enhanced"
#endif
        }

        let menu = NSMenu()
#if VIDEONOTES_ENHANCED
        let productItem = NSMenuItem(title: "VideoNotes Enhanced", action: nil, keyEquivalent: "")
        productItem.isEnabled = false
        menu.addItem(productItem)

        let editionItem = NSMenuItem(title: "增强版 · 自动读取系统正在播放", action: nil, keyEquivalent: "")
        editionItem.isEnabled = false
        menu.addItem(editionItem)
#else
        menu.addItem(withTitle: "VideoNotes", action: nil, keyEquivalent: "")
#endif
        menu.addItem(.separator())

        // 快捷键提示
        let shortcutItem = NSMenuItem(title: "⌘⇧Space  输入框", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        let historyShortcutItem = NSMenuItem(title: "⌘⇧H  历史记录", action: nil, keyEquivalent: "")
        historyShortcutItem.isEnabled = false
        menu.addItem(historyShortcutItem)

        let pasteClipItem = NSMenuItem(title: "⌘V  粘贴截图到输入框", action: nil, keyEquivalent: "")
        pasteClipItem.isEnabled = false
        menu.addItem(pasteClipItem)

        menu.addItem(.separator())

        // 基本操作
        let showInputItem = NSMenuItem(title: "显示输入框", action: #selector(showInputPanel), keyEquivalent: "")
        showInputItem.target = self
        menu.addItem(showInputItem)

        let historyItem = NSMenuItem(title: "历史记录…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let dailyDashboardItem = NSMenuItem(
            title: "每日学习看板…",
            action: #selector(showDailyLearningDashboard),
            keyEquivalent: ""
        )
        dailyDashboardItem.target = self
        menu.addItem(dailyDashboardItem)

        menu.addItem(.separator())

        let sessionMenu = NSMenu(title: "视频会话")
        sessionMenu.delegate = self
        videoSessionMenu = sessionMenu
        rebuildVideoSessionMenu()

        let sessionMenuItem = NSMenuItem(title: "视频会话", action: nil, keyEquivalent: "")
        sessionMenuItem.submenu = sessionMenu
        menu.addItem(sessionMenuItem)

        menu.addItem(.separator())

        // AI 复盘子菜单
        let reviewMenu = NSMenu()
        reviewMenu.title = "AI 复盘"

        let reviewTodayItem = NSMenuItem(title: "复盘今天 → 生成并发送飞书", action: #selector(reviewToday), keyEquivalent: "")
        reviewTodayItem.target = self
        reviewMenu.addItem(reviewTodayItem)

        let reviewYesterdayItem = NSMenuItem(title: "复盘昨天 → 生成并发送飞书", action: #selector(reviewYesterday), keyEquivalent: "")
        reviewYesterdayItem.target = self
        reviewMenu.addItem(reviewYesterdayItem)

        let reviewWeekItem = NSMenuItem(title: "复盘本周 → 生成并发送飞书", action: #selector(reviewThisWeek), keyEquivalent: "")
        reviewWeekItem.target = self
        reviewMenu.addItem(reviewWeekItem)

        let reviewAllItem = NSMenuItem(title: "复盘全部 → 生成并发送飞书", action: #selector(reviewAll), keyEquivalent: "")
        reviewAllItem.target = self
        reviewMenu.addItem(reviewAllItem)

        reviewMenu.addItem(.separator())

        let reviewCopyTodayItem = NSMenuItem(title: "复盘今天 → 仅生成（不推送）", action: #selector(reviewCopyToday), keyEquivalent: "")
        reviewCopyTodayItem.target = self
        reviewMenu.addItem(reviewCopyTodayItem)

        let reviewCopyYesterdayItem = NSMenuItem(title: "复盘昨天 → 仅生成（不推送）", action: #selector(reviewCopyYesterday), keyEquivalent: "")
        reviewCopyYesterdayItem.target = self
        reviewMenu.addItem(reviewCopyYesterdayItem)

        let reviewCopyWeekItem = NSMenuItem(title: "复盘本周 → 仅生成（不推送）", action: #selector(reviewCopyThisWeek), keyEquivalent: "")
        reviewCopyWeekItem.target = self
        reviewMenu.addItem(reviewCopyWeekItem)

        reviewMenu.addItem(.separator())

        let reviewCurrentVideoItem = NSMenuItem(title: "复盘当前视频 → 仅复制", action: #selector(reviewCurrentVideo), keyEquivalent: "")
        reviewCurrentVideoItem.target = self
        reviewMenu.addItem(reviewCurrentVideoItem)

        let reviewMenuItem = NSMenuItem(title: "AI 复盘", action: nil, keyEquivalent: "")
        reviewMenuItem.submenu = reviewMenu
        menu.addItem(reviewMenuItem)

        // 设置
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

#if VIDEONOTES_ENHANCED
        let quitTitle = "退出 VideoNotes Enhanced"
#else
        let quitTitle = "退出 VideoNotes"
#endif
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Basic Actions

    @objc private func showInputPanel() {
        inputPanel.show()
    }

    @objc private func showHistory() {
        openHistoryWindow()
    }

    @objc private func showDailyLearningDashboard() {
        openDailyLearningDashboardWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings Window

    @objc private func showSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.minSize = NSSize(width: 680, height: 560)
            settingsWindowController = .init(window: window)
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - AI Review Actions

    @objc private func reviewToday() {
        ReviewManager.shared.generateAndPushToFeishu(timeRange: .today)
    }

    @objc private func reviewYesterday() {
        ReviewManager.shared.generateAndPushToFeishu(timeRange: .yesterday)
    }

    @objc private func reviewThisWeek() {
        ReviewManager.shared.generateAndPushToFeishu(timeRange: .thisWeek)
    }

    @objc private func reviewAll() {
        ReviewManager.shared.generateAndPushToFeishu(timeRange: .all)
    }

    @objc private func reviewCopyToday() {
        ReviewManager.shared.generateOnly(timeRange: .today)
    }

    @objc private func reviewCopyYesterday() {
        ReviewManager.shared.generateOnly(timeRange: .yesterday)
    }

    @objc private func reviewCopyThisWeek() {
        ReviewManager.shared.generateOnly(timeRange: .thisWeek)
    }

    @objc private func reviewCurrentVideo() {
#if VIDEONOTES_ENHANCED
        if let sessionID = EnhancedMediaSessionCoordinator.shared
            .captureContext(at: Date())?.sessionID {
            ReviewManager.shared.generateVideoReview(sessionID: sessionID)
            return
        }
#endif
        guard let sessionID = VideoSessionManager.shared.currentSession?.id else {
#if VIDEONOTES_ENHANCED
            ReviewManager.shared.lastError = "没有识别到正在播放的视频，请播放视频或开始手动视频会话"
#else
            ReviewManager.shared.lastError = "请先开始一个视频会话"
#endif
            return
        }
        ReviewManager.shared.generateVideoReview(sessionID: sessionID)
    }

    // MARK: - History Window

    private func openHistoryWindow() {
        if historyWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "笔记"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentView = NSHostingView(rootView: HistoryView())
            window.center()
            window.minSize = NSSize(width: 640, height: 480)
            historyWindowController = .init(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        historyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDailyLearningDashboardWindow() {
        if dailyDashboardWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "每日学习看板"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentView = NSHostingView(rootView: DailyLearningDashboard())
            window.center()
            window.minSize = NSSize(width: 760, height: 650)
            dailyDashboardWindowController = .init(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        dailyDashboardWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Deactivation

    func applicationDidResignActive(_ notification: Notification) {
        if inputPanel?.isVisible == false
            && historyWindowController?.window?.isVisible != true
            && dailyDashboardWindowController?.window?.isVisible != true
            && settingsWindowController?.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
#if VIDEONOTES_ENHANCED
        EnhancedMediaSessionCoordinator.shared.stop()
#endif
        FeishuRelayClient.shared.stop()
        VideoSessionManager.shared.pauseForApplicationTermination()
    }

#if DEBUG
    // MARK: - Paste Flow Diagnostic

    /// Exercises the subtitle parser without touching the user's local
    /// transcript store. This keeps the parser's format support verifiable in
    /// a debug build while the production app contains no test-only paths.
    private func runSubtitleParserDiagnostic() {
        let samples: [(String, String, Int)] = [
            ("SRT", "1\n00:00:01,200 --> 00:00:03,000\n第一句\n\n2\n00:00:04,000 --> 00:00:05,000\n第二句", 2),
            ("WebVTT", "WEBVTT\n\n00:00:06.000 --> 00:00:07.500\n第三句", 1),
            ("ASS", "[Events]\nDialogue: 0,0:00:08.00,0:00:10.00,Default,,0,0,0,,{\\i1}第四句{\\i0}", 1),
            ("LRC", "[00:11.20]第五句\n[00:12.40]第六句", 2)
        ]

        do {
            for (name, text, expectedCueCount) in samples {
                let draft = try VideoSubtitleParser.draft(
                    fromPastedText: text,
                    sourceName: name
                )
                guard draft.cues.count == expectedCueCount else {
                    NSLog("[SubtitleParserDiagnostic] FAILURE %@ expected=%d actual=%d", name, expectedCueCount, draft.cues.count)
                    return
                }
            }
            NSLog("[SubtitleParserDiagnostic] SUCCESS all subtitle formats parsed")
        } catch {
            NSLog("[SubtitleParserDiagnostic] FAILURE %@", error.localizedDescription)
        }
    }

    /// 诊断用：自动执行 打开输入框 -> 写入测试图片 -> 发送 Cmd+V -> 输出各层日志。
    private func runPasteFlowDiagnostic() {
        NSLog("[VNPasteDiag] step0: start")
        inputPanel.show()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let panel = self.inputPanel else { return }
            NSLog("[VNPasteDiag] step1: panel visible=\(panel.isVisible) keyWindow=\(panel.isKeyWindow) firstResponder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")

            let image = NSImage(size: NSSize(width: 320, height: 180))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 180)).fill()
            image.unlockFocus()

            let pb = NSPasteboard.general
            pb.clearContents()
            let wrote = pb.writeObjects([image])
            NSLog("[VNPasteDiag] step2: wrote image to pasteboard=\(wrote) types=\(pb.types?.map(\.rawValue) ?? [])")

            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            ) else {
                NSLog("[VNPasteDiag] step3: FAILED to create Cmd+V event")
                return
            }
            panel.sendEvent(event)
            NSLog("[VNPasteDiag] step4: sent Cmd+V to panel")
        }
    }
#endif

    // MARK: - Video Sessions

    @objc private func startVideoSession() {
        guard VideoSessionManager.shared.currentSession == nil else { return }

        // Showing a title prompt needs activation, but starting a session
        // should not leave the learner away from their full-screen video.
        let previousActiveApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "开始视频会话"
        alert.informativeText = "给正在观看的视频起个标题。之后每条笔记都会自动记录相对时间。"
        alert.addButton(withTitle: "开始计时")
        alert.addButton(withTitle: "取消")

        let titleField = NSTextField(string: "")
        titleField.placeholderString = "例如：高数强化班 第4讲"
        titleField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = titleField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            VideoSessionManager.shared.start(title: titleField.stringValue)
        }

        if inputPanel?.isVisible != true,
           historyWindowController?.window?.isVisible != true,
           settingsWindowController?.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
            if let previousActiveApp,
               previousActiveApp.bundleIdentifier != Bundle.main.bundleIdentifier,
               !previousActiveApp.isTerminated {
                previousActiveApp.activate(options: [.activateAllWindows])
            }
        }
    }

    @objc private func toggleVideoSessionPause() {
        if VideoSessionManager.shared.isRunning {
            VideoSessionManager.shared.pause()
        } else {
            VideoSessionManager.shared.resume()
        }
    }

    @objc private func endVideoSession() {
        _ = VideoSessionManager.shared.endCurrentSession()
    }

    private func rebuildVideoSessionMenu() {
        guard let videoSessionMenu else { return }
        videoSessionMenu.removeAllItems()

        if let session = VideoSessionManager.shared.currentSession {
            let elapsed = VideoSession.formattedTimestamp(for: VideoSessionManager.shared.elapsedTime)
            let status = session.isRunning ? "进行中" : "已暂停"
            let title = "\(session.title) · \(elapsed) · \(status)"
            let statusItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            videoSessionMenu.addItem(statusItem)
            videoSessionMenu.addItem(.separator())

            let pauseTitle = session.isRunning ? "暂停计时" : "继续计时"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleVideoSessionPause), keyEquivalent: "")
            pauseItem.target = self
            videoSessionMenu.addItem(pauseItem)

            let endItem = NSMenuItem(title: "结束视频会话", action: #selector(endVideoSession), keyEquivalent: "")
            endItem.target = self
            videoSessionMenu.addItem(endItem)
        } else {
            let startItem = NSMenuItem(title: "开始视频会话…", action: #selector(startVideoSession), keyEquivalent: "")
            startItem.target = self
            videoSessionMenu.addItem(startItem)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === videoSessionMenu {
            rebuildVideoSessionMenu()
        }
    }
}

// MARK: - GlobalHotkeyDelegate

extension AppDelegate: GlobalHotkeyDelegate {
    func hotkeyTriggered(kind: HotkeyKind) {
        NSLog("🔑 [VN] AppDelegate received hotkey: \(kind)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                NSLog("🔑 [VN] self is nil in hotkey callback")
                return
            }
            switch kind {
            case .toggleInput:
                NSLog("🔑 [VN] → toggle input panel")
                self.inputPanel.toggle()
            case .showHistory:
                NSLog("🔑 [VN] → open history")
                self.openHistoryWindow()
            }
        }
    }
}
