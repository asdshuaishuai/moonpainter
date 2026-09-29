#!/bin/sh
# MoonPainter AI 修图 demo 构建脚本：
#   1. 引擎 → 经典 wasm（moonpainter.wasm，零 import 宿主中立）
#   2. demo 页逻辑 → MoonBit js 后端（demo.js，含 posoco agent 循环 + LLM 客户端）
#   3. index.html（仅壳；页面结构由 demo.js 内 MoonBit 代码构建）
#   4. Node headless 自检（mock 模型完整修图回合 × wasm 引擎）
#   5. npm SDK 冒烟（多会话 + 渲染 + 容器打包）
# 产物在 dist/；本地预览：cd dist && python3 -m http.server 8080
set -e
cd "$(dirname "$0")"

echo "== 1/5 引擎 wasm 构建 =="
moon build --target wasm 2>&1 | tail -1

echo "== 2/5 demo（MoonBit js 后端）构建 =="
moon build --target js 2>&1 | tail -1

echo "== 3/5 组装 dist/ =="
rm -rf dist
mkdir -p dist
cp _build/wasm/release/build/wasm/wasm.wasm dist/moonpainter.wasm 2>/dev/null ||
  cp _build/wasm/debug/build/wasm/wasm.wasm dist/moonpainter.wasm
cp _build/js/release/build/demo/demo.js dist/demo.js 2>/dev/null ||
  cp _build/js/debug/build/demo/demo.js dist/demo.js
cat > dist/index.html << 'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>MoonPainter · AI 修图 Demo</title>
<script src="demo.js" defer></script>
</head>
<body><div id="app">加载中…（需从 HTTP 服务访问，见 README）</div></body>
</html>
HTML
ls -la dist | awk 'NR>1 {print $5, $9}'

echo "== 4/5 Node headless 自检（mock 模型 × wasm 引擎） =="
cd dist
NODE_OUT=$(node demo.js)
echo "$NODE_OUT" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['headless_selftest'] is True
assert d.get('engine_ok') is True, d
assert d.get('version'), d
print('headless selftest OK:', d)
"
cd ..

echo "== 5/5 npm SDK 冒烟（多会话 + 渲染 + 容器） =="
cp _build/wasm/debug/build/wasm/wasm.wasm npm/moonpainter-sdk/moonpainter.wasm
cd npm/moonpainter-sdk
node --input-type=module -e "
import { loadEngine } from './index.js';
const mp = await loadEngine();
const v = mp.version();
if (v.engine !== 'moonpainter') throw new Error('engine mismatch');
await mp.exec('session-open full_image');
mp.exec('new 300 200 uuid=npm-verify');
mp.exec('add-rect x=10 y=10 w=120 h=80 fill=#2E6FE8FF name=card');
const r = mp.render(300);
if (!r.ok || !r.png_b64.startsWith('iVBOR')) throw new Error('render failed');
const saved = mp.saveMpd();
if (!saved.ok) throw new Error('save failed');
const h = mp.open();
mp.execOn(h, 'session-open full_image');
mp.execOn(h, 'new 50 50 uuid=second');
const r2 = mp.execOn(h, 'render 50');
if (!r2.ok) throw new Error('multi-session render failed');
mp.close(h);
const r3 = mp.execOn(h, 'new 1 1');
if (!r3.error || !r3.error.includes('未知会话句柄')) throw new Error('closed handle should fail');
console.log('NPM SDK SMOKE OK: multi-session + render + save all green');
"
cd ../..
echo ""
echo "DEMO BUILD PASS ✓   本地预览: cd dist && python3 -m http.server 8080 → http://localhost:8080"
