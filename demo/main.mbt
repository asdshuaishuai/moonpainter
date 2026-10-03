/// demo —— 专业修图软件 UI（demo/main）。
///
/// 人机操作面（非一键 AI）：左列真实工具（移动/画笔/橡皮/吸管/裁剪/文本/缩放），
/// 上下文选项条（笔色/笔径/滤镜强度/裁剪确认），右侧「调整·滤镜」面板
/// （磨皮/美白/色彩/滤镜，全部以调整层叠加，可撤销可保存）。

let g_sel : Ref[String] = Ref("")
let g_ready : Ref[Bool] = Ref(false)
/// 当前画笔层 id（首个 brush 使用时惰性创建/绑定）
let g_paint : Ref[String] = Ref("")
/// 逐点绘制（折线/多边形）已点的点，画布坐标（整数：画布事件本来就取整）。
/// 空白键的 `points=` 只能建层时给——"逐点连击"是**人类**画多边形的唯一路子，
/// 而前端此前只有单次拖拽的交互，于是折线/多边形整条能力只有 AI 够得到。
let g_pts : Ref[Array[(Int, Int)]] = Ref([])
/// 「换图」模式：非空 = 下一次文件选择要把这张图**原地换掉**（值是要换的层 id）。
/// 复用同一个 `<input type=file>`：多一个输入框就多一条"选完文件不知道走哪条路"的路。
let g_swap : Ref[String] = Ref("")
/// 待应用裁剪区域 "x,y,w,h"（空串=无）
let g_crop : Ref[String] = Ref("")

fn eng(line : String) -> Json {
  parse_json_safe(engine_exec_line(line))
}

fn eng_ok(j : Json) -> Bool {
  json_has_ok(j)
}

fn eng_s(j : Json, key : String) -> String {
  json_get_str(j, key)
}

fn eng_render(w : Int) -> Unit {
  let r = eng("render \{w}")
  let b64 = eng_s(r, "png_b64")
  if b64 != "" {
    js_canvas_img(b64)
  }
}

/// Double → 紧凑字符串（整数不带小数点）。
fn d2s(d : Double) -> String {
  if d == d.to_int().to_double() {
    d.to_int().to_string()
  } else {
    "\{d}"
  }
}

///|
/// 确保画笔层存在：优先复用既有 raster 层，否则新建。
fn ensure_paint_layer() -> String {
  if g_paint.val != "" {
    return g_paint.val
  }
  // 找既有 raster 层
  let j = eng("list-layers")
  match json_get(j, "layers") {
    Some(Json::Array(ls)) =>
      for l in ls {
        if json_get_str(l, "kind") == "raster" {
          g_paint.val = json_get_str(l, "id")
          return g_paint.val
        }
      }
    _ => ()
  }
  let r = eng("add-paint name=画笔层")
  g_paint.val = eng_s(r, "id")
  g_paint.val
}

///|
/// 笔刷/橡皮分段（画布拖拽节流上送；一段一撤销快照）。
fn do_stroke(mode : String, pts : String) -> Unit {
  bootstrap()
  let lid = ensure_paint_layer()
  let size = js_state_get("size")
  let cmd = if mode == "erase" {
    "erase layer=\{lid} pts=\{pts} r=\{size}"
  } else {
    let color = js_state_get("color")
    if color == "" {
      "brush layer=\{lid} pts=\{pts} r=\{size} color=#FF3366FF"
    } else {
      "brush layer=\{lid} pts=\{pts} r=\{size} color=\{color}FF"
    }
  }
  let r = eng(cmd)
  if eng_ok(r) {
    eng_render(800)
    refresh_layers_light()
  }
}

///|
/// 吸管取色：sample → 回填笔色 + 状态栏提示。
fn do_pick(coords : String) -> Unit {
  bootstrap()
  let parts : Array[String] = []
  for p in coords.split(",") {
    parts.push(p.to_owned())
  }
  if parts.length() != 2 {
    return
  }
  let x = parts[0]
  let y = parts[1]
  // 一下点击做两件事：`sample` 取色 + `pick` 认这一点的层是谁，并把那一层
  // **选中**。此前只有取色，于是"看到想要的颜色/元素，点一下把它选上接着改"
  // 这个最自然的动作做不到——`pick` 这条命令也就只有 AI 够得到（README 名单
  // 里那条理由写着"名字撞车，人类用 sample"，其实缺的是**这个动作**）。
  let r = eng("sample \{x} \{y}")
  let color = eng_s(r, "color")
  let pr = eng("pick \{x} \{y}")
  let id = match json_get(pr, "id") {
    Some(Json::String(s)) => s
    _ => ""
  }
  let at = if id != "" {
    g_sel.val = id
    "（层 \{id} 已选中）"
  } else {
    "（这一点没有层）"
  }
  if color != "" {
    js_set_brush_color(color)
  }
  refresh_ui()
  if color != "" {
    js_status_bar("💧 取色 \{color} \{at} — 已设为笔刷颜色")
  } else {
    js_status_bar("💧 \{at}")
  }
}

///|
/// 文本工具：画布点击选位置 → 选项条输入内容 → 添加。
fn do_text_pick(coords : String) -> Unit {
  bootstrap()
  js_set_text_target(coords)
  js_status_bar("T 位置已选 (\{coords.replace(old=",", new=", ")}) — 在上方输入文字后点「添加」")
}

///|
///|
/// 把自由文本包成命令行参数：双引号包裹，内部的双引号与反斜杠按
/// `tokenize_line` 的转义规则处理。图层名/文字内容都走这里。
fn quote_arg(s : String) -> String {
  let esc = s.replace(old="\\", new="\\\\").replace(old="\"", new="\\\"")
  "\"" + esc + "\""
}

///|
fn do_text_add() -> Unit {
  let txt = js_val("tinput")
  if txt.trim(char_set=" \t").length() == 0 {
    js_status_bar("⚠ 先输入文字内容")
    return
  }
  let coords = js_state_get("textAt")
  if coords == "" {
    js_status_bar("⚠ 先用文本工具点击画布选择位置")
    return
  }
  // 含空格的文字必须包双引号（引号内的空格不参与分词，见 agent 的
  // tokenize_line）。原先这里把空格换成下划线，但引擎从不还原它，于是
  // 用户输入 "Hello World" 存进去、渲染出来都是 "Hello_World"。
  let quoted = quote_arg(txt)
  let parts : Array[String] = []
  for p in coords.split(",") {
    parts.push(p.to_owned())
  }
  if parts.length() != 2 {
    return
  }
  let color = js_state_get("color")
  let fill = if color == "" { "#222222" } else { color }
  let r = eng("add-text x=\{parts[0]} y=\{parts[1]} text=\{quoted} font_size=32 fill=\{fill}FF name=文本")
  if eng_ok(r) {
    js_set_text_target("")
    js_val_clear("tinput")
    eng_render(800)
    refresh_ui()
    js_status_bar("T 文本已添加")
  }
}

