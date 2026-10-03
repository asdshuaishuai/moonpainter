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
# step-slugs: 1=wasm 2=demo-js 3=dist 4=node-headless 5=clickthrough 6=sdk-smoke 7=html-wiring 8=doc-tools 9=demo-test

echo "== 1/9 引擎 wasm 构建 =="
run_quiet moon build --target wasm

echo "== 2/9 demo（MoonBit js 后端）构建 =="
run_quiet moon build --target js

echo "== 3/9 组装 dist/ =="
rm -rf dist
mkdir -p dist
cp _build/wasm/release/build/wasm/wasm.wasm dist/moonpainter.wasm 2>/dev/null ||
  cp _build/wasm/debug/build/wasm/wasm.wasm dist/moonpainter.wasm
cp _build/js/release/build/demo/demo.js dist/demo.js 2>/dev/null ||
  cp _build/js/debug/build/demo/demo.js dist/demo.js
cp demo/clickthrough.mjs dist/clickthrough.mjs
# 构建元数据进页面：**人做功能测试时必须知道自己在测哪一版**。没有它，
# 浏览器缓存住旧 `demo.js`/`moonpainter.wasm` 时人测的是旧引擎而不自知——
# 这正是"静默降级"在人这一侧的样子。三个量都可机器核对：
#   commit   = git HEAD 短 hash（工作区脏时带 `+`）
#   wasm_sha = 产物内容 sha256 前 12 位（与引擎自报的 `mp_version` 一起显示）
#   demo_sha = demo.js 内容 sha256 前 12 位，同时当 `<script src>` 的查询串
#              （查询串变了浏览器必定重新拉取，不会再拿旧的 demo.js）
MP_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
git diff --quiet -- . 2>/dev/null || MP_COMMIT="$MP_COMMIT+"
MP_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MP_WASM_SHA=$(python3 -c "import hashlib;print(hashlib.sha256(open('dist/moonpainter.wasm','rb').read()).hexdigest()[:12])")
MP_JS_SHA=$(python3 -c "import hashlib;print(hashlib.sha256(open('dist/demo.js','rb').read()).hexdigest()[:12])")
cat > dist/index.html << HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>MoonPainter · AI 修图 Demo</title>
<script>window.__MP_BUILD__ = { time: '$MP_NOW', commit: '$MP_COMMIT', wasm_sha: '$MP_WASM_SHA', demo_sha: '$MP_JS_SHA' };</script>
<script src="demo.js?v=$MP_JS_SHA" defer></script>
</head>
<body><div id="app">加载中…（需从 HTTP 服务访问，见 README）</div></body>
</html>
HTML
echo "构建元数据 commit=$MP_COMMIT wasm=$MP_WASM_SHA demo.js=$MP_JS_SHA time=$MP_NOW"
ls -la dist | awk 'NR>1 {print $5, $9}'

echo "== 4/9 Node headless 自检（mock 模型 × wasm 引擎） =="
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
echo "== 5/9 人类面点击穿透（真的 demo.js + 最小 DOM 壳，直接调页面处理器） =="
# 为什么值得单列一步：处理器那一层此前只有**源码级**证据（名字注册了、HTML 里
# 有按钮），"点了到底动不动引擎、动得对不对"只有人在浏览器里点得出来。
# 这里用哑 DOM 壳加载构建产物，调 `__poly_finish`/`__shape_ready`/`__rename`
# 这些页面处理器，再从引擎把状态**读回来**逐条断言。
# 它验的是「处理器 → do_* → 引擎」这条链；**DOM 本身的正确性仍需浏览器**。
# `|| true`：驱动器非零退出时，`set -e` 会在下面的解析**之前**把脚本干掉，
# 于是失败**一声不响**（实测只看到一行步骤标题）。判据必须自己说话，
# 由下面的 python 打印每条不过的断言并决定退出码。
CT_OUT=$(node clickthrough.mjs || true)
echo "$CT_OUT" | python3 -c "
import json, sys
# 驱动器会打出**两行** JSON：demo.js 自己的 headless 自检（import 时执行 main）
# 加穿透报告。取带 clickthrough 字段的那一行——按行号取会在 demo.js 多打一行
# 时静默解析错东西。
lines = [l for l in sys.stdin.read().split('\n') if l.strip()]
d = json.loads([l for l in lines if '\"clickthrough\"' in l][-1])
if not d.get('clickthrough'):
    bad = [c for c in d['checks'] if not c['ok']]
    print('FAIL: 点击穿透有 %d 条不过' % len(bad))
    for c in bad:
        print('  -', c['name'], '|', c['extra'][:200])
    sys.exit(1)
