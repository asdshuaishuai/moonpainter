/// canonical JSON 与指纹测试：往返一致、字节确定、坏输入精确拒绝。

///|
fn make_sample() -> @core.Document {
  let doc = @core.new_document("uuid-test-0001", 800, 600)
  let bg = @core.default_layer("l1", "background", 0.0, 0.0, 800.0, 600.0)
  let bg2 = {
    ..bg,
    fill: @core.Fill::Solid(0x1B2A41FF),
    tags: ["background"],
    // 蒙版字段此前**一个都没有覆盖**：把 `mask_of` 里的 x/w/radius/feather/
    // invert 逐个换成常量，197 个测试全过（行为是对的，只是没人守着）。
    // 这类字段最危险——round 17/18 修的正是"蒙版参数存下来却没人读"，
    // 同样的回归再来一次，测试会一声不响。
    // 这个蒙版取**多边形**且带非默认顶点：canonical 往返只有对"样本里取了非默认值"
    // 的字段才成立（铁律 1）——`points` 若留空，把解析写成常量也没人抓得住。
    mask: Some({
      kind: @core.ShapeKind::Polygon,
      x: 12.5,
      y: 13.25,
      w: 100.0,
      h: 90.5,
      radius: 8.0,
      feather: 3.5,
      roughen: 2.25,
      invert: true,
      points: [(0.0, 0.0), (100.0, 0.0), (50.0, 90.5)],
    }),
  }
  let circle = @core.default_layer("l2", "hero orb", 300.0, 140.0, 200.0, 200.0)
  let circle2 = {
    ..circle,
    kind: @core.ShapeKind::Ellipse,
    fill: @core.Fill::LinearGradient(
      0xFF7A45FF,
      0x2E6FE8FF,
      0.0,
      0.0,
      1.0,
      1.0,
    ),
    stroke: { color: 0xFFFFFFCC, width: 3.5 },
    opacity: 0.9,
    blend: @core.BlendMode::Screen,
    // **这几个字段必须在这里出现**，否则"往返字节一致"这条最强的性质对它们
    // 是瞎的：`visible` 曾因为样本里全是默认的 true，值被写成常量都没有测试
    // 会红（实测：把解析改成恒 true，197 个测试全过）。
    // 规则：canonical 往返的样本必须让每个字段都取**非默认值**。
    visible: false,
    rotation_deg: 15.5,
    corner_radius: 6.0,
    flip_h: true,
    flip_v: true,
  }
  let poly = @core.default_layer("l4", "arrow", 60.0, 60.0, 120.0, 80.0)
  let poly2 = {
    ..poly,
    kind: @core.ShapeKind::Polygon,
    points: [(0.0, 0.0), (120.0, 40.0), (0.0, 80.0)],
    fill: @core.Fill::Solid(0x33CC66FF),
  }
  let line = @core.default_layer("l5", "baseline", 60.0, 160.0, 200.0, 2.0)
  let line2 = {
    ..line,
    kind: @core.ShapeKind::Line,
    points: [(0.0, 1.0), (200.0, 1.0)],
    fill: @core.Fill::NoFill,
    stroke: { color: 0xFFFFFFFF, width: 2.0 },
  }
  // **Raster 层此前在样本里根本没有** ⇒ `dabs` 整个字段（含克隆三字段）的
  // canonical 往返没人守：把 `clone` 读成常量 false、`sdx/sdy` 读成 0，
  // 画面会从"克隆取样"退化成"一块死色"，而往返测试照样绿。
  let ras = @core.default_layer("l6", "retouch", 10.0, 20.0, 30.0, 40.0)
  let ras2 = {
    ..ras,
    kind: @core.ShapeKind::Raster,
    dabs: [
      {
        x: 12.5,
        y: 13.25,
        r: 4.5,
        color: 0x11223344,
        erase: false,
        clone: true,
        sdx: -30.5,
        sdy: 7.25,
      },
      { x: 5.0, y: 6.0, r: 2.0, color: 0xFF00FF00, erase: true, clone: false, sdx: 0.0, sdy: 0.0 },
    ],
  }
  let g = @core.default_layer("l3", "frame", 40.0, 40.0, 720.0, 520.0)
  let g2 = { ..g, kind: @core.ShapeKind::Group, children: [poly2, line2] }
  doc.layers.push(bg2)
  doc.layers.push(circle2)
  doc.layers.push(g2)
  doc.layers.push(ras2)
  doc.assets.push({ hash: "abc123", width: 64, height: 48 })
  doc.params.push({ name: "palette.primary", value: "#FF7A45" })
  doc.next_layer_no = 6
  doc
}

