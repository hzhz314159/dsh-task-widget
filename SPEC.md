# SPEC: dsh-task-widget v0.6.0 — Windows 桌面玻璃任务台

> 状态：**已定稿**（4 个开放问题 Q1–Q4 已闭环，见 §10）。确认后即进入实现。
> 目标版本：**v0.6.0**（合并一句话：修真机「文字随透明度衰减」bug + 推进 `design/提升设计.md` 的 P2 全量 + P1 残留 + 工程一致性 + 加固）。
> 基线：`dsh-task-widget-0.5.0`（免编译交付，`src`==`dist`）。

---

## 1. 背景与目标

v0.5.0 已落地 Win11 DWM Acrylic 真液态玻璃、Token 本回合/累计、余额错误友好、运行中计时、四角预设+磁吸、用量卡开关+点击跳用量页、设置页区块、系统通知、崩溃自愈。

真机实测发现：**调低「玻璃透明度」时，窗口内文字也跟着变淡、不清晰** —— 用户明确：「字体会跟着透明度变，我不需要这样」。这是本轮最高优先修复。

在修复之上，本轮一并推进 `design/提升设计.md` 的 P2（SSE 单通道合并、Toast 点击聚焦会话、全屏自动隐藏）与 P1 残留（任务卡 tooltip），并补齐工程一致性（peerDependencies、client inject、bundle 装配）与加固。

## 2. 术语

- **alpha（玻璃透明度）**：窗口"能透多少桌面"的控制量。v0.5.0 语义是"窗口整体不透明度"；v0.6.0 改为"仅玻璃层透明度"，**文字/前景不参与衰减**。
- **cardAlpha（卡片着色强度）**：卡片底色/surface 着色深浅，与 alpha 解耦保留。
- **DWM Acrylic**：Win11（build≥22000）`DWMWA_SYSTEMBACKDROP_TYPE=3`，合成器级真高斯模糊；Win10 降级为纯色半透明。
- **SSE 单通道**：widget 侧用一条 `text/event-stream` 长连接同时消费 snapshot/toast/pending/ctl，替代 `2s 快照轮询 + 500ms 命令轮询`。
- **toast 聚焦**：Windows 系统通知点击 → DSH Web UI 切到对应会话。

## 3. 现状基线（实测口径）

| 组件 | 文件 | 关键事实 |
|---|---|---|
| 宿主守护 | `src/lib/index.js`（625 行） | `inject:['webServer']`；路由 `/dsh-task-widget/{,api/snapshot,api/events,api/ctl}`；`pushEvent(kind,title,detail)` 推 `event: toast`（**无 sessionId 字段**）；`collect()` 聚合 sessions+jobs+balance；脏标记 600ms 防抖 SSE；崩溃自愈 3s/5 次熔断；`app.version='0.5.0'`。 |
| Web 注入 | `src/lib/client.js`（374 行） | `inject:['slots']`；**已声明但 `dsh.client.inject` 未含 `dsh-client-ui-slots`**；`settings.section` 槽（inject→register 嵌套，仿 dsh-wsl-settings）；常驻 SSE 仅监听 **snapshot / pending**（**未监听 toast**）；头部开关按钮 `conversation.session.header.actions`。 |
| 原生小窗 | `src/widget/widget.ps1`（1014 行） | WPF 无边框置顶，DWM Acrylic + SpecGlow；**`widget.ps1:303 $win.Opacity = alpha/100` ← bug 根因**（整窗含文字随 alpha 衰减）；轮询 `/api/snapshot` 2s + `.command.json` 500ms；`Apply-Theme` 走 `tintA=ck*70`（Win11）/ `cardBg.Opacity=ck`（Win10）。 |
| 包声明 | `src/package.json` | `version 0.5.0`；无 `peerDependencies`；无 `dsh.bundle`；`dsh.client.inject=["dsh-client-ui-conversation"]`。 |
| 构建 | `scripts/build.sh` | 免编译，仅产物完整性校验（含 `widget.ps1` UTF-8 BOM 检查、`__ModuleLoader__` 特征检查）。 |

## 4. 功能需求（v0.6.0）

