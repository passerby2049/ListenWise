# ListenWise 油猴脚本使用教程

在 YouTube 视频页添加一个 **"Open in ListenWise"** 按钮，一键把当前视频导入到 ListenWise 开始转写学习。

## 工作原理

脚本在 YouTube 视频页注入一个按钮，点击后跳转到 `listenwise://import?url=<视频URL>`。ListenWise 在 `Info.plist` 里注册了 `listenwise://` URL scheme，系统会把这个 URL 交给 app；app 收到后会自动新建一个 Story 并开始下载转写。

## 前置条件

1. **ListenWise 至少被 Launch Services 注册过一次**。跑一次 Release build 或双击打开过 `ListenWise.app` 即可。验证方式：
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
     -dump | grep -A2 "listenwise:"
   ```
   看到 `listenwise:` 就说明注册成功了。

2. **一个支持用户脚本的浏览器扩展**。推荐 **Tampermonkey**（免费、主流浏览器全覆盖）。

---

## 安装 Tampermonkey

挑你用的浏览器走对应入口：

| 浏览器 | 安装方式 |
| --- | --- |
| **Chrome / Comet / Arc / Brave / Edge** | Chrome 应用商店 → 搜索 "Tampermonkey" → 添加扩展 |
| **Safari** | Mac App Store → 搜索 "Tampermonkey" → 安装后在 Safari `设置 → 扩展` 里启用 |
| **Firefox** | Firefox Add-ons → 搜索 "Tampermonkey" → 添加到 Firefox |

### ⚠️ Chrome 内核浏览器必须打开「开发者模式」

Chrome / Comet / Arc / Brave / Edge 在 2024 年后 **强制要求** 用户脚本扩展开启开发者模式，否则 Tampermonkey 没法运行本地脚本。步骤：

1. 地址栏输入 `chrome://extensions`（Edge 是 `edge://extensions`，Brave 是 `brave://extensions`，Arc/Comet 同理）
2. 页面右上角打开 **「开发者模式 / Developer mode」** 的开关
3. 如果浏览器弹出"关闭开发者模式扩展"的横幅，点 **保留 / Keep** 不要禁用

> Safari 和 Firefox 不需要这一步。

---

## 安装脚本

### 方式 A：直接粘贴（最快）

1. 点 Tampermonkey 图标 → **管理面板 / Dashboard**
2. 顶部标签切到 **"+"（新建脚本）**
3. 清空默认内容，把 `scripts/listenwise-youtube.user.js` 的全部内容粘贴进去
4. `⌘S` / `Ctrl+S` 保存
5. 确认 **已启用 / Enabled** 列显示绿色

### 方式 B：从文件系统打开

1. 用浏览器打开 `file:///<你的仓库绝对路径>/scripts/listenwise-youtube.user.js`
2. 如果 Tampermonkey 识别到 `.user.js` 后缀，会自动弹出安装页
3. 点 **安装 / Install**

> 某些 Chrome 内核浏览器禁止直接打开本地 `file://` 的 userscript 安装流程，这种情况请用方式 A。

---

## 使用

1. 打开任意 YouTube 视频页，例如 `https://www.youtube.com/watch?v=xxxxx`
   - 支持普通视频和 Shorts
2. 视频标题下方的操作栏（点赞/分享/下载那一排）末尾会出现一个 **琥珀色胶囊按钮 "Open in ListenWise"**
3. 点击按钮
4. 浏览器弹出"是否允许打开 ListenWise？"—— 点 **允许**（可以勾选"始终允许"免得每次问）
5. ListenWise 自动激活，新建一个 Story，打开 YouTube 导入对话框并开始下载
6. 下载结束后自动开始转写，不用手动粘贴链接

---

## 故障排查

**看不到按钮**
- 刷新页面（YouTube 是 SPA，脚本已监听路由变化但个别情况仍需刷新一次）
- 确认 Tampermonkey 仪表盘里脚本是 **已启用** 状态
- Chrome 内核浏览器：确认 `chrome://extensions` 里 **开发者模式** 开着
- 打开 DevTools Console 搜 `listenwise`，看脚本是否被注入

**点按钮没反应 / 浏览器说"无法打开该链接"**
- ListenWise 没被 Launch Services 注册过。跑一次：
  ```bash
  xcodebuild -scheme ListenWise -configuration Release build
  open ~/Library/Developer/Xcode/DerivedData/ListenWise-*/Build/Products/Release/ListenWise.app
  ```
  打开一次后关掉，再去点按钮。
- 用 `lsregister` 命令（见前置条件）确认 scheme 已注册。

**ListenWise 打开了但没开始下载**
- 看看 app 是否停留在空 Story 页面。如果是，说明 deep link 没被正确解析 —— 复制一下按钮的 `href` 检查一下格式（应该是 `listenwise://import?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D...`）
- 如果 URL 里的 `v=` 参数丢了，很可能是 YouTube 页面 DOM 变了，欢迎改脚本里的 `currentVideoURL()`。

**多台设备想同步脚本**
- Tampermonkey 仪表盘 → `实用工具 / Utilities` → 启用 Chrome Sync 或导出 zip，在另一台机器导入。

---

## 卸载

- Tampermonkey 仪表盘 → 找到 "Open in ListenWise" → 回收站图标删除。
- URL scheme 不想要了，从 `ListenWise/Info.plist` 里删掉 `CFBundleURLTypes` 那段再重 build。
