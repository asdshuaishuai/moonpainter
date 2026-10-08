#!/usr/bin/env python3
"""生成 PSD 语料 + 期望值（③ PSD 兼容的**独立 oracle**）。

为什么要这个脚本：本仓库的 PSD 读写是 MoonBit 实现的。如果"期望值"也用我们自己的
实现算出来，那就是自己给自己判卷（本仓库反复栽过的"判据自己满足自己"）。口径：

  * **写语料的人**：`psd-tools`（第三方 Python 实现，MIT），**分层与平铺都由它写出**
    —— 是真实的第三方产物，不是我们按规范手搓的字节。
  * **算期望的人**：两张独立的脸 ——
      ① `Pillow` 读回**合成图**（`PSDImage` → RGBA 逐字节）；
      ② `psd-tools` 读回**层表**（名字 / 矩形 / 不透明度 / 可见性 / 混合模式）
         与每层自己的像素。
    两个读法对不上就在生成时报错（**不会写出坏语料**）。
  * 结果：PSD 文件 + `corpus.mbt`（base64 + 期望 sha）+ `corpus.json`（可审计）一起提交，
    `codec/psd_test.mbt` 与 `verify.sh#psd-corpus` **离线**比对 —— 跑门禁的机器
    **不需要** psd-tools / Pillow（期望值是生成时钉死的）。

⚠️ 唯一"我们自己"的代码是**读回校验的第二遍**（`tools/check_psd_with_oracle.py`：
把 MoonBit 写出的 PSD 交给 psd-tools + Pillow 读），那是**反向**的独立验证。

依赖（只在重新生成语料时需要）：
    python3 -m venv /tmp/psdvenv && /tmp/psdvenv/bin/pip install psd-tools
用法：
    /tmp/psdvenv/bin/python tools/make_psd_corpus.py           # 重新生成
    /tmp/psdvenv/bin/python tools/make_psd_corpus.py --check    # 幂等校验（改了没提交）
⚠️ 重新生成会改 `corpus.mbt` / `corpus.json`；版本号写进语料（psd-tools/Pillow）。
"""

import base64
import hashlib
import base64
import io
import json
import os
import struct
import sys

from PIL import Image
from psd_tools import PSDImage
from psd_tools.constants import BlendMode, ColorMode, Compression

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "codec", "testdata", "psd")

import psd_tools as _pt

PSD_TOOLS = _pt.__version__
PILLOW = getattr(Image, "__version__", "?")


def sha(b):
    return hashlib.sha256(b).hexdigest()
def compose_normal(width, height, layers):
    """按 Normal 混合合成（本语料只用 Normal）：底透明 + 层序叠加。"""
    acc = [0.0] * (width * height * 4)
    for L in layers:
        if not L["visible"]:
            continue
        w, h = L["w"], L["h"]
        a_layer = L["opacity"] / 255.0
        for yy in range(h):
            for xx in range(w):
                di = ((L["y"] + yy) * width + (L["x"] + xx)) * 4
                si = (yy * w + xx) * 4
                sa = L["rgba"][si + 3] / 255.0 * a_layer
                if sa <= 0:
                    continue
                for c in range(3):
                    sc = L["rgba"][si + c] / 255.0
                    dc = acc[di + c]
                    acc[di + c] = sc * sa + dc * (1 - sa)
                acc[di + 3] = sa + acc[di + 3] * (1 - sa)
    out = bytearray()
    for i in range(width * height):
        for c in range(4):
            out.append(max(0, min(255, int(round(acc[i * 4 + c] * 255)))))
    return bytes(out)


# ---------------------------------------------------------------------------
# 语料清单
# ---------------------------------------------------------------------------
def flat_case(name, mode, size, build, compression):
    """用 psd-tools 写一张**平铺** PSD（0 层 + 合成图），期望值双读。"""
    im = Image.new("RGBA", size)
    build(im)
    pil_mode = "RGB" if mode == "RGB" else ("L" if mode == "L" else "RGBA")
    psd = PSDImage.new(mode=pil_mode, size=size)
    path = os.path.join(OUT, name + ".psd")
    psd.save(path, compression=compression)
    raw = open(path, "rb").read()
    # ①Pillow 读回合成
    pil = Image.open(io.BytesIO(raw)).convert("RGBA").tobytes()
    # ②psd-tools 读回合成（两张脸必须一致）
    back = PSDImage.open(io.BytesIO(raw))
    ref = back.composite if not callable(back.composite) else back.composite()
    if ref is None:
        raise SystemExit("%s: psd-tools 读不出合成图" % name)
    ref_rgba = ref.convert("RGBA").tobytes()
    if ref_rgba != pil:
        raise SystemExit("%s: Pillow 与 psd-tools 的合成图不一致（%s vs %s）"
                         % (name, sha(pil)[:12], sha(ref_rgba)[:12]))
    found = 0
    off = 26
    cmd_len, = struct.unpack(">I", raw[off:off + 4])
    off += 4 + cmd_len
    res_len, = struct.unpack(">I", raw[off:off + 4])
    off += 4 + res_len
    lm_len, = struct.unpack(">I", raw[off:off + 4])
    off += 4
    if lm_len:
        off += lm_len
    comp, = struct.unpack(">H", raw[off:off + 2])
    ref_png, tol = _ref_over_white(back)
    return dict(name=name, kind="flat", file=name + ".psd", sha256=sha(raw),
                width=size[0], height=size[1], psd_mode=pil_mode,
                compression=comp, composite_sha256=sha(pil),
                render_ref_png=ref_png, render_tol=tol,
                bytes=len(raw), layers=[],
                note="psd-tools 写出 / Pillow 与 psd-tools 双读合成图（compression=%d）" % comp)


