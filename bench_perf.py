#!/usr/bin/env python3
"""性能标定：把文档里写的性能数字变成可重复的测量。

用法：
    python3 bench_perf.py            # 两个实验都跑（约 3–5 分钟）
    python3 bench_perf.py m1         # 只跑实验一（编辑表代价模型）
    python3 bench_perf.py m2         # 只跑实验二（12MP 渲染证伪线）

**这个脚本不进任何门禁**，因为它量的是**墙钟时间**：换一台机器、换一个
构建模式数字就变。它存在的意义是让 DESIGN 里那几个性能数字**能指回一次
可重复的测量**（本仓库的纪律：注释/文档里的性能数字不许是"听上去合理"的
猜测——实测差点把一句"提速 43 倍"写进注释，见 PLAN 补遗十七）。

━━ 纪律（这些坑全部实测踩过，别删）━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
* **全链不许出现 `"error"`**：手工实验链条里每一步都要查。实测栽过四次；
  最近一次是 `add-rect l1 …` 少写 `id=`，命令静默失败，于是**整轮标定跑在
  一张空画布上**。
* **层 id 一律用 `id=`**：位置参数写法会静默失败。
* **`add-mask` 是位置参数命令**（`add-mask <id>`，不是 `id=`）。
* **`render` 默认 `width=1024`（预览！）**：量全分辨率必须显式写
  `render <width>`，否则量的是 1MP 预览而不是 12MP 画布。
* **release 构建**：`moon run --target native cli` 默认是 debug，比 release
  慢 2–4 倍；数字要描述产品就必须带 `--release`。
* **单次差异不是结论**：实测首测 24.65s vs 复测 19.86s（差 24%），那是首轮
  冷启动的离群值。一律多次重复取中位，并把首尾基线各测一次以暴露漂移。
* **别通过管道看退出码**。
"""
import base64
import json
import re
import statistics
import struct
import subprocess
import sys
import time

MOON = ["moon", "run", "--target", "native", "cli", "--release"]

# 量内存时必须绕开 `moon run` 的 driver，直接跑编译产物（driver 自己的 RSS
# 会把信号淹掉）。跑过一次 `moon build --target native --release` 才会存在。
CLI_BIN = "_build/native/release/build/cli/cli.exe"


def run_cli(cmds, label):
    """跑一条命令链。返回 (秒, stdout)；链条里出现 "error" 就报出来并返回 None。"""
    t = time.time()
    r = subprocess.run(MOON, input=cmds, capture_output=True, text=True, timeout=3600)
    dt = time.time() - t
    bad = [l for l in r.stdout.splitlines() if '"error"' in l]
    if bad:
        print(f"  !! {label}：链条里有错误，这次测量作废：{bad[0][:200]}")
        return None, r.stdout
    return dt, r.stdout


def bench(build, tail, label, reps):
    """重复 reps 次，返回中位秒数与原始样本。"""
    ts = []
    for _ in range(reps):
        dt, _ = run_cli(build() + tail, label)
        if dt is None:
            return None, []
        ts.append(dt)
    med = statistics.median(ts)
    print(f"  {label:34s} {['%.2f' % x for x in ts]}  中位 {med:.2f}s")
    return med, ts


# ---------------------------------------------------------------------------
# 实验一：编辑表代价模型  cost ≈ k × (画布像素数 × 算子数)
# ---------------------------------------------------------------------------