///|
/// 移动工具：拖拽增量 → 选中图层 move（松手提交）。
fn do_move_delta(dx_s : String, dy_s : String) -> Unit {
  bootstrap()
  if g_sel.val == "" {
    js_status_bar("🖐 先在图层面板选中图层，再拖动移动")
    return
  }
  let dx = parse_double_safe(dx_s)
  let dy = parse_double_safe(dy_s)
  if dx == 0.0 && dy == 0.0 {
    return
  }
  let q = eng("query-layer \{g_sel.val}")
  let l = match json_get(q, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  // 判据（纯函数）在前：`move` 对这些 kind 回 ok 而画面逐位不变，
  // 照发就是"拖了没反应还没人说话"——手势层也走能力表（PLAN 五十一）。
  let refusal = move_gesture_refusal(l)
  if refusal != "" {
    js_status_bar("🖐 " + refusal)
    return
  }
  let lx = json_num(l, "x")
  let ly = json_num(l, "y")
  let r = eng("move \{g_sel.val} \{d2s(lx + dx)} \{d2s(ly + dy)}")
  if !eng_ok(r) {
    // 人类侧入口必须报**引擎原话**（同 `do_ui_cmd`）
    js_status_bar("⚠ " + eng_s(r, "error"))
    return
  }
  eng_render(800)
  refresh_props()
}

///|
/// 取一个非负整数（取不到或非法给 0）。蒙版圆角/羽化用——它们是非负像素值，
/// 负号在这里没有意义，所以不走 `parse_double_safe` 那条带符号的路径。
fn parse_int_safe(s : String) -> Int {
  let mut v = 0
  for ch in s.iter() {
    let c = ch.to_int()
    if c < 48 || c > 57 {
      return 0
    }
    v = v * 10 + (c - 48)
  }
  v
}

///|
fn parse_double_safe(s : String) -> Double {
  let neg = s.has_prefix("-")
  let body = if neg { s[1:].to_owned() } else { s }
  let mut int_part = 0.0
  let mut frac_part = 0.0
  let mut in_frac = false
  let mut frac_scale = 0.1
  let mut ok = body.length() > 0
  for ch in body.iter() {
    let n = ch.to_int()
    if n >= 48 && n <= 57 {
      if in_frac {
        frac_part = frac_part + (n - 48).to_double() * frac_scale
        frac_scale = frac_scale * 0.1
      } else {
        int_part = int_part * 10.0 + (n - 48).to_double()
      }
    } else if ch == '.' && !in_frac {
      in_frac = true
    } else {
      ok = false
    }
  }
  let v = int_part + frac_part
  if neg { -v } else if ok { v } else { 0.0 }
}

///|
fn json_num(j : Json, key : String) -> Double {
  match json_get(j, key) {
    Some(Json::Number(n, ..)) => n
    _ => 0.0
  }
}

///|
/// 裁剪：拖拽完成后记录待应用区域并亮出确认按钮。
fn do_crop_ready(rect : String) -> Unit {
  g_crop.val = rect
  if rect == "" {
    js_show_crop_btns(false, "")
    js_status_bar("✂️ 拖拽选区裁剪")
  } else {
    js_show_crop_btns(true, rect)
    js_status_bar("✂️ 选区 \{rect} — 「应用裁剪」生效，或重新拖拽")
  }
}

///|
/// 蒙版拖拽落定：给**当前选中图层**加几何蒙版（kind = rect|ellipse）。
/// 坐标与裁剪一样走画布坐标，`set-mask` 只能改 invert，几何一律 add-mask 重建。
///|
/// 蒙版命令行拼接（**纯函数**，便于测试）。
///
/// 圆角与羽化**只在矩形上有效**：`radius` 是"仅矩形"的参数（引擎对椭圆会
/// 拒绝），`feather` 两者都吃。所以这里是 `kind == "rect"` 才带 `radius`。
/// 两者为 0 时不写进命令行——保持历史命令行的形状，也让"没设过"与"设了 0"
/// 在日志里可分辨。
pub fn mask_line(id : String, kind : String, parts : Array[String], radius : Int, feather : Int) -> String {
  let mut line = "add-mask \{id} kind=\{kind} x=\{parts[0]} y=\{parts[1]} w=\{parts[2]} h=\{parts[3]}"
  if kind == "rect" && radius > 0 {
    line = line + " radius=\{radius}"
  }
  if feather > 0 {
    line = line + " feather=\{feather}"
  }
  line
}

fn do_mask_ready(kind : String, rect : String) -> Unit {
  let id = g_sel.val
  if id == "" {
    js_status_bar("⚠ 先在右侧图层面板点选图层，再拖拽画蒙版")
    return
  }
  let parts : Array[String] = []
  for p in rect.split(",") {
    parts.push(p.to_owned())
  }
  if parts.length() != 4 {
    return
  }
  let radius = parse_int_safe(js_state_get("mask_radius"))
  let feather = parse_int_safe(js_state_get("mask_feather"))
  let r = eng(mask_line(id, kind, parts, radius, feather))
  if eng_ok(r) {
    let extra = if feather > 0 { "，羽化 \{feather}px" } else { "" }
    let extra2 = if kind == "rect" && radius > 0 { "，圆角 \{radius}px" } else { "" }
    js_status_bar("▨ 蒙版已加：\{rect}\{extra2}\{extra}（蒙版外不渲染）")
    eng_render(800)
    refresh_ui()
  }
}

///|
/// 蒙版反选。引擎的 `set-mask` 只改 invert，所以先查当前值再取反。
fn do_mask_invert(id : String) -> Unit {
  let q = eng("query-layer \{id}")
  let l = match json_get(q, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let cur = match json_get(l, "mask") {
    Some(m) =>
      match json_get(m, "invert") {
        Some(Json::True) => "false"
        _ => "true"
      }
    None => "true"
  }
  let _ = do_ui_cmd("set-mask \{id} \{cur}")
}

///|
fn do_mask_clear(id : String) -> Unit {
  let _ = do_ui_cmd("remove-mask \{id}")
}

///|
fn do_crop_apply() -> Unit {
  if g_crop.val == "" {
    return
  }
  let parts : Array[String] = []
  for p in g_crop.val.split(",") {
    parts.push(p.to_owned())
  }
  if parts.length() == 4 {
    let r = eng("crop \{parts[0]} \{parts[1]} \{parts[2]} \{parts[3]}")
    if eng_ok(r) {
      js_log_line("✂️ 裁剪 → \{parts[2]}x\{parts[3]}", "#4a4")
    } else {
      js_log_line("❌ 裁剪失败: \{eng_s(r, "error")}", "#f66")
    }
  }
  g_crop.val = ""
  js_show_crop_btns(false, "")
  js_hide_crop()
  eng_render(800)
  refresh_ui()
}

///|
fn do_crop_cancel() -> Unit {
  g_crop.val = ""
  js_show_crop_btns(false, "")
  js_hide_crop()
  js_status_bar("✂️ 已取消选区")
}

///|
/// 调整/滤镜按钮：op + 强度（有符号操作由 JS 传正负）。
fn do_filter(op : String, value_s : String) -> Unit {
  bootstrap()
  // 空串 = "这个算子没有可调数值"（黑白/反色）：**不要拼 value=**。
  // 引擎对"给没有数值的算子传 value="直接报错（渲染器压根不读它），
  // 此前这里一律拼 `value=0`，那两个按钮会因此失败。
  let line = if value_s == "" {
    "add-adjust op=\{op}"
  } else {
    "add-adjust op=\{op} value=\{value_s}"
  }
  let r = eng(line)
  if eng_ok(r) {
    eng_render(800)
    refresh_ui()
    let how = if value_s == "" { "无参数" } else { "value=\{value_s}" }
    js_status_bar("🎛 已叠加 \{op}（\{how}）— 调整层可撤销")
  } else {
    js_log_line("❌ \{eng_s(r, "error")}", "#f66")
  }
}

///|
/// 图层不透明度滑杆。
fn do_opacity(id : String, v_s : String) -> Unit {
  let v = parse_double_safe(v_s)
  let _ = do_ui_cmd("set-style \{id} opacity=\{d2s(v / 100.0)}")
}

///|
fn bootstrap() -> Unit {
  if g_ready.val {
    return
  }
  let _ = engine_reset()
  let _ = engine_exec_line("session-open full_image")
  let _ = engine_exec_line("new 800 600 uuid=painter")
  let _ = engine_exec_line("add-rect x=0 y=0 w=800 h=600 fill=#F5F0EBFF name=画布底色 tag=background")
  let _ = engine_exec_line("add-rect x=80 y=100 w=300 h=200 fill=#2C3E6BFF radius=16 name=主卡片")
  let _ = engine_exec_line("add-ellipse x=440 y=120 w=180 h=180 lgrad=#FF7A45FF,#2E6FE8FF,0,0,1,1 name=渐变球")
  let _ = engine_exec_line("add-text x=100 y=340 text=MoonPainter font_size=32 fill=#2C3E6BFF name=标题")
  g_paint.val = ""
  g_ready.val = true
  eng_render(800)
  refresh_ui()
}

///|
/// 轻量刷新（笔刷拖拽中）：只更新状态栏，不重建面板。
fn refresh_layers_light() -> Unit {
  let fp_j = eng("fingerprint")
  js_status_bar("🖌 \{json_get_str(fp_j, "fingerprint")[0:12].to_owned()}…")
}


///|
/// 图层列表的 HTML：**纯函数**（输入 `list-layers` 的根级数组 + 当前选中 id），
/// 原先它长在 `refresh_ui` 里、只有浏览器点开才生成，测试拿不到——同
/// `tool_line` 那次提取的理由：能测的那半要测得到。
fn layers_html(layers : Array[Json], sel : String) -> String {
  let count = layers.length()
  let sb = StringBuilder()
  let mut i = count - 1
  while i >= 0 {
    let l = layers[i]
    let lid = json_get_str(l, "id")
    let lnm = json_get_str(l, "name")
    let lkd = json_get_str(l, "kind")
    let vis = match json_get(l, "visible") {
      Some(Json::True) => true
      _ => false
    }
    let selc = if lid == sel { " sel" } else { "" }
    let eye = if vis { "👁" } else { "🚫" }
    let ico = match lkd {
      "text" => "T"
      "image" => "🖼"
      "group" => "📁"
      "adjust" => "◐"
      "raster" => "🖌"
      _ => "□"
    }
    sb.write_string("<div class='li")
    sb.write_string(selc)
    sb.write_string("' onclick='globalThis.__sel(\"")
    sb.write_string(lid)
    sb.write_string("\")'><span class='eye' onclick='event.stopPropagation();globalThis.__vis(\"")
    sb.write_string(lid)
    sb.write_string("\")'>")
    sb.write_string(eye)
    sb.write_string("</span><span class='ico'>")
    sb.write_string(ico)
    sb.write_string("</span><span class='lnm'>")
    // 层名/类型是**用户输入或容器内容**：不转义的话名字里的 `<` 会被浏览器
    // 当成标签（名字后半截直接消失），`&` 会吃掉后面几个字符。
    sb.write_string(html_attr(lnm))
    sb.write_string("</span><span class='lkd'>")
    sb.write_string(html_attr(lkd))
    sb.write_string("</span>")
    // 空组给个记认：`group-remove` 把最后一个成员移走之后，组会**留在原地**
    // （引擎不替你删——那才是静默动作），而 `lint` 把它算作"装了却什么都不干"。
    // 人类侧看不到 lint，所以在列表上直接标出来，才谈得上"看得见、删得掉"。
    if is_empty_group(l) {
      sb.write_string("<span class='lkd' title='空组：lint 会报「装了却什么都不干」'>空</span>")
    }
    // 有蒙版的层给个记认（否则用户看不出这层的可见范围被裁过）
    match json_get(l, "mask") {
      Some(m) =>
        match json_get(m, "invert") {
          Some(Json::True) => sb.write_string("<span class='lkd' title='蒙版·反选'>▨反</span>")
          _ => sb.write_string("<span class='lkd' title='蒙版'>▨</span>")
        }
      None => ()
    }
    sb.write_string("</div>")
    i = i - 1
  }
  sb.to_string()
}

fn refresh_ui() -> Unit {
  let j = eng("list-layers")
  if !eng_ok(j) {
    return
  }
  let layers = match json_get(j, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  let count = layers.length()
  js_refresh_layers(layers_html(layers, g_sel.val))
  let fp_j = eng("fingerprint")
  let fp = json_get_str(fp_j, "fingerprint")
  let doc_j = eng("inspect")
  let _ = doc_j
  js_status_bar("图层: \{count} │ 指纹: \{fp}")
  refresh_props()
}

///|
/// HTML 属性值里的特殊字符转义。层名/文字内容/标签都是**用户输入**，
/// 直接拼进 `value='…'` 会让一个引号把后面的结构撑破（属性截断、后续
/// 属性变成正文），而测试看不出"结构破了"——所以拼 HTML 的用户输入一律过它。
fn html_attr(s : String) -> String {
  s.replace(old="&", new="&amp;")
    .replace(old="'", new="&#39;")
    .replace(old="\"", new="&quot;")
    .replace(old="<", new="&lt;")
    .replace(old=">", new="&gt;")
}

///|
/// 翻转的两个布尔值 → `flip` 命令的方向词。四个组合都能表达
/// （(t,f)=h，(f,t)=v，(t,t)=both，(f,f)=none），所以按钮只要把**目标状态**
/// 算出来交给引擎即可——不需要"切换"语义（`flip` 是**设置**不是取反，
/// 这一点曾经差一点让按钮写成 `flip id h` 而把垂直翻转悄悄清掉）。
fn flip_word(fh : Bool, fv : Bool) -> String {
  if fh && fv {
    "both"
  } else if fh {
    "h"
  } else if fv {
    "v"
  } else {
    "none"
  }
}

///|
/// 数字输入框（属性面板用）。`handler(id, this.value)` —— 两个参数，
/// 与 `js_reg2s` 的签名一致。
fn num_input(label : String, val : String, handler : String, id : String) -> String {
  "<span class='pk'>" + label + "</span><input class='pnum' type='number' value='" +
  html_attr(val) + "' onchange='globalThis." + handler + "(\"" + id +
  "\",this.value)'/>"
}

///|
/// 文本输入框（层名/文字内容/算子/标签）。`val` 为空时显示占位提示。
fn txt_input(ph : String, val : String, handler : String, id : String) -> String {
  "<input class='pin' value='" + html_attr(val) + "' placeholder='" + html_attr(ph) +
  "' onchange='globalThis." + handler + "(\"" + id + "\",this.value)'/>"
}

///|
/// 在 `list-layers` 的嵌套树里找某层的**父组 id**：根级层 → `Some("")`，
/// 找不到 → `None`。`query-layer` 不报父级，而"加入/移出组"必须知道它现在挂在
/// 谁身上——属性面板的「父级」选择器要用这个（人类侧唯一能回读层级的路径）。
fn parent_group_of(layers : Array[Json], id : String, parent : String) -> String? {
  for l in layers {
    let lid = json_get_str(l, "id")
    if lid == id {
      return Some(parent)
    }
    match json_get(l, "children") {
      Some(Json::Array(kids)) => {
        match parent_group_of(kids, id, lid) {
          Some(p) => return Some(p)
          None => ()
        }
      }
      _ => ()
    }
  }
  None
}

///|
/// 这个层是不是**空组**（组且一个成员都没有）。提成一处实现：图层列表的
/// "空"标识与白盒测试共用——`group-remove` 移走最后一个成员之后组会留在原地，
/// 而 `lint` 会把它算作"装了却什么都不干"。
fn is_empty_group(l : Json) -> Bool {
  if json_get_str(l, "kind") != "group" {
    return false
  }
  match json_get(l, "children") {
    Some(Json::Array(k)) => k.length() == 0
    _ => true
  }
}

///|
fn find_id_deep(layers : Array[Json], id : String) -> Bool {
  for l in layers {
    if json_get_str(l, "id") == id {
      return true
    }
    match json_get(l, "children") {
      Some(Json::Array(kids)) => {
        if find_id_deep(kids, id) {
          return true
        }
      }
      _ => ()
    }
  }
  false
}

///|
/// 收集**根级**的组：面板的「父级」下拉只列它们——`group-add` 的成员必须是根级层，
/// 所以能当父级的也只有根级组（嵌套编组引擎侧不支持）。
fn root_groups(layers : Array[Json]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for l in layers {
    if json_get_str(l, "kind") == "group" {
      out.push((json_get_str(l, "id"), json_get_str(l, "name")))
    }
  }
  out
}

///|
/// 一个新组的 id：`g1`、`g2`…取第一个没被占用的。**不许撞已有的 id**——
/// `group` 撞 id 会直接报错，而人类点一下「编组」不该看到错误。
fn fresh_group_id(layers : Array[Json]) -> String {
  let mut k = 1
  while k < 1000 {
    let cand = "g\{k}"
    if !find_id_deep(layers, cand) {
      return cand
    }
    k = k + 1
  }
  "g\{js_now_ms()}"
}

///|
/// 从一层 JSON 里读能力表（引擎 `query-layer`/`list-layers` 的 `caps`）。
/// 与 `caps_reported` 配对用：**缺字段**（前端/引擎版本不匹配）与**空表**
/// （这个层真的没有可改的变换能力）是两件事，不许合成一件。
fn caps_of(l : Json) -> Array[String] {
  match json_get(l, "caps") {
    Some(Json::Array(a)) =>
      a.map(fn(t) {
        match t {
          Json::String(x) => x
          _ => ""
        }
      })
    _ => []
  }
}

///|
fn caps_reported(l : Json) -> Bool {
  match json_get(l, "caps") {
    Some(_) => true
    None => false
  }
}

///|
/// 拖动这个层会不会**改变画面**？空串 = 可以拖，非空 = 拒绝的理由。
///
/// 判据只看引擎报的 `caps`，**不看 kind**：`move` 对调整层回 `ok` 而画面
/// 逐位不变（实测，见 PLAN 五十一）——手势照发就是**静默失败的手势**，
/// 和"面板画出改了没反应的输入框"是同一类问题（静默失败的入口比没有入口更坏）。
/// 提成纯函数是为了**不用引擎也能正反两向测**（拼 HTML/判据这一半必须在测试里）。
fn move_gesture_refusal(l : Json) -> String {
  if !caps_reported(l) {
    return "引擎没报 caps（前端/引擎版本可能不匹配）：拖动已停用"
  }
  if caps_of(l).contains("move") {
    return ""
  }
  let kind = json_get_str(l, "kind")
  // 组现在会**搬内容**（`caps` 里有 `move`）⇒ 走到这里的只可能是"搬了也什么都不动"
  // 的容器（空组 / 只装调整层的组）与调整层本身
  "这个层（\{kind}）的 x/y 不参与渲染（它没有自己的画面：调整层作用于其下的合成，空组/只装调整层的组搬了也没有内容可搬）：拖动不会改变画面"
}

///|
/// 属性面板的 HTML：**纯函数**（输入 `query-layer` 的那一层 + `list-layers` 的根级数组）。
/// 原先它长在 `refresh_props` 里、只有浏览器点开某个图层才生成，测试拿不到——
/// 与 `layers_html` 同一次提取：能测的那半要测得到（`build_demo.sh#html-wiring`
/// 那种源码级 grep 只能证明"写过"，证明不了"拼出来的 HTML 里有"）。
fn props_html(l : Json, roots : Array[Json]) -> String {
  let sb = StringBuilder()
  let gid = json_get_str(l, "id")
  let gname = json_get_str(l, "name")
  let gkind = json_get_str(l, "kind")
  let gx = json_num_str(l, "x")
  let gy = json_num_str(l, "y")
  let gw = json_num_str(l, "w")
  let gh = json_num_str(l, "h")
  let gop = json_num_str(l, "opacity")
  let gbl = json_get_str(l, "blend")
  // `json_num_str` 对**缺失**字段回 "—"（那是给人看的占位），但
  // `<input type=number>` 拿到 "—" 只会显示空白、提交时又是空串——
  // 这里回落到 0（旋转缺省就是 0，与 canonical JSON 省略该字段等价）
  let grot = match json_get(l, "rot") {
    Some(_) => json_num_str(l, "rot")
    None => "0"
  }
  let gtext = json_get_str(l, "text")
  let gfs = json_num_str(l, "font_size")
  let (adj_op, adj_val) = match json_get(l, "adjust") {
    Some(a) => (json_get_str(a, "op"), json_num_str(a, "value"))
    None => ("", "")
  }
  let gtags : Array[String] = match json_get(l, "tags") {
    Some(Json::Array(a)) =>
      a.map(fn(t) {
        match t {
          Json::String(x) => x
          _ => ""
        }
      })
    _ => []
  }
  // 能力表（引擎 `query-layer` 报的 `caps`）：面板**不抄 kind 名单**，
  // 一切"这个控件画不画"都问它——判断两处实现必然先烂（PLAN 五十一）。
  // `has_caps` 与空表要分开：缺字段是**前端/引擎版本不匹配**（该明说），
  // 空表是"这个层真的没有可改的变换能力"。
  let has_caps = caps_reported(l)
  let caps = caps_of(l)
  let can = fn(c : String) -> Bool { caps.contains(c) }
  // 调整层显示算子
  let adj = match json_get(l, "adjust") {
    Some(a) => {
      let op = json_get_str(a, "op")
      let v = json_num_str(a, "value")
      "<span class='pk'>算子</span><span class='pv'>\{op} (\{v})</span>"
    }
    None => ""
  }
  let sb = StringBuilder()
  sb.write_string("<div class='pg'>")
  sb.write_string("<span class='pk'>ID</span><span class='pv'>")
  sb.write_string(gid)
  sb.write_string("</span><span class='pk'>名称</span><span class='pv'>")
  sb.write_string(html_attr(gname))
  sb.write_string("</span><span class='pk'>类型</span><span class='pv'>")
  sb.write_string(gkind)
  sb.write_string("</span>")
  sb.write_string(adj)
  sb.write_string("<span class='pk'>X</span><span class='pv'>")
  sb.write_string(gx)
  sb.write_string("</span><span class='pk'>Y</span><span class='pv'>")
  sb.write_string(gy)
  sb.write_string("</span><span class='pk'>W</span><span class='pv'>")
  sb.write_string(gw)
  sb.write_string("</span><span class='pk'>H</span><span class='pv'>")
  sb.write_string(gh)
  sb.write_string("</span><span class='pk'>混合</span><span class='pv'>")
  sb.write_string(gbl)
  sb.write_string("</span></div>")
  // ── 人类侧的可改属性 ──────────────────────────────────────────
  // 这一块此前只有「不透明度滑杆 + 删/置顶/置底 + 蒙版 + 分组」：层名、坐标、
  // 尺寸、旋转、翻转、文字内容、调整算子、标签**全都只有 AI 改得动**——
  // 人类想把一个层挪 10 像素、改个名字、把字放大一点，只能删了重加（蒙版/
  // 标签/层序/id 引用全丢，调整层还会被推到栈顶改变作用范围）。每条控件都
  // 直接对到一条引擎命令，命令名在源码里是字面量——`ui_audit.py` 按
  // "字符串首词是命令名"统计人类面覆盖，所以这里写的就是那份名册。
  sb.write_string("<div class='pedit'>")
  sb.write_string(txt_input("层名", gname, "__rename", gid))
  if !has_caps {
    // 宁可少画、也要说清为什么：静默少一排控件，人会以为界面坏了。
    sb.write_string(
      "<span class='pv' title='本页从引擎的 query-layer 读 caps（能力表）决定画哪些控件；读不到就一个都不画，免得画出改了没反应的控件'>（引擎没报 caps：能力相关控件已隐藏，前端与引擎版本可能不匹配）</span>",
    )
  } else {
    if can("move") {
      sb.write_string(num_input("X", gx, "__setx", gid))
      sb.write_string(num_input("Y", gy, "__sety", gid))
    } else {
      // `move` 对这个 kind **没有画面效果**（实测：组/调整层 x/y 不读）——
      // 发一个改了不动的输入框就是静默失败的入口（PLAN 五十一）。
      sb.write_string(
        "<span class='pk'>X/Y</span><span class='pv' title='这个 kind 的 x/y 不参与渲染：move 回 ok 而画面逐位不变'>" +
        html_attr(gx) + "," + html_attr(gy) + "（不参与渲染）</span>",
      )
    }
    if can("resize") {
      sb.write_string(num_input("W", gw, "__setw", gid))
      sb.write_string(num_input("H", gh, "__seth", gid))
    } else {
      sb.write_string(
        "<span class='pk'>W/H</span><span class='pv' title='这个 kind 的 w/h 不参与渲染（文本按字号画、笔触的窗口是画布尺寸、组画的是子层、调整层作用于其下合成）：改它画面不会变，盒子与墨不符时 lint 会报'>" +
        html_attr(gw) + "×" + html_attr(gh) + "（不参与渲染，故不可改）</span>",
      )
    }
    if can("rotate") {
      sb.write_string(num_input("旋转", grot, "__rotate", gid))
    } else {
      sb.write_string(
        "<span class='pk'>旋转</span><span class='pv' title='这个 kind 不读 rotation_deg：rotate 会被引擎拒绝（错误原话在状态栏）'>不适用</span>",
      )
    }
    if can("flip") {
      sb.write_string("<button class='ghost' title='水平翻转' onclick='globalThis.__flip(\"")
      sb.write_string(gid)
      sb.write_string("\",\"h\")'>⇋</button>")
      sb.write_string("<button class='ghost' title='垂直翻转' onclick='globalThis.__flip(\"")
      sb.write_string(gid)
      sb.write_string("\",\"v\")'>⇅</button>")
    } else {
      sb.write_string(
        "<span class='pk'>翻转</span><span class='pv' title='这个 kind 不读 flip_h/flip_v：flip 会被引擎拒绝'>不适用</span>",
      )
    }
  }
  sb.write_string("</div>")
  if can("asset") {
    sb.write_string("<div class='pedit'><button class='ghost' title='原地换掉这张图：层序/蒙版/标签/透明度/翻转/旋转都不动' onclick='globalThis.__img_swap(\"")
    sb.write_string(gid)
    sb.write_string("\");document.getElementById(\"file-in\").click()'>换图</button></div>")
  }
  if can("text") {
    sb.write_string("<div class='pedit'>")
    sb.write_string(txt_input("文字内容", gtext, "__text_set", gid))
  }
  if can("font_size") {
    sb.write_string("<div class='pedit'>")
    sb.write_string(num_input("字号", gfs, "__text_font", gid))
    sb.write_string("</div>")
  }
  if can("adjust") {
    sb.write_string("<div class='pedit'>")
    sb.write_string(txt_input("算子", adj_op, "__adj_op", gid))
    sb.write_string(num_input("数值", adj_val, "__adj_val", gid))
    sb.write_string("</div>")
  }
  sb.write_string("<div class='pedit'>")
  sb.write_string(txt_input("加标签", "", "__tag_add", gid))
  for t in gtags {
    sb.write_string("<span class='pvw'>#")
    sb.write_string(html_attr(t))
    sb.write_string("<button class='ghost' title='摘掉这个标签' onclick='globalThis.__tag_del(\"")
    sb.write_string(gid)
    sb.write_string("\",\"")
    sb.write_string(html_attr(t))
    sb.write_string("\")'>✕</button></span>")
  }
  sb.write_string("</div>")
  // 不透明度滑杆（change 提交）。⚠️ 这一格也是能力：调整层的 α **不参与渲染**
  // （强度走算子的 `value`；实测 opacity=0.3 与 1.0 的 render sha 逐位相同）——
  // 给它画一个拖了没反应的滑杆就是静默入口，所以问 caps（PLAN 五十二）。
  if can("opacity") {
    sb.write_string("<div class='osl'><span class='pk'>α</span><input type='range' min='0' max='100' value='\{opacity_pct(gop)}' oninput='globalThis.__optip(\"")
    sb.write_string(gid)
    sb.write_string("\",this.value)' onchange='globalThis.__op(\"")
    sb.write_string(gid)
    sb.write_string("\",this.value)'/><span class='pv' id='opv'>")
    sb.write_string(gop)
    sb.write_string("</span></div>")
  } else {
    sb.write_string(
      "<div class='osl'><span class='pk'>α</span><span class='pv' title='调整层的不透明度不参与渲染：它的强度是算子的「数值」（value）'>不适用（强度用「数值」）</span></div>",
    )
  }
  sb.write_string("<div class='pact'><button onclick='globalThis.__del(\"")
  sb.write_string(gid)
  sb.write_string("\")'>删除</button><button onclick='globalThis.__front(\"")
  sb.write_string(gid)
  sb.write_string("\")'>置顶</button><button onclick='globalThis.__back(\"")
  sb.write_string(gid)
  sb.write_string("\")'>置底</button>")
  // 蒙版也是能力之一（组不读蒙版：引擎会拒 `add-mask`），照 caps 画
  if can("mask") {
    sb.write_string("<button onclick='globalThis.__mask_invert(\"")
    sb.write_string(gid)
    sb.write_string("\")'>蒙版反选</button><button class='ghost' onclick='globalThis.__mask_clear(\"")
    sb.write_string(gid)
    sb.write_string("\")'>去蒙版</button>")
  }
  // 分组：人类侧的入口。组 → 「解组」；非组 → 「编组」+「父级」下拉
  // （根级 / 各根级组，覆盖 group-add 与 group-remove 两个方向）。
  // `roots` 是**参数**（调用方取一次 `list-layers` 就够）——纯函数里不许再调
  // 引擎：那会让这一段重新变成"只有浏览器里点得动"的代码，测试一跑就 panic。
  let parent = match parent_group_of(roots, gid, "") {
    Some(p) => p
    None => ""
  }
  if can("children") {
    sb.write_string("<button class='ghost' onclick='globalThis.__ungroup_sel(\"")
    sb.write_string(gid)
    sb.write_string("\")'>解组</button>")
  } else {
    sb.write_string("<button class='ghost' onclick='globalThis.__group_sel(\"")
    sb.write_string(gid)
    sb.write_string("\")'>编组</button>")
    sb.write_string("<select title='父级：根级或某个组' onchange='globalThis.__reparent(\"")
    sb.write_string(gid)
    sb.write_string("\",this.value)'>")
    sb.write_string("<option value=''")
    if parent == "" {
      sb.write_string(" selected")
    }
    sb.write_string(">根级</option>")
    for g in root_groups(roots) {
      sb.write_string("<option value='")
      sb.write_string(g.0)
      sb.write_string("'")
      if parent == g.0 {
        sb.write_string(" selected")
      }
      sb.write_string(">")
      sb.write_string(g.0)
      sb.write_string(" · ")
      sb.write_string(g.1)
      sb.write_string("</option>")
    }
    // 手改容器可能造出嵌套（引擎侧建不出来）：父级不在根级组里时也要显示真话
    if parent != "" {
      let mut known = false
      for g in root_groups(roots) {
        if g.0 == parent {
          known = true
        }
      }
      if !known {
        sb.write_string("<option value='")
        sb.write_string(parent)
        sb.write_string("' selected>")
        sb.write_string(parent)
        sb.write_string("（嵌套）</option>")
      }
    }
    sb.write_string("</select>")
  }
  sb.write_string("</div>")
  sb.to_string()
}

fn refresh_props() -> Unit {
  let id = g_sel.val
  if id == "" {
    js_update_props("<div class='ns'>点击图层查看属性</div>")
    return
  }
  let j = eng("query-layer \{id}")
  if !eng_ok(j) {
    return
  }
  let l = match json_get(j, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  // 「父级」下拉的候选：只列**根级**组（`group-add` 拒非根级组）
  let lst = eng("list-layers")
  let roots = match json_get(lst, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  js_update_props(props_html(l, roots))
}

///|
fn opacity_pct(op_s : String) -> Int {
  let v = parse_double_safe(op_s)
  let p = (v * 100.0).to_int()
  if p < 0 {
    0
  } else if p > 100 {
    100
  } else {
    p
  }
}

///|
///|
/// 读一个布尔字段（缺失/类型不对都当 false）。原先这四行在 `do_vis` 里
/// 手写过一遍，翻转按钮再抄一遍就会分叉。
fn json_true(j : Json, key : String) -> Bool {
  match json_get(j, key) {
    Some(Json::True) => true
    _ => false
  }
}

fn json_num_str(j : Json, key : String) -> String {
  match json_get(j, key) {
    Some(Json::Number(n, ..)) => d2s(n)
    _ => "—"
  }
}

///|
/// 取整数（取不到给 0）。画布尺寸走这里——`json_num_str` 取不到会返回占位符
/// "—"，直接拿去当宽度会得到 0 或别的怪东西。
fn json_as_int(j : Json, key : String) -> Int {
  match json_get(j, key) {
    Some(Json::Number(n, ..)) => n.to_int()
    _ => 0
  }
}

fn do_sel(id : String) -> Unit {
  g_sel.val = id
  refresh_ui()
}

fn do_vis(id : String) -> Unit {
  let q = eng("query-layer \{id}")
  let l = match json_get(q, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let cur = match json_get(l, "visible") {
    Some(Json::True) => "false"
    _ => "true"
  }
  let _ = do_ui_cmd("visible \{id} \{cur}")
}

fn do_del(id : String) -> Unit {
  // 成功才动本地状态：删失败（例如 id 已经不在）还把选中清掉，人就更懵了
  if do_ui_cmd("delete \{id}") {
    if g_paint.val == id {
      g_paint.val = ""
    }
    g_sel.val = ""
  }
}

fn do_reorder(id : String, where_ : String) -> Unit {
  let _ = do_ui_cmd("reorder \{id} \{where_}")
}

///|
/// 人类侧「编组」：把选中的**根级**层包进一个新组（`group` 的成员下界是 1 个）。
/// 引擎的四条分组命令（`group`/`ungroup`/`group-add`/`group-remove`）此前只有
/// AI 与命令行走得到，前端一个分组动作都没有——README 因此写过一句假的
/// "人类前端可直接用"；这一轮把它变成真的。
fn do_group_sel(id : String) -> Unit {
  let j = eng("list-layers")
  let layers = match json_get(j, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  let gid = fresh_group_id(layers)
  // `group` 的成员必须是**根级**层：已经在组里的层点「编组」会被引擎拒——
  // 那句拒绝必须摆到状态栏（此前丢弃回包 ⇒ 点了什么都不发生、也没有一句话）
  if do_ui_cmd("group \{gid} \{id}") {
    g_sel.val = gid
  }
}

///|
fn do_ungroup_sel(id : String) -> Unit {
  if do_ui_cmd("ungroup \{id}") {
    g_sel.val = ""
  }
}

///|
/// 严格整数解析：**非数不许静默退默认**。`parse_double_safe` 失败是回 0.0 的，
/// 拿它当画布坐标，"读不出来"就变成"画在左上角"（而且回包还是 ok）。
/// 画布事件本来就取整，所以这里只认十进制整数（可带负号）。
fn strict_int(s : String) -> Int? {
  let t = s.trim(char_set=" \t").to_owned()
  let neg = t.has_prefix("-")
  let body = if neg { t[1:].to_owned() } else { t }
  if body.length() == 0 {
    return None
  }
  let mut v = 0
  for ch in body.iter() {
    let n = ch.to_int()
    if n < 48 || n > 57 {
      return None
    }
    v = v * 10 + (n - 48)
  }
  Some(if neg { -v } else { v })
}

///|
/// `"x0,y0,w,h"` → 四个整数（拖拽框）。**一个不合格就整体 None**，
/// 不许"部分成功"（三个数对、一个错，画出来的是另一块地方）。
fn box4(box : String) -> (Int, Int, Int, Int)? {
  let parts : Array[StringView] = box.split(",").collect()
  if parts.length() != 4 {
    return None
  }
  match (
    strict_int(parts[0].to_owned()),
    strict_int(parts[1].to_owned()),
    strict_int(parts[2].to_owned()),
    strict_int(parts[3].to_owned()),
  ) {
    (Some(x), Some(y), Some(w), Some(h)) => Some((x, y, w, h))
    _ => None
  }
}

///|
/// `"x,y"` → 一个点（逐点绘制）。
fn xy2(s : String) -> (Int, Int)? {
  let parts : Array[StringView] = s.split(",").collect()
  if parts.length() != 2 {
    return None
  }
  match (strict_int(parts[0].to_owned()), strict_int(parts[1].to_owned())) {
    (Some(x), Some(y)) => Some((x, y))
    _ => None
  }
}

///|
/// 点列 → `points=` 串（`x,y;x,y`）。局部坐标由调用方给（见 `pts_local`）。
fn pts_str(pts : Array[(Int, Int)]) -> String {
  let sb = StringBuilder::new()
  for i, p in pts {
    if i > 0 {
      sb.write_string(";")
    }
    sb.write_string("\{p.0},\{p.1}")
  }
  sb.to_string()
}

///|
/// 落一个点。与上一点**完全相同**就不加：双击的第二下会再落一个同坐标的点，
/// 不去重就变成"一条零长度线段"（引擎会照单收下）。
fn poly_add(pts : Array[(Int, Int)], x : Int, y : Int) -> Array[(Int, Int)] {
  let n = pts.length()
  if n > 0 && pts[n - 1].0 == x && pts[n - 1].1 == y {
    pts
  } else {
    pts + [(x, y)]
  }
}

///|
/// 点列的包围盒 `(x0, y0, w, h)`。**宽高至少 1**：水平的折线（所有点同 y）
/// 盒高是 0，而引擎的 `w/h > 0` 是硬下界（0 会被入口拒绝）——盒子取 1 像素，
/// 点仍落在盒内（`pts_local` 相对盒原点，y 都是 0）。
fn pts_box(pts : Array[(Int, Int)]) -> (Int, Int, Int, Int) {
  match pts {
    [] => (0, 0, 1, 1)
    _ => {
      let mut x0 = pts[0].0
      let mut y0 = pts[0].1
      let mut x1 = pts[0].0
      let mut y1 = pts[0].1
      for p in pts {
        if p.0 < x0 {
          x0 = p.0
        }
        if p.1 < y0 {
          y0 = p.1
        }
        if p.0 > x1 {
          x1 = p.0
        }
        if p.1 > y1 {
          y1 = p.1
        }
      }
      (x0, y0, max_int(1, x1 - x0), max_int(1, y1 - y0))
    }
  }
}

fn max_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// 点列 → 相对包围盒原点的局部点（引擎的 `points=` 是**本层 bbox 的局部坐标**，
/// 与 `x/y/w/h` 一起决定它落在哪；这一步写错的表现是"形状整体位移"）。
fn pts_local(pts : Array[(Int, Int)]) -> Array[(Int, Int)] {
  let (x0, y0, _, _) = pts_box(pts)
  pts.map(fn(p) { (p.0 - x0, p.1 - y0) })
}

///|
/// 点数够不够（**与引擎同一把尺子**：折线 ≥2、多边形 ≥3，`in_polygon`/线段的
/// 下界）。前端这道判只是为了在点第二个点之前就能说话，权威仍在引擎。
fn shape_ready(kind : String, n : Int) -> Bool {
  if kind == "line" {
    n >= 2
  } else {
    n >= 3
  }
}

///|
/// 状态栏提示：还差几个点。**空集也要说话**（"已点 0 个点"不是废话，是人
/// 唯一能确认工具真的切换了的反馈）。
fn poly_hint(kind : String, n : Int) -> String {
  let need = if kind == "line" { 2 } else { 3 }
  let what = if kind == "line" { "折线" } else { "多边形" }
  if n >= need {
    "✏️ \{what}：已点 \{n} 个点 —— 双击画布或按回车结束（点越多边越多）"
  } else {
    "✏️ \{what}：已点 \{n} 个点，还差 \{need - n} 个（双击/回车结束，Esc 放弃）"
  }
}

///|
/// 一条形状命令行（纯函数，测试直接喂点列断言）。`fill`/`stroke` 由调用方按
/// 工具取（多边形要填充、折线要描边），**不在这里偷偷给默认色**。
fn shape_line(
  kind : String,
  pts : Array[(Int, Int)],
  fill : String,
  stroke : String,
  sw : String
) -> String {
  let (x0, y0, w, h) = pts_box(pts)
  if kind == "line" {
    "add-line x=\{x0} y=\{y0} w=\{w} h=\{h} points=\{pts_str(pts_local(pts))} stroke=\{stroke} stroke_w=\{sw} name=折线"
  } else {
    "add-polygon x=\{x0} y=\{y0} w=\{w} h=\{h} points=\{pts_str(pts_local(pts))} fill=\{fill} name=多边形"
  }
}

///|
/// 提交一条**人类侧**命令：失败要把引擎的原话摆到状态栏上。
/// 这一层是这轮补的——此前人类侧的入口大多是 `let _ = engine_exec_line(…)`，
/// 失败了连"没反应"都算不上（画面不动，人以为自己点错了）。引擎的拒绝理由
/// 是它唯一的说明书（"羽化必须 ≥ 0"、"画布单边 ≤ 4096"），必须传给人。
fn do_ui_cmd(line : String) -> Bool {
  // `engine_exec_line` 回的是**字符串**（原始 JSON），走 `eng` 解析成 Json。
  // 返回成败：调用方若要顺带改本地状态（清选中、记新组 id），必须**只在成功后**改。
  let j = eng(line)
  if eng_ok(j) {
    eng_render(800)
    refresh_ui()
    true
  } else {
    js_status_bar("⚠ " + eng_s(j, "error"))
    false
  }
}

///|
/// 拖拽出的矩形/椭圆（`__shape_ready(kind, "x0,y0,w,h")`）。太小就当没画：
/// 一个 1×1 的层在画布上根本看不见，而它会改变指纹、进列表、被 lint 念。
fn do_shape_ready(kind : String, box : String) -> Unit {
  match box4(box) {
    Some((x0, y0, w, h)) => {
      if w < 2 || h < 2 {
        js_status_bar("⚠ 太小了（\{w}x\{h}）：拖出一个大于 2 像素的框再松手")
        return
      }
      let color = js_state_get("color")
      let fill = if color == "" { "#FF3366FF" } else { color + "FF" }
      // **命令名不许插值拼**（`"add-\{kind}"` 在源码里读不出是哪条命令，
      // 对账脚本会把 add-rect/add-ellipse 都判成"人类够不着"——判据看不见
      // 就等于没有入口）。两条命令各写一遍，参数部分共用。
      let args = "x=\{x0} y=\{y0} w=\{w} h=\{h} fill=\{fill} name="
      if kind == "ellipse" {
        let _ = do_ui_cmd("add-ellipse " + args + "椭圆")
      } else {
        let _ = do_ui_cmd("add-rect " + args + "矩形")
      }
    }
    None => js_status_bar("⚠ 画布坐标没读出来（\{box}）")
  }
}

///|
/// 逐点绘制落一个点（`__poly_click("x,y")`）。
fn do_poly_click(xy : String) -> Unit {
  match xy2(xy) {
    Some((x, y)) => {
      let kind = current_shape_tool()
      g_pts.val = poly_add(g_pts.val, x, y)
      js_poly_preview(pts_str(g_pts.val))
      js_status_bar(poly_hint(kind, g_pts.val.length()))
    }
    None => js_status_bar("⚠ 画布坐标没读出来（\{xy}）")
  }
}

///|
/// 当前是折线还是多边形（默认多边形）——形态只由工具决定，别在别处再判一遍。
fn current_shape_tool() -> String {
  if js_state_get("tool") == "line" {
    "line"
  } else {
    "poly"
  }
}

///|
/// 结束逐点绘制（双击 / 回车）：点数够就建层，不够就说还差几个。
fn do_poly_finish() -> Unit {
  let kind = current_shape_tool()
  let pts = g_pts.val
  if !shape_ready(kind, pts.length()) {
    js_status_bar(poly_hint(kind, pts.length()))
    return
  }
  let color = js_state_get("color")
  let c = if color == "" { "#FF3366FF" } else { color + "FF" }
  let sw = js_state_get("size")
  let line = shape_line(kind, pts, c, c, if sw == "" { "2" } else { sw })
  g_pts.val = []
  js_poly_preview("")
  let _ = do_ui_cmd(line)
}

///|
/// 放弃未闭合的点（Esc / 切换工具）。**要说一声**：点了一半切走工具，
/// 画面什么都不动而人以为"画上去了"是最坏的一种。
fn do_poly_cancel() -> Unit {
  let n = g_pts.val.length()
  if n > 0 {
    g_pts.val = []
    js_poly_preview("")
    js_status_bar("✏️ 已放弃 \{n} 个未闭合的点（折线/多边形要双击或回车结束）")
  }
}

///|
/// 进入「换图」模式：记住要换的层，随后由页面触发文件选择
/// （inline JS 里紧跟一次 `file-in` 的 click）。选完文件由
/// `on_file_selected` 按这个状态分叉成 `set-image`。
fn do_img_swap(id : String) -> Unit {
  g_swap.val = id
}

///|
/// 层重命名（`rename`）。空名字在入口就拦——引擎那边空名字会写进 canonical
/// JSON 与指纹，而列表上只剩一个空行，人根本认不出是哪一层。
fn do_rename(id : String, name : String) -> Unit {
  let n = name.trim(char_set=" \t").to_owned()
  if n.length() == 0 {
    js_status_bar("⚠ 层名不能为空")
    return
  }
  let _ = do_ui_cmd("rename " + id + " " + quote_arg(n))
}

///|
/// 改一个坐标/尺寸分量。引擎的 `move` / `resize` 都是**整对**赋值
/// （`move <id> <x> <y>`），所以先回读另一半再发——只发改的那个。
fn do_set_axis(id : String, key : String, v : String) -> Unit {
  let j = eng("query-layer " + id)
  if !eng_ok(j) {
    js_status_bar("⚠ " + eng_s(j, "error"))
    return
  }
  let l = match json_get(j, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let x = json_num_str(l, "x")
  let y = json_num_str(l, "y")
  let w = json_num_str(l, "w")
  let h = json_num_str(l, "h")
  let line = if key == "x" {
    "move " + id + " " + v + " " + y
  } else if key == "y" {
    "move " + id + " " + x + " " + v
  } else if key == "w" {
    "resize " + id + " " + v + " " + h
  } else {
    "resize " + id + " " + w + " " + v
  }
  let _ = do_ui_cmd(line)
}

///|
/// 绕层中心旋转（`rotate`）。
fn do_rotate(id : String, v : String) -> Unit {
  let _ = do_ui_cmd("rotate " + id + " " + v)
}

///|
/// 翻转：`flip` 是**设置**不是取反，所以要把当前两个标志读出来、算成目标
/// 状态（`flip_word`）再发——直接发 `flip id h` 会**悄悄清掉垂直翻转**。
fn do_flip(id : String, axis : String) -> Unit {
  let j = eng("query-layer " + id)
  if !eng_ok(j) {
    js_status_bar("⚠ " + eng_s(j, "error"))
    return
  }
  let l = match json_get(j, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let fh = if axis == "h" {
    !json_true(l, "flip_h")
  } else {
    json_true(l, "flip_h")
  }
  let fv = if axis == "v" {
    !json_true(l, "flip_v")
  } else {
    json_true(l, "flip_v")
  }
  let _ = do_ui_cmd("flip " + id + " " + flip_word(fh, fv))
}

///|
/// 改文字内容（`set-text`）。盒子跟着内容重算（引擎侧规则），所以这里不传
/// w/h——要固定盒子得显式给尺寸（AI 那条路）。
fn do_text_set(id : String, txt : String) -> Unit {
  if txt.length() == 0 {
    js_status_bar("⚠ 文字内容不能为空（空文本层会被 lint 报）")
    return
  }
  let _ = do_ui_cmd("set-text " + id + " " + quote_arg(txt))
}

///|
/// 改字号：`set-text` 的内容是**位置参数**，所以改字号得把当前文字带上。
fn do_text_font(id : String, v : String) -> Unit {
  let j = eng("query-layer " + id)
  if !eng_ok(j) {
    js_status_bar("⚠ " + eng_s(j, "error"))
    return
  }
  let l = match json_get(j, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let t = json_get_str(l, "text")
  let _ = do_ui_cmd("set-text " + id + " " + quote_arg(t) + " font_size=" + v)
}

///|
/// 改调整层的算子/数值（`set-adjust`，**原地改、层序不变**）。取值契约由
/// 引擎把关（invert/grayscale 不收 value、越界拒绝），错误原话转给人。
fn do_adj(id : String, which : String, v : String) -> Unit {
  let key = if which == "op" { "op=" } else { "value=" }
  let _ = do_ui_cmd("set-adjust " + id + " " + key + v)
}

///|
/// 打标签：这是人类把"哪几层是一组"告诉 AI 的通道——MVSL 的
/// `layer=@<标签>` 按标签选层，标签本身不影响渲染。
fn do_tag_add(id : String, t : String) -> Unit {
  let tag = t.trim(char_set=" \t").to_owned()
  if tag.length() == 0 {
    js_status_bar("⚠ 标签不能为空")
    return
  }
  let _ = do_ui_cmd("tag " + id + " " + quote_arg(tag))
}

///|
/// 摘标签（`untag`，与 `tag` 对偶）。
fn do_tag_del(id : String, t : String) -> Unit {
  let _ = do_ui_cmd("untag " + id + " " + quote_arg(t))
}

///|
/// 从输入框读一个画布尺寸，空/非数就用默认值（「新建」与「改画布」共用）。
fn canvas_dim(elem : String, dflt : String) -> String {
  let v = js_val(elem).trim(char_set=" \t").to_owned()
  match parse_double_safe(v) {
    d =>
      if d > 0.0 {
        v
      } else {
        dflt
      }
    _ => dflt
  }
}

///|
/// 改画布尺寸（`set-canvas`）：**只改画布，图层不动**。超上限（单边 4096）
/// 会被引擎拒，理由原样转给人。
fn do_set_canvas() -> Unit {
  let w = canvas_dim("cw", "800")
  let h = canvas_dim("ch", "600")
  let _ = do_ui_cmd("set-canvas " + w + " " + h)
}

///|
/// 「父级」下拉：`target == ""` = 移回根级，否则加进那个组。
/// 从 A 组换到 B 组要**两条**引擎命令（`group-remove` 再 `group-add`——引擎没有
/// "直接改嫁"的单条命令）；顺序是刻意的：先摘后加，第二步若失败层落在**根级**
/// 而不是两边都不在，状态可读可救。
fn do_reparent(id : String, target : String) -> Unit {
  let j = eng("list-layers")
  let layers = match json_get(j, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  let parent = match parent_group_of(layers, id, "") {
    Some(p) => p
    None => ""
  }
  if parent == target {
    return
  }
  if parent != "" {
    // 两步都经统一入口：哪一步失败就把**引擎原话**摆出来（成败决定下一步）
    if !do_ui_cmd("group-remove \{parent} \{id}") {
      return
    }
  }
  if target != "" {
    let _ = do_ui_cmd("group-add \{target} \{id}")
  }
}

fn do_undo() -> Unit {
  let _ = engine_exec_line("undo")
  g_paint.val = ""
  eng_render(800)
  refresh_ui()
}

fn do_redo() -> Unit {
  let _ = engine_exec_line("redo")
  g_paint.val = ""
  eng_render(800)
  refresh_ui()
}

fn do_new() -> Unit {
  // 尺寸跟着顶栏输入框走（此前写死 800×600，人想开个别的尺寸只能先建再裁）
  let w = canvas_dim("cw", "800")
  let h = canvas_dim("ch", "600")
  let _ = engine_exec_line("new " + w + " " + h + " uuid=n\{js_now_ms()}")
  let _ = engine_exec_line("add-rect x=0 y=0 w=\{w} h=\{h} fill=#FFFFFFFF name=背景")
  g_sel.val = ""
  g_paint.val = ""
  eng_render(800)
  refresh_ui()
}

async fn on_mpd_selected() -> Unit {
  bootstrap()
  let result = js_read_file_b64("mpd-in").wait()
  let ok = match json_get(result, "ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    js_log_line("⚠ 没有选中文件", "#f66")
    return
  }
  let b64 = match json_get(result, "b64") {
    Some(Json::String(s)) => s
    _ => ""
  }
  let name = match json_get(result, "name") {
    Some(Json::String(s)) => s
    _ => "?"
  }
  // 先声明 vision 能力再载入：闸是会话级的，载入后马上要 render 预览
  let _ = engine_exec_line("session-open full_image")
  let r = eng("open-mpd-b64 \{b64}")
  if eng_ok(r) {
    g_sel.val = ""
    g_paint.val = ""
    refresh_ui()
    // 用**容器自己的**画布宽度渲染：硬编码 800 会让打开一张别的尺寸的图时
    // 预览比例不对（引擎会按给定宽度缩放，看着"成功了"其实不是原尺寸）
    let w = match json_get(eng("inspect"), "manifest") {
      Some(m) =>
        match json_get(m, "canvas") {
          Some(c) => json_as_int(c, "w")
          None => 0
        }
      None => 0
    }
    eng_render(if w > 0 { w } else { 800 })
    let dims = if w > 0 { "\{w} 宽" } else { "尺寸未知" }
    js_log_line("📂 已打开 \{name}（\{dims}；容器即事实源，内容与保存时一致）", "#4a4")
  } else {
    js_log_line("⚠ 打开失败：\{eng_s(r, "error")}", "#f66")
  }
}

fn do_save() -> Unit {
  let r = eng("save-mpd-b64")
  let b64 = eng_s(r, "mpd_b64")
  if b64 != "" {
    js_download_file("painting.mpd", b64)
    js_log_line("📦 已保存 .mpd（含笔迹与调整层）", "#4a4")
  } else {
    js_log_line("⚠ 保存失败", "#f66")
  }
}

fn do_export() -> Unit {
  let r = eng("render 1200")
  let b64 = eng_s(r, "png_b64")
  if b64 != "" {
    js_download_file("export.png", b64)
    js_log_line("📷 PNG 已导出", "#4a4")
  }
}

///|
/// 一次文件选择 → 一条命令行：**「导入新层」还是「原地换图」由调用方给的
/// swap_id 决定**（空 = 导入）。抽成纯函数是为了让这条分叉可测——它是那种
/// "选完文件画面变了但变错了"的经典位置（把换图做成新层，蒙版/标签/层序全丢）。
fn import_line(swap_id : String, b64 : String, name : String) -> String {
  if swap_id != "" {
    "set-image " + swap_id + " b64=" + b64
  } else {
    "add-image x=100 y=60 w=600 h=450 b64=" + b64 + " name=" + quote_arg(name)
  }
}

///|
fn do_import(b64 : String, name : String) -> Unit {
  bootstrap()
  let cmd = "add-image x=100 y=60 w=600 h=450 b64=\{b64} name=\{quote_arg(name)}"
  let r = eng(cmd)
  if eng_ok(r) {
    js_log_line("📷 导入: \{name}（任意格式已转 PNG）", "#4a4")
    g_sel.val = eng_s(r, "id")
    eng_render(800)
    refresh_ui()
  } else {
    js_log_line("❌ 导入失败", "#f66")
  }
}

async fn ai_turn() -> Unit {
  bootstrap()
  let req = js_val("ai-request")
  if req.trim(char_set=" \t").length() == 0 {
    js_log_line("⚠ 请输入需求", "#fa0")
    return
  }
  js_disabled("ai-run", true)
  defer js_disabled("ai-run", false)
  let provider = js_val("ai-provider")
  let base_in = js_val("ai-baseurl")
  let model_in = js_val("ai-model")
  let key = js_val("ai-key")
  let cfg : LlmConfig = {
    provider,
    base_url: if base_in != "" { base_in } else { preset_base_url(provider) },
    model: if model_in != "" {
      model_in
    } else {
      match models_for(provider).get(0) {
        Some(m) => m.id
        None => ""
      }
    },
    api_key: key,
  }
  if cfg.provider != "mock" && (cfg.base_url == "" || cfg.api_key == "") {
    js_log_line("⚠ 真实端点需要 Base URL + API Key", "#fa0")
    return
  }
  js_log_line("── AI 回合 (\{cfg.provider}:\{cfg.model}) ──", "#6af")
  let summary = run_edit_turn(
    req,
    cfg,
    log=fn(line) {
      let c = if line.has_prefix("🔧") || line.has_prefix("🛠") {
        "#8af"
      } else if line.has_prefix("✅") {
        "#4a4"
      } else if line.has_prefix("❌") {
        "#f66"
      } else if line.has_prefix("🖼") {
        "#fa0"
      } else {
        ""
      }
      js_log_line(line, c)
    },
    on_image=fn(png) { js_canvas_img(png) },
  )
  js_log_line("💬 \{summary}", "#afa")
  g_paint.val = ""
  refresh_ui()
}

fn inject_css() -> Unit {
  js_css(
    #|*{margin:0;padding:0;box-sizing:border-box}
    #|body{font-family:-apple-system,'Segoe UI','PingFang SC',sans-serif;background:#111;color:#bbb;font-size:13px;overflow:hidden;user-select:none}
    #|#app{display:grid;grid-template-rows:40px 42px 1fr 24px auto;grid-template-columns:48px 1fr 264px;height:100vh}
    #|.topbar{grid-column:1/4;display:flex;align-items:center;background:#1b1b2e;border-bottom:1px solid #32324a;padding:0 10px;gap:2px;z-index:100}
    #|.topbar .logo{font-weight:700;color:#7ab8ff;font-size:14px;margin-right:14px;pointer-events:none}
    #|.topbar button{background:none;color:#99a;border:1px solid transparent;border-radius:4px;padding:4px 10px;font-size:12px;cursor:pointer;white-space:nowrap}
    #|.topbar button:hover{background:#2a2a4e;color:#dde}
    #|.topbar .sep{width:1px;height:18px;background:#333;margin:0 4px}
    #|.topbar .pri{background:#3d63ff;color:#fff;font-weight:500}
    #|.topbar .pri:hover{background:#5a7fff}
    #|.optbar{grid-column:1/4;display:flex;align-items:center;background:#22223a;border-bottom:1px solid #32324a;padding:0 12px;gap:8px;min-height:42px}
    #|.optbar .ctx{display:none;align-items:center;gap:8px;font-size:12px;color:#889}
    #|.optbar .ctx[data-for=move]{display:flex}
    #|.optbar input[type=range]{width:110px;accent-color:#3d63ff}
    #|.optbar input[type=color]{width:34px;height:26px;border:1px solid #3a3a5e;border-radius:4px;background:#0d1020;cursor:pointer;padding:1px}
    #|.optbar .hint{color:#556;font-size:11px}
    #|#crop-btns{display:none;align-items:center;gap:6px}
    #|#crop-btns button{background:#3d63ff;color:#fff;border:0;border-radius:4px;padding:4px 12px;font-size:12px;cursor:pointer;font-weight:500}
    #|#crop-btns button.ghost{background:#2a2a4e;color:#99a}
    #|.tools{background:#1b1b2e;border-right:1px solid #32324a;display:flex;flex-direction:column;align-items:center;padding:6px 0;gap:2px}
    #|.tools .t{width:36px;height:36px;display:flex;align-items:center;justify-content:center;border-radius:7px;cursor:pointer;font-size:16px;color:#778;transition:background .12s}
    #|.tools .t:hover{background:#2a2a4e;color:#ccd}
    #|.tools .t.on{background:#3d63ff;color:#fff}
    #|.tools .ts{width:26px;height:1px;background:#333;margin:4px 0}
    #|.carea{background:#26262f;display:flex;align-items:center;justify-content:center;overflow:auto;position:relative}
    #|.cwrap{border:1px solid #444;box-shadow:0 4px 24px #0008;background:repeating-conic-gradient(#3a3a4e 0% 25%,#2a2a3e 0% 50%) 0 0/16px 16px}
    #|#canvas-img{display:block;max-width:100%;max-height:72vh}
    #|#canvas-img.tool-brush,#canvas-img.tool-erase,#canvas-img.tool-pick,#canvas-img.tool-crop,#canvas-img.tool-text,#canvas-img.tool-rect,#canvas-img.tool-ellipse,#canvas-img.tool-line,#canvas-img.tool-poly{cursor:crosshair}
    #|.rpanel{background:#1b1b2e;border-left:1px solid #32324a;display:flex;flex-direction:column;overflow:hidden}
    #|.rscroll{flex:1;overflow-y:auto;display:flex;flex-direction:column}
    #|.ph{padding:7px 10px 5px;font-size:10px;font-weight:600;color:#667;text-transform:uppercase;letter-spacing:.8px;user-select:none}
    #|.fxgrid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:4px;padding:0 10px 8px}
    #|.fxgrid button{background:#26264a;color:#aab;border:1px solid #32325a;border-radius:5px;padding:6px 2px;font-size:11px;cursor:pointer;transition:all .1s}
    #|.fxgrid button:hover{background:#333a5a;border-color:#3d63ff;color:#dde}
    #|.fxgrid button:active{background:#3d63ff;color:#fff}
    #|.fstr{display:flex;align-items:center;gap:8px;padding:2px 10px 8px;font-size:11px;color:#889}
    #|.fstr input{flex:1;accent-color:#3d63ff}
    #|#llist{min-height:80px;max-height:200px;overflow-y:auto}
    #|.li{display:flex;align-items:center;padding:5px 8px;cursor:pointer;border-bottom:1px solid #20203a;gap:6px;font-size:12px;transition:background .1s}
    #|.li:hover{background:#22284a}
    #|.li.sel{background:#2a3a6e;border-left:2px solid #4a7cff}
    #|.li .eye{cursor:pointer;font-size:13px;width:20px;text-align:center;flex-shrink:0}
    #|.li .ico{width:18px;text-align:center;font-size:11px;color:#688;flex-shrink:0}
    #|.li .lnm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#bcc}
    #|.li .lkd{font-size:9px;color:#556;text-transform:uppercase}
    #|.ph2{padding:7px 10px;font-size:10px;font-weight:600;color:#667;text-transform:uppercase;letter-spacing:.8px;border-top:1px solid #2a2a4e;border-bottom:1px solid #2a2a4e}
    #|#pprops{padding:8px;overflow-y:auto}
    #|.pg{display:grid;grid-template-columns:52px 1fr;gap:2px 6px;font-size:11px}
    #|.pk{color:#567;text-align:right}
    #|.pv{color:#99a;user-select:text}
    #|.ns{color:#456;font-size:11px;text-align:center;padding:14px}
    #|.pact{margin-top:8px;display:flex;gap:4px}
    #|.pact button{flex:1;background:#2a2a4e;color:#89a;border:0;border-radius:4px;padding:4px;font-size:11px;cursor:pointer}
    #|.pact button:hover{background:#3a3a5e;color:#dde}
    #|.osl{display:flex;align-items:center;gap:6px;margin-top:6px;font-size:11px}
    #|.osl input{flex:1;accent-color:#3d63ff}
    #|.topbar .badge{margin-left:auto;color:#7f9;font-size:11px;padding:2px 8px;border:1px solid #2c3a4e;border-radius:10px;white-space:nowrap;user-select:text;cursor:help}
    #|.dbg{display:flex;flex-direction:column;gap:6px;padding:6px 8px 14px}
    #|.dbg button{background:#23233a;color:#bbc;border:1px solid #3a3a5e;border-radius:4px;padding:4px 7px;font-size:11px;cursor:pointer}
    #|.dbg button:hover{background:#2e2e4e;color:#dde}
    #|.dbg .dbgrow{display:flex;flex-wrap:wrap;gap:4px;align-items:center}
    #|.dbg .scbtn{background:#2b3f6b;color:#dce9ff;font-weight:600;padding:6px 8px}
    #|.dbg .scbtn:hover{background:#3a5290}
    #|.dbg .dbgta{width:100%;height:56px;background:#0d1020;color:#cdd;border:1px solid #3a3a5e;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:10px;padding:4px;user-select:text}
    #|.dbg .cmdin{flex:1;min-width:110px;background:#0d1020;color:#cdd;border:1px solid #3a3a5e;border-radius:4px;font-size:11px;padding:4px;user-select:text}
    #|.dbg .pk2{width:64px;background:#0d1020;color:#cdd;border:1px solid #3a3a5e;border-radius:4px;font-size:11px;padding:4px;user-select:text}
    #|.dbg .dbgout{max-height:190px;overflow:auto;background:#0d1020;color:#9ab;border:1px solid #2a2a44;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:10px;padding:6px;white-space:pre-wrap;word-break:break-all;user-select:text}
    #|.schdr{color:#7f9;font-size:10px;font-family:ui-monospace,Menlo,monospace;padding:2px 0 6px;border-bottom:1px solid #2a2a44;word-break:break-all}
    #|.sc{font-size:11px}
    #|.scok{color:#7fd18a;padding:2px 0;line-height:1.4}
    #|.scbad{color:#ff9b8a;padding:2px 0;line-height:1.4}
    #|.sct{width:100%;border-collapse:collapse;font-size:10px}
    #|.sct th{text-align:left;color:#778;font-weight:500;border-bottom:1px solid #2a2a44;padding:2px 3px}
    #|.sct td{vertical-align:top;padding:2px 3px;border-bottom:1px solid #1e1e30;line-height:1.35}
    #|.scp{color:#7fd18a;font-weight:700}
    #|.scf{color:#ff7a6a;font-weight:700}
    #|.scw{color:#889}
    #|.sce{color:#9ab;font-family:ui-monospace,Menlo,monospace;word-break:break-all}
    #|.sbar{grid-column:1/4;display:flex;align-items:center;background:#1b1b2e;border-top:1px solid #32324a;padding:0 12px;font-size:11px;color:#567;gap:14px}
    #|.aip{grid-column:1/4;background:#12142a;border-top:1px solid #333;display:flex;flex-direction:column;max-height:280px;transition:max-height .2s}
    #|.aip.closed{max-height:36px;overflow:hidden}
    #|.aihead{display:flex;align-items:center;justify-content:space-between;padding:8px 14px;cursor:pointer;user-select:none}
    #|.aihead span{font-size:12px;font-weight:600;color:#7ab8ff}
    #|.aihead .tg{font-size:14px;color:#567}
    #|.aibody{padding:6px 14px 10px;display:flex;flex-direction:column;gap:5px}
    #|.aicfg{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
    #|.aicfg select,.aicfg input{background:#0d1020;color:#99a;border:1px solid #2a2a4e;border-radius:4px;padding:4px 6px;font-size:11px}
    #|.aicfg select{width:150px}
    #|.aicfg input{flex:1;min-width:80px}
    #|.aireq{display:flex;gap:6px}
    #|.aireq input{flex:1;background:#0d1020;color:#ccc;border:1px solid #3a3a5e;border-radius:6px;padding:8px 12px;font-size:13px}
    #|.aireq button{background:#3d63ff;color:#fff;border:0;border-radius:6px;padding:8px 18px;font-size:13px;cursor:pointer;font-weight:500}
    #|.aireq button:disabled{opacity:.4}
    #|.aireq button:hover:not(:disabled){background:#5a7fff}
    #|#ailog{height:110px;overflow-y:auto;background:#0d1020;border-radius:6px;border:1px solid #1e2340}
  )
}

///|
/// 页面骨架 HTML。
///
/// 抽成 `pub` 是为了让测试能对它做**静态接线检查**：HTML 里引用的每个
/// `globalThis.__x` 必须真的被 `register_globals()` 注册，`getElementById('y')`
/// 里的每个 id 必须真的出现在同一份 HTML 里。这类断链以前只有"在浏览器里点
/// 一下"才能发现——而走不到那条路的人就永远发现不了（仓库里 `undo` 与蒙版
/// UI 都栽过这个形状）。
pub fn app_html() -> String {
  (
      #|<div class='topbar'>
      #|<span class='logo'>🎨 MoonPainter</span>
      #|<span class='badge' id='build-badge' title='这一页是哪一版构建：引擎自报版本 · mpd 容器版本 · git commit · 构建时间 · wasm 内容 sha。人做功能测试时先看这里——徽标对不上就是打开/缓存了旧构建。'>版本…</span>
      #|<button onclick='globalThis.__new()'>新建</button>
      #|<input class='pnum' id='cw' type='number' min='1' max='4096' value='800' title='画布宽（新建 / 改画布用）'/>
      #|<span class='sep'>×</span>
      #|<input class='pnum' id='ch' type='number' min='1' max='4096' value='600' title='画布高'/>
      #|<button onclick='globalThis.__set_canvas()'>改画布</button>
      #|<button onclick="globalThis.__img_swap('');document.getElementById('file-in').click()">📷 导入图片</button>
      #|<span class='sep'></span>
      #|<button onclick='globalThis.__undo()'>↩ 撤销</button>
      #|<button onclick='globalThis.__redo()'>↪ 重做</button>
      #|<span class='sep'></span>
      #|<button onclick="document.getElementById('mpd-in').click()">📂 打开 .mpd</button>
      #|<button onclick='globalThis.__save()'>💾 保存 .mpd</button>
      #|<button onclick='globalThis.__export()'>🖼 导出 PNG</button>
      #|<span class='sep'></span>
      #|<button class='pri' onclick='globalThis.__toggle_ai()'>🤖 AI 修图</button>
      #|</div>
      #|<div class='optbar' id='optbar'>
      #|<div class='ctx' data-for='move'><span>🖐 拖动移动选中图层</span><span class='hint'>先在右侧图层面板点选图层</span></div>
      #|<div class='ctx' data-for='brush'><input type='color' id='bcolor' value='#ff3366'/><span>笔径</span><input type='range' id='bsize' min='1' max='60' value='10'/><span id='bsize-v' class='hint'>10 px</span></div>
      #|<div class='ctx' data-for='erase'><span>🧽</span><span>笔径</span><input type='range' id='esize' min='1' max='60' value='14'/><span class='hint'>橡皮擦：只擦本层笔迹，透出下层</span></div>
      #|<div class='ctx' data-for='pick'><span>💧 点击画布取色，自动设为笔刷颜色</span></div>
      #|<div class='ctx' data-for='text'><span>T</span><input id='tinput' placeholder='输入文字内容…' style='width:200px;background:#0d1020;color:#ccc;border:1px solid #3a3a5e;border-radius:4px;padding:4px 8px;font-size:12px'/><button onclick='globalThis.__text_add()' style='background:#3d63ff;color:#fff;border:0;border-radius:4px;padding:4px 12px;font-size:12px;cursor:pointer'>添加</button><span class='hint'>先点画布选位置</span></div>
      #|<div class='ctx' data-for='crop'><span>✂️ 拖拽出裁剪选区</span>
      #|<div id='crop-btns'><button onclick='globalThis.__crop_apply()'>✓ 应用裁剪</button><button class='ghost' onclick='globalThis.__crop_cancel()'>✕ 取消</button></div></div>
      #|<div class='ctx' data-for='mask'><span>▭ 拖拽出矩形蒙版范围（作用于右侧选中的图层）</span><span class='hint'>圆角</span><input type='range' id='mask-radius' min='0' max='200' value='0'/><span id='mask-radius-v' class='hint'>0</span><span class='hint'>羽化</span><input type='range' id='mask-feather' min='0' max='100' value='0'/><span id='mask-feather-v' class='hint'>0</span><span class='hint'>蒙版外不渲染</span></div>
      #|<div class='ctx' data-for='mask_e'><span>◯ 拖拽出椭圆蒙版范围（作用于右侧选中的图层）</span><span class='hint'>羽化</span><input type='range' id='mask-feather-e' min='0' max='100' value='0'/><span id='mask-feather-e-v' class='hint'>0</span><span class='hint'>蒙版外不渲染</span></div>
      #|</div>
      #|<div class='tools' id='tools'>
      #|<div class='t on' data-tool='move' title='移动' onclick='globalThis.__tool("move")'>🖐</div>
      #|<div class='t' data-tool='brush' title='画笔' onclick='globalThis.__tool("brush")'>🖌</div>
      #|<div class='t' data-tool='erase' title='橡皮擦' onclick='globalThis.__tool("erase")'>🧽</div>
      #|<div class='t' data-tool='pick' title='吸管取色' onclick='globalThis.__tool("pick")'>💧</div>
      #|<div class='ts'></div>
      #|<div class='t' data-tool='text' title='文本' onclick='globalThis.__tool("text")'>T</div>
      #|<div class='t' data-tool='crop' title='裁剪' onclick='globalThis.__tool("crop")'>✂️</div>
      #|<div class='t' data-tool='mask' title='矩形蒙版（拖拽）' onclick='globalThis.__tool("mask")'>▭</div>
      #|<div class='t' data-tool='mask_e' title='椭圆蒙版（拖拽）' onclick='globalThis.__tool("mask_e")'>◯</div>
      #|<div class='ts'></div>
      #|<div class='t' data-tool='rect' title='矩形（拖拽）' onclick='globalThis.__tool("rect")'>▤</div>
      #|<div class='t' data-tool='ellipse' title='椭圆（拖拽）' onclick='globalThis.__tool("ellipse")'>⬭</div>
      #|<div class='t' data-tool='line' title='折线（逐点点击；双击或回车结束）' onclick='globalThis.__tool("line")'>╱</div>
      #|<div class='t' data-tool='poly' title='多边形（逐点点击 ≥3 点；双击/回车闭合，Esc 放弃）' onclick='globalThis.__tool("poly")'>⬠</div>
      #|<div class='ts'></div>
      #|<div class='t' title='放大' onclick='globalThis.__zoom("1.25")'>🔍+</div>
      #|<div class='t' title='缩小' onclick='globalThis.__zoom("0.8")'>🔍−</div>
      #|<div class='t' title='适合窗口' onclick='globalThis.__zoom("0")'>⛶</div>
      #|<div class='ts'></div>
      #|<div class='t' title='导入图片' onclick="document.getElementById('file-in').click()">📷</div>
      #|<div class='t' title='直方图统计' onclick='globalThis.__stats("")'>📊</div>
      #|</div>
      #|<div class='carea'>
      #|<div class='cwrap' id='drop-zone'><img id='canvas-img' alt='画布' draggable='false'/></div>
      #|</div>
      #|<div class='rpanel'>
      #|<div class='rscroll'>
      #|<div class='ph'>调整 · 美颜（叠加调整层，可撤销）</div>
      #|<div class='fstr'><span>强度</span><input type='range' id='fstr' min='5' max='100' value='50'/><span id='fstr-v' class='hint'>0.50</span></div>
      #|<div class='fxgrid'>
      #|<button onclick='globalThis.__af("smooth","+")'>🧴 磨皮</button>
      #|<button onclick='globalThis.__af("whiten","+")'>🤍 美白</button>
      #|<button onclick='globalThis.__af("blur","+")'>🌫 模糊</button>
      #|<button onclick='globalThis.__af("sharpen","+")'>🔪 锐化</button>
      #|<button onclick='globalThis.__af("warm","+")'>🔥 暖色</button>
      #|<button onclick='globalThis.__af("warm","-")'>❄️ 冷色</button>
      #|<button onclick='globalThis.__af("vignette","+")'>⬛ 暗角</button>
      #|<button onclick='globalThis.__af("grayscale","")'>🖨 黑白</button>
      #|<button onclick='globalThis.__af("invert","")'>🔄 反色</button>
      #|<button onclick='globalThis.__af("brightness","+")'>☀️ 亮度+</button>
      #|<button onclick='globalThis.__af("brightness","-")'>🌑 亮度−</button>
      #|<button onclick='globalThis.__af("contrast","+")'>◐ 对比+</button>
      #|<button onclick='globalThis.__af("contrast","-")'>◑ 对比−</button>
      #|<button onclick='globalThis.__af("saturation","+")'>🎨 饱和+</button>
      #|<button onclick='globalThis.__af("saturation","-")'>🫥 饱和−</button>
      #|</div>
      #|<div class='ph2'>图层</div>
      #|<div id='llist'></div>
      #|<div class='ph2'>属性</div>
      #|<div id='pprops'><div class='ns'>点击图层查看属性</div></div>
      #|<div class='ph2'>🩺 自检 · 调试（面向功能测试）</div>
      #|<div class='dbg'>
      #|<button class='scbtn' onclick='globalThis.__selfcheck()'>🧪 功能自检：跑一遍功能清单</button>
      #|<div id='sc-report' class='sc'><div class='ns'>点上面的按钮。清单跑在**另一份**引擎上（不动你当前的文档），每条断言一个可观测事实：画面 sha 变没变 / 指纹等不等 / pick 拾到哪一层；失败项把引擎原话与实测值一起印出来。</div></div>
      #|<div class='dbgrow'>
      #|<button onclick='globalThis.__dbg_lint()'>lint 检查</button>
      #|<button onclick='globalThis.__dbg_edits()'>编辑历史</button>
      #|<button onclick='globalThis.__dbg_census()'>全图普查</button>
      #|<button onclick='globalThis.__dbg_probe()'>探一点(10,10)</button>
      #|<button onclick='globalThis.__dbg_help()'>命令字典</button>
      #|<button onclick='globalThis.__dbg_tools()'>工具清单</button>
      #|<button onclick='globalThis.__dbg_schema()'>选择子清单</button>
      #|<button onclick='globalThis.__dbg_preview()'>选区预览</button>
      #|</div>
      #|<div class='dbgrow'><span class='hint'>MVSL 编辑表（贴 JSON；base64 由页面转，模型侧那份同理）</span></div>
      #|<textarea id='mvsl-json' class='dbgta' placeholder='{"version":1,"ops":[],"guards":[]}'></textarea>
      #|<div class='dbgrow'>
      #|<button onclick='globalThis.__mvsl_set()'>装表</button>
      #|<button onclick='globalThis.__mvsl_show()'>看表</button>
      #|<button onclick='globalThis.__mvsl_impact()'>影响证书</button>
      #|<button onclick='globalThis.__mvsl_assert()'>断言</button>
      #|<button onclick='globalThis.__mvsl_clear()'>清表</button>
      #|</div>
      #|<div class='dbgrow'>
      #|<input id='param-k' class='pk2' placeholder='key'/><input id='param-v' class='pk2' placeholder='value'/>
      #|<button onclick='globalThis.__param_list()'>列元参数</button>
      #|<button onclick='globalThis.__param_set()'>写元参数</button>
      #|<button onclick='globalThis.__param_del()'>删元参数</button>
      #|</div>
      #|<div class='dbgrow'>
      #|<input id='cmd-input' class='cmdin' placeholder='任意一行引擎命令（63 条全都能跑：render 400 overlay=1 / query-layer r1 …）'/>
      #|<button onclick='globalThis.__cmd()'>执行</button>
      #|</div>
      #|<pre id='dbg-out' class='dbgout'>（这里显示回包 JSON。`render`/`select-preview` 这类带 PNG 的回包会在上面画布上直接铺出来。）</pre>
      #|</div>
      #|</div>
      #|</div>
      #|<div class='sbar'><span id='sbar-text'>就绪</span></div>
      #|<div class='aip' id='ai-panel'>
      #|<div class='aihead' onclick='globalThis.__toggle_ai()'>
      #|<span>🤖 AI 修图 — 人类提需求，AI 逐工具操作，全程可见</span>
      #|<span class='tg' id='ai-arrow'>▼</span>
      #|</div>
      #|<div class='aibody'>
      #|<div class='aicfg'>
      #|<select id='ai-provider'></select>
      #|<input id='ai-baseurl' placeholder='Base URL'/>
      #|<input id='ai-model' placeholder='模型 ID'/>
      #|<input id='ai-key' type='password' placeholder='API Key' style='max-width:150px'/>
      #|</div>
      #|<div class='aireq'>
      #|<input id='ai-request' placeholder='描述你的修图需求…' value='给图片加一个暖色调滤镜，再在左上角写上 Happy'/>
      #|<button id='ai-run'>🤖 执行</button>
      #|</div>
      #|<div id='ailog'></div>
      #|</div>
      #|</div>
      #|<input type='file' id='file-in' accept='image/*' style='display:none' onchange='globalThis.__file_sel()'/>
      #|<input type='file' id='mpd-in' accept='.mpd,application/zip' style='display:none' onchange='globalThis.__mpd_sel()'/>
  )
}

///|
fn inject_html() -> Unit {
  js_html("app", app_html())
  for p in provider_presets() {
    js_add_opt("ai-provider", p.id, p.name)
  }
}

async fn on_file_selected() -> Unit {
  bootstrap()
  let result = js_read_file_input("file-in").wait()
  let ok = match json_get(result, "ok") {
    Some(Json::True) => true
    _ => false
  }
  if ok {
    let b64 = match json_get(result, "b64") {
      Some(Json::String(s)) => s
      _ => ""
    }
    let name = match json_get(result, "name") {
      Some(Json::String(s)) => s
      _ => "image"
    }
    if b64 != "" {
      let swap_id = g_swap.val
      g_swap.val = ""
      if swap_id != "" {
        // 原地换图：层序/蒙版/标签/透明度/翻转/旋转都不动（`set-image` 的语义）
        let r = eng(import_line(swap_id, b64, name))
        if eng_ok(r) {
          js_log_line("🖼 已换图（层序与蒙版不变）", "#4a4")
          eng_render(800)
          refresh_ui()
        } else {
          js_log_line("❌ 换图失败：\{eng_s(r, "error")}", "#f66")
        }
      } else {
        do_import(b64, name)
      }
    }
  } else {
    let err = match json_get(result, "error") {
      Some(Json::String(s)) => s
      _ => "?"
    }
    js_log_line("⚠ 文件读取失败: \{err}", "#f66")
  }
}

///|
/// 把所有事件处理器挂到 `globalThis` 上（页面里 `onclick='globalThis.__x()'` 靠它）。
/// `pub` 是为了让测试能注册一遍再去核对页面 HTML 的引用——见 `app_html`。
pub fn register_globals() -> Unit {
  js_reg0("__run", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { ai_turn() }) })
  js_reg0("__save", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { do_save() }) })
  js_reg0("__export", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { do_export() }) })
  js_reg0("__file_sel", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { on_file_selected() }) })
  js_reg0("__mpd_sel", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { on_mpd_selected() }) })
  js_reg0("__crop_apply", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { do_crop_apply() }) })
  // AI 面板折叠。**这个注册原先漏了**：HTML 里「🤖 AI 修图」按钮与面板标题
  // 都写着 `onclick='globalThis.__toggle_ai()'`，而 `js_toggle_ai` 的 FFI 早就
  // 写好了、却没有任何地方调用它——点下去是 `__toggle_ai is not a function`。
  // 是"页面接线"那条测试抓到它的（在此之前只有人工点一下才看得见）。
  js_reg1("__toggle_ai", fn(_ : String) { js_toggle_ai() })
  js_reg1("__sel", fn(id : String) { do_sel(id) })
  js_reg1("__vis", fn(id : String) { do_vis(id) })
  js_reg1("__del", fn(id : String) { do_del(id) })
  js_reg1("__undo", fn(_ : String) { do_undo() })
  js_reg1("__redo", fn(_ : String) { do_redo() })
  js_reg1("__new", fn(_ : String) { do_new() })
  js_reg1("__front", fn(id : String) { do_reorder(id, "front") })
  js_reg1("__back", fn(id : String) { do_reorder(id, "back") })
  js_reg1("__tool", fn(name : String) {
    // 切换工具时把没闭合的点说清楚再放弃：静默丢掉已点的点，人会以为画上去了
    if name != "line" && name != "poly" && g_pts.val.length() > 0 {
      do_poly_cancel()
    }
    js_set_tool(name)
    js_canvas_cursor(name)
    js_status_bar(
      match name {
        "brush" => "🖌 画笔：按住拖动绘制（自动建画笔层）"
        "erase" => "🧽 橡皮擦：只擦除画笔层笔迹"
        "pick" => "💧 吸管：点击取色"
        "text" => "T 文本：点击画布输入"
        "crop" => "✂️ 裁剪：拖拽选区后应用"
        "rect" => "▤ 矩形：拖拽一个框"
        "ellipse" => "⬭ 椭圆：拖拽一个框"
        "line" => poly_hint("line", 0)
        "poly" => poly_hint("poly", 0)
        _ => "🖐 移动：图层面板选中后拖动"
      },
    )
  })
  js_reg1("__zoom", fn(f_s : String) {
    let f = parse_double_safe(f_s)
    if f == 0.0 {
      js_zoom_fit()
    } else {
      js_zoom_canvas(f)
    }
  })
  js_reg2s("__stroke", fn(mode : String, pts : String) { do_stroke(mode, pts) })
  js_reg1("__pick_at", fn(coords : String) { do_pick(coords) })
  js_reg1("__text_at", fn(coords : String) { do_text_pick(coords) })
  js_reg0("__text_add", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() { do_text_add() })
  })
  js_reg2s("__move_delta", fn(dx : String, dy : String) { do_move_delta(dx, dy) })
  js_reg1("__crop_ready", fn(rect : String) { do_crop_ready(rect) })
  js_reg2s("__mask_ready", fn(kind : String, rect : String) { do_mask_ready(kind, rect) })
  js_reg1("__mask_invert", fn(id : String) { do_mask_invert(id) })
  js_reg1("__mask_clear", fn(id : String) { do_mask_clear(id) })
  js_reg1("__group_sel", fn(id : String) { do_group_sel(id) })
  js_reg1("__ungroup_sel", fn(id : String) { do_ungroup_sel(id) })
  js_reg2s("__reparent", fn(id : String, target : String) { do_reparent(id, target) })
  // 人类侧的可改属性（这一批命令此前只有 AI 走得到，见 PLAN 三十）
  js_reg1("__img_swap", fn(id : String) { do_img_swap(id) })
  js_reg2s("__shape_ready", fn(kind : String, box : String) { do_shape_ready(kind, box) })
  js_reg1("__poly_click", fn(xy : String) { do_poly_click(xy) })
  js_reg0("__poly_finish", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() { do_poly_finish() })
  })
  js_reg0("__poly_cancel", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() { do_poly_cancel() })
  })
  js_reg2s("__rename", fn(id : String, v : String) { do_rename(id, v) })
  js_reg2s("__setx", fn(id : String, v : String) { do_set_axis(id, "x", v) })
  js_reg2s("__sety", fn(id : String, v : String) { do_set_axis(id, "y", v) })
  js_reg2s("__setw", fn(id : String, v : String) { do_set_axis(id, "w", v) })
  js_reg2s("__seth", fn(id : String, v : String) { do_set_axis(id, "h", v) })
  js_reg2s("__rotate", fn(id : String, v : String) { do_rotate(id, v) })
  js_reg2s("__flip", fn(id : String, axis : String) { do_flip(id, axis) })
  js_reg2s("__text_set", fn(id : String, v : String) { do_text_set(id, v) })
  js_reg2s("__text_font", fn(id : String, v : String) { do_text_font(id, v) })
  js_reg2s("__adj_op", fn(id : String, v : String) { do_adj(id, "op", v) })
  js_reg2s("__adj_val", fn(id : String, v : String) { do_adj(id, "value", v) })
  js_reg2s("__tag_add", fn(id : String, v : String) { do_tag_add(id, v) })
  js_reg2s("__tag_del", fn(id : String, v : String) { do_tag_del(id, v) })
  js_reg1("__set_canvas", fn(_ : String) { do_set_canvas() })
  js_reg1("__crop_cancel", fn(_ : String) { do_crop_cancel() })
  js_reg2s("__af", fn(op : String, sign : String) {
    let s = js_state_get("strength")
    let v = if sign == "" {
      // 无符号算子（黑白/反色）：传空串，由 do_filter 决定不拼 value=
      ""
    } else if sign == "-" {
      "-\{s}"
    } else {
      s
    }
    do_filter(op, v)
  })
  js_reg2s("__op", fn(id : String, v : String) { do_opacity(id, v) })
  js_reg0("__refresh", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
      g_paint.val = ""
      refresh_ui()
    })
  })
  js_reg2s("__optip", fn(_ : String, v : String) {
    js_text("opv", "\{parse_double_safe(v) / 100.0}")
  })
  js_reg1("__stats", fn(_ : String) {
    let s = eng("stats")
    js_log_line("📊 \{s.stringify()}", "#8af")
  })
  js_reg2s("__drop", fn(b64 : String, name : String) { do_import(b64, name) })
  // ── 自检 / 调试面板 ────────────────────────────────────────────────
  // ⚠️ 每条命令名都写成**字面量**并且和引擎调用写在**同一行**里：`ui_audit.py`
  // 判"人类前端真的发得出去"靠的是"字符串首词是命令名 + 同语句里有引擎入口"。
  // 把命令名插值拼（`"\{cmd}"`）或只写在注入的 HTML 里，对账看不见 = 等于没有入口
  // （README 的名单也会跟着撒谎）。
  js_reg0("__selfcheck", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_selfcheck()
    })
  })
  js_reg0("__dbg_lint", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("lint"))
    })
  })
  js_reg0("__dbg_edits", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("edits"))
    })
  })
  js_reg0("__dbg_census", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("census"))
    })
  })
  js_reg0("__dbg_probe", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("probe x=10 y=10 r=8"))
    })
  })
  js_reg0("__dbg_help", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("help"))
    })
  })
  js_reg0("__dbg_tools", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("list-tools"))
    })
  })
  js_reg0("__dbg_schema", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("sel-schema"))
    })
  })
  js_reg0("__dbg_preview", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
      
    do_dbg_show(engine_exec_line("select-preview " + b64_text(sc_geo_sel())))
    })
  })
  js_reg0("__mvsl_set", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
      
    let json = js_val("mvsl-json")
    if json == "" {
      js_status_bar("⚠ 先在「MVSL 编辑表」文本框里贴 JSON（例：{\"version\":1,\"ops\":[],\"guards\":[]}）")
      return
    }
    let _ = do_ui_cmd("mvsl-set " + b64_text(json))
    do_dbg_raw(engine_exec_line("mvsl-show"))
    })
  })
  js_reg0("__mvsl_show", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("mvsl-show"))
    })
  })
  js_reg0("__mvsl_impact", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_show(engine_exec_line("mvsl-impact"))
    })
  })
  js_reg0("__mvsl_assert", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("mvsl-assert"))
    })
  })
  js_reg0("__mvsl_clear", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
      
    let _ = do_ui_cmd("mvsl-clear")
    do_dbg_raw(engine_exec_line("mvsl-show"))
    })
  })
  js_reg0("__param_list", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_dbg_raw(engine_exec_line("list-params"))
    })
  })
  js_reg0("__param_set", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
      
    let k = js_val("param-k")
    let v = js_val("param-v")
    if k == "" {
      js_status_bar("⚠ 先填元参数的 key")
      return
    }
    let _ = do_ui_cmd("set-param " + k + " " + v)
    do_dbg_raw(engine_exec_line("list-params"))
    })
  })
  js_reg0("__param_del", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
      
    let k = js_val("param-k")
    if k == "" {
      js_status_bar("⚠ 先填要删的元参数 key")
      return
    }
    let _ = do_ui_cmd("remove-param " + k)
    do_dbg_raw(engine_exec_line("list-params"))
    })
  })
  js_reg0("__cmd", fn() -> @js_async.Promise[Unit] {
    @js_async.Promise::from_async(async fn() {
       do_console_cmd()
    })
  })
}

