// 图层样式（fx）**命令面**这一半：`set-fx`。
//
// 与 core（参数判据/契约档）和 render（像素/裁剪）分开钉：这边管"AI 与人类
// 能怎么用"——键认不认得出、值收不收得下、缺的参数补成什么、改不改得动、
// 报不报得出、装了却什么都不干有没有人说话。铁律 11：数值断言精确解析，
// 不许 `contains("shadow(")` 这种只咬措辞的写法。

///|
/// `query-layer` 回的 `layer.fx` 字符串（缺字段就 abort，不静默）。
fn fx_of_layer(text : String) -> String {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  let l = match obj.get("layer") {
    Some(v) => v
    None => abort("回包缺 layer：\{text}")
  }
  let f = match l.get("fx") {
    Some(v) => v
    None => abort("query-layer 没报 fx 字段：\{text}")
  }
  match f.as_str() {
    Some(x) => x
    None => abort("fx 不是字符串：\{text}")
  }
}

///|
/// 命令回包里的 `fx` 字段（`set-fx` 自己回显的那份）。
fn fx_of_reply(text : String) -> String {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  match obj.get("fx") {
    Some(v) =>
      match v.as_str() {
        Some(x) => x
        None => abort("fx 不是字符串：\{text}")
      }
    None => abort("回包缺 fx：\{text}")
  }
}

///|
fn fx_scene(uuid : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 80 60 uuid=\{uuid}")
  let _ = run(s, "add-rect id=r1 x=10 y=10 w=30 h=20 fill=#3366FFFF")
  s
}

///|
test "set-fx：键一门清（拼错/裸词/空值/一个参数都不给都拒绝），值也要收得下" {
  let s = fx_scene("fx-keys")
  // 零参数：什么都不改 ⇒ 报用法（不是静默 ok）
  let e0 = run(s, "set-fx r1")
  assert_true(e0.has_prefix("{\"error\":\""), msg="一个参数都不给要报错：\{e0}")
  assert_true(e0.contains("clear=1"), msg="用法串要指路：\{e0}")
  // 拼错的键：kv_args 会静默丢掉它 ⇒ 必须由 check_kv_args 拦下并给合法清单
  let e1 = run(s, "set-fx r1 shadow_dxx=3")
  assert_true(e1.has_prefix("{\"error\":\""), msg="拼错的键要报错：\{e1}")
  assert_true(e1.contains("shadow_dx"), msg="要给出合法键清单：\{e1}")
  // 裸词（漏了 `=`）
  let e2 = run(s, "set-fx r1 shadow")
  assert_true(e2.has_prefix("{\"error\":\""), msg="裸词要报错：\{e2}")
  // 空值
  let e3 = run(s, "set-fx r1 shadow_dx=")
  assert_true(e3.has_prefix("{\"error\":\""), msg="空值要报错：\{e3}")
  // 非数不许静默退默认（铁律 11 那条）
  let e4 = run(s, "set-fx r1 shadow_dx=abc")
  assert_true(e4.has_prefix("{\"error\":\""), msg="非数要报错：\{e4}")
  assert_true(e4.contains("shadow_dx=abc"), msg="要回显收到的值：\{e4}")
  // 布尔只收 true/false/1/0
  let e5 = run(s, "set-fx r1 shadow=yes")
  assert_true(e5.has_prefix("{\"error\":\""), msg="布尔要报错：\{e5}")
  // 颜色：合法收下、非法拒绝
  let e6 = run(s, "set-fx r1 shadow_color=#GGGGGG")
  assert_true(e6.has_prefix("{\"error\":\""), msg="非法颜色要报错：\{e6}")
  assert_true(e6.contains("#RRGGBB"), msg="要说清颜色写法：\{e6}")
  // 层不存在
  let e7 = run(s, "set-fx nope shadow=1")
  assert_true(e7.has_prefix("{\"error\":\"层不存在"), msg=e7)
}

