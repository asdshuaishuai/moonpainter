/// agent —— PSD 导入（③ PSD 兼容 · 读的**出口**：把 PSD 变成文档）。
///
/// 分工：`codec/psd.mbt` 只把字节解成 `PsdImage`（不认识文档模型）；
/// 这里把 `PsdImage` 变成 `.mpd` 文档 —— 每个 PSD 图层一个 `Image` 层
/// （像素经 PNG 编码进**内容寻址资产**，"像素资产只增不改"照旧）。
///
/// 三条纪律：
/// 1. **一层一个资产**：PNG 编码走 `@codec.png_encode`、登记走 `place_asset`
///    （与 `add-image` 同一条路径）——不新建第二条"塞像素"的路。
/// 2. **不降级的边界声明在 codec 里**：读不了的（16 位/CMYK/ZIP/组/真蒙版/图层
///    效果）在 `psd_decode` 就报错，这一层不做任何"猜"或"降级"。
/// 3. **层序就是渲染序**：PSD 里解码出来的顺序（与 psd-tools 一致、自底向上）
///    直接进 `doc.layers`，不重排、不反转。
///
/// 单位与映射（写进字典）：
/// - `opacity`：PSD 是 0..255，本仓库是 0..1（`/255`，唯一一处换算）。
/// - 混合模式：PSD 的 7 种签名 ↔ 本仓库 7 种（`codec.psd_blend_name` 一处，
///   反向走 `@agent.parse_blend`）。
/// - `x/y/w/h`：PSD 的图层矩形就是画布像素坐标（可伸出画布；本仓库允许）。
/// - 名字：`luni` 优先，退回 Pascal 名。

///|
/// 一份 PSD 资产字节（b64）→ 文档。`id_prefix` 用来给导入的层起名/占 id。
fn psd_doc_of(
  s : Session,
  psd : @codec.PsdImage,
  uuid : String,
) -> Result[@core.Document, String] {
  let doc = @core.new_document(uuid, psd.width, psd.height)
  // 0 层的 PSD（"拼合文件"）不是错误：它是**只有合成图**的合法 PSD。
  // 此时把合成图当成唯一一层导进来 —— 这是"读到了什么就放什么"，
  // 不是降级（PSD 里确实只有这一张图）。
  if psd.layers.length() == 0 {
    let png = match psd_rgba_png(psd.composite, psd.width, psd.height) {
      Err(e) => return Err(e)
      Ok(b) => b
    }
    let (hash, _iw, _ih) = match place_asset(s, doc, png) {
      Err(e) => return Err(e)
      Ok(t) => t
    }
    let layer = @core.Layer::{
      id: "l1",
      name: "composite",
      kind: @core.ShapeKind::Image,
      visible: true,
      opacity: 1.0,
      blend: @core.BlendMode::Normal,
      x: 0.0,
      y: 0.0,
      w: psd.width.to_double(),
      h: psd.height.to_double(),
      rotation_deg: 0.0,
      corner_radius: 0.0,
      flip_h: false,
      flip_v: false,
      text: "",
      font_size: 0.0,
      text_style: None,
      mask: None,
      adjust: None,
      fx: None,
      points: [],
      handles: [],
      dabs: [],
      fill: @core.Fill::NoFill,
      stroke: @core.Stroke::{ color: 0, width: 0.0 },
      asset_hash: hash,
      tags: [],
      children: [],
    }
    let doc2 = { ..doc, layers: [layer], next_layer_no: 2 }
    return Ok(doc2)
  }
  let layers : Array[@core.Layer] = []
  let mut i = 0
  let used : Map[String, Bool] = Map([])
  while i < psd.layers.length() {
    let pl = psd.layers[i]
    let png = match psd_rgba_png(pl.rgba, pl.w, pl.h) {
      Err(e) => return Err("图层 \{pl.name}：\{e}")
      Ok(b) => b
    }
    let (hash, _iw, _ih) = match place_asset(s, doc, png) {
      Err(e) => return Err("图层 \{pl.name}：\{e}")
      Ok(t) => t
    }
    let blend = match parse_blend(pl.blend) {
      Err(e) => return Err("图层 \{pl.name}：\{e}")
      Ok(b) => b
    }
    let id = psd_layer_id(pl.name, i + 1, used)
    used.set(id, true)
    layers.push({
      id,
      name: psd_layer_display_name(pl.name, i + 1),
      kind: @core.ShapeKind::Image,
      visible: pl.visible,
      // ⚠️ 唯一一处 0..255 → 0..1 换算。
      opacity: pl.opacity.to_double() / 255.0,
      blend,
      x: pl.x.to_double(),
      y: pl.y.to_double(),
      w: pl.w.to_double(),
      h: pl.h.to_double(),
      rotation_deg: 0.0,
      corner_radius: 0.0,
      flip_h: false,
      flip_v: false,
      text: "",
      font_size: 0.0,
      text_style: None,
      mask: None,
      adjust: None,
      fx: None,
      points: [],
      handles: [],
      dabs: [],
      fill: @core.Fill::NoFill,
      stroke: @core.Stroke::{ color: 0, width: 0.0 },
      asset_hash: hash,
      tags: [],
      children: [],
    })
    i = i + 1
  }
  Ok({ ..doc, layers, next_layer_no: psd.layers.length() + 1 })
}

