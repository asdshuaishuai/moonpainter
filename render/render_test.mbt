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
test "层合成底图 = 不透明白底 + 图层（MVSL 编辑表的输入前提）" {
  // 上一条验了"图层覆盖处"的白底混合；这条验**没被任何图层覆盖的角落**，
  // 把管线语义整体钉住：底图 = 铺满的不透明白底 + 图层。
  //
  // 为什么值得单独一条：MVSL 编辑表的输入就是这个底图，所以
  //   - 编辑表**处理不到半透明像素**（底图 alpha 恒 255）；
  //   - "recolor 的边界去污染在合成底图上无解"的理由比"α 难以恢复"更强：
  //     前景覆盖率 α 在铺白底这一刻就**从未存在过**。
  // 如果哪天有人去掉 `render_layers` 里的白底，图层覆盖处可能仍"看起来
  // 差不多"（合成数学还在），但未覆盖区会立刻露馅。
  let env = @render.RenderEnv::new()
  let doc = @core.new_document("u-opaque", 6, 6)
  let l = @core.default_layer("l1", "half", 1.0, 1.0, 2.0, 2.0)
  doc.layers.push({ ..l, fill: @core.Fill::Solid(0xFF0000FF), opacity: 0.5 })
  let buf = @render.render_layers(doc, env)
  // 未覆盖的角落是不透明白（不是透明、不是黑）
  assert_eq(@codec.rgba_get(buf, 5, 5), 0xFFFFFFFF, msg="未覆盖区应是白底")
  assert_eq(@codec.rgba_get(buf, 0, 0), 0xFFFFFFFF, msg="未覆盖区应是白底")
  // 整幅图没有任何半透明像素
  let mut translucent = 0
  let mut i = 0
  while i < buf.width * buf.height {
    if ((buf.pixels[i] >> 24) & 0xFF) != 255 {
      translucent = translucent + 1
    }
    i = i + 1
  }
  assert_eq(translucent, 0, msg="底图出现半透明像素——MVSL 的输入前提被破坏")
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
  //
  // 这个值在「填充/描边的自带 alpha 真正生效」那次修复后变过一次：
  // 场景里 `rot2` 的描边是 `0xFFFFFFAA`（alpha=0xAA 的半透明白），而修复前
  // 那个 alpha 被 `color & 0x00FFFFFF` 丢掉了——即 goldne 记录的其实是
  // "不透明白描边"的画面。是一次**有意为之**的变更，不是漂移。
  assert_eq(hash, "c3c7b4e162438b7b6097c591f0c23c4cc3d1f101b4086be29a1ef3a479b9032d")
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

///|
test "填充色自带的 alpha 生效：50% 红压白底 = 255/127/127" {
  // `Fill::Solid(0xAARRGGBB)` 的类型注释与工具面的 `fill: #RRGGBB[AA]` 都
  // 承诺了这个 alpha，但 `paint_layer` 曾经 `color & 0x00FFFFFF` 把它丢掉：
  // `fill=#FF000080`（半透明红）渲染成**完全不透明红**，而且不报错。
  // 当时仓库里没有任何测试用半透明填充（命令面文本形式一处都没有，数值常量
  // 也只在一条 golden 里间接沾到一次），所以这个缺口一直没人踩到。
  let doc = @core.new_document("u-alpha", 8, 8)
  let base = @core.default_layer("l", "l", 0.0, 0.0, 8.0, 8.0)
  doc.layers.push({ ..base, fill: @core.Fill::Solid(0x80FF0000) })
  let env = @render.RenderEnv::new()
  let buf = @render.render_doc(doc, env)
  // 白底 + 50% 红 → G/B 通道 = 255 × 0.5 ≈ 127
  assert_eq(@codec.rgba_get(buf, 4, 4), 0xFFFF7F7F)
}

///|
test "描边色自带的 alpha 也生效：50% 蓝压白底 = 127/127/255" {
  let doc = @core.new_document("u-alpha2", 8, 8)
  let base = @core.default_layer("l", "l", 0.0, 0.0, 8.0, 8.0)
  doc.layers.push({
    ..base,
    fill: @core.Fill::NoFill,
    stroke: { color: 0x800000FF, width: 8.0 },
  })
  let env = @render.RenderEnv::new()
  let buf = @render.render_doc(doc, env)
  assert_eq(@codec.rgba_get(buf, 4, 4), 0xFF7F7FFF)
}

///|
test "不透明填充的输出不变（alpha=FF 是绝大多数路径）" {
  // 上一条修复不能把"本来就不透明"的常规路径也改掉。
  let doc = @core.new_document("u-alpha3", 8, 8)
  let base = @core.default_layer("l", "l", 0.0, 0.0, 8.0, 8.0)
  doc.layers.push({ ..base, fill: @core.Fill::Solid(0xFFFF0000) })
  let env = @render.RenderEnv::new()
  let buf = @render.render_doc(doc, env)
  assert_eq(@codec.rgba_get(buf, 4, 4), 0xFFFF0000)
  // 25% / 75% 两个中间档也对得上（量化取整要一致）
  let d2 = @core.new_document("u-alpha4", 8, 8)
  let b2 = @core.default_layer("l", "l", 0.0, 0.0, 8.0, 8.0)
  d2.layers.push({ ..b2, fill: @core.Fill::Solid(0x40FF0000) })
  let buf2 = @render.render_doc(d2, env)
  // 25% 红 + 75% 白 → R 仍是 255，G/B = 255 × 0.75 ≈ 191
  assert_eq(@codec.rgba_get(buf2, 4, 4), 0xFFFFBFBF)
}

///|
test "pick：只报「真的在那里画了东西」的层（与 paint_layer 同一套语义）" {
  // 老实现走压平的 `all_layers` 且只查 `visible`，于是三类层会被报成
  // "在那里"而实际一个像素都没画。`sample` 同时回颜色与层 id，
  // 两个字段会当场互相矛盾（实测 `color=#FFFFFFFF`（白纸）+ `layer=l1`）。
  // 这一组用例把每一类各钉一条。
  // 1) 自身 opacity=0
  let d1 = @core.new_document("u-pick-ghost", 100, 100)
  d1.layers.push({ ..@core.default_layer("g", "g", 0.0, 0.0, 100.0, 100.0), opacity: 0.0 })
  assert_true(@render.pick(d1, 50.0, 50.0) is None)
  // 2) 隐藏组的子层（子层自身 visible=true，但组不可见 → 画不出来）
  let d2 = @core.new_document("u-pick-hide", 100, 100)
  let kid = @core.default_layer("kid", "k", 0.0, 0.0, 40.0, 40.0)
  d2.layers.push(
    { ..@core.default_layer("grp", "G", 0.0, 0.0, 40.0, 40.0), kind: @core.ShapeKind::Group, children: [kid], visible: false },
  )
  assert_true(@render.pick(d2, 10.0, 10.0) is None)
  // 3) 组 opacity=0（子层自身不透明，但继承下来是 0）
  let d3 = @core.new_document("u-pick-gop", 100, 100)
  d3.layers.push(
    { ..@core.default_layer("grp", "G", 0.0, 0.0, 40.0, 40.0), kind: @core.ShapeKind::Group, children: [kid], opacity: 0.0 },
  )
  assert_true(@render.pick(d3, 10.0, 10.0) is None)
  // 4) 蒙版盖不到的点（层在那里不画；蒙版内的点照常命中）
  let d4 = @core.new_document("u-pick-mask", 100, 100)
  d4.layers.push(
    {
      ..@core.default_layer("m", "m", 0.0, 0.0, 60.0, 60.0),
      mask: Some(@core.LayerMask::{ kind: @core.ShapeKind::Rect, x: 0.0, y: 0.0, w: 10.0, h: 10.0, radius: 0.0, feather: 0.0, roughen: 0.0, invert: false, points: [] }),
    },
  )
  assert_true(@render.pick(d4, 40.0, 40.0) is None, msg="蒙版外的点不算「在那里」")
  assert_eq(@render.pick(d4, 5.0, 5.0), Some("m"), msg="蒙版内仍应命中")
  // 5) raster 层：只在笔触覆盖处算「有东西」，erase 过的地方不算
  let d5 = @core.new_document("u-pick-dab", 100, 100)
  let dab = @core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFF0000FF, erase: false, clone: false, sdx: 0.0, sdy: 0.0 }
  let era = @core.Dab::{ x: 60.0, y: 20.0, r: 6.0, color: 0x00000000, erase: true, clone: false, sdx: 0.0, sdy: 0.0 }
  let painted = @core.Dab::{ x: 60.0, y: 20.0, r: 6.0, color: 0xFF00FF00, erase: false, clone: false, sdx: 0.0, sdy: 0.0 }
  d5.layers.push(
    { ..@core.default_layer("r", "r", 0.0, 0.0, 100.0, 100.0), kind: @core.ShapeKind::Raster, dabs: [dab, painted, era] },
  )
  assert_eq(@render.pick(d5, 20.0, 20.0), Some("r"), msg="笔触处应命中 raster 层")
  assert_true(@render.pick(d5, 60.0, 20.0) is None, msg="最后落的是 erase，那里没有东西")
  assert_true(@render.pick(d5, 90.0, 90.0) is None, msg="没落过笔的地方不算")
  // 6) 非回归：上层命中上层、空白 None（且调整层无面不挡下层）
  let d6 = @core.new_document("u-pick-reg", 100, 100)
  d6.layers.push(@core.default_layer("l1", "a", 0.0, 0.0, 40.0, 40.0))
  d6.layers.push(
    { ..@core.default_layer("adj", "A", 0.0, 0.0, 100.0, 100.0), kind: @core.ShapeKind::Adjust, adjust: Some(@core.Adjust::{ op: @core.AdjustOp::Brightness, value: 0.2 }) },
  )
  assert_eq(@render.pick(d6, 10.0, 10.0), Some("l1"), msg="调整层无面，不该挡住下面的层")
  assert_true(@render.pick(d6, 90.0, 90.0) is None)
}

