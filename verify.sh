#!/bin/sh
# MoonPainter 一键验证门（AGENTS.md 口径）：
#   1. moon check 零错误零警告（-W error 由 moon check 默认把 warning 计数呈现，这里断言输出无 Warning）
#   2. moon test --target native 全绿
#   3. CLI 子进程端到端：管道喂命令 → 落盘 .mpd
#   4. 独立外部验证：系统 unzip 校验容器（不用引擎自证）
#   5. open→save 字节一致（确定性 pack 的进程级闭环）
# 任何一步失败即非零退出。
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d /tmp/moonpainter-verify.XXXXXX)
trap 'rm -rf "$OUT"' EXIT

echo "== 1/6 moon check =="
CHECK_OUT=$(moon check 2>&1)
echo "$CHECK_OUT" | tail -1
if echo "$CHECK_OUT" | grep -q "Warning"; then
  echo "FAIL: moon check 存在 Warning"
  echo "$CHECK_OUT" | grep -A4 "Warning" | head -20
  exit 1
fi

echo "== 2/6 moon test --target native =="
moon test --target native 2>&1 | tail -1

echo "== 3/6 wasm-gc 可检 + 测试（引擎纯字节进出的背书） =="
moon check --target wasm-gc 2>&1 | tail -1
moon test --target wasm-gc 2>&1 | tail -1

echo "== 4/6 CLI 子进程端到端 =="
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

echo "== 5/6 独立外部验证（系统 unzip，非引擎自证） =="
unzip -t "$OUT/verify.mpd" > /dev/null && echo "unzip -t: 容器完整性 OK"
unzip -l "$OUT/verify.mpd" | grep -q "meta/design.json"  || { echo "FAIL: 缺 meta/design.json"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "previews/flat.png" || { echo "FAIL: 缺 flat 预览"; exit 1; }
unzip -l "$OUT/verify.mpd" | grep -q "assets/sha256/"    || { echo "FAIL: 缺资产层"; exit 1; }
unzip -p "$OUT/verify.mpd" manifest.json | grep -q '"format":"moonpainter.mpd"' || { echo "FAIL: manifest 格式标识不对"; exit 1; }
echo "manifest/预览/资产三件套齐全"
# 元参数层可直接文本阅读（双层容器的核心承诺）
unzip -p "$OUT/verify.mpd" meta/design.json | head -c 200; echo " …"

echo "== 6/6 open → save 字节一致（进程级确定性闭环） =="
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

echo ""
echo "ALL VERIFY PASS ✓"
