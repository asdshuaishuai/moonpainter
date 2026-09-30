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
    layer: "",
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
    layer: "",
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

///|
/// 带 `layer=` 作用域的算子（其余字段与 `rprog` 相同）。
fn rprog_layer(sel : @core.SelSpec, hue : Double, layer : String) -> @core.EditProgram {
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel,
    amount: 1.0,
    hue_deg: hue,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer,
    refine: [],
    note: "",
    evidence: None,
  }
  { ops: [op], guards: [] }
}

///|
fn must_render(
  doc : @core.Document,
  env : @render.RenderEnv,
  prog : @core.EditProgram,
) -> @codec.RgbaBuf {
  match @render.render_doc_with(doc, env, prog) {
    Ok(x) => x
    Err(e) => abort("不该失败: \{e}")
  }
}

///|
test "图层级编辑：layer= 把作用域收窄到那一层（与文档级形成对照）" {
  // PLAN 里最大的一条待办。关键不在"加个字段"，而在**选择子在哪张图上求值**：
  // 只有先把那一层单独栅格化，才拿得到"这一层自己的像素"；合成底图上前景与
  // 背景早已乘在一起（README 的诚实边界说过，`recolor` 的边缘去污染在底图上
  // 无解，就是这个原因）。
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let whole = rsel(0.0, 0.0, 16.0, 8.0)
  let doc_level = must_render(doc, env, rprog(whole, 120.0))
  let layer_level = must_render(doc, env, rprog_layer(whole, 120.0, "l1"))
  // 对照 A：文档级——两侧都被改（否则这条测试的"收窄"就没有参照物）
  assert_true(
    @codec.rgba_get(doc_level, 4, 4) != 0xFFC81E1E,
    msg="文档级应当改变左半",
  )
  assert_true(
    @codec.rgba_get(doc_level, 12, 4) != 0xFF1E5ACC,
    msg="文档级应当改变右半",
  )
  // 对照 B：图层级——左半被改，右半**逐位不变**
  assert_true(
    @codec.rgba_get(layer_level, 4, 4) != 0xFFC81E1E,
    msg="layer=l1 应当改变左半",
  )
  assert_eq(
    @codec.rgba_get(layer_level, 12, 4),
    0xFF1E5ACC,
    msg="layer=l1 不该碰右半",
  )
  // 且左半的结果与文档级一致：左半只由 l1 构成，选择子在同一批像素上求值
  assert_eq(
    @codec.rgba_get(layer_level, 4, 4),
    @codec.rgba_get(doc_level, 4, 4),
    msg="同层覆盖区上，图层级与文档级应当给出同一个像素",
  )
}

///|
test "图层级编辑：文档级算子仍然作用在合成图上（两段式）" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let whole = rsel(0.0, 0.0, 16.0, 8.0)
  let left = rsel(0.0, 0.0, 8.0, 8.0)
  let right = rsel(8.0, 0.0, 8.0, 8.0)
  // 两个图层级算子（各绑一层）+ 一个文档级算子
  let p : @core.EditProgram = {
    ops: [
      rprog_layer(whole, 120.0, "l1").ops[0],
      rprog_layer(whole, 240.0, "l2").ops[0],
      rprog(right, 30.0).ops[0],
    ],
    guards: [],
  }
  let out = must_render(doc, env, p)
  // 两侧都被各自的图层级算子改过（与原始色不同）
  assert_true(@codec.rgba_get(out, 4, 4) != 0xFFC81E1E, msg="l1 应被改")
  assert_true(@codec.rgba_get(out, 12, 4) != 0xFF1E5ACC, msg="l2 应被改")
  // 与"只有图层级段"的结果不同——证明文档级段真的又在合成图上跑了一遍
  let only_layers : @core.EditProgram = {
    ops: [
      rprog_layer(whole, 120.0, "l1").ops[0],
      rprog_layer(whole, 240.0, "l2").ops[0],
    ],
    guards: [],
  }
  let two_stage = must_render(doc, env, only_layers)
  assert_true(
    @codec.rgba_get(out, 12, 4) != @codec.rgba_get(two_stage, 12, 4) ||
    @codec.rgba_get(out, 4, 4) != @codec.rgba_get(two_stage, 4, 4),
    msg="文档级算子必须真的又作用了一遍（否则两段式只是摆设）",
  )
  let _ = left
}

///|
test "图层级编辑：只引用一层的表，不含图层级算子时走原路径（逐位不变）" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let whole = rsel(0.0, 0.0, 16.0, 8.0)
  // layer="" → 单段路径，应与 render_doc + run_program 完全一致
  let a = must_render(doc, env, rprog(whole, 120.0))
  let base = @render.render_layers(doc, env)
  let b = match @pixel.run_program(base, rprog(whole, 120.0)) {
    Ok(pair) => pair.0
    Err(e) => abort("不该失败: \{e}")
  }
  let mut i = 0
  let total = a.width * a.height
  while i < total {
    assert_eq(a.pixels[i], b.pixels[i], msg="空 layer 必须走单段路径 @\{i}")
    i = i + 1
  }
}

