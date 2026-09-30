/// mpd —— .mpd 容器（mpd/mpd）。
///
/// 双层结构（PLAN.md §4）：
/// - 元参数层（纯文本）：manifest.json + meta/{design,params,vision,agent}.json
/// - 设计稿层：assets/sha256/<hash>（内容寻址 PNG 资产）+ previews/{flat,thumb}.png
///
/// 纪律：
/// - **pack 确定性**：固定条目顺序 + 固定 ZIP 时间戳 + canonical JSON
///   → 同状态两次 pack 字节一致（可 diff、可进版本管理）；
/// - **拒绝式校验**（unpack 逐条）：EOCD/中央目录、manifest 存在与 format 匹配、
///   前向版本拒绝、每条目 CRC、资产 sha256 对账、路径安全、限额；
/// - **canonical 指纹**：sha256(design.json) 贯穿 manifest 与所有变更信封。

///|
/// 容器限额（对齐 Compositor 纪律，PLAN.md §4）。
pub const LIMIT_MAX_SIDE : Int = 30000

///|
pub const LIMIT_MAX_PIXELS : Int = 100000000

///|
pub const LIMIT_MAX_LAYERS : Int = 10000

///|
pub const LIMIT_META_BYTES : Int = 4194304 // 4 MiB

///|
pub const LIMIT_ASSET_BYTES : Int = 536870912 // 512 MiB

///|
/// 打包输入：文档 + 资产字节（hash 必须是字节的 sha256）+ Agent 档案行
/// + 当前 canonical MVSL 编辑表（`meta/mvsl.json`）。
///
/// **编辑表是状态，edits 是轨迹**（PLAN-MVSL §3 ChatGPT 条目）：mvsl 是
/// 当前程序（渲染的真值输入），edits 只是历史日志，两者分离。
pub(all) struct MpdDoc {
  doc : @core.Document
  assets : Array[(String, Bytes)]
  /// agent.json 的编辑历史摘要（按时间序）
  edits : Array[String]
  /// 当前 MVSL 编辑表（canonical program；空程序 = 逐位还原 base）
  mut mvsl : @core.EditProgram
}

///|
pub fn MpdDoc::new(doc : @core.Document) -> MpdDoc {
  { doc, assets: [], edits: [], mvsl: @core.EditProgram::new() }
}

///|
/// 登记一笔资产（hash 由调用方保证 = sha256(bytes)；add-image 命令负责计算）。
pub fn MpdDoc::add_asset(self : MpdDoc, hash : String, bytes : Bytes) -> Unit {
  self.assets.push((hash, bytes))
}

///|
/// 当前文档指纹（= sha256(canonical design.json)）。
pub fn fingerprint(m : MpdDoc) -> String {
  @core.fingerprint(m.doc)
}

///|
/// 当前编辑表的指纹（= sha256(canonical mvsl.json)）。与文档指纹并列：
/// 人改结构、AI 改编辑表，两条指纹各自可对账。
pub fn program_hash(m : MpdDoc) -> String {
  @base.sha256_hex(@utf8.encode(@core.program_to_json(m.mvsl)))
}

