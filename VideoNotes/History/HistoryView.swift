import SwiftUI
import AppKit

// MARK: - HistoryView

struct HistoryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case favorites = "收藏"
        var id: Self { self }
    }

    @ObservedObject private var store = HistoryStore.shared
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var showClearConfirm = false
    @State private var copiedId: UUID?
    @State private var exportCopied = false

    var body: some View {
        ZStack {
            VNStyle.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)
                content
                Divider().opacity(0.45)
                footer
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 680)
        .alert("清空所有笔记？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) { store.deleteAll() }
        } message: {
            Text("将删除全部 \(store.records.count) 条笔记，包括收藏内容。此操作无法撤销。")
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("笔记")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索内容或标签", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .accessibilityLabel("搜索笔记")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .vnGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var content: some View {
        if filteredGroups.isEmpty {
            VStack(spacing: 13) {
                Image(systemName: emptyIcon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(emptyTitle)
                    .font(.title3.weight(.semibold))
                Text(emptyDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !searchText.isEmpty || filter == .favorites {
                    Button("显示全部") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            searchText = ""
                            filter = .all
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(filteredGroups, id: \.0) { group, items in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(group.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text("\(items.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, record in
                                    HistoryRow(
                                        record: record,
                                        isCopied: copiedId == record.id,
                                        onCopy: { copyRecord(record) },
                                        onToggleFavorite: { store.toggleFavorite(id: record.id) },
                                        onDelete: { store.delete(id: record.id) }
                                    )
                                    if index < items.count - 1 {
                                        Divider().padding(.leading, 70).opacity(0.42)
                                    }
                                }
                            }
                            .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("清空", systemImage: "trash")
            }
            .disabled(store.records.isEmpty)

            Spacer()

            if exportCopied {
                Label("Markdown 已复制", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button {
                ClipboardManager.shared.copy(text: store.exportAsMarkdown())
                withAnimation { exportCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { exportCopied = false }
                }
            } label: {
                Label("复制 Markdown", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .tint(VNStyle.accent)
            .disabled(store.records.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var baseRecords: [NoteRecord] {
        filter == .favorites ? store.records.filter(\.isFavorite) : store.records
    }

    private var filteredGroups: [(NoteRecord.TimeGroup, [NoteRecord])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = query.isEmpty ? baseRecords : baseRecords.filter {
            $0.content.lowercased().contains(query)
                || $0.tags.contains(where: { $0.lowercased().contains(query) })
                || ($0.videoTitle?.lowercased().contains(query) ?? false)
        }
        return NoteRecord.TimeGroup.allCases.compactMap { group in
            let items = records.filter { $0.timeGroup == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    private var summaryText: String {
        let favoriteCount = store.records.filter(\.isFavorite).count
        return "\(store.records.count) 条记录 · \(favoriteCount) 条收藏 · 仅存储在这台 Mac"
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "没有匹配的笔记" }
        if filter == .favorites { return "还没有收藏" }
        return "从第一条笔记开始"
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "换个关键词试试，或清除当前筛选。" }
        if filter == .favorites { return "点亮笔记旁的星标，就能在这里快速找到。" }
        return "按 ⌘⇧Space，在任何视频上方快速记录。"
    }

    private var emptyIcon: String {
        !searchText.isEmpty ? "magnifyingglass" : (filter == .favorites ? "star" : "note.text")
    }

    private func copyRecord(_ record: NoteRecord) {
        ClipboardManager.shared.copy(text: record.content)
        withAnimation(.snappy(duration: 0.2)) { copiedId = record.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedId == record.id { withAnimation { copiedId = nil } }
        }
    }
}

// MARK: - HistoryRow

struct HistoryRow: View {
    let record: NoteRecord
    let isCopied: Bool
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 3) {
                Text(record.createdAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(record.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(width: 48)

            VStack(alignment: .leading, spacing: 7) {
                Text(record.content)
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if !record.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(record.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(VNStyle.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VNStyle.accent.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }

            HStack(spacing: 2) {
                iconButton(
                    record.isFavorite ? "star.fill" : "star",
                    color: record.isFavorite ? .yellow : .secondary,
                    help: record.isFavorite ? "取消收藏" : "收藏",
                    action: onToggleFavorite
                )
                iconButton(
                    isCopied ? "checkmark" : "doc.on.doc",
                    color: isCopied ? .green : .secondary,
                    help: "复制",
                    action: onCopy
                )
                iconButton("trash", color: .secondary, help: "删除", action: onDelete)
            }
            .opacity(isHovered || record.isFavorite || isCopied ? 1 : 0.42)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .background(isHovered ? VNStyle.accent.opacity(0.045) : .clear)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("复制", action: onCopy)
            Button(record.isFavorite ? "取消收藏" : "收藏", action: onToggleFavorite)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private func iconButton(
        _ symbol: String,
        color: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 27, height: 27)
                .background(isHovered ? Color.primary.opacity(0.055) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