///|
test "图层级编辑：layer= 与 STAGE 基准组合被拒绝（分段后序号不连续）" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 16.0, h: 8.0, feather: 0.0 }
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: { basis: @core.Stage(0), expr: @core.Atom(@core.Geo(g, "rect")) },
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "l1",
    refine: [],
    note: "",
    evidence: None,
  }
  let prog : @core.EditProgram = { ops: [op], guards: [] }
  match @render.render_doc_with(doc, env, prog) {
    Ok(_) => abort("layer= 与 STAGE 组合必须被拒绝，而不是静默取错缓冲")
    Err(e) =>
      assert_true(
        e.contains("STAGE") && e.contains("分段"),
        msg="错误信息要说清原因：\{e}",
      )
  }
}

///|
test "recolor 边界去污染：图层级作用在纯前景色上，文档级作用在混合色上" {
  // 这是**图层级作用域解决的第一个真问题**：半透明像素的颜色是"前景与背景的
  // 混合"，对它做色彩变换等于连背景的贡献一起偏移（边界污染）。有了
  // `rasterize_layer`，变换可以先作用在**纯前景色**上、再合成回去。
  //
  // 判据不是"两条路径不同"（那太弱），而是可精确算出来的：
  //   图层级结果 == composite(背景, shift(纯前景) 带原 alpha)
  // 其中 `shift(纯前景)` 从一张"只有不透明前景、没有混合"的图上取——那种图上
  // 文档级与图层级是一回事，所以可以放心用它当参照。
  let env = @render.RenderEnv::new()
  let whole8 = rsel(0.0, 0.0, 8.0, 8.0)
  // 1) shift(纯红)：无混合的图上取，文档级即可
  let pure = @core.new_document("u-depollute-1", 8, 8)
  let pr = @core.default_layer("r", "r", 0.0, 0.0, 8.0, 8.0)
  pure.layers.push({ ..pr, fill: @core.Fill::Solid(0xFFFF0000) })
  let shifted = @codec.rgba_get(must_render(pure, env, rprog(whole8, 120.0)), 4, 4)
  assert_true(shifted != 0xFFFF0000, msg="变换必须真的改变了纯红")
  // 2) 蓝底 + 半透明红：每个像素都是混合色
  let doc = @core.new_document("u-depollute-2", 8, 8)
  let bg = @core.default_layer("bg", "bg", 0.0, 0.0, 8.0, 8.0)
  doc.layers.push({ ..bg, fill: @core.Fill::Solid(0xFF0000FF) })
  let ov = @core.default_layer("b", "b", 0.0, 0.0, 8.0, 8.0)
  doc.layers.push({ ..ov, fill: @core.Fill::Solid(0xAAFF0000) })
  // 3) 去污染的正确结果：变换后的**纯前景色**（保持原 alpha）与背景合成
  let want = @render.composite_pixel(
    0xFF0000FF,
    (0xAA << 24) | (shifted & 0x00FFFFFF),
    @core.BlendMode::Normal,
  )
  let layer_level = @codec.rgba_get(
    must_render(doc, env, rprog_layer(whole8, 120.0, "b")),
    4,
    4,
  )
  assert_eq(layer_level, want, msg="图层级应当作用于纯前景色（即去污染）")
  // 4) 文档级：变换吃的是混合色——同一个像素给出别的值，这就是边界污染
  let doc_level = @codec.rgba_get(must_render(doc, env, rprog(whole8, 120.0)), 4, 4)
  assert_true(
    doc_level != want,
    msg="文档级应当给出被污染的结果（两者相同则说明这条测试没有区分度）",
  )
  // 5) 而且背景本身**没有**被牵连：图层级路径下，不含该层像素的位置逐位不变。
  //    这里层铺满全图，所以换个角度——把层缩到左半，看右半。
  let doc2 = @core.new_document("u-depollute-3", 8, 8)
  let bg2 = @core.default_layer("bg", "bg", 0.0, 0.0, 8.0, 8.0)
  doc2.layers.push({ ..bg2, fill: @core.Fill::Solid(0xFFFFFFFF) })
  let half = @core.default_layer("b", "b", 0.0, 0.0, 4.0, 8.0)
  doc2.layers.push({ ..half, fill: @core.Fill::Solid(0xAAFF0000) })
  let out2 = must_render(doc2, env, rprog_layer(whole8, 120.0, "b"))
  assert_eq(
    @codec.rgba_get(out2, 6, 4),
    0xFFFFFFFF,
    msg="图层级路径不该碰到这一层覆盖范围之外的背景",
  )
  assert_true(
    @codec.rgba_get(out2, 2, 4) != 0xFFFFFFFF,
    msg="层内像素必须真的被改了",
  )
}