///|
test "canonical JSON 往返：序列化 → 反解 → 再序列化字节一致" {
  let doc = make_sample()
  let j1 = @core.doc_to_json(doc)
  let back = match @core.doc_from_json(j1) {
    Ok(d) => d
    Err(e) => abort("反解失败: \{e}")
  }
  let j2 = @core.doc_to_json(back)
  assert_eq(j2, j1)
}

///|
test "canonical 序列化与指纹确定性" {
  let doc = make_sample()
  let a = @core.doc_to_json(doc)
  let b = @core.doc_to_json(doc)
  assert_eq(a, b)
  assert_eq(@core.fingerprint(doc).length(), 64)
  assert_eq(@core.fingerprint(doc), @core.fingerprint(doc))
  // 内容变化 → 指纹变化
  let doc2 = make_sample()
  let changed = {
    ..doc2.layers[0],
    fill: @core.Fill::Solid(0xFF0000FF),
  }
  doc2.layers[0] = changed
  assert_true(@core.fingerprint(doc2) != @core.fingerprint(doc))
}

///|
test "往返后结构与语义字段保真" {
  let doc = make_sample()
  let back = match @core.doc_from_json(@core.doc_to_json(doc)) {
    Ok(d) => d
    Err(e) => abort("反解失败: \{e}")
  }
  assert_eq(back.width, 800)
  assert_eq(back.height, 600)
  assert_eq(back.uuid, "uuid-test-0001")
  assert_eq(back.next_layer_no, 6)
  assert_eq(back.layers.length(), 4)
  // 克隆笔触逐个字段保真：这几个字段"写得出、读不回"的表现是画面从克隆取样
  // 退化成一块死色（而往返字节一致照样成立——两边都错成默认值）
  match back.layers[3].dabs {
    [d0, d1] => {
      assert_true(d0.clone, msg="clone 标志必须往返保真")
      assert_eq(d0.sdx, -30.5, msg="源偏移 dx（画布向量）必须往返保真")
      assert_eq(d0.sdy, 7.25, msg="源偏移 dy")
      assert_eq(d0.r, 4.5)
      assert_eq(d0.color, 0x11223344)
      assert_true(d1.erase, msg="同一层的橡皮笔触也要保真")
      assert_true(!d1.clone, msg="非克隆笔触不许被读成克隆")
    }
    other => abort("笔触数量不对：\{other.length()}")
  }
  // 蒙版字段必须逐个保真（此前它们连一条断言都没有）
  match back.layers[0].mask {
    Some(m) => {
      assert_true(m.kind is @core.ShapeKind::Polygon)
      // 顶点也要逐个保真：新字段最容易"写得出、读不回"
      assert_eq(m.points.length(), 3)
      assert_eq(m.points[2], (50.0, 90.5))
      assert_eq(m.x, 12.5)
      assert_eq(m.y, 13.25)
      assert_eq(m.w, 100.0)
      assert_eq(m.h, 90.5)
      assert_eq(m.radius, 8.0)
      assert_eq(m.feather, 3.5)
      assert_eq(m.roughen, 2.25, msg="毛边幅度必须往返保真（默认值样本会掩盖解析错误）")
      assert_eq(m.invert, true)
    }
    None => abort("bg 层的蒙版在往返里丢了")
  }
  let g = back.layers[2]
  assert_true(g.kind is @core.ShapeKind::Group)
  assert_eq(g.children.length(), 2)
  assert_eq(g.children[0].points.length(), 3)
  let circle = back.layers[1]
  match circle.fill {
    @core.Fill::LinearGradient(_, _, _, _, _, _) => assert_true(true)
    _ => abort("circle.fill 应为 LinearGradient")
  }
  assert_eq(circle.stroke.width, 3.5)
  assert_true(circle.blend is @core.BlendMode::Screen)
  // 这几个字段曾经在样本里全是默认值，于是"往返保真"对它们是空的
  assert_eq(circle.visible, false, msg="隐藏状态必须往返")
  assert_eq(circle.rotation_deg, 15.5)
  assert_eq(circle.corner_radius, 6.0)
  assert_true(circle.flip_h)
  assert_true(circle.flip_v)
  assert_eq(back.params[0].name, "palette.primary")
  assert_eq(back.assets[0].hash, "abc123")
}

