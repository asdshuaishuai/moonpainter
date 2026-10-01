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
          let hint = match k {
            "points" => "（顶点只能在 add-polygon/add-line 建层时给，建完没有改顶点的命令）"
            "x" | "y" => "（改位置用 move）"
            "w" | "h" => "（改尺寸用 resize）"
            "text" => "（改文字用 set-text）"
            "font_size" => "（字号在 add-text 建层时给）"
            _ => ""
          }
          if allowed.length() == 0 {
            return Err("\{ctx}：不接受 `\{k}=` 这类参数（该命令只认位置参数）")
          }
          return Err("\{ctx}：不认识的参数 `\{k}`\{hint}；认得的是 \{allowed.join("/")}")
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
      if v == "none" {
        nl = { ..nl, fill: @core.Fill::NoFill }
      } else {
        match parse_color(v) {
          Ok(c) => nl = { ..nl, fill: @core.Fill::Solid(c) }
          Err(e) => return Err(e)
        }
      }
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
      nl = {
        ..nl,
        fill: @core.Fill::LinearGradient(c0, c1, nums[0], nums[1], nums[2], nums[3]),
      }
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
      nl = { ..nl, stroke: { color: c, width: w } }
    }
    None => match m.get("stroke_w") {
        Some(_) => {
          match arg_d(m, "stroke_w", nl.stroke.width) {
            Ok(w) => {
              match (stroke_w_check)(w) {
                Ok(_) => ()
                Err(e) => return Err(e)
              }
              nl = { ..nl, stroke: { color: nl.stroke.color, width: w } }
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
        Ok(b) => nl = { ..nl, blend: b }
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
  match m.get("radius") {
    Some(v) => match to_d(v) {
      Some(r) => {
        if r < 0.0 {
          return Err("radius 不能为负")
        }
        // 非矩形层的圆角是**死数据**：`corner_radius` 只在渲染器的 Rect
        // 分支被读，而 `add-*`/`set-style` 都会把它写进 canonical JSON ——
        // 于是指纹变了、query-layer 又不报（它按 kind 投影）、画面逐位没变。
        // 入口直接拒绝（与 set-text 同一条纪律），lint 兜住手改容器。
        if !(nl.kind is @core.ShapeKind::Rect) {
          return Err(
            "radius 只对矩形（rect）有意义：这层是 \{kind_str(nl.kind)}，渲染器不读它的圆角（椭圆本身就是圆的；要给图形加圆角请用 add-rect）",
          )
        }
        nl = { ..nl, corner_radius: r }
      }
      None => return Err("radius \{v} 不是数字")
    }
    None => ()
  }
  match m.get("rot") {
    Some(v) => match to_d(v) {
      Some(r) => nl = { ..nl, rotation_deg: r }
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
  match m.get("points") {
    Some(v) => {
      // `points` 只有 polygon 与 line 的渲染路径读（`in_polygon` + 折线描边
      // 距离测试）。矩形/椭圆上给 points 会**写进 canonical JSON、改变指纹，
      // 而画面逐位不变**——和"椭圆上的 radius"、"rect 上的 text" 是同一个
      // 死数据 bug（实测：指纹 7248c56f→189c73d6，render_sha 一字未变）。
      if !(kind is @core.ShapeKind::Polygon) && !(kind is @core.ShapeKind::Line) {
        return Err(
          "points 只对 polygon/line 有意义：这层是 \{kind_str(kind)}，渲染器不读它的顶点（矩形/椭圆用 w/h/radius 定义形状；要折线请用 add-polygon）",
        )
      }
      match parse_points(v) {
        Ok(pts) => l = { ..l, points: pts }
        Err(e) => return Err(e)
      }
    }
    None => if kind is @core.ShapeKind::Line {
      // 默认对角线
      l = { ..l, points: [(0.0, 0.0), (w, h)], fill: @core.Fill::NoFill, stroke: { color: 0xFF000000, width: 2.0 } }
    }
  }
  match m.get("stroke_w") {
    Some(_) => {
      match arg_d(m, "stroke_w", 2.0) {
        Ok(w) => l = { ..l, stroke: { color: l.stroke.color, width: w } }
        Err(e) => return Err(e)
      }
    }
    None => ()
  }
  apply_style_kv(l, m)
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
}

///|
fn kind_only_fields() -> Array[KindOnly] {
  [
    {
      field: "text",
      reader: "text 层",
      kinds: ["text"],
      dead: fn(l) { if l.text != "" { "text 字段" } else { "" } },
    },
    {
      field: "font_size",
      reader: "text 层",
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
      reader: "rect",
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
      kinds: ["adjust"],
      dead: fn(l) { if l.adjust is Some(_) { "adjust 字段" } else { "" } },
    },
    {
      field: "asset_hash",
      reader: "image 层",
      kinds: ["image"],
      dead: fn(l) { if l.asset_hash != "" { "asset 引用" } else { "" } },
    },
    {
      field: "dabs",
      reader: "raster 层",
      kinds: ["raster"],
      dead: fn(l) {
        if l.dabs.length() > 0 { "\{l.dabs.length()} 个笔触" } else { "" }
      },
    },
    {
      field: "children",
      reader: "group",
      kinds: ["group"],
      dead: fn(l) {
        if l.children.length() > 0 { "\{l.children.length()} 个子层" } else { "" }
      },
    },
  ]
}

/// 收集重复 id / 越界 / 非法值等 P0–P2 违规（lint 命令）。
pub fn lint_doc(doc : @core.Document) -> Array[String] {
  let v : Array[String] = []
  // P0 画布限额
  if doc.width > @mpd.LIMIT_MAX_SIDE || doc.height > @mpd.LIMIT_MAX_SIDE {
    v.push("P0 canvas 画布单边超限（>\{@mpd.LIMIT_MAX_SIDE}）")
  }
  if doc.width.to_int64() * doc.height.to_int64() > @mpd.LIMIT_MAX_PIXELS.to_int64() {
    v.push("P0 canvas 画布总像素超限")
  }
  let seen : Map[String, Bool] = Map([])
  for l in @core.all_layers(doc.layers) {
    if seen.get(l.id) is Some(_) {
      v.push("P1 dup 层 id 重复：\{l.id}")
    }
    seen.set(l.id, true)
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
      }
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
