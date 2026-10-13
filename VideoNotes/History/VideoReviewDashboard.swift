import SwiftUI

// MARK: - Video Review Dashboard

/// A visual, local presentation of a completed video-learning review.
///
/// The dashboard deliberately visualizes only facts present in the current
/// video session (timestamps and notes) plus the AI's written conclusions. It
/// does not invent a score, mastery percentage, or player controls.
struct VideoReviewDashboard: View {
    let result: VideoReviewResult

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecordID: UUID?
    @State private var didCopy = false
    @State private var feishuSendState: FeishuSendState = .idle
    @State private var showFeishuSetupAlert = false

    private var analysis: VideoReviewAnalysis {
        VideoReviewAnalysis(markdown: result.markdown)
    }

    private var timestampedRecords: [NoteRecord] {
        result.records.sorted { left, right in
            let leftTime = left.videoTimestampSeconds
                ?? left.createdAt.timeIntervalSinceReferenceDate
            let rightTime = right.videoTimestampSeconds
                ?? right.createdAt.timeIntervalSinceReferenceDate
            return leftTime < rightTime
        }
    }

    private var selectedRecord: NoteRecord? {
        if let selectedRecordID,
           let record = timestampedRecords.first(where: { $0.id == selectedRecordID }) {
            return record
        }
        return timestampedRecords.first
    }

    private var firstTimestamp: String {
        guard let record = timestampedRecords.first else { return "—" }
        return timestamp(for: record)
    }

    private var lastTimestamp: String {
        guard let record = timestampedRecords.last else { return "—" }
        return timestamp(for: record)
    }

