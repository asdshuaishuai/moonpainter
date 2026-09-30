#!/bin/sh
# MoonPainter AI 修图 demo 构建脚本：
#   1. 引擎 → 经典 wasm（moonpainter.wasm，零 import 宿主中立）
#   2. demo 页逻辑 → MoonBit js 后端（demo.js，含 posoco agent 循环 + LLM 客户端）
#   3. index.html（仅壳；页面结构由 demo.js 内 MoonBit 代码构建）
#   4. Node headless 自检（mock 模型完整修图回合 × wasm 引擎）
#   5. npm SDK 冒烟（多会话 + 渲染 + 容器打包）
#   6. demo 测试（moon test --target js：工具面 + MVSL 闭环可达）
# 产物在 dist/；本地预览：cd dist && python3 -m http.server 8080
set -e
cd "$(dirname "$0")"

# 同 verify.sh：`moon test ... | tail -1` 在 set -e 下**不会**因测试失败而中止
# （管道的退出码是 tail 的）。demo 测试曾经这样失败着，而脚本照样报 PASS。
run_quiet() {
  log=$(mktemp /tmp/moonpainter-demo-step.XXXXXX)
  if ! "$@" > "$log" 2>&1; then
    echo "FAIL: $*"
    tail -30 "$log"
    rm -f "$log"
    exit 1
  fi
  tail -1 "$log"
  rm -f "$log"
}

echo "== 1/7 引擎 wasm 构建 =="
run_quiet moon build --target wasm

echo "== 2/7 demo（MoonBit js 后端）构建 =="
run_quiet moon build --target js

echo "== 3/7 组装 dist/ =="
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

echo "== 4/7 Node headless 自检（mock 模型 × wasm 引擎） =="
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

echo "== 5/7 npm SDK 冒烟（多会话 + 渲染 + 容器） =="
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
// 存→开闭环。容器是唯一事实源，只有存没有开等于存了个死文件；而断言不能
// 只看 ok —— 那证明不了内容真的回来了。先把文档改脏，再装回去，看两件事：
// 指纹回到存档前，且临时加的那层真的不见了。
mp.exec('add-rect x=200 y=150 w=50 h=30 fill=#FF0000FF name=__temp__');
const restored = mp.openMpd(saved.mpd_b64);
if (!restored.ok) throw new Error('openMpd failed: ' + restored.error);
if (restored.fingerprint !== saved.fingerprint) {
  throw new Error('openMpd 指纹不回原：' + restored.fingerprint + ' vs ' + saved.fingerprint);
}
if (mp.exec('list-layers').layers.some((l) => l.name === '__temp__')) {
  throw new Error('openMpd 返回 ok 但临时层还在——文档没有被真的恢复');
}
const h = mp.open();
mp.execOn(h, 'session-open full_image');
mp.execOn(h, 'new 50 50 uuid=second');
const r2 = mp.execOn(h, 'render 50');
if (!r2.ok) throw new Error('multi-session render failed');
mp.close(h);
const r3 = mp.execOn(h, 'new 1 1');
if (!r3.error || !r3.error.includes('未知会话句柄')) throw new Error('closed handle should fail');
console.log('NPM SDK SMOKE OK: multi-session + render + save/open round-trip all green');
"
cd ../..

echo "== 6/7 页面接线：HTML 引用的每个处理器的名字都出现过在注册表里 =="
# 运行时那条测试（demo_test「页面接线」）比这条强——它拿的是**真的拼出来的
# HTML**。但它只覆盖静态骨架 `app_html()`；图层列表与属性面板是
# `sb.write_string(...)` **动态拼**出来的，那段 HTML 只有在浏览器里点开某个
# 图层才会生成，测试拿不到。这里补一条源码级交叉核对，把两类引用都罩住。
#
# 这条不是理论上的：它当场抓到过 `__toggle_ai` —— HTML 里「🤖 AI 修图」按钮
# 与面板标题都写着 `onclick='globalThis.__toggle_ai()'`，而 `js_toggle_ai` 的
# FFI 早就写好、却没有任何地方调用它，点下去是 `__toggle_ai is not a function`。
python3 - <<'PYW'
import re, sys, glob
refs, regs = set(), set()
for path in glob.glob('demo/*.mbt'):
    for line in open(path, encoding='utf-8'):
        stripped = line.lstrip()
        if stripped.startswith('//'):
            continue                      # 注释里的示例不算引用
        refs.update(re.findall(r'globalThis\.(__[A-Za-z_][A-Za-z_0-9]*)', line))
        regs.update(re.findall(r'js_reg[0-9a-z]*\("(__[A-Za-z_][A-Za-z_0-9]*)"', line))
missing = sorted(refs - regs)
if missing:
    print('FAIL: 页面引用了没注册的处理器（点了就是 JS 报错）：', '、'.join(missing))
    sys.exit(1)
print('页面接线 OK（%d 个处理器引用全部有注册）' % len(refs))
PYW

echo "== 7/7 demo 测试（工具面 + MVSL 闭环可达；需 Node） =="
# 这条守住"引擎有能力"与"产品里的 AI 用得上"之间的缝：mock 模型经真实
# tool provider 驱动真实 wasm 引擎，跑完整 MVSL 闭环（普查→试选→装表→
# 影响/断言→渲染），并断言图像类回包走附件。
run_quiet moon test --target js -p moonpainter/demo

echo ""
echo "DEMO BUILD PASS ✓   本地预览: cd dist && python3 -m http.server 8080 → http://localhost:8080"
