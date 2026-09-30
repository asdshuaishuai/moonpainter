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
  /// 当前 MVSL 编辑表（人机同一 IR：GUI 操作与 AI 工具调用走同一张表、
  /// 同一撤销栈；渲染的真值输入，随 .mpd 的 meta/mvsl.json 落盘）
  mut mvsl : @core.EditProgram
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
    mvsl: @core.EditProgram::new(),
  }
}

///|
fn err(msg : String) -> String {
  "{\"error\":\"\{@core.json_escape(msg)}\"}"
}

///|
/// 命令行分词：按空白切分，**双引号包裹的片段整体算一个 token**（引号内的
/// 空格不参与切分）；`\"` 表示字面引号。引号可以出现在 token 中间，所以
/// `text="Hello World"` 与 `name="My Layer"` 都按预期工作。
///
/// 为什么需要它：协议里原本只有"下划线代替空格"这一说——它写在 `add-text`
/// 的错误提示里、前端 `do_text_add` 也真的把空格换成了下划线，**但引擎从未
/// 实现还原**。于是用户在前端输入 "Hello World"，存进去和渲染出来的都是
/// 带下划线的 `Hello_World`。引号既不必牺牲下划线（`_` 仍是字面下划线，
/// 历史行为完全不变），也不用发明新编码。
///
/// 未闭合的引号按字面处理（把已读部分当作普通 token），不报错——命令行
/// 协议的错误一律由各命令自己给，分词器不制造新的失败面。
fn tokenize_line(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut sb = StringBuilder()
  let mut in_quote = false
  let mut started = false
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.get_char(i).unwrap_or(' ')
    i = i + 1
    if in_quote {
      if c == '"' {
        in_quote = false
      } else if c == '\\' && i < n {
        let c2 = s.get_char(i).unwrap_or(c)
        i = i + 1
        sb.write_char(c2)
      } else {
        sb.write_char(c)
      }
    } else if c == '"' {
      in_quote = true
      started = true
    } else if is_ws(c) {
      if started {
        out.push(sb.to_string())
        sb = StringBuilder()
        started = false
      }
    } else {
      sb.write_char(c)
      started = true
    }
  }
  if started {
    out.push(sb.to_string())
  }
  out
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
  let tokens = tokenize_line(trimmed)
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
    "add-text" => cmd_add_text(s, tokens)
    "set-text" => cmd_set_text(s, tokens)
    "add-paint" => cmd_add_paint(s, tokens)
    "brush" => cmd_brush(s, tokens, false)
    "erase" => cmd_brush(s, tokens, true)
    "crop" => cmd_crop(s, tokens)
    "sample" => cmd_sample(s, tokens)
    "add-adjust" => cmd_add_adjust(s, tokens)
    "add-mask" => cmd_add_mask(s, tokens)
    "set-mask" => cmd_set_mask(s, tokens)
    "remove-mask" => cmd_remove_mask(s, tokens)
    "list-params" => cmd_list_params(s)
    "set-param" => cmd_set_param(s, tokens)
    "render" => cmd_render(s, tokens)
    "pick" => cmd_pick(s, tokens)
    "stats" => cmd_stats(s)
    // 区域级 affordance（census 破除「先定位才能普查」的循环依赖）
    "census" => cmd_census(s, tokens)
    "probe" => cmd_probe(s, tokens)
    // 语法自证：示例由 canonical 写出器产出、由同一解析器验回（文档不漂移）
    "sel-schema" => cmd_sel_schema(s, tokens)
    "lint" => cmd_lint(s)
    "fingerprint" => cmd_fingerprint(s)
    "inspect" => cmd_inspect(s)
    "edits" => cmd_edits(s)
    "undo" => cmd_undo(s)
    "redo" => cmd_redo(s)
    // MVSL 编辑表（PLAN-MVSL §4 P1 闭环 affordance）
    "mvsl-set" => cmd_mvsl_set(s, tokens)
    "mvsl-show" => cmd_mvsl_show(s)
    "mvsl-clear" => cmd_mvsl_clear(s)
    "select-preview" => cmd_select_preview(s, tokens)
    "mvsl-impact" => cmd_mvsl_impact(s, tokens)
    "mvsl-assert" => cmd_mvsl_assert(s)
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
  if l.text != "" {
    sb.write_string(",\"text\":\"\{@core.json_escape(l.text)}\"")
    sb.write_string(",\"font_size\":\{@core.fmt_num(l.font_size)}")
  }
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
  match l.mask {
    Some(m) =>
      sb.write_string(
        ",\"mask\":{\"kind\":\"\{kind_str(m.kind)}\",\"x\":\{@core.fmt_num(m.x)},\"y\":\{@core.fmt_num(m.y)},\"w\":\{@core.fmt_num(m.w)},\"h\":\{@core.fmt_num(m.h)},\"radius\":\{@core.fmt_num(m.radius)},\"invert\":\{m.invert}}",
      )
    None => ()
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
    @core.ShapeKind::Text => "text"
    @core.ShapeKind::Adjust => "adjust"
    @core.ShapeKind::Raster => "raster"
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
/// 解析 k=v 中的调整算子（op/value）。
fn parse_adjust(m : Map[String, String]) -> Result[@core.Adjust, String] {
  let op = match m.get("op") {
    Some(v) => v
    None => return Err("adjust 需要 op=")
  }
  let value = match to_d(m.get("value").unwrap_or("0")) {
    Some(v) => v
    None => return Err("value=\{m.get("value").unwrap_or("0")} 不是数字")
  }
  match op {
    "brightness" => Ok({ op: @core.AdjustOp::Brightness, value })
    "contrast" => Ok({ op: @core.AdjustOp::Contrast, value })
    "saturation" => Ok({ op: @core.AdjustOp::Saturation, value })
    "invert" => Ok({ op: @core.AdjustOp::Invert, value: 0.0 })
    "grayscale" => Ok({ op: @core.AdjustOp::Grayscale, value: 0.0 })
    "blur" => Ok({ op: @core.AdjustOp::Blur, value })
    "sharpen" => Ok({ op: @core.AdjustOp::Sharpen, value })
    "smooth" => Ok({ op: @core.AdjustOp::Smooth, value })
    "whiten" => Ok({ op: @core.AdjustOp::Whiten, value })
    "warm" => Ok({ op: @core.AdjustOp::Warm, value })
    "vignette" => Ok({ op: @core.AdjustOp::Vignette, value })
    _ =>
      Err(
        "未知调整算子 \{op}（brightness/contrast/saturation/invert/grayscale/blur/sharpen/smooth/whiten/warm/vignette）",
      )
  }
}

///|
fn cmd_add_text(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let text = match m.get("text") {
    Some(t) => t
    None => return err("add-text 需要 text=<内容>（含空格用双引号包起来：text=\"Hello World\"）")
  }
  let id = match m.get("id") {
    Some(i) => i
    None => @core.alloc_layer_id(doc)
  }
  if @core.find_layer(doc.layers, id) is Some(_) {
    return err("层 id 已存在：\{id}")
  }
  let w = match to_d(m.get("w").unwrap_or("0")) {
    Some(v) => v
    None => 0.0
  }
  let h = match to_d(m.get("h").unwrap_or("0")) {
    Some(v) => v
    None => 0.0
  }
  let x = match to_d(m.get("x").unwrap_or("0")) {
    Some(v) => v
    None => 0.0
  }
  let y = match to_d(m.get("y").unwrap_or("0")) {
    Some(v) => v
    None => 0.0
  }
  // w ≤ 0 时按 6px/字符、font_size 高度估算占位盒
  let fs = match to_d(m.get("font_size").unwrap_or("16")) {
    Some(v) => v
    None => 16.0
  }
  let bw = if w > 0.0 { w } else { text.length().to_double() * fs * 6.0 / 7.0 }
  let bh = if h > 0.0 { h } else { fs }
  let layer = match build_shape_layer(id, @core.ShapeKind::Text, m) {
    Ok(l) => l
    Err(e) => return err(e)
  }
  let l2 = {
    ..layer,
    x: if x != 0.0 { x } else { layer.x },
    y: if y != 0.0 { y } else { layer.y },
    w: bw,
    h: bh,
    text,
    font_size: fs,
    fill: @core.Fill::Solid(0xFF000000),
  }
  snapshot(s, doc, "add text \{id}")
  doc.layers.push(l2)
  "{\"ok\":true,\"op\":\"add-text\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_set_text(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：set-text <id> <新内容>（含空格用双引号包起来）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  snapshot(s, doc, "set-text \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, text: tokens[2] } })
  "{\"ok\":true,\"op\":\"set-text\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_add_adjust(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let adj = match parse_adjust(m) {
    Ok(a) => a
    Err(e) => return err(e)
  }
  let id = match m.get("id") {
    Some(i) => i
    None => @core.alloc_layer_id(doc)
  }
  if @core.find_layer(doc.layers, id) is Some(_) {
    return err("层 id 已存在：\{id}")
  }
  // 调整层置于栈顶（PSD 语义：作用于其下全部可见层）
  let l = @core.default_layer(id, m.get("name").unwrap_or(id), 0.0, 0.0, doc.width.to_double(), doc.height.to_double())
  let l2 = { ..l, kind: @core.ShapeKind::Adjust, fill: @core.Fill::NoFill, adjust: Some(adj) }
  snapshot(s, doc, "add adjust \{id}")
  doc.layers.push(l2)
  "{\"ok\":true,\"op\":\"add-adjust\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_add_mask(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err(
      "用法：add-mask <id> kind=rect|ellipse x= y= w= h= [radius=<圆角 px，仅矩形，默认 0>] [invert=true]",
    )
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  let m = kv_args(tokens, 2)
  let kind = match m.get("kind") {
    Some("ellipse") => @core.ShapeKind::Ellipse
    Some("rect") => @core.ShapeKind::Rect
    Some(other) => return err("蒙版 kind 应为 rect|ellipse，got \{other}")
    None => return err("add-mask 需要 kind=rect|ellipse")
  }
  let x = match to_d(m.get("x").unwrap_or("0")) {
    Some(v) => v
    None => return err("x 非法")
  }
  let y = match to_d(m.get("y").unwrap_or("0")) {
    Some(v) => v
    None => return err("y 非法")
  }
  let w = match to_d(m.get("w").unwrap_or("0")) {
    Some(v) => if v > 0.0 { v } else { return err("蒙版 w 必须为正") }
    None => return err("add-mask 需要 w=")
  }
  let h = match to_d(m.get("h").unwrap_or("0")) {
    Some(v) => if v > 0.0 { v } else { return err("蒙版 h 必须为正") }
    None => return err("add-mask 需要 h=")
  }
  // radius 曾经是"非法值静默变 0"——`radius=abc` 不报错、`radius=-5` 也收。
  // 现在它真的参与渲染了（圆角矩形），静默降级会让"看起来加了圆角"和
  // "圆角根本没生效"难以区分（这正是它藏了这么久的原因）。
  let radius = match m.get("radius") {
    Some(v) =>
      match to_d(v) {
        Some(d) =>
          if d < 0.0 {
            return err("蒙版 radius 不能为负：\{v}")
          } else {
            d
          }
        None => return err("radius=\{v} 不是数字")
      }
    None => 0.0
  }
  let invert = match m.get("invert") {
    Some("true") | Some("1") => true
    _ => false
  }
  snapshot(s, doc, "add-mask \{id}")
  let _ = update_layer(doc.layers, id, fn(l) {
    { ..l, mask: Some({ kind, x, y, w, h, radius, invert }) }
  })
  "{\"ok\":true,\"op\":\"add-mask\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_set_mask(s : Session, tokens : Array[String]) -> String {
  // set-mask **只改 invert**（几何修改走 remove-mask + add-mask）。
  //
  // 这里曾经静默接受任何 tokens[2]：认不出 `true`/`1`/`invert=true` 就当
  // false。于是照字典传 `x= y= w= h=` 会**什么都不改却返回 ok**（指纹一字
  // 未变），还会把原有的 invert 重置掉——踩了铁律 3"不支持就报明确错误"。
  // 现在认不出就拒绝，并指路几何修改的正确做法。
  if tokens.length() < 3 {
    return err("用法：set-mask <id> true|false（只改反选；几何修改用 remove-mask + add-mask）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let inv = match tokens[2] {
    "true" | "1" | "invert=true" => true
    "false" | "0" | "invert=false" => false
    other =>
      return err(
        "set-mask 只改 invert（true|false）；几何修改请用 remove-mask + add-mask，got \{other}",
      )
  }
  snapshot(s, doc, "set-mask \{id}")
  let ok = update_layer(doc.layers, id, fn(l) {
    match l.mask {
      Some(m) => { ..l, mask: Some({ ..m, invert: inv }) }
      None => l
    }
  })
  if ok {
    "{\"ok\":true,\"op\":\"set-mask\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
  } else {
    err("层不存在：\{id}")
  }
}