- **F1 文字不随玻璃透明度衰减（修真机 bug，最高优先）**：调整 `alpha` 玻璃透明度时，文字/前景始终保持全不透明、清晰；`alpha` 仅作用于玻璃层（DWM 着色 wash / Win10 卡面 / sheen）。
- **F2 SSE 单通道合并**：widget 侧用一条 `/api/events` SSE 长连接消费 snapshot/toast/pending/**ctl**，移除 2s 快照轮询；保留 `.command.json` 兜底（SSE 断连时回退文件轮询）。
- **F3 Toast → 聚焦会话（降级方案）**：宿主 `pushEvent` 与 `recentDone` 携带 `sessionId`；Windows toast 点击仅聚焦 widget 本体（免 COM），widget 内"最近完成"可点行 → 既有 activate 链路跳转 DSH 会话；不自动强切、Web 内无额外提示。
- **F4 全屏自动隐藏小窗**：任意前台窗口进入全屏时，小窗自动隐藏；退出全屏恢复。
- **F5 任务卡 tooltip**：悬停显示完整 `cwd` + 父子会话区分。
- **F6 工程一致性**：补 `peerDependencies`；`dsh.client.inject` 加 `dsh-client-ui-slots`；补 `dsh.bundle` + `cordis.patch.yml`（让 `dsh plugin add` 可正式装配，与注入双路径一致）。
- **F7 加固**：widget 启动写一行 `widget/.log` 诊断（version/win11/acrylic/hwnd）；保留现有崩溃自愈与 SSE 断连清理；F2 引入 SSE 重连兜底。

## 5. 非目标（明确不做）

- 不拆 `widget.ps1`（保持单体零依赖、可控）。
- 不引入 NuGet / 第三方模块（纯 PS5.1 + WPF）。
- 不改宿主与 DSH 注入/卸载契约（`inject` 列表、`ctx.effect` 清理）。
- 不重做通知机制（WinRT Toast + AUMID + 托盘回退保留）。
- 本轮不引入 TS / 重做免编译交付形态（仍是"源码即产物"）。

## 6. 架构（变更点标注 ★）

```
宿主守护 (lib/index.js)
  ├─ collect() ★ sessionViews 增 cwd 全路径（供 F5）
  ├─ pushEvent(kind,title,detail,sessionId?) ★ ev.sessionId（F3）
  ├─ writeCommand(action) ★ 同时广播 event: ctl 到 SSE（F2，host→widget 走 SSE）
  ├─ /api/ctl?action=activate    已有，pending→client SSE 跳转（F3 落地复用）
  └─ /api/events  SSE：snapshot / toast / pending / ctl（★ ctl 新增）

客户端 (lib/client.js)
  └─ 设置页「玻璃透明度」文案 ★ 标注「不影响文字清晰度」（F1）
      （toast 聚焦不经客户端：用户点 widget 内完成行/任务行 → 既有 pending 跳转链路）

原生小窗 (widget/widget.ps1)
  ├─ Apply-Theme ★ F1：$win.Opacity 恒 1；alpha → tintA(11)/cardBg.Opacity(10)/sheen
  ├─ ★ F2：开一条 SSE 长连接解析 event-stream；snapshot 实时驱动；ctl 即时执行；
  │        移除 2s 轮询；SSE 断连 N 次回退 .command.json 轮询
  ├─ ★ F3：recentDone 每条带 sessionId → widget「最近完成」可点行 → 既有 activate 链路（零 COM，Q1 降级）
  ├─ ★ F4：WinEventHook(EVENT_SYSTEM_FOREGROUND + EVENT_OBJECT_LOCATIONCHANGE) 事件驱动全屏显隐（Q4）
  ├─ ★ F5：任务行 ToolTip = 完整 cwd + 父子标注
  └─ ★ F7：启动写 widget/.log 诊断行

包声明 (package.json) ★
  ├─ version → 0.6.0
  ├─ + peerDependencies（F6a）
  ├─ dsh.client.inject += dsh-client-ui-slots（F6b）
  └─ + dsh.bundle.patch → cordis.patch.yml（F6c）
```

## 7. 关键技术点

### 7.1 F1 文字/玻璃分离（核心 bug 修复）+ 液态玻璃重做（Accent 终版，两步踩坑记录）

**现状根因**（`widget/widget.ps1`）：
- 画笔层面：文字 brush 用 `New-Brush '#F2F4F8'`（默认 alpha 255）——本身已是全不透明。
- bug A（F1）：`$win.Opacity = alpha/100` 对整棵可视树（含所有 TextBlock）施加不透明度 → 文字发虚。
- bug B（玻璃"平涂无模糊"）三步推理（已实测确认）：
  1. v0.5.0 原状：XAML `AllowsTransparency="True"` → layered 窗口，DWM `DWMWA_SYSTEMBACKDROP_TYPE=3` **对 layered 窗口静默失效** → 只有半透明纯色 wash，无模糊（"很差"）。
  2. 试改 non-layered（移除 AllowsTransparency）+ `Background=Transparent`：DWM readback 显示 backdrop=3 生效，**但本机 WPF/.NET 栈把透明底渲染成纯黑**盖住 backdrop → 用户实测"背景全黑，很劣质"。
  3. **结论（终版）**：layered 窗口 + `SetWindowCompositionAttribute(ACCENT_ENABLE_ACRYLICBLURBEHIND=4)`（Start 菜单同款）——对 layered 逐像素透明窗口同样生效，透明 + 真高斯模糊两全。

**修复（终版）**：
1. `$win.Opacity = 1.0`（F1 恒定，永不随 alpha 变）。
2. **液态玻璃 = Accent**：
   - XAML 保留 `AllowsTransparency="True"`（layered → 逐像素透明，不黑）。
   - `Apply-Acrylic`：`SetWindowCompositionAttribute(WCA_ACCENT_POLICY=19)`，`AccentPolicy{ AccentState=4, AccentFlags=0, GradientColor=ABGR, AnimationId=0 }`；着色 `GradientColor = (tintA<<24)|(B<<16)|(G<<8)|R`，`tintA = clamp( round((alpha/100)*(cardAlpha/100)*150), 40, 255 )`，基色浅 `#FFFFFF` / 深 `#0E1320` —— **alpha 只作用玻璃着色深浅，文字全不透明**。返回真值写 `$script:acrylicOn`（F7 .log 的 acrylic= 即真实返回值）。
   - `Apply-Theme` 先调 `Apply-Acrylic` 定玻璃能力，再分支出 wash：卡片 = `tintA = clamp( round((alpha/100)*ck*40), 10, 150 )` 的半透明玻璃贴片；降级分支（无 Accent 支持）维持 `cardBg.Opacity = alpha*ck` 纯色。
   - 圆角：layered 下 DWM 圆角偏好不生效 → 全平台 `CreateRoundRectRgn(0,0,W,H,20,20)` 区域裁剪（Accent 模糊随区域裁剪）。
   - 阴影减淡：MainShadow 0.30→0.22、UsageShadow 0.26→0.18。SpecGlow/UsageGloss sheen `Opacity = alpha/100 * baseSheen`（70/55）不变；边框 `borderA`（220/200）不随 alpha 衰减。
3. **语义**：`alpha` 注释/设置页文案"玻璃透明度（不影响文字清晰度）"；`.config.json` 字段 `alpha` 不变（向后兼容）。

**验证（本机实测全过）**：
- ExStyle=`0x80008`（layered+topmost）；`Apply-Acrylic` 返回 True（.log acrylic=True）。
- 边距像素由 v1 的纯黑变为 frosted 桌面色；模糊块均值测试 **4/5 玻璃像素≈邻域块均值**（真高斯模糊，非平涂着色）。
- 文字全清晰（文字 brush 恒 alpha 255）。注：截图/命令均在用户实机会话完成。

### 7.2 F2 SSE 单通道合并（widget 侧）

**现状**：widget 轮询 `/api/snapshot`（2s）+ `.command.json`（500ms）两条通道；`/api/events` SSE 已存在但仅供 DSH Web 客户端消费。

**目标**：widget 用一条 `System.Net.HttpWebRequest` 流式 SSE 长连接消费 `snapshot/toast/pending/ctl`；移除 2s 快照轮询；`.command.json` 降级为 SSE 断连兜底。

**改动**：
- 宿主 `writeCommand(action)`：写文件之外，**并行向所有 SSE 客户端 `client.write('event: ctl\ndata: {"action":...}')`**。widget 若在线则即时消费、删除文件需求。
- widget 新增 `Connect-Sse`：`[HttpWebRequest]::Create($base + '/api/events')`，`AllowReadStreamBuffering=$false`，循环 `GetResponseStream().Read(...)` 增量解析 `event:/data:` 帧（与现有 `retry:3000` 首行兼容）。
- 解析到 `snapshot` → 直接喂现有 `Render-Snapshot`（去重：payload.ts 相同则跳过渲染）。
- 解析到 `ctl` → 执行 `Invoke-Command` 等价动作；命中即删 `.command.json` 防重放。
- SSE 断连：浏览器侧自动重连由 widget 手写 reconnect（退避 3s/6s/12s，封顶 12s）；连续 N=3 次失败 → 回退 `.command.json` 500ms 轮询直到 SSE 恢复。
- HTTP 请求需带 `Accept: text/event-stream`；超时设为足够大（长连接），用 `$req.Timeout = -1` 或 `ReadWriteTimeout` 适配。

**收益/风险**：减 4 通道为 1 通道；实时性优于 2s 轮询。风险 = PS5.1 SSE 分块解析可靠性 → 兜底轮询保底，避免回归。

### 7.3 F3 Toast 点击 → 聚焦会话

**已具备链路**：widget 点任务行 → `/api/ctl?action=activate&session=<sid>` → 宿主 `pendingActivate` + 即时 `event: pending` 推送 → Web 客户端 SSE `pending` → `sessions.select`。**对运行中任务已生效**，本轮补"完成 toast"。

**改动（降级方案 Q1，零 COM）**：
- 宿主 `pushEvent(kind,title,detail,sessionId?)`：`ev.sessionId = sessionId`。
  - `session-done`（`onAgentStatus`）→ 带 `id`。
  - `todos-done`（`onSessionEvent`）→ 带 `session.id`。
  - `job-done`（`onJobDone`）→ 带 `v.ownerSession`（可能为空）。
- 宿主 SSE `event: toast` payload 增加 `sessionId` 字段。
- widget 渲染 toast（WinRT XML）**不带 launch/COM 回调**：toast 点击仅激活 AUMID 应用 = 聚焦 widget 窗口本体（默认行为，免 COM activator）。点击 toast ≠ 直跳会话；真正的"完成 → 跳转会话"由 **widget 内"最近完成"可点行**承担：宿主 snapshot 已带 `recentDone: {id,title,doneAt}`，本轮补 `recentDone` 每条增 `sessionId`，widget 把"最近完成"渲染为可点行 → 行点击走**既有 activate 链路**（`/api/ctl?action=activate&session=<sid>` → pending → Web `sessions.select`）。
- Web 客户端 `.client.js`：**不新增 toast 监听、不自动 select**（见 Q2/Q3）——"完成聚焦"完全由"用户显式点击 widget 内完成行 / 任务行"触发，走既有 pending 跳转路径。零 COM、对升级稳定。

**收益**：避免纯 PS5.1 注册 `INotificationActivationCallback` 的复杂度与不稳定（Q1 已确认放弃 COM activator 路线）。代价 = 用户点 toast 后需再点一下 widget 内"最近完成"行才跳会话，可接受。

### 7.4 F4 全屏自动隐藏

**方案（widget 侧事件驱动，零宿主改动，Q4 确认）**：用 Win32 `SetWinEventHook` 订阅前台 + 前台窗口尺寸/位置变化，callback 比对全屏态切换 → 显隐小窗。

**接线（PowerShell P/Invoke）**：
- `user32!SetWinEventHook(eventMin, eventMax, hmodWinEventProc, pfnWinEventProc, idProcess, idThread, dwFlags)`，`WINEVENT_OUTOFCONTEXT=0x0`（回调在调用线程消息泵，WPF 消息泵天然分发）。
- 订阅两条事件：
  - `EVENT_SYSTEM_FOREGROUND = 0x3`：前台窗口切换 —— 新前台是全屏 app → 隐藏。
  - `EVENT_OBJECT_LOCATIONCHANGE = 0x800B`：窗口位置/尺寸变化 —— 捕获"当前前台窗口 F11 进入全屏"这类**前台不变但尺寸变全屏**的场景（纯 FOREGROUND hook 会漏掉）。
- 回调体（`WINEVENTPROC` 委托）：仅当 `idObject==OBJID_WINDOW(0)` 且 `hwnd==GetForegroundWindow()` 时，`GetWindowRect` 比对 widget 所在屏 `Screen.FromHandle(hwnd).Bounds`（`rect==bounds` 视为全屏）；全屏态翻转才 `Visibility=Collapsed/Visible`（去抖：状态未变不动），并置 `$script:hiddenByFs` 标志避免与用户主动 hide 冲突。
- **回调委托保活**：`WINEVENTPROC` 是函数指针，PS 委托须用 `[System.Runtime.InteropServices.GCHandle]::Alloc($callback)` 或模块级 `[scriptblock]` 强引用持有，防 GC 回收导致回调失效（PS5.1 经典坑）。
- `UnhookWinEvent` 在退出时调用（与 `ensureWidget` 退出清理一并）。

**判定口径**：`rect == monitor bounds`（含 DPI 物理像素）即全屏。游戏/视频播放器/F11 浏览器全屏全部命中 → 符合"勿挡全屏"直觉。退出全屏（前台切回非全屏 / 全屏窗口复原）→ 恢复显示，除非用户已显式 hide。

**不依赖 DSH 全屏事件**（对升级稳定）。如后续 DSH 暴露 `ui/fullscreen` 事件可作为提前优化（宿主发 `ctl hide`），列为可选。

### 7.5 F5 任务卡 tooltip

- 宿主 `collect()` `sessionViews` 增 `cwd`（全路径，`safe(()=>session.header.cwd)`）；snapshot 序列化体积 +≤少量字符/会话。
- widget 任务行 `ToolTip` = `cwd` +（`parentId` 存在 ? `` ↳ 父会话: <parentId 缩短> `` : ''）。
- 行内现有 workspace 主行 / 工作区副行不变；tooltip 仅悬停可见。

### 7.6 F6 工程一致性

- **F6a peerDependencies**（`package.json`）：
  ```jsonc
  "peerDependencies": {
    "cordis": ">=4.0.0-rc <5",
    "@deepseek-ai/dsh-client-ui-slots": ">=0.0.1-rc <2",
    "@deepseek-ai/dsh-client-ui-conversation": ">=0.0.1-rc <2"
  }
  ```
  （范围声明，不硬编码版本；免编译场景为声明性，供 `dsh plugin add` 依赖解析与规范化。）
- **F6b client inject 一致性**：`dsh.client.inject` 改为
  `["@deepseek-ai/dsh-client-ui-conversation", "@deepseek-ai/dsh-client-ui-slots"]`
  ——与 `client.js` 使用 `ctx.slots` 的契约一致（避免 slots 服务依赖隐式传递）。
- **F6c bundle 装配**：新增 `cordis.patch.yml`：
  ```yaml
  - insert:
      - id: task-widget
        name: '@dsh-external/dsh-task-widget'
        config: {}
  ```
  `package.json` 加 `"dsh": { ..., "bundle": { "patch": "./cordis.patch.yml" }, ... }`。注入路径不受影响（bundle patch 仅在包进 `bundles` 列表时应用）。id `task-widget` 全局唯一，避免 `duplicate loader entry id`。

### 7.7 F7 加固

- widget 启动（`$win.Add_Loaded` 后）写一行到 `widget/.log`：`[startup] v=0.6.0 win11=$isWin11 acrylic=$script:acrylicOn hwnd=$hwnd theme=$light` —— 复盘"为什么没玻璃"。
- 保留：崩溃自愈 3s/5 次熔断、`widgetQuit` 不自愈、SSE 客户端断连清理、心跳脏标记兜底。
- 新增：F2 SSE 断连退避重连 + 文件轮询兜底（见 7.2）；F4 全屏自检错误吞没（不拖垮小窗）。

## 8. 配置变更

| 字段 | 文件 | v0.5.0 → v0.6.0 |
|---|---|---|
| `version` | `package.json` | `0.5.0` → `0.6.0` |
| `app.version` | `lib/index.js` `collect()` | `'0.5.0'` → `'0.6.0'` |
| `alpha` 语义 | `widget.ps1` / 设置页文案 | "窗口整体不透明度" → "玻璃透明度（不影响文字）"；字段名不变 |
| `peerDependencies` | `package.json` | 无 → 补齐（F6a） |
| `dsh.client.inject` | `package.json` | `[conversation]` → `[conversation, slots]`（F6b） |
| `dsh.bundle` | `package.json` | 无 → `{ patch: './cordis.patch.yml' }`（F6c） |
| `cordis.patch.yml` | 包根 | 无 → 新增（F6c） |

`.config.json`（accent/alpha/cardAlpha/locked/preset/usageHidden）字段集合不变，向后兼容。

## 9. 版本与交付

- 目标版本 **v0.6.0**。
- 工作位置：复制 v0.5.0 交付物至 `E:\DSH Zone\dsh-task-widget-0.6.0\`（本机会话工作区，注入器路径惯例）。
- 交付形态：免编译纯 JS + PS1（`dev_build_plugin` 仅校验、`npm pack` 出 tgz）。
- 验证方式：`dev_inject_plugin` → `dev_reload_package` 热验证（免重启）；真机按 §12 回归。

## 10. 已确认决策（依据提问答复，2026-08）

- **主线**：v0.5.1 残留 + v0.6.0 全 P2 + 稳定加固 + 工程一致性，一次交付（提问 dev_target 答复"1/2/3 都要"）。
- **真机 bug**：调低玻璃透明度时文字跟着变淡、不清晰 → F1 修复（提问 tested 答复"字体会跟着透明度变，我不需要这样"）。
- **v0.6.0 候选项**：全部纳入（SSE 单通道合并 / Toast 点击聚焦会话 / 全屏自动隐藏 / 任务卡 tooltip）。
- **工程一致性**：补 peerDependencies + client inject 一致性 + bundle 装配能力，三项全做。
- **工作位置**：复制到 `E:\DSH Zone` 工作区开发与注入验证。
- **执行节奏**：先出 SPEC，确认后再实现。
- **Q1 Toast 激活**：采用**降级方案**——toast 点击仅聚焦 widget 本体（免 COM），真正的"完成 → 跳转会话"由 widget 内"最近完成"可点行承担，走既有 activate 链路。放弃 COM `INotificationActivationCallback` 路线（纯 PS5.1 不稳定）。
- **Q2 自动聚焦**：**不自动切**——完成不在 Web 自动 `sessions.select`；"聚焦会话"一律由用户显式点击（widget 内完成行/任务行）触发，避免后台完成强拽打断当轮操作。Web 客户端不新增 toast 监听。
- **Q3 Web 内完成提示**：**仅系统通知**——除 Windows toast 外，Web UI 不额外弹内联"完成提示"。
- **Q4 全屏检测**：**事件驱动**——`SetWinEventHook` 订阅 `EVENT_SYSTEM_FOREGROUND` + `EVENT_OBJECT_LOCATIONCHANGE`，callback 比对全屏态切换显隐（不用 1s 轮询）。

## 11. 开放问题

（已全部闭环，见 §10 Q1–Q4。）

## 12. 验证方法

1. **F1 字字清晰**：alpha 调到 40%，桌面壁纸仍呈霜化模糊、**文字全清晰无发虚**；alpha=100 回归原貌。
2. **F2 单通道**：widget 进程仅一条对 `/api/events` 的 ESTABLISHED 连接（无 2s snapshot 循环请求）；改 accent「应用」→ widget ≤1s 内热应用（SSE ctl）。
3. **F3 toast 聚焦**：`dev_inject` 后跑一个会话完成 → 收 Windows 通知 → 点击（或降级行点击）→ DSH UI 切到该会话。
4. **F4 全屏隐藏**：开任意全屏应用（F11 浏览器/视频）→ 小窗自动消失；退出 → 恢复。
5. **F5 tooltip**：悬停任务卡 → 显示完整 cwd + 父会话标注。
6. **回归**：强调色 6 色 / 玻璃与卡片透明度 / 应用按钮 / 锁定 / 四角预设与磁吸 / 用量卡开关与点击 / 跟随系统深浅色 / 崩溃自愈，全部维持 v0.5.0 行为。
7. **工程**：`package.json` 解析正常、`dsh-client-ui-slots` 已 inject、`dsh plugin --profile web add <dir>` 可正式装配（bundle patch 命中、无 `duplicate id`）。

## 13. 实施路径（确认 SPEC 后）

1. 复制 v0.5.0 交付物 → `E:\DSH Zone\dsh-task-widget-0.6.0\`，清理冗余 src/dist 双份（保留单一交付布局：`lib/widget/scripts/cordis.patch.yml/package.json/README.md/SPEC.md/docs`）。
2. `widget/widget.ps1`：F1（`$win.Opacity=1` + alpha→玻璃层）、F2（SSE 长连接 + 兜底）、F3（recentDone 可点行走既有 activate 链路）、F4（WinEventHook 事件驱动全屏显隐 + 委托保活）、F5（ToolTip）、F7（启动日志）。
3. `lib/index.js`：`collect()` 增 cwd + `recentDone` 增 sessionId；`pushEvent` 增 sessionId 并广播；`writeCommand` 并发 `event: ctl`；`app.version='0.6.0'`。
4. `lib/client.js`：设置页文案「玻璃透明度（不影响文字清晰度）」。（toast 聚焦不经客户端，按 Q1–Q3 无新增 SSE 监听与自动 select。）。
5. `package.json` + 新增 `cordis.patch.yml`（F6）。
6. `dev_build_plugin` → `dev_inject_plugin` → 按 §12 真机验证 → `dev_reload_package` 迭代 → `npm pack` 出 `dsh-task-widget-0.6.0.tgz`（可选 `dev_release_plugin` 发 GitHub Release）。