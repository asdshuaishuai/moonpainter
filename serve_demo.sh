#!/usr/bin/env bash
# 起一个**固定端口 + 禁缓存**的静态服务，供人做功能测试：
#
#     ./serve_demo.sh [端口]        # 默认 8137
#
# 为什么不用 `python3 -m http.server`：它带 `Last-Modified`/`ETag`，浏览器会拿
# 缓存里的旧 `demo.js`/`moonpainter.wasm` 而不自知——人对着旧引擎点半天，报出来
# 的现象指向别的地方（同一条纪律："验收工具与被验对象不同状态时，报出来的现象
# 会指向别的地方"）。这里显式 `Cache-Control: no-store`，并在启动时打印**当前
# dist 的构建元数据**（与页面右上角徽标同源），先确认在测哪一版再点。
#
# 只读 `dist/`；不构建。改完代码先 `./build_demo.sh` 再刷新页面。
set -euo pipefail
PORT="${1:-8137}"
cd "$(dirname "$0")"

if [ ! -f dist/demo.js ] || [ ! -f dist/moonpainter.wasm ]; then
  echo "FAIL: dist/ 里没有 demo.js / moonpainter.wasm —— 先跑 ./build_demo.sh" >&2
  exit 1
fi

# 构建元数据（从 index.html 里读，**不是重新算**：页面显示的就是它）
META=$(python3 - << 'PY'
import re, io
s = io.open('dist/index.html', encoding='utf-8').read()
m = re.search(r'__MP_BUILD__\s*=\s*(\{.*?\})', s)
print(m.group(1) if m else '（index.html 里没有 __MP_BUILD__：这不是 build_demo.sh 产出的页面）')
PY
)
echo "dist 构建元数据：$META"

# **产物与徽标必须同源**：手工往 `dist/` 拷过文件（或只重建了一半）时，人会
# 看着徽标上的 commit、点的却是另一份引擎。判据在 `check_dist_meta.py` 一处
# （构建的 dist 步也调它）——不一致直接拒绝启动：静默服务一份混搭的 dist
# 比"提醒一句"坏得多。
python3 check_dist_meta.py
echo "MoonPainter demo → http://127.0.0.1:$PORT/"

exec python3 - "$PORT" << 'PY'
import http.server, socketserver, sys, os

port = int(sys.argv[1])
root = os.path.join(os.getcwd(), 'dist')

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=root, **kw)
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        super().end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write("[serve] %s %s\n" % (self.address_string(), fmt % args))

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
PY
