// dsh-task-widget 客户端：
//   1. 会话头部「任务小窗」快捷开关按钮（打开/隐藏桌面玻璃小窗）。
//   2. 设置页「任务小窗」区块（经 settings.section 槽注入，与 dsh-wsl-settings 同款
//      inject→register 模式）：显示/隐藏开关、强调色 6 色板、玻璃/卡片透明度、
//      小窗位置（四角吸附预设）、用量卡开关，以及「应用」按钮——外观改动点应用后才提交。
//   3. 常驻 SSE 监听 /dsh-task-widget/api/events：消费小窗点击任务产生的 pendingActivate，
//      调用 sessions.select 跳转到对应会话（不再依赖设置页打开）。
// 按钮样式与官方头部动作一致。
window.__ModuleLoader__.load({
	id: "@dsh-external/dsh-task-widget",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react_jsx_runtime = require("react/jsx-runtime");

		// ------------------------------------------------------------------
		// CSS
		// ------------------------------------------------------------------
		const TAG = "@dsh-external/dsh-task-widget/client.css";
		const CSS = [
			// 会话头部小图标按钮
			".dsh-widget-btn{display:inline-flex;align-items:center;justify-content:center;",
			"box-sizing:border-box;border:1px solid var(--dsw-alias-border-l1);border-radius:8px;",
			"background:transparent;color:var(--dsw-alias-label-tertiary);width:26px;height:26px;",
			"padding:0;cursor:pointer;transition:color .15s,border-color .15s,background .15s}",
			".dsh-widget-btn:hover{color:var(--dsw-alias-label-primary);border-color:var(--dsw-alias-border-l2);",
			"background:var(--dsw-alias-interactive-bg-hover,rgba(255,255,255,.06))}",
			".dsh-widget-btn svg{width:14px;height:14px}",
			".dsh-widget-btn[data-on='1']{color:var(--dsw-alias-state-info-primary,#58a6ff);",
			"border-color:color-mix(in srgb,var(--dsw-alias-state-info-primary,#58a6ff) 45%,transparent)}",
			// 设置页区块
			".dsw-w-section{display:flex;flex-direction:column;width:100%;gap:14px;padding:2px 0 6px}",
			".dsw-w-row{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:44px}",
			".dsw-w-row-desc{margin-top:2px;font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary)}",
			".dsw-w-row-title{font-size:13px;color:var(--dsw-alias-label-primary)}",
			".dsw-w-switch{position:relative;flex:none;width:36px;height:20px;border-radius:10px;",
			"background:var(--dsw-alias-control-bg,rgba(128,128,128,.35));",
			"border:1px solid var(--dsw-alias-border-l2);cursor:pointer;padding:0;",
			"transition:background .15s,border-color .15s}",
			".dsw-w-switch::after{content:'';position:absolute;top:2px;left:2px;width:14px;height:14px;",
			"border-radius:50%;background:var(--dsw-alias-label-primary,#e6e9f2);",
			"box-shadow:0 1px 2px rgba(0,0,0,.35);transition:left .15s}",
			".dsw-w-switch[data-on='1']{background:var(--dsw-alias-state-info-primary,#58a6ff);",
			"border-color:transparent}",
			".dsw-w-switch[data-on='1']::after{left:18px}",
			".dsw-w-hint{margin-top:10px;font-size:12px;line-height:18px;color:var(--dsw-alias-label-tertiary)}",
			".dsw-w-label{font-size:12px;color:var(--dsw-alias-label-secondary);margin:10px 0 6px}",
			".dsw-w-swatches{display:flex;gap:8px;flex-wrap:wrap}",
			".dsw-w-swatch{width:22px;height:22px;border-radius:50%;cursor:pointer;padding:0;border:2px solid transparent;position:relative;flex:none}",
			".dsw-w-swatch[data-on='1']{border-color:var(--dsw-alias-label-primary)}",
			".dsw-w-swatch::after{position:absolute;inset:3px;border-radius:50%;background:inherit}",
			".dsw-w-range{width:100%;accent-color:var(--dsw-alias-state-info-primary,#58a6ff);cursor:pointer}",
			".dsw-w-rangeval{font-size:11px;color:var(--dsw-alias-label-tertiary);margin-top:2px}",
			".dsw-w-presets{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;max-width:210px}",
			".dsw-w-preset{padding:7px 0;border-radius:8px;cursor:pointer;font-size:12px;text-align:center;",
			"border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-interactive-bg-hover,rgba(255,255,255,.04));",
			"color:var(--dsw-alias-label-secondary);transition:all .15s}",
			".dsw-w-preset[data-on='1']{border-color:color-mix(in srgb,var(--dsw-alias-state-info-primary,#58a6ff) 50%,transparent);",
			"background:color-mix(in srgb,var(--dsw-alias-state-info-primary,#58a6ff) 14%,transparent);color:var(--dsw-alias-label-primary)}",
			".dsw-w-apply{margin-top:4px;align-self:flex-start;padding:6px 16px;border-radius:8px;cursor:pointer;",
			"font-size:13px;border:1px solid var(--dsw-alias-state-info-primary,#58a6ff);",
			"background:var(--dsw-alias-state-info-primary,#58a6ff);color:#fff;transition:opacity .15s}",
			".dsw-w-apply:hover{opacity:.88}",
			".dsw-w-apply[disabled]{opacity:.5;cursor:default}",
			".dsw-w-applied{font-size:12px;color:var(--dsw-alias-state-success-primary,#34d399);margin-left:10px}",
			".dsw-w-dirty{font-size:12px;color:var(--dsw-alias-label-tertiary);margin-left:10px;opacity:.7}"
		].join("");

		function ensureCss() {
			if (typeof document === "undefined") return;
			if (document.querySelector("style[data-plugin-css=" + JSON.stringify(TAG) + "]")) return;
			const tag = document.createElement("style");
			tag.dataset.plugin = "@dsh-external/dsh-task-widget";
			tag.dataset.pluginCss = TAG;
			tag.textContent = CSS;
			document.head.appendChild(tag);
		}

		// ------------------------------------------------------------------
		// 会话头部快捷开关按钮
		// ------------------------------------------------------------------
		function WidgetToggleButton() {
			let react = require("react");
			const [on, setOn] = (0, react.useState)(false);
			const onClick = () => {
				fetch("/dsh-task-widget/api/ctl?action=toggle", { method: "POST" })
					.then((r) => r.ok ? r.json() : null)
					.then((j) => { if (j && typeof j.visible === "boolean") setOn(j.visible); })
					.catch(() => {});
			};
			(0, react.useEffect)(() => {
				fetch("/dsh-task-widget/api/ctl?action=status")
					.then((r) => r.ok ? r.json() : null)
					.then((j) => { if (j && j.widget === "running") setOn(j.visible === true); })
					.catch(() => {});
			}, []);
			return react_jsx_runtime.jsx("button", {
				type: "button",
				className: "dsh-widget-btn",
				"data-on": on ? "1" : "0",
				title: on ? "隐藏桌面任务小窗" : "打开桌面任务小窗（液态玻璃）",
				"aria-label": "桌面任务小窗开关",
				onClick,
				children: react_jsx_runtime.jsx("svg", {
					viewBox: "0 0 24 24",
					fill: "none",
					stroke: "currentColor",
					strokeWidth: "1.8",
					strokeLinecap: "round",
					strokeLinejoin: "round",
					children: [
						react_jsx_runtime.jsx("rect", { x: "4", y: "3", width: "16", height: "13", rx: "3" }),
						react_jsx_runtime.jsx("path", { d: "M12 20v-4" }),
						react_jsx_runtime.jsx("path", { d: "M8 20h8" }),
						react_jsx_runtime.jsx("circle", { cx: "12", cy: "9", r: "1.6" })
					]
				})
			});
		}

		// ------------------------------------------------------------------
		// 设置页「任务小窗」区块：显示/隐藏开关 + 强调色 + 透明度 + 位置 + 用量卡 + 应用按钮
		// 外观改动（颜色/透明度/位置/用量卡）仅本地暂存，点击「应用」才提交到宿主。
		// ------------------------------------------------------------------
		function TaskWidgetSettingsSection() {
			let react = require("react");
			const [on, setOn] = (0, react.useState)(null); // null = 加载中
			const [hint, setHint] = (0, react.useState)("正在读取小窗状态…");
			const SWATCHES = [
				["#4D9FFF", "电光蓝"], ["#34D399", "翡翠绿"], ["#FBBF24", "琥珀"],
				["#F87171", "珊瑚红"], ["#A78BFA", "鸢尾紫"], ["#22D3EE", "湖水青"]
			];
			const PRESETS = [
				["topLeft", "左上"], ["topRight", "右上"],
				["bottomLeft", "左下"], ["bottomRight", "右下"]
			];
			// 外观：本地暂存（未提交）+ 已提交基线（用于判断是否有未应用改动）
			const [accent, setAccent] = (0, react.useState)("#4D9FFF");
			const [alpha, setAlpha] = (0, react.useState)(100);
			const [cardAlpha, setCardAlpha] = (0, react.useState)(100);
			const [preset, setPreset] = (0, react.useState)("topRight");
			const [usageHidden, setUsageHidden] = (0, react.useState)(false);
			const [base, setBase] = (0, react.useState)({ accent: "#4D9FFF", alpha: 100, cardAlpha: 100, preset: "topRight", usageHidden: false });
			const [applying, setApplying] = (0, react.useState)(false);
			const [applied, setApplied] = (0, react.useState)(false);

			const dirty = accent !== base.accent || alpha !== base.alpha || cardAlpha !== base.cardAlpha
				|| preset !== base.preset || usageHidden !== base.usageHidden;

			const refresh = () => {
				fetch("/dsh-task-widget/api/ctl?action=status")
					.then((r) => r.ok ? r.json() : null)
					.then((j) => {
						if (!j) { setHint("无法连接任务小窗服务"); return; }
						if (j.pendingActivate && j.pendingActivate.id) activateSession(j.pendingActivate.id);
						const running = j.widget === "running";
						setOn(running && j.visible === true);
						if (j.cfg) {
							setAccent(j.cfg.accent); setAlpha(j.cfg.alpha); setCardAlpha(j.cfg.cardAlpha || 100);
							const p = j.cfg.preset && PRESETS.some(([pp]) => pp === j.cfg.preset) ? j.cfg.preset : "topRight";
							setPreset(p);
							setUsageHidden(j.cfg.usageHidden === true);
							setBase({ accent: j.cfg.accent, alpha: j.cfg.alpha, cardAlpha: j.cfg.cardAlpha || 100, preset: p, usageHidden: j.cfg.usageHidden === true });
						}
						setHint(running
							? (j.visible === true ? "桌面小窗当前显示中" : "桌面小窗已隐藏，任务完成时自动弹回")
							: "桌面小窗未运行，打开后将自动启动");
					})
					.catch(() => setHint("无法连接任务小窗服务"));
			};
			(0, react.useEffect)(() => { refresh(); }, []);
			const onToggle = () => {
				fetch("/dsh-task-widget/api/ctl?action=toggle", { method: "POST" })
					.then((r) => r.ok ? r.json() : null)
					.then((j) => { if (j && typeof j.visible === "boolean") setOn(j.visible); refresh(); })
					.catch(() => setHint("操作失败，请重试"));
			};
			const onAccent = (hex) => { setAccent(hex); setApplied(false); };
			const onAlpha = (e) => { setAlpha(Number(e.target.value)); setApplied(false); };
			const onCardAlpha = (e) => { setCardAlpha(Number(e.target.value)); setApplied(false); };
			const onPreset = (p) => { setPreset(p); setApplied(false); };
			const onUsageToggle = () => { setUsageHidden((v) => !v); setApplied(false); };
			const onApply = () => {
				if (applying) return;
				setApplying(true);
				fetch("/dsh-task-widget/api/ctl?action=config&accent=" + encodeURIComponent(accent)
					+ "&alpha=" + alpha + "&cardAlpha=" + cardAlpha
					+ "&preset=" + encodeURIComponent(preset) + "&usageHidden=" + (usageHidden ? 1 : 0), { method: "POST" })
					.then((r) => r.ok ? r.json() : null)
					.then((j) => {
						if (j && j.ok) {
							setBase({ accent, alpha, cardAlpha, preset, usageHidden });
							setApplied(true);
							setHint("外观已应用，桌面小窗实时更新");
						} else {
							setHint("应用失败：" + ((j && j.error) || "未知错误"));
						}
					})
					.catch(() => setHint("应用失败，请重试"))
					.finally(() => setApplying(false));
			};
			return react_jsx_runtime.jsxs("div", {
				className: "dsw-w-section",
				children: [
					react_jsx_runtime.jsx("div", {
						className: "dsw-w-row",
						children: [
							react_jsx_runtime.jsxs("div", {
								children: [
									react_jsx_runtime.jsx("div", { className: "dsw-w-row-title", children: "显示桌面任务小窗" }),
									react_jsx_runtime.jsx("div", { className: "dsw-w-row-desc", children: "小窗内无关闭/收起按钮；开关统一在这里控制。" })
								]
							}),
							react_jsx_runtime.jsx("button", {
								type: "button",
								className: "dsw-w-switch",
								"data-on": on ? "1" : "0",
								role: "switch",
								"aria-checked": on === true,
								"aria-label": "显示桌面任务小窗",
								onClick: onToggle
							})
						]
					}),
					react_jsx_runtime.jsx("div", { className: "dsw-w-label", children: "卡片颜色（强调色，玻璃着色）" }),
					react_jsx_runtime.jsx("div", {
						className: "dsw-w-swatches",
						children: SWATCHES.map(([hex, name]) =>
							react_jsx_runtime.jsx("button", {
								type: "button",
								className: "dsw-w-swatch",
								"data-on": accent === hex ? "1" : "0",
								style: { background: hex },
								title: name,
								"aria-label": name,
								onClick: () => onAccent(hex)
							}, hex)
						)
					}),
					react_jsx_runtime.jsx("div", { className: "dsw-w-label", children: "玻璃透明度" }),
					react_jsx_runtime.jsx("input", {
						type: "range",
						className: "dsw-w-range",
						min: 40, max: 100, step: 5,
						value: alpha,
						onChange: onAlpha,
						"aria-label": "玻璃透明度"
					}),
					react_jsx_runtime.jsx("div", { className: "dsw-w-rangeval", children: alpha + "%" }),
					react_jsx_runtime.jsx("div", { className: "dsw-w-label", children: "卡片透明度（任务卡/用量卡）" }),
					react_jsx_runtime.jsx("input", {
						type: "range",
						className: "dsw-w-range",
						min: 40, max: 100, step: 5,
						value: cardAlpha,
						onChange: onCardAlpha,
						"aria-label": "卡片透明度"
					}),
					react_jsx_runtime.jsx("div", { className: "dsw-w-rangeval", children: cardAlpha + "%" }),
					react_jsx_runtime.jsx("div", { className: "dsw-w-label", children: "小窗位置（吸附到屏幕角落）" }),
					react_jsx_runtime.jsx("div", {
						className: "dsw-w-presets",
						children: PRESETS.map(([p, name]) =>
							react_jsx_runtime.jsx("button", {
								type: "button",
								className: "dsw-w-preset",
								"data-on": preset === p ? "1" : "0",
								onClick: () => onPreset(p),
								children: name
							}, p)
						)
					}),
					react_jsx_runtime.jsx("div", {
						className: "dsw-w-row",
						children: [
							react_jsx_runtime.jsxs("div", {
								children: [
									react_jsx_runtime.jsx("div", { className: "dsw-w-row-title", children: "显示用量卡" }),
									react_jsx_runtime.jsx("div", { className: "dsw-w-row-desc", children: "关闭后小窗更紧凑（仅任务列表）。" })
								]
							}),
							react_jsx_runtime.jsx("button", {
								type: "button",
								className: "dsw-w-switch",
								"data-on": (!usageHidden) ? "1" : "0",
								role: "switch",
								"aria-checked": usageHidden !== true,
								"aria-label": "显示用量卡",
								onClick: onUsageToggle
							})
						]
					}),
					react_jsx_runtime.jsxs("div", {
						style: { display: "flex", alignItems: "center", marginTop: 4 },
						children: [
							react_jsx_runtime.jsx("button", {
								type: "button",
								className: "dsw-w-apply",
								disabled: applying || !dirty,
								onClick: onApply,
								children: applying ? "应用中…" : "应用"
							}),
							applied ? react_jsx_runtime.jsx("span", { className: "dsw-w-applied", children: "已应用" }) : null,
							dirty && !applied ? react_jsx_runtime.jsx("span", { className: "dsw-w-dirty", children: "有未应用的改动" }) : null
						]
					}),
					react_jsx_runtime.jsx("div", { className: "dsw-w-hint", children: hint })
				]
			});
		}

		// ------------------------------------------------------------------
		// 会话跳转：小窗点击任务 → 宿主 pendingActivate → 此处 select 对应会话
		// ------------------------------------------------------------------
		let sessionService = null;
		const activateSession = (id) => {
			if (sessionService && typeof sessionService.select === "function") {
				try { sessionService.select(id); } catch (e) { /* 会话可能已消失 */ }
			}
			fetch("/dsh-task-widget/api/ctl?action=activate_clear", { method: "POST" }).catch(() => {});
		};

		// 常驻 SSE：消费 pendingActivate（小窗点击任务 → 跳转会话），不再依赖设置页打开。
		let evtSource = null;
		const ensureStream = () => {
			if (evtSource || typeof EventSource === "undefined") return;
			try {
				evtSource = new EventSource("/dsh-task-widget/api/events");
				const consume = (j) => {
					if (j && j.pendingActivate && j.pendingActivate.id) activateSession(j.pendingActivate.id);
				};
				evtSource.addEventListener("snapshot", (e) => {
					try { consume(JSON.parse(e.data)); } catch (err) { /* 忽略 */ }
				});
				evtSource.addEventListener("pending", (e) => {
					try { const j = JSON.parse(e.data); if (j && j.id) activateSession(j.id); } catch (err) { /* 忽略 */ }
				});
				evtSource.addEventListener("error", () => { /* 断线由浏览器自动重连，无需处理 */ });
			} catch (err) { /* 环境不支持 SSE 时静默降级（设置页仍可在打开时跳转） */ }
		};

		// ------------------------------------------------------------------
		// 插件入口
		// ------------------------------------------------------------------
		const inject = ["slots"];

		function apply(ctx) {
			try { sessionService = ctx.get("sessions"); } catch (e) { sessionService = null; }
			ensureCss();
			ensureStream();
			ctx.effect(() => ctx.slots.register({
				name: "conversation.session.header.actions",
				id: "task-widget-toggle",
				order: 300
			}, WidgetToggleButton), "dsh-task-widget: toggle button");
			// 设置页区块：必须经 settings.section 槽「注入」才能被设置面板渲染。
			// 正确形态（与 dsh-wsl-settings 一致）：外层 inject 一个工厂，工厂内 register
			// 出真正的区块组件；register 必须带 inject: () => ({}) 字段。
			// 直 register({name:"settings.section"}) 不会被设置面板消费 → 区块不出现（v0.3.0 的失误）。
			ctx.slots.inject("settings.section", () => ctx.slots.register({
				name: "settings.section",
				id: "task-widget",
				order: 20,
				label: () => "任务小窗",
				inject: () => ({})
			}, TaskWidgetSettingsSection), "dsh-task-widget: settings section");
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
