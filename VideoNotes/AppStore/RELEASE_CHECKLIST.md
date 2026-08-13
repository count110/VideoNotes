# VideoNotes 1.0 — App Store 发布检查清单

## 已在工程中完成

- [x] Release 与 Debug 构建通过
- [x] App Sandbox 开启，仅保留出站网络权限
- [x] Hardened Runtime 开启
- [x] 去除麦克风、语音识别、辅助功能、输入监控和 Apple Events 权限申请
- [x] API Key 与 AppSecret 使用 macOS Keychain
- [x] 添加完整 macOS AppIcon 图标集
- [x] 添加 `PrivacyInfo.xcprivacy`
- [x] 添加生产力分类、加密声明、版权和单实例配置
- [x] UI 实机验收：悬浮输入、保存反馈、内容复位、历史搜索/收藏、设置分栏
- [x] macOS 26+ 原生 Liquid Glass 与 macOS 13–15 Material 回退

## 提交前必须人工完成

- [ ] 将 `com.videonotes.app` 改为开发者账号下已注册且唯一的 Bundle ID
- [ ] 在 Signing & Capabilities 中选择 Apple Developer Team
- [ ] 确认版本号 `1.0` 与 Build `1`；每次上传递增 Build
- [ ] 使用 Product → Archive 生成分发归档
- [ ] 在 Organizer 中执行 Validate App，解决全部签名或资产问题
- [ ] 将隐私政策草案发布到公开 HTTPS 页面，并填写 Privacy Policy URL
- [ ] 填写支持网址、营销网址（可选）和审核联系信息
- [ ] 上传至少 3 张清晰截图：悬浮速记、历史记录、设置/AI 复盘
- [ ] App Privacy 声明：不跟踪；仅为功能处理用户内容与用户 ID；由于凭据/OpenID 可关联身份，应选择“与用户关联”
- [ ] 在审核备注中说明 AI/微信为可选 BYOK 功能，不影响核心本地速记体验
- [ ] 若审核员需要测试联网能力，准备专用测试凭据；不要提交个人生产密钥
- [ ] 在一台未安装过 VideoNotes 的 Mac 上完成干净安装测试
- [ ] 验证 macOS 13、当前正式版 macOS、macOS 27 各一次

## 已知发布注意事项

1. 当前工程未配置 Team，因此本次只能完成无签名 Release 验证，不能代替 App Store 分发签名验证。
2. App Store 沙盒版的数据目录与历史非沙盒测试版不同。升级前请复制 Markdown 或备份 `history.json`；首个商店版本不应承诺自动迁移旧测试数据。
3. 微信公众号模板消息需要开发者自己的公众号配置。审核说明中要明确这是高级可选功能。
4. DeepSeek 和微信均为第三方处理方。隐私政策与 App Store Connect 的数据使用声明必须保持一致。
