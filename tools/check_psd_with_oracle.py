#!/usr/bin/env python3
"""把 **MoonBit 写出的 PSD** 交给第三方读（③ PSD 兼容 · 写侧的独立 oracle）。

为什么要它：`codec/psd_out.mbt` 写出来的字节，如果只用**我们自己的读侧**验，那是
自己给自己判卷——写错一个约定俗成的字段（合成图交错序、Pascal 名对齐、flags 的
可见位……）我们两边一起错也能过。所以这里**反向**验证一遍：

  * 走**真 CLI 进程**建一个固定场景的文档（脚本存在 `roundtrip.json` 里，
    `verify.sh#psd-roundtrip` 读同一份脚本重放——脚本只有一处）；
  * `export-psd-b64` 拿到 PSD 字节，落盘 `codec/testdata/psd/roundtrip.psd`；
  * **psd-tools** 读回层表（名字/矩形/不透明度/可见性/混合模式）与
    `composite(force=True)`（按层重算的合成图）；
  * **Pillow** 读回合成图；
  * 三张脸互相对账：我们 `render` 的像素 == Pillow 读回的合成图 ==
    psd-tools 叠白纸重算的合成图（最后一条允许 ±1 的进位差，见 `tol` 字段）。

期望值（文件 sha / render sha / Pillow 合成 sha / 层表 / psd-tools 合成 sha 与
最大差）全部写进 `codec/testdata/psd/roundtrip.json`，于是 **门禁离线可跑**：
`verify.sh#psd-roundtrip` 只重放脚本 + 比这些数字，不需要 psd-tools。

依赖（只在生成/深度检查时需要）：
    python3 -m venv /tmp/psdvenv && /tmp/psdvenv/bin/pip install psd-tools
用法：
    /tmp/psdvenv/bin/python tools/check_psd_with_oracle.py            # 生成 + 检查
    /tmp/psdvenv/bin/python tools/check_psd_with_oracle.py --check     # 幂等校验（不改文件）
"""

import base64
import hashlib
import json
import os
import subprocess
import sys

from PIL import Image
from psd_tools import PSDImage

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "codec", "testdata", "psd")
PSD_PATH = os.path.join(DATA, "roundtrip.psd")
JSON_PATH = os.path.join(DATA, "roundtrip.json")

