/// agent —— 会话与命令分发（agent/session）。
///
/// 行协议（对齐 moonviz CLI 模式）：一行一命令，空白分隔，k=v 传参，
/// 大载荷（PNG/.mpd）走 base64。信封：成功 {"ok":true,...}（变更类必带
/// fingerprint），失败 {"error":"精确原因"}——AgentGate 零容忍。
///
/// vision 闸是硬前置：除 help/session-open 外的一切命令都要求
/// session-open full_image 已通过（引擎只服务有完整图片视觉的多模态）。

///|
pub(all) struct Session {
  mut doc : @core.Document?
  assets : Array[(String, Bytes)]
  edits : Array[String]
  mut vision_ok : Bool
  undo_stack : Array[String]
  redo_stack : Array[String]
  /// 最近一次 render 的 png sha256（vision 通道注册）
  mut last_render_hash : String
}

///|
fn is_ws(c : Char) -> Bool {
  let n = c.to_int()
  n == 32 || n == 9 || n == 10 || n == 13
}

///|
/// 弹出队首（容量护栏用；Array 无 shift，remove(0) 实现）。
fn shift_str(arr : Array[String]) -> String {
  let head = arr[0]
  let _ = arr.remove(0)
  head
}

///|
pub fn Session::new() -> Session {
  {
    doc: None,
    assets: [],
    edits: [],
    vision_ok: false,
    undo_stack: [],
    redo_stack: [],
    last_render_hash: "",
  }
}

///|
fn err(msg : String) -> String {
  "{\"error\":\"\{@core.json_escape(msg)}\"}"
}

///|
/// 命令执行入口。任何失败返回 {"error":...}，绝不半截落状态。
pub fn exec(s : Session, line : String) -> String {
  // 手工去首尾空白（避开 API 版本差异）
  let mut b = 0
  let e0 = line.length()
  let mut e = e0
  let mut go = true
  while go && b < e {
    match line.get_char(b) {
      Some(c) => if is_ws(c) { b = b + 1 } else { go = false }
      None => go = false
    }
  }
  go = true
  while go && e > b {
    match line.get_char(e - 1) {
      Some(c) => if is_ws(c) { e = e - 1 } else { go = false }
      None => go = false
    }
  }
  if e <= b {
    return err("空命令")
  }
  let trimmed = line[b:e].to_owned()
  let tokens : Array[String] = []
  for t in trimmed.split(" ") {
    if t.length() > 0 {
      tokens.push(t.to_owned())
    }
  }
  if tokens.length() == 0 {
    return err("空命令")
  }
  let verb = tokens[0]
  // ---- 无需 vision 闸的命令 ----
  if verb == "help" {
    return help_json()
  }
  if verb == "session-open" {
    return cmd_session_open(s, tokens)
  }
  if verb == "list-tools" {
    return tools_json()
  }
  // ---- vision 闸 ----
  if !s.vision_ok {
    return err(
      "vision 闸未通过：MoonPainter 只服务具备完整图片视觉的多模态模型，请先执行 `session-open full_image`",
    )
  }
  match verb {
    "new" => cmd_new(s, tokens)
    "set-canvas" => cmd_set_canvas(s, tokens)
    "list-layers" => cmd_list_layers(s)
    "query-layer" => cmd_query_layer(s, tokens)
    "add-rect" => cmd_add_shape(s, tokens, @core.ShapeKind::Rect)
    "add-ellipse" => cmd_add_shape(s, tokens, @core.ShapeKind::Ellipse)
    "add-polygon" => cmd_add_shape(s, tokens, @core.ShapeKind::Polygon)
    "add-line" => cmd_add_shape(s, tokens, @core.ShapeKind::Line)
    "add-image" => cmd_add_image(s, tokens)
    "set-style" => cmd_set_style(s, tokens)
    "move" => cmd_move(s, tokens)
    "resize" => cmd_resize(s, tokens)
    "rotate" => cmd_rotate(s, tokens)
    "flip" => cmd_flip(s, tokens)
    "rename" => cmd_rename(s, tokens)
    "tag" => cmd_tag(s, tokens)
    "delete" => cmd_delete(s, tokens)
    "visible" => cmd_visible(s, tokens)
    "reorder" => cmd_reorder(s, tokens)
    "group" => cmd_group(s, tokens)
    "ungroup" => cmd_ungroup(s, tokens)
    "list-params" => cmd_list_params(s)
    "set-param" => cmd_set_param(s, tokens)
    "render" => cmd_render(s, tokens)
    "pick" => cmd_pick(s, tokens)
    "stats" => cmd_stats(s)
    "lint" => cmd_lint(s)
    "fingerprint" => cmd_fingerprint(s)
    "inspect" => cmd_inspect(s)
    "edits" => cmd_edits(s)
    "undo" => cmd_undo(s)
    "redo" => cmd_redo(s)
    "save-mpd-b64" => cmd_save_b64(s)
    "open-mpd-b64" => cmd_open_b64(s, tokens)
    _ => err("未知命令 \{verb}（help 查看全量）")
  }
}