print('点击穿透 OK（%d 条断言：逐点形状/拖拽形状/点数下界/改名改坐标改标签/坏输入/重渲染/顶栏徽标两条）' % d['total'])
"
cd ..

echo "== 6/9 npm SDK 冒烟（多会话 + 渲染 + 容器） =="
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

echo "== 7/9 页面接线：引用的都注册了（含经参数传进拼 HTML helper 的），且注册的都被引用了（反方向：死处理器） =="
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
        # `globalThis.__x = …` 是**定义**（有些处理器就是从注入的 JS 里挂上去的，
        # 比如 headless 测试钩子），别把它算成引用。
        # ⚠️ 别写成 `(__\w*)(?!\s*=)`：负向前瞻会逼正则**回溯**，把名字截短一个
        # 字符好让断言成立——实测它把 `__headless_exec` 读成 `__headless_exe`
        # 并据此报"引用了没注册的处理器"。**判据自己念错名字**比不判更坏。
        # ⚠️ `globalThis.__MP_BUILD__`（构建元数据）**不是**处理器：它由
        # `build_demo.sh` 写进页面、被 `js_build_info` 读。不过滤的话门禁会把
        # "页面引用了没注册的处理器 __MP_BUILD__" 报出来——**判据自己念错名字
        # 比不判更坏**（同下面那条负向前瞻的注解）。过滤只认全大写常量这一种。
        for m in re.finditer(r'globalThis\.(__[A-Za-z_][A-Za-z_0-9]*)(\s*=)?', line):
            if m.group(1).isupper() or m.group(1).strip('_').isupper():
                continue                  # 数据常量，不是处理器
            if m.group(2):
                regs.add(m.group(1))
            else:
                refs.add(m.group(1))
        # 处理器名也可能是**经参数**传进拼 HTML 的辅助函数的
        # （`txt_input(…, "__rename", …)`）——那时源码里只有裸字符串字面量、
        # 没有 `globalThis.` 前缀。只扫前者会漏掉**整整一类**：实测新加的一批
        # 控件里，14 个名字只有 3 个带前缀（其余都走参数），而门禁报"37 个全部
        # 有注册"照样好看。这类前端断链的典型症状是"点了没反应"。
        refs.update(re.findall(r'"(__[A-Za-z_][A-Za-z_0-9]*)"', line))
        regs.update(re.findall(r'js_reg[0-9a-z]*\("(__[A-Za-z_][A-Za-z_0-9]*)"', line))
missing = sorted(refs - regs)
if missing:
    print('FAIL: 页面引用了没注册的处理器（点了就是 JS 报错）：', '、'.join(missing))
    sys.exit(1)

# **反方向也要问**：注册了却没人引用的处理器 = 死代码，或者"加了功能却没接上"
# （新加一批处理器时最常见：注册写了、页面/驱动器忘了引用，点了没反应的那一半
# 反过来就是"永远点不到的功能"）。⚠️ 判据必须**先剥掉注册声明本身**再找引用——
# 第一版没剥，于是每个处理器都被自己的注册行"引用"了一次，74 个全部合格，
# 判据等于没写。**判据自己满足自己**是最难发现的那种空判据。
# 驱动器（`demo/*.mjs`，clickthrough）里的引用**也算引用**：它是真的在调。
drivers = ''
for path in glob.glob('demo/*.mjs'):
    for line in open(path, encoding='utf-8'):
        if line.lstrip().startswith('//'):
            continue
        drivers += line
