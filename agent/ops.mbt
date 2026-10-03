/// agent —— 解析与层编辑原语（agent/ops）。
/// AgentGate 纪律：参数非法立即精确报错，绝不落半截状态。

///|
pub fn to_d(s : String) -> Double? {
  let v = Some(@string.parse_double(s)) catch { _ => None }
  match v {
    Some(d) => if d != d || (d * 2.0 == d && d != 0.0) { None } else { Some(d) }
    None => None
  }
}

///|
pub fn to_i(s : String) -> Int? {
  Some(@string.parse_int(s)) catch {
    _ => None
  }
}

///|
/// 颜色校验：#RRGGBB 或 #RRGGBBAA。非法色在入口拒绝（AgentGate 零容忍）。
pub fn valid_color(s : String) -> Bool {
  if !s.has_prefix("#") {
    return false
  }
  let body = s[1:].to_owned()
  if body.length() != 6 && body.length() != 8 {
    return false
  }
  for i in 0..<body.length() {
    match body.get_char(i) {
      Some(c) => {
        let n = c.to_int()
        let ok = (n >= 48 && n <= 57) ||
          (n >= 97 && n <= 102) ||
          (n >= 65 && n <= 70)
        if !ok {
          return false
        }
      }
      None => return false
    }
  }
  true
}

///|
pub fn parse_color(s : String) -> Result[Int, String] {
  if valid_color(s) {
    Ok(@codec.color_from_hex(s))
  } else {
    Err("非法颜色 \{s}（应为 #RRGGBB 或 #RRGGBBAA）")
  }
}

///|
pub fn parse_blend(s : String) -> Result[@core.BlendMode, String] {
  match s {
    "normal" => Ok(@core.BlendMode::Normal)
    "multiply" => Ok(@core.BlendMode::Multiply)
    "screen" => Ok(@core.BlendMode::Screen)
    "overlay" => Ok(@core.BlendMode::Overlay)
    "darken" => Ok(@core.BlendMode::Darken)
    "lighten" => Ok(@core.BlendMode::Lighten)
    "difference" => Ok(@core.BlendMode::Difference)
    _ => Err("未知混合模式 \{s}（normal/multiply/screen/overlay/darken/lighten/difference）")
  }
}

///|
/// 找首个 '=' 的下标（k=v 参数切分用）。
fn find_eq(s : String) -> Int? {
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => if c == '=' {
        return Some(i)
      }
      None => return None
    }
    i = i + 1
  }
  None
}

///|
/// 逐个检查 `key=value` 形式的参数：**未知的键、缺 `=` 的裸词、空键、空值
/// 一律拒绝**。
///
/// `kv_args` 是**静默**的：认不出 `=` 的 token 直接丢、空值的也丢。于是
/// `set-style l1 fil=#FF0000`（拼错）、`set-style l1 fill`（漏了 `=`）、
/// `set-style l1 fill=`（空值）**全都返回 ok 而一个像素没改**——调用方以为
/// 改成功了。`set-mask` 当年栽的正是这一类（"照字典传 x= y= w= h= 会什么都
/// 不改却返回 ok"），这里把它变成通用检查。
pub fn check_kv_args(
  tokens : Array[String],
  from : Int,
  allowed : Array[String],
  ctx : String,
) -> Result[Unit, String] {
  let mut i = from
  while i < tokens.length() {
    let t = tokens[i]
    match find_eq(t) {
      Some(eq) => {
        if eq == 0 {
          return Err("\{ctx}：`\{t}` 缺键名（应为 key=value）")
        }
        if eq >= t.length() - 1 {
          let k0 = t[0:eq].to_owned()
          return Err("\{ctx}：`\{k0}=` 的值是空的（空值参数一律拒绝，请给一个具体的值）")
        }
        let k = t[0:eq].to_owned()
        if !allowed.contains(k) {
          let k2 = k
          let hint = match k {
            "points" => "（顶点只在 polygon/line 层上有意义：建层用 add-polygon/add-line，改已建层的顶点用 set-style <id> points=x,y;x,y;…）"
            "x" => "（改位置用 move）"
            "y" => "（改位置用 move）"
            "w" => "（改尺寸用 resize）"
            "h" => "（改尺寸用 resize）"
            "text" => "（改文字用 set-text）"
            "font_size" => "（字号在 add-text 建层时给）"
            _ => ""
          }
          // 手写的那几条更具体（说的是"换哪条命令"）；表里的短注补上
          // "这个 kind 为什么不读它"——两条不重复，也不互相打架。
          let table_hint = match ctx_shape_kind(ctx) {
            Some(k) => kind_only_dead_note(k, key_field(k2))
            None => ""
          }
          if allowed.length() == 0 {
            return Err("\{ctx}：不接受 `\{k}=` 这类参数（该命令只认位置参数）")
          }
          let extra = if hint == "" { table_hint } else { "" }
          return Err(
            "\{ctx}：不认识的参数 `\{k}`\{hint}\{extra}；认得的是 \{allowed.join("/")}",
          )
        }
      }
      None => {
        if allowed.length() == 0 {
          return Err("\{ctx}：多给了 `\{t}`（该命令只认前面的位置参数）")
        }
        return Err("\{ctx}：`\{t}` 不是 key=value 形式（是不是漏了 `=`？）")
      }
    }
    i = i + 1
  }
  Ok(())
}

///|
/// 同 `check_kv_args`，但**放行位置参数**（裸词）。
///
/// `render [width] [vx0 vy0 vx1 vy1] [overlay=1]` 与
/// `select-preview <base64> [max=…]` 这类命令合法地收裸词，严格的
/// `check_kv_args` 会把它们全拒掉（实测给 `session-open` 无脑推平时
/// 误伤过位置参数 `full_image`）。这里只审**带 `=` 的 token**：
/// 键名不认识 / 值是空 —— 拒绝；不带 `=` 的整词交给命令自己解析。
pub fn check_kv_names(
  tokens : Array[String],
  from : Int,
  allowed : Array[String],
  ctx : String,
) -> Result[Unit, String] {
  let mut i = from
  while i < tokens.length() {
    let t = tokens[i]
    match find_eq(t) {
      Some(eq) => {
        if eq == 0 {
          return Err("\{ctx}：`\{t}` 缺键名（应为 key=value）")
        }
        if eq >= t.length() - 1 {
          let k0 = t[0:eq].to_owned()
          return Err("\{ctx}：`\{k0}=` 的值是空的")
        }
        let k = t[0:eq].to_owned()
        if !allowed.contains(k) {
          // 空键表要说人话：`认得的是 ` 后面空着等于没说。
          if allowed.length() == 0 {
            return Err("\{ctx}：不接受 `\{k}=` 这类参数（它只认位置参数）")
          }
          let hint = match k {
            "width" | "w" => "（宽度是位置参数：写在命令名后面，不是 width=）"
            "max" => "（预览最长边用 max=<像素>）"
            _ => ""
          }
          return Err("\{ctx}：不认识的参数 `\{k}`\{hint}；认得的是 \{allowed.join("/")}")
        }
      }
      None => ()
    }
    i = i + 1
  }
  Ok(())
}

///|
/// k=v 参数表（同键后值覆盖前值）。
pub fn kv_args(tokens : Array[String], from : Int) -> Map[String, String] {
  let m : Map[String, String] = Map([])
  let mut i = from
  while i < tokens.length() {
    let t = tokens[i]
    match find_eq(t) {
      Some(eq) => {
        if eq > 0 && eq < t.length() - 1 {
          let k = t[0:eq].to_owned()
          let v = t[eq + 1:].to_owned()
          m.set(k, v)
        }
      }
      None => ()
    }
    i = i + 1
  }
  m
}

///|
fn arg_d(
  m : Map[String, String],
  key : String,
  dflt : Double,
) -> Result[Double, String] {
  match m.get(key) {
    None => Ok(dflt)
    Some(v) => match to_d(v) {
      Some(x) => Ok(x)
      None => Err("参数 \{key}=\{v} 不是数字")
    }
  }
}

