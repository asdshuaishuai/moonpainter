/// 实心矩形层的**整块内部快速填充**（`solid_rect_interior` + `paint_solid_rect_interior`）。
///
/// 这是条性能路径：它把"4 个 2×2 子样本全在矩形内"的像素按**常量**源色合成，
/// 跳过逐像素的 4 次 `to_local`/`inside_fill`。12MP 整幅实心矩形层因此从
/// ~0.5 s/层降到 0.09 s/层——顺带说明**它一旦判宽一个像素，画面就静默多/少
/// 一块**，所以这里要钉三件事：
///
///   * **前提缺一不可**（正控 + 五个负控）：旋转/翻转/蒙版/描边/渐变
///     各自都要退出快速路径，否则"内部"不再是常量块（圆角是**另一条专门的
///     测试**：它不退出快速路径，而是把盒内缩半径——圆弧那一支单独钉）；
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
test "实心矩形快速路径：前提齐了才有内部，五个负控一个都不能少" {
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

  // 五个负控：每条前提各自单独破坏一次，都必须退出快速路径
  // （圆角不在这个名单里：它现在**进**快速路径，见下面那条测试。）
  let cases : Array[(String, @core.Layer)] = [
    ("旋转", { ..base, rotation_deg: 15.0 }),
    ("flip_h", { ..base, flip_h: true }),
    ("flip_v", { ..base, flip_v: true }),
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
      // 圆角 0 与 3 各跑一遍：圆角的"盒"比矩形小一圈，正好逼出"快速段与
      // 通用段在同一张图上接缝"（角上那圈像素必须由通用路径画对）。
      for cr in [0.0, 3.0] {
      let rect = {
        ..@core.default_layer("r1", "r1", 10.3 + dx, 7.7 + dw, 20.25 + dw, 15.5 + dx),
        fill: @core.Fill::Solid(0x803366CC),
        opacity: 0.5,
        corner_radius: cr,
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
        msg="dx=\{dx} dw=\{dw} 圆角=\{cr}：快速路径与通用路径差了 \{diff} 个像素",
      )
      }
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
    points: [],
  }
}

