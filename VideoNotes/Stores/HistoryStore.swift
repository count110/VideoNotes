import Foundation
import Combine

// MARK: - HistoryStore

/// 历史记录持久化存储
///
/// 使用 JSON 文件存储（不依赖 SwiftData / CoreData）
/// 原因：
/// 1. 零依赖，macOS 13+ 原生支持
/// 2. 笔记规模以个人使用为准，JSON 在当前阶段足够
/// 3. 易于调试和迁移
/// 4. 未来可平滑迁移到 SwiftData
///
/// 隐私：所有数据仅存储在本地 ~/Library/Application Support/VideoNotes/
///
final class HistoryStore: ObservableObject {

    enum RestoreMode {
        case merge
        case replace
    }

    struct VideoGroup: Identifiable {
        let id: UUID
        let title: String
        let records: [NoteRecord]
    }

    // MARK: - Singleton

    static let shared = HistoryStore()

    // MARK: - Properties

    @Published private(set) var records: [NoteRecord] = []

    /// 存储目录
    private let storageDir: URL

    /// 存储文件
    private let storageFile: URL

    // MARK: - Init

    private init() {
        let fm = FileManager.default
        storageDir = ApplicationStorage.directory
        storageFile = storageDir.appendingPathComponent("history.json")

        // 创建目录
        try? fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

        load()
    }

    // MARK: - Create

    func add(
        content: String,
        contentType: NoteRecord.ContentType = .plainText,
        inputMethod: NoteRecord.InputMethod = .keyboard,
        videoTitle: String? = nil,
        videoURL: String? = nil,
        videoSessionID: UUID? = nil,
        videoTimestamp: String? = nil,
        videoTimestampSeconds: TimeInterval? = nil,
        screenshotPath: String? = nil,
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil
    ) {
        let record = NoteRecord(
            content: content,
            contentType: contentType,
            inputMethod: inputMethod,
            videoTitle: videoTitle,
            videoURL: videoURL,
            videoTimestamp: videoTimestamp,
            videoSessionID: videoSessionID,
            videoTimestampSeconds: videoTimestampSeconds,
            screenshotPath: screenshotPath,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceApplicationName: sourceApplicationName
        )
        records.insert(record, at: 0)
        save()
    }

    // MARK: - Screenshot Clip

    /// 创建一条截图笔记。
    /// 截图文件由 ScreenshotService 先落盘，这里只记录路径与视频时间。
    @discardableResult
    func addScreenshotClip(
        screenshotPath: String,
        videoTitle: String? = nil,
        videoURL: String? = nil,
        videoSessionID: UUID? = nil,
        videoTimestamp: String? = nil,
        videoTimestampSeconds: TimeInterval? = nil,
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil
    ) -> NoteRecord {
        let record = NoteRecord(
            content: "",
            contentType: .screenshot,
            inputMethod: .keyboard,
            videoTitle: videoTitle,
            videoURL: videoURL,
            videoTimestamp: videoTimestamp,
            videoSessionID: videoSessionID,
            videoTimestampSeconds: videoTimestampSeconds,
            screenshotPath: screenshotPath,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceApplicationName: sourceApplicationName
        )
        records.insert(record, at: 0)
        save()
        return record
    }

    // MARK: - Update

