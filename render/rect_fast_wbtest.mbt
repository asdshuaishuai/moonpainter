/// 实心矩形层的**整块内部快速填充**（`solid_rect_interior` + `paint_solid_rect_interior`）。
///
/// 这是条性能路径：它把"4 个 2×2 子样本全在矩形内"的像素按**常量**源色合成，
/// 跳过逐像素的 4 次 `to_local`/`inside_fill`。12MP 整幅实心矩形层因此从
/// ~0.5 s/层降到 0.09 s/层——顺带说明**它一旦判宽一个像素，画面就静默多/少
/// 一块**，所以这里要钉三件事：
///
///   * **前提缺一不可**（正控 + 六个负控）：旋转/翻转/圆角/蒙版/描边/渐变
///     各自都要退出快速路径，否则"内部"不再是常量块；
///   * **内部是极大集**：框内的每个像素 4 样本全在内（不判宽）；框外**紧邻
///     一圈**至少有一个样本在外（不判窄，判窄只是慢，但"内部"这个名字就骗人）；
///   * **与通用路径逐位一致**：翻转 `flip_h+flip_v` 的同一矩形**不走**快速路径
///     （矩形与其镜像的填充域同一块、Solid 颜色与位置无关，所以两者本来就该
///     逐位相同），把它当"通用路径的对照实现"来比。**对照必须是真对照**：
///     先断言那个变体确实没有快速路径，否则哪天前提写漏了，这条会悄悄变成
///     "自己跟自己比"。

///|
/// 一个用于快速路径的单层文档（画布 64×64，白底）。
fn fast_doc(id : String, l : @core.Layer) -> @core.Document {
  let doc = @core.new_document(id, 64, 64)
  doc.layers.push(l)
  doc
}

///|
/// 独立的"4 样本全在内"判据（不复用 `inside_fill`，否则是拿实现验实现）。
/// 矩形填充域是半开区间 `[0,w)×[0,h)`（见 `in_rounded_rect` 第一句）。
fn four_samples_inside(l : @core.Layer, px : Int, py : Int) -> Bool {
  let mut ok = true
  for s in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
    let lx = px.to_double() + s.0 - l.x
    let ly = py.to_double() + s.1 - l.y
    if !(lx >= 0.0 && lx < l.w && ly >= 0.0 && ly < l.h) {
      ok = false
    }
  }
  ok
}

///|
test "实心矩形快速路径：前提齐了才有内部，六个负控一个都不能少" {
  let base = {
    ..@core.default_layer("r1", "r1", 10.3, 7.7, 20.25, 15.5),
    fill: @core.Fill::Solid(0xFF3366CC),
  }
  // 正控：10.3-0.25+ε ⇒ 11；10.3+20.25-0.75-ε ⇒ 30；7.7-0.25+ε ⇒ 8；7.7+15.5-0.75-ε ⇒ 23
  let box = match solid_rect_interior(base, base.fill, 0, 0, 64, 64) {
    None => fail("实心、不旋转、不翻转、无圆角无蒙版无描边的矩形必须走快速路径")
    Some(b) => b
  }
  let (ix0, iy0, ix1, iy1) = box
  assert_eq((ix0, iy0, ix1, iy1), (11, 8, 30, 23))
  // 不判宽：框内每个像素的 4 个样本全在内
  let mut y = iy0
  while y < iy1 {
    let mut x = ix0
    while x < ix1 {
      assert_true(
        four_samples_inside(base, x, y),
        msg="内部框判宽了：(\{x},\{y}) 有样本落在矩形外",
      )
      x = x + 1
    }
    y = y + 1
  }
  // 不判窄：框外紧邻一圈至少有一个样本在外（"极大集"，否则"内部"名不副实）
  for probe in [(ix0 - 1, iy0), (ix1, iy0), (ix0, iy0 - 1), (ix0, iy1)] {
    assert_true(
      !four_samples_inside(base, probe.0, probe.1),
      msg="内部框判窄了：框外紧邻的 (\{probe.0},\{probe.1}) 其实 4 样本全在内",
    )
  }

  // 六个负控：每条前提各自单独破坏一次，都必须退出快速路径
  let cases : Array[(String, @core.Layer)] = [
    ("旋转", { ..base, rotation_deg: 15.0 }),
    ("flip_h", { ..base, flip_h: true }),
    ("flip_v", { ..base, flip_v: true }),
    ("圆角", { ..base, corner_radius: 3.0 }),
    ("蒙版取反（覆盖恒 1 的区域在形状外，无界）", { ..base, mask: Some(rect_mask(0.0, 0.0, 64.0, 64.0, 0.0, 0.0, true)) }),
    ("蒙版太小/羽化太大（根本没有覆盖恒 1 的像素）", { ..base, mask: Some(rect_mask(20.0, 20.0, 1.0, 1.0, 4.0, 0.0, false)) }),
    ("描边", { ..base, stroke: { ..base.stroke, width: 2.0 } }),
    (
      "渐变",
      {
        ..base,
        fill: @core.Fill::LinearGradient(0xFF000000, 0xFFFFFFFF, 0.0, 0.0, 1.0, 1.0),
      },
    ),
  ]
  for c in cases {
    assert_true(
      solid_rect_interior(c.1, c.1.fill, 0, 0, 64, 64) is None,
      msg="「\{c.0}」这一条前提没退出快速路径（它的内部不是常量块）",
    )
  }

  // 边界情形：完全在窗外 ⇒ 没有内部（不是"空框"而是 None）
  assert_true(
    solid_rect_interior(base, base.fill, 0, 0, 64, 5) is None,
    msg="整块都在窗外时不该给出内部框",
  )
}