///|
/// manifest.json 文本（固定字段序——canonical）。
fn manifest_json(m : MpdDoc) -> String {
  let d = m.doc
  let layers_n = @core.all_layers(d.layers).length()
  let sb = StringBuilder()
  sb.write_string("{\"format\":\"\{@core.MPD_FORMAT_ID}\",\"version\":\{@core.MPD_VERSION}")
  sb.write_string(",\"engine\":\"\{@core.ENGINE_VERSION}\"")
  sb.write_string(",\"uuid\":\"\{d.uuid}\"")
  sb.write_string(",\"canvas\":{\"w\":\{d.width},\"h\":\{d.height},\"dpi\":\{d.dpi},\"profile\":\"\{d.profile}\"}")
  sb.write_string(",\"counts\":{\"layers\":\{layers_n},\"assets\":\{d.assets.length()},\"params\":\{d.params.length()}}")
  sb.write_string(",\"fingerprint\":\"\{fingerprint(m)}\"")
  // MVSL 语义三决定 + 三个算法版本 pin（PLAN-MVSL §1.7）：
  // 选择子求值基准、算子有序性、色彩语义版本必须随容器走，
  // 旧引擎遇不认识的 render_contract 一律拒绝，不静默错渲。
  sb.write_string(",\"mvsl\":{")
  sb.write_string("\"ir\":\{@core.MVSL_IR_VERSION}")
  sb.write_string(",\"render_contract\":\{@core.RENDER_CONTRACT_VERSION}")
  sb.write_string(",\"selector_algo\":\"\{@core.SELECTOR_ALGO_VERSION}\"")
  sb.write_string(",\"color_semantics\":\"\{@core.COLOR_SEMANTICS_VERSION}\"")
  sb.write_string(",\"op_semantics\":\"\{@core.OP_SEMANTICS_VERSION}\"")
  sb.write_string(",\"ops\":\{m.mvsl.ops.length()}")
  sb.write_string(",\"guards\":\{m.mvsl.guards.length()}")
  sb.write_string(",\"program_sha256\":\"\{program_hash(m)}\"}")
  sb.write_string(",\"asset_index\":[")
  let mut f = true
  for a in d.assets {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{a.hash}\"")
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
fn params_json(d : @core.Document) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"named\":[")
  let mut f = true
  for p in d.params {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"name\":\"\{@core.json_escape(p.name)}\",\"value\":\"\{@core.json_escape(p.value)}\"}")
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
fn vision_json() -> String {
  "{\"previews\":[\"previews/flat.png\",\"previews/thumb.png\"],\"anchors\":[]}"
}

///|
fn agent_json(m : MpdDoc) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"engine\":\"\{@core.ENGINE_VERSION}\",\"edits\":[")
  let mut f = true
  for e in m.edits {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{@core.json_escape(e)}\"")
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// 渲染预览 PNG（长边 ≤ max_side；viewport 全景）。
///
/// **预览必须走编辑表**：预览是「保存后会看到什么」的承诺，
/// 少渲染一批编辑就等于撒谎。
fn preview_png(
  m : MpdDoc,
  env : @render.RenderEnv,
  max_side : Int,
) -> Result[Bytes, String] {
  let d = m.doc
  let w = d.width
  let h = d.height
  let long = if w > h { w } else { h }
  let out_w = if long > max_side {
    let scaled = (w.to_double() * max_side.to_double() / long.to_double() + 0.5).to_int()
    if scaled < 1 { 1 } else { scaled }
  } else {
    w
  }
  if out_w < 1 {
    return Err("预览宽度过小")
  }
  let buf = match @render.render_view_with(d, env, 0.0, 0.0, 1.0, 1.0, out_w, m.mvsl) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  Ok(@codec.png_encode(buf))
}

///|
/// 解码全部资产为渲染环境。
pub fn render_env(m : MpdDoc) -> Result[@render.RenderEnv, String] {
  let env = @render.RenderEnv::new()
  for pair in m.assets {
    let (hash, bytes) = pair
    match @codec.png_decode(bytes) {
      Ok(img) => env.assets.set(hash, img)
      Err(e) => return Err("资产 \{hash} 无法解码: \{e}")
    }
  }
  Ok(env)
}

