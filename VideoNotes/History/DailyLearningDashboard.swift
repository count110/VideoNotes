import SwiftUI
import Foundation

// MARK: - Daily learning data

struct DailyLearningTopic: Identifiable, Hashable {
    let name: String
    let count: Int

    var id: String { name }
}

struct DailyLearningDay: Identifiable, Hashable {
    let date: Date
    let noteCount: Int
    let studyDuration: TimeInterval
    let sessionCount: Int

    var id: Date { date }

    var durationLabel: String {
        DailyLearningFormat.shortDuration(studyDuration)
    }
}

/// A point-in-time summary used by both the local dashboard and the Feishu
/// card. It is built from explicit local records and sessions only.
struct DailyLearningSummary {
    let date: Date
    let records: [NoteRecord]
    let sessionCount: Int
    let studyDuration: TimeInterval
    let videoCount: Int
    let favoriteCount: Int
    let screenshotCount: Int
    let videoTitles: [String]
    let topTopics: [DailyLearningTopic]

    var noteCount: Int { records.count }

    var dateLabel: String {
        DailyLearningFormat.longDate(date)
    }

    var studyDurationLabel: String {
        DailyLearningFormat.duration(studyDuration)
    }

    /// A compact, readable payload for a Feishu interactive card.
    var feishuMarkdown: String {
        var lines = [
            "## \(dateLabel) 学习看板",
            "",
            "**学习时长** \(studyDurationLabel)　**笔记** \(noteCount) 条　**视频/会话** \(videoCount)　**收藏** \(favoriteCount)"
        ]

        if screenshotCount > 0 {
            lines.append("包含 \(screenshotCount) 条截图笔记")
        }

        if !topTopics.isEmpty {
            lines.append("")
            lines.append("### 重点来源")
            lines.append(contentsOf: topTopics.prefix(5).map { "- \($0.name)（\($0.count)）" })
        }

        if !videoTitles.isEmpty {
            lines.append("")
            lines.append("### 学习内容")
            lines.append(contentsOf: videoTitles.prefix(8).map { "- \($0)" })
        }

        lines.append("")
        lines.append("### 今日笔记")
        if records.isEmpty {
            lines.append("今天还没有记下笔记。")
        } else {
            let noteLines = records.reversed().prefix(12).map { record in
                let time = DailyLearningFormat.time(record.createdAt)
                let rawContent = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = rawContent.isEmpty
                    ? (record.isScreenshotClip ? "截图笔记" : "未填写内容")
                    : rawContent.replacingOccurrences(of: "\n", with: " ")
                return "- \(time) \(content)"
            }
            lines.append(contentsOf: noteLines)
            if records.count > 12 {
                lines.append("- 其余 \(records.count - 12) 条笔记已保留在 VideoNotes 本地看板")
            }
        }

        return lines.joined(separator: "\n")
    }
}

enum DailyLearningStats {
    static func summary(
        for date: Date,
        records: [NoteRecord],
        sessions: [VideoSession],
        referenceDate: Date = Date()
    ) -> DailyLearningSummary {
        let calendar = Calendar.current
        let dayRecords = records
            .filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
            .sorted { $0.createdAt > $1.createdAt }
        let daySessions = sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: date) }
        let studyDuration = daySessions.reduce(0) { total, session in
            total + session.elapsedTime(at: referenceDate)
        }

        var sourceIdentifiers = Set<String>()
        var titles = Set<String>()
        for session in daySessions {
            sourceIdentifiers.insert("session:\(session.id.uuidString)")
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                titles.insert(title)
            }
        }
        for record in dayRecords {
            if let sessionID = record.videoSessionID {
                sourceIdentifiers.insert("session:\(sessionID.uuidString)")
            } else if let title = normalized(record.videoTitle) {
                sourceIdentifiers.insert("title:\(title)")
            }
            if let title = normalized(record.videoTitle) {
                titles.insert(title)
            }
        }

        var topicCounts: [String: Int] = [:]
        for tag in dayRecords.flatMap(\.tags) {
            guard let normalizedTag = normalized(tag) else { continue }
            topicCounts[normalizedTag, default: 0] += 1
        }
        // Most existing notes do not have tags yet. Video titles still make a
        // useful daily breakdown until the user starts tagging notes.
        if topicCounts.isEmpty {
            for title in titles {
                topicCounts[title, default: 0] += 1
            }
        }

        var topics = topicCounts.map { entry in
            DailyLearningTopic(name: entry.key, count: entry.value)
        }
        topics.sort { left, right in
            if left.count != right.count {
                return left.count > right.count
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        return DailyLearningSummary(
            date: calendar.startOfDay(for: date),
            records: dayRecords,
            sessionCount: daySessions.count,
            studyDuration: studyDuration,
            videoCount: sourceIdentifiers.count,
            favoriteCount: dayRecords.filter(\.isFavorite).count,
            screenshotCount: dayRecords.filter(\.isScreenshotClip).count,
            videoTitles: titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            topTopics: Array(topics.prefix(8))
        )
    }

    static func recentDays(
        count: Int,
        endingAt date: Date,
        records: [NoteRecord],
        sessions: [VideoSession],
        referenceDate: Date = Date()
    ) -> [DailyLearningDay] {
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: date)
        let safeCount = max(1, count)

        return (0..<safeCount).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDate) else {
                return nil
            }
            let summary = summary(
                for: day,
                records: records,
                sessions: sessions,
                referenceDate: referenceDate
            )
            return DailyLearningDay(
                date: summary.date,
                noteCount: summary.noteCount,
                studyDuration: summary.studyDuration,
                sessionCount: summary.sessionCount
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func normalized(_ value: String) -> String? {
        normalized(Optional(value))
    }
}

