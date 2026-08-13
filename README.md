<div align="center">

# VideoNotes

**在全屏视频上方随时唤出的 macOS 原生速记工具**

看视频时按 `⌘⇧Space`，写下重点并回车保存——视频不暂停，笔记已入历史。

</div>

---

## 📸 软件截图

### 悬浮输入框 — 边看视频边记笔记

按 `⌘⇧Space` 唤出，覆盖在全屏视频之上，不切换当前 App，不暂停播放。

![VideoNotes 悬浮输入框](docs/screenshot-input-cropped.png)

> 输入完按 `Enter` 自动复制到剪贴板并保存，`Shift+Enter` 换行，`Esc` 关闭。2 秒完成一次记录。

### 历史记录 — 搜索、收藏、导出

按 `⌘⇧H` 打开笔记历史，支持全文搜索、时间分组、一键复制、Markdown 导出。

![VideoNotes 历史记录](docs/screenshot-history-cropped.png)

> 所有笔记仅存储在本机应用容器中，不上云、不跟踪、不分析。

---

## ✨ 功能特点

### 🎯 核心体验

- **全局快捷键唤出** — `⌘⇧Space` 随时唤出悬浮输入框，覆盖在全屏视频之上
- **零打扰** — 不切换 App、不暂停视频、不抢焦点（NSPanel + nonactivatingPanel）
- **Enter 即发** — 输入完按 Enter，自动复制到剪贴板并保存到历史
- **2 秒记一笔** — 从唤出到保存，全程不离开当前画面

### 📝 笔记管理

- **本地历史** — 所有笔记自动保存，支持时间分组浏览
- **全文搜索** — 按内容或标签快速检索
- **收藏筛选** — 重要笔记标星收藏，一键过滤
- **一键复制** — 单条复制或批量复制为 Markdown 格式
- **隐私优先** — 数据仅存本机应用容器，无云同步、无分析 SDK

### 🤖 AI 复盘（可选）

- 接入 **DeepSeek API**，对一段时间内的笔记做智能总结
- 生成结构化复盘摘要，提炼关键要点
- API Key 保存在 macOS 钥匙串中，不写入明文配置

### 📲 微信推送（可选）

- 复盘结果通过微信公众号模板消息推送到手机
- 碎片笔记随时回顾，不在电脑前也能看

### 🖥️ 多屏与全屏适配

- 覆盖 Safari、Chrome、QuickTime、Bilibili 等全屏空间
- 跨 Space、跨全屏 App、外接显示器，窗口跟随当前桌面空间
- `collectionBehavior = .moveToActiveSpace` 确保跨屏切换可靠

### 🎨 视觉设计

- **macOS 26+** — 原生 Liquid Glass 玻璃效果
- **macOS 13–15** — 自动回退到 Material 材质
- 暗色模式适配，半透明背景与模糊效果
- 输入框带呼吸边动画，快速输入时节奏加快

### 🔧 系统集成

- **菜单栏常驻** — 不占 Dock 位置（LSUIElement）
- **Carbon RegisterEventHotKey** — 系统级全局快捷键，比第三方库更稳定
- **App Sandbox + Hardened Runtime** — 完整沙盒与运行时保护
- **Keychain 密钥保护** — API Key 和 AppSecret 存储在钥匙串

---

## ⌨️ 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘⇧Space` | 唤出悬浮输入框 |
| `⌘⇧H` | 打开历史记录 |
| `Enter` | 保存笔记并复制到剪贴板 |
| `Shift+Enter` | 输入换行 |
| `Esc` | 关闭输入框 |

---

## 🚀 安装与使用

### 方式一：从源码构建

```bash
# 克隆仓库
git clone https://github.com/count110/VideoNotes.git
cd VideoNotes

# 使用 Xcode 构建
xcodebuild \
  -project VideoNotes.xcodeproj \
  -scheme VideoNotes \
  -configuration Release \
  build

# 或直接用 Xcode 打开
open VideoNotes.xcodeproj
```

**系统要求**：macOS 13+，Xcode 15+（推荐 Xcode 26）

### 方式二：使用

1. 启动后在菜单栏出现图标
2. 看视频时按 `⌘⇧Space`，输入文字，`Enter` 提交
3. `⌘⇧H` 查看历史记录

---

## 🏗️ 技术架构

```text
VideoNotes/
├── App/               应用生命周期与菜单栏（LSUIElement）
├── Window/            悬浮输入面板（NSPanel + nonactivatingPanel）
├── History/           历史记录界面（SwiftUI）
├── Settings/          设置中心（SwiftUI）
├── Stores/            本地持久化（JSON + 文件系统）
├── AI/                DeepSeek 复盘与钥匙串封装
├── WeChat/            微信模板消息推送
├── Hotkey/            Carbon 全局快捷键
├── Clipboard/         剪贴板监控
├── Models/            数据模型
├── Input/             输入处理
├── Assets/            全尺寸 AppIcon
├── AppStore/          上架材料与检查清单
├── PrivacyInfo.xcprivacy
└── VideoNotes.entitlements
```

**技术栈**：Swift + SwiftUI + AppKit，零第三方依赖。

---

## 🔒 隐私

- 历史记录默认只保存在本机应用容器中
- DeepSeek API Key 与微信 AppSecret 保存到 macOS 钥匙串，不写入明文文件
- 只有用户主动生成 AI 复盘或发送微信消息时，相关笔记内容才会发送到所配置的服务
- 应用不包含广告、分析 SDK 或跨应用跟踪

---

## 📄 License

MIT License - 详见 [LICENSE](LICENSE)

---

<div align="center">

**如果这个项目对你有帮助，欢迎 ⭐ Star**

</div>
