/// .mpd 容器测试：往返保真、pack 确定性、拒绝式校验全覆盖（PLAN.md §7.6）。

///|
fn sample_mpd() -> @mpd.MpdDoc {
  let doc = @core.new_document("uuid-mpd-0001", 120, 80)
  let bg = @core.default_layer("l1", "bg", 0.0, 0.0, 120.0, 80.0)
  let bg2 = { ..bg, fill: @core.Fill::Solid(0x223344FF), tags: ["background"] }
  let orb = @core.default_layer("l2", "orb", 30.0, 10.0, 40.0, 40.0)
  let orb2 = {
    ..orb,
    kind: @core.ShapeKind::Ellipse,
    fill: @core.Fill::LinearGradient(0xFF7A45FF, 0x2E6FE8FF, 0.0, 0.0, 1.0, 1.0),
    blend: @core.BlendMode::Screen,
  }
  doc.layers.push(bg2)
  doc.layers.push(orb2)
  // 位图资产
  let img = @codec.rgba_new(4, 3)
  @codec.fill_rect_rgba(img, 0, 0, 4, 3, @codec.color_from_hex("#CC3366"))
  let png = @codec.png_encode(img)
  let hash = @base.sha256_hex(png)
  doc.assets.push({ hash, width: 4, height: 3 })
  let pic = @core.default_layer("l3", "pic", 80.0, 20.0, 24.0, 18.0)
  let pic2 = {
    ..pic,
    kind: @core.ShapeKind::Image,
    fill: @core.Fill::NoFill,
    asset_hash: hash,
  }
  doc.layers.push(pic2)
  doc.params.push({ name: "palette.primary", value: "#FF7A45" })
  doc.next_layer_no = 4
  let m = @mpd.MpdDoc::new(doc)
  m.add_asset(hash, png)
  m.edits.push("init: 3 layers + 1 asset")
  m
}

///|
test "pack → unpack 往返保真（结构/指纹/资产/档案）" {
  let m = sample_mpd()
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let back = match @mpd.unpack(packed) {
    Ok(x) => x
    Err(e) => abort("unpack 失败: \{e}")
  }
  assert_eq(@mpd.fingerprint(back), @mpd.fingerprint(m))
  assert_eq(@core.doc_to_json(back.doc), @core.doc_to_json(m.doc))
  assert_eq(back.assets.length(), 1)
  assert_eq(back.assets[0].0, m.assets[0].0)
  assert_eq(back.assets[0].1.length(), m.assets[0].1.length())
  assert_eq(back.edits.length(), 1)
  assert_eq(back.edits[0], "init: 3 layers + 1 asset")
}

///|
test "pack 确定性：同状态两次打包字节一致" {
  let a = match @mpd.pack(sample_mpd()) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let b = match @mpd.pack(sample_mpd()) {
    Ok(x) => x
    Err(e) => abort("pack 失败: \{e}")
  }
  assert_eq(a.length(), b.length())
  let mut i = 0
  while i < a.length() {
    assert_eq(a[i].to_int(), b[i].to_int())
    i = i + 1
  }
}

///|
test "往返后再 pack 字节仍一致（闭环确定性）" {
  let p1 = match @mpd.pack(sample_mpd()) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  let m = match @mpd.unpack(p1) {
    Ok(x) => x
    Err(e) => abort(e)
  }
  let p2 = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  assert_eq(p1.length(), p2.length())
  let mut i = 0
  while i < p1.length() {
    assert_eq(p1[i].to_int(), p2[i].to_int())
    i = i + 1
  }
}

///|
test "拒绝：垃圾字节 / 截断容器" {
  match @mpd.unpack(@utf8.encode("this is definitely not a zip file at all")) {
    Err(_) => assert_true(true)
    Ok(_) => abort("垃圾不该通过")
  }
  let packed = match @mpd.pack(sample_mpd()) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  let cut : Array[Byte] = []
  let mut i = 0
  let cut_at = packed.length() / 2
  while i < cut_at {
    cut.push(packed[i])
    i = i + 1
  }
  match @mpd.unpack(Bytes::from_array(cut)) {
    Err(_) => assert_true(true)
    Ok(_) => abort("截断容器不该通过")
  }
}

///|
/// 手工重组 ZIP（篡改单个部件）——拒绝式校验的用例底座。
fn repack_with(
  m : @mpd.MpdDoc,
  replace : Array[(String, String)],
) -> Bytes {
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let z = @codec.Zip::open(packed)
  let entries : Array[@codec.ZipOutEntry] = []
  for e in z.entries {
    if e.is_dir {
      continue
    }
    let mut text : String? = None
    for pair in replace {
      if pair.0 == e.name {
        text = Some(pair.1)
      }
    }
    match text {
      Some(t) => entries.push(@codec.ZipOutEntry::of_text(e.name, t))
      None => entries.push(
        @codec.ZipOutEntry::new(e.name, z.read(e.name), compress=false),
      )
    }
  }
  @codec.build_zip(entries)
}

