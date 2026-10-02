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
test "图层级编辑：STAGE(n>0) 与图层级算子共存必须被拒绝（分段后序号不连续）" {
  // 判据本轮**扩到了整张表**：不只是"层算子自己写 STAGE"，而是"表里只要有
  // 图层级算子，文档级段的 `stage:n`（n>0）口径就与算子序号对不上"——插一条
  // 只改某层的算子，会静默换掉后面文档级算子取到的像素（实测坐实）。
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 16.0, h: 8.0, feather: 0.0 }
  let mk = fn(id : String, basis : @core.SelBasis, layer : String) -> @core.EditOp {
    {
      id,
      kind: @core.Recolor,
      sel: { basis, expr: @core.Atom(@core.Geo(g, "rect")) },
      amount: 1.0,
      hue_deg: 120.0,
      temp_kelvin: 0.0,
      relight_gain: 1.0,
      layer,
      refine: [],
      note: "",
      evidence: None,
    }
  }
  // ① 层算子自己引用 STAGE(0)：`STAGE(0)` = 本条算子的输入，两段式下语义恒真 → 放行
  let ok_prog : @core.EditProgram = { ops: [mk("e1", @core.Stage(0), "l1")], guards: [] }
  match @render.render_doc_with(doc, env, ok_prog) {
    Ok(_) => ()
    Err(e) => abort("STAGE(0) 是「本条算子的输入」，不该被拒：\{e}")
  }
  // ② 层算子自己引用 STAGE(1)：分段后序号不连续 → 拒绝
  let bad1 : @core.EditProgram = { ops: [mk("e1", @core.Stage(1), "l1")], guards: [] }
  match @render.render_doc_with(doc, env, bad1) {
    Ok(_) => abort("层算子的 STAGE(n>0) 必须被拒绝，而不是静默取错缓冲")
    Err(e) => assert_true(e.contains("STAGE"), msg="错误信息要说清原因：\{e}")
  }
  // ③ 表里有层算子，文档级算子引用 STAGE(1) 而**表里第 1 条是层算子** → 拒绝
  //    （这正是"插一条层算子就静默换缓冲"的形态）
  let bad2 : @core.EditProgram = {
    ops: [
      mk("layer-op", @core.Base, "l2"),
      mk("d1", @core.Base, ""),
      mk("d2", @core.Stage(1), ""),
    ],
    guards: [],
  }
  match @render.render_doc_with(doc, env, bad2) {
    Ok(_) => abort("两段式下文档级 STAGE(1) 指向的是层算子之后，必须拒绝")
    Err(e) =>
      assert_true(
        e.contains("STAGE") && e.contains("文档级"),
        msg="错误要说清是文档级段的口径问题：\{e}",
      )
  }
  // ④ 正控：表里第 1 条恰好是**文档级**（层算子排在最后）→ 放行（不许误伤）
  let ok2 : @core.EditProgram = {
    ops: [
      mk("d1", @core.Base, ""),
      mk("d2", @core.Stage(1), ""),
      mk("layer-op", @core.Base, "l2"),
    ],
    guards: [],
  }
  match @render.render_doc_with(doc, env, ok2) {
    Ok(_) => ()
    Err(e) => abort("目标条是文档级算子时 STAGE(1) 语义明确，不该被拒：\{e}")
  }
  // ⑤ 正控：整张表都是文档级（历史行为，一律放行）
  let ok3 : @core.EditProgram = { ops: [mk("d1", @core.Base, ""), mk("d2", @core.Stage(1), "")], guards: [] }
  match @render.render_doc_with(doc, env, ok3) {
    Ok(_) => ()
    Err(e) => abort("纯文档级表的 STAGE(1) 是历史行为，不该被拒：\{e}")
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

///|
/// 给某一层打上标签（返回新文档；不改原文档）。
fn tag_only(doc : @core.Document, id : String, tag : String) -> @core.Document {
  let layers : Array[@core.Layer] = []
  for l in doc.layers {
    if l.id == id {
      layers.push(@core.layer_with_tag(l, tag))
    } else {
      layers.push(l)
    }
  }
  { ..doc, layers }
}

///|
/// 把某一层的某个标签摘掉（返回新文档）。
fn untag_only(doc : @core.Document, id : String, tag : String) -> @core.Document {
  let layers : Array[@core.Layer] = []
  for l in doc.layers {
    if l.id == id {
      layers.push(@core.layer_without_tag(l, tag))
    } else {
      layers.push(l)
    }
  }
  { ..doc, layers }
}

///|
fn whole16() -> @core.SelSpec {
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 16.0, h: 8.0, feather: 0.0 }
  { basis: @core.Base, expr: @core.Atom(@core.Geo(g, "rect")) }
}

