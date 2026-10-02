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
    (
      "蒙版",
      {
        ..base,
        mask: Some(@core.LayerMask::{
          kind: @core.ShapeKind::Rect,
          x: 0.0,
          y: 0.0,
          w: 64.0,
          h: 64.0,
          radius: 0.0,
          feather: 0.0,
          roughen: 0.0,
          invert: false,
        }),
      },
    ),
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
