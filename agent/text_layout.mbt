/// agent —— **文本排版**的命令面（②C）。
///
/// 分工：`core/text_style.mbt` 是**唯一的排版算法**（拆行/折行/盒子/单位换算），
/// 这里只做三件事——把 kv 参数读成 `TextStyle`、把 `TextStyle` 报给调用方、
/// 让 `lint` 用同一句话兜住手改容器。盒子那一步 `agent/session.mbt` 的
/// `text_box` 也调 `core.text_box_of`（**别在这里再算一遍**）。

///|
/// 整数 kv 参数（②C 的行距/字距）。
///
/// 为什么单独一个：`line_height`/`letter_spacing` 的单位是**字形格**（整数），
/// 而 `arg_d` 收下 `8.5` 之后写进 canonical JSON 只能是 `8`（字段是 `Int`）
/// ⇒ 存了 `8.5` 读回来 `8`，往返字节不一致。给了小数就报错（铁律 11：非数/怪值
/// 不许静默退默认）。
pub fn arg_i(
  m : Map[String, String],
  key : String,
  dflt : Int,
) -> Result[Int, String] {
  match m.get(key) {
    None => Ok(dflt)
    Some(v) =>
      match to_d(v) {
        Some(x) => {
          let i = x.to_int()
          if i.to_double() != x {
            Err("参数 \{key}=\{v} 必须是整数（单位：字形格 = 字号/7 向下取整）")
          } else {
            Ok(i)
          }
        }
        None => Err("参数 \{key}=\{v} 不是整数")
      }
  }
}

///|
/// 把 kv 参数读成 `TextStyle`（**部分更新的唯一入口**：`add-text` 与
/// `set-text` 共用）。
///
/// `base = None`（建层）时以 `core.text_neutral_style()` 为底；`set-text` 传
/// 当前层的 `text_style` ⇒ **只给要改的键**（与 `set-fx`/`set-mask` 同一条）。
/// 一个键都没给就原样返回 `base`（连 `None` 都不会变成 `Some(默认)`——
/// "装了却什么都没动"是 `lint` 报的白装，不该由一次无关调用顺手造出来）。
pub fn text_style_args(
  m : Map[String, String],
  base : @core.TextStyle?,
  ctx : String,
) -> Result[@core.TextStyle?, String] {
  let given = m.get("align") is Some(_) ||
    m.get("line_height") is Some(_) ||
    m.get("letter_spacing") is Some(_) ||
    m.get("wrap") is Some(_)
  if !given {
    return Ok(base)
  }
  let d = match base {
    Some(b) => b
    None => @core.text_neutral_style()
  }
  let align = match m.get("align") {
    None => d.align
    Some(a) =>
      match @core.text_align_from_name(a) {
        Some(x) => x
        None =>
          return Err(
            "\{ctx} 的 align 必须是 left|center|right，收到 \{a}",
          )
      }
  }
  let line_height = match arg_i(m, "line_height", d.line_height) {
    Ok(v) => v
    Err(e) => return Err("\{ctx}：\{e}")
  }
  let letter_spacing = match arg_i(m, "letter_spacing", d.letter_spacing) {
    Ok(v) => v
    Err(e) => return Err("\{ctx}：\{e}")
  }
  let wrap = match kv_bool_arg(m, "wrap", d.wrap, "\{ctx} 的 wrap") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let s : @core.TextStyle = { align, line_height, letter_spacing, wrap }
  match @core.text_style_param_error(s) {
    Some(e) => Err("\{ctx}：\{e}")
    None => Ok(Some(s))
  }
}

///|
/// 报给调用方的写法（`query-layer`/`list-layers` 共用一处）。
/// `None` 时不报（老形状的回包逐字节不变）。
pub fn text_style_report(ts : @core.TextStyle?) -> String {
  match ts {
    None => ""
    Some(s) =>
      ",\"text_style\":{\"align\":\"" +
      @core.text_align_name(s.align) +
      "\",\"line_height\":" +
      s.line_height.to_string() +
      ",\"letter_spacing\":" +
      s.letter_spacing.to_string() +
      ",\"wrap\":" +
      s.wrap.to_string() +
      "}"
  }
}

///|
/// 需要显式 `w=` 才能折行的判据（**一处**：`add-text` 与 `set-text` 共用）。
/// 折行宽度 = 盒子宽度；盒子由内容派生时"折行"没有意义（自己折给自己看）。
/// 返回非空 = 拒绝理由。
pub fn text_wrap_width_error(ctx : String, wrap : Bool, w_given : Bool) -> String {
  if wrap && !w_given {
    "\{ctx}：wrap=1 要配 w=<像素>（折行宽度就是盒子宽度）——不给 w 的话盒子等于内容宽度，折不出东西来"
  } else {
    ""
  }
}

///|
/// `lint` 的两条文本排版判据（②C）。**判据一处**：命令面拒不了的两种状态
/// （手改容器 / 用别的命令造成的）在这里报。
///
/// ①**白装**：`text_style` 存在但四个值全默认 —— 渲染与 `None` 逐位相同，
///   于是"我设过排版"这句话没有任何画面证据（同"四件全关的 fx"那条分工）。
/// ②**对齐看不出来**：对齐是"在盒子宽度里怎么摆"，盒子宽度 = 内容宽度时
///   左/中/右给出同一张画面（`align` 白装）。`wrap=1` 时盒子由调用方固定，
///   所以不报。
pub fn text_style_lint(id : String, l : @core.Layer, out : Array[String]) -> Unit {
  let ts = match l.text_style {
    Some(t) => t
    None => return
  }
  if @core.text_style_is_default(ts) {
    out.push(
      "P2 style 文本层 \{id} 的 text_style 四个值全是默认（对齐 left、行距 8、字距 0、不折行）：渲染与没有这个字段逐位相同 —— 要么改一个值，要么把字段摘掉",
    )
    return
  }
  if !(ts.align is @core.TextAlign::Left) && !ts.wrap {
    let (cw, _) = @core.text_box_of(l.text, l.font_size, ts, 0.0)
    // ⚠️ 判据是"盒子**没有比内容更宽**"（`<=`），不是"更宽"——第一版写成
    // `l.w >= cw` 把方向搞反了，于是**真的能看出对齐**的层反而被报（正控当场
    // 抓住：`w=180` 的 align=center 也被报成"看不出来"）。漏报与误报都是 bug。
    if l.w <= cw + 0.000000001 {
      out.push(
        "P2 style 文本层 \{id} 的 align=\{@core.text_align_name(ts.align)} 但盒子宽度等于内容宽度（\{@core.fmt_num(l.w)}）：对齐是「在盒子宽度里怎么摆」，看不出来 —— 给个更宽的 w=，或者加 wrap=1",
      )
    }
  }
}
