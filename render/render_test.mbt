/// 渲染测试：混合公式数值验证（不依赖 golden）、确定性、取景、pick、stats。

///|
/// 4×4 画布：底红矩形 + 顶蓝矩形（可换混合模式）。
fn blend_doc(mode : @core.BlendMode) -> @core.Document {
  let doc = @core.new_document("u-blend", 4, 4)
  let red = @core.default_layer("l1", "red", 0.0, 0.0, 4.0, 4.0)
  let red2 = { ..red, fill: @core.Fill::Solid(0xFF0000FF), blend: @core.BlendMode::Normal }
  let blue = @core.default_layer("l2", "blue", 0.0, 0.0, 4.0, 4.0)
  let blue2 = {
    ..blue,
    fill: @core.Fill::Solid(0xFFFF0000),
    blend: mode,
  }
  doc.layers.push(red2)
  doc.layers.push(blue2)
  doc
}

///|
test "混合公式数值验证：multiply→黑 / screen→品红 / normal→蓝" {
  let env = @render.RenderEnv::new()
  // multiply: 红 × 蓝 = 黑
  let m = @render.render_doc(blend_doc(@core.BlendMode::Multiply), env)
  let pm = @codec.rgba_get(m, 2, 2)
  assert_eq(pm, 0xFF000000)
  // screen: 红 ∪ 蓝 = 品红 (R=255,G=0,B=255)
  let s = @render.render_doc(blend_doc(@core.BlendMode::Screen), env)
  let ps = @codec.rgba_get(s, 2, 2)
  assert_eq(ps, 0xFFFF00FF)
  // normal: 蓝盖红 = 蓝
  let n = @render.render_doc(blend_doc(@core.BlendMode::Normal), env)
  let pn = @codec.rgba_get(n, 2, 2)
  assert_eq(pn, 0xFFFF0000)
}

///|
test "半透明层透明度并入：50% 蓝盖白 → 127/255 蓝" {
  let env = @render.RenderEnv::new()
  let doc = @core.new_document("u-alpha", 4, 4)
  let blue = @core.default_layer("l1", "blue", 0.0, 0.0, 4.0, 4.0)
  let blue2 = {
    ..blue,
    fill: @core.Fill::Solid(0xFF0000FF),
    opacity: 0.5,
    blend: @core.BlendMode::Normal,
  }
  doc.layers.push(blue2)
  let buf = @render.render_doc(doc, env)
  let p = @codec.rgba_get(buf, 1, 1)
  let a = (p >> 24) & 0xFF
  let r = (p >> 16) & 0xFF // R 通道（0xAARRGGBB 打包，R 在次高字节）
  let b = p & 0xFF
  assert_eq(a, 255)
  assert_eq(b, 255) // 蓝通道全量
  // 白底 50% 蓝：R = G = 127~128（浮点取整容差 1）
  assert_true(r >= 126 && r <= 129, msg="R=\{r}")
}

///|
test "合成：半透明 src over 半透明 dst 必须去预乘" {
  // 已有的混合测试全用**不透明**层（alpha=255）：此时 ao=1、预乘即直通，
  // "去预乘"那一步对结果毫无影响——把它换成"直接返回预乘值"，全部测试通过。
  // 半透明合成因此没人守护（颜色整片偏暗）。这里锁住 W3C 公式的数值：
  //   dst=0x80000000（半透明黑）、src=0x80FFFFFF（半透明白）、Normal
  //   sa = da = 128/255
  //   ao  = sa + da(1-sa)          = 0.75198 → A = 192 = 0xC0
  //   o_r = sa(1-da)sr + sa·da·sr  = 0.50198
  //   r   = o_r / ao               = 0.66755 → 170 = 0xAA   ← 去预乘
  //   （不去预乘会得到 128 = 0x80）
  assert_eq(
    @render.composite_pixel(0x80000000, 0x80FFFFFF, @core.BlendMode::Normal),
    0xC0AAAAAA,
    msg="半透明合成必须去预乘（否则整片偏暗）",
  )
  // 双方不透明时预乘即直通——这条保证上面的差异确实来自去预乘那一步
  assert_eq(
    @render.composite_pixel(0xFF000000, 0xFF808080, @core.BlendMode::Normal),
    0xFF808080,
  )
}

///|
test "边界去污染在合成底图上没有唯一解（α 在合成时就丢了）" {
  // 这是"recolor 的边界带去污染（I = αF + (1−α)B，只改 F）为什么不能
  // 在编辑表里做"的**判定性事实**，不是猜测：
  //   场景 A：不透明白底 + 50% 不透明度的纯红层
  //   场景 B：本来就画了一笔不透明粉红 #FF7F7F
  let from_layers = @render.composite_pixel(
    0xFFFFFFFF,
    0x80FF0000,
    @core.BlendMode::Normal,
  )
  assert_eq(
    from_layers,
    0xFFFF7F7F,
    msg="白底 + 50% 红必须与纯粉红逐位相同——这正是信息丢失",
  )
  // 底图上两者一模一样。于是"把这个像素的前景红改成绿、保持与白底各半
  // 的混合"没有唯一解：引擎无从知道背后是 (α=0.5, F=红, B=白) 还是
  // (α=1, F=粉红, B=任意)。
  //
  // 反演 I = αF + (1−α)B 需要**同时**知道 α 与 B，而 α 在层合成那一刻
  // 就被乘掉了。所以去污染不可能在"编辑表作用于合成底图"的架构里实现；
  // 它的前置条件是**图层级编辑**——那时图层的 α 与它下方的合成结果都已知。
  // 这条测试若失败，说明合成公式变了，上面这段论证的前提也要重审。
}