def pil_case(name, mode, size, build, compression=Compression.RLE):
    """`PSDImage.frompil` 写的 PSD：**合成图**按指定压缩（RLE）——平铺 PSD 的
    合成压缩这一格只有这条路径给得出来（`PSDImage.new` 的合成恒为 RAW）。
    期望值同样双读（Pillow + psd-tools）。"""
    im = Image.new(mode if mode != "L" else "L", size)
    build(im)
    if mode == "RGB":
        im = im.convert("RGB")
    elif mode == "RGBA":
        im = im.convert("RGBA")
    psd = PSDImage.frompil(im)
    path = os.path.join(OUT, name + ".psd")
    psd.save(path, compression=compression)
    raw = open(path, "rb").read()
    pil = Image.open(io.BytesIO(raw)).convert("RGBA").tobytes()
    back = PSDImage.open(io.BytesIO(raw))
    comp_img = back.composite if not callable(back.composite) else back.composite()
    ref_rgba = comp_img.convert("RGBA").tobytes()
    if ref_rgba != pil:
        raise SystemExit("%s: Pillow 与 psd-tools 的合成图不一致" % name)
    off = 26
    cmd_len, = struct.unpack(">I", raw[off:off + 4])
    off += 4 + cmd_len
    res_len, = struct.unpack(">I", raw[off:off + 4])
    off += 4 + res_len
    lm_len, = struct.unpack(">I", raw[off:off + 4])
    off += 4
    if lm_len:
        off += lm_len
    comp, = struct.unpack(">H", raw[off:off + 2])
    table = []
    for L in back:
        table.append(dict(name=L.name, x=L.left, y=L.top, w=L.width, h=L.height,
                          opacity=L.opacity, visible=L.visible,
                          blend=_blend_name(L),
                          rgba_sha256=sha(L.topil().convert("RGBA").tobytes())))
    ref_png, tol = _ref_over_white(back)
    return dict(name=name, kind="flat", file=name + ".psd", sha256=sha(raw),
                width=size[0], height=size[1], psd_mode=mode,
                compression=comp, composite_sha256=sha(pil), bytes=len(raw),
                render_ref_png=ref_png, render_tol=tol,
                layers=table,
                note="psd-tools frompil 写出 / 双读合成图 / 层表由 psd-tools 读回（compression=%d）" % comp)


def layered_case(name, width, height, layers, compression=Compression.RLE):
    """分层 PSD：psd-tools 写 + 双读（层表由 psd-tools 读回、合成图两张脸对齐）。"""
    psd = PSDImage.new(mode="RGB", size=(width, height))
    for L in layers:
        pl = psd.create_pixel_layer(
            Image.frombytes("RGBA", (L["w"], L["h"]), L["rgba"]),
            name=L["name"], top=L["y"], left=L["x"],
            opacity=L["opacity"], compression=compression, blend_mode=BlendMode.NORMAL)
        # `create_pixel_layer` 没有 visible 参数（读回来恒 True）——隐藏层要**建好之后**
        # 设属性。这不是我们写的字节的"自由度"，而是第三方 API 的形状。
        if not L["visible"]:
            pl.visible = False
    path = os.path.join(OUT, name + ".psd")
    psd.save(path, compression=compression)
    raw = open(path, "rb").read()
    back = PSDImage.open(io.BytesIO(raw))
    pil = Image.open(io.BytesIO(raw)).convert("RGBA").tobytes()
    comp_img = back.composite if not callable(back.composite) else back.composite()
    ref = comp_img.convert("RGBA").tobytes()
    if pil != ref:
        raise SystemExit("%s: Pillow 与 psd-tools 的合成图不一致" % name)
    table = []
    for L in back:  # 自底向上
        table.append(dict(name=L.name, x=L.left, y=L.top, w=L.width, h=L.height,
                          opacity=L.opacity, visible=L.visible,
                          blend=_blend_name(L),
                          rgba_sha256=sha(L.topil().convert("RGBA").tobytes())))
    # 与**输入**对齐一次（psd-tools 读回来的层序/参数必须就是我们要写的那份）
    if len(table) != len(layers):
        raise SystemExit("%s: 读回 %d 层，写了 %d 层" % (name, len(table), len(layers)))
    for got, want in zip(table, layers):
        if (got["name"], got["x"], got["y"], got["w"], got["h"],
                got["opacity"], got["visible"]) != (
                want["name"], want["x"], want["y"], want["w"], want["h"],
                want["opacity"], want["visible"]):
            raise SystemExit("%s: 层参数往返不一致\n  got=%r\n  want=%r" % (name, got, want))
    ref_png, tol = _ref_over_white(back)
    return dict(name=name, kind="layered", file=name + ".psd", sha256=sha(raw),
                width=width, height=height, compression=int(compression),
                composite_sha256=sha(pil), bytes=len(raw), layers=table,
                render_ref_png=ref_png, render_tol=tol,
                note="psd-tools 写出 / 层表由 psd-tools 读回 / 合成图两张脸一致")


