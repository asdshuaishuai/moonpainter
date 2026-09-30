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
fn sample_mvsl_program() -> @core.EditProgram {
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: {
      basis: @core.Base,
      expr: @core.Atom(
        @core.Geo({ x: 0.0, y: 0.0, w: 60.0, h: 80.0, feather: 2.0 }, "rect"),
      ),
    },
    amount: 0.75,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [@core.Feather(1.0)],
    note: "调色",
    evidence: Some({
      label: "背景",
      pos_seeds: [(4.0, 4.0)],
      neg_seeds: [(100.0, 4.0)],
    }),
  }
  let prot : @core.Guard = {
    id: "g1",
    sel: {
      basis: @core.Base,
      expr: @core.Atom(
        @core.Geo({ x: 60.0, y: 0.0, w: 60.0, h: 80.0, feather: 0.0 }, "rect"),
      ),
    },
    max_de: 0.02,
    max_changed_ratio: 0.1,
  }
  { ops: [op], guards: [prot] }
}

///|
/// 从 JSON 对象精确取数字字段（纪律 11：数值断言不靠子串匹配——
/// `contains("\"layers\":3")` 会被 `"layers":30` 骗过）。
fn num_field(obj : @core.JValue, key : String) -> Double {
  match obj.get(key) {
    Some(@core.JValue::JNum(d)) => d
    Some(_) => abort("字段 \{key} 不是数字")
    None => abort("缺字段 \{key}")
  }
}

///|
test "manifest 的 counts 如实报告（layers/assets/params 不许互换或写死）" {
  // counts 是对外可见的事实——工具与审阅者据此判断"容器里到底有什么"，
  // 而 verify.sh 只校验 format 与 MVSL 版本块。把 layers 和 assets 互换
  // 此前**全部测试通过**。
  let m = sample_mpd() // 3 层 + 1 位图资产 + 1 参数
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let z = @codec.Zip::open(packed)
  let manifest = z.read_text("manifest.json")
  let v = match @core.parse_json(manifest) {
    Ok(x) => x
    Err(e) => abort("manifest 不是合法 JSON: \{e}")
  }
  let counts = match v.get("counts") {
    Some(c) => c
    None => abort("manifest 缺 counts：\{manifest}")
  }
  assert_eq(num_field(counts, "layers"), 3.0, msg=manifest)
  assert_eq(num_field(counts, "assets"), 1.0, msg=manifest)
  assert_eq(num_field(counts, "params"), 1.0, msg=manifest)
}

///|
test "MVSL：编辑表随容器往返，版本块自洽（list 条目 + manifest 声明）" {
  let m = sample_mpd()
  m.mvsl = sample_mvsl_program()
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  // 条目存在且是 canonical 形式
  let z = @codec.Zip::open(packed)
  assert_true(z.has("meta/mvsl.json"), msg="容器缺 meta/mvsl.json")
  assert_eq(z.read_text("meta/mvsl.json"), @core.program_to_json(m.mvsl))
  // manifest 版本块
  let manifest = z.read_text("manifest.json")
  assert_true(manifest.contains("\"render_contract\":1"), msg=manifest)
  assert_true(manifest.contains("\"selector_algo\":\"mvsl-sel-1\""), msg=manifest)
  assert_true(manifest.contains("\"color_semantics\":\"oklch-1\""), msg=manifest)
  assert_true(manifest.contains("\"op_semantics\":\"mvsl-op-1\""), msg=manifest)
  assert_true(manifest.contains("\"program_sha256\":\"\{@mpd.program_hash(m)}\""), msg=manifest)
  // 往返：结构 + 证据 + 指纹
  let back = match @mpd.unpack(packed) {
    Ok(x) => x
    Err(e) => abort("unpack 失败: \{e}")
  }
  assert_eq(@core.program_to_json(back.mvsl), @core.program_to_json(m.mvsl))
  assert_eq(@mpd.program_hash(back), @mpd.program_hash(m))
  assert_eq(back.mvsl.ops[0].note, "调色")
  match back.mvsl.ops[0].evidence {
    Some(ev) => assert_eq(ev.label, "背景")
    None => abort("证据丢失")
  }
  // 重打包字节一致
  let again = match @mpd.pack(back) {
    Ok(b) => b
    Err(e) => abort("repack 失败: \{e}")
  }
  assert_eq(@base.sha256_hex(again), @base.sha256_hex(packed))
}

