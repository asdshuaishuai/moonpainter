#!/bin/sh
# MoonPainter 一键验证门（AGENTS.md 口径）：
#   1. moon check 零错误零警告（-W error 由 moon check 默认把 warning 计数呈现，这里断言输出无 Warning）
#   2. moon test --target native 全绿
#   3. wasm-gc 可检 + 可测（引擎纯字节进出的背书）
#   4. CLI 子进程端到端：管道喂命令 → 落盘 .mpd
#   5. 独立外部验证：系统 unzip 校验容器（不用引擎自证）
#   6. open→save 字节一致（确定性 pack 的进程级闭环）
#   7. MVSL 编辑表命令面：安装 → impact → 断言 fail → 随容器往返
# 任何一步失败即非零退出。
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d /tmp/moonpainter-verify.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

# 跑一条输出很长的命令，失败即中止。
#
# 为什么不直接写 `cmd | tail -1`：**管道的退出码是最后一个命令（tail）的**，
# 所以哪怕 moon test 失败，`set -e` 也不会中止——门禁会带着失败的测试报 PASS。
# 本仓库真的踩过这个坑：demo 测试明明断言失败，build_demo.sh 照样打印
# "DEMO BUILD PASS ✓"。这类"假门禁"比没有门禁更坏，因为它给的是虚假的安心。
run_quiet() {
  log="$OUT/step.log"
  if ! "$@" > "$log" 2>&1; then
    echo "FAIL: $*"
    tail -30 "$log"
    exit 1
  fi
  tail -1 "$log"
}

echo "== 1/11 moon check =="
CHECK_OUT=$(moon check 2>&1)
echo "$CHECK_OUT" | tail -1
if echo "$CHECK_OUT" | grep -q "Warning"; then
  echo "FAIL: moon check 存在 Warning"
  echo "$CHECK_OUT" | grep -A4 "Warning" | head -20
  exit 1
fi

echo "== 2/11 moon test --target native =="
run_quiet moon test --target native

echo "== 3/11 wasm-gc 可检 + 测试（引擎纯字节进出的背书） =="
# wasm-gc 的 check 也要查 warning：铁律 1 的"0 error / 0 warning"不分 target。
# （步骤 1 查的是默认 target；target 特有的 warning 只能在这里抓。）
WASM_CHECK=$(moon check --target wasm-gc 2>&1)
echo "$WASM_CHECK" | tail -1
if echo "$WASM_CHECK" | grep -q "Warning"; then
  echo "FAIL: moon check --target wasm-gc 存在 Warning"
  echo "$WASM_CHECK" | grep -A4 "Warning" | head -20
  exit 1
fi
run_quiet moon test --target wasm-gc

echo "== 4/11 CLI 子进程端到端 =="
# 生成最小 2×2 RGBA PNG（python3 标准库，zlib+struct 手工构造）作为位图资产
PNG_B64=$(python3 -c "
import zlib, struct, base64
def chunk(tag, data):
    c = tag + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
raw = b''
for y in range(2):
    raw += b'\\x00'
    for x in range(2):
        raw += bytes([0xCC, 0x33, 0x66, 0xFF])
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw))
png += chunk(b'IEND', b'')
print(base64.b64encode(png).decode())
")
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=verify-001' \
  'add-rect x=0 y=0 w=320 h=240 fill=#1B2A41FF name=bg tag=background' \
  'add-ellipse x=100 y=50 w=120 h=120 lgrad=#FF7A45FF,#2E6FE8FF,0,0,1,1 blend=screen name=orb' \
  "add-image x=210 y=160 w=70 h=50 b64=$PNG_B64 name=badge" \
  'flip orb none' \
  'lint' \
  'render 320' \
  'render 320 overlay=1' \
  "save-mpd $OUT/verify.mpd" \
  ':exit' \
  | moon run --target native cli > "$OUT/cli.log"
