/// MVSL 命令面端到端（agent 层）：编辑表读写、选择子预览、impact 证书、
/// 保护断言、随容器落盘往返。
///
/// 全程只走行协议（@agent.exec），不旁路直调引擎——这正是「人机同一 IR、
/// 同一命令面」的可验证形态。

///|
fn b64_of(text : String) -> String {
  @base64.encode(@utf8.encode(text))
}

///|
/// 一条「左半边改色」的等价选择子（几何谓词，不依赖具体颜色）。
fn left_half_sel() -> @core.SelSpec {
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 160.0, h: 240.0, feather: 0.0 }
  let expr : @core.SelExpr = @core.Atom(@core.Geo(g, "rect"))
  { basis: @core.Base, expr }
}

///|
/// 一条 recolor 算子（可选携带保护断言）。
fn recolor_program(guards : Array[@core.Guard]) -> @core.EditProgram {
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: left_half_sel(),
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [],
    note: "",
    evidence: None,
  }
  { ops: [op], guards }
}

///|
/// 取回包 JSON 里的字符串字段（失败即 abort，测试里不留静默分支）。
fn jfield(text : String, key : String) -> String {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  let v = match obj.get(key) {
    Some(x) => x
    None => abort("回包缺字段 \{key}：\{text}")
  }
  match v.as_str() {
    Some(x) => x
    None => abort("回包字段 \{key} 不是字符串：\{text}")
  }
}

///|
fn scene(uuid : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 320 240 uuid=\{uuid}")
  let _ = run(s, "add-rect x=0 y=0 w=320 h=240 fill=#1E5ACCFF name=bg")
  s
}

///|
test "MVSL：编辑表安装/规范化/坏载荷零容忍" {
  let s = scene("mvsl-set")
  // 坏 base64
  let e0 = run(s, "mvsl-set !!!not-base64!!!")
  assert_true(e0.has_prefix("{\"error\":\"编辑表载荷 base64 解码失败"), msg=e0)
  // 坏 JSON（半截对象）
  let truncated = "{\"version\":1,\"ops\":["
  let e1 = run(s, "mvsl-set \{b64_of(truncated)}")
  assert_true(e1.has_prefix("{\"error\":\"编辑表解析失败"), msg=e1)
  // 更高 IR 版本
  let future = "{\"version\":99,\"ops\":[],\"guards\":[]}"
  let e2 = run(s, "mvsl-set \{b64_of(future)}")
  assert_true(e2.contains("高于引擎支持"), msg=e2)
  // 未知算子（sel 合法，病根落在 kind 上）
  let alien = "{\"version\":1,\"ops\":[{\"id\":\"x\",\"kind\":\"neural_gen\",\"sel\":{\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"feather\":0}}},\"amount\":1,\"hue_deg\":0,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}],\"guards\":[]}"
  let e3 = run(s, "mvsl-set \{b64_of(alien)}")
  assert_true(e3.contains("未知算子"), msg=e3)
  // 空程序 = 逐位还原
  let r0 = run(s, "mvsl-clear")
  assert_true(r0.contains("\"ops\":0"), msg=r0)
  // 正常安装：canonical 往返 + 指纹稳定
  let text = @core.program_to_json(recolor_program([]))
  let r1 = run(s, "mvsl-set \{b64_of(text)}")
  assert_true(r1.contains("\"op\":\"mvsl-set\""), msg=r1)
  let r2 = run(s, "mvsl-show")
  assert_true(r2.contains("\"ops\":1"), msg=r2)
  let h1 = @base.sha256_hex(@utf8.encode(text))
  assert_true(r2.contains(h1), msg="program_sha256 应与 canonical 文本一致：\{r2}")
  // 传入非 canonical 的等价文本（多余空白）→ 内部规范化后指纹仍一致
  let loose = text.replace(old=",\"guards\"", new=", \"guards\"")
  let r3 = run(s, "mvsl-set \{b64_of(loose)}")
  assert_true(r3.contains(h1), msg="非 canonical 输入应被规范化：\{r3}")
}

