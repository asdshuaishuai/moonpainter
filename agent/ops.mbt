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
      nl = { ..nl, stroke: { color: c, width: w } }
    }
    None => match m.get("stroke_w") {
        Some(_) => {
          match arg_d(m, "stroke_w", nl.stroke.width) {
            Ok(w) => nl = { ..nl, stroke: { color: nl.stroke.color, width: w } }
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
  match m.get("radius") {
    Some(v) => match to_d(v) {
      Some(r) => {
        if r < 0.0 {
          return Err("radius 不能为负")
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
    } else if l.text != "" {
      // `set-text` 已在入口拒绝非文本层，这里兜住**手改 design.json /
      // 外部构造的容器**（与渐变端点同一条纪律：入口拒绝 + lint 兜底）。
      // 这个字段会被写进 canonical JSON、**改变指纹**，渲染器却根本不读它。
      v.push("P2 noop 层 \{l.id} 是 \{kind_str(l.kind)} 却带着 text 字段（渲染器不读，纯粹改变指纹）")
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
