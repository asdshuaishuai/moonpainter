// 自由变换 `transform`（⑤C 的引擎侧）：位置 + 盒子 + 旋转**一次**写完。
//
// 它存在的**唯一理由**是"一个手势 = 一步历史"：`move`+`resize`+`rotate` 分开发
// 是三步，撤销要按三次（PS 的自由变换是一步）。所以这里的判据不止"值写对了"，
// 还要咬住 **`edits` 只涨一条**、**`undo` 一次回到原样**。
//
// 判据分四组：
//   ① 值：五个键都真的写进去了（精确解析，不子串匹配）；
//   ② 部分更新：只给 x/y 时 w/h/rot 一个都不许动（"给了才改"）；
//   ③ 一步历史：`edits` +1、`undo` 一次全回去；
//   ④ 入口：什么都不给要**报错**（空动作）、w/h 必须为正、
//      `rot` 走与 `rotate` 同一条 kind 门禁（调整层上写非默认 rot 要拒）。

///|
fn tf_edit_count(s : @agent.Session) -> Int {
  let obj = match @core.parse_json(run(s, "edits")) {
    Ok(o) => o
    Err(e) => abort("edits 不是 JSON：\{e}")
  }
  match obj.get("count") {
    Some(@core.JValue::JNum(n)) => n.to_int()
    _ => abort("edits 缺 count")
  }
}

///|
test "transform：五个键一次写完（位置/盒子/旋转），回包与回读一致" {
  let s = scene("tf-all")
  let _ = run(s, "add-rect id=r x=10 y=10 w=20 h=10")
  let r = run(s, "transform r x=30 y=25 w=40 h=20 rot=15")
  assert_true(r.has_prefix("{\"ok\":true,\"op\":\"transform\""), msg=r)
  let q = run(s, "query-layer r")
  assert_true(layer_num(q, "x") == 30.0, msg="x 没写进去：\{q}")
  assert_true(layer_num(q, "y") == 25.0, msg="y 没写进去：\{q}")
  assert_true(layer_num(q, "w") == 40.0, msg="w 没写进去：\{q}")
  assert_true(layer_num(q, "h") == 20.0, msg="h 没写进去：\{q}")
  assert_true(layer_num(q, "rot") == 15.0, msg="rot 没写进去：\{q}")
}

///|
test "transform：部分更新——只给的键才改（其余一个都不许动）" {
  let s = scene("tf-partial")
  let _ = run(s, "add-rect id=r x=10 y=10 w=20 h=10")
  let _ = run(s, "transform r rot=45")
  let q1 = run(s, "query-layer r")
  assert_true(
    layer_num(q1, "x") == 10.0 &&
    layer_num(q1, "y") == 10.0 &&
    layer_num(q1, "w") == 20.0 &&
    layer_num(q1, "h") == 10.0 &&
    layer_num(q1, "rot") == 45.0,
    msg="只给了 rot，几何不该动：\{q1}",
  )
  let _ = run(s, "transform r x=50 y=60")
  let q2 = run(s, "query-layer r")
  assert_true(
    layer_num(q2, "x") == 50.0 &&
    layer_num(q2, "y") == 60.0 &&
    layer_num(q2, "w") == 20.0 &&
    layer_num(q2, "h") == 10.0 &&
    layer_num(q2, "rot") == 45.0,
    msg="只给了 x/y，盒子与旋转都该保持：\{q2}",
  )
}

///|
test "transform：一个手势 = 一步历史（edits 只涨一条，undo 一次全回去）" {
  let s = scene("tf-one-step")
  let _ = run(s, "add-rect id=r x=10 y=10 w=20 h=10")
  let fp0 = run(s, "fingerprint")
  let n0 = tf_edit_count(s)
  let _ = run(s, "transform r x=30 y=25 w=40 h=20 rot=15")
  let n1 = tf_edit_count(s)
  assert_true(n1 == n0 + 1, msg="一次 transform 应该只涨一条历史：\{n0} → \{n1}")
  let _ = run(s, "undo")
  let q = run(s, "query-layer r")
  assert_true(
    layer_num(q, "x") == 10.0 &&
    layer_num(q, "y") == 10.0 &&
    layer_num(q, "w") == 20.0 &&
    layer_num(q, "h") == 10.0 &&
    layer_num(q, "rot") == 0.0,
    msg="undo 一次就要回到变换前（位置/盒子/旋转一起回）：\{q}",
  )
  assert_true(run(s, "fingerprint") == fp0, msg="undo 后的指纹必须与变换前逐字节相同")
}