///|
test "椭圆 + 渐变 + 旋转 golden 渲染确定性" {
  let doc = @core.new_document("u-golden", 64, 64)
  let bg = @core.default_layer("l1", "bg", 0.0, 0.0, 64.0, 64.0)
  let bg2 = { ..bg, fill: @core.Fill::Solid(0x1B2A41FF) }
  let orb = @core.default_layer("l2", "orb", 12.0, 12.0, 40.0, 40.0)
  let orb2 = {
    ..orb,
    kind: @core.ShapeKind::Ellipse,
    fill: @core.Fill::LinearGradient(0xFF7A45FF, 0x2E6FE8FF, 0.0, 0.0, 1.0, 1.0),
  }
  let bar = @core.default_layer("l3", "bar", 8.0, 52.0, 48.0, 4.0)
  let bar2 = {
    ..bar,
    kind: @core.ShapeKind::Rect,
    corner_radius: 2.0,
    fill: @core.Fill::Solid(0x33CC66FF),
    blend: @core.BlendMode::Screen,
  }
  let rot = @core.default_layer("l4", "tilt", 20.0, 4.0, 24.0, 8.0)
  let rot2 = {
    ..rot,
    rotation_deg: 30.0,
    fill: @core.Fill::NoFill,
    stroke: { color: 0xFFFFFFAA, width: 2.0 },
  }
  doc.layers.push(bg2)
  doc.layers.push(orb2)
  doc.layers.push(bar2)
  doc.layers.push(rot2)
  let env = @render.RenderEnv::new()
  let png1 = @codec.png_encode(@render.render_doc(doc, env))
  let png2 = @codec.png_encode(@render.render_doc(doc, env))
  assert_eq(png1.length(), png2.length())
  let mut i = 0
  while i < png1.length() {
    assert_eq(png1[i].to_int(), png2[i].to_int())
    i = i + 1
  }
  let hash = @base.sha256_hex(png1)
  // golden：固定样例场景的渲染指纹（同引擎版本内必须稳定）
  assert_eq(hash, "9caa1c1d52d6297e5a802733850c1252a981abbd2fc4458e27e765578e9e5195")
}

///|
test "pick：上层命中返回上层 id，空白返回 None" {
  let doc = @core.new_document("u-pick", 100, 100)
  let a = @core.default_layer("l1", "a", 10.0, 10.0, 50.0, 50.0)
  let a2 = { ..a, fill: @core.Fill::Solid(0xFF0000FF) }
  let b = @core.default_layer("l2", "b", 30.0, 30.0, 50.0, 50.0)
  let b2 = { ..b, fill: @core.Fill::Solid(0xFF00FF00) }
  doc.layers.push(a2)
  doc.layers.push(b2)
  // (40,40) 同时命中两层 → 顶层 l2
  assert_eq(@render.pick(doc, 40.0, 40.0), Some("l2"))
  // (15,15) 只在 a 内
  assert_eq(@render.pick(doc, 15.0, 15.0), Some("l1"))
  // (5,5) 都不在
  assert_true(@render.pick(doc, 5.0, 5.0) is None)
}

///|
test "render_view：取景裁剪 + 缩放尺寸正确，角点像素与全图一致" {
  let doc = @core.new_document("u-view", 100, 100)
  let a = @core.default_layer("l1", "a", 50.0, 0.0, 50.0, 100.0)
  let a2 = { ..a, fill: @core.Fill::Solid(0xFF0000FF) } // 右半蓝，左半白
  doc.layers.push(a2)
  let env = @render.RenderEnv::new()
  let view = match @render.render_view(doc, env, 0.5, 0.0, 1.0, 1.0, 20) {
    Ok(v) => v
    Err(e) => abort("render_view 失败: \{e}")
  }
  assert_eq(view.width, 20)
  // 视口区域是 50×100（竖长），按宽度 20 等比 → 高 40
  assert_eq(view.height, 40)
  // 右半取景：全部应为蓝
  assert_eq(@codec.rgba_get(view, 10, 10), 0xFF0000FF)
  // 非法 viewport 拒绝
  assert_true(
    match @render.render_view(doc, env, 0.9, 0.0, 0.1, 1.0, 10) {
      Err(_) => true
      Ok(_) => false
    },
  )
}

///|
test "stats：直方图 JSON 形态与全覆盖计数" {
  let doc = @core.new_document("u-stats", 8, 8)
  let a = @core.default_layer("l1", "a", 0.0, 0.0, 8.0, 8.0)
  let a2 = { ..a, fill: @core.Fill::Solid(0xFF336699) }
  doc.layers.push(a2)
  let env = @render.RenderEnv::new()
  let s = @render.stats(@render.render_doc(doc, env))
  assert_true(s.has_prefix("{\"total\":64,\"opaque_px\":64"))
  assert_true(s.has_suffix("]}"))
}
