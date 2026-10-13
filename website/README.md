# VideoNotes 在线体验

纯静态 HTML / CSS / JavaScript 网站，与 macOS App 同仓库维护，无构建依赖。

- 一分钟原创无声动画演示、选择本机视频播放、时间进度跳转。
- 时间点笔记、页内悬浮速记、编辑、收藏、全文搜索。
- 浏览器本地保存，Markdown 导出、浏览器打印为 PDF、JSON 备份合并导入。
- 复盘按视频和时间整理笔记原文，没有接入 AI。无账号、云笔记或飞书令牌。
- 所有个人内容使用 textContent 渲染；导入有格式、数量和大小验证。
- 笔记存储于当前来源的 localStorage；清理浏览器数据会丢失记录，视频文件刷新后需重新选择。网页备份与 macOS App 格式不同。
- 快捷键仅在当前网页有效，无法覆盖其他应用。

## 本地体验

在仓库根目录运行 `python3 -m http.server 4173 --directory website`，访问 http://localhost:4173/。

检查：`node --check website/app.js` 与 `node --test website/tests/model.test.mjs`。

## 阿里云部署

使用现有 api.lwgsjc.online HTTPS 服务的 /videonotes/ 路径，不新增监听端口。
通过已登录的阿里云命令助手，以 root 运行 `deploy/aliyun.sh <完整提交 SHA>`。
脚本从 GitHub 按固定提交下载源码、核对静态文件 SHA-256、只发布运行需要的五个文件，并保留配置备份和旧版本。
服务器目录为 /opt/videonotes-web/releases/<SHA>，current 指向在线版本。
配置位于 /etc/paper-checker/nginx.conf；修改前后检查配置与原 /health。现有 /api/ 路由保留。

## 回滚

将 /opt/videonotes-web/current 指向保留的旧 release。首次部署如需移除路由，恢复部署输出的 BACKUP 配置，然后运行 `nginx -t -c /etc/paper-checker/nginx.conf` 并 `systemctl reload paper-checker-proxy`。
不要删除其他应用配置、证书或数据。

GitHub 推送不会自动部署；再次发布需以新 SHA 运行部署脚本。
