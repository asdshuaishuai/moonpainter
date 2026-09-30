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
    mask: Some({
      kind: @core.ShapeKind::Rect,
      x: 12.5,
      y: 13.25,
      w: 100.0,
      h: 90.5,
      radius: 8.0,
      feather: 3.5,
      invert: true,
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
  let g = @core.default_layer("l3", "frame", 40.0, 40.0, 720.0, 520.0)
  let g2 = { ..g, kind: @core.ShapeKind::Group, children: [poly2, line2] }
  doc.layers.push(bg2)
  doc.layers.push(circle2)
  doc.layers.push(g2)
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
  assert_eq(back.layers.length(), 3)
  // 蒙版字段必须逐个保真（此前它们连一条断言都没有）
  match back.layers[0].mask {
    Some(m) => {
      assert_true(m.kind is @core.ShapeKind::Rect)
      assert_eq(m.x, 12.5)
      assert_eq(m.y, 13.25)
      assert_eq(m.w, 100.0)
      assert_eq(m.h, 90.5)
      assert_eq(m.radius, 8.0)
      assert_eq(m.feather, 3.5)
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
test "alloc_layer_id 单调分配" {
  let doc = @core.new_document("u", 100, 100)
  assert_eq(@core.alloc_layer_id(doc), "l1")
  assert_eq(@core.alloc_layer_id(doc), "l2")
  assert_eq(@core.alloc_layer_id(doc), "l3")
}