///|
/// 打包为 .mpd 字节流。打包前做限额与资产对账（坏输入在源头拒绝）。
pub fn pack(m : MpdDoc) -> Result[Bytes, String] {
  let d = m.doc
  if d.width <= 0 || d.height <= 0 {
    return Err("画布尺寸必须为正")
  }
  if d.width > LIMIT_MAX_SIDE || d.height > LIMIT_MAX_SIDE {
    return Err("画布单边超限（>\{LIMIT_MAX_SIDE}）")
  }
  if d.width.to_int64() * d.height.to_int64() > LIMIT_MAX_PIXELS.to_int64() {
    return Err("画布总像素超限（>\{LIMIT_MAX_PIXELS}）")
  }
  if @core.all_layers(d.layers).length() > LIMIT_MAX_LAYERS {
    return Err("层数超限（>\{LIMIT_MAX_LAYERS}）")
  }
  // 编辑表：坏程序在源头拒绝（限额护栏 + 参数范围 + 未知算子）
  match @core.validate_program(m.mvsl) {
    Ok(_) => ()
    Err(e) => return Err("MVSL 编辑表校验失败：\{e}")
  }
  // 资产对账 + 限额
  for pair in m.assets {
    let (hash, bytes) = pair
    if bytes.length() > LIMIT_ASSET_BYTES {
      return Err("资产 \{hash} 超过 512MiB 限额")
    }
    if @base.sha256_hex(bytes) != hash {
      return Err("资产对账失败：\{hash} 不是其字节的 sha256")
    }
  }
  for a in d.assets {
    let mut found = false
    for pair in m.assets {
      if pair.0 == a.hash {
        found = true
        break
      }
    }
    if !found {
      return Err("文档引用的资产未登记字节: \{a.hash}")
    }
  }
  // 预览
  let env = match render_env(m) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  let flat = match preview_png(m, env, 2048) {
    Ok(b) => b
    Err(e) => return Err("flat 预览失败: \{e}")
  }
  let thumb = match preview_png(m, env, 512) {
    Ok(b) => b
    Err(e) => return Err("thumb 预览失败: \{e}")
  }
  // 元参数层文本
  let design_text = @core.doc_to_json(d)
  let manifest_text = manifest_json(m)
  let params_text = params_json(d)
  let vision_text = vision_json()
  let agent_text = agent_json(m)
  let mvsl_text = @core.program_to_json(m.mvsl)
  let meta_total = @utf8.encode(manifest_text).length() +
    @utf8.encode(design_text).length() +
    @utf8.encode(params_text).length() +
    @utf8.encode(vision_text).length() +
    @utf8.encode(agent_text).length() +
    @utf8.encode(mvsl_text).length()
  if meta_total > LIMIT_META_BYTES {
    return Err("元参数层总量超限（>\{LIMIT_META_BYTES} 字节）")
  }
  // 固定顺序条目（确定性 pack 的前提）
  let entries : Array[@codec.ZipOutEntry] = []
  entries.push(@codec.ZipOutEntry::of_text("manifest.json", manifest_text))
  entries.push(@codec.ZipOutEntry::of_text("meta/design.json", design_text))
  entries.push(@codec.ZipOutEntry::of_text("meta/params.json", params_text))
  entries.push(@codec.ZipOutEntry::of_text("meta/vision.json", vision_text))
  entries.push(@codec.ZipOutEntry::of_text("meta/agent.json", agent_text))
  entries.push(@codec.ZipOutEntry::of_text("meta/mvsl.json", mvsl_text))
  // PNG 已压缩：存储条目
  entries.push(@codec.ZipOutEntry::new("previews/flat.png", flat, compress=false))
  entries.push(@codec.ZipOutEntry::new("previews/thumb.png", thumb, compress=false))
  for pair in m.assets {
    let (hash, bytes) = pair
    entries.push(
      @codec.ZipOutEntry::new("assets/sha256/\{hash}", bytes, compress=false),
    )
  }
  Ok(@codec.build_zip(entries))
}