///|
test "拒绝：manifest 指纹与 design.json 不符（篡改检测）" {
  let m = sample_mpd()
  // 篡改 design.json（改画布宽度），manifest 指纹保持原值 → 对账必须失败
  let z = @codec.Zip::open(
    match @mpd.pack(m) {
      Ok(b) => b
      Err(e) => abort(e)
    },
  )
  let design = z.read_text("meta/design.json")
  let bad = design.replace(old="\"width\":120", new="\"width\":121")
  assert_true(bad != design)
  let tampered = repack_with(m, [("meta/design.json", bad)])
  match @mpd.unpack(tampered) {
    Err(msg) => assert_true(msg.has_prefix("指纹对账失败"))
    Ok(_) => abort("篡改 design 不该通过")
  }
}

///|
test "拒绝：坏 format / 前向版本 / 缺部件" {
  let m = sample_mpd()
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  let z = @codec.Zip::open(packed)
  let manifest = z.read_text("manifest.json")
  // 坏 format
  let bad_fmt = manifest.replace(old="moonpainter.mpd", new="evil.format")
  match @mpd.unpack(repack_with(m, [("manifest.json", bad_fmt)])) {
    Err(msg) => assert_true(msg.has_prefix("容器格式不符"))
    Ok(_) => abort("坏 format 不该通过")
  }
  // 前向版本
  let bad_ver = manifest.replace(old="\"version\":1", new="\"version\":99")
  match @mpd.unpack(repack_with(m, [("manifest.json", bad_ver)])) {
    Err(msg) => assert_true(msg.has_prefix("容器版本"))
    Ok(_) => abort("前向版本不该通过")
  }
  // 缺 meta/design.json：重组时跳过该部件
  let entries : Array[@codec.ZipOutEntry] = []
  for e in z.entries {
    if e.name != "meta/design.json" && !e.is_dir {
      entries.push(
        @codec.ZipOutEntry::new(e.name, z.read(e.name), compress=false),
      )
    }
  }
  match @mpd.unpack(@codec.build_zip(entries)) {
    Err(msg) => assert_true(msg.has_prefix("缺 meta/design.json"))
    Ok(_) => abort("缺 design 不该通过")
  }
}

///|
test "拒绝：路径穿越条目 / 资产哈希对账失败" {
  let m = sample_mpd()
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort(e)
  }
  let z = @codec.Zip::open(packed)
  // 追加一个 ../evil 条目
  let entries : Array[@codec.ZipOutEntry] = []
  for e in z.entries {
    if !e.is_dir {
      entries.push(
        @codec.ZipOutEntry::new(e.name, z.read(e.name), compress=false),
      )
    }
  }
  entries.push(@codec.ZipOutEntry::of_text("../evil.txt", "boom"))
  match @mpd.unpack(@codec.build_zip(entries)) {
    Err(msg) => assert_true(msg.has_prefix("不安全路径"))
    Ok(_) => abort("路径穿越不该通过")
  }
  // 资产字节被换但名字不变 → sha256 对账失败
  let asset_name = "assets/sha256/\{m.assets[0].0}"
  let evil : Array[@codec.ZipOutEntry] = []
  for e in z.entries {
    if e.is_dir {
      continue
    }
    if e.name == asset_name {
      evil.push(@codec.ZipOutEntry::of_text(asset_name, "tampered asset bytes"))
    } else {
      evil.push(@codec.ZipOutEntry::new(e.name, z.read(e.name), compress=false))
    }
  }
  match @mpd.unpack(@codec.build_zip(evil)) {
    Err(msg) => assert_true(msg.has_prefix("资产对账失败"))
    Ok(_) => abort("资产篡改不该通过")
  }
}

///|
test "pack 源头拒绝：资产 hash 与字节不符 / 引用未登记资产 / 画布超限" {
  let m = sample_mpd()
  // hash 与字节不符
  let bad = @mpd.MpdDoc::new(m.doc)
  bad.add_asset("deadbeef", m.assets[0].1)
  match @mpd.pack(bad) {
    Err(msg) => assert_true(msg.has_prefix("资产对账失败"))
    Ok(_) => abort("假 hash 不该 pack")
  }
  // 引用未登记资产（doc 引用存在但容器无字节）
  let ghost = @mpd.MpdDoc::new(m.doc)
  match @mpd.pack(ghost) {
    Err(msg) => assert_true(msg.has_prefix("文档引用的资产"))
    Ok(_) => abort("幽灵资产不该 pack")
  }
  // 画布超限
  let big = @core.new_document("u-big", 40000, 100)
  let mb = @mpd.MpdDoc::new(big)
  match @mpd.pack(mb) {
    Err(msg) => assert_true(msg.has_prefix("画布单边超限"))
    Ok(_) => abort("超大画布不该 pack")
  }
}