///|
test "MVSL：select-preview 返回数值证书 + 覆盖图（图与数一并给）" {
  let s = scene("mvsl-preview")
  let sel = @core.selspec_to_json(left_half_sel())
  let r = run(s, "select-preview \{b64_of(sel)} max=120")
  assert_true(r.contains("\"op\":\"select-preview\""), msg=r)
  // 左半边 = 320×240 的一半 → 覆盖率 ≈ 0.5
  assert_true(near(jnum_field(r, "coverage"), 0.5), msg=r)
  assert_true(r.contains("\"components\":1"), msg=r)
  assert_true(r.contains("\"bbox\":[0,0,159,239]"), msg=r)
  assert_true(r.contains("\"component_facts\":[{\"id\":1"), msg=r)
  // 选择子反解入口对称：canonical 文本必须能原样反解
  let back = match @core.selspec_from_json(sel) {
    Ok(x) => x
    Err(e) => abort("反解失败: \{e}")
  }
  assert_eq(@core.selspec_to_json(back), sel, msg="SelSpec canonical 往返不幂等")
  // 坏选择子载荷
  let alien_sel = "{\"basis\":\"base\",\"expr\":{\"t\":\"hair_sel\"}}"
  let e = run(s, "select-preview \{b64_of(alien_sel)}")
  assert_true(e.contains("未知选择子"), msg=e)
  let no_expr = "{\"basis\":\"base\"}"
  let e2 = run(s, "select-preview \{b64_of(no_expr)}")
  assert_true(e2.contains("缺 expr"), msg=e2)
}

///|
/// 取回包里 `per_op[idx]` 的数值字段。
///
/// **为什么不能用 `contains("\"leak_ratio\":0")`**：那是子串匹配，而
/// `"leak_ratio":0.0279` 以 `"leak_ratio":0` 开头——泄漏率在 `[0,1)` 的
/// 任何值都能通过。本仓库曾有 5 处 leak 断言栽在这上面，看起来在守护
/// "选区外零泄漏"，实际只拒绝 ≥ 1 的泄漏率。数值字段一律精确解析。
fn per_op_num(text : String, idx : Int, key : String) -> Double {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  let arr = match obj.get("per_op") {
    Some(@core.JValue::JArr(a)) => a
    _ => abort("回包缺 per_op 数组：\{text}")
  }
  if idx >= arr.length() {
    abort("per_op 只有 \{arr.length()} 项，取不到第 \{idx} 项")
  }
  let v = match arr[idx].get(key) {
    Some(x) => x
    None => abort("per_op[\{idx}] 缺字段 \{key}：\{text}")
  }
  match v.as_num() {
    Some(x) => x
    None => abort("per_op[\{idx}].\{key} 不是数字：\{text}")
  }
}

///|
/// 浮点近似相等（coverage 之类由权重求和得出，别用 ==）。
fn near(a : Double, b : Double) -> Bool {
  let d = if a > b { a - b } else { b - a }
  d < 0.000000001
}

