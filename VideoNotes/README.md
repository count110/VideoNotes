# VideoNotes

在全屏视频上方随时唤出的 macOS 原生速记工具。

按 `⌘⇧Space`，写下重点并回车保存；笔记会复制到剪贴板并留在本机历史中。按 `⌘⇧H` 查看、搜索、收藏或导出记录。

## 产品能力

- 全局快捷键唤出，不依赖辅助功能或输入监控权限
- 覆盖 Safari、Chrome、QuickTime 等全屏空间
- `Enter` 保存、`Shift+Enter` 换行、`Esc` 关闭
- 本地历史、收藏筛选、全文搜索、Markdown 复制
- 可选 DeepSeek AI 复盘与微信公众号推送
- macOS 26+ 使用原生 Liquid Glass，macOS 13–15 自动使用 Material 回退
- App Sandbox、Hardened Runtime、Keychain 密钥保护
- 菜单栏常驻，不占用 Dock

## 隐私

- 历史记录默认只保存在本机应用容器中。
- DeepSeek API Key 与微信 AppSecret 保存到 macOS 钥匙串，不写入明文配置文件。
- 只有用户主动生成 AI 复盘或发送微信消息时，相关笔记内容才会发送到所配置的服务。
- 应用不包含广告、分析 SDK 或跨应用跟踪。

## 构建

项目文件位于上一级目录：`../VideoNotes.xcodeproj`。

```bash
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
xcodebuild \
  -project ../VideoNotes.xcodeproj \
  -scheme VideoNotes \
  -configuration Release \
  build
```

最低系统版本为 macOS 13。使用 Xcode 26/27 构建时，会为新系统编译原生玻璃效果，同时保留旧系统兼容路径。

## App Store 发布

发布前请完成 `AppStore/RELEASE_CHECKLIST.md`。其中必须由开发者账号持有人完成的项目包括：

- 设置唯一 Bundle ID 与 Apple Developer Team
- Archive 并通过 Xcode Organizer 验证
- 将隐私政策发布到公开 HTTPS 地址
- 准备 App Store 截图、支持网址和审核联系信息
- 在 App Store Connect 中按 `PrivacyInfo.xcprivacy` 如实填写 App Privacy

## 工程结构

```text
VideoNotes/
├── App/               应用生命周期与菜单栏
├── Window/            悬浮输入面板与视觉系统
├── History/           历史记录界面
├── Settings/          设置中心
├── Stores/            本地持久化
├── AI/                DeepSeek 复盘与钥匙串封装
├── WeChat/            微信模板消息推送
├── Assets/            全尺寸 AppIcon
├── AppStore/          上架材料草案与检查清单
├── PrivacyInfo.xcprivacy
└── VideoNotes.entitlements
```