orphan = []
for name in sorted(regs):
    used = False
    pat = re.compile(r'(globalThis\.)?' + re.escape(name) + r'\b')
    for path in glob.glob('demo/*.mbt'):
        for line in open(path, encoding='utf-8'):
            if line.lstrip().startswith('//'):
                continue
            cleaned = re.sub(r'js_reg[0-9a-z]*\("__[A-Za-z_][A-Za-z_0-9]*"', '', line)
            if pat.search(cleaned):
                used = True
                break
        if used:
            break
    if not used and pat.search(drivers):
        used = True
    if not used:
        orphan.append(name)
if orphan:
    print('FAIL: 注册了却没人引用的处理器（死代码 / 加了功能没接上）：', '、'.join(orphan))
    sys.exit(1)
print('页面接线 OK（%d 个处理器引用全部有注册，且 %d 个注册的都有引用）' % (len(refs), len(regs)))
PYW

echo "== 8/9 文档里的工具数、AI/人类两条边界与实际一致（数字漂了就红） =="
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

# 人类前端是**另一条边界**：上面那块管的是「AI 工具面 ↔ 引擎」，这块管
# 「人类前端 ↔ 引擎」。此前没人管——实测 63 条命令里人类前端只走得到 35 条，
# 而 README 的「绘制」一行读起来像"产品支持画多边形"。
# 判据（名单 + 理由 + 数字，脚本里逐条自证过反例）：
# ① 人类可达集合 = 源码里作为字符串**首词**出现的命令（不许写上去却够不着）；
# ② 引擎 − 人类可达 == README 名单（不重不漏、不许幽灵命令）；
# ③ 每条必须写理由（空理由 = 没做过的决定）；④ 散文里的条数要对得上。
run_quiet python3 ui_audit.py

# ---- 功能自检清单的条数也要对账 ----
# 自检面板是"人做功能级测试"的入口，README 里写着它有多少条。**数字进散文就
# 没人管**（铁律 3）——所以条数从源码数出来（`SCase` 的字面量 `name:`），
# 与 README 那句逐字对。清单加一条、README 忘了改，这一步红。
python3 - <<'PYD'
import re, sys
src = open('demo/selfcheck.mbt', encoding='utf-8').read()
n = len(re.findall(r'\n\s+name: "', src))
m = re.search(r'点一下跑 \*\*(\d+) 条\*\*功能清单', open('README.md', encoding='utf-8').read())
if not m:
    print('FAIL: README 里找不到「点一下跑 **N 条**功能清单」那句（改写法要同步这里）')
    sys.exit(1)
if int(m.group(1)) != n:
    print('FAIL: README 写自检 %s 条，实际 %d 条' % (m.group(1), n))
    sys.exit(1)
if n < 20:
    print('FAIL: 自检清单只剩 %d 条（少于 20 条基本等于没有覆盖面）' % n)
    sys.exit(1)
print('功能自检条数 OK（README 与实际都是 %d 条）' % n)
PYD

echo "== 9/9 demo 测试（工具面 + MVSL 闭环可达；需 Node） =="
# 这条守住"引擎有能力"与"产品里的 AI 用得上"之间的缝：mock 模型经真实
# tool provider 驱动真实 wasm 引擎，跑完整 MVSL 闭环（普查→试选→装表→
# 影响/断言→渲染），并断言图像类回包走附件。
run_quiet moon test --target js -p moonpainter/demo

echo ""
echo "DEMO BUILD PASS ✓   人做功能测试: ./serve_demo.sh → http://127.0.0.1:8137/"
echo "                    （「点哪里 → 期望什么」的清单见 demo/TESTING.md）"
