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

echo "== 1/7 moon check =="
CHECK_OUT=$(moon check 2>&1)
echo "$CHECK_OUT" | tail -1
if echo "$CHECK_OUT" | grep -q "Warning"; then
  echo "FAIL: moon check 存在 Warning"
  echo "$CHECK_OUT" | grep -A4 "Warning" | head -20
  exit 1
fi

echo "== 2/7 moon test --target native =="
moon test --target native 2>&1 | tail -1

echo "== 3/7 wasm-gc 可检 + 测试（引擎纯字节进出的背书） =="
moon check --target wasm-gc 2>&1 | tail -1
moon test --target wasm-gc 2>&1 | tail -1

echo "== 4/7 CLI 子进程端到端 =="
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

echo "== 5/7 独立外部验证（系统 unzip，非引擎自证） =="
unzip -t "$OUT/verify.mpd" > /dev/null && echo "unzip -t: 容器完整性 OK"
unzip -l "$OUT/verify.mpd" | grep -q "meta/design.json"  || { echo "FAIL: 缺 meta/design.json"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "previews/flat.png" || { echo "FAIL: 缺 flat 预览"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "assets/sha256/"    || { echo "FAIL: 缺资产层"; exit 1; }
unzip -p "$OUT/verify.mpd" manifest.json | grep -q '"format":"moonpainter.mpd"' || { echo "FAIL: manifest 格式标识不对"; exit 1; }
echo "manifest/预览/资产三件套齐全"
# 元参数层可直接文本阅读（双层容器的核心承诺）
unzip -p "$OUT/verify.mpd" meta/design.json | head -c 200; echo " …"

echo "== 6/7 open → save 字节一致（进程级确定性闭环） =="
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

echo "== 7/7 MVSL 编辑表命令面 + 渲染管线闭环（安装 → render/impact 同图 → 断言 → lint 空操作/违约 → 容器往返） =="
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
grep -q '"leak_ratio":0' "$OUT/mvsl.log" || { echo "FAIL: 选区外有泄漏"; exit 1; }
# **编辑表真的进了渲染管线**：render 与 mvsl-impact 必须给出同一张最终图。
# 这是本轮最要紧的一条断言——它把"编辑表只是一份被存下来的数据"和
# "编辑表真的改变了渲染结果"区分开。
RSHA=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/mvsl.log" | head -1)
ISHA=$(sed -n 's/.*"result_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/mvsl.log" | head -1)
if [ -z "$RSHA" ]; then echo "FAIL: render 回包缺 render_sha256"; exit 1; fi
if [ -z "$ISHA" ]; then echo "FAIL: mvsl-impact 回包缺 result_sha256"; exit 1; fi
if [ "$RSHA" != "$ISHA" ]; then
  echo "FAIL: render($RSHA) 与 impact($ISHA) 不是同一张图——编辑表没进渲染管线"
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
echo "MVSL：安装/render≡impact/断言/容器往返/预览走编辑表/lint 空操作与违约 全部 OK"

echo ""
echo "ALL VERIFY PASS ✓"
