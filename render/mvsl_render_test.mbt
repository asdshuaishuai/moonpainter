/// 渲染管线里的 MVSL 编辑表（最终一遍）：空程序逐位等价、非空程序按选择子
/// 生效、坏程序报错而不是糊过去、取景不改变选择子语义。

///|
/// 16×8 画布：左半红、右半蓝（几何谓词可精确切分）。
fn two_tone_doc() -> @core.Document {
  let doc = @core.new_document("u-mvsl-render", 16, 8)
  let l = @core.default_layer("l1", "left", 0.0, 0.0, 8.0, 8.0)
  let l2 = { ..l, fill: @core.Fill::Solid(0xFFC81E1E) }
  let r = @core.default_layer("l2", "right", 8.0, 0.0, 8.0, 8.0)
  let r2 = { ..r, fill: @core.Fill::Solid(0xFF1E5ACC) }
  doc.layers.push(l2)
  doc.layers.push(r2)
  doc
}

///|
fn rsel(x : Double, y : Double, w : Double, h : Double) -> @core.SelSpec {
  let g : @core.GeoWindow = { x, y, w, h, feather: 0.0 }
  { basis: @core.Base, expr: @core.Atom(@core.Geo(g, "rect")) }
}

///|
fn rprog(sel : @core.SelSpec, hue : Double) -> @core.EditProgram {
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel,
    amount: 1.0,
    hue_deg: hue,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  { ops: [op], guards: [] }
}

///|
test "空编辑表：render_doc_with 与 render_doc 逐位相同（既有 golden 不受影响）" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let a = @render.render_doc(doc, env)
  let b = match @render.render_doc_with(doc, env, @core.EditProgram::new()) {
    Ok(x) => x
    Err(e) => abort("空程序不该失败: \{e}")
  }
  assert_eq(b.width, a.width, msg="宽")
  assert_eq(b.height, a.height, msg="高")
  let total = a.width * a.height
  let mut i = 0
  while i < total {
    assert_eq(b.pixels[i], a.pixels[i], msg="空编辑表破坏了逐位还原 @\{i}")
    i = i + 1
  }
  // 取景路径同理
  let v0 = match @render.render_view(doc, env, 0.0, 0.0, 1.0, 1.0, 16) {
    Ok(x) => x
    Err(e) => abort("view: \{e}")
  }
  let v1 = match @render.render_view_with(doc, env, 0.0, 0.0, 1.0, 1.0, 16, { ops: [], guards: [] }) {
    Ok(x) => x
    Err(e) => abort("view_with: \{e}")
  }
  assert_eq(v1.pixels[0], v0.pixels[0], msg="空程序取景左上角不同")
  assert_eq(v1.pixels[15], v0.pixels[15], msg="空程序取景右上角不同")
}

///|
test "非空编辑表：只在选择子命中的像素上改变渲染结果" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let base = @render.render_doc(doc, env)
  // 只改左半（画布坐标 x ∈ [0,8)）
  let out = match @render.render_doc_with(doc, env, rprog(rsel(0.0, 0.0, 8.0, 8.0), 120.0)) {
    Ok(x) => x
    Err(e) => abort("render_doc_with: \{e}")
  }
  // 左半必须变
  assert_true(@codec.rgba_get(out, 2, 4) != @codec.rgba_get(base, 2, 4), msg="左半未生效")
  // 右半必须逐位不变
  let mut x = 8
  while x < 16 {
    let mut y = 0
    while y < 8 {
      assert_eq(
        @codec.rgba_get(out, x, y),
        @codec.rgba_get(base, x, y),
        msg="右半被误改 @(\{x},\{y})",
      )
      y = y + 1
    }
    x = x + 1
  }
}

///|
test "取景不改变选择子语义：同一程序在两个 viewport 下命中同一批画布像素" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let prog = rprog(rsel(4.0, 0.0, 4.0, 8.0), 90.0)
  // 全图取景（16px 宽）
  let full = match @render.render_view_with(doc, env, 0.0, 0.0, 1.0, 1.0, 16, prog) {
    Ok(x) => x
    Err(e) => abort("full: \{e}")
  }
  let basefull = @render.render_doc(doc, env)
  // 命中区（画布 x∈[4,8)）变了
  assert_true(@codec.rgba_get(full, 5, 4) != @codec.rgba_get(basefull, 5, 4), msg="命中区未生效")
  // 未命中区没变
  assert_eq(@codec.rgba_get(full, 1, 4), @codec.rgba_get(basefull, 1, 4), msg="左侧被误改")
  assert_eq(@codec.rgba_get(full, 12, 4), @codec.rgba_get(basefull, 12, 4), msg="右侧被误改")
  // 取景到左半（归一化 0..0.5）→ 输出的右半是画布 x∈[4,8)，应带改动
  let left_half = match @render.render_view_with(doc, env, 0.0, 0.0, 0.5, 1.0, 8, prog) {
    Ok(x) => x
    Err(e) => abort("left_half: \{e}")
  }
  assert_true(
    @codec.rgba_get(left_half, 5, 4) != @codec.rgba_get(basefull, 1, 4),
    msg="取景到左半后仍应看到命中区的改动",
  )
}

///|
test "坏编辑表：渲染报错，不静默漏渲染" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  // 第 0 个算子引用 stage:1（前视）→ 必须报错
  let op : @core.EditOp = {
    id: "e0",
    kind: @core.Recolor,
    sel: { basis: @core.Stage(1), expr: rsel(0.0, 0.0, 1.0, 1.0).expr },
    amount: 1.0,
    hue_deg: 10.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  match @render.render_doc_with(doc, env, { ops: [op], guards: [] }) {
    Ok(_) => abort("前视 STAGE 不该渲染成功")
    Err(e) => assert_true(e.has_prefix("MVSL 编辑表执行失败"), msg=e)
  }
  // 取景路径同样必须报错（不能只在全图路径上把关）
  match @render.render_view_with(doc, env, 0.0, 0.0, 1.0, 1.0, 8, { ops: [op], guards: [] }) {
    Ok(_) => abort("取景路径漏把关")
    Err(e) => assert_true(e.has_prefix("MVSL 编辑表执行失败"), msg=e)
  }
}

///|
test "编辑表 base 是层合成底图：反复渲染不会自我叠加" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let prog = rprog(rsel(0.0, 0.0, 16.0, 8.0), 120.0)
  let once = match @render.render_doc_with(doc, env, prog) {
    Ok(x) => x
    Err(e) => abort("once: \{e}")
  }
  let twice = match @render.render_doc_with(doc, env, prog) {
    Ok(x) => x
    Err(e) => abort("twice: \{e}")
  }
  // 两次渲染逐位一致（底图始终是层合成，不是上一次的结果）
  let total = once.width * once.height
  let mut i = 0
  while i < total {
    assert_eq(twice.pixels[i], once.pixels[i], msg="重复渲染不幂等 @\{i}")
    i = i + 1
  }
  // 且确实与底图不同（不是空转）
  let base = @render.render_doc(doc, env)
  assert_true(once.pixels[0] != base.pixels[0], msg="编辑表没起作用")
}