///|
test "实心矩形快速路径：与通用路径逐位一致（翻转镜像当对照，且对照必须真的没走快速路径）" {
  let env = RenderEnv::new()
  let mut dx = 0.0
  while dx < 1.0 {
    let mut dw = 0.0
    while dw < 1.0 {
      let rect = {
        ..@core.default_layer("r1", "r1", 10.3 + dx, 7.7 + dw, 20.25 + dw, 15.5 + dx),
        fill: @core.Fill::Solid(0x803366CC),
        opacity: 0.5,
      }
      // 对照：同一矩形 + 双向翻转。填充域与其镜像同一块、Solid 颜色与位置无关，
      // 所以"该画成什么样"完全相同；而翻转这条前提让它**退出**快速路径。
      let mirrored = { ..rect, flip_h: true, flip_v: true }
      assert_true(
        solid_rect_interior(rect, rect.fill, 0, 0, 64, 64) is Some(_),
        msg="被测的那个矩形没走快速路径（这条对照就白比了）",
      )
      assert_true(
        solid_rect_interior(mirrored, mirrored.fill, 0, 0, 64, 64) is None,
        msg="对照没有退出快速路径 —— 比的是「自己跟自己」，验不出任何东西",
      )
      let a = render_layers(fast_doc("a", rect), env)
      let b = render_layers(fast_doc("b", mirrored), env)
      // 判别力自证：两张图必须**都真的画了东西**（否则"逐位相同"是空话）
      let mut solid_px = 0
      let mut i = 0
      while i < 64 * 64 {
        if ((a.pixels[i] >> 24) & 0xFF) == 0xFF {
          solid_px = solid_px + 1
        }
        i = i + 1
      }
      assert_true(solid_px > 0, msg="快速路径一个像素都没落（dx=\{dx} dw=\{dw}）")
      let mut diff = 0
      let mut j = 0
      while j < 64 * 64 {
        if a.pixels[j] != b.pixels[j] {
          diff = diff + 1
        }
        j = j + 1
      }
      assert_true(
        diff == 0,
        msg="dx=\{dx} dw=\{dw}：快速路径与通用路径差了 \{diff} 个像素",
      )
      dw = dw + 0.5
    }
    dx = dx + 0.5
  }
}

