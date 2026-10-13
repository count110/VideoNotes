import Foundation

/// Resolves the app's local data directory for each distribution target.
///
/// The App Store build deliberately keeps its historical location unchanged.
/// The Enhanced build owns an independent directory and imports a small,
/// explicit allow-list from the App Store container once, using copy-only
/// semantics. The source container is never moved, deleted, or written to.
enum ApplicationStorage {
    static let directory: URL = {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

#if VIDEONOTES_ENHANCED
        let directory = applicationSupport.appendingPathComponent(
            "VideoNotes Enhanced",
            isDirectory: true
        )
#else
        let directory = applicationSupport.appendingPathComponent(
            "VideoNotes",
            isDirectory: true
        )
#endif

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[ApplicationStorage] 无法创建数据目录: \(error.localizedDescription)")
        }

#if VIDEONOTES_ENHANCED
        importAppStoreDataIfNeeded(to: directory, using: fileManager)
#endif
        return directory
    }()

#if VIDEONOTES_ENHANCED
    /// Imports only files whose destination does not yet exist. This keeps the
    /// Enhanced database independent and makes repeated launches idempotent.
    private static func importAppStoreDataIfNeeded(
        to destinationDirectory: URL,
        using fileManager: FileManager
    ) {
        let sourceDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("com.videonotes.app", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VideoNotes", isDirectory: true)

        let allowedFileNames = [
            "history.json",
            "video_sessions.json",
            "config.json",
            "feishu_config.json"
        ]

        for fileName in allowedFileNames {
            let source = sourceDirectory.appendingPathComponent(fileName)
            let destination = destinationDirectory.appendingPathComponent(fileName)
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  !fileManager.fileExists(atPath: destination.path) else {
                continue
            }

            do {
                try fileManager.copyItem(at: source, to: destination)
                NSLog("[ApplicationStorage] 已只读导入 \(fileName)")
            } catch {
                // A concurrent launch may have completed the same copy first.
                // Never remove or overwrite the resulting destination.
                if !fileManager.fileExists(atPath: destination.path) {
                    NSLog("[ApplicationStorage] 导入 \(fileName) 失败: \(error.localizedDescription)")
                }
            }
        }
    }
#endif
}

/// User-adjustable appearance values for the floating note editor.
///
/// The value is deliberately kept in UserDefaults instead of the note data
/// directory: it is a local UI preference and should not travel with a
/// .videonotesbackup file.
enum FloatingInputAppearanceSettings {
    static let opacityKey = "VideoNotes.floatingInputOpacity"
    static let defaultOpacity = 1.0
    static let minimumOpacity = 0.45
    static let maximumOpacity = 1.0

    static let glowBrightnessKey = "VideoNotes.floatingInputGlowBrightness"
    static let defaultGlowBrightness = 1.0
    static let minimumGlowBrightness = 0.25
    static let maximumGlowBrightness = 1.0

    static let glowSpeedKey = "VideoNotes.floatingInputGlowSpeed"
    static let defaultGlowSpeed = 1.0
    static let minimumGlowSpeed = 0.50
    static let maximumGlowSpeed = 2.0
}
