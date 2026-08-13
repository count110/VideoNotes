import Foundation
import Combine

// MARK: - HistoryStore

/// 历史记录持久化存储
///
/// 使用 JSON 文件存储（不依赖 SwiftData / CoreData）
/// 原因：
/// 1. 零依赖，macOS 13+ 原生支持
/// 2. 数据量小（≤500 条），JSON 足够
/// 3. 易于调试和迁移
/// 4. 未来可平滑迁移到 SwiftData
///
/// 隐私：所有数据仅存储在本地 ~/Library/Application Support/VideoNotes/
///
final class HistoryStore: ObservableObject {

    // MARK: - Singleton

    static let shared = HistoryStore()

    // MARK: - Properties

    @Published private(set) var records: [NoteRecord] = []

    /// 最大保存数量
    static let maxCount: Int = 500

    /// 存储目录
    private let storageDir: URL

    /// 存储文件
    private let storageFile: URL

    // MARK: - Init

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        storageDir = appSupport.appendingPathComponent("VideoNotes", isDirectory: true)
        storageFile = storageDir.appendingPathComponent("history.json")

        // 创建目录
        try? fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

        load()
    }

    // MARK: - Create

    func add(content: String, contentType: NoteRecord.ContentType = .plainText, inputMethod: NoteRecord.InputMethod = .keyboard) {
        let record = NoteRecord(content: content, contentType: contentType, inputMethod: inputMethod)
        records.insert(record, at: 0)
        enforceMaxLimit()
        save()
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
        records.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        records.removeAll()
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

    // MARK: - Export

    func exportAsMarkdown() -> String {
        var lines: [String] = ["# VideoNotes 历史记录", ""]

        for (group, items) in groupedRecords() {
            lines.append("## \(group.displayName)")
            lines.append("")
            for item in items {
                let time = item.createdAt.formatted(date: .abbreviated, time: .shortened)
                lines.append("- [\(time)] \(item.content)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func enforceMaxLimit() {
        guard records.count > Self.maxCount else { return }

        // 收藏不应被静默删除；当收藏本身超过上限时允许暂时超出容量。
        let favorites = records.filter(\.isFavorite)
        let nonFavorites = records.filter { !$0.isFavorite }
        let availableSlots = max(0, Self.maxCount - favorites.count)
        records = favorites + nonFavorites.prefix(availableSlots)
        records.sort { $0.createdAt > $1.createdAt }
    }

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
            enforceMaxLimit()
        } catch {
            print("[HistoryStore] 加载失败: \(error)")
        }
    }
}
