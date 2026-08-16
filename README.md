# dsh-task-widget — Windows 桌面独立小组件（液态玻璃任务台）v0.3.1

一个真正的 Windows 桌面置顶小组件，以 DSH 插件形式运行：宿主守护跑在 DSH 服务进程内，
派生一个 **PowerShell + WPF 原生小窗**（`widget/widget.ps1`，零外部依赖、系统自带运行时），展示：

- **所有任务**：全部会话全量列出（不截断）；**运行中任务前置三点跑马灯动画**（●○ 依次点亮）；
  **点击任务卡片跳转到对应会话页面**（`sessions.select`）
- **任务完成提醒**：会话回合完成 / todo 全部完成 → 小窗内玻璃 toast（隐藏小窗后任务完成自动弹回）
- **底部用量卡（独立卡片，接在主卡底下）**：四项指标——Token 用量（总耗 token）、当前花费（¥，总额度−可用）、剩余 Token 量（上下文容量−已用）、剩余额度（可用余额 ¥）
- **外观**：**真高斯模糊液态玻璃（Liquid Glass）**——截屏窗口背后的桌面并用 WPF BlurEffect 做高斯模糊，
  再叠 accent 着色玻璃 + 顶部径向高光（光打在玻璃上的漫反射）+ 渐变高光描边 + 柔和投影 + 行 hover 微交互。
  **两卡一致**：主卡与用量卡使用同一模糊层、同一 accent 着色、同一描边（不再是一张实心 accent + 一张半透明）。
  **布局**：主卡（任务列表可滚动 + 右下角锁定）在上，**用量卡为独立卡片固定接在主卡底部**（不随滚动消失）；
  小窗内无标题/关闭/收起/滚动条/声音；右下角**位置锁定按钮**。
  **任务卡**：项目名（主行）+ 工作区名（cwd basename，暗色副行）区分显示。
  **软件内可调**（设置 → 任务小窗）：强调色 6 色板 + 玻璃着色强度 + 卡片透明度，**改完点「应用」提交**（40–100%）。

## v0.3.0 修复与增强（相对 0.2.0）

| 项 | 0.2.0 问题 | 0.3.0 修复 |
| --- | --- | --- |
| 颜色/透明度调节 | 设置页区块用 `ctx.slots.inject(...)` 嵌套注册，与 DSH 槽系统不匹配 → 区块不渲染 → 控件根本不显示 | v0.3.0 误改成 `ctx.slots.register` 直注册（settings.section 必须靠 inject 消费）→ 仍不显示；**v0.3.1 改回正确的 `inject→register` 嵌套注册** + 增加「应用」按钮（见下） |
| 位置锁定 | `LockBtn` 上挂了 `PreviewMouseLeftButtonDown{Handled=true}`，吞掉自身 `Click` → 锁按钮点了没反应 | 移除该拦截，仅由主卡拖拽处理器在回溯到 LockBtn 时跳过拖拽；锁按钮点击与按压缩放恢复正常 |
| 任务点击跳转 | `pendingActivate` 只在「设置页打开时轮询」才消费 → 小窗里点任务时设置页多半没开，等于失效 | 客户端新增常驻 `EventSource` 监听 `/api/events` 的 `snapshot`/`pending` 事件，命中即 `sessions.select` 跳转；服务端 `activate` 时立刻推送 `pending` 事件 |
| Token 用量卡 | 嵌在主卡内部（不独立） | 拆分为两张独立浮玻璃卡：主卡（任务 + 锁定）+ 用量卡（固定接在主卡底部） |
| 液态玻璃 | — | 新增顶部径向高光层（SpecGlow / UsageGloss）、更柔和的弥散投影、行 hover 提亮微交互；主题/配置切换时一并重绘已有任务行 |

## v0.3.1 修复与增强（相对 0.3.0）