///|
/// **位图层的盒子跟着「内容」走**——这是"盒子"这件事的第二处（第一处是
/// `agent.session` 的 `text_box`，文本层）。
///
/// 渲染器把资产**拉伸到盒子**（`paint_layer`：`sx = lx / w * img.width`），
/// 所以"给一张 400×300 的图却留着缺省 100×100 的盒"不是无害的默认值：画面被
/// 静默压成正方形，而回包里 `asset_size` 还老老实实写 400x300 ——同一个信封里
/// 两个字段描述的不是同一件事（本仓库那类最难的 bug：**看起来成功了**）。
///
/// 规则（与文本层的占位盒同一条）：**都没给** → 盒 = 资产像素尺寸；
/// **只给一边** → 另一边按原比例推（不许把长宽比悄悄改掉）；**两边都给** →
/// 听调用方的（他要的就是那个框）。范围检查**不在这里**：显式给的值由
/// `build_shape_layer` 那唯一一句话判（`w/h 必须为正`），推出来的值在正数
/// 输入下必然为正——同一句话不抄两遍。
pub fn image_box(
  m : Map[String, String],
  iw : Int,
  ih : Int,
) -> Result[(Double, Double), String] {
  let w_given = m.get("w") is Some(_)
  let h_given = m.get("h") is Some(_)
  if !w_given && !h_given {
    return Ok((iw.to_double(), ih.to_double()))
  }
  let w = match arg_d(m, "w", 0.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let h = match arg_d(m, "h", 0.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if w_given && h_given {
    return Ok((w, h))
  }
  let ratio = iw.to_double() / ih.to_double()
  if w_given {
    return Ok((w, w / ratio))
  }
  Ok((h * ratio, h))
}

///|
/// 把**一棵子树整体平移**（连同后代一起搬）。
///
/// `move <组> x y` 的语义是"把这个容器的**内容**搬过去"——组的 `x/y` 渲染器
/// 不读（组没有自己的画面），只改盒子就是**回 ok 而画面一个像素不动**（实测：
/// 组的盒子 0,0 → 15,10、子层盒子不动、`render_sha256` 逐位相同、`lint` 报 0
/// 违规）。所以对组必须连后代一起搬，见 PLAN 五十五。
///
/// 递归到每个后代、每个后代各平移**一次**（嵌套组的子层也是后代，不会被搬两遍）。
pub fn shift_layer_tree(l : @core.Layer, dx : Double, dy : Double) -> @core.Layer {
  let kids : Array[@core.Layer] = []
  for c in l.children {
    // ⚠️ 只搬**一次**：`shift_layer_tree` 递归到每个后代、每个后代各平移一遍。
    // 这里再补一次 delta 就是"嵌套后代搬两遍"（实测那条变异 Q65 存活过一次：
    // 循环里再加一次看似"更保险"，其实是把祖先的位移叠加到后代头上）。
    kids.push(shift_layer_tree(c, dx, dy))
  }
  { ..l, x: l.x + dx, y: l.y + dy, children: kids }
}

///|
/// 一棵子树的层数（含自己）——`move` 用它回报"这次真正搬了多少层"。
pub fn count_layer_tree(l : @core.Layer) -> Int {
  let mut n = 1
  for c in l.children {
    n = n + count_layer_tree(c)
  }
  n
}

///|
/// 递归替换层（就地替换数组槽位；children 数组是引用，可变）。
pub fn update_layer(
  layers : Array[@core.Layer],
  id : String,
  f : (@core.Layer) -> @core.Layer,
) -> Bool {
  let mut i = 0
  while i < layers.length() {
    let l = layers[i]
    if l.id == id {
      layers[i] = f(l)
      return true
    }
    if update_layer(l.children, id, f) {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// 递归删除层。
pub fn remove_layer(layers : Array[@core.Layer], id : String) -> Bool {
  let mut i = 0
  while i < layers.length() {
    if layers[i].id == id {
      let _ = layers.remove(i)
      return true
    }
    if remove_layer(layers[i].children, id) {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// 顶点数下界：渲染器**只对 ≥3 个顶点的 polygon 围面**（`in_polygon` 第一句
/// 就是 `if pts.length() < 3 { return false }`），**≥2 个顶点才画得出线段**。
/// 少于下界 = 装了却什么都不干：指纹变了、`query-layer` 报着那串顶点、
/// 画面逐位没变（实测 `add-polygon w=40 h=40 points=0,0;40,40` 回 ok、
/// `lint` 报 0 违规、渲染一像素不落）。
/// **一处实现，命令面与 lint 共用**——两处各写一遍就会分叉。
pub fn points_min_count(kind : @core.ShapeKind) -> Int {
  if kind is @core.ShapeKind::Polygon {
    3
  } else if kind is @core.ShapeKind::Line {
    2
  } else {
    0 // 不适用：矩形/椭圆/文本/位图都不用顶点定义形状
  }
}

///|
/// 顶点数不足的说明（"" = 够，或这个 kind 本来就不用顶点）。
/// **命令面（建层 + `set-style points=`）与 lint 共用这一句**——三处各写一遍
/// 必然分叉（一处说 2、一处说 3，或者两处对"几分算够"各有一套）。
pub fn points_count_error(kind : @core.ShapeKind, n : Int) -> String {
  let need = points_min_count(kind)
  if need == 0 || n >= need {
    return ""
  }
  "\{kind_str(kind)} 至少要 \{need} 个顶点才画得出东西（\{n} 个 = 什么都不画）；只画两点之间的线段请用 add-line"
}

///|
/// 按层类型解析并校验顶点串（命令面用）。
pub fn parse_points_for(
  kind : @core.ShapeKind,
  s : String,
) -> Result[Array[(Double, Double)], String] {
  let pts = match parse_points(s) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let e = points_count_error(kind, pts.length())
  if e != "" {
    return Err(e)
  }
  Ok(pts)
}

///|
/// points 解析："x,y;x,y;…"（局部坐标）。
pub fn parse_points(s : String) -> Result[Array[(Double, Double)], String] {
  let out : Array[(Double, Double)] = []
  for seg in s.split(";") {
    let xy : Array[String] = []
    for p in seg.split(",") {
      xy.push(p.to_owned())
    }
    if xy.length() != 2 {
      return Err("points 顶点 \{seg} 应为 x,y 形态")
    }
    let x = match to_d(xy[0]) {
      Some(v) => v
      None => return Err("points 顶点 \{xy[0]} 不是数字")
    }
    let y = match to_d(xy[1]) {
      Some(v) => v
      None => return Err("points 顶点 \{xy[1]} 不是数字")
    }
    out.push((x, y))
  }
  if out.length() < 2 {
    return Err("points 至少 2 个顶点")
  }
  Ok(out)
}

///|
/// 应用 kv 到层样式（fill/stroke/opacity/blend/radius/rot/visible/name/tag）。
pub fn apply_style_kv(
  l : @core.Layer,
  m : Map[String, String],
) -> Result[@core.Layer, String] {
  let mut nl = l
  match m.get("fill") {
    Some(v) => {
      let cand = if v == "none" {
        { ..nl, fill: @core.Fill::NoFill }
      } else {
        match parse_color(v) {
          Ok(c) => { ..nl, fill: @core.Fill::Solid(c) }
          Err(e) => return Err(e)
        }
      }
      match kind_only_write_error(cand, "fill") {
        Some(e) => return Err(e)
        None => ()
      }
      nl = cand
    }
    None => ()
  }
  match m.get("lgrad") {
    // lgrad=c0,c1,x0,y0,x1,y1
    Some(v) => {
      let parts : Array[String] = []
      for p in v.split(",") {
        parts.push(p.to_owned())
      }
      if parts.length() != 6 {
        return Err("lgrad 应为 c0,c1,x0,y0,x1,y1")
      }
      let c0 = match parse_color(parts[0]) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let c1 = match parse_color(parts[1]) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let nums : Array[Double] = []
      for i in 0..<4 {
        match to_d(parts[i + 2]) {
          Some(x) => nums.push(x)
          None => return Err("lgrad 端点 \{parts[i + 2]} 不是数字")
        }
      }
      // 端点是归一化坐标而非像素——写错会静默变成一个「几乎看不出过渡」的
      // 渐变（见 core.grad_endpoint_error 的注释）。入口就拦，并给出换算建议。
      let gerr = @core.grad_endpoint_error(
        nums[0], nums[1], nums[2], nums[3], nl.w, nl.h,
      )
      if gerr != "" {
        return Err(gerr)
      }
      let cand = {
        ..nl,
        fill: @core.Fill::LinearGradient(c0, c1, nums[0], nums[1], nums[2], nums[3]),
      }
      // 渐变也是 `fill` 这一格（同一张表、同一句判据）：折线上写 lgrad 同样不生效
      match kind_only_write_error(cand, "fill") {
        Some(e) => return Err(e)
        None => ()
      }
      nl = cand
    }
    None => ()
  }
  // 笔宽只许 ≥ 0。负值此前被收下：它写进 canonical JSON、改变指纹、
  // `query-layer` 报得出来，而渲染器 `inside_stroke` 里第一句就是
  // `if l.stroke.width > 0.0 { … } else { 0.0 }` —— **描边一个像素都不画**，
  // 调用方拿到的却是 ok（"我明明设了描边"）。
  let stroke_w_check = fn(w : Double) -> Result[Unit, String] {
    if w < 0.0 {
      return Err("stroke_w 不能为负（0 = 不画描边）：\{@core.fmt_num(w)}")
    }
    Ok(())
  }
  match m.get("stroke") {
    Some(v) => {
      let c = match parse_color(v) {
        Ok(x) => x
        Err(e) => return Err(e)
      }
      let w = match arg_d(m, "stroke_w", nl.stroke.width) {
        Ok(x) => x
        Err(e) => return Err(e)
      }
      match (stroke_w_check)(w) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      // 描边只实现了矩形/椭圆/线段（`inside_stroke` 的 `_ =>` 分支就是这句
      // 话）。别的 kind 上写它是死数据 ⇒ 与 fill/rot/blend 同一句判据。
      let cand = { ..nl, stroke: { color: c, width: w } }
      match kind_only_write_error(cand, "stroke") {
        Some(e) => return Err(e)
        None => ()
      }
      nl = cand
    }
    None => match m.get("stroke_w") {
        Some(_) => {
          match arg_d(m, "stroke_w", nl.stroke.width) {
            Ok(w) => {
              match (stroke_w_check)(w) {
                Ok(_) => ()
                Err(e) => return Err(e)
              }
              let cand = { ..nl, stroke: { color: nl.stroke.color, width: w } }
              match kind_only_write_error(cand, "stroke") {
                Some(e) => return Err(e)
                None => ()
              }
              nl = cand
            }
            Err(e) => return Err(e)
          }
        }
        None => ()
      }
  }
  match m.get("opacity") {
    Some(v) => match to_d(v) {
      Some(o) => {
        if o < 0.0 || o > 1.0 {
          return Err("opacity \{v} 越界（0..1）")
        }
        nl = { ..nl, opacity: o }
      }
      None => return Err("opacity \{v} 不是数字")
    }
    None => ()
  }
  match m.get("blend") {
    Some(v) => {
      match parse_blend(v) {
        // 组上的 blend 渲染器根本不读（直通层、自身无面）：实测写进去画面逐位
        // 不变。`normal` 是默认值 ⇒ 与 rotate/flip 同一口径，放行它当"清字段"。
        Ok(b) => {
          let cand = { ..nl, blend: b }
          match kind_only_write_error(cand, "blend") {
            Some(e) => return Err(e)
            None => ()
          }
          nl = cand
        }
        Err(e) => return Err(e)
      }
    }
    None => ()
  }
  match m.get("tag") {
    Some(v) => {
      // 兑现注释里的承诺（此前 `tag=` 被静默忽略——不报错、tags 为空）
      if v == "" {
        return Err("tag 不能为空")
      }
      nl = @core.layer_with_tag(nl, v)
    }
    None => ()
  }
  match m.get("points") {
    Some(v) => {
      // 顶点原先只能在建层时给：想改一个三角形的顶点只能删了重加，而重加把层
      // 推到栈顶（蒙版/标签/透明度/层序全丢）。这里补上"改得动"这条路，
      // 与 set-text / set-adjust 同一条纪律。
      // 种类检查与建层同一句话（表里那一行）：非 polygon/line 上写 points 是
      // **死数据**（写进 canonical JSON、改变指纹、画面逐位不变）。
      // ⚠️ 必须排在形态检查**之前**：`set-style bg points=0,0;1` 要先听到
      // "这层不读顶点"，而不是"顶点太少"（那句话会把人引到错的方向）。
      match kind_only_kind_error(nl.kind, nl.id, "points") {
        Some(e) => return Err(e)
        None => ()
      }
      match parse_points_for(nl.kind, v) {
        Ok(pts) => nl = { ..nl, points: pts }
        Err(e) => return Err(e)
      }
    }
    None => ()
  }
  match m.get("radius") {
    Some(v) => match to_d(v) {
      Some(r) => {
        if r < 0.0 {
          return Err("radius 不能为负")
        }
        // 非矩形层的圆角是**死数据**：`corner_radius` 只在渲染器的 Rect
        // 分支被读，而 `add-*`/`set-style` 都会把它写进 canonical JSON ——
        // 于是指纹变了、query-layer 又不报（它按 kind 投影）、画面逐位没变。
        // 判据与**表里那一行**共用（`kind_only_write_error`，传候选层）；
        // `radius=0` 是清字段，自动放行。lint 兜住手改容器。
        let cand = { ..nl, corner_radius: r }
        match kind_only_write_error(cand, "corner_radius") {
          Some(e) => return Err(e)
          None => ()
        }
        nl = cand
      }
      None => return Err("radius \{v} 不是数字")
    }
    None => ()
  }
  match m.get("rot") {
    Some(v) => match to_d(v) {
      Some(r) => {
        let cand = { ..nl, rotation_deg: r }
        match kind_only_write_error(cand, "rotation_deg") {
          Some(e) => return Err(e)
          None => ()
        }
        nl = cand
      }
      None => return Err("rot \{v} 不是数字")
    }
    None => ()
  }
  match m.get("visible") {
    Some(v) => {
      if v == "true" || v == "1" {
        nl = { ..nl, visible: true }
      } else if v == "false" || v == "0" {
        nl = { ..nl, visible: false }
      } else {
        return Err("visible \{v} 应为 true/false")
      }
    }
    None => ()
  }
  match m.get("name") {
    Some(v) => nl = { ..nl, name: v }
    None => ()
  }
  Ok(nl)
}

///|
/// 从 kv 构造新形状层（add-* 命令公共底座）。
pub fn build_shape_layer(
  id : String,
  kind : @core.ShapeKind,
  m : Map[String, String],
) -> Result[@core.Layer, String] {
  let x = match arg_d(m, "x", 0.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let y = match arg_d(m, "y", 0.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let w = match arg_d(m, "w", 100.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let h = match arg_d(m, "h", 100.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if w <= 0.0 || h <= 0.0 {
    return Err("w/h 必须为正")
  }
  let name = match m.get("name") {
    Some(n) => n
    None => id
  }
  let mut l = @core.default_layer(id, name, x, y, w, h)
  l = { ..l, kind }
  // 默认填充：灰色；显式 fill= 可覆盖
  // 只有 **line 的默认对角线**在这里给（那是"建层"的语义）。显式 `points=`/
  // `stroke_w=` 一律交给末尾的 `apply_style_kv` —— 它俩此前在这里**各有一份
  // 拷贝**（同一个判断两处实现）：`points` 的 kind 门与顶点数下界、`stroke_w`
  // 的范围检查都在两边各写一遍。两份拷贝的后果实测到了：往这里注入
  // "kind 门不生效"的变异**不会红**——另一份拷贝还在守（变异门判 SURVIVED）。
  // 判据存活的原因不是"没人守"，是"守的人有两个"。
  if !(m.get("points") is Some(_)) && kind is @core.ShapeKind::Line {
    // 默认对角线
    l = { ..l, points: [(0.0, 0.0), (w, h)], fill: @core.Fill::NoFill, stroke: { color: 0xFF000000, width: 2.0 } }
  }
  let built = apply_style_kv(l, m)
  // 顶点数再判一次（用**同一句话**）：`points=` 走上面的字符串校验，
  // 而"根本没给 points 的 polygon"要到这儿才看得出来 —— 0 顶点的多边形
  // 渲染器同样一个像素不落，回包却是 ok。
  match built {
    Ok(nl) => {
      let e = points_count_error(nl.kind, nl.points.length())
      if e != "" {
        return Err(e)
      }
      Ok(nl)
    }
    Err(e) => Err(e)
  }
}

///|
///|
/// 「某 kind 才有意义」的字段：**一行一个**。
///
/// 判定 = 「值非空/非默认」且「kind 不在允许集合」→ 该层带着死数据：
/// 它会被写进 canonical JSON、**改变指纹**，渲染器却根本不读它——于是
/// "改成功了吗"的三个信号自相矛盾（指纹说变了、query-layer 报出来了、
/// 画面逐位没变）。
///
/// **为什么是一张表**：这类字段每加一个，天真的做法是在 lint 里再加一条
/// `if`。本仓库栽过好几次"只会变长的表"，所以这里做成一行一个字段：
/// 新增 kind 专属字段只需加一行，而且漏没漏能一眼数出来。
///
/// 每行的 `reader` 必须与 `render/scene.mbt` 的实际读点一致——渲染器只在
/// 它自己的 kind 分支里读这些字段（Group→children / Adjust→adjust /
/// Text→text+font_size / Raster→dabs / Image→asset_hash /
/// Rect→corner_radius / Polygon·Line→points）。
priv struct KindOnly {
  field : String // 诊断里怎么称呼这个字段
  reader : String // 渲染器在哪种 kind 下读它（写给人看）
  kinds : Array[String] // 允许携带它的 kind（`kind_str` 的词）
  dead : (@core.Layer) -> String // 返回非空 = 带着死数据（内容是值的描述）
  // 被拒时的**出路**（空 = 用通用措辞）。有些字段的替代写法是具体的：
  // `radius` 只对矩形有意义 ⇒ 要圆角请用 `add-rect`；`fill` 在折线上
  // ⇒ 请用 `stroke=`。这句跟着表走，命令面与 lint 才不会一个说 A 一个说 B。
  hint : String
}

///|
fn kind_only_fields() -> Array[KindOnly] {
  [
    {
      field: "text",
      reader: "text 层",
      hint: "",
      kinds: ["text"],
      dead: fn(l) { if l.text != "" { "text 字段" } else { "" } },
    },
    {
      field: "font_size",
      reader: "text 层",
      hint: "",
      kinds: ["text"],
      dead: fn(l) {
        if l.font_size != 16.0 {
          "font_size=\{@core.fmt_num(l.font_size)}"
        } else {
          ""
        }
      },
    },
    {
      field: "corner_radius",
      reader: "矩形（rect）",
      hint: "渲染器不读它的圆角（椭圆本身就是圆的；要给图形加圆角请用 add-rect）",
      kinds: ["rect"],
      dead: fn(l) {
        if l.corner_radius != 0.0 {
          "radius=\{@core.fmt_num(l.corner_radius)}"
        } else {
          ""
        }
      },
    },
    {
      field: "points",
      reader: "polygon/line",
      hint: "渲染器不读它的顶点（矩形/椭圆用 w/h/radius 定义形状；要折线请用 add-line）",
      kinds: ["polygon", "line"],
      dead: fn(l) {
        if l.points.length() > 0 {
          "\{l.points.length()} 个顶点"
        } else {
          ""
        }
      },
    },
    {
      field: "adjust",
      reader: "adjust 层",
      hint: "",
      kinds: ["adjust"],
      dead: fn(l) { if l.adjust is Some(_) { "adjust 字段" } else { "" } },
    },
    {
      field: "asset_hash",
      reader: "image 层",
      hint: "",
      kinds: ["image"],
      dead: fn(l) { if l.asset_hash != "" { "asset 引用" } else { "" } },
    },
    {
      field: "dabs",
      reader: "raster 层",
      hint: "",
      kinds: ["raster"],
      dead: fn(l) {
        if l.dabs.length() > 0 { "\{l.dabs.length()} 个笔触" } else { "" }
      },
    },
    {
      field: "children",
      reader: "group",
      hint: "",
      kinds: ["group"],
      dead: fn(l) {
        if l.children.length() > 0 { "\{l.children.length()} 个子层" } else { "" }
      },
    },
    // ↓ 下面五行是「变换/混合/蒙版」的**读点矩阵**：实测（非退化探针：非白底 +
    //   左右不对称的位图 + 30° 旋转）它们在 text/adjust 上**不被读**——写进去回
    //   ok、指纹变、画面逐位不变。（`group` 与 `raster` 都曾是这一格：组的变换、
    //   笔触层的变换都是"后来才接上"的，每次接上都要把这一行改过来——矩阵跟着
    //   渲染器走，不是渲染器跟着矩阵走。）
    //   ⚠️ 探针必须非退化，否则会得出反结论：整块纯色方块的 rotate/flip 是
    //   **恒等变换**（第一版就是这样把 image 判成"不读"的），multiply 压在
    //   白底上也是恒等（第一版把 blend 判成"全都不读"）。
    {
      field: "rotation_deg",
      reader: "有面的层（几何/位图）+ **组**（变换整棵子树）+ **笔触层**（绕落笔范围中心）+ **文本层**（绕自己的盒子中心）",
      hint: "",
      // `group` 从 PLAN 五十六起读（`render.paint_layer` 把组压进祖先链、
      // 子层的 `to_local` 就会经过它）、`raster` 从 PLAN 六十起读（轴心 =
      // 落笔范围中心）、`text` 从 PLAN 六十一起读（字形逐点过完整变换链）
      // ——读点矩阵必须跟着渲染器走，否则"渲染器读了而入口还拒"是一条
      // 凭空的能力上限、"入口收下而渲染器不读"是一条静默的谎。
      kinds: ["rect", "ellipse", "polygon", "line", "image", "group", "raster", "text"],
      dead: fn(l) {
        if l.rotation_deg != 0.0 {
          "rotation_deg=\{@core.fmt_num(l.rotation_deg)}"
        } else {
          ""
        }
      },
    },
    {
      field: "flip_h",
      reader: "有面的层（几何/位图）+ **组**（整棵子树镜像）+ **笔触层**（绕落笔范围中心）+ **文本层**（绕自己的盒子中心）",
      hint: "",
      // 与 `rotation_deg` 同一份名单（PLAN 五十六/六十/六十一）。
      kinds: ["rect", "ellipse", "polygon", "line", "image", "group", "raster", "text"],
      dead: fn(l) { if l.flip_h { "flip_h=true" } else { "" } },
    },
    {
      field: "flip_v",
      reader: "有面的层（几何/位图）+ **组**（整棵子树镜像）+ **笔触层**（绕落笔范围中心）+ **文本层**（绕自己的盒子中心）",
      hint: "",
      // 与 `rotation_deg` 同一份名单（PLAN 五十六/六十/六十一）。
      kinds: ["rect", "ellipse", "polygon", "line", "image", "group", "raster", "text"],
      dead: fn(l) { if l.flip_v { "flip_v=true" } else { "" } },
    },
    {
      field: "blend",
      reader: "有面的层（几何/位图）",
      hint: "",
      kinds: ["rect", "ellipse", "polygon", "line", "image"],
      dead: fn(l) {
        if !(l.blend is @core.BlendMode::Normal) {
          "blend=\{blend_str(l.blend)}"
        } else {
          ""
        }
      },
    },
    // ↓ 填充与描边也是读点矩阵的一部分：**描边只实现了矩形/椭圆/线段**
    //   （`inside_stroke` 的 `_ =>` 分支写着"多边形描边与位图描边不实现"），
    //   而"多边形描边"这条边界此前只有一句代码注释——`add-polygon stroke=6`
    //   收得下、指纹变、画面逐位不变。填充同理：折线只有描边（字典里那句
    //   "fill 不生效"说的就是它），位图的填充也不读（缺资产是固定洋红）。
    //   ⚠️ 默认填充是 `Solid(0xFF808080)`、默认描边是 `{0xFF000000, width 0}`
    //   ——"写了默认值"与"没写"必须一样，否则清字段的写法会被自己拒掉。
    {
      field: "fill",
      reader: "有填充面的层（矩形/椭圆/多边形/文本）",
      hint: "折线只有描边（要颜色请用 stroke=），位图/笔触/调整层/组没有填充面",
      kinds: ["rect", "ellipse", "polygon", "text"],
      dead: fn(l) {
        match l.fill {
          // 默认灰：没写过填充
          @core.Fill::Solid(c) => if c == 0xFF808080 { "" } else { "fill=\{@codec.color_to_hex(c)}" }
          // `fill=none` 是**清空**写法（也是组的常态），不算死数据
          @core.Fill::NoFill => ""
          @core.Fill::LinearGradient(_, _, _, _, _, _) => "lgrad=…"
        }
      },
    },
    {
      field: "stroke",
      reader: "矩形/椭圆/线段（`inside_stroke` 只实现这三种）",
      hint: "描边只实现了矩形/椭圆/线段；位图/文本/笔触/调整层/组都没有描边",
      kinds: ["rect", "ellipse", "line"],
      dead: fn(l) {
        let w = if l.stroke.width != 0.0 {
          "stroke_w=\{@core.fmt_num(l.stroke.width)}"
        } else {
          ""
        }
        let c = if l.stroke.color != 0xFF000000 {
          "stroke=\{@codec.color_to_hex(l.stroke.color)}"
        } else {
          ""
        }
        if w != "" && c != "" {
          "\{w} \{c}"
        } else if w != "" {
          w
        } else {
          c
        }
      },
    },
    {
      field: "mask",
      reader: "除组以外的层",
      hint: "",
      kinds: ["rect", "ellipse", "polygon", "line", "image", "text", "raster", "adjust"],
      dead: fn(l) {
        match l.mask {
          Some(_) => "mask=已设置"
          None => ""
        }
      },
    },
  ]
}

///|
/// **往一个层上写某个字段之前**问一句：这个字段在这层上渲染器读不读？
/// （`Some(理由)` = 不读，命令面必须拒——铁律 6：不支持就报明确错误，不降级。）
///
/// 判据与 `lint_doc` 共用**同一张表** `kind_only_fields`：值非默认 + kind 不在
/// 允许集合 = 死数据。传进来的 `l` 必须是**已经带上新值的候选层**，于是
/// "写默认值 = 清字段"自动放行（`rotate t1 0`、`flip t1 none`、
/// `blend=normal` 的 `dead` 都是空串）——手改容器/旧容器里的死数据靠它们洗回来。
///
/// 措辞要给**出路**：说清渲染器在哪读它、怎么清。
///|
/// 蒙版写入门禁的**占位蒙版**：`kind_only_fields` 里 mask 那一格只问"这层读不读
/// 蒙版"，不关心参数（参数归 `mask_param_error`），所以问一句不必把整份蒙版造出来。
fn mask_write_probe() -> @core.LayerMask {
  {
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 1.0,
    h: 1.0,
    radius: 0.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
  }
}

///|
fn kind_only_row(field : String) -> KindOnly? {
  for c in kind_only_fields() {
    if c.field == field {
      return Some(c)
    }
  }
  None
}

///|
/// 命令键 → 表里的字段名（`fill=`/`lgrad=` 都写 `Fill`、`stroke=`/`stroke_w=`
/// 都写 `Stroke`）。**只此一份**：字典的"这个 kind 认哪些键"与参数报错里的
/// 指路都从它算——手写第二份映射就一定会分叉。
fn key_field(key : String) -> String {
  match key {
    "fill" => "fill"
    "lgrad" => "fill"
    "stroke" => "stroke"
    "stroke_w" => "stroke"
    "radius" => "corner_radius"
    "points" => "points"
    "rot" => "rotation_deg"
    "blend" => "blend"
    _ => ""
  }
}

///|
/// `check_kv_args` 的 `ctx` 名 → 这一层的 kind。只有 `add-*` 建层命令有**确定**
/// 的 kind；`set-style` 的 kind 是逐层的（同一个键在不同层上答案不同），那种
/// 情况由写值时的 `kind_only_write_error` 拒。
fn ctx_shape_kind(ctx : String) -> @core.ShapeKind? {
  match ctx {
    "add-rect" => Some(@core.ShapeKind::Rect)
    "add-ellipse" => Some(@core.ShapeKind::Ellipse)
    "add-polygon" => Some(@core.ShapeKind::Polygon)
    "add-line" => Some(@core.ShapeKind::Line)
    "add-image" => Some(@core.ShapeKind::Image)
    "add-text" => Some(@core.ShapeKind::Text)
    "add-adjust" => Some(@core.ShapeKind::Adjust)
    "add-paint" => Some(@core.ShapeKind::Raster)
    _ => None
  }
}

///|
/// 这个 kind 上不读这个字段时的**短注**（空 = 读它）。字典的描述与参数报错
/// 的指路都用它 ⇒ 措辞与 `kind_only_write_error` 同源，不会一个说 A 一个说 B。
fn kind_only_dead_note(kind : @core.ShapeKind, field : String) -> String {
  match kind_only_row(field) {
    Some(c) =>
      if c.kinds.contains(kind_str(kind)) {
        ""
      } else {
        let h = if c.hint != "" { c.hint } else { "渲染器只对 \{c.reader} 读 \{c.field}" }
        "（\{field} 在 \{kind_str(kind)} 上不生效：\{h}）"
      }
    None => ""
  }
}

///|
fn kind_only_write_error(l : @core.Layer, field : String) -> String? {
  for c in kind_only_fields() {
    if c.field == field {
      let why = (c.dead)(l)
      // 写了默认值 = 清字段：放行（旧容器里的死数据要洗得回来）
      if why == "" {
        return None
      }
      // ⚠️ 这一句是**判据本体**：`kind_only_reject_text` 只拼措辞、不判成员
      // （重构时漏掉它 ⇒ 每个 kind 都被拒，测试当场红）
      if c.kinds.contains(kind_str(l.kind)) {
        return None
      }
      return kind_only_reject_text(c, l.kind, l.id, field, why)
    }
  }
  None
}

///|
/// 只想问"这个 kind 读不读这个字段"、**值还没解析出来**时用（`points` 的形态
/// 检查依赖 kind，得先听到"这层不读顶点"，而不是"顶点太少"）。
///
/// 与 `kind_only_write_error` 共用同一行、同一句措辞——两条入口路径判的必须
/// 是同一件事。
fn kind_only_kind_error(
  kind : @core.ShapeKind,
  id : String,
  field : String,
) -> String? {
  for c in kind_only_fields() {
    if c.field == field {
      if c.kinds.contains(kind_str(kind)) {
        return None
      }
      return kind_only_reject_text(c, kind, id, field, "")
    }
  }
  None
}

///|
/// 被拒时的措辞只有这一处：有"出路"（`hint`）的行说清该用什么替代，其余走
/// 通用措辞（说清渲染器在哪读、怎么清）。
fn kind_only_reject_text(
  c : KindOnly,
  kind : @core.ShapeKind,
  id : String,
  field : String,
  why : String,
) -> String? {
  if c.hint != "" {
    let val = if why != "" { "（\{why}）" } else { "" }
    return Some(
      "\{field} 只对\{c.reader}有意义：这层是 \{kind_str(kind)}\{val}，\{c.hint}",
    )
  }
  let hint = if field == "mask" { "（蒙版用 remove-mask）" } else { "" }
  Some(
    "\{kind_str(kind)} 层 \{id} 上的 \{field} 不生效：渲染器只对 \{c.reader} 读 \{c.field}，写进去也不会改变任何像素。要清掉这个字段请写默认值\{hint}",
  )
}

/// 收集重复 id / 越界 / 非法值等 P0–P2 违规（lint 命令）。
///|
///|
/// `max(0, a, b)`：上面那条"超出窗多少"的判据用（负值 = 在窗内）。
fn over2(a : Double, b : Double) -> Double {
  let m = if a > b { a } else { b }
  if m > 0.0 { m } else { 0.0 }
}

///|
/// 「描边把整层盖满」的判据（**只有一处**）：矩形/椭圆的描边**朝内**（内缩一圈），
/// 内缩盒在 `2*stroke_w >= min(w,h)` 时退化成空 ⇒ 整块内部都算描边，`fill` 一个
/// 像素都看不见。实测 20×20 + `stroke_w=10`（等号）时中心就是描边色 —— 所以
/// 判据是 `>=` 而不是 `>`。
fn stroke_cover_error(l : @core.Layer) -> String? {
  let sw = l.stroke.width
  if sw <= 0.0 {
    return None
  }
  let inward = l.kind is @core.ShapeKind::Rect || l.kind is @core.ShapeKind::Ellipse
  if !inward {
    return None
  }
  let short = if l.w < l.h { l.w } else { l.h }
  if sw * 2.0 < short {
    return None
  }
  Some(
    "P2 stroke 层 \{l.id} 的描边宽 \{@core.fmt_num(sw)} 盖满整层（\{@core.fmt_num(l.w)}x\{@core.fmt_num(l.h)}）：渲染器把描边画成实心块、fill 看不见（描边朝内，内缩盒退化成空）——要实心就直接给 fill=，要描边请把 stroke_w 降到 \{@core.fmt_num(short / 2.0)} 以下",
  )
}

///|
/// 「线段的描边被渲染窗裁掉」的判据（**只有一处**）。线段描边**以线段为中心**
/// （两侧各半宽 + 圆头），胶囊会伸出层盒子；而渲染窗只有"盒子的对角线为边 +
/// 2px"（`@render.paint_window`，与 `pick` 共用一处实现），**窗外的像素根本不画**
/// ⇒ 画出来的线比 `stroke_w` 窄。实测 8×4 盒 + `stroke_w=20` 只画出 13×13 的
/// 方块（圆头与两侧全没了）；旋转 30° 后还会更偏（窗是轴对齐的，胶囊不是）。
/// 只报"落在画布内"的那部分：窗外且画布外的部分本来就没有损失。
fn stroke_clip_error(l : @core.Layer, cw : Int, ch : Int) -> String? {
  if !(l.kind is @core.ShapeKind::Line) || l.stroke.width <= 0.0 {
    return None
  }
  let pts = l.points
  if pts.length() < 2 {
    return None
  }
  let (wx0, wy0, wx1, wy1) = @render.paint_window(l)
  let half = l.stroke.width / 2.0
  let mut clipped = false
  let mut i = 0
  while i + 1 < pts.length() && !clipped {
    let (ax, ay) = pts[i]
    let (bx, by) = pts[i + 1]
    let dx = bx - ax
    let dy = by - ay
    let len = Double::sqrt(dx * dx + dy * dy)
    if len > 0.0 {
      let ux = dx / len
      let uy = dy / len
      // 胶囊在局部坐标里的极值点：两侧各半宽（法向）+ 两端的圆头顶点（轴向）
      let cand : Array[(Double, Double)] = [
        (ax - uy * half, ay + ux * half),
        (ax + uy * half, ay - ux * half),
        (bx - uy * half, by + ux * half),
        (bx + uy * half, by - ux * half),
        (ax - ux * half, ay - uy * half),
        (bx + ux * half, by + uy * half),
      ]
      for p in cand {
        // 正逆变换分开写就会有一边先烂 ⇒ 走渲染器自己的 `to_canvas`
        let (cx, cy) = @render.to_canvas(l, p.0, p.1)
        let in_canvas = cx >= 0.0 && cy >= 0.0 && cx < cw.to_double() && cy < ch.to_double()
        if in_canvas {
          // **超出窗多少**才说话：窗的 2px 松弛量就是用来吸收整数取整的
          // （`paint_window` 把边界 `.to_int()` 之后 ±2），所以只切掉 0–2px 的
          // 圆头不该报——实测 `sw=4` 的正常线就被切了不到 1px，按"出窗即报"
          // 会误报。超出松弛量才是"画出来真的比 stroke_w 窄"。
          let cutx = over2(wx0.to_double() - cx, cx - wx1.to_double())
          let cuty = over2(wy0.to_double() - cy, cy - wy1.to_double())
          let cut = if cutx > cuty { cutx } else { cuty }
          if cut > 2.0 {
            clipped = true
          }
        }
      }
    }
    i = i + 1
  }
  if !clipped {
    return None
  }
  Some(
    "P2 stroke 层 \{l.id} 的描边（宽 \{@core.fmt_num(l.stroke.width)}）伸出渲染窗超过松弛量：窗 = 层盒子的对角线为边 + 2px（\{wx0},\{wy0}–\{wx1},\{wy1}），伸到窗外的两侧与圆头不会被画 ⇒ 画出来比 stroke_w 窄；要么把 stroke_w 调小，要么把盒子 w/h 放大到装得下描边",
  )
}

///|
/// 一个层对若干**变换/编辑命令**的画面效果（`query-layer`/`list-layers` 报出来，
/// 人类前端据此决定**画不画控件**）。
///
/// 它回答的不是"命令收不收"（那是入口门禁），而是**"收下之后画面会不会变"**：
/// 实测 `move` 在组/调整层上回 `ok` 而画面一像素不动、`resize` 在文本/笔触层上
/// 同样（`w/h` 一条渲染路径都不读）。控件画在那儿只会让人以为改坏了——
/// 读点矩阵那一节留下的"人类侧还差一格"就是靠这条能力表补上的。
///
/// **判据一处**：有面的那些格子（rotate/flip/mask/text/font_size/adjust/asset/
/// children）直接读**读点矩阵那一行**（`kind_only_row`，与两条入口路径同一行、
/// 同一句措辞）；字段名打错时这里是"少报"（`None => false`）而不是"全报"，
/// 且 `agent/caps_test.mbt` 逐 kind 断言**完整** caps，打错当场红。
///
/// `move`/`resize` 判的是**容器字段** `x/y/w/h`——每个层都有盒子，"写了/没写"
/// 分不出来，矩阵那套 `dead` 判据用不上——名单来自 PLAN 五十一 的逐 kind 实测，
/// 并由同一条对照测试钉住：**caps 说有 ⇒ 渲染 sha 必须变；说没有 ⇒ 必须逐位相同**。
/// 实测名单（探针非退化；指纹变才算"命令真生效"）：
///   矩形/椭圆/位图：`x/y` 平移、`w/h` 参与（位图是**拉伸到盒子**）；
///   多边形/线段：`x/y` 平移；`w/h` 是**渲染窗**（`paint_window`）⇒ 改它可能裁剪；
///   文本：`x/y` 读（字按 `font_size` 画）、**盒子不参与渲染**（实测显式 `w=/h=`
///         与缺省盒 render sha 逐位相同）；
///   笔触：`x/y` 平移笔触、**盒子不参与渲染**（窗口是画布尺寸）；
///   组/调整层：`x/y` 与盒子**都不读**（组画的是子层、调整层作用于其下的合成）。
/// 另一格是 `opacity`（不透明度）：**所有 kind 都读**（组也算合成的一层，
/// 调整层则是"算子生效多少"）。此前调整层的 α 是个**开关**（α=0 整层不施加、
/// (0,1] 全强度——中间那些位置静默无效），现在与蒙版覆盖度合成同一处软强度
/// （PLAN 五十三）。
///|
/// 组上还挂着**非恒等变换**时，`ungroup` / `group-remove` 会**把变换丢掉**
/// ——画面跟着变，而回包说 `ok`（实测：`rotate grp 90` 之后 `ungroup grp`，
/// `render_sha256` 从 `c09a3d3b…` 变成 `e4ef0899…`，三个信号里没有一个说
/// "画面变了"，见 PLAN 五十七）。
///
/// 返回**拒绝理由**，恒等变换/非组返回空串（调用方按空串放行）。
/// 判据一处：两个命令共用这一句，别各写一份"组上有没有变换"。
pub fn group_transform_error(l : @core.Layer, op : String) -> String {
  if !(l.kind is @core.ShapeKind::Group) {
    return ""
  }
  let what : Array[String] = []
  if l.rotation_deg != 0.0 {
    what.push("rot=\{@core.fmt_num(l.rotation_deg)}")
  }
  if l.flip_h || l.flip_v {
    let d = if l.flip_h && l.flip_v {
      "both"
    } else if l.flip_h {
      "h"
    } else {
      "v"
    }
    what.push("flip=\{d}")
  }
  if what.length() == 0 {
    return ""
  }
  "组 \{l.id} 上还挂着变换（\{what.join("、")}）：\{op} 会把变换**丢掉**、画面跟着变。先 `rotate \{l.id} 0` / `flip \{l.id} none` 清掉它，或者保留这个组"
}

pub fn layer_caps(l : @core.Layer) -> Array[String] {
  let caps : Array[String] = []
  let reads = fn(field : String) -> Bool {
    match kind_only_row(field) {
      Some(c) => c.kinds.contains(kind_str(l.kind))
      None => false
    }
  }
  let k = l.kind
  let text_kind = k is @core.ShapeKind::Text
  let raster_kind = k is @core.ShapeKind::Raster
  let face = k is @core.ShapeKind::Rect ||
    k is @core.ShapeKind::Ellipse ||
    k is @core.ShapeKind::Polygon ||
    k is @core.ShapeKind::Line ||
    k is @core.ShapeKind::Image
  // 顺序即文档顺序（DESIGN §3 的 caps 列表按这个顺序报）
  let group_kind = k is @core.ShapeKind::Group
  if face || text_kind || raster_kind {
    caps.push("move")
  } else if group_kind && group_has_movable(l) {
    // 组自己没画面：它的 `move` 是"搬后代"（`shift_layer_tree`）。只有后代里
    // 真的有人读位置时才算有能力——空组 / 只装调整层的组搬了也是画面逐位相同，
    // 那正是 `caps` 要拦住的那种"说有 ⇒ 画面变"的反例。
    caps.push("move")
  }
  if face {
    caps.push("resize")
  }
  // `opacity`：所有 kind 都读（调整层也不例外——软强度 = 蒙版覆盖度 × α，
  // 见 `render.apply_adjust_layer`；此前 α 在 (0,1) 上**静默无效**，见 PLAN 五十三）
  caps.push("opacity")
  for p in [
    ("rotate", "rotation_deg"),
    ("flip", "flip_h"),
    ("mask", "mask"),
    ("text", "text"),
    ("font_size", "font_size"),
    ("adjust", "adjust"),
    ("asset", "asset_hash"),
    ("children", "children"),
  ] {
    if reads(p.1) {
      caps.push(p.0)
    }
  }
  caps
}

///|
/// 组里有没有"读位置"的后代（递归穿透嵌套组）——`layer_caps` 给组报 `move`
/// 的判据。**判据只有这一处**：命令面（`cmd_move` 的搬法）与能力表都照它。
fn group_has_movable(l : @core.Layer) -> Bool {
  for c in l.children {
    if layer_caps(c).contains("move") {
      return true
    }
  }
  false
}

///|
pub fn lint_doc(doc : @core.Document) -> Array[String] {
  let v : Array[String] = []
  // P0 画布限额
  if doc.width > @mpd.LIMIT_MAX_SIDE || doc.height > @mpd.LIMIT_MAX_SIDE {
    v.push("P0 canvas 画布单边超限（>\{@mpd.LIMIT_MAX_SIDE}）")
  }
  if doc.width.to_int64() * doc.height.to_int64() > @mpd.LIMIT_MAX_PIXELS.to_int64() {
    v.push("P0 canvas 画布总像素超限")
  }
  // P0 render 超出**可渲染上限**：`new`/`set-canvas` 已拒，这里兜住手改容器、
  // 以及**旧引擎（81ff759 之前）产出的超限容器**——那时候 `new 5000 200` 是能
  // 建能存的，所以这种容器真实存在（"旧引擎产不出"是错的说法）。
  // 与上面两条不同，这一条不是"参数非法"而是
  // **"渲染会静默丢内容"**——容器是合法的、指纹是对的、命令全回 ok，
  // 只有渲染少画一块。所以它必须能被单独报出来。
  let rlim = @render.render_limit_error(doc.width, doc.height)
  if rlim != "" {
    v.push("P0 render 画布超出可渲染上限：\{rlim}")
  }
  let seen : Map[String, Bool] = Map([])
  for l in @core.all_layers(doc.layers) {
    if seen.get(l.id) is Some(_) {
      v.push("P1 dup 层 id 重复：\{l.id}")
    }
    seen.set(l.id, true)
    // P1 ns 层 id 与 MVSL 的 `layer=@tag` 命名空间冲突：命令面已拒（`@` 开头的
    // id 建不出来），这里兜住手改的旧容器——`layer=@hero` 到底是"那个叫 @hero
    // 的层"还是"带 hero 标签的全部层"会按容器内容有两种读法，而读错的那边不报错。
    match @core.layer_id_error(l.id) {
      Some(e) => v.push("P1 ns 层 \{l.id}：\{e}")
      None => ()
    }
    // P2 几何
    if l.w <= 0.0 || l.h <= 0.0 {
      v.push("P2 geom 层 \{l.id} 尺寸非正（\{l.w}x\{l.h}）")
    }
    if !(l.kind is @core.ShapeKind::Group) {
      if l.x > doc.width.to_double() ||
        l.y > doc.height.to_double() ||
        l.x + l.w < 0.0 ||
        l.y + l.h < 0.0 {
        v.push("P2 geom 层 \{l.id} 完全在画布外")
      }
    }
    if l.opacity < 0.0 || l.opacity > 1.0 {
      v.push("P2 style 层 \{l.id} opacity 越界")
    }
    // 笔宽为负：命令面已拦（`stroke_w 不能为负`），这里兜住手改容器。
    // 渲染器 `inside_stroke` 第一句就把 ≤0 折成 0 → **描边静默不画**。
    if l.stroke.width < 0.0 {
      v.push(
        "P2 style 层 \{l.id} 的 stroke_w 为负（\{@core.fmt_num(l.stroke.width)}）：渲染器按 0 处理，描边一个像素都不画",
      )
    }
    // 字号非正：命令面已拦（add-text），这里兜住手改容器。文本层的 w/h 是
    // 由字号推出来的，字号 ≤0 会得到零/负尺寸的层（那两条已有 lint 报，
    // 但报的是"尺寸非正"，看不出根因在字号）。
    if l.kind is @core.ShapeKind::Text {
      if l.font_size <= 0.0 {
        v.push(
          "P2 style 文本层 \{l.id} 的 font_size 非正（\{@core.fmt_num(l.font_size)}）：渲染不出任何字形",
        )
      } else if l.text.length() > 0 {
        // 盒子装不下自己的文字：渲染器**不按盒子裁剪**（实测 add-text text=Hi 再
        // set-text 成 "Hello World"，两张图的 render sha256 逐位相同），所以字会
        // 画到盒子外面；而 `pick`/`overlay` 线框/`lgrad` 端点全按盒子算 ——
        // 同一个层，"看得见的范围"与"报出来的范围"对不上。
        // 命令面已拦（set-text 重算盒子），这里兜住手改容器 / resize 缩小。
        let est = text_box(l.text, l.font_size)
        let ew = est.0
        let eh = est.1
        if l.w + 0.000000001 < ew || l.h + 0.000000001 < eh {
          v.push(
            "P2 geom 文本层 \{l.id} 的盒子装不下自己的文字（\{@core.fmt_num(l.w)}x\{@core.fmt_num(l.h)} < 估算 \{@core.fmt_num(ew)}x\{@core.fmt_num(eh)}）：渲染器不裁剪，字会画到盒子外，而 pick/overlay/lgrad 按盒子算",
          )
        }
      }
    }
    // 顶点数不足：`in_polygon` 要求 ≥3、线段要 ≥2 —— 少于下界就是
    // "装了却什么都不干"（指纹变了、query-layer 报着顶点、画面一像素不落）。
    // 命令面已拦（add-polygon/add-line 与 set-style points= 共用
    // `points_min_count`），这里兜住手改容器。下界与命令面**同一处实现**。
    {
      // 说明文字与命令面**同一句**（`points_count_error`）
      let e = points_count_error(l.kind, l.points.length())
      if e != "" {
        v.push("P2 geom 层 \{l.id}：\{e}")
      }
    }
    // 顶点落在渲染窗外：那部分**不会被画出来**（`paint_layer` 只在
    // `paint_window` 里落像素），而层的顶点表里还留着它 —— 同一个层，
    // "它是什么形状"与"画出来什么形状"对不上。判据与渲染器**同一把尺子**
    // （`@render.paint_window`），并且要先把局部顶点换算成画布坐标
    // （`@render.to_canvas`，旋转/翻转都要算上），否则误报。
    // 渲染窗比盒子大（对角线 + 2px），所以"顶点出盒"本身不是错，
    // 只有出**窗**才是真的画不出来 —— 判据不许比渲染器严。
    if l.kind is @core.ShapeKind::Polygon || l.kind is @core.ShapeKind::Line {
      let win = @render.paint_window(l)
      let x0 = win.0
      let y0 = win.1
      let x1 = win.2
      let y1 = win.3
      let mut i = 0
      let mut reported = false
      while i < l.points.length() && !reported {
        let pt = l.points[i]
        let cp = @render.to_canvas(l, pt.0, pt.1)
        let cx = cp.0
        let cy = cp.1
        if cx < x0.to_double() || cx >= x1.to_double() ||
          cy < y0.to_double() || cy >= y1.to_double() {
          reported = true
        }
        i = i + 1
      }
      if reported {
        v.push(
          "P2 geom 层 \{l.id} 有顶点落在渲染窗外：渲染器只画窗内的像素（窗 = 以层盒中心为心、对角线为边再放宽 2px），窗外那部分顶点画不出来 —— 放大 w/h 或把顶点写进窗内",
        )
      }
    }
    // 蒙版参数：命令面已拦（add-mask/set-mask 都过 `@core.mask_param_error`），
    // 这里兜住**手改容器 / 旧版本产物**。判据与入口是**同一句**
    // （`@core.mask_param_error`），所以"入口拒绝什么"与"lint 报什么"不可能分叉。
    // 为什么值得报：尺寸非正的蒙版会把整层**悄悄**藏掉（invert 后整层露出），
    // 负的 radius/feather/roughen 则被渲染器各自折成 0 —— 三者都是"给了参数
    // 但不生效"，而 `query-layer` 照旧把它报出来、指纹照旧变了。
    match l.mask {
      Some(mk) => {
        let me = @core.mask_param_error(mk)
        if me != "" {
          v.push("P2 mask 层 \{l.id}：\{me}")
        }
      }
      None => ()
    }
    // 所有「某 kind 才有意义」的字段走同一张表。此前这里只有三条手写 if
    // （text / radius / points），而同类字段还有五个（font_size / adjust /
    // asset_hash / dabs / children）——**特例化的检查一定漏**。
    for c in kind_only_fields() {
      let why = (c.dead)(l)
      if why != "" && !c.kinds.contains(kind_str(l.kind)) {
        v.push(
          "P2 noop 层 \{l.id} 是 \{kind_str(l.kind)} 却带着 \{why}（渲染器只对 \{c.reader} 读 \{c.field}，纯粹改变指纹）",
        )
      }
    }
    // 描边把整层盖满 / 线段的描边被渲染窗裁掉：两条都是"护栏改了输出却没人报"
    // （PLAN 十九）。判据各只有一处，命令面**不拦**——把描边调宽是合法操作，
    // 结果只是"变成实心块"或"被裁窄"，同 `adjust value=0` 那条分工：
    // 入口拦"非法/无效字段"，lint 拦"合法但画出来的不是他要的"。
    match stroke_cover_error(l) {
      Some(m) => v.push(m)
      None => ()
    }
    match stroke_clip_error(l, doc.width, doc.height) {
      Some(m) => v.push(m)
      None => ()
    }
    // 渐变端点越界：命令面已拦（add-rect/set-style 直接报错），这里兜住
    // 手改 design.json 或外部构造的容器——它渲染出来是个「几乎看不出过渡」
    // 的渐变，不报就没人知道。
    match l.fill {
      @core.Fill::LinearGradient(_gc0, _gc1, gx0, gy0, gx1, gy1) => {
        let ge = @core.grad_endpoint_error(gx0, gy0, gx1, gy1, l.w, l.h)
        if ge != "" {
          v.push("P0 fill 层 \{l.id} 的渐变端点越界：\{ge}")
        }
      }
      _ => ()
    }
    // P2 「装了却什么都不干」——几何/文本侧的空操作。
    // 这类状态**每个命令都返回 ok**、渲染也"成功"（只是没有像素），
    // 所以只有 lint 会报；MVSL 侧早就有这条纪律（空算子/空断言），
    // 几何侧此前没有。实测：空组与空文本层都是 `violations=0`。
    if l.kind is @core.ShapeKind::Group {
      if l.children.length() == 0 {
        v.push("P2 noop 组 \{l.id} 没有任何成员（直通合成里什么都不做）")
      }

    }
    if l.kind is @core.ShapeKind::Text {
      if l.text == "" {
        v.push("P2 noop 文本层 \{l.id} 内容为空（渲染不出任何字形）")
      }
    }
    // 调整层：整个层就由 op+value 定义，所以"装了却什么都不干"在这里
    // 有三种面孔，命令面已经拦掉两种（越界、给无值算子传 value），
    // 这里兜住**手改 design.json / 外部构造的容器**。
    // 第三种（value 恰好是 0）命令面**不拦**——把强度调到 0 是合法操作，
    // 但那确实是一层不干活的层，只有 lint 会说（实测 `add-adjust op=brightness`
    // 建出来的层 `query-layer` 报得出、指纹变了、画面逐位不变，lint 报 0 违规）。
    if l.kind is @core.ShapeKind::Adjust {
      match l.adjust {
        Some(a) => {
          let (has_value, lo, hi) = adjust_spec(a.op)
          let name = @core.adjust_op_name(a.op)
          if !has_value {
            if a.value != 0.0 {
              v.push(
                "P2 noop 调整层 \{l.id} 的 \{name} 不接受数值（渲染器不读 value），却存着 value=\{@core.fmt_num(a.value)}（纯粹改变指纹）",
              )
            }
          } else if a.value < lo || a.value > hi {
            v.push(
              "P2 style 调整层 \{l.id} 的 value=\{@core.fmt_num(a.value)} 超出 \{name} 的范围 [\{@core.fmt_num(lo)}..\{@core.fmt_num(hi)}]",
            )
          } else if a.value == 0.0 {
            v.push(
              "P2 noop 调整层 \{l.id} 是 \{name} 但 value=0（画面逐位不变；要么给个非零数值，要么删掉这层）",
            )
          }
        }
        None => ()
      }
    }
    // P1 引用
    if l.kind is @core.ShapeKind::Image {
      if l.asset_hash == "" {
        v.push("P1 ref 层 \{l.id} image 层缺 asset")
      } else {
        let mut found = false
        for a in doc.assets {
          if a.hash == l.asset_hash {
            found = true
          }
        }
        if !found {
          v.push("P1 ref 层 \{l.id} 引用未登记资产 \{l.asset_hash}")
        }
      }
    }
  }
  if @core.all_layers(doc.layers).length() > @mpd.LIMIT_MAX_LAYERS {
    v.push("P0 layers 层数超限")
  }
  v
}
