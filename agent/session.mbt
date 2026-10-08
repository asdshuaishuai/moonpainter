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
  /// **步骤历史**（③ 每步可见、可跳回）：每个真实变更命令的"人话标签"，
  /// 与撤销栈**同一批打点**（`snapshot` 一处）。
  ///
  /// 与 `edits` 的分工：`edits` 是**事件日志**（连 undo/redo/goto 这些"不产生
  /// 新状态"的动作也记），`labels` 只记**产生状态的步骤**——面板上出现的每一行
  /// 必须对应一个能跳回去的状态，否则"跳到第 3 步"会落到一个语义不明的地方。
  labels : Array[String]
  /// `labels[0]` 对应的**绝对步号**（1 起）。撤销栈有 64 的容量上限，溢出时最早
  /// 的快照被丢掉 ⇒ 能回去的最早一步跟着往后挪，这里如实记账（`history` 会报
  /// 出来，`goto` 越过它就**报错**而不是"跳到一个看着对、其实不是那一刻"的状态）。
  mut step_base : Int
  /// 当前状态的**绝对步号**：0 = `new` 之后的初始文档；= 已发生的变更数。
  mut cursor : Int
  /// **命令之前**的状态（`exec` 在分发前抓一次，`snapshot` 用它入栈）。
  ///
  /// 为什么要在入口抓：`snapshot` 原先在命令中途调用，而"中途"往往已经改过
  /// doc——最典型的是 `alloc_layer_id` 已经把 `next_layer_no` 递增了。于是快照
  /// 里存的是一个**从未存在过**的状态（层是旧的、计数器是新的），`undo` 回来的
  /// doc 与"那一刻"**指纹不同**（实测 `add-rect`×4 后 `undo`×2 得到
  /// `next_layer_no:4`，而直接建两层是 3；画面一样，只有指纹看得出来）。
  /// 修法放在入口而不是 32 个调用点：调用点每加一个都可能忘，而入口只有一处。
  /// 只读命令抓了也不用（不调 `snapshot` ⇒ 栈不变），代价是一次序列化。
  mut pending_pre : String?
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
    labels: [],
    step_base: 0,
    cursor: 0,
    pending_pre: None,
    last_render_hash: "",
    mvsl: @core.EditProgram::new(),
  }
}

///|
fn err(msg : String) -> String {
  "{\"error\":\"\{@core.json_escape(msg)}\"}"
}

///|
/// 标签数组 → JSON 数组字面量（**一处实现**）。
///
/// `query-layer` 与 `untag` 都要回吐标签列表：两处各写一遍就是两份转义/分隔
/// 逻辑，谁先改谁先烂（外层 `[]`、逗号、`json_escape` 都有翻车余地）。
fn tags_json(tags : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("[")
  let mut f = true
  for t in tags {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{@core.json_escape(t)}\"")
  }
  sb.write_string("]")
  sb.to_string()
}

///|
/// 执行前的**唯一入口**（agent 侧）：先拒坏作用域，再把 `layer=@tag` 展开成
/// 具体层 id。
///
/// 与 render 侧共用 core 的同一对判据（`tag_scope_error` + `expand_layer_scopes`）：
/// 标签是**活的**——给层打上标签它立刻进入作用范围，摘掉立刻退出，所以展开必须
/// 在**执行时**做，不能在 `mvsl-set` 时把表烤成当时的层 id。
///
/// 为什么"拒"也在这里：`mvsl-impact`/`mvsl-assert` 走的是"在合成底图上跑整张
/// 表"这条近似路径，而 `run_program` 根本不看 `layer`。表里留着一条落空的
/// `@tag` 时，render 会报错、impact 却照样给出一张"改了 N 个像素"的证书——
/// "render ≡ impact" 这条不变量当场破掉。所以执行侧统一在这里拒绝。
fn mvsl_resolved(
  s : Session,
  doc : @core.Document,
) -> Result[@core.EditProgram, String] {
  match @core.tag_scope_error(s.mvsl, doc) {
    Some(e) => Err(e)
    None => Ok(@core.expand_layer_scopes(s.mvsl, doc))
  }
}

///|
/// 新建层时决定它的 id：`id=` 给了就用，没给就自动分配 —— **唯一实现**。
///
/// 五处 `add-*` 各抄过一遍这四行（其中 `add-image` 还漏了"id 已存在"那一步，
/// 于是它能造出两个同 id 的层，而 `layer=` 作用域、`query-layer`、`pick`
/// 全都按"id 唯一"在找层）。顺手落实一条命名空间规则：**层 id 不许以 `@`
/// 开头**（`@` 保留给 MVSL 的 `layer=@tag`），否则同一个 `layer` 字符串会按
/// 容器内容有两种读法，而读错的那边不报错。
fn user_layer_id(
  doc : @core.Document,
  m : Map[String, String],
  owner : String,
) -> Result[String, String] {
  let id = match m.get("id") {
    Some(i) => i
    None => @core.alloc_layer_id(doc)
  }
  match @core.layer_id_error(id) {
    Some(e) => return Err("\{owner}：\{e}")
    None => ()
  }
  if @core.find_layer(doc.layers, id) is Some(_) {
    return Err("层 id 已存在：\{id}")
  }
  Ok(id)
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
        // 转义：`\"` → 字面引号、`\\` → 字面反斜杠（沿旧行为），
        // **②C 新增 `\n` → 换行**（文本层的硬换行：`text="Hello\nWorld"`）。
        // 用法串/字典里写明；含真正反斜杠的内容写 `\\`。
        let c2 = s.get_char(i).unwrap_or(c)
        i = i + 1
        if c2 == 'n' {
          sb.write_char('\n')
        } else {
          sb.write_char(c2)
        }
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
  // **命令之前**的状态：就在分发之前抓（`snapshot` 的唯一输入）。
  // 放在这里而不是各命令内部——"快照必须是命令之前"这条只要有一个调用点忘，
  // `undo` 回来的就不是那一刻，而那种偏差**只在指纹上看得出来**（画面对）。
  s.pending_pre = match s.doc {
    Some(d) => Some(@core.doc_to_json(d))
    None => None
  }
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
    "path-preview" => cmd_path_preview(s, tokens)
    "add-rect" => cmd_add_shape(s, tokens, @core.ShapeKind::Rect, "add-rect")
    "add-ellipse" => cmd_add_shape(s, tokens, @core.ShapeKind::Ellipse, "add-ellipse")
    "add-polygon" => cmd_add_shape(s, tokens, @core.ShapeKind::Polygon, "add-polygon")
    "add-line" => cmd_add_shape(s, tokens, @core.ShapeKind::Line, "add-line")
    "add-path" => cmd_add_shape(s, tokens, @core.ShapeKind::Path, "add-path")
    "bool-op" => cmd_bool_op(s, tokens)
    "add-image" => cmd_add_image(s, tokens)
    "set-image" => cmd_set_image(s, tokens)
    "set-style" => cmd_set_style(s, tokens)
    "move" => cmd_move(s, tokens)
    "resize" => cmd_resize(s, tokens)
    "transform" => cmd_transform(s, tokens)
    "rotate" => cmd_rotate(s, tokens)
    "flip" => cmd_flip(s, tokens)
    "rename" => cmd_rename(s, tokens)
    "tag" => cmd_tag(s, tokens)
    "untag" => cmd_untag(s, tokens)
    "delete" => cmd_delete(s, tokens)
    "visible" => cmd_visible(s, tokens)
    "reorder" => cmd_reorder(s, tokens)
    "group" => cmd_group(s, tokens)
    "group-add" => cmd_group_add(s, tokens)
    "group-remove" => cmd_group_remove(s, tokens)
    "ungroup" => cmd_ungroup(s, tokens)
    "add-text" => cmd_add_text(s, tokens)
    "set-text" => cmd_set_text(s, tokens)
    "add-paint" => cmd_add_paint(s, tokens)
    "brush" => cmd_brush(s, tokens)
    "erase" => cmd_erase(s, tokens)
    "clone" => cmd_clone(s, tokens)
    "crop" => cmd_crop(s, tokens)
    "sample" => cmd_sample(s, tokens)
    "add-adjust" => cmd_add_adjust(s, tokens)
    "adjust-spec" => cmd_adjust_spec(s, tokens)
    "set-adjust" => cmd_set_adjust(s, tokens)
    "set-fx" => cmd_set_fx(s, tokens)
    "add-mask" => cmd_add_mask(s, tokens)
    "set-mask" => cmd_set_mask(s, tokens)
    "remove-mask" => cmd_remove_mask(s, tokens)
    "list-params" => cmd_list_params(s)
    "set-param" => cmd_set_param(s, tokens)
    "remove-param" => cmd_remove_param(s, tokens)
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
    "history" => cmd_history(s)
    "goto" => cmd_goto(s, tokens)
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
    let got = if tokens.length() > 1 {
      tokens[1:].join(" ")
    } else {
      "(无参数)"
    }
    err(
      "vision 闸拒绝：唯一合法声明是 full_image（能读取整幅渲染图并理解空间关系），或 vision=full_image。收到的是 `\{got}`。纯文本/仅 OCR 模型请换多模态模型，或改用 moonviz 做纯结构设计",
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
  // 跳回历史中间再动手 ⇒ 后面那些步骤**真的没了**（PS 的历史面板同语义：
  // 新操作截断未来）。这里必须把标签一起截掉：留着它们，面板会出现"看得见、
  // 跳不回去"的幽灵步骤，而 `goto 5` 会落到一条已经作废的线上。
  while s.labels.length() > s.cursor - s.step_base {
    let _ = s.labels.pop()
  }
  // 入栈的是**命令之前**的状态（`exec` 在分发前抓）：命令中途的 doc 已经不是
  // "那一刻"了——`alloc_layer_id` 早把计数器动了，存下来的会是一个从未存在过的
  // 状态，`undo` 的指纹与"那一刻"对不上（画面对、指纹不对，最难查的那种）。
  let pre = match s.pending_pre {
    Some(p) => p
    None => @core.doc_to_json(doc)
  }
  s.pending_pre = None
  s.undo_stack.push(pre)
  if s.undo_stack.length() > 64 {
    let _ = shift_str(s.undo_stack)
    // 最早那份快照被丢掉了 ⇒ 能回去的最早一步往后挪一位，**如实记账**
    s.step_base = s.step_base + 1
    if s.labels.length() > 0 {
      let _ = s.labels.remove(0)
    }
  }
  s.redo_stack.clear()
  s.labels.push(edit_line)
  s.cursor = s.step_base + s.labels.length()
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
  // 可渲染上限：放在 mpd 的容器契约（单边/总像素）之后——先报"容器接不接受"，
  // 再报"渲染器画不画得出来"。此前这里**什么都不报**，于是 `new 5000 200`
  // 回 ok，而渲染只画左上角 4096×4096、lint 报 0 违规（实测静默丢内容）。
  let lim = @render.render_limit_error(w, h)
  if lim != "" {
    return err(lim)
  }
  match check_kv_args(tokens, 3, ["uuid"], "new") {
    Ok(_) => ()
    Err(e) => return err(e)
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
  s.labels.clear()
  s.step_base = 0
  s.cursor = 0
  s.edits.push("new \{w}x\{h}")
  "{\"ok\":true,\"op\":\"new\",\"uuid\":\"\{uuid}\",\"width\":\{w},\"height\":\{h},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_set_canvas(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err(
      "用法：set-canvas <w> <h>（**只改画布，图层不会被移动或缩放**：变大露空白，变小裁掉超出部分）",
    )
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
  // 同一句可渲染上限判据（与 new / lint 共用，见 @render.render_limit_error）。
  // ⚠️ 这条尤其要紧：`set-canvas` 是**表装好之后**唯一能把画布改大的命令，
  // 而编辑表的规模护栏按 `doc.width` 记账——画布大到渲染器只画一角时，
  // 护栏算的代价与真正渲染的东西不是一回事。
  let lim = @render.render_limit_error(w, h)
  if lim != "" {
    return err(lim)
  }
  snapshot(s, doc, "set-canvas \{w}x\{h}")
  doc.width = w
  doc.height = h
  "{\"ok\":true,\"op\":\"set-canvas\",\"width\":\{w},\"height\":\{h},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 调整参数的报告片段（**一处实现**：层报告与 `add-adjust`/`set-adjust` 的回显
/// 共用它）。色阶报 5 个数、曲线报**可回灌的点表文本** + 引擎采样出来的预览点。
///
/// 曲线的预览点必须由**引擎**算（`@render.curve_sample` 与渲染共用 `curve_map`）：
/// 前端自己插值就会画出一条与画面不符的线，"预览骗人"比没有预览更坏。
/// 数值一律 `fmt_num` —— 回灌文本要与 `parse_pairs` 读得进来的一致。
fn adjust_json(adj : @core.Adjust) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"op\":\"\{@core.adjust_op_name(adj.op)}\",\"value\":\{@core.fmt_num(adj.value)}")
  match adj.levels {
    Some(lv) =>
      sb.write_string(
        ",\"levels\":{\"in_lo\":\{@core.fmt_num(lv.in_lo)},\"in_hi\":\{@core.fmt_num(lv.in_hi)},\"gamma\":\{@core.fmt_num(lv.gamma)},\"out_lo\":\{@core.fmt_num(lv.out_lo)},\"out_hi\":\{@core.fmt_num(lv.out_hi)}}",
      )
    None => ()
  }
  if adj.params.length() > 0 {
    // ②B 滤镜参数：按键名升序（存的就是升序）——**对象字面量顺序即字节**
    sb.write_string(",\"params\":{")
    let mut first_p = true
    for p in adj.params {
      if first_p {
        first_p = false
      } else {
        sb.write_string(",")
      }
      sb.write_string("\"\{p.0}\":\{@core.fmt_num(p.1)}")
    }
    sb.write_string("}")
  }
  if adj.curve.length() > 0 {
    sb.write_string(",\"points\":\"\{@core.curve_points_text(adj.curve)}\"")
    sb.write_string(",\"curve_sample\":[")
    let mut first = true
    for p in @render.curve_sample(adj.curve, 9) {
      if first {
        first = false
      } else {
        sb.write_string(",")
      }
      sb.write_string("[\{@core.fmt_num(p.0)},\{@core.fmt_num(p.1)}]")
    }
    sb.write_string("]")
  }
  sb.write_string("}")
  sb.to_string()
}

