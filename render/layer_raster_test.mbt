/// 逐层栅格化 + 合成（**层级混合**）与直接渲染（**元素级混合**）的对照实验。
///
/// 这组测试要钉住的是「图层级编辑」的**架构前提**：要"只作用于某几个图层"，
/// 先得能把单层栅格化出来（`rasterize_layer`），改完再叠回主缓冲
/// （`blend_buffer`）。但"逐层栅格化再合成"与现在的"直接逐层画"是不是同一
/// 件事，取决于**层内元素有没有互相重叠**——所以两条都要钉：
///
///   * 不透明层：逐位相同；
///   * 层内半透明重叠：**也逐位相同**——`over` 运算是结合的
///     （`over(over(bg,a),b) == over(bg, over(a,b))`），所以"先叠出整层再与底
///     混合"和"每个元素各自与底混合"在 Normal 模式下数学等价。
///
/// 第二点一开始我写反了：以为"层级混合"会改变结果，还断言"必须有差异"，
/// 结果 `diff=0` 报错。**那个 0 其实是最好的消息**——它意味着把逐层栅格化
/// 接进渲染管线是**零回归**的：能单独拿到、改完放回去，而输出一个像素不变。
/// 图层级编辑要的是"能对某一层单独施加编辑"，不是"改变混合语义"。

///|
fn rect_layer(id : String, x : Double, w : Double, fill : Int) -> @core.Layer {
  let l = @core.default_layer(id, id, x, 0.0, w, 8.0)
  { ..l, fill: @core.Fill::Solid(fill) }
}

///|
test "栅格化合成：不透明层与直接渲染逐位相同" {
  let doc = @core.new_document("u-rast", 8, 8)
  doc.layers.push(rect_layer("a", 0.0, 8.0, 0xFFFF0000))
  doc.layers.push(rect_layer("b", 4.0, 4.0, 0xFF00FF00))
  let env = @render.RenderEnv::new()
  let direct = @render.render_layers(doc, env)
  let raster = @render.render_layers_rasterized(doc, env)
  let mut y = 0
  while y < 8 {
    let mut x = 0
    while x < 8 {
      assert_eq(
        @codec.rgba_get(raster, x, y),
        @codec.rgba_get(direct, x, y),
        msg="(\{x},\{y})：不透明层下两条路径应逐位相同",
      )
      x = x + 1
    }
    y = y + 1
  }
}

///|
test "栅格化合成：层内半透明重叠时也逐位相同（over 结合 ⇒ 零回归）" {
  // 一层：半透明填充 + 半透明描边（描边压在填充的边界上，层内自重叠）。
  let doc = @core.new_document("u-rast2", 16, 16)
  let base = @core.default_layer("l", "l", 2.0, 2.0, 12.0, 12.0)
  let l = {
    ..base,
    fill: @core.Fill::Solid(0x80FF0000),
    stroke: { color: 0x800000FF, width: 4.0 },
  }
  doc.layers.push(l)
  let env = @render.RenderEnv::new()
  let direct = @render.render_layers(doc, env)
  let raster = @render.render_layers_rasterized(doc, env)
  let mut diff = 0
  let mut y = 0
  while y < 16 {
    let mut x = 0
    while x < 16 {
      if @codec.rgba_get(raster, x, y) != @codec.rgba_get(direct, x, y) {
        diff = diff + 1
      }
      x = x + 1
    }
    y = y + 1
  }
  // 逐位相同 = 逐层栅格化没有改变渲染语义，接进管线是零回归的。
  assert_eq(
    diff,
    0,
    msg="层内半透明重叠时两条路径应逐位相同（over 结合），实际 \{diff} 个像素不同",
  )
  // 但这一层**确实**是半透明的——否则上面那条断言是空的（层全不透明时
  // 两条路径当然相同，测不出任何东西）。这条让样本里包含"那个约定存在的理由"。
  let env2 = @render.RenderEnv::new()
  let buf = @render.rasterize_layer(l, 16, 16, env2)
  let a = (@codec.rgba_get(buf, 8, 8) >> 24) & 0xFF
  assert_true(
    a > 0 && a < 255,
    msg="这一层必须是半透明的（alpha 应介于 0 与 255，got \{a}），否则上面那条断言没有意义",
  )
}

///|
test "rasterize_layer：透明底上拿到的是这一层自己的 RGBA（alpha=覆盖度）" {
  // 半透明矩形：栅格化后该像素 alpha 应是 0x80 左右，而不是被白底拉满。
  let base = @core.default_layer("l", "l", 0.0, 0.0, 8.0, 8.0)
  let l = { ..base, fill: @core.Fill::Solid(0x80FF0000) }
  let env = @render.RenderEnv::new()
  let buf = @render.rasterize_layer(l, 8, 8, env)
  let c = @codec.rgba_get(buf, 4, 4)
  let a = (c >> 24) & 0xFF
  assert_true(
    a > 0 && a < 255,
    msg="半透明层的栅格化像素应保留部分 alpha（got a=\{a}，c=\{c}）",
  )
  // 层外（这张图铺满，所以取一个必然在层内的点对照）：颜色应对得上填充色系
  assert_eq(@codec.rgba_get(buf, 4, 4) & 0x00FFFFFF, 0x00FF0000)
}