///|
fn cmd_session_open(s : Session, tokens : Array[String]) -> String {
  let mut ok = false
  if tokens.length() >= 2 && tokens[1] == "full_image" {
    ok = true
  }
  if !ok {
    // 也接受 vision=full_image 形态
    let m = kv_args(tokens, 1)
    if m.get("vision") is Some("full_image") {
      ok = true
    }
  }
  if ok {
    s.vision_ok = true
    "{\"ok\":true,\"op\":\"session-open\",\"vision\":\"full_image\",\"engine\":\"\{@core.ENGINE_VERSION}\"}"
  } else {
    err(
      "vision 闸拒绝：唯一合法声明是 full_image（能读取整幅渲染图并理解空间关系）。纯文本/仅 OCR 模型请换多模态模型，或改用 moonviz 做纯结构设计",
    )
  }
}

///|
fn require_doc(s : Session) -> Result[@core.Document, String] {
  match s.doc {
    Some(d) => Ok(d)
    None => Err("尚未创建文档：先执行 new <w> <h>")
  }
}

///|
/// 变更快照：撤销栈入栈、重做栈清空、编辑日志登记（带容量护栏）。
fn snapshot(s : Session, doc : @core.Document, edit_line : String) -> Unit {
  s.undo_stack.push(@core.doc_to_json(doc))
  if s.undo_stack.length() > 64 {
    let _ = shift_str(s.undo_stack)
  }
  s.redo_stack.clear()
  s.edits.push(edit_line)
  if s.edits.length() > 500 {
    let _ = shift_str(s.edits)
  }
}

