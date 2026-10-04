// 色阶 / 曲线（PLAN 七十）：**像素映射**这一半。
//
// 与 core 的参数判据分开钉：那边管"参数收不收得下"，这边管"收下之后每个像素
// 变成什么"。要咬住的是四件事：
//
//   * **色阶的五个参数各自的作用**：输入黑白点（夹到 0..1 的两端）、gamma
//     （1 = 不动）、输出黑白点（重映射到区间）——少一项就会退化成"三个参数
//     白装"；
//   * **曲线是单调三次（PCHIP）**：控制点单调则输出单调、且**不过冲**
//     （普通三次样条会把邻近亮度压出一个坑，那是"调完曲线反而脏了"）；
//   * **两条路径共用一处**：整幅路径与蒙版路径都走 `adjust_pixel`，LUT 只算
//     一次——同一条色阶在两条路上必须给出同一个数；
//   * **查表类算子的 LUT 只对 levels/curves 存在**（其余算子走各自的分支，
//     别让 LUT 悄悄参与）。

///|
fn lv(a : Double, b : Double, g : Double, c : Double, d : Double) -> @core.Levels {
  { in_lo: a, in_hi: b, gamma: g, out_lo: c, out_hi: d }
}

///|
fn lv_adj(l : @core.Levels) -> @core.Adjust {
  { ..@core.make_adjust(@core.AdjustOp::Levels, 0.0), levels: Some(l) }
}

///|
fn cv_adj(pts : Array[(Double, Double)]) -> @core.Adjust {
  { ..@core.make_adjust(@core.AdjustOp::Curves, 0.0), curve: pts }
}

///|
test "色阶 LUT：gamma=1 且黑白点给满 = 恒等（老画面一个像素都不许动）" {
  let lut = levels_lut(lv(0.0, 1.0, 1.0, 0.0, 1.0))
  assert_eq(lut.length(), 256, msg="LUT 条数")
  let mut i = 0
  while i < 256 {
    assert_eq(lut[i], i, msg="恒等色阶在 \{i} 处不是恒等")
    i = i + 1
  }
}

///|
test "色阶 LUT：输入黑白点把区间外的值夹住、把区间拉满" {
  // in_lo=0.25, in_hi=0.75, gamma=1, out 0..1 ⇒ v'=clamp01((v-0.25)/0.5)
  // ⚠️ 下面这些是**实测值**（整条链只有乘除，跨 target 逐位一致）：`64/255` 只比
  // 0.25 多 9.8e-4，×255 之后是 0.49999999999996 ⇒ 舍入到 **0**（不是 1）——
  // 写"应该是 1"就是在替浮点数做主，而判据要的是那个真会发生的行为。
  let lut = levels_lut(lv(0.25, 0.75, 1.0, 0.0, 1.0))
  assert_eq(lut.length(), 256, msg="LUT 条数")
  assert_eq(lut[0], 0, msg="0 在区间外 ⇒ 压到黑")
  assert_eq(lut[63], 0, msg="63/255=0.247 < 0.25 ⇒ 黑（边界左侧）")
  assert_eq(lut[64], 0, msg="64/255=0.2510 ⇒ 0.49999999999996/255 档 ⇒ 0（实测）")
  assert_eq(lut[65], 2, msg="65/255 ⇒ 2（实测）")
  assert_eq(lut[128], 129, msg="中点 ⇒ 129（实测：0.503921×255=128.5 向上）")
  assert_eq(lut[191], 255, msg="191/255=0.749 ⇒ 254.5 向上 ⇒ 255（实测）")
  assert_eq(lut[255], 255, msg="255 在区间外 ⇒ 顶到白")
  // **单调不减**是"色阶"的定义（这条被违反就是"把亮度调出了反转"）
  let mut i = 1
  while i < 256 {
    assert_true(lut[i] >= lut[i - 1], msg="色阶必须单调不减（\{i} 处反了）")
    i = i + 1
  }
}

