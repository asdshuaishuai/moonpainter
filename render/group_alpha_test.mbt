///|
/// 组的 α 语义：**先把子层叠成"这个组自己的画面"，再整体打折**（SVG
/// `<g opacity>` 的语义）。
///
/// 实测过的错法（逐子层各自打折）：两个不透明子层重叠、组 α=0.5 时，
/// 不重叠处 `#FF7F7FFF`（红）/`#7F7FFFFF`（蓝），而**重叠处是 `#7F3FBFFF`**
/// ——蓝透过"红 α=0.5 的粉"，重叠区被混合了两次，画面里多出一条谁都解释不清
/// 的接缝。整体打折下重叠处应与不重叠的蓝区**同一个值**（PLAN 五十四）。

///|
/// 两个不透明子层重叠的组：红 0..20、蓝 10..30，组 α 可变。
fn group_overlap_doc(alpha : Double) -> @core.Document {
  let doc = @core.new_document("ga", 40, 20)
  let r = {
    ..@core.default_layer("r", "r", 0.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFFFF0000),
  }
  let b = {
    ..@core.default_layer("b", "b", 10.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFF0000FF),
  }
  doc.layers.push({
    ..@core.default_layer("g", "g", 0.0, 0.0, 40.0, 20.0),
    kind: @core.ShapeKind::Group,
    children: [r, b],
    opacity: alpha,
  })
  doc
}

///|
/// 参照：**没有组**的一个不透明蓝层，α 可变——"组整体打折"在重叠区应当与它
/// 给出同一个值（两条不同的代码路径，不是把同一个数算两遍）。
fn blue_alpha_doc(alpha : Double) -> @core.Document {
  let doc = @core.new_document("ba", 40, 20)
  doc.layers.push({
    ..@core.default_layer("b", "b", 0.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFF0000FF),
    opacity: alpha,
  })
  doc
}

///|
fn render_px_of(doc : @core.Document, x : Int, y : Int) -> Int {
  @codec.rgba_get(@render.render_doc(doc, @render.RenderEnv::new()), x, y)
}

///|
test "组的 α：重叠区等于「整体打折」，不再逐子层各自打折（接缝消失）" {
  let g = group_overlap_doc(0.5)
  // 不重叠处照旧：红 α=0.5 叠白底、蓝 α=0.5 叠白底
  assert_eq(render_px_of(g, 5, 10), 0xFFFF7F7F, msg="红区")
  assert_eq(render_px_of(g, 25, 10), 0xFF7F7FFF, msg="蓝区")
  // 重叠处（蓝盖红）：**必须**等于"一个不透明蓝层 α=0.5"的值
  assert_eq(render_px_of(g, 15, 10), render_px_of(blue_alpha_doc(0.5), 5, 10))
  assert_eq(render_px_of(g, 15, 10), 0xFF7F7FFF, msg="重叠区要等于不重叠的蓝区")
  // 判别力自证：不许是"逐子层各自打折"那个值（实测的旧行为，就是这条接缝）
  assert_true(
    render_px_of(g, 15, 10) != 0xFF7F3FBF,
    msg="重叠区还是旧的双重混合值 ⇒ 组没有整体打折",
  )
}

///|
test "组的 α=1：与「没有这一层组」逐位相同（快路径不许改变任何像素）" {
  let grouped = @render.render_doc(group_overlap_doc(1.0), @render.RenderEnv::new())
  let flat = @core.new_document("flat", 40, 20)
  flat.layers.push({
    ..@core.default_layer("r", "r", 0.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFFFF0000),
  })
  flat.layers.push({
    ..@core.default_layer("b", "b", 10.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFF0000FF),
  })
  let flat_buf = @render.render_doc(flat, @render.RenderEnv::new())
  assert_eq(grouped.pixels.length(), flat_buf.pixels.length())
  let mut i = 0
  let mut diff = 0
  while i < grouped.pixels.length() {
    if grouped.pixels[i] != flat_buf.pixels[i] {
      diff = diff + 1
    }
    i = i + 1
  }
  assert_eq(diff, 0, msg="α=1 的组必须与平铺逐位相同（快路径的等价性）")
}

///|
test "组的 α：半透明子层的 α 与组的 α 相乘（不是两次打折）" {
  // 子层自身 α=0.5、组 α=0.5 ⇒ 应等于"一个不透明层 α=0.25"
  let doc = @core.new_document("gh", 40, 20)
  let b = {
    ..@core.default_layer("b", "b", 0.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFF0000FF),
    opacity: 0.5,
  }
  doc.layers.push({
    ..@core.default_layer("g", "g", 0.0, 0.0, 40.0, 20.0),
    kind: @core.ShapeKind::Group,
    children: [b],
    opacity: 0.5,
  })
  assert_eq(render_px_of(doc, 5, 10), render_px_of(blue_alpha_doc(0.25), 5, 10))
}

///|
test "组的 α：嵌套组的 α 也相乘（内层先整体打折，外层再整体打折）" {
  let inner = @core.new_document("nest", 40, 20)
  let b = {
    ..@core.default_layer("b", "b", 0.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFF0000FF),
  }
  let inner_group = {
    ..@core.default_layer("gi", "gi", 0.0, 0.0, 40.0, 20.0),
    kind: @core.ShapeKind::Group,
    children: [b],
    opacity: 0.5,
  }
  inner.layers.push({
    ..@core.default_layer("go", "go", 0.0, 0.0, 40.0, 20.0),
    kind: @core.ShapeKind::Group,
    children: [inner_group],
    opacity: 0.5,
  })
  assert_eq(render_px_of(inner, 5, 10), render_px_of(blue_alpha_doc(0.25), 5, 10))
}