///|
test "MVSL：预览走编辑表（预览是「保存后会看到什么」的承诺）" {
  let plain = sample_mpd()
  let packed_plain = match @mpd.pack(plain) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let z0 = @codec.Zip::open(packed_plain)
  let flat0 = z0.read("previews/flat.png")
  let thumb0 = z0.read("previews/thumb.png")
  // 同一文档 + 非空编辑表 → 预览必须变
  let edited = sample_mpd()
  edited.mvsl = sample_mvsl_program()
  let packed_edited = match @mpd.pack(edited) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let z1 = @codec.Zip::open(packed_edited)
  let flat1 = z1.read("previews/flat.png")
  let thumb1 = z1.read("previews/thumb.png")
  assert_true(
    @base.sha256_hex(flat1) != @base.sha256_hex(flat0),
    msg="带编辑表的 flat 预览与不带的一致（预览漏渲染了编辑表）",
  )
  assert_true(
    @base.sha256_hex(thumb1) != @base.sha256_hex(thumb0),
    msg="thumb 预览漏渲染了编辑表",
  )
  // 确定性：同一状态再打包一次，预览字节一致
  let again = match @mpd.pack(edited) {
    Ok(b) => b
    Err(e) => abort("repack 失败: \{e}")
  }
  let z2 = @codec.Zip::open(again)
  assert_eq(@base.sha256_hex(z2.read("previews/flat.png")), @base.sha256_hex(flat1))
  // 坏编辑表不该被打包成"预览悄悄退回底图"
  let bad = sample_mpd()
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: { basis: @core.Stage(3), expr: sample_mvsl_program().ops[0].sel.expr },
    amount: 1.0,
    hue_deg: 10.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  bad.mvsl = { ops: [op], guards: [] }
  match @mpd.pack(bad) {
    Err(msg) => assert_true(msg.has_prefix("MVSL 编辑表校验失败"), msg=msg)
    Ok(_) => abort("越界 stage 不该 pack")
  }
}

///|
test "MVSL 拒绝：编辑表被改写 / 半截状态 / 更高 render contract" {
  let m = sample_mpd()
  m.mvsl = sample_mvsl_program()
  let canonical = @core.program_to_json(m.mvsl)
  // 编辑表字节被改（内容有效但指纹对不上）
  let loosened = canonical.replace(old=",\"guards\"", new=", \"guards\"")
  assert_true(loosened != canonical)
  let t1 = repack_with(m, [("meta/mvsl.json", loosened)])
  match @mpd.unpack(t1) {
    Err(msg) => assert_true(msg.has_prefix("meta/mvsl.json 不是 canonical 形式"), msg=msg)
    Ok(_) => abort("非 canonical 编辑表不该通过")
  }
  // 编辑表内容被换成另一个合法程序（指纹对账必须抓到）
  let swapped = @core.program_to_json({ ops: [], guards: [] })
  let t2 = repack_with(m, [("meta/mvsl.json", swapped)])
  match @mpd.unpack(t2) {
    Err(msg) => assert_true(msg.has_prefix("编辑表指纹对账失败"), msg=msg)
    Ok(_) => abort("换掉编辑表不该通过")
  }
  // manifest 声明了 mvsl 但没有对应条目（半截状态）
  let packed = match @mpd.pack(m) {
    Ok(b) => b
    Err(e) => abort("pack 失败: \{e}")
  }
  let z = @codec.Zip::open(packed)
  let entries : Array[@codec.ZipOutEntry] = []
  for e in z.entries {
    if !e.is_dir && e.name != "meta/mvsl.json" {
      entries.push(@codec.ZipOutEntry::new(e.name, z.read(e.name), compress=false))
    }
  }
  match @mpd.unpack(@codec.build_zip(entries)) {
    Err(msg) =>
      assert_true(msg.has_prefix("manifest 声明了 mvsl 但缺 meta/mvsl.json"), msg=msg)
    Ok(_) => abort("半截状态不该通过")
  }
  // 更高 render contract
  let manifest = z.read_text("manifest.json")
  let higher = manifest.replace(
    old="\"render_contract\":1",
    new="\"render_contract\":99",
  )
  assert_true(higher != manifest, msg="render_contract 字段未找到")
  match @mpd.unpack(repack_with(m, [("manifest.json", higher)])) {
    Err(msg) => assert_true(msg.has_prefix("render contract 版本"), msg=msg)
    Ok(_) => abort("更高 render contract 不该通过")
  }
  // selector 算法版本不符（微调过的编辑表会漂移，必须拒绝）
  let other_algo = manifest.replace(
    old="\"selector_algo\":\"mvsl-sel-1\"",
    new="\"selector_algo\":\"mvsl-sel-2\"",
  )
  assert_true(other_algo != manifest)
  match @mpd.unpack(repack_with(m, [("manifest.json", other_algo)])) {
    Err(msg) => assert_true(msg.has_prefix("selector 算法版本"), msg=msg)
    Ok(_) => abort("异版本 selector 不该通过")
  }
}

///|
test "MVSL pack 源头拒绝：坏程序不进容器" {
  let m = sample_mpd()
  // amount 越界
  let bad : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: {
      basis: @core.Base,
      expr: @core.Atom(
        @core.Geo({ x: 0.0, y: 0.0, w: 1.0, h: 1.0, feather: 0.0 }, "rect"),
      ),
    },
    amount: 1.5,
    hue_deg: 10.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  m.mvsl = { ops: [bad], guards: [] }
  match @mpd.pack(m) {
    Err(msg) => assert_true(msg.has_prefix("MVSL 编辑表校验失败"), msg=msg)
    Ok(_) => abort("越界 amount 不该 pack")
  }
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
  // 前向版本（不写死版本号：容器规范会随格式演进升版）
  let bad_ver = manifest.replace(
    old="\"version\":\{@core.MPD_VERSION}",
    new="\"version\":99",
  )
  assert_true(bad_ver != manifest, msg="前向版本构造失败：manifest 里没找到 version 字段")
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