| 项 | 问题 / 诉求 | 0.3.1 处理 |
| --- | --- | --- |
| 设置页仍不显示 | v0.3.0 把设置区块改成 `ctx.slots.register` 直注册，但 `settings.section` 是**靠 inject 消费**的槽，直注册不会被渲染 | 改回与 dsh-wsl-settings 一致的 `inject("settings.section", () => register({name,id,order,label:()=>string, inject:()=>({})}, Component))`；参照官方 save 模式新增**「应用」按钮**，颜色/透明度改动点应用才提交 |
| 两卡不一致 | 主卡是半透明玻璃、用量卡是实心 accent 填充，透明度/颜色看着不同 | 两卡统一为「同一模糊层 + 同一 accent 着色玻璃 + 同一描边」；accent 只用于着色与描边，不再单独填一整张卡 |
| 要真高斯模糊 | 之前只是半透明渐变，不是模糊 | 新增模糊层：截屏窗口背后的桌面区域，用 WPF `BlurEffect` 做高斯模糊（截屏前 `Opacity=0` 暂隐窗口避免把自身也截进去递归）；移动/缩放/每 5s 刷新，常驻模糊背景 |
| 工作区 vs 项目名 | 任务卡只显示一个名字，两者混在一起 | 快照新增 `workspace`（cwd basename）；任务卡项目名作主行、工作区名作暗色副行（「工作区 · xxx」）区分 |
| 用量卡指标 | 之前是上下文占用环 + 分段条 | 改为四项指标：Token 用量（总耗 token）/ 当前花费（¥，总额度−可用）/ 剩余 Token 量（容量−已用）/ 剩余额度（可用余额 ¥），2×2 布局 |

## 架构

```
DSH 服务进程（宿主守护 lib/index.js）
  ├─ ctx.sessions / ctx.jobs / ctx.sessionProjections → 数据收集
  ├─ api.deepseek.com/user/balance → 余额（5 分钟刷新）
  ├─ webServer 注册 /dsh-task-widget 前缀路由（同源）
  │    ├─ /                     调试页（内联 HTML）
  │    ├─ /api/snapshot         完整快照 JSON（含 pendingActivate）
  │    ├─ /api/events           SSE 实时推送（snapshot + toast + pending 事件）
  │    └─ /api/ctl              show/hide/toggle/status/config/activate/activate_clear（客户端/小窗调用）
  └─ 派生 powershell.exe -File widget/widget.ps1
       ├─ WPF 无边框液态玻璃窗（AllowsTransparency 自绘 + 圆角阴影层 + 径向高光，Win10/11 一致）
       ├─ 始终置顶 + 不占任务栏 + 右上角定位 + 主卡拖拽（右下角锁按钮可锁定）
       ├─ 数据：2s 轮询 /api/snapshot（toast 回放最近 12 条完成事件）
       ├─ 控制：500ms 轮询 widget/.command.json ← 宿主写 show/hide/toggle/config/quit
       └─ 任务卡点击 → 宿主 activate API → 客户端（常驻 SSE）sessions.select 跳转
```

## 使用

- 注入：`dev_inject_plugin <本插件目录>`（或 `dev_install_package` 持久装配）
- 启动即自动拉起小窗（右上角）；DSH 会话头部出现「任务台」开关按钮可随时隐藏/显示
- 小窗内无任何控件（无标题/关闭/收起/滚动条/声音）；右下角为**位置锁定按钮**
- 显示/隐藏、强调色、玻璃着色强度、卡片透明度统一在 **DSH 设置 → 任务小窗** 控制；颜色/透明度改动后点 **「应用」** 才提交到小窗
- **点击小窗里的任务卡** → 自动跳转到对应会话页面

## 构建与注入

```bash
bash scripts/build.sh        # 产物校验（纯 JS + PS1 交付，无编译步骤）
dev_build_plugin <本插件目录>   # 可选：打包 tgz
dev_inject_plugin <本插件目录>  # 运行时注入
dev_reload_package dsh-task-widget             # 热重载（改 lib/ 或 widget/ 后）
dev_uninject_plugin dsh-task-widget            # 卸载（小窗进程一并退出）
```

## 说明

- 小窗为 PowerShell 5.1 + WPF（PresentationFramework），Windows 10/11 原生支持，无任何外部依赖。
- 玻璃效果为**真高斯模糊液态玻璃**：截屏窗口背后的桌面并用 WPF `BlurEffect` 模糊（每 5s 及移动/缩放时刷新），叠 accent 着色层；不依赖 Win11 DWMWA_SYSTEMBACKDROP_TYPE（非激活窗口会退化为不透明暗灰，小组件不抢焦点故弃用）。截屏前窗口 `Opacity=0` 暂隐约 40ms 以避免把自身截进去递归，几乎无感。
- `widget/widget.ps1` **必须保持 UTF-8 带 BOM**（Windows PowerShell 5.1 无 BOM 按 ANSI 读取，中文会乱码崩溃）。
- 宿主对小窗做崩溃自愈（3s 重拉），连续 5 次快速崩溃则暂停等待手动 toggle。
- 完成事件保留最近 12 条，小窗重连时回放 toast；SSE 仅用于 web 调试页/扩展，小窗本体走快照轮询。