///|
test "色阶：区间外的值必须**钳住**，不是外推（外推把黑场推成负数/NaN）" {
  // ⚠️ 这条件曾经**没人守**：钳制那句写不写，只测"gamma=1 且输出黑白点给满"
  // 的用例是看不出来的——那种参数下外推出来的值恰好也被 clamp8 夹回同一档
  // （实测变异 R97 存活）。要让外推露出马脚，得同时满足：输入黑白点非默认
  // **且** 输出黑白点非默认（外推量按 out_hi-out_lo 放大），或者 gamma≠1
  // （外推区里 `pow(负数, 分数次幂)` = NaN，NaN 会一路漏进 LUT）。
  let a = levels_lut(lv(0.25, 0.75, 1.0, 0.2, 0.8))
  // 钳住 ⇒ 0 落在输出黑点 0.2 ⇒ 51；外推 ⇒ 0.2 + (-0.5)*0.6 = -0.1 ⇒ 0
  assert_eq(a[0], 51, msg="区间下界外必须给输出黑点 0.2 ⇒ 51（外推会给 -0.1）")
  // 钳住 ⇒ 255 落在输出白点 0.8 ⇒ 204；外推 ⇒ 0.2 + 1.5*0.6 = 1.1 ⇒ 255
  assert_eq(a[255], 204, msg="区间上界外必须给输出白点 0.8 ⇒ 204（外推会给 1.1）")
  let b = levels_lut(lv(0.25, 0.75, 2.0, 0.2, 0.8))
  assert_eq(b[0], 51, msg="gamma≠1 时区间外仍是输出黑点（外推在这里是 pow(-0.5,0.5)=NaN）")
  assert_eq(b[255], 204, msg="gamma≠1 时的上界外同理")
  assert_eq(b[64], 58, msg="区间内的值走真正的 gamma 映射（实测 58）")
  // 单调不减在"输入非默认 + 输出非默认"下也要成立（钳制写错会在这条上露头）
  let mut i = 1
  while i < 256 {
    assert_true(a[i] >= a[i - 1], msg="钳制后仍须单调不减（\{i} 处反了）")
    assert_true(b[i] >= b[i - 1], msg="gamma=2 且钳制后仍须单调不减（\{i} 处反了）")
    i = i + 1
  }
}

///|
test "色阶 LUT：gamma>1 提亮中间调、<1 压暗中间调（方向不许反）" {
  let bright = levels_lut(lv(0.0, 1.0, 2.0, 0.0, 1.0))
  let dark = levels_lut(lv(0.0, 1.0, 0.5, 0.0, 1.0))
  // 实测：gamma=2 时 128 → 181、64 → 128、192 → 221；gamma=0.5 时 128 → 64……
  assert_eq(bright[128], 181, msg="gamma=2 的中间调（实测）")
  assert_eq(bright[64], 128, msg="gamma=2 的暗部（实测）")
  assert_eq(bright[192], 221, msg="gamma=2 的亮部（实测）")
  assert_eq(dark[128], 64, msg="gamma=0.5 的中间调（实测）")
  assert_eq(dark[64], 16, msg="gamma=0.5 的暗部（实测）")
  assert_eq(dark[192], 145, msg="gamma=0.5 的亮部（实测）")
  // 方向：gamma>1 在 (0,255) 上**处处不低于**原值，<1 处处不高于原值
  let mut i = 1
  while i < 255 {
    assert_true(bright[i] >= i, msg="gamma>1 在 \{i} 处压暗了（方向反了）")
    assert_true(dark[i] <= i, msg="gamma<1 在 \{i} 处提亮了（方向反了）")
    i = i + 1
  }
  assert_eq(bright[0], 0, msg="黑场不动（0 的任意次幂还是 0）")
  assert_eq(bright[255], 255, msg="白场不动")
  assert_eq(dark[255], 255, msg="白场不动")
}