///|
/// 解包 .mpd。任何一条校验不过即拒绝（精确错误信息），绝不带病渲染。
pub fn unpack(data : Bytes) -> Result[MpdDoc, String] {
  if data.length() < 64 {
    return Err("文件过短，不是 .mpd（\{data.length()} 字节）")
  }
  let z = @codec.Zip::open(data)
  if z.entries.length() == 0 {
    let why = if z.warnings.length() > 0 {
      z.warnings[0]
    } else {
      "空容器"
    }
    return Err("ZIP 打开失败：\{why}")
  }
  // 路径安全：任何条目名都不允许 .. 或绝对路径
  for e in z.entries {
    if e.name.has_prefix("/") || contains_dots(e.name) {
      return Err("不安全路径：\{e.name}")
    }
  }
  // 每条目 CRC 校验（拒绝式）
  for e in z.entries {
    if !e.is_dir && !z.check_crc(e) {
      return Err("条目 CRC 校验失败：\{e.name}")
    }
  }
  // manifest
  if !z.has("manifest.json") {
    return Err("缺 manifest.json")
  }
  let manifest = match @core.parse_json(z.read_text("manifest.json")) {
    Ok(v) => v
    Err(e) => return Err("manifest.json 解析失败：\{e}")
  }
  let format = match manifest.get("format") {
    Some(v) => match v.as_str() {
      Some(s) => s
      None => return Err("manifest.format 不是字符串")
    }
    None => return Err("manifest 缺 format")
  }
  if format != @core.MPD_FORMAT_ID {
    return Err("容器格式不符：\{format}（期望 \{@core.MPD_FORMAT_ID}）")
  }
  let ver = match manifest.get("version") {
    Some(v) => match v.as_num() {
      Some(n) => n
      None => return Err("manifest.version 不是数字")
    }
    None => return Err("manifest 缺 version")
  }
  if ver > @core.MPD_VERSION.to_double() {
    return Err("容器版本 \{ver} 高于引擎支持的 \{@core.MPD_VERSION}，拒绝打开")
  }
  // design.json（严格 UTF-8）
  if !z.has("meta/design.json") {
    return Err("缺 meta/design.json")
  }
  let design_raw = z.read("meta/design.json")
  let design_text = match @codec.decode_utf8(design_raw) {
    Some(t) => t
    None => return Err("meta/design.json 不是合法 UTF-8")
  }
  let doc = match @core.doc_from_json(design_text) {
    Ok(d) => d
    Err(e) => return Err("meta/design.json：\{e}")
  }
  // 指纹对账：manifest 里记录的 fingerprint 必须等于 design.json 的实际指纹
  let fp_expect = match manifest.get("fingerprint") {
    Some(v) => match v.as_str() {
      Some(s) => s
      None => return Err("manifest.fingerprint 不是字符串")
    }
    None => return Err("manifest 缺 fingerprint")
  }
  let fp_actual = @base.sha256_hex(@utf8.encode(design_text))
  if fp_expect != fp_actual {
    return Err("指纹对账失败：manifest 记录 \{fp_expect}，实际 \{fp_actual}（容器被篡改或损坏）")
  }
  // 限额复检
  if doc.width <= 0 || doc.height <= 0 {
    return Err("画布尺寸必须为正")
  }
  if doc.width > LIMIT_MAX_SIDE || doc.height > LIMIT_MAX_SIDE {
    return Err("画布单边超限")
  }
  if doc.width.to_int64() * doc.height.to_int64() > LIMIT_MAX_PIXELS.to_int64() {
    return Err("画布总像素超限")
  }
  if @core.all_layers(doc.layers).length() > LIMIT_MAX_LAYERS {
    return Err("层数超限")
  }
  // 资产：索引对账 + sha256 对账
  let m = MpdDoc::new(doc)
  let asset_names = z.names_under("assets/sha256/")
  for name in asset_names {
    let bytes = z.read(name)
    if bytes.length() > LIMIT_ASSET_BYTES {
      return Err("资产超限：\{name}")
    }
    let hash = @base.sha256_hex(bytes)
    if name != "assets/sha256/\{hash}" {
      return Err("资产对账失败：\{name} 内容的 sha256 是 \{hash}")
    }
    m.assets.push((hash, bytes))
  }
  for a in doc.assets {
    let mut found = false
    for pair in m.assets {
      if pair.0 == a.hash {
        found = true
        break
      }
    }
    if !found {
      return Err("文档引用的资产在容器中缺失: \{a.hash}")
    }
  }
  // agent.json 编辑历史（可选部件）
  if z.has("meta/agent.json") {
    match @core.parse_json(z.read_text("meta/agent.json")) {
      Ok(av) => match av.get("edits") {
        Some(ev) => match ev.as_arr() {
          Some(arr) => for item in arr {
            match item.as_str() {
              Some(s) => m.edits.push(s)
              None => ()
            }
          }
          None => ()
        }
        None => ()
      }
      Err(_) => () // agent.json 损坏不阻断打开（非权威部件），如实丢空
    }
  }
  // MVSL 编辑表（权威部件：渲染的真值输入，损坏或版本不符一律拒绝）
  let mvsl_decl = manifest.get("mvsl")
  if z.has("meta/mvsl.json") {
    let mvsl_text = z.read_text("meta/mvsl.json")
    let prog = match @core.program_from_json(mvsl_text) {
      Ok(p) => p
      Err(e) => return Err("meta/mvsl.json：\{e}")
    }
    match @core.validate_program(prog) {
      Ok(_) => ()
      Err(e) => return Err("meta/mvsl.json 校验失败：\{e}")
    }
    // canonical 形式是容器契约的一部分：非 canonical 字节会让
    // open→save 不再逐字节一致，属损坏而非「可容忍的格式差异」。
    let recanon = @core.program_to_json(prog)
    if recanon != mvsl_text {
      return Err("meta/mvsl.json 不是 canonical 形式（容器被改写或非本引擎产出）")
    }
    // manifest 声明的两个摘要必须与实际一致（篡改检测）
    match mvsl_decl {
      Some(mv) => {
        let declared = match mv.get("program_sha256") {
          Some(v) => match v.as_str() {
            Some(s) => s
            None => return Err("manifest.mvsl.program_sha256 不是字符串")
          }
          None => return Err("manifest.mvsl 缺 program_sha256")
        }
        let actual = @base.sha256_hex(@utf8.encode(mvsl_text))
        if declared != actual {
          return Err("编辑表指纹对账失败：manifest 记录 \{declared}，实际 \{actual}")
        }
        let rc = match mv.get("render_contract") {
          Some(v) => match v.as_num() {
            Some(n) => n
            None => return Err("manifest.mvsl.render_contract 不是数字")
          }
          None => return Err("manifest.mvsl 缺 render_contract")
        }
        if rc > @core.RENDER_CONTRACT_VERSION.to_double() {
          return Err(
            "render contract 版本 \{@core.fmt_num(rc)} 高于引擎支持的 \{@core.RENDER_CONTRACT_VERSION}，拒绝打开（不静默错渲）",
          )
        }
        let sa = match mv.get("selector_algo") {
          Some(v) => match v.as_str() {
            Some(s) => s
            None => return Err("manifest.mvsl.selector_algo 不是字符串")
          }
          None => return Err("manifest.mvsl 缺 selector_algo")
        }
        if sa != @core.SELECTOR_ALGO_VERSION {
          return Err(
            "selector 算法版本 \{sa} 与引擎的 \{@core.SELECTOR_ALGO_VERSION} 不符，拒绝打开（选择子算法变了，微调过的编辑表会漂移）",
          )
        }
        let cs = match mv.get("color_semantics") {
          Some(v) => match v.as_str() {
            Some(s) => s
            None => return Err("manifest.mvsl.color_semantics 不是字符串")
          }
          None => return Err("manifest.mvsl 缺 color_semantics")
        }
        if cs != @core.COLOR_SEMANTICS_VERSION {
          return Err(
            "色彩语义版本 \{cs} 与引擎的 \{@core.COLOR_SEMANTICS_VERSION} 不符，拒绝打开",
          )
        }
      }
      None => return Err("容器带 meta/mvsl.json 但 manifest 无 mvsl 版本块（拒绝半截状态）")
    }
    m.mvsl = prog
  } else if mvsl_decl is Some(_) {
    return Err("manifest 声明了 mvsl 但缺 meta/mvsl.json（拒绝半截状态）")
  }
  Ok(m)
}

///|
fn contains_dots(name : String) -> Bool {
  for p in name.split("/") {
    if p == ".." {
      return true
    }
  }
  false
}

///|
/// 容器签名（诊断用）。
pub fn container_signature() -> String {
  "\{@core.MPD_FORMAT_ID}/v\{@core.MPD_VERSION} (engine \{@core.ENGINE_VERSION})"
}
