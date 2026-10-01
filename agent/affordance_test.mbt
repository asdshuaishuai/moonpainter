/// census / probe 命令端到端（agent 层）：区域事实与单点归属。
///
/// 这两个命令解决的是同一件事：**区域级事实的循环依赖**——AI 得先知道
/// 「画面里有什么」才能提选择子，而定位恰是 VLM 最弱的一环。测试因此
/// 重点断言「引擎给出的数值能不能替代模型去猜」。

///|
fn b64_sel(spec : @core.SelSpec) -> String {
  @base64.encode(@utf8.encode(@core.selspec_to_json(spec)))
}

///|
fn rect_sel(x : Double, y : Double, w : Double, h : Double) -> @core.SelSpec {
  let g : @core.GeoWindow = { x, y, w, h, feather: 0.0 }
  { basis: @core.Base, expr: @core.Atom(@core.Geo(g, "rect")) }
}

///|
fn two_tone(uuid : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 320 240 uuid=\{uuid}")
  let _ = run(s, "add-rect x=0 y=0 w=160 h=240 fill=#C81E1EFF name=left")
  let _ = run(s, "add-rect x=160 y=0 w=160 h=240 fill=#1E5ACCFF name=right")
  s
}

///|
test "census：全图 hue×sat 桶 + V 与 L 的对照" {
  let s = two_tone("census-all")
  let r = run(s, "census")
  assert_true(r.contains("\"op\":\"census\""), msg=r)
  assert_true(r.contains("\"total\":76800"), msg=r)
  assert_true(r.contains("\"counted\":76800"), msg=r)
  // 红在桶 0、蓝在桶 7（每桶 30°），各 38400 像素
  assert_true(r.contains("\"hue_bins\":[38400,"), msg=r)
  // V 与 L 必须并列给出，且 V 明显高于 L（V 不是感知亮度）
  assert_true(r.contains("\"hsv_v\":"), msg=r)
  assert_true(r.contains("\"sel_l\":"), msg=r)
  // 无 within 时不应出现区域字段
  assert_true(!r.contains("\"coverage\":"), msg="无 within 不应报覆盖率：\{r}")
  // 坏 within 载荷
  let e = run(s, "census within=!!!bad!!!")
  assert_true(e.contains("within 载荷 base64 解码失败"), msg=e)
  let bad_basis = "{\"basis\":\"nope\"}"
  let e2 = run(s, "census within=\{@base64.encode(@utf8.encode(bad_basis))}")
  assert_true(e2.contains("选择子基准"), msg=e2)
}

///|
test "census within：区域收窄 + 覆盖率/bbox/连通域事实" {
  let s = two_tone("census-within")
  let r = run(s, "census within=\{b64_sel(rect_sel(0.0, 0.0, 160.0, 240.0))} components=4")
  assert_true(r.contains("\"counted\":38400"), msg=r)
  assert_true(near(jnum_field(r, "coverage"), 0.5), msg=r)
  assert_true(r.contains("\"components\":1"), msg=r)
  assert_true(r.contains("\"bbox\":[0,0,159,239]"), msg=r)
  assert_true(r.contains("\"component_facts\":[{\"id\":1"), msg=r)
  // 桶被收窄到只剩红
  assert_true(r.contains("\"hue_bins\":[38400,"), msg=r)
  // components 参数坏值
  let e = run(s, "census components=abc")
  assert_true(e.contains("components=abc 不是整数"), msg=e)
}

///|
test "probe：单点邻域统计 + 逐算子 membership 与连通域 id" {
  let s = two_tone("probe-basic")
  // 编辑表：左半换色；保护右半
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: rect_sel(0.0, 0.0, 160.0, 240.0),
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [],
    note: "",
    evidence: None,
  }
  let prot : @core.Guard = {
    id: "g1",
    sel: rect_sel(160.0, 0.0, 160.0, 240.0),
    max_de: 0.001,
    max_changed_ratio: 0.0,
  }
  let prog : @core.EditProgram = { ops: [op], guards: [prot] }
  let text = @core.program_to_json(prog)
  let _ = run(s, "mvsl-set \{@base64.encode(@utf8.encode(text))}")
  // 左半：算子命中（component 1），保护断言不覆盖
  let l = run(s, "probe x=80 y=120 r=2")
  assert_true(l.contains("\"x\":80"), msg=l)
  assert_true(l.contains("\"r\":2"), msg=l)
  assert_true(
    l.contains("\"ops\":[{\"id\":\"e1\",\"layer\":\"\",\"membership\":1,\"component\":1}]"),
    msg=l,
  )
  assert_true(l.contains("\"guards\":[{\"id\":\"g1\",\"membership\":0}]"), msg=l)
  assert_true(l.contains("\"edge\":0"), msg=l)
  // 右半：算子不命中（component 0），保护断言覆盖
  let rr = run(s, "probe x=300 y=120 r=2")
  assert_true(
    rr.contains("\"ops\":[{\"id\":\"e1\",\"layer\":\"\",\"membership\":0,\"component\":0}]"),
    msg=rr,
  )
  assert_true(rr.contains("\"guards\":[{\"id\":\"g1\",\"membership\":1}]"), msg=rr)
  // 边界处（x=159/160 交界）应有明显边缘
  let edge = run(s, "probe x=160 y=120 r=1")
  assert_true(edge.contains("\"edge\":"), msg=edge)
  assert_true(!edge.contains("\"edge\":0,"), msg="交界处不应报零边缘：\{edge}")
}