def m1(reps=3):
    W = N = 1024
    n_ops = 10

    def prog():
        ops = [
            {
                "id": f"e{i}",
                "kind": "recolor",
                "sel": {
                    "basis": "base",
                    "expr": {
                        "t": "geo",
                        "shape": "rect",
                        "w": {"x": 0, "y": 0, "w": W, "h": W, "feather": 0},
                    },
                },
                "amount": 0.5,
                "hue_deg": 30.0,
            }
            for i in range(n_ops)
        ]
        return base64.b64encode(
            json.dumps({"version": 1, "ops": ops, "guards": []}).encode()
        ).decode()

    def build():
        # ⚠️ `id=l1` 不是 `l1`：漏了 `=` 会让这条命令静默失败，
        # 底图就是空的，测出来的"每像素代价"跟真跑毫无关系。
        return (
            f"session-open full_image\nnew {W} {W}\n"
            f"add-rect id=l1 x=0 y=0 w={W} h={W} fill=#FF0000\n"
            f"mvsl-set {prog()}\n"
        )

    print(f"实验一：编辑表代价模型（{W}×{W} = {W*W/1e6:.2f}MP、"
          f"{n_ops} 条整幅 recolor、{reps} 次取中位）")
    geo, _ = bench(build, "mvsl-impact max=8\n", "geo 选择子命中全图", reps)
    empty_sel = (
        f"session-open full_image\nnew {W} {W}\n"
        f"add-rect id=l1 x=0 y=0 w={W} h={W} fill=#FF0000\n"
        f"mvsl-set {_prog_offscreen(W, n_ops)}\n"
    )
    off, _ = bench(lambda: empty_sel, "mvsl-impact max=8\n", "geo 选择子命中空集", reps)

    px_ops = W * W * n_ops
    if geo:
        print(f"  ⇒ {geo/px_ops*1e6:.3f} µs/(像素·算子)"
              f"（整幅已知值 ≈ 2 µs，见 DESIGN 边界节）")
    if off:
        print(f"  ⇒ 命中空集（不混合）{off/px_ops*1e6:.3f} µs/(像素·算子)"
              f" ⇒ 选择子求值占其中约 {off/px_ops*1e6:.2f}，其余是色彩变换")


def _prog_offscreen(W, n_ops):
    ops = [
        {
            "id": f"e{i}",
            "kind": "recolor",
            "sel": {
                "basis": "base",
                "expr": {
                    "t": "geo",
                    "shape": "rect",
                    "w": {"x": -900, "y": -900, "w": 10, "h": 10, "feather": 0},
                },
            },
            "amount": 0.5,
            "hue_deg": 30.0,
        }
        for i in range(n_ops)
    ]
    return base64.b64encode(
        json.dumps({"version": 1, "ops": ops, "guards": []}).encode()
    ).decode()


# ---------------------------------------------------------------------------
# 实验二：12MP 渲染证伪线（PLAN-MVSL §5 / DESIGN 边界节）
# ---------------------------------------------------------------------------

def m2(reps=2):
    W, H = 4000, 3000  # 12 MP

    def build(nl, mask):
        s = f"session-open full_image\nnew {W} {H}\n"
        for i in range(nl):
            s += f"add-rect id=l{i} x=0 y=0 w={W} h={H} fill=#FF0000 opacity=0.5\n"
        if mask:
            # ⚠️ 位置参数：`add-mask <层 id>`，写成 `id=l0` 会静默失败。
            s += f"add-mask l0 x=0 y=0 w={W} h={H} feather=64\n"
        return s

    print(f"实验二：12MP 证伪线（{W}×{H} = {W*H/1e6:.1f}MP、{reps} 次取中位）")
    print("  出口用 `render 4000`（全分辨率 + PNG 编码）；"
          "⚠️ 裸 `render` 是 1024 预览，量不到 12MP")
    r1, _ = bench(lambda: build(1, False), "render 4000\n", "1 层", reps)
    r4, _ = bench(lambda: build(4, False), "render 4000\n", "4 层", reps)
    r10, _ = bench(lambda: build(10, False), "render 4000\n", "10 层", reps)
    r10m, _ = bench(lambda: build(10, True), "render 4000\n", "10 层 + 软蒙版", reps)

    print("\n  结论（只报量到的，不外推）：")
    print("    口径：上面的层都是**整幅画布**的层。几何层已按 paint_window 裁窗，")
    print("    小层远便宜（未实测）；Text/Raster/Group/Adjust 不裁窗。")
    if r1:
        print(f"    1 层 = {r1:.2f}s ⇒ 「12MP 软 mask <2s」在**单层**下"
              f"{'成立' if r1 < 2.0 else '不成立'}")
    if r1 and r10:
        per_layer = (r10 - r1) / 9
        if per_layer > 0:
            print(f"    每层边际 ≈ {per_layer:.2f}s ⇒ 该线在约 "
                  f"{(2.0 - r1) / per_layer + 1:.1f} 层处就破了")
    if r10 and r10m:
        print(f"    10 层的蒙版边际 = {r10m - r10:+.2f}s"
              f" ⇒ **蒙版不是瓶颈，逐层合成才是**")


