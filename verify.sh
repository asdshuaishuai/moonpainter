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

# 步骤 slug 映射（**散文里引用步骤的唯一方式**：`verify.sh#anchors`）。
# 为什么不写编号：插一步，散文里的「第 N 步」就全错，而没有任何东西会红——
# 实测 README 的「`verify.sh` 第 9 步用 --check-anchors」早已错位（锚点自检
# 是第 10 步，第 9 步是参数下界）。第 8 步的文档数字对账会核这张表。
# step-slugs: 1=check 2=native-test 3=wasm-gc 4=cli-e2e 5=unzip 6=roundtrip 7=mvsl-e2e 8=catalog 9=arg-lower-bound 10=anchors 11=params 12=deps 13=fields 14=panic-hunt 15=scorecard
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

# 步骤编号自洽：分母必须是实际步数、编号必须连续。此前加了一整步（对账门禁）
# 而前面 10 个标题还写着 /10 —— 日志里的"10/10"是真的、分母是假的。
python3 - <<'PYD'
import re, sys
text = open('verify.sh', encoding='utf-8').read()
steps = re.findall(r'^echo "== (\d+)/(\d+) ', text, re.M)
if not steps:
    print('FAIL: 找不到步骤标题')
    sys.exit(1)
nums = [int(a) for a, _ in steps]
totals = {int(b) for _, b in steps}
bad = []
if totals != {len(steps)}:
    bad.append('分母写着 %s，实际 %d 步（加步骤忘了改分母？）'
               % (sorted(totals), len(steps)))
if nums != list(range(1, len(steps) + 1)):
    bad.append('编号不连续：%s' % nums)
if bad:
    print('FAIL: ' + '；'.join(bad))
    sys.exit(1)
print('verify.sh 步骤编号自洽（%d 步，分母全是 %d）' % (len(steps), len(steps)))
PYD

echo "== 1/15 moon check =="
CHECK_OUT=$(moon check 2>&1)
echo "$CHECK_OUT" | tail -1
if echo "$CHECK_OUT" | grep -q "Warning"; then
  echo "FAIL: moon check 存在 Warning"
  echo "$CHECK_OUT" | grep -A4 "Warning" | head -20
  exit 1
fi

echo "== 2/15 moon test --target native =="
run_quiet moon test --target native
# 留下条数给文档对账（README 首页写着具体条数）：**散文里的数字必须有人管**，
# 实测它写着"native 192 项"而当时已经 283 项，没有任何东西会红。
cp "$OUT/step.log" "$OUT/native-tests.log"

echo "== 3/15 wasm-gc 可检 + 测试（引擎纯字节进出的背书） =="
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
cp "$OUT/step.log" "$OUT/wasm-tests.log"

echo "== 4/15 CLI 子进程端到端（含蒙版参数面：毛边 / 部分更新 / 容器契约档位） =="
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
  'add-ellipse x=100 y=50 w=120 h=120 lgrad=#FF7A45FF,#2E6FE8FF,0,0,1,1 blend=screen id=orb name=orb' \
  "add-image x=210 y=160 w=70 h=50 b64=$PNG_B64 name=badge" \
  'flip orb none' \
  'lint' \
  'render 320' \
  'render 320 overlay=1' \
  "save-mpd $OUT/verify.mpd" \
  ':exit' \
  | moon run --target native cli > "$OUT/cli.log"
tail -3 "$OUT/cli.log"
# 这条链里**不许有任何命令报错**：此前 `flip orb none` 一直在报「层不存在：orb」
# （`name=` 不是 id），而这一步只断言了 add-image/lint/save-mpd —— 一条静默失败的
# 命令在端到端门禁里躺了很久，画面碰巧一样所以没人发现。门禁的每一行都要么被断言、
# 要么被这条"全链无 error"罩住。
grep -q '"error"' "$OUT/cli.log" && { echo "FAIL: CLI e2e 链里有命令报错（未断言的失败）"; grep '"error"' "$OUT/cli.log"; exit 1; }
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

