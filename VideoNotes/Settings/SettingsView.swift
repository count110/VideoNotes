import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - SettingsView

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable, Equatable {
        case general = "通用"
        case ai = "AI 复盘"
        case codex = "本地 Codex"
#if VIDEONOTES_ENHANCED
        case subtitles = "字幕"
#endif
        case feishu = "飞书推送"

        var id: Self { self }
        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .ai: return "sparkles"
            case .codex: return "terminal.fill"
#if VIDEONOTES_ENHANCED
            case .subtitles: return "captions.bubble.fill"
#endif
            case .feishu: return "paperplane.fill"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "快捷键与隐私"
            case .ai: return "整理零散笔记"
            case .codex: return "调用本机 Codex CLI"
#if VIDEONOTES_ENHANCED
            case .subtitles: return "导入与平台提取"
#endif
            case .feishu: return "将视频复盘发到学习群"
            }
        }
    }

    @State private var selection: Page = .general
    @State private var apiKey = ""
    @State private var aiModel = "deepseek-chat"
    @State private var codexExecutablePath = ""
#if VIDEONOTES_ENHANCED
    @State private var ytdlpExecutablePath = ""
#endif
    @State private var feishuWebhook = ""
    @State private var feishuSigningSecret = ""
    @State private var feishuAppID = ""
    @State private var feishuAppSecret = ""
    @State private var relayBaseURL = ""
    @State private var relayPairingCode = ""
    @State private var showSavedToast = false
    @State private var testStatus = ""
    @State private var isTesting = false
    @State private var isPairingRelay = false
    @State private var isDisconnectingRelay = false
    @State private var isBackingUp = false
    @State private var backupStatus = ""
    @State private var reviewExportDirectoryPath = ""
    @AppStorage(FloatingInputAppearanceSettings.opacityKey)
    private var inputBoxOpacity = FloatingInputAppearanceSettings.defaultOpacity
    @AppStorage(FloatingInputAppearanceSettings.glowBrightnessKey)
    private var glowBrightness = FloatingInputAppearanceSettings.defaultGlowBrightness
    @AppStorage(FloatingInputAppearanceSettings.glowSpeedKey)
    private var glowSpeed = FloatingInputAppearanceSettings.defaultGlowSpeed
    @ObservedObject private var feishuRelay = FeishuRelayClient.shared
    @ObservedObject private var localCodex = LocalCodexClient.shared
#if VIDEONOTES_ENHANCED
    @ObservedObject private var ytdlp = YTDLPSubtitleClient.shared
    @ObservedObject private var enhancedMediaCoordinator = EnhancedMediaSessionCoordinator.shared
#endif

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.rawValue)
                        Text(page.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: page.icon)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(page == .feishu ? VNStyle.violet : VNStyle.accent)
                }
                .tag(page)
                .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            ZStack {
                VNStyle.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        pageHeader
                        pageContent
                    }
                    .padding(28)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) { saveBar }
            }
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 560, idealHeight: 660)
        .onAppear(perform: loadConfig)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.rawValue)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(headerDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selection {
        case .general:
            generalPage
        case .ai:
            aiPage
        case .codex:
            codexPage
#if VIDEONOTES_ENHANCED
        case .subtitles:
            subtitlePage
#endif
        case .feishu:
            feishuPage
        }
    }

    private var generalPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "快速操作", icon: "keyboard") {
                shortcutRow(symbol: "command", keys: "⌘ ⇧ Space", title: "显示快速输入")
                Divider().opacity(0.45)
                shortcutRow(symbol: "clock.arrow.circlepath", keys: "⌘ ⇧ H", title: "打开历史记录")
                Divider().opacity(0.45)
                shortcutRow(symbol: "camera.viewfinder", keys: "⌘ V", title: "粘贴截图到输入框")
            }

            inputAppearanceCard

            dataBackupCard

#if VIDEONOTES_ENHANCED
            enhancedMediaCard
