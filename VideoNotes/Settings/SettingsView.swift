import SwiftUI
import AppKit

// MARK: - SettingsView

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "通用"
        case ai = "AI 复盘"
        case wechat = "微信推送"

        var id: Self { self }
        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .ai: return "sparkles"
            case .wechat: return "message.fill"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "快捷键与隐私"
            case .ai: return "整理零散笔记"
            case .wechat: return "将复盘发到微信"
            }
        }
    }

    @State private var selection: Page = .general
    @State private var apiKey = ""
    @State private var aiModel = "deepseek-chat"
    @State private var wxAppId = ""
    @State private var wxAppSecret = ""
    @State private var wxTemplateId = ""
    @State private var wxOpenId = ""
    @State private var showSavedToast = false
    @State private var testStatus = ""
    @State private var isTesting = false

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
                        .foregroundStyle(page == .wechat ? .green : VNStyle.accent)
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
        case .wechat:
            wechatPage
        }
    }

    private var generalPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "快速操作", icon: "keyboard") {
                shortcutRow(symbol: "command", keys: "⌘ ⇧ Space", title: "显示快速输入")
                Divider().opacity(0.45)
                shortcutRow(symbol: "clock.arrow.circlepath", keys: "⌘ ⇧ H", title: "打开历史记录")
            }

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
                    detail: "API Key 与 AppSecret 使用 macOS Keychain 保护。"
                )
                Divider().opacity(0.45)
                featureRow(
                    icon: "network",
                    tint: .purple,
                    title: "联网由你触发",
                    detail: "仅在生成 AI 复盘或微信推送时发送对应内容。"
                )
            }

            settingsCard(title: "关于", icon: "info.circle") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VideoNotes").font(.headline)
                        Text("版本 \(appVersion)（\(buildNumber)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("macOS 13+")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }

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

    private var wechatPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: "公众号模板消息", icon: "message.fill") {
                field("AppID", hint: "wx…", text: $wxAppId)
                Divider().opacity(0.45)
                field("AppSecret", hint: "输入 AppSecret", text: $wxAppSecret, secure: true)
                Divider().opacity(0.45)
                field("模板 ID", hint: "template_id", text: $wxTemplateId)
                Divider().opacity(0.45)
                field("OpenID", hint: "o…", text: $wxOpenId)

                HStack {
                    Label("模板变量需包含 title、content、time", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("发送测试消息") { testWeChatPush() }
                        .disabled(!wechatFieldsComplete || isTesting)
                }
                .padding(.top, 4)
            }
            statusView(prefix: "微信")
        }
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
        case .wechat: return "将生成的复盘推送到你的微信公众号。"
        }
    }

    private var wechatFieldsComplete: Bool {
        !wxAppId.isEmpty && !wxAppSecret.isEmpty && !wxTemplateId.isEmpty && !wxOpenId.isEmpty
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private func loadConfig() {
        AISummarizer.shared.loadConfig()
        if let config = AISummarizer.shared.config {
            apiKey = config.apiKey
            aiModel = config.model
        }
        WeChatPusher.shared.loadConfig()
        if let config = WeChatPusher.shared.config {
            wxAppId = config.appId
            wxAppSecret = config.appSecret
            wxTemplateId = config.templateId
            wxOpenId = config.openId
        }
    }

    private func saveAll() {
        AISummarizer.shared.saveConfig(apiKey: apiKey, model: aiModel)
        WeChatPusher.shared.saveConfig(
            appId: wxAppId,
            appSecret: wxAppSecret,
            templateId: wxTemplateId,
            openId: wxOpenId
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

    private func testWeChatPush() {
        isTesting = true
        testStatus = "微信 正在发送测试消息…"
        WeChatPusher.shared.saveConfig(
            appId: wxAppId,
            appSecret: wxAppSecret,
            templateId: wxTemplateId,
            openId: wxOpenId
        )
        WeChatPusher.shared.push(title: "VideoNotes 测试", content: "配置成功，VideoNotes 已准备好推送复盘。") { result in
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success: testStatus = "微信 推送成功"
                case .failure(let error): testStatus = "微信 \(error.localizedDescription)"
                }
            }
        }
    }
}