tail -3 "$OUT/cli.log"
grep -q '"op":"add-image"' "$OUT/cli.log" || { echo "FAIL: add-image 未成功"; exit 1; }
grep -q '"op":"lint","violations":0' "$OUT/cli.log" || { echo "FAIL: lint 非零违规"; exit 1; }
grep -q '"op":"save-mpd"' "$OUT/cli.log" || { echo "FAIL: save-mpd 未成功"; cat "$OUT/cli.log"; exit 1; }
test -f "$OUT/verify.mpd" || { echo "FAIL: 落盘文件不存在"; exit 1; }
# 渐变端点在命令面上是**归一化 0..1**，而同一条命令的 x/y/w/h 是像素——
# 这个不一致极易写错。写错后引擎一切正常：层建好了、渲染成功了、颜色也确实是
# 渐变，只是几乎看不出过渡（把 60,40 写进端点的实测结果与纯色无异）。
# 这类「看起来生效了」的静默错误必须在入口拦下，并给出换算后的建议值。
printf '%s\n' \
  'session-open full_image' \
  'new 160 180 uuid=verify-grad' \
  'add-rect x=0 y=0 w=160 h=180 lgrad=#E8B23CFF,#B4361EFF,0,0,60,40 name=px' \
  ':exit' \
  | moon run --target native cli > "$OUT/grad.log"
grep -q '渐变端点必须落在 0..1' "$OUT/grad.log" || { echo "FAIL: 像素坐标写进渐变端点未被拒绝（静默变成纯色）"; exit 1; }
grep -q '0.375' "$OUT/grad.log" || { echo "FAIL: 拒绝信息未给出换算建议"; exit 1; }

