/// core —— JSON：通用解析器 + canonical 文档序列化 + 指纹（core/json）。
///
/// 两件事：
/// 1. 一个够小的通用 JSON 解析器（JValue）——design.json / manifest.json /
///    params.json / agent.json 共用，manuscript 解析失败必须报精确位置；
/// 2. Document 的 canonical 序列化——**固定字段序、固定数字格式**，
///    同一文档序列化两次字节一致，sha256 即文档指纹（PLAN.md §4）。
///
/// 不用哈希表迭代产生输出：对象输出顺序全部手写定死（家族纪律）。

///|
/// 通用 JSON 值。
pub(all) enum JValue {
  JNull
  JBool(Bool)
  JNum(Double)
  JStr(String)
  JArr(Array[JValue])
  JObj(Map[String, JValue])
}

///|
/// 取对象字段。
pub fn JValue::get(self : JValue, key : String) -> JValue? {
  match self {
    JObj(m) => m.get(key)
    _ => None
  }
}

///|
pub fn JValue::as_str(self : JValue) -> String? {
  match self {
    JStr(s) => Some(s)
    _ => None
  }
}

///|
pub fn JValue::as_num(self : JValue) -> Double? {
  match self {
    JNum(n) => Some(n)
    _ => None
  }
}

///|
pub fn JValue::as_bool(self : JValue) -> Bool? {
  match self {
    JBool(b) => Some(b)
    _ => None
  }
}

///|
pub fn JValue::as_arr(self : JValue) -> Array[JValue]? {
  match self {
    JArr(a) => Some(a)
    _ => None
  }
}

// ---------------------------------------------------------------------------
// 解析器
// ---------------------------------------------------------------------------

///|
priv struct JParser {
  src : String
  mut pos : Int
  mut err : String
}

///|
/// 解析 JSON 文本。失败返回精确错误（含位置）。
pub fn parse_json(text : String) -> Result[JValue, String] {
  let p = { src: text, pos: 0, err: "" }
  jp_ws(p)
  let v = jp_value(p)
  jp_ws(p)
  if p.pos < p.src.length() {
    return Err("json: 第 \{p.pos} 字符后有多余内容")
  }
  match v {
    Some(value) => Ok(value)
    None => {
      let msg = if p.err.length() > 0 {
        p.err
      } else {
        "json: 第 \{p.pos} 字符处解析失败"
      }
      Err(msg)
    }
  }
}

///|
fn jp_ws(p : JParser) -> Unit {
  while p.pos < p.src.length() {
    match p.src.get_char(p.pos) {
      Some(c) => {
        let n = c.to_int()
        if n == 32 || n == 9 || n == 10 || n == 13 {
          p.pos = p.pos + 1
        } else {
          break
        }
      }
      None => break
    }
  }
}

///|
fn jp_err(p : JParser, msg : String) -> JValue? {
  if p.err.length() == 0 {
    p.err = "json: 第 \{p.pos} 字符处\{msg}"
  }
  None
}

///|
fn jp_value(p : JParser) -> JValue? {
  if p.pos >= p.src.length() {
    return jp_err(p, "提前结束")
  }
  match p.src.get_char(p.pos) {
    None => jp_err(p, "非法字符")
    Some(c) => {
      let n = c.to_int()
      if c == '{' {
        p.pos = p.pos + 1
        jp_object(p)
      } else if c == '[' {
        p.pos = p.pos + 1
        jp_array(p)
      } else if n == 34 {
        // '"'
        match jp_string(p) {
          Some(s) => Some(JStr(s))
          None => None
        }
      } else if n == 116 {
        // 't'
        jp_lit(p, "true", JBool(true))
      } else if n == 102 {
        // 'f'
        jp_lit(p, "false", JBool(false))
      } else if n == 110 {
        // 'n'
        jp_lit(p, "null", JNull)
      } else if n == 45 || (n >= 48 && n <= 57) {
        jp_number(p)
      } else {
        jp_err(p, "非法字符")
      }
    }
  }
}

///|
fn jp_lit(p : JParser, word : String, v : JValue) -> JValue? {
  if p.src.length() - p.pos >= word.length() {
    let seg = p.src[p.pos:p.pos + word.length()].to_owned()
    if seg == word {
      p.pos = p.pos + word.length()
      return Some(v)
    }
  }
  jp_err(p, "非法字面量")
}

///|
fn jp_object(p : JParser) -> JValue? {
  let m : Map[String, JValue] = Map([])
  jp_ws(p)
  match p.src.get_char(p.pos) {
    Some(c) => if c == '}' {
      p.pos = p.pos + 1
      return Some(JObj(m))
    }
    None => ()
  }
  let mut ok = true
  while ok {
    jp_ws(p)
    let key = match jp_string(p) {
      Some(k) => k
      None => return jp_err(p, "期望对象键")
    }
    jp_ws(p)
    match p.src.get_char(p.pos) {
      Some(c) => if c != ':' {
        return jp_err(p, "期望 ':'")
      }
      None => return jp_err(p, "期望 ':'")
    }
    p.pos = p.pos + 1
    jp_ws(p)
    match jp_value(p) {
      Some(v) => m.set(key, v)
      None => return None
    }
    jp_ws(p)
    match p.src.get_char(p.pos) {
      Some(c) => if c == ',' {
        p.pos = p.pos + 1
      } else if c == '}' {
        p.pos = p.pos + 1
        ok = false
      } else {
        return jp_err(p, "期望 ',' 或 '}'")
      }
      None => return jp_err(p, "对象未闭合")
    }
  }
  Some(JObj(m))
}

///|
fn jp_array(p : JParser) -> JValue? {
  let arr : Array[JValue] = []
  jp_ws(p)
  match p.src.get_char(p.pos) {
    Some(c) => if c == ']' {
      p.pos = p.pos + 1
      return Some(JArr(arr))
    }
    None => ()
  }
  let mut ok = true
  while ok {
    jp_ws(p)
    match jp_value(p) {
      Some(v) => arr.push(v)
      None => return None
    }
    jp_ws(p)
    match p.src.get_char(p.pos) {
      Some(c) => if c == ',' {
        p.pos = p.pos + 1
      } else if c == ']' {
        p.pos = p.pos + 1
        ok = false
      } else {
        return jp_err(p, "期望 ',' 或 ']'")
      }
      None => return jp_err(p, "数组未闭合")
    }
  }
  Some(JArr(arr))
}