# 固定场景（**确定性的**：不给随机 uuid，命令序写死）。刻意覆盖写侧每一条分支：
# 组（烤成一个层）、半透明 + multiply、文本 + 蒙版 + 图层样式（烤进像素）、
# 隐藏层（内容要留住）、空组（1×1 全透明）、贴着画布边缘的层（盒子裁剪）、
# 不透明度 0.5（8 位四舍五入）。
SCENES = {
    # ① `main`：**没有非 normal 混合**，所以第三方"按层重算"的结果可以与我们逐位对账。
    #    刻意覆盖写侧每一条分支：组（烤成一个层）、组 α=0.5、文本 + 蒙版 + 图层样式
    #    （烤进像素）、隐藏层（内容要留住）、空组（1×1 全透明）、贴着画布边缘的层
    #    （盒子裁剪）、不透明度 0.25（8 位四舍五入）。
    #
    #    ⚠️ 为什么把非 normal 混合单独拆出去：实测 psd-tools 1.24.0 的
    #    `composite(force=True)` 对带混合模式的层**按 normal 混**——screen 层叠在白底上
    #    它给 (200,234,200)（= 0.25 α 的 normal 叠加），而正确答案是白（screen 遇白恒白）。
    #    同一张图：Pillow 读回**存下来的合成图**与我们的 render 逐位相同。
    #    所以"重算"这条路对混合模式不可信，我们把混合模式放到 ② 里只验**编码**。
    "main": [
        "session-open full_image",
        "new 24 18 uuid=psd-roundtrip",
        "add-rect x=1 y=1 w=10 h=8 fill=#CC2222FF name=底板 id=r1",
        "add-ellipse x=8 y=6 w=12 h=9 fill=#2244CCAA name=半透明蓝 id=e1",
        "add-text x=2 y=2 text=Hi fill=#000000FF name=字 id=t1 font_size=7",
        "add-mask t1 kind=rect x=1 y=1 w=14 h=12 feather=1",
        "set-fx t1 shadow=true outline=true",
        "group g1 r1 e1",
        "set-style g1 opacity=0.5",
        "add-rect x=20 y=14 w=6 h=6 fill=#22AA22FF name=边缘 id=r2",
        "set-style r2 opacity=0.25",
        "visible t1 false",
        "add-rect x=0 y=0 w=3 h=3 fill=#000000FF name=空手 id=r3",
        "group g2 r3",
        "group-remove g2 r3",
        "delete r3",
        "export-psd-b64",
        "render 24",
    ],
    # ② `blend`：非 normal 混合（multiply / screen）只验**编码**——psd-tools 读回的
    #    混合模式签名必须与我们的模型一致，而画面正确性由"Pillow 存图 == render"
    #    与 MoonBit 侧的"导出→导入→渲染逐位相同"守着。
    "blend": [
        "session-open full_image",
        "new 16 12 uuid=psd-roundtrip-blend",
        "add-rect x=0 y=0 w=16 h=12 fill=#FFFFFF00 name=底 id=b1",
        "add-rect x=1 y=1 w=6 h=5 fill=#3366FFFF name=乘 id=b2 blend=multiply",
        "add-rect x=8 y=6 w=6 h=5 fill=#22AA22FF name=滤 id=b3 blend=screen",
        "set-style b3 opacity=0.5",
        "export-psd-b64",
        "render 16",
    ],
}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def run_cli(lines):
    """跑真 CLI，回 `{op: 回包}`（一行一个 JSON）。"""
    proc = subprocess.run(
        ["moon", "run", "--target", "native", "cli"],
        cwd=ROOT,
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit("CLI 跑失败（退出码 %d）：\n%s\n%s"
                         % (proc.returncode, proc.stdout[-2000:], proc.stderr[-2000:]))
    out = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            out.append(json.loads(line))
    if not out:
        raise SystemExit("CLI 没有输出任何 JSON 回包")
    return out


def last(out, op):
    got = [d for d in out if d.get("op") == op]
    if not got:
        raise SystemExit("CLI 回包里没有 %s：%s" % (op, out[-3:]))
    if "error" in got[-1]:
        raise SystemExit("%s 报错：%s" % (op, got[-1]["error"]))
    return got[-1]


def rgba_of_png(png_bytes):
    im = Image.open(__import__("io").BytesIO(png_bytes)).convert("RGBA")
    return im.tobytes(), im.size


def layer_facts(psd):
    facts = []
    for L in psd:
        facts.append({
            "name": L.name,
            "x": int(L.left),
            "y": int(L.top),
            "w": int(L.width),
            "h": int(L.height),
            "opacity": int(L.opacity),
            "visible": bool(L.visible),
            "blend": str(L.blend_mode.name).lower(),
        })
    return facts


def force_white(psd):
    """按层重算的合成图叠白纸（我们画布是白纸语义）。"""
    comp = psd.composite(force=True)
    if comp is None:
        raise SystemExit("psd-tools 的 composite(force=True) 返回 None（层数据读不出来？）")
    comp = comp.convert("RGBA")
    white = Image.new("RGBA", comp.size, (255, 255, 255, 255))
    return Image.alpha_composite(white, comp).tobytes()


def gather_one(name, script):
    """跑一个场景：导出 → 三方读 → 对账，回该场景的期望值字典。"""
    psd_path = os.path.join(DATA, "roundtrip_%s.psd" % name)
    out = run_cli(script)
    exp = last(out, "export-psd-b64")
    psd_bytes = base64.b64decode(exp["psd_b64"])
    with open(psd_path, "wb") as fp:
        fp.write(psd_bytes)

    width, height = exp["width"], exp["height"]
    render = last(out, "render")
    render_px, size = rgba_of_png(base64.b64decode(render["png_b64"]))
    if size != (width, height):
        raise SystemExit("render 尺寸不对：%s（要 %s）" % (size, (width, height)))

    psd = PSDImage.open(psd_path)
    facts = layer_facts(psd)

    # ① Pillow 读**存下来的合成图**：必须与我们的 render 逐位相同
    with Image.open(psd_path) as im:
        pillow_px = im.convert("RGBA").tobytes()
        pillow_size = im.size
    if pillow_size != (width, height):
        raise SystemExit("Pillow 读出的尺寸不对：%s" % (pillow_size,))
    if pillow_px != render_px:
        bad = sum(1 for a, b in zip(pillow_px, render_px) if a != b)
        raise SystemExit(
            "FAIL[%s]: Pillow 读回的合成图 != 我们 render 的像素（%d 字节不同）—— "
            "写出去的合成图不是画面的存档" % (name, bad))

    # ② 层表对账：psd-tools 读到的名字/矩形/不透明度/可见性/混合 == 引擎自己报的
    # （`psd-info` 要等导出之后才有 b64，所以单开一个进程问）
    info = last(
        run_cli(["session-open full_image",
                 "psd-info b64=%s" % base64.b64encode(psd_bytes).decode()]),
        "psd-info")
    info_layers = info["layer_table"]
    if len(info_layers) != len(facts):
        raise SystemExit("FAIL[%s]: 层数对不上：psd-tools=%d，我们=%d"
                         % (name, len(facts), len(info_layers)))
    for i, (a, b) in enumerate(zip(facts, info_layers)):
        for k in ("name", "x", "y", "w", "h", "opacity", "visible"):
            if a[k] != b[k]:
                raise SystemExit("FAIL[%s]: 第 %d 层字段 %s 对不上：psd-tools=%r，我们=%r"
                                 % (name, i, k, a[k], b[k]))
        if a["blend"] != b["blend"]:
            raise SystemExit("FAIL[%s]: 第 %d 层混合模式对不上：psd-tools=%r，我们=%r"
                             % (name, i, a["blend"], b["blend"]))

    # ③ 按层重算（psd-tools `composite(force=True)` 叠白纸）：只对 `main` 有约束
    #    —— 带非 normal 混合的层它按 normal 混（见 SCENES 的注释），那条路不可信。
    forced = force_white(psd)
    diff = maxd = 0
    for a, b in zip(forced, render_px):
        d = abs(a - b)
        if d:
            diff += 1
            if d > maxd:
                maxd = d
    if name == "main" and maxd > 1:
        raise SystemExit("FAIL[main]: psd-tools 按层重算的合成图与我们的 render 差得太多："
                         "%d 字节 / 最大差 %d" % (diff, maxd))

    return {
        "cli_script": script,
        "width": width,
        "height": height,
        "psd_sha256": sha(psd_bytes),
        "bytes": len(psd_bytes),
        "render_sha256": sha(render_px),
        # CLI 信封里的 `render_sha256` 是**PNG 字节**的 sha（缓存键）：门禁离线
        # 拿它当"渲染没变"的活判据（不用解码 PNG）
        "render_png_sha256": render["render_sha256"],
        "pillow_composite_sha256": sha(pillow_px),
        "psd_tools_force_white_sha256": sha(forced),
        "psd_tools_force_white_diff_bytes": diff,
        "psd_tools_force_white_max_diff": maxd,
        "layers": facts,
    }


def gather():
    return {
        "note": "由 tools/check_psd_with_oracle.py 生成：psd-tools + Pillow 读**我们写出的** PSD",
        "scenes": {name: gather_one(name, script) for name, script in SCENES.items()},
    }


def main():
    check = "--check" in sys.argv
    before = None
    if os.path.exists(JSON_PATH):
        before = json.load(open(JSON_PATH, encoding="utf-8"))
    data = gather()

    text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if check:
        if before != data:
            print("FAIL: roundtrip.json 不是最新（重新生成后要一起提交）")
            return 1
        print("roundtrip 幂等 ✓（%s）"
              % "、".join("%s：%d 字节 / %d 层 / 合成图 %s…"
                          % (n, sc["bytes"], len(sc["layers"]), sc["psd_sha256"][:12])
                          for n, sc in sorted(data["scenes"].items())))
        return 0

    with open(JSON_PATH, "w", encoding="utf-8") as fp:
        fp.write(text)
    for name, sc in sorted(data["scenes"].items()):
        print("写出 roundtrip_%s.psd（%d 字节，%d 层）" % (name, sc["bytes"], len(sc["layers"])))
        print("  合成图：Pillow 与 render 逐位相同 ✓")
        print("  层表：%d 层逐字段与 psd-tools 一致 ✓（含混合模式）" % len(sc["layers"]))
        print("  按层重算（psd-tools 叠白纸）：%d 字节不同、最大差 %d"
              % (sc["psd_tools_force_white_diff_bytes"],
                 sc["psd_tools_force_white_max_diff"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
