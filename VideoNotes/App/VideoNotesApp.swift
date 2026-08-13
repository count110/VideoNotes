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
    private var settingsWindowController: NSWindowController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        setupStatusItem()
        inputPanel = FloatingInputPanel()

        hotkeyManager = GlobalHotkeyManager()
        hotkeyManager.delegate = self
        hotkeyManager.register()

#if DEBUG
        // UI automation entry points. Excluded entirely from release builds.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-input") {
            DispatchQueue.main.async { [weak self] in self?.inputPanel.show() }
        }
        if arguments.contains("--ui-test-history") {
            DispatchQueue.main.async { [weak self] in self?.openHistoryWindow() }
        }
        if arguments.contains("--ui-test-settings") {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
#endif
    }

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
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "VideoNotes", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // 快捷键提示
        let shortcutItem = NSMenuItem(title: "⌘⇧Space  输入框", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        let historyShortcutItem = NSMenuItem(title: "⌘⇧H  历史记录", action: nil, keyEquivalent: "")
        historyShortcutItem.isEnabled = false
        menu.addItem(historyShortcutItem)

        menu.addItem(.separator())

        // 基本操作
        let showInputItem = NSMenuItem(title: "显示输入框", action: #selector(showInputPanel), keyEquivalent: "")
        showInputItem.target = self
        menu.addItem(showInputItem)

        let historyItem = NSMenuItem(title: "历史记录…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        // AI 复盘子菜单
        let reviewMenu = NSMenu()
        reviewMenu.title = "AI 复盘"

        let reviewTodayItem = NSMenuItem(title: "复盘今天 → 生成并发送微信", action: #selector(reviewToday), keyEquivalent: "")
        reviewTodayItem.target = self
        reviewMenu.addItem(reviewTodayItem)

        let reviewYesterdayItem = NSMenuItem(title: "复盘昨天 → 生成并发送微信", action: #selector(reviewYesterday), keyEquivalent: "")
        reviewYesterdayItem.target = self
        reviewMenu.addItem(reviewYesterdayItem)

        let reviewWeekItem = NSMenuItem(title: "复盘本周 → 生成并发送微信", action: #selector(reviewThisWeek), keyEquivalent: "")
        reviewWeekItem.target = self
        reviewMenu.addItem(reviewWeekItem)

        let reviewAllItem = NSMenuItem(title: "复盘全部 → 生成并发送微信", action: #selector(reviewAll), keyEquivalent: "")
        reviewAllItem.target = self
        reviewMenu.addItem(reviewAllItem)

        reviewMenu.addItem(.separator())

        let reviewCopyTodayItem = NSMenuItem(title: "复盘今天 → 仅复制（不推送）", action: #selector(reviewCopyToday), keyEquivalent: "")
        reviewCopyTodayItem.target = self
        reviewMenu.addItem(reviewCopyTodayItem)

        let reviewCopyWeekItem = NSMenuItem(title: "复盘本周 → 仅复制（不推送）", action: #selector(reviewCopyThisWeek), keyEquivalent: "")
        reviewCopyWeekItem.target = self
        reviewMenu.addItem(reviewCopyWeekItem)

        let reviewMenuItem = NSMenuItem(title: "AI 复盘", action: nil, keyEquivalent: "")
        reviewMenuItem.submenu = reviewMenu
        menu.addItem(reviewMenuItem)

        // 设置
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 VideoNotes", action: #selector(quitApp), keyEquivalent: "q")
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
        ReviewManager.shared.generateAndPush(timeRange: .today)
    }

    @objc private func reviewYesterday() {
        ReviewManager.shared.generateAndPush(timeRange: .yesterday)
    }

    @objc private func reviewThisWeek() {
        ReviewManager.shared.generateAndPush(timeRange: .thisWeek)
    }

    @objc private func reviewAll() {
        ReviewManager.shared.generateAndPush(timeRange: .all)
    }

    @objc private func reviewCopyToday() {
        ReviewManager.shared.generateOnly(timeRange: .today)
    }

    @objc private func reviewCopyThisWeek() {
        ReviewManager.shared.generateOnly(timeRange: .thisWeek)
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

    // MARK: - Deactivation

    func applicationDidResignActive(_ notification: Notification) {
        if inputPanel?.isVisible == false
            && historyWindowController?.window?.isVisible != true
            && settingsWindowController?.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
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