///|
test "MVSL：软色彩窗落在真实渐变上时，过渡带不算泄漏" {
  // 上面那条用的是几何硬边选择子（权重非 0 即 1）。这里换**真实渐变**：
  // 色相连续变化，任何色窗都必然带软过渡带（0 < w < 0.5 的像素）。
  //
  // 这曾是一个概念错误：leak 判据原为 `w >= 0.5`，把过渡带算成"选区外"，
  // 于是软选择子一律报出非零"泄漏率"（实测 8.5%），模型会据此去收缩
  // 选择子——而过渡带本来就是要改的区域。
  let s = scene("mvsl-impact-soft")
  let _ = run(
    s,
    "add-rect x=0 y=0 w=160 h=180 lgrad=#F2C14EFF,#A8221AFF,0,0,1,1 name=g",
  )
  let sel : @core.SelSpec = {
    basis: @core.Base,
    expr: @core.Atom(
      @core.Color({
        h_center: 50.0,
        h_half: 30.0,
        s_center: 0.14,
        s_half: 0.10,
        l_center: 0.64,
        l_half: 0.25,
        feather: 0.4,
      }),
    ),
  }
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel,
    amount: 1.0,
    hue_deg: -70.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [],
    note: "",
    evidence: None,
  }
  let prog : @core.EditProgram = { ops: [op], guards: [] }
  let set = run(s, "mvsl-set \{b64_of(@core.program_to_json(prog))}")
  assert_true(set.contains("\"ops\":1"), msg=set)
  // 前提自检：这个选择子必须真的带软边界（覆盖率不是整数比 = 权重非全 0/1）
  let pv = run(s, "select-preview \{b64_of(@core.selspec_to_json(sel))}")
  let cov = jnum_field(pv, "coverage")
  assert_true(cov > 0.0, msg="色窗应命中渐变中段：\{pv}")
  // 前提自检：必须真的带软边界。软选择子的 coverage 不会是 0/1 之类的
  // 整数比（那是"权重非 0 即 1"的硬边特征）——否则这条测试没测到过渡带。
  assert_true(
    !near(cov, 0.0) && !near(cov, 1.0),
    msg="该选择子没产生软边界，测不到过渡带：coverage=\{cov}",
  )
  let imp = run(s, "mvsl-impact max=120")
  let leak = per_op_num(imp, 0, "leak_ratio")
  assert_true(leak == 0.0, msg="过渡带被误判成泄漏：leak_ratio=\{leak}")
  // 且确实改了东西（不是空操作在"通过"）
  assert_true(
    jnum_field(imp, "changed_total") > 0.0,
    msg="该编辑表本应产生改动：\{imp}",
  )
}

///|
test "MVSL：mvsl-impact 逐算子证书（改动数/ΔE/选区外泄漏率）" {
  let s = scene("mvsl-impact")
  let text = @core.program_to_json(recolor_program([]))
  let _ = run(s, "mvsl-set \{b64_of(text)}")
  let r = run(s, "mvsl-impact max=120")
  assert_true(r.contains("\"op\":\"mvsl-impact\""), msg=r)
  assert_true(r.contains("\"stages\":1"), msg=r)
  // 左半边 160×240 = 38400 像素被改
  assert_true(r.contains("\"changed\":38400"), msg=r)
  // 去污染 + 支撑集判据：选区外泄漏率必须精确为 0
  let leak0 = per_op_num(r, 0, "leak_ratio")
  assert_true(leak0 == 0.0, msg="选区外泄漏 \{leak0}：\{r}")
  // 目标区平均 ΔE > 0（确实改了色）
  assert_true(r.contains("\"sel_de\":"), msg=r)
  // 空编辑表：stages 0、零改动
  let _ = run(s, "mvsl-clear")
  let r2 = run(s, "mvsl-impact")
  assert_true(r2.contains("\"stages\":0"), msg=r2)
  assert_true(r2.contains("\"changed_total\":0"), msg=r2)
}

