/// 调整层（`add-adjust`）的**蒙版**。
///
/// 实测过的静默失败：给调整层装蒙版，`add-mask` 回 ok、`lint` 一个字不说、
/// 而渲染 **逐位不变**——`paint_layer` 里那条分派直接调
/// `apply_adjust(l.adjust, buf)`，从来不看 `l.mask`。也就是说"局部提亮/局部
/// 模糊"是装得上、改不动、也报不出来的状态（铁律 6 那一类）。
///
/// 现在的语义：`p' = lerp(p, op(p), cover)`——复用编辑表那句唯一的软混合原语
/// `@pixel.lerp_argb`（软权重只有一处实现）。这里要钉五件事：
///
///   * **没有蒙版逐位不变**：既有文档/golden 一个像素都不许动；
///   * **蒙版盖满整幅 == 没有蒙版**（覆盖度恰好 1 时走 `op` 直通）；
///   * **硬边蒙版的边界**：蒙版内 `op(p)`、蒙版外**原样**；
///   * **羽化带是软的**：中间覆盖度必须等于 `lerp_argb(p, op(p), cover)`，
///     忽略覆盖度（硬边化）就红；
///   * **窗口不能比支撑区小**：`invert`（区域无界）与 `roughen`（覆盖度能甩到
///     形状外 `roughen` 个像素）各一条——判窄了不是变慢，是**静默漏一块**。

///|
/// 画布 16×16，整幅填一个固定色，挂一条调整层（x/y/w/h 都是画布）。
fn adj_doc(buf_color : Int) -> @core.Document {
  let doc = @core.new_document("a", 16, 16)
  doc.layers.push({
    ..@core.default_layer("base", "base", 0.0, 0.0, 16.0, 16.0),
    fill: @core.Fill::Solid(buf_color),
  })
  doc
}

///|
fn adjust_layer(op : @core.AdjustOp, value : Double) -> @core.Layer {
  {
    ..@core.default_layer("a1", "a1", 0.0, 0.0, 16.0, 16.0),
    kind: @core.ShapeKind::Adjust,
    adjust: Some(@core.Adjust::{ op: op, value: value }),
  }
}

///|
/// 蒙版（矩形，画布坐标）。
fn adj_mask(
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  feather : Double,
  roughen : Double,
  invert : Bool,
) -> @core.LayerMask {
  @core.LayerMask::{
    kind: @core.ShapeKind::Rect,
    x,
    y,
    w,
    h,
    radius: 0.0,
    feather,
    roughen,
    invert,
  }
}

///|
/// 渲染并取像素。
fn render_px(doc : @core.Document) -> @codec.RgbaBuf {
  render_doc(doc, RenderEnv::new())
}

///|
fn px(buf : @codec.RgbaBuf, x : Int, y : Int) -> Int {
  buf.pixels[y * buf.width + x]
}

///|
test "调整层蒙版：没有蒙版时逐位等于原来的整幅算子（既有文档一个像素都不动）" {
  let base_color = 0xFF3366CC
  let plain = adjust_layer(@core.AdjustOp::Invert, 1.0)
  let doc = adj_doc(base_color)
  doc.layers.push(plain)
  let got = render_px(doc)
  // 对照：手工在同一个底色上跑整幅算子（`apply_adjust` 就是原来那条路径）
  let want = @codec.rgba_new(16, 16)
  let mut i = 0
  while i < 256 {
    want.pixels[i] = base_color
    i = i + 1
  }
  apply_adjust(Some(@core.Adjust::{ op: @core.AdjustOp::Invert, value: 1.0 }), want)
  let mut k = 0
  while k < 256 {
    assert_eq(got.pixels[k], want.pixels[k], msg="无蒙版路径第 \{k} 像素变了")
    k = k + 1
  }
}