///|
test "pick 与 paint_layer 同窗：渲染窗外、画布外的点都不报（判据不许比渲染器松）" {
  // 实测的两个矛盾（都是"报出来的 id 不对应真实产物"）：
  //  ① 画布 20×20 上放 100×100 的矩形 → `pick 30 10` 报 r1，而 `sample 30 10`
  //     直接报"超出画布" —— 同一个点两个命令两种答案；
  //  ② `add-polygon w=10 h=10 points=0,0;50,0;50,50`（渲染窗只到 x≤14）
  //     → `pick 30 10` 报 p1，而那里 probe 出来是白纸。
  // 修法是把窗提成 `paint_window` 一处实现，`paint_layer` 与 `pick` 共用。
  let env = @render.RenderEnv::new()
  // ① 画布边界
  let d1 = @core.new_document("big-rect", 20, 20)
  let r = @core.default_layer("r1", "r1", 0.0, 0.0, 100.0, 100.0)
  d1.layers.push({ ..r, fill: @core.Fill::Solid(0xFFFF0000) })
  assert_eq(@render.pick(d1, 19.0, 19.0), Some("r1"))
  assert_eq(@render.pick(d1, 30.0, 10.0), None)
  assert_eq(@render.pick(d1, -1.0, 5.0), None)
  // ② 渲染窗：10×10 盒 + 顶点伸到 50 的三角（窗 = [-4,14)²）
  let d2 = @core.new_document("wide-tri", 60, 60)
  let p = @core.default_layer("p1", "p1", 0.0, 0.0, 10.0, 10.0)
  d2.layers.push({
    ..p,
    kind: @core.ShapeKind::Polygon,
    fill: @core.Fill::Solid(0xFF00FF00),
    points: [(0.0, 0.0), (50.0, 0.0), (50.0, 50.0)],
  })
  let buf = @render.render_doc(d2, env)
  // 窗内：有墨的地方必须拾得到（判据也不许比渲染器**严**）
  // (5,1) 是严格内部点（斜边是 y=x，(5,5) 恰好压在边上 → 抗锯齿淡绿）
  assert_eq(@codec.rgba_get(buf, 5, 1), 0xFF00FF00)
  assert_eq(@render.pick(d2, 5.0, 1.0), Some("p1"))
  // 边缘像素是抗锯齿后的淡绿（非纯色），只断言"有墨"
  assert_true(@codec.rgba_get(buf, 12, 2) != 0xFFFFFFFF, msg="(12,2) 该有墨")
  assert_eq(@render.pick(d2, 12.0, 2.0), Some("p1"))
  // 窗外：没有墨的地方一个都不许报（13,2 有墨、15,2 没有，逐点对照）
  assert_true(@codec.rgba_get(buf, 13, 2) != 0xFFFFFFFF, msg="(13,2) 该有墨")
  assert_eq(@render.pick(d2, 13.0, 2.0), Some("p1"))
  assert_eq(@codec.rgba_get(buf, 15, 2), 0xFFFFFFFF)
  assert_eq(@render.pick(d2, 15.0, 2.0), None)
  assert_eq(@codec.rgba_get(buf, 30, 10), 0xFFFFFFFF)
  assert_eq(@render.pick(d2, 30.0, 10.0), None)
}