# 蒙版参数面（毛边 + 部分更新 + 容器契约档位）：这三件事都在**真 CLI 进程**里
# 走一遍——单元测试证明得了函数，证明不了"命令面真的把它接上了、容器真的声明了"。
# ① `set-mask` 是**部分更新**：只给 feather，其余五个字段必须原样保留
#    （此前"只改羽化"得 remove-mask + add-mask，而 add-mask 是全量建立 →
#     没重复写的 radius/roughen 会被悄悄重置成 0）；
# ② 毛边真的进渲染：同一份文档有/无 roughen 的 render sha 必须不同，
#    而同样的输入跑两次必须逐位相同（噪声里不许有随机数/时间戳）；
# ③ 用到毛边的容器按实际能力声明 render_contract=2（老引擎据此**拒绝打开**，
#    而不是把它画成光滑边）——而没有毛边的那份容器照旧声明 1（第 7 步断言）。
printf '%s\n' \
  'session-open full_image' \
  'new 32 32 uuid=verify-rough' \
  'add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF id=r name=r' \
  'add-mask r kind=rect x=6 y=6 w=20 h=20 radius=4 feather=2 roughen=3' \
  'set-mask r feather=7' \
  'query-layer r' \
  'render 32' \
  'render 32' \
  "save-mpd $OUT/rough.mpd" \
  ':exit' \
  | moon run --target native cli > "$OUT/rough.log"
grep -q '"error"' "$OUT/rough.log" && { echo "FAIL: 蒙版 e2e 链里有命令报错"; grep '"error"' "$OUT/rough.log"; exit 1; }
grep -q '"op":"set-mask"' "$OUT/rough.log" || { echo "FAIL: set-mask 未成功"; exit 1; }
# 精确锚住数值（子串匹配会被 `"roughen":3.5` / `"x":60` 骗过——铁律 11）
grep -Eq '"x":6[,}]' "$OUT/rough.log" || { echo "FAIL: 未给的 x 被 set-mask 改掉了（部分更新退化成全量替换）"; exit 1; }
grep -Eq '"w":20[,}]' "$OUT/rough.log" || { echo "FAIL: 未给的 w 被改掉"; exit 1; }
grep -Eq '"radius":4[,}]' "$OUT/rough.log" || { echo "FAIL: 未给的 radius 被改掉"; exit 1; }
grep -Eq '"roughen":3[,}]' "$OUT/rough.log" || { echo "FAIL: 未给的 roughen 被改掉"; exit 1; }
grep -Eq '"feather":7[,}]' "$OUT/rough.log" || { echo "FAIL: 给的 feather 没生效"; exit 1; }
ROUGH_A=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/rough.log" | head -1)
ROUGH_B=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/rough.log" | sed -n 2p)
if [ -z "$ROUGH_A" ] || [ -z "$ROUGH_B" ]; then echo "FAIL: render 回包缺 render_sha256"; exit 1; fi
[ "$ROUGH_A" = "$ROUGH_B" ] || { echo "FAIL: 毛边渲染不可复现（噪声里有随机源）"; exit 1; }
printf '%s\n' \
  'session-open full_image' \
  'new 32 32 uuid=verify-smooth' \
  'add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF id=r name=r' \
  'add-mask r kind=rect x=6 y=6 w=20 h=20 radius=4 feather=7' \
  'render 32' \
  ':exit' \
  | moon run --target native cli > "$OUT/smooth.log"
grep -q '"error"' "$OUT/smooth.log" && { echo "FAIL: 光滑边对照链里有命令报错"; grep '"error"' "$OUT/smooth.log"; exit 1; }
SMOOTH_SHA=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/smooth.log" | head -1)
if [ -z "$SMOOTH_SHA" ]; then echo "FAIL: 光滑边对照缺 render_sha256"; exit 1; fi
[ "$ROUGH_A" != "$SMOOTH_SHA" ] || { echo "FAIL: roughen 存下来却没进渲染（毛边与光滑边逐位相同）"; exit 1; }
RC=$(unzip -p "$OUT/rough.mpd" manifest.json | sed -n 's/.*"render_contract":\([0-9]*\).*/\1/p')
[ "$RC" = "2" ] || { echo "FAIL: 用到毛边的容器应声明 render_contract=2，实际 $RC"; exit 1; }
# 重开必须**先过 vision 闸**（`open-mpd` 不是旁路）；重开后逐位对账：
# 指纹必须与保存时一致、毛边幅度必须还在（容器是唯一事实源，不是"存了个数字"）。
SAVE_FP=$(sed -n 's/.*"op":"set-mask","id":"r","fingerprint":"\([0-9a-f]*\)".*/\1/p' "$OUT/rough.log" | tail -1)
if [ -z "$SAVE_FP" ]; then echo "FAIL: 保存侧缺指纹"; exit 1; fi
printf '%s\n' "session-open full_image" "open-mpd $OUT/rough.mpd" "query-layer r" ":exit" \
  | moon run --target native cli > "$OUT/rough_open.log"
