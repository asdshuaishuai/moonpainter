// ②C 文本排版（对齐 / 行距 / 字距 / 折行）：**命令面**这一半。
//
// 与 core（排版算法）和 render（像素）分开钉：这边管"AI 与人类能怎么用"——
// 键认不认得出、值收不收得下（含"给了小数"这种怪值）、改不改得动（部分更新）、
// 报不报得出（四个值都要能回读）、装了却什么都不干有没有人说话（lint）。
// 铁律 11：所有数值断言走 `@core.parse_json` 精确取值，不许 contains 子串。

///|
/// 回包里的嵌套字段（缺了就 abort，不静默）。
fn ts_field(text : String, path : Array[String]) -> @core.JValue {
  let path_str = path.join(".")
  let mut cur = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  for k in path {
    let next = match cur.get(k) {
      Some(v) => v
      None => abort("回包缺字段 \{path_str}（卡在 \{k}）：\{text}")
    }
    cur = next
  }
  cur
}

///|
fn ts_num(text : String, path : Array[String]) -> Double {
  match ts_field(text, path).as_num() {
    Some(x) => x
    None => abort("字段不是数字：\{text}")
  }
}

///|
fn ts_str(text : String, path : Array[String]) -> String {
  match ts_field(text, path).as_str() {
    Some(x) => x
    None => abort("字段不是字符串：\{text}")
  }
}

///|
fn ts_bool(text : String, path : Array[String]) -> Bool {
  match ts_field(text, path).as_bool() {
    Some(x) => x
    None => abort("字段不是布尔：\{text}")
  }
}

///|
/// 场景：200×80 画布 + 一个空文本层探针。
fn ts_scene(tag : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 80 uuid=\{tag}")
  s
}

///|
test "②C 建层：四个排版键都收，`\\n` 硬换行进容器，报得出来" {
  let s = ts_scene("ts-add")
  let r = run(
    s,
    "add-text id=t1 x=10 y=10 w=180 text=\"Hi\\nThere\" align=center line_height=12 letter_spacing=2 wrap=1",
  )
  assert_true(!r.contains("error"), msg=r)
  let q = run(s, "query-layer t1")
  assert_eq(ts_str(q, ["layer", "text"]), "Hi\nThere", msg="`\\n` 必须变成真换行")
  assert_eq(ts_str(q, ["layer", "text_style", "align"]), "center", msg="align 回读")
  assert_eq(ts_num(q, ["layer", "text_style", "line_height"]), 12.0, msg="line_height 回读")
  assert_eq(
    ts_num(q, ["layer", "text_style", "letter_spacing"]),
    2.0,
    msg="letter_spacing 回读",
  )
  assert_eq(ts_bool(q, ["layer", "text_style", "wrap"]), true, msg="wrap 回读")
  // 盒子跟着内容走：2 行 ⇒ h = fs + 1 × 行距 × sc（fs=16 ⇒ sc=2 ⇒ 12×2=24）
  assert_eq(ts_num(q, ["layer", "h"]), 16.0 + 24.0, msg="两行盒高")
  assert_eq(ts_num(q, ["layer", "w"]), 180.0, msg="显式 w 优先")
  // 老形状（没给排版）的回包**不许**出现 text_style 字段（否则老前端会看见新键）
  let r2 = run(s, "add-text id=t2 x=0 y=0 text=Hi")
  assert_true(!r2.contains("error"), msg=r2)
  let q2 = run(s, "query-layer t2")
  assert_true(
    match @core.parse_json(q2) {
      Ok(o) =>
        match o.get("layer") {
          Some(l) => l.get("text_style") is None
          None => false
        }
      Err(_) => false
    },
    msg="没有排版的层不许报 text_style：\{q2}",
  )
}

