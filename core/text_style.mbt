/// core —— **文本排版**（②C：字号 / 对齐 / 换行 / 行距 / 字距）。
///
/// 纪律（与 `filter_param_rows`、`kind_only_fields` 同源）：
/// **排版只有一处实现**——「这段文字排成哪几行、每行从哪儿画、行与行差多少」
/// 由这个文件回答；`agent` 的 `text_box`（盒子跟着内容走）与 `render` 的
/// 逐像素绘制/墨点判据都调它。两处各算一遍就必然分叉（本仓库踩过：`text_box`
/// 只在 `add-text` 用、`set-text` 不重算，于是文字被画到盒子外而 `query-layer`
/// 还报着旧盒子）。
///
/// 单位（铁律 8：带坐标/尺寸的参数必须在字典里写明单位）：
/// - `line_height`：**字形格**（一格 = `sc` 个像素，`sc = max(1, floor(font_size/7))`），
///   即"行与行差几个字形格"；缺省 8 = 7 行字模 + 1 行空隙。
/// - `letter_spacing`：同样以**字形格**为单位，加在每字符 6 格的推进上。
///   取字形格而不是像素，是因为字模是**整数格**位图——非整数推进会让"这个点
///   在不在墨上"出现两种答案（`text_cell` 的整格索引就废了）。

///|
/// 文本对齐（②C）。名字表在下面**一处**，读写两侧共用。
pub(all) enum TextAlign {
  Left
  Center
  Right
}

///|
pub fn text_align_name(a : TextAlign) -> String {
  match a {
    Left => "left"
    Center => "center"
    Right => "right"
  }
}

///|
pub fn text_align_from_name(n : String) -> TextAlign? {
  match n {
    "left" => Some(Left)
    "center" => Some(Center)
    "right" => Some(Right)
    _ => None
  }
}

///|
pub fn all_text_aligns() -> Array[TextAlign] {
  [Left, Center, Right]
}

///|
/// 文本排版属性（②C）。**只在 Text 层有意义**；层上存的是 `TextStyle?`：
/// `None` = 全默认（历史行为），于是老文档的 canonical 字节一个字节都不变。
pub(all) struct TextStyle {
  align : TextAlign
  line_height : Int
  letter_spacing : Int
  wrap : Bool
}

///|
/// 默认排版（= 历史单行行为）。
pub fn text_neutral_style() -> TextStyle {
  { align: Left, line_height: 8, letter_spacing: 0, wrap: false }
}

///|
/// "装了却什么都没动"的判据（②C）：`Some(默认)` 与 `None` 渲染逐位相同，
/// 所以前者是白装——由 `lint` 报（同"全关的 fx"那条分工）。
pub fn text_style_is_default(s : TextStyle) -> Bool {
  s.align is Left && s.line_height == 8 && s.letter_spacing == 0 && !s.wrap
}

///|
/// 取值范围判据（**一处**：入口与 `lint` 共用）。单位写在话里——错误提示是
/// 调用方唯一的说明书。
pub fn text_style_param_error(s : TextStyle) -> String? {
  if s.line_height < 1 || s.line_height > 64 {
    return Some(
      "line_height 必须在 1..64（单位是**字形格** = 字号/7 向下取整、至少 1；缺省 8 = 7 行字模 + 1 行空隙，当前 \{s.line_height}）",
    )
  }
  if s.letter_spacing < -5 || s.letter_spacing > 32 {
    return Some(
      "letter_spacing 必须在 -5..32（单位是**字形格**，加在每字符 6 格的推进上；-5 时推进只剩 1 格、字会叠在一起，当前 \{s.letter_spacing}）",
    )
  }
  None
}

///|
/// 字形放大倍数（**一处**）：`sc = max(1, floor(font_size/7))`。
/// 与 `render`/`agent` 的历史口径逐字相同（16px 字号 ⇒ 2 倍、20px 也 ⇒ 2 倍）。
pub fn text_scale(font_size : Double) -> Int {
  let s = (font_size / 7.0).to_int()
  if s < 1 {
    1
  } else {
    s
  }
}

///|
/// 每字符**推进**（字形格数）：6 格字模 + 字距。`letter_spacing = -5` ⇒ 只剩 1 格。
pub fn text_adv_cols(s : TextStyle) -> Int {
  6 + s.letter_spacing
}

