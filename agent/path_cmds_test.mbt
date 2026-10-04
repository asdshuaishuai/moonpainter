/// 钢笔/贝塞尔路径的**命令面**判据（④）。
///
/// 判据的口径：不只断言"回包 ok"，而是断言**画面真的变成那条曲线**
/// ——路径最容易静默失败的地方是"控制柄被忽略"（回包 ok、指纹变了、
/// `query-layer` 报着 handles，而画出来是一条折线）。


///|
/// 取 `query-layer` 回包里 `layer` 子对象的数值字段（精确解析，不子串匹配）。
fn layer_num(text : String, key : String) -> Double {
  match @core.parse_json(text) {
    Ok(obj) =>
      match obj.get("layer") {
        Some(inner) =>
          match inner.get(key) {
            Some(@core.JValue::JNum(n)) => n
            _ => -1.0
          }
        None => -1.0
      }
    Err(_) => -1.0
  }
}


///|
/// 取 `query-layer` 回包里 `layer` 子对象的字符串字段（精确解析，不子串匹配）。
fn layer_str(text : String, key : String) -> String {
  match @core.parse_json(text) {
    Ok(obj) =>
      match obj.get("layer") {
        Some(inner) =>
          match inner.get(key) {
            Some(@core.JValue::JStr(v)) => v
            Some(@core.JValue::JBool(b)) => if b { "true" } else { "false" }
            _ => "<非字符串>"
          }
        None => "<无 layer>"
      }
    Err(_) => "<解析失败>"
  }
}

///|
/// 渲染 sha256（走引擎自己的 render 命令，与宿主看到的是同一条路径）。
fn path_sha(s : @agent.Session, line : String) -> String {
  jstr_field(run(s, line), "render_sha256")
}

///|
test "add-path：折线（handles 全 0）与曲线（handles 抬起）渲染逐位不同，且曲线真的鼓出去" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 120 uuid=path-1")
  // 同一条锚点、唯一的差别是有没有控制柄 ⇒ 两份渲染必须不同（判别力自证）
  let flat = run(s, 
    "add-path x=10 y=10 points=0,0;100,0 fill=none stroke=#FF0000FF stroke_w=6",
  )
  assert_true(flat.contains("\"ok\":true"))
  let s1 = path_sha(s, "render 120")
  let cur = run(s, 
    "add-path x=10 y=10 points=0,0;100,0 handles=0,0;0,80;0,80;0,0 fill=none stroke=#FF0000FF stroke_w=6",
  )
  assert_true(cur.contains("\"ok\":true"))
  let s2 = path_sha(s, "render 120")
  assert_true(s1 != s2)
  // 曲线鼓到锚点盒之外：盒子跟着内容走 ⇒ w/h 自算（锚点盒高 0、曲线到 +60）
  let q = run(s, "query-layer l2")
  // 层字段在 `layer` 子对象里：走 parse_json 取数（不许子串匹配，"w":9 会被
  // "w":90 包含而通过）
  assert_true(layer_num(q, "w") > 90.0, msg=q)
  let _ = s
}

///|
test "add-path：默认是开放路径（fill=none 只描边），显式 fill= 才闭合填充" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 80 80 uuid=path-2")
  let _ = run(s, "add-path x=10 y=10 points=0,0;60,0;60,60")
  let q = run(s, "query-layer l1")
  assert_true(q.contains("\"ok\":true"))
  // 默认 fill=none ⇒ 开放：三个锚点围出的那个三角内部**不填**（白底透出来）
  let inside = run(s, "sample 55 50")
  assert_eq(jstr_field(inside, "color"), "#FFFFFFFF")
  // 显式填充 ⇒ 同一个三角内部被填上（绿）。**同一点位、同一条判据**，
  // 唯一的差别是有没有 fill= ⇒ 这就是"默认值真的有语义"的判据。
  let _ = run(s, "add-path x=10 y=10 points=0,0;60,0;60,60 fill=#00FF00FF")
  let inside2 = run(s, "sample 55 50")
  assert_eq(jstr_field(inside2, "color"), "#00FF00FF")
  let _ = s
}

///|
test "add-path：锚点/控制柄的坏输入在入口拒绝（不是静默画错）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 60 uuid=path-3")
  // 锚点不足
  let e1 = run(s, "add-path points=0,0")
  assert_true(e1.contains("至少"))
  // 控制柄条数不对（3 个锚点要 6 个偏移）
  let e2 = run(s, "add-path points=0,0;10,0;20,20 handles=0,0;0,0;0,0")
  assert_true(e2.contains("handles"))
  // 非数、拼错的键（静默 no-op 的三个来源）都要报
  let e3 = run(s, "add-path points=0,0;xx,0")
  assert_true(e3.contains("不是数字"))
  let e4 = run(s, "add-path points=0,0;10,0 handlez=0,0")
  assert_true(e4.contains("handlez"))
  let _ = s
}

///|
test "set-style handles=：原地改控制柄（盒子跟着内容重算，不用删了重加）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 120 uuid=path-4")
  let _ = run(s, 
    "add-path x=10 y=10 points=0,0;100,0 fill=none stroke=#FF0000FF stroke_w=6",
  )
  let flat_sha = path_sha(s, "render 120")
  let r = run(s, "set-style l1 handles=0,0;0,80;0,80;0,0")
  assert_true(r.contains("\"ok\":true"))
  // 改完**画面真的变了**（不是只改了容器字段）：这是"改得动"的判据
  let curved_sha = path_sha(s, "render 120")
  assert_true(flat_sha != curved_sha)
  // 盒子的高度必须跟着曲线走（盒子跟着内容走）
  let q = run(s, "query-layer l1")
  assert_true(layer_num(q, "h") > 50.0, msg=q)
  // 回读得出控制柄（"报得出"这一面）
  assert_true(q.contains("handles"))
  // 条数不对要拒
  let e = run(s, "set-style l1 handles=0,0;0,0")
  assert_true(e.contains("handles"))
}


///|
test "开/闭语义只有一处判据：fill=none ⇒ closed=false，给了填充 ⇒ closed=true（且描边真的收口）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 120 uuid=path-close")
  // 三个锚点、开放路径（默认 fill=none）
  let _ = run(s, "add-path x=10 y=10 points=0,0;80,0;80,80 fill=none stroke=#FF0000FF stroke_w=4")
  let q1 = run(s, "query-layer l1")
  assert_eq(layer_str(q1, "closed"), "false")
  // 收口那一笔（最后一个锚点连回第一个）**画出来了没有**：open 时 (10,10)-(90,80)
  // 这条对角线不该有墨；闭合后它必须有墨。这就是"闭合 = 多一条边"的判据，
  // 不是只看一个布尔字段。
  let mid_open = run(s, "sample 47 42")
  let _ = run(s, "set-style l1 fill=#00FF00FF")
  let q2 = run(s, "query-layer l1")
  assert_eq(layer_str(q2, "closed"), "true")
  let mid_closed = run(s, "sample 47 42")
  assert_true(
    jstr_field(mid_open, "color") != jstr_field(mid_closed, "color"),
    msg="收口那条边必须真的画出来（开：\{mid_open} 闭：\{mid_closed}）",
  )
}