#endif

            settingsCard(title: "隐私", icon: "hand.raised.fill") {
                featureRow(
                    icon: "internaldrive",
                    tint: .blue,
                    title: "笔记保存在本机",
                    detail: "历史记录不会自动上传或同步。"
                )
                Divider().opacity(0.45)
                featureRow(
                    icon: "key.fill",
                    tint: .orange,
                    title: "密钥存入钥匙串",
                    detail: "DeepSeek API Key、飞书 Webhook 与 Relay 设备令牌均使用 macOS Keychain 保护。"
                )
                Divider().opacity(0.45)
                featureRow(
                    icon: "network",
                    tint: .purple,
                    title: "联网由你触发",
                    detail: "仅在你生成/发送复盘，或明确配对飞书 Relay 后与已绑定群保持连接。"
                )
            }

            settingsCard(title: "关于", icon: "info.circle") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(productName).font(.headline)
                        Text("版本 \(appVersion)（\(buildNumber)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
#if VIDEONOTES_ENHANCED
                    Text("ENHANCED · 非 App Store")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.10), in: Capsule())
#else
                    Text("macOS 13+")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.06), in: Capsule())
#endif
                }
            }
        }
    }

    private var inputAppearanceCard: some View {
        settingsCard(title: "输入框外观 · Liquid Glass", icon: "rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label("玻璃透明度", systemImage: "circle.lefthalf.filled")
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 12)

                    Text("\(Int((inputBoxOpacity * 100).rounded()))%")
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(VNStyle.accent)

                    Button("恢复默认") {
                        inputBoxOpacity = FloatingInputAppearanceSettings.defaultOpacity
                    }
                    .controlSize(.small)
                }

                Slider(
                    value: $inputBoxOpacity,
                    in: FloatingInputAppearanceSettings.minimumOpacity...FloatingInputAppearanceSettings.maximumOpacity,
                    step: 0.01
                )
                .tint(VNStyle.accent)

                HStack {
                    Text("更透明")
                    Spacer()
                    Text("更不透明")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                Divider().opacity(0.45)

                HStack(spacing: 12) {
                    Label("光效亮度", systemImage: "sun.max.fill")
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 12)

                    Text("\(Int((glowBrightness * 100).rounded()))%")
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(VNStyle.accent)
                }

                Slider(
                    value: $glowBrightness,
                    in: FloatingInputAppearanceSettings.minimumGlowBrightness...FloatingInputAppearanceSettings.maximumGlowBrightness,
                    step: 0.01
                )
                .tint(VNStyle.accent)

                HStack {
                    Text("柔和")
                    Spacer()
                    Text("明亮")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                HStack(spacing: 12) {
                    Label("光效速度", systemImage: "speedometer")
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 12)

                    Text("\(Int((glowSpeed * 100).rounded()))%")
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(VNStyle.accent)
                }

                Slider(
                    value: $glowSpeed,
                    in: FloatingInputAppearanceSettings.minimumGlowSpeed...FloatingInputAppearanceSettings.maximumGlowSpeed,
                    step: 0.01
                )
                .tint(VNStyle.accent)

                HStack {
                    Text("慢")
                    Spacer()
                    Text("快")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(VNStyle.cyan)
                    Text("调整后立即生效。macOS 26 使用原生 Liquid Glass 玻璃材质；较旧系统自动使用系统毛玻璃。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("全部恢复默认") {
                        inputBoxOpacity = FloatingInputAppearanceSettings.defaultOpacity
                        glowBrightness = FloatingInputAppearanceSettings.defaultGlowBrightness
                        glowSpeed = FloatingInputAppearanceSettings.defaultGlowSpeed
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var dataBackupCard: some View {
        settingsCard(title: "数据与备份", icon: "externaldrive.fill") {
            featureRow(
                icon: "arrow.up.doc.fill",
                tint: .blue,
                title: "一键导出可迁移备份",
                detail: "包含笔记、视频会话和截图附件，可在另一台电脑加载。API Key、飞书密钥和本地 Codex 路径不会导出。"
            )

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("复盘 PDF 自动保存目录", systemImage: "folder.fill")
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 8)

                    Button("选择…") {
                        chooseReviewExportDirectory()
                    }
                    .controlSize(.small)

                    Button("恢复默认") {
                        resetReviewExportDirectory()
                    }
                    .controlSize(.small)
                }

                Text(reviewExportDirectoryPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text("生成 Codex 复盘 PDF 后会自动保存到这里，不再弹出保存窗口。目录不存在时会自动创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.45)

            HStack(spacing: 10) {
                Button {
                    exportBackup()
                } label: {
                    Label("导出备份", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(VNStyle.accent)
                .disabled(isBackingUp)

                Button {
                    importBackup()
                } label: {
                    Label("加载备份", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                .disabled(isBackingUp)

                if isBackingUp {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !backupStatus.isEmpty {
                Label(backupStatus, systemImage: backupStatusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(backupStatusIsSuccess ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

#if VIDEONOTES_ENHANCED
    private var enhancedMediaCard: some View {
        settingsCard(title: "自动媒体识别（增强版）", icon: "play.rectangle.on.rectangle") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: enhancedMediaCoordinator.currentDisplay?.isPlaying == true ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VNStyle.cyan)
                    .frame(width: 28, height: 28)
                    .background(VNStyle.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    if let media = enhancedMediaCoordinator.currentDisplay {
                        Text(media.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)

                        Text(enhancedMediaStatus(media))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("等待播放器提供媒体信息")
                            .font(.subheadline.weight(.medium))
                        Text("打开并播放视频后，可在这里检查识别状态。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)
                Button("刷新") {
                    enhancedMediaCoordinator.refresh()
                }
                .controlSize(.small)
            }

            Divider().opacity(0.45)

            featureRow(
                icon: "waveform",
                tint: .cyan,
                title: "自动记录真实播放时间",
                detail: "保存笔记时读取播放器提供的标题、播放进度和播放状态；播放器未提供链接时不会伪造链接。"
            )

            Divider().opacity(0.45)

            featureRow(
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                title: "使用 macOS 私有媒体接口",
                detail: "此增强版不适合提交 App Store，系统升级后接口也可能变化。不会申请录屏、辅助功能或自动化权限。"
            )
        }
    }

    private func enhancedMediaStatus(_ media: MediaCaptureContext) -> String {
        let elapsed = VideoSession.formattedTimestamp(for: media.elapsedTime)
        let duration = media.duration.map { " / \(VideoSession.formattedTimestamp(for: $0))" } ?? ""
        let playback = media.isPlaying ? "正在播放" : "已暂停"
        let source = media.sourceApplicationName ?? media.sourceBundleIdentifier
        return ["\(elapsed)\(duration)", playback, source]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
#endif

    private var aiPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "DeepSeek", icon: "sparkles") {
                field("API Key", hint: "sk-…", text: $apiKey, secure: true)
                Divider().opacity(0.45)
                field("模型", hint: "deepseek-chat", text: $aiModel)

                HStack {
                    Label("笔记内容会发送到 DeepSeek 以生成复盘", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("测试连接") { testAIConnection() }
                        .disabled(apiKey.isEmpty || isTesting)
                }
                .padding(.top, 4)
            }
            statusView(prefix: "AI")
        }
    }

    private var codexPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "本地 Codex CLI", icon: "terminal.fill") {
                field(
                    "可执行文件",
                    hint: "留空则自动检测 ChatGPT.app 内置 Codex",
                    text: $codexExecutablePath
                )

                HStack(spacing: 10) {
                    Label(
                        localCodex.resolvedExecutablePath == nil
                            ? "未找到可用的 Codex CLI"
                            : "已检测到：\(localCodex.resolvedExecutableDisplayPath)",
                        systemImage: localCodex.resolvedExecutablePath == nil ? "exclamationmark.triangle" : "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(localCodex.resolvedExecutablePath == nil ? .orange : .secondary)
                    .lineLimit(2)

                    Spacer()

                    Button("选择…") { chooseCodexExecutable() }
                        .controlSize(.small)
                    Button("自动检测") {
                        codexExecutablePath = ""
                        localCodex.resetToAutomaticDiscovery()
                    }
                    .controlSize(.small)
                }

                Divider().opacity(0.45)

                featureRow(
                    icon: "lock.shield.fill",
                    tint: VNStyle.violet,
                    title: "只读生成复盘",
                    detail: "VideoNotes 通过 codex exec 非交互调用，只把你选中的笔记发送给本地 Codex，不修改项目文件。"
                )

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("在笔记窗口点“导出 / 复制”后，可选择任意笔记范围生成 Codex 复盘 PDF。首次使用前请先确认本机 Codex CLI 已登录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("测试本地 Codex") { testCodexConnection() }
                        .disabled(localCodex.isRunning)
                }
                .padding(.top, 3)
            }
            statusView(prefix: "Codex")
        }
    }

#if VIDEONOTES_ENHANCED
    private var subtitlePage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "yt-dlp 平台字幕提取器", icon: "captions.bubble.fill") {
                field(
                    "可执行文件",
                    hint: "通常无需填写：VideoNotes 会自动使用已配置的本地工具",
                    text: $ytdlpExecutablePath
                )

                HStack(spacing: 10) {
                    Label(
                        ytdlp.resolvedExecutablePath == nil
                            ? "未找到 yt-dlp"
                            : "已检测到：\(ytdlp.resolvedExecutableDisplayPath)",
                        systemImage: ytdlp.resolvedExecutablePath == nil ? "exclamationmark.triangle" : "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(ytdlp.resolvedExecutablePath == nil ? .orange : .secondary)
                    .lineLimit(2)

                    Spacer()

                    Button("选择…") { chooseYTDLPExecutable() }
                        .controlSize(.small)
                    Button("自动检测") {
                        ytdlpExecutablePath = ""
                        ytdlp.resetToAutomaticDiscovery()
                    }
                    .controlSize(.small)
                }

                Divider().opacity(0.45)

                featureRow(
                    icon: "captions.bubble",
                    tint: VNStyle.violet,
                    title: "优先提取平台已有字幕",
                    detail: "先显示发布者提供的原字幕；只有平台自动识别的内容才会标注为“自动字幕”。不会把 AI 转写伪装成原字幕。"
                )

                Divider().opacity(0.45)

                featureRow(
                    icon: "arrow.down.to.line.compact",
                    tint: .green,
                    title: "不下载视频，不消耗 AI 额度",
                    detail: "每次只读取字幕清单并下载你选择的一条字幕到临时目录，导入后临时文件会删除。不会读取浏览器 Cookie、不会登录或绕过 DRM、付费墙和地区限制。"
                )

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("yt-dlp 是免费的开源工具。VideoNotes 已优先使用自己的本地工具；只有你要改用其他版本时，才需要在上方选择可执行文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("查看官方安装说明") {
                            guard let url = URL(string: "https://github.com/yt-dlp/yt-dlp/wiki/Installation") else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(VNStyle.accent)
                    }
                }

                HStack {
                    Spacer()
                    Button("测试字幕提取器") { testYTDLPConnection() }
                        .disabled(ytdlp.isRunning)
                }
                .padding(.top, 3)
            }

            settingsCard(title: "跨系统方案", icon: "arrow.triangle.2.circlepath") {
                featureRow(
                    icon: "desktopcomputer",
                    tint: .blue,
                    title: "macOS、Windows、Linux 可共用",
                    detail: "VideoNotes 只依赖 yt-dlp 的标准命令和 SRT/VTT 等字幕文件；未来其他系统版本只需替换界面与本机进程调用，不需要迁移字幕数据格式。"
                )
                Divider().opacity(0.45)
                featureRow(
                    icon: "externaldrive.fill",
                    tint: .orange,
                    title: "备份会保留字幕来源信息",
                    detail: "平台名称、语言、原字幕/自动字幕标记和视频来源链接都会随 VideoNotes 备份迁移。"
                )
            }

            statusView(prefix: "字幕")
        }
    }
#endif

    private var feishuPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "复盘群机器人（主动推送）", icon: "paperplane.fill") {
                field(
                    "Webhook",
                    hint: "https://open.feishu.cn/open-apis/bot/v2/hook/…",
                    text: $feishuWebhook,
                    secure: true
                )
                Divider().opacity(0.45)
                field(
                    "签名密钥（可选）",
                    hint: "群机器人开启签名校验时填写",
                    text: $feishuSigningSecret,
                    secure: true
                )
                Divider().opacity(0.45)
                field(
                    "自建应用 App ID",
                    hint: "用于上传截图，飞书开放平台创建自建应用后获取",
                    text: $feishuAppID,
                    secure: true
                )
                Divider().opacity(0.45)
                field(
                    "自建应用 App Secret",
                    hint: "仅保存在本机钥匙串",
                    text: $feishuAppSecret,
                    secure: true
                )

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(VNStyle.cyan)
                    Text("如果希望复盘卡片里附带截图，需要配置飞书自建应用 App ID 和 App Secret，并在飞书开放平台为该应用开通 im:resource（上传图片）权限，同时把机器人加入目标群。只配 Webhook 时，截图会跳过发送。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(VNStyle.violet)
                    Text("Webhook、签名密钥、App ID 与 App Secret 只保存在此 Mac 的钥匙串。每次发送都由你在 AI 学习看板中手动触发，应用不会读取群消息或成员。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                HStack {
                    Spacer()
                    Button("发送测试消息") { testFeishuPush() }
                        .disabled(!feishuFieldsComplete || isTesting)
                }
                .padding(.top, 4)
            }

            settingsCard(title: "群内 @VideoNotes 复盘", icon: "at") {
                field(
                    "Relay 地址",
                    hint: "https://relay.example.com",
                    text: $relayBaseURL
                )

                Divider().opacity(0.45)

                field(
                    "一次性配对码",
                    hint: "由 Relay 管理员创建",
                    text: $relayPairingCode,
                    secure: true
                )

                relayConnectionDetail

                HStack(spacing: 10) {
                    if feishuRelay.requiresNewPairing {
                        Button("重新安全配对") { pairRelay() }
                            .disabled(!relayFieldsComplete || isPairingRelay)
                    } else if feishuRelay.hasPendingPairing && relayPairingCode.isEmpty {
                        Button("继续安全配对") { resumeRelayPairing() }
                            .disabled(isPairingRelay)
                    } else {
                        Button("安全配对") { pairRelay() }
                            .disabled(!relayFieldsComplete || isPairingRelay)
                    }

                    if !feishuRelay.requiresNewPairing {
                        Button("刷新状态") { feishuRelay.refreshStatus() }
                            .disabled(!feishuRelay.isPaired || isPairingRelay)
                    }

                    if feishuRelay.isPaired && !feishuRelay.requiresNewPairing {
                        Button("断开此 Mac", role: .destructive) {
                            disconnectRelay()
                        }
                        .disabled(isPairingRelay || isDisconnectingRelay)
                    } else if feishuRelay.hasPendingPairing {
                        Button("取消配对", role: .destructive) {
                            feishuRelay.cancelPendingPairing()
                            relayPairingCode = ""
                        }
                        .disabled(isPairingRelay)
                    }
                }
                .padding(.top, 2)
            }
            statusView(prefix: "飞书")
        }
    }

    @ViewBuilder
    private var relayConnectionDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: relayStateIcon)
                    .foregroundStyle(relayStateColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feishuRelay.connectionState.displayName)
                        .font(.caption.weight(.medium))
                    Text("配对后，仅接受已绑定飞书群中 @机器人的复盘指令。飞书应用密钥不会保存在此 Mac。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let instruction = feishuRelay.bindingInstruction,
               !instruction.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("请在目标飞书群中 @VideoNotes 复盘，并发送：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(instruction)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .textSelection(.enabled)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        Button {
                            ClipboardManager.shared.copy(text: instruction)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制绑定指令")
                        .accessibilityLabel("复制绑定指令")
                    }
                }
                .padding(.top, 1)
            }

            if let error = feishuRelay.lastError,
               !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private var saveBar: some View {
        HStack {
            if showSavedToast {
                Label("已安全保存", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Spacer()
            Button("保存设置", action: saveAll)
                .buttonStyle(.borderedProminent)
                .tint(VNStyle.accent)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vnCard(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func shortcutRow(symbol: String, keys: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(VNStyle.accent)
            Text(title)
            Spacer()
            Text(keys)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func featureRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(
        _ label: String,
        hint: String,
        text: Binding<String>,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.subheadline)
                .frame(width: 90, alignment: .leading)
            Group {
                if secure {
                    SecureField(hint, text: text)
                } else {
                    TextField(hint, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func statusView(prefix: String) -> some View {
        if !testStatus.isEmpty && testStatus.hasPrefix(prefix) {
            let success = testStatus.contains("成功")
            Label(testStatus, systemImage: success ? "checkmark.circle.fill" : (isTesting ? "progress.indicator" : "exclamationmark.triangle.fill"))
                .font(.caption)
                .foregroundStyle(success ? .green : (isTesting ? .secondary : .red))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((success ? Color.green : Color.red).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var headerDescription: String {
        switch selection {
        case .general: return "少一点打断，多留下一点灵感。"
        case .ai: return "把一段时间里的零散笔记整理成结构化复盘。"
        case .codex: return "调用本机 Codex，把选中的笔记排版成复盘 PDF。"
#if VIDEONOTES_ENHANCED
        case .subtitles: return "优先导入视频平台已有字幕，再交给 AI 做学习分析。"
#endif
        case .feishu: return "手动推送复盘，或安全连接一个可 @ 的专属飞书机器人。"
        }
    }

    private var feishuFieldsComplete: Bool {
        !feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var relayFieldsComplete: Bool {
        !relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !relayPairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var relayStateIcon: String {
        switch feishuRelay.connectionState {
        case .connected:
            return "checkmark.shield.fill"
        case .awaitingGroupBinding, .pairing, .checking:
            return "clock.arrow.circlepath"
        case .reconnecting, .pairingPending, .disconnecting, .disconnectFailed, .needsPairing:
            return "exclamationmark.shield.fill"
        case .notConfigured:
            return "lock.shield"
        }
    }

    private var relayStateColor: Color {
        switch feishuRelay.connectionState {
        case .connected:
            return .green
        case .reconnecting, .pairingPending, .disconnecting, .disconnectFailed, .needsPairing:
            return .orange
        default:
            return VNStyle.violet
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var backupStatusIsSuccess: Bool {
        backupStatus.hasPrefix("备份已") || backupStatus.hasPrefix("复盘目录已")
    }

    private var productName: String {
#if VIDEONOTES_ENHANCED
        return "VideoNotes Enhanced"
#else
        return "VideoNotes"
#endif
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private func loadConfig() {
#if VIDEONOTES_ENHANCED
        enhancedMediaCoordinator.refresh()
#endif
        AISummarizer.shared.loadConfig()
        if let config = AISummarizer.shared.config {
            apiKey = config.apiKey
            aiModel = config.model
        }
        codexExecutablePath = localCodex.configuredExecutablePath
#if VIDEONOTES_ENHANCED
        ytdlpExecutablePath = ytdlp.configuredExecutablePath
#endif
        reviewExportDirectoryPath = ReviewExportSettings.directoryURL.path
        FeishuPusher.shared.loadConfig()
        if let config = FeishuPusher.shared.config {
            feishuWebhook = config.webhook
            feishuSigningSecret = config.signingSecret
            feishuAppID = config.appID
            feishuAppSecret = config.appSecret
        }
        relayBaseURL = FeishuRelayClient.shared.configuredBaseURL ?? ""
    }

    private func saveAll() {
        AISummarizer.shared.saveConfig(apiKey: apiKey, model: aiModel)
        localCodex.setExecutablePath(codexExecutablePath)
#if VIDEONOTES_ENHANCED
        ytdlp.setExecutablePath(ytdlpExecutablePath)
#endif
        FeishuPusher.shared.saveConfig(
            webhook: feishuWebhook,
            signingSecret: feishuSigningSecret,
            appID: feishuAppID,
            appSecret: feishuAppSecret
        )
        withAnimation(.snappy(duration: 0.25)) { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedToast = false }
        }
    }

    private func testAIConnection() {
        isTesting = true
        testStatus = "AI 正在测试连接…"
        AISummarizer.shared.saveConfig(apiKey: apiKey, model: aiModel)
        AISummarizer.shared.generateReview(records: [NoteRecord(content: "这是一条连接测试笔记")]) { result in
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success: testStatus = "AI 连接成功"
                case .failure(let error): testStatus = "AI \(error.localizedDescription)"
                }
            }
        }
    }

    private func testFeishuPush() {
        isTesting = true
        testStatus = "飞书 正在发送测试消息…"
        FeishuPusher.shared.saveConfig(
            webhook: feishuWebhook,
            signingSecret: feishuSigningSecret,
            appID: feishuAppID,
            appSecret: feishuAppSecret
        )
        FeishuPusher.shared.sendTestMessage { result in
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success:
                    testStatus = "飞书 推送成功"
                case .failure(let error):
                    testStatus = "飞书 \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Portable backup

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "导出 VideoNotes 备份"
        panel.allowedContentTypes = [UTType.data]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = DataBackupManager.suggestedFileName()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBackingUp = true
        backupStatus = "正在导出备份…"
        // SettingsView is a value type, so it cannot be captured weakly. The
        // State wrappers remain valid while this window is open and let the
        // completion hop back to the main thread safely.
        DispatchQueue.global(qos: .userInitiated).async { [url] in
            do {
                let hasSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                try DataBackupManager.shared.export(to: url)
                DispatchQueue.main.async {
                    isBackingUp = false
                    backupStatus = "备份已导出：\(url.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    isBackingUp = false
                    backupStatus = "备份导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "加载 VideoNotes 备份"
        panel.allowedContentTypes = [UTType.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let mode = requestedRestoreMode() else { return }

        isBackingUp = true
        backupStatus = "正在加载备份…"
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Restore publishes the new records and sessions. Keep that mutation
        // on the main actor so the open History window refreshes immediately.
        do {
            let result = try DataBackupManager.shared.restore(from: url, mode: mode)
            isBackingUp = false
            backupStatus = "备份已加载：\(result.noteCount) 条笔记、\(result.sessionCount) 个视频会话、\(result.subtitleCount) 份字幕"
        } catch {
            isBackingUp = false
            backupStatus = "备份加载失败：\(error.localizedDescription)"
        }
    }

    private func requestedRestoreMode() -> DataBackupManager.RestoreMode? {
        guard !HistoryStore.shared.records.isEmpty else { return .replace }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "如何加载这份备份？"
        alert.informativeText = "合并会保留现有笔记，并按 UUID 更新重复记录；替换会移除当前列表中的笔记。现有截图文件不会被删除。"
        alert.addButton(withTitle: "合并")
        alert.addButton(withTitle: "替换现有数据")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func chooseReviewExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择复盘 PDF 自动保存目录"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = ReviewExportSettings.directoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        ReviewExportSettings.setDirectory(url)
        if hasSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
        reviewExportDirectoryPath = ReviewExportSettings.directoryURL.path
        backupStatus = "复盘目录已设置"
    }

    private func resetReviewExportDirectory() {
        ReviewExportSettings.resetToDefault()
        reviewExportDirectoryPath = ReviewExportSettings.directoryURL.path
        backupStatus = "复盘目录已恢复默认"
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex CLI"
        panel.allowedContentTypes = [UTType.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexExecutablePath = url.path
        localCodex.setExecutablePath(url.path)
    }

#if VIDEONOTES_ENHANCED
    private func chooseYTDLPExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 yt-dlp"
        panel.allowedContentTypes = [UTType.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        ytdlpExecutablePath = url.path
        ytdlp.setExecutablePath(url.path)
    }

    private func testYTDLPConnection() {
        ytdlp.setExecutablePath(ytdlpExecutablePath)
        isTesting = true
        testStatus = "字幕 正在测试 yt-dlp…"
        ytdlp.testConnection { result in
            isTesting = false
            switch result {
            case .success(let version):
                testStatus = "字幕提取器连接成功（yt-dlp \(version)）"
            case .failure(let error):
                testStatus = "字幕 \(error.localizedDescription)"
            }
        }
    }
#endif

    private func testCodexConnection() {
        localCodex.setExecutablePath(codexExecutablePath)
        isTesting = true
        testStatus = "Codex 正在测试连接…"
        localCodex.testConnection { result in
            isTesting = false
            switch result {
            case .success(let version):
                testStatus = "Codex 连接成功（\(version)）"
            case .failure(let error):
                testStatus = "Codex \(error.localizedDescription)"
            }
        }
    }

    private func pairRelay() {
        isPairingRelay = true
        FeishuRelayClient.shared.pair(
            relayBaseURL: relayBaseURL,
            pairingCode: relayPairingCode
        ) { result in
            isPairingRelay = false
            switch result {
            case .success:
                relayPairingCode = ""
            case .failure:
                // The detailed status remains next to the binding controls so
                // users can retry without losing the locally stored tuple.
                break
            }
        }
    }

    private func resumeRelayPairing() {
        isPairingRelay = true
        FeishuRelayClient.shared.resumePendingPairing { _ in
            isPairingRelay = false
            relayPairingCode = ""
        }
    }

    private func disconnectRelay() {
        isDisconnectingRelay = true
        FeishuRelayClient.shared.disconnect { result in
            isDisconnectingRelay = false
            if case .success = result {
                relayBaseURL = ""
                relayPairingCode = ""
            }
            // Failure remains visible in the Relay status card. Keeping the
            // form values and local credentials lets the user retry safely.
        }
    }
}