///|
test "transform：空动作 / 非数 / 非正盒子 / 调整层上的旋转都在入口被拒" {
  let s = scene("tf-reject")
  let _ = run(s, "add-rect id=r x=10 y=10 w=20 h=10")
  let _ = run(s, "add-adjust id=a1 op=brightness value=0.5")
  // 计数从**这一切就绪之后**开始：只数下面那一条成功的 `transform a1 rot=0`
  let n0 = tf_edit_count(s)
  // ① 什么都不给 = 空动作（回 ok 而什么都没做是最坏的一种）
  let e1 = run(s, "transform r")
  assert_true(e1.contains("\"error\":") && e1.contains("至少要给一个键"), msg=e1)
  // ② 认不出来的键（拼错/多一个空格）要被入口说出来，而不是静默丢掉
  let e2 = run(s, "transform r xx=5")
  assert_true(e2.contains("\"error\":") && e2.contains("xx"), msg=e2)
  // ③ 给了但不是数
  let e3 = run(s, "transform r w=abc")
  assert_true(e3.contains("\"error\":") && e3.contains("不是数字"), msg=e3)
  // ④ w/h 必须为正（与 `resize` 同一句话）
  let e4 = run(s, "transform r w=0")
  assert_true(e4.contains("\"error\":") && e4.contains("必须为正"), msg=e4)
  let e5 = run(s, "transform r h=-3")
  assert_true(e5.contains("\"error\":") && e5.contains("必须为正"), msg=e5)
  // ⑤ 调整层上写**非默认**旋转：与 `rotate` 同一条 kind 门禁
  let e6 = run(s, "transform a1 rot=30")
  assert_true(e6.contains("\"error\":") && e6.contains("rotation_deg"), msg=e6)
  // 清字段的写法照过（写默认值 = 把旧容器洗回来）
  let ok1 = run(s, "transform a1 rot=0")
  assert_true(ok1.has_prefix("{\"ok\":true,\"op\":\"transform\""), msg=ok1)
  // 但**别的一格都不许跟着被改**：一条被拒的命令不能留下半截效果
  let q = run(s, "query-layer r")
  assert_true(
    layer_num(q, "x") == 10.0 &&
    layer_num(q, "y") == 10.0 &&
    layer_num(q, "w") == 20.0 &&
    layer_num(q, "h") == 10.0,
    msg="被拒的命令改了别的东西：\{q}",
  )
  // edits：五条被拒的都没记历史，两条成功的（a1 rot=0）才记
  let n1 = tf_edit_count(s)
  assert_true(n1 == n0 + 1, msg="被拒的命令不该进历史：\{n0} → \{n1}")
}

///|
test "transform：组是搬整棵子树（只改盒子 = 回 ok 而画面不动）" {
  let s = scene("tf-group")
  let _ = run(s, "add-rect id=c1 x=20 y=20 w=30 h=30")
  let _ = run(s, "add-rect id=c2 x=60 y=20 w=30 h=30")
  let _ = run(s, "group grp c1 c2")
  let r = run(s, "transform grp x=100 y=100")
  assert_true(r.contains("\"moved_layers\":3"), msg="组的 transform 该报搬了几层：\{r}")
  let q1 = run(s, "query-layer c1")
  let q2 = run(s, "query-layer c2")
  assert_true(
    layer_num(q1, "x") == 100.0 && layer_num(q1, "y") == 100.0,
    msg="子层 c1 该跟着搬：\{q1}",
  )
  assert_true(
    layer_num(q2, "x") == 140.0 && layer_num(q2, "y") == 100.0,
    msg="子层 c2 该跟着搬：\{q2}",
  )
}
