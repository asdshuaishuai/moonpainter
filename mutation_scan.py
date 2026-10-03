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

**这个脚本自己也有一个静默失效模式**：每个变异靠一段「锚点文本」定位要替换
的代码，锚点一旦被后续重构改掉、或变得不再唯一，那个变异就**再也没跑过**。
实测踩过：R3 的锚点被一次重构改了缩进、R4 的锚点变成匹配 2 处，两个变异静静
失效了一轮，而汇总里的「变异 N 个全部通过」照旧好看。所以：
  * INVALID（锚点失效 **或变异本身编译不过**）会让脚本**退出码 1**。两类都
    意味着"这条变异没在测试任何东西"——实测 R29 的替换串括号不配对、一直编译
    不过，而每次汇总照旧印 PASS；
  * `--check-anchors` 只校验锚点唯一命中（秒级），已接进 `verify.sh` 第 9 步。

用法（在仓库根）：
    python3 mutation_scan.py                  # 全跑（本机约 42 分钟：110 条 × 每条一次全量 moon test）
    python3 mutation_scan.py M1 M7            # 只跑指定项
    python3 mutation_scan.py --check-anchors  # 只校验锚点（秒级）
退出码：有「应当被抓住却存活」的变异 → 1；有锚点失效 → 1。
"""

import os
import shutil
import signal
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
BAK = "/tmp/moonpainter_mut_bak"

# 当前注入着的变异：`(mid, path)`。信号处理器靠它把自己注入的东西**还原回去**——
# 实测踩过：`job_kill` 掉扫描（AGENTS 里还写着"宁可用 job_kill 停掉重跑"），
# `try/finally` 里的还原**根本不执行**，注入的变异就留在工作区里
# （那次是 `pixel/program.mbt` 的 `if prog.ops.length() == 0` 变成 `if false`）。
# 这是最坏的一类残留：`git status` 只显示"文件被改过"，下一步可能就是
# **把它当自己的改动提交上去**。
INFLIGHT = None


def _restore_inflight():
    """还原当前注入的变异；返回被还原的变异 id（没有则 None）。"""
    global INFLIGHT
    if INFLIGHT is None:
        return None
    mid, path = INFLIGHT
    try:
        shutil.copy(BAK, path)
    except Exception as e:  # 还原失败必须喊出来：静默 = 树里留着注入
        print(f"!!! 还原 {path} 失败：{e}（工作区可能带着注入的变异！）", file=sys.stderr)
    INFLIGHT = None
    return mid


def _on_signal(signum, _frame):
    mid = _restore_inflight()
    print(
        f"\n收到信号 {signum}：已还原注入的变异（{mid or '无'}）——"
        "**本轮扫描不完整，结果不能当门禁**",
        file=sys.stderr,
    )
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, _on_signal)
signal.signal(signal.SIGINT, _on_signal)

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
        "      let cov = if g.feather <= 0.0 {\n        if d <= 0.0 { 1.0 } else { 0.0 }\n      } else {\n        soft_cover((g.feather - d) / g.feather, Smooth)\n      }",
        "      let cov = if d <= 0.0 { 1.0 } else { 0.0 }",
        "killed",
    ),
    (
        "N8", "几何采样丢掉半像素中心偏移",
        "pixel/edit.mbt",
        "      let px = x.to_double() + 0.5\n      let py = y.to_double() + 0.5\n      let d = if is_ellipse {",
        "      let px = x.to_double()\n      let py = y.to_double()\n      let d = if is_ellipse {",
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
        "R7",
        "填充/描边色自带的 alpha 又被丢掉（半透明渲染成不透明）",
        "render/scene.mbt",
        '  let ca = (color >> 24) & 0xFF\n  let cover = if ca >= 255 { cover } else { (cover * ca + 127) / 255 }',
        '  let cover = cover',
        "killed",
    ),
    (
        "R8",
        "add-text 又无条件覆盖用户 fill（显式颜色静默失效）",
        "agent/session.mbt",
        '  let text_fill = match m.get("fill") {\n    Some(_) => layer.fill\n    None => @core.Fill::Solid(0xFF000000)\n  }',
        '  let text_fill = @core.Fill::Solid(0xFF000000)',
        "killed",
    ),
    (
        "R9",
        "program_for_layer 取错段（层段拿到文档级算子 → 这条层的算子一个都不跑）",
        "core/mvsl.mbt",
        '''pub fn program_for_layer(p : EditProgram, layer_id : String) -> EditProgram {
  { ops: segment_ops(p, layer_id), guards: [] }''',
        '''pub fn program_for_layer(p : EditProgram, layer_id : String) -> EditProgram {
  let _keep = layer_id
  { ops: segment_ops(p, ""), guards: [] }''',
        "killed",
    ),
    (
        "R10",
        "program_has_layer_scope 判反（含图层级算子的表走单段路径）",
        "core/mvsl.mbt",
        '  for op in p.ops {\n    if op.layer != "" {\n      return true',
        '  for op in p.ops {\n    if op.layer == "" {\n      return true',
        "killed",
    ),
    (
        "R11",
        "rasterize_layer 用白底而不是透明底（层失去 alpha，去污染失效）",
        "render/scene.mbt",
        '  @codec.fill_rect_rgba(buf, 0, 0, w, h, 0x00000000)',
        '  @codec.fill_rect_rgba(buf, 0, 0, w, h, 0xFFFFFFFF)',
        "killed",
    ),
    (
        "R21",
        "counts.layers 用非递归的顶层层数（组内层漏计）",
        "mpd/mpd.mbt",
        """  let layers_n = @core.all_layers(d.layers).length()""",
        """  let layers_n = d.layers.length()""",
        "killed",
    ),
    (
        "R22",
        "vision.previews 登记一个不存在的预览（自述撒谎）",
        "mpd/mpd.mbt",
        r"""[\"previews/flat.png\",\"previews/thumb.png\"]""",
        r"""[\"previews/flat.png\",\"previews/gone.png\"]""",
        "killed",
    ),
    (
        "R23",
        "set-text 不查层 kind（在 rect 上写死数据、指纹变了画面没变）",
        "agent/session.mbt",
        """  if !(target.kind is @core.ShapeKind::Text) {""",
        """  if false {""",
        "killed",
    ),
    (
        "R24",
        "lint 不报空组（装了却什么都不干的状态没人告诉调用方）",
        "agent/ops.mbt",
        """        v.push("P2 noop 组 \\{l.id} 没有任何成员（直通合成里什么都不做）")""",
        """        let _ = l""",
        "killed",
    ),
    (
        "R25",
        "lint 不报非文本层上的 text 死数据（表格把 text 的合法 kind 写错）",
        "agent/ops.mbt",
        r"""      field: "text",
      reader: "text 层",
      hint: "",
      kinds: ["text"],""",
        r"""      field: "text",
      reader: "text 层",
      hint: "",
      kinds: ["rect"],""",
        "killed",
    ),
    (
        "R26",
        "非矩形层也接受 radius（死数据改变指纹、画面没变）",
        "agent/ops.mbt",
        """        match kind_only_write_error(cand, "corner_radius") {""",
        """        match kind_only_write_error(cand, "corner_radiusX") {""",
        "killed",
    ),
    (
        "R27",
        "lint 报 radius 却不报数值（「报了字段名不报值」满足不了数值断言）",
        "agent/ops.mbt",
        r"""          "radius=\{@core.fmt_num(l.corner_radius)}"
        } else {""",
        r"""          "radius"
        } else {""",
        "killed",
    ),
    (
        "R28",
        "layer_summary 不报 radius/flip（设了读不回来）",
        "agent/session.mbt",
        """  if l.flip_h || l.flip_v {""",
        """  if false {""",
        "killed",
    ),
    (
        "R29",
        "set-adjust 不查层 kind（把 adjust 写进 rect，又是死数据）",
        "agent/session.mbt",
        r"""  let cur = match target.adjust {
    Some(a) => a
    None =>
      return err(""",
        r"""  let cur = match target.adjust {
    Some(a) => a
    None => { op: @core.AdjustOp::Brightness, value: 0.0 }
  }
  let _unreachable = if false { return err(""",
        "killed",
    ),
    (
        "R30",
        "layer_summary 不报 adjust（调整层的 op/value 读不回来）",
        "agent/session.mbt",
        r"""  match l.adjust {""",
        r"""  match (None : @core.Adjust?) {""",
        "killed",
    ),
    (
        "R31",
        "set-adjust 不沿用原值（只给 op 时把 value 清零）",
        "agent/session.mbt",
        r"""          if (adjust_spec(o)).0 {
            merged.set("value", @core.fmt_num(cur.value))
          }""",
        r"""          if (adjust_spec(o)).0 {
            merged.set("value", "0")
          }""",
        "killed",
    ),
    (
        "R32",
        "adjust_op_name 把 brightness 的名字写错（报告与 canonical 不一致）",
        "core/document.mbt",
        '    Brightness => "brightness"',
        '    Brightness => "bright"',
        "killed",
    ),
    (
        "R33",
        "set-style 不校验参数（拼错的键静默 no-op，返回 ok 而没改）",
        "agent/session.mbt",
        r"""  match check_kv_args(tokens, 2, set_style_keys(), "set-style") {
    Ok(_) => ()
    Err(e) => return err(e)
  }""",
        r"""  let _ = check_kv_args(tokens, 2, set_style_keys(), "set-style")""",
        "killed",
    ),
    (
        "R34",
        "check_kv_args 放行未知键（拼错的键回到静默 no-op）",
        "agent/ops.mbt",
        r"""          return Err("\{ctx}：`\{k0}=` 的值是空的（空值参数一律拒绝，请给一个具体的值）")
        }
        let k = t[0:eq].to_owned()
        if !allowed.contains(k) {""",
        r"""          return Err("\{ctx}：`\{k0}=` 的值是空的（空值参数一律拒绝，请给一个具体的值）")
        }
        let k = t[0:eq].to_owned()
        if false {""",
        "killed",
    ),
    (
        "R35",
        "check_kv_args 放行裸词（漏了 = 也当合法）",
        "agent/ops.mbt",
        r"""      None => {
        if allowed.length() == 0 {
          return Err("\{ctx}：多给了 `\{t}`（该命令只认前面的位置参数）")
        }
        return Err("\{ctx}：`\{t}` 不是 key=value 形式（是不是漏了 `=`？）")
      }""",
        r"""      None => ()""",
        "killed",
    ),
    (
        "R36",
        "apply_style_kv 不应用 tag（tag= 又是静默 no-op）",
        "agent/ops.mbt",
        r"""      nl = @core.layer_with_tag(nl, v)""",
        r"""      let _ = v""",
        "killed",
    ),
    (
        "R37",
        "points 的 kind 门写反（rect 收下顶点、polygon 反被拒）—— 判据的允许集合错",
        "agent/ops.mbt",
        """      if c.kinds.contains(kind_str(kind)) {
        return None
      }
      return kind_only_reject_text(c, kind, id, field, "")""",
        """      if true {
        return None
      }
      return kind_only_reject_text(c, kind, id, field, "")""",
        "killed",
    ),
    (
        "R38",
        "lint 不报非 polygon/line 上的死顶点（表格把 points 的合法 kind 放宽到 rect）",
        "agent/ops.mbt",
        r"""      field: "points",
      reader: "polygon/line",
      hint: "渲染器不读它的顶点（矩形/椭圆用 w/h/radius 定义形状；要折线请用 add-line）",
      kinds: ["polygon", "line"],""",
        r"""      field: "points",
      reader: "polygon/line",
      hint: "渲染器不读它的顶点（矩形/椭圆用 w/h/radius 定义形状；要折线请用 add-line）",
      kinds: ["polygon", "line", "rect"],""",
        "killed",
    ),
    (
        "R39",
        "query-layer 不报顶点（polygon 的形状读不回来）",
        "agent/session.mbt",
        r"""    if l.kind is @core.ShapeKind::Polygon || l.kind is @core.ShapeKind::Line {
      sb.write_string(",\"points\":[")""",
        r"""    if false {
      sb.write_string(",\"points\":[")""",
        "killed",
    ),
    (
        "R40",
        "add-mask 不校验参数（radus= 拼错静默给硬边直角蒙版）",
        "agent/session.mbt",
        r"""  match check_kv_args(tokens, 2, mask_keys(), "add-mask") {
    Ok(_) => ()
    Err(e) => return err(e)
  }""",
        r"""  let _ = tokens""",
        "killed",
    ),
    (
        "R41",
        "add-adjust 不校验参数（value 拼错静默按 0 建一个没效果的层）",
        "agent/session.mbt",
        r"""  match check_kv_args(tokens, 1, add_adjust_keys(), "add-adjust") {
    Ok(_) => ()
    Err(e) => return err(e)
  }""",
        r"""  let _ = tokens""",
        "killed",
    ),
    (
        "R42",
        "session-open 的拒绝不回显收到的参数（拼错时误导成模型不合格）",
        "agent/session.mbt",
        r"""    let got = if tokens.length() > 1 {
      tokens[1:].join(" ")
    } else {
      "(无参数)"
    }""",
        r"""    let got = "(无参数)" """"",
        "killed",
    ),
    (
        "R43",
        "brush 不校验参数（rr= 拼错静默用默认半径）",
        "agent/session.mbt",
        r"""  match check_kv_args(tokens, 1, ["layer", "pts", "r", "color"], "brush") {
    Ok(_) => ()
    Err(e) => return err(e)
  }""",
        r"""  let _ = tokens""",
        "killed",
    ),
    (
        "R44",
        "new 不校验参数（uuid 拼错静默用默认 uuid）",
        "agent/session.mbt",
        r"""  match check_kv_args(tokens, 3, ["uuid"], "new") {
    Ok(_) => ()
    Err(e) => return err(e)
  }""",
        r"""  let _ = tokens""",
        "killed",
    ),
    (
        "R45",
        "census/probe 不校验参数（bogus= 静默忽略）",
        "agent/affordance_cmds.mbt",
        r"""  match check_kv_args(tokens, 1, ["within", "components"], "census") {
    Ok(_) => ()
    Err(e) => return err(e)
  }""",
        r"""  let _ = tokens""",
        "killed",
    ),
    (
        "R46",
        "census components=0 静默退回默认 16（要 0 个连通域却给了 16 个）",
        "agent/affordance_cmds.mbt",
        r"""      if v <= 0 {
        return err("components=\{v} 必须为正（连通域个数的上限）")
      }
      max_comp = v""",
        r"""      if v > 0 {
        max_comp = v
      }""",
        "killed",
    ),
    (
        "R47",
        "mvsl-impact max=0 静默退回默认 1024",
        "agent/mvsl_cmds.mbt",
        r"""  match check_kv_args(tokens, 1, ["max"], "mvsl-impact") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let mut max_side = 1024
  for t in tokens {
    if t.has_prefix("max=") {
      let v = match to_i(t[4:].to_owned()) {
        Some(v) => v
        None => return err("max=\{t[4:].to_owned()} 不是整数")
      }
      if v <= 0 {
        return err("max=\{v} 必须为正（预览最长边像素）")
      }
      max_side = v
    }
  }""",
        r"""  match check_kv_args(tokens, 1, ["max"], "mvsl-impact") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let mut max_side = 1024
  for t in tokens {
    if t.has_prefix("max=") {
      let v = match to_i(t[4:].to_owned()) {
        Some(v) => v
        None => return err("max=\{t[4:].to_owned()} 不是整数")
      }
      if v > 0 {
        max_side = v
      }
    }
  }""",
        "killed",
    ),
    (
        "R48",
        "render overlay=yes 静默无效（以为开了叠加层，拿到的是干净图）",
        "agent/session.mbt",
        r"""      let v = t[8:].to_owned()
      match v {
        "1" | "true" => overlay = true
        "0" | "false" => overlay = false
        _ => return err("overlay=\{v} 应为 1/0/true/false")
      }""",
        r"""      overlay = true""",
        "killed",
    ),
    (
        "R49",
        "render 的键校验放行未知键（width=16 报成「width=width=16 不是整数」）",
        "agent/session.mbt",
        r"""  match check_kv_names(tokens, 1, ["overlay"], "render") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  // render [width] [vx0 vy0 vx1 vy1]""",
        r"""  // render [width] [vx0 vy0 vx1 vy1]""",
        "killed",
    ),
    (
        "R50",
        "lint 的 kind 专属字段表漏掉 font_size 一格（rect 上的字号成死数据）",
        "agent/ops.mbt",
        r"""    {
      field: "font_size",
      reader: "text 层",
      hint: "",
      kinds: ["text"],""",
        r"""    {
      field: "font_size",
      reader: "unknown",
      hint: "",
      kinds: ["font_size-never"],""",
        "killed",
    ),
    (
        "R51",
        "lint 的 kind 专属字段表漏掉 adjust 一格",
        "agent/ops.mbt",
        r"""      field: "adjust",
      reader: "adjust 层",
      hint: "",
      kinds: ["adjust"],""",
        r"""      field: "adjust",
      reader: "unknown",
      hint: "",
      kinds: ["adjust-never"],""",
        "killed",
    ),
    (
        "R52",
        "lint 的 kind 专属字段表漏掉 dabs / children / asset_hash",
        "agent/ops.mbt",
        r"""      field: "asset_hash",
      reader: "image 层",
      hint: "",
      kinds: ["image"],
      dead: fn(l) { if l.asset_hash != "" { "asset 引用" } else { "" } },
    },
    {
      field: "dabs",
      reader: "raster 层",
      hint: "",
      kinds: ["raster"],
      dead: fn(l) {
        if l.dabs.length() > 0 { "\{l.dabs.length()} 个笔触" } else { "" }
      },
    },
    {
      field: "children",
      reader: "group",
      hint: "",
      kinds: ["group"],
      dead: fn(l) {
        if l.children.length() > 0 { "\{l.children.length()} 个子层" } else { "" }
      },
    },""",
        r"""      field: "asset_hash",
      reader: "image 层",
      hint: "",
      kinds: ["image"],
      dead: fn(l) { if l.asset_hash != "" { "asset 引用" } else { "" } },
    },""",
        "killed",
    ),
    (
        "R53",
        "mvsl-impact 拿全分辨率 sha 冒充回吐 PNG 的 sha（信封里两个字段不同图）",
        "agent/mvsl_cmds.mbt",
        r"""  sb.write_string(",\"result_sha256\":\"\{@base.sha256_hex(preview_png)}\"")
  sb.write_string(",\"full_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"")""",
        r"""  sb.write_string(",\"result_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"")
  sb.write_string(",\"full_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"")""",
        "killed",
    ),
    (
        "R54",
        "mvsl-impact 回吐未降采样的 PNG（max= 失效，sha 也就跟着对不上）",
        "agent/mvsl_cmds.mbt",
        r"""  let preview = @pixel.downsample_box(out, max_side)""",
        r"""  let preview = out""",
        "killed",
    ),
    (
        "R55",
        "mvsl-assert 把全分辨率 sha 又叫回 result_sha256（与有 PNG 的命令撞名）",
        "agent/mvsl_cmds.mbt",
        r"""  sb.write_string(",\"result_full_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"}")""",
        r"""  sb.write_string(",\"result_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"}")""",
        "killed",
    ),
    (
        "R56",
        "pick 不查继承下来的透明度（组 opacity=0 / 祖先全透明的子层照样被报出来）",
        "render/scene.mbt",
        r"""    let eff = clamp01(l.opacity * inherited_opacity)
    if eff <= 0.0 {
      continue
    }
    if l.kind is @core.ShapeKind::Group {""",
        r"""    let eff = clamp01(l.opacity * inherited_opacity)
    if false {
      continue
    }
    if l.kind is @core.ShapeKind::Group {""",
        "killed",
    ),
    (
        "R57",
        "pick 忽略蒙版（蒙版外的点也报成「层在那里」）",
        "render/scene.mbt",
        r"""    if mask_cover_at(l, lx, ly) <= 0.0 {
      continue
    }""",
        r"""    if false {
      continue
    }""",
        "killed",
    ),
    (
        "R58",
        "pick 不看 raster 笔触（画了东西的笔触层拾不到）",
        "render/scene.mbt",
        r"""    if l.kind is @core.ShapeKind::Raster {
      if raster_covers(l, lx, ly) {
        return Some(l.id)
      }
      continue
    }""",
        r"""    if l.kind is @core.ShapeKind::Raster {
      continue
    }""",
        "killed",
    ),
    (
        "R59",
        "raster_covers 把 erase 笔触当成有东西（擦掉的地方还报「在那里」）",
        "render/scene.mbt",
        r"""      return !d.erase""",
        r"""      return true""",
        "killed",
    ),
    (
        "R60",
        "erase 又收下 color=（收了不生效的静默 no-op 参数）",
        "agent/session.mbt",
        r"""  match check_kv_args(tokens, 1, ["layer", "pts", "r"], "erase") {""",
        r"""  match check_kv_args(tokens, 1, ["layer", "pts", "r", "color"], "erase") {""",
        "killed",
    ),
    (
        "R18",
        "蒙版羽化解析恒 0（软边蒙版重开后变硬边）",
        "core/json.mbt",
        """        feather: num_f(raw, "feather"),""",
        """        feather: 0.0,""",
        "killed",
    ),
    (
        "R19",
        "蒙版圆角解析恒 0（圆角蒙版重开后变直角）",
        "core/json.mbt",
        """        radius: num_f(raw, "radius"),""",
        """        radius: 0.0,""",
        "killed",
    ),
    (
        "R20",
        "蒙版反选解析恒 false（反选蒙版重开后反回来）",
        "core/json.mbt",
        """        invert: bool_field(raw, "invert"),""",
        """        invert: false,""",
        "killed",
    ),
    (
        "R17",
        "visible 解析恒 true（隐藏的层重开后会自己冒出来）",
        "core/json.mbt",
        """  let visible = bool_of(v, "visible")""",
        """  let visible = Ok(true)""",
        "killed",
    ),
    (
        "R16",
        "set-text 下界写小（缺参数时越界 panic 而非报用法错）",
        "agent/session.mbt",
        """  if tokens.length() < 3 {
    return err(
      "用法：set-text <id>""",
        """  if tokens.length() < 2 {
    return err(
      "用法：set-text <id>""",
        "killed",
    ),
    (
        "R15",
        "delete 不收敛资产引用（design.json 留悬空引用、manifest 自述撒谎）",
        "agent/session.mbt",
        """    let pruned = @core.prune_unreferenced_assets(doc)""",
        """    let pruned = 0""",
        "killed",
    ),
    (
        "R13",
        "pack 全量写入会话资产（孤儿资产进容器）",
        "agent/session.mbt",
        """    if referenced.contains(pair.0) {
      m.add_asset(pair.0, pair.1)
    }""",
        """    m.add_asset(pair.0, pair.1)""",
        "killed",
    ),
    (
        "R14",
        "referenced_asset_hashes 拿只增的 doc.assets 当引用表（判断等于没判断）",
        "core/document.mbt",
        """  for l in doc.layers {
    if l.asset_hash != "" && !out.contains(l.asset_hash) {
      out.push(l.asset_hash)
    }
  }""",
        """  for a in doc.assets {
    if !out.contains(a.hash) {
      out.push(a.hash)
    }
  }""",
        "killed",
    ),
    (
        "R12",
        "remove-param 不真删（只清空值，条目留下）",
        "agent/session.mbt",
        """    if p.name != name {
      next.push(p)
    }""",
        """    next.push({ name: p.name, value: "" })""",
        "killed",
    ),
    (
        "R5",
        "圆角矩形 SDF 漏掉 min(max(q),0) 项（内部所有点的内距算成 0）",
        "render/scene.mbt",
        '  let mx = if qx > qy { qx } else { qy }\n  let mn = if mx < 0.0 { mx } else { 0.0 }\n  Double::sqrt(ox * ox + oy * oy) + mn - r',
        '  Double::sqrt(ox * ox + oy * oy) - r',
        "killed",
    ),
    (
        "R6",
        "蒙版 feather 被忽略（羽化参数存了不用）",
        "render/scene.mbt",
        '  let cover = if mask.feather > 0.0 {',
        '  let cover = if mask.feather > 1000000.0 {',
        "killed",
    ),
    (
        "R3",
        "蒙版 radius 又被忽略（存了不用，退回静默失败）",
        "render/scene.mbt",
        '        } else if mask.radius <= 0.0 {\n          true\n        } else {\n          rounded_rect_inside(dx, dy, mask.w, mask.h, mask.radius)\n        }',
        '        } else {\n          true\n        }',
        "killed",
    ),
    (
        "R4",
        "蒙版 radius 不按半边长夹住（SDF 路径；超大半径让圆角整个失效）",
        "render/scene.mbt",
        '  let r0 = if radius > hw { hw } else { radius }\n  let r = if r0 > hh { hh } else { r0 }\n  let ax = if dx > hw { dx - hw } else { hw - dx }\n  let ay = if dy > hh { dy - hh } else { hh - dy }\n  let qx = ax - (hw - r)\n  let qy = ay - (hh - r)\n  let ox = if qx > 0.0 { qx } else { 0.0 }\n  let oy = if qy > 0.0 { qy } else { 0.0 }\n  // 标准圆角矩形 SDF 的第二项',
        '  let r = radius\n  let ax = if dx > hw { dx - hw } else { hw - dx }\n  let ay = if dy > hh { dy - hh } else { hh - dy }\n  let qx = ax - (hw - r)\n  let qy = ay - (hh - r)\n  let ox = if qx > 0.0 { qx } else { 0.0 }\n  let oy = if qy > 0.0 { qy } else { 0.0 }\n  // 标准圆角矩形 SDF 的第二项',
        "killed",
    ),
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
        "set-mask 的布尔解析退回静默：认不出的值当成 false（改了没反应却报 ok）",
        "agent/session.mbt",
        r"""    Some(other) => Err("蒙版 invert 应为 true|false，got \{other}")""",
        r"""    Some(_) => Ok(false)""",
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
    (
        "Q21",
        "set-style 收下 points 但不写回层（回 ok 而顶点没变，指纹照样变）",
        "agent/ops.mbt",
        """      match parse_points_for(nl.kind, v) {
        Ok(pts) => nl = { ..nl, points: pts }
        Err(e) => return Err(e)
      }""",
        """      match parse_points_for(nl.kind, v) {
        Ok(pts) => nl = { ..nl, points: nl.points }
        Err(e) => return Err(e)
      }""",
        "killed",
    ),
    (
        "Q22",
        "set-style 不在入口拦「非 polygon/line 上的 points」（死数据照样写进 JSON 改指纹）",
        "agent/ops.mbt",
        """      match kind_only_kind_error(nl.kind, nl.id, "points") {""",
        """      match kind_only_kind_error(nl.kind, nl.id, "pointsX") {""",
        "killed",
    ),
    (
        "Q23",
        "顶点数下界放宽（2 顶点的 polygon 收了，而渲染器一个像素都不落）",
        "agent/ops.mbt",
        """  let need = points_min_count(kind)
  if need == 0 || n >= need {""",
        """  let need = points_min_count(kind)
  if need == 0 || n + 1 >= need {""",
        "killed",
    ),
    (
        "Q24",
        "lint 不再报顶点数不足（手改容器里「什么都不画」的层没了声音）",
        "agent/ops.mbt",
        """      let e = points_count_error(l.kind, l.points.length())
      if e != "" {
        v.push("P2 geom 层 \\{l.id}：\\{e}")
      }""",
        """      let e = points_count_error(l.kind, l.points.length())
      if e != "" && false {
        v.push("P2 geom 层 \\{l.id}：\\{e}")
      }""",
        "killed",
    ),
    (
        "Q18",
        "lint 拿「盒子」当渲染窗（判据比渲染器严：盒外窗内的墨被误报画不出来）",
        "agent/ops.mbt",
        """      let win = @render.paint_window(l)""",
        """      let win = (
        l.x.to_int(),
        l.y.to_int(),
        (l.x + l.w).to_int(),
        (l.y + l.h).to_int(),
      )""",
        "killed",
    ),
    (
        "Q19",
        "to_canvas 的 flip_h 换算写错（局部→画布坐标错：往返不一致、lint 误报顶点）",
        "render/scene.mbt",
        """  if l.flip_h {
    x = l.w - x
  }
  if l.flip_v {
    y = l.h - y
  }""",
        """  if l.flip_h {
    x = l.w + x
  }
  if l.flip_v {
    y = l.h - y
  }""",
        "killed",
    ),
    (
        "Q20",
        "lint 不再报窗外顶点（顶点被静默裁掉，层自述的形状与画出来的不符）",
        "agent/ops.mbt",
        """        if cx < x0.to_double() || cx >= x1.to_double() ||
          cy < y0.to_double() || cy >= y1.to_double() {
          reported = true
        }""",
        """        if cx < x0.to_double() - 1000000.0 || cx >= x1.to_double() + 1000000.0 ||
          cy < y0.to_double() - 1000000.0 || cy >= y1.to_double() + 1000000.0 {
          reported = true
        }""",
        "killed",
    ),
    (
        "Q15",
        "pick 丢掉渲染窗守卫（窗外的顶点被报成「有这层」，而那里没有像素）",
        "render/scene.mbt",
        """      let px = x.to_int()
      let py = y.to_int()
      if px < x0 || px >= x1 || py < y0 || py >= y1 {
        continue
      }""",
        """      let px = x.to_int()
      let py = y.to_int()
      if px < x0 - 1000000 || px >= x1 + 1000000 || py < y0 - 1000000 || py >= y1 + 1000000 {
        continue
      }""",
        "killed",
    ),
    (
        "Q16",
        "pick 丢掉画布边界守卫（画布外的点报出层，而 sample 同一个点报「超出画布」）",
        "render/scene.mbt",
        """  if x < 0.0 || y < 0.0 || x >= doc.width.to_double() || y >= doc.height.to_double() {
    return None
  }""",
        """  if x < -1000000.0 || y < -1000000.0 || x >= doc.width.to_double() + 1000000.0 || y >= doc.height.to_double() + 1000000.0 {
    return None
  }""",
        "killed",
    ),
    (
        "Q17",
        "pick 用渲染窗的「盒」而不是真窗（判据比渲染器严：窗内盒外的墨拾不到）",
        "render/scene.mbt",
        """      let (x0, y0, x1, y1) = paint_window(l)""",
        """      let (x0, y0, x1, y1) = (
        l.x.to_int(),
        l.y.to_int(),
        (l.x + l.w).to_int(),
        (l.y + l.h).to_int(),
      )""",
        "killed",
    ),
    (
        "Q12",
        "set-text 不重算盒子（层报出来的范围装不下自己的像素）",
        "agent/session.mbt",
        """  let est = text_box(content, fs)
  let ew = est.0
  let eh = est.1""",
        """  let est = text_box(content, fs)
  let ew = target.w
  let eh = target.h""",
        "killed",
    ),
    (
        "Q13",
        "set-text 不再卡非正字号（改字号这条新路绕过了 add-text 的校验）",
        "agent/session.mbt",
        """    None => target.font_size
  }
  if fs <= 0.0 {""",
        """    None => target.font_size
  }
  if fs <= -1000000.0 {""",
        "killed",
    ),
    (
        "Q14",
        "lint 不再报「盒子装不下自己的文字」（手改容器/缩小盒子静默错位）",
        "agent/ops.mbt",
        """        if l.w + 0.000000001 < ew || l.h + 0.000000001 < eh {""",
        """        if l.w + 0.000000001 < ew - 1000000.0 || l.h + 0.000000001 < eh {""",
        "killed",
    ),
    (
        "Q8",
        "笔宽不再卡负值（描边静默不画，而回包 ok）",
        "agent/ops.mbt",
        """    if w < 0.0 {
      return Err("stroke_w 不能为负（0 = 不画描边）：""",
        """    if w < -1000000.0 {
      return Err("stroke_w 不能为负（0 = 不画描边）：""",
        "killed",
    ),
    (
        "Q9",
        "字号不再卡非正（建出负尺寸层，只有 lint 说话）",
        "agent/session.mbt",
        """  let fs = match arg_d(m, "font_size", 16.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  if fs <= 0.0 {""",
        """  let fs = match arg_d(m, "font_size", 16.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  if fs <= -1000000.0 {""",
        "killed",
    ),
    (
        "Q10",
        "add-text 的数值解析退回静默默认（w=abc 当 0、font_size=abc 当 16）",
        "agent/session.mbt",
        """  let fs = match arg_d(m, "font_size", 16.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }""",
        """  let fs = match to_d(m.get("font_size").unwrap_or("16")) {
    Some(v) => v
    None => 16.0
  }""",
        "killed",
    ),
    (
        "Q11",
        "lint 不再报负笔宽（手改容器的描边静默消失）",
        "agent/ops.mbt",
        """    if l.stroke.width < 0.0 {""",
        """    if l.stroke.width < -1000000.0 {""",
        "killed",
    ),
    (
        "Q7",
        "调整算子不再校验取值范围（value=99 被收下，clamp 成与 value=1 逐位相同）",
        "agent/session.mbt",
        """  if value < lo || value > hi {""",
        """  if value < lo - 1000000.0 || value > hi + 1000000.0 {""",
        "killed",
    ),
    (
        "Q4",
        "无值算子（invert/grayscale）又收下用不上的 value=（静默丢掉）",
        "agent/session.mbt",
        """  let raw = m.get("value")""",
        """  let raw : String? = if has_value { m.get("value") } else { None }""",
        "killed",
    ),
    (
        "Q5",
        "有值算子不给 value 也放行（默认 0 → 建一个什么都不干的层）",
        "agent/session.mbt",
        """    None =>
      return Err(
        "算子 \\{opname} 需要 value=（范围 [\\{@core.fmt_num(lo)}..\\{@core.fmt_num(hi)}]；不给就是建一个什么都不干的层）",
      )
  }""",
        """    None => "0"
  }""",
        "killed",
    ),
    (
        "Q6",
        "lint 不再报 value=0 的空操作调整层",
        "agent/ops.mbt",
        """          } else if a.value == 0.0 {""",
        """          } else if a.value == -12345.0 {""",
        "killed",
    ),
    # ── T 组：标签面（打/摘）与 remove-* 的"没东西可删"（本轮新增）──
    # 每个"入口拒绝/报错"的判据都要有一条变异证明它真的在咬：这些分支的共同
    # 失败模式是**静默成功**（回 ok、指纹变/不变，而调用方以为做成了）。
    (
        "T1",
        "untag 摘标签变成「只留被摘的那个」（!= 写成 ==）",
        "core/document.mbt",
        """    if t != tag {""",
        """    if t == tag {""",
        "killed",
    ),
    (
        "T2",
        "层上的标签判断恒为假（layer_has_tag 永远说没有）",
        "core/document.mbt",
        """    if t == tag {
      return true
    }""",
        """    if t == tag {
      return false
    }""",
        "killed",
    ),
    (
        "T3",
        "untag 不再检查「这个标签真的在不在」（摘不存在的标签静默成功）",
        "agent/session.mbt",
        """  if tag != "*" && !@core.layer_has_tag(l, tag) {""",
        """  if tag != "*" && l.tags.length() < 0 {""",
        "killed",
    ),
    (
        "T4",
        "tag 不再拒空标签（空串被打进容器、改指纹）",
        "agent/session.mbt",
        """  if tag == "" {
    return err("标签不能是空串（空串在 query-layer 里回读成一对空引号、还白占指纹，且没法单独摘）")""",
        """  if tag == "__never__" {
    return err("标签不能是空串（空串在 query-layer 里回读成一对空引号、还白占指纹，且没法单独摘）")""",
        "killed",
    ),
    (
        "T5",
        "tag 不再拒 `*`（打上一个永远摘不掉的标签名）",
        "agent/session.mbt",
        """  if tag == "*" {
    return err("标签不能是 `*`（它保留给 untag <id> * 的清空语义；换个名字）")""",
        """  if tag == "__star__" {
    return err("标签不能是 `*`（它保留给 untag <id> * 的清空语义；换个名字）")""",
        "killed",
    ),
    (
        "T6",
        "remove-mask 不再查「本来有没有蒙版」（删不存在的蒙版静默成功）",
        "agent/session.mbt",
        """  if l.mask is None {
    return err("层 \\{id} 本来就没有蒙版，remove-mask 没东西可删（add-mask 添加）")""",
        """  if l.mask is Some(_) {
    return err("层 \\{id} 本来就没有蒙版，remove-mask 没东西可删（add-mask 添加）")""",
        "killed",
    ),
    # ------------------------------------------------------------------
    # U 组：标签作用域 `layer=@tag`（标签当活选层器）
    # ------------------------------------------------------------------
    (
        "U1",
        "标签作用域语法失认（@ 前缀再也不算标签作用域）",
        "core/mvsl.mbt",
        """  if scope.has_prefix("@") {
    Some(scope[1:].to_owned())""",
        """  if scope.has_prefix("!") {
    Some(scope[1:].to_owned())""",
        "killed",
    ),
    (
        "U2",
        "展开时按层 id 匹配而不是按标签（标签作用域退化成层 id）",
        "core/mvsl.mbt",
        """        for l in doc.layers {
          if layer_has_tag(l, tag) {
            ops.push({ ..op, layer: l.id })
            hit = true
          }
        }""",
        """        for l in doc.layers {
          if l.id == tag {
            ops.push({ ..op, layer: l.id })
            hit = true
          }
        }""",
        "killed",
    ),
    (
        "U3",
        "标签作用域只落到第一个匹配的层（「一层集合」变成「一层」）",
        "core/mvsl.mbt",
        """        for l in doc.layers {
          if layer_has_tag(l, tag) {
            ops.push({ ..op, layer: l.id })
            hit = true
          }
        }""",
        """        for l in doc.layers {
          if layer_has_tag(l, tag) && l.id == doc.layers[0].id {
            ops.push({ ..op, layer: l.id })
            hit = true
          }
        }""",
        "killed",
    ),
    (
        "U4",
        "落不到任何层的标签作用域不再被拒（算子静默不生效）",
        "core/mvsl.mbt",
        """        if n == 0 {
          return Some(
            "算子 \\{op.id} 的 layer=@\\{tag} 落不到任何层""",
        """        if n < 0 {
          return Some(
            "算子 \\{op.id} 的 layer=@\\{tag} 落不到任何层""",
        "killed",
    ),
    (
        "U5",
        "层 id 命名空间规则失效（@ 开头的 id 放行，同一个字符串两种读法）",
        "core/mvsl.mbt",
        """  if id.has_prefix("@") {
    Some("层 id 不许以 `@` 开头""",
        """  if id.has_prefix("@@") {
    Some("层 id 不许以 `@` 开头""",
        "killed",
    ),
    (
        "U6",
        "匹配不到的标签作用域被静默丢掉（不是原样留给下游客拒绝）",
        "core/mvsl.mbt",
        """        if !hit {
          ops.push(op)
        }""",
        """        if !hit {
          let _ = op
        }""",
        "killed",
    ),
    (
        "U7",
        "真渲染/分析忽略 layer= 作用域（整表当文档级跑，层作用域形同不存在）",
        "render/scene.mbt",
        """  // 不含图层级算子 → 原来的单段路径，**逐位不变**。
  if !@core.program_has_layer_scope(prog) {""",
        """  // 不含图层级算子 → 原来的单段路径，**逐位不变**。
  if true {""",
        "killed",
    ),
    (
        "U8",
        "层算子的选择子基底退回合成底图（在错的图上求值/量数）",
        "render/scene.mbt",
        """        list.push({
          op: sub.ops[k],
          layer: l.id,
          basis: kbasis,""",
        """        list.push({
          op: sub.ops[k],
          layer: l.id,
          basis: out,""",
        "killed",
    ),
    (
        "U9",
        "probe 的逐算子 membership 用合成底图（层算子的选区在错的图上算）",
        "agent/affordance_cmds.mbt",
        """    let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(st.basis), @pixel.FieldCache::new()) {""",
        """    let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(base), @pixel.FieldCache::new()) {""",
        "killed",
    ),
    (
        "U10",
        "mvsl-impact 的逐算子权重场用合成底图（支撑集/核心区 ΔE 量错图）",
        "agent/mvsl_cmds.mbt",
        """    let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(st.basis), cache) {""",
        """    let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(base), cache) {""",
        "killed",
    ),
    (
        "U12",
        "lint 把「改了层栅格但对外不可见」误归因为「选择子没命中」（修法被指错方向）",
        "agent/mvsl_lint.mbt",
        """    } else if stage_changed > 0 {""",
        """    } else if stage_changed > 100000000 {""",
        "killed",
    ),
    (
        "U11",
        "mvsl-assert 在近似图（合成底图上跑整表）上判定保护断言",
        "agent/mvsl_cmds.mbt",
        """  let (_, out) = match @render.impact_stages(doc, env, prog) {
    Ok(r) => r
    Err(e) => return err(e)
  }""",
        """  let (out, _) = match @pixel.run_program(base, prog) {
    Ok(r) => r
    Err(e) => return err(e)
  }""",
        "killed",
    ),
    (
        "U13",
        "渲染器忽略蒙版毛边（roughen 存下来但没人读：画面与光滑边逐位相同）",
        "render/scene.mbt",
        """  if mask.roughen > 0.0 {""",
        """  if false {""",
        "killed",
    ),
    (
        "U14",
        "毛边噪声变成常数（边界不再被啃动，只剩「存了参数」）",
        "render/scene.mbt",
        """  amp * (v * 2.0 - 1.0)
}""",
        """  amp * 0.0
}""",
        "killed",
    ),
    (
        "U15",
        "set-mask 变成全量替换：没给的字段被悄悄重置成 0（小调整吃掉别的参数）",
        "agent/session.mbt",
        """  let x = match mask_arg_d(m, "x", old.x) {""",
        """  let x = match mask_arg_d(m, "x", 0.0) {""",
        "killed",
    ),
    (
        "U16",
        "set-mask 改一个不存在的蒙版静默成功（回 ok 而指纹一字未变）",
        "agent/session.mbt",
        r"""    None =>
      return err("层 \{id} 本来就没有蒙版，set-mask 没东西可改（用 add-mask 添加）")""",
        r'''    None =>
      return "{\"ok\":true,\"op\":\"set-mask\",\"id\":\"\{id}\"}"''',
        "killed",
    ),
    (
        "U17",
        "蒙版的取值判据不看 roughen 为负（给了负数却不报，渲染器折成 0）",
        "core/document.mbt",
        """  if m.roughen < 0.0 {""",
        """  if false {""",
        "killed",
    ),
    (
        "U18",
        "容器一律声明最高 render_contract（版本闸失去分辨力：老引擎打不开任何新容器）",
        "mpd/mpd.mbt",
        """  let rc = @core.required_render_contract(d)""",
        """  let rc = @core.RENDER_CONTRACT_VERSION""",
        "killed",
    ),
    (
        "U19",
        "蒙版 kind 认不出来不报错（静默按矩形解析：打开成功、形状是错的、指纹对不上）",
        "core/json.mbt",
        r"""    other => {
      return Err(
        "蒙版 kind 未知：\{other}（认得的是 rect、ellipse；要摘掉蒙版用 remove-mask）",
      )
    }""",
        """    _ => Rect""",
        "killed",
    ),
    (
        "U28",
        "共享软覆盖原语不再是全函数（NaN 会原样漏出，重新埋下挂死的可能）",
        "pixel/color.mbt",
        """  if !(t > 0.0) {
    return 0.0
  }""",
        """  if t <= 0.0 {
    return 0.0
  }""",
        "killed",
    ),
    (
        "U26",
        "geo 选择子丢掉 feather<=0 的硬边分支（边界 d=0 处出 NaN）",
        "pixel/edit.mbt",
        """      let cov = if g.feather <= 0.0 {
        if d <= 0.0 { 1.0 } else { 0.0 }
      } else {
        soft_cover((g.feather - d) / g.feather, Smooth)
      }""",
        """      let cov = soft_cover((g.feather - d) / g.feather, Smooth)""",
        "killed",
    ),
    (
        "U27",
        "geo 选择子的 t 化简成 1-d/feather（数学等价但浮点舍入不同）",
        "pixel/edit.mbt",
        """        soft_cover((g.feather - d) / g.feather, Smooth)""",
        """        soft_cover(1.0 - d / g.feather, Smooth)""",
        "killed",
    ),
    (
        "U24",
        "共享软覆盖原语的 Linear 预设被换成 Smooth（蒙版羽化曲线静默变陡）",
        "pixel/color.mbt",
        """    Linear => t
    Smooth => smoothstep(t)""",
        """    Linear => smoothstep(t)
    Smooth => smoothstep(t)""",
        "killed",
    ),
    (
        "U25",
        "共享软覆盖原语的 Smooth 预设退化成线性（选择子软窗边界不再连续可导）",
        "pixel/color.mbt",
        """    Linear => t
    Smooth => smoothstep(t)""",
        """    Linear => t
    Smooth => t""",
        "killed",
    ),
    (
        "U23",
        "geo 选择子的软覆盖方向反了（边界处就衰减，窗内反而落选）",
        "pixel/edit.mbt",
        """        soft_cover((g.feather - d) / g.feather, Smooth)""",
        """        soft_cover(d / g.feather, Smooth)""",
        "killed",
    ),
    (
        "U21",
        "文档级 STAGE(n>0) 与图层级算子共存被放行（两段式下静默换掉取到的像素）",
        "core/mvsl.mbt",
        """        let ok = same_seg && n - 1 < i
        if n > 0 && !ok {""",
        """        let ok = true
        if false {""",
        "killed",
    ),
    (
        "U22",
        "算子字段的中性值回落 0（relight_gain 缺省 = 0 → 合法语义被静默拒装）",
        "core/mvsl.mbt",
        """    relight_gain: jfneutral(v, "relight_gain", 1.0),""",
        """    relight_gain: jfin(v, "relight_gain"),""",
        "killed",
    ),
    (
        "U20",
        "lint 不报手改容器里的退化蒙版（负 roughen / 非正尺寸没人说）",
        "agent/ops.mbt",
        r"""        let me = @core.mask_param_error(mk)
        if me != "" {
          v.push("P2 mask 层 \{l.id}：\{me}")
        }""",
        """        let _ = @core.mask_param_error(mk)""",
        "killed",
    ),
    (
        "W1",
        "编辑表条数判据写成 >= （恰好 256 条被误拒）",
        "core/mvsl.mbt",
        "  if n > MAX_EDIT_OPS {",
        "  if n >= MAX_EDIT_OPS {",
        "killed",
    ),
    (
        "W2",
        "编辑表断言数判据失效（65 条断言被放行）",
        "core/mvsl.mbt",
        "  if g > MAX_EDIT_GUARDS {",
        "  if g > MAX_EDIT_GUARDS + 1000000 {",
        "killed",
    ),
    (
        "W3",
        "编辑表代价判据失效（巨幅画布被放行）",
        "core/mvsl.mbt",
        "  if pxops > MAX_EDIT_PIXEL_OPS {",
        "  if pxops > MAX_EDIT_PIXEL_OPS * 1.0E9 {",
        "killed",
    ),
    (
        "W4",
        "入口 mvsl-set 不判规模（越界的表装得进 session）",
        "agent/mvsl_cmds.mbt",
        """  let cost = @core.edit_cost_error(prog, doc.width, doc.height)
  if cost != "" {
    return err(cost)
  }""",
        """  let _ = @core.edit_cost_error(prog, doc.width, doc.height)""",
        "killed",
    ),
    (
        "W5",
        "渲染执行时不判规模（装表后 set-canvas 放大的路没人拦）",
        "render/scene.mbt",
        """  match edit_cost_refusal(doc, prog) {
    Some(e) => return Err(e)
    None => ()
  }
""",
        """  let _ = edit_cost_refusal(doc, prog)
""",
        "killed",
    ),
    # --- 第 49 轮：可渲染上限（画布 > 4096 此前被静默截断）---
    (
        "X1",
        "可渲染上限判据失效（超限画布被放行 —— 又变成静默截断）",
        "render/scene.mbt",
        "  if w <= RENDER_MAX_SIDE && h <= RENDER_MAX_SIDE {",
        "  if w <= RENDER_MAX_SIDE || h <= RENDER_MAX_SIDE {",
        "killed",
    ),
    (
        "X2",
        "可渲染上限判据把边界写窄（4096 本身被拒）",
        "render/scene.mbt",
        "  if w <= RENDER_MAX_SIDE && h <= RENDER_MAX_SIDE {",
        "  if w < RENDER_MAX_SIDE && h < RENDER_MAX_SIDE {",
        "killed",
    ),
    (
        "X3",
        "入口 new 不判可渲染上限（5000 宽画布建得出来）",
        "agent/session.mbt",
        """  let lim = @render.render_limit_error(w, h)
  if lim != "" {
    return err(lim)
  }
  match check_kv_args(tokens, 3, ["uuid"], "new") {""",
        """  let lim = @render.render_limit_error(w, h)
  let _ = lim
  match check_kv_args(tokens, 3, ["uuid"], "new") {""",
        "killed",
    ),
    (
        "X4",
        "入口 set-canvas 不判可渲染上限（装表后能把画布改到 5000）",
        "agent/session.mbt",
        """  let lim = @render.render_limit_error(w, h)
  if lim != "" {
    return err(lim)
  }
  snapshot(s, doc, "set-canvas \{w}x\{h}")""",
        """  let lim = @render.render_limit_error(w, h)
  let _ = lim
  snapshot(s, doc, "set-canvas \{w}x\{h}")""",
        "killed",
    ),
    (
        "X5",
        "lint 不报超出可渲染上限的画布（手改容器没人说话）",
        "agent/ops.mbt",
        """  let rlim = @render.render_limit_error(doc.width, doc.height)
  if rlim != "" {
    v.push("P0 render 画布超出可渲染上限：\{rlim}")
  }""",
        """  let rlim = @render.render_limit_error(doc.width, doc.height)
  let _ = rlim""",
        "killed",
    ),
    (
        "X6",
        "渲染截断整个去掉（改一处实现时最容易顺手删掉的那句）",
        "render/scene.mbt",
        """  let cw = if w > RENDER_MAX_SIDE { RENDER_MAX_SIDE } else { w }
  let ch = if h > RENDER_MAX_SIDE { RENDER_MAX_SIDE } else { h }
  (cw, ch)""",
        """  (w, h)""",
        "killed",
    ),
    (
        "Y1",
        "census 又把 canvas 报成**截断后**的渲染尺寸（回读缺陷原样复发）",
        "agent/affordance_cmds.mbt",
        '''  sb.write_string(",\\"canvas\\":[\\{dw},\\{dh}]")''',
        '''  sb.write_string(",\\"canvas\\":[\\{base.width},\\{base.height}]")''',
        "killed",
    ),
    (
        "Y2",
        "open-mpd 又对超限容器一声不吭（notice 恒为空）",
        "agent/session.mbt",
        '''  Ok((@core.fingerprint(m.doc), @render.render_limit_error(m.doc.width, m.doc.height)))''',
        '''  Ok((@core.fingerprint(m.doc), ""))''',
        "killed",
    ),
    (
        "Z1",
        "文档级段不再把 stage:n 从表序改写成段内序号（静默指到别的缓冲）",
        "core/mvsl.mbt",
        '''            { ..op.sel, basis: Stage(seg_no[n - 1]) }''',
        '''            { ..op.sel, basis: Stage(n) }''',
        "killed",
    ),
    (
        "Z2",
        "逐算子报告又把 basis 报成段基准而不是真正求值的缓冲（数字全错而渲染是对的）",
        "render/scene.mbt",
        '''      let obasis = match prog.ops[i].sel.basis {
        @core.Base => base
        @core.Stage(n) => @pixel.stage_basis_of(base, stages, n)
      }''',
        '''      let obasis = base''',
        "killed",
    ),
    (
        "Z5",
        "入口判据改回**展开前**的表（标签展开会改表序 → 入口说合法、渲染才拒）",
        "agent/mvsl_cmds.mbt",
        '''  @core.layer_scope_error(@core.expand_layer_scopes(prog, doc))''',
        '''  @core.layer_scope_error(prog)''',
        "killed",
    ),
    (
        "Z6",
        "渲染侧判据搬回**展开前**（判据看一张表、重编号看另一张表）",
        "render/scene.mbt",
        '''  let prog = @core.expand_layer_scopes(prog, doc)
  // ⚠️ `stage:n` 的判据必须在**展开之后**跑：一个 `layer=@tag` 的算子展开成
  // "标签命中几层就几条"，表序会变，而"同段 + 严格在前"正是按表序判的——
  // 判据看展开前的表、下面 `program_*_scope` 的重编号看展开后的表，就是同一个
  // 判断在**两张表**上各判一次（展开前说合法、执行时才发现指到别段）。
  match @core.layer_scope_error(prog) {
    Some(e) => return Err(e)
    None => ()
  }''',
        '''  match @core.layer_scope_error(prog) {
    Some(e) => return Err(e)
    None => ()
  }
  let prog = @core.expand_layer_scopes(prog, doc)''',
        "killed",
    ),
    (
        "Z4",
        "stage:n 判据丢掉\"同段\"要求（跨段引用被放行 → 取到别段的缓冲）",
        "core/mvsl.mbt",
        '''        let ok = same_seg && n - 1 < i''',
        '''        let ok = n - 1 < i''',
        "killed",
    ),
    (
        "Z3",
        "stage:n 的静态判据丢掉上界（自指/前视变成校验放行、渲染才失败）",
        "core/mvsl.mbt",
        '''        let ok = same_seg && n - 1 < i''',
        '''        let ok = same_seg''',
        "killed",
    ),
    (
        "Z7",
        "位图层的盒子退回缺省 100×100（任意比例的图被静默压成正方形——回包里 asset_size 还写着真实尺寸）",
        "agent/ops.mbt",
        '''    return Ok((iw.to_double(), ih.to_double()))''',
        '''    return Ok((100.0, 100.0))''',
        "killed",
    ),
    (
        "Z8",
        "只给一边时另一边不按原比例推（留缺省 100 → 长宽比被悄悄改掉）",
        "agent/ops.mbt",
        '''  if w_given {
    return Ok((w, w / ratio))
  }''',
        '''  if w_given {
    return Ok((w, 100.0))
  }''',
        "killed",
    ),
    (
        "Z10",
        "group-add 把新成员塞到 children 头部（组内层序反转，画面变了）",
        "agent/session.mbt",
        '''    let kids = l.children
    for m in moving {
      kids.push(m)
    }''',
        '''    let kids = l.children
    for m in moving {
      kids.insert(0, m)
    }''',
        "killed",
    ),
    (
        "Z11",
        "group-remove 把成员推到根级栈顶（落点从『组的下一层』变成最上面）",
        "agent/session.mbt",
        '''    doc.layers.insert(idx + off, t)''',
        '''    doc.layers.push(t)''',
        "killed",
    ),
    (
        "Z12",
        "group-add 忘了从根级摘掉（层同时挂在根级与组里）",
        "agent/session.mbt",
        '''  for mid in ids {
    let _ = detach_layer(doc.layers, mid)
  }''',
        '''  for mid in ids {
    let _ = mid
  }''',
        "killed",
    ),
    (
        "Q25",
        "dab 盒去掉 ±1 松弛（落笔窗口太紧：笔触边缘被静默裁掉一列像素）",
        "render/scene.mbt",
        """  let x0 = (l.x + d.x - d.r).to_int() - 1
  let y0 = (l.y + d.y - d.r).to_int() - 1
  let x1 = (l.x + d.x + d.r).to_int() + 1
  let y1 = (l.y + d.y + d.r).to_int() + 1""",
        """  let x0 = (l.x + d.x - d.r).to_int()
  let y0 = (l.y + d.y - d.r).to_int()
  let x1 = (l.x + d.x + d.r).to_int()
  let y1 = (l.y + d.y + d.r).to_int()""",
        "killed",
    ),
    (
        "Q27",
        "蒙版「覆盖恒为 1」的盒忽略 feather+roughen（羽化带里的像素被按全覆盖合成：整层静默加亮）",
        "render/scene.mbt",
        "  let t = m.feather + m.roughen + INTERIOR_EPS",
        "  let t = INTERIOR_EPS",
        "killed",
    ),
    (
        "Q26",
        "实心矩形的快速内部判宽 1 像素（边界像素按全覆盖合成：画面多出一条硬边）",
        "render/scene.mbt",
        """  let ix1 = clamp_int((l.x + l.w - rr - 0.75 - INTERIOR_EPS).ceil(), px0, px1)
  let iy0 = clamp_int((l.y + rr - 0.25 + INTERIOR_EPS).ceil(), py0, py1)
  let iy1 = clamp_int((l.y + l.h - rr - 0.75 - INTERIOR_EPS).ceil(), py0, py1)""",
        """  let ix1 = clamp_int((l.x + l.w - rr - 0.75 - INTERIOR_EPS).ceil() + 1.0, px0, px1)
  let iy0 = clamp_int((l.y + rr - 0.25 + INTERIOR_EPS).ceil(), py0, py1)
  let iy1 = clamp_int((l.y + l.h - rr - 0.75 - INTERIOR_EPS).ceil() + 1.0, py0, py1)""",
        "killed",
    ),
    (
        "Q28",
        "圆角矩形的快速内部不内缩半径（圆弧外那圈像素被按全覆盖合成：角上静默多一块）",
        "render/scene.mbt",
        "  let rr = clamped_radius(l.w, l.h, l.corner_radius)",
        "  let rr = 0.0",
        "killed",
    ),
    (
        "Q29",
        "调整层的蒙版不参与混合（覆盖度被丢掉：羽化带变硬边）",
        "render/scene.mbt",
        "        buf.pixels[at] = if strength >= 1.0 { op } else { @pixel.lerp_argb(p, op, strength) }",
        "        buf.pixels[at] = op",
        "killed",
    ),
    (
        "Q30",
        "调整层蒙版窗口不含 roughen 外溢（毛边甩到形状外那圈像素静默漏改）",
        "render/scene.mbt",
        "  let slack = m.roughen.ceil() + 1.0",
        "  let slack = 0.0",
        "killed",
    ),
    (
        "Q31",
        "调整层蒙版窗口对 invert 仍按形状 bbox 裁（区域无界的蒙版漏掉整片）",
        "render/scene.mbt",
        "  if m.invert || m.w <= 0.0 || m.h <= 0.0 {",
        "  if m.w <= 0.0 || m.h <= 0.0 {",
        "killed",
    ),
    (
        "Q32",
        "调整层的邻域算子在原缓冲上就地做（把已经改过的像素当邻居）",
        "render/scene.mbt",
        "  apply_adjust(l.adjust, scratch)",
        "  apply_adjust(l.adjust, buf)",
        "killed",
    ),
    (
        "Q33",
        "调整层 α=1 时把蒙版当没有：整幅施加（蒙版装了却什么都不干）",
        "render/scene.mbt",
        "  if eff_opacity >= 1.0 && l.mask is None {",
        "  if eff_opacity >= 1.0 {",
        # 这条曾是**等价**变异（旧结构下"无蒙版走软混合"与"直通"逐位相同，只是
        # 白拷一次整幅）；五十三把软强度收成一处（覆盖度 × α）之后，同一行上的
        # `l.mask is None` 变成真判据——去掉它，α=1 的带蒙版调整层会整幅施加，
        # 蒙版静默失效。等价 → killed（锚点腐烂时自检当场报"出现 0 次"）。
        "killed",
    ),
    (
        "Q48",
        "描边盖满的判据写成 > 而不是 >=（等号那一格——内缩盒正好退化成空——悄悄放过）",
        "agent/ops.mbt",
        '  if sw * 2.0 < short {\n    return None\n  }',
        '  if sw * 2.0 <= short {\n    return None\n  }',
        "killed",
    ),
    (
        "Q49",
        "窗裁的判据不看画布（整层在画布外也报：没有可见损失却报违规）",
        "agent/ops.mbt",
        '        let in_canvas = cx >= 0.0 && cy >= 0.0 && cx < cw.to_double() && cy < ch.to_double()',
        '        let in_canvas = true',
        "killed",
    ),
    (
        "Q50",
        "窗裁的换算不走 to_canvas（用局部坐标加平移，旋转/翻转被忽略）",
        "agent/ops.mbt",
        '        let (cx, cy) = @render.to_canvas(l, p.0, p.1)',
        '        let (cx, cy) = (p.0 + l.x, p.1 + l.y)',
        "killed",
    ),
    (
        "Q51",
        "窗裁的容差失效（把窗的 2px 松弛量当成 0：正常的线也报）",
        "agent/ops.mbt",
        '          if cut > 2.0 {',
        '          if cut > 0.0 {',
        "killed",
    ),
    (
        "Q52",
        "笔触窗口改用层盒子（w/h 不是读点：会把层外的墨整块裁掉）",
        "render/scene.mbt",
        "dabs_window(l, buf.width, buf.height)",
        "dabs_window(l, l.w.to_int(), l.h.to_int())",
        "killed",
    ),
    (
        "Q53",
        "笔触盒子判据的等号被算成「装不下」（判据边界抖动）",
        "agent/ops.mbt",
        "  if cx0 + eps >= bx0 && cy0 + eps >= by0 && cx1 <= bx1 + eps && cy1 <= by1 + eps {",
        "  if cx0 + eps >= bx0 && cy0 + eps >= by0 && cx1 <= bx1 - eps && cy1 <= by1 + eps {",
        "killed",
    ),
    (
        "Q54",
        "笔触盒子判据不算 dab 半径（圆心在盒内就算装得下）",
        "agent/ops.mbt",
        "    let dx1 = d.x + d.r",
        "    let dx1 = d.x",
        "killed",
    ),
    (
        "Q55",
        "笔触盒子判据不按画布裁剪（画布外的墨也算可见错位）",
        "agent/ops.mbt",
        "  let cx1 = lo_hi(l.x + x1, 0.0, cwd)",
        "  let cx1 = l.x + x1",
        "killed",
    ),
    # Q59（"能力表说调整层也有 opacity"）已**退休**：那条行为现在是正确的
    # ——调整层的 α 真的参与渲染（软强度 = 蒙版覆盖度 × α，PLAN 五十三），
    # 于是 caps 就该报它。退休记录在 PLAN 五十三（锚点自检当场报"出现 0 次"）。
    (
        "Q60",
        "调整层的软强度丢掉层不透明度（α 又变回那个开关：0 之外全是全强度）",
        "render/scene.mbt",
        "      let strength = cover * eff_opacity",
        "      let strength = cover",
        "killed",
    ),
    (
        "Q61",
        "调整层无蒙版时忽略 α（快路径把\"全强度\"当\"没有软混合\"）",
        "render/scene.mbt",
        "  if eff_opacity >= 1.0 && l.mask is None {",
        "  if l.mask is None {",
        "killed",
    ),
    (
        "Q62",
        "组的 α 退回逐子层各自打折（重叠区被混合两次：接缝回来了）",
        "render/scene.mbt",
        "        paint_layer(c, scratch, env, 1.0)",
        "        paint_layer(c, buf, env, eff_opacity)",
        "killed",
    ),
    (
        "Q63",
        "组的整体打折忘了乘组 α（组画面的 alpha 不折，等于组 α 只有 0/1 两档）",
        "render/scene.mbt",
        "          let src = compose_src(255, p, 1.0, eff_opacity)",
        "          let src = compose_src(255, p, 1.0, 1.0)",
        "killed",
    ),
    (
        "Q64",
        "组的 move 只改自己的 x/y（后代不动：回 ok 而画面一个像素不变）",
        "agent/session.mbt",
        "    update_layer(doc.layers, id, fn(l) { shift_layer_tree(l, dx, dy) })",
        "    update_layer(doc.layers, id, fn(l) { { ..l, x, y } })",
        "killed",
    ),
    (
        "Q66",
        "嵌套后代被搬两遍（同一棵子树的 delta 叠加：更深的后代挪了两倍）",
        "agent/ops.mbt",
        "  { ..l, x: l.x + dx, y: l.y + dy, children: kids }",
        "  { ..l, x: l.x + dx * 2.0, y: l.y + dy * 2.0, children: kids }",
        # 只在**有嵌套**时露馅：`agent/group_move_test.mbt` 的 `go>gi>a` 用例
        # 断言最内层 `a` 的盒子恰好是 7,3（搬两遍会是 14,6）。
        "killed",
    ),
    (
        "Q65",
        "递归平移把后代搬两遍（重复 push 同一个子层）",
        "agent/ops.mbt",
        "    kids.push(shift_layer_tree(c, dx, dy))\n  }",
        "    kids.push(shift_layer_tree(c, dx, dy))\n    kids.push(shift_layer_tree(c, dx, dy))\n  }",
        # **等价**：重复 push 的是同一个 `kids` 数组——`kids[j]` 被后一个（同样的值）
        # 覆盖，数组内容与长度都不变。实测：推演一遍（两条路径都只搬一次）后
        # 手工把这段注入源文件跑全量测试，119 条全过、一条都不红 ⇒ 判定等价，
        # 与 `Q65` 最初想守的"祖先位移叠加到后代头上"根本不是同一件事
        # （那需要 `x: c.x + dx` 这种真的多加一次，见 PLAN 五十五）。
        "equivalent",
    ),
    (
        "Q56",
        "能力表把字段名写错（读点矩阵查不到 ⇒ 这个能力永远不报，画面参数静默不可达）",
        "agent/ops.mbt",
        '    ("rotate", "rotation_deg"),',
        '    ("rotate", "rotation_deg_typo"),',
        "killed",
    ),
    (
        "Q57",
        "能力表说文本层能 resize（面板于是又画出改了不动的 W/H 输入框）",
        "agent/ops.mbt",
        "  if face {\n    caps.push(\"resize\")\n  }",
        "  if face || text_kind {\n    caps.push(\"resize\")\n  }",
        "killed",
    ),
    (
        "Q58",
        "回包不再报能力表（前端读不到 caps ⇒ 人类侧能力控件全灭/或退回去猜 kind）",
        "agent/session.mbt",
        '  sb.write_string(",\\"caps\\":[")',
        '  sb.write_string(",\\"caps_x\\":[")',
        "killed",
    ),
    (
        "Q42",
        "fill 那一行漏掉 polygon（多边形的填充被当成死数据，正常路径被误伤）",
        "agent/ops.mbt",
        '      kinds: ["rect", "ellipse", "polygon", "text"],',
        '      kinds: ["rect", "ellipse", "text"],',
        "killed",
    ),
    (
        "Q43",
        "stroke 那一行把 polygon 也算成读描边的（多边形描边静默收下、画面不变）",
        "agent/ops.mbt",
        '      kinds: ["rect", "ellipse", "line"],',
        '      kinds: ["rect", "ellipse", "line", "polygon"],',
        "killed",
    ),
    (
        "Q44",
        "fill 的默认值判据失效（默认灰也被当成写了填充：正常矩形全被误伤）",
        "agent/ops.mbt",
        '          @core.Fill::Solid(c) => if c == 0xFF808080 { "" } else { "fill=\\{@codec.color_to_hex(c)}" }',
        '          @core.Fill::Solid(c) => if false { "" } else { "fill=\\{@codec.color_to_hex(c)}" }',
        "killed",
    ),
    (
        "Q45",
        "字典不再按读点矩阵过滤（建层命令又开始广告它做不到的键）",
        "agent/session.mbt",
        '    if f == "" || kind_only_dead_note(kind, f) == "" {',
        '    if true {',
        "killed",
    ),
    (
        "Q46",
        "key_field 丢掉 lgrad 的映射（折线上的渐变填充从键表里漏回一条生路）",
        "agent/ops.mbt",
        '    "lgrad" => "fill"',
        '    "lgrad" => ""',
        "killed",
    ),
    (
        "Q47",
        "只给 stroke_w 的那条闸问的是旧宽度（等于永不触发：多边形描边宽静默收下）",
        "agent/ops.mbt",
        '              let cand = { ..nl, stroke: { color: nl.stroke.color, width: w } }',
        '              let cand = { ..nl, stroke: { color: nl.stroke.color, width: nl.stroke.width } }',
        "killed",
    ),
    (
        "Q35",
        "读点矩阵里把某一行的合法 kind 写宽（group 也被当成能读 rotation 的层）",
        "agent/ops.mbt",
        '      field: "rotation_deg",\n      reader: "有面的层（几何/位图）",\n      hint: "",\n      kinds: ["rect", "ellipse", "polygon", "line", "image"],',
        '      field: "rotation_deg",\n      reader: "有面的层（几何/位图）",\n      hint: "",\n      kinds: ["rect", "ellipse", "polygon", "line", "image", "group"],',
        "killed",
    ),
    (
        "Q36",
        "mask 那一行漏掉 adjust（上一轮刚接上的读点被写回去）",
        "agent/ops.mbt",
        '      kinds: ["rect", "ellipse", "polygon", "line", "image", "text", "raster", "adjust"],',
        '      kinds: ["rect", "ellipse", "polygon", "line", "image", "text", "raster"],',
        "killed",
    ),
    (
        "Q37",
        "写入门禁的判据整个失效（kind_only_write_error 永不报错）",
        "agent/ops.mbt",
        '      if c.kinds.contains(kind_str(l.kind)) {\n        return None\n      }\n      return kind_only_reject_text(c, l.kind, l.id, field, why)',
        '      if false {\n        return None\n      }\n      return kind_only_reject_text(c, l.kind, l.id, field, why)',
        "killed",
    ),
    (
        "Q38",
        "rotate 的门禁问的是候选层以外的值（等于永不触发）",
        "agent/session.mbt",
        '  match kind_only_write_error({ ..rl, rotation_deg: deg }, "rotation_deg") {',
        '  match kind_only_write_error({ ..rl, rotation_deg: 0.0 }, "rotation_deg") {',
        "killed",
    ),
    (
        "Q39",
        "set-style 的 blend 门禁问了一个不存在的字段（等于没有门禁）",
        "agent/ops.mbt",
        '          match kind_only_write_error(cand, "blend") {',
        '          match kind_only_write_error(cand, "blendX") {',
        "killed",
    ),
    (
        "Q40",
        "add-mask 的门禁问了一个不存在的字段（组上装蒙版又变回静默）",
        "agent/session.mbt",
        '  match kind_only_write_error({ ..ml, mask: Some(mask_write_probe()) }, "mask") {',
        '  match kind_only_write_error({ ..ml, mask: Some(mask_write_probe()) }, "maskX") {',
        "killed",
    ),
    (
        "Q41",
        "清字段的写法被一并拒掉（写默认值也当成死数据：旧容器再也洗不回来）",
        "agent/ops.mbt",
        '        if l.rotation_deg != 0.0 {\n          "rotation_deg=\\{@core.fmt_num(l.rotation_deg)}"',
        '        if true {\n          "rotation_deg=\\{@core.fmt_num(l.rotation_deg)}"',
        "killed",
    ),
    (
        "Z9",
        "set-image 从『原地换像素』退化成『重造该层』（蒙版/标签/层序一起丢）",
        "agent/session.mbt",
        '''  let _ = update_layer(doc.layers, id, fn(l) { { ..l, asset_hash: hash, w: bw, h: bh } })''',
        '''  let _ = update_layer(doc.layers, id, fn(l) { { ..l, asset_hash: hash, w: bw, h: bh, mask: None, tags: [] } })''',
        "killed",
    ),
    ]


