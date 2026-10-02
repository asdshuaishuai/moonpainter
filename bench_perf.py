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
import statistics
import struct
import subprocess
import sys
import time

MOON = ["moon", "run", "--target", "native", "cli", "--release"]


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