# ---------------------------------------------------------------------------
# 自检：`render 4000` 真的吐 4000×3000 吗？蒙版真的生效吗？
# ---------------------------------------------------------------------------

def selfcheck():
    """测量的前提本身也要验证：尺寸对不对、蒙版有没有被应用。"""
    W, H = 4000, 3000
    base = (f"session-open full_image\nnew {W} {H}\n"
            f"add-rect id=l1 x=0 y=0 w={W} h={H} fill=#FF0000\n")
    print("自检：`render 4000` 的实际输出尺寸与蒙版是否生效")

    def sha(tail, label):
        _, out = run_cli(base + tail, label)
        if not out:
            return None
        j = json.loads([l for l in out.splitlines() if l.startswith("{")][-1])
        png = base64.b64decode(j["png_b64"])
        # 直接读 PNG 头，别信信封里的 width/height（信封可能描述了另一张图）
        w, h = struct.unpack(">II", png[16:24])
        print(f"  {label:14s} 信封 {j['width']}×{j['height']} / "
              f"PNG 实际 {w}×{h}  sha={j['render_sha256'][:16]}")
        return j["render_sha256"]

    s_none = sha("render 4000\n", "无蒙版")
    s_hard = sha(f"add-mask l1 x=0 y=0 w={W} h={H}\nrender 4000\n", "硬边蒙版")
    s_soft = sha(f"add-mask l1 x=0 y=0 w={W} h={H} feather=64\nrender 4000\n", "软蒙版")
    print(f"  软蒙版改变了渲染？{s_none != s_soft}"
          f"（硬边蒙版与层完全同位，逐位相同才是对的：{s_none == s_hard}）")


# ---------------------------------------------------------------------------
# 实验三：内存模型 —— 峰值 RSS ≈ 斜率 × (画布像素数 × 算子数)
#
# 为什么单独量它：`edit_cost_error` 的判据是**时间**（像素·算子 ≤ 2e8，
# 按实测 2 µs 换算 ≈ 400 秒）。但内存与时间同源 —— 每条算子都留一个整幅
# 中间缓冲（`run_program` 的 `stages`，STAGE(n) 要能回看），每个**不同**的
# BASE 选择子还留一个整幅浮点场（`FieldCache`）。于是时间预算**隐含**了一个
# 内存上限，而那个上限此前没有任何地方写出来（PLAN-MVSL 里那句
# 「24MP ≈ 384MB」是错的：24MP 单个浮点场就是 192MB）。
#
# 布局（读代码：`codec/png.mbt` 的 RgbaBuf.pixels 是 FixedArray[Int]、
# `pixel/edit.mbt` 的 Field.v 是 FixedArray[Double]）：
#   4 B/px 每条算子的中间缓冲（保留） + 8 B/px 每个不同选择子的场（保留）
#   = 12 B/px/算子；实测斜率见下（低 K 处略高，含瞬时场与分配器高水位）。
# ---------------------------------------------------------------------------

def _prog_distinct(W, k):
    """k 条算子、**互不相同**的 BASE 选择子（最坏内存情形：场缓存不共享）。

    选择子必须真的不同（这里让 geo 窗的 x 逐条平移）：全用同一个选择子的话
    `FieldCache` 只留一份场，量出来的斜率会系统性偏小。
    """
    ops = [
        {
            "id": f"e{i}",
            "kind": "recolor",
            "sel": {
                "basis": "base",
                "expr": {
                    "t": "geo",
                    "shape": "rect",
                    # 逐条平移 → canonical 文本不同 → 缓存各留一份
                    "w": {"x": i, "y": 0, "w": W, "h": W, "feather": 0},
                },
            },
            "amount": 0.5,
            "hue_deg": 30.0,
        }
        for i in range(k)
    ]
    return base64.b64encode(
        json.dumps({"version": 1, "ops": ops, "guards": []}).encode()
    ).decode()