///|
test "probe：参数/越界零容忍" {
  let s = two_tone("probe-err")
  let e0 = run(s, "probe")
  assert_true(e0.contains("用法：probe"), msg=e0)
  let e1 = run(s, "probe x=abc y=1")
  assert_true(e1.contains("x=abc 不是整数"), msg=e1)
  let e2 = run(s, "probe x=1 y=abc")
  assert_true(e2.contains("y=abc 不是整数"), msg=e2)
  let e3 = run(s, "probe x=1 y=1 r=abc")
  assert_true(e3.contains("r=abc 不是整数"), msg=e3)
  let e4 = run(s, "probe x=999 y=1 r=1")
  assert_true(e4.contains("超出画布"), msg=e4)
  let e5 = run(s, "probe x=1 y=1 r=99")
  assert_true(e5.contains("探针半径 99 越界"), msg=e5)
}

///|
/// 取字段的**规范字符串表示**，用于逐字段精确比对。这里不能退回子串匹配：
/// `"mean_l":0.62` 与 `"mean_l":0.6` 互相"包含"，而批量入口的全部意义
/// 恰恰是"和单点报一样的数字"（铁律 11）。
fn field_repr(j : @core.JValue, key : String) -> String {
  match j.get(key) {
    Some(@core.JValue::JNum(n)) => @core.fmt_num(n)
    Some(@core.JValue::JStr(s)) => s
    Some(@core.JValue::JBool(b)) => if b { "true" } else { "false" }
    Some(@core.JValue::JNull) => "null"
    Some(_) => "<复合>"
    None => "<无此字段>"
  }
}

///|
/// 取数组字段。用于 `ops` / `guards`——它们不能只比 `field_repr` 的 `<复合>`，
/// 那等于没比。
fn arr_of(j : @core.JValue, key : String) -> Array[@core.JValue] {
  match j.get(key) {
    Some(@core.JValue::JArr(a)) => a
    _ => abort("字段 \{key} 不是数组")
  }
}

///|
/// 给会话装一条"左半换色、保护右半"的编辑表，让 `probe` 的 `ops` / `guards`
/// 输出**非空**。空表上的"两条路报一样的值"是恒真的，测不出任何东西。
fn with_mvsl(s : @agent.Session) -> Unit {
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: rect_sel(0.0, 0.0, 160.0, 240.0),
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [],
    note: "",
    evidence: None,
  }
  let prot : @core.Guard = {
    id: "g1",
    sel: rect_sel(160.0, 0.0, 160.0, 240.0),
    max_de: 0.001,
    max_changed_ratio: 0.0,
  }
  let prog : @core.EditProgram = { ops: [op], guards: [prot] }
  let _ = run(s, "mvsl-set \{@base64.encode(@utf8.encode(@core.program_to_json(prog)))}")
}

///|
fn jparse(text : String) -> @core.JValue {
  match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
}

///|
test "probe 批量入口：同一个点在两条路上报出逐字段相同的值" {
  // 批量入口的全部意义是**省往返**，不是给出另一套数字。两条路共用同一段
  // 字段拼装（`probe_one_json`），这条把它钉住——将来有人"优化"其中一条
  // 而忘了另一条，会在这里红。
  //
  // 范围：这里只比**标量字段**（会话没装编辑表，`ops`/`guards` 都是空数组，
  // 比了也是恒真）。逐算子 membership 与连通域 id 的一致性由下面那条
  // 装了表的测试负责——批量真正会走样的地方在那里。
  let s = two_tone("probe-batch")
  let one = run(s, "probe x=5 y=5 r=3")
  let batch = run(s, "probe points=5,5 r=3")
  let oj = jparse(one)
  let bj = jparse(batch)
  let pts = match bj.get("points") {
    Some(@core.JValue::JArr(a)) => a
    _ => abort("批量应带 points 数组：\{batch}")
  }
  assert_eq(pts.length(), 1)
  let p0 = pts[0]
  for k in [
    "x", "y", "r", "color", "mean_l", "var_l", "mean_a", "mean_b", "edge",
    "edge_conf",
  ] {
    assert_eq(field_repr(p0, k), field_repr(oj, k))
  }
  // 先确认上面那圈不是在"两边都缺失"上空转
  assert_eq(field_repr(p0, "color"), "#C81E1EFF")
  assert_eq(field_repr(oj, "color"), "#C81E1EFF")
  // 信封字段各归各的：单点带 ok/op，批量带 count/r/points，且批量不带单点的 x
  assert_true(oj.get("ok") is Some(_), msg=one)
  assert_eq(field_repr(bj, "count"), "1")
  assert_true(!(bj.get("x") is Some(_)), msg="批量信封里不该有单点的 x：\{batch}")
}