///|
test "色阶 LUT：输出黑白点把整条曲线重映射到子区间" {
  // out_lo=0.2, out_hi=0.8 ⇒ 0 → 51，255 → 204，中点 → 127.5 附近
  let lut = levels_lut(lv(0.0, 1.0, 1.0, 0.2, 0.8))
  assert_eq(lut[0], 51, msg="输出黑点 0.2*255=51")
  assert_eq(lut[255], 204, msg="输出白点 0.8*255=204")
  assert_eq(lut[128], 128, msg="中点仍在中点（线性重映射）")
  // 输出黑点 = 输出白点 = 纯色（合法：out_lo <= out_hi 允许相等）
  let flat = levels_lut(lv(0.0, 1.0, 1.0, 0.5, 0.5))
  assert_eq(flat[0], 128, msg="输出区间退化成一个点")
  assert_eq(flat[255], 128, msg="输出区间退化成一个点（暗部）")
}

///|
test "曲线：端点精确、区间外钳住、单调控制点 ⇒ 单调且不过冲" {
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.25, 0.5), (0.75, 0.6), (1.0, 1.0)]
  assert_eq(curve_map(pts, 0.0), 0.0, msg="左端点")
  assert_eq(curve_map(pts, 1.0), 1.0, msg="右端点")
  assert_eq(curve_map(pts, 0.25), 0.5, msg="控制点必须被穿过（插值，不是拟合）")
  assert_eq(curve_map(pts, 0.75), 0.6, msg="控制点必须被穿过")
  assert_eq(curve_map(pts, -0.5), 0.0, msg="区间外钳到端点值")
  assert_eq(curve_map(pts, 1.5), 1.0, msg="区间外钳到端点值")
  // 单调 + 不过冲：256 个采样点都落在 [minY, maxY] 里且不下降
  let mut prev = curve_map(pts, 0.0)
  let mut i = 1
  while i < 256 {
    let y = curve_map(pts, i.to_double() / 255.0)
    assert_true(y >= prev - 1.0e-12, msg="单调控制点必须给出单调输出（\{i} 处下掉了）")
    assert_true(y >= 0.0 && y <= 1.0, msg="输出越界（\{i} 处 y=\{y}）")
    prev = y
    i = i + 1
  }
  // **逐段不过冲**：每一段里的输出都夹在该段两个控制点的 y 之间——这正是 PCHIP
  // 与普通三次样条的区别（后者会在段内冲出去）。逐段判、不判全局：全局最大值
  // 就是端点值 1.0，"不许超过 1.0"是句废话。
  let mut seg = 0
  while seg + 1 < pts.length() {
    let x0 = pts[seg].0
    let x1 = pts[seg + 1].0
    let y0 = pts[seg].1
    let y1 = pts[seg + 1].1
    let ymin = if y0 < y1 { y0 } else { y1 }
    let ymax = if y0 > y1 { y0 } else { y1 }
    let mut k = 0
    while k <= 40 {
      let x = x0 + (x1 - x0) * k.to_double() / 40.0
      let y = curve_map(pts, x)
      assert_true(
        y >= ymin - 1.0e-12 && y <= ymax + 1.0e-12,
        msg="第 \{seg} 段在 x=\{x} 处冲到 [\{ymin},\{ymax}] 之外（y=\{y}）",
      )
      k = k + 1
    }
    seg = seg + 1
  }
}

///|
test "曲线：段内的**具体数值**要钉住（否则「换个插值公式」没人抓得住）" {
  // 只断言"单调 + 不过冲 + 穿过控制点"的话，把 PCHIP 换成"内部斜率一律取 0"
  // 也照样全绿（那种曲线依然单调、依然穿过控制点、依然不越界）——而它的中段
  // 形状完全不同。所以这里钉**实测值**（整条链只有乘除，跨 target 逐位一致）。
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.4, 0.2), (0.6, 0.9), (1.0, 1.0)]
  let want : Array[(Double, Double)] = [
    (0.45, 0.3313804023845007),
    (0.5, 0.5609538002980626),
    (0.55, 0.7850502980625935),
    (0.7, 0.939984631147541),
    (0.8, 0.9633196721311477),
  ]
  for c in want {
    let got = curve_map(pts, c.0)
    let d = if got > c.1 { got - c.1 } else { c.1 - got }
    assert_true(d < 1.0e-12, msg="curve_map(\{c.0}) = \{got}，实测应为 \{c.1}")
  }
}

