import AppKit
import SwiftUI

// MARK: - ClipToastWindow

/// 截图笔记的轻量成功反馈。
///
/// 一个不会抢焦点、不会暂停视频的小浮层：
/// - nonactivatingPanel + ignoresMouseEvents
/// - 不调用 NSApp.activate
/// - 1 秒左右自动淡出
final class ClipToastWindow: NSPanel {

    static let shared = ClipToastWindow()

    private var hideWorkItem: DispatchWorkItem?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isFloatingPanel = true
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    static func show(message: String) {
        DispatchQueue.main.async {
            shared.present(message: message)
        }
    }

    // MARK: - Presentation

    private func present(message: String) {
        let hostingView = NSHostingView(
            rootView: ClipToastView(message: message)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView

        let fittingSize = hostingView.fittingSize
        let size = NSSize(
            width: max(120, min(360, fittingSize.width + 24)),
            height: max(36, fittingSize.height + 12)
        )
        setContentSize(size)

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 24
        setFrameOrigin(NSPoint(x: x, y: y))

        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }

        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: workItem)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        })
    }
}

// MARK: - ClipToastView

private struct ClipToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .fixedSize()
    }
}