///|
test "set-fx：部分更新（给了的改、没给的沿用它自己），回包与 query-layer 说同一件事" {
  let s = fx_scene("fx-partial")
  // 缺省底 = default_fx（四件全关、参数是缺省 4/4/4）
  let r1 = run(s, "set-fx r1 shadow=1")
  assert_true(r1.has_prefix("{\"ok\":true"), msg=r1)
  assert_eq(
    fx_of_reply(r1),
    "shadow(4,4,4,#00000080)",
    msg="只开开关 ⇒ 用缺省偏移/模糊/颜色：\{r1}",
  )
  // 键序无关：改一个数不许把别的键带上或丢掉
  let r2 = run(s, "set-fx r1 shadow_dx=-9")
  assert_eq(
    fx_of_reply(r2),
    "shadow(-9,4,4,#00000080)",
    msg="部分更新要保留没给的键：\{r2}",
  )
  // 再开一件：两件都在（互不干扰）
  let r3 = run(s, "set-fx r1 outline=1 outline_w=7.5 outline_color=#FF0000")
  assert_eq(
    fx_of_reply(r3),
    "shadow(-9,4,4,#00000080),outline(7.5,#FF0000FF)",
    msg="第二件不许把第一件冲掉；#RRGGBB 补齐成 #RRGGBBAA（不透明）：\{r3}",
  )
  // 关掉一件：它从报告里消失，但**参数留着**（再打开还是 7.5）
  let r4 = run(s, "set-fx r1 outline=0")
  assert_eq(fx_of_reply(r4), "shadow(-9,4,4,#00000080)", msg="关掉的那件不再报：\{r4}")
  let r5 = run(s, "set-fx r1 outline=1")
  assert_eq(
    fx_of_reply(r5),
    "shadow(-9,4,4,#00000080),outline(7.5,#FF0000FF)",
    msg="重新打开要还是原来那些参数：\{r5}",
  )
  // query-layer 读回来的与回包一致（"能改就要能读"）
  let q = run(s, "query-layer r1")
  assert_eq(fx_of_layer(q), fx_of_reply(r5), msg="回读与回显必须说同一件事：\{q}")
  // 四件全开时的报告格式（每件自己的参数、颜色走 #RRGGBBAA）
  let r6 = run(
    s,
    "set-fx r1 glow=1 glow_radius=12 glow_color=#FFD70080 inner=1 inner_dx=3 inner_dy=-3 inner_blur=6 inner_color=#00000080",
  )
  assert_eq(
    fx_of_reply(r6),
    "shadow(-9,4,4,#00000080),outline(7.5,#FF0000FF),glow(12,#FFD70080),inner(3,-3,6,#00000080)",
    msg="四件全开的报告（顺序固定 = 渲染顺序）：\{r6}",
  )
}

///|
test "set-fx：clear=1 摘掉整份样式，且与其它键不能同时给" {
  let s = fx_scene("fx-clear")
  // 本来就没有样式 ⇒ clear 也要报错（不是静默成功：那会让调用方以为摘掉了）
  let e0 = run(s, "set-fx r1 clear=1")
  assert_true(e0.has_prefix("{\"error\":\""), msg="没有样式时 clear 要报错：\{e0}")
  let _ = run(s, "set-fx r1 shadow=1")
  assert_eq(fx_of_layer(run(s, "query-layer r1")), "shadow(4,4,4,#00000080)")
  let e1 = run(s, "set-fx r1 clear=1 shadow_dx=8")
  assert_true(e1.has_prefix("{\"error\":\""), msg="clear 与其它键同时给要报错：\{e1}")
  let r = run(s, "set-fx r1 clear=1")
  assert_true(r.has_prefix("{\"ok\":true"), msg=r)
  assert_eq(fx_of_reply(r), "none", msg="摘掉后回包说 none：\{r}")
  assert_eq(fx_of_layer(run(s, "query-layer r1")), "none", msg="回读也说 none")
  // 摘掉之后还能再装上（摘干净了：参数不残留）
  let r2 = run(s, "set-fx r1 shadow=1")
  assert_eq(fx_of_reply(r2), "shadow(4,4,4,#00000080)", msg="重装回到缺省值：\{r2}")
}

///|
test "set-fx：取值判据（负半径拒、NaN 拒、上限 64、dx/dy 可负）与同一句判据" {
  let s = fx_scene("fx-range")
  // 上限：65 拒、64 收
  let e0 = run(s, "set-fx r1 shadow_blur=65")
  assert_true(e0.has_prefix("{\"error\":\""), msg="超上限要拒：\{e0}")
  assert_true(e0.contains("64"), msg="要说清上限是 64：\{e0}")
  let ok0 = run(s, "set-fx r1 shadow_blur=64")
  assert_true(ok0.has_prefix("{\"ok\":true"), msg="正好 64 要收下：\{ok0}")
  // 负数拒（半径/宽度不能为负）
  let e1 = run(s, "set-fx r1 outline_w=-1")
  assert_true(e1.has_prefix("{\"error\":\""), msg="负宽度要拒：\{e1}")
  let e2 = run(s, "set-fx r1 glow_radius=-0.5")
  assert_true(e2.has_prefix("{\"error\":\""), msg="负半径要拒：\{e2}")
  let e3 = run(s, "set-fx r1 inner_blur=-3")
  assert_true(e3.has_prefix("{\"error\":\""), msg="负模糊要拒：\{e3}")
  // dx/dy 可以是负的（那就往左上偏）
  let ok1 = run(s, "set-fx r1 shadow_dx=-20 shadow_dy=-20 inner_dx=-4")
  assert_true(ok1.has_prefix("{\"ok\":true"), msg="偏移可负：\{ok1}")
  // NaN / inf：`to_d` 拦下（`arg_d` 那条纪律）
  let e4 = run(s, "set-fx r1 shadow_blur=nan")
  assert_true(e4.has_prefix("{\"error\":\""), msg="nan 要拒：\{e4}")
  let e5 = run(s, "set-fx r1 shadow_blur=inf")
  assert_true(e5.has_prefix("{\"error\":\""), msg="inf 要拒：\{e5}")
  // 值 0 是**合法**的（那是"这一件画不出东西"，交给 lint 报——入口不拦，
  // 同 `adjust value=0` 那条分工）
  let ok2 = run(s, "set-fx r1 outline=1 outline_w=0")
  assert_true(ok2.has_prefix("{\"ok\":true"), msg="宽度 0 合法（lint 会说它不干活）：\{ok2}")
  let l = run(s, "lint")
  assert_true(l.contains("描边开关开着却画不出"), msg="宽度 0 要由 lint 报：\{l}")
}