///|
fn cmd_new(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：new <w> <h> [uuid=..]")
  }
  let w = match to_i(tokens[1]) {
    Some(v) => v
    None => return err("w=\{tokens[1]} 不是整数")
  }
  let h = match to_i(tokens[2]) {
    Some(v) => v
    None => return err("h=\{tokens[2]} 不是整数")
  }
  if w <= 0 || h <= 0 {
    return err("画布尺寸必须为正")
  }
  if w > @mpd.LIMIT_MAX_SIDE || h > @mpd.LIMIT_MAX_SIDE {
    return err("画布单边超限（>\{@mpd.LIMIT_MAX_SIDE}）")
  }
  if w.to_int64() * h.to_int64() > @mpd.LIMIT_MAX_PIXELS.to_int64() {
    return err("画布总像素超限")
  }
  let m = kv_args(tokens, 3)
  let uuid = match m.get("uuid") {
    Some(u) => u
    None => "doc-\{w}x\{h}"
  }
  let doc = @core.new_document(uuid, w, h)
  s.doc = Some(doc)
  s.undo_stack.clear()
  s.redo_stack.clear()
  s.edits.push("new \{w}x\{h}")
  "{\"ok\":true,\"op\":\"new\",\"uuid\":\"\{uuid}\",\"width\":\{w},\"height\":\{h},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_set_canvas(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：set-canvas <w> <h>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let w = match to_i(tokens[1]) {
    Some(v) => v
    None => return err("w=\{tokens[1]} 不是整数")
  }
  let h = match to_i(tokens[2]) {
    Some(v) => v
    None => return err("h=\{tokens[2]} 不是整数")
  }
  if w <= 0 || h <= 0 || w > @mpd.LIMIT_MAX_SIDE || h > @mpd.LIMIT_MAX_SIDE {
    return err("画布尺寸非法（1..\{@mpd.LIMIT_MAX_SIDE}）")
  }
  if w.to_int64() * h.to_int64() > @mpd.LIMIT_MAX_PIXELS.to_int64() {
    return err("画布总像素超限")
  }
  snapshot(s, doc, "set-canvas \{w}x\{h}")
  doc.width = w
  doc.height = h
  "{\"ok\":true,\"op\":\"set-canvas\",\"width\":\{w},\"height\":\{h},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn layer_summary(l : @core.Layer) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":\"\{l.id}\",\"name\":\"\{@core.json_escape(l.name)}\"")
  sb.write_string(",\"kind\":\"\{kind_str(l.kind)}\"")
  sb.write_string(",\"x\":\{@core.fmt_num(l.x)},\"y\":\{@core.fmt_num(l.y)},\"w\":\{@core.fmt_num(l.w)},\"h\":\{@core.fmt_num(l.h)}")
  sb.write_string(",\"visible\":\{l.visible}")
  sb.write_string(",\"opacity\":\{@core.fmt_num(l.opacity)}")
  sb.write_string(",\"blend\":\"\{blend_str(l.blend)}\"")
  sb.write_string(",\"rot\":\{@core.fmt_num(l.rotation_deg)}")
  if l.asset_hash != "" {
    sb.write_string(",\"asset\":\"\{l.asset_hash}\"")
  }
  if l.tags.length() > 0 {
    sb.write_string(",\"tags\":[")
    let mut f = true
    for t in l.tags {
      if f {
        f = false
      } else {
        sb.write_string(",")
      }
      sb.write_string("\"\{@core.json_escape(t)}\"")
    }
    sb.write_string("]")
  }
  if l.children.length() > 0 {
    sb.write_string(",\"children\":[")
    let mut f = true
    for c in l.children {
      if f {
        f = false
      } else {
        sb.write_string(",")
      }
      sb.write_string(layer_summary(c))
    }
    sb.write_string("]")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
fn kind_str(k : @core.ShapeKind) -> String {
  match k {
    @core.ShapeKind::Rect => "rect"
    @core.ShapeKind::Ellipse => "ellipse"
    @core.ShapeKind::Line => "line"
    @core.ShapeKind::Polygon => "polygon"
    @core.ShapeKind::Image => "image"
    @core.ShapeKind::Group => "group"
  }
}

///|
fn blend_str(b : @core.BlendMode) -> String {
  match b {
    @core.BlendMode::Normal => "normal"
    @core.BlendMode::Multiply => "multiply"
    @core.BlendMode::Screen => "screen"
    @core.BlendMode::Overlay => "overlay"
    @core.BlendMode::Darken => "darken"
    @core.BlendMode::Lighten => "lighten"
    @core.BlendMode::Difference => "difference"
  }
}

///|
fn cmd_list_layers(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"list-layers\",\"count\":\{doc.layers.length()},\"layers\":[")
  let mut f = true
  for l in doc.layers {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(layer_summary(l))
  }
  sb.write_string("],\"fingerprint\":\"\{@core.fingerprint(doc)}\"}")
  sb.to_string()
}

///|
fn cmd_query_layer(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：query-layer <id>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  match @core.find_layer(doc.layers, tokens[1]) {
    Some(l) => "{\"ok\":true,\"op\":\"query-layer\",\"layer\":\{layer_summary(l)}}"
    None => err("层不存在：\{tokens[1]}")
  }
}

