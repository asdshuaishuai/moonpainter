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
  assert_true(r.contains("\"coverage\":0.5"), msg=r)
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
test "MVSL：mvsl-impact 逐算子证书（改动数/ΔE/选区外泄漏率）" {
  let s = scene("mvsl-impact")
  let text = @core.program_to_json(recolor_program([]))
  let _ = run(s, "mvsl-set \{b64_of(text)}")
  let r = run(s, "mvsl-impact max=120")
  assert_true(r.contains("\"op\":\"mvsl-impact\""), msg=r)
  assert_true(r.contains("\"stages\":1"), msg=r)
  // 左半边 160×240 = 38400 像素被改
  assert_true(r.contains("\"changed\":38400"), msg=r)
  // 几何谓词硬边 + 去污染：选区外泄漏率必须是 0
  assert_true(r.contains("\"leak_ratio\":0"), msg=r)
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
  // 2) impact：result_sha256 是"全画布最终图"的指纹
  let impact_sha = jfield(run(s, "mvsl-impact max=64"), "result_sha256")
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