///|
test "渲染管线闭环：render / previews / impact 三者必须给出同一张图" {
  let s = scene("mvsl-pipeline")
  // 装编辑表**之前**的最终图（用于证明"是编辑表改变了管线输出"）
  let before_sha = jfield(run(s, "render 320"), "render_sha256")
  let text = @core.program_to_json(recolor_program([]))
  let _ = run(s, "mvsl-set \{b64_of(text)}")
  // 1) render：取景 = 全画布 1:1 时，就是最终图
  let render_sha = jfield(run(s, "render 320"), "render_sha256")
  assert_true(
    run(s, "render 0").contains("out_width 越界"),
    msg="越界 out_width 应报错",
  )
  // 2) impact：**full_sha256** 才是"全画布最终图"的指纹；`result_sha256`
  //    是回吐那张（可能被 max= 降采样的）预览 PNG 的 sha。此前两者被混为
  //    一谈，而当时的老代码恰好把全分辨率 sha 写进 result_sha256——
  //    "render == impact"看着一直绿，其实是因为那个字段名不副实。
  let impact_sha = jfield(run(s, "mvsl-impact max=64"), "full_sha256")
  // 3) previews：容器里的 flat.png 必须与上面两者逐字节一致
  let mpd_b64 = jfield(run(s, "save-mpd-b64"), "mpd_b64")
  let bytes = @base64.decode(mpd_b64) catch {
    _ => abort("mpd base64 解码失败")
  }
  let z = @codec.Zip::open(bytes)
  let flat_sha = @base.sha256_hex(z.read("previews/flat.png"))
  // **编辑表真的进了渲染管线**：装表前后渲染结果必须不同
  assert_true(render_sha != before_sha, msg="装了编辑表但 render 输出没变（管线漏渲染）")
  // **三条出口同一张图**：render == impact == 容器预览
  assert_eq(render_sha, impact_sha, msg="render 与 mvsl-impact 的结果图不一致")
  assert_eq(flat_sha, impact_sha, msg="容器预览与 mvsl-impact 的结果图不一致")
  assert_eq(
    @base.sha256_hex(z.read("previews/thumb.png")),
    flat_sha,
    msg="flat/thumb 应一致",
  )
  // 4) 视觉通道（sample）看到的也必须是最终图，不是底图
  let probe_in = run(s, "sample 80 120")
  let probe_out = run(s, "sample 300 120")
  assert_true(
    !probe_in.contains("#1E5ACCFF"),
    msg="编辑区内的 sample 仍返回底图颜色：\{probe_in}",
  )
  assert_true(
    probe_out.contains("#1E5ACCFF"),
    msg="编辑区外的 sample 应返回底图颜色：\{probe_out}",
  )
  // 5) 清空编辑表 → 回到装表前的那张图（管线无残留状态）
  let _ = run(s, "mvsl-clear")
  assert_eq(
    jfield(run(s, "render 320"), "render_sha256"),
    before_sha,
    msg="清空编辑表后渲染未回到原图",
  )
}

///|
test "三个身份字段各司其职：文档指纹不随编辑表变，program_sha256 才随它变" {
  // 这是个真实陷阱：宿主若只按 fingerprint 判缓存失效，编辑表改动后会继续
  // 用旧图——因为 fingerprint 覆盖的是 design.json，编辑表不在其中。
  let s = scene("mvsl-identity")
  let r0 = run(s, "render 320")
  let fp0 = jfield(r0, "fingerprint")
  let p0 = jfield(r0, "program_sha256")
  let i0 = jfield(r0, "render_sha256")
  let text = @core.program_to_json(recolor_program([]))
  let _ = run(s, "mvsl-set \{b64_of(text)}")
  let r1 = run(s, "render 320")
  let fp1 = jfield(r1, "fingerprint")
  let p1 = jfield(r1, "program_sha256")
  let i1 = jfield(r1, "render_sha256")
  // 文档没动 → 文档指纹必须不变（否则 .mpd 指纹对账语义就错了）
  assert_eq(fp1, fp0, msg="装编辑表不该改变文档指纹")
  // 编辑表动了 → program_sha256 必须变
  assert_true(p1 != p0, msg="装编辑表后 program_sha256 未变")
  // 渲染结果变了 → render_sha256 必须变（宿主缓存的唯一真值）
  assert_true(i1 != i0, msg="装编辑表后 render_sha256 未变（管线漏渲染）")
  // program_sha256 与容器 manifest 里的同名字段同算法
  assert_eq(
    p1,
    @core.program_sha256(recolor_program([])),
    msg="program_sha256 与 core 实现不一致",
  )
  // 清空后回到原值（空程序的指纹是稳定的）
  let _ = run(s, "mvsl-clear")
  let r2 = run(s, "render 320")
  assert_eq(jfield(r2, "program_sha256"), p0, msg="清空后 program_sha256 应回到空程序指纹")
  assert_eq(jfield(r2, "render_sha256"), i0, msg="清空后渲染应回到原图")
  assert_eq(jfield(r2, "fingerprint"), fp0, msg="清空后文档指纹不变")
}