///|
/// 右上角徽标文案（**纯函数**：同样的输入给同样的字符串，测试里直接断言）。
///
/// 人做功能测试时，最怕的是"点了半天其实是缓存里的旧引擎"——所以这里有四个量：
/// 引擎**自报**的版本（来自已加载的 wasm，不是编译进页面的常量）、mpd 容器版本、
/// git commit、构建时间、wasm 内容 sha。构建元数据缺失时**明说**"这页不是
/// build_demo.sh 产出的"——静默显示一个假版本号比不显示更坏。
pub fn build_badge_text(info : String, engine_ver : String) -> String {
  let b = parse_json_safe(info)
  let ev = parse_json_safe(engine_ver)
  let ver = json_get_str(ev, "version")
  let cont = json_get_str(ev, "container")
  let commit = json_get_str(b, "commit")
  let t = json_get_str(b, "time")
  let wasm = json_get_str(b, "wasm_sha")
  if commit == "" && wasm == "" {
    return "版本未知 · 这页不是 ./build_demo.sh 产出的（引擎 v\{ver}）"
  }
  let ts = if t.length() >= 16 { t[5:16].to_owned() } else { t }
  let ws = if wasm.length() > 8 { wasm[0:8].to_owned() } else { wasm }
  "引擎 v\{ver} · \{cont} · 构建 \{commit} \{ts} · wasm \{ws}"
}

