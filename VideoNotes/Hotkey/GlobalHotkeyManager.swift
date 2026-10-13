import AppKit
import Carbon.HIToolbox

// MARK: - Delegate Protocol

protocol GlobalHotkeyDelegate: AnyObject {
    func hotkeyTriggered(kind: HotkeyKind)
}

// MARK: - HotkeyKind

/// 快捷键类型
enum HotkeyKind {
    case toggleInput          // ⌘⇧Space — 唤出/关闭输入框
    case showHistory          // ⌘⇧H    — 打开历史记录
}

// MARK: - HotkeyConfig

struct HotkeyConfig {
    let keyCode: UInt32
    let modifiers: UInt32
    let kind: HotkeyKind

    // ⌘⇧Space
    static let toggleInput = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey),
        kind: .toggleInput
    )

    // ⌘⇧H
    static let showHistory = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_H),
        modifiers: UInt32(cmdKey | shiftKey),
        kind: .showHistory
    )

}

// MARK: - GlobalHotkeyManager

/// 全局快捷键管理器
///
/// 使用 Carbon RegisterEventHotKey API（macOS 官方推荐方式）
/// 支持注册多个全局快捷键
///
final class GlobalHotkeyManager {

    // MARK: Properties

    weak var delegate: GlobalHotkeyDelegate?

    private var hotkeyRefs: [HotkeyKind: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var lastToggleEventAt: TimeInterval = 0

    // MARK: Register / Unregister

    func register() {
        NSLog("🔑 [VN] register() called")
        guard eventHandler == nil else {
            NSLog("🔑 [VN] already registered, adding hotkeys")
            // 已注册，追加快捷键
            registerHotkey(.toggleInput)
            registerHotkey(.showHistory)
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotkeyEvent(eventRef)
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandler
        )

        NSLog("🔑 [VN] registering hotkeys...")
        registerHotkey(.toggleInput)
        registerHotkey(.showHistory)
        NSLog("🔑 [VN] register done, refs: \(hotkeyRefs.keys)")
    }

    func unregister() {
        for (_, ref) in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - Private

    private func registerHotkey(_ config: HotkeyConfig) {
        guard hotkeyRefs[config.kind] == nil else { return }

        let id: UInt32
        switch config.kind {
        case .toggleInput: id = 1
        case .showHistory: id = 2
        }

        var ref: EventHotKeyRef?
        let hotkeyId = EventHotKeyID(signature: OSType(0x564E_4F54), id: id)  // "VNOT"

        RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotkeyId,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if let ref = ref {
            hotkeyRefs[config.kind] = ref
            NSLog("🔑 [VN] registered hotkey id=\(id) ref=\(ref)")
        } else {
            NSLog("🔑 [VN] FAILED to register hotkey id=\(id)")
        }
    }

    private func handleHotkeyEvent(_ eventRef: EventRef?) {
        guard let eventRef = eventRef else { return }

        var hotkeyId = EventHotKeyID()
        GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyId
        )

        NSLog("🔑 [VN] hotkey fired, id=\(hotkeyId.id)")
        switch hotkeyId.id {
        case 1:
            // Carbon can emit a repeat when the shortcut is held for a moment.
            // A second toggle would immediately close the editor that just
            // appeared, which feels like an input interruption.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastToggleEventAt >= 0.28 else {
                NSLog("🔑 [VN] ignored repeated toggle hotkey")
                return
            }
            lastToggleEventAt = now
            NSLog("🔑 [VN] → toggleInput")
            delegate?.hotkeyTriggered(kind: .toggleInput)
        case 2:
            NSLog("🔑 [VN] → showHistory")
            delegate?.hotkeyTriggered(kind: .showHistory)
        default:
            NSLog("🔑 [VN] → unknown id=\(hotkeyId.id)")
        }
    }

    deinit {
        unregister()
    }
}