///|
test "to_canvas 是 to_local 的逆（旋转 + 双向翻转都往返一致）" {
  // 正/逆变换分开写就有一边先烂：lint 要用 to_canvas 把局部顶点换成画布坐标
  // 再与渲染窗比，逆变换写错 → 误报/漏报。这里锁住两者互逆。
  let mut l = @core.default_layer("l1", "l1", 7.0, 13.0, 40.0, 20.0)
  l = { ..l, rotation_deg: 30.0, flip_h: true, flip_v: true }
  let pts : Array[(Double, Double)] = [
    (0.0, 0.0),
    (40.0, 0.0),
    (40.0, 20.0),
    (0.0, 20.0),
    (13.5, 7.25),
  ]
  // 容差按实测精度定：`cos_rad`/`sin_rad` 是**级数近似**（不是 stdlib），
  // 30° 往返实测差 ~1.7e-6 —— 这是近似的精度，不是变换写错。真正写错
  // （符号/顺序/少一步 flip）差的是 O(1)~O(10)，0.0001 咬得住。
  for p in pts {
    let c = @render.to_canvas(l, p.0, p.1)
    let back = @render.to_local(l, c.0, c.1)
    let dx = back.0 - p.0
    let dy = back.1 - p.1
    let ax = if dx < 0.0 { -dx } else { dx }
    let ay = if dy < 0.0 { -dy } else { dy }
    let d = ax + ay
    assert_true(d < 0.0001, msg="往返不一致：\{p.0},\{p.1} → \{back.0},\{back.1}")
  }
  // 旋转 0 + 不翻转时就是简单的平移（正控：别把最简情形算错）
  let l2 = @core.default_layer("l2", "l2", 5.0, 6.0, 10.0, 10.0)
  let c2 = @render.to_canvas(l2, 1.0, 2.0)
  assert_eq(c2.0, 6.0)
  assert_eq(c2.1, 8.0)
}