///|
/// 徽标填进顶栏（浏览器启动时调一次；也是"这页是哪一版"的唯一可见凭据）。
fn do_build_badge() -> Unit {
  js_text("build-badge", build_badge_text(js_build_info(), engine_version_json()))
}

///|
/// 诊断回包铺到 `#dbg-out`。**截断**：`help`/`census`/`edits` 的回包能到几十 KB，
/// 铺满面板反而看不见重点（要全文的走「命令字典」那条自己看）。
fn do_dbg_raw(raw : String) -> Unit {
  js_text("dbg-out", shorten_str(raw, 6000))
  let j = parse_json_safe(raw)
  if eng_ok(j) {
    js_status_bar("🩺 回包已铺到「自检 · 调试」面板")
  } else {
    js_status_bar("⚠ " + eng_s(j, "error"))
  }
}

///|
/// 带 PNG 的诊断命令（`select-preview`/`render`/`mvsl-impact`）：回包铺出来，
/// PNG 直接画到画布上——"选区到底覆盖了哪里"看图最快，数值在回包里。
fn do_dbg_show(raw : String) -> Unit {
  let j = parse_json_safe(raw)
  let b64 = eng_s(j, "png_b64")
  let b64b = eng_s(j, "overlay_png_b64")
  let b64c = eng_s(j, "result_png_b64")
  let img = if b64 != "" { b64 } else if b64b != "" { b64b } else { b64c }
  if img != "" {
    js_canvas_img(img)
    js_text(
      "dbg-out",
      shorten_str(raw, 400) + "\n…（回包里的 PNG 已铺到画布，base64 共 " + img.length().to_string() + " 字符，这里不铺）",
    )
    js_status_bar("🩺 回包里的 PNG 已铺到画布（下一次渲染/操作会恢复）")
  } else {
    do_dbg_raw(raw)
  }
}