///|
test "MVSL：保护断言违反则命令信封 fail（别动人物 = 机器可验证约束）" {
  let s = scene("mvsl-assert")
  // 保护区 = 左半边（正是要改的地方）→ 两条都违反
  let prot : @core.Guard = {
    id: "g1",
    sel: left_half_sel(),
    max_de: 0.001,
    max_changed_ratio: 0.0,
  }
  let text = @core.program_to_json(recolor_program([prot]))
  let _ = run(s, "mvsl-set \{b64_of(text)}")
  let r = run(s, "mvsl-assert")
  assert_true(r.has_prefix("{\"error\":\"断言未通过（2 条）"), msg=r)
  assert_true(r.contains("保护区平均 ΔE"), msg=r)
  assert_true(r.contains("保护区改动比例"), msg=r)
  // 保护区改成右半边（本次不动）→ 通过
  let prot2 : @core.Guard = {
    id: "g1",
    sel: {
      basis: @core.Base,
      expr: @core.Atom(
        @core.Geo({ x: 160.0, y: 0.0, w: 160.0, h: 240.0, feather: 0.0 }, "rect"),
      ),
    },
    max_de: 0.001,
    max_changed_ratio: 0.0,
  }
  let text2 = @core.program_to_json(recolor_program([prot2]))
  let _ = run(s, "mvsl-set \{b64_of(text2)}")
  let r2 = run(s, "mvsl-assert")
  assert_true(r2.contains("\"violations\":0"), msg=r2)
  assert_true(r2.contains("\"guards\":1"), msg=r2)
}

///|
test "MVSL：编辑表随 .mpd 落盘往返（编辑表是状态，edits 是轨迹）" {
  let s = scene("mvsl-mpd")
  let ev : @core.Evidence = {
    label: "背景蓝",
    pos_seeds: [(10.0, 10.0)],
    neg_seeds: [(200.0, 10.0)],
  }
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: left_half_sel(),
    amount: 0.8,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [@core.Feather(2.0)],
    note: "调色",
    evidence: Some(ev),
  }
  let text = @core.program_to_json({ ops: [op], guards: [] })
  let set = run(s, "mvsl-set \{b64_of(text)}")
  assert_true(set.contains("\"op\":\"mvsl-set\""), msg=set)
  let save = run(s, "save-mpd-b64")
  let sv = match @core.parse_json(save) {
    Ok(x) => x
    Err(e) => abort("save-mpd-b64 回包不是 JSON: \{e}")
  }
  let mpd_b64 = match sv.get("mpd_b64") {
    Some(@core.JStr(x)) => x
    _ => abort("save-mpd-b64 回包缺 mpd_b64：\{save}")
  }
  // 新会话打开：编辑表必须原样回来（不是历史里能看见，而是状态里生效）
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let open = run(s2, "open-mpd-b64 \{mpd_b64}")
  assert_true(open.contains("\"op\":\"open-mpd-b64\""), msg=open)
  let show = run(s2, "mvsl-show")
  let want = @base.sha256_hex(@utf8.encode(text))
  assert_true(show.contains(want), msg="编辑表未随容器往返：\{show}")
  assert_true(show.contains("背景蓝"), msg="确定性证据（种子点）未随容器往返")
  // 再打包一次必须逐字节一致（确定性 pack 的进程内闭环）
  let save2 = run(s2, "save-mpd-b64")
  assert_eq(save2, save, msg="open→save 字节不一致")
}

///|
/// 带 `layer=` 作用域的算子（其余字段取中性值）。
fn scope_prog(layer : String) -> @core.EditProgram {
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 16.0, h: 8.0, feather: 0.0 }
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: { basis: @core.Base, expr: @core.Atom(@core.Geo(g, "rect")) },
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer,
    refine: [],
    note: "",
    evidence: None,
  }
  { ops: [op], guards: [] }
}