///|
test "坏 JSON / 坏 format / 前向版本 全部精确拒绝" {
  match @core.doc_from_json("{not json") {
    Err(msg) => assert_true(msg.length() > 0)
    Ok(_) => abort("坏 JSON 不该通过")
  }
  match @core.doc_from_json("{\"format\":\"other.doc\",\"version\":1}") {
    Err(msg) => assert_true(msg.length() > 0)
    Ok(_) => abort("坏 format 不该通过")
  }
  let future = "{\"format\":\"moonpainter.doc\",\"version\":99,\"uuid\":\"u\",\"width\":1,\"height\":1,\"dpi\":72,\"profile\":\"srgb\",\"next_layer_no\":1,\"assets\":[],\"params\":[],\"layers\":[]}"
  match @core.doc_from_json(future) {
    Err(msg) => assert_true(msg.length() > 0)
    Ok(_) => abort("未来版本不该通过")
  }
}

///|
test "蒙版 kind 认不出来必须报错，不许静默当成「没有蒙版」" {
  // 原来的行为：`mask_of` 遇到不认识的 kind 返回 `None` —— 引擎说"打开成功"，
  // 然后把整层**当没有蒙版**画出来（整层露出），而指纹又对不上。三个信号
  // 互相矛盾，且没有任何一个字告诉调用方问题出在蒙版上。
  // 这同时是新增蒙版种类的**兼容前提**：旧引擎读到不认识的 kind 必须失败得响。
  //
  // 输入由 canonical 写出器产出后再做**定点替换**（而不是手写整份层的 JSON）
  // ——手写漏一个必填字段，测的就成了"层字段不完整"，与蒙版毫无关系。
  let good = @core.doc_to_json(make_sample())
  let marker = ",\"mask\":{\"kind\":\"polygon\","
  assert_true(good.contains(marker), msg="样本里应能定位到蒙版片段：\{good}")
  // ① 不认识的 kind → 报错，且错误里要说清收到的值、合法取值、以及怎么摘掉
  let bad = good.replace(old=marker, new=",\"mask\":{\"kind\":\"triangle\",")
  match @core.doc_from_json(bad) {
    Err(msg) => {
      assert_true(msg.contains("triangle"), msg="错误要回显收到的 kind：\{msg}")
      assert_true(msg.contains("rect"), msg="错误要给出合法取值：\{msg}")
      assert_true(msg.contains("polygon"), msg="合法取值里要含新增的 polygon：\{msg}")
      assert_true(msg.contains("remove-mask"), msg="错误要指路怎么摘掉：\{msg}")
    }
    Ok(_) => abort("不认识的蒙版 kind 不该通过")
  }
  // ② 蒙版对象缺 kind → 同样报错（不是"没有蒙版"）
  let nokind = good.replace(old=marker, new=",\"mask\":{")
  match @core.doc_from_json(nokind) {
    Err(msg) => assert_true(msg.contains("kind"), msg="错误要指出缺 kind：\{msg}")
    Ok(_) => abort("缺 kind 的蒙版不该通过")
  }
  // ③ 正控：样本自己照旧打得开，且 roughen 真的读进来（不是常量）
  match @core.doc_from_json(good) {
    Ok(d) =>
      match d.layers[0].mask {
        Some(m) => {
          assert_eq(m.roughen, 2.25)
          assert_true(m.kind is @core.ShapeKind::Polygon)
          assert_eq(m.points.length(), 3, msg="顶点也要随容器读回来")
        }
        None => abort("正常蒙版不该丢")
      }
    Err(e) => abort("正常蒙版不该被拒：\{e}")
  }
  // ④ "mask": null 仍是"没有蒙版"（空集也要说话：不是错误）
  let plain = @core.new_document("u-nomask", 8, 8)
  plain.layers.push(@core.default_layer("l1", "a", 0.0, 0.0, 4.0, 4.0))
  let text = @core.doc_to_json(plain)
  assert_true(text.contains("\"mask\":null"), msg="没有蒙版应写 null：\{text}")
  match @core.doc_from_json(text) {
    Ok(d) =>
      match d.layers[0].mask {
        None => assert_true(true)
        Some(_) => abort("mask=null 应解析成没有蒙版")
      }
    Err(e) => abort("mask=null 不该被拒：\{e}")
  }
}