///|
test "probe 批量入口：坏载荷零容忍（空/不成对/非整数/越界/超限）" {
  let s = two_tone("probe-batch-err")
  // `points=`（空值）现在被**参数校验**拒掉（此前它走不到批量分支：
  // `kv_args` 只收「键=非空值」的 token，空值被丢弃后落到单点模式，
  // 报的是用法提示）。这条锁的是"空值不会静默通过"，不是某一句文案。
  let e0 = run(s, "probe points=")
  assert_true(e0.contains("值是空的"), msg=e0)
  assert_true(e0.contains("points="), msg="报错要点名是哪个键：\{e0}")
  // 解析不出任何点（只给分隔符）
  let e0b = run(s, "probe points=;")
  assert_true(e0b.contains("没解析出任何点"), msg=e0b)
  let e1 = run(s, "probe points=5")
  assert_true(e1.contains("每段应为 x,y"), msg=e1)
  let e2 = run(s, "probe points=a,1")
  assert_true(e2.contains("不是整数"), msg=e2)
  // 批量里只要有一个点越界就整体拒绝，不许"跳过坏点给好点"
  let e3 = run(s, "probe points=5,5;999,1")
  assert_true(e3.contains("超出画布"), msg=e3)
  let mut spec = ""
  for i in 0..<65 {
    if i > 0 {
      spec = spec + ";"
    }
    spec = spec + "\{i},1"
  }
  let e4 = run(s, "probe points=\{spec}")
  assert_true(e4.contains("最多 64 个点"), msg=e4)
  assert_true(e4.contains("census"), msg="超限提示应指路 census：\{e4}")
  // x=/y= 与 points= 同时给时批量优先（字典里写明）
  let both = run(s, "probe x=1 y=1 points=5,5")
  assert_eq(field_repr(jparse(both), "count"), "1")
}

///|
test "probe 批量入口：装表之后 ops/guards 也与单点逐元素一致" {
  // **样本里必须有"这个约定存在的理由"**：批量入口会走样的地方不是 x/y/color
  // （那些一眼能看出），而是逐算子的 membership 与连通域 id——而它们只有在
  // 装了编辑表时才有内容。用空表测"两条路一致"，是又一次"用 HELLO 测空格
  // 转义协议"。这条先装表，再逐元素逐字段比。
  let s = two_tone("probe-batch-mvsl")
  with_mvsl(s)
  let one = run(s, "probe x=80 y=120 r=2")
  let batch = run(s, "probe points=80,120;300,120 r=2")
  let oj = jparse(one)
  let pts = arr_of(jparse(batch), "points")
  assert_eq(pts.length(), 2)
  for k in [
    "x", "y", "r", "color", "mean_l", "var_l", "mean_a", "mean_b", "edge",
    "edge_conf",
  ] {
    assert_eq(field_repr(pts[0], k), field_repr(oj, k))
  }
  // ops：逐元素逐字段
  let ops_one = arr_of(oj, "ops")
  let ops_b = arr_of(pts[0], "ops")
  assert_eq(ops_one.length(), 1)
  assert_eq(ops_b.length(), 1)
  for i in 0..<ops_one.length() {
    for k in ["id", "membership", "component"] {
      assert_eq(field_repr(ops_b[i], k), field_repr(ops_one[i], k))
    }
  }
  // guards：同上
  let g_one = arr_of(oj, "guards")
  let g_b = arr_of(pts[0], "guards")
  assert_eq(g_one.length(), 1)
  assert_eq(g_b.length(), 1)
  for i in 0..<g_one.length() {
    for k in ["id", "membership"] {
      assert_eq(field_repr(g_b[i], k), field_repr(g_one[i], k))
    }
  }
  // 上面比的是"两项相同"，得先确认这些字段**不是处处相同**：批量里第二个点
  // 在右半，membership 与连通域 id 都该和第一个点不一样。
  assert_eq(field_repr(ops_one[0], "component"), "1")
  assert_eq(field_repr(ops_one[0], "membership"), "1")
  let ops_b2 = arr_of(pts[1], "ops")
  assert_eq(field_repr(ops_b2[0], "component"), "0")
  assert_eq(field_repr(ops_b2[0], "membership"), "0")
  // guards 在右半是覆盖的（membership 1），左半不覆盖（0）
  assert_eq(field_repr(arr_of(pts[1], "guards")[0], "membership"), "1")
  assert_eq(field_repr(g_one[0], "membership"), "0")
}
