import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - HistoryView

private struct VideoContentGroup: Identifiable {
    let target: VideoSubtitleTarget
    let records: [NoteRecord]
    let subtitles: [VideoSubtitleDocument]
    let subtitleAnalysis: VideoSubtitleAnalysis?
    let lastActivity: Date

    var id: UUID { target.sessionID }
    var title: String { target.title }
}

struct HistoryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case favorites = "收藏"
        var id: Self { self }
    }

    private enum BrowseMode: String, CaseIterable, Identifiable {
        case date = "时间"
        case video = "视频"
        var id: Self { self }
    }

    @ObservedObject private var store = HistoryStore.shared
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var browseMode: BrowseMode = .date
    @State private var showClearConfirm = false
    @State private var copiedId: UUID?
    @State private var showExportSheet = false
    @State private var isGeneratingCodexReview = false
    @State private var exportStatus: String?
    @State private var editingRecord: NoteRecord?
    @State private var editingContent = ""
    @ObservedObject private var reviewManager = ReviewManager.shared
    @State private var reviewStatus: String?
    @State private var reviewStatusSessionID: UUID?
    @State private var presentedVideoReview: VideoReviewResult?
    @State private var previewRecord: NoteRecord?
    @ObservedObject private var subtitleStore = VideoSubtitleStore.shared
    @State private var showSubtitleImportSheet = false
    @State private var subtitleImportTarget: VideoSubtitleTarget?
    @State private var presentedSubtitleAnalysis: VideoSubtitleAnalysis?
    @State private var isGeneratingSubtitleAnalysis = false
    @State private var subtitleAnalysisStatus: String?
    @State private var subtitleAnalysisStatusSessionID: UUID?
    @State private var subtitleAnalysisUsesCodex = false

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
        .sheet(item: $editingRecord) { record in
            NoteEditorSheet(
                content: $editingContent,
                onCancel: { editingRecord = nil },
                onSave: {
                    store.update(id: record.id, content: editingContent)
                    editingRecord = nil
                }
            )
        }
        .sheet(item: $presentedVideoReview) { result in
            VideoReviewDashboard(result: result)
        }
        .sheet(item: $previewRecord) { record in
            ScreenshotPreviewSheet(record: record)
        }
        .sheet(isPresented: $showSubtitleImportSheet) {
            SubtitleImportSheet(
                initialTarget: subtitleImportTarget,
                availableTargets: videoSubtitleTargets,
                onImported: { target in
                    subtitleImportTarget = target
                    browseMode = .video
                }
            )
        }
        .sheet(item: $presentedSubtitleAnalysis) { analysis in
            SubtitleAnalysisDashboard(
                analysis: analysis,
                documents: subtitleStore.documents(for: analysis.videoSessionID),
                notes: store.records.filter { $0.videoSessionID == analysis.videoSessionID }
            )
        }
        .sheet(isPresented: $showExportSheet) {
            NoteExportSheet(
                allRecords: store.records,
                visibleRecords: visibleExportRecords,
                isGeneratingCodex: $isGeneratingCodexReview,
                onCopy: { records in
                    copySelectedRecords(records)
                },
                onExportPDF: { records in
                    exportPDF(records: records)
                },
                onGenerateCodexPDF: { records in
                    generateCodexPDF(records: records)
                },
                onCancelCodex: {
                    LocalCodexClient.shared.cancelCurrentRun()
                }
            )
        }
        .onReceive(reviewManager.videoReviewCompleted) { result in
            reviewStatusSessionID = result.sessionID
            reviewStatus = "分析已生成，已复制到剪贴板"
            presentedVideoReview = result
        }
        .onReceive(reviewManager.videoReviewFailed) { failure in
            reviewStatusSessionID = failure.sessionID
            reviewStatus = failure.message
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
                Button {
                    openSubtitleImporter()
                } label: {
                    Label("导入字幕", systemImage: "captions.bubble")
                }
                .buttonStyle(.bordered)
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Picker("浏览方式", selection: $browseMode) {
                ForEach(BrowseMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)

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
        if isEmpty {
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
        } else if browseMode == .date {
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
                                        onEdit: { beginEditing(record) },
                                        onToggleFavorite: { store.toggleFavorite(id: record.id) },
                                        onDelete: { store.delete(id: record.id) },
                                        onJumpToVideo: { jumpToVideo(record) },
                                        onPreviewScreenshot: { previewRecord = record },
                                        timeStyle: .createdAt
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
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(videoGroups) { group in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.rectangle.fill")
                                    .foregroundStyle(VNStyle.accent)
                                Text(group.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(group.records.count) 条笔记")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                if !group.subtitles.isEmpty {
                                    Label("\(group.subtitles.count) 份字幕", systemImage: "captions.bubble")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(VNStyle.violet)
                                }
                                Spacer()

                                if !group.subtitles.isEmpty {
                                    if isGeneratingSubtitleAnalysis,
                                       subtitleAnalysisStatusSessionID == group.id {
                                        if subtitleAnalysisUsesCodex {
                                            Button {
                                                LocalCodexClient.shared.cancelCurrentRun()
                                            } label: {
                                                Label("取消字幕分析", systemImage: "xmark.circle")
                                            }
                                            .buttonStyle(.bordered)
                                            .tint(.orange)
                                        } else {
                                            ProgressView()
                                                .controlSize(.small)
                                                .padding(.horizontal, 7)
                                        }
                                    } else if let analysis = group.subtitleAnalysis {
                                        Button {
                                            presentedSubtitleAnalysis = analysis
                                        } label: {
                                            Label("查看字幕分析", systemImage: "sparkles.rectangle.stack")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(VNStyle.violet)
                                        .disabled(isGeneratingSubtitleAnalysis)
                                    } else {
                                        Button {
                                            generateSubtitleAnalysis(for: group)
                                        } label: {
                                            Label("AI 分析字幕", systemImage: "sparkles")
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(VNStyle.violet)
                                        .disabled(isGeneratingSubtitleAnalysis)
                                    }
                                }

                                Button {
                                    openSubtitleImporter(for: group.target)
                                } label: {
                                    Label(
                                        group.subtitles.isEmpty ? "导入字幕" : "管理字幕",
                                        systemImage: "captions.bubble"
                                    )
                                }
                                .buttonStyle(.bordered)

                                if !group.records.isEmpty,
                                   let result = reviewManager.videoReview(for: group.id) {
                                    Button {
                                        presentedVideoReview = result
                                    } label: {
                                        Label("查看可视化分析", systemImage: "chart.xyaxis.line")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(VNStyle.violet)
                                    .contextMenu {
                                        Button {
                                            reviewStatus = nil
                                            reviewStatusSessionID = group.id
                                            reviewManager.generateVideoReview(sessionID: group.id)
                                        } label: {
                                            Label("重新分析", systemImage: "arrow.clockwise")
                                        }
                                        .disabled(reviewManager.isGenerating)
                                    }
                                } else if !group.records.isEmpty {
                                    Button {
                                        reviewStatus = nil
                                        reviewStatusSessionID = group.id
                                        reviewManager.generateVideoReview(sessionID: group.id)
                                    } label: {
                                        if reviewManager.isGenerating, reviewStatusSessionID == group.id {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("复盘这个视频", systemImage: "sparkles")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(VNStyle.accent)
                                    .disabled(reviewManager.isGenerating)
                                }
                            }
                            .padding(.horizontal, 4)

                            if !group.subtitles.isEmpty {
                                Text(
                                    group.subtitles
                                        .map { "\($0.sourceName) · \($0.format.displayName) · \($0.cueCount) 条时间点" }
                                        .joined(separator: "    ")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.horizontal, 4)
                            }

                            if let subtitleAnalysisStatus,
                               subtitleAnalysisStatusSessionID == group.id {
                                HStack(spacing: 8) {
                                    if isGeneratingSubtitleAnalysis {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    Text(subtitleAnalysisStatus)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            }

                            if let reviewStatus, reviewStatusSessionID == group.id {
                                HStack(spacing: 10) {
                                    Text(reviewStatus)
                                        .font(.caption)
                                        .foregroundStyle(
                                            reviewManager.videoReview(for: group.id) == nil
                                                ? Color.secondary
                                                : Color.green
                                        )

                                }
                                .padding(.horizontal, 4)
                            }

                            if group.records.isEmpty {
                                HStack(spacing: 10) {
                                    Image(systemName: "text.bubble")
                                        .foregroundStyle(VNStyle.violet)
                                    Text("字幕已关联到这个视频。可直接用 AI 分析，或继续在视频上记录笔记。")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                        HistoryRow(
                                            record: record,
                                            isCopied: copiedId == record.id,
                                            onCopy: { copyRecord(record) },
                                            onEdit: { beginEditing(record) },
                                            onToggleFavorite: { store.toggleFavorite(id: record.id) },
                                            onDelete: { store.delete(id: record.id) },
                                            onJumpToVideo: { jumpToVideo(record) },
                                            onPreviewScreenshot: { previewRecord = record },
                                            timeStyle: .videoTimestamp
                                        )
                                        if index < group.records.count - 1 {
                                            Divider().padding(.leading, 70).opacity(0.42)
                                        }
                                    }
                                }
                                .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
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

            if let exportStatus {
                Label(exportStatus, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button {
                showExportSheet = true
            } label: {
                Label("导出 / 复制", systemImage: "square.and.arrow.up")
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

    private var filteredRecords: [NoteRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? baseRecords : baseRecords.filter {
            $0.content.lowercased().contains(query)
                || $0.tags.contains(where: { $0.lowercased().contains(query) })
                || ($0.videoTitle?.lowercased().contains(query) ?? false)
        }
    }

    private var videoGroups: [VideoContentGroup] {
        let noteGroups = store.videoGroups(records: filteredRecords)
        let notesBySession = Dictionary(
            uniqueKeysWithValues: noteGroups.map { ($0.id, $0) }
        )
        let subtitlesBySession = Dictionary(
            grouping: subtitleStore.documents,
            by: \.videoSessionID
        )
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sessionIDs = Set(notesBySession.keys)

        // Subtitle-only videos remain usable even before the user writes the
        // first note. The Favorites filter intentionally stays note-based.
        if filter != .favorites {
            for subtitle in subtitleStore.documents {
                let matchesSearch = query.isEmpty
                    || subtitle.videoTitle.lowercased().contains(query)
                    || subtitle.sourceName.lowercased().contains(query)
                    || subtitle.normalizedText.lowercased().contains(query)
                if matchesSearch {
                    sessionIDs.insert(subtitle.videoSessionID)
                }
            }
        }

        return sessionIDs.compactMap { sessionID in
            let noteGroup = notesBySession[sessionID]
            let records = noteGroup?.records ?? []
            let subtitles = (subtitlesBySession[sessionID] ?? [])
                .sorted { $0.importedAt < $1.importedAt }
            guard !records.isEmpty || !subtitles.isEmpty else { return nil }

            let title = noteGroup?.title
                ?? subtitles.first?.videoTitle
                ?? "未命名视频"
            let videoURL = records.compactMap(\.videoURL).first
                ?? subtitles.compactMap(\.videoURL).first
            let lastNoteDate = records.map(\.createdAt).max() ?? .distantPast
            let lastSubtitleDate = subtitles.map(\.importedAt).max() ?? .distantPast
            let analysis = subtitleStore.analysis(for: sessionID)
            let lastAnalysisDate = analysis?.generatedAt ?? .distantPast

            return VideoContentGroup(
                target: VideoSubtitleTarget(
                    sessionID: sessionID,
                    title: title,
                    videoURL: videoURL
                ),
                records: records,
                subtitles: subtitles,
                subtitleAnalysis: analysis,
                lastActivity: max(max(lastNoteDate, lastSubtitleDate), lastAnalysisDate)
            )
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The date view shows every filtered record, while the video view only
    /// shows records that belong to a titled video session. Keep "当前筛选
    /// 结果" aligned with what is actually visible in either mode.
    private var visibleExportRecords: [NoteRecord] {
        guard browseMode == .video else { return filteredRecords }
        return videoGroups.flatMap { $0.records }
    }

    private var isEmpty: Bool {
        browseMode == .date ? filteredGroups.isEmpty : videoGroups.isEmpty
    }

    private var summaryText: String {
        let favoriteCount = store.records.filter(\.isFavorite).count
        return "\(store.records.count) 条记录 · \(favoriteCount) 条收藏 · 本机存储，可导出备份"
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "没有匹配的笔记" }
        if filter == .favorites { return "还没有收藏" }
        if browseMode == .video { return "还没有视频笔记" }
        return "从第一条笔记开始"
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "换个关键词试试，或清除当前筛选。" }
        if filter == .favorites { return "点亮笔记旁的星标，就能在这里快速找到。" }
        if browseMode == .video { return "从菜单栏开始视频会话后，笔记会自动按视频时间整理。" }
        return "按 ⌘⇧Space，在任何视频上方快速记录。"
    }

    private var emptyIcon: String {
        !searchText.isEmpty ? "magnifyingglass" : (filter == .favorites ? "star" : (browseMode == .video ? "play.rectangle" : "note.text"))
    }

    private func copyRecord(_ record: NoteRecord) {
        let textToCopy = record.isScreenshotClip && record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? VideoJumpService.displayTimestamp(for: record)
            : record.content
        ClipboardManager.shared.copy(text: textToCopy)
        withAnimation(.snappy(duration: 0.2)) { copiedId = record.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedId == record.id { withAnimation { copiedId = nil } }
        }
    }

    private func jumpToVideo(_ record: NoteRecord) {
        VideoJumpService.shared.jump(to: record)
    }

    // MARK: - Video subtitles

    private var capturedSubtitleTarget: VideoSubtitleTarget? {
        guard let context = MediaCaptureResolver.context() else { return nil }
        return VideoSubtitleTarget(
            sessionID: context.sessionID,
            title: context.title,
            videoURL: context.url
        )
    }

    private var videoSubtitleTargets: [VideoSubtitleTarget] {
        var targets: [UUID: VideoSubtitleTarget] = [:]

        for group in store.videoGroups() {
            let videoURL = group.records.compactMap(\.videoURL).first
            targets[group.id] = VideoSubtitleTarget(
                sessionID: group.id,
                title: group.title,
                videoURL: videoURL
            )
        }

        for subtitle in subtitleStore.documents {
            if targets[subtitle.videoSessionID] == nil {
                targets[subtitle.videoSessionID] = VideoSubtitleTarget(
                    sessionID: subtitle.videoSessionID,
                    title: subtitle.videoTitle,
                    videoURL: subtitle.videoURL
                )
            }
        }

        if let capturedSubtitleTarget {
            targets[capturedSubtitleTarget.id] = capturedSubtitleTarget
        }

        return targets.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func openSubtitleImporter(for target: VideoSubtitleTarget? = nil) {
        subtitleImportTarget = target
            ?? capturedSubtitleTarget
            ?? videoSubtitleTargets.first
        showSubtitleImportSheet = true
    }

    private func generateSubtitleAnalysis(for group: VideoContentGroup) {
        guard !group.subtitles.isEmpty, !isGeneratingSubtitleAnalysis else { return }

        let useLocalCodex = LocalCodexClient.shared.resolvedExecutablePath != nil
        guard useLocalCodex || AISummarizer.shared.isConfigured else {
            showExportAlert(
                message: "没有可用的 AI 分析服务",
                informativeText: "请在设置中配置本地 Codex，或填写 DeepSeek API Key 后再试。"
            )
            return
        }

        isGeneratingSubtitleAnalysis = true
        subtitleAnalysisUsesCodex = useLocalCodex
        subtitleAnalysisStatusSessionID = group.id
        subtitleAnalysisStatus = useLocalCodex
            ? "正在通过本地 Codex 分析 (group.subtitles.count) 份字幕…"
            : "正在通过已配置的 AI 分析 (group.subtitles.count) 份字幕…"

        let finish: (Result<String, Error>) -> Void = { result in
            DispatchQueue.main.async {
                self.isGeneratingSubtitleAnalysis = false
                self.subtitleAnalysisUsesCodex = false

                switch result {
                case .success(let markdown):
                    let analysis = VideoSubtitleAnalysis(
                        videoSessionID: group.id,
                        videoTitle: group.title,
                        markdown: markdown,
                        subtitleCount: group.subtitles.count,
                        cueCount: group.subtitles.reduce(0) { $0 + $1.cueCount },
                        noteCount: group.records.count,
                        generatedAt: Date()
                    )
                    self.subtitleStore.saveAnalysis(analysis)
                    self.subtitleAnalysisStatus = "字幕分析已生成，已在本机保存"
                    self.presentedSubtitleAnalysis = analysis
                case .failure(let error):
                    if let codexError = error as? LocalCodexClient.CodexError,
                       case .cancelled = codexError {
                        self.subtitleAnalysisStatus = "已取消字幕分析"
                        self.clearSubtitleAnalysisStatus(after: 2.5, for: group.id)
                    } else {
                        self.subtitleAnalysisStatus = nil
                        self.showExportAlert(
                            message: "字幕分析失败",
                            informativeText: error.localizedDescription
                        )
                    }
                }
            }
        }

        if useLocalCodex {
            LocalCodexClient.shared.generateSubtitleAnalysis(
                videoTitle: group.title,
                documents: group.subtitles,
                notes: group.records,
                completion: finish
            )
        } else {
            AISummarizer.shared.generateSubtitleAnalysis(
                videoTitle: group.title,
                documents: group.subtitles,
                notes: group.records,
                completion: finish
            )
        }
    }

    private func clearSubtitleAnalysisStatus(
        after delay: TimeInterval,
        for sessionID: UUID
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !isGeneratingSubtitleAnalysis,
                  subtitleAnalysisStatusSessionID == sessionID else {
                return
            }
            withAnimation {
                subtitleAnalysisStatus = nil
                subtitleAnalysisStatusSessionID = nil
            }
        }
    }

    // MARK: - Selection export

    private func copySelectedRecords(_ selectedRecords: [NoteRecord]) {
        guard !selectedRecords.isEmpty else {
            showExportAlert(
                message: "没有可以复制的笔记",
                informativeText: "请调整导出范围后重试。"
            )
            return
        }

        let markdown = store.exportAsMarkdown(records: selectedRecords)
        ClipboardManager.shared.copy(text: markdown)
        withAnimation(.snappy(duration: 0.2)) {
            exportStatus = "已复制 \(selectedRecords.count) 条笔记"
        }
        clearExportStatus(after: 2.2)
    }

    private func exportPDF(records selectedRecords: [NoteRecord]) {
        guard !selectedRecords.isEmpty else {
            showExportAlert(
                message: "没有可以导出的笔记",
                informativeText: "请调整导出范围后重试。"
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "导出选定笔记"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.pdfFileName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try DailyNotesPDFExporter().export(
                records: selectedRecords,
                to: url,
                title: "VideoNotes 选定笔记",
                subtitle: Self.dateRangeDescription(for: selectedRecords)
            )
            exportStatus = "PDF 已导出"
            showExportSuccess(url: url, message: "笔记 PDF 已成功导出")
        } catch {
            showExportAlert(message: "导出失败", informativeText: error.localizedDescription)
        }
    }

    private func generateCodexPDF(records selectedRecords: [NoteRecord]) {
        guard !selectedRecords.isEmpty else {
            showExportAlert(
                message: "没有可以复盘的笔记",
                informativeText: "请调整导出范围后重试。"
            )
            return
        }
        guard LocalCodexClient.shared.resolvedExecutablePath != nil else {
            showExportAlert(
                message: "没有找到本地 Codex",
                informativeText: "请打开设置 → 本地 Codex，检查 CLI 路径或使用自动检测。"
            )
            return
        }

        isGeneratingCodexReview = true
        exportStatus = "Codex 正在整理 \(selectedRecords.count) 条笔记…"
        LocalCodexClient.shared.generateReview(records: selectedRecords) { result in
            isGeneratingCodexReview = false
            switch result {
            case .success(let markdown):
                showExportSheet = false
                exportCodexReview(markdown: markdown, records: selectedRecords)
            case .failure(let error):
                if let codexError = error as? LocalCodexClient.CodexError,
                   case .cancelled = codexError {
                    exportStatus = "已取消 Codex 复盘"
                    clearExportStatus(after: 2.5)
                } else {
                    exportStatus = nil
                    showExportAlert(message: "Codex 复盘失败", informativeText: error.localizedDescription)
                }
            }
        }
    }

    private func exportCodexReview(markdown: String, records selectedRecords: [NoteRecord]) {
        do {
            let url = try ReviewExportSettings.withDirectoryAccess { directory in
                let destination = ReviewExportSettings.uniqueFileURL(
                    in: directory,
                    fileName: Self.codexPDFFileName()
                )
                try ReviewPDFExporter().export(
                    markdown: markdown,
                    title: "VideoNotes · \(Self.dateRangeDescription(for: selectedRecords))",
                    noteCount: selectedRecords.count,
                    to: destination
                )
                return destination
            }
            exportStatus = "Codex 复盘 PDF 已自动保存：\(url.lastPathComponent)"
            clearExportStatus(after: 3.2)
        } catch {
            showExportAlert(message: "复盘 PDF 导出失败", informativeText: error.localizedDescription)
        }
    }

    private func clearExportStatus(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation { exportStatus = nil }
        }
    }

    private func showExportSuccess(url: URL, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.informativeText = url.path
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func showExportAlert(message: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func dateRangeDescription(for records: [NoteRecord]) -> String {
        guard let first = records.map(\.createdAt).min(),
              let last = records.map(\.createdAt).max() else {
            return "未指定日期"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        let firstText = formatter.string(from: first)
        let lastText = formatter.string(from: last)
        return firstText == lastText ? firstText : "\(firstText) — \(lastText)"
    }

    private static func pdfFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "VideoNotes_笔记_\(formatter.string(from: Date())).pdf"
    }

    private static func codexPDFFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "VideoNotes_Codex复盘_\(formatter.string(from: Date())).pdf"
    }

    private func beginEditing(_ record: NoteRecord) {
        editingContent = record.content
        editingRecord = record
    }
}

// MARK: - Selection export sheet

private struct NoteExportSheet: View {
    private enum Scope: String, CaseIterable, Identifiable, Equatable {
        case currentView = "当前筛选结果"
        case all = "全部笔记"
        case favorites = "收藏笔记"
        case today = "今天"
        case yesterday = "昨天"
        case thisWeek = "最近 7 天"
        case custom = "自定义日期"

        var id: Self { self }
    }

    let allRecords: [NoteRecord]
    let visibleRecords: [NoteRecord]
    @Binding var isGeneratingCodex: Bool
    let onCopy: ([NoteRecord]) -> Void
    let onExportPDF: ([NoteRecord]) -> Void
    let onGenerateCodexPDF: ([NoteRecord]) -> Void
    let onCancelCodex: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .currentView
    @State private var startDate: Date
    @State private var endDate: Date

    init(
        allRecords: [NoteRecord],
        visibleRecords: [NoteRecord],
        isGeneratingCodex: Binding<Bool>,
        onCopy: @escaping ([NoteRecord]) -> Void,
        onExportPDF: @escaping ([NoteRecord]) -> Void,
        onGenerateCodexPDF: @escaping ([NoteRecord]) -> Void,
        onCancelCodex: @escaping () -> Void
    ) {
        self.allRecords = allRecords
        self.visibleRecords = visibleRecords
        self._isGeneratingCodex = isGeneratingCodex
        self.onCopy = onCopy
        self.onExportPDF = onExportPDF
        self.onGenerateCodexPDF = onGenerateCodexPDF
        self.onCancelCodex = onCancelCodex

        let calendar = Calendar.current
        self._startDate = State(initialValue: calendar.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        self._endDate = State(initialValue: Date())
    }

    private var selectedRecords: [NoteRecord] {
        let calendar = Calendar.current
        switch scope {
        case .currentView:
            return visibleRecords
        case .all:
            return allRecords
        case .favorites:
            return allRecords.filter(\.isFavorite)
        case .today:
            return allRecords.filter { calendar.isDateInToday($0.createdAt) }
        case .yesterday:
            return allRecords.filter { calendar.isDateInYesterday($0.createdAt) }
        case .thisWeek:
            let boundary = calendar.date(
                byAdding: .day,
                value: -6,
                to: calendar.startOfDay(for: Date())
            ) ?? Date.distantPast
            return allRecords.filter { $0.createdAt >= boundary }
        case .custom:
            let rawStart = calendar.startOfDay(for: startDate)
            let rawEnd = calendar.startOfDay(for: endDate)
            let start = min(rawStart, rawEnd)
            let endDay = max(rawStart, rawEnd)
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return allRecords.filter { $0.createdAt >= start && $0.createdAt < end }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导出或复制笔记")
                        .font(.title2.weight(.bold))
                    Text("先选择范围，再决定输出方式。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("笔记范围")
                    .font(.subheadline.weight(.semibold))
                Picker("笔记范围", selection: $scope) {
                    ForEach(Scope.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if scope == .currentView {
                    Text("按当前历史记录窗口的搜索和收藏筛选处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if scope == .custom {
                    HStack(spacing: 12) {
                        DatePicker("开始", selection: $startDate, displayedComponents: .date)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        DatePicker("结束", selection: $endDate, displayedComponents: .date)
                    }
                    .font(.caption)
                    Text("开始和结束日期可按任意顺序选择，系统会自动按时间先后处理。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(15)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 9) {
                Image(systemName: selectedRecords.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(selectedRecords.isEmpty ? .orange : .green)
                Text(selectedRecords.isEmpty ? "当前范围没有笔记" : "将处理 \(selectedRecords.count) 条笔记")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if selectedRecords.count > 200 {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("当前范围较大，本地 Codex 可能需要 20 分钟以上。建议改选“今天”或自定义日期，按学习日分次复盘。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Button {
                    onCopy(selectedRecords)
                    dismiss()
                } label: {
                    Label("复制 Markdown", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRecords.isEmpty || isGeneratingCodex)

                Button {
                    onExportPDF(selectedRecords)
                    dismiss()
                } label: {
                    Label("导出 PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.borderedProminent)
                .tint(VNStyle.accent)
                .disabled(selectedRecords.isEmpty || isGeneratingCodex)

                Button {
                    if isGeneratingCodex {
                        onCancelCodex()
                    } else {
                        onGenerateCodexPDF(selectedRecords)
                    }
                } label: {
                    if isGeneratingCodex {
                        Label("取消生成", systemImage: "xmark.circle")
                    } else {
                        Label("Codex 复盘 PDF", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .tint(VNStyle.violet)
                .disabled(selectedRecords.isEmpty)
            }

            if isGeneratingCodex {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在调用本地 Codex。笔记越多耗时越长；关闭此窗口不会中断，完成后会自动保存到默认复盘目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

// MARK: - Subtitle import

private struct SubtitleImportSheet: View {
    let initialTarget: VideoSubtitleTarget?
    let availableTargets: [VideoSubtitleTarget]
    let onImported: (VideoSubtitleTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subtitleStore = VideoSubtitleStore.shared
    @State private var selectedTargetID: UUID?
    @State private var manualSessionID = UUID()
    @State private var manualVideoTitle = ""
    @State private var manualVideoURL = ""
    @State private var drafts: [VideoSubtitleDraft] = []
    @State private var pastedSubtitle = ""
    @State private var pastedName = "粘贴的字幕"
    @State private var isDropTarget = false
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var isReadingFiles = false
    @ObservedObject private var localCodex = LocalCodexClient.shared
    @State private var isDiscoveringWithCodex = false
    @State private var codexDiscoveryStatus: String?
#if VIDEONOTES_ENHANCED
    @ObservedObject private var ytdlp = YTDLPSubtitleClient.shared
    @State private var platformSubtitleTracks: [VideoPlatformSubtitleTrack] = []
    @State private var isListingPlatformSubtitles = false
    @State private var importingPlatformTrackID: String?
    @State private var platformSubtitleStatus: String?
    @State private var platformOperationID: UUID?
    @State private var showsAllPlatformSubtitleTracks = false
#endif

    init(
        initialTarget: VideoSubtitleTarget?,
        availableTargets: [VideoSubtitleTarget],
        onImported: @escaping (VideoSubtitleTarget) -> Void
    ) {
        self.initialTarget = initialTarget
        self.availableTargets = availableTargets
        self.onImported = onImported
        self._selectedTargetID = State(
            initialValue: initialTarget?.id ?? availableTargets.first?.id
        )
    }

    private var selectableTargets: [VideoSubtitleTarget] {
        var targets = availableTargets
        if let initialTarget,
           !targets.contains(where: { $0.id == initialTarget.id }) {
            targets.insert(initialTarget, at: 0)
        }
        return targets
    }

    private var resolvedTarget: VideoSubtitleTarget? {
        if let selectedTargetID,
           let target = selectableTargets.first(where: { $0.id == selectedTargetID }) {
            return target
        }

        let title = manualVideoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let url = manualVideoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return VideoSubtitleTarget(
            sessionID: manualSessionID,
            title: title,
            videoURL: url.isEmpty ? nil : url
        )
    }

    private var existingDocuments: [VideoSubtitleDocument] {
        guard let target = resolvedTarget else { return [] }
        return subtitleStore.documents(for: target.id)
    }

    private var canImport: Bool {
        !drafts.isEmpty
            && resolvedTarget != nil
            && !isReadingFiles
            && !isDiscoveringWithCodex
            && !isPlatformSubtitleBusy
    }

    private var isPlatformSubtitleBusy: Bool {
#if VIDEONOTES_ENHANCED
        return isListingPlatformSubtitles || importingPlatformTrackID != nil
#else
        return false
#endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                targetPicker
#if VIDEONOTES_ENHANCED
                platformSubtitlePanel
#endif
                codexDiscoveryPanel
                subtitleDropZone
                pastedTextArea

                if !drafts.isEmpty {
                    draftList
                }

                if !existingDocuments.isEmpty {
                    existingSubtitleList
                }

                Divider().opacity(0.5)
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 600, idealHeight: 760)
        .alert("无法添加字幕", isPresented: $showImportError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
        .onDisappear {
            // The discovery run belongs to this sheet. If the sheet is closed
            // before Codex returns, do not leave an unexpected background web
            // search running against the selected video.
            if isDiscoveringWithCodex, localCodex.isRunning {
                localCodex.cancelCurrentRun()
            }
#if VIDEONOTES_ENHANCED
            if isPlatformSubtitleBusy, ytdlp.isRunning {
                ytdlp.cancelCurrentRun()
            }
#endif
        }
#if VIDEONOTES_ENHANCED
        .onChange(of: selectedTargetID) { _ in
            resetPlatformSubtitleChoices()
        }
        .onChange(of: manualVideoURL) { _ in
            resetPlatformSubtitleChoices()
        }
#endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(VNStyle.violet)
                .frame(width: 40, height: 40)
                .background(
                    VNStyle.violet.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("导入视频字幕")
                    .font(.title3.weight(.bold))
                Text(subtitleImportIntroduction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("关闭", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var subtitleImportIntroduction: String {
#if VIDEONOTES_ENHANCED
        "可选择、拖入或粘贴多个字幕，也可优先从视频平台提取已有字幕。字幕保存在本机并进入数据备份；只有点击 Codex 查找或 AI 分析时，才会交给相应服务。"
#else
        "可选择或拖入多个字幕文件，也可以直接粘贴字幕内容。字幕先保存在本机并进入数据备份；只有点击“让 Codex 自动寻找”或“AI 分析字幕”时，才会把必要内容交给本机 Codex 或已配置的分析服务。"
#endif
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关联到视频")
                .font(.subheadline.weight(.semibold))

            if !selectableTargets.isEmpty {
                Picker("关联视频", selection: $selectedTargetID) {
                    ForEach(selectableTargets) { target in
                        Text(target.title).tag(target.id as UUID?)
                    }
                    Text("手动指定视频…").tag(nil as UUID?)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if selectedTargetID == nil {
                VStack(spacing: 9) {
                    TextField("视频名称", text: $manualVideoTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("视频链接（可选）", text: $manualVideoURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let target = resolvedTarget {
                Label("字幕将关联到：\(target.title)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(VNStyle.accent)
            } else {
                Label("请先选择或填写视频名称", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(15)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

#if VIDEONOTES_ENHANCED
    private func resetPlatformSubtitleChoices() {
        if isPlatformSubtitleBusy, ytdlp.isRunning {
            ytdlp.cancelCurrentRun()
        }
        platformSubtitleTracks = []
        platformSubtitleStatus = nil
        isListingPlatformSubtitles = false
        importingPlatformTrackID = nil
        platformOperationID = nil
        showsAllPlatformSubtitleTracks = false
    }

    private var hasPublicPlatformVideoURL: Bool {
        guard let rawURL = resolvedTarget?.videoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL) else {
            return false
        }
        return VideoSubtitleRemoteLoader.acceptsPublicHTTPSSource(url)
    }

    private var platformSubtitlePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.green)
                    .frame(width: 23, height: 23)
                    .background(.green.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("从视频平台提取字幕")
                        .font(.subheadline.weight(.semibold))
                    Text("优先读取发布者提供的字幕；没有时才显示平台自动字幕。不会下载视频，也不消耗 Codex 或 AI 额度。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isPlatformSubtitleBusy, ytdlp.isRunning {
                    Button {
                        ytdlp.cancelCurrentRun()
                    } label: {
                        Label("取消", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else if isPlatformSubtitleBusy {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 9)
                } else {
                    Button {
                        findPlatformSubtitles()
                    } label: {
                        Label("查找平台字幕", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(
                        resolvedTarget == nil
                            || !hasPublicPlatformVideoURL
                            || ytdlp.resolvedExecutablePath == nil
                            || ytdlp.isRunning
                            || isReadingFiles
                            || isDiscoveringWithCodex
                    )
                }
            }

            if let platformSubtitleStatus {
                HStack(spacing: 7) {
                    if isPlatformSubtitleBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(platformSubtitleStatus)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if ytdlp.resolvedExecutablePath == nil {
                Label("未检测到 yt-dlp；可在“设置 → 字幕”中配置免费的本地字幕提取器。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if ytdlp.isRunning {
                Label("字幕提取器正在处理另一个任务，完成后可再查找。", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if resolvedTarget?.videoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                Text("当前没有视频链接。选择“手动指定视频”并填写公开 HTTPS 链接后，即可从对应平台读取字幕。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !platformSubtitleTracks.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("可导入的字幕（优先原字幕）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(visiblePlatformSubtitleTracks)) { track in
                        platformSubtitleTrackRow(track)
                    }

                    if platformSubtitleTracks.count > 6 {
                        Button(showsAllPlatformSubtitleTracks ? "收起其他语言" : "显示其余 \(platformSubtitleTracks.count - 6) 条字幕") {
                            showsAllPlatformSubtitleTracks.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(VNStyle.accent)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(14)
        .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.green.opacity(0.16), lineWidth: 1)
        )
    }

    private func platformSubtitleTrackRow(_ track: VideoPlatformSubtitleTrack) -> some View {
        HStack(spacing: 9) {
            Image(systemName: track.captionKind == .creatorProvided ? "checkmark.seal.fill" : "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(track.captionKind == .creatorProvided ? .green : .orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.languageName)
                        .font(.caption.weight(.medium))
                    Text(track.languageCode.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text("\(track.captionKind.displayName) · \(track.formatSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if importingPlatformTrackID == track.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 58)
            } else {
                Button("导入") {
                    importPlatformSubtitle(track)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    isPlatformSubtitleBusy
                        || ytdlp.isRunning
                        || isReadingFiles
                        || isDiscoveringWithCodex
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var visiblePlatformSubtitleTracks: [VideoPlatformSubtitleTrack] {
        showsAllPlatformSubtitleTracks
            ? platformSubtitleTracks
            : Array(platformSubtitleTracks.prefix(6))
    }
#endif

    private var codexDiscoveryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(VNStyle.violet)
                    .frame(width: 23, height: 23)
                    .background(VNStyle.violet.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("让 Codex 自动寻找原字幕")
                        .font(.subheadline.weight(.semibold))
                    Text(codexDiscoveryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isDiscoveringWithCodex, localCodex.isRunning {
                    Button {
                        localCodex.cancelCurrentRun()
                    } label: {
                        Label("取消查找", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else if isDiscoveringWithCodex {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 9)
                } else {
                    Button {
                        discoverSubtitleWithCodex()
                    } label: {
                        Label("自动寻找", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VNStyle.violet)
                    .disabled(
                        resolvedTarget == nil
                            || localCodex.resolvedExecutablePath == nil
                            || localCodex.isRunning
                            || isReadingFiles
                    )
                }
            }

            if let codexDiscoveryStatus {
                HStack(spacing: 7) {
                    if isDiscoveringWithCodex {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(codexDiscoveryStatus)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if localCodex.resolvedExecutablePath == nil {
                Label("未检测到本机 Codex；可在“设置 → 本地 Codex”中指定路径。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if localCodex.isRunning {
                Label("本机 Codex 正在处理另一个任务，完成后可再查找字幕。", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if resolvedTarget?.videoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                Text("当前没有视频链接，仍会按标题检索，但仅在匹配证据充分时才自动导入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(VNStyle.violet.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VNStyle.violet.opacity(0.16), lineWidth: 1)
        )
    }

    private var codexDiscoveryDescription: String {
#if VIDEONOTES_ENHANCED
        "平台字幕提取不到时，可让本机 Codex 按标题和链接检索公开来源；只有确认高匹配、无需登录的 HTTPS 字幕直链后，才会自动导入。"
#else
        "本机 Codex 会按视频标题和链接检索公开字幕；只有确认高匹配、无需登录的 HTTPS 字幕直链后，才会自动导入到这个视频。"
#endif
    }

    private var subtitleDropZone: some View {
        VStack(spacing: 9) {
            Image(systemName: isReadingFiles ? "arrow.triangle.2.circlepath" : "arrow.down.doc")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isDropTarget ? VNStyle.violet : .secondary)
                .rotationEffect(.degrees(isReadingFiles ? 360 : 0))
                .animation(isReadingFiles ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isReadingFiles)

            Text(isReadingFiles ? "正在读取字幕…" : "把字幕文件拖到这里")
                .font(.system(size: 15, weight: .semibold))
            Text("支持 SRT、VTT、ASS、SSA、LRC、SUB、TXT，可一次拖入多份。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("选择字幕文件…", action: chooseSubtitleFiles)
                .buttonStyle(.bordered)
                .disabled(isReadingFiles || isDiscoveringWithCodex || isPlatformSubtitleBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 138)
        .background(
            isDropTarget ? VNStyle.violet.opacity(0.11) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDropTarget ? VNStyle.violet.opacity(0.65) : Color.primary.opacity(0.13),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
        )
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isDropTarget,
            perform: receiveDroppedFiles
        )
    }

    private var pastedTextArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("或直接粘贴字幕")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("从剪贴板粘贴") {
                    guard let text = NSPasteboard.general.string(forType: .string),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        presentImportError("剪贴板里没有可用的文本字幕")
                        return
                    }
                    pastedSubtitle = text
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(VNStyle.accent)
            }

            HStack(spacing: 10) {
                TextField("来源名称", text: $pastedName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 230)
                Spacer()
                Button("加入待导入列表", action: addPastedSubtitle)
                    .buttonStyle(.bordered)
                    .disabled(pastedSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $pastedSubtitle)
                .font(.system(size: 13.5))
                .padding(7)
                .frame(height: 112)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var draftList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("待导入字幕（\(drafts.count)）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("清空") { drafts.removeAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(drafts) { draft in
                HStack(spacing: 9) {
                    Image(systemName: "captions.bubble")
                        .foregroundStyle(VNStyle.violet)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.sourceName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(subtitleOriginDescription(source: draft.source, provider: draft.subtitleProvider, languageCode: draft.languageCode, captionKind: draft.captionKind)) · \(draft.format.displayName) · \(draft.cues.count) 条时间点 · \(draft.normalizedText.count) 字")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        drafts.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除 \(draft.sourceName)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }

    private var existingSubtitleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已关联字幕（\(existingDocuments.count)）")
                .font(.subheadline.weight(.semibold))

            ForEach(existingDocuments) { document in
                HStack(spacing: 9) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(document.sourceName)
                        .font(.caption)
                        .lineLimit(1)
                    Text("\(subtitleOriginDescription(source: document.source, provider: document.subtitleProvider, languageCode: document.languageCode, captionKind: document.captionKind)) · \(document.format.displayName) · \(document.cueCount) 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        subtitleStore.delete(documentID: document.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除这份字幕")
                    .accessibilityLabel("删除 \(document.sourceName)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isReadingFiles {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在解析字幕文件…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(subtitleImportFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("取消", role: .cancel) { dismiss() }
            Button {
                importDrafts()
            } label: {
                Label("导入 \(drafts.count) 份字幕", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(VNStyle.violet)
            .disabled(!canImport)
        }
    }

    private var subtitleImportFooter: String {
#if VIDEONOTES_ENHANCED
        "优先从平台提取已有字幕；找不到时可让本机 Codex 查找公开来源，也可手动导入。导入后可在“视频”页直接发起 AI 字幕分析。"
#else
        "可手动导入，也可让本机 Codex 查找公开字幕；导入后可在“视频”页直接发起 AI 字幕分析。"
#endif
    }

    private func subtitleOriginDescription(
        source: VideoSubtitleSource,
        provider: String?,
        languageCode: String?,
        captionKind: VideoSubtitleCaptionKind?
    ) -> String {
        var parts = [source.displayName]
        if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            parts.append(provider)
        }
        if let captionKind {
            parts.append(captionKind.displayName)
        }
        if let languageCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines), !languageCode.isEmpty {
            parts.append(languageCode.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private func chooseSubtitleFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择视频字幕文件"
        // Some subtitle extensions do not have a stable macOS UTType. Let
        // the panel expose ordinary data files, then validate every selected
        // extension in VideoSubtitleParser before it is ever stored.
        panel.allowedContentTypes = [.data, .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加字幕"

        guard panel.runModal() == .OK else { return }
        appendSubtitleFiles(panel.urls)
    }

    private func receiveDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                defer { group.leave() }
                guard let url = object else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            self.appendSubtitleFiles(urls)
        }
        return true
    }

    private func appendSubtitleFiles(_ urls: [URL]) {
        let uniqueURLs = Array(Set(urls.map(\.standardizedFileURL)))
        guard !uniqueURLs.isEmpty else { return }
        isReadingFiles = true

        DispatchQueue.global(qos: .userInitiated).async {
            var parsedDrafts: [VideoSubtitleDraft] = []
            var messages: [String] = []

            for url in uniqueURLs {
                do {
                    parsedDrafts.append(try VideoSubtitleParser.draft(fromFile: url))
                } catch {
                    messages.append(error.localizedDescription)
                }
            }

            DispatchQueue.main.async {
                self.isReadingFiles = false
                for draft in parsedDrafts where !self.drafts.contains(where: {
                    $0.sourceName == draft.sourceName && $0.rawText == draft.rawText
                }) {
                    self.drafts.append(draft)
                }
                if !messages.isEmpty {
                    self.presentImportError(messages.joined(separator: "\n"))
                }
            }
        }
    }

    private func addPastedSubtitle() {
        do {
            let draft = try VideoSubtitleParser.draft(
                fromPastedText: pastedSubtitle,
                sourceName: pastedName
            )
            if !drafts.contains(where: { $0.rawText == draft.rawText }) {
                drafts.append(draft)
            }
            pastedSubtitle = ""
            pastedName = "粘贴的字幕"
        } catch {
            presentImportError(error.localizedDescription)
        }
    }

#if VIDEONOTES_ENHANCED
    private func findPlatformSubtitles() {
        guard let target = resolvedTarget else {
            presentImportError("请先选择或填写要关联的视频")
            return
        }
        guard ytdlp.resolvedExecutablePath != nil else {
            presentImportError("没有找到 yt-dlp，请在“设置 → 字幕”中选择可执行文件或使用自动检测")
            return
        }
        guard !ytdlp.isRunning, !isPlatformSubtitleBusy else { return }

        isListingPlatformSubtitles = true
        platformSubtitleTracks = []
        platformSubtitleStatus = "正在读取平台提供的字幕清单…"
        let operationID = UUID()
        platformOperationID = operationID

        ytdlp.listAvailableSubtitles(for: target) { result in
            guard self.platformOperationID == operationID else { return }
            self.platformOperationID = nil
            self.isListingPlatformSubtitles = false
            switch result {
            case .success(let tracks):
                self.platformSubtitleTracks = tracks
                let originalCount = tracks.filter { $0.captionKind == .creatorProvided }.count
                let automaticCount = tracks.filter { $0.captionKind == .automatic }.count
                var summary: [String] = []
                if originalCount > 0 { summary.append("\(originalCount) 条原字幕") }
                if automaticCount > 0 { summary.append("\(automaticCount) 条自动字幕") }
                self.platformSubtitleStatus = "已找到：\(summary.joined(separator: "、"))"
            case .failure(let error):
                self.platformSubtitleStatus = nil
                if let extractorError = error as? YTDLPSubtitleClient.SubtitleExtractorError,
                   case .cancelled = extractorError {
                    self.platformSubtitleStatus = "已取消平台字幕查找"
                } else {
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func importPlatformSubtitle(_ track: VideoPlatformSubtitleTrack) {
        guard let target = resolvedTarget else {
            presentImportError("请先选择或填写要关联的视频")
            return
        }
        guard !ytdlp.isRunning, !isPlatformSubtitleBusy else { return }

        importingPlatformTrackID = track.id
        platformSubtitleStatus = "正在导入 \(track.languageName) \(track.captionKind.displayName)…"
        let operationID = UUID()
        platformOperationID = operationID

        ytdlp.downloadSubtitle(track, for: target) { result in
            guard self.platformOperationID == operationID else { return }
            self.platformOperationID = nil
            self.importingPlatformTrackID = nil
            switch result {
            case .success(let draft):
                guard !self.isDuplicate(draft, for: target) else {
                    self.platformSubtitleStatus = "这份字幕已关联到当前视频，无需重复导入"
                    return
                }
                let imported = self.subtitleStore.importDrafts([draft], for: target)
                guard !imported.isEmpty else {
                    self.platformSubtitleStatus = nil
                    self.presentImportError("平台字幕已读取，但未能保存到当前视频")
                    return
                }
                self.onImported(target)
                self.platformSubtitleStatus = "已导入：\(draft.sourceName)"
            case .failure(let error):
                if let extractorError = error as? YTDLPSubtitleClient.SubtitleExtractorError,
                   case .cancelled = extractorError {
                    self.platformSubtitleStatus = "已取消平台字幕导入"
                } else {
                    self.platformSubtitleStatus = nil
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }
#endif

    private func isDuplicate(
        _ draft: VideoSubtitleDraft,
        for target: VideoSubtitleTarget
    ) -> Bool {
        subtitleStore.documents(for: target.id).contains { document in
            if let sourceURL = draft.sourceURL,
               document.sourceURL == sourceURL,
               document.languageCode == draft.languageCode,
               document.captionKind == draft.captionKind {
                return true
            }
            return document.normalizedText == draft.normalizedText
        }
    }

    private func discoverSubtitleWithCodex() {
        guard let target = resolvedTarget else {
            presentImportError("请先选择或填写要关联的视频")
            return
        }
        guard localCodex.resolvedExecutablePath != nil else {
            presentImportError("没有找到本机 Codex，请在“设置 → 本地 Codex”中指定路径")
            return
        }
        guard !localCodex.isRunning, !isDiscoveringWithCodex else { return }

        isDiscoveringWithCodex = true
        codexDiscoveryStatus = "正在让本机 Codex 检索公开字幕…"

        localCodex.discoverPublicSubtitle(for: target) { result in
            switch result {
            case .success(let discovery):
                self.codexDiscoveryStatus = "已找到高匹配字幕，正在安全读取并解析…"
                VideoSubtitleRemoteLoader.fetchDraft(from: discovery) { loadResult in
                    self.isDiscoveringWithCodex = false

                    switch loadResult {
                    case .success(let draft):
                        guard !self.isDuplicate(draft, for: target) else {
                            self.codexDiscoveryStatus = "这份自动找到的字幕已关联到当前视频，无需重复导入"
                            return
                        }

                        let imported = self.subtitleStore.importDrafts([draft], for: target)
                        guard !imported.isEmpty else {
                            self.codexDiscoveryStatus = nil
                            self.presentImportError("自动找到字幕，但未能保存到当前视频")
                            return
                        }
                        self.onImported(target)
                        self.codexDiscoveryStatus = "已自动导入：\(draft.sourceName)"
                    case .failure(let error):
                        self.codexDiscoveryStatus = nil
                        self.presentImportError(error.localizedDescription)
                    }
                }
            case .failure(let error):
                self.isDiscoveringWithCodex = false
                if let codexError = error as? LocalCodexClient.CodexError,
                   case .cancelled = codexError {
                    self.codexDiscoveryStatus = "已取消自动寻找"
                } else {
                    self.codexDiscoveryStatus = nil
                    self.presentImportError(error.localizedDescription)
                }
            }
        }
    }

    private func importDrafts() {
        guard let target = resolvedTarget else {
            presentImportError("请先选择或填写要关联的视频")
            return
        }
        let imported = subtitleStore.importDrafts(drafts, for: target)
        guard !imported.isEmpty else {
            presentImportError("没有可导入的字幕内容")
            return
        }
        onImported(target)
        dismiss()
    }

    private func presentImportError(_ message: String) {
        importErrorMessage = message
        showImportError = true
    }
}

// MARK: - HistoryRow

struct HistoryRow: View {
    enum TimeStyle {
        case createdAt
        case videoTimestamp
    }

    let record: NoteRecord
    let isCopied: Bool
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    let onJumpToVideo: () -> Void
    let onPreviewScreenshot: () -> Void
    let timeStyle: TimeStyle

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 3) {
                Text(primaryTime)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(secondaryTime)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(width: timeStyle == .videoTimestamp ? 64 : 48)
            .contentShape(Rectangle())
            .onTapGesture { onJumpToVideo() }
            .help("跳回视频时间点")

            VStack(alignment: .leading, spacing: 7) {
                if record.isScreenshotClip {
                    ScreenshotClipThumbnail(
                        path: record.screenshotPath,
                        onOpen: onPreviewScreenshot,
                        onJump: onJumpToVideo
                    )

                    if !record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(record.content)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .contentShape(Rectangle())
                            .onTapGesture { onJumpToVideo() }
                    }
                } else {
                    Text(record.content)
                        .font(.system(size: 14.5))
                        .lineSpacing(3)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .contentShape(Rectangle())
                        .onTapGesture { onJumpToVideo() }
                }

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
                iconButton("pencil", color: .secondary, help: "编辑", action: onEdit)
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
            Button("跳回视频时间点", action: onJumpToVideo)
            if record.isScreenshotClip {
                Button("放大查看截图", action: onPreviewScreenshot)
            }
            Divider()
            Button("复制", action: onCopy)
            Button("编辑", action: onEdit)
            Button(record.isFavorite ? "取消收藏" : "收藏", action: onToggleFavorite)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private var primaryTime: String {
        switch timeStyle {
        case .createdAt:
            return record.createdAt.formatted(.dateTime.hour().minute())
        case .videoTimestamp:
            if let seconds = record.videoTimestampSeconds {
                return VideoSession.formattedTimestamp(for: seconds)
            }
            return record.videoTimestamp ?? "--:--"
        }
    }

    private var secondaryTime: String {
        switch timeStyle {
        case .createdAt:
            return record.createdAt.formatted(.dateTime.month(.abbreviated).day())
        case .videoTimestamp:
            return "视频时间"
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

// MARK: - Screenshot Clip Thumbnail

/// 缩略图显示，不撑满侧边栏。单击缩略图跳回视频，右下角按钮放大查看。
private struct ScreenshotClipThumbnail: View {
    let path: String?
    let onOpen: () -> Void
    let onJump: () -> Void

    private var image: NSImage? {
        path.flatMap { NSImage(contentsOfFile: $0) }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 210, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
            .onTapGesture { onJump() }
            .help("跳回视频时间点")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(7)
            .help("放大查看截图")
            .accessibilityLabel("放大查看截图")
        }
        .frame(width: 210, height: 118)
    }
}

// MARK: - Screenshot Preview

private struct ScreenshotPreviewSheet: View {
    let record: NoteRecord

    @Environment(\.dismiss) private var dismiss

    private var image: NSImage? {
        record.screenshotPath.flatMap { NSImage(contentsOfFile: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("截图笔记")
                    .font(.title3.weight(.semibold))

                if record.videoTimestamp != nil || record.videoTimestampSeconds != nil {
                    Text(VideoJumpService.displayTimestamp(for: record))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(VNStyle.accent)
                }

                Spacer()

                Button {
                    VideoJumpService.shared.jump(to: record)
                    dismiss()
                } label: {
                    Label("跳回视频时间点", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(VNStyle.accent)

                Button("关闭", role: .cancel) { dismiss() }
            }

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("截图文件不存在")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("原截图可能已被移动或删除。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 760, minHeight: 400, idealHeight: 620)
    }
}

// MARK: - Note Editor

private struct NoteEditorSheet: View {
    @Binding var content: String
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑笔记")
                .font(.title3.weight(.semibold))

            TextEditor(text: $content)
                .font(.system(size: 14.5))
                .padding(8)
                .frame(minWidth: 440, minHeight: 180)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .tint(VNStyle.accent)
                    .disabled(!canSave)
            }
        }
        .padding(22)
    }
}