    var body: some View {
        ZStack {
            VNStyle.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                dashboardHeader
                Divider().opacity(0.45)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        overviewCard
                        learningTimeline
                        aiInsights
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }

                Divider().opacity(0.45)
                dashboardFooter
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 760)
        .onAppear {
            if selectedRecordID == nil {
                selectedRecordID = timestampedRecords.first?.id
            }
        }
        .alert("连接飞书群", isPresented: $showFeishuSetupAlert) {
            Button("好") {}
        } message: {
            Text("请先在「设置 → 飞书推送」粘贴此群机器人的 Webhook 地址。复盘只会在你点击发送后才会发到飞书。")
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(VNStyle.violet)
                .frame(width: 38, height: 38)
                .background(VNStyle.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("AI 学习看板")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(result.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            Text("已生成")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.green.opacity(0.11), in: Capsule())

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(.primary.opacity(0.06), in: Circle())
            .help("关闭分析结果")
            .accessibilityLabel("关闭分析结果")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("本次视频学习", systemImage: "play.rectangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("AI 基于 \(result.records.count) 条原始笔记整理")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text(result.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 10) {
                overviewMetric(value: "\(result.records.count)", label: "笔记")
                overviewMetric(value: firstTimestamp, label: "首次记录")
                overviewMetric(value: lastTimestamp, label: "最晚记录")
                overviewMetric(
                    value: result.generatedAt.formatted(.dateTime.hour().minute()),
                    label: "生成时间"
                )
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [VNStyle.accent.opacity(0.92), VNStyle.violet.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
        )
    }

    private func overviewMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var learningTimeline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("学习时间线", systemImage: "timeline.selection")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("点击时间点查看原始笔记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if timestampedRecords.isEmpty {
                Text("这次分析没有可显示的原始笔记。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(timestampedRecords.enumerated()), id: \.element.id) { index, record in
                            timelineNode(for: record)

                            if index < timestampedRecords.count - 1 {
                                Capsule()
                                    .fill(VNStyle.accent.opacity(0.26))
                                    .frame(width: 38, height: 2)
                                    .padding(.top, 31)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }

                if let selectedRecord {
                    HStack(alignment: .top, spacing: 10) {
                        Text(timestamp(for: selectedRecord))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(VNStyle.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(VNStyle.accent.opacity(0.11), in: Capsule())

                        Text(selectedRecord.content)
                            .font(.system(size: 13.5))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(VNStyle.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timelineNode(for record: NoteRecord) -> some View {
        let isSelected = selectedRecordID == record.id

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedRecordID = record.id
            }
        } label: {
            VStack(spacing: 7) {
                Text(timestamp(for: record))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? VNStyle.accent : .secondary)
                    .frame(height: 16)

                Circle()
                    .fill(isSelected ? VNStyle.accent : VNStyle.cyan.opacity(0.72))
                    .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                    .overlay(Circle().strokeBorder(.white.opacity(0.65), lineWidth: isSelected ? 2 : 1))
                    .shadow(color: isSelected ? VNStyle.accent.opacity(0.38) : .clear, radius: 5)

                Text(record.content)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 122, height: 31, alignment: .top)
            }
            .frame(width: 128)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看 \(timestamp(for: record)) 的笔记")
        .accessibilityLabel("查看 \(timestamp(for: record)) 的笔记")
    }

    @ViewBuilder
    private var aiInsights: some View {
        if analysis.hasAllRequiredSections {
            VStack(alignment: .leading, spacing: 12) {
                Label("AI 分析结论", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 3)

                analysisCard(
                    title: VideoReviewAnalysis.Section.summary.rawValue,
                    symbol: "text.alignleft",
                    tint: VNStyle.accent,
                    content: analysis.content(for: .summary)
                )

                HStack(alignment: .top, spacing: 12) {
                    analysisCard(
                        title: VideoReviewAnalysis.Section.keyPoints.rawValue,
                        symbol: "key.fill",
                        tint: VNStyle.cyan,
                        content: analysis.content(for: .keyPoints)
                    )
                    analysisCard(
                        title: VideoReviewAnalysis.Section.questions.rawValue,
                        symbol: "questionmark.bubble.fill",
                        tint: VNStyle.violet,
                        content: analysis.content(for: .questions)
                    )
                    analysisCard(
                        title: VideoReviewAnalysis.Section.pitfalls.rawValue,
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        content: analysis.content(for: .pitfalls)
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    revisitCard
                    analysisCard(
                        title: VideoReviewAnalysis.Section.nextSteps.rawValue,
                        symbol: "checklist",
                        tint: .green,
                        content: analysis.content(for: .nextSteps)
                    )
                }
            }
        } else {
            analysisCard(
                title: "完整分析",
                symbol: "doc.text.fill",
                tint: VNStyle.violet,
                content: result.markdown
            )
        }
    }

    private func analysisCard(
        title: String,
        symbol: String,
        tint: Color,
        content: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            ReviewMarkdownBody(content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var revisitCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(
                VideoReviewAnalysis.Section.revisit.rawValue,
                systemImage: "gobackward"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.pink)

            ReviewMarkdownBody(content: analysis.content(for: .revisit))

            if !analysis.revisitPoints.isEmpty {
                Divider().opacity(0.5)

                Text("回看时间点")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 7) {
                    ForEach(analysis.revisitPoints) { point in
                        Button {
                            selectRecord(near: point.timestamp)
                        } label: {
                            Text(point.timestamp)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.pink)
                        .background(.pink.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.pink.opacity(0.18), lineWidth: 0.75))
                        .help(point.detail)
                        .accessibilityLabel("查看 \(point.timestamp) 的笔记")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var dashboardFooter: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("结果仅基于这次视频会话中的本地笔记生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch feishuSendState {
                case .idle, .sending:
                    EmptyView()
                case .success:
                    Label("已发送到飞书群", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }

            Spacer()

            if didCopy {
                Label("完整复盘已复制", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button {
                ClipboardManager.shared.copy(text: result.markdown)
                withAnimation(.easeInOut(duration: 0.18)) { didCopy = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeInOut(duration: 0.18)) { didCopy = false }
                }
            } label: {
                Label("复制完整复盘", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .tint(VNStyle.accent)

            Button(action: sendToFeishu) {
                if case .sending = feishuSendState {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在发送…")
                    }
                } else {
                    Label("发送到飞书群", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.bordered)
            .tint(VNStyle.violet)
            .disabled(isFeishuSending)
            .help("将本次视频复盘发送到已配置的飞书群")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func timestamp(for record: NoteRecord) -> String {
        if let seconds = record.videoTimestampSeconds {
            return VideoSession.formattedTimestamp(for: seconds)
        }
        return record.videoTimestamp ?? "—"
    }

    private func selectRecord(near timestamp: String) {
        guard let targetSeconds = VideoReviewAnalysis.seconds(for: timestamp),
              let record = timestampedRecords.min(by: { left, right in
                  let leftDistance = abs((left.videoTimestampSeconds ?? targetSeconds) - targetSeconds)
                  let rightDistance = abs((right.videoTimestampSeconds ?? targetSeconds) - targetSeconds)
                  return leftDistance < rightDistance
              }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            selectedRecordID = record.id
        }
    }

    private var isFeishuSending: Bool {
        if case .sending = feishuSendState { return true }
        return false
    }

    private func sendToFeishu() {
        guard FeishuPusher.shared.isConfigured else {
            showFeishuSetupAlert = true
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            feishuSendState = .sending
        }

        FeishuPusher.shared.pushVideoReview(
            title: result.title,
            markdown: result.markdown,
            records: timestampedRecords,
            generatedAt: result.generatedAt
        ) { outcome in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.18)) {
                    switch outcome {
                    case .success:
                        self.feishuSendState = .success
                    case .failure(let error):
                        self.feishuSendState = .failed("发送失败：\(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

private enum FeishuSendState: Equatable {
    case idle
    case sending
    case success
    case failed(String)
}

// MARK: - Subtitle analysis dashboard

/// A compact local reader for the latest AI analysis of imported subtitle
/// sources. It keeps the source count and time-cue count visible so an AI
/// conclusion is never confused with a complete video transcript.
struct SubtitleAnalysisDashboard: View {
    let analysis: VideoSubtitleAnalysis
    let documents: [VideoSubtitleDocument]
    let notes: [NoteRecord]

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    @State private var exportStatus: String?
    @State private var showExportError = false
    @State private var exportErrorMessage = ""

    var body: some View {
        ZStack {
            VNStyle.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        overviewCard
                        sourceCard
                        analysisCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }

                Divider().opacity(0.45)
                footer
            }
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 610, idealHeight: 760)
        .alert("保存字幕分析失败", isPresented: $showExportError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(exportErrorMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(VNStyle.violet)
                .frame(width: 38, height: 38)
                .background(
                    VNStyle.violet.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("字幕 AI 分析")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(analysis.videoTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            Text("本机已保存")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.green.opacity(0.11), in: Capsule())

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(.primary.opacity(0.06), in: Circle())
            .help("关闭字幕分析")
            .accessibilityLabel("关闭字幕分析")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("字幕辅助学习", systemImage: "waveform.and.mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("仅基于已导入的字幕与本视频笔记")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text(analysis.videoTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 10) {
                metric(value: "\(analysis.subtitleCount)", label: "字幕来源")
                metric(value: "\(analysis.cueCount)", label: "时间点")
                metric(value: "\(analysis.noteCount)", label: "关联笔记")
                metric(
                    value: analysis.generatedAt.formatted(.dateTime.hour().minute()),
                    label: "生成时间"
                )
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [VNStyle.violet.opacity(0.92), VNStyle.accent.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
        )
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("分析依据", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(notes.count) 条视频笔记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if documents.isEmpty {
                Text("原字幕已被删除；下面保留的是此前生成并保存在本机的分析结果。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(documents) { document in
                    HStack(spacing: 10) {
                        Image(systemName: "captions.bubble")
                            .foregroundStyle(VNStyle.violet)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.sourceName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text("\(document.format.displayName) · \(document.cueCount) 条可回看时间点 · \(document.source.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("完整分析", systemImage: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VNStyle.violet)
            ReviewMarkdownBody(content: analysis.markdown)
        }
        .padding(18)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let exportStatus {
                    Label(exportStatus, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("分析结果可复制或保存为 PDF，不会自动发送到任何服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if didCopy {
                Label("已复制", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button {
                ClipboardManager.shared.copy(text: analysis.markdown)
                withAnimation(.easeInOut(duration: 0.18)) { didCopy = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeInOut(duration: 0.18)) { didCopy = false }
                }
            } label: {
                Label("复制分析", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button(action: exportPDF) {
                Label("保存 PDF", systemImage: "doc.richtext")
            }
            .buttonStyle(.borderedProminent)
            .tint(VNStyle.violet)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func exportPDF() {
        do {
            let url = try ReviewExportSettings.withDirectoryAccess { directory in
                let destination = ReviewExportSettings.uniqueFileURL(
                    in: directory,
                    fileName: Self.pdfFileName()
                )
                try ReviewPDFExporter().export(
                    markdown: analysis.markdown,
                    title: "VideoNotes · 字幕分析 · \(analysis.videoTitle)",
                    noteCount: analysis.noteCount,
                    to: destination
                )
                return destination
            }
            exportStatus = "PDF 已保存：\(url.lastPathComponent)"
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private static func pdfFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "VideoNotes_字幕分析_\(formatter.string(from: Date())).pdf"
    }
}

// MARK: - AI markdown parsing

/// The prompt already asks the model for six headings. This parser is
/// intentionally forgiving: if the response changes shape, the dashboard
/// falls back to a complete-analysis card instead of hiding the result.
private struct VideoReviewAnalysis {
    enum Section: String, CaseIterable, Hashable {
        case summary = "视频内容摘要"
        case keyPoints = "核心知识点"
        case questions = "用户标记的疑问"
        case pitfalls = "易错点"
        case revisit = "建议重新观看的时间点"
        case nextSteps = "后续复习建议"
    }

    struct RevisitPoint: Identifiable, Hashable {
        let timestamp: String
        let detail: String

        var id: String { "\(timestamp)-\(detail)" }
    }

    private let sections: [Section: String]

    init(markdown: String) {
        var linesBySection: [Section: [String]] = [:]
        var currentSection: Section?

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let heading = Self.sectionHeading(in: trimmedLine) {
                currentSection = heading
                continue
            }

            if trimmedLine.hasPrefix("#") {
                currentSection = nil
                continue
            }

            if let currentSection {
                linesBySection[currentSection, default: []].append(rawLine)
            }
        }

        sections = linesBySection.reduce(into: [:]) { result, entry in
            let content = entry.value
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                result[entry.key] = content
            }
        }
    }

    var hasAllRequiredSections: Bool {
        Section.allCases.allSatisfy { sections[$0] != nil }
    }

    func content(for section: Section) -> String {
        sections[section] ?? "未明确标记"
    }

    var revisitPoints: [RevisitPoint] {
        guard let content = sections[.revisit] else { return [] }

        var seenTimestamps = Set<String>()
        return content
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine)
                guard let timestamp = Self.timestamps(in: line).first,
                      seenTimestamps.insert(timestamp).inserted else {
                    return nil
                }

                let detail = line
                    .replacingOccurrences(of: "[\(timestamp)]", with: "")
                    .replacingOccurrences(of: timestamp, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•*：: "))

                return RevisitPoint(
                    timestamp: timestamp,
                    detail: detail.isEmpty ? "建议回看这段视频" : detail
                )
            }
    }

    static func seconds(for timestamp: String) -> TimeInterval? {
        let values = timestamp
            .split(separator: ":")
            .compactMap { Double($0) }

        switch values.count {
        case 2:
            return values[0] * 60 + values[1]
        case 3:
            return values[0] * 3600 + values[1] * 60 + values[2]
        default:
            return nil
        }
    }

    private static func sectionHeading(in line: String) -> Section? {
        guard line.hasPrefix("#") else { return nil }

        let normalized = line
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Section.allCases.first { normalized.contains($0.rawValue) }
    }

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:\d{1,2}:)?\d{1,2}:\d{2}(?!\d)"#
    )

    private static func timestamps(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return timestampRegex
            .matches(in: text, range: range)
            .compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                return String(text[range])
            }
    }
}

// MARK: - Dashboard components

private struct ReviewMarkdownBody: View {
    let content: String

    private var lines: [String] {
        content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 7) {
                    if isBullet(line) {
                        Circle()
                            .fill(.secondary.opacity(0.65))
                            .frame(width: 4.5, height: 4.5)
                            .padding(.top, 6)
                    }

                    Text(cleaned(line))
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(.primary.opacity(0.86))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func isBullet(_ line: String) -> Bool {
        line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*")
    }

    private func cleaned(_ line: String) -> String {
        line
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
            .replacingOccurrences(of: "**", with: "")
    }
}

/// A small wrapping layout for the real time points extracted from the AI
/// response. It avoids relying on a third-party tag-flow component.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