///|
test "required_render_contract：按文档实际用到的能力声明，别一律写最高档" {
  // 容器 manifest 里的 render_contract 是**版本闸**：读到高于自身支持的版本
  // 一律拒绝打开。若写入端一律写引擎支持的上限，闸就失去分辨力（老引擎打不开
  // 任何新容器）；若一律写 1，用到毛边蒙版的文档会被老引擎**静默画成光滑边**。
  let d = @core.new_document("u-rc", 16, 16)
  d.layers.push(@core.default_layer("l1", "a", 0.0, 0.0, 8.0, 8.0))
  assert_eq(@core.required_render_contract(d), 1, msg="没有蒙版 → 老契约")
  let plain : @core.LayerMask = {
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 8.0,
    h: 8.0,
    radius: 2.0,
    feather: 3.0,
    roughen: 0.0,
    invert: false,
    points: [],
  }
  d.layers[0] = { ..d.layers[0], mask: Some(plain) }
  assert_eq(@core.required_render_contract(d), 1, msg="只有老语义（圆角/羽化）→ 仍是老契约")
  d.layers[0] = { ..d.layers[0], mask: Some({ ..plain, roughen: 2.0 }) }
  assert_eq(
    @core.required_render_contract(d),
    @core.RENDER_CONTRACT_ROUGHEN,
    msg="用到毛边 → 声明到**毛边那一档**（不是当前最高档）",
  )
  // 多边形蒙版（任意形状选区）是**第三档**：老引擎的 `mask_cover_at` 只认椭圆、
  // 其余一律当矩形画 ⇒ 套索选区会被画成方框，所以必须让老引擎拒绝打开。
  let poly : @core.LayerMask = {
    ..plain,
    kind: @core.ShapeKind::Polygon,
    points: [(0.0, 0.0), (8.0, 0.0), (4.0, 8.0)],
  }
  let d2 = @core.new_document("u-rc2", 16, 16)
  d2.layers.push({ ..@core.default_layer("l2", "b", 0.0, 0.0, 8.0, 8.0), mask: Some(poly) })
  assert_eq(
    @core.required_render_contract(d2),
    @core.RENDER_CONTRACT_POLY_MASK,
    msg="套索蒙版 → 第三档",
  )
  // ⚠️ 取**最高**档：两份蒙版各需要一档时，不能只看先遇到的那一层
  // （早退实现会把 3 报成 2，老引擎就会打开并把套索画成方框）。
  let d3 = @core.new_document("u-rc3", 16, 16)
  d3.layers.push({
    ..@core.default_layer("l3", "c", 0.0, 0.0, 8.0, 8.0),
    mask: Some({ ..plain, roughen: 2.0 }),
  })
  d3.layers.push({ ..@core.default_layer("l4", "d", 0.0, 0.0, 8.0, 8.0), mask: Some(poly) })
  assert_eq(
    @core.required_render_contract(d3),
    @core.RENDER_CONTRACT_POLY_MASK,
    msg="毛边(2) + 套索(3) 并存 → 报最高档 3",
  )
  // 仿制图章（克隆笔触）是**第四档**：老引擎读不到 `clone/sdx/sdy`，会把克隆
  // 笔触当成普通笔色画上去 —— 整笔变成一块死色，而"污点被盖住了"还很像成功。
  let d4 = @core.new_document("u-rc4", 16, 16)
  let cd : @core.Dab = {
    x: 4.0,
    y: 4.0,
    r: 2.0,
    color: 0x00000000,
    erase: false,
    clone: true,
    sdx: -2.0,
    sdy: 0.0,
  }
  let pd : @core.Dab = {
    x: 8.0,
    y: 8.0,
    r: 2.0,
    color: 0xFF0000FF,
    erase: false,
    clone: false,
    sdx: 0.0,
    sdy: 0.0,
  }
  d4.layers.push({
    ..@core.default_layer("l5", "e", 0.0, 0.0, 16.0, 16.0),
    kind: @core.ShapeKind::Raster,
    dabs: [cd],
  })
  assert_eq(
    @core.required_render_contract(d4),
    @core.RENDER_CONTRACT_CLONE,
    msg="克隆笔触 → 第四档（老引擎会画成一块死色）",
  )
  // **负控**：普通笔触不许被一并抬到第四档 —— 一律写上限等于让版本闸失去分辨力
  // （老引擎将打不开任何新容器）。
  let d5 = { ..d4, layers: [{ ..d4.layers[0], dabs: [pd] }] }
  assert_eq(
    @core.required_render_contract(d5),
    1,
    msg="只有普通笔触 → 仍是基础档（不许无条件抬档）",
  )
}

