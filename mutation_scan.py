#!/usr/bin/env python3
"""变异测试：验证「测试是否真的守护了产品承诺」。

做法：往产品代码注入一个语义 bug，跑 `moon test --target native`。
若全绿，说明那个承诺没有任何测试守护（或者断言是假的）。

为什么需要它：本仓库有过两次教训——
  * `leak_ratio` 的判据用错了阈值（软过渡带被误报成「选区外泄漏」），
    而守着它的 5 处断言是子串匹配（`"leak_ratio":0` 会被 `0.0279` 骗过），
    于是这个真 bug 藏了好几轮；
  * MVSL 最核心的那句 `out = lerp(in, op(in), w)` 没有数值测试——
    把 w 换成常量 1.0（软权重硬边化）时，150 条测试全部通过。

「测试全绿」不等于「行为被守护」。这个脚本是那个差距的度量。

用法（在仓库根）：
    python3 mutation_scan.py            # 全跑（约 5 分钟）
    python3 mutation_scan.py M1 M7      # 只跑指定项
退出码：有「应当被抓住却存活」的变异 → 1。
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
BAK = "/tmp/moonpainter_mut_bak"

# (编号, 说明, 相对路径, 原串, 替换串, 预期)
# 预期只能是 "killed"（应当被测试抓住）或 "equivalent"（语义等价，允许存活）
MUTS = [
    (
        "M1", "编辑表忽略软权重（out=op(in)，硬边化）",
        "pixel/edit.mbt",
        "      out.pixels[i] = lerp_argb(in_c, op_c, w)",
        "      out.pixels[i] = lerp_argb(in_c, op_c, 1.0)",
        "killed",
    ),
    (
        "M2", "空编辑表短路失效（走正常路径）",
        "pixel/program.mbt",
        "  if prog.ops.length() == 0 {\n    return Ok((base, []))\n  }",
        "  if false {\n    return Ok((base, []))\n  }",
        # 等价：ops 为空时循环体不执行，cur 仍是 base、stages 仍是 []，
        # 与短路返回逐位相同。短路只是省掉 SelCtx/FieldCache 的构造。
        "equivalent",
    ),
    (
        "M3", "彩窗的彩度项拿色相半宽判",
        "pixel/edit.mbt",
        "  window_membership(ds, w.s_half, w.feather) *",
        "  window_membership(ds, w.h_half, w.feather) *",
        "killed",
    ),
    (
        "M4", "program_sha256 变常量",
        "core/mvsl.mbt",
        "  @base.sha256_hex(@utf8.encode(program_to_json(p)))",
        '  @base.sha256_hex(@utf8.encode("const"))',
        "killed",
    ),
    (
        "M5", "fingerprint 变常量",
        "core/json.mbt",
        "  @base.sha256_hex(@utf8.encode(doc_to_json(doc)))",
        '  @base.sha256_hex(@utf8.encode("const"))',
        "killed",
    ),
    (
        "M6", "check_guards 恒通过",
        "pixel/program.mbt",
        ") -> Result[Array[String], String] {\n  let fails : Array[String] = []",
        ") -> Result[Array[String], String] {\n  let fails : Array[String] = []\n  if before.width > 0 {\n    return Ok([])\n  }",
        "killed",
    ),
    (
        "M7", "8 位量化由四舍五入改截断",
        "pixel/edit.mbt",
        "  let q = v + 0.5",
        "  let q = v",
        "killed",
    ),
    (
        "M8", "彩窗的色相项漏掉 feather",
        "pixel/edit.mbt",
        "  window_membership(dh, w.h_half, w.feather) *",
        "  window_membership(dh, w.h_half, 0.0) *",
        "killed",
    ),
    (
        "M8b", "彩窗的彩度项漏掉 feather",
        "pixel/edit.mbt",
        "  window_membership(ds, w.s_half, w.feather) *",
        "  window_membership(ds, w.s_half, 0.0) *",
        "killed",
    ),
    (
        "M9", "lint 不报「装了表却什么都没改」",
        "agent/mvsl_lint.mbt",
        "  if total_rep.changed == 0 {",
        "  if false {",
        "killed",
    ),
    (
        "M10", "保护断言不报违约",
        "pixel/program.mbt",
        "  Ok(fails)",
        "  Ok([])",
        # 注意：fails 收集路径有两处形态相同的返回，锚点必须唯一
        "killed",
    ),
    (
        "M11", "色相环距离不取最短弧",
        "pixel/color.mbt",
        "  while d > 180.0 {\n    d = 360.0 - d\n  }",
        "  if d > 180.0 {\n    d = d\n  }",
        "killed",
    ),
    # --- 第二批：图层合成 / 几何选择子 / 编码器 / 哈希 ---
    (
        "N1", "合成丢掉背景保留项（(1-sa)*da*dst）",
        "render/blend.mbt",
        "    (1.0 - sa) * da * dr",
        "    0.0 * dr",
        "killed",
    ),
    (
        "N2", "alpha 合成公式错（sa+da 而非 sa+da(1-sa)）",
        "render/blend.mbt",
        "  let ao = sa + da * (1.0 - sa)",
        "  let ao = sa + da",
        "killed",
    ),
    (
        "N3", "合成后不去预乘",
        "render/blend.mbt",
        "  let v = clamp01(premul / alpha) * 255.0 + 0.5",
        "  let v = clamp01(premul) * 255.0 + 0.5",
        "killed",
    ),
    (
        "N4", "Multiply 模式退化成 src-over",
        "render/blend.mbt",
        "    @core.BlendMode::Multiply => cb * cs",
        "    @core.BlendMode::Multiply => cs",
        "killed",
    ),
    (
        "N5", "Screen 公式错（少了 -cb*cs）",
        "render/blend.mbt",
        "    @core.BlendMode::Screen => cb + cs - cb * cs",
        "    @core.BlendMode::Screen => cb + cs",
        "killed",
    ),
    (
        "N6", "矩形距离退化成「到中心距离」",
        "pixel/edit.mbt",
        "  let lo_x = g.x\n  let hi_x = g.x + g.w\n  let lo_y = g.y\n  let hi_y = g.y + g.h",
        "  let lo_x = g.x + g.w * 0.5\n  let hi_x = g.x + g.w * 0.5\n  let lo_y = g.y + g.h * 0.5\n  let hi_y = g.y + g.h * 0.5",
        "killed",
    ),
    (
        "N7", "几何选择子丢掉羽化（硬边）",
        "pixel/edit.mbt",
        "      f.v[y * ctx.base.width + x] = window_membership(d, g.feather, 1.0)",
        "      f.v[y * ctx.base.width + x] = window_membership(d, g.feather, 0.0)",
        "killed",
    ),
    (
        "N8", "几何采样丢掉半像素中心偏移",
        "pixel/edit.mbt",
        "      let px = x.to_double() + 0.5\n      let py = y.to_double() + 0.5\n      let d = if shape == \"ellipse\" {",
        "      let px = x.to_double()\n      let py = y.to_double()\n      let d = if shape == \"ellipse\" {",
        "killed",
    ),
    (
        "N9", "SHA-256 轮常量改一个比特",
        "base/sha256.mbt",
        "  0x428a2f98, 0x71374491,",
        "  0x428a2f98, 0x71374490,",
        "killed",
    ),
    (
        "N10", "PNG 扫描线 filter 字节改成 1",
        "codec/png.mbt",
        "  for y in 0..<buf.height {\n    push_b(raw, 0)",
        "  for y in 0..<buf.height {\n    push_b(raw, 1)",
        "killed",
    ),
    (
        "N11", "CRC32 初值不为全 1",
        "codec/zip.mbt",
        "  let mut crc = 0xFFFFFFFF",
        "  let mut crc = 0x00000000",
        "killed",
    ),
    # --- 第三批：预览 overlay / 降采样 / 容器 manifest ---
    (
        "P1", "覆盖预览忽略 membership 强度（软边界消失）",
        "pixel/overlay.mbt",
        "      let mixed = lerp_argb(c, OVERLAY_ARGb, OVERLAY_ALPHA * w)",
        "      let mixed = lerp_argb(c, OVERLAY_ARGb, OVERLAY_ALPHA)",
        "killed",
    ),
    (
        "P2", "盒平均降采样不做平均（只取左上角像素）",
        "pixel/overlay.mbt",
        "      out.pixels[y * ow + x] = (round_div(sa, n) << 24) +\n        (round_div(sr, n) << 16) +\n        (round_div(sg, n) << 8) +\n        round_div(sb, n)",
        "      out.pixels[y * ow + x] = src.pixels[(y * k) * src.width + x * k]",
        "killed",
    ),
    (
        "P3", "manifest 的 layers/assets 计数互换",
        "mpd/mpd.mbt",
        '\\"counts\\":{\\"layers\\":\\{layers_n},\\"assets\\":\\{d.assets.length()}',
        '\\"counts\\":{\\"layers\\":\\{d.assets.length()},\\"assets\\":\\{layers_n}',
        "killed",
    ),
    # ---- 命令行分词（自由文本的空格靠它，见 tokenize_line）----
    (
        "R1",
        "probe 批量模式省掉 guards（与单点模式字段走样）",
        "agent/affordance_cmds.mbt",
        '  sb.write_string(",\\"guards\\":[")',
        '  if !envelope {\n    return Ok(sb.to_string() + ",\\"guards\\":[]}")\n  }\n  sb.write_string(",\\"guards\\":[")',
        "killed",
    ),
    (
        "R2",
        "probe 批量点数上限失效（一次能塞进无限多个点）",
        "agent/affordance_cmds.mbt",
        '  if out.length() > 64 {',
        '  if out.length() > 100000 {',
        "killed",
    ),
    (
        "Q3",
        "set-mask 退回静默接受：认不出的参数当成 false（几何改不动却报 ok）",
        "agent/session.mbt",
        r"""    other =>
      return err(
        "set-mask 只改 invert（true|false）；几何修改请用 remove-mask + add-mask，got \{other}",
      )""",
        r"""    _ => false""",
        "killed",
    ),
    (
        "Q1",
        "命令行分词丢掉引号语义（引号内的空格又会被切断）",
        "agent/session.mbt",
        """    } else if c == '"' {
      in_quote = true
      started = true
    } else if is_ws(c) {""",
        """    } else if c == '"' {
      sb.write_char(c)
      started = true
    } else if is_ws(c) {""",
        "killed",
    ),
    (
        "Q2",
        r"引号内的 \" 转义失效（字面引号退化成裸反斜杠）",
        "agent/session.mbt",
        r"""      } else if c == '\\' && i < n {""",
        r"""      } else if false {""",
        "killed",
    ),
]


def run_native_tests():
    r = subprocess.run(
        ["moon", "test", "--target", "native"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return r.stdout + r.stderr


def judge(out):
    summary = [l for l in out.splitlines() if l.startswith("Total tests")]
    crashed = "exited with signal" in out or "SIGABRT" in out
    if not summary:
        if "failed when checking" in out or "Parse error" in out:
            return "INVALID", "编译失败（变异本身不合法）"
        if crashed:
            return "KILLED", "测试进程崩溃（abort）"
        return "UNKNOWN", "无法判定"
    failed = int(summary[-1].split("failed:")[1].strip().rstrip("."))
    if failed > 0:
        return "KILLED", f"{failed} 条测试失败"
    if crashed:
        return "KILLED", "测试进程崩溃（abort）"
    return "SURVIVED", "全部通过（无人守护）"


def main():
    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    todo = [m for m in MUTS if not wanted or m[0] in wanted]
    if not todo:
        print(f"没有匹配的变异：{wanted}", file=sys.stderr)
        return 2
    dirty = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True
    ).stdout.strip()
    if dirty:
        print("警告：工作区不干净，变异前后可能混淆：\n" + dirty, file=sys.stderr)

    results = []
    for mid, desc, rel, old, new, expect in todo:
        path = os.path.join(ROOT, rel)
        src = open(path, encoding="utf-8").read()
        n = src.count(old)
        if n != 1:
            results.append((mid, desc, expect, "INVALID", f"锚点出现 {n} 次"))
            print(f"{mid}: INVALID（锚点 {n} 次）", flush=True)
            continue
        shutil.copy(path, BAK)
        try:
            open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
            verdict, detail = judge(run_native_tests())
        finally:
            shutil.copy(BAK, path)  # 无论成败都还原
        results.append((mid, desc, expect, verdict, detail))
        mark = ""
        if verdict == "SURVIVED" and expect == "killed":
            mark = "   ← 应当被抓住却没有！"
        elif verdict == "KILLED" and expect == "equivalent":
            mark = "   ← 等价变异被抓住（测试比预期更严，通常是好事）"
        print(f"{mid}: {verdict} — {detail}{mark}", flush=True)

    print("\n===== 汇总 =====", flush=True)
    misses = []
    for mid, desc, expect, verdict, detail in results:
        print(f"{verdict:9s} {mid:5s} {desc}  ({detail})", flush=True)
        if expect == "killed" and verdict in ("SURVIVED", "UNKNOWN"):
            misses.append(mid)
    valid = [r for r in results if r[3] != "INVALID"]
    survived = [r for r in valid if r[3] == "SURVIVED"]
    print(f"\n变异 {len(valid)} 个：被抓住 {len(valid) - len(survived)}，存活 {len(survived)}")
    for r in survived:
        if r[2] == "equivalent":
            print(f"  存活的 {r[0]} 是**已确认的等价变异**（不改变行为，允许存活）")
    if misses:
        print(f"\nFAIL: 这些变异应当被抓住却存活了：{misses}")
        return 1
    print("\nMUTATION SCAN PASS ✓（所有非等价变异都被测试抓住）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