echo "== 5/11 独立外部验证（系统 unzip，非引擎自证） =="
unzip -t "$OUT/verify.mpd" > /dev/null && echo "unzip -t: 容器完整性 OK"
unzip -l "$OUT/verify.mpd" | grep -q "meta/design.json"  || { echo "FAIL: 缺 meta/design.json"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "previews/flat.png" || { echo "FAIL: 缺 flat 预览"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "assets/sha256/"    || { echo "FAIL: 缺资产层"; exit 1; }
unzip -p "$OUT/verify.mpd" manifest.json | grep -q '"format":"moonpainter.mpd"' || { echo "FAIL: manifest 格式标识不对"; exit 1; }
echo "manifest/预览/资产三件套齐全"
# 元参数层可直接文本阅读（双层容器的核心承诺）
unzip -p "$OUT/verify.mpd" meta/design.json | head -c 200; echo " …"

echo "== 6/11 open → save 字节一致（进程级确定性闭环） =="
printf '%s\n' \
  'session-open full_image' \
  "open-mpd $OUT/verify.mpd" \
  "save-mpd $OUT/resave.mpd" \
  ':exit' \
  | moon run --target native cli > "$OUT/reopen.log"
grep -q '"op":"save-mpd"' "$OUT/reopen.log" || { echo "FAIL: reopen save 失败"; cat "$OUT/reopen.log"; exit 1; }
if cmp -s "$OUT/verify.mpd" "$OUT/resave.mpd"; then
  echo "open→save 字节一致 OK（$(wc -c < "$OUT/verify.mpd" | tr -d ' ') 字节）"
else
  echo "FAIL: reopen 后再打包字节不一致"
  exit 1
fi

# `open-mpd-b64`：SDK 门面（npm/moonpainter-sdk 的 openMpd）走的就是这条。
# 第 8 步只用**裸命令**戳分发，证明不了它真的能载入；上面那条字节一致走的是
# `open-mpd <文件>` 变体。这条把 b64 变体也钉住：喂真实载荷、比对指纹。
# 存档指纹来自**另一个进程**：只比对"载入回包 vs 载入后的 fingerprint"是自洽的，
# 万一载入什么都没做两边也会一致。再加一个独立判据：载入前故意 `new 16 16`，
# 载入后画布宽度必须不再是 16（证明文档真的被换掉了，而不只是返回了 ok）。
SAVED_JSON=$(printf '%s\n' 'session-open full_image' "open-mpd $OUT/verify.mpd" \
  'save-mpd-b64' | moon run --target native cli \
  | python3 -c "import json,sys; d=[json.loads(l) for l in sys.stdin if 'mpd_b64' in l][0]; print(d['mpd_b64'], d['fingerprint'])")
SAVED_B64=${SAVED_JSON%% *}
SAVED_FP=${SAVED_JSON##* }
test -n "$SAVED_B64" && test -n "$SAVED_FP" || { echo "FAIL: 取不到 mpd_b64/fingerprint"; exit 1; }
printf '%s\n' 'session-open full_image' 'new 16 16' \
  "open-mpd-b64 $SAVED_B64" 'fingerprint' 'inspect' \
  | moon run --target native cli > "$OUT/b64open.log"
python3 - "$OUT/b64open.log" "$SAVED_FP" <<'PYX'
import json, sys
opened = fp = insp = None
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    if d.get("op") == "open-mpd-b64":
        opened = d
    if d.get("op") == "fingerprint":
        fp = d
    if d.get("op") == "inspect":
        insp = d
want = sys.argv[2]
if not opened or not opened.get("ok"):
    print("FAIL: open-mpd-b64 没成功：", opened)
    sys.exit(1)
if opened.get("fingerprint") != want:
    print("FAIL: 载入回包指纹 != 存档进程的指纹：", opened.get("fingerprint"), want)
    sys.exit(1)
if not fp or fp.get("fingerprint") != want:
    print("FAIL: 载入后 session 的指纹 != 存档指纹：", fp, want)
    sys.exit(1)
w = (insp or {}).get("manifest", {}).get("canvas", {}).get("w")
if w == 16:
    print("FAIL: 载入前是 16 宽，载入后还是 16 —— 文档没被换掉")
    sys.exit(1)
print("open-mpd-b64 载入 OK（指纹 %s…，画布 %s 宽）" % (want[:12], w))
PYX

echo "== 7/11 MVSL 编辑表命令面 + 渲染管线闭环（安装 → render/impact 同图 → 断言 → 软边界/空操作/违约 lint → 容器往返） =="
# canonical 编辑表由引擎自己产出（不手写 JSON——少一个大括号就会得到
# 指不到病根的解析错误）。这里用固定文本：字段序即 canonical 字段序。
MVSL_PROG='{"version":1,"ops":[{"id":"e1","kind":"recolor","sel":{"basis":"base","expr":{"t":"geo","shape":"rect","w":{"x":0,"y":0,"w":160,"h":240,"feather":0}}},"amount":1,"hue_deg":120,"temp_kelvin":0,"relight_gain":1,"refine":[],"note":"","evidence":null}],"guards":[{"id":"g1","sel":{"basis":"base","expr":{"t":"geo","shape":"rect","w":{"x":160,"y":0,"w":160,"h":240,"feather":0}}},"max_de":0.001,"max_changed_ratio":0}]}'
MVSL_B64=$(printf '%s' "$MVSL_PROG" | base64 | tr -d '\n')
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=mvsl-verify' \
  'add-rect x=0 y=0 w=320 h=240 fill=#1E5ACCFF name=bg' \
  "mvsl-set $MVSL_B64" \
  'render 320' \
  'mvsl-impact max=160' \
  'mvsl-assert' \
  "save-mpd $OUT/mvsl.mpd" \
  ':exit' \
  | moon run --target native cli > "$OUT/mvsl.log"
grep -q '"op":"mvsl-set"' "$OUT/mvsl.log" || { echo "FAIL: mvsl-set 未成功"; exit 1; }
grep -q '"op":"mvsl-impact"' "$OUT/mvsl.log" || { echo "FAIL: mvsl-impact 未成功"; exit 1; }
# 左半边 160x240 必须被改动，且几何硬边 + 去污染 → 选区外泄漏率 0
grep -q '"changed":38400' "$OUT/mvsl.log" || { echo "FAIL: impact 改动像素数不对"; exit 1; }
# 精确匹配：子串 `"leak_ratio":0` 会被 `"leak_ratio":0.0279` 骗过
# （泄漏率在 [0,1) 的任何值都能通过），必须锚住字段值的结尾。
grep -Eq '"leak_ratio":0[,}]' "$OUT/mvsl.log" || { echo "FAIL: 选区外有泄漏"; exit 1; }
# **编辑表真的进了渲染管线**：render 与 mvsl-impact 必须给出同一张最终图。
# 这是本轮最要紧的一条断言——它把"编辑表只是一份被存下来的数据"和
# "编辑表真的改变了渲染结果"区分开。
#
# 口径要挑对：这里 canvas 320x240、`mvsl-impact max=160` 会**降采样**，
# 而 `render 320` 是全分辨率——所以要比的是 impact 的 **`full_sha256`**
# （全分辨率结果），不是 `result_sha256`（回吐那张 160 宽预览的 sha）。
# 这条判据此前**靠错误才成立**：老代码的 `result_sha256` 哈希的就是全分辨率
# `out`（与回吐的 PNG 对不上，但恰好与 render 相等），于是
# "impact 的 result == render"看起来一直是绿的。**一个判据要问清它比的是
# 哪两张图**，否则修好实现反而会把它弄红。
RSHA=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/mvsl.log" | head -1)
FSHA=$(sed -n 's/.*"full_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/mvsl.log" | head -1)
ISHA=$(sed -n 's/.*"result_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/mvsl.log" | head -1)
if [ -z "$RSHA" ]; then echo "FAIL: render 回包缺 render_sha256"; exit 1; fi
if [ -z "$FSHA" ]; then echo "FAIL: mvsl-impact 回包缺 full_sha256"; exit 1; fi
if [ -z "$ISHA" ]; then echo "FAIL: mvsl-impact 回包缺 result_sha256"; exit 1; fi
if [ "$RSHA" != "$FSHA" ]; then
  echo "FAIL: render($RSHA) 与 impact 全分辨率结果($FSHA) 不是同一张图——编辑表没进渲染管线"
  exit 1
fi
# **sha 必须真的是回吐那张 PNG 的 sha**：拿 b64 解出来自己算一遍，
# 而不是信信封里的另一个字段。预览被降采样过，所以它**应当**与全分辨率不同。
IPNG=$(sed -n 's/.*"result_png_b64":"\([A-Za-z0-9+/=]*\)".*/\1/p' "$OUT/mvsl.log" | head -1)
if [ -z "$IPNG" ]; then echo "FAIL: mvsl-impact 回包缺 result_png_b64"; exit 1; fi
IPNG_SHA=$(printf '%s' "$IPNG" | base64 -d | shasum -a 256 | cut -d' ' -f1)
if [ "$IPNG_SHA" != "$ISHA" ]; then
  echo "FAIL: result_sha256($ISHA) 不是回吐 PNG 的 sha($IPNG_SHA)——信封里两个字段不是同一张图"
  exit 1
fi
if [ "$ISHA" = "$FSHA" ]; then
  echo "FAIL: 预览($ISHA) 与全分辨率结果相同——max=160 应当降采样了，判据大概没在测该测的东西"
  exit 1
fi
# 保护断言命中右半边（未改动）→ 通过；再验一条必然违反的断言
grep -q '"op":"mvsl-assert","guards":1,"violations":0' "$OUT/mvsl.log" || { echo "FAIL: 合法程序被断言拦下"; exit 1; }
MVSL_BAD='{"version":1,"ops":[{"id":"e1","kind":"recolor","sel":{"basis":"base","expr":{"t":"geo","shape":"rect","w":{"x":0,"y":0,"w":320,"h":240,"feather":0}}},"amount":1,"hue_deg":120,"temp_kelvin":0,"relight_gain":1,"refine":[],"note":"","evidence":null}],"guards":[{"id":"g1","sel":{"basis":"base","expr":{"t":"geo","shape":"rect","w":{"x":0,"y":0,"w":160,"h":240,"feather":0}}},"max_de":0.001,"max_changed_ratio":0}]}'
MVSL_BAD_B64=$(printf '%s' "$MVSL_BAD" | base64 | tr -d '\n')
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=mvsl-verify-bad' \
  'add-rect x=0 y=0 w=320 h=240 fill=#1E5ACCFF name=bg' \
  "mvsl-set $MVSL_BAD_B64" \
  'mvsl-assert' \
  ':exit' \
  | moon run --target native cli > "$OUT/mvsl_bad.log"
grep -q '"error":"断言未通过（2 条）' "$OUT/mvsl_bad.log" || { echo "FAIL: 侵犯保护区的程序未被断言拦下"; exit 1; }
# 编辑表随容器往返（状态不是历史：重开后必须原样在编辑表里）
unzip -p "$OUT/mvsl.mpd" meta/mvsl.json | grep -q '"hue_deg":120' || { echo "FAIL: 容器缺编辑表"; exit 1; }
unzip -p "$OUT/mvsl.mpd" manifest.json | grep -q '"render_contract":1' || { echo "FAIL: manifest 缺 MVSL 版本块"; exit 1; }

# 图层级作用域 `layer=`：只改指定的那一层。
# 两层同色，左半 l1 被引用、右半 l2 没有——所以"左半变、右半不变"是精确判据，
# 而不是"有没有差异"这种弱判据。取值用等值比较，不做子串匹配（铁律 11）。
#
# **选择子必须是全图（w=64）**：一开始写成了 w=32（只盖左半），于是"右半没变"
# 在**任何**情况下都成立——删掉 layer= 它照样通过，是一条空断言。全图选择子
# 才有区分度：不带 layer 时左右都变，带 layer 时只有左变。
SCOPE_PROG='{"version":1,"ops":[{"id":"e1","kind":"recolor","sel":{"basis":"base","expr":{"t":"geo","shape":"rect","w":{"x":0,"y":0,"w":64,"h":32,"feather":0}}},"amount":1,"hue_deg":120,"temp_kelvin":0,"relight_gain":1,"layer":"l1","refine":[],"note":"","evidence":null}],"guards":[]}'
SCOPE_B64=$(printf '%s' "$SCOPE_PROG" | base64 | tr -d '\n')
printf '%s\n' \
  'session-open full_image' \
  'new 64 32 uuid=mvsl-scope' \
  'add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF id=l1' \
  'add-rect x=32 y=0 w=32 h=32 fill=#FF0000FF id=l2' \
  "mvsl-set $SCOPE_B64" \
  'sample 16 16' \
  'sample 48 16' \
  | moon run --target native cli > "$OUT/scope.log"
grep -q '"op":"mvsl-set"' "$OUT/scope.log" || { echo "FAIL: 图层级编辑表装不上"; cat "$OUT/scope.log"; exit 1; }
SCOPE_COLORS=$(grep -o '"color":"#[0-9A-F]*"' "$OUT/scope.log")
SCOPE_LEFT=$(printf '%s\n' "$SCOPE_COLORS" | sed -n '1p')
SCOPE_RIGHT=$(printf '%s\n' "$SCOPE_COLORS" | sed -n '2p')
if [ "$SCOPE_RIGHT" != '"color":"#FF0000FF"' ]; then
  echo "FAIL: 图层级作用域越界——未被引用的层被改了（右半 $SCOPE_RIGHT）"
  exit 1
fi
if [ "$SCOPE_LEFT" = '"color":"#FF0000FF"' ]; then
  echo "FAIL: 图层级算子没有生效——被引用的层颜色未变（左半 $SCOPE_LEFT）"
  exit 1
fi
# 引用不存在的层必须被拒绝（否则那个算子在表里、跑得通、什么都不改）
printf '%s\n' \
  'session-open full_image' \
  'new 64 32 uuid=mvsl-scope-bad2' \
  'add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF id=l1' \
  "mvsl-set $(printf '%s' "${SCOPE_PROG/l1/nope}" | base64 | tr -d '\n')" \
  | moon run --target native cli > "$OUT/scope_bad.log"
grep -q '"error":"算子引用了不存在的图层' "$OUT/scope_bad.log" || { echo "FAIL: 引用不存在的层未被拒绝"; cat "$OUT/scope_bad.log"; exit 1; }
echo "图层级作用域 OK（左半被改、右半逐位不变；不存在的层被拒）"
printf '%s\n' \
  'session-open full_image' \
  "open-mpd $OUT/mvsl.mpd" \
  'mvsl-show' \
  "save-mpd $OUT/mvsl-resave.mpd" \
  ':exit' \
  | moon run --target native cli > "$OUT/mvsl_reopen.log"
grep -q '"ops":1' "$OUT/mvsl_reopen.log" || { echo "FAIL: 重开后编辑表丢失"; exit 1; }
cmp -s "$OUT/mvsl.mpd" "$OUT/mvsl-resave.mpd" || { echo "FAIL: 带编辑表的容器 open→save 字节不一致"; exit 1; }
# 预览必须走编辑表：同一文档，装与不装编辑表的 flat 预览必须不同
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=mvsl-verify' \
  "open-mpd $OUT/mvsl.mpd" \
  'mvsl-clear' \
  "save-mpd $OUT/mvsl-noprog.mpd" \
  ':exit' \
  | moon run --target native cli > /dev/null
unzip -p "$OUT/mvsl.mpd" previews/flat.png > "$OUT/flat_prog.png"
unzip -p "$OUT/mvsl-noprog.mpd" previews/flat.png > "$OUT/flat_noprog.png"
if cmp -s "$OUT/flat_prog.png" "$OUT/flat_noprog.png"; then
  echo "FAIL: 带/不带编辑表的预览字节相同——预览漏渲染了编辑表"
  exit 1
fi
# 软选择子的过渡带**不是泄漏**：leak 判据是选择子支撑集（w>0），不是连通域
# 证书阈值 0.5。用真实渐变 + 柔边色彩窗覆盖这一条——上面那个泄漏断言用的是
# 几何硬边选择子（权重非 0 即 1），旧判据下也是 0，**根本测不到软边界**。
MVSL_SOFT_SEL='{"t":"color","w":{"h":50,"hw":30,"s":0.14,"sh":0.1,"l":0.64,"lh":0.25,"feather":0.4}}'
MVSL_SOFT='{"version":1,"ops":[{"id":"e1","kind":"recolor","sel":{"basis":"base","expr":'"$MVSL_SOFT_SEL"'},"amount":1,"hue_deg":-70,"temp_kelvin":0,"relight_gain":1,"refine":[],"note":"","evidence":null}],"guards":[]}'
MVSL_SOFT_B64=$(printf '%s' "$MVSL_SOFT" | base64 | tr -d '\n')
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=mvsl-soft' \
  'add-rect x=0 y=0 w=320 h=240 fill=#1E5ACCFF name=bg' \
  'add-rect x=0 y=0 w=160 h=180 lgrad=#F2C14EFF,#A8221AFF,0,0,1,1 name=g' \
  "mvsl-set $MVSL_SOFT_B64" \
  'mvsl-impact max=120' \
  ':exit' \
  | moon run --target native cli > "$OUT/mvsl_soft.log"
grep -Eq '"leak_ratio":0[,}]' "$OUT/mvsl_soft.log" || { echo "FAIL: 软过渡带被误判成泄漏"; exit 1; }
grep -Eq '"changed_total":[1-9]' "$OUT/mvsl_soft.log" || { echo "FAIL: 软窗场景本应产生改动（断言在拿空操作通过）"; exit 1; }
# 编辑表 lint 必须说出「装了却什么都没改」——这是一类**每个命令都返回 ok**
# 的失败：mvsl-set ok、impact ok、assert 0 违规、render ok，只有 lint 会报。
# 用一条必然不命中的色窗（绿，而画布只有蓝）。
MVSL_DEAD='{"version":1,"ops":[{"id":"e1","kind":"recolor","sel":{"basis":"base","expr":{"t":"color","w":{"h":145,"hw":25,"s":0.18,"sh":0.08,"l":0.7,"lh":0.15,"feather":0.1}}},"amount":1,"hue_deg":120,"temp_kelvin":0,"relight_gain":1,"refine":[],"note":"","evidence":null}],"guards":[]}'
MVSL_DEAD_B64=$(printf '%s' "$MVSL_DEAD" | base64 | tr -d '\n')
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=mvsl-dead' \
  'add-rect x=0 y=0 w=320 h=240 fill=#1E5ACCFF name=bg' \
  "mvsl-set $MVSL_DEAD_B64" \
  'mvsl-impact' \
  'lint' \
  ':exit' \
  | moon run --target native cli > "$OUT/mvsl_dead.log"
grep -q '"changed_total":0' "$OUT/mvsl_dead.log" || { echo "FAIL: 该选择子本就不该命中"; exit 1; }
grep -q '整张图逐位未变' "$OUT/mvsl_dead.log" || { echo "FAIL: lint 未报出空操作编辑表（静默失败）"; exit 1; }
# 断言被违反时 lint 也必须报（用户的「别动 XX」不许静默失守）
printf '%s\n' \
  'session-open full_image' \
  'new 320 240 uuid=mvsl-dead2' \
  'add-rect x=0 y=0 w=320 h=240 fill=#1E5ACCFF name=bg' \
  "mvsl-set $MVSL_BAD_B64" \
  'lint' \
  ':exit' \
  | moon run --target native cli > "$OUT/mvsl_lintbad.log"
grep -q '保护断言被违反' "$OUT/mvsl_lintbad.log" || { echo "FAIL: lint 未报出被违反的保护断言"; exit 1; }
echo "MVSL：安装/render≡impact/断言/软过渡带不算泄漏/容器往返/预览走编辑表/lint 空操作与违约 全部 OK"

echo "== 8/11 命令字典与分发一致（铁律 6） =="
# 字典（agent/tools.mbt，经 list-tools 输出）与分发（session.mbt 的命令 match）
# 是两张**手写表**，铁律 6 要求同步，但此前没有任何自动化守着。
# demo 侧就栽在这上面：10 个工具"注册了却接不上"，而人类走前端按钮、测试
# 又直接调底层命令，两条路都绕开了缺口，于是坏了很多没人发现。这里用真实
# 调用逐个戳：**注册进 help 的每个命令都必须真的可达**。
printf '%s\n' 'session-open full_image' 'list-tools' \
  | moon run --target native cli > "$OUT/catalog.log" 2>&1
python3 - "$OUT/catalog.log" > "$OUT/cmdlist.txt" <<'PYEOF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if '"tools"' not in line:
        continue
    for t in json.loads(line)["tools"]:
        print(t["name"])
PYEOF
test -s "$OUT/cmdlist.txt" || { echo "FAIL: list-tools 没吐出命令表"; exit 1; }
{ printf '%s\n' 'session-open full_image' 'new 16 16'; cat "$OUT/cmdlist.txt"; } \
  | moon run --target native cli > "$OUT/probe.log" 2>&1
python3 - "$OUT/probe.log" "$OUT/cmdlist.txt" <<'PYEOF'
import json, sys
bad = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if "未知命令" in str(d.get("error", "")):
        bad.append(d["error"])
n = len([l for l in open(sys.argv[2], encoding="utf-8") if l.strip()])
if bad:
    print("FAIL: 字典里注册了却不可达的命令：")
    for b in bad:
        print("   ", b)
    sys.exit(1)
print(f"命令字典一致性 OK（{n} 个命令逐个可达）")
PYEOF

echo "== 9/11 命令参数下界自检（读 tokens[N] 之前必须先卡住 N） =="
# 每个命令开头的 `if tokens.length() < K` 是唯一的越界防线。K 写小了，
# 命令**不报用法错、而是越界 panic**：进程从 cmd_* 里直接崩掉，用户看到调用栈
# 而不是提示。实测栽过一次——`set-text l1` 的下界写成 2（应为 3），
# `tokens[2]` 越界把 CLI 干掉了；而第 8 步只用**裸命令名**逐个戳，照不到它。
#
# 这是纯静态核对：拿每个 cmd_* 里读到的**字面下标最大值**跟它的下界比。
# 变量下标（循环里的 `tokens[i]`）不在此列，它们本来就被 length 圈着。
#
# **必须剥掉注释**：实测这个扫描器被我**自己写的注释**骗过——注释里一句
# 「静默接受任何 tokens[2]」被当成了真读 tokens[2]，报出一个不存在的越界，
# 把 verify 卡在 9/10。判据要能分清代码与散文。（鉴别力也当场验过：注入
# 一行真的 `tokens[2]` 它会响。）
python3 - agent/session.mbt <<'PYBOUND'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
funcs, cur = [], None
for i, line in enumerate(lines):
    m = re.match(r"fn (cmd_[a-z0-9_]+)\(", line)
    if m:
        if cur:
            funcs.append(cur)
        cur = {"name": m.group(1), "body": []}
    elif cur is not None:
        if re.match(r"^\}", line):
            funcs.append(cur)
            cur = None
        else:
            cur["body"].append(line)
if cur:
    funcs.append(cur)

def strip_comment(line):
    """去掉行尾注释（引号内的 `//` 不算）。
    这一步是必须的：扫描器曾被我**自己写的注释**骗过——注释里提了一句
    「静默接受任何 tokens[2]」，它就当成真读了 tokens[2]，于是报了一个
    不存在的越界。**判据必须能分清代码与散文。**"""
    out, in_str = [], False
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_str = not in_str
        if not in_str and c == "/" and i + 1 < len(line) and line[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out)

bad, checked = [], 0
for f in funcs:
    code = [strip_comment(l) for l in f["body"]]
    body = "\n".join(code)
    g = re.search(r"tokens\.length\(\) < (\d+)", body)
    if not g:
        continue
    lo = int(g.group(1))
    idxs = {int(m.group(1)) for l in code for m in re.finditer(r"tokens\[(\d+)\]", l)}
    if not idxs:
        continue
    checked += 1
    if max(idxs) >= lo:
        bad.append((f["name"], lo, max(idxs)))

if bad:
    print("FAIL: 下界卡不住自己的下标读取（会越界 panic 而不是报用法错）：")
    for name, lo, mx in bad:
        print(f"    {name}: 下界 {lo}，却读到 tokens[{mx}]")
    sys.exit(1)
if checked == 0:
    print("FAIL: 一个命令都没扫到，扫描大概坏了")
    sys.exit(1)
print(f"命令参数下界 OK（{checked} 个命令，读 tokens[N] 的都在下界之内）")
PYBOUND

echo "== 10/11 变异锚点自检（变异门不许静默失效） =="
# 变异门（mutation_scan.py）往实现里注入语义 bug、看测试能否抓住——但它自己
# 也有一个静默失效模式：锚点文本一旦被重构改掉、或变得不再唯一，那个变异
# 就**再也没跑过**，而汇总里的「N 个变异全部通过」照旧好看。实测踩过：
# R3 的锚点被一次重构改掉、R4 的锚点变成匹配 2 处，两个变异静静失效了一轮，
# 我却照着"33 个全通过"把数字写进了文档。这一步只校验"每个锚点唯一命中 1 处"
# （秒级，不跑那 5 分钟的测试），把失效挡在常规门禁里。
python3 mutation_scan.py --check-anchors

echo "== 11/11 字典 ↔ 解析器 参数对账（承诺的参数必须真的认） =="
# 铁律 6 只覆盖**命令清单**；**参数**一直是两张互不校验的表：工具字典里
# 写 `key=`（LLM 就是照这个发参数的），解析器里另有 check_kv_args 的允许键表。
# 对不上的两种表现都实测过：
#   - 字典写了、解析器不认 → 照描述发参数被拒（mvsl-set 曾用手写记法写了 layer=）
#   - 解析器认了、字典没写 → 只有读源码才知道有它（add-image 收下整套形状键，
#     而字典只写了 x/y/w/h/b64；add-rect 的手写清单漏了 visible=）
# 判据是"解析器认哪些键"必须**读得出来**：命令名不是字面量、键表读不出来
# 一律判失败——静默跳过就等于这块覆盖没了（同第 10 步的道理）。
# 判别力已注入验证：字典多写一个键 / 解析器多认一个键，两向都会红。
python3 param_audit.py

echo ""
echo "ALL VERIFY PASS ✓"