///|
/// 命令控制台：任意一行引擎命令（63 条全都能跑）。走 `do_ui_cmd` 那条路
/// （渲染 + 刷新界面），所以**改文档的命令也会立刻看到画面变化**；只读命令
/// 的回包同样铺到面板上——它是"逐条手测"的兜底入口。
fn do_console_cmd() -> Unit {
  let line = js_val("cmd-input")
  if line == "" {
    js_status_bar("⚠ 先在输入框里写一条引擎命令")
    return
  }
  // ⚠️ **只执行一次**：先 `eng(line)` 再 `engine_exec_line(line)` 会把命令跑两遍
  // （`add-rect` 会加两层，而面板只显示"成功"）。拿原始回包自己解析。
  let raw = engine_exec_line(line)
  let j = parse_json_safe(raw)
  js_text("dbg-out", shorten_str(raw, 6000))
  if eng_ok(j) {
    eng_render(800)
    refresh_ui()
    js_status_bar("🩺 \{line} → ok（回包见调试面板）")
  } else {
    js_status_bar("⚠ " + eng_s(j, "error"))
  }
}

///|
/// 功能自检：**另起一份引擎实例**（`js_clone_engine`）跑清单——自检会 `new`、
/// 会装编辑表，绝不能在用户手上这份文档上做（自检的副作用比不做自检更坏）。
fn do_selfcheck() -> Unit {
  let rows = selfcheck_run_isolated()
  // 报告头上带**这一版是哪一版**：这份报告是要拿去对质的（"我在 abc1234 上
  // 看到第 7 条红"），缺了它，报告本身就没法指回一次可重复的构建。
  let head = "<div class='schdr'>" +
    html_attr(build_badge_text(js_build_info(), engine_version_json())) +
    "</div>"
  js_html("sc-report", head + selfcheck_html(rows))
  let bad = rows.filter(fn(r) { !r.1 }).length()
  if bad == 0 {
    js_status_bar("🧪 功能自检：\{rows.length()} 条全过 ✓（跑在另一份引擎上，你的文档没被动过）")
  } else {
    js_status_bar("⚠ 功能自检：\{bad}/\{rows.length()} 条失败 —— 右侧报告里每条都印了实测值与引擎原话")
  }
}

