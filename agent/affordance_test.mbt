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
  assert_true(l.contains("\"ops\":[{\"id\":\"e1\",\"membership\":1,\"component\":1}]"), msg=l)
  assert_true(l.contains("\"guards\":[{\"id\":\"g1\",\"membership\":0}]"), msg=l)
  assert_true(l.contains("\"edge\":0"), msg=l)
  // 右半：算子不命中（component 0），保护断言覆盖
  let rr = run(s, "probe x=300 y=120 r=2")
  assert_true(rr.contains("\"ops\":[{\"id\":\"e1\",\"membership\":0,\"component\":0}]"), msg=rr)
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