///|
fn jp_string(p : JParser) -> String? {
  match p.src.get_char(p.pos) {
    Some(c) => if c != '"' {
      return None
    }
    None => return None
  }
  p.pos = p.pos + 1
  let sb = StringBuilder()
  let mut done = false
  while !done {
    if p.pos >= p.src.length() {
      return None
    }
    match p.src.get_char(p.pos) {
      Some(c) => {
        let n = c.to_int()
        if n == 34 {
          p.pos = p.pos + 1
          done = true
        } else if n == 92 {
          // 反斜杠转义
          p.pos = p.pos + 1
          match p.src.get_char(p.pos) {
            Some(e) => {
              let en = e.to_int()
              if en == 34 {
                sb.write_char('"')
                p.pos = p.pos + 1
              } else if en == 92 {
                sb.write_char('\\')
                p.pos = p.pos + 1
              } else if en == 47 {
                sb.write_char('/')
                p.pos = p.pos + 1
              } else if en == 98 {
                sb.write_char('\u{0008}')
                p.pos = p.pos + 1
              } else if en == 102 {
                sb.write_char('\u{000C}')
                p.pos = p.pos + 1
              } else if en == 110 {
                sb.write_char('\n')
                p.pos = p.pos + 1
              } else if en == 114 {
                sb.write_char('\r')
                p.pos = p.pos + 1
              } else if en == 116 {
                sb.write_char('\t')
                p.pos = p.pos + 1
              } else if en == 117 {
                // \uXXXX
                if p.pos + 4 >= p.src.length() {
                  return None
                }
                let hex = p.src[p.pos + 1:p.pos + 5].to_owned()
                let code = hex4(hex)
                match code {
                  Some(cv) => {
                    match cv.to_char() {
                      Some(ch) => sb.write_char(ch)
                      None => ()
                    }
                    p.pos = p.pos + 5
                  }
                  None => return None
                }
              } else {
                return None
              }
            }
            None => return None
          }
        } else if n < 0x20 {
          return None // 控制字符必须转义
        } else {
          sb.write_char(c)
          p.pos = p.pos + 1
        }
      }
      None => return None
    }
  }
  Some(sb.to_string())
}

///|
fn hex4(s : String) -> Int? {
  let mut v = 0
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => {
        let n = c.to_int()
        let d = if n >= 48 && n <= 57 {
          Some(n - 48)
        } else if n >= 97 && n <= 102 {
          Some(n - 87)
        } else if n >= 65 && n <= 70 {
          Some(n - 55)
        } else {
          None
        }
        match d {
          Some(x) => v = v * 16 + x
          None => return None
        }
      }
      None => return None
    }
    i = i + 1
  }
  Some(v)
}

///|
fn jp_number(p : JParser) -> JValue? {
  let start = p.pos
  while p.pos < p.src.length() {
    match p.src.get_char(p.pos) {
      Some(c) => {
        let n = c.to_int()
        if (n >= 48 && n <= 57) ||
          n == 45 ||
          n == 43 ||
          n == 46 ||
          n == 101 ||
          n == 69 {
          p.pos = p.pos + 1
        } else {
          break
        }
      }
      None => break
    }
  }
  if p.pos == start {
    return jp_err(p, "非法数字")
  }
  let seg = p.src[start:p.pos].to_owned()
  let parsed : Double? = Some(@string.parse_double(seg)) catch {
    _ => None
  }
  match parsed {
    Some(d) => Some(JNum(d))
    None => jp_err(p, "数字无法解析: \{seg}")
  }
}

// ---------------------------------------------------------------------------
// 序列化（canonical）
// ---------------------------------------------------------------------------

///|
/// JSON 字符串转义（只转义必须转义的）。
pub fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  for i in 0..<s.length() {
    match s.get_char(i) {
      Some(c) => {
        let n = c.to_int()
        if n == 34 {
          sb.write_string("\\\"")
        } else if n == 92 {
          sb.write_string("\\\\")
        } else if n == 10 {
          sb.write_string("\\n")
        } else if n == 13 {
          sb.write_string("\\r")
        } else if n == 9 {
          sb.write_string("\\t")
        } else if n < 0x20 {
          sb.write_string("\\u")
          sb.write_string(hex4_str(n))
        } else {
          sb.write_char(c)
        }
      }
      None => ()
    }
  }
  sb.to_string()
}

///|
fn hex4_str(v : Int) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  let mut i = 3
  while i >= 0 {
    let d = (v >> (i * 4)) & 0xF
    match digits.get_char(d) {
      Some(c) => sb.write_char(c)
      None => sb.write_char('0')
    }
    i = i - 1
  }
  sb.to_string()
}

///|
/// canonical 数字格式：整数值不带小数点，其余用语言最短表示。
/// 同一引擎版本内确定性；跨版本由 canonical 测试守护。
pub fn fmt_num(d : Double) -> String {
  let abs = if d < 0.0 { -d } else { d }
  if abs < 1000000000000000.0 && d == d.to_int().to_double() {
    d.to_int().to_string()
  } else {
    "\{d}"
  }
}

// ---------------------------------------------------------------------------
// Document ⇄ JSON
// ---------------------------------------------------------------------------

///|
fn kind_str(k : ShapeKind) -> String {
  match k {
    Rect => "rect"
    Ellipse => "ellipse"
    Line => "line"
    Polygon => "polygon"
    Image => "image"
    Group => "group"
    Text => "text"
    Adjust => "adjust"
    Raster => "raster"
    Path => "path"
  }
}

///|
/// `BlendMode` → canonical 名字。**读（`parse_blend` 在 agent 侧）与写（这里）
/// 成对**：agent 的导出/P SD 报告都读这一处，别在别处再抄一张表。
pub fn blend_name(b : BlendMode) -> String {
  match b {
    Normal => "normal"
    Multiply => "multiply"
    Screen => "screen"
    Overlay => "overlay"
    Darken => "darken"
    Lighten => "lighten"
    Difference => "difference"
  }
}

