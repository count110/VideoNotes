import Foundation

/// A normalized snapshot of the media that was playing when a note was saved.
///
/// The App Store build only uses the manual Video Session implementation. The
/// Enhanced target adds a private provider that returns this same neutral model,
/// keeping private framework names and symbols out of the standard binary.
struct MediaCaptureContext: Equatable {
    let sessionID: UUID
    let title: String
    let url: String?
    let elapsedTime: TimeInterval
    let duration: TimeInterval?
    let isPlaying: Bool
    let sourceBundleIdentifier: String?
    let sourceApplicationName: String?
    let capturedAt: Date
}

enum MediaCaptureResolver {
    static func context(
        at date: Date = Date(),
        expectedSourceBundleIdentifier: String? = nil
    ) -> MediaCaptureContext? {
#if VIDEONOTES_ENHANCED
        if let external = EnhancedMediaSessionCoordinator.shared.captureContext(
            at: date,
            expectedSourceBundleIdentifier: expectedSourceBundleIdentifier
        ) {
            return external
        }
#endif

        guard let manual = VideoSessionManager.shared.timestampForCurrentSession(at: date) else {
            return nil
        }

        return MediaCaptureContext(
            sessionID: manual.session.id,
            title: manual.session.title,
            url: nil,
            elapsedTime: manual.elapsed,
            duration: nil,
            isPlaying: manual.session.isRunning,
            sourceBundleIdentifier: nil,
            sourceApplicationName: nil,
            capturedAt: date
        )
    }
}
