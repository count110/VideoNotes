import SwiftUI
import AppKit

// MARK: - Video timestamp anchor

/// The timestamp is deliberately a control rather than a decorative label.
/// During editing it receives the context captured when the note opened, so
/// the anchor stays stable while the video continues to play.
struct VideoSessionIndicator: View {
    @ObservedObject var sessionManager: VideoSessionManager
    let capturedContext: MediaCaptureContext?
    let compact: Bool
    let onTimestampTap: ((String) -> Void)?

#if VIDEONOTES_ENHANCED
    @ObservedObject private var enhancedMediaCoordinator = EnhancedMediaSessionCoordinator.shared
#endif

    var body: some View {
        if let capturedContext {
            contextIndicator(capturedContext)
        } else {
            liveIndicator
        }
    }

    @ViewBuilder
    private func contextIndicator(_ context: MediaCaptureContext) -> some View {
        let timestamp = VideoSession.formattedTimestamp(for: context.elapsedTime)

        HStack(spacing: 8) {
            timestampButton(
                timestamp: timestamp,
                isPlaying: context.isPlaying
            )

            if !compact {
                contextTitle(context.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频时间锚点 (timestamp)，(shortTitle(context.title))")
    }

    @ViewBuilder
    private var liveIndicator: some View {
#if VIDEONOTES_ENHANCED
        if let media = enhancedMediaCoordinator.currentDisplay {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let current = enhancedMediaCoordinator.captureContext(at: timeline.date) ?? media
                liveRow(
                    timestamp: VideoSession.formattedTimestamp(for: current.elapsedTime),
                    isPlaying: current.isPlaying,
                    title: current.title
                )
            }
        } else {
            manualLiveIndicator
        }
#else
        manualLiveIndicator
#endif
    }

    private var manualLiveIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let current = sessionManager.timestampForCurrentSession(at: timeline.date)
            liveRow(
                timestamp: current.map { VideoSession.formattedTimestamp(for: $0.elapsed) } ?? "--:--",
                isPlaying: current?.session.isRunning == true,
                title: current?.session.title
            )
        }
    }

    private func liveRow(
        timestamp: String,
        isPlaying: Bool,
        title: String?
    ) -> some View {
        HStack(spacing: 8) {
            timestampButton(timestamp: timestamp, isPlaying: isPlaying)
            if !compact, let title, !title.isEmpty {
                contextTitle(title)
            }
        }
    }

    private func timestampButton(timestamp: String, isPlaying: Bool) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
            Text(timestamp)
                .monospacedDigit()
        }
        .font(.system(size: 13.2, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.94))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.white.opacity(0.075), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.55)
        }

        if let onTimestampTap {
            return AnyView(
                Button {
                    onTimestampTap(timestamp)
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .help(timestamp == "--:--" ? "暂无视频时间" : "复制视频时间点 (timestamp)")
                .accessibilityLabel("视频时间点 (timestamp)")
                .accessibilityHint("点击复制时间点")
            )
        }

        return AnyView(
            label
                .accessibilityLabel("视频时间点 (timestamp)")
        )
    }

    private func contextTitle(_ title: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white.opacity(0.42))
                .frame(width: 4, height: 4)
            Text(shortTitle(title))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.70))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(title)
        .accessibilityLabel("视频 (shortTitle(title))")
    }

    private func shortTitle(_ title: String) -> String {
        let pathName = (title as NSString).lastPathComponent
        let withoutExtension = (pathName as NSString).deletingPathExtension
        let trimmed = withoutExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "当前视频" }

        var index = trimmed.startIndex
        while index < trimmed.endIndex,
              trimmed[index].isNumber || trimmed[index] == "." || trimmed[index] == "_" || trimmed[index] == "-" {
            index = trimmed.index(after: index)
        }
        let result = String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? trimmed : result
    }
}
