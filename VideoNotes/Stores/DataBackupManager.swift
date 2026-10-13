import Foundation

// MARK: - Portable data backup

/// Exports the local VideoNotes data into one self-contained JSON file.
///
/// The app currently uses JSON rather than a database engine. Keeping the
/// backup format explicit still gives users a database-like one-click export
/// and makes the file portable between Macs. Screenshot bytes are embedded so
/// a restored screenshot note does not keep a path that only exists on the
/// original computer.
final class DataBackupManager {

    static let shared = DataBackupManager()

    private static let formatName = "VideoNotesBackup"
    private static let currentSchemaVersion = 2

    enum RestoreMode: Equatable {
        case merge
        case replace
    }

    struct RestoreResult {
        let noteCount: Int
        let sessionCount: Int
        let subtitleCount: Int
        let attachmentCount: Int
    }

    private struct Attachment: Codable {
        let noteID: UUID
        let fileName: String
        let data: Data
    }

    private struct BackupDocument: Codable {
        let format: String
        let schemaVersion: Int
        let createdAt: Date
        let records: [NoteRecord]
        let sessions: [VideoSession]
        let currentSessionID: UUID?
        let attachments: [Attachment]
        let subtitles: VideoSubtitleStore.BackupSnapshot?
    }

    enum BackupError: LocalizedError {
        case invalidFormat
        case unsupportedVersion(Int)
        case cannotReadAttachment(String)
        case cannotWriteAttachment(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "这不是有效的 VideoNotes 备份文件"
            case .unsupportedVersion(let version):
                return "备份版本 \(version) 暂不支持，请先升级 VideoNotes"
            case .cannotReadAttachment(let path):
                return "无法读取截图附件：\(path)"
            case .cannotWriteAttachment(let path):
                return "无法恢复截图附件：\(path)"
            }
        }
    }

    private init() {}

    static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "VideoNotes_备份_\(formatter.string(from: date)).videonotesbackup"
    }

    /// Writes a complete snapshot without exporting API keys or other
    /// credentials stored in the Keychain.
    func export(to url: URL) throws {
        let fileManager = FileManager.default
        var attachments: [Attachment] = []

        for record in HistoryStore.shared.records {
            guard let screenshotPath = record.screenshotPath,
                  fileManager.fileExists(atPath: screenshotPath) else {
                continue
            }

            let screenshotURL = URL(fileURLWithPath: screenshotPath)
            guard let data = try? Data(contentsOf: screenshotURL) else {
                throw BackupError.cannotReadAttachment(screenshotPath)
            }

            let fileExtension = screenshotURL.pathExtension.lowercased().isEmpty
                ? "png"
                : screenshotURL.pathExtension.lowercased()
            attachments.append(
                Attachment(
                    noteID: record.id,
                    fileName: "\(record.id.uuidString).\(fileExtension)",
                    data: data
                )
            )
        }

        let document = BackupDocument(
            format: Self.formatName,
            schemaVersion: Self.currentSchemaVersion,
            createdAt: Date(),
            records: HistoryStore.shared.records,
            sessions: VideoSessionManager.shared.sessions,
            currentSessionID: VideoSessionManager.shared.currentSessionID,
            attachments: attachments,
            subtitles: VideoSubtitleStore.shared.backupSnapshot()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    /// Loads a backup after the whole document has decoded successfully. A
    /// merge replaces records with matching UUIDs and adds new ones; replace
    /// keeps only the imported snapshot. Existing screenshot files are left
    /// untouched, so an accidental restore never destroys unrelated files.
    @discardableResult
    func restore(from url: URL, mode: RestoreMode) throws -> RestoreResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let document: BackupDocument
        do {
            document = try decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw BackupError.invalidFormat
        }

        guard document.format == Self.formatName else {
            throw BackupError.invalidFormat
        }
        guard document.schemaVersion <= Self.currentSchemaVersion else {
            throw BackupError.unsupportedVersion(document.schemaVersion)
        }

        let restoredRecords = try restoreAttachments(
            in: document.records,
            attachments: document.attachments
        )

        let historyMode: HistoryStore.RestoreMode = mode == .merge ? .merge : .replace
        let importedNoteCount = HistoryStore.shared.restore(
            records: restoredRecords,
            mode: historyMode
        )

        let sessions: [VideoSession]
        let currentSessionID: UUID?
        switch mode {
        case .replace:
            sessions = document.sessions
            currentSessionID = document.currentSessionID
        case .merge:
            var merged: [UUID: VideoSession] = [:]
            for session in VideoSessionManager.shared.sessions {
                merged[session.id] = session
            }
            for session in document.sessions {
                merged[session.id] = session
            }
            sessions = Array(merged.values)
            currentSessionID = document.currentSessionID ?? VideoSessionManager.shared.currentSessionID
        }

        VideoSessionManager.shared.restore(
            sessions: sessions,
            currentSessionID: currentSessionID
        )

        let subtitleCount = VideoSubtitleStore.shared.restore(
            snapshot: document.subtitles,
            mode: historyMode
        )

        return RestoreResult(
            noteCount: importedNoteCount,
            sessionCount: document.sessions.count,
            subtitleCount: subtitleCount,
            attachmentCount: document.attachments.count
        )
    }

    private func restoreAttachments(
        in records: [NoteRecord],
        attachments: [Attachment]
    ) throws -> [NoteRecord] {
        guard !attachments.isEmpty else {
            // A backup made after a screenshot was moved or deleted cannot
            // carry that file to another Mac. Clear the stale source path so
            // the restored record remains honest and shows its placeholder.
            return records.map { record in
                var copy = record
                if record.screenshotPath != nil {
                    copy.screenshotPath = nil
                }
                return copy
            }
        }

        let screenshotsDirectory = ApplicationStorage.directory
            .appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: screenshotsDirectory,
            withIntermediateDirectories: true
        )

        var attachmentByNoteID: [UUID: Attachment] = [:]
        for attachment in attachments {
            // The last duplicate is deterministic and avoids a crash on a
            // hand-edited or otherwise malformed backup file.
            attachmentByNoteID[attachment.noteID] = attachment
        }

        return try records.map { record in
            var copy = record
            guard let attachment = attachmentByNoteID[record.id],
                  !attachment.data.isEmpty else {
                copy.screenshotPath = nil
                return copy
            }

            let safeExtension = Self.safeImageExtension(attachment.fileName)
            let destination = screenshotsDirectory
                .appendingPathComponent("\(record.id.uuidString).\(safeExtension)")

            do {
                try attachment.data.write(to: destination, options: .atomic)
            } catch {
                throw BackupError.cannotWriteAttachment(destination.path)
            }
            copy.screenshotPath = destination.path
            return copy
        }
    }

    private static func safeImageExtension(_ fileName: String) -> String {
        let extensionName = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch extensionName {
        case "jpg", "jpeg", "heic", "webp":
            return extensionName
        default:
            return "png"
        }
    }
}