///|
test "②C 改得动：set-text 是**部分更新**（只给一个键，其余原样）" {
  let s = ts_scene("ts-set")
  let _ = run(
    s,
    "add-text id=t1 x=0 y=0 w=180 text=\"A\\nB\" align=center line_height=12 letter_spacing=2 wrap=1",
  )
  // 只改对齐：其余三个必须原样（全量重建会把没写的键悄悄退回默认）
  let r = run(s, "set-text t1 \"A\\nB\" align=right")
  assert_true(!r.contains("error"), msg=r)
  let q = run(s, "query-layer t1")
  assert_eq(ts_str(q, ["layer", "text_style", "align"]), "right", msg="align 改了")
  assert_eq(ts_num(q, ["layer", "text_style", "line_height"]), 12.0, msg="行距没被重置")
  assert_eq(ts_num(q, ["layer", "text_style", "letter_spacing"]), 2.0, msg="字距没被重置")
  assert_eq(ts_bool(q, ["layer", "text_style", "wrap"]), true, msg="wrap 没被重置")
  // 只改字距：盒子跟着新排版重算（高度不变，1 行）
  let r2 = run(s, "set-text t1 \"A\\nB\" letter_spacing=4")
  assert_true(!r2.contains("error"), msg=r2)
  let q2 = run(s, "query-layer t1")
  assert_eq(ts_num(q2, ["layer", "text_style", "letter_spacing"]), 4.0, msg="字距改了")
  assert_eq(ts_str(q2, ["layer", "text_style", "align"]), "right", msg="对齐没被重置")
  // 换字号：盒高按新 sc 重算（fs=28 ⇒ sc=4 ⇒ 2 行 = 28 + 12×4 = 76）
  let _ = run(s, "set-text t1 \"A\\nB\" font_size=28")
  let q3 = run(s, "query-layer t1")
  assert_eq(ts_num(q3, ["layer", "h"]), 76.0, msg="换字号后盒高按新 sc 重算")
}

///|
test "②C 入口判据：怪值、越界、不认识的枚举、折行没宽度，四个方向都拒" {
  let s = ts_scene("ts-rej")
  let _ = run(s, "add-text id=t1 x=0 y=0 text=Hi")
  let bad = [
    // 不认识的对齐（不许静默当 left）
    ("set-text t1 Hi align=middle", "align"),
    // 行距越界（0 与 65）与"给了小数"（字段是 Int，存 8.5 读回来只能是 8）
    ("set-text t1 Hi line_height=0", "line_height"),
    ("set-text t1 Hi line_height=65", "line_height"),
    ("set-text t1 Hi line_height=8.5", "整数"),
    // 字距越界
    ("set-text t1 Hi letter_spacing=-6", "letter_spacing"),
    ("set-text t1 Hi letter_spacing=33", "letter_spacing"),
    // 布尔值必须是 true|false|1|0
    ("set-text t1 Hi wrap=yes", "wrap"),
    // 折行必须给宽度（不给就没得折）
    ("set-text t1 Hi wrap=1", "wrap=1"),
    // 非文本层带排版键：键本身就不认
    ("add-rect x=0 y=0 w=10 h=10 align=center", "align"),
  ]
  for c in bad {
    let r = run(s, c.0)
    assert_true(
      r.contains("error") && r.contains(c.1),
      msg="`\{c.0} 必须被拒且说清 \{c.1}，实际：\{r}",
    )
  }
  // 正控：合法端点必须收（0/65 被拒而 1/64 收，否则那条判据是"一律拒绝"）
  for c in [
    "set-text t1 Hi line_height=1",
    "set-text t1 Hi line_height=64",
    "set-text t1 Hi letter_spacing=-5",
    "set-text t1 Hi letter_spacing=32",
    "set-text t1 Hi align=left",
  ] {
    let r = run(s, c)
    assert_true(!r.contains("error"), msg="`\{c} 是合法输入，不该被拒：\{r}")
  }
  // 建层时折行没宽度也要拒（与 set-text 同一句话）
  let rw = run(s, "add-text id=t9 x=0 y=0 text=Hi wrap=1")
  assert_true(rw.contains("error") && rw.contains("wrap=1"), msg=rw)
}