fn layer_summary(l : @core.Layer) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":\"\{l.id}\",\"name\":\"\{@core.json_escape(l.name)}\"")
  sb.write_string(",\"kind\":\"\{kind_str(l.kind)}\"")
  // 盒子走 `@core.effective_box`：**组的盒子 = 成员的并集**（实时派生）——
  // 报告面与渲染的旋转轴心共用这一个定义，别在这里再读 `l.w/l.h`
  // （那样组会报出建组时那个快照，实测报的是**画布尺寸**，见 PLAN 五十七）。
  let (bx, by, bw, bh) = @core.effective_box(l)
  sb.write_string(",\"x\":\{@core.fmt_num(bx)},\"y\":\{@core.fmt_num(by)},\"w\":\{@core.fmt_num(bw)},\"h\":\{@core.fmt_num(bh)}")
  sb.write_string(",\"visible\":\{l.visible}")
  sb.write_string(",\"opacity\":\{@core.fmt_num(l.opacity)}")
  sb.write_string(",\"blend\":\"\{blend_str(l.blend)}\"")
  // 能力表（"这条命令对这个 kind 的画面有没有效果"）——人类前端据此画控件，
  // **别在 demo 里再抄一遍 kind 名单**：判断两处实现必然先烂。
  sb.write_string(",\"caps\":[")
  let mut cap_first = true
  for c in layer_caps(l) {
    if cap_first {
      cap_first = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{c}\"")
  }
  sb.write_string("]")
  sb.write_string(",\"rot\":\{@core.fmt_num(l.rotation_deg)}")
  // 圆的圆角与翻转此前**只写不读**：`set-style radius=`/`flip` 改了画面与
  // 指纹，但 `query-layer`/`list-layers` 都不报，于是调用方无处回读——
  // 想"再圆一点"只能靠自己记住上次设了多少。fill/stroke 有 sample/census/
  // probe 这条视觉回读路径，几何样式没有（看渲染只能看出"有圆角"，量不出
  // 多少像素）。所以这两个必须报出来。
  if l.kind is @core.ShapeKind::Rect {
    if l.corner_radius != 0.0 {
      sb.write_string(",\"radius\":\{@core.fmt_num(l.corner_radius)}")
    }
  }
  // polygon/line 的顶点**就是它的形状**（w/h 只是外接框），此前既不报也没有
  // 任何命令能改——调用方建完折线就再也读不回自己给了哪些顶点。
  if l.points.length() > 0 {
    if l.kind is @core.ShapeKind::Polygon ||
      l.kind is @core.ShapeKind::Line ||
      l.kind is @core.ShapeKind::Path {
      sb.write_string(",\"points\":[")
      let mut pf = true
      for p in l.points {
        if pf {
          pf = false
        } else {
          sb.write_string(",")
        }
        sb.write_string(
          "[\{@core.fmt_num(p.0)},\{@core.fmt_num(p.1)}]",
        )
      }
      sb.write_string("]")
    }
    // 控制柄**条数 + 数值**都报：渲染器读它、也能改它（`set-style handles=`），
    // 只报"有几个"会让"改成功了吗"问不回来（同 radius 那条：报字段名不报值的
    // 断言会被满足而其实没在守护）。全 0 也报——"缺省 = 折线"必须有回读路径。
    // 路径**闭不闭合**必须报出来：它是 `fill` 的派生事实（`NoFill` = 开放），
    // 而"填没填"在报告面只以颜色形式存在（`sample`/`census`），问不出"这条路径
    // 收口了没有"。渲染器读它、人侧两条路径（点回首锚闭合 vs 回车开放）也由它
    // 区分——不报出来，调用方只能靠自己记住当时怎么收的尾。
    if l.kind is @core.ShapeKind::Path {
      sb.write_string(",\"closed\":\{@core.fill_closed(l.fill)}")
    }
    if l.kind is @core.ShapeKind::Path && l.handles.length() > 0 {
      sb.write_string(",\"handles\":[")
      let mut hf = true
      for h in l.handles {
        if hf {
          hf = false
        } else {
          sb.write_string(",")
        }
        sb.write_string("[\{@core.fmt_num(h.0)},\{@core.fmt_num(h.1)}]")
      }
      sb.write_string("]")
    }
  }
  if l.flip_h || l.flip_v {
    sb.write_string(",\"flip_h\":\{l.flip_h},\"flip_v\":\{l.flip_v}")
  }
  // 笔触层的内容此前**一个字都不报**（x/y/r/颜色/橡皮/克隆全在容器里，问不出来）
  // ——"这一笔是从哪儿取的源"不报出来，调用方只能靠自己记住。
  // 报**数量**与**源偏移**：偏移是整笔恒定的那个向量（画布坐标，与 dab 自己的
  // 局部坐标**不同空间**，所以这里绝不把两者相加后报成一个点）；
  // 多笔克隆时给**第一笔**的偏移（同一条命令的 dab 共用一个值）。
  if l.kind is @core.ShapeKind::Raster {
    if l.dabs.length() > 0 {
      sb.write_string(",\"dabs\":\{l.dabs.length()}")
      let mut cd = 0
      let mut cox = 0.0
      let mut coy = 0.0
      let mut have = false
      for d in l.dabs {
        if d.clone {
          cd = cd + 1
          if !have {
            have = true
            cox = d.sdx
            coy = d.sdy
          }
        }
      }
      if cd > 0 {
        sb.write_string(",\"clone_dabs\":\{cd}")
        sb.write_string(
          ",\"clone_off\":[\{@core.fmt_num(cox)},\{@core.fmt_num(coy)}]",
        )
      }
    }
  }
  if l.text != "" {
    sb.write_string(",\"text\":\"\{@core.json_escape(l.text)}\"")
    sb.write_string(",\"font_size\":\{@core.fmt_num(l.font_size)}")
  }
  // 文本排版（②C）：**能打上就要能读回来**（同 radius/flip/adjust/fx 那条）。
  // 空文字的文本层也报——"设了排版但没内容"同样是调用方要看得见的状态。
  if l.kind is @core.ShapeKind::Text {
    sb.write_string(text_style_report(l.text_style))
  }
  if l.asset_hash != "" {
    sb.write_string(",\"asset\":\"\{l.asset_hash}\"")
  }
  if l.tags.length() > 0 {
    sb.write_string(",\"tags\":\{tags_json(l.tags)}")
  }
  // 调整层**整个层就由 op+value 定义**，此前两者都不报——于是两个不同的
  // 调整层在 list/query 里长得一模一样，调用方无法回读"我装的是哪个算子、
  // 调了多少"。（与 radius/flip 同一条：能设不能读。）
  match l.adjust {
    Some(adj) => {
      sb.write_string(",\"adjust\":")
      sb.write_string(adjust_json(adj))
    }
    None => ()
  }
  // 图层样式：**能打上就要能读回来**（同 radius/flip/adjust 那条）。
  // 只报**开着的**那几件（`none` = 压根没有样式；`all-off` = 挂着一份但
  // 四个开关全关，画面逐位不变）——两者必须区分得开，否则"装了却什么都不干"
  // 在报告面看不见。
  sb.write_string(",\"fx\":\"\{fx_report(l.fx)}\"")
  match l.mask {
    Some(m) =>
      sb.write_string(
        ",\"mask\":{\"kind\":\"\{kind_str(m.kind)}\",\"x\":\{@core.fmt_num(m.x)},\"y\":\{@core.fmt_num(m.y)},\"w\":\{@core.fmt_num(m.w)},\"h\":\{@core.fmt_num(m.h)},\"radius\":\{@core.fmt_num(m.radius)},\"feather\":\{@core.fmt_num(m.feather)},\"roughen\":\{@core.fmt_num(m.roughen)},\"invert\":\{m.invert},\"points\":\{@core.points_json(m.points)}}",
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
    @core.ShapeKind::Path => "path"
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
/// `path-preview points=… [handles=…] [closed=true|false]`——把锚点/控制柄**采样成
/// 折线点串**回报给界面画预览。
///
/// 为什么要有这条只读命令：人侧钢笔在落定之前总得画点什么，而"预览怎么采样"如果
/// 在 demo 里再实现一遍，就成了同一个形状有两份采样规则（`pick` 与渲染分叉那类
/// bug 的翻版，且**预览与落定不一致**是人一眼就能看到的那种）。所以采样只在
/// `@core.path_samples` 一处，界面照引擎给的折线画。
fn cmd_path_preview(s : Session, tokens : Array[String]) -> String {
  let _ = s
  match check_kv_args(tokens, 1, ["points", "handles", "closed"], "path-preview") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let pts = match m.get("points") {
    Some(v) =>
      match parse_points(v) {
        Ok(p) => p
        Err(e) => return err(e)
      }
    None => return err("用法：path-preview points=x,y;x,y;… [handles=dx,dy;…] [closed=true|false]")
  }
  let hs = match m.get("handles") {
    Some(v) =>
      match parse_points(v) {
        Ok(h) => h
        Err(e) => return err(e)
      }
    None => []
  }
  let ce = @core.handles_count_error(pts.length(), hs.length())
  if ce != "" {
    return err(ce)
  }
  let closed = match m.get("closed") {
    None => false
    Some("true") | Some("1") => true
    Some("false") | Some("0") => false
    Some(other) => return err("closed 应为 true|false，got \{other}")
  }
  let samples = @core.path_samples(pts, hs, closed)
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"path-preview\",\"count\":\{samples.length()},\"points\":\"")
  let mut f = true
  for p in samples {
    if f {
      f = false
    } else {
      sb.write_string(";")
    }
    sb.write_string("\{@core.fmt_num(p.0)},\{@core.fmt_num(p.1)}")
  }
  sb.write_string("\"}")
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
  name : String,
) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  // 参数校验（同 set-style：拼错的键、裸词、空值一律拒绝，不留静默 no-op）
  // 命令名由分发表显式传入：它本来就知道名字，而 `"add-\{kind_str(kind)}"`
  // 这种拼出来的名字会让**参数对账门禁**看不见这四个命令（实测就是被
  // 静默跳过的）。判据读得到，才谈得上被守护。
  match check_kv_args(tokens, 1, add_shape_keys(kind), name) {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let id = match user_layer_id(doc, m, name) {
    Ok(id) => id
    Err(e) => return err(e)
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
/// 登记一份 PNG 资产（内容寻址、幂等）：返回 `(hash, 宽, 高)`。
///
/// 两张表要同时维护：`s.assets` 是**只增**的字节登记簿（撤销要把字节还回来），
/// `doc.assets` 是写进 canonical design.json 的**当前引用表**。**一处实现**：
/// `add-image` 与 `set-image` 共用——各登记一遍必然有一处先烂（只塞登记簿忘了
/// 引用表，`save` 就会丢资产；只塞引用表，渲染时 `env.assets` 取不到位图）。
fn place_asset(
  s : Session,
  doc : @core.Document,
  bytes : Bytes,
) -> Result[(String, Int, Int), String] {
  let img = match @codec.png_decode(bytes) {
    Ok(i) => i
    Err(e) => return Err("PNG 解码失败：\{e}")
  }
  let hash = @base.sha256_hex(bytes)
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
  Ok((hash, img.width, img.height))
}

///|
/// `b64=` 载荷 → 字节（两条位图命令共用的那一句话）。**PNG 解码不在这里**：
/// 它在 `place_asset` 里、登记资产**之前**——这样"载荷损坏"必然在改文档之前失败
/// （唯一一处解码，而不是每条命令各解一遍）。
fn decode_b64(b64 : String) -> Result[Bytes, String] {
  let bytes : Bytes = @base64.decode(b64) catch {
    _ => return Err("b64 载荷解码失败")
  }
  Ok(bytes)
}

///|
fn cmd_add_image(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  match check_kv_args(tokens, 1, add_image_keys(), "add-image") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let b64 = match m.get("b64") {
    Some(v) => v
    None => return err("add-image 需要 b64=<png base64>")
  }
  let bytes = match decode_b64(b64) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let (hash, iw, ih) = match place_asset(s, doc, bytes) {
    Ok(t) => t
    Err(e) => return err(e)
  }
  let id = match user_layer_id(doc, m, "add-image") {
    Ok(id) => id
    Err(e) => return err(e)
  }
  let layer = match build_shape_layer(id, @core.ShapeKind::Image, m) {
    Ok(l) => l
    Err(e) => return err(e)
  }
  // 盒子跟着内容走（见 `image_box` 的长注释）：缺省不再是 100×100。
  let (bw, bh) = match image_box(m, iw, ih) {
    Ok(pair) => pair
    Err(e) => return err(e)
  }
  let layer2 = { ..layer, asset_hash: hash, w: bw, h: bh }
  snapshot(s, doc, "add image \{id} asset=\{hash[0:8].to_owned()}")
  doc.layers.push(layer2)
  "{\"ok\":true,\"op\":\"add-image\",\"id\":\"\{id}\",\"asset\":\"\{hash}\",\"asset_size\":\"\{iw}x\{ih}\",\"w\":\{@core.fmt_num(bw)},\"h\":\{@core.fmt_num(bh)},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// `set-image <id> b64=<png base64> [w=] [h=]`：**原地换掉**一个位图层的资产。
///
/// 对偶于 `set-text` / `set-adjust` / `set-mask` / `set-style points=`：此前
/// "换一张图"只能 `delete` 再 `add-image`，于是层序、蒙版、标签、透明度、翻转、
/// 旋转**全丢**，而且重加会把它推到栈顶（改变它与相邻层的叠放关系）。
/// 换图只该换像素。
fn cmd_set_image(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：set-image <id> b64=<png base64> [w=] [h=]")
  }
  match check_kv_args(tokens, 2, set_image_keys(), "set-image") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let target = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  if !(target.kind is @core.ShapeKind::Image) {
    return err(
      "层 \{id} 是 \{kind_str(target.kind)} 不是位图层（换几何用 set-style，换文字用 set-text）",
    )
  }
  let m = kv_args(tokens, 2)
  let b64 = match m.get("b64") {
    Some(v) => v
    None => return err("set-image 需要 b64=<png base64>（换图必须给新像素）")
  }
  let bytes = match decode_b64(b64) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let (hash, iw, ih) = match place_asset(s, doc, bytes) {
    Ok(t) => t
    Err(e) => return err(e)
  }
  let (bw, bh) = match image_box(m, iw, ih) {
    Ok(pair) => pair
    Err(e) => return err(e)
  }
  snapshot(s, doc, "set image \{id} asset=\{hash[0:8].to_owned()}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, asset_hash: hash, w: bw, h: bh } })
  "{\"ok\":true,\"op\":\"set-image\",\"id\":\"\{id}\",\"asset\":\"\{hash}\",\"asset_size\":\"\{iw}x\{ih}\",\"w\":\{@core.fmt_num(bw)},\"h\":\{@core.fmt_num(bh)},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// `set-image` 认的全部键（`w`/`h` 只在调用方要**固定框**时才给；不给就是
/// "盒子跟着新图走"，见 `image_box`）。
fn set_image_keys() -> Array[String] {
  ["b64", "w", "h"]
}

///|
fn add_text_keys() -> Array[String] {
  [
    "id", "name", "x", "y", "w", "h", "text", "font_size", "fill",
    // ②C 文本排版（对齐/行距/字距/折行）
    "align", "line_height", "letter_spacing", "wrap",
  ]
}

///|
/// `add-adjust` 认的全部键（与 `cmd_add_adjust` 的校验一一对应）。
/// 工具字典的描述从它生成——**别再手写第二份**。
pub fn add_adjust_keys() -> Array[String] {
  [
    "op",
    "value",
    "in_lo",
    "in_hi",
    "gamma",
    "out_lo",
    "out_hi",
    "points",
    // ②B 滤镜参数（每个算子只认自己那几键，见 `@core.filter_param_rows`；
    // 这里要**手写字面量**是因为 `param_audit.py` 从 `check_kv_args` 的实参读键表，
    // 读不出字面量就判这门禁有洞。与 core 表的等式由测试钉住。）
    "angle",
    "radius",
    "center_x",
    "center_y",
    "amount",
    "mono",
    "size",
    "levels",
    "channel",
    "level",
    "hue",
    "sat",
    "light",
    "cr",
    "cg",
    "cb",
    "id",
    "name",
  ]
}

///|
/// `set-adjust` 认的全部键：与 `add-adjust` 同，**除了 `id=`/`name=`**
/// （它是原地改，不建层，给这两个键没有意义）。
///
/// ⚠️ 这里**故意写成字面量**、不写成 `add_adjust_keys().filter(…)`：
/// `param_audit.py` 是从 `check_kv_args` 的第三个实参读键表的，读不出字面量
/// 就判失败（静默跳过 = 这门禁有洞）。字面量带来的漂移风险由一条测试堵住
/// （`adjust_params_test.mbt` 断言两份清单只差 id/name）——"一处实现"的替代
/// 不是"再抄一份没人管"，而是"两份 + 一条会红的等式"。
///|
/// `transform` 认的全部键（字面量：`param_audit.py` 从 `check_kv_args` 的第三个
/// 实参读键表，读不出字面量就判这门禁有洞；四个键都已在 `field_audit.KEY_FIELD`
/// 里登记过——`transform` 只是把它们**一次**写下去）。
pub fn transform_keys() -> Array[String] {
  ["x", "y", "w", "h", "rot"]
}

pub fn set_adjust_keys() -> Array[String] {
  [
    "op",
    "value",
    "in_lo",
    "in_hi",
    "gamma",
    "out_lo",
    "out_hi",
    "points",
    "angle",
    "radius",
    "center_x",
    "center_y",
    "amount",
    "mono",
    "size",
    "levels",
    "channel",
    "level",
    "hue",
    "sat",
    "light",
    "cr",
    "cg",
    "cb",
  ]
}

///|
/// 色阶的 5 个键（`add-adjust`/`set-adjust` 共用的**唯一清单**：解析器的
/// 缺省填充、字典用法串、`set-adjust` 的部分更新都从这里出）。
fn level_keys() -> Array[String] {
  ["in_lo", "in_hi", "gamma", "out_lo", "out_hi"]
}

///|
/// `add-paint` 认的全部键。
///|
/// `set-text` 认的全部键：位置参数是 `<id> <内容>`，之后只认这三个。
fn set_text_keys() -> Array[String] {
  ["font_size", "w", "h", "align", "line_height", "letter_spacing", "wrap"]
}

///|
fn add_paint_keys() -> Array[String] {
  ["id", "name"]
}

///|
/// `add-image` 认的全部键（形状键 + 图像载荷）。
fn add_image_keys() -> Array[String] {
  let ks = add_shape_keys(@core.ShapeKind::Image)
  ks.push("b64")
  ks
}

///|
/// `set-style` 认的全部键（与 `apply_style_kv` 的分支一一对应）。
/// 放在这里当**单一事实源**：用法串、错误消息都从它出。
///|
/// `add-rect`/`add-ellipse`/`add-polygon`/`add-line` 认的全部键。
/// 只有 polygon/line 才认 `points`（其余 kind 上的 points 是死数据，见
/// `build_shape_layer` 里的拒绝）；只有 rect 才认 `radius`。
fn add_shape_keys(kind : @core.ShapeKind) -> Array[String] {
  // 只广告**这个 kind 真的读**的键（读点矩阵在 `agent/ops.mbt` 的
  // `kind_only_fields` 一处）：字典的描述从这里生成，所以"字典承诺的键"
  // 与"渲染器读的键"不可能分叉——此前 `add-polygon` 广告了 `stroke=`、
  // `add-image` 广告了整套形状键，而它们在那些 kind 上写进去画面逐位不变。
  let all : Array[String] = [
    "id", "name", "x", "y", "w", "h", "fill", "lgrad", "stroke", "stroke_w", "opacity", "blend",
    "radius", "rot", "visible", "tag",
  ]
  let ks : Array[String] = []
  for k in all {
    let f = key_field(k)
    // 认不出的键（id/name/opacity/…）一律留；认得出的按表判"这层读不读它"
    if f == "" || kind_only_dead_note(kind, f) == "" {
      ks.push(k)
    }
  }
  if kind is @core.ShapeKind::Polygon || kind is @core.ShapeKind::Line {
    ks.push("points")
  }
  if kind is @core.ShapeKind::Path {
    ks.push("points")
    // 控制柄：`handles=dx,dy;…` 与锚点**一一对应**（每个锚 in/out 两个偏移）。
    // 键表从 `kind_only_fields` 算不出来（那是"字段 vs kind"的表，这里还要多一个
    // 语法层），所以与 `points` 并列手写在这唯一一处，字典描述也从它生成。
    ks.push("handles")
  }
  ks
}

///|
fn set_style_keys() -> Array[String] {
  [
    "fill", "lgrad", "stroke", "stroke_w", "opacity", "blend", "radius", "points", "handles", "rot", "visible",
    "name", "tag",
  ]
}

///|
fn cmd_set_style(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    // 用法串从键清单**生成**（此前是手写的第二份拷贝，加了 tag 就会不同步）
    let usage = set_style_keys().map(fn(k) { "[\{k}=..]" }).join(" ")
    return err("用法：set-style <id> \{usage}")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  if @core.find_layer(doc.layers, id) is None {
    return err("层不存在：\{id}")
  }
  // 参数校验必须在快照**之前**：被拒的命令不该留下一条撤销记录。
  // 这里曾经对拼错的键、漏了 `=` 的裸词、空值全部静默返回 ok 而一个像素
  // 没改（`fil=#FF0000` / `fill` / `fill=` 三种都试过，指纹一字未变）。
  match check_kv_args(tokens, 2, set_style_keys(), "set-style") {
    Ok(_) => ()
    Err(e) => return err(e)
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
  let target = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 组：**连后代一起搬**（组的 x/y 渲染器不读，只改盒子会"回 ok 而画面不动"，
  // 见 `shift_layer_tree`）。非组：只改自己的 x/y（历史行为，一个像素不变）。
  let is_group = target.kind is @core.ShapeKind::Group
  let dx = x - target.x
  let dy = y - target.y
  snapshot(s, doc, "move \{id}")
  let moved = if is_group { count_layer_tree(target) } else { 1 }
  let ok = if is_group {
    update_layer(doc.layers, id, fn(l) { shift_layer_tree(l, dx, dy) })
  } else {
    update_layer(doc.layers, id, fn(l) { { ..l, x, y } })
  }
  if ok {
    "{\"ok\":true,\"op\":\"move\",\"id\":\"\{id}\",\"moved_layers\":\{moved},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
  let rl = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 写不生效的字段要在**入口**拒（铁律 6）。判据与 lint 同一张表
  // （`kind_only_write_error`，传**候选层**）：值非默认 + 这个 kind 不读它 ⇒ 拒；
  // 于是 `rotate t1 0` 自动放行（写默认值 = 清字段，旧容器靠它洗回来）。
  match kind_only_write_error({ ..rl, rotation_deg: deg }, "rotation_deg") {
    Some(e) => return err(e)
    None => ()
  }
  snapshot(s, doc, "rotate \{id} \{@core.fmt_num(deg)}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, rotation_deg: deg } })
  "{\"ok\":true,\"op\":\"rotate\",\"id\":\"\{id}\",\"rot\":\{@core.fmt_num(deg)},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// `transform <id> [x=][y=][w=][h=][rot=]`：**自由变换**——把"位置 + 盒子 +
/// 旋转"在**一条命令里**写下去，于是画布上的一个拖拽手势（挪/拉手柄/转）
/// 是**一步历史**，`undo` 一次就回到变换前。
///
/// 为什么不复用三条既有命令：`move`+`resize`+`rotate` 是**三步**（历史面板里
/// 一次手势会变成三条、撤销要按三次；PS 的自由变换是一步）。所以这里不是
/// "再写一遍那三个判断"，而是**调用它们的同一批判据**：
///   * `w`/`h` 必须为正（与 `resize` 同一句话）；
///   * `rot` 走 `kind_only_write_error(候选层, "rotation_deg")`——与 `rotate`
///     同一条入口判据（写不生效的字段要在入口拒；`rot` 恰好等于该 kind 的
///     默认值则放行，那是"清字段"的写法）；
///   * `x`/`y` 对组是"连后代一起搬"（与 `move` 同一条 `shift_layer_tree` 路径）。
///
/// 至少要给一个键：一个键都不给就是"回 ok 而什么都没做"，那正是这仓库反复
/// 堵的那类静默失败。
fn cmd_transform(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：transform <id> [x=] [y=] [w=] [h=] [rot=]")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  match check_kv_args(tokens, 2, transform_keys(), "transform") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 2)
  if m.length() == 0 {
    return err("transform 至少要给一个键（x=/y=/w=/h=/rot=）——什么都不给的变换是空动作")
  }
  let target = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 逐键解析：**给了才改**（部分更新；`arg_d` 把"给了但不是数"变成错误）
  let nx = match m.get("x") {
    Some(v) =>
      match to_d(v) {
        Some(d) => d
        None => return err("x=\{v} 不是数字")
      }
    None => target.x
  }
  let ny = match m.get("y") {
    Some(v) =>
      match to_d(v) {
        Some(d) => d
        None => return err("y=\{v} 不是数字")
      }
    None => target.y
  }
  let nw = match m.get("w") {
    Some(v) =>
      match to_d(v) {
        Some(d) => d
        None => return err("w=\{v} 不是数字")
      }
    None => target.w
  }
  let nh = match m.get("h") {
    Some(v) =>
      match to_d(v) {
        Some(d) => d
        None => return err("h=\{v} 不是数字")
      }
    None => target.h
  }
  let nrot = match m.get("rot") {
    Some(v) =>
      match to_d(v) {
        Some(d) => d
        None => return err("rot=\{v} 不是数字")
      }
    None => target.rotation_deg
  }
  if m.get("w") is Some(_) || m.get("h") is Some(_) {
    if nw <= 0.0 || nh <= 0.0 {
      return err("w/h 必须为正")
    }
  }
  // 旋转：与 `rotate` 同一条入口判据（传**候选层**：只有值非默认 + 这个 kind
  // 不读它才拒；`rot=0` 是清字段，照过）
  match kind_only_write_error({ ..target, rotation_deg: nrot }, "rotation_deg") {
    Some(e) => return err(e)
    None => ()
  }
  // 位置：组的 x/y 渲染器不读 ⇒ 与 `move` 一样走"搬整棵子树"，不然就是
  // "回 ok 而画面不动"
  let is_group = target.kind is @core.ShapeKind::Group
  let dx = nx - target.x
  let dy = ny - target.y
  let touched : Array[String] = []
  if m.get("x") is Some(_) || m.get("y") is Some(_) {
    touched.push("xy")
  }
  if m.get("w") is Some(_) || m.get("h") is Some(_) {
    touched.push("wh")
  }
  if m.get("rot") is Some(_) {
    touched.push("rot")
  }
  snapshot(s, doc, "transform \{id} \{touched.join("+")}")
  let moved = if is_group && (m.get("x") is Some(_) || m.get("y") is Some(_)) {
    count_layer_tree(target)
  } else {
    1
  }
  let _ = update_layer(doc.layers, id, fn(l) {
    let moved_l = if is_group { shift_layer_tree(l, dx, dy) } else { { ..l, x: nx, y: ny } }
    { ..moved_l, w: nw, h: nh, rotation_deg: nrot }
  })
  "{\"ok\":true,\"op\":\"transform\",\"id\":\"\{id}\",\"x\":\{@core.fmt_num(nx)},\"y\":\{@core.fmt_num(ny)},\"w\":\{@core.fmt_num(nw)},\"h\":\{@core.fmt_num(nh)},\"rot\":\{@core.fmt_num(nrot)},\"moved_layers\":\{moved},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
  let fl = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 同 rotate：候选层上问，`flip x1 none` 自动放行。
  let fcand = { ..fl, flip_h: fh, flip_v: fv }
  for f in ["flip_h", "flip_v"] {
    match kind_only_write_error(fcand, f) {
      Some(e) => return err(e)
      None => ()
    }
  }
  snapshot(s, doc, "flip \{id} \{tokens[2]}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, flip_h: fh, flip_v: fv } })
  "{\"ok\":true,\"op\":\"flip\",\"id\":\"\{id}\",\"flip_h\":\{fh},\"flip_v\":\{fv},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 解析 k=v 中的调整算子（op/value）。
///|
/// 调整算子的**取值契约**：`(是否有可调数值, 下界, 上界)`。
///
/// 此前字典里只有一句 `value=<-1..1>`，而它对一半算子是**错的**：
/// blur/sharpen/smooth/whiten/vignette 是 0..1（`core` 的类型注释写着），
/// 而 invert/grayscale 压根**不读** value（渲染器那两个分支不碰它）。
/// 后果是 `add-adjust op=invert value=0.5` 回 ok 而 0.5 被静默丢掉；
/// `value=99` 也被收下（brightness 会 clamp 成纯白，而 `value=1.0` 像素
/// 完全一样、指纹不同——两张"不同"的文档渲染逐位相同，没有任何信号）。
///|
/// `value` 的取值范围（**只对"读 value"的算子有意义**——读不读由 core 的
/// `adjust_uses_value` 一处说了算，别在这里再判一遍）。
fn adjust_bounds(op : @core.AdjustOp) -> (Double, Double) {
  match op {
    @core.AdjustOp::Blur => (0.0, 1.0)
    @core.AdjustOp::Sharpen => (0.0, 1.0)
    @core.AdjustOp::Smooth => (0.0, 1.0)
    @core.AdjustOp::Whiten => (0.0, 1.0)
    @core.AdjustOp::Vignette => (0.0, 1.0)
    _ => (-1.0, 1.0)
  }
}

///|
/// 算子清单（**从 `core.all_adjust_ops` 生成**，手工清单是漏改的温床）。
/// 带上取值范围，让调用方一眼看出该给多少。
fn adjust_op_list() -> String {
  @core.all_adjust_ops().map(fn(o) {
    let name = @core.adjust_op_name(o)
    if @core.adjust_uses_value(o) {
      let (lo, hi) = adjust_bounds(o)
      "\{name}=[\{@core.fmt_num(lo)}..\{@core.fmt_num(hi)}]"
    } else if o is @core.AdjustOp::Levels {
      // 参数面从**键清单**生成（`level_keys`），范围写在解析处一处
      "levels(" + level_keys().map(fn(k) { "\{k}=0..1" }).join(" ") + ")"
    } else if o is @core.AdjustOp::Curves {
      "curves(points=x,y;x,y;…；x/y ∈ 0..1、x 严格递增、2..32 点)"
    } else if @core.is_filter_op(o) {
      // 滤镜（②B）：键与范围**从 core 的表生成**（字典是 LLM 唯一的说明书）
      "\{name}(" +
      @core.filter_param_rows(o).map(fn(r) {
        "\{r.key}=\{@core.fmt_num(r.lo)}..\{@core.fmt_num(r.hi)}"
      }).join(" ") +
      ")"
    } else {
      // 老口径：没有可调数值的算子要**明说**（LLM 才不会给它塞 value=）
      "\{name}（无数值）"
    }
  }).join(" ")
}

///|
/// 工具字典里 `add-adjust` 的算子说明（**从同一张表生成**）。
/// 此前那句 `value=<-1..1>` 对 blur/sharpen/smooth/whiten/vignette **是错的**
/// （0..1），也没说 invert/grayscale 不接受 value——字典是 LLM 唯一的说明书，
/// 写错了它就一直发错参数（而引擎只会静默丢掉）。
pub fn adjust_op_doc() -> String {
  adjust_op_list()
}

///|
/// 解析命令面的 `op=`/`value=`（`add-adjust` 与 `set-adjust` 共用）。
///
/// 三种此前静默收下的输入现在都拒绝：
/// ①未知算子（本来就会报，但清单从 `core.all_adjust_ops` 生成）；
/// ②`value` 越界（`value=99` 只被 clamp，画面与 `value=1.0` 逐位相同）；
/// ③给"没有可调数值"的算子（invert/grayscale）传 `value=`——渲染器不读它，
/// 回包却是 ok，调用方分不出"改成功了"与"参数被丢了"。
///|
/// 色阶的一个键：给了就解析（**给了但不是数要报**），没给用中性值。
/// 缺省填充写在这里一处——命令面、`set-adjust` 的部分更新都读它。
fn level_arg(m : Map[String, String], key : String, dflt : Double) -> Result[Double, String] {
  match m.get(key) {
    Some(t) =>
      match to_d(t) {
        Some(v) => Ok(v)
        None => Err("\{key}=\{t} 不是数字")
      }
    None => Ok(dflt)
  }
}

///|
/// **参数字族互斥**的判据：色阶五键只对 `op=levels` 有意义、`points=` 只对
/// `op=curves` 有意义，其余算子给了就拒（"收了也会被丢掉"的那种静默失败）。
///
/// 句子**从 core 借**（`adjust_param_error`）：命令面看的是"给没给这个键"，
/// 容器读入端看的是"结构里有没有这个字段"，两者说的是同一件事，话就该是同一句。
fn foreign_param_error(m : Map[String, String], op : @core.AdjustOp) -> String? {
  let base = @core.make_adjust(op, 0.0)
  // op=levels 时它自己那族是合法的：构造候选时得把色阶填上，否则 core 会先报
  // "需要 5 个色阶参数"（那句话在问的是缺项，不是互斥）
  let cand = if op is @core.AdjustOp::Levels {
    { ..base, levels: Some(@core.levels_identity()) }
  } else {
    base
  }
  let mut has_lv = false
  for k in level_keys() {
    if m.get(k) is Some(_) {
      has_lv = true
    }
  }
  if has_lv {
    match @core.adjust_param_error({ ..cand, levels: Some(@core.levels_identity()) }) {
      Some(e) => return Some(e)
      None => ()
    }
  }
  if m.get("points") is Some(_) {
    match @core.adjust_param_error({ ..cand, curve: [(0.0, 0.0), (1.0, 1.0)] }) {
      Some(e) => return Some(e)
      None => ()
    }
  }
  // ②B 滤镜键：只认**本算子**那几键。`add-adjust op=motion-blur size=5` 这种
  // "给了别的滤镜的键"如果静默丢掉，回包 ok 而画面一点没变（本仓库反复抓的那类）。
  let mine = @core.filter_param_keys(op)
  for k in filter_key_universe() {
    if m.get(k) is Some(_) && !mine.contains(k) {
      let owners = @core.all_adjust_ops().filter(fn(o) {
        @core.filter_param_keys(o).contains(k)
      }).map(@core.adjust_op_name)
      return Some(
        "算子 \{@core.adjust_op_name(op)} 不吃 \{k}=（\{k}= 只对 op=" +
        owners.join("/") +
        " 有意义）",
      )
    }
  }
  None
}

///|
/// **全部**滤镜参数键的并集（从 core 的算子表算，不手抄第二份）。
/// 用途只有一个：判"给了别的滤镜算子的键"。
fn filter_key_universe() -> Array[String] {
  let out : Array[String] = []
  for o in @core.all_adjust_ops() {
    for k in @core.filter_param_keys(o) {
      if !out.contains(k) {
        out.push(k)
      }
    }
  }
  out
}

fn parse_adjust(m : Map[String, String]) -> Result[@core.Adjust, String] {
  let opname = match m.get("op") {
    Some(v) => v
    None => return Err("adjust 需要 op=（可选：" + adjust_op_list() + "）")
  }
  let op = match @core.adjust_op_from_name(opname) {
    Some(o) => o
    None => return Err("未知调整算子 \{opname}（可选：" + adjust_op_list() + "）")
  }
  // ①用不上的参数一律拒（"收了也会被丢掉"的那种静默失败）
  let uses_value = @core.adjust_uses_value(op)
  let raw_value = m.get("value")
  if !uses_value {
    match raw_value {
      Some(_) =>
        return Err(
          "算子 \{opname} 不接受 value=（它没有可调数值，渲染器不读 value；给了也会被丢掉，所以入口直接拒绝）",
        )
      None => ()
    }
  }
  // ①'参数字族互斥：色阶五键 / points= 各归各的算子（句子从 core 借）
  match foreign_param_error(m, op) {
    Some(e) => return Err(e)
    None => ()
  }
  // ②色阶 / 曲线：各自的参数面
  // ⚠️ 顺序即语义：这两族**没有 value**，先拦"不给 value 就直接建层"的那条
  // 快路（实测把 `!uses_value` 的提前返回放在这两族之前，`op=levels` 会拿着
  // 五个参数一路走到快路里、回 ok、建出一个**没有任何参数**的中性层：容器里
  // 只剩 op+value，画面逐位不变，而 lint 报"需要 5 个色阶参数"）。
  if op is @core.AdjustOp::Levels {
    let ident = @core.levels_identity()
    let mut given = 0
    for k in level_keys() {
      if m.get(k) is Some(_) {
        given = given + 1
      }
    }
    let in_lo = match level_arg(m, "in_lo", ident.in_lo) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let in_hi = match level_arg(m, "in_hi", ident.in_hi) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let gamma = match level_arg(m, "gamma", ident.gamma) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let out_lo = match level_arg(m, "out_lo", ident.out_lo) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let out_hi = match level_arg(m, "out_hi", ident.out_hi) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if given == 0 {
      return Err(
        "算子 levels 至少要给一个色阶参数（" + level_keys().map(fn(k) { "\{k}=" }).join("") +
        "）——一个都不给就是一个什么都不干的层（中性值 0/1/1/0/1）",
      )
    }
    let lv : @core.Levels = { in_lo, in_hi, gamma, out_lo, out_hi }
    match @core.levels_error(lv) {
      Some(e) => return Err(e)
      None => ()
    }
    return Ok({ ..@core.make_adjust(op, 0.0), levels: Some(lv) })
  }
  if op is @core.AdjustOp::Curves {
    let text = match m.get("points") {
      Some(v) => v
      None => return Err("算子 curves 需要 points=x,y;x,y;…（x/y ∈ 0..1、x 严格递增、2..32 点）")
    }
    let pts = match parse_pairs(text, "曲线的控制点", "点") {
      Ok(p) => p
      Err(e) => return Err(e)
    }
    match @core.curve_error(pts) {
      Some(e) => return Err(e)
      None => ()
    }
    return Ok({ ..@core.make_adjust(op, 0.0), curve: pts })
  }
  // ②B 滤镜：键表来自 core 的 `filter_param_rows`（**唯一清单**）。
  // 与色阶同形的一条规则：**至少要给一个键**，缺的键填该键的**中性值**
  // （中性值选"让这一维不干活"的值——缺参数不该悄悄带来看得见的效果；
  // 全中性 = 装了不干活的层，交给 lint 报，命令面不拦）。
  if @core.is_filter_op(op) {
    let rows = @core.filter_param_rows(op)
    let params : Array[(String, Double)] = []
    let mut given = 0
    for r in rows {
      match m.get(r.key) {
        Some(t) => {
          given = given + 1
          let v = match to_d(t) {
            Some(x) => x
            None => return Err("\{r.key}=\{t} 不是数字")
          }
          params.push((r.key, v))
        }
        None => params.push((r.key, r.neutral))
      }
    }
    if given == 0 {
      return Err(
        "算子 \{opname} 至少要给一个参数（" +
        rows.map(fn(r) {
          "\{r.key}=\{@core.fmt_num(r.lo)}..\{@core.fmt_num(r.hi)}"
        }).join(" ") +
        "）——一个都不给就是一个什么都不干的层",
      )
    }
    match @core.filter_param_error(op, params) {
      Some(e) => return Err(e)
      None => ()
    }
    return Ok(@core.make_filter_adjust(op, params))
  }
  // 无值算子（invert/grayscale）：到这儿就结束（下面是"必须给 value"的路径）
  if !uses_value {
    return Ok(@core.make_adjust(op, 0.0))
  }
  // ③数值类算子（原来的口径不变：必须给，且要在范围内）
  let (lo, hi) = adjust_bounds(op)
  let text = match raw_value {
    Some(v) => v
    None =>
      return Err(
        "算子 \{opname} 需要 value=（范围 [\{@core.fmt_num(lo)}..\{@core.fmt_num(hi)}]；不给就是建一个什么都不干的层）",
      )
  }
  let value = match to_d(text) {
    Some(v) => v
    None => return Err("value=\{text} 不是数字")
  }
  if value < lo || value > hi {
    return Err(
      "value=\{text} 超出 \{opname} 的范围 [\{@core.fmt_num(lo)}..\{@core.fmt_num(hi)}]",
    )
  }
  Ok(@core.make_adjust(op, value))
}
///|
/// 文本层的**占位盒**（ASCII 点阵字形）：宽 = 6/7 字宽 × 字数，高 = 字号。
///
/// `add-text` 与 `set-text` **共用这一处**。以前只有 `add-text` 用它，`set-text`
/// 只换文字不动盒子 —— 于是 `add-text text=Hi`（盒子 27.43）之后
/// `set-text … "Hello World"`，渲染器照样把 11 个字**画到盒子外面**
/// （实测两种建法的 render sha256 逐位相同，而 query-layer 报的 w 还是 27.43）。
/// 盒子是渲染之外唯一的范围事实源：`pick`/`overlay` 线框/`lgrad` 归一化端点
/// 都按它算，所以"装不下自己的像素"就是三个信号自相矛盾。
fn text_box(
  text : String,
  fs : Double,
  style : @core.TextStyle?,
  explicit_w : Double,
) -> (Double, Double) {
  let st = match style {
    Some(s) => s
    None => @core.text_neutral_style()
  }
  // 排版算法（拆行/折行/单位换算）在 `core.text_box_of` **一处**；这里只是
  // 把 `None` 折成中性样式。`text_style` 为 `None` 且 `explicit_w = 0` 时它
  // 退回历史公式 `n × fs × 6/7`（逐位相同）。
  @core.text_box_of(text, fs, st, explicit_w)
}

///|
fn cmd_add_text(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  match check_kv_args(tokens, 1, add_text_keys(), "add-text") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let text = match m.get("text") {
    Some(t) => t
    None => return err("add-text 需要 text=<内容>（含空格用双引号包起来：text=\"Hello World\"）")
  }
  let id = match user_layer_id(doc, m, "add-text") {
    Ok(id) => id
    Err(e) => return err(e)
  }
  // 数值一律走 `arg_d`：它把"给了但根本不是数"变成错误。此前这五处是
  // `match to_d(...) { Some(v) => v, None => 默认 }` —— `w=abc`/`font_size=abc`
  // **静默退成默认值**，回包 ok（同一个键拼错会被 `check_kv_args` 拒，值写坏
  // 却不会）。`w ≤ 0` 仍然是"按 6px/字符估算占位盒"（有意的默认，键缺席时也如此）。
  let w = match arg_d(m, "w", 0.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let h = match arg_d(m, "h", 0.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let x = match arg_d(m, "x", 0.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let y = match arg_d(m, "y", 0.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  // 字号：非数报错、非正也报错（此前 `font_size=-3` 建出 -5.14x-3 的负尺寸层，
  // 只有 lint 会说话；`font_size=abc` 更是静默按 16 算）。
  let fs = match arg_d(m, "font_size", 16.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  if fs <= 0.0 {
    return err("font_size 必须为正（像素）：\{@core.fmt_num(fs)} ≠ 正数")
  }
  // 注意：这里 `w ≤ 0 → 估算盒` 只对**缺省**成立。显式 `w=0`/负值走不到这儿
  // ——下面 `build_shape_layer` 会先报 "w/h 必须为正"（实测 `add-text … w=0`
  // 报的是那句）。原来这里注释写"w ≤ 0 时估算"，读起来像"给 0 也行"。
  let style = match text_style_args(m, None, "add-text") {
    Ok(t) => t
    Err(e) => return err(e)
  }
  let want_wrap = match style {
    Some(t) => t.wrap
    None => false
  }
  let we = text_wrap_width_error("add-text", want_wrap, w > 0.0)
  if we != "" {
    return err(we)
  }
  let est = text_box(text, fs, style, w)
  let bw = if w > 0.0 { w } else { est.0 }
  let bh = if h > 0.0 { h } else { est.1 }
  let layer = match build_shape_layer(id, @core.ShapeKind::Text, m) {
    Ok(l) => l
    Err(e) => return err(e)
  }
  // 文本层默认黑字，但**显式给了 fill= 就该生效**：此前这里无条件写死
  // `fill: Solid(0xFF000000)`，把 `build_shape_layer`（它内部走 `apply_style_kv`）
  // 已经解析好的用户 fill 盖掉了，于是 `add-text ... fill=#0000FFFF` 静默渲染成
  // 黑字——参数被接受、被落盘、被上报，只有渲染不看它。
  let text_fill = match m.get("fill") {
    Some(_) => layer.fill
    None => @core.Fill::Solid(0xFF000000)
  }
  let l2 = {
    ..layer,
    x: if x != 0.0 { x } else { layer.x },
    y: if y != 0.0 { y } else { layer.y },
    w: bw,
    h: bh,
    text,
    font_size: fs,
    text_style: style,
    fill: text_fill,
  }
  snapshot(s, doc, "add text \{id}")
  doc.layers.push(l2)
  "{\"ok\":true,\"op\":\"add-text\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_set_text(s : Session, tokens : Array[String]) -> String {
  // 下界是 **3**（`set-text <id> <内容>`）。原先写 2，于是 `set-text l1`
  // 穿过校验、在下面 `tokens[2]` 上**越界 panic**：CLI 进程直接从
  // `cmd_set_text` 崩掉，用户看到的是调用栈而不是用法提示。
  // 注意内容可以为空（`set-text l1 ""` 是"清空文本"的合法写法，分词后
  // 仍是 3 个 token），所以下界卡 3 不会误伤这条用法。
  if tokens.length() < 3 {
    return err(
      "用法：set-text <id> <新内容> [font_size=<px>] [w=<px>] [h=<px>] [align=left|center|right] [line_height=<字形格>] [letter_spacing=<字形格>] [wrap=0|1]（含空格用双引号包起来；清空用 \"\"）",
    )
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let target = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 非文本层的 `text` 字段是**死数据**：渲染器只对 Text 层读它，但它会被
  // 写进 canonical JSON、**改变指纹**、并在 query-layer 里报出来。于是
  // "改成功了吗"的三种信号自相矛盾——指纹说变了、画面一个像素没变。
  // 入口直接拒绝（不降级、不糊弄），手改容器的情形由 lint 兜底。
  if !(target.kind is @core.ShapeKind::Text) {
    return err(
      "层 \{id} 是 \{kind_str(target.kind)} 不是文本层，设不了文字内容（要给图形加标题请先 add-text 建一个文本层）",
    )
  }
  // 可选 kv：字号（**此前字号只有 add-text 能定**，想改大一点只能删了重加——
  // 而重加把层推到栈顶、还会丢掉蒙版/标签/透明度。这是 set-adjust/set-mask
  // 同一条"改得动吗"纪律）与显式盒子（不给就按 text_box 重算）。
  match check_kv_args(tokens, 3, set_text_keys(), "set-text") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 3)
  let content = tokens[2]
  let fs = match m.get("font_size") {
    Some(_) =>
      match arg_d(m, "font_size", target.font_size) {
        Ok(v) => v
        Err(e) => return err(e)
      }
    None => target.font_size
  }
  if fs <= 0.0 {
    return err("font_size 必须为正（像素）：\{@core.fmt_num(fs)} ≠ 正数")
  }
  // 盒子：显式给 w/h 就用给的（与 add-text 同一条规则：必须为正），
  // 否则按内容与字号**重算**——`set-text` 曾只换文字不动盒子，于是层报出来的
  // 范围装不下自己的像素（`pick` 拾不到、overlay 线框画小了、lgrad 端点错位）。
  let style = match text_style_args(m, target.text_style, "set-text") {
    Ok(t) => t
    Err(e) => return err(e)
  }
  let want_wrap = match style {
    Some(t) => t.wrap
    None => false
  }
  // 折行宽度：显式 `w=` 优先，否则沿用**当前盒子宽度**（内容只换几个字时
  // 盒子不该跳——`wrap` 关着时盒子照旧跟着内容重算，历史行为不变）。
  // 只有在"从没折行变成要折行"时才必须显式给 w=：那时当前盒子就是内容宽度，
  // 拿它当折行宽度等于折给自己看。
  let was_wrap = match target.text_style {
    Some(t) => t.wrap
    None => false
  }
  let we = text_wrap_width_error("set-text", want_wrap && !was_wrap, m.get("w") is Some(_))
  if we != "" {
    return err(we)
  }
  let wrap_w = if m.get("w") is Some(_) {
    match arg_d(m, "w", 0.0) {
      Ok(v) => v
      Err(e) => return err(e)
    }
  } else if want_wrap {
    target.w
  } else {
    0.0
  }
  let est = text_box(content, fs, style, wrap_w)
  let ew = est.0
  let eh = est.1
  let nw = match m.get("w") {
    Some(_) =>
      match arg_d(m, "w", ew) {
        Ok(v) => v
        Err(e) => return err(e)
      }
    None => ew
  }
  let nh = match m.get("h") {
    Some(_) =>
      match arg_d(m, "h", eh) {
        Ok(v) => v
        Err(e) => return err(e)
      }
    None => eh
  }
  if (m.get("w") is Some(_) || m.get("h") is Some(_)) && (nw <= 0.0 || nh <= 0.0) {
    return err("w/h 必须为正（显式给盒子时）：\{@core.fmt_num(nw)} x \{@core.fmt_num(nh)}")
  }
  snapshot(s, doc, "set-text \{id}")
  let _ = update_layer(
    doc.layers,
    id,
    fn(l) { { ..l, text: content, font_size: fs, text_style: style, w: nw, h: nh } },
  )
  "{\"ok\":true,\"op\":\"set-text\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
///|
/// `adjust-spec` 认的键（只有 `op`）。⚠️ **必须是字面量**：`param_audit.py` 从
/// `check_kv_args` 的第三个实参读键表，读不出就判这门禁有洞。
pub fn adjust_spec_keys() -> Array[String] {
  ["op"]
}

///|
/// **参数面查询**（`adjust-spec [op=<算子>]`）：把每个算子"吃哪些键、范围多少、
/// 中性值是什么、要不要整数"原样报出来；给了 `op=` 就只报那一个。
///
/// 为什么要有这条命令：前端（demo 面板）必须"由引擎报出来的参数面决定"画哪些
/// 控件——db 里的算子名单/键名/范围抄一份就必然有一处先烂（PLAN 五十一那条）。
/// 色阶/曲线时代面板还能靠"`adjust.levels` 在不在"猜，滤镜的键**事先不存在**
/// （没给过参数就没有 `params`），于是"换成 pixelate 该铺哪些键的中性值"前端
/// 无从得知，只能抄表。这条命令把那张表（`core.filter_param_rows` +
/// `adjust_bounds`/`adjust_uses_value`）变成可读的机器接口——**没有第二张表**。
fn cmd_adjust_spec(s : Session, tokens : Array[String]) -> String {
  let _ = s
  match check_kv_args(tokens, 1, adjust_spec_keys(), "adjust-spec") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let ops : Array[@core.AdjustOp] = match m.get("op") {
    Some(name) =>
      match @core.adjust_op_from_name(name) {
        Some(o) => [o]
        None => return err("未知调整算子 \{name}（可选：" + adjust_op_list() + "）")
      }
    None => @core.all_adjust_ops()
  }
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"spec\":[")
  let mut first_op = true
  for o in ops {
    if first_op {
      first_op = false
    } else {
      sb.write_string(",")
    }
    let uses_value = @core.adjust_uses_value(o)
    let (lo, hi) = adjust_bounds(o)
    sb.write_string(
      "{\"op\":\"" + @core.adjust_op_name(o) + "\",\"uses_value\":" +
      (if uses_value { "true" } else { "false" }) +
      ",\"lo\":" + @core.fmt_num(lo) + ",\"hi\":" + @core.fmt_num(hi) + ",\"params\":[",
    )
    let mut first_p = true
    for r in @core.filter_param_rows(o) {
      if first_p {
        first_p = false
      } else {
        sb.write_string(",")
      }
      sb.write_string(
        "{\"key\":\"" + r.key + "\",\"lo\":" + @core.fmt_num(r.lo) + ",\"hi\":" +
        @core.fmt_num(r.hi) + ",\"neutral\":" + @core.fmt_num(r.neutral) + ",\"integral\":" +
        (if r.integral { "true" } else { "false" }) + ",\"doc\":\"" + @core.json_escape(r.doc) + "\"}",
      )
    }
    sb.write_string("]}")
  }
  sb.write_string("]}")
  sb.to_string()
}

fn cmd_add_adjust(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  // 此前 `value` 拼错（`vlaue=1.5`）会静默按 0 处理 —— 建出一个"没效果"的
  // 调整层，回包 ok。
  match check_kv_args(tokens, 1, add_adjust_keys(), "add-adjust") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let adj = match parse_adjust(m) {
    Ok(a) => a
    Err(e) => return err(e)
  }
  let id = match user_layer_id(doc, m, "add-adjust") {
    Ok(id) => id
    Err(e) => return err(e)
  }
  // 调整层置于栈顶（PSD 语义：作用于其下全部可见层）
  let l = @core.default_layer(id, m.get("name").unwrap_or(id), 0.0, 0.0, doc.width.to_double(), doc.height.to_double())
  let l2 = { ..l, kind: @core.ShapeKind::Adjust, fill: @core.Fill::NoFill, adjust: Some(adj) }
  snapshot(s, doc, "add adjust \{id}")
  doc.layers.push(l2)
  "{\"ok\":true,\"op\":\"add-adjust\",\"id\":\"\{id}\",\"adjust\":" +
  adjust_json(adj) +
  ",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 改调整层的算子/数值，**原地改、不动层序**。
///
/// 此前只有 `add-adjust`，想"把亮度再调高一点"只能 delete + 重新 add——而
/// 重新添加会把它推到**栈顶**，于是"只改了个数值"变成了"连作用范围也变了"
/// （调整层作用于其下全部可见层）。`set-mask` 是 `add-mask` 的对偶，这里同理。
fn cmd_set_adjust(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err(
      "用法：set-adjust <id> [op=<算子>] [value=<数>] [滤镜参数…]（原地改，层序不变；op 与参数键见 add-adjust）",
    )
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let target = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  let cur = match target.adjust {
    Some(a) => a
    None =>
      return err(
        "层 \{id} 是 \{kind_str(target.kind)} 不是调整层（改画面用 set-style；要加调整层用 add-adjust）",
      )
  }
  // 先查键：`set-adjust l2 vallue=1` 拼错时 kv_args 给出空表，此前会报
  // "至少要给 op= 或 value="——那句错话在"拼错了"时是**误导**。
  match check_kv_args(tokens, 2, set_adjust_keys(), "set-adjust") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 2)
  if m.length() == 0 {
    return err(
      "set-adjust 至少要给一个参数（op= / value= / 色阶五键 / points= / 滤镜参数键——都没给就什么都没改）",
    )
  }
  // 只给了 value 就沿用原算子（反之亦然）。注意：**新算子没有可调数值时不能
  // 凭空塞 value=**（老写法无条件塞 `cur.value`），否则 `set-adjust l1 op=invert`
  // 会被自己的拒绝规则打回——而用户根本没给 value。
  //
  // 色阶的**部分更新**在这里做（给 in_lo=0.1 就只改它，其余沿用当前值）：
  // "把 gamma 再抬一点"是最常用的动作，逼调用方把 5 个数都抄一遍才是坑。
  // 曲线反过来：**整表替换**（点表没有"第 3 个点的 y"这种身份，逐点合并没有意义）。
  // **合并规则只有一句话：m 里的键原样赢，缺的按"当前层"补默认。**
  // ⚠️ 此前只搬了 op/value，`set-adjust cv points=…` 于是把新点表丢在 m 里没搬
  // 进 merged ⇒ `query-layer` 回读还是旧点表（命令回 ok，画面一点没变）。
  let merged : Map[String, String] = Map([])
  let opname = m.get("op").unwrap_or(@core.adjust_op_name(cur.op))
  merged.set("op", opname)
  for k in add_adjust_keys() {
    if k != "id" && k != "name" {
      match m.get(k) {
        Some(v) => merged.set(k, v)
        None => ()
      }
    }
  }
  let target_op = @core.adjust_op_from_name(opname)
  // 数值类算子：只给 op 时沿用原 value
  if !merged.contains("value") {
    match target_op {
      Some(o) =>
        if @core.adjust_uses_value(o) {
          merged.set("value", @core.fmt_num(cur.value))
        }
      None => ()
    }
  }
  // 色阶：沿用当前 5 个数（不是色阶层就用中性值），m 里给了的已经覆盖在上一步
  if target_op is Some(@core.AdjustOp::Levels) {
    let base = if cur.op is @core.AdjustOp::Levels {
      match cur.levels {
        Some(lv) => lv
        None => @core.levels_identity()
      }
    } else {
      @core.levels_identity()
    }
    let keys = level_keys()
    let vals = [base.in_lo, base.in_hi, base.gamma, base.out_lo, base.out_hi]
    let mut i = 0
    for k in keys {
      if !merged.contains(k) {
        merged.set(k, @core.fmt_num(vals[i]))
      }
      i = i + 1
    }
    // 换算子到 levels 又一个色阶参数都不给 ⇒ 中性（什么都不干）⇒ 拒绝
    if !(cur.op is @core.AdjustOp::Levels) {
      let mut touched = false
      for k in keys {
        if m.get(k) is Some(_) {
          touched = true
        }
      }
      if !touched {
        return err(
          "set-adjust 把算子换成 levels 时至少要给一个色阶参数（" +
          keys.map(fn(k) { "\{k}=" }).join("") + "）",
        )
      }
    }
  }
  // 曲线：不给 points 且本来就是曲线层 ⇒ 沿用当前点表；换算子到 curves 又不给
  // 点表就由 parse_adjust 报"需要 points="（整表替换：点表没有逐点身份）
  if target_op is Some(@core.AdjustOp::Curves) &&
    !merged.contains("points") &&
    cur.op is @core.AdjustOp::Curves {
    merged.set("points", @core.curve_points_text(cur.curve))
  }
  // ②B 滤镜：与色阶**同形**的部分更新——缺的键沿用当前层的值（**同一个**滤镜
  // 算子）或该键的中性值（换了算子）。`set-adjust l1 radius=20` 是最常用的动作，
  // 逼调用方把 angle 也抄一遍才是坑；而"换成 noise 又一个键都不给"是空操作 ⇒ 拒。
  match target_op {
    Some(o) =>
      if @core.is_filter_op(o) {
        let rows = @core.filter_param_rows(o)
        let same = @core.adjust_op_name(cur.op) == @core.adjust_op_name(o)
        let mut touched = false
        for r in rows {
          if m.get(r.key) is Some(_) {
            touched = true
          }
        }
        for r in rows {
          if !merged.contains(r.key) {
            let v = if same {
              match @core.filter_param_value(cur.params, r.key) {
                Some(x) => x
                None => r.neutral
              }
            } else {
              r.neutral
            }
            merged.set(r.key, @core.fmt_num(v))
          }
        }
        if !same && !touched {
          return err(
            "set-adjust 把算子换成 \{@core.adjust_op_name(o)} 时至少要给一个参数（" +
            rows.map(fn(r) { "\{r.key}=" }).join("") + "）——一个都不给就是空操作层",
          )
        }
      }
    None => ()
  }
  let adj = match parse_adjust(merged) {
    Ok(a) => a
    Err(e) => return err(e)
  }
  snapshot(s, doc, "set-adjust \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, adjust: Some(adj) } })
  "{\"ok\":true,\"op\":\"set-adjust\",\"id\":\"\{id}\",\"adjust\":" +
  adjust_json(adj) +
  ",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 蒙版参数的**唯一键清单**（`add-mask`/`set-mask` 的解析器 allow-list，
/// 以及字典里的用法串）。两处各写一份就会漂移——而漂移的那一半正是 LLM
/// 唯一的说明书（它照字典发参数，字典没写 / 写错 → 一直发错）。
fn mask_keys() -> Array[String] {
  ["kind", "x", "y", "w", "h", "radius", "feather", "roughen", "invert", "points"]
}

///|
/// 字典里的蒙版参数用法串（从键清单生成，顺序即清单顺序）。
pub fn mask_key_doc() -> String {
  let mut s = "kind=rect|ellipse|polygon"
  for k in mask_keys() {
    let part = match k {
      "kind" => ""
      "radius" => " [radius=<圆角 px，仅矩形，默认 0>]"
      "feather" => " [feather=<边缘羽化 px，默认 0=硬边；过渡带在蒙版内侧>]"
      "roughen" => " [roughen=<边缘毛化 px，默认 0=光滑边>]"
      "invert" => " [invert=true]"
      // 任意形状选区：顶点是**盒子内的局部坐标** `x,y;x,y;…`。盒子就是支持窗，
      // 顶点跑出盒子那部分画不出来 —— 入口与 lint 用同一条判据（@core.mask_param_error）。
      "points" => " [points=<多边形顶点 x,y;x,y;…，仅 kind=polygon；局部坐标 0..w/0..h，至少 3 个>]"
      _ => " " + k + "=<像素>"
    }
    s = s + part
  }
  s
}

///|
/// 蒙版参数的**部分更新**读取器（`set-mask` 与 `add-mask` 共用一把尺子）。
///
/// 给了就必须是数字且报得出错因（`arg_d` 的纪律：**非数不许静默退默认**）；
/// 没给就沿用现值。
fn mask_arg_d(m : Map[String, String], key : String, cur : Double) -> Result[Double, String] {
  match m.get(key) {
    None => Ok(cur)
    Some(v) =>
      match to_d(v) {
        Some(d) => Ok(d)
        None => Err("蒙版 \{key}=\{v} 不是数字")
      }
  }
}

///|
/// 蒙版 kind 的读取器（与 JSON 侧同一句判断：只认 rect|ellipse）。
fn mask_arg_kind(
  m : Map[String, String],
  cur : @core.ShapeKind,
) -> Result[@core.ShapeKind, String] {
  match m.get("kind") {
    None => Ok(cur)
    Some("rect") => Ok(@core.ShapeKind::Rect)
    Some("ellipse") => Ok(@core.ShapeKind::Ellipse)
    // 两种写法都收：报告面（kind_str）写的是 polygon，人能照着抄回来
    Some("polygon") => Ok(@core.ShapeKind::Polygon)
    Some("poly") => Ok(@core.ShapeKind::Polygon)
    Some(other) => Err("蒙版 kind 应为 rect|ellipse|polygon，got \{other}")
  }
}

///|
/// 蒙版顶点的读取器（`add-mask`）：没给 = 空；给了就交给 `parse_points`
/// ——与多边形图层**同一个**解析器、同一条错误话术（各写一份必然分叉）。
fn mask_arg_points(
  m : Map[String, String],
) -> Result[Array[(Double, Double)], String] {
  match m.get("points") {
    None => Ok([])
    Some(s) => parse_points(s)
  }
}

///|
/// 蒙版顶点的读取器（`set-mask`，部分更新）：没给 = 保留原样。
fn mask_arg_points_keep(
  m : Map[String, String],
  cur : Array[(Double, Double)],
) -> Result[Array[(Double, Double)], String] {
  match m.get("points") {
    None => Ok(cur)
    Some(s) => parse_points(s)
  }
}

///|
/// 蒙版 invert 的读取器：**认不出就报错**（`invert=maybe` 不许悄悄当 false）。
fn mask_arg_bool(m : Map[String, String], cur : Bool) -> Result[Bool, String] {
  // 布尔参数的读法**只有一处**（`kv_bool_arg`）：蒙版 invert 与图层样式的四个
  // 开关共用它——两处各写一份 `true|false|1|0` 的名单就必然有一处先烂。
  kv_bool_arg(m, "invert", cur, "蒙版 invert")
}

///|
fn cmd_add_mask(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err(
      "用法：add-mask <id> kind=rect|ellipse x= y= w= h= [radius=<圆角 px，仅矩形，默认 0>] [feather=<边缘羽化 px，默认 0=硬边>] [roughen=<边缘毛化 px，默认 0=光滑边>] [invert=true]",
    )
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let ml = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 蒙版在组上不生效（组直通、自身无面）⇒ 入口拒；其余 kind 都读它。
  match kind_only_write_error({ ..ml, mask: Some(mask_write_probe()) }, "mask") {
    Some(e) => return err(e)
    None => ()
  }
  // 蒙版的 `radius` 当年正是"静默接受任何 tokens[2]"那类 bug 的发源地
  // （见 set-mask 的注释）；这里同样把"没认出来"变成错误。
  match check_kv_args(tokens, 2, mask_keys(), "add-mask") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 2)
  let kind = match mask_arg_kind(m, @core.ShapeKind::Rect) {
    Ok(k) => k
    Err(e) => return err(e)
  }
  // `w=`/`h=` 是**必给**参数（没有尺寸的蒙版没有意义），先分"缺了"与"值非法"，
  // 后者交给 `@core.mask_param_error`（与 lint 同一句判据）。
  if m.get("w") is None {
    return err("add-mask 需要 w=")
  }
  if m.get("h") is None {
    return err("add-mask 需要 h=")
  }
  let mut cand : @core.LayerMask = {
    kind,
    x: 0.0,
    y: 0.0,
    w: 0.0,
    h: 0.0,
    radius: 0.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
    points: match mask_arg_points(m) {
      Ok(ps) => ps
      Err(e) => return err(e)
    },
  }
  // radius/feather/roughen 都曾"非法值静默变 0"：`radius=abc` 不报错、`radius=-5`
  // 也收。它们现在真的参与渲染（圆角/羽化/毛边），静默降级会让"看起来加了效果"
  // 和"效果根本没生效"难以区分——这正是它们藏了这么久的原因。
  for key in ["x", "y", "w", "h", "radius", "feather", "roughen"] {
    let cur = 0.0
    let v = match mask_arg_d(m, key, cur) {
      Ok(v) => v
      Err(e) => return err(e)
    }
    cand = match key {
      "x" => { ..cand, x: v }
      "y" => { ..cand, y: v }
      "w" => { ..cand, w: v }
      "h" => { ..cand, h: v }
      "radius" => { ..cand, radius: v }
      "feather" => { ..cand, feather: v }
      _ => { ..cand, roughen: v }
    }
  }
  let inv = match mask_arg_bool(m, false) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  cand = { ..cand, invert: inv }
  // 取值判据只有一句（`@core.mask_param_error`，lint 也用它）
  let why = @core.mask_param_error(cand)
  if why != "" {
    return err(why)
  }
  snapshot(s, doc, "add-mask \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, mask: Some(cand) } })
  "{\"ok\":true,\"op\":\"add-mask\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// `set-mask <id> [kind=] [x=] [y=] [w=] [h=] [radius=] [feather=] [roughen=] [invert=]`
/// —— 蒙版参数的**部分更新**（只给要改的那些，其余原样保留）。
///
/// 为什么要有它：`add-mask` 是**全量**建立（缺省即默认 0）。于是"只想把羽化
/// 从 4 调到 12"若走 `remove-mask` + `add-mask`，**没重复写的 radius 会被悄悄
/// 重置成 0**、roughen 归零——一次小调整把另外几个参数吃掉，而且不报错。
/// 同 `set-adjust`/`set-text`/`set-style points` 那条"改得动吗"纪律：能设的
/// 名字必须能原地改。
///
/// 兼容：`set-mask <id> true|false` 是历史写法（等价于只给 `invert=`），照旧
/// 接受；认不出的一律拒绝并给用法，不做静默降级。
fn cmd_set_mask(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err(
      "用法：set-mask <id> [kind=rect|ellipse] [x=] [y=] [w=] [h=] [radius=] [feather=] [roughen=] [invert=true|false]（至少给一个；历史写法 `set-mask <id> true|false` 等价于只给 invert=）",
    )
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let l = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  match kind_only_write_error({ ..l, mask: Some(mask_write_probe()) }, "mask") {
    Some(e) => return err(e)
    None => ()
  }
  // 改一个不存在的蒙版不许静默成功（同 `remove-mask` 那条纪律：删不存在的
  // 东西也不许静默成功）。此前这里 `update_layer` 原样返回，回包是 ok 而指纹
  // 一字未变——调用方以为自己改了。
  let old = match l.mask {
    Some(m) => m
    None =>
      return err("层 \{id} 本来就没有蒙版，set-mask 没东西可改（用 add-mask 添加）")
  }
  // 位置参数（历史写法）先归一成 `invert=`，再走同一套解析。
  let toks : Array[String] = [tokens[0], tokens[1]]
  for i in 2..<tokens.length() {
    let t = tokens[i]
    if t.contains("=") || t == "true" || t == "false" || t == "1" || t == "0" {
      toks.push(if t.contains("=") { t } else { "invert=\{t}" })
    } else {
      return err(
        "set-mask 的参数要么是 `键=值`，要么是历史写法的 true|false；认不出 \{t}（改动整块几何用 remove-mask + add-mask）",
      )
    }
  }
  match check_kv_args(toks, 2, mask_keys(), "set-mask") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(toks, 2)
  if m.length() == 0 {
    return err("set-mask 至少要给一个要改的参数（例如 feather=12）")
  }
  let kind = match mask_arg_kind(m, old.kind) {
    Ok(k) => k
    Err(e) => return err(e)
  }
  let x = match mask_arg_d(m, "x", old.x) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let y = match mask_arg_d(m, "y", old.y) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let w = match mask_arg_d(m, "w", old.w) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let h = match mask_arg_d(m, "h", old.h) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let radius = match mask_arg_d(m, "radius", old.radius) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let feather = match mask_arg_d(m, "feather", old.feather) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let roughen = match mask_arg_d(m, "roughen", old.roughen) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  let invert = match mask_arg_bool(m, old.invert) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let points = match mask_arg_points_keep(m, old.points) {
    Ok(ps) => ps
    Err(e) => return err(e)
  }
  let neu : @core.LayerMask = {
    kind,
    x,
    y,
    w,
    h,
    radius,
    feather,
    roughen,
    invert,
    points,
  }
  let why = @core.mask_param_error(neu)
  if why != "" {
    return err(why)
  }
  snapshot(s, doc, "set-mask \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, mask: Some(neu) } })
  "{\"ok\":true,\"op\":\"set-mask\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
  // 与 `remove-param` 同一条纪律：**删不存在的东西不许静默成功**。
  // 此前这里既不查层也不查蒙版——`remove-mask typo-id` 回 ok、指纹不变，
  // 调用方以为删掉了。（`remove-param` 早就写着"静默成功会让调用方以为删掉了"，
  // 而它的兄弟漏了。）
  let l = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  if l.mask is None {
    return err("层 \{id} 本来就没有蒙版，remove-mask 没东西可删（add-mask 添加）")
  }
  snapshot(s, doc, "remove-mask \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, mask: None } })
  "{\"ok\":true,\"op\":\"remove-mask\",\"id\":\"\{id}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_rename(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err(
      "用法：rename <id> <new-name>（名字含空格时必须用双引号包住：rename l1 \"背景 层\"）",
    )
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
    return err("用法：tag <id> <tag>（摘标签用 untag <id> <tag|*>）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let tag = tokens[2]
  // 空标签与 `*` 是"打得上却摘不掉"的名字：前者在 query-layer 里只是一对
  // 空引号（回读时分不清"打了空标签"与"解析出岔子"）、在 JSON 里白占一个
  // 字节串并改指纹；后者与 `untag <id> *` 的清空语义撞车，打上就再没有
  // 单独摘掉它的写法。**能打上的名字，都必须能摘下**，所以这两种入口就拒。
  if tag == "" {
    return err("标签不能是空串（空串在 query-layer 里回读成一对空引号、还白占指纹，且没法单独摘）")
  }
  if tag == "*" {
    return err("标签不能是 `*`（它保留给 untag <id> * 的清空语义；换个名字）")
  }
  let l = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  let added = !@core.layer_has_tag(l, tag)
  snapshot(s, doc, "tag \{id} \{tag}")
  let _ = update_layer(doc.layers, id, fn(l) { @core.layer_with_tag(l, tag) })
  // `added` 是"这一步真的做了事吗"的直答：重复打同一个标签是幂等的（状态就是
  // 调用方要的那个），但不该让调用方自己去比指纹才发现什么都没变。
  "{\"ok\":true,\"op\":\"tag\",\"id\":\"\{id}\",\"tag\":\"\{tag}\",\"added\":\{added},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
fn cmd_untag(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：untag <id> <tag|*>（* = 清空全部标签）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let tag = tokens[2]
  let l = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  if l.tags.length() == 0 {
    return err("层 \{id} 没有任何标签，untag 没东西可摘（tag <id> <tag> 可以打标签）")
  }
  if tag == "" {
    return err("标签不能是空串（空标签摘不到，也不会被 tag 收下）")
  }
  if tag != "*" && !@core.layer_has_tag(l, tag) {
    return err("层 \{id} 没有标签 \{tag}（现有：\{l.tags.join("、")}；query-layer 也能看）")
  }
  snapshot(s, doc, "untag \{id} \{tag}")
  // `*` 的"清空"就是对每个现有标签各摘一次：与"摘一个"共用**同一个纯函数**，
  // 于是两条路径不可能分叉（清空不是另一份手写的 `tags: []`）。同一个 `apply`
  // 既算回包里的 `removed`，又交给 update_layer —— 判断只有一处。
  let apply : (@core.Layer) -> @core.Layer = fn(x) {
    if tag == "*" {
      let mut cur = x
      for t in x.tags {
        cur = @core.layer_without_tag(cur, t)
      }
      cur
    } else {
      @core.layer_without_tag(x, tag)
    }
  }
  let next = apply(l)
  let removed = l.tags.length() - next.tags.length()
  let _ = update_layer(doc.layers, id, apply)
  "{\"ok\":true,\"op\":\"untag\",\"id\":\"\{id}\",\"tag\":\"\{tag}\",\"removed\":\{removed},\"tags\":\{tags_json(next.tags)},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
    // 层没了，它引用的资产可能就成了孤儿。**在这里收敛，不在打包时**：
    // `doc.assets` 是写进 canonical design.json 的权威元数据，留着悬空引用
    // 会让外部读者（`unzip` 后直接看文本的人）照着找不到的字节去找。
    // 会话的 `s.assets` 登记簿不动——撤销要把字节还回来。
    let pruned = @core.prune_unreferenced_assets(doc)
    "{\"ok\":true,\"op\":\"delete\",\"id\":\"\{id}\",\"pruned_assets\":\{pruned},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
/// 把组的**盒子快照**刷成成员的并集（`@core.group_bbox`）。
///
/// 渲染与报告面都走 `@core.effective_box`（实时派生），所以这个快照**不影响
/// 任何画面或回包**——它只是让 canonical JSON 里的 `x/y/w/h` 不至于是一份
/// 建组那一刻的旧账（旧引擎也读它）。三处改成员关系的地方（`group` /
/// `group-add` / `group-remove`）共用这一处，别各写一遍。
fn group_with_fresh_box(l : @core.Layer) -> @core.Layer {
  match @core.group_bbox(l.children) {
    Some(b) => { ..l, x: b.0, y: b.1, w: b.2, h: b.3 }
    None => l
  }
}

///|
fn cmd_group(s : Session, tokens : Array[String]) -> String {
  // 下界是 **1 个成员**，不是 2 个。这里原先写 `< 4`（即至少两个成员），
  // 但"只有一个成员的组"本来就能到达（分两个再删一个），于是入口比可达状态
  // 更严——字典里写的是 `group <gid> <id…>`，也读作"一个也行"。
  // 三处口径统一到"至少一个"。
  if tokens.length() < 3 {
    return err("用法：group <gid> <id> [id...]（至少一个成员，且都须是根级层）")
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
  // 组盒 = **成员的并集**（`@core.group_bbox`），不是画布尺寸。
  // 实测过的错法：这里原先是 `0,0,doc.width,doc.height`，于是组的旋转轴心
  // 是**画布中心**（人类以为绕自己的内容转），`query-layer` 还报出 100×100
  // 而内容只有 10,10,60,10 —— 一个谁都没读过的谎（PLAN 五十七）。
  // 渲染与报告面都走 `@core.effective_box`（实时派生），这里是同一件事的
  // **快照**（canonical JSON 要有个值、旧引擎要读得懂）。
  let (gx, gy, gw, gh) = match @core.group_bbox(children) {
    Some(b) => b
    None => (0.0, 0.0, doc.width.to_double(), doc.height.to_double())
  }
  let g = {
    ..@core.default_layer(gid, gid, gx, gy, gw, gh),
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
  // 组上的 rot/flip 存在**组自己**身上，拆了就没地方放 ⇒ 画面会变而回包说 ok
  // （判据一处：`@agent.group_transform_error`，`group-remove` 共用）
  let gt = group_transform_error(g, "ungroup")
  if gt != "" {
    return err(gt)
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
/// 把一个层从它所在的那个数组里**摘出来**（就地移除并返回该层）。
///
/// `locate_container` 给的容器可能是根数组、也可能是某个组的 `children`——
/// 两者是同一类东西，所以"摘取"只有这一份实现：`group-add` / `group-remove`
/// 共用（`ungroup` 是整体搬，另有自己的整段逻辑）。
fn detach_layer(layers : Array[@core.Layer], id : String) -> @core.Layer? {
  let arr = match locate_container(layers, id) {
    Some(a) => a
    None => return None
  }
  let mut i = 0
  while i < arr.length() {
    if arr[i].id == id {
      return Some(arr.remove(i))
    }
    i = i + 1
  }
  None
}

///|
/// 收集 `ids` 里出现在 `arr` 中的层，**按 `arr` 的顺序**（层序即数组序）。
fn collect_in_order(
  arr : Array[@core.Layer],
  ids : Array[String],
) -> Array[@core.Layer] {
  let out : Array[@core.Layer] = []
  for l in arr {
    for id in ids {
      if l.id == id {
        out.push(l)
      }
    }
  }
  out
}

///|
/// 成员 id 列表：去重（同一个 id 给两次是**调用方的错**，不是"加两份"）。
fn member_ids_of(tokens : Array[String], from : Int) -> Result[Array[String], String] {
  let ids : Array[String] = []
  let mut i = from
  while i < tokens.length() {
    let mid = tokens[i]
    for seen in ids {
      if seen == mid {
        return Err("成员重复：\{mid}")
      }
    }
    ids.push(mid)
    i = i + 1
  }
  Ok(ids)
}

///|
/// `group-add <gid> <id> [id...]`：把**已经存在**的根级层加进**已经存在**的组。
///
/// 对偶于 `group-remove`，也是 `children` 这一格"局部可改"的补丁：此前只能
/// `ungroup` + `group` 整体重组——组的 `name`/`opacity`/`blend`/`tags`/`mask`
/// 全丢，而且整组会被重排到成员的层序位置。
///
/// 三条刻意的不支持（都写在字典与 README 边界里，不静默降级）：
/// ①成员必须是**根级**层（已经在组里的先 `group-remove`）；
/// ②成员不能是组——**不支持嵌套编组**（`group` 建组时也只收根级层，这条不变量
///  渲染/命中/压平都依赖，不能从侧门打开）；
/// ③新成员追加到该组 `children` 的**栈顶**（children 自底向上，即画在原有成员
///   之上）。要精确层序用 `reorder`。
fn cmd_group_add(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：group-add <gid> <id> [id...]（成员须是根级层，追加到该组栈顶）")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let gid = tokens[1]
  let g = match @core.find_layer(doc.layers, gid) {
    Some(l) => l
    None => return err("组不存在：\{gid}（新建组用 group）")
  }
  if !(g.kind is @core.ShapeKind::Group) {
    return err(
      "层 \{gid} 是 \{kind_str(g.kind)} 不是组（新建组用 group；改它的属性用 set-style）",
    )
  }
  let ids = match member_ids_of(tokens, 2) {
    Ok(ids) => ids
    Err(e) => return err(e)
  }
  for mid in ids {
    if mid == gid {
      return err("不能把组加进它自己：\{gid}")
    }
    let mut at_root = false
    for l in doc.layers {
      if l.id == mid {
        at_root = true
      }
    }
    if !at_root {
      return err(
        "成员 \{mid} 不是根级层（不存在，或已在某个组里）——先 group-remove 再 group-add",
      )
    }
    let m = match @core.find_layer(doc.layers, mid) {
      Some(l) => l
      None => return err("层不存在：\{mid}")
    }
    if m.kind is @core.ShapeKind::Group {
      return err("成员 \{mid} 是组——不支持嵌套编组（先把它的成员 group-remove 出来）")
    }
  }
  // 先按根级顺序把要搬的层抓出来（摘掉之后就找不到它们了）
  let moving = collect_in_order(doc.layers, ids)
  snapshot(s, doc, "group-add \{gid} (\{moving.length()})")
  for mid in ids {
    let _ = detach_layer(doc.layers, mid)
  }
  let _ = update_layer(doc.layers, gid, fn(l) {
    let kids = l.children
    for m in moving {
      kids.push(m)
    }
    group_with_fresh_box({ ..l, children: kids })
  })
  "{\"ok\":true,\"op\":\"group-add\",\"id\":\"\{gid}\",\"moved\":\{moving.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// `group-remove <gid> <id> [id...]`：把组的**直接成员**移回根级。
///
/// 落在**该组的槽位上 = 组的下一层（画在组的下面）**——与 `ungroup` 的落点
/// 一致（`ungroup` 也是把子层放在组的那个槽位）；"方向"是语义，别留给读者猜。
/// 成员的相对次序按 `children` 顺序保留，要精确层序用 `reorder`。
/// 解散整组仍用 `ungroup`。
fn cmd_group_remove(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err("用法：group-remove <gid> <id> [id...]（移回根级，落在该组的层序位置）")
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
    return err("层 \{gid} 是 \{kind_str(g.kind)} 不是组（解散整组用 ungroup）")
  }
  let ids = match member_ids_of(tokens, 2) {
    Ok(ids) => ids
    Err(e) => return err(e)
  }
  for mid in ids {
    // **直接**成员：嵌套的孙子层不在这里移（主编组不支持嵌套，但手改容器可能造出来）
    let mut direct = false
    for c in g.children {
      if c.id == mid {
        direct = true
      }
    }
    if !direct {
      return err("层 \{mid} 不是组 \{gid} 的直接成员（解散整组用 ungroup）")
    }
  }
  // 同 `ungroup`：从有变换的组里摘成员 = 它在组内是被变换过的、摘出来就
  // 按自己的坐标画（画面跳一下），而回包说 ok
  let gt = group_transform_error(g, "group-remove")
  if gt != "" {
    return err(gt)
  }
  let taken = collect_in_order(g.children, ids)
  // 组的槽位（要在动 children 之前拿到）
  let mut idx = 0
  let mut i = 0
  while i < doc.layers.length() {
    if doc.layers[i].id == gid {
      idx = i
    }
    i = i + 1
  }
  snapshot(s, doc, "group-remove \{gid} (\{taken.length()})")
  let _ = update_layer(doc.layers, gid, fn(l) {
    let kids : Array[@core.Layer] = []
    for c in l.children {
      let mut drop = false
      for mid in ids {
        if c.id == mid {
          drop = true
        }
      }
      if !drop {
        kids.push(c)
      }
    }
    group_with_fresh_box({ ..l, children: kids })
  })
  let mut off = 0
  for t in taken {
    doc.layers.insert(idx + off, t)
    off = off + 1
  }
  "{\"ok\":true,\"op\":\"group-remove\",\"id\":\"\{gid}\",\"moved\":\{taken.length()},\"at\":\{idx},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
/// 删掉一个命名元参数。`set-param` 的对偶——在此之前 `Param` 表**只增不减**：
/// `set-param x ""` 只是把值清空，条目还在（实测 count 不变），所以名字写错
/// 一次就永久留在容器里。纯元数据不参与渲染，但它是会被 `unzip` 读到、
/// 会随容器分发出去的对外事实。
fn cmd_remove_param(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：remove-param <name>")
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let name = tokens[1]
  let before = doc.params.length()
  let next : Array[@core.Param] = []
  for p in doc.params {
    if p.name != name {
      next.push(p)
    }
  }
  if next.length() == before {
    // 不存在就明确报错，不静默成功——静默成功会让调用方以为删掉了
    return err("元参数不存在：\{name}（list-params 查看现有条目）")
  }
  snapshot(s, doc, "remove-param \{name}")
  doc.params.clear()
  for p in next {
    doc.params.push(p)
  }
  "{\"ok\":true,\"op\":\"remove-param\",\"name\":\"\{@core.json_escape(name)}\",\"removed\":1,\"count\":\{doc.params.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// 从 `save-mpd-b64` 的回包里量出容器**字节数**（测试用；b64 长度 × 3/4）。
/// 抽成函数是因为测试要拿它比对"清理前后容器变短了"。
pub fn mp_b64_len(envelope : String) -> Int {
  mp_b64(envelope).length() / 4 * 3
}

///|
/// 从 `save-mpd-b64` 的回包里取出 b64 载荷（取不到给空串）。
pub fn mp_b64(envelope : String) -> String {
  match envelope.find("\"mpd_b64\":\"") {
    Some(i) => {
      let rest = envelope[i + 11:].to_owned()
      match rest.find("\"") {
        Some(j) => rest[:j].to_owned()
        None => ""
      }
    }
    None => ""
  }
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
  // 键校验必须在**位置参数解析之前**：否则 `render width=16`（把位置参数
  // 写成了 kv）会先掉进 `to_i(tokens[1])`，报出 "width=width=16 不是整数"
  // 这种自己咬自己的话，而不是"不认识的参数 `width`"。
  match check_kv_names(tokens, 1, ["overlay"], "render") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  // render [width] [vx0 vy0 vx1 vy1] [overlay=1]
  //
  // 位置参数只认**不含 `=` 的 token**：字典写的是 `render [width] … [overlay=1]`，
  // 也就是 `overlay=` 可以单独出现。此前 `render overlay=1` 通过了键名校验、
  // 却掉进 `to_i("overlay=1")`，报出 "width=overlay=1 不是整数"——**字典承诺的
  // 写法用不了**（实测；这个判据由 `key_effect_audit.py` 的（命令,键）配对发现）。
  let pos : Array[String] = []
  for t in tokens {
    if !t.contains("=") {
      pos.push(t)
    }
  }
  let mut width = 1024
  let mut vx0 = 0.0
  let mut vy0 = 0.0
  let mut vx1 = 1.0
  let mut vy1 = 1.0
  if pos.length() >= 2 {
    match to_i(pos[1]) {
      Some(w) => width = w
      None => return err("width=\{pos[1]} 不是整数")
    }
  }
  if pos.length() >= 6 {
    // 取景四元组
    let nums : Array[Double] = []
    let mut k = 2
    while k < 6 {
      match to_d(pos[k]) {
        Some(v) => nums.push(v)
        None => return err("viewport 参数 \{pos[k]} 不是数字")
      }
      k = k + 1
    }
    vx0 = nums[0]
    vy0 = nums[1]
    vx1 = nums[2]
    vy1 = nums[3]
  }
  let env = match session_env(s) {
    Ok(e) => e
    Err(e) => return err(e)
  }
  // overlay=1：叠加层 bbox 序号线框（视觉通道的像素↔结构对位辅助）
  let mut overlay = false
  for t in tokens {
    if t.has_prefix("overlay=") {
      // 此前只认 `overlay=1`/`overlay=true`，`overlay=yes` 之类**静默无效**
      // ——调用方以为开了叠加层，拿到的却是干净图。
      let v = t[8:].to_owned()
      match v {
        "1" | "true" => overlay = true
        "0" | "false" => overlay = false
        _ => return err("overlay=\{v} 应为 1/0/true/false")
      }
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
    // `layer=@tag` 落不到任何层 —— **入口**（mvsl-set）会拒，但标签是活的：
    // 表装好之后有人 `untag` 掉了那个标签，这条算子就变成"在表里、跑得通、
    // 什么都不改"。入口拒绝管不了事后，所以这里用同一个 core 判据兜底。
    match @core.tag_scope_error(s.mvsl, doc) {
      Some(e) => v.push("P4 \{e}")
      None => ()
    }
    match mvsl_context(s) {
      Ok(pair) =>
        match mvsl_resolved(s, doc) {
          // 坏作用域已经作为 P4 报过，别再拿一张解释不了的表算一遍数字
          Err(_) => ()
          Ok(prog) => for item in lint_mvsl(doc, pair.0, pair.1, prog) {
            v.push(item)
          }
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
/// 步骤历史：每一步的**人话标签** + 当前游标（③ 每步可见）。
///
/// `done=false` 的那些是"跳回后还没重做的未来步骤"（PS 历史面板里显示为灰行）
/// ——面板据此把它们画成可点的未来、并说清"再动手就没了"。
/// `base` 是**还能回去的最早一步**（撤销栈容量 64 的护栏如实报出来，
/// 别让人以为能一路回到开头）。
fn cmd_history(s : Session) -> String {
  let sb = StringBuilder()
  let total = s.step_base + s.labels.length()
  sb.write_string(
    "{\"ok\":true,\"op\":\"history\",\"cursor\":\{s.cursor},\"base\":\{s.step_base},\"total\":\{total},\"count\":\{s.labels.length()},\"can_undo\":\{s.cursor > s.step_base},\"can_redo\":\{s.cursor < total},\"steps\":[",
  )
  let mut i = 0
  for label in s.labels {
    if i > 0 {
      sb.write_string(",")
    }
    let abs = s.step_base + i + 1
    sb.write_string(
      "{\"i\":\{abs},\"label\":\"\{@core.json_escape(label)}\",\"done\":\{abs <= s.cursor}}",
    )
    i = i + 1
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// 跳到第 k 步（0 = `new` 之后的初始文档）——**复用已有的 undo/redo 原语**，
/// 不新增第二条恢复路径（同一个"恢复状态"的判断只许有一处实现）。
///
/// 越界与"超出保留窗口"都在入口拒绝，并把能回去的范围报出来。
fn cmd_goto(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：goto <步号>（0 = 初始状态；步号见 history）")
  }
  let k = match to_i(tokens[1]) {
    Some(v) => v
    None => return err("goto 的步号=\{tokens[1]} 不是整数")
  }
  let total = s.step_base + s.labels.length()
  if k < s.step_base {
    return err(
      "回不到第 \{k} 步：只保留最近 \{s.labels.length()} 步（\{s.step_base}..\{total}，撤销栈 64 的容量上限），更早的快照已被丢弃",
    )
  }
  if k > total {
    return err("第 \{k} 步还不存在：当前总步数是 \{total}")
  }
  // `guard` 是保留字（AGENTS 铁律 9 里就写着），这里叫 hops。
  let mut hops = 0
  while s.cursor > k && hops < 600 {
    let r = cmd_undo(s)
    if r.has_prefix("{\"error\"") {
      return r
    }
    hops = hops + 1
  }
  while s.cursor < k && hops < 600 {
    let r = cmd_redo(s)
    if r.has_prefix("{\"error\"") {
      return r
    }
    hops = hops + 1
  }
  if s.cursor != k {
    return err("goto 没能走到第 \{k} 步（停在 \{s.cursor}）：历史栈异常")
  }
  let fp = match s.doc {
    Some(d) => @core.fingerprint(d)
    None => ""
  }
  "{\"ok\":true,\"op\":\"goto\",\"step\":\{k},\"fingerprint\":\"\{fp}\"}"
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
      s.cursor = s.cursor - 1
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
      s.cursor = s.cursor + 1
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
  // 只打包**文档还在引用**的资产。会话的 `s.assets` 是只增的登记簿（内容寻址，
  // 同一份字节只登记一次），而 `doc.assets` 是当前引用表——`delete` 掉一个
  // 图片层不会、也不该去动登记簿（撤销要能把字节还回来）。
  //
  // 收口放在这里而不是 `delete` 里：任何让资产变成孤儿的路径（删层、换图、
  // 撤销后重放……）都会经过打包，改一处就够。此前这里是 `for pair in s.assets`
  // 全量写入，实测**删掉图片层后容器里仍留着那份 PNG**（design.json 已不引用
  // 它），而 `@mpd.pack` 只做"引用的必须有字节"的正向对账、不反向清理。
  let referenced = @core.referenced_asset_hashes(doc)
  for pair in s.assets {
    if referenced.contains(pair.0) {
      m.add_asset(pair.0, pair.1)
    }
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
///
/// 返回 `(指纹, 知会语)`：知会语非空时调用方**必须**把它带给用户。
///
/// ⚠️ **这是第四个能装进"超出可渲染上限"画布的入口**（前两个是 `new` /
/// `set-canvas`），而它与那两个的处理**必须不同**：这里**不拒**。理由是可自救性
/// ——`81ff759` 之前的引擎**允许** `new 5000 200`，所以这种容器**真实存在**
/// （本仓库自己的旧版本产出的），拒绝打开就等于"用户连打开自己的文件再
/// `crop` 到 4096 这条路都没有"。于是：放行 + **明说**（`notice` 字段），后果
/// 继续由 `lint` 的 P0 与渲染兜底去报。这与 `new`/`set-canvas` 拒绝不矛盾：
/// 那两个入口的参数是**调用方现在写的**，改个数字就行，没有要保留的既有文件。
pub fn load_mpd(s : Session, bytes : Bytes) -> Result[(String, String), String] {
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
  Ok((@core.fingerprint(m.doc), @render.render_limit_error(m.doc.width, m.doc.height)))
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
    Ok(pair) => {
      let (fp, notice) = pair
      let mut out = "{\"ok\":true,\"op\":\"open-mpd-b64\",\"fingerprint\":\"\{fp}\""
      if notice != "" {
        out = out + ",\"notice\":\"\{@core.json_escape(notice)}\""
      }
      out + "}"
    }
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
  match check_kv_args(tokens, 1, ["id", "name"], "add-paint") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let id = match user_layer_id(doc, m, "add-paint") {
    Ok(id) => id
    Err(e) => return err(e)
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
///|
/// `brush`：沿折线落笔触（画笔）。
///
/// `check_kv_args` 的键表**写字面量**、且与本函数一一对应：门禁要读得出来
/// 才谈得上守护。此前 `brush`/`erase` 共用一个函数、键表按布尔分支算，
/// 于是 `erase` 静默收下了 `color=` —— 而橡皮擦恒全强度（`paint_dabs` 里
/// `dalpha` 对 erase 直接取 1.0，连笔色 alpha 都不读），那是个**收了也不
/// 生效**的参数。拆成两条命令后，各自的键表一眼可读。
fn cmd_brush(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, ["layer", "pts", "r", "color"], "brush") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  cmd_dabs(s, tokens, false, false)
}

///|
/// `erase`：橡皮擦（destination-out）。**不收 color=**（恒全强度）。
fn cmd_erase(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, ["layer", "pts", "r"], "erase") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  cmd_dabs(s, tokens, true, false)
}

///|
/// `clone`：**仿制图章**（去污点的基本件）——不落本色，改从"本层之下的合成
/// 结果"里按**源偏移**取样，一笔一笔把干净的地方盖到脏的地方。
///
/// `src=x,y` 是源锚点（**画布坐标**，与 `pts` 同一个坐标系）：偏移 = 源锚点 −
/// 第一个落点，整笔恒定（PS 的"对齐"模式；换一笔就重新锚定 = "非对齐"）。
/// **不收 color=**：克隆的颜色来自画面，收下它就是"收了不生效"。
fn cmd_clone(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, ["layer", "pts", "r", "src"], "clone") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  cmd_dabs(s, tokens, false, true)
}

///|
/// 两条落笔命令的公共部分（校验已由调用方做完）。
fn cmd_dabs(
  s : Session,
  tokens : Array[String],
  erase : Bool,
  clone : Bool,
) -> String {
  // 命令名**一处**推出（三条命令共用这个函数；名字决定回包 op、快照文案与
  // 用法串——各写一份就是"同一个判断两处实现"）
  let name = if erase { "erase" } else if clone { "clone" } else { "brush" }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  if tokens.length() < 2 {
    let extra = if clone { " src=x,y" } else { "" }
    return err("用法：\{name} layer=<id> pts=x1,y1;x2,y2[;…] r=<半径px>\{extra}")
  }
  let m = kv_args(tokens, 1)
  let lid = match m.get("layer") {
    Some(v) => v
    None => return err("\{name} 需要 layer=<id>")
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
    None => return err("\{name} 需要 pts=x1,y1;x2,y2[;…]")
  }
  let r = match arg_d(m, "r", 4.0) {
    Ok(v) => v
    Err(e) => return err(e)
  }
  if r <= 0.0 || r > 200.0 {
    return err("r 越界（0 < r ≤ 200）")
  }
  let color : Int = if erase || clone {
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
  // 克隆的源偏移：**画布坐标**（同 pts）。锚点必须在画布内——取样源就是画布
  // 合成结果，锚点在外面等于"这一笔拿不到任何东西"，入口直接拒而不是画一片空。
  let mut sdx = 0.0
  let mut sdy = 0.0
  if clone {
    let (sx, sy) = match m.get("src") {
      Some(v) =>
        match parse_xy(v) {
          Ok(p) => p
          Err(e) => return err(e)
        }
      None => return err("clone 需要 src=x,y（源锚点，画布坐标）")
    }
    if sx < 0.0 || sy < 0.0 || sx >= doc.width.to_double() || sy >= doc.height.to_double() {
      return err(
        "源锚点 (\{@core.fmt_num(sx)},\{@core.fmt_num(sy)}) 超出画布 (\{doc.width}x\{doc.height})",
      )
    }
    sdx = sx - pts[0].0
    sdy = sy - pts[0].1
    if sdx == 0.0 && sdy == 0.0 {
      return err("源锚点与第一个落点重合：克隆会把自己盖到自己上（源偏移不能是 0,0）")
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
      dabs.push({
        x: ax + dx * t,
        y: ay + dy * t,
        r,
        color,
        erase,
        clone,
        sdx,
        sdy,
      })
      k = k + 1
    }
    i = i + 1
  }
  let last = pts[pts.length() - 1]
  dabs.push({ x: last.0, y: last.1, r, color, erase, clone, sdx, sdy })
  snapshot(s, doc, "\{name} \{lid} (\{dabs.length()} dabs)")
  let _ = update_layer(doc.layers, lid, fn(l) { { ..l, dabs: l.dabs + dabs } })
  "{\"ok\":true,\"op\":\"\{name}\",\"id\":\"\{lid}\",\"dabs\":\{dabs.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
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