grep -q '"op":"open-mpd"' "$OUT/rough_open.log" || { echo "FAIL: 声明契约 2 的容器自己被拒了"; exit 1; }
grep -q '"error"' "$OUT/rough_open.log" && { echo "FAIL: 重开链里有命令报错"; grep '"error"' "$OUT/rough_open.log"; exit 1; }
grep -Eq '"roughen":3[,}]' "$OUT/rough_open.log" || { echo "FAIL: 毛边蒙版没随容器往返"; exit 1; }
grep -Eq '"feather":7[,}]' "$OUT/rough_open.log" || { echo "FAIL: set-mask 改的羽化没随容器往返"; exit 1; }

echo "== 5/15 独立外部验证（系统 unzip，非引擎自证） =="
unzip -t "$OUT/verify.mpd" > /dev/null && echo "unzip -t: 容器完整性 OK"
unzip -l "$OUT/verify.mpd" | grep -q "meta/design.json"  || { echo "FAIL: 缺 meta/design.json"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "previews/flat.png" || { echo "FAIL: 缺 flat 预览"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "assets/sha256/"    || { echo "FAIL: 缺资产层"; exit 1; }
unzip -p "$OUT/verify.mpd" manifest.json | grep -q '"format":"moonpainter.mpd"' || { echo "FAIL: manifest 格式标识不对"; exit 1; }
echo "manifest/预览/资产三件套齐全"
# 元参数层可直接文本阅读（双层容器的核心承诺）
unzip -p "$OUT/verify.mpd" meta/design.json | head -c 200; echo " …"

echo "== 6/15 open → save 字节一致（进程级确定性闭环） =="
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

echo "== 7/15 MVSL 编辑表命令面 + 渲染管线闭环（安装 → render/impact 同图 → 断言 → 软边界/空操作/违约 lint → 容器往返） =="
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
# 这份文档没有毛边蒙版 → 声明的是**最低档** 1（不是引擎上限 2）：
# 版本闸按"文档实际用到的能力"声明，老引擎只拒绝真正需要新契约的容器。
unzip -p "$OUT/mvsl.mpd" manifest.json | grep -q '"render_contract":1' || { echo "FAIL: manifest 缺 MVSL 版本块（或声明档位不对）"; exit 1; }

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
  'render 64' \
  'mvsl-impact' \
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
# **分析出口必须量真渲染那一步**：层作用域下 render 与 impact 仍须同图，
# 且 impact 的改动数必须是**那一层的像素数**而不是整幅。
# 这条此前是假的：impact 走 `run_program(合成底图, 整表)`（`run_program` 根本不看
# `layer`），于是 `layer=l1` 被报成"整幅 2048 像素都改了"（真渲染只改 1024），
# 而且与文档级程序给出**同一个 full_sha256**。上面那条 sample 判据照不到它
# （它只看两个采样点的颜色），所以这里补上"图与数"的判据。
SCOPE_RSHA=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/scope.log" | tail -1)
SCOPE_FSHA=$(sed -n 's/.*"full_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/scope.log" | tail -1)
if [ -z "$SCOPE_RSHA" ] || [ -z "$SCOPE_FSHA" ]; then
  echo "FAIL: 层作用域下 render/impact 缺 sha"; cat "$OUT/scope.log"; exit 1
fi
if [ "$SCOPE_RSHA" != "$SCOPE_FSHA" ]; then
  echo "FAIL: 层作用域下 render($SCOPE_RSHA) 与 impact 全分辨率结果($SCOPE_FSHA) 不是同一张图"
  exit 1
fi
# 32x32 = 1024：只有被引用的那一层（左半）被改。锚住字段值结尾，不做子串匹配。
grep -Eq '"changed_total":1024[,}]' "$OUT/scope.log" || {
  echo "FAIL: 层作用域下 impact 的改动数不是那一层的像素数"; grep -o '"changed_total":[0-9]*' "$OUT/scope.log"; exit 1
}
grep -q '"layer":"l1"' "$OUT/scope.log" || { echo "FAIL: impact 没报出逐算子作用在哪一层"; exit 1; }
# 对照：同一条算子去掉 layer= → 整幅 2048 都被改，且最终图必须**不同**
DOC_PROG=$(printf '%s' "${SCOPE_PROG/\"layer\":\"l1\"/\"layer\":\"\"}")
printf '%s\n' \
  'session-open full_image' \
  'new 64 32 uuid=mvsl-scope-doc' \
  'add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF id=l1' \
  'add-rect x=32 y=0 w=32 h=32 fill=#FF0000FF id=l2' \
  "mvsl-set $(printf '%s' "$DOC_PROG" | base64 | tr -d '\n')" \
  'render 64' \
  'mvsl-impact' \
  | moon run --target native cli > "$OUT/scope_doc.log"
DOC_RSHA=$(sed -n 's/.*"render_sha256":"\([0-9a-f]*\)".*/\1/p' "$OUT/scope_doc.log" | tail -1)
grep -Eq '"changed_total":2048[,}]' "$OUT/scope_doc.log" || {
  echo "FAIL: 文档级对照的改动数不是整幅 2048"; cat "$OUT/scope_doc.log"; exit 1
}
if [ "$DOC_RSHA" = "$SCOPE_RSHA" ]; then
  echo "FAIL: 带 layer= 与不带 layer= 渲染出了同一张图——作用域没被量进去"
  exit 1
fi
echo "图层级作用域 OK（左半被改、右半逐位不变；不存在的层被拒；render≡impact 且改动数=该层像素数）"
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

echo "== 8/15 命令字典与分发一致（铁律 6）+ 文档数字 / AGENTS.md 字节预算 =="
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

# 文档里写的**命令条数**也要对得上：DESIGN §2 写着"agent（57 命令…"而字典
# 早已是 59 —— 同一个数字在三份文档里各写一遍，谁都没查（README 的"59 条命令"
# 与 AGENTS 的"查看全部 59 个命令"同样没人查，只是碰巧是对的）。
# 只审**活文档**（README/DESIGN/AGENTS）：PLAN.md 是实施历史，
# 里面的数字是当时的记录，改它等于篡改历史。
# 路径走 argv：`<<'PYD'` 是引号 heredoc，块里的 $OUT **不会**被 shell 展开
# （上一版就栽在这：FileNotFoundError: '$OUT/cmdlist.txt'）
# 实际测试条数（上面两步留下的日志）→ 交给对账脚本核 README 首页的声明。
# 读不出来就**判失败**（读不出来 = 这块对账没了，而汇总照旧好看）。
NATIVE_N=$(sed -n 's/^Total tests: \([0-9]*\),.*/\1/p' "$OUT/native-tests.log" | tail -1)
WASM_N=$(sed -n 's/^Total tests: \([0-9]*\),.*/\1/p' "$OUT/wasm-tests.log" | tail -1)
test -n "$NATIVE_N" && test -n "$WASM_N" || { echo "FAIL: 读不出测试条数（$OUT/native-tests.log / wasm-tests.log）"; exit 1; }
export NATIVE_N WASM_N

python3 - "$OUT/cmdlist.txt" <<'PYD'
import ast, os, re, sys
n = len([l for l in open(sys.argv[1], encoding='utf-8') if l.strip()])
bad = []
DOCS = ('README.md', 'DESIGN.md', 'AGENTS.md')

# ── 步骤 slug 表：每个脚本的步骤数、编号连续、slug 恰好覆盖每一步 ────────
def steps_of(path):
    src = open(path, encoding='utf-8').read()
    heads = re.findall(r'^echo "== (\d+)/(\d+) ', src, re.M)
    m = re.search(r'step-slugs:(.*)', src)
    if not m:
        return None, None, '%s 里找不到 step-slugs 映射' % path
    slugs = {}
    for part in m.group(1).split():
        if '=' not in part:
            return None, None, '%s 的 step-slugs 里「%s」不是 n=slug 形态' % (path, part)
        k, v = part.split('=', 1)
        if not k.isdigit():
            return None, None, '%s 的 step-slugs 键「%s」不是数字' % (path, k)
        slugs[int(k)] = v
    nums = [int(a) for a, _ in heads]
    totals = {int(b) for _, b in heads}
    if totals != {len(heads)}:
        return None, None, '%s 的步骤分母写着 %s，实际 %d 步' % (path, sorted(totals), len(heads))
    if nums != list(range(1, len(heads) + 1)):
        return None, None, '%s 的步骤编号不连续：%s' % (path, nums)
    if sorted(slugs) != nums:
        return None, None, '%s 的 step-slugs 覆盖 %s，而步骤是 %s（加步骤忘了配 slug？）' % (
            path, sorted(slugs), nums)
    if len(set(slugs.values())) != len(slugs):
        return None, None, '%s 的 step-slugs 有重名' % path
    return len(heads), slugs, None

scripts = {}
fatal = []
for sp in ('verify.sh', 'build_demo.sh'):
    cnt, slugs, err = steps_of(sp)
    if err:
        fatal.append(err)
    scripts[sp] = (cnt, slugs or {})
if fatal:
    # **读不出步骤表就立刻停**，别带着 None 往下走：实测第一版把 None 渗进
    # 后面的 `%d`，于是"映射漏了一步"变成一句 TypeError traceback ——
    # 退出码是 1（看着像"抓住了"），而真正该说的话一个字没印。
    # 门禁崩溃 ≠ 门禁判定：崩溃让人以为判据在咬，其实判据根本没跑完。
    print('FAIL: ' + '；'.join(fatal))
    sys.exit(1)

# ── MUTS 条数：静态解析（不执行脚本，避免它的副作用） ────────────────────
# `mutation_scan.py` 的锚点里全是 MoonBit 的 `\{kind}` 字面量，Python 3.12+
# 会对这种"无效转义"发 SyntaxWarning（当前仍原样保留反斜杠，故锚点是对的）。
# 日志是给人看的，别让判据自己刷警告；同时把 filename 传进去，真出错时报得准。
import warnings
with warnings.catch_warnings():
    warnings.simplefilter('ignore', SyntaxWarning)
    tree = ast.parse(open('mutation_scan.py', encoding='utf-8').read(), filename='mutation_scan.py')
node = next((x for x in tree.body
             if isinstance(x, ast.Assign) and getattr(x.targets[0], 'id', None) == 'MUTS'), None)
if node is None:
    bad.append('mutation_scan.py 里读不出 MUTS（判据失效，别静默跳过）')
    muts_total, muts_killed = 0, 0
else:
    muts = ast.literal_eval(node.value)
    muts_total = len(muts)
    muts_killed = muts_total - sum(1 for e in muts if e[5] == 'equivalent')

# ── README 声明的 verify.sh 步数 + 该节编号清单项数 ──────────────────────
rm = open('README.md', encoding='utf-8').read()
# 步数声明：**每一处**都要核（原先只核第一处），且要认**中文数字**——
# 首页那句写的是"`./verify.sh` 八步验证门全过"，而正则只认 \d+，
# 于是它从缝里漏过去、步数从 8 变 13 也没人红。
CN_DIGIT = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
            '六': 6, '七': 7, '八': 8, '九': 9, '十': 10}
def cn2int(t):
    if t in CN_DIGIT:
        return CN_DIGIT[t]
    if t.startswith('十'):
        return 10 + CN_DIGIT.get(t[1:], 0)
    if '十' in t:
        a, b = t.split('十')
        return CN_DIGIT[a] * 10 + (CN_DIGIT.get(b, 0) if b else 0)
    return None
claims = list(re.finditer(r'`\./verify\.sh`[^\n]{0,4}?([0-9]+|[一二三四五六七八九十]+)\s*步', rm))
if not claims:
    bad.append('README 没有「`./verify.sh` N 步」的步数声明（数不出来 = 没在核对）')
else:
    for m in claims:
        got = int(m.group(1)) if m.group(1).isdigit() else cn2int(m.group(1))
        if got != scripts['verify.sh'][0]:
            bad.append('README 写 verify.sh %s 步（「%s」），实际 %d 步'
                       % (m.group(1), m.group(0), scripts['verify.sh'][0]))
    # 编号清单要锚在**那份声明后面真跟着清单**的那一处：首页横幅也写着
    # "`./verify.sh` 十三步验证门全过"，但它后面没有清单（原先只匹配数字，
    # 首页的中文数字漏过去了，所以从没暴露这个歧义）。
    def _section_items(after):
        t = rm[after:]
        t = t[:t.find('\n## ')] if '\n## ' in t else t
        return re.findall(r'^\d+\. ', t, re.M)
    m = claims[0]
    items = _section_items(m.end())
    for c in claims:
        cand = _section_items(c.end())
        if len(cand) > len(items):
            m, items = c, cand
    sec = rm[m.end():]
    sec = sec[:sec.find('\n## ')] if '\n## ' in sec else sec
    items = re.findall(r'^\d+\. ', sec, re.M)
    if len(items) != scripts['verify.sh'][0]:
        bad.append('README 的验证门清单列了 %d 项，而 verify.sh 有 %d 步' % (len(items), scripts['verify.sh'][0]))

# ── 测试条数（**按文件各扫一遍**）────────────────────────────────────
# 实测 README 首页写着"native 192 项 / wasm-gc 190 项"而当时已 283/281，
# 没有任何东西会红——散文里的数字又一个没人管的。
# ⚠️ 这条判据**不许**放进下面那个逐行循环里：那里 `rm` 是 README 全文，
# 于是每读一行就把 README 重扫一遍，报出上百条重复、还把行号/文件名安到
# 别的文档头上（实测第一版就报"DESIGN.md 写了…"几十遍）。判据自己说错话
# 比不判更坏。
_real_n = int(os.environ['NATIVE_N'])
_real_w = int(os.environ['WASM_N'])
for _path in DOCS:
    for m in re.finditer(r'native\s*([0-9]+)\s*项\s*/\s*wasm-gc\s*([0-9]+)\s*项',
                         open(_path, encoding='utf-8').read()):
        if int(m.group(1)) != _real_n or int(m.group(2)) != _real_w:
            bad.append('%s 写「native %s 项 / wasm-gc %s 项」，实际 native %d / wasm-gc %d'
                       % (_path, m.group(1), m.group(2), _real_n, _real_w))

for path in DOCS:
    # 自动维护的进度区块（deepgit）**不是承诺**：里面有时间戳、提交标题、乃至
    # 「命令数 56→57」这种历史记录。与 PLAN.md 同一条理由（实施历史不审），
    # 但这里没有独立文件可跳过，所以按标记块跳过。
    SKIP_A, SKIP_B = '<!-- deepgit:begin progress -->', '<!-- deepgit:end progress -->'
    skipping = False
    for i, line in enumerate(open(path, encoding='utf-8'), 1):
        if SKIP_A in line:
            skipping = True
        if skipping:
            if SKIP_B in line:
                skipping = False
            continue
        # ① 命令条数：**两种语序都要认**
        # 数字在前：`59 个命令` / `59 条命令`。负向后视 `(?<![/\d])` 把步骤编号
        # 「8/14 命令字典…」里的 12 排除掉。
        # ⚠️ **这条只认「数字与命令之间只有条/个」的写法**（`63 条命令` ✓、
        # `引擎 63 条命令里` ✓）。要写**分项**（"其中 N 条是某某"）就把修饰语
        # 放进这个缝里：`那 16 条够不着的命令` 不被抓，而 `16 条命令的人类入口`
        # **会被抓**——实测 2026-10-03 就误报过一次（README 那句讲的是 16 个入口，
        # 不是引擎总数）。判据与散文都没错，错的是这条界线没写下来。
        # **别把这段删了**：看见的人才知道分项该往哪儿写。
        for m in re.finditer(r'(?<![/\d])(\d+)\s*(?:条)?\s*(?:个)?命令', line):
            if int(m.group(1)) != n:
                bad.append('%s:%d 写「%s 条命令」，实际 %d' % (path, i, m.group(1), n))
        # 数字在后：`命令集（58 个` / `命令数 60`。实测 DESIGN §6 的标题
        # 「命令集（58 个；…」就是这么漏过去的——判据只认作者当时写的那一种
        # 语序，于是同一个数字在第三份文档里烂着而门禁全绿。**判据要认得出
        # 所有写法**；`命令` 后面必须是 集/数/总数，否则「这个命令 3 个参数」
        # 这种正常句子会被误判（负控）。
        for m in re.finditer(r'命令(?:集|数|总数)\s*(?:[（(：:]\s*)?(\d+)\s*(?:个|条)?', line):
            if int(m.group(1)) != n:
                bad.append('%s:%d 写「命令集/命令数 %s」，实际 %d' % (path, i, m.group(1), n))
        # ② 步骤引用只许走 slug，而且 slug 必须真实存在
        for m in re.finditer(r'(verify\.sh|build_demo\.sh)#([A-Za-z0-9_-]+)', line):
            if m.group(2) not in scripts[m.group(1)][1].values():
                bad.append('%s:%d 引用了不存在的步骤 slug「%s#%s」（%s 的 slug：%s）' % (
                    path, i, m.group(1), m.group(2), m.group(1),
                    ' '.join(sorted(scripts[m.group(1)][1].values()))))
        # ③ 散文里禁止用编号引用步骤（插一步就全错，且没人会红）
        for m in re.finditer(r'第\s*\d+\s*步', line):
            bad.append('%s:%d 用编号引用步骤「%s」——请写 slug（如 `verify.sh#anchors`）'
                       % (path, i, m.group(0)))
        dens = sorted({str(scripts[sp][0]) for sp in scripts if scripts[sp][0]})
        for m in re.finditer(r'(?<![\w#])(\d+)/(?:%s)(?![\d])' % '|'.join(dens), line):
            bad.append('%s:%d 用编号引用步骤「%s」——请写 slug' % (path, i, m.group(0)))
        # ④ 变异条数
        for m in re.finditer(r'(\d+)\s*个变异中\s*(\d+)\s*个被抓住', line):
            if (int(m.group(1)), int(m.group(2))) != (muts_total, muts_killed):
                bad.append('%s:%d 写「%s 个变异中 %s 个被抓住」，实际 %d 中 %d' % (
                    path, i, m.group(1), m.group(2), muts_total, muts_killed))

# ── AGENTS.md 的字节预算（指令文件有硬上限，超了会被**从尾部静默截断**） ──
# 2026-10-01 实测：AGENTS.md 长到 65977 字节时，宿主按 65536 字节的预算加载它，
# **从尾部截断**——先切掉的是 deepgit 进度块与「结构速览」，再长就轮到
# `快速命令`（那份列出所有门禁的清单）与 demo 纪律，而且**没有任何东西会红**：
# 纪律文件自己在静默降级。这与本仓库反复抓的那一类 bug 完全同形（护栏同时是
# 能力上限、截断 = 静默丢内容），只不过这次被截的是"规矩"本身。
# 分工：**AGENTS.md 只留规则，经过与实测数字进 PLAN.md**（实施历史不在对账内）。
# 预算取 48 KiB：给自动维护的 deepgit 块与未来的新规则留出余量，而不是卡在
# 65536 上——贴着上限就等于下一次加规则又会静默截断。
AGENTS_BUDGET = 48 * 1024
agents_bytes = len(open('AGENTS.md', 'rb').read())
if agents_bytes > AGENTS_BUDGET:
    bad.append('AGENTS.md 已 %d 字节（预算 %d）：指令文件超预算会被**从尾部静默截断**，'
               '文末的规则会先消失而门禁照旧全绿。新经过/新数字写进 PLAN.md，'
               'AGENTS.md 只留规则。' % (agents_bytes, AGENTS_BUDGET))

if bad:
    print('FAIL: ' + '；'.join(bad))
    sys.exit(1)
print('文档数字 OK（命令 %d；verify.sh %d 步 / build_demo.sh %d 步，步骤引用全是有效 slug；'
      '变异 %d 中 %d 被抓住；AGENTS.md %d/%d 字节）'
      % (n, scripts['verify.sh'][0], scripts['build_demo.sh'][0],
         muts_total, muts_killed, agents_bytes, AGENTS_BUDGET))

# ── 单调地板：上面这些数字"只许抬不许降"（等号门禁只管"写没写对"，管不住退化）──
# 谁测量谁核对：这里核对的是**这一步自己测出来的**四个数。其余指标由各自的
# 测量点核对（`ui_audit.py` / `build_demo.sh` / `panic_hunt.py`）。
import floors
floors.check('engine_commands', n)
floors.check('tests_native', int(os.environ['NATIVE_N']))
floors.check('tests_wasm', int(os.environ['WASM_N']))
floors.check('mutations', muts_total)
floors.check('mutations_killed', muts_killed)
PYD

echo "== 单调地板（只许抬不许降） =="
# 「数字是承诺」缺的那一半：删掉一条命令/一个入口/一条变异，再把文档数字改成新的，
# 等号门禁照旧全绿。地板是**另一份数据**（floors.toml），下调必须在同一次提交里
# 配一条 [[retired]] 写明理由，这里拿工作树与 HEAD 逐项比。
python3 floors.py --check-history

# 性能数字是**唯一一处**此前只靠人自觉的承诺：`bench_perf.py` 量的是墙钟时间，
# 不许进门禁（换机器就红），于是"文档里的性能数字"没有任何东西对账——实测一句
# **连数字都没有**的边界结论（"12MP <2s 对任何多一点层数都不成立"）在 perf 三轮
# 之后仍然是错的。办法是把"测量"与"引用"分开：数字只能由 `bench_perf.py` 产出并
# 写进 `bench/ledger.json`（账本），文档只能引用账本里的数。
# 判别力已注入验证：抄错一个表格单元 / 把「不成立」写成「成立」/ 把每层边际或
# 破线层数改掉 / 删掉一个标记块，四种都会红（见 PLAN 四十）。
python3 bench_ledger.py

echo "== 9/15 命令参数下界自检（读 tokens[N] 之前必须先卡住 N） =="
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

echo "== 10/15 变异锚点自检（变异门不许静默失效） =="
# 变异门（mutation_scan.py）往实现里注入语义 bug、看测试能否抓住——但它自己
# 也有一个静默失效模式：锚点文本一旦被重构改掉、或变得不再唯一，那个变异
# 就**再也没跑过**，而汇总里的「N 个变异全部通过」照旧好看。实测踩过：
# R3 的锚点被一次重构改掉、R4 的锚点变成匹配 2 处，两个变异静静失效了一轮，
# 我却照着"33 个全通过"把数字写进了文档。这一步只校验"每个锚点唯一命中 1 处"
# （秒级，不跑几十分钟的全量扫描），把失效挡在常规门禁里。
python3 mutation_scan.py --check-anchors
# 第二个静默失效模式是**残余态**：扫描被 `kill -9`/断电打断时，注入的变异
# 会留在树里（`git status` 只说"文件被改过"），而**下一次扫描会拿它当基线**
# ——整轮结果都不可信。实测：`kill -9` 把 SHA-256 的 K 常量改成 `0x71374490`
# 留在 `base/sha256.mbt`，下一步就可能被当自己的改动提交。`--selfcheck` 用
# 合成正文验"这道残余态判据本身咬得住"（四种情形），秒级。
python3 mutation_scan.py --selfcheck

echo "== 11/15 字典 ↔ 解析器 参数对账（承诺的参数必须真的认） =="
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

echo "== 12/15 依赖方向门禁（铁律 5：方向/零第三方/FFI 边界） =="
# 铁律 5 此前**一条都没门禁**：moon 编译器只管有没有环，**反向依赖照样编得过**。
# 判据：①每个包都在 ORDER 里（新包必须登记，不许静默不审）②内部边全部朝前
# ③pixel 绝不依赖 render ④引擎包零第三方依赖 ⑤demo 不 import 任何引擎包
# （引擎交互只走 wasm ABI）⑥FFI 只在 cli/demo。实测它一上来就抓到
# `demo/moon.pkg` 里那句 `moonpainter/core`——只为 `@core.ENGINE_VERSION`
# 一个常量而存在的旁路（同一个事实两条路：demo 编译进去的常量 vs 已加载 wasm
# 的 `mp_version`）。
python3 dep_audit.py

echo "== 13/15 字段面门禁（\`Layer\` 的每个字段，建层之后改得动吗） =="
# 「改得动吗」这一面此前是**靠手走**的：AGENTS 里写着"这一面到此走完"，而那是
# 走过 add-adjust / set-text / set-style points 三处之后下的结论。**手走的清单
# 一定漏**——实测这次漏了两处：`asset_hash`（换图只能删了重加，层序/蒙版/标签
# 全丢）与位图层的**盒子**（缺省 100×100 把任意比例的图静默压成正方形）。
# 判据：每个字段必须有"建层之后能改它"的命令归属；改不动的要显式声明为
# **身份**字段（id/kind）——"暂时没做"不算理由，那种要写进能力边界。
# 键/命令清单从源码静态读，读不出来判失败（静默跳过 = 覆盖没了而汇总照旧好看）。
# 判别力已注入验证：拿掉一个键的登记、拿掉一个字段的覆盖，两向都会红。
python3 field_audit.py

echo "== 14/15 对抗性参数 fuzz（每条命令 × 敌意参数：只回错、不崩） =="
# 命令面越铺越宽，"某个分支在某个奇怪参数下把进程干掉"是必然会出现的 bug，
# 而它只在真实输入下暴露。此前两条门禁都照不到这一片：`verify.sh#catalog` 只用
# **裸命令名**逐个戳（脚本自己的注释就承认"照不到带参数才越界的那批"），
# `verify.sh#arg-lower-bound` 只是**静态**扫"读 tokens[N] 前卡了 N 没有"。
# 现场是 `set-text l1`：越界读 tokens[2]，CLI 进程当场 abort——用户看到调用栈，
# 不是用法提示。这一步把全部命令 × 固定敌意语料（位置参数 33 种形态 + 字典里
# **声明过的每个键** × 16 种敌意值）喂给一个 CLI 进程，断言：退出码 0、
# **每行输入都有恰好一行 JSON 回包**（静默与崩溃一样是 bug）、回包全是合法 JSON、
# stderr 里没有 PanicError 一类字眼。红了就按前缀二分，指名报出把它干掉的那一行。
# 判别力已注入验证：把 `cmd_set_text` 的下界守卫去掉，本步立刻非零退出，
# 报出 `set-text`（退出码 134 + PanicError 调用栈）——正是当年那个真 bug。
python3 panic_hunt.py

echo "== 15/15 记分卡 + 键效果（收了却没人读的键必须为 0） =="
# 两件事，一条判据：①**行为式**问一遍"字典承诺的每个键真的被读了吗"——
# 每个（命令, 键）配对在同一个 CLI 进程里跑两遍（键取基线值 vs 探针值），
# 比四个可观测出口（命令回包 / fingerprint / list-layers / render sha256）；
# 四个全都没变 = 这个键**收了却没人读**（退出码非零）。②记分卡：
# `scorecard/areas.toml` 的每条必须有一个**唯一命中**的源码锚点 + 合法 slug，
# 生成 `docs/scorecard.md` 并与提交的那份逐字节比较（文档过期只许重新生成）。
# 判别力已注入验证：把 `radius` 的写入删掉（收了不写），本步立刻报出
# `add-rect radius` 与 `set-style radius` 两条死键并非零退出；
# 再拿掉一条 item 的 gate、把一个锚点指向不存在的符号，记分卡侧同样红。
python3 key_effect_audit.py
python3 scorecard.py --check

echo ""
echo "ALL VERIFY PASS ✓"
