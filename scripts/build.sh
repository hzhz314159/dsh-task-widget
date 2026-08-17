#!/bin/bash
# dsh-task-widget — 免编译交付：源码即产物（纯 JS ESM + 原生 PS1 渲染器，无 TS/tsdown 步骤）。
# 仅做产物完整性校验，保证注入器 dev_build_plugin 流水线可用。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== dsh-task-widget 产物校验 ==="
[ -f lib/index.js ] || { echo "build: lib/index.js missing" >&2; exit 1; }
[ -f lib/client.js ] || { echo "build: lib/client.js missing" >&2; exit 1; }
[ -f widget/widget.ps1 ] || { echo "build: widget/widget.ps1 missing" >&2; exit 1; }
head -c 3 widget/widget.ps1 | od -An -tx1 | grep -q "ef bb bf" || { echo "build: widget/widget.ps1 缺少 UTF-8 BOM（Windows PowerShell 5.1 需要）" >&2; exit 1; }
node -e "JSON.parse(require('fs').readFileSync('package.json','utf8'));console.log('package.json OK')"
grep -q '__ModuleLoader__' lib/client.js || { echo "build: lib/client.js 缺 __ModuleLoader__ 特征" >&2; exit 1; }
echo "=== 校验通过（无编译步骤） ==="
