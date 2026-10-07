/// flip（翻转）与 render overlay 的行为测试（本轮补齐能力）。

///|
/// 60×40 画布：左半黑矩形 l1 + 右侧 24×20 的右向三角形 l2（顶点偏右侧）。
fn flip_doc() -> @core.Document {
  let doc = @core.new_document("u-flip", 60, 40)
  let bg = @core.default_layer("l1", "bg", 0.0, 0.0, 30.0, 40.0)
  let bg2 = { ..bg, fill: @core.Fill::Solid(0xFF000000) }
  // 三角形占位盒 (36..56, 10..30)，顶点在右缘中点 → 明显左右不对称
  let tri = @core.default_layer("l2", "tri", 36.0, 10.0, 20.0, 20.0)
  let tri2 = {
    ..tri,
    kind: @core.ShapeKind::Polygon,
    points: [(0.0, 0.0), (20.0, 10.0), (0.0, 20.0)],
    fill: @core.Fill::Solid(0xFF00FF00),
  }
  doc.layers.push(bg2)
  doc.layers.push(tri2)
  doc
}

///|
test "flip 序列化往返：flip_h/flip_v 进 canonical JSON" {
  let doc = flip_doc()
  let tri = match @core.find_layer(doc.layers, "l2") {
    Some(l) => l
    None => abort("l2 缺失")
  }
  let tri_f = { ..tri, flip_h: true, flip_v: true }
  doc.layers[1] = tri_f
  let j = @core.doc_to_json(doc)
  assert_true(j.contains("\"flip_h\":true"), msg=j)
  let back = match @core.doc_from_json(j) {
    Ok(d) => d
    Err(e) => abort("反解失败: \{e}")
  }
  assert_true(back.layers[1].flip_h)
  assert_true(back.layers[1].flip_v)
}

///|
test "渲染镜像：flip_h 后三角形尖端像素换边" {
  let env = @render.RenderEnv::new()
  // 顶部探针（y=11 局部内部仅 x∈[0,2]，镜像前后明确互换）
  let a = @render.render_doc(flip_doc(), env)
  assert_eq(@codec.rgba_get(a, 37, 11), 0xFF00FF00) // 未翻转：左上在内部
  assert_eq(@codec.rgba_get(a, 55, 11), 0xFFFFFFFF) // 右上空白
  // 翻转 h：镜像
  let doc = flip_doc()
  let tri = match @core.find_layer(doc.layers, "l2") {
    Some(l) => l
    None => abort("l2 缺失")
  }
  doc.layers[1] = { ..tri, flip_h: true }
  let b = @render.render_doc(doc, env)
  assert_eq(@codec.rgba_get(b, 55, 11), 0xFF00FF00)
  assert_eq(@codec.rgba_get(b, 37, 11), 0xFFFFFFFF)
}

///|
test "render overlay：bbox 线框与序号色可从渲染结果中检出" {
  let env = @render.RenderEnv::new()
  // l1 序号 1 → 调色板[0] 0xFFFF3355；其 bbox 顶点 (0,0) 应被线框染色
  let plain = match @render.render_view(flip_doc(), env, 0.0, 0.0, 1.0, 1.0, 60) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  let marked = match @render.render_view_overlay(flip_doc(), env, 0.0, 0.0, 1.0, 1.0, 60) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  // 未叠加：(0,0) 是 l1 黑底；叠加后是线框色
  assert_eq(@codec.rgba_get(plain, 0, 0), 0xFF000000)
  assert_eq(@codec.rgba_get(marked, 0, 0), 0xFFFF3355)
  // 三角形 bbox 右下角 (56,30) → 序号 2 → 调色板[1]
  assert_eq(@codec.rgba_get(marked, 56, 30), 0xFF33CC66)
  // plain 与 marked 尺寸一致；overlay 不影响无 overlay 渲染（golden 不受扰）
  assert_eq(plain.width, marked.width)
}

///|
/// **盒子巨大的层不许把 overlay 画卡死**（PLAN 七十五）。
///
/// `add-rect w=99999999999999999999` 是**入口收下**的合法文档（Double 有限），
/// 层填充被 `paint_window` 裁到画布、秒回；而 overlay 要给每个可见层画 bbox
/// 线框，线框走 Bresenham——**迭代次数由线段长度决定**，于是"越界由
/// `rgba_set` 丢弃"这句话对写成立、对循环不成立，渲染整条进程卡死。
/// 这条测试的判据是**能跑完**（修好之前它自己会挂住）+ 线框仍出现在画布里。
test "overlay：层盒子巨大（1e20）也必须画得完，且线框仍落在画布内" {
  let doc = @core.new_document("u-huge", 40, 40)
  let l = @core.default_layer("l1", "huge", 0.0, 0.0, 1.0e20, 1.0e20)
  doc.layers.push({ ..l, fill: @core.Fill::Solid(0xFF000000) })
  let env = @render.RenderEnv::new()
  let marked = match @render.render_view_overlay(doc, env, 0.0, 0.0, 1.0, 1.0, 40) {
    Ok(b) => b
    Err(e) => abort("overlay 渲染失败: \{e}")
  }
  assert_eq(marked.width, 40)
  assert_eq(marked.height, 40)
  // 线框色（序号 1 = palette[0]）必须真的出现在画布里：裁过头 = 线框没了
  let mut found = 0
  for y in 0..<marked.height {
    for x in 0..<marked.width {
      if @codec.rgba_get(marked, x, y) == 0xFFFF3355 {
        found = found + 1
      }
    }
  }
  assert_true(found > 0, msg="巨大盒子的线框仍要画出来（被裁掉的只是框外那部分）")
}