///|
/// 蒙版构造助手（矩形；`feather`/`roughen`/`invert` 都显式给）。
fn rect_mask(
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
test "实心矩形快速路径：蒙版「覆盖恒为 1」的盒——每个像素都真的 cover==1，且不小得离谱" {
  let base = {
    ..@core.default_layer("r1", "r1", 10.3, 7.7, 20.25, 15.5),
    fill: @core.Fill::Solid(0xFF3366CC),
  }
  // 覆盖整幅画布、无羽化 ⇒ 蒙版不额外约束（盒 = 矩形自己的内部）
  let full = { ..base, mask: Some(rect_mask(0.0, 0.0, 64.0, 64.0, 0.0, 0.0, false)) }
  assert_eq(
    solid_rect_interior(full, full.fill, 0, 0, 64, 64),
    Some((11, 8, 30, 23)),
  )
  // 蒙版右边界切进层内（w=25、feather=4 ⇒ 覆盖恒 1 只到 x=20）⇒ 盒被切到 21
  let cut = { ..base, mask: Some(rect_mask(0.0, 0.0, 25.0, 64.0, 4.0, 0.0, false)) }
  assert_eq(solid_rect_interior(cut, cut.fill, 0, 0, 64, 64), Some((11, 8, 21, 23)))
  // 毛边也要算进阈值：roughen=3 时盒再内缩 3 像素（否则噪声会把 cover 压到 1 以下）
  let rough = { ..base, mask: Some(rect_mask(0.0, 0.0, 25.0, 64.0, 4.0, 3.0, false)) }
  assert_eq(
    solid_rect_interior(rough, rough.fill, 0, 0, 64, 64),
    Some((11, 8, 18, 23)),
  )

  // **决定性判据**：返回的盒里**每个**像素的蒙版覆盖必须真的是 1.0
  // （这里直接调 `mask_cover_at`——它就是快速路径假设的那句话）。
  let cases : Array[@core.Layer] = [
    full,
    cut,
    rough,
    // 椭圆蒙版：内接正方形 + ε 余量，同样是"只会小"的保守盒
    {
      ..base,
      mask: Some({
        ..rect_mask(0.0, 0.0, 64.0, 64.0, 6.0, 0.0, false),
        kind: @core.ShapeKind::Ellipse,
      }),
    },
    // 圆角矩形蒙版
    {
      ..base,
      mask: Some({ ..rect_mask(0.0, 0.0, 64.0, 64.0, 2.0, 1.0, false), radius: 9.0 }),
    },
    // 小椭圆蒙版：盒由**椭圆**决定（不是被层的内部裁掉），于是"覆盖恒 1"这条
    // 断言就真的沿着椭圆边缘在跑 —— 椭圆那一支的 √2 内接盒子才被钉住
    {
      ..base,
      mask: Some({
        ..rect_mask(8.0, 6.0, 24.0, 20.0, 0.0, 0.0, false),
        kind: @core.ShapeKind::Ellipse,
      }),
    },
  ]
  for l in cases {
    match solid_rect_interior(l, l.fill, 0, 0, 64, 64) {
      None => ()
      Some((ix0, iy0, ix1, iy1)) => {
        let mut y = iy0
        while y < iy1 {
          let mut x = ix0
          while x < ix1 {
            let c = mask_cover_at(l, x.to_double(), y.to_double())
            assert_eq(
              c,
              1.0,
              msg="盒里 (\{x},\{y}) 的蒙版覆盖是 \{c}，不是 1 —— 快速路径会静默加亮",
            )
            x = x + 1
          }
          y = y + 1
        }
        // 不判窄得离谱：盒的面积至少要装得下（真区域的一大块），
        // 否则"快速路径"名存实亡（保守到空盒也能过上面那条）
        let area = (ix1 - ix0) * (iy1 - iy0)
        let layer_area = 20 * 15
        assert_true(
          area >= layer_area / 4,
          msg="蒙版覆盖恒 1 的盒只有 \{area} 像素（层内部约 \{layer_area}）——保守过头了",
        )
      }
    }
  }
}

///|
test "实心矩形快速路径 + 蒙版：与通用路径逐位一致（翻转镜像当对照）" {
  let env = RenderEnv::new()
  let mut dx = 0.0
  while dx < 1.0 {
    let rect = {
      ..@core.default_layer("r1", "r1", 10.3 + dx, 7.7, 20.25, 15.5),
      fill: @core.Fill::Solid(0x803366CC),
      opacity: 0.5,
    }
    // 大软蒙版（覆盖恒 1 的区域盖住层内部 ⇒ 走快速路径）+ 一个**切进层里**的
    // 蒙版（一部分走快速路径、一部分走通用路径，两段必须在同一张图上接得严丝合缝）
    for m in [
      rect_mask(0.0, 0.0, 64.0, 64.0, 7.0, 0.0, false),
      rect_mask(0.0, 0.0, 22.0, 64.0, 5.0, 2.0, false),
    ] {
      let masked = { ..rect, mask: Some(m) }
      let mirrored = { ..masked, flip_h: true, flip_v: true }
      assert_true(
        solid_rect_interior(masked, masked.fill, 0, 0, 64, 64) is Some(_),
        msg="这个蒙版该能走快速路径（否则这条对拍白比）",
      )
      assert_true(
        solid_rect_interior(mirrored, mirrored.fill, 0, 0, 64, 64) is None,
        msg="对照没有退出快速路径 —— 比的是自己跟自己",
      )
      let a = render_layers(fast_doc("a", masked), env)
      let b = render_layers(fast_doc("b", mirrored), env)
      let mut diff = 0
      let mut j = 0
      while j < 64 * 64 {
        if a.pixels[j] != b.pixels[j] {
          diff = diff + 1
        }
        j = j + 1
      }
      assert_true(
        diff == 0,
        msg="dx=\{dx} 蒙版 w=\{m.w} feather=\{m.feather} roughen=\{m.roughen}：快速路径与通用路径差了 \{diff} 个像素",
      )
    }
    dx = dx + 0.5
  }
}