// MARK: - Automatic review PDF destination

/// Stores the user's preferred destination for Codex review PDFs.
///
/// The Enhanced target can write to the selected folder directly. The
/// security-scoped bookmark also keeps the setting usable by the sandboxed
/// target after the settings window has been closed or the app has relaunched.
enum ReviewExportSettings {

    private static let directoryPathKey = "reviewPDFExportDirectoryPath"
    private static let directoryBookmarkKey = "reviewPDFExportDirectoryBookmark"

    static var defaultDirectoryURL: URL {
#if VIDEONOTES_ENHANCED
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("VideoNotes 复盘", isDirectory: true)
#else
        ApplicationStorage.directory
            .appendingPathComponent("ReviewPDFs", isDirectory: true)
#endif
    }

    /// Returns the bookmarked folder when available, then the legacy path,
    /// and finally a predictable user-visible default directory.
    static var directoryURL: URL {
        let defaults = UserDefaults.standard

        if let bookmarkData = defaults.data(forKey: directoryBookmarkKey) {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    store(resolvedURL)
                }
                return resolvedURL.standardizedFileURL
            }
        }

        if let path = defaults.string(forKey: directoryPathKey),
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        return defaultDirectoryURL
    }

    static func setDirectory(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: directoryPathKey)
            UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
            return
        }
        store(url.standardizedFileURL)
    }

    static func resetToDefault() {
        setDirectory(nil)
    }

    /// Keeps security-scoped access active for the full duration of an export.
    /// This matters for the sandboxed target and is harmless for the Enhanced
    /// target, where the selected directory is already directly accessible.
    static func withDirectoryAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = directoryURL
        let hasSecurityScope = directory.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try body(directory)
    }

    /// Avoids overwriting an earlier review generated in the same second.
    static func uniqueFileURL(in directory: URL, fileName: String) -> URL {
        let fileManager = FileManager.default
        let initialURL = directory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: initialURL.path) else {
            return initialURL
        }

        let fileURL = URL(fileURLWithPath: fileName)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let extensionName = fileURL.pathExtension
        for index in 2...999 {
            let candidateName = extensionName.isEmpty
                ? "\(baseName)-\(index)"
                : "\(baseName)-\(index).\(extensionName)"
            let candidateURL = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        let fallbackName = extensionName.isEmpty
            ? "\(baseName)-\(UUID().uuidString.prefix(8))"
            : "\(baseName)-\(UUID().uuidString.prefix(8)).\(extensionName)"
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
    }

    private static func store(_ url: URL) {
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: directoryPathKey)
        if let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmarkData, forKey: directoryBookmarkKey)
        } else {
            defaults.removeObject(forKey: directoryBookmarkKey)
        }
    }
}