///|
test "快速路径：圆角矩形的内接盒 —— 盒里每个像素的 4 个样本都真的在形内" {
  let base = {
    ..@core.default_layer("r1", "r1", 10.3, 7.7, 20.25, 15.5),
    fill: @core.Fill::Solid(0xFF3366CC),
    corner_radius: 3.0,
  }
  // 半径 3 ⇒ 每条边再内缩 3：10.3+3-0.25 ⇒ 14；10.3+20.25-3-0.75 ⇒ 27；
  // 7.7+3-0.25 ⇒ 11；7.7+15.5-3-0.75 ⇒ 20。
  assert_eq(
    solid_rect_interior(base, base.fill, 0, 0, 64, 64),
    Some((14, 11, 27, 20)),
  )
  // 对照：同一个盒子把半径改成 0 就必须回到矩形内部 —— 说明内缩真的发生了
  // （否则"圆角也走快速路径"这句只是把矩形那条路又跑了一遍）。
  let square = { ..base, corner_radius: 0.0 }
  assert_eq(
    solid_rect_interior(square, square.fill, 0, 0, 64, 64),
    Some((11, 8, 30, 23)),
  )

  // **决定性判据**：盒里每个像素的 4 个样本都必须真的在形内。这里用的正是
  // 渲染器算 cover 的那一个判据（`inside_fill`，笔宽 ≤ 0 时 cover = 命中数/4）
  // ——快速路径的前提就是这句话，圆弧那一支判宽一个像素 = 角上静默多一块。
  let cases : Array[(String, @core.Layer)] = [
    ("半径 3", base),
    ("半径 5", { ..base, corner_radius: 5.0 }),
    ("半径 7（逼近半高 7.75）", { ..base, corner_radius: 7.0 }),
    ("圆角 + 蒙版右边界切进来", { ..base, mask: Some(rect_mask(0.0, 0.0, 25.0, 64.0, 4.0, 0.0, false)) }),
  ]
  let mut fast_px = 0
  for c in cases {
    match solid_rect_interior(c.1, c.1.fill, 0, 0, 64, 64) {
      None => fail("「\{c.0}」该能走快速路径（否则这条断言是空的）")
      Some((ix0, iy0, ix1, iy1)) => {
        let mut y = iy0
        while y < iy1 {
          let mut x = ix0
          while x < ix1 {
            for s in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
              let lx = x.to_double() + s.0 - c.1.x
              let ly = y.to_double() + s.1 - c.1.y
              assert_true(
                inside_fill(c.1, lx, ly),
                msg="「\{c.0}」的盒里 (\{x},\{y}) 样本 (\{s.0},\{s.1}) 在形外 —— 快速路径会静默多画一块",
              )
            }
            fast_px = fast_px + 1
            x = x + 1
          }
          y = y + 1
        }
      }
    }
  }
  assert_true(fast_px > 0, msg="一条圆角用例都没落进快速路径")

  // 负控：半径大到直边带退化 ⇒ 没有盒子（不是空盒，是 None）
  //   r = h/2 = 7.75 ⇒ y 带 [15.2, 14.7) 空；药丸 r = 30 ⇒ x 带空。
  for pill in [
    ("半径 = 半高", { ..base, corner_radius: 7.75 }),
    ("半径 > 半宽（药丸）", { ..base, corner_radius: 30.0 }),
  ] {
    assert_true(
      solid_rect_interior(pill.1, pill.1.fill, 0, 0, 64, 64) is None,
      msg="「\{pill.0}」的直边带已经退化成线，不该再给出盒子",
    )
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
  // 蒙版右边界切进层内（局部 w=25、feather=4 ⇒ 覆盖恒 1 只到局部 x=21）
  // ⚠️ 盒要**先平移回画布**（层在 10.3，局部 4 ⇒ 画布 14.3 ⇒ 首个整覆盖列 15）。
  // 修前这里期望 (11,8,21,23)：把局部盒当画布盒用，于是"覆盖恒为 1"的盒从
  // 画布 11 起——那一列的覆盖其实只有 0.7/4，快速路径按 1.0 合成 = **静默加亮**。
  let cut = { ..base, mask: Some(rect_mask(0.0, 0.0, 25.0, 64.0, 4.0, 0.0, false)) }
  assert_eq(solid_rect_interior(cut, cut.fill, 0, 0, 64, 64), Some((15, 12, 30, 23)))
  // 毛边也要算进阈值：roughen=3 时盒再内缩 3 像素（否则噪声会把 cover 压到 1 以下）
  let rough = { ..base, mask: Some(rect_mask(0.0, 0.0, 25.0, 64.0, 4.0, 3.0, false)) }
  assert_eq(
    solid_rect_interior(rough, rough.fill, 0, 0, 64, 64),
    Some((18, 15, 28, 23)),
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
    // 蒙版自己的**右边界切在层内部**、且带羽化但没有毛边：这条专门钉住快速盒的
    // 上界要给 2×2 子样本留 0.75 的余量（`SUBSAMPLE_MAX`）——不然最右一列会被
    // 按 cover=1 合成，而它最后一个子样本的覆盖其实只有 0.975。
    {
      ..base,
      mask: Some(rect_mask(0.0, 0.0, 15.0, 64.0, 2.0, 0.0, false)),
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
            // ⚠️ 盒是**画布**像素盒（`solid_rect_interior` 在画布坐标里算），
            // 而 `mask_cover_at` 收**层局部**坐标 ⇒ 必须过 `to_local`。
            // 这条循环此前直接传画布 x/y，与 `mask_full_box` 当年那份"局部当画布"
            // 互相自证成"对"，两个错凑成一条绿 —— 现在两边都换算。
            // 而且渲染器真正取的是 **2×2 子样本**（通用路径按样本算覆盖度、快速
            // 路径按 1.0 合成），所以"逐位相同"要求四个样本都恰好 1，不是只看中心。
            for (sx, sy) in subsample_2x2 {
              let (lx, ly) = to_local(l, x.to_double() + sx, y.to_double() + sy)
              let c = mask_cover_at(l, lx, ly)
              assert_eq(
                c,
                1.0,
                msg="盒里 (\{x},\{y}) 子样本 (\{sx},\{sy}) 的覆盖是 \{c}，不是 1 —— 快速路径会静默加亮",
              )
            }
            x = x + 1
          }
          y = y + 1
        }
        // 不判窄得离谱：盒至少要装得下几个像素，否则"快速路径"名存实亡
        // （保守到空盒也能过上面那条）。
        // ⚠️ 这里曾写"≥ 层内部面积的 1/4"——那是个**编出来的**阈值，它当年能过
        // 恰恰是因为蒙版盒被整体错位了一层的位置（`mask_full_box` 那份局部/画布
        // 混用），交集碰巧大。坐标修准之后，`feather=6` 盖在 15px 高的椭圆上，
        // "覆盖恒为 1"的核心本来就只剩 3×2 像素——真值如此，不是保守过头。
        let area = (ix1 - ix0) * (iy1 - iy0)
        assert_true(
          area >= 4,
          msg="蒙版覆盖恒 1 的盒只有 \{area} 像素（盒 (\{ix0},\{iy0},\{ix1},\{iy1})）——保守过头了",
        )
      }
    }
  }
}

