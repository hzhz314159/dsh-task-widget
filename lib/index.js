// dsh-task-widget — Windows 桌面独立小组件（液态玻璃任务台）宿主守护。
//
// 架构：本插件运行在 DSH 服务进程内——
//   1. 数据收集：ctx.sessions（会话）+ ctx.jobs（后台任务）+ ctx.sessionProjections
//      （title/todos/goal/tokenUsage/contextPressure/contextBreakdown/sessionStats）
//      + api.deepseek.com/user/balance（账户余额，与桌面壳层 balance.js 同口径）。
//   2. 在 DSH web 服务器上注册 /dsh-task-widget 前缀路由（同源）：
//        /dsh-task-widget/           调试页（内联 HTML）
//        /dsh-task-widget/api/snapshot   完整快照 JSON
//        /dsh-task-widget/api/events     SSE 实时推送（快照 + toast + pending 事件）
//        /dsh-task-widget/api/ctl        小窗显示/隐藏/配置/激活（供 DSH 客户端与小窗调用）
//   3. 派生 PowerShell + WPF 原生小窗（widget/widget.ps1，零外部依赖）：
//      Win11 DWM Acrylic 真高斯模糊液态玻璃、始终置顶、可拖动、深/浅色跟随系统、
//      任务完成 toast + 提示音；控制走命令文件（widget/.command.json，小窗 500ms 轮询）。
//
// 全部资源挂 ctx.effect：热重载/卸载即净（路由注销、子进程终止、订阅清理）。