///|
test "曲线：水平的控制点段必须**逐位**平（PCHIP 的斜率在此取 0）" {
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.25, 0.5), (0.5, 0.5), (1.0, 1.0)]
  assert_eq(curve_map(pts, 0.375), 0.5, msg="平台段中点的 y 必须正好 0.5")
  assert_eq(curve_map(pts, 0.25), 0.5, msg="平台段左端")
  assert_eq(curve_map(pts, 0.5), 0.5, msg="平台段右端")
  // 平台段里**一个采样点都不许**离开 0.5（"逐位平"是这条的全部意思）
  let mut k = 0
  while k <= 20 {
    let x = 0.25 + 0.25 * k.to_double() / 20.0
    assert_eq(curve_map(pts, x), 0.5, msg="平台段 x=\{x} 处不平")
    k = k + 1
  }
}

///|
test "曲线：控制点陡升时**不许**在邻近亮度上压出坑（那是普通三次样条的病）" {
  // 只在 0.5 处抬到 0.9：单调插值在 0.4 附近不许低于 0.4（否则就是"调高中间调
  // 反而把暗部压得更暗"）。普通三次样条在这里会给出 < 0.4 的下冲。
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.5, 0.9), (1.0, 1.0)]
  let y40 = curve_map(pts, 0.4)
  assert_true(y40 >= 0.4, msg="0.4 处被压到 \{y40}（下冲）")
  assert_true(y40 <= 0.9, msg="0.4 处冲到 \{y40}（上冲）")
  let y60 = curve_map(pts, 0.6)
  assert_true(y60 >= 0.9, msg="0.6 处应继续上升（实测 \{y60}）")
}

///|
test "曲线 LUT 与采样：同一张表的两种出口必须一致" {
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.5, 0.6), (1.0, 1.0)]
  let lut = curve_lut(pts)
  assert_eq(lut.length(), 256, msg="LUT 条数")
  let mut i = 0
  while i < 256 {
    let want = (curve_map(pts, i.to_double() / 255.0) * 255.0 + 0.5).to_int()
    assert_eq(lut[i], clamp8(want), msg="LUT 与 curve_map 在 \{i} 处不一致")
    i = i + 1
  }
  // 采样给面板画预览：9 个点、x 均匀、y 由引擎算（前端不许自己插值）
  let sample = curve_sample(pts, 9)
  assert_eq(sample.length(), 9, msg="采样条数")
  assert_eq(sample[0], (0.0, 0.0), msg="采样左端")
  assert_eq(sample[8].0, 1.0, msg="采样右端")
  assert_eq(sample[4].1, 0.6, msg="采样必须穿过控制点")
}

///|
test "adjust_map：只有 levels/curves 有 LUT，其余算子必须是 None" {
  match adjust_map(lv_adj(lv(0.2, 0.8, 1.0, 0.0, 1.0))) {
    Some(t) => assert_eq(t.length(), 256, msg="色阶 LUT 条数")
    None => abort("色阶应当有 LUT")
  }
  match adjust_map(cv_adj([(0.0, 0.0), (1.0, 1.0)])) {
    Some(t) => assert_eq(t.length(), 256, msg="曲线 LUT 条数")
    None => abort("曲线应当有 LUT")
  }
  // 负控：其余算子不许有 LUT（有的话 LUT 分支会先返回，等于把算子换掉了）
  for op in [
    @core.AdjustOp::Brightness,
    @core.AdjustOp::Contrast,
    @core.AdjustOp::Saturation,
    @core.AdjustOp::Invert,
    @core.AdjustOp::Grayscale,
    @core.AdjustOp::Blur,
    @core.AdjustOp::Sharpen,
    @core.AdjustOp::Smooth,
    @core.AdjustOp::Whiten,
    @core.AdjustOp::Warm,
    @core.AdjustOp::Vignette,
  ] {
    assert_true(
      adjust_map(@core.make_adjust(op, 0.5)) is None,
      msg="\{@core.adjust_op_name(op)} 不该有 LUT",
    )
  }
  // 参数缺失（手改容器能造出来）时也不许有 LUT：那时候渲染器只能原样返回，
  // 而不是拿一张空表把画面刷成 0
  assert_true(
    adjust_map(@core.make_adjust(@core.AdjustOp::Levels, 0.0)) is None,
    msg="没有参数的 levels 不许有 LUT",
  )
  assert_true(
    adjust_map(@core.make_adjust(@core.AdjustOp::Curves, 0.0)) is None,
    msg="没有点表的 curves 不许有 LUT",
  )
}