///|
test "set-fx：调整层装不了样式（同一格 kind 表），摘得掉手改塞进去的 fx" {
  let s = fx_scene("fx-kind")
  let _ = run(s, "add-adjust id=a1 op=brightness value=0.3")
  // 入口拒绝，并且要指路（"调整层没有自己的像素"）
  let e = run(s, "set-fx a1 shadow=1")
  assert_true(e.has_prefix("{\"error\":\""), msg="调整层要拒：\{e}")
  assert_true(
    e.contains("调整层") && e.contains("自己的像素"),
    msg="要说清为什么（调整层没有自己的像素）：\{e}",
  )
  // 能力表（人侧画控件照着它走）：几何层有 fx、调整层没有。
  // ⚠️ 判据要打**caps 数组**上，不能拿整条回包 `contains("\"fx\"")`——
  // 每条层的报告里都有一个 `"fx":"none"` 字段，那种写法对"没有能力"也成立。
  assert_true(caps_str(s, "r1").contains("fx"), msg="几何层的 caps 要有 fx：\{caps_str(s, "r1")}")
  assert_eq(
    caps_str(s, "a1").contains("fx"),
    false,
    msg="调整层的 caps 不许有 fx：\{caps_str(s, "a1")}",
  )
  // 手改容器给调整层塞了一份样式：lint 要报（kind 那一格），而 `clear=1`
  // 必须仍摘得掉——"能打上的名字必须能摘下"（否则那个字段永远洗不掉）
  let doc = @core.new_document("fx-hand", 80, 60)
  doc.layers.push({
    ..@core.default_layer("a9", "a", 0.0, 0.0, 80.0, 60.0),
    kind: @core.ShapeKind::Adjust,
    adjust: Some(@core.Adjust::{ op: @core.AdjustOp::Brightness, value: 0.3, levels: None, curve: [] }),
    fx: Some({ ..@core.default_fx(), shadow: true }),
  })
  let v = @agent.lint_doc(doc)
  assert_true(
    v.filter(fn(x) { x.contains("fx 字段") }).length() == 1,
    msg="手改容器里调整层带 fx 要报一条（kind 那格）：\{v.join(" | ")}",
  )
  // 正控：同样的 fx 挂在矩形上，一个字都不报
  let doc2 = @core.new_document("fx-hand-ok", 80, 60)
  doc2.layers.push({
    ..@core.default_layer("r9", "r", 0.0, 0.0, 30.0, 20.0),
    fx: Some({ ..@core.default_fx(), shadow: true }),
  })
  assert_eq(@agent.lint_doc(doc2).length(), 0, msg="矩形上装样式不该报任何违规")
}

///|
test "set-fx：lint 逐件说清「开关开着却画不出像素」与「四个全关」" {
  let s = fx_scene("fx-lint")
  // 四件全关（挂着一份空样式）：画面逐位不变 ⇒ 报"全关"那句
  let r0 = run(s, "set-fx r1 glow_radius=8")
  assert_true(r0.has_prefix("{\"ok\":true"), msg=r0)
  assert_eq(fx_of_reply(r0), "all-off", msg="四个开关全关要报 all-off：\{r0}")
  let l0 = run(s, "lint")
  assert_eq(jnum_field(l0, "violations"), 1.0, msg="全关要报一条：\{l0}")
  assert_true(l0.contains("四个开关全关着"), msg=l0)
  // 逐件：每件都给一个"开着但画不出"的配置，报出来的名字必须**是那一件**
  let cases : Array[(String, String)] = [
    ("shadow=1 shadow_dx=0 shadow_dy=0 shadow_blur=0", "投影"),
    ("shadow=0 outline=1 outline_w=0.5", "描边"),
    ("outline=0 glow=1 glow_radius=0.5", "外发光"),
    ("glow=0 inner=1 inner_dx=0 inner_dy=0 inner_blur=0", "内阴影"),
    ("inner=0 shadow=1 shadow_dx=8 shadow_color=#00000000", "投影"),
  ]
  for c in cases {
    let _ = run(s, "set-fx r1 " + c.0)
    let l = run(s, "lint")
    assert_true(
      l.contains(c.1 + "开关开着却画不出"),
      msg="这一件要指名道姓（\{c.0}）：\{l}",
    )
    // 只报那一条（没开的不许跟着喊）
    assert_eq(jnum_field(l, "violations"), 1.0, msg="只该报一条：\{c.0} → \{l}")
  }
  // 正控：一件真的画得出来 ⇒ 一个字都不报
  let _ = run(s, "set-fx r1 clear=1")
  let _ = run(s, "set-fx r1 shadow=1 shadow_dx=6 shadow_blur=0")
  let l2 = run(s, "lint")
  assert_eq(jnum_field(l2, "violations"), 0.0, msg="真样式不许报：\{l2}")
}
