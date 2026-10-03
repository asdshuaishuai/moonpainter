/// 笔触层（Raster）的**读点**：`x/y` 是读的，`w/h` 不是。
///
/// 这一格在 PLAN 里挂过一轮疑点（"dab 存的是不是画布坐标 ⇒ x/y 半读"）。
/// 量完是**负结果**：`dab_box` 用的是 `l.x + d.x`（dab 存**局部**坐标、层
/// 的 x/y 负责平移），所以 `move` 真的会挪笔触；而 `w/h` 只有报告面
/// （query-layer / overlay 线框）读，渲染器一条都不读——`dabs_window` 的
/// 裁剪用的是**画布**尺寸（`buf.width/height`），不是层的盒子。
///
/// 不变量必须钉住，因为"拿层的盒子当笔触窗口"看起来很像一次优化
/// （少扫几行），实际上会**静默裁掉墨**。变异 Q52 就是这一刀。

///|
fn raster_doc(uuid : String) -> @core.Document {
  let doc = @core.new_document(uuid, 100, 100)
  let d1 = @core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFFFF0000, erase: false }
  let d2 = @core.Dab::{ x: 60.0, y: 20.0, r: 6.0, color: 0xFF00FF00, erase: false }
  doc.layers.push(
    {
      ..@core.default_layer("r", "笔触", 0.0, 0.0, 100.0, 100.0),
      kind: @core.ShapeKind::Raster,
      dabs: [d1, d2],
    },
  )
  doc
}

///|
/// 找两块缓冲第一个不同的像素（`None` = 逐位相同）。**不在 helper 里断言**：
/// helper 没有 error 类型时 `assert_eq` 编不过（error 4122）。
fn first_diff(a : @codec.RgbaBuf, b : @codec.RgbaBuf) -> (Int, Int)? {
  if a.width != b.width || a.height != b.height {
    return Some((-1, -1))
  }
  let mut y = 0
  while y < a.height {
    let mut x = 0
    while x < a.width {
      if @codec.rgba_get(a, x, y) != @codec.rgba_get(b, x, y) {
        return Some((x, y))
      }
      x = x + 1
    }
    y = y + 1
  }
  None
}

///|
test "笔触层：改盒子（w/h）不改一个像素、也不改拾取（x/y 才是读点）" {
  let env = @render.RenderEnv::new()
  let doc = raster_doc("u-raster-box")
  let before = @render.render_layers(doc, env)
  // 前置状态：笔触真的落了墨（否则下面"逐位相同"可能只是"两边都空的"）
  assert_eq(@codec.rgba_get(before, 20, 20), 0xFFFF0000, msg="前置：dab1 应在 (20,20) 落红")
  assert_eq(@codec.rgba_get(before, 60, 20), 0xFF00FF00, msg="前置：dab2 应在 (60,20) 落绿")
  assert_eq(@render.pick(doc, 20.0, 20.0), Some("r"), msg="前置：pick 应命中")

  // 把盒子缩到 10×10（比任何一个 dab 都小）——**像素必须一个都不变**
  let l0 = doc.layers[0]
  doc.layers[0] = { ..l0, w: 10.0, h: 10.0 }
  let after = @render.render_layers(doc, env)
  assert_true(
    first_diff(before, after) is None,
    msg="盒子从 100×100 缩到 10×10 不该改一个像素（w/h 不是读点）",
  )
  assert_eq(@render.pick(doc, 20.0, 20.0), Some("r"), msg="盒子变小不该让 pick 丢掉墨")
  assert_eq(@render.pick(doc, 60.0, 20.0), Some("r"), msg="同上（第二个 dab）")

  // 正控（另一头）：`x/y` **是**读点——挪层必须把墨一起挪走，
  // 否则上面那条"逐位相同"可能只是因为整个渲染路径根本没读层坐标。
  let l1 = doc.layers[0]
  doc.layers[0] = { ..l1, x: 30.0 }
  let moved = @render.render_layers(doc, env)
  assert_eq(@codec.rgba_get(moved, 50, 20), 0xFFFF0000, msg="x=30 后 dab1 应落到 (50,20)")
  assert_eq(@codec.rgba_get(moved, 20, 20), 0xFFFFFFFF, msg="原位应露出白底")
  assert_true(@render.pick(doc, 20.0, 20.0) is None, msg="挪走之后原位不该再命中")
  assert_eq(@render.pick(doc, 50.0, 20.0), Some("r"), msg="新位置应命中")
}