///|
fn cmd_remove_mask(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：remove-mask <id>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  snapshot(s, doc, "remove-mask \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, mask: None } })
  "{\"ok\":true,\"op\":\"remove-mask\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
  // 视觉通道必须看到**最终图**（底图 + 编辑表）：模型据此判断效果、
  // 也据此决定下一步，漏掉编辑表等于给它看错图。
  let rendered : Result[@codec.RgbaBuf, String] = if overlay {
    @render.render_view_overlay_with(doc, env, vx0, vy0, vx1, vy1, width, s.mvsl)
  } else {
    @render.render_view_with(doc, env, vx0, vy0, vx1, vy1, width, s.mvsl)
  }
  let buf = match rendered {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let png = @codec.png_encode(buf)
  let hash = @base.sha256_hex(png)
  s.last_render_hash = hash
  let b64 = @base64.encode(png)
  // 三个身份字段一起给出，别让宿主猜：
  //   fingerprint    = design.json 的 sha256（**编辑表变了它不会变**）
  //   program_sha256 = 编辑表的 sha256
  //   render_sha256  = 这张 PNG 的 sha256（渲染产物缓存的唯一真值）
  let prog_sha = @core.program_sha256(s.mvsl)
  "{\"ok\":true,\"op\":\"render\",\"width\":\{buf.width},\"height\":\{buf.height},\"overlay\":\{overlay},\"png_b64\":\"\{b64}\",\"render_sha256\":\"\{hash}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\",\"program_sha256\":\"\{prog_sha}\"}"
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
  let buf = match @render.render_doc_with(doc, env, s.mvsl) {
    Ok(b) => b
    Err(e) => return err(e)
  }
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
  // 编辑表也要 lint：装了表却什么都没改、断言被违反、某条算子白装——
  // 这些状态每个命令都返回 ok，只有 lint 会说出来。
  if s.mvsl.ops.length() > 0 || s.mvsl.guards.length() > 0 {
    match mvsl_base(s) {
      Ok(base) => for item in lint_mvsl(base, s.mvsl) {
        v.push(item)
      }
      Err(e) => v.push("P0 mvsl 草稿无法光栅化：\{e}")
    }
  }
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
  m.mvsl = s.mvsl
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
  s.mvsl = m.mvsl
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

// ---------------------------------------------------------------------------
// 修图操作命令：画笔 / 橡皮擦 / 裁剪 / 取色（B1–B3）
// ---------------------------------------------------------------------------

///|
/// 新建画笔层（Raster）：几何 = 全画布，dabs 为内容。
fn cmd_add_paint(s : Session, tokens : Array[String]) -> String {
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
  let name = m.get("name").unwrap_or("画笔层")
  let l = @core.default_layer(id, name, 0.0, 0.0, doc.width.to_double(), doc.height.to_double())
  let l2 = { ..l, kind: @core.ShapeKind::Raster, fill: @core.Fill::NoFill }
  snapshot(s, doc, "add-paint \{id}")
  doc.layers.push(l2)
  "{\"ok\":true,\"op\":\"add-paint\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 沿折线落笔触（画笔/橡皮擦共用）。pts 为**画布坐标**——落点存入层时
/// 平移到层局部坐标（层被 move/crop 后语义不变）。笔触沿段均匀分布，
/// 间距 = max(1, r·0.45)。
fn cmd_brush(s : Session, tokens : Array[String], erase : Bool) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  if tokens.length() < 2 {
    return err("用法：brush layer=<id> pts=x1,y1;x2,y2[;…] r=<半径px> [color=#RRGGBB[AA]]")
  }
  let m = kv_args(tokens, 1)
  let lid = match m.get("layer") {
    Some(v) => v
    None => return err("brush 需要 layer=<id>")
  }
  let layer = match @core.find_layer(doc.layers, lid) {
    Some(l) => l
    None => return err("层不存在：\{lid}")
  }
  if !(layer.kind is @core.ShapeKind::Raster) {
    return err("层 \{lid} 不是画笔层（raster）：先 add-paint 或对 raster 层落笔")
  }
  let pts = match m.get("pts") {
    Some(v) =>
      match parse_points(v) {
        Ok(p) => p
        Err(e) => return err(e)
      }
    None => return err("brush 需要 pts=x1,y1;x2,y2[;…]")
  }
  let r = match arg_d(m, "r", 4.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  if r <= 0.0 || r > 200.0 {
    return err("r 越界（0 < r ≤ 200）")
  }
  let color : Int = if erase {
    0x00000000
  } else {
    match m.get("color") {
      Some(c) =>
        match parse_color(c) {
          Ok(v) => v
          Err(e) => return err(e)
        }
      None => 0xFF000000
    }
  }
  // 折线等距落点（画布坐标 → 层局部：减层原点，move/crop 后语义稳定）
  let ox = layer.x
  let oy = layer.y
  let canvas_pts : Array[(Double, Double)] = []
  for p in pts {
    canvas_pts.push((p.0 - ox, p.1 - oy))
  }
  let pts = canvas_pts
  let dabs : Array[@core.Dab] = []
  let spacing = if r * 0.45 > 1.0 { r * 0.45 } else { 1.0 }
  let mut i = 0
  while i + 1 < pts.length() {
    let (ax, ay) = pts[i]
    let (bx, by) = pts[i + 1]
    let dx = bx - ax
    let dy = by - ay
    let len = Double::sqrt(dx * dx + dy * dy)
    let n = if len <= 0.0 {
      1
    } else {
      let v = (len / spacing).to_int()
      if v < 1 { 1 } else { v }
    }
    let mut k = 0
    while k < n {
      let t = k.to_double() / n.to_double()
      dabs.push({ x: ax + dx * t, y: ay + dy * t, r, color, erase })
      k = k + 1
    }
    i = i + 1
  }
  let last = pts[pts.length() - 1]
  dabs.push({ x: last.0, y: last.1, r, color, erase })
  snapshot(s, doc, "\{if erase { "erase" } else { "brush" }} \{lid} (\{dabs.length()} dabs)")
  let _ = update_layer(doc.layers, lid, fn(l) { { ..l, dabs: l.dabs + dabs } })
  "{\"ok\":true,\"op\":\"\{if erase { "erase" } else { "brush" }}\",\"id\":\"\{lid}\",\"dabs\":\{dabs.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn shift_layers(
  layers : Array[@core.Layer],
  dx : Double,
  dy : Double,
) -> Unit {
  let mut i = 0
  while i < layers.length() {
    let l = layers[i]
    layers[i] = { ..l, x: l.x + dx, y: l.y + dy }
    shift_layers(layers[i].children, dx, dy)
    i = i + 1
  }
}

///|
/// 裁剪：画布收窄到 (x,y,w,h)，全部层同步平移 (-x,-y)。
/// 硬约束：区域必须在原画布内（越界拒绝，AgentGate 零容忍）。
fn cmd_crop(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  if tokens.length() < 5 {
    return err("用法：crop <x> <y> <w> <h>")
  }
  let cx = match to_i(tokens[1]) {
    Some(v) => v
    None => return err("x=\{tokens[1]} 不是整数")
  }
  let cy = match to_i(tokens[2]) {
    Some(v) => v
    None => return err("y=\{tokens[2]} 不是整数")
  }
  let cw = match to_i(tokens[3]) {
    Some(v) => v
    None => return err("w=\{tokens[3]} 不是整数")
  }
  let ch = match to_i(tokens[4]) {
    Some(v) => v
    None => return err("h=\{tokens[4]} 不是整数")
  }
  if cw <= 0 || ch <= 0 {
    return err("裁剪尺寸必须为正")
  }
  if cx < 0 || cy < 0 || cx + cw > doc.width || cy + ch > doc.height {
    return err(
      "裁剪区域 (\{cx},\{cy},\{cw},\{ch}) 超出画布 (\{doc.width}x\{doc.height})",
    )
  }
  if cw.to_int64() * ch.to_int64() > @mpd.LIMIT_MAX_PIXELS.to_int64() {
    return err("画布总像素超限")
  }
  snapshot(s, doc, "crop \{cx},\{cy} \{cw}x\{ch}")
  shift_layers(doc.layers, -cx.to_double(), -cy.to_double())
  doc.width = cw
  doc.height = ch
  "{\"ok\":true,\"op\":\"crop\",\"width\":\{cw},\"height\":\{ch},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 取色（吸管）：渲染当前合成并采样 (x,y) 像素颜色。
fn cmd_sample(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  if tokens.length() < 3 {
    return err("用法：sample <x> <y>")
  }
  let x = match to_i(tokens[1]) {
    Some(v) => v
    None => return err("x=\{tokens[1]} 不是整数")
  }
  let y = match to_i(tokens[2]) {
    Some(v) => v
    None => return err("y=\{tokens[2]} 不是整数")
  }
  if x < 0 || y < 0 || x >= doc.width || y >= doc.height {
    return err("采样点 (\{x},\{y}) 超出画布 (\{doc.width}x\{doc.height})")
  }
  let env = match session_env(s) {
    Ok(e) => e
    Err(e) => return err(e)
  }
  let buf = match @render.render_doc_with(doc, env, s.mvsl) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let px = if x >= buf.width { buf.width - 1 } else { x }
  let py = if y >= buf.height { buf.height - 1 } else { y }
  let c = @codec.rgba_get(buf, px, py)
  let picked = match @render.pick(doc, x.to_double() + 0.5, y.to_double() + 0.5) {
    Some(id) => id
    None => ""
  }
  "{\"ok\":true,\"op\":\"sample\",\"x\":\{x},\"y\":\{y},\"color\":\"\{@codec.color_to_hex(c)}\",\"layer\":\"\{picked}\"}"
}