///|
test "mask_param_error：一句话说清「装不上/不生效」的四种情形（入口与 lint 共用）" {
  let ok : @core.LayerMask = {
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 10.0,
    h: 10.0,
    radius: 0.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
    points: [],
  }
  assert_eq(@core.mask_param_error(ok), "", msg="合法蒙版不许报错（判据两头都要咬）")
  // 尺寸非正：覆盖区为空 → invert=false 时整层被藏掉
  assert_true(@core.mask_param_error({ ..ok, w: 0.0 }).contains("尺寸"), msg="w=0 要报尺寸")
  assert_true(@core.mask_param_error({ ..ok, h: -1.0 }).contains("尺寸"), msg="h<0 要报尺寸")
  // 三个"给负数 = 渲染器各自折成 0"的参数
  assert_true(@core.mask_param_error({ ..ok, radius: -1.0 }).contains("radius"))
  assert_true(@core.mask_param_error({ ..ok, feather: -1.0 }).contains("feather"))
  assert_true(@core.mask_param_error({ ..ok, roughen: -1.0 }).contains("roughen"))
  // 多边形蒙版（套索）：**点数下界**与**顶点必须在盒内**——两条都在
  // `mask_param_error` 一处实现（入口与 lint 共用），错误话术要点名是哪个顶点。
  let poly : @core.LayerMask = {
    ..ok,
    kind: @core.ShapeKind::Polygon,
    w: 50.0,
    h: 50.0,
    points: [(0.0, 0.0), (50.0, 0.0), (25.0, 50.0)],
  }
  assert_eq(@core.mask_param_error(poly), "", msg="合法三角形不该报")
  assert_true(
    @core.mask_param_error({ ..poly, points: [(0.0, 0.0), (5.0, 0.0)] }).contains("至少要有 3 个顶点"),
  )
  let out = @core.mask_param_error({ ..poly, points: [(0.0, 0.0), (50.0, 0.0), (99.0, 9.0)] })
  assert_true(out.contains("99"), msg="要点名越界的那个顶点：\{out}")
  assert_true(out.contains("盒子"), msg="要说清判据是「盒子=支持窗」：\{out}")
  // 非多边形带顶点 = 渲染器不读它（改了画面逐位不变，只会平白改变指纹）
  assert_true(
    @core.mask_param_error({ ..ok, points: [(1.0, 1.0), (2.0, 2.0), (3.0, 3.0)] }).contains("只有多边形蒙版"),
  )
  // 错误信息要带上实际收到的值（值也进指纹，"报了字段不报值"没法自查）
  assert_true(@core.mask_param_error({ ..ok, roughen: -2.5 }).contains("-2.5"))
}

///|
test "alloc_layer_id 单调分配" {
  let doc = @core.new_document("u", 100, 100)
  assert_eq(@core.alloc_layer_id(doc), "l1")
  assert_eq(@core.alloc_layer_id(doc), "l2")
  assert_eq(@core.alloc_layer_id(doc), "l3")
}