///|
test "画面：色阶层真的改像素，且数值等于 LUT（整幅路径）" {
  let base = 0xFF404040
  let doc = @core.new_document("lv", 16, 16)
  doc.layers.push({
    ..@core.default_layer("base", "base", 0.0, 0.0, 16.0, 16.0),
    fill: @core.Fill::Solid(base),
  })
  let l = lv(0.25, 0.75, 1.0, 0.0, 1.0)
  doc.layers.push({
    ..@core.default_layer("a1", "a1", 0.0, 0.0, 16.0, 16.0),
    kind: @core.ShapeKind::Adjust,
    adjust: Some(lv_adj(l)),
  })
  let buf = render_doc(doc, RenderEnv::new())
  let lut = levels_lut(l)
  let want = (0xFF << 24) + (lut[64] << 16) + (lut[64] << 8) + lut[64]
  let mut i = 0
  while i < 256 {
    assert_eq(buf.pixels[i], want, msg="第 \{i} 像素与 LUT 不符")
    i = i + 1
  }
  // 人脸⾯**必须真的变了**（否则上面那条断言在"色阶没生效"时也成立）
  assert_true(want != base, msg="这组参数应当改变画面（否则这条测试什么都没验）")
}

///|
test "画面：蒙版路径与整幅路径共用同一个映射（色阶/曲线各一格）" {
  let base = 0xFF808080
  for adj in [
    lv_adj(lv(0.3, 0.7, 1.5, 0.1, 0.9)),
    cv_adj([(0.0, 0.0), (0.4, 0.25), (1.0, 1.0)]),
  ] {
    // 直接跑整幅算子得到"应然"
    let want = @codec.rgba_new(16, 16)
    let mut k = 0
    while k < 256 {
      want.pixels[k] = base
      k = k + 1
    }
    apply_adjust(Some(adj), want)
    // 经**蒙版**路径（覆盖度 1 ⇒ 直通；这里用硬边矩形盖满整幅）
    let doc = @core.new_document("mv", 16, 16)
    doc.layers.push({
      ..@core.default_layer("base", "base", 0.0, 0.0, 16.0, 16.0),
      fill: @core.Fill::Solid(base),
    })
    doc.layers.push({
      ..@core.default_layer("a1", "a1", 0.0, 0.0, 16.0, 16.0),
      kind: @core.ShapeKind::Adjust,
      adjust: Some(adj),
      mask: Some(@core.LayerMask::{
        kind: @core.ShapeKind::Rect,
        x: -2.0,
        y: -2.0,
        w: 20.0,
        h: 20.0,
        radius: 0.0,
        feather: 0.0,
        roughen: 0.0,
        invert: false,
        points: [],
      }),
    })
    let got = render_doc(doc, RenderEnv::new())
    let mut i = 0
    while i < 256 {
      assert_eq(
        got.pixels[i],
        want.pixels[i],
        msg="蒙版路径与整幅路径在 \{@core.adjust_op_name(adj.op)} 上分叉（第 \{i} 像素）",
      )
      i = i + 1
    }
    // 与"原图"必须不同：否则"两条路一致"在两者都没生效时也成立
    assert_true(want.pixels[0] != base, msg="这组参数应当改变画面")
  }
}