///|
test "layer=@tag：只改带该标签的层，且与 layer=<id> 逐位等价" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc() // l1 左半红、l2 右半蓝
  let tagged = tag_only(doc, "l1", "hero")
  let base = @render.render_doc(tagged, env)
  // 标签作用域 vs 具体层 id：同一张图的两种写法，必须逐位相同
  let by_tag = must_render(tagged, env, rprog_layer(whole16(), 120.0, "@hero"))
  let by_id = must_render(tagged, env, rprog_layer(whole16(), 120.0, "l1"))
  let total = base.width * base.height
  let mut i = 0
  while i < total {
    assert_eq(
      by_tag.pixels[i],
      by_id.pixels[i],
      msg="layer=@hero 与 layer=l1 应当逐位相同 @\{i}",
    )
    i = i + 1
  }
  // 没带标签的那一层（右半蓝）必须逐位不动
  let mut y = 0
  while y < base.height {
    let mut x = 8
    while x < base.width {
      assert_eq(
        @codec.rgba_get(by_tag, x, y),
        @codec.rgba_get(base, x, y),
        msg="没带 hero 标签的层不该被改 (\{x},\{y})",
      )
      x = x + 1
    }
    y = y + 1
  }
  // 带标签的那一层必须真的被改了（否则上面全是在比"都没动"）
  assert_true(
    @codec.rgba_get(by_tag, 2, 4) != @codec.rgba_get(base, 2, 4),
    msg="带 hero 标签的层必须真的被改",
  )
}

///|
test "layer=@tag 是**一层集合**：两个层都带标签时两份都改，与两条显式算子逐位等价" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let both = tag_only(tag_only(doc, "l1", "hero"), "l2", "hero")
  // 一条 @hero 展开成两条（每层一条）
  let by_tag = must_render(both, env, rprog_layer(whole16(), 120.0, "@hero"))
  // 显式写成两条算子（顺序：层序 l1 → l2）
  let op1 = rprog_layer(whole16(), 120.0, "l1").ops[0]
  let op2 = rprog_layer(whole16(), 120.0, "l2").ops[0]
  let by_two : @core.EditProgram = { ops: [op1, op2], guards: [] }
  let by_two_out = must_render(both, env, by_two)
  let total = by_tag.width * by_tag.height
  let mut i = 0
  while i < total {
    assert_eq(
      by_tag.pixels[i],
      by_two_out.pixels[i],
      msg="一条 @hero 应当等价于「每层各一条算子」 @\{i}",
    )
    i = i + 1
  }
  // 两层都变了：左右各取一点与底图比
  let base = @render.render_doc(both, env)
  assert_true(
    @codec.rgba_get(by_tag, 2, 4) != @codec.rgba_get(base, 2, 4),
    msg="左层（带标签）应被改",
  )
  assert_true(
    @codec.rgba_get(by_tag, 12, 4) != @codec.rgba_get(base, 12, 4),
    msg="右层（带标签）也应被改——只改第一层就是 bug",
  )
}

///|
test "layer=@tag 的活绑定：标签摘掉之后，同一条表在渲染期被拒（不是静默不生效）" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let tagged = tag_only(doc, "l1", "hero")
  let prog = rprog_layer(whole16(), 120.0, "@hero")
  // 正控：打得上的时候渲染得出来
  let _ = must_render(tagged, env, prog)
  // 摘掉标签（**没有**重新装表）：同一条表必须报错，而不是回一张没改的图
  let stripped = untag_only(tagged, "l1", "hero")
  match @render.render_doc_with(stripped, env, prog) {
    Ok(_) =>
      abort("标签摘掉后 layer=@hero 落不到任何层，渲染必须报错而不是静默不生效")
    Err(e) => {
      assert_true(e.contains("hero"), msg="报错应点出是哪个标签：\{e}")
      assert_true(e.contains("静默"), msg="报错应说明后果：\{e}")
    }
  }
}