///|
fn cmd_add_shape(
  s : Session,
  tokens : Array[String],
  kind : @core.ShapeKind,
) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let id = match m.get("id") {
    Some(i) => i
    None => @core.alloc_layer_id(doc)
  }
  if @core.find_layer(doc.layers, id) is Some(_) {
    return err("层 id 已存在：\{id}")
  }
  let layer = match build_shape_layer(id, kind, m) {
    Ok(l) => l
    Err(e) => return err(e)
  }
  snapshot(s, doc, "add \{kind_str(kind)} \{id}")
  doc.layers.push(layer)
  "{\"ok\":true,\"op\":\"add-\{kind_str(kind)}\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_add_image(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let b64 = match m.get("b64") {
    Some(v) => v
    None => return err("add-image 需要 b64=<png base64>")
  }
  let bytes : Bytes = @base64.decode(b64) catch {
    _ => return err("b64 载荷解码失败")
  }
  let img = match @codec.png_decode(bytes) {
    Ok(i) => i
    Err(e) => return err("PNG 解码失败：\{e}")
  }
  let hash = @base.sha256_hex(bytes)
  // 登记资产（幂等）
  let mut already = false
  for pair in s.assets {
    if pair.0 == hash {
      already = true
    }
  }
  if !already {
    s.assets.push((hash, bytes))
  }
  let mut doc_has = false
  for a in doc.assets {
    if a.hash == hash {
      doc_has = true
    }
  }
  if !doc_has {
    doc.assets.push({ hash, width: img.width, height: img.height })
  }
  let id = match m.get("id") {
    Some(i) => i
    None => @core.alloc_layer_id(doc)
  }
  let layer = match build_shape_layer(id, @core.ShapeKind::Image, m) {
    Ok(l) => l
    Err(e) => return err(e)
  }
  let layer2 = { ..layer, asset_hash: hash }
  snapshot(s, doc, "add image \{id} asset=\{hash[0:8].to_owned()}")
  doc.layers.push(layer2)
  "{\"ok\":true,\"op\":\"add-image\",\"id\":\"\{id}\",\"asset\":\"\{hash}\",\"asset_size\":\"\{img.width}x\{img.height}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_set_style(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：set-style <id> [fill=..] [lgrad=..] [stroke=..] [stroke_w=..] [opacity=..] [blend=..] [radius=..] [rot=..] [visible=..] [name=..]")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  // 快照必须在任何修改之前（其他命令同此纪律；此前误放在修改后，
  // 导致 undo 恢复的是已改状态——e2e 抓出）。
  snapshot(s, doc, "set-style \{id}")
  let m = kv_args(tokens, 2)
  let mut applied = false
  let r = update_layer(doc.layers, id, fn(l) {
      applied = true
      match apply_style_kv(l, m) {
        Ok(nl) => nl
        Err(_) => l // 错误在下面统一报（闭包不便传播）
      }
    })
  if !r {
    return err("层不存在：\{id}")
  }
  // 二次校验：apply_style_kv 可能失败，重新单独跑一遍拿错误
  let probe = @core.find_layer(doc.layers, id)
  let newl = match probe {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  let check = apply_style_kv(newl, m)
  if check is Err(_) {
    let msg = match check {
      Err(e) => e
      Ok(_) => ""
    }
    // 应用前先校验：这里说明闭包里失败了但层已被改成原样（apply 失败时返回原层）
    // 为保证零容忍，撤销这次 no-op 并报错
    let _ = applied
    return err(msg)
  }
  "{\"ok\":true,\"op\":\"set-style\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_move(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 4 {
    return err("用法：move <id> <x> <y>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let x = match to_d(tokens[2]) {
    Some(v) => v
    None => return err("x=\{tokens[2]} 不是数字")
  }
  let y = match to_d(tokens[3]) {
    Some(v) => v
    None => return err("y=\{tokens[3]} 不是数字")
  }
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "move \{id}")
  let ok = update_layer(doc.layers, id, fn(l) { { ..l, x, y } })
  if ok {
    "{\"ok\":true,\"op\":\"move\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
  } else {
    err("层不存在：\{id}")
  }
}