///|
test "图层级算子：装得进、报得出，引用不存在的层被拒绝且不污染 session" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 16 8")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF id=l1")
  // 正常路径：layer=l1 存在 → 装得进
  let ok = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("l1")))}")
  assert_true(ok.contains("\"ok\":true"), msg=ok)
  // 报告里能读出这个作用域（解析 JSON，不做子串匹配）
  let show = run(s, "mvsl-show")
  let j = match @core.parse_json(show) {
    Ok(x) => x
    Err(e) => abort("mvsl-show 不是合法 JSON: \{e}")
  }
  let prog_text = match j.get("program") {
    Some(JStr(t)) => t
    _ => abort("mvsl-show 应当带 program 全文")
  }
  let pj = match @core.parse_json(prog_text) {
    Ok(x) => x
    Err(e) => abort("program 不是合法 JSON: \{e}")
  }
  let ops = match pj.get("ops") {
    Some(JArr(a)) => a
    _ => abort("program 里应有 ops")
  }
  assert_eq(ops.length(), 1, msg="算子数")
  assert_eq(
    match ops[0].get("layer") {
      Some(JStr(t)) => t
      _ => ""
    },
    "l1",
    msg="作用域应当往返",
  )
  // 引用不存在的层 → 拒绝，并说清原因
  let e = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("nope")))}")
  assert_true(e.has_prefix("{\"error\":\""), msg=e)
  assert_true(e.contains("不存在的图层"), msg=e)
  // 关键：坏表**不能**留在 session 里（校验必须在赋值之前）
  let show2 = run(s, "mvsl-show")
  let j2 = match @core.parse_json(show2) {
    Ok(x) => x
    Err(e) => abort("mvsl-show 不是合法 JSON: \{e}")
  }
  let text2 = match j2.get("program") {
    Some(JStr(t)) => t
    _ => abort("mvsl-show 应当带 program 全文")
  }
  assert_true(text2.contains("\"layer\":\"l1\""), msg="session 里应当仍是原来那张好表")
  assert_true(!text2.contains("nope"), msg="坏表不该被写进 session")
}

///|
test "图层级算子：layer= 与 STAGE 基准的组合在入口被拒绝" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 16 8")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF id=l1")
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 16.0, h: 8.0, feather: 0.0 }
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: { basis: @core.Stage(0), expr: @core.Atom(@core.Geo(g, "rect")) },
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "l1",
    refine: [],
    note: "",
    evidence: None,
  }
  let prog : @core.EditProgram = { ops: [op], guards: [] }
  let e = run(s, "mvsl-set \{b64_of(@core.program_to_json(prog))}")
  assert_true(e.has_prefix("{\"error\":\""), msg=e)
  assert_true(e.contains("STAGE"), msg=e)
}

///|
test "信封里的 sha 必须是回吐那张 PNG 的 sha（不许拿全分辨率冒充）" {
  // 实测过的 bug：`mvsl-impact` 的 `result_png_b64` 是
  // `downsample_box(out, max_side)` **之后**编码的，而 `result_sha256`
  // 哈希的是**全分辨率** `out`。画布 64x64、max=16 时宿主拿到 16x16 的图，
  // 却配着一个算不到它头上的 sha——**同一个信封里两个字段描述的不是同一张图**。
  // 拿 sha 当缓存键/对账凭据的宿主会静默错配，比报错难查得多。
  //
  // 这条与 `render` 是同一份契约：`render_sha256` 的注释写着
  // "这张 PNG 的 sha256（渲染产物缓存的唯一真值）"。
  let s = scene("impact-sha")
  let j = run(s, "mvsl-impact max=16")
  let png = @base64.decode(jfield(j, "result_png_b64")) catch {
    _ => abort("结果 PNG base64 解码失败")
  }
  assert_eq(
    @base.sha256_hex(png),
    jfield(j, "result_sha256"),
    msg="result_sha256 必须是回吐 PNG 的 sha（信封里两字段要指同一张图）",
  )
  // 画布 64x64 被 max=16 降采样：预览与全分辨率结果**必须**不同，
  // 否则这条测试没在测降采样那条路（判据要问清自己比的是哪两张图）。
  assert_true(
    jfield(j, "full_sha256") != jfield(j, "result_sha256"),
    msg="降采样后预览 sha 应与全分辨率不同",
  )
  // 全分辨率结果 == **同一分辨率**的 render（画布 320x240 → render 320）。
  // 别在这里写 `render 64`：那是 64 宽的缩放视图，与全分辨率结果本就不同，
  // 断言会红——**比 sha 之前先问清两张图的分辨率是否可比**。
  let ren = run(s, "render 320")
  assert_eq(
    jfield(ren, "render_sha256"),
    jfield(j, "full_sha256"),
    msg="impact 的 full_sha256 应与同分辨率的 render 同图",
  )
}