///|
test "layer=@tag 的坏写法：裸 @ 与落不到任何层都报错" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  match @render.render_doc_with(doc, env, rprog_layer(whole16(), 120.0, "@")) {
    Ok(_) => abort("layer=@ 必须报错")
    Err(e) => assert_true(e.contains("没有标签名"), msg="裸 @ 的报错不对：\{e}")
  }
  match @render.render_doc_with(doc, env, rprog_layer(whole16(), 120.0, "@nobody")) {
    Ok(_) => abort("layer=@nobody 必须报错")
    Err(e) =>
      assert_true(e.contains("nobody"), msg="落不到任何层的报错应点出标签：\{e}")
  }
}

///|
/// 逐位比较两张缓冲（尺寸 + 每个像素）。
fn same_buf(a : @codec.RgbaBuf, b : @codec.RgbaBuf) -> Bool {
  if a.width != b.width || a.height != b.height {
    return false
  }
  let total = a.width * a.height
  let mut i = 0
  while i < total {
    if a.pixels[i] != b.pixels[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn stages_of(
  doc : @core.Document,
  env : @render.RenderEnv,
  prog : @core.EditProgram,
) -> (Array[@render.ImpactStage], @codec.RgbaBuf) {
  match @render.impact_stages(doc, env, prog) {
    Ok(pair) => pair
    Err(e) => abort("不该失败: \{e}")
  }
}

///|
test "分析出口与真渲染同源：impact_stages 的最终图 == render_doc_with（文档级/层作用域/标签作用域）" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let half = rsel(0.0, 0.0, 8.0, 8.0)
  // 文档级
  let p_doc = rprog(half, 120.0)
  // 层作用域
  let p_layer = rprog_layer(half, 120.0, "l1")
  // 标签作用域（活在容器上）
  let tagged = tag_only(doc, "l1", "hero")
  let p_tag : @core.EditProgram = { ops: [{ ..rprog_layer(half, 120.0, "@hero").ops[0] }], guards: [] }
  for pair in [
    (doc, p_doc, "文档级"),
    (doc, p_layer, "层作用域"),
    (tagged, p_tag, "标签作用域"),
  ] {
    let (stages, out) = stages_of(pair.0, env, pair.1)
    let real = must_render(pair.0, env, pair.1)
    assert_true(
      same_buf(out, real),
      msg="\{pair.2}：impact_stages 的最终图与真渲染不是逐位同一张",
    )
    assert_eq(stages.length(), 1, msg="\{pair.2}：一条算子应有一个阶段")
  }
}

///|
test "逐算子阶段的基底是**该算子真正求值的那张图**：层算子=层栅格，文档级=合成底图" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let half = rsel(0.0, 0.0, 8.0, 8.0)
  // 层算子：基底必须逐位等于 rasterize_layer(l1)（透明底 + 只画这一层）
  let (ls, _) = stages_of(doc, env, rprog_layer(half, 120.0, "l1"))
  let l1 = doc.layers[0]
  let lb = @render.rasterize_layer(l1, doc.width, doc.height, env)
  assert_eq(ls[0].layer, "l1", msg="阶段应报出具体层 id")
  assert_true(same_buf(ls[0].basis, lb), msg="层算子的选择子基底不是该层自己的栅格")
  assert_true(!same_buf(ls[0].basis, @render.render_doc(doc, env)), msg="层算子的基底不该是合成底图")
  assert_true(same_buf(ls[0].before, lb), msg="第一个层算子的 before = 层栅格")
  // 文档级算子：基底是合成底图
  let (ds, _) = stages_of(doc, env, rprog(half, 120.0))
  let base = @render.render_doc(doc, env)
  assert_eq(ds[0].layer, "", msg="文档级算子的 layer 应为空")
  assert_true(same_buf(ds[0].basis, base), msg="文档级算子的基底不是合成底图")
  assert_true(same_buf(ds[0].before, base), msg="第一个文档级算子的 before = 合成底图")
}

///|
test "混合作用域的阶段顺序与链式一致：层算子按层序在前，文档级算子在后" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let half = rsel(0.0, 0.0, 8.0, 8.0)
  let l_op : @core.EditOp = { ..rprog_layer(half, 120.0, "l1").ops[0], id: "layer-op" }
  let d_op : @core.EditOp = { ..rprog(half, 40.0).ops[0], id: "doc-op" }
  let prog : @core.EditProgram = { ops: [d_op, l_op], guards: [] }
  let (stages, out) = stages_of(doc, env, prog)
  assert_eq(stages.length(), 2, msg="两条算子两个阶段")
  // 表里先写的是文档级算子，但两段式下**层算子先执行**（跨作用域顺序不保留，
  // DESIGN §8 已声明）——阶段报告必须照执行的顺序，而不是表格字面顺序。
  assert_eq(stages[0].op.id, "layer-op", msg="第一阶段的算子 id")
  assert_eq(stages[0].layer, "l1", msg="第一阶段应是层算子")
  assert_eq(stages[1].layer, "", msg="第二阶段应是文档级算子")
  assert_eq(stages[1].op.id, "doc-op", msg="第二阶段的算子 id")
  // 文档级算子的 before = 层算子合成回去之后的图（不是合成底图）
  let base = @render.render_doc(doc, env)
  assert_true(!same_buf(stages[1].before, base), msg="文档级 before 应是已改过层的合成图")
  assert_true(same_buf(out, must_render(doc, env, prog)), msg="最终图必须与真渲染一致")
}

