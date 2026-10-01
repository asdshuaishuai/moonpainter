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
    python3 mutation_scan.py                  # 全跑（约 5 分钟）
    python3 mutation_scan.py M1 M7            # 只跑指定项
    python3 mutation_scan.py --check-anchors  # 只校验锚点（秒级）
退出码：有「应当被抓住却存活」的变异 → 1；有锚点失效 → 1。
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
        "R7",
        "填充/描边色自带的 alpha 又被丢掉（半透明渲染成不透明）",
        "render/scene.mbt",
        '        let ca = (color >> 24) & 0xFF\n        let cover = if ca >= 255 { cover } else { (cover * ca + 127) / 255 }',
        '        let cover = cover',
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
        "program_for_layer 不按图层过滤（图层级算子漏到所有层上）",
        "core/mvsl.mbt",
        '    if op.layer == layer_id {\n      ops.push(op)',
        '    if op.layer != "" {\n      ops.push(op)',
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
      kinds: ["text"],""",
        r"""      field: "text",
      reader: "text 层",
      kinds: ["rect"],""",
        "killed",
    ),
    (
        "R26",
        "非矩形层也接受 radius（死数据改变指纹、画面没变）",
        "agent/ops.mbt",
        """        if !(nl.kind is @core.ShapeKind::Rect) {
          return Err(
            "radius 只对矩形（rect）有意义：这层是 \\{kind_str(nl.kind)}，渲染器不读它的圆角（椭圆本身就是圆的；要给图形加圆角请用 add-rect）",
          )
        }
""",
        "",
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
        "build_shape_layer 不查 kind 就收 points（rect 上的死顶点）",
        "agent/ops.mbt",
        r"""      if !(kind is @core.ShapeKind::Polygon) && !(kind is @core.ShapeKind::Line) {
        return Err(
          "points 只对 polygon/line 有意义：这层是 \{kind_str(kind)}，渲染器不读它的顶点（矩形/椭圆用 w/h/radius 定义形状；要折线请用 add-polygon）",
        )
      }""",
        r"""      let _ = kind""",
        "killed",
    ),
    (
        "R38",
        "lint 不报非 polygon/line 上的死顶点（表格把 points 的合法 kind 放宽到 rect）",
        "agent/ops.mbt",
        r"""      field: "points",
      reader: "polygon/line",
      kinds: ["polygon", "line"],""",
        r"""      field: "points",
      reader: "polygon/line",
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
        r"""  match check_kv_args(
    tokens,
    2,
    ["kind", "x", "y", "w", "h", "radius", "feather", "invert"],
    "add-mask",
  ) {
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
        r"""      if v <= 0 {
        return err("max=\{v} 必须为正（预览最长边像素）")
      }
      max_side = v
    }
  }
  let base = match mvsl_base(s) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let (out, stages) = match @pixel.run_program(base, s.mvsl) {""",
        r"""      if v > 0 {
        max_side = v
      }
    }
  }
  let base = match mvsl_base(s) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let (out, stages) = match @pixel.run_program(base, s.mvsl) {""",
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
      kinds: ["text"],""",
        r"""    {
      field: "font_size",
      reader: "unknown",
      kinds: ["font_size-never"],""",
        "killed",
    ),
    (
        "R51",
        "lint 的 kind 专属字段表漏掉 adjust 一格",
        "agent/ops.mbt",
        r"""      field: "adjust",
      reader: "adjust 层",
      kinds: ["adjust"],""",
        r"""      field: "adjust",
      reader: "unknown",
      kinds: ["adjust-never"],""",
        "killed",
    ),
    (
        "R52",
        "lint 的 kind 专属字段表漏掉 dabs / children / asset_hash",
        "agent/ops.mbt",
        r"""      field: "asset_hash",
      reader: "image 层",
      kinds: ["image"],
      dead: fn(l) { if l.asset_hash != "" { "asset 引用" } else { "" } },
    },
    {
      field: "dabs",
      reader: "raster 层",
      kinds: ["raster"],
      dead: fn(l) {
        if l.dabs.length() > 0 { "\{l.dabs.length()} 个笔触" } else { "" }
      },
    },
    {
      field: "children",
      reader: "group",
      kinds: ["group"],
      dead: fn(l) {
        if l.children.length() > 0 { "\{l.children.length()} 个子层" } else { "" }
      },
    },""",
        r"""      field: "asset_hash",
      reader: "image 层",
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
        """              kind: Rect,
              x: num_f(mv, "x"),
              y: num_f(mv, "y"),
              w: num_f(mv, "w"),
              h: num_f(mv, "h"),
              radius: num_f(mv, "radius"),
              feather: num_f(mv, "feather"),
              invert: bool_field(mv, "invert"),""",
        """              kind: Rect,
              x: num_f(mv, "x"),
              y: num_f(mv, "y"),
              w: num_f(mv, "w"),
              h: num_f(mv, "h"),
              radius: num_f(mv, "radius"),
              feather: 0.0,
              invert: bool_field(mv, "invert"),""",
        "killed",
    ),
    (
        "R19",
        "蒙版圆角解析恒 0（圆角蒙版重开后变直角）",
        "core/json.mbt",
        """              kind: Rect,
              x: num_f(mv, "x"),
              y: num_f(mv, "y"),
              w: num_f(mv, "w"),
              h: num_f(mv, "h"),
              radius: num_f(mv, "radius"),
              feather: num_f(mv, "feather"),
              invert: bool_field(mv, "invert"),""",
        """              kind: Rect,
              x: num_f(mv, "x"),
              y: num_f(mv, "y"),
              w: num_f(mv, "w"),
              h: num_f(mv, "h"),
              radius: 0.0,
              feather: num_f(mv, "feather"),
              invert: bool_field(mv, "invert"),""",
        "killed",
    ),
    (
        "R20",
        "蒙版反选解析恒 false（反选蒙版重开后反回来）",
        "core/json.mbt",
        """              kind: Rect,
              x: num_f(mv, "x"),
              y: num_f(mv, "y"),
              w: num_f(mv, "w"),
              h: num_f(mv, "h"),
              radius: num_f(mv, "radius"),
              feather: num_f(mv, "feather"),
              invert: bool_field(mv, "invert"),""",
        """              kind: Rect,
              x: num_f(mv, "x"),
              y: num_f(mv, "y"),
              w: num_f(mv, "w"),
              h: num_f(mv, "h"),
              radius: num_f(mv, "radius"),
              feather: num_f(mv, "feather"),
              invert: false,""",
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
    print("\nMUTATION SCAN PASS ✓（所有非等价变异都被测试抓住）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