///|
test "②C 折行：给宽度真的换行，盒子高度跟着涨（正控 + 负控）" {
  let s = ts_scene("ts-wrap")
  // 10 个字符 × 24px = 240px > 180 ⇒ 折成 7+3 两行
  // 字号 28 ⇒ sc=4、推进 6×4=24px；盒宽 180 ⇒ 一行 7 个字符，10 个字符折成 7+3
  let r = run(s, "add-text id=t1 x=0 y=0 w=180 text=HHHHHHHHHH wrap=1 font_size=28")
  assert_true(!r.contains("error"), msg=r)
  let q = run(s, "query-layer t1")
  assert_eq(ts_num(q, ["layer", "h"]), 28.0 + 8.0 * 4.0, msg="折成两行 ⇒ 盒高 60")
  // 负控：同样的文字**不折行**时只有一行高
  let r2 = run(s, "add-text id=t2 x=0 y=0 w=180 text=HHHHHHHHHH font_size=28")
  assert_true(!r2.contains("error"), msg=r2)
  let q2 = run(s, "query-layer t2")
  assert_eq(ts_num(q2, ["layer", "h"]), 28.0, msg="不折行 ⇒ 单行盒高")
}

///|
test "②C lint：白装、对齐看不出来、非文本层带排版 —— 三条都要有人说话" {
  let s = ts_scene("ts-lint")
  // ①全默认的 text_style = 白装（渲染与 None 逐位相同）
  let _ = run(s, "add-text id=t1 x=0 y=0 text=Hi align=left line_height=8 wrap=0")
  // ②align 非默认但盒子宽度 == 内容宽度 ⇒ 对齐看不出来
  let _ = run(s, "add-text id=t2 x=0 y=0 text=Hi align=center")
  // ③正控：真的改画面（w 给宽 + align=center）⇒ lint 一个字都不许报
  let _ = run(s, "add-text id=t3 x=0 y=0 w=180 text=Hi align=center")
  let v = run(s, "lint")
  let got = match @core.parse_json(v) {
    Ok(o) => o
    Err(e) => abort("lint 回包不是 JSON（\{e}）：\{v}")
  }
  let items = match got.get("items") {
    Some(@core.JArr(a)) => a
    _ => abort("lint 回包缺 items：\{v}")
  }
  let mut t1_hit = false
  let mut t2_hit = false
  let mut t3_hit = false
  for it in items {
    let line = match it {
      @core.JStr(s) => s
      _ => ""
    }
    if line.contains("t1") && line.contains("text_style") {
      t1_hit = true
    }
    if line.contains("t2") && line.contains("align") {
      t2_hit = true
    }
    if line.contains(" t3 ") {
      t3_hit = true
    }
  }
  assert_true(t1_hit, msg="全默认的 text_style 是白装，lint 必须报：\{v}")
  assert_true(t2_hit, msg="align=center 但盒子等于内容宽度，lint 必须报：\{v}")
  assert_true(!t3_hit, msg="真改画面的排版不该被报（正控）：\{v}")
}

///|
test "②C 手改容器：非文本层带 text_style 由 lint 兜住（命令面拒在键上）" {
  let s = ts_scene("ts-junk")
  let _ = run(s, "add-rect id=r1 x=0 y=0 w=40 h=40 fill=#FF0000FF")
  // 命令面：`set-style` 的键表里没有排版键
  let r = run(s, "set-style r1 align=center")
  assert_true(r.contains("error"), msg="非文本层收不下 align：\{r}")
  // 手改容器（直接改层再 lint）：字段进去之后必须有人喊
  let doc = match s.doc {
    Some(d) => d
    None => abort("会话没有文档")
  }
  let mut i = 0
  let mut hit = false
  while i < doc.layers.length() {
    if doc.layers[i].id == "r1" {
      doc.layers[i] = {
        ..doc.layers[i],
        text_style: Some({ ..@core.text_neutral_style(), align: @core.TextAlign::Right }),
      }
      hit = true
    }
    i = i + 1
  }
  assert_true(hit, msg="场景里应该有 r1")
  let v = run(s, "lint")
  assert_true(
    v.contains("r1") && v.contains("text_style"),
    msg="手改容器里的 text_style 死数据必须被 lint 报出来：\{v}",
  )
}
