// 白盒测试：**描边的方向**是语义，不是实现细节（铁律 6 / PLAN 十五）。
//
// 同一个 `stroke_w`，几何形状与线段的含义**不一样**：
//   · 矩形/椭圆：描边带在盒子**内**（`outer && !inner`）——不越出层盒子；
//   · 线段：以线段为中心，两边各 `stroke_w/2`（`dist_to_seg <= width/2`）。
// 这条差异此前只活在代码里（`inside_stroke` 的三个分支），文档一个字没写，
// 于是"描边宽 8 的矩形为什么外面没变宽"只能靠读源码回答。现在文档写了
// （DESIGN 边界节），测试钉住它——**改方向必须先改这两处**。

///|
fn stroke_probe_layer(kind : @core.ShapeKind, w : Double, h : Double, sw : Double) -> @core.Layer {
  let l = @core.default_layer("s1", "s", 10.0, 10.0, w, h)
  {
    ..l,
    kind,
    stroke: { color: 0xFF0000FF, width: sw },
    points: [(0.0, 0.0), (w, h)],
  }
}

///|
test "描边方向：矩形向内（盒外不是描边）、线段居中（两端各半宽）" {
  // 20×20 的矩形，描边宽 8 ⇒ 内缩一圈：局部 [-1,21] 里，
  // 盒外（lx = -1 或 21）**不是**描边，盒内边缘（lx = 3）是描边。
  let r = stroke_probe_layer(@core.ShapeKind::Rect, 20.0, 20.0, 8.0)
  assert_false(inside_stroke(r, -1.0, 10.0), msg="矩形描边不许越出盒子（左）")
  assert_false(inside_stroke(r, 21.0, 10.0), msg="矩形描边不许越出盒子（右）")
  assert_false(inside_stroke(r, 10.0, -1.0), msg="矩形描边不许越出盒子（上）")
  assert_true(inside_stroke(r, 3.0, 10.0), msg="盒内一圈必须是描边")
  assert_true(inside_stroke(r, 17.0, 10.0), msg="盒内一圈必须是描边（右）")
  // 内缩 8 之后中心是"内盒"里 ⇒ 不是描边（那是 fill 的地盘）
  assert_false(inside_stroke(r, 10.0, 10.0), msg="内缩 8 的盒子中心不是描边")
  // 描边宽度大于半个短边时内盒退化成负尺寸 ⇒ **整块都算描边**
  // （画出来是实心块、fill 被盖住）：这是实现语义，文档写着，测试钉住
  let fat = stroke_probe_layer(@core.ShapeKind::Rect, 20.0, 20.0, 16.0)
  assert_true(inside_stroke(fat, 10.0, 10.0), msg="描边宽 ≥ 半短边时整块退化成描边（实心块）")

  // 线段：两端各半宽——(0,0)→(20,20) 的中点在线上，法向 3 像素内是描边
  let seg = stroke_probe_layer(@core.ShapeKind::Line, 20.0, 20.0, 8.0)
  assert_true(inside_stroke(seg, 10.0, 10.0), msg="线段上的点在描边里")
  let d = 8.0 / 2.0 * 0.7 // 法向偏移 2.8 ⇒ 距线段 2.8 < 4
  assert_true(inside_stroke(seg, 10.0 + d, 10.0 - d), msg="线段两侧各半宽都在描边里")
  assert_false(inside_stroke(seg, 10.0 + 4.0 * 1.5, 10.0 - 4.0 * 1.5), msg="超出半宽就不是描边")

  // 椭圆：也是向内（归一化半径在 [inner_r, 1] 之间）
  let e = stroke_probe_layer(@core.ShapeKind::Ellipse, 20.0, 20.0, 8.0)
  assert_false(inside_stroke(e, -1.0, 10.0), msg="椭圆描边也不越出盒子")
  assert_true(inside_stroke(e, 0.5, 10.0), msg="椭圆盒内侧必须是描边")

  // 多边形/位图/文本没有描边实现（读点矩阵：入口会拒，这里钉住渲染侧）
  let p = stroke_probe_layer(@core.ShapeKind::Polygon, 20.0, 20.0, 8.0)
  assert_false(inside_stroke(p, 10.0, 10.0), msg="多边形没有描边实现")
  let t = stroke_probe_layer(@core.ShapeKind::Text, 20.0, 20.0, 8.0)
  assert_false(inside_stroke(t, 10.0, 10.0), msg="文本没有描边实现")
}