///|
fn fill_json(f : Fill) -> String {
  match f {
    NoFill => "{\"t\":\"none\"}"
    Solid(c) => "{\"t\":\"solid\",\"c\":\"\{@codec.color_to_hex(c)}\"}"
    LinearGradient(c0, c1, x0, y0, x1, y1) => "{\"t\":\"lgrad\",\"c0\":\"\{@codec.color_to_hex(c0)}\",\"c1\":\"\{@codec.color_to_hex(c1)}\",\"x0\":\{fmt_num(x0)},\"y0\":\{fmt_num(y0)},\"x1\":\{fmt_num(x1)},\"y1\":\{fmt_num(y1)}}"
  }
}

///|
fn mask_json(m : LayerMask?) -> String {
  match m {
    None => "null"
    Some(mask) => {
      let kind = match mask.kind {
        Rect => "rect"
        Ellipse => "ellipse"
        Polygon => "polygon"
        _ => "rect"
      }
      "{\"kind\":\"\{kind}\",\"x\":\{fmt_num(mask.x)},\"y\":\{fmt_num(mask.y)},\"w\":\{fmt_num(mask.w)},\"h\":\{fmt_num(mask.h)},\"radius\":\{fmt_num(mask.radius)},\"feather\":\{fmt_num(mask.feather)},\"roughen\":\{fmt_num(mask.roughen)},\"invert\":\{mask.invert},\"points\":\{points_json(mask.points)}}"
    }
  }
}

///|
///|
/// 色阶参数的写出端：字段名与读入端（`adjust_of`）逐字对应。
fn levels_json(lv : Levels) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"in_lo\":\{fmt_num(lv.in_lo)},\"in_hi\":\{fmt_num(lv.in_hi)}")
  sb.write_string(",\"gamma\":\{fmt_num(lv.gamma)}")
  sb.write_string(",\"out_lo\":\{fmt_num(lv.out_lo)},\"out_hi\":\{fmt_num(lv.out_hi)}}")
  sb.to_string()
}

///|
/// 曲线的点表：`[[x,y],…]`。**空表不写字段**（缺省 = 没有曲线）——于是老文档
/// 的字节流一个字节都不变（canonical 往返的前提）。
fn curve_json(pts : Array[(Double, Double)]) -> String {
  let sb = StringBuilder()
  sb.write_string("[")
  let mut i = 0
  for p in pts {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("[\{fmt_num(p.0)},\{fmt_num(p.1)}]")
    i = i + 1
  }
  sb.write_string("]")
  sb.to_string()
}

///|
/// 滤镜参数的写出端：`[["angle",30],["radius",12]]`——**顺序即字节**（键名升序，
/// `sort_params` 一处保证），所以 canonical 指纹稳定。字符串走 `json_escape`
/// （键名本该来自 `filter_param_rows` 的 ASCII 表，但写端不该假设输入是干净的）。
fn filter_params_json(params : Array[(String, Double)]) -> String {
  let sb = StringBuilder()
  sb.write_string("[")
  let mut i = 0
  while i < params.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("[\"" + json_escape(params[i].0) + "\"," + fmt_num(params[i].1) + "]")
    i = i + 1
  }
  sb.write_string("]")
  sb.to_string()
}

fn adjust_json(a : Adjust?) -> String {
  match a {
    None => "null"
    Some(adj) => {
      let op = adjust_op_name(adj.op)
      let sb = StringBuilder()
      sb.write_string("{\"op\":\"\{op}\",\"value\":\{fmt_num(adj.value)}")
      match adj.levels {
        Some(lv) => {
          sb.write_string(",\"levels\":")
          sb.write_string(levels_json(lv))
        }
        None => ()
      }
      if adj.curve.length() > 0 {
        sb.write_string(",\"curve\":")
        sb.write_string(curve_json(adj.curve))
      }
      if adj.params.length() > 0 {
        sb.write_string(",\"params\":")
        sb.write_string(filter_params_json(adj.params))
      }
      sb.write_string("}")
      sb.to_string()
    }
  }
}

///|
/// 图层样式的写出端：**只在该层真的有 fx 时写这个字段**（`None` 时整个字段
/// 不出现）——老文档的 canonical 字节一个字节都不变，与 `handles` 同一条思路。
/// 字段名与读入端（`fx_of`）逐字对应，16 个字段**全写**（不是"只写非默认"：
/// 样式是一整件东西，半个对象读回来只能靠默认值猜，改一个开关时容易把别的
/// 参数悄悄退回默认）。
fn fx_json(f : LayerFx?) -> String {
  match f {
    None => ""
    Some(fx) => {
      let sb = StringBuilder()
      sb.write_string(",\"fx\":{")
      sb.write_string("\"shadow\":\{fx.shadow},\"shadow_dx\":\{fmt_num(fx.shadow_dx)},\"shadow_dy\":\{fmt_num(fx.shadow_dy)}")
      sb.write_string(",\"shadow_blur\":\{fmt_num(fx.shadow_blur)},\"shadow_color\":\"\{@codec.color_to_hex(fx.shadow_color)}\"")
      sb.write_string(",\"outline\":\{fx.outline},\"outline_w\":\{fmt_num(fx.outline_w)},\"outline_color\":\"\{@codec.color_to_hex(fx.outline_color)}\"")
      sb.write_string(",\"glow\":\{fx.glow},\"glow_radius\":\{fmt_num(fx.glow_radius)},\"glow_color\":\"\{@codec.color_to_hex(fx.glow_color)}\"")
      sb.write_string(",\"inner\":\{fx.inner},\"inner_dx\":\{fmt_num(fx.inner_dx)},\"inner_dy\":\{fmt_num(fx.inner_dy)}")
      sb.write_string(",\"inner_blur\":\{fmt_num(fx.inner_blur)},\"inner_color\":\"\{@codec.color_to_hex(fx.inner_color)}\"")
      sb.write_string("}")
      sb.to_string()
    }
  }
}