TEST_TIMEOUT = 900  # 秒；正常一轮全量测试约 1–2 分钟

def run_native_tests():
    """跑一轮全量 native 测试。

    ⚠️ **必须有超时。** 实测撞到过一种变异：把 `feather<=0` 的硬边分支删掉，
    边界上算出 `0/0 = NaN`，NaN 漏进下游某个带比较的循环，测试**永不结束**
    （`moon test -p moonpainter/pixel` 挂了 40 分钟、日志一个字节都没有）。
    当时变异门没有超时，于是**整个门跟着一起挂死**——比"漏掉一条变异"更糟，
    因为连"被抓住 N 个"的汇总都拿不到。超时把这种变异判成 KILLED
    （它确实被抓住了：测试跑不完就是最响的失败），而不是让门一起停摆。
    （那处 NaN 已同时修成"原语不许输出 NaN"，这里是第二道保险。）
    """
    try:
        r = subprocess.run(
            ["moon", "test", "--target", "native"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=TEST_TIMEOUT,
        )
        return r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        def dec(x):
            if x is None:
                return ""
            return x if isinstance(x, str) else x.decode("utf-8", "replace")

        return dec(e.stdout) + dec(e.stderr) + "\n@@TIMEOUT@@\n"


def judge(out):
    if "@@TIMEOUT@@" in out:
        # 测试没跑完（挂死）。这不是"存活"——变异确实把行为改坏了，
        # 而且坏得很明显（跑不完）。详见 run_native_tests 的注释。
        return "KILLED", f"测试挂死（超过 {TEST_TIMEOUT}s 未结束）"
    summary = [l for l in out.splitlines() if l.startswith("Total tests")]
    crashed = "exited with signal" in out or "SIGABRT" in out
    if not summary:
        if crashed:
            return "KILLED", "测试进程崩溃（abort）"
        # 没有 "Total tests" 行 = **测试压根没跑到**：变异编译不过（"failed when
        # checking"/"Parse error"）或工具链报错。此前这种情况落在 UNKNOWN 上，
        # 而 UNKNOWN 被汇总算进了"被抓住"——实测注入一段编译不过的替换串，
        # 摘要印的是"被抓住 1，存活 0 / PASS"。
        return "INVALID", "测试没跑起来（变异编译不过 / 工具链报错）"
    failed = int(summary[-1].split("failed:")[1].strip().rstrip("."))
    if failed > 0:
        return "KILLED", f"{failed} 条测试失败"
    if crashed:
        return "KILLED", "测试进程崩溃（abort）"
    return "SURVIVED", "全部通过（无人守护）"


def stale_in(bodies, wanted):
    """`[(mid, rel)]`：哪些变异看起来**正注入在树里**（锚点串不在、替换串在）。

    纯函数（吃 `{rel: 文本}`），所以 `--selfcheck` 能喂合成样本给它，
    不必真去改文件——**判据自己也要有能抓住注入的测试**。
    """
    out = []
    for mid, _desc, rel, old, new, _expect in MUTS:
        if rel not in wanted:
            continue
        body = bodies.get(rel)
        if body is None:
            continue
        if old not in body and new in body:
            out.append((mid, rel))
    return out


def selfcheck():
    """这道"残余态"护栏的自检：喂合成正文，三种情形都要判对。"""
    mid, _desc, rel, old, new, _expect = MUTS[0]
    cases = [
        ("干净（锚点在）", {rel: "prefix " + old + " suffix"}, []),
        ("残留（锚点不在、替换串在）", {rel: old.replace(old, new)}, [(mid, rel)]),
        ("既不在锚点也不在替换串（重构过）", {rel: "something else"}, []),
        ("别的文件残留，不在本次目标里", {"other/file.mbt": new}, []),
    ]
    bad = []
    for name, bodies, want in cases:
        got = stale_in(bodies, {rel})
        if got != want:
            bad.append(f"{name}：期望 {want}，实际 {got}")
    if bad:
        print("FAIL: 残余态护栏自检不过：", file=sys.stderr)
        for b in bad:
            print("   " + b, file=sys.stderr)
        return 1
    print(f"残余态护栏自检通过（{len(cases)} 种情形；样本用 {mid}）")
    return 0


def check_anchors():
    """只校验每个变异的 old 锚点在当前源码里**唯一存在**，不跑测试（秒级）。

    锚点失效 = 该处覆盖被悄悄拿掉。实测踩过：R3 的锚点被一次重构改掉、
    R4 的锚点变成匹配 2 处，两个变异静静失效了一轮，而"变异 33 个全通过"
    看起来一切正常。所以这一步要独立、要便宜、要进常规门禁。
    """
    bad = []
    seen_ids = {}
    for mid, desc, rel, old, new, expect in MUTS:
        # 编号唯一：`mutation_scan.py Q3` 这种按 id 单跑，重复 id 会让它一次跑
        # 两个变异（而汇总里的计数看起来照旧正常）。实测踩过：新加的三条与既有
        # 的 Q3 撞了编号。
        if mid in seen_ids:
            bad.append((mid, rel, "编号与前面那条重复（按 id 单跑会有歧义）"))
        seen_ids[mid] = True
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            bad.append((mid, rel, "文件不存在"))
            continue
        n = open(path, encoding="utf-8").read().count(old)
        if n != 1:
            bad.append((mid, rel, f"锚点出现 {n} 次，应为 1 次"))
    if bad:
        print(f"变异锚点失效 {len(bad)} 个（这些变异等于没在跑）：", file=sys.stderr)
        for mid, rel, why in bad:
            print(f"  {mid}  {rel}  {why}", file=sys.stderr)
        return 1
    print(f"变异锚点全部有效（{len(MUTS)} 个，每个唯一命中 1 处）")
    return 0


def main():
    if "--check-anchors" in sys.argv:
        return check_anchors()
    if "--selfcheck" in sys.argv:
        return selfcheck()
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

    # **开工前体检：树里是不是留着上一次注入的变异？**
    # 信号（SIGTERM/SIGINT）现在能还原，但 `kill -9`、断电、OOM 都抓不住——
    # 而残留是**悄悄毁掉整轮结果**：扫描把"变异态"当基线，于是要么锚点找不到
    # （判 INVALID、"这条没在测任何东西"），要么把已经坏掉的代码当参照。
    # 判据：某个变异的**替换串在文件里、锚点串不在** ⇒ 这个文件正处在那一态。
    rels = {t[2] for t in todo}
    bodies = {}
    for _rel in rels:
        with open(os.path.join(ROOT, _rel), encoding="utf-8") as f:
            bodies[_rel] = f.read()
    stale = stale_in(bodies, rels)
    if stale:
        print("\n拒绝开工：树里像是**留着上一次注入的变异**（锚点串不在、替换串在）：",
              file=sys.stderr)
        for mid, rel in stale:
            print(f"   {rel}  ←  {mid} 的替换串还在；`git diff {rel}` 看一眼，"
                  f"确认不是自己的改动后 `git checkout -- {rel}`", file=sys.stderr)
        print("（`kill -9` / 断电 / OOM 都会留下这种状态，信号处理器抓不住）",
              file=sys.stderr)
        return 3

    # 扫描前逐字节快照：收尾核对"每个目标文件是不是回到了扫描前的样子"。
    # 这一条不是形式主义——它同时兜住"信号中断没还原""还原写错路径"
    # "两次注入叠在一起"，而这三件事都只表现为**树里留着变异**。
    snapshot = {}
    for _mid, _desc, rel, _old, _new, _expect in todo:
        p = os.path.join(ROOT, rel)
        if rel not in snapshot:
            with open(p, "rb") as f:
                snapshot[rel] = f.read()

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
        global INFLIGHT
        try:
            INFLIGHT = (mid, path)
            open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
            verdict, detail = judge(run_native_tests())
        finally:
            shutil.copy(BAK, path)  # 无论成败都还原
            INFLIGHT = None
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
    invalid = [r for r in results if r[3] == "INVALID"]
    valid = [r for r in results if r[3] != "INVALID"]
    survived = [r for r in valid if r[3] == "SURVIVED"]
    killed = [r for r in valid if r[3] == "KILLED"]
    unknown = [r for r in valid if r[3] == "UNKNOWN"]
    print(
        f"\n变异 {len(valid)} 个：被抓住 {len(killed)}，存活 {len(survived)}"
        + (f"，无法判定 {len(unknown)}" if unknown else "")
        + (f"，无效 {len(invalid)}" if invalid else "")
    )
    for r in survived:
        if r[2] == "equivalent":
            print(f"  存活的 {r[0]} 是**已确认的等价变异**（不改变行为，允许存活）")
    # **收尾核对**：目标文件必须逐个回到扫描前的字节。信号中断、还原写错路径、
    # 两次注入叠在一起——这三件事都只表现为"树里留着注入的变异"，而 `git status`
    # 只会说"文件被改过"，下一步就可能把它当自己的改动提交上去（实测踩过）。
    leftover = []
    for _rel, _bytes in snapshot.items():
        with open(os.path.join(ROOT, _rel), "rb") as f:
            if f.read() != _bytes:
                leftover.append(_rel)
    if leftover:
        print("\nFAIL: 这些文件扫描结束后**没有回到扫描前的样子**（树里可能留着注入的变异）：")
        for _rel in leftover:
            print(f"   {_rel}  →  `git diff {_rel}` 看一眼，**别把它当自己的改动提交**")
    else:
        print(f"收尾核对：{len(snapshot)} 个目标文件都回到了扫描前的字节 ✓", flush=True)

    if misses:
        print(f"\nFAIL: 这些变异应当被抓住却存活了：{misses}")
        return 1
    # INVALID 必须**判失败**：它不是"通过"，是**这条变异压根没在测试任何东西**
    # （锚点失效 = 覆盖被拿掉；编译不过 = 变异自己不合法）。此前它被静默排除在
    # 统计之外——实测 R29 的替换串括号不配对、一直编译不过，而每次汇总都印
    # "MUTATION SCAN PASS ✓（所有非等价变异都被测试抓住）"。
    if unknown:
        print(f"\nFAIL: 这些变异**无法判定**（测试没跑起来 / 结果读不出来）：")
        for r in unknown:
            print(f"   {r[0]:5s} {r[1]}  （{r[4]}）")
        return 1
    if invalid:
        print(f"\nFAIL: 这些变异**没有在测试任何东西**（锚点失效 / 编译不过）：")
        for r in invalid:
            print(f"   {r[0]:5s} {r[1]}  （{r[4]}）")
        return 1
    if leftover:
        return 1
    print("\nMUTATION SCAN PASS ✓（所有非等价变异都被测试抓住）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