///|
fn cmd_resize(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 4 {
    return err("用法：resize <id> <w> <h>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let w = match to_d(tokens[2]) {
    Some(v) => v
    None => return err("w=\{tokens[2]} 不是数字")
  }
  let h = match to_d(tokens[3]) {
    Some(v) => v
    None => return err("h=\{tokens[3]} 不是数字")
  }
  if w <= 0.0 || h <= 0.0 {
    return err("w/h 必须为正")
  }
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "resize \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, w, h } })
  "{\"ok\":true,\"op\":\"resize\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_rotate(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：rotate <id> <deg>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let deg = match to_d(tokens[2]) {
    Some(v) => v
    None => return err("deg=\{tokens[2]} 不是数字")
  }
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "rotate \{id} \{@core.fmt_num(deg)}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, rotation_deg: deg } })
  "{\"ok\":true,\"op\":\"rotate\",\"id\":\"\{id}\",\"rot\":\{@core.fmt_num(deg)},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_flip(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：flip <id> h|v|both|none")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let (fh, fv) = match tokens[2] {
    "h" => (true, false)
    "v" => (false, true)
    "both" => (true, true)
    "none" => (false, false)
    _ => return err("flip 方向应为 h/v/both/none")
  }
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "flip \{id} \{tokens[2]}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, flip_h: fh, flip_v: fv } })
  "{\"ok\":true,\"op\":\"flip\",\"id\":\"\{id}\",\"flip_h\":\{fh},\"flip_v\":\{fv},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_rename(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：rename <id> <new-name>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let name = tokens[2]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "rename \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, name } })
  "{\"ok\":true,\"op\":\"rename\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_tag(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：tag <id> <tag>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let tag = tokens[2]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "tag \{id} \{tag}")
  let _ = update_layer(doc.layers, id, fn(l) {
    let tags = l.tags.copy()
    let mut dup = false
    for t in tags {
      if t == tag {
        dup = true
      }
    }
    if !dup {
      tags.push(tag)
    }
    { ..l, tags }
  })
  "{\"ok\":true,\"op\":\"tag\",\"id\":\"\{id}\",\"tag\":\"\{tag}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_delete(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：delete <id>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "delete \{id}")
  let removed = remove_layer(doc.layers, id)
  if removed {
    "{\"ok\":true,\"op\":\"delete\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
  } else {
    err("删除失败：\{id}")
  }
}