///|
test "调整层蒙版：盖满整幅 == 没有蒙版（覆盖度 1 走直通，不进软混合）" {
  let base_color = 0xFF3366CC
  let no_mask = adj_doc(base_color)
  no_mask.layers.push(adjust_layer(@core.AdjustOp::Invert, 1.0))
  let full_mask = adj_doc(base_color)
  full_mask.layers.push({
    ..adjust_layer(@core.AdjustOp::Invert, 1.0),
    mask: Some(adj_mask(-2.0, -2.0, 20.0, 20.0, 0.0, 0.0, false)),
  })
  let a = render_px(no_mask)
  let b = render_px(full_mask)
  let mut i = 0
  while i < 256 {
    assert_eq(b.pixels[i], a.pixels[i], msg="盖满整幅与无蒙版差了第 \{i} 像素")
    i = i + 1
  }
}

///|
test "调整层蒙版：硬边蒙版只改蒙版里那一半，外面原样" {
  let base_color = 0xFF3366CC
  let doc = adj_doc(base_color)
  doc.layers.push({
    ..adjust_layer(@core.AdjustOp::Invert, 1.0),
    mask: Some(adj_mask(0.0, 0.0, 8.0, 16.0, 0.0, 0.0, false)),
  })
  let got = render_px(doc)
  let inv = 0xFFCC9933 // 0xFF3366CC 的逐通道取反：33→CC、66→99、CC→33
  assert_eq(px(got, 0, 0), inv, msg="蒙版内的像素没有被反转")
  assert_eq(px(got, 7, 15), inv, msg="蒙版内的右下角像素没有被反转")
  assert_eq(px(got, 8, 0), base_color, msg="蒙版外的像素被改了（蒙版没生效在窗口上）")
  assert_eq(px(got, 15, 15), base_color, msg="蒙版外的像素被改了")
}

///|
test "调整层蒙版：羽化带按覆盖度软混合（忽略覆盖度就红）" {
  let base_color = 0xFF3366CC
  let op_color = 0xFFCC9933
  let doc = adj_doc(base_color)
  doc.layers.push({
    ..adjust_layer(@core.AdjustOp::Invert, 1.0),
    mask: Some(adj_mask(0.0, 0.0, 16.0, 16.0, 8.0, 0.0, false)),
  })
  let got = render_px(doc)
  // 期望值直接由"蒙版覆盖度 + 唯一的软混合原语"给出（不是另写一份公式）
  let l = doc.layers[1]
  let mut y = 0
  while y < 16 {
    let mut x = 0
    while x < 16 {
      let cover = mask_cover_at(l, x.to_double() + 0.5, y.to_double() + 0.5)
      let want = if cover >= 1.0 {
        op_color
      } else {
        @pixel.lerp_argb(base_color, op_color, cover)
      }
      assert_eq(
        px(got, x, y),
        want,
        msg="(\{x},\{y}) 覆盖度 \{cover} 的软混合不对（硬边化会在这里露出来）",
      )
      x = x + 1
    }
    y = y + 1
  }
  // 关键：羽化带里必须出现**中间色**（覆盖度严格介于 0 与 1 之间），
  // 否则"软混合"可能恰好被两端值满足。
  let mid = px(got, 0, 0)
  assert_true(
    mid != base_color && mid != op_color,
    msg="羽化带上没有中间色：软覆盖没参与混合（got=\{mid}）",
  )
}

///|
test "调整层蒙版：invert 蒙版的区域无界 —— 形状外也必须被算子改到" {
  let base_color = 0xFF3366CC
  let doc = adj_doc(base_color)
  doc.layers.push({
    ..adjust_layer(@core.AdjustOp::Invert, 1.0),
    // invert 的蒙版：形状内**不**改、形状外全改
    mask: Some(adj_mask(0.0, 0.0, 8.0, 16.0, 0.0, 0.0, true)),
  })
  let got = render_px(doc)
  assert_eq(px(got, 0, 0), base_color, msg="invert 蒙版内的像素不该被改")
  assert_eq(
    px(got, 8, 0),
    0xFFCC9933,
    msg="invert 蒙版外的像素必须被改（窗口按形状 bbox 裁就会漏掉这一整片）",
  )
  assert_eq(px(got, 15, 15), 0xFFCC9933, msg="invert 蒙版外（右下）也必须被改")
}