///|
/// 层 id：PSD 层名不是 id（可能为空、带空格、重名）——一律用 `l<n>`，
/// 并从 1 开始试到不重（PSD 层名里出现过的 id 不冲突，因为 id 空间是
/// 整个文档，这里只保证导入的层之间不撞）。
fn psd_layer_id(_name : String, n : Int, used : Map[String, Bool]) -> String {
  let mut k = n
  while true {
    let id = "l\{k}"
    match used.get(id) {
      None => return id
      Some(_) => k = k + 1
    }
  }
  ""
}

///|
/// 层显示名：PSD 里可以没有名字（占位）——给一个说得清的名字，别让
/// `query-layer` 报出一个空字符串（"能打上的名字必须能摘下"的反面：名字空着
/// 就没人能引用它）。
fn psd_layer_display_name(name : String, n : Int) -> String {
  if name.length() == 0 {
    "layer \{n}"
  } else {
    name
  }
}

///|
/// RGBA（w*h*4，非预乘）→ PNG 字节。RgbaBuf 是 0xAARRGGBB：这一处换算，
/// 别在别处再写一遍。
fn psd_rgba_png(rgba : Array[Byte], w : Int, h : Int) -> Result[Bytes, String] {
  if w <= 0 || h <= 0 {
    return Err("尺寸非正（\{w}×\{h}）—— 空图层的矩形为零，导不进来")
  }
  if rgba.length() != w * h * 4 {
    return Err("像素长度 \{rgba.length()} ≠ w×h×4（\{w * h * 4}）")
  }
  let buf = @codec.rgba_new(w, h)
  let mut i = 0
  while i < w * h {
    let r = rgba[i * 4].to_int() & 0xFF
    let g = rgba[i * 4 + 1].to_int() & 0xFF
    let b = rgba[i * 4 + 2].to_int() & 0xFF
    let a = rgba[i * 4 + 3].to_int() & 0xFF
    @codec.rgba_set(buf, i % w, i / w, (a << 24) | (r << 16) | (g << 8) | b)
    i = i + 1
  }
  Ok(@codec.png_encode(buf))
}

///|
/// `psd-info b64=<base64>`：只报结构，**不改会话**（先看得见"会读成什么"，
/// 再决定要不要 `open-psd`）。
pub fn cmd_psd_info(s : Session, tokens : Array[String]) -> String {
  let _ = s
  match check_kv_args(tokens, 1, ["b64"], "psd-info") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let b64 = match m.get("b64") {
    Some(v) => v
    None => return err("psd-info 需要 b64=<psd base64>")
  }
  let bytes = match decode_b64(b64) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let img = match @codec.psd_decode(bytes) {
    Ok(i) => i
    Err(e) => return err(e)
  }
  let layer_jsons : Array[String] = []
  for l in img.layers {
    layer_jsons.push(
      "{\"name\":\"\{@core.json_escape(l.name)}\",\"x\":\{l.x},\"y\":\{l.y},\"w\":\{l.w},\"h\":\{l.h},\"opacity\":\{l.opacity},\"visible\":\{l.visible},\"blend\":\"\{l.blend}\"}",
    )
  }
  let dropped = if img.layers.length() == 0 { "composite-only" } else { "" }
  "{\"ok\":true,\"op\":\"psd-info\",\"width\":\{img.width},\"height\":\{img.height},\"channels\":\{img.channels},\"layers\":\{img.layers.length()},\"layer_table\":[\{layer_jsons.join(",")}],\"note\":\"\{dropped}\",\"composite_sha256\":\"\{@base.sha256_hex(Bytes::from_array(img.composite))}\"}"
}

///|
/// `open-psd b64=<base64> [uuid=..]`：把 PSD 打开成当前文档（**替换**会话文档，
/// 与 `new`/`open-mpd-b64` 同一语义：都换掉整份文档）。
pub fn cmd_open_psd(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, ["b64", "uuid"], "open-psd") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let b64 = match m.get("b64") {
    Some(v) => v
    None => return err("open-psd 需要 b64=<psd base64>")
  }
  let bytes = match decode_b64(b64) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let img = match @codec.psd_decode(bytes) {
    Ok(i) => i
    Err(e) => return err(e)
  }
  let uuid = match m.get("uuid") {
    Some(u) => u
    None => "psd-\{img.width}x\{img.height}"
  }
  let doc = match psd_doc_of(s, img, uuid) {
    Err(e) => return err(e)
    Ok(d) => d
  }
  let fp = @core.fingerprint(doc)
  let n = doc.layers.length()
  s.doc = Some(doc)
  "{\"ok\":true,\"op\":\"open-psd\",\"width\":\{img.width},\"height\":\{img.height},\"layers\":\{n},\"fingerprint\":\"\{fp}\"}"
}