def _peak_rss_mb(cmds):
    """跑一条命令链，返回其峰值 RSS（MB）。用 /usr/bin/time -l 量**子进程树**。

    ⚠️ 必须直接跑 `_build/native/release/build/cli/cli.exe`，不能跑 `moon run`：
    后者的 driver 进程自己的 RSS 会把信号淹掉（同"测量前先验测量前提"）。
    ⚠️ macOS 的 `/usr/bin/time -l` 输出是「数字在前」——`5996544  maximum
    resident set size`，单位是字节。第一版照着「标签在前」写正则，直接崩了。
    """
    r = subprocess.run(
        ["/usr/bin/time", "-l", CLI_BIN], input=cmds, capture_output=True, text=True,
        timeout=3600,
    )
    m = re.search(r"(\d+)\s+maximum resident set size", r.stderr)
    if m is None:
        print("  !! 读不出峰值 RSS（/usr/bin/time -l 的输出格式变了？）")
        return None
    bad = [l for l in r.stdout.splitlines() if '"error"' in l]
    if bad:
        print(f"  !! 链条里有错误，这次测量作废：{bad[0][:200]}")
        return None
    return int(m.group(1)) / 1e6


def m3():
    W = 1024
    px = W * W
    base = (f"session-open full_image\nnew {W} {W}\n"
            f"add-rect id=l1 x=0 y=0 w={W} h={W} fill=#FF0000\n")
    print(f"内存标定：{W}×{W} 画布，算子数 ↑，选择子两两不同（最坏情形）")
    b = _peak_rss_mb(base + "mvsl-impact max=8\n")
    if b is None:
        return None
    print(f"  K=0（基线，含引擎常驻）      {b:7.1f} MB")
    prev_k, prev = 0, b
    for k in (2, 4, 8, 12, 16):
        mb = _peak_rss_mb(base + f"mvsl-set {_prog_distinct(W, k)}\nmvsl-impact max=8\n")
        if mb is None:
            return None
        # MB → 字节：1e6（不是 2^20；/usr/bin/time 报的是十进制字节数）
        bpo = (mb - b) * 1e6 / k / px
        slope = (mb - prev) * 1e6 / (k - prev_k) / px
        print(f"  K={k:<3d} {mb:7.1f} MB  增量 {(mb - b):7.1f} MB"
              f"  = {bpo:5.2f} B/像素·算子（区间斜率 {slope:5.2f}）")
        prev_k, prev = k, mb
    # 判据落在**声明过的布局**上：12 B/px/算子 = 4（保留缓冲）+ 8（缓存场）。
    # 实测低 K 处 ~14.4（瞬时场与分配器高水位随 K 摊薄），K↑ 收敛到 ~12.3。
    last = (prev - b) * 1e6 / prev_k / px
    print(f"  收敛斜率 {last:.2f} B/像素·算子（声明布局 4+8=12；"
          f"低 K 高水位把它抬到 ~14）")
    # 时间预算隐含的内存上限：ops×px ≤ 2e8，取实测上界 14.4 B/px 为保守值。
    for c in (12.0, 14.4):
        print(f"    ⇒ 按 {c:4.1f} B/像素·算子 与 2e8 像素·算子预算，"
              f"最坏峰值 ≈ {c * 2e8 / 1e9:.1f} GB（**与画布尺寸无关**）")
    return last


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("all", "selfcheck"):
        selfcheck()
        print()
    if which in ("all", "m1"):
        m1()
        print()
    if which in ("all", "m2"):
        m2()
        print()
    if which in ("all", "m3"):
        m3()