///|
/// 文本排版的写出端（②C）：**只在真的有排版时写这个字段**（`None` 时整个字段
/// 不出现）——老文档的 canonical 字节一个字节都不变，与 `fx`/`handles` 同一条
/// 思路。四个字段**全写**（不是"只写非默认"）：排版是一整件东西，半个对象
/// 读回来只能靠默认值猜。
fn text_style_json(ts : TextStyle?) -> String {
  match ts {
    None => ""
    Some(s) => {
      ",\"text_style\":{\"align\":\"" +
      text_align_name(s.align) +
      "\",\"line_height\":" +
      s.line_height.to_string() +
      ",\"letter_spacing\":" +
      s.letter_spacing.to_string() +
      ",\"wrap\":" +
      s.wrap.to_string() +
      "}"
    }
  }
}

///|
/// 读入端：字段缺省 = `None`（全默认）。不认识的 `align` 必须**失败得响**
/// （铁律：不认识的枚举不许当默认值收下）。
fn text_style_of(v : JValue) -> Result[TextStyle?, String] {
  let raw = match v.get("text_style") {
    Some(t) => t
    None => return Ok(None)
  }
  if raw is JNull {
    return Ok(None)
  }
  let d = text_neutral_style()
  let align = match str_field(raw, "align") {
    Some(a) => match text_align_from_name(a) {
      Some(x) => x
      None => {
        let mut names = ""
        let mut first = true
        for a2 in all_text_aligns() {
          if first {
            first = false
          } else {
            names = names + "/"
          }
          names = names + text_align_name(a2)
        }
        return Err("text_style.align 必须是 \{names}，收到 \{a}")
      }
    }
    None => d.align
  }
  let line_height = match raw.get("line_height") {
    Some(_) => int_field(raw, "line_height")
    None => d.line_height
  }
  let letter_spacing = match raw.get("letter_spacing") {
    Some(_) => int_field(raw, "letter_spacing")
    None => d.letter_spacing
  }
  Ok(Some({ align, line_height, letter_spacing, wrap: bool_field(raw, "wrap") }))
}