private enum DailyLearningFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    static func longDate(_ date: Date) -> String {
        formatter("yyyy年M月d日").string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        formatter("M/d").string(from: date)
    }

    static func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    static func duration(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        if minutes < 60 {
            return "\(minutes) 分钟"
        }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    static func shortDuration(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        if minutes < 60 {
            return "\(minutes)m"
        }
        return "\(minutes / 60)h"
    }
}

// MARK: - Daily learning dashboard

struct DailyLearningDashboard: View {
    @ObservedObject private var store = HistoryStore.shared
    @ObservedObject private var sessionManager = VideoSessionManager.shared

    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var referenceDate = Date()
    @State private var sendState: FeishuDashboardSendState = .idle
    @State private var showFeishuSetup = false

    private var summary: DailyLearningSummary {
        DailyLearningStats.summary(
            for: selectedDate,
            records: store.records,
            sessions: sessionManager.sessions,
            referenceDate: referenceDate
        )
    }

    private var trendDays: [DailyLearningDay] {
        DailyLearningStats.recentDays(
            count: 14,
            endingAt: selectedDate,
            records: store.records,
            sessions: sessionManager.sessions,
            referenceDate: referenceDate
        )
    }

    var body: some View {
        ZStack {
            VNStyle.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    overviewCard
                    trendCard
                    focusCard
                    notesCard
                    footer
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 650, idealHeight: 780)
        .alert("还没有连接飞书", isPresented: $showFeishuSetup) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("请打开菜单栏 VideoNotes → 设置 → 飞书推送，粘贴目标学习群的自定义机器人 Webhook，然后点击保存设置。")
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            referenceDate = now
        }
        .onChange(of: selectedDate) { newValue in
            let normalizedDate = Calendar.current.startOfDay(for: newValue)
            if normalizedDate != newValue {
                selectedDate = normalizedDate
            }
            sendState = .idle
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("每日学习看板", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("把每天记下的内容，变成看得见的学习进度。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                DatePicker(
                    "选择日期",
                    selection: $selectedDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()

                Button("回到今天") {
                    selectedDate = Calendar.current.startOfDay(for: Date())
                }
                .controlSize(.small)
                .disabled(Calendar.current.isDateInToday(selectedDate))
            }
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.dateLabel)
                        .font(.title3.weight(.bold))
                    Text(summary.noteCount == 0 && summary.sessionCount == 0
                         ? "这一天还没有学习记录"
                         : "这一天留下了清晰的学习轨迹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: summary.noteCount == 0 ? "moon.stars" : "sun.max.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(summary.noteCount == 0 ? VNStyle.violet : VNStyle.accent)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 12
            ) {
                metricTile(value: "\(summary.noteCount)", label: "笔记", symbol: "note.text", tint: VNStyle.accent)
                metricTile(value: summary.studyDurationLabel, label: "学习时长", symbol: "clock.fill", tint: VNStyle.cyan)
                metricTile(value: "\(summary.videoCount)", label: "视频/来源", symbol: "play.rectangle.fill", tint: VNStyle.violet)
                metricTile(value: "\(summary.favoriteCount)", label: "收藏", symbol: "star.fill", tint: .orange)
            }
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricTile(value: String, label: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var trendCard: some View {
        let maxNotes = max(trendDays.map(\.noteCount).max() ?? 0, 1)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("近 14 天记录趋势", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text("点击柱子切换日期")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 7) {
                ForEach(trendDays) { day in
                    let isSelected = Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                    Button {
                        selectedDate = day.date
                    } label: {
                        VStack(spacing: 5) {
                            Text(day.noteCount == 0 ? "—" : "\(day.noteCount)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(isSelected ? VNStyle.accent : .secondary)
                                .frame(height: 14)

                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? VNStyle.accent : VNStyle.cyan.opacity(0.52))
                                .frame(
                                    height: day.noteCount == 0
                                        ? 7
                                        : max(9, 82 * CGFloat(day.noteCount) / CGFloat(maxNotes))
                                )
                                .overlay {
                                    if day.sessionCount > 0 {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(.white.opacity(0.45), lineWidth: 0.7)
                                    }
                                }

                            Text(DailyLearningFormat.shortDate(day.date))
                                .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .rounded))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                            Text(day.durationLabel)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看 \(DailyLearningFormat.longDate(day.date))")
                }
            }
            .frame(height: 137, alignment: .bottom)
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("重点来源", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Text(summary.screenshotCount > 0 ? "含 \(summary.screenshotCount) 条截图" : "按标签或视频来源汇总")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summary.topTopics.isEmpty {
                Text("还没有可汇总的主题。给笔记添加标签，或在视频会话中记录内容后，这里会自动形成排行。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let maxCount = max(summary.topTopics.map(\.count).max() ?? 1, 1)
                VStack(spacing: 10) {
                    ForEach(summary.topTopics.prefix(5)) { topic in
                        HStack(spacing: 10) {
                            Text(topic.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(VNStyle.accent.opacity(0.09))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [VNStyle.accent, VNStyle.violet],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: proxy.size.width * CGFloat(topic.count) / CGFloat(maxCount))
                                }
                            }
                            .frame(height: 8)

                            Text("\(topic.count)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 25, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("当天笔记", systemImage: "list.bullet.rectangle.portrait")
                    .font(.headline)
                Spacer()
                Text(summary.noteCount > 10 ? "显示最近 10 条" : "\(summary.noteCount) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if summary.records.isEmpty {
                Text("这一天没有笔记内容，但如果有视频会话，学习时长仍会保留在上方统计中。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(summary.records.prefix(10).enumerated()), id: \.element.id) { index, record in
                        HStack(alignment: .top, spacing: 12) {
                            Text(DailyLearningFormat.time(record.createdAt))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(VNStyle.accent)
                                .frame(width: 43, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? (record.isScreenshotClip ? "截图笔记" : "未填写内容")
                                     : record.content)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if let videoTitle = record.videoTitle,
                                   !videoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Label(videoTitle, systemImage: "play.rectangle")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            if record.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 9)

                        if index < min(summary.records.count, 10) - 1 {
                            Divider().padding(.leading, 55).opacity(0.45)
                        }
                    }
                }
            }
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    FeishuPusher.shared.isConfigured ? "飞书已配置" : "尚未配置飞书",
                    systemImage: FeishuPusher.shared.isConfigured ? "checkmark.circle.fill" : "paperplane"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(FeishuPusher.shared.isConfigured ? .green : .secondary)
                Text("只在你点击同步时发送当天摘要，不会后台上传全部历史笔记。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button {
                sendToFeishu()
            } label: {
                switch sendState {
                case .sending:
                    ProgressView()
                        .controlSize(.small)
                    Text("正在同步…")
                case .success:
                    Label("已同步到飞书", systemImage: "checkmark.circle.fill")
                case .failure:
                    Label("重试同步", systemImage: "arrow.clockwise")
                case .idle:
                    Label("同步到飞书", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(VNStyle.accent)
            .disabled(sendState == .sending)
        }
        .padding(.horizontal, 4)
    }

    private func sendToFeishu() {
        guard FeishuPusher.shared.isConfigured else {
            showFeishuSetup = true
            return
        }

        let snapshot = summary
        sendState = .sending
        FeishuPusher.shared.pushDailyLearningSummary(summary: snapshot) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    sendState = .success
                case .failure(let error):
                    sendState = .failure(error.localizedDescription)
                }
            }
        }
    }
}

private enum FeishuDashboardSendState: Equatable {
    case idle
    case sending
    case success
    case failure(String)
}