///|
fn cmd_visible(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：visible <id> <true|false>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let vis = if tokens[2] == "true" || tokens[2] == "1" {
    true
  } else if tokens[2] == "false" || tokens[2] == "0" {
    false
  } else {
    return err("visible 取值应为 true/false")
  }
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "visible \{id} \{vis}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, visible: vis } })
  "{\"ok\":true,\"op\":\"visible\",\"id\":\"\{id}\",\"visible\":\{vis},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 定位包含某 id 的数组（返回数组引用，供 reorder/group 移动槽位）。
fn locate_container(
  layers : Array[@core.Layer],
  id : String,
) -> Array[@core.Layer]? {
  for l in layers {
    if l.id == id {
      return Some(layers)
    }
  }
  for l in layers {
    match locate_container(l.children, id) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  None
}

///|
fn cmd_reorder(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：reorder <id> front|back|up|down")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let how = tokens[2]
  let arr = match locate_container(doc.layers, id) {
    Some(a) => a
    None => return err("层不存在：\{id}")
  }
  let mut idx = -1
  let mut i = 0
  while i < arr.length() {
    if arr[i].id == id {
      idx = i
    }
    i = i + 1
  }
  if idx < 0 {
    return err("层不存在：\{id}")
  }
  let target = match how {
    "front" => arr.length() - 1 // 顶层（数组尾）
    "back" => 0
    "up" => if idx + 1 < arr.length() { idx + 1 } else { idx }
    "down" => if idx - 1 >= 0 { idx - 1 } else { idx }
    _ => return err("reorder 方向应为 front/back/up/down")
  }
  if target == idx {
    return "{\"ok\":true,\"op\":\"reorder\",\"id\":\"\{id}\",\"moved\":false,\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
  }
  snapshot(s, doc, "reorder \{id} \{how}")
  let l = arr[idx]
  let _ = arr.remove(idx)
  arr.insert(target, l)
  "{\"ok\":true,\"op\":\"reorder\",\"id\":\"\{id}\",\"moved\":true,\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_group(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 4 {
    return err("用法：group <gid> <id1> <id2> ...（成员须为根级层）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let gid = tokens[1]
  if @core.find_layer(doc.layers, gid) is Some(_) {
    return err("层 id 已存在：\{gid}")
  }
  // 校验成员：必须都在根级
  let member_ids : Array[String] = []
  let mut i = 2
  while i < tokens.length() {
    member_ids.push(tokens[i])
    i = i + 1
  }
  let mut min_idx = doc.layers.length()
  let children : Array[@core.Layer] = []
  for mid in member_ids {
    let mut idx = -1
    let mut k = 0
    while k < doc.layers.length() {
      if doc.layers[k].id == mid {
        idx = k
      }
      k = k + 1
    }
    if idx < 0 {
      return err("成员 \{mid} 不是根级层（嵌套编组请先 ungroup）")
    }
    if idx < min_idx {
      min_idx = idx
    }
  }
  // 按根级顺序收集成员
  let mut k = 0
  while k < doc.layers.length() {
    for mid in member_ids {
      if doc.layers[k].id == mid {
        children.push(doc.layers[k])
      }
    }
    k = k + 1
  }
  snapshot(s, doc, "group \{gid} (\{children.length()})")
  // 从后往前移除成员，再在 min_idx 插入组
  let mut rm = member_ids.length() - 1
  while rm >= 0 {
    let mut k2 = doc.layers.length() - 1
    while k2 >= 0 {
      if doc.layers[k2].id == member_ids[rm] {
        let _ = doc.layers.remove(k2)
        break
      }
      k2 = k2 - 1
    }
    rm = rm - 1
  }
  let g = {
    ..@core.default_layer(
        gid,
        gid,
        0.0,
        0.0,
        doc.width.to_double(),
        doc.height.to_double(),
      ),
    kind: @core.ShapeKind::Group,
    fill: @core.Fill::NoFill,
    children,
  }
  doc.layers.insert(min_idx, g)
  "{\"ok\":true,\"op\":\"group\",\"id\":\"\{gid}\",\"members\":\{children.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_ungroup(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：ungroup <gid>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let gid = tokens[1]
  let g = match @core.find_layer(doc.layers, gid) {
    Some(l) => l
    None => return err("层不存在：\{gid}")
  }
  if !(g.kind is @core.ShapeKind::Group) {
    return err("层 \{gid} 不是组")
  }
  snapshot(s, doc, "ungroup \{gid}")
  let arr = match locate_container(doc.layers, gid) {
    Some(a) => a
    None => return err("定位失败：\{gid}")
  }
  let mut idx = -1
  let mut i = 0
  while i < arr.length() {
    if arr[i].id == gid {
      idx = i
    }
    i = i + 1
  }
  let _ = arr.remove(idx)
  let mut offset = 0
  for c in g.children {
    arr.insert(idx + offset, c)
    offset = offset + 1
  }
  "{\"ok\":true,\"op\":\"ungroup\",\"id\":\"\{gid}\",\"restored\":\{g.children.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_list_params(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"list-params\",\"count\":\{doc.params.length()},\"named\":[")
  let mut f = true
  for p in doc.params {
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
fn cmd_set_param(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：set-param <name> <value>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let name = tokens[1]
  let value = tokens[2]
  snapshot(s, doc, "set-param \{name}")
  // 同名覆盖，否则追加
  let mut replaced = false
  let next : Array[@core.Param] = []
  for p in doc.params {
    if p.name == name {
      next.push({ name, value })
      replaced = true
    } else {
      next.push(p)
    }
  }
  if !replaced {
    next.push({ name, value })
  }
  doc.params.clear()
  for p in next {
    doc.params.push(p)
  }
  "{\"ok\":true,\"op\":\"set-param\",\"name\":\"\{@core.json_escape(name)}\",\"value\":\"\{@core.json_escape(value)}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 会话渲染环境（解码全部资产）。
fn session_env(s : Session) -> Result[@render.RenderEnv, String] {
  let env = @render.RenderEnv::new()
  for pair in s.assets {
    match @codec.png_decode(pair.1) {
      Ok(img) => env.assets.set(pair.0, img)
      Err(e) => return Err("资产 \{pair.0} 解码失败: \{e}")
    }
  }
  Ok(env)
}

///|
fn cmd_render(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  // render [width] [vx0 vy0 vx1 vy1]
  let mut width = 1024
  let mut vx0 = 0.0
  let mut vy0 = 0.0
  let mut vx1 = 1.0
  let mut vy1 = 1.0
  let mut i = 1
  if tokens.length() >= 2 {
    match to_i(tokens[1]) {
      Some(w) => width = w
      None => return err("width=\{tokens[1]} 不是整数")
    }
  }
  if tokens.length() >= 6 {
    // 取景四元组
    let nums : Array[Double] = []
    let mut k = 2
    while k < 6 {
      match to_d(tokens[k]) {
        Some(v) => nums.push(v)
        None => return err("viewport 参数 \{tokens[k]} 不是数字")
      }
      k = k + 1
    }
    vx0 = nums[0]
    vy0 = nums[1]
    vx1 = nums[2]
    vy1 = nums[3]
    i = 6
  }
  let _ = i
  let env = match session_env(s) {
    Ok(e) => e
    Err(e) => return err(e)
  }
  // overlay=1：叠加层 bbox 序号线框（视觉通道的像素↔结构对位辅助）
  let mut overlay = false
  for t in tokens {
    if t == "overlay=1" || t == "overlay=true" {
      overlay = true
    }
  }
  let rendered : Result[@codec.RgbaBuf, String] = if overlay {
    @render.render_view_overlay(doc, env, vx0, vy0, vx1, vy1, width)
  } else {
    @render.render_view(doc, env, vx0, vy0, vx1, vy1, width)
  }
  let buf = match rendered {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let png = @codec.png_encode(buf)
  let hash = @base.sha256_hex(png)
  s.last_render_hash = hash
  let b64 = @base64.encode(png)
  "{\"ok\":true,\"op\":\"render\",\"width\":\{buf.width},\"height\":\{buf.height},\"overlay\":\{overlay},\"png_b64\":\"\{b64}\",\"render_sha256\":\"\{hash}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_pick(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：pick <x> <y>（画布像素坐标）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let x = match to_d(tokens[1]) {
    Some(v) => v
    None => return err("x=\{tokens[1]} 不是数字")
  }
  let y = match to_d(tokens[2]) {
    Some(v) => v
    None => return err("y=\{tokens[2]} 不是数字")
  }
  match @render.pick(doc, x, y) {
    Some(id) => "{\"ok\":true,\"op\":\"pick\",\"x\":\{@core.fmt_num(x)},\"y\":\{@core.fmt_num(y)},\"id\":\"\{id}\"}"
    None => "{\"ok\":true,\"op\":\"pick\",\"x\":\{@core.fmt_num(x)},\"y\":\{@core.fmt_num(y)},\"id\":null}"
  }
}

///|
fn cmd_stats(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let env = match session_env(s) {
    Ok(e) => e
    Err(e) => return err(e)
  }
  let buf = @render.render_doc(doc, env)
  let png = @codec.png_encode(buf)
  s.last_render_hash = @base.sha256_hex(png)
  let st = @render.stats(buf)
  // stats 返回的本身就是 JSON 对象文本
  "{\"ok\":true,\"op\":\"stats\",\{st[1:].to_owned()}"
}

///|
fn cmd_lint(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let v = lint_doc(doc)
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"lint\",\"violations\":\{v.length()},\"items\":[")
  let mut f = true
  for item in v {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{@core.json_escape(item)}\"")
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
fn cmd_fingerprint(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  "{\"ok\":true,\"op\":\"fingerprint\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 元参数层实时视图：manifest 摘要 + canonical design.json 全文 +
/// params / 编辑历史。PLAN §6 承诺的 inspect（分页全文）——当前文档量级
/// 一次性返回即可，分页在 >4MiB 限额逼近时再引入（诚实边界）。
fn cmd_inspect(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let layers_n = @core.all_layers(doc.layers).length()
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"inspect\",\"manifest\":{")
  sb.write_string("\"format\":\"\{@core.MPD_FORMAT_ID}\",\"version\":\{@core.MPD_VERSION},\"engine\":\"\{@core.ENGINE_VERSION}\"")
  sb.write_string(",\"uuid\":\"\{doc.uuid}\",\"canvas\":{\"w\":\{doc.width},\"h\":\{doc.height}}")
  sb.write_string(",\"counts\":{\"layers\":\{layers_n},\"assets\":\{doc.assets.length()},\"params\":\{doc.params.length()}}")
  sb.write_string(",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}")
  sb.write_string(",\"design\":")
  sb.write_string(@core.doc_to_json(doc))
  sb.write_string(",\"params\":[")
  let mut f = true
  for p in doc.params {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"name\":\"\{@core.json_escape(p.name)}\",\"value\":\"\{@core.json_escape(p.value)}\"}")
  }
  sb.write_string("],\"edits\":[")
  let mut f2 = true
  for e in s.edits {
    if f2 {
      f2 = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{@core.json_escape(e)}\"")
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
fn cmd_edits(s : Session) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"edits\",\"count\":\{s.edits.length()},\"edits\":[")
  let mut f = true
  for e in s.edits {
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
fn cmd_undo(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  if s.undo_stack.length() == 0 {
    return err("撤销栈为空")
  }
  let snap = s.undo_stack[s.undo_stack.length() - 1]
  let _ = s.undo_stack.pop()
  s.redo_stack.push(@core.doc_to_json(doc))
  match @core.doc_from_json(snap) {
    Ok(prev) => {
      s.doc = Some(prev)
      s.edits.push("undo")
      "{\"ok\":true,\"op\":\"undo\",\"fingerprint\":\"\{@core.fingerprint(prev)}\"}"
    }
    Err(e) => err("撤销快照损坏：\{e}")
  }
}

///|
fn cmd_redo(s : Session) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  if s.redo_stack.length() == 0 {
    return err("重做栈为空")
  }
  let snap = s.redo_stack[s.redo_stack.length() - 1]
  let _ = s.redo_stack.pop()
  s.undo_stack.push(@core.doc_to_json(doc))
  match @core.doc_from_json(snap) {
    Ok(next) => {
      s.doc = Some(next)
      s.edits.push("redo")
      "{\"ok\":true,\"op\":\"redo\",\"fingerprint\":\"\{@core.fingerprint(next)}\"}"
    }
    Err(e) => err("重做快照损坏：\{e}")
  }
}

///|
/// 当前会话打包含器（cli 的 save-mpd / save-mpd-b64 底座）。
pub fn pack_current(s : Session) -> Result[Bytes, String] {
  let doc = match s.doc {
    Some(d) => d
    None => return Err("尚未创建文档：先执行 new <w> <h>")
  }
  let m = @mpd.MpdDoc::new(doc)
  for pair in s.assets {
    m.add_asset(pair.0, pair.1)
  }
  for e in s.edits {
    m.edits.push(e)
  }
  @mpd.pack(m)
}

///|
fn cmd_save_b64(s : Session) -> String {
  match pack_current(s) {
    Ok(bytes) => {
      let fp = match s.doc {
        Some(d) => @core.fingerprint(d)
        None => ""
      }
      "{\"ok\":true,\"op\":\"save-mpd-b64\",\"mpd_b64\":\"\{@base64.encode(bytes)}\",\"fingerprint\":\"\{fp}\"}"
    }
    Err(e) => err(e)
  }
}

///|
/// 从容器字节载入会话（cli 的 open-mpd / open-mpd-b64 底座）。
pub fn load_mpd(s : Session, bytes : Bytes) -> Result[String, String] {
  let m = match @mpd.unpack(bytes) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  s.doc = Some(m.doc)
  s.assets.clear()
  for pair in m.assets {
    s.assets.push(pair)
  }
  s.edits.clear()
  for e in m.edits {
    s.edits.push(e)
  }
  // 不追加 "open-mpd" 伪条目：打开容器不篡改编辑历史，
  // 从而 open→save 必须字节一致（verify.sh 第 5 步的确定性闭环）。
  s.undo_stack.clear()
  s.redo_stack.clear()
  Ok(@core.fingerprint(m.doc))
}

///|
fn cmd_open_b64(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：open-mpd-b64 <mpd-base64>")
  }
  let bytes : Bytes = @base64.decode(tokens[1]) catch {
    _ => return err("b64 载荷解码失败")
  }
  match load_mpd(s, bytes) {
    Ok(fp) => "{\"ok\":true,\"op\":\"open-mpd-b64\",\"fingerprint\":\"\{fp}\"}"
    Err(e) => err(e)
  }
}

///|
fn help_json() -> String {
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"help\",\"tools\":[")
  let mut f = true
  for t in list_tools() {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"name\":\"\{t.name}\",\"channel\":\"\{t.channel}\",\"desc\":\"\{@core.json_escape(t.description)}\"}")
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
fn tools_json() -> String {
  help_json()
}