    func update(id: UUID, content: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].content = content
        records[index].updatedAt = Date()
        save()
    }

    func toggleFavorite(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isFavorite.toggle()
        records[index].updatedAt = Date()
        save()
    }

    func addTag(id: UUID, tag: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if !records[index].tags.contains(tag) {
            records[index].tags.append(tag)
            records[index].updatedAt = Date()
            save()
        }
    }

    // MARK: - Delete

    func delete(id: UUID) {
        let screenshotPath = records.first(where: { $0.id == id })?.screenshotPath
        records.removeAll { $0.id == id }
        if let screenshotPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: screenshotPath))
        }
        save()
    }

    func deleteAll() {
        let screenshotPaths = records.compactMap(\.screenshotPath)
        records.removeAll()
        for path in screenshotPaths {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        save()
    }

    // MARK: - Query

    func search(query: String) -> [NoteRecord] {
        guard !query.isEmpty else { return records }

        let lowered = query.lowercased()
        return records.filter { record in
            record.content.lowercased().contains(lowered)
            || record.tags.contains { $0.lowercased().contains(lowered) }
            || (record.videoTitle?.lowercased().contains(lowered) ?? false)
        }
    }

    /// 按时间分组
    func groupedRecords(query: String = "") -> [(NoteRecord.TimeGroup, [NoteRecord])] {
        let filtered = search(query: query)
        return NoteRecord.TimeGroup.allCases.compactMap { group in
            let items = filtered.filter { $0.timeGroup == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// Groups only notes created within an explicit Video Session. Older notes
    /// without session metadata deliberately remain in the date-based view.
    func videoGroups(records source: [NoteRecord]? = nil) -> [VideoGroup] {
        let records = source ?? self.records
        let grouped = Dictionary(grouping: records.compactMap { record -> (UUID, NoteRecord)? in
            guard let sessionID = record.videoSessionID else { return nil }
            return (sessionID, record)
        }, by: \.0)

        return grouped.compactMap { sessionID, pairs in
            let items = pairs.map(\.1)
            guard let title = items.compactMap(\.videoTitle).first, !title.isEmpty else { return nil }
            return VideoGroup(
                id: sessionID,
                title: title,
                records: items.sorted {
                    let left = $0.videoTimestampSeconds ?? $0.createdAt.timeIntervalSinceReferenceDate
                    let right = $1.videoTimestampSeconds ?? $1.createdAt.timeIntervalSinceReferenceDate
                    return left < right
                }
            )
        }
        .sorted { left, right in
            let leftDate = left.records.map(\.createdAt).max() ?? .distantPast
            let rightDate = right.records.map(\.createdAt).max() ?? .distantPast
            return leftDate > rightDate
        }
    }

    // MARK: - Export

    func exportAsMarkdown() -> String {
        exportAsMarkdown(records: records)
    }

    /// Exports an explicit selection without applying a hidden date filter.
    /// The history export sheet and the local Codex integration both use this
    /// path so every output contains the same selected records.
    func exportAsMarkdown(
        records selectedRecords: [NoteRecord],
        title: String = "VideoNotes 历史记录"
    ) -> String {
        var lines: [String] = ["# \(title)", ""]

        let sortedRecords = selectedRecords.sorted { $0.createdAt < $1.createdAt }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sortedRecords) { record in
            if calendar.isDateInToday(record.createdAt) {
                return "今天"
            } else if calendar.isDateInYesterday(record.createdAt) {
                return "昨天"
            } else if Date().timeIntervalSince(record.createdAt) < 7 * 24 * 3600 {
                return "7 天内"
            } else {
                return "更早"
            }
        }

        for groupName in ["今天", "昨天", "7 天内", "更早"] {
            guard let items = grouped[groupName], !items.isEmpty else { continue }
            lines.append("## \(groupName)")
            lines.append("")
            for item in items {
                let time = item.createdAt.formatted(date: .abbreviated, time: .shortened)
                if item.isScreenshotClip {
                    let timestamp = item.videoTimestamp ?? (item.videoTimestampSeconds.map { VideoSession.formattedTimestamp(for: $0) } ?? "")
                    let caption = timestamp.isEmpty ? "截图" : "截图 \(timestamp)"
                    let note = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = note.isEmpty ? "" : "：\(note)"
                    lines.append("- [\(time)] \(caption)\(suffix)")
                } else {
                    var line = "- [\(time)] \(item.content)"
                    if let videoTitle = item.videoTitle,
                       !videoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        line += "（视频：\(videoTitle)）"
                    }
                    if !item.tags.isEmpty {
                        line += " [标签：\(item.tags.joined(separator: "、"))]"
                    }
                    lines.append(line)
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Restores notes after a backup has been validated and screenshot paths
    /// have been rewritten to the current Mac.
    @discardableResult
    func restore(records importedRecords: [NoteRecord], mode: RestoreMode) -> Int {
        switch mode {
        case .replace:
            records = importedRecords
        case .merge:
            var merged: [UUID: NoteRecord] = [:]
            for record in records {
                merged[record.id] = record
            }
            for record in importedRecords {
                merged[record.id] = record
            }
            records = Array(merged.values)
        }

        records.sort { $0.createdAt > $1.createdAt }
        save()
        return importedRecords.count
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageFile, options: .atomic)
        } catch {
            print("[HistoryStore] 保存失败: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageFile.path) else { return }

        do {
            let data = try Data(contentsOf: storageFile)
            records = try JSONDecoder().decode([NoteRecord].self, from: data)
            records.sort { $0.createdAt > $1.createdAt }
        } catch {
            print("[HistoryStore] 加载失败: \(error)")
        }
    }
}