///|
test "标签作用域在阶段报告里已展开成具体层：一个标签两条算子两条阶段" {
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  let mut tagged = tag_only(doc, "l1", "hero")
  tagged = tag_only(tagged, "l2", "hero")
  let op : @core.EditOp = { ..rprog_layer(whole16(), 120.0, "@hero").ops[0] }
  let prog : @core.EditProgram = { ops: [op], guards: [] }
  let (stages, _) = stages_of(tagged, env, prog)
  assert_eq(stages.length(), 2, msg="两个层带标签 → 两条阶段")
  assert_eq(stages[0].layer, "l1", msg="层序即顺序（l1 先）")
  assert_eq(stages[1].layer, "l2", msg="层序即顺序（l2 后）")
  assert_eq(stages[0].op.id, "e1", msg="展开后 id 保持不变（同一算子落到两个层）")
}

///|
/// 造一条给定 id / 选择子 / 色相的 recolor 算子（表里每条都要不同 id）。
fn docop(id : String, sel : @core.SelSpec, hue : Double) -> @core.EditOp {
  let o = rprog(sel, hue).ops[0]
  { ..o, id, sel }
}

///|
test "两段式下文档级 stage:n 仍是**表序**：段内重编号不许偷偷换掉取到的缓冲" {
  // 由来：`stage:n` 的声明含义是"**表里**第 n 条算子之后的中间缓冲"，而两段式
  // 渲染把表拆段跑（层段 → 合成 → 文档级段），`run_program` 的 `Stage(n)` 却是
  // **段内**序号。`layer_scope_error` 只检查了"第 n 条是不是文档级算子"，没检查
  // 段内重编号之后那个 n 还指不指着同一条——于是**文档级算子前面插一条层算子，
  // 取到的缓冲就整体前移一格**，而校验、lint、渲染全都不会说话。
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc() // l1 左半红、l2 右半蓝
  // 表（0 基）：0=层算子（唯一作用是让两段式生效）1=a 2=b 3=c
  // `c` 用 stage:2 ⇒ 按表序 = "第 2 条之后" = a 的输出。
  let lay = rprog_layer(whole16(), 120.0, "l1").ops[0]
  let opa = docop("a", whole16(), 10.0)
  let opb = docop("b", whole16(), 200.0)
  let selc : @core.SelSpec = { basis: @core.Stage(2), expr: whole16().expr }
  let opc = docop("c", selc, 300.0)
  let prog : @core.EditProgram = { ops: [lay, opa, opb, opc], guards: [] }
  assert_true(
    @core.layer_scope_error(prog) is None,
    msg="这张表按现有判据是合法的（不然测的就不是这一段）",
  )
  let (stages, _) = stages_of(doc, env, prog)
  // 阶段顺序：层算子（按层序）→ 文档级算子（按表序）
  assert_eq(stages.length(), 4, msg="1 条层阶段 + 3 条文档级阶段")
  assert_eq(stages[1].op.id, "a", msg="文档级阶段按表序")
  assert_eq(stages[3].op.id, "c", msg="文档级阶段按表序")
  // **判别力自证**：两个候选缓冲必须真的不同，否则这条断言会悄悄变成空的。
  assert_true(
    !same_buf(stages[1].after, stages[2].after),
    msg="a 与 b 的输出必须不同（否则'指错了'根本量不出来）",
  )
  // 声明语义：c 的基准 = 表里第 2 条算子之后的缓冲 = a 的输出。
  assert_true(
    same_buf(stages[3].basis, stages[1].after),
    msg="stage:2 必须指表序第 2 条（a）之后的缓冲；指到 b 上就是静默换了像素",
  )
}