///|
test "调整层蒙版：roughen 能把覆盖度甩到形状外，窗口必须含那几像素" {
  let base_color = 0xFF3366CC
  let doc = adj_doc(base_color)
  let l = {
    ..adjust_layer(@core.AdjustOp::Invert, 1.0),
    mask: Some(adj_mask(4.0, 4.0, 8.0, 8.0, 0.0, 6.0, true)),
  }
  doc.layers.push(l)
  let got = render_px(doc)
  // 形状 bbox 是 [4,12)×[4,12)，毛边 6px ⇒ 支撑区到 [0,16)。逐像素按覆盖度比。
  let mut y = 0
  while y < 16 {
    let mut x = 0
    while x < 16 {
      let cover = mask_cover_at(l, x.to_double() + 0.5, y.to_double() + 0.5)
      let op_color = 0xFFCC9933
      let want = if cover <= 0.0 {
        base_color
      } else if cover >= 1.0 {
        op_color
      } else {
        @pixel.lerp_argb(base_color, op_color, cover)
      }
      assert_eq(px(got, x, y), want, msg="(\{x},\{y}) 毛边覆盖度 \{cover} 处不对")
      x = x + 1
    }
    y = y + 1
  }
  // 形状外、毛边带里的某一格必须真的被改到（否则窗口裁得过窄这条测试是空的）
  let mut touched = 0
  for p in [(0, 4), (4, 0), (14, 4), (4, 14)] {
    let c = mask_cover_at(l, p.0.to_double() + 0.5, p.1.to_double() + 0.5)
    if c > 0.0 {
      touched = touched + 1
      assert_true(
        px(got, p.0, p.1) != base_color,
        msg="形状外毛边带上 (\{p.0},\{p.1}) 覆盖度 \{c} > 0 却没有被改（窗口判窄）",
      )
    }
  }
  assert_true(touched > 0, msg="这条用例的毛边一个像素都没甩出形状，断言是空的")
}