///|
/// 文本拆行（**一处**）：`\n` 是硬换行；`wrap = true` 时再按 `box_w` 贪婪折行
/// （以空格为词界；一个词比整行还宽就硬切；空白段落仍占一行——PS 口径）。
///
/// ⚠️ 折行只在 `wrap = true` 时生效：不折行时**逐字照画**（历史行为逐位不变，
/// 多个连续空格也照旧占位）。
pub fn text_lines(
  text : String,
  style : TextStyle,
  box_w : Double,
  font_size : Double,
) -> Array[String] {
  let hard : Array[String] = []
  let mut sb = StringBuilder()
  for ch in text {
    if ch == '\n' {
      hard.push(sb.to_string())
      sb = StringBuilder()
    } else {
      sb.write_char(ch)
    }
  }
  hard.push(sb.to_string())
  if !style.wrap {
    return hard
  }
  // 一行塞得下几个字符：按**画出来的推进**算（整数格），不是按盒子的理想字宽
  let adv = text_adv_cols(style) * text_scale(font_size)
  let mut cols = (box_w / adv.to_double()).to_int()
  if cols < 1 {
    cols = 1
  }
  let out : Array[String] = []
  for para in hard {
    wrap_paragraph(para, cols, out)
  }
  out
}

///|
fn wrap_paragraph(para : String, cols : Int, out : Array[String]) -> Unit {
  let words : Array[String] = []
  let mut sb = StringBuilder()
  for ch in para {
    if ch == ' ' {
      if sb.to_string() != "" {
        words.push(sb.to_string())
        sb = StringBuilder()
      }
    } else {
      sb.write_char(ch)
    }
  }
  if sb.to_string() != "" {
    words.push(sb.to_string())
  }
  if words.length() == 0 {
    out.push("")
    return
  }
  let mut cur = ""
  for w in words {
    let wl = w.length()
    if wl > cols {
      if cur != "" {
        out.push(cur)
        cur = ""
      }
      let mut i = 0
      while i < wl {
        let j = if i + cols > wl { wl } else { i + cols }
        let piece = w[i:j].to_owned()
        if j < wl {
          out.push(piece)
        } else {
          cur = piece
        }
        i = j
      }
    } else if cur == "" {
      cur = w
    } else if cur.length() + 1 + wl <= cols {
      cur = cur + " " + w
    } else {
      out.push(cur)
      cur = w
    }
  }
  if cur != "" {
    out.push(cur)
  }
}

///|
/// 一行的**理想**盒宽：`字符数 × 字号 × 6/7`（历史公式，逐位复现）+ 字距。
/// ⚠️ `letter_spacing = 0` 时走的是**原式**（`n * fs * 6.0 / 7.0`，先乘后除）——
/// 换一种等价写法会让浮点最后一位变、老 golden 与指纹跟着变。
pub fn text_line_box_w(n : Int, font_size : Double, s : TextStyle) -> Double {
  let base = n.to_double() * font_size * 6.0 / 7.0
  if s.letter_spacing == 0 || n == 0 {
    base
  } else {
    base + (n - 1).to_double() * (s.letter_spacing * text_scale(font_size)).to_double()
  }
}

///|
/// 文本盒子（**一处**）：`explicit_w > 0` 时宽度用它（`wrap=1` 必须给），否则
/// 宽度 = 最长行的理想盒宽（内容派生）；高度 = `font_size + (行数-1) × 行距 × sc`。
/// 单行 ⇒ `(n × fs × 6/7, fs)`，与历史逐位相同。
pub fn text_box_of(
  text : String,
  font_size : Double,
  style : TextStyle,
  explicit_w : Double,
) -> (Double, Double) {
  let lines = text_lines(text, style, explicit_w, font_size)
  let mut w = 0.0
  for ln in lines {
    let lw = text_line_box_w(ln.length(), font_size, style)
    if lw > w {
      w = lw
    }
  }
  let n = lines.length()
  let sc = text_scale(font_size)
  let h = font_size + (n - 1).to_double() * (style.line_height * sc).to_double()
  let bw = if explicit_w > 0.0 { explicit_w } else { w }
  (bw, h)
}