def rgba_solid(w, h, color):
    return bytes(color) * (w * h)


# ---------------------------------------------------------------------------
# 边界样本：本仓库**明确拒绝**的 PSD（"不降级"的证据）
# ---------------------------------------------------------------------------
def bad_case(name, psd, want, note):
    """写一张第三方能读、我们**必须拒绝**的 PSD。

    合法性由第三方读回来证：`psd-tools` 打得开、层数对得上（拒绝一个坏文件
    不算本事，拒绝一个**好文件**才是边界声明）。
    """
    path = os.path.join(OUT, name + ".psd")
    psd.save(path)
    raw = open(path, "rb").read()
    back = PSDImage.open(io.BytesIO(raw))
    return dict(name=name, kind="boundary", file=name + ".psd", sha256=sha(raw),
                want=want, bytes=len(raw), note=note,
                third_party_ok="psd-tools 打得开（%d 层）" % len(list(back)))


def zip_case(name, compression, want):
    layer = dict(name="zip layer", x=0, y=0, w=4, h=4, opacity=255, visible=True,
                 rgba=rgba_solid(4, 4, (10, 200, 10, 255)))
    psd = PSDImage.new(mode="RGB", size=(5, 5))
    psd.create_pixel_layer(Image.frombytes("RGBA", (4, 4), layer["rgba"]),
                           name=layer["name"], compression=compression)
    return bad_case(name, psd, want,
                    "第三方写出、压缩方式 = %s（我们能读的只有 0/1）" % int(compression))


def depth_case(name, depth, want):
    psd = PSDImage.new(mode="RGB", size=(4, 4), depth=depth)
    return bad_case(name, psd, want, "第三方写出、位深 = %d" % depth)


def cmyk_case(name, want):
    psd = PSDImage.new(mode="CMYK", size=(4, 4))
    return bad_case(name, psd, want, "第三方写出、色彩模式 = CMYK")


def group_case(name, want):
    psd = PSDImage.new(mode="RGB", size=(6, 6))
    g = psd.create_group(name="a group")
    g.create_pixel_layer(Image.new("RGBA", (3, 3), (255, 0, 0, 255)), name="inner")
    return bad_case(name, psd, want, "第三方写出、带一个图层组（section divider）")


def patch_uniform(raw, off, h, value):
    """把"每行一个重复游程"的通道数据里每行的值字节改成 `value`（长度不变）。

    只接受"每行 2 字节 + 第一条指令是重复段"的形状；不是这个形状就报错，
    绝不在没看懂的地方乱改字节。
    """
    comp, = struct.unpack(">H", raw[off:off + 2])
    if comp != 1:
        raise SystemExit("patch_uniform：只做 RLE（comp=%d）" % comp)
    counts = [struct.unpack(">H", raw[off + 2 + 2 * i:off + 4 + 2 * i])[0]
              for i in range(h)]
    q = off + 2 + 2 * h
    for c in counts:
        if c != 2 or raw[q] < 0x80:
            raise SystemExit("patch_uniform：第 %d 行游程不是「2 字节重复段」" % counts.index(c))
        raw[q + 1] = value
        q += c


def _blend_name(layer):
    """混合模式名：psd-tools 的枚举 `str()` 会带 `blendmode.` 前缀。

    JSON 与 MoonBit 表必须是**同一个名字**（否则门禁报的是"名字不一样"，
    而两边其实在说同一件事）。
    """
    return str(layer.blend_mode).lower().replace("blendmode.", "")