///|
test "stage:n 的静态判据要连「前视/自指」一起咬（否则校验放行、渲染才失败）" {
  // `stage:n` 指的是"**表里**第 n 条之后的缓冲"，所以引用者自己的表序是上界：
  // n 必须**严格小于**引用者（0 基 i ⇒ n ≤ i）。此前判据只查了"第 n 条是不是
  // 文档级算子"，漏掉上界——于是 `stage:` 指到自己（或后面那条）时校验放行，
  // 而 `run_program` 在执行期才报"拒绝前视引用"：**命令面收下了、渲染时才失败**，
  // 正是 `validate_program` 开头声明要避免的那件事。
  let opa = docop("a", whole16(), 10.0)
  let opc = docop("c", whole16(), 300.0)
  // 表：[a, b(stage:2), c]；b 自己是第 2 条，stage:2 = "第 2 条之后" = b 的输出
  let b_self = docop("b", { basis: @core.Stage(2), expr: whole16().expr }, 200.0)
  let bad : @core.EditProgram = { ops: [opa, b_self, opc], guards: [] }
  match @core.layer_scope_error(bad) {
    None => abort("自指/前视必须在**静态校验**里拒（否则执行期才报'拒绝前视引用'）")
    Some(e) => {
      assert_true(e.contains("b"), msg="报错要点出是哪条算子：\{e}")
      assert_true(e.contains("STAGE(2)"), msg="报错要回显收到的 n：\{e}")
    }
  }
  // 正控 1：stage:1（第 1 条之后 = a 的输出）对第 2 条算子来说是合法的
  let b_ok = docop("b", { basis: @core.Stage(1), expr: whole16().expr }, 200.0)
  let good : @core.EditProgram = { ops: [opa, b_ok, opc], guards: [] }
  assert_true(
    @core.layer_scope_error(good) is None,
    msg="stage:1 在表序上指向更早的算子，必须放行（判据不许写宽）",
  )
  // 正控 2：stage:0（本段输入）恒放行
  let b_zero = docop("b", { basis: @core.Stage(0), expr: whole16().expr }, 200.0)
  assert_true(
    @core.layer_scope_error({ ops: [opa, b_zero], guards: [] }) is None,
    msg="stage:0 表示本段输入，无歧义，必须放行",
  )
  // 正控 3：**不带 STAGE** 的同形表当然也要放行（否则前两条正控可能是靠别的原因过的）
  assert_true(
    @core.layer_scope_error({ ops: [opa, opc], guards: [] }) is None,
    msg="没有 STAGE 的表必须放行",
  )
}

///|
test "单段路径下 stage:n 的 basis 报告也必须是**真正求值的**那个缓冲" {
  // 与两段式那条同源，但走的是**单段**分支（表里没有层算子）——两条分支各写
  // 一遍"basis 取哪个缓冲"，于是必须各有一条测试守着（变异 Z2 就是拿这条
  // 单段分支做的反例：没有它，单段下把 basis 报成段基准没人会发现）。
  let env = @render.RenderEnv::new()
  let doc = two_tone_doc()
  // 表：[a, b, c(stage:1)]；stage:1 = 表里第 1 条之后 = a 的输出
  //（**不是** c 自己的输入——c 的输入是 b 的输出，这正是这条断言有判别力的原因）
  let opa = docop("a", whole16(), 10.0)
  let opb = docop("b", whole16(), 200.0)
  let opc = docop("c", { basis: @core.Stage(1), expr: whole16().expr }, 300.0)
  let (stages, _) = stages_of(doc, env, { ops: [opa, opb, opc], guards: [] })
  assert_eq(stages.length(), 3, msg="单段：每条算子一个阶段")
  assert_true(
    !same_buf(stages[0].after, stages[1].after),
    msg="判别力自证：a 与 b 的输出必须不同，否则'报错基底'量不出来",
  )
  assert_true(
    same_buf(stages[2].basis, stages[0].after),
    msg="stage:1 的 reported basis 必须是 a 的输出（报成底图就是数字全错而渲染对）",
  )
  assert_true(
    !same_buf(stages[2].basis, stages[1].after),
    msg="不许退化成'报成前一条的输出'（那不是它求值的图）",
  )
}