///|
test "调整层蒙版：邻域算子（blur）逐像素 == lerp(原像素, 整幅模糊, 覆盖度)" {
  // 期望值**独立算**：先渲染"没有调整层"的底图，再把同一个算子整幅跑一遍，
  // 然后按覆盖度混合。这条能同时咬住三种错法——
  //   ①就地做邻域算子（把已经改过的像素当邻居）：模糊结果会不一样；
  //   ②忽略覆盖度（硬边化）：羽化带对不上；
  //   ③窗口判窄：蒙版外那圈 / invert 的整片对不上。
  let base_color = 0xFF3366CC
  let doc = @core.new_document("b", 16, 16)
  doc.layers.push({
    ..@core.default_layer("base", "base", 0.0, 0.0, 16.0, 16.0),
    fill: @core.Fill::Solid(base_color),
  })
  // 一条 1px 白竖线：模糊必须**读得到**它（邻居真的参与了），否则这条是空的
  doc.layers.push({
    ..@core.default_layer("line", "line", 9.0, 0.0, 1.0, 16.0),
    fill: @core.Fill::Solid(0xFFFFFFFF),
  })
  let base_img = render_px(doc)
  let blur_only = @codec.rgba_new(16, 16)
  let mut i = 0
  while i < 256 {
    blur_only.pixels[i] = base_img.pixels[i]
    i = i + 1
  }
  apply_adjust(Some(@core.Adjust::{ op: @core.AdjustOp::Blur, value: 1.0 }), blur_only)
  // 白线被模糊"抹开"了 ⇒ 期望值与原图像确有差异（否则这条断言是空的）
  let mut spread = 0
  let mut j = 0
  while j < 256 {
    if blur_only.pixels[j] != base_img.pixels[j] {
      spread = spread + 1
    }
    j = j + 1
  }
  assert_true(spread > 0, msg="整幅模糊没改变任何像素，这条期望值是空的")

  let l = {
    ..adjust_layer(@core.AdjustOp::Blur, 1.0),
    // 硬边蒙版盖住右半（含那条白线右侧），羽化 4px 让边界也走软混合
    mask: Some(adj_mask(8.0, 0.0, 8.0, 16.0, 4.0, 0.0, false)),
  }
  doc.layers.push(l)
  let got = render_px(doc)
  let mut y = 0
  while y < 16 {
    let mut x = 0
    while x < 16 {
      let cover = mask_cover_at(l, x.to_double() + 0.5, y.to_double() + 0.5)
      let at = y * 16 + x
      let want = if cover <= 0.0 {
        base_img.pixels[at]
      } else if cover >= 1.0 {
        blur_only.pixels[at]
      } else {
        @pixel.lerp_argb(base_img.pixels[at], blur_only.pixels[at], cover)
      }
      assert_eq(
        got.pixels[at],
        want,
        msg="(\{x},\{y}) 覆盖度 \{cover}：邻域算子 + 蒙版的结果不对",
      )
      x = x + 1
    }
    y = y + 1
  }
  // 蒙版 bbox **之外**（x < 8，羽化带也够不到那里）整片必须逐位等于底图。
  // ⚠️ 白线在 x=9：它落在羽化带里（覆盖度 ~0.32），所以不是"原样"而是软混合
  // ——用像素级循环已经验过；这里单独钉"bbox 外一个像素都不许动"。
  let mut yy = 0
  while yy < 16 {
    let mut xx = 0
    while xx < 8 {
      assert_eq(
        got.pixels[yy * 16 + xx],
        base_img.pixels[yy * 16 + xx],
        msg="蒙版 bbox 外的 (\{xx},\{yy}) 被改了",
      )
      xx = xx + 1
    }
    yy = yy + 1
  }
}

///|
test "调整层蒙版：非反选的毛边也能把覆盖度甩出形状 bbox —— 窗口必须含那圈" {
  // ⚠️ 上面那条毛边用例用的是 `invert`，而 `invert` 的区域无界 ⇒ 支撑窗退回
  // **整幅**，于是它压根没考到 `slack`（实测量过：把 slack 置 0 那条用例照样绿，
  // 变异门判 SURVIVED）。这条用非反选 + 小形状 + 大毛边，专钉"bbox 外扩"。
  let base_color = 0xFF3366CC
  let op_color = 0xFFCC9933
  let doc = adj_doc(base_color)
  let l = {
    ..adjust_layer(@core.AdjustOp::Invert, 1.0),
    mask: Some(adj_mask(6.0, 6.0, 4.0, 4.0, 3.0, 8.0, false)),
  }
  doc.layers.push(l)
  let got = render_px(doc)
  let mut outside_hits = 0
  let mut y = 0
  while y < 16 {
    let mut x = 0
    while x < 16 {
      let cover = mask_cover_at(l, x.to_double() + 0.5, y.to_double() + 0.5)
      let in_bbox = x >= 6 && x < 10 && y >= 6 && y < 10
      if !in_bbox && cover > 0.0 {
        outside_hits = outside_hits + 1
        let want = if cover >= 1.0 {
          op_color
        } else {
          @pixel.lerp_argb(base_color, op_color, cover)
        }
        assert_eq(
          px(got, x, y),
          want,
          msg="bbox 外 (\{x},\{y}) 覆盖度 \{cover}：毛边外溢那圈被漏掉了（窗口判窄）",
        )
      }
      x = x + 1
    }
    y = y + 1
  }
  assert_true(
    outside_hits > 0,
    msg="这组毛边参数一个像素都没甩出 bbox —— 这条断言是空的（要换参数，不是删断言）",
  )
}