import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';
import { existsSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { spawn } from 'node:child_process';
import https from 'node:https';

const name = 'dsh-task-widget';
const inject = ['webServer'];

const HERE = dirname(fileURLToPath(import.meta.url));
const WIDGET_DIR = join(HERE, '..', 'widget');
const COMMAND_FILE = join(WIDGET_DIR, '.command.json');
const CONFIG_FILE = join(WIDGET_DIR, '.config.json');
const DEBUG_PAGE = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>DSH 任务台</title>
<body style="font-family:Segoe UI,Microsoft YaHei;background:#141a33;color:#dfe6ff;padding:24px">
<h2>DSH 任务台 · 调试页</h2>
<p>桌面小窗由 PowerShell+WPF 原生渲染（widget/widget.ps1），本页仅供调试。</p>
<ul><li><a href="/dsh-task-widget/api/snapshot" style="color:#7aa2ff">/api/snapshot</a> 完整快照 JSON</li>
<li><a href="/dsh-task-widget/api/ctl?action=status" style="color:#7aa2ff">/api/ctl?action=status</a> 状态</li>
<li><a href="/dsh-task-widget/api/ctl?action=toggle" style="color:#7aa2ff">/api/ctl?action=toggle</a> 开关小窗</li></ul></body></html>`;
const BALANCE_INTERVAL_MS = 5 * 60 * 1000;
const MAX_RECENT_DONE = 6;
const MAX_EVENTS = 12;
const PRESETS = ['topRight', 'topLeft', 'bottomRight', 'bottomLeft'];

// ════════════════════════════════════════════════════════════════════
// PowerShell 定位（系统自带；WPF 渲染小窗）
// ════════════════════════════════════════════════════════════════════
function findPowerShell() {
  const candidates = [];
  if (process.env.SystemRoot) {
    candidates.push(join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'));
  }
  candidates.push('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe');
  candidates.push('powershell.exe');
  for (const c of candidates) if (c && existsSync(c)) return c;
  return 'powershell.exe';
}

// ════════════════════════════════════════════════════════════════════
// 工具
// ════════════════════════════════════════════════════════════════════
function safe(fn, fallback) {
  try { return fn(); } catch { return fallback; }
}

function sessionTitle(session, projectionValues) {
  const t = projectionValues && projectionValues.title;
  if (typeof t === 'string' && t.trim()) return t;
  const h = safe(() => session.header, undefined);
  const cwd = h && h.cwd;
  return (typeof cwd === 'string' && cwd) ? basename(cwd) : session.id;
}

/** turn/start 与 turn/end 的平衡：有未闭合回合视为运行中（无 agent/status 时的兜底）。 */
function turnBalancedRunning(session) {
  let bal = 0;
  const events = safe(() => session.events, []);
  if (!Array.isArray(events)) return false;
  for (const e of events) {
    if (!e || typeof e.type !== 'string') continue;
    if (e.type === 'turn/start') bal += 1;
    else if (e.type === 'turn/end') bal -= 1;
  }
  return bal > 0;
}

function lastEventTime(session) {
  const events = safe(() => session.events, []);
  const last = Array.isArray(events) ? events[events.length - 1] : undefined;
  return last && typeof last.time === 'number' ? last.time : 0;
}

/** 会话累计 token 总量（输入/缓存读/缓存写/输出）。 */
function tokenTotalOf(values) {
  if (!values || !values.tokenUsage) return 0;
  const u = values.tokenUsage;
  const n = (x) => (typeof x === 'number' && Number.isFinite(x)) ? x : 0;
  return n(u.uncachedInputTokens) + n(u.cacheReadTokens) + n(u.cacheWriteTokens) + n(u.outputTokens);
}

function fmtMoney(n) {
  if (typeof n !== 'number' || !Number.isFinite(n)) return '—';
  return n.toLocaleString('zh-CN', { maximumFractionDigits: 2 });
}

// ════════════════════════════════════════════════════════════════════
// 插件主体
// ════════════════════════════════════════════════════════════════════
function apply(ctx) {
  return ctx.effect(() => {
    const log = (...a) => console.log('[dsh-task-widget]', ...a);
    const warn = (...a) => console.warn('[dsh-task-widget]', ...a);

    const web = ctx.get('webServer', false);
    const state = {
      disposed: false,
      sessions: [],            // 收集后的会话视图
      jobs: [],                // 收集后的任务视图
      balance: null,           // {available,currency,total,granted,toppedUp,error}
      running: new Map(),      // sessionId -> boolean（agent/status 权威）
      todosSeen: new Map(),    // sessionId -> todos 指纹（用于“全部完成”事件去重）
      recentDone: [],          // 最近完成的会话 {id,title,doneAt}
      events: [],              // 完成事件队列（toast 回放）
      widget: null,            // 子进程
      widgetVisible: false,    // 窗口可见性（宿主维护，供设置页开关）
      widgetQuit: false,       // 用户主动退出（不再自动拉起）
      spawnAttempts: 0,
      crashStreak: 0,          // 连续快速崩溃计数（防自愈死循环）
      pendingActivate: null,   // 小窗点击任务 → 客户端跳转会话（{id, ts}）
      dirty: false,
      flushTimer: null,
      sseClients: new Set(),
      lastSnapshot: null,
      turnTokens: new Map(),   // sessionId -> 最近完成回合的 token 增量
      turnStart: new Map(),    // sessionId -> turn/start 时的累计 token 总量
    };

    const services = {
      sessions: () => ctx.get('sessions', false),
      projections: () => ctx.get('sessionProjections', false),
      jobs: () => ctx.get('jobs', false),
    };

    // ──────────────────────────────────────────────────────────────
    // 收集：会话 + 投影 + 任务 + 余额 → 快照
    // ──────────────────────────────────────────────────────────────
    function collect() {
      const sessions = services.sessions();
      const projections = services.projections();
      const jobs = services.jobs();
      const sessionViews = [];
      const liveIds = new Set();
      const live = sessions && typeof sessions.list === 'function' ? safe(() => sessions.list(), []) : [];
      const liveArr = Array.isArray(live) ? live : [];

      for (const session of liveArr) {
        if (!session || typeof session.id !== 'string') continue;
        liveIds.add(session.id);
        const values = projections && typeof projections.snapshot === 'function'
          ? safe(() => projections.snapshot(session).values, {}) : {};
        const running = state.running.get(session.id) ?? turnBalancedRunning(session);
        const todos = Array.isArray(values.todos) ? values.todos : [];
        const done = todos.length > 0 && todos.every((t) => t && t.status === 'completed');
        const cwd = safe(() => session.header && session.header.cwd, undefined);
        const workspace = (typeof cwd === 'string' && cwd) ? basename(cwd) : '';
        // 本回合 token：优先用进行中的实时增量，否则用最近完成回合的增量
        const tt = tokenTotalOf(values);
        let turn = state.turnTokens.get(session.id) ?? null;
        if (running && state.turnStart.has(session.id)) {
          const d = tt - (state.turnStart.get(session.id) || 0);
          if (d > 0) turn = Math.round(d);
        }
        sessionViews.push({
          id: session.id,
          title: sessionTitle(session, values),
          workspace,
          cwd: (typeof cwd === 'string' && cwd) ? cwd : undefined,
          running,
          updatedAt: lastEventTime(session),
          parentId: safe(() => session.header && session.header.parentSession, undefined),
          agentPreset: safe(() => session.header && session.header.agentPreset, undefined),
          blank: safe(() => session.blank, false),
          todos,
          todosDone: done,
          goal: values.goal ?? undefined,
          tokenUsage: values.tokenUsage ?? undefined,
          turnTokens: turn,
          contextPressure: values.contextPressure ?? undefined,
          contextBreakdown: values.contextBreakdown ?? undefined,
          sessionStats: values.sessionStats ?? undefined,
        });
      }

      // 会话消失（结束/清理）→ 记入最近完成
      for (const [id, prev] of state.running) {
        if (!liveIds.has(id) && prev && !state.recentDone.some((r) => r.id === id)) {
          const known = state.sessions.find((s) => s.id === id);
          state.recentDone.unshift({ id, sessionId: id, title: known ? known.title : id, doneAt: Date.now() });
          if (state.recentDone.length > MAX_RECENT_DONE) state.recentDone.length = MAX_RECENT_DONE;
        }
      }

      // 后台任务（按 ownerSession 挂到会话下；无主的归入全局）
      const jobViews = [];
      const byOwner = new Map();
      if (jobs && typeof jobs.list === 'function') {
        const all = safe(() => jobs.list(), []);
        if (Array.isArray(all)) {
          for (const j of all) {
            const v = {
              id: String(j.id ?? ''),
              kind: String(j.kind ?? 'job'),
              label: String(j.label ?? ''),
              status: String(j.status ?? 'unknown'),
              startedAt: typeof j.startedAt === 'number' ? j.startedAt : 0,
              finishedAt: typeof j.finishedAt === 'number' ? j.finishedAt : undefined,
              ownerSession: typeof j.ownerSession === 'string' ? j.ownerSession : undefined,
            };
            jobViews.push(v);
            if (v.ownerSession) {
              if (!byOwner.has(v.ownerSession)) byOwner.set(v.ownerSession, []);
              byOwner.get(v.ownerSession).push(v);
            }
          }
        }
      }
      for (const v of sessionViews) v.jobs = byOwner.get(v.id) ?? [];

      // 会话排序：运行中在前（按更新时间），其余按更新时间倒序
      sessionViews.sort((a, b) => {
        if (a.running !== b.running) return a.running ? -1 : 1;
        return (b.updatedAt || 0) - (a.updatedAt || 0);
      });

      state.sessions = sessionViews;
      state.jobs = jobViews;

      const snap = {
        ts: Date.now(),
        app: { version: '0.6.0', widgetUrl: widgetBaseUrl() },
        sessions: sessionViews.slice(0, 12),
        jobs: jobViews.slice(0, 20),
        recentDone: state.recentDone,
        balance: state.balance,
        events: state.events.slice(-MAX_EVENTS),
        pendingActivate: state.pendingActivate,
      };
      state.lastSnapshot = snap;
      return snap;
    }

    function widgetBaseUrl() {
      const port = web ? web.port : 0;
      return port ? 'http://127.0.0.1:' + port + '/dsh-task-widget' : '';
    }

    // ──────────────────────────────────────────────────────────────
    // 事件：完成提醒 + 本回合 token 增量追踪
    // ──────────────────────────────────────────────────────────────
    function pushEvent(kind, title, detail, sessionId) {
      const ev = { kind, title, detail, ts: Date.now() };
      if (sessionId && typeof sessionId === 'string') ev.sessionId = sessionId;
      state.events.push(ev);
      if (state.events.length > MAX_EVENTS) state.events.shift();
      for (const client of state.sseClients) {
        try { client.write('event: toast\ndata: ' + JSON.stringify(ev) + '\n\n'); } catch { /* 客户端断开 */ }
      }
      log('event:', kind, '|', title);
    }

    /** 会话事件：todo 完成检测 + 本回合 token 增量（turn/start 记起点，turn/end 算增量）。 */
    function onSessionEvent(session) {
      if (!session || typeof session.id !== 'string') return;
      const projections = services.projections();
      if (projections && typeof projections.snapshot === 'function') {
        const values = safe(() => projections.snapshot(session).values, {});
        // —— 本回合 token 增量追踪 ——
        const tt = tokenTotalOf(values);
        const evs = safe(() => session.events, []);
        const last = Array.isArray(evs) ? evs[evs.length - 1] : undefined;
        if (last && typeof last.type === 'string') {
          if (last.type === 'turn/start') {
            state.turnStart.set(session.id, tt);
          } else if (last.type === 'turn/end') {
            if (state.turnStart.has(session.id)) {
              const d = Math.max(0, tt - (state.turnStart.get(session.id) || 0));
              if (d > 0) state.turnTokens.set(session.id, Math.round(d));
              state.turnStart.delete(session.id);
            }
          }
        }
        // —— todo 全部完成检测（指纹去重）——
        const todos = Array.isArray(values.todos) ? values.todos : [];
        const sig = todos.map((t) => (t ? t.status + ':' + String(t.content) : '')).join('|');
        const prev = state.todosSeen.get(session.id);
        if (sig && sig !== prev) {
          state.todosSeen.set(session.id, sig);
          const allDone = todos.every((t) => t && t.status === 'completed');
          const prevAllDone = prev !== undefined && prev.split('|').every((part) => part.startsWith('completed:'));
          if (allDone && !prevAllDone && todos.length > 0) {
            const title = state.sessions.find((s) => s.id === session.id)?.title ?? sessionTitle(session, values);
            pushEvent('todos-done', '任务全部完成', title + ' · ' + todos.length + ' 项', session.id);
          }
        }
      }
      markDirty();
    }

    function onAgentStatus({ agent, status }) {
      const id = agent && typeof agent.id === 'string' ? agent.id : (agent && typeof agent === 'string' ? agent : '');
      if (!id) return;
      const running = status === 'running';
      const prev = state.running.get(id);
      if (prev === running) return;
      state.running.set(id, running);
      if (prev === true && !running) {
        // 会话完成一个回合 → 完成提醒（补标题：下一轮 collect 会填，这里用旧视图兜底）
        const known = state.sessions.find((s) => s.id === id);
        const title = known ? known.title : id;
        state.recentDone.unshift({ id, sessionId: id, title, doneAt: Date.now() });
        if (state.recentDone.length > MAX_RECENT_DONE) state.recentDone.length = MAX_RECENT_DONE;
        pushEvent('session-done', '会话完成', title, id);
        // 用户关过小窗 → 任务完成时自动弹回
        if (state.widgetQuit) { state.widgetQuit = false; ensureWidget(); }
      }
      markDirty();
    }

    function onJobDone(snapshot) {
      const v = snapshot || {};
      const title = state.sessions.find((s) => s.id === v.ownerSession)?.title ?? '';
      pushEvent('job-done', '后台任务完成', (title ? title + ' · ' : '') + String(v.label || v.id || ''), v.ownerSession || '');
      markDirty();
    }

    // ──────────────────────────────────────────────────────────────
    // 推送：SSE
    // ──────────────────────────────────────────────────────────────
    function markDirty() {
      if (state.disposed || state.dirty) return;
      state.dirty = true;
      state.flushTimer = setTimeout(() => {
        state.dirty = false;
        if (state.disposed) return;
        const snap = collect();
        for (const client of state.sseClients) {
          try { client.write('event: snapshot\ndata: ' + JSON.stringify(snap) + '\n\n'); } catch { /* 忽略 */ }
        }
      }, 600);
    }

    // ──────────────────────────────────────────────────────────────
    // 小窗子进程：派生 / 监督 / 控制
    // ──────────────────────────────────────────────────────────────
    function writeCommand(action) {
      try {
        writeFileSync(COMMAND_FILE, JSON.stringify({ action, ts: Date.now() }));
      } catch (e) {
        warn('写控制命令失败: ' + String(e && e.message || e));
      }
      // F2 SSE 单通道：并行广播 event:ctl，widget 在线即实时响应；离线则由 .command.json 兜底轮询
      const payload = { action, ts: Date.now() };
      for (const client of state.sseClients) {
        try { client.write('event: ctl\ndata: ' + JSON.stringify(payload) + '\n\n'); } catch { /* 忽略断开 */ }
      }
      return true;
    }

    function ensureWidget() {
      if (state.disposed || state.widgetQuit) return;
      if (state.widget && state.widget.exitCode === null) return; // 进程尚在
      const ps = findPowerShell();
      const psScript = join(WIDGET_DIR, 'widget.ps1');
      if (!existsSync(psScript)) { warn('小窗脚本缺失: ' + psScript); return; }
      if (!web || !web.port) {
        if (state.spawnAttempts < 60) {
          state.spawnAttempts += 1;
          setTimeout(ensureWidget, 1000);
        } else {
          warn('web 服务器端口一直未就绪，放弃自动拉起小窗');
        }
        return;
      }
      state.spawnAttempts = 0;
      // 清残留命令文件（如旧 fiber dispose 留下的 quit，防毒死新小窗）
      try { rmSync(COMMAND_FILE, { force: true }); } catch { /* 忽略 */ }
      state.widgetVisible = true;   // 新窗口默认显示
      const url = widgetBaseUrl();
      log('拉起小窗: powershell → ' + url);
      // 连续 5 次在 60s 内快速崩溃 → 停止自愈（等用户显式 toggle）
      const now = Date.now();
      if (state.crashStreak >= 5 && now - (state.lastSpawnAt || 0) < 60000) {
        warn('小窗连续崩溃 ' + state.crashStreak + ' 次，暂停自愈（可手动 toggle 重试）');
        state.widgetQuit = true;
        return;
      }
      state.lastSpawnAt = now;
      try {
        const child = spawn(ps, [
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
          '-File', psScript,
          '-BaseUrl', url,
          '-CommandFile', COMMAND_FILE,
        ], { stdio: 'ignore', windowsHide: true });
        state.widget = child;
        child.on('error', (e) => warn('小窗进程错误: ' + String(e && e.message || e)));
        child.on('exit', (code) => {
          state.widgetVisible = false;
          log('小窗退出 code=' + code);
          if (!state.disposed && !state.widgetQuit && code !== 0) {
            state.crashStreak += 1;
            setTimeout(() => ensureWidget(), 3000); // 崩溃自愈
          } else {
            state.crashStreak = 0;
          }
        });
      } catch (e) {
        warn('小窗启动失败: ' + String(e && e.message || e));
      }
    }

    function toggleWidget() {
      if (state.widget && state.widget.exitCode === null) {
        writeCommand('toggle');
        state.widgetVisible = !state.widgetVisible;
        return { ok: true, visible: state.widgetVisible };
      }
      state.widgetQuit = false;
      state.crashStreak = 0;
      state.widgetVisible = true;
      ensureWidget();
      return { ok: true, visible: true };
    }

    // ──────────────────────────────────────────────────────────────
    // HTTP 路由（DSH web 服务器同源注册）
    // ──────────────────────────────────────────────────────────────
    function json(res, code, obj) {
      try {
        const body = JSON.stringify(obj);
        res.writeHead(code, {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'no-store',
        });
        res.end(body);
      } catch { /* 已断开 */ }
    }

    function handleRoute(req, res) {
      const u = new URL(req.url ?? '/', 'http://x');
      const p = u.pathname;
      try {
        if (p === '/dsh-task-widget' || p === '/dsh-task-widget/') {
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
          res.end(DEBUG_PAGE);
          return;
        }
        if (p === '/dsh-task-widget/api/snapshot') {
          json(res, 200, state.lastSnapshot ?? collect());
          return;
        }
        if (p === '/dsh-task-widget/api/events') {
          res.writeHead(200, {
            'Content-Type': 'text/event-stream; charset=utf-8',
            'Cache-Control': 'no-store',
            'Connection': 'keep-alive',
          });
          res.write('retry: 3000\n\n');
          res.write('event: snapshot\ndata: ' + JSON.stringify(state.lastSnapshot ?? collect()) + '\n\n');
          state.sseClients.add(res);
          req.on('close', () => { state.sseClients.delete(res); });
          return; // 保持连接
        }
        if (p === '/dsh-task-widget/api/ctl') {
          const action = u.searchParams.get('action') || 'status';
          if (action === 'toggle') return json(res, 200, toggleWidget());
          if (action === 'show') {
            state.widgetQuit = false; state.widgetVisible = true;
            if (state.widget && state.widget.exitCode === null) writeCommand('show'); else ensureWidget();
            return json(res, 200, { ok: true, visible: true });
          }
          if (action === 'hide') {
            state.widgetVisible = false;
            writeCommand('hide');
            return json(res, 200, { ok: true, visible: false });
          }
          if (action === 'quit') {
            state.widgetQuit = true; state.widgetVisible = false;
            writeCommand('quit');
            return json(res, 200, { ok: true, visible: false });
          }
          if (action === 'activate') {
            const sid = u.searchParams.get('session') || '';
            if (sid) {
              state.pendingActivate = { id: sid, ts: Date.now() };
              // 立刻推送 pending 事件，让客户端常驻 SSE 监听即时跳转（不再依赖设置页打开）
              const payload = 'event: pending\ndata: ' + JSON.stringify({ id: sid }) + '\n\n';
              for (const client of state.sseClients) {
                try { client.write(payload); } catch { /* 忽略 */ }
              }
            }
            return json(res, 200, { ok: true });
          }
          if (action === 'activate_clear') {
            state.pendingActivate = null;
            return json(res, 200, { ok: true });
          }
          if (action === 'config') {
            // 软件内调整：强调色 + 透明度 + 位置预设 + 用量卡开关 → 写 .config.json 并通知小窗热应用
            const accent = u.searchParams.get('accent') || '';
            const alphaRaw = u.searchParams.get('alpha');
            const cardAlphaRaw = u.searchParams.get('cardAlpha');
            const presetRaw = u.searchParams.get('preset');
            const usageHiddenRaw = u.searchParams.get('usageHidden');
            const cfg = { accent: '#4D9FFF', alpha: 100, cardAlpha: 100, locked: false, preset: 'topRight', usageHidden: false };
            try {
              if (existsSync(CONFIG_FILE)) {
                const cur = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
                if (cur && typeof cur === 'object') Object.assign(cfg, cur);
              }
            } catch { /* 忽略损坏配置 */ }
            if (/^#[0-9A-Fa-f]{6}$/.test(accent)) cfg.accent = accent;
            if (alphaRaw !== null) {
              const a = Number(alphaRaw);
              if (Number.isFinite(a) && a >= 40 && a <= 100) cfg.alpha = Math.round(a);
            }
            if (cardAlphaRaw !== null) {
              const ca = Number(cardAlphaRaw);
              if (Number.isFinite(ca) && ca >= 40 && ca <= 100) cfg.cardAlpha = Math.round(ca);
            }
            if (presetRaw && PRESETS.includes(presetRaw)) cfg.preset = presetRaw;
            if (usageHiddenRaw !== null) cfg.usageHidden = usageHiddenRaw === '1' || usageHiddenRaw === 'true';
            try {
              writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
              writeCommand('config');
              return json(res, 200, { ok: true, cfg });
            } catch (e) {
              return json(res, 500, { ok: false, error: String(e && e.message || e) });
            }
          }
          if (action === 'status') {
            return json(res, 200, {
              ok: true,
              port: web ? web.port : 0,
              widget: (state.widget && state.widget.exitCode === null) ? 'running' : 'stopped',
              visible: state.widgetVisible,
              pendingActivate: state.pendingActivate,
              cfg: safe(() => {
                const c = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
                return {
                  accent: String(c.accent || '#4D9FFF'),
                  alpha: Number(c.alpha) || 100,
                  cardAlpha: Number(c.cardAlpha) || 100,
                  locked: Boolean(c.locked),
                  preset: PRESETS.includes(c.preset) ? c.preset : 'topRight',
                  usageHidden: Boolean(c.usageHidden),
                };
              }, { accent: '#4D9FFF', alpha: 100, cardAlpha: 100, locked: false, preset: 'topRight', usageHidden: false }),
              sessions: state.sessions.length,
              jobs: state.jobs.length,
              balance: state.balance,
            });
          }
          return json(res, 400, { ok: false, error: 'unknown action' });
        }
        // 前缀下其它路径
        json(res, 404, { ok: false, error: 'not found' });
      } catch (e) {
        warn('route error: ' + String(e && e.message || e));
        try { res.writeHead(500); res.end('internal error'); } catch { /* 忽略 */ }
      }
    }

    // ──────────────────────────────────────────────────────────────
    // 装配
    // ──────────────────────────────────────────────────────────────
    const disposers = [];

    if (web && typeof web.register === 'function') {
      disposers.push(web.register({ kind: 'prefix', path: '/dsh-task-widget', handler: handleRoute }));
      log('路由已注册: /dsh-task-widget（port=' + (web.port || '待监听') + '）');
    } else {
      warn('webServer 服务不可用，小窗页面无法提供');
    }

    // 会话/任务事件
    const sessions = services.sessions();
    if (sessions) {
      if (typeof ctx.on === 'function') {
        disposers.push(ctx.on('agent/status', onAgentStatus));
        disposers.push(ctx.on('session/event', (session) => onSessionEvent(session)));
        disposers.push(ctx.on('session/created', () => markDirty()));
        disposers.push(ctx.on('session/disposed', () => markDirty()));
      }
    } else {
      warn('sessions 服务不可用（任务数据缺失）');
    }

    const jobs = services.jobs();
    if (jobs && typeof jobs.onJobDone === 'function') {
      disposers.push(jobs.onJobDone(onJobDone));
    }

    // 心跳脏标记兜底（部分事件不触发时也能刷新 UI）
    const heartbeat = setInterval(() => { if (!state.disposed) markDirty(); }, 10000);
    disposers.push(() => clearInterval(heartbeat));

    // 首帧快照 + 拉起小窗
    collect();
    setTimeout(ensureWidget, 1500);

    // 卸载清理
    return () => {
      state.disposed = true;
      if (state.flushTimer) clearTimeout(state.flushTimer);
      for (const d of disposers) safe(d, undefined);
      if (state.widget && state.widget.exitCode === null) {
        try { writeCommand('quit'); } catch { /* 忽略 */ }
        try { state.widget.kill(); } catch { /* 忽略 */ }
      } else {
        // 无活进程时清掉可能残留的命令文件，避免污染下次 spawn
        try { rmSync(COMMAND_FILE, { force: true }); } catch { /* 忽略 */ }
      }
      for (const client of state.sseClients) {
        try { client.end(); } catch { /* 忽略 */ }
      }
      state.sseClients.clear();
      log('已卸载（路由/订阅/子进程全部清理）');
    };
  }, 'dsh-task-widget: daemon');
}

export { apply, inject, name };