fn main {
  if js_is_node() {
    // Node headless：同步 wasm 加载 + 引擎验证
    ensure_engine()
    let r0 = engine_exec_line("session-open full_image")
    let r1 = engine_exec_line("new 400 300 uuid=headless")
    let r2 = engine_exec_line("add-paint")
    let r3 = engine_exec_line("brush layer=l1 pts=20,20;180,150 r=8 color=#FF0000FF")
    let r4 = engine_exec_line("add-adjust op=smooth value=0.5")
    let r5 = engine_exec_line("crop 10 10 200 150")
    let r6 = engine_exec_line("render 200")
    let ok = r0.contains("ok") &&
      r1.contains("ok") &&
      r2.contains("ok") &&
      r3.contains("ok") &&
      r4.contains("ok") &&
      r5.contains("ok") &&
      r6.contains("png_b64")
    let ok_val : Json = Json::boolean(ok)
    // 版本从**已加载的 wasm 引擎**读（`mp_version`），不读 demo 自己编译进去的
    // 常量：wasm 产物过期时两者会不一致，而自检报的应该是引擎的版本、不是
    // 页面的版本。这同时消掉了 demo 对引擎包唯一的 import（铁律 5：demo 只经
    // wasm ABI 驱动引擎，`dep_audit.py` 第 12 步守着这条）。
    let ver_raw = engine_version_json()
    let ver_val : Json = try {
      @json.parse(ver_raw)
    } catch {
      _ => Json::string(ver_raw)
    }
    let result : Json = Json::object({
      "headless_selftest": Json::boolean(true),
      "engine_ok": ok_val,
      "version": ver_val,
    })
    // 人类面的**处理器表**在 headless 里也挂上：`demo/clickthrough.mjs` 直接调
    // `globalThis.__poly_finish()` 这些页面处理器，验的是"处理器 → do_* → 引擎"
    // 整条链。此前这条链只有源码级证据（名字对得上、HTML 里有这个按钮），
    // "点了到底动不动引擎、动得对不对"只有人在浏览器里点得出来。
    // 顺带把引擎入口暴露出去，好让驱动器把状态**读回来**断言。
    register_globals()
    js_expose_exec(fn(line : String) { engine_exec_line(line) })
    js_expose_boot(fn() { bootstrap() })
    println(result.stringify())
  } else {
    // 浏览器：同步初始化（无 async 运行时依赖）
    ensure_engine()
    inject_css()
    inject_html()
    register_globals()
    setup_tool_state()
    // 顶栏徽标：**这一页是哪一版**（人做功能测试的第一件事）
    do_build_badge()
    js_click_global("ai-run", "__run")
    js_setup_drop("drop-zone", "__drop")
    bootstrap()
    js_setup_canvas("canvas-img")
    js_bind_size_labels()
    js_status_bar("就绪 — 🖌 直接在画布上画 / 右侧一键修图 / 🤖 AI 面板")
    js_log_line("🎨 MoonPainter 就绪。画笔/橡皮/裁剪/吸管在左侧工具栏；右侧「调整·美颜」一键叠加滤镜；或拖拽图片导入。", "#6af")
  }
}