///|
test "实心矩形快速路径 + 蒙版：覆盖恒 1 的蒙版必须画得与「没有蒙版」逐位相同" {
  let env = RenderEnv::new()
  let mut dx = 0.0
  while dx < 1.0 {
    let rect = {
      ..@core.default_layer("r1", "r1", 10.3 + dx, 7.7, 20.25, 15.5),
      fill: @core.Fill::Solid(0x803366CC),
      opacity: 0.5,
      corner_radius: 3.0,
    }
    // **覆盖恒为 1** 的蒙版（整幅、无羽化、无毛边）：快速段的全部假设就是
    // "盒里覆盖恒 1"，所以这种蒙版的画面必须与**根本没有蒙版**逐位相同——
    // 两段的接缝（盒边界）上一旦有一处算错，这里立刻红。
    //
    // ⚠️ 这条曾经拿"翻转镜像"当对照：蒙版是**贴在层矩形上**的、会跟着层一起
    // 镜像，于是镜像版画的**不是同一块**（实测 (13,7) 上原件中心在蒙版外、
    // 镜像版在内 ⇒ 差 266 个像素是**正确行为**）。改前两者都"错得一样"才逐位
    // 相同——**对拍的前提错了，绿的也不是判据**（PLAN 五十六）。
    // 也别拿**带羽化**的蒙版跟无蒙版比：那是蒙版本来就该改画面，比出来的
    // 差异不是接缝（实测 37 个像素）。
    let full = { ..rect, mask: Some(rect_mask(0.0, 0.0, 64.0, 64.0, 0.0, 0.0, false)) }
    let nomask = { ..rect, mask: None }
    assert_true(
      solid_rect_interior(full, full.fill, 0, 0, 64, 64) is Some(_),
      msg="覆盖恒 1 的蒙版该能走快速路径（否则这条对拍白比）",
    )
    assert_true(
      solid_rect_interior(nomask, nomask.fill, 0, 0, 64, 64) is Some(_),
      msg="无蒙版版必须也走快速路径（对照组的前提）",
    )
    let a = render_layers(fast_doc("a", full), env)
    let b = render_layers(fast_doc("b", nomask), env)
    // 判别力自证：两张图都必须真的画了东西（否则"逐位相同"是空话）
    let mut solid_px = 0
    let mut i = 0
    while i < 64 * 64 {
      if ((a.pixels[i] >> 24) & 0xFF) == 0xFF {
        solid_px = solid_px + 1
      }
      i = i + 1
    }
    assert_true(solid_px > 0, msg="快速路径一个像素都没落（dx=\{dx}）")
    let mut ndiff = 0
    let mut j = 0
    while j < 64 * 64 {
      if a.pixels[j] != b.pixels[j] {
        ndiff = ndiff + 1
      }
      j = j + 1
    }
    assert_true(
      ndiff == 0,
      msg="dx=\{dx}：覆盖恒 1 的蒙版与无蒙版差了 \{ndiff} 个像素（接缝算错了）",
    )
    dx = dx + 0.5
  }
}