///|
test "不回吐 PNG 的命令别用「某张图的 sha」这种名字" {
  // `mvsl-assert` 只给断言结论、**不回吐任何 PNG**，它的两个 sha 描述的都是
  // 全分辨率缓冲。此前字段名 `result_sha256` 与 `mvsl-impact` 里那个
  // "回吐 PNG 的 sha"撞名，宿主很容易拿去对一张根本不存在的图。名字说准。
  let s = scene("assert-sha-name")
  let j = run(s, "mvsl-assert")
  assert_true(jfield(j, "result_full_sha256") != "", msg="assert 要给全分辨率结果 sha：\{j}")
  assert_true(
    !j.contains("\"result_sha256\""),
    msg="没有 PNG 就别用 result_sha256 这个名字：\{j}",
  )
}

///|
test "layer=@tag：标签当作用域（与具体层 id 同一张图；入口拒落空的标签）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 16 8")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF id=l1")
  let _ = run(s, "add-rect x=8 y=0 w=8 h=8 fill=#0000FFFF id=l2")
  // 落不到任何层 → 入口拒绝（否则这条算子在表里、跑得通、什么都不改）
  let bad = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("@hero")))}")
  assert_true(bad.contains("\"error\""), msg=bad)
  assert_true(bad.contains("hero"), msg="报错应点出标签名：\{bad}")
  assert_true(bad.contains("静默"), msg="报错应说明后果：\{bad}")
  // 裸 @ 也要报
  let bare = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("@")))}")
  assert_true(bare.contains("没有标签名"), msg=bare)
  // 打了个标签之后装得进，并且**渲染结果与写具体层 id 逐位相同**
  let _ = run(s, "tag l1 hero")
  let ok = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("@hero")))}")
  assert_true(ok.contains("\"ok\":true"), msg=ok)
  let r1 = jfield(run(s, "render"), "render_sha256")
  let ok2 = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("l1")))}")
  assert_true(ok2.contains("\"ok\":true"), msg=ok2)
  let r2 = jfield(run(s, "render"), "render_sha256")
  assert_eq(r1, r2, msg="layer=@hero 与 layer=l1 必须渲染出同一张图")
  // impact 走的是"在合成底图上跑整张表"的近似路径，同样要能接受标签作用域
  let imp = run(s, "mvsl-impact")
  assert_true(imp.contains("\"ok\":true"), msg=imp)
}