def _png_bytes(img):
    """Pillow 编码的 PNG 字节（渲染 oracle 的参考图）。

    期望值**生成时**算好写进语料，门禁离线跑（不需要 Pillow / psd-tools）。
    """
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _ref_over_white(psd):
    """**按层重算**的合成图叠白纸（白纸是本仓库画布语义）。

    为什么不用存图那份合成图：它在无像素处是**黑底**且不带 alpha（实测
    `channels=3`），拿它比会把"白纸 vs 黑底"当成差异——第一版就这么比，
    `layered_three` 报 66 字节不同、最大差 255，看着像我们读丢了东西。
    `composite(force=True)` 才是"从层重算"，带 alpha。
    容差：图层不透明度不是 0/255 时，浮点（psd-tools）与定点（我们）差 1。
    """
    comp = psd.composite(force=True).convert("RGBA")
    white = Image.new("RGBA", comp.size, (255, 255, 255, 255))
    # 容差判据（**实测**出来的，不是猜的）：
    # - 图层不透明度不是 0/255：`layered_two` 的 128/255 过渡带差 1；
    # - 合成图里有**半透明**像素（alpha 1..254）：`flat_rgba_rle_comp` 差 1
    #   （Pillow 的 alpha_composite 与我们的定点混合在进位上不同）。
    # 两类都是"第三方用浮点、我们用定点"，不是读丢了东西；余下的例子必须逐位相同。
    # 容差**量**出来，不猜：把"合成图叠白纸"这一步用**我们的定点公式**
    # （`(c*a + 255*(255-a))/255` 整数除）算一遍，与 Pillow 的
    # `alpha_composite`（浮点 + 它的进位）逐位比；有差才声明 tol=1。
    # ⚠️ 第一版按"有半透明像素就 tol=1"猜，结果 `flat_rgba_alpha`（有半透明
    # 但两边正好逐位相同）被无谓放宽，而 `flat_rgba_rle_comp` 的差正是进位；
    # 判据比现象松，就等于没有判据。
    ref = Image.alpha_composite(white, comp).convert("RGBA")
    src = comp.tobytes()
    ours = bytearray()
    for i in range(comp.size[0] * comp.size[1]):
        a = src[i * 4 + 3]
        for k in range(3):
            ours.append((src[i * 4 + k] * a + 255 * (255 - a)) // 255)
        ours.append(255)
    tol = 1 if bytes(ours) != ref.tobytes() else 0
    return _png_bytes(ref), tol


def layer_channel_regions(raw):
    """[ {cid: (offset, length)} ]，自底向上（顺序与文件里一致）。"""
    off = 26
    cl, = struct.unpack(">I", raw[off:off + 4]); off += 4 + cl
    rl, = struct.unpack(">I", raw[off:off + 4]); off += 4 + rl
    lm, = struct.unpack(">I", raw[off:off + 4]); off += 4
    if lm == 0:
        return []
    info_len, = struct.unpack(">I", raw[off:off + 4]); off += 4
    nlay, = struct.unpack(">h", raw[off:off + 2]); off += 2
    p = off
    chans = []
    for _ in range(abs(nlay)):
        p += 16
        nch, = struct.unpack(">H", raw[p:p + 2]); p += 2
        cs = []
        for _c in range(nch):
            cid, clen = struct.unpack(">hI", raw[p:p + 6]); p += 6
            cs.append((cid, clen))
        p += 12
        ex, = struct.unpack(">I", raw[p:p + 4]); p += 4 + ex
        chans.append(cs)
    regions = []
    q = p  # 通道数据紧跟所有层记录之后
    for cs in chans:
        m = {}
        for cid, clen in cs:
            m[cid] = (q, clen)
            q += clen
        regions.append(m)
    return regions


def mask_case(name, want):
    """带**真实**像素蒙版的 PSD（我们拒绝）。

    psd-tools 没有"设置图层蒙版"的 API（`PixelLayer.mask` 只读），所以做法是
    **字节级改写第三方写出的文件里那个 -2 蒙版通道的 RLE 流**：把它从"全 255
    （全可见的占位蒙版）"改成"全 0（全遮挡）"——**长度一个字节都不变**
    （`fb ff` → `fb 00`：重复段计数与游程长度相同），所以文件结构与合法性完全不变。
    读回来验明蒙版真的变黑了（psd-tools 的 mask 像素最小值 = 0）。
    """
    psd = PSDImage.new(mode="RGB", size=(6, 6))
    psd.create_pixel_layer(Image.new("RGBA", (4, 4), (255, 0, 0, 255)), name="masked")
    buf = io.BytesIO()
    psd.save(buf)
    raw = bytearray(buf.getvalue())
    # 定位第一条图层记录的通道表（拿 -2 通道的数据长度与起点）
    off = 26
    cmd_len, = struct.unpack(">I", raw[off:off + 4]); off += 4 + cmd_len
    res_len, = struct.unpack(">I", raw[off:off + 4]); off += 4 + res_len
    lm, = struct.unpack(">I", raw[off:off + 4]); off += 4
    info_len, = struct.unpack(">I", raw[off:off + 4]); off += 4
    nlay, = struct.unpack(">h", raw[off:off + 2]); off += 2
    p = off
    p += 16
    nch, = struct.unpack(">H", raw[p:p + 2]); p += 2
    chans = []
    for _ in range(nch):
        cid, clen = struct.unpack(">hI", raw[p:p + 6]); p += 6
        chans.append([cid, clen])
    p += 8 + 4
    ex, = struct.unpack(">I", raw[p:p + 4]); p += 4 + ex
    # 通道数据紧跟所有层记录之后（`p` 此刻正是第一条通道数据的起点）
    q = p
    mask_off = None
    for cid, clen in chans:
        if cid == -2:
            mask_off = q
        q += clen
    if mask_off is None:
        raise SystemExit("%s: 找不到 -2 蒙版通道" % name)
    mlen = dict(chans)[-2]
    blob = bytes(raw[mask_off:mask_off + mlen])
    patched = blob.replace(b"\xff", b"\x00", 1)  # 只改游程的字节值（长度不变）
    if patched == blob:
        raise SystemExit("%s: 蒙版通道里没有可改写的游程字节" % name)
    raw[mask_off:mask_off + mlen] = patched
    path = os.path.join(OUT, name + ".psd")
    open(path, "wb").write(bytes(raw))
    back = PSDImage.open(io.BytesIO(bytes(raw)))
    l0 = list(back)[0]
    if l0.mask is None:
        raise SystemExit("%s: 读回来没有蒙版" % name)
    mn = min(l0.mask.topil().convert("L").tobytes())
    if mn != 0:
        raise SystemExit("%s: 蒙版没有变黑（min=%d）" % (name, mn))
    return dict(name=name, kind="boundary", file=name + ".psd", sha256=sha(bytes(raw)),
                want=want, bytes=len(raw),
                note="第三方写出 + 字节级把 -2 蒙版通道的游程改成 0（长度不变；psd-tools 读回 mask 最小值=0）",
                third_party_ok="psd-tools 读回 mask 像素 min=0")


def alpha_case(name, rgba, want_note=""):
    """半透明像素的层：把 psd-tools 写反的那两个通道**对调**（长度不变）。

    psd-tools 的 `create_pixel_layer(RGBA)` 会把输入的 alpha 写进 **-2 蒙版通道**
    （-1 恒 255）——那是它的实现选择，不是 PSD 的规矩：Photoshop 写的是 -1 = alpha、
    蒙版是另一个东西。这里把两个通道的**游程值字节**对调（`fd 80` ↔ `fd ff`，
    长度一个字节不变），得到"Photoshop 会写的形状"，再用 psd-tools 验：
    层 alpha = 128、蒙版全 255。期望值取 `topil()`。
    """
    w = h = 4
    psd = PSDImage.new(mode="RGB", size=(w, h))
    psd.create_pixel_layer(Image.frombytes("RGBA", (w, h), rgba), name="semi")
    buf = io.BytesIO()
    psd.save(buf)
    raw = bytearray(buf.getvalue())
    regs = layer_channel_regions(bytes(raw))[0]
    a_off, a_len = regs[-1]
    m_off, m_len = regs[-2]
    # ⚠️ 通道数据 = 压缩 u16 + **行长度表**（h 个 u16）+ 各行游程；游程里不是
    # "每两个字节一对"就完事（表头也在里面）——第一版按奇偶位置改，把行长度表
    # 改成了 0x80，psd-tools 当场报 "128 is not a valid Compression"。
    # 正确做法：按行长度表定位每行游程，改**该行游程的最后一个字节**（值字节）。
    patch_uniform(raw, a_off, h, 0x80)
    patch_uniform(raw, m_off, h, 0xFF)
    path = os.path.join(OUT, name + ".psd")
    open(path, "wb").write(bytes(raw))
    back = PSDImage.open(io.BytesIO(bytes(raw)))
    l0 = list(back)[0]
    pil = l0.topil().convert("RGBA")
    if min(pil.tobytes()[3::4]) != 128:
        raise SystemExit("%s: 层 alpha 不是 128（对调没成功）" % name)
    if l0.mask is not None and min(l0.mask.topil().convert("L").tobytes()) != 255:
        raise SystemExit("%s: 蒙版不是全可见" % name)
    _ref, _tol = _ref_over_white(back)
    return dict(name=name, kind="layered", file=name + ".psd", sha256=sha(bytes(raw)),
                width=w, height=h, compression=0,
                render_ref_png=_ref, render_tol=_tol,
                composite_sha256=sha(Image.open(io.BytesIO(bytes(raw))).convert("RGBA").tobytes()),
                bytes=len(raw), layers=[dict(name="semi", x=0, y=0, w=w, h=h,
                                             opacity=255, visible=True, blend="normal",
                                             rgba_sha256=sha(pil.tobytes()))],
                note="psd-tools 写出 + 把 -1/-2 通道的游程值对调（长度不变）" + want_note)


def two_layer_as_bad(name, width, height, layers, want):
    """写一张**合法**的分层 PSD，但期望我们拒绝（蒙版那两例用）。"""
    psd = PSDImage.new(mode="RGB", size=(width, height))
    for L in layers:
        psd.create_pixel_layer(Image.frombytes("RGBA", (L["w"], L["h"]), L["rgba"]),
                               name=L["name"], top=L["y"], left=L["x"],
                               opacity=L["opacity"], compression=Compression.RLE)
    path = os.path.join(OUT, name + ".psd")
    psd.save(path, compression=Compression.RLE)
    raw = open(path, "rb").read()
    back = PSDImage.open(io.BytesIO(raw))
    masks = [L.mask for L in back]
    if not any(m is not None and min(m.topil().convert("L").tobytes()) < 255 for m in masks):
        raise SystemExit("%s: 这张文件里没有非平凡的蒙版，不配当边界样本" % name)
    return dict(name=name, kind="boundary", file=name + ".psd", sha256=sha(raw),
                want=want, bytes=len(raw),
                note="第三方写出：psd-tools 把 RGBA 的 alpha 写进 -2 蒙版通道 ⇒ 真有非平凡蒙版",
                third_party_ok="psd-tools 读回蒙版 min=%d" % min(
                    m.topil().convert("L").tobytes()) if False else "psd-tools 读回蒙版非全可见")


def probe_compressions(raw):
    """文件里**真实**的压缩字段（别把"我们想要的"写进语料）。"""
    off = 26
    cl, = struct.unpack(">I", raw[off:off + 4]); off += 4 + cl
    rl, = struct.unpack(">I", raw[off:off + 4]); off += 4 + rl
    lm, = struct.unpack(">I", raw[off:off + 4]); off += 4
    layer_comps = []
    if lm:
        li, = struct.unpack(">I", raw[off:off + 4])
        q = off + 4
        nlay, = struct.unpack(">h", raw[q:q + 2]); q += 2
        for _ in range(abs(nlay)):
            q += 16
            nch, = struct.unpack(">H", raw[q:q + 2]); q += 2
            chans = []
            for _c in range(nch):
                cid, clen = struct.unpack(">hI", raw[q:q + 6]); q += 6
                chans.append((cid, clen))
            layer_comps.append(chans)
            q += 12
            ex, = struct.unpack(">I", raw[q:q + 4]); q += 4 + ex
        off = off + 4 + li + 4
    comp, = struct.unpack(">H", raw[off:off + 2])
    return comp, layer_comps


def mbt_str(s):
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def main():
    check = "--check" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    cases = []

    # ①平铺（0 层 + 合成图）：合成图 RAW 的六例
    cases.append(flat_case("flat_rgb_rle", "RGB", (12, 5),
                           lambda im: [im.putpixel((x, y), (x * 20 % 256, y * 40 % 256, 90))
                                       for y in range(5) for x in range(12)],
                           Compression.RLE))
    cases.append(flat_case("flat_rgb_raw", "RGB", (9, 4),
                           lambda im: [im.putpixel((x, y), (7 * x % 256, 255 - 9 * y, x + y))
                                       for y in range(4) for x in range(9)],
                           Compression.RAW))
    cases.append(flat_case("flat_rgba_alpha", "RGBA", (9, 7),
                           lambda im: [im.putpixel((x, y), (255, 0, 0, (x * 30) % 256))
                                       for y in range(7) for x in range(9)],
                           Compression.RLE))
    cases.append(flat_case("flat_gray", "L", (8, 8),
                           lambda im: [im.putpixel((x, y), (x * 8 + y * 3) % 256)
                                       for y in range(8) for x in range(8)],
                           Compression.RLE))
    cases.append(flat_case("flat_1x1", "RGB", (1, 1),
                           lambda im: im.putpixel((0, 0), (17, 34, 51)),
                           Compression.RAW))
    cases.append(flat_case("flat_7x3", "RGB", (7, 3),
                           lambda im: [im.putpixel((x, y), (200 - x * 7, 30 + y * 11, 255))
                                       for y in range(3) for x in range(7)],
                           Compression.RLE))
    # ①b 合成图 **RLE**（`frompil` 路径；`PSDImage.new` 的合成恒 RAW）
    cases.append(pil_case("flat_rgb_rle_comp", "RGB", (11, 6),
                          lambda im: [im.putpixel((x, y), (x * 11 % 256, 60, y * 33 % 256))
                                      for y in range(6) for x in range(11)]))
    cases.append(pil_case("flat_rgba_rle_comp", "RGBA", (6, 6),
                          lambda im: [im.putpixel((x, y), (0, 255, 0, x * 40 % 256))
                                      for y in range(6) for x in range(6)]))
    # ②分层（RLE）：底红 6×4 @ (1,1)，上蓝 4×4 @ (3,2) opacity=128
    L1 = dict(name="bottom red", x=1, y=1, w=6, h=4, opacity=255, visible=True,
              rgba=rgba_solid(6, 4, (255, 0, 0, 255)))
    L2 = dict(name="top blue", x=3, y=2, w=4, h=4, opacity=128, visible=True,
              rgba=rgba_solid(4, 4, (0, 0, 255, 255)))
    cases.append(layered_case("layered_two", 10, 7, [L1, L2]))
    H1 = dict(name="shown", x=0, y=0, w=5, h=5, opacity=255, visible=True,
              rgba=rgba_solid(5, 5, (0, 200, 0, 255)))
    H2 = dict(name="hidden", x=2, y=2, w=5, h=5, opacity=255, visible=False,
              rgba=rgba_solid(5, 5, (255, 255, 0, 255)))
    cases.append(layered_case("layered_hidden", 8, 8, [H1, H2]))
    T2 = dict(name="solid", x=1, y=1, w=3, h=3, opacity=255, visible=True,
              rgba=rgba_solid(3, 3, (250, 250, 250, 255)))
    cases.append(layered_case("layered_three", 6, 6, [
        dict(name="opaque", x=0, y=0, w=3, h=3, opacity=255, visible=True,
             rgba=rgba_solid(3, 3, (120, 30, 200, 255))), T2]))
    cases.append(alpha_case("layered_alpha", bytes([200, 100, 50, 128]) * 16))

    for c in cases:
        comp, lay = probe_compressions(open(os.path.join(OUT, c["file"]), "rb").read())
        c["compression"] = comp
        c["layer_channel_counts"] = lay
    # 语料里的期望值只保留"能被 MoonBit 侧比对"的部分（把权威值钉死）
    for c in cases:
        raw = open(os.path.join(OUT, c["file"]), "rb").read()
        c["sha256"] = sha(raw)
        c["bytes"] = len(raw)

    # ③边界样本（我们必须**拒绝**，而第三方读得开）
    bad = []
    bad.append(zip_case("boundary_zip", Compression.ZIP, "压缩方式 2 不支持"))
    bad.append(zip_case("boundary_zip_pred", Compression.ZIP_WITH_PREDICTION,
                        "压缩方式 3 不支持"))
    bad.append(depth_case("boundary_depth16", 16, "位深 16 不支持"))
    bad.append(cmyk_case("boundary_cmyk", "色彩模式 CMYK 不支持"))
    bad.append(group_case("boundary_group", "图层组"))
    bad.append(mask_case("boundary_mask", "像素蒙版"))
    # psd-tools 把 RGBA 的 alpha 写进 -2 蒙版通道 ⇒ 那张文件里**真的有**一个非平凡
    # 蒙版（全 0 = 全遮挡、全 128 = 半遮挡）——我们拒绝，不是"读不了"，是"读进来
    # 也表达不了，不许静默丢"。这两例保留原样当边界的**证据**。
    bad.append(two_layer_as_bad("layered_halfalpha_as_mask", 5, 5, [
        dict(name="half", x=0, y=0, w=4, h=4, opacity=200, visible=True,
             rgba=bytes([200, 100, 50, 128]) * 16)], "像素蒙版"))
    bad.append(two_layer_as_bad("layered_transparent_as_mask", 6, 6, [
        dict(name="empty alpha", x=0, y=0, w=4, h=4, opacity=255, visible=True,
             rgba=rgba_solid(4, 4, (10, 20, 30, 0))),
        dict(name="solid", x=1, y=1, w=3, h=3, opacity=255, visible=True,
             rgba=rgba_solid(3, 3, (250, 250, 250, 255)))], "像素蒙版"))

    corpus = dict(psd_tools=PSD_TOOLS, pillow=PILLOW, cases=cases, boundary=bad)

    # ---- 生成 MoonBit 语料表 ----
    mb = []
    mb.append('///|')
    mb.append('/// **生成的 PSD 语料表**（`tools/make_psd_corpus.py`；psd-tools %s / Pillow %s）。' % (PSD_TOOLS, PILLOW))
    mb.append('/// 别手改：语料与期望值是**第三方实现**（psd-tools 写、Pillow + psd-tools 读）算出来的，')
    mb.append('/// 重新生成后跑 `python3 tools/make_psd_corpus.py --check`（用 venv 的 python）确认幂等。')
    mb.append('///')
    mb.append('/// ⚠️ 这张表是 `_test.mbt`（只在测试编译时进包）：`.psd` 文件本身也提交在')
    mb.append('/// `codec/testdata/psd/`，`verify.sh#psd-corpus` 走 CLI 用同一批文件。')
    mb.append('///')
    mb.append('/// 一层语料的期望（层表 + 每层 RGBA 的 sha256）。')
    mb.append('pub struct PsdLayerCase {')
    mb.append('  name : String')
    mb.append('  x : Int')
    mb.append('  y : Int')
    mb.append('  w : Int')
    mb.append('  h : Int')
    mb.append('  opacity : Int')
    mb.append('  visible : Bool')
    mb.append('  blend : String')
    mb.append('  rgba_sha : String')
    mb.append('}')
    mb.append('')
    mb.append('///|')
    mb.append('/// 一例 PSD 语料（`b64` 是文件字节；期望值来自第三方实现）。')
    mb.append('pub struct PsdCase {')
    mb.append('  name : String')
    mb.append('  file : String')
    mb.append('  b64 : String')
    mb.append('  width : Int')
    mb.append('  height : Int')
    mb.append('  composite_sha : String')
    mb.append('  layers : Array[PsdLayerCase]')
    mb.append('}')
    mb.append('')
    mb.append('///|')
    mb.append('/// 一例**必须被拒绝**的边界样本（`want` = 错误里必须出现的话）。')
    mb.append('pub struct PsdBadCase {')
    mb.append('  name : String')
    mb.append('  file : String')
    mb.append('  b64 : String')
    mb.append('  want : String')
    mb.append('  note : String')
    mb.append('}')
    mb.append('')
    mb.append('///|')
    mb.append('pub let psd_ok_cases : Array[PsdCase] = [')
    for c in cases:
        raw = open(os.path.join(OUT, c["file"]), "rb").read()
        b64 = base64.b64encode(raw).decode()
        mb.append('  {')
        mb.append('    name: %s,' % mbt_str(c["name"]))
        mb.append('    file: %s,' % mbt_str(c["file"]))
        mb.append('    b64: %s,' % mbt_str(b64))
        mb.append('    width: %d,' % c["width"])
        mb.append('    height: %d,' % c["height"])
        mb.append('    composite_sha: %s,' % mbt_str(c["composite_sha256"]))
        mb.append('    layers: [')
        for L in c["layers"]:
            mb.append('      {')
            mb.append('        name: %s,' % mbt_str(L["name"]))
            mb.append('        x: %d,' % L["x"])
            mb.append('        y: %d,' % L["y"])
            mb.append('        w: %d,' % L["w"])
            mb.append('        h: %d,' % L["h"])
            mb.append('        opacity: %d,' % L["opacity"])
            mb.append('        visible: %s,' % ("true" if L["visible"] else "false"))
            mb.append('        blend: %s,' % mbt_str(L["blend"].replace("blendmode.", "")))
            mb.append('        rgba_sha: %s,' % mbt_str(L["rgba_sha256"]))
            mb.append('      },')
        mb.append('    ],')
        mb.append('  },')
    mb.append(']')
    mb.append('')
    mb.append('///|')
    mb.append('pub let psd_bad_cases : Array[PsdBadCase] = [')
    for c in bad:
        raw = open(os.path.join(OUT, c["file"]), "rb").read()
        b64 = base64.b64encode(raw).decode()
        mb.append('  {')
        mb.append('    name: %s,' % mbt_str(c["name"]))
        mb.append('    file: %s,' % mbt_str(c["file"]))
        mb.append('    b64: %s,' % mbt_str(b64))
        mb.append('    want: %s,' % mbt_str(c["want"]))
        mb.append('    note: %s,' % mbt_str(c["note"]))
        mb.append('  },')
    mb.append(']')
    mb.append('')
    mbt = "\n".join(mb)

    # json 里去掉 base64（体积）——期望值可审计，字节在 .psd 里
    for c in cases:
        c.pop("b64", None)
    json_txt = json.dumps(corpus, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    mbt_path = os.path.join(OUT, "corpus.mbt")
    json_path = os.path.join(OUT, "corpus.json")

    # ---- 生成 agent 侧的**渲染参考图**（也是生成的，别手改）----
    rb = []
    rb.append('///|')
    rb.append('/// **生成的 PSD 渲染参考图**（`tools/make_psd_corpus.py`；psd-tools %s /' % PSD_TOOLS)
    rb.append('/// Pillow %s）。别手改。' % PILLOW)
    rb.append('///')
    rb.append('/// 每张图 = psd-tools **按层重算**的合成图（`composite(force=True)`，')
    rb.append('/// 带 alpha）**叠在白纸上**（本仓库画布语义）之后 Pillow 编码的 PNG。')
    rb.append('/// 用途：`agent/psd_test.mbt` 里"导入 → 渲染 → 与参考图比"的端到端判据。')
    rb.append('/// 参考图在**生成时**算好（门禁离线跑，不需要 Pillow / psd-tools）。')
    rb.append('///')
    rb.append('/// `*_TOL`：该例声明允许的最大通道差（0 = 必须逐位相同）。图层不透明度')
    rb.append('/// 不是 0/255 时，第三方（浮点）与我们（定点）的混合差 1。')
    for c in cases:
        var = "PSD_REF_" + "".join(ch if ch.isalnum() else "_" for ch in c["name"]).upper()
        rb.append('///|')
        rb.append('const %s_PNG : String = %s' % (var, mbt_str(c["render_ref_png"])))
        rb.append('')
        rb.append('///|')
        rb.append('const %s_TOL : Int = %d' % (var, c.get("render_tol", 0)))
        rb.append('')
    refs_txt = "\n".join(rb)

    if check:
        ok = True
        have_mbt = open(os.path.join(ROOT, "codec", "psd_corpus_test.mbt"),
                        encoding="utf-8").read() if os.path.exists(
            os.path.join(ROOT, "codec", "psd_corpus_test.mbt")) else ""
        if have_mbt != mbt:
            ok = False
            print("不一致：codec/psd_corpus_test.mbt（重新生成后请连同语料一起提交）")
        have_json = open(json_path, encoding="utf-8").read() if os.path.exists(json_path) else ""
        if have_json != json_txt:
            ok = False
            print("不一致：%s" % json_path)
        refs_path = os.path.join(ROOT, "agent", "psd_refs_test.mbt")
        have_refs = open(refs_path, encoding="utf-8").read() if os.path.exists(refs_path) else ""
        if have_refs != refs_txt:
            ok = False
            print("不一致：agent/psd_refs_test.mbt（重新生成后请连同语料一起提交）")
        print("PSD 语料幂等 ✓（%d 例 + %d 边界，psd-tools %s / Pillow %s）"
              % (len(cases), len(bad), PSD_TOOLS, PILLOW) if ok else "PSD 语料**不幂等**")
        return 0 if ok else 1

    with open(os.path.join(ROOT, "codec", "psd_corpus_test.mbt"), "w",
              encoding="utf-8") as f:
        f.write(mbt)
    with open(os.path.join(ROOT, "agent", "psd_refs_test.mbt"), "w",
              encoding="utf-8") as f:
        f.write(refs_txt)
    with open(json_path, "w", encoding="utf-8") as f:
        f.write(json_txt)
    if os.path.exists(mbt_path):
        os.remove(mbt_path)
    print("已写出 %d 例语料 + %d 边界 → %s（psd-tools %s / Pillow %s）"
          % (len(cases), len(bad), OUT, PSD_TOOLS, PILLOW))
    for c in cases:
        print("  %-22s %-8s %3d×%-3d %5d 字节  合成comp=%d 层通道=%s 合成 sha=%s"
              % (c["name"], c["kind"], c["width"], c["height"], c["bytes"],
                 c["compression"], len(c["layers"]), c["composite_sha256"][:12]))
    for c in bad:
        print("  %-22s 边界     拒绝期望=%s" % (c["name"], c["want"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
