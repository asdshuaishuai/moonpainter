#!/usr/bin/env python3
"""`dist/` 里的产物与 `dist/index.html` 里的构建元数据必须同源。

**为什么需要它**：徽标（页面右上角）是人做功能测试时"我在测哪一版"的唯一
凭据，它读的是构建时写进 `index.html` 的 `__MP_BUILD__`。而 `dist/` 里的
`demo.js`/`moonpainter.wasm` 是可以被**单独**替换的（手工拷文件、只重建了
一半、把别的构建的产物合并过来）——那时人看着徽标上的 commit，点的却是
另一份引擎：**验收工具与被验对象不同状态，报出来的现象会指向别的地方**。

判据一处：构建的第 `dist` 步（保证刚产出的 dist 自洽）与 `serve_demo.sh`
启动前（保证即将服务出去的那份自洽）共用本脚本，别各写一份。

用法：`python3 check_dist_meta.py`（在仓库根跑；不一致 → 退出码 1 并说差在哪）
"""
import hashlib
import io
import re
import sys

HTML = 'dist/index.html'
ARTIFACTS = (('wasm_sha', 'dist/moonpainter.wasm'), ('demo_sha', 'dist/demo.js'))


def main() -> int:
    try:
        html = io.open(HTML, encoding='utf-8').read()
    except OSError:
        print('FAIL: 读不到 %s —— 先跑 ./build_demo.sh' % HTML, file=sys.stderr)
        return 1
    m = re.search(r'__MP_BUILD__\s*=\s*\{(.*?)\}', html)
    if not m:
        print('FAIL: %s 里没有 __MP_BUILD__ —— 这不是 build_demo.sh 产出的页面' % HTML,
              file=sys.stderr)
        return 1
    meta = dict(re.findall(r"(\w+)\s*:\s*'([^']*)'", m.group(1)))
    bad = []
    for key, path in ARTIFACTS:
        try:
            got = hashlib.sha256(open(path, 'rb').read()).hexdigest()[:12]
        except OSError:
            print('FAIL: 读不到 %s —— 先跑 ./build_demo.sh' % path, file=sys.stderr)
            return 1
        if meta.get(key) != got:
            bad.append('%s：页面写 %s，文件实际 %s（%s）' % (key, meta.get(key), got, path))
    if bad:
        print('FAIL: dist/ 里的产物与页面里的构建元数据不是同一份：', file=sys.stderr)
        for b in bad:
            print('  - ' + b, file=sys.stderr)
        print('  → 跑一次 ./build_demo.sh 重建（别手工拷文件进 dist/）', file=sys.stderr)
        return 1
    print('产物与徽标一致 ✓（commit %s / wasm %s / demo.js %s）'
          % (meta.get('commit'), meta.get('wasm_sha'), meta.get('demo_sha')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