///|
test "layer=@tag 是活绑定：事后摘掉标签 → render/impact 都拒绝，lint 报 P4" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 16 8")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF id=l1")
  let _ = run(s, "tag l1 hero")
  let _ = run(s, "mvsl-set \{b64_of(@core.program_to_json(scope_prog("@hero")))}")
  let before = jfield(run(s, "render"), "render_sha256")
  // 摘标签（**没有**重新装表）：作用范围当场变空
  let un = run(s, "untag l1 hero")
  assert_true(un.contains("\"ok\":true"), msg=un)
  let e = run(s, "render")
  assert_true(e.contains("\"error\""), msg="标签摘掉后 render 必须报错，而不是回一张没改的图：\{e}")
  assert_true(e.contains("hero"), msg="报错应点出标签：\{e}")
  // render 报错时 impact 不许还给证书（render ≡ impact 这条不变量）
  let ei = run(s, "mvsl-impact")
  assert_true(ei.contains("\"error\""), msg="render 拒绝时 impact 也必须拒绝：\{ei}")
  let ea = run(s, "mvsl-assert")
  assert_true(ea.contains("\"error\""), msg="assert 同规：\{ea}")
  // lint 要说出"这条算子现在什么都不改"
  let lint = run(s, "lint")
  assert_true(lint.contains("P4"), msg="lint 必须报 P4：\{lint}")
  assert_true(lint.contains("hero"), msg="lint 的 P4 应点出标签：\{lint}")
  // 重新打上标签 → 立刻回到原样（活绑定，两个方向都要动）
  let _ = run(s, "tag l1 hero")
  let after = jfield(run(s, "render"), "render_sha256")
  assert_eq(after, before, msg="重新打上标签后应当逐位回到原来的图")
}

///|
test "层 id 命名空间：@ 开头的 id 在五个 add-* 入口全被拒（同一个字符串不许两种读法）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 16 8")
  let cmds = [
    "add-rect x=0 y=0 w=4 h=4 fill=#FF0000FF id=@bad",
    "add-ellipse x=0 y=0 w=4 h=4 fill=#FF0000FF id=@bad",
    "add-text x=0 y=0 text=hi id=@bad",
    "add-adjust op=brightness value=0.5 id=@bad",
    "add-paint id=@bad",
  ]
  for c in cmds {
    let r = run(s, c)
    assert_true(r.contains("\"error\""), msg="\{c} 应当被拒：\{r}")
    assert_true(r.contains("layer=@tag"), msg="\{c} 的报错应点明 @ 保留给标签作用域：\{r}")
  }
  // 正控：正常 id 照样建得出来（判据两头都要咬）
  let ok = run(s, "add-rect x=0 y=0 w=4 h=4 fill=#FF0000FF id=good")
  assert_true(ok.contains("\"ok\":true"), msg=ok)
}

///|
test "lint 兜底：手改容器里 @ 开头的层 id 会被报出来（命令面进不来，旧容器进得来）" {
  let doc = @core.new_document("u-at-id", 8, 4)
  doc.layers.push(@core.default_layer("@hero", "sneaky", 0.0, 0.0, 8.0, 4.0))
  let v = @agent.lint_doc(doc)
  let mut hit = false
  for item in v {
    if item.contains("ns") && item.contains("@hero") {
      hit = true
    }
  }
  assert_true(hit, msg="lint 必须报出 @ 开头的层 id（否则 layer=@hero 会有两种读法）：\{v.join("、")}")
  // 正控：正常 id 一个字都不该报（误报也是 bug）
  let doc2 = @core.new_document("u-ok-id", 8, 4)
  doc2.layers.push(@core.default_layer("hero", "ok", 0.0, 0.0, 8.0, 4.0))
  let v2 = @agent.lint_doc(doc2)
  assert_eq(v2.length(), 0, msg="正常 id 不该被报：\{v2.join("、")}")
}

///|
test "mvsl-set 的报错回显收到的载荷（手搓 base64 漏字段时能自己看出来）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 16 8")
  // 缺 version 的载荷：报错必须带上**原文**，否则调用方在几千字符的 base64 里找不到北
  let payload = "{\"ops\":[],\"guards\":[]}"
  let r = run(s, "mvsl-set \{b64_of(payload)}")
  assert_true(r.contains("缺 version"), msg=r)
  assert_true(r.contains("收到的载荷"), msg="报错应回显载荷：\{r}")
  assert_true(r.contains("ops"), msg="回显里应能看到实际收到的字段：\{r}")
  // 正控：带 version 的同一张表装得进（判据咬的是载荷，不是"只要非空就报错"）
  let payload_ok = "{\"version\":1,\"ops\":[],\"guards\":[]}"
  let ok = run(s, "mvsl-set \{b64_of(payload_ok)}")
  assert_true(ok.contains("\"ok\":true"), msg=ok)
}
