/// demo —— 专业修图软件 UI（demo/main）。
///
/// 人机操作面（非一键 AI）：左列真实工具（移动/画笔/橡皮/吸管/裁剪/文本/缩放），
/// 上下文选项条（笔色/笔径/滤镜强度/裁剪确认），右侧「调整·滤镜」面板
/// （磨皮/美白/色彩/滤镜，全部以调整层叠加，可撤销可保存）。

let g_sel : Ref[String] = Ref("")
let g_ready : Ref[Bool] = Ref(false)
/// 当前画笔层 id（首个 brush 使用时惰性创建/绑定）
let g_paint : Ref[String] = Ref("")
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
  let r = eng("sample \{parts[0]} \{parts[1]}")
  let color = eng_s(r, "color")
  if color != "" {
    js_set_brush_color(color)
    let layer = eng_s(r, "layer")
    let at = if layer != "" { "（层 \{layer}）" } else { "" }
    js_status_bar("💧 取色 \{color}\{at} — 已设为笔刷颜色")
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
  let lx = json_num(l, "x")
  let ly = json_num(l, "y")
  let _ = eng("move \{g_sel.val} \{d2s(lx + dx)} \{d2s(ly + dy)}")
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
  let _ = engine_exec_line("set-mask \{id} \{cur}")
  eng_render(800)
  refresh_ui()
}

///|
fn do_mask_clear(id : String) -> Unit {
  let _ = engine_exec_line("remove-mask \{id}")
  eng_render(800)
  refresh_ui()
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
  let _ = engine_exec_line("set-style \{id} opacity=\{d2s(v / 100.0)}")
  eng_render(800)
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
    let sel = if lid == g_sel.val { " sel" } else { "" }
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
    sb.write_string(sel)
    sb.write_string("' onclick='globalThis.__sel(\"")
    sb.write_string(lid)
    sb.write_string("\")'><span class='eye' onclick='event.stopPropagation();globalThis.__vis(\"")
    sb.write_string(lid)
    sb.write_string("\")'>")
    sb.write_string(eye)
    sb.write_string("</span><span class='ico'>")
    sb.write_string(ico)
    sb.write_string("</span><span class='lnm'>")
    sb.write_string(lnm)
    sb.write_string("</span><span class='lkd'>")
    sb.write_string(lkd)
    sb.write_string("</span>")
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
  js_refresh_layers(sb.to_string())
  let fp_j = eng("fingerprint")
  let fp = json_get_str(fp_j, "fingerprint")
  let doc_j = eng("inspect")
  let _ = doc_j
  js_status_bar("图层: \{count} │ 指纹: \{fp}")
  refresh_props()
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
  let gid = json_get_str(l, "id")
  let gname = json_get_str(l, "name")
  let gkind = json_get_str(l, "kind")
  let gx = json_num_str(l, "x")
  let gy = json_num_str(l, "y")
  let gw = json_num_str(l, "w")
  let gh = json_num_str(l, "h")
  let gop = json_num_str(l, "opacity")
  let gbl = json_get_str(l, "blend")
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
  sb.write_string(gname)
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
  // 不透明度滑杆（change 提交）
  sb.write_string("<div class='osl'><span class='pk'>α</span><input type='range' min='0' max='100' value='\{opacity_pct(gop)}' oninput='globalThis.__optip(\"")
  sb.write_string(id)
  sb.write_string("\",this.value)' onchange='globalThis.__op(\"")
  sb.write_string(id)
  sb.write_string("\",this.value)'/><span class='pv' id='opv'>")
  sb.write_string(gop)
  sb.write_string("</span></div>")
  sb.write_string("<div class='pact'><button onclick='globalThis.__del(\"")
  sb.write_string(id)
  sb.write_string("\")'>删除</button><button onclick='globalThis.__front(\"")
  sb.write_string(id)
  sb.write_string("\")'>置顶</button><button onclick='globalThis.__back(\"")
  sb.write_string(id)
  sb.write_string("\")'>置底</button><button onclick='globalThis.__mask_invert(\"")
  sb.write_string(id)
  sb.write_string("\")'>蒙版反选</button><button class='ghost' onclick='globalThis.__mask_clear(\"")
  sb.write_string(id)
  sb.write_string("\")'>去蒙版</button></div>")
  js_update_props(sb.to_string())
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
  let _ = engine_exec_line("visible \{id} \{cur}")
  eng_render(800)
  refresh_ui()
}

fn do_del(id : String) -> Unit {
  let _ = engine_exec_line("delete \{id}")
  if g_paint.val == id {
    g_paint.val = ""
  }
  g_sel.val = ""
  eng_render(800)
  refresh_ui()
}

fn do_reorder(id : String, where_ : String) -> Unit {
  let _ = engine_exec_line("reorder \{id} \{where_}")
  eng_render(800)
  refresh_ui()
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
  let _ = engine_exec_line("new 800 600 uuid=n\{js_now_ms()}")
  let _ = engine_exec_line("add-rect x=0 y=0 w=800 h=600 fill=#FFFFFFFF name=背景")
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
    #|#canvas-img.tool-brush,#canvas-img.tool-erase,#canvas-img.tool-pick,#canvas-img.tool-crop,#canvas-img.tool-text{cursor:crosshair}
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
      #|<button onclick='globalThis.__new()'>新建</button>
      #|<button onclick="document.getElementById('file-in').click()">📷 导入图片</button>
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
      do_import(b64, name)
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
    js_set_tool(name)
    js_canvas_cursor(name)
    js_status_bar(
      match name {
        "brush" => "🖌 画笔：按住拖动绘制（自动建画笔层）"
        "erase" => "🧽 橡皮擦：只擦除画笔层笔迹"
        "pick" => "💧 吸管：点击取色"
        "text" => "T 文本：点击画布输入"
        "crop" => "✂️ 裁剪：拖拽选区后应用"
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
    println(result.stringify())
  } else {
    // 浏览器：同步初始化（无 async 运行时依赖）
    ensure_engine()
    inject_css()
    inject_html()
    register_globals()
    setup_tool_state()
    js_click_global("ai-run", "__run")
    js_setup_drop("drop-zone", "__drop")
    bootstrap()
    js_setup_canvas("canvas-img")
    js_bind_size_labels()
    js_status_bar("就绪 — 🖌 直接在画布上画 / 右侧一键修图 / 🤖 AI 面板")
    js_log_line("🎨 MoonPainter 就绪。画笔/橡皮/裁剪/吸管在左侧工具栏；右侧「调整·美颜」一键叠加滤镜；或拖拽图片导入。", "#6af")
  }
}
