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

# 步骤 slug 映射（散文里引用步骤用 `build_demo.sh#doc-tools` 这种形态；
# 编号会随插入步骤错位）。verify.sh 第 8 步的文档数字对账会核这张表。
# step-slugs: 1=wasm 2=demo-js 3=dist 4=node-headless 5=sdk-smoke 6=html-wiring 7=doc-tools 8=demo-test

echo "== 1/8 引擎 wasm 构建 =="
run_quiet moon build --target wasm

echo "== 2/8 demo（MoonBit js 后端）构建 =="
run_quiet moon build --target js

echo "== 3/8 组装 dist/ =="
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

echo "== 4/8 Node headless 自检（mock 模型 × wasm 引擎） =="
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

echo "== 5/8 npm SDK 冒烟（多会话 + 渲染 + 容器） =="
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

echo "== 6/8 页面接线：HTML 引用的每个处理器的名字都出现过在注册表里 =="
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

echo "== 7/8 文档里的工具数与边界与实际一致（数字漂了就红） =="
# 实测踩过：给工具面加了 3 个工具，`grep -c "make_tool("` 数出 52 ——
# 那个数里含 `fn make_tool(` **函数定义本身**，真实是 51，于是 README/AGENTS
# 被写错。文档里的数字是"我们做到了多少"的承诺（铁律 3），不能靠手数。
python3 - <<'PYD'
import re, sys
src = open('demo/paint_tools.mbt', encoding='utf-8').read()
n = len(set(re.findall(r'make_tool\(\s*"([a-z0-9_]+)"', src)))
bad = []
for path, pat, label in (
    ('README.md', r'\*\*(\d+) 个工具，MVSL', 'README 工具数'),
    ('AGENTS.md', r'手写子集\*\*（当前 (\d+) 个）', 'AGENTS 工具数'),
):
    text = open(path, encoding='utf-8').read()
    m = re.search(pat, text)
    if not m:
        bad.append('%s：找不到那句数字（是不是改写成了别的说法？）' % label)
    elif int(m.group(1)) != n:
        bad.append('%s：文档写 %s，实际 %d' % (label, m.group(1), n))
if bad:
    print('FAIL: ' + '；'.join(bad))
    sys.exit(1)
print('文档工具数 OK（README 与 AGENTS 都是 %d，与 paint_tool_defs 一致）' % n)

# ---- 引擎命令面 ↔ 工具面：两个方向都要对 ----
# 方向一（工具面指着谁）：`tool_cmd` 的每条 `Some("…")` 都必须是引擎真有的
# 命令。实测没人守这条：把 `tool_cmd("move")` 改成 `Some("move-layer")`，
# 工具在**运行时**才炸，而 `undispatched_tools()` 只查"臂在不在"。
# 方向二（谁够不着）：README 里那块名单必须**恰好**是
# 引擎命令 − 工具面覆盖，多写少写都红——它是诚实边界（铁律 3），
# 不能靠人眼对着两张表数。
eng = set(re.findall(r'add\(\s*\n?\s*"([a-z0-9\-]+)"', open('agent/tools.mbt', encoding='utf-8').read()))
tc = src[src.index('fn tool_cmd'):src.index('pub fn tool_line')]
covered = set(re.findall(r'Some\("([a-z0-9\-]+)"\)', tc))
r = open('README.md', encoding='utf-8').read()
try:
    seg = r[r.index('<!-- unreachable:begin -->'):r.index('<!-- unreachable:end -->')]
except ValueError:
    print('FAIL: README 里找不到 unreachable 标记（名单没被核对）')
    sys.exit(1)
named = set(re.findall(r'`([a-z][a-z0-9\-]+)`', seg))
unreach = eng - covered
if covered - eng:
    bad.append('工具面指着引擎里没有的命令：%s' % sorted(covered - eng))
if named != unreach:
    bad.append('README 的边界名单与实际差集不一致：名单多写 %s / 漏写 %s'
               % (sorted(named - unreach), sorted(unreach - named)))
m = re.search(r'够不着 (\d+) 条', seg)
if not m or int(m.group(1)) != len(unreach):
    bad.append('README 写的条数与实际差集不符（写 %s，实际 %d）'
               % (m.group(1) if m else '?', len(unreach)))
if bad:
    print('FAIL: ' + '；'.join(bad))
    sys.exit(1)
print('引擎/工具边界 OK（引擎 %d 条 − 工具面 %d 条 = 够不着 %d 条，与 README 一致）'
      % (len(eng), len(covered), len(unreach)))
PYD

echo "== 8/8 demo 测试（工具面 + MVSL 闭环可达；需 Node） =="
# 这条守住"引擎有能力"与"产品里的 AI 用得上"之间的缝：mock 模型经真实
# tool provider 驱动真实 wasm 引擎，跑完整 MVSL 闭环（普查→试选→装表→
# 影响/断言→渲染），并断言图像类回包走附件。
run_quiet moon test --target js -p moonpainter/demo

echo ""
echo "DEMO BUILD PASS ✓   本地预览: cd dist && python3 -m http.server 8080 → http://localhost:8080"