///|
fn layer_json(l : Layer) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":\"\{l.id}\",\"name\":\"")
  sb.write_string(json_escape(l.name))
  sb.write_string("\",\"kind\":\"\{kind_str(l.kind)}\",\"visible\":")
  sb.write_string(l.visible.to_string())
  sb.write_string(",\"opacity\":\{fmt_num(l.opacity)},\"blend\":\"\{blend_name(l.blend)}\"")
  sb.write_string(",\"x\":\{fmt_num(l.x)},\"y\":\{fmt_num(l.y)},\"w\":\{fmt_num(l.w)},\"h\":\{fmt_num(l.h)}")
  sb.write_string(",\"rot\":\{fmt_num(l.rotation_deg)},\"radius\":\{fmt_num(l.corner_radius)},\"flip_h\":\{l.flip_h},\"flip_v\":\{l.flip_v}")
  sb.write_string(",\"text\":\"\{json_escape(l.text)}\",\"font_size\":\{fmt_num(l.font_size)}")
  // 排版**只在有 text_style 时写**（见 `text_style_json` 的注释）：老文档字节不变。
  sb.write_string(text_style_json(l.text_style))
  sb.write_string(",\"mask\":")
  sb.write_string(mask_json(l.mask))
  sb.write_string(",\"adjust\":")
  sb.write_string(adjust_json(l.adjust))
  // 样式**只在有 fx 时写**（见 `fx_json` 的注释）：没有样式的层字节不变。
  sb.write_string(fx_json(l.fx))
  sb.write_string(",\"points\":")
  sb.write_string(points_json(l.points))
  // 控制柄**只写非空**：非 Path 层逐位不变（老 golden 不动），Path 层全 0 控制柄
  // 也能省掉一长串 `[0,0]`——"缺省 = 折线"这条语义必须读写两侧一致。
  if l.handles.length() > 0 {
    sb.write_string(",\"handles\":")
    sb.write_string(points_json(l.handles))
  }
  sb.write_string(",\"fill\":\{fill_json(l.fill)}")
  sb.write_string(",\"stroke\":{\"c\":\"\{@codec.color_to_hex(l.stroke.color)}\",\"w\":\{fmt_num(l.stroke.width)}}")
  sb.write_string(",\"dabs\":[")
  let mut fd = true
  for d in l.dabs {
    if fd {
      fd = false
    } else {
      sb.write_string(",")
    }
    // 克隆字段**只写非默认值**（同 radius/points 那套：canonical 字节不被
    // "没用到克隆"的每个 dab 撑大），所以读侧必须把这个不对称写对——
    // `num_f`/`bool_field` 的缺省就是"没写 = 假/0"。
    sb.write_string(
      "{\"x\":\{fmt_num(d.x)},\"y\":\{fmt_num(d.y)},\"r\":\{fmt_num(d.r)},\"c\":\"\{@codec.color_to_hex(d.color)}\",\"e\":\{d.erase}",
    )
    if d.clone {
      sb.write_string(
        ",\"cl\":true,\"sdx\":\{fmt_num(d.sdx)},\"sdy\":\{fmt_num(d.sdy)}",
      )
    }
    sb.write_string("}")
  }
  sb.write_string("]")
  sb.write_string(",\"asset\":\"\{l.asset_hash}\"")
  sb.write_string(",\"tags\":[")
  let mut f2 = true
  for t in l.tags {
    if f2 {
      f2 = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("\"\{json_escape(t)}\"")
  }
  sb.write_string("]")
  sb.write_string(",\"children\":[")
  let mut f3 = true
  for c in l.children {
    if f3 {
      f3 = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(layer_json(c))
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// canonical 序列化：固定字段序、固定数字格式。同文档两次序列化字节一致。
pub fn doc_to_json(doc : Document) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"format\":\"\{DOC_FORMAT_ID}\",\"version\":\{DOC_VERSION}")
  sb.write_string(",\"uuid\":\"\{doc.uuid}\"")
  sb.write_string(",\"width\":\{doc.width},\"height\":\{doc.height},\"dpi\":\{doc.dpi},\"profile\":\"\{doc.profile}\"")
  sb.write_string(",\"next_layer_no\":\{doc.next_layer_no}")
  sb.write_string(",\"assets\":[")
  let mut fa = true
  for a in doc.assets {
    if fa {
      fa = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"hash\":\"\{a.hash}\",\"width\":\{a.width},\"height\":\{a.height}}")
  }
  sb.write_string("]")
  sb.write_string(",\"params\":[")
  let mut fp = true
  for p in doc.params {
    if fp {
      fp = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"name\":\"\{json_escape(p.name)}\",\"value\":\"\{json_escape(p.value)}\"}")
  }
  sb.write_string("]")
  sb.write_string(",\"layers\":[")
  let mut fl = true
  for l in doc.layers {
    if fl {
      fl = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(layer_json(l))
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// 文档指纹：canonical JSON 文本的 SHA-256。所有变更信封必带（PLAN.md §4）。
pub fn fingerprint(doc : Document) -> String {
  @base.sha256_hex(@utf8.encode(doc_to_json(doc)))
}

///|
fn num_of(v : JValue, field : String) -> Result[Double, String] {
  match v.get(field) {
    Some(JNum(n)) => Ok(n)
    _ => Err("字段 \{field} 缺失或不是数字")
  }
}

///|
fn str_of(v : JValue, field : String) -> Result[String, String] {
  match v.get(field) {
    Some(JStr(s)) => Ok(s)
    _ => Err("字段 \{field} 缺失或不是字符串")
  }
}

///|
fn bool_of(v : JValue, field : String) -> Result[Bool, String] {
  match v.get(field) {
    Some(JBool(b)) => Ok(b)
    _ => Err("字段 \{field} 缺失或不是布尔")
  }
}

///|
fn kind_of(s : String) -> Result[ShapeKind, String] {
  match s {
    "rect" => Ok(Rect)
    "ellipse" => Ok(Ellipse)
    "line" => Ok(Line)
    "polygon" => Ok(Polygon)
    "image" => Ok(Image)
    "group" => Ok(Group)
    "text" => Ok(Text)
    "adjust" => Ok(Adjust)
    "raster" => Ok(Raster)
    "path" => Ok(Path)
    _ => Err("未知节点类型: \{s}")
  }
}

///|
fn blend_of(s : String) -> Result[BlendMode, String] {
  match s {
    "normal" => Ok(Normal)
    "multiply" => Ok(Multiply)
    "screen" => Ok(Screen)
    "overlay" => Ok(Overlay)
    "darken" => Ok(Darken)
    "lighten" => Ok(Lighten)
    "difference" => Ok(Difference)
    _ => Err("未知混合模式: \{s}")
  }
}

///|
fn fill_of(v : JValue) -> Result[Fill, String] {
  match v.get("t") {
    Some(JStr("none")) => Ok(NoFill)
    Some(JStr("solid")) => match v.get("c") {
      Some(JStr(c)) => Ok(Solid(@codec.color_from_hex(c)))
      _ => Err("solid 填充缺 c")
    }
    Some(JStr("lgrad")) => {
      let c0 = str_of(v, "c0")
      let c1 = str_of(v, "c1")
      let x0 = num_of(v, "x0")
      let y0 = num_of(v, "y0")
      let x1 = num_of(v, "x1")
      let y1 = num_of(v, "y1")
      match (c0, c1, x0, y0, x1, y1) {
        (Ok(a), Ok(b), Ok(c), Ok(d), Ok(e), Ok(f)) =>
          Ok(LinearGradient(@codec.color_from_hex(a), @codec.color_from_hex(b), c, d, e, f))
        _ => Err("lgrad 填充字段不完整")
      }
    }
    _ => Err("未知填充类型")
  }
}

///|
/// 蒙版解析。**不认识的 kind 一律报错，不是"当作没有蒙版"**。
///
/// 后者是这里原来的行为，而它是一条静默错渲：手改容器把 `kind` 打错一个字母，
/// 引擎会说"打开成功"并把整层**当没有蒙版**画出来（层全露），指纹也对不上——
/// 三个信号互相矛盾。同 `kind_of`/算子解析的纪律：认不出来就**失败得响**。
/// 这也是新增蒙版种类的**兼容前提**：旧引擎读到不认识的 kind 会拒绝打开，
/// 而不是静默画出另一张图。
fn mask_of(v : JValue) -> Result[LayerMask?, String] {
  let raw = match v.get("mask") {
    Some(mv) => mv
    None => return Ok(None)
  }
  if raw is JNull {
    return Ok(None)
  }
  let kind_s = match str_field(raw, "kind") {
    Some(k) => k
    None => return Err("蒙版缺 kind（认得的是 rect、ellipse、polygon；要摘掉蒙版用 remove-mask）")
  }
  let kind = match kind_s {
    "rect" => Rect
    "ellipse" => Ellipse
    // 任意形状选区（套索）：容器里写的是 polygon（写出端与 `kind_str` 一致）
    "polygon" => Polygon
    "poly" => Polygon
    other => {
      return Err(
        "蒙版 kind 未知：\{other}（认得的是 rect、ellipse、polygon；要摘掉蒙版用 remove-mask）",
      )
    }
  }
  Ok(
    Some(
      {
        kind,
        x: num_f(raw, "x"),
        y: num_f(raw, "y"),
        w: num_f(raw, "w"),
        h: num_f(raw, "h"),
        radius: num_f(raw, "radius"),
        feather: num_f(raw, "feather"),
        roughen: num_f(raw, "roughen"),
        invert: bool_field(raw, "invert"),
        points: match points_of_or_empty(raw) {
          Ok(ps) => ps
          Err(e) => return Err(e)
        },
      },
    ),
  )
}

///|
/// 层/蒙版顶点的**写出**（一处实现）：`[[x,y],…]`。报告面（`query-layer` 的
/// 蒙版字段）也复用它——两处各写一遍，先烂的一定是没人读的那处。
pub fn points_json(pts : Array[(Double, Double)]) -> String {
  let sb = StringBuilder()
  sb.write_string("[")
  let mut first = true
  for pt in pts {
    if first {
      first = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("[\{fmt_num(pt.0)},\{fmt_num(pt.1)}]")
  }
  sb.write_string("]")
  sb.to_string()
}

///|
/// 层顶点的**解析**（一处实现，图层与蒙版共用；两边各写一份必然分叉）。
/// 缺 `points` 是错误（老容器都有它）；允许空数组（形状层之外的 kind 就是空的）。
fn points_of(v : JValue) -> Result[Array[(Double, Double)], String] {
  match v.get("points") {
    Some(JArr(arr)) => points_parse(arr)
    _ => Err("缺 points")
  }
}

///|
/// 蒙版用：`points` 可以缺席（老容器里的蒙版没有这个字段），缺席 = 空。
fn points_of_or_empty(v : JValue) -> Result[Array[(Double, Double)], String] {
  points_of_or_empty_key(v, "points")
}

///|
///|
/// 按**键名**取点串（`points`/`handles` 共用一处解析）：两个字段的格式完全一样
/// （`[[x,y],…]`），各写一份解析就会出现"一个能读一个读不了"。
fn points_of_or_empty_key(
  v : JValue,
  key : String,
) -> Result[Array[(Double, Double)], String] {
  match v.get(key) {
    Some(JArr(arr)) => points_parse(arr)
    _ => Ok([])
  }
}

///|
fn points_parse(arr : Array[JValue]) -> Result[Array[(Double, Double)], String] {
  let points : Array[(Double, Double)] = []
  for pt in arr {
    match pt {
      JArr(pair) =>
        if pair.length() == 2 {
          let a = pair[0]
          let b = pair[1]
          match (a, b) {
            (JNum(x), JNum(y)) => points.push((x, y))
            _ => return Err("points 顶点不是数字")
          }
        } else {
          return Err("points 顶点不是二元组")
        }
      _ => return Err("points 顶点不是数组")
    }
  }
  Ok(points)
}

///|
fn str_field(v : JValue, key : String) -> String? {
  match v.get(key) {
    Some(s) => s.as_str()
    None => None
  }
}

///|
fn bool_field(v : JValue, key : String) -> Bool {
  match v.get(key) {
    Some(b) => match b.as_bool() {
      Some(t) => t
      None => false
    }
    None => false
  }
}

///|
/// 整数字段（②C 的 `line_height`/`letter_spacing`）：给的是小数就**失败得响**
/// （`8.5` 行距没有意义；静默截断 = 读回来的东西与存下去的字节不一致）。
fn int_field(v : JValue, key : String) -> Int {
  let n = num_f(v, key)
  n.to_int()
}

///|
fn num_f(v : JValue, key : String) -> Double {
  match v.get(key) {
    Some(n) => match n.as_num() {
      Some(d) => d
      None => 0.0
    }
    None => 0.0
  }
}

///|
///|
/// 读调整层参数（**失败得响**：不认识的算子、缺参数、参数越界都在这里报，
/// 而不是把整块 `adjust` 悄悄丢掉——丢掉会让"我调过色阶"与画面不一致，
/// 而回包一切正常）。
///
/// 三处与老版本不同，都是刻意的：
/// ①未知算子名 ⇒ `Err`（老引擎遇到本引擎新加的 `levels` 会在这里报"不认"，
///   配合 `required_render_contract` 的 6 档 ⇒ 拒绝打开而不是静默不施加）；
/// ②`levels`/`curve` 字段存在时必须**完整**（少一个数就报，不是按 0 收下）；
/// ③参数组合经 `adjust_param_error`（与命令入口**同一句话**）。
fn adjust_of(v : JValue) -> Result[Adjust?, String] {
  let raw = match v.get("adjust") {
    Some(av) => av
    None => return Ok(None)
  }
  if raw is JNull {
    return Ok(None)
  }
  let opname = match str_field(raw, "op") {
    Some(o) => o
    None =>
      return Err("调整层缺 op（可选：" + all_adjust_ops().map(adjust_op_name).join(" ") + "）")
  }
  let op = match adjust_op_from_name(opname) {
    Some(o) => o
    None =>
      return Err(
        "调整算子未知：\{opname}（本引擎认的是：" +
        all_adjust_ops().map(adjust_op_name).join(" ") +
        "；这一层是别的版本写的 ⇒ 拒绝打开，别静默丢掉它的作用）",
      )
  }
  let value = num_f(raw, "value")
  // 色阶：字段在就必须 5 个数都在
  let levels = match raw.get("levels") {
    Some(lv) =>
      if lv is JNull {
        None
      } else {
        let in_lo = match num_of(lv, "in_lo") {
          Ok(x) => x
          Err(e) => return Err("色阶参数不完整：\{e}")
        }
        let in_hi = match num_of(lv, "in_hi") {
          Ok(x) => x
          Err(e) => return Err("色阶参数不完整：\{e}")
        }
        let gamma = match num_of(lv, "gamma") {
          Ok(x) => x
          Err(e) => return Err("色阶参数不完整：\{e}")
        }
        let out_lo = match num_of(lv, "out_lo") {
          Ok(x) => x
          Err(e) => return Err("色阶参数不完整：\{e}")
        }
        let out_hi = match num_of(lv, "out_hi") {
          Ok(x) => x
          Err(e) => return Err("色阶参数不完整：\{e}")
        }
        Some({ in_lo, in_hi, gamma, out_lo, out_hi })
      }
    None => None
  }
  // 曲线：字段在就必须是 [[x,y],…] 且每项都在 0..1
  let curve : Array[(Double, Double)] = []
  match raw.get("curve") {
    Some(cv) =>
      match cv {
        JArr(items) => {
          let mut i = 0
          for it in items {
            match it {
              JArr(pair) => {
                if pair.length() != 2 {
                  return Err("曲线的第 \{i + 1} 个点不是 [x,y]（收到 \{pair.length()} 个数）")
                }
                let x = match pair[0] {
                  JNum(d) => d
                  _ => return Err("曲线的第 \{i + 1} 个点的 x 不是数字")
                }
                let y = match pair[1] {
                  JNum(d) => d
                  _ => return Err("曲线的第 \{i + 1} 个点的 y 不是数字")
                }
                curve.push((x, y))
              }
              _ => return Err("曲线的第 \{i + 1} 个点不是 [x,y]")
            }
            i = i + 1
          }
        }
        JNull => ()
        _ => return Err("curve 必须是 [[x,y],…] 的点表")
      }
    None => ()
  }
  // 滤镜参数：字段在就必须是 [[键,数值],…]（形状/范围/排序由 adjust_param_error 一句判）
  let params : Array[(String, Double)] = []
  match raw.get("params") {
    Some(pv) =>
      match pv {
        JArr(items) => {
          let mut i = 0
          for it in items {
            match it {
              JArr(pair) =>
                if pair.length() != 2 {
                  return Err("params 的第 \{i + 1} 项不是 [键,数值]")
                } else {
                  let k = match pair[0] {
                    JStr(sv) => sv
                    _ => return Err("params 的第 \{i + 1} 项的键不是字符串")
                  }
                  let v = match pair[1] {
                    JNum(d) => d
                    _ => return Err("params 的第 \{i + 1} 项的数值不是数字")
                  }
                  params.push((k, v))
                }
              _ => return Err("params 的第 \{i + 1} 项不是 [键,数值]")
            }
            i = i + 1
          }
        }
        JNull => ()
        _ => return Err("params 必须是 [[键,数值],…] 的表")
      }
    None => ()
  }
  let adj : Adjust = { op, value, levels, curve, params }
  match adjust_param_error(adj) {
    Some(e) => Err(e)
    None => Ok(Some(adj))
  }
}

///|
/// 图层样式的读入端（与 `fx_json` 逐字对应）。
///
/// 缺字段按 `default_fx()` 补齐（手改容器/将来加字段时不至于读不出来），
/// 但**取值不在这里判**：越界/负值由 `fx_param_error` 一句说了算，入口拒、
/// lint 报（同 `mask_of` 那条分工——容器里的坏值要能被"看见"，而不是打不开）。
fn fx_of(v : JValue) -> Result[LayerFx?, String] {
  let raw = match v.get("fx") {
    Some(fv) => fv
    None => return Ok(None)
  }
  if raw is JNull {
    return Ok(None)
  }
  let d = default_fx()
  // 颜色：字典/命令面走 `parse_color`（#RRGGBB / #RRGGBBAA），这里同一个
  // `@codec.color_from_hex`——两处各写一份 hex 解析必然分叉。
  let color = fn(key : String, dflt : Int) -> Int {
    match str_field(raw, key) {
      Some(s) => @codec.color_from_hex(s)
      None => dflt
    }
  }
  Ok(
    Some(
      {
        shadow: bool_field(raw, "shadow"),
        shadow_dx: num_f(raw, "shadow_dx"),
        shadow_dy: num_f(raw, "shadow_dy"),
        shadow_blur: match raw.get("shadow_blur") {
          Some(_) => num_f(raw, "shadow_blur")
          None => d.shadow_blur
        },
        shadow_color: color("shadow_color", d.shadow_color),
        outline: bool_field(raw, "outline"),
        outline_w: match raw.get("outline_w") {
          Some(_) => num_f(raw, "outline_w")
          None => d.outline_w
        },
        outline_color: color("outline_color", d.outline_color),
        glow: bool_field(raw, "glow"),
        glow_radius: match raw.get("glow_radius") {
          Some(_) => num_f(raw, "glow_radius")
          None => d.glow_radius
        },
        glow_color: color("glow_color", d.glow_color),
        inner: bool_field(raw, "inner"),
        inner_dx: num_f(raw, "inner_dx"),
        inner_dy: num_f(raw, "inner_dy"),
        inner_blur: match raw.get("inner_blur") {
          Some(_) => num_f(raw, "inner_blur")
          None => d.inner_blur
        },
        inner_color: color("inner_color", d.inner_color),
      },
    ),
  )
}

///|
fn dab_of(v : JValue) -> Result[Dab, String] {
  let x = num_of(v, "x")
  let y = num_of(v, "y")
  let r = num_of(v, "r")
  let c = str_of(v, "c")
  match (x, y, r, c) {
    (Ok(dx), Ok(dy), Ok(dr), Ok(dc)) =>
      Ok({
        x: dx,
        y: dy,
        r: dr,
        color: @codec.color_from_hex(dc),
        erase: bool_field(v, "e"),
        clone: bool_field(v, "cl"),
        sdx: num_f(v, "sdx"),
        sdy: num_f(v, "sdy"),
      })
    _ => Err("dab 字段不完整（x/y/r/c）")
  }
}

///|
fn layer_of(v : JValue) -> Result[Layer, String] {
  let id = str_of(v, "id")
  let name = str_of(v, "name")
  let kind = match str_of(v, "kind") {
    Ok(k) => kind_of(k)
    Err(e) => return Err(e)
  }
  let visible = bool_of(v, "visible")
  let opacity = num_of(v, "opacity")
  let blend = match str_of(v, "blend") {
    Ok(b) => blend_of(b)
    Err(e) => return Err(e)
  }
  let x = num_of(v, "x")
  let y = num_of(v, "y")
  let w = num_of(v, "w")
  let h = num_of(v, "h")
  let rot = num_of(v, "rot")
  let radius = num_of(v, "radius")
  let flip_h = bool_of(v, "flip_h")
  let flip_v = bool_of(v, "flip_v")
  let text = match str_of(v, "text") {
    Ok(t) => Some(t)
    Err(_) => None
  }
  let font_size = match num_of(v, "font_size") {
    Ok(n) => Some(n)
    Err(_) => None
  }
  let mask = match mask_of(v) {
    Ok(m) => m
    Err(e) => return Err(e)
  }
  let adjust = match adjust_of(v) {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let fx = match fx_of(v) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  let text_style = match text_style_of(v) {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  let fill = match v.get("fill") {
    Some(f) => fill_of(f)
    None => return Err("缺 fill")
  }
  let stroke_c = match v.get("stroke") {
    Some(sv) => match str_of(sv, "c") {
      Ok(c) => Ok(@codec.color_from_hex(c))
      Err(e) => Err(e)
    }
    None => Err("缺 stroke")
  }
  let stroke_w = match v.get("stroke") {
    Some(sv) => num_of(sv, "w")
    None => Err("缺 stroke")
  }
  let asset = str_of(v, "asset")
  let points = match points_of(v) {
    Ok(ps) => ps
    Err(e) => return Err(e)
  }
  // 控制柄**缺省即空**（老容器没有这个字段，全 0 = 折线语义）——同 `dabs` 那套：
  // 只对 Path 有意义的字段不写出来也能读回来。解析与 `points` 走同一处。
  let handles = match points_of_or_empty_key(v, "handles") {
    Ok(hs) => hs
    Err(e) => return Err(e)
  }
  let tags : Array[String] = []
  match v.get("tags") {
    Some(JArr(arr)) => for t in arr {
        match t {
          JStr(s) => tags.push(s)
          _ => return Err("tags 项不是字符串")
        }
      }
    _ => return Err("缺 tags")
  }
  let children : Array[Layer] = []
  match v.get("children") {
    Some(JArr(arr)) => for cv in arr {
        match layer_of(cv) {
          Ok(l) => children.push(l)
          Err(e) => return Err("子层: \{e}")
        }
      }
    _ => return Err("缺 children")
  }
  let dabs : Array[Dab] = []
  match v.get("dabs") {
    Some(JArr(arr)) => for dv in arr {
        match dab_of(dv) {
          Ok(d) => dabs.push(d)
          Err(e) => return Err("dab: \{e}")
        }
      }
    _ => return Err("缺 dabs")
  }
  // 逐字段拼装（元组匹配 15 个字段太长，按序检查）
  match
    (id, name, kind, visible, opacity, blend, x, y, w, h, rot, radius, flip_h, flip_v, text, font_size, mask, adjust, fill, stroke_c, stroke_w, asset) {
    (
      Ok(i),
      Ok(n),
      Ok(k),
      Ok(vis),
      Ok(op),
      Ok(bl),
      Ok(lx),
      Ok(ly),
      Ok(lw),
      Ok(lh),
      Ok(lr),
      Ok(rc),
      Ok(flip_h),
      Ok(flip_v),
      Some(txt),
      Some(fs),
      mask,
      adjust,
      Ok(fi),
      Ok(sc),
      Ok(sw),
      Ok(ash),
    ) =>
      Ok({
        id: i,
        name: n,
        kind: k,
        visible: vis,
        opacity: op,
        blend: bl,
        x: lx,
        y: ly,
        w: lw,
        h: lh,
        rotation_deg: lr,
        corner_radius: rc,
        flip_h,
        flip_v,
        text: txt,
        font_size: fs,
        text_style,
        mask,
        adjust,
        fx,
        points,
        handles,
        dabs,
        fill: fi,
        stroke: { color: sc, width: sw },
        asset_hash: ash,
        tags,
        children,
      })
    _ => Err("层字段不完整或类型错误")
  }
}

///|
/// 从 canonical JSON 反解文档。拒绝未知 format 与更高版本（前向拒绝纪律）。
pub fn doc_from_json(text : String) -> Result[Document, String] {
  let v = match parse_json(text) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  match str_of(v, "format") {
    Ok(f) => {
      if f != DOC_FORMAT_ID {
        return Err("文档格式不符: \{f}（期望 \{DOC_FORMAT_ID}）")
      }
    }
    Err(e) => return Err(e)
  }
  match num_of(v, "version") {
    Ok(ver) => {
      if ver > DOC_VERSION.to_double() {
        return Err("文档版本 \{ver} 高于引擎支持的 \{DOC_VERSION}，拒绝打开")
      }
    }
    Err(e) => return Err(e)
  }
  let uuid = str_of(v, "uuid")
  let width = num_of(v, "width")
  let height = num_of(v, "height")
  let dpi = num_of(v, "dpi")
  let profile = str_of(v, "profile")
  let next_no = num_of(v, "next_layer_no")
  let uuid_v = match uuid {
    Ok(u) => u
    Err(e) => return Err(e)
  }
  let width_v = match width {
    Ok(w) => w.to_int()
    Err(e) => return Err(e)
  }
  let height_v = match height {
    Ok(h) => h.to_int()
    Err(e) => return Err(e)
  }
  let dpi_v = match dpi {
    Ok(d) => d.to_int()
    Err(e) => return Err(e)
  }
  let profile_v = match profile {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let next_v = match next_no {
    Ok(n) => n.to_int()
    Err(e) => return Err(e)
  }
  let assets : Array[Asset] = []
  match v.get("assets") {
    Some(JArr(arr)) => for av in arr {
        match (str_of(av, "hash"), num_of(av, "width"), num_of(av, "height")) {
          (Ok(h), Ok(w), Ok(hh)) =>
            assets.push({ hash: h, width: w.to_int(), height: hh.to_int() })
          _ => return Err("资产登记字段不完整")
        }
      }
    _ => return Err("缺 assets")
  }
  let params : Array[Param] = []
  match v.get("params") {
    Some(JArr(arr)) => for pv in arr {
        match (str_of(pv, "name"), str_of(pv, "value")) {
          (Ok(n), Ok(val)) => params.push({ name: n, value: val })
          _ => return Err("元参数字段不完整")
        }
      }
    _ => return Err("缺 params")
  }
  let layers : Array[Layer] = []
  match v.get("layers") {
    Some(JArr(arr)) => for lv in arr {
        match layer_of(lv) {
          Ok(l) => layers.push(l)
          Err(e) => return Err(e)
        }
      }
    _ => return Err("缺 layers")
  }
  Ok({
    uuid: uuid_v,
    width: width_v,
    height: height_v,
    dpi: dpi_v,
    profile: profile_v,
    layers,
    assets,
    params,
    next_layer_no: next_v,
  })
}