///|
test "毛边蒙版进真渲染管线：边界被啃动、深处不动、pick 与渲染同一把尺子" {
  // 白盒那几条测的是 `mask_cover_at`，这条测**它真的被渲染管线用上**：
  // 同一份文档只改 `roughen`，渲染产物必须不同（不是"存了但没人读"），
  // 而且差别只出现在蒙版边界附近（不能把整块啃穿）。
  let w = 48
  let h = 48
  let mk = fn(rough : Double) -> @core.Document {
    let d = @core.new_document("u-rough", w, h)
    let m : @core.LayerMask = {
      kind: @core.ShapeKind::Rect,
      x: 8.0,
      y: 8.0,
      w: 32.0,
      h: 32.0,
      radius: 0.0,
      feather: 0.0,
      roughen: rough,
      invert: false,
      points: [],
    }
    d.layers.push(
      {
        ..@core.default_layer("r", "r", 0.0, 0.0, w.to_double(), h.to_double()),
        mask: Some(m),
      },
    )
    d
  }
  let env = @render.RenderEnv::new()
  let smooth = @render.render_doc(mk(0.0), env)
  let rough = @render.render_doc(mk(3.0), env)
  let mut changed = 0
  let mut deep_bad = 0
  let mut y = 0
  while y < h {
    let mut x = 0
    while x < w {
      let a = @codec.rgba_get(smooth, x, y)
      let b = @codec.rgba_get(rough, x, y)
      if a != b {
        changed = changed + 1
      }
      // 离边界 (>3px) 的内部点：两版都必须是不透明的红（蒙版内满覆盖）
      let px = x.to_double() + 0.5
      let py = y.to_double() + 0.5
      if px >= 12.0 && px <= 36.0 && py >= 12.0 && py <= 36.0 && a != b {
        deep_bad = deep_bad + 1
      }
      x = x + 1
    }
    y = y + 1
  }
  assert_true(changed > 20, msg="毛边必须真的改变渲染产物，实际只改了 \{changed} 个像素")
  assert_eq(deep_bad, 0, msg="毛边只许啃边界（幅度 3 < 4），深处不许变")
  // 确定性：同一份文档渲染两次逐位一致（噪声里不许有随机数/时间戳）
  let again = @render.render_doc(mk(3.0), env)
  assert_eq(
    @base.sha256_hex(@codec.png_encode(rough)),
    @base.sha256_hex(@codec.png_encode(again)),
    msg="毛边渲染必须可复现",
  )
  // `pick` 走的是同一个 `mask_cover_at`（一处实现）：在**被啃掉**的那个像素上
  // pick 必须说"这里没有东西"，与渲染产物一致——判据不许比渲染器松。
  let mut flipped_at : (Int, Int) = (0 - 1, 0 - 1)
  let mut fy = 0
  while fy < h && flipped_at.0 < 0 {
    let mut fx = 0
    while fx < w && flipped_at.0 < 0 {
      let a = @codec.rgba_get(smooth, fx, fy)
      let b = @codec.rgba_get(rough, fx, fy)
      // 平滑版有墨、毛边版被啃成透明（透明 = 全 0 alpha，画布底是白 → 找"变了"的边界点）
      if a != b {
        flipped_at = (fx, fy)
      }
      fx = fx + 1
    }
    fy = fy + 1
  }
  assert_true(flipped_at.0 >= 0, msg="应能找到至少一个被毛边改动的像素")
  let rough_pick = @render.pick(mk(3.0), flipped_at.0.to_double(), flipped_at.1.to_double())
  let ink = @codec.rgba_get(rough, flipped_at.0, flipped_at.1)
  let has_ink = ((ink >> 24) & 0xFF) != 0
  assert_eq(
    rough_pick is Some(_),
    has_ink,
    msg="pick 与渲染必须同一把尺子（同一像素上不能一个说有、一个说没有）",
  )
}
///|
test "渲染上限：超过 4096 的画布被截到左上角（命令面已拒，这里守兜底那半）" {
  // 命令面（`new`/`set-canvas`）现在直接拒绝超限画布，所以这种文档只剩两条
  // 来路：手改容器、或旧版本产物。它到渲染器这时**仍然会被截断**——这是
  // 有意的兜底（宁可裁掉也不要一次分配几 GB），但必须**可测**：
  // 少了这一格，"把 render_size 的截断去掉"这条变异没人抓得住
  // （现有测试里的画布全都 ≤ 4096，截断与不截断逐位相同）。
  let doc = @core.new_document("render-size-clamp", 5000, 200)
  let far = @core.default_layer("d1", "far", 4500.0, 0.0, 100.0, 100.0)
  doc.layers.push(far)
  let buf = @render.render_layers(doc, @render.RenderEnv::new())
  assert_eq(buf.width, 4096, msg="宽必须截到上限")
  assert_eq(buf.height, 200, msg="没超的那一边一个字都不许动")
  // 恰好等于上限的文档必须**逐位不变**（不许把判据写成 `>=`）
  let ok = @core.new_document("render-size-ok", 4096, 200)
  let okbuf = @render.render_layers(ok, @render.RenderEnv::new())
  assert_eq(okbuf.width, 4096, msg="4096 就是上限本身，必须放行")
  // 纯函数的边界（与上面同源，一处实现）
  let (w1, h1) = @render.render_size(5000, 200)
  assert_true(w1 == 4096 && h1 == 200, msg="render_size 宽截断")
  let (w2, h2) = @render.render_size(200, 5000)
  assert_true(w2 == 200 && h2 == 4096, msg="render_size 高截断")
  let (w3, h3) = @render.render_size(300, 400)
  assert_true(w3 == 300 && h3 == 400, msg="没超的一边不许动")
}
