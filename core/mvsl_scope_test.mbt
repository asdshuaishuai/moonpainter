/// 标签作用域（`layer=@tag`）：语法解析、命名空间规则、静态校验与展开。
///
/// 这一组要钉住的是一件事：**标签是活选层器**——"这条算子改哪些层"只有一处
/// 判断（`expand_layer_scopes`），且它只依赖容器里已有的层与标签。

///|
fn scope_op(id : String, layer : String) -> @core.EditOp {
  let g : @core.GeoWindow = { x: 0.0, y: 0.0, w: 4.0, h: 4.0, feather: 0.0 }
  let sel : @core.SelSpec = { basis: @core.Base, expr: @core.Atom(@core.Geo(g, "rect")) }
  {
    id,
    kind: @core.Recolor,
    sel,
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer,
    refine: [],
    note: "",
    evidence: None,
  }
}

///|
fn scope_doc() -> @core.Document {
  let doc = @core.new_document("u-mvsl-scope", 8, 4)
  let a = @core.default_layer("a", "a", 0.0, 0.0, 4.0, 4.0)
  let b = @core.default_layer("b", "b", 4.0, 0.0, 4.0, 4.0)
  let c = @core.default_layer("c", "c", 0.0, 0.0, 8.0, 4.0)
  doc.layers.push({ ..a, tags: ["hero", "bg"] })
  doc.layers.push({ ..b, tags: ["hero"] })
  doc.layers.push(c)
  doc
}

///|
test "layer=@tag 的语法：@ 前缀才是标签作用域，层 id 不是" {
  assert_true(@core.layer_scope_tag("@hero") is Some("hero"), msg="@hero 应解析成标签 hero")
  assert_true(@core.layer_scope_tag("l1") is None, msg="层 id 不该被当成标签作用域")
  assert_true(
    @core.layer_scope_tag("@") is Some(""),
    msg="裸 @ 应解析成空标签（由 tag_scope_error 报「后面没有标签名」）",
  )
  assert_true(
    @core.layer_scope_tag("@a@b") is Some("a@b"),
    msg="标签名里的 @ 属于标签本身（只认第一个 @）",
  )
}

///|
test "层 id 命名空间：@ 开头的 id 在入口就被拒（同一个字符串不许有两种读法）" {
  assert_true(@core.layer_id_error("l1") is None, msg="普通 id 应当放行")
  assert_true(@core.layer_id_error("bg.1-a_2") is None, msg="点/下划线/短横都该放行")
  let e = match @core.layer_id_error("@hero") {
    Some(e) => e
    None => abort("@ 开头的 id 必须被拒")
  }
  // 报错要说清"为什么"与"怎么办"，别只说"非法"
  assert_true(e.contains("layer=@tag"), msg="错误未点明 @ 保留给标签作用域：\{e}")
}

///|
test "tag_scope_error：裸 @ 与落不到任何层都要报，落到层上才放行" {
  let doc = scope_doc()
  // 正控：@hero 落在 a、b 两层上 → 一个字都不报（漏报与误报都是 bug）
  let ok : @core.EditProgram = { ops: [scope_op("e1", "@hero")], guards: [] }
  assert_true(@core.tag_scope_error(ok, doc) is None, msg="@hero 落在两层上不该报错")
  // @bg 只落在 a 上 → 也放行
  let one : @core.EditProgram = { ops: [scope_op("e1", "@bg")], guards: [] }
  assert_true(@core.tag_scope_error(one, doc) is None, msg="@bg 落在一层上不该报错")
  // 空标签
  let bare : @core.EditProgram = { ops: [scope_op("e1", "@")], guards: [] }
  let e0 = match @core.tag_scope_error(bare, doc) {
    Some(e) => e
    None => abort("裸 @ 必须报错")
  }
  assert_true(e0.contains("没有标签名"), msg="裸 @ 的报错没说清缺什么：\{e0}")
  // 落不到任何层
  let miss : @core.EditProgram = { ops: [scope_op("e1", "@nobody")], guards: [] }
  let e1 = match @core.tag_scope_error(miss, doc) {
    Some(e) => e
    None => abort("落不到任何层的标签作用域必须报错（否则这条算子静默不生效）")
  }
  assert_true(e1.contains("nobody"), msg="报错未点出是哪个标签：\{e1}")
  assert_true(e1.contains("静默"), msg="报错未说明后果：\{e1}")
  assert_true(e1.contains("tag <id>"), msg="报错未给出下一步（怎么打标签）：\{e1}")
  // 文档级算子不受影响
  let doclevel : @core.EditProgram = { ops: [scope_op("e1", "")], guards: [] }
  assert_true(@core.tag_scope_error(doclevel, doc) is None, msg="文档级算子不该被这条判据碰到")
}

///|
test "expand_layer_scopes：按层序展开、顺序保持、匹配不到的原样留下" {
  let doc = scope_doc()
  // 三条算子：文档级 → @hero（两层）→ 具体层 id
  let p : @core.EditProgram = {
    ops: [scope_op("e0", ""), scope_op("e1", "@hero"), scope_op("e2", "c")],
    guards: [],
  }
  let ex = @core.expand_layer_scopes(p, doc)
  assert_eq(ex.ops.length(), 4, msg="一条 @hero 应展开成两份（a、b）")
  assert_eq(ex.ops[0].id, "e0", msg="文档级算子顺序不该变")
  assert_eq(ex.ops[1].layer, "a", msg="展开顺序 = doc.layers 顺序（先 a）")
  assert_eq(ex.ops[2].layer, "b", msg="展开顺序 = doc.layers 顺序（后 b）")
  assert_eq(ex.ops[3].layer, "c", msg="具体层 id 原样保留")
  // 展开出的算子除 layer 外与原件逐字段相同（id 不变：impact/probe 按 id 对账）
  assert_eq(ex.ops[1].id, "e1", msg="展开不该改算子 id")
  assert_eq(ex.ops[1].hue_deg, 120.0, msg="展开不该改算子参数")
  assert_true(ex.ops[1].kind is @core.Recolor, msg="展开不该改算子类型")
  // 匹配不到 → 原样留下（交给 tag_scope_error / render 拒绝，绝不静默丢掉）
  let miss : @core.EditProgram = { ops: [scope_op("e9", "@nobody")], guards: [] }
  let ex2 = @core.expand_layer_scopes(miss, doc)
  assert_eq(ex2.ops.length(), 1, msg="匹配不到的算子不许被悄悄丢掉")
  assert_eq(ex2.ops[0].layer, "@nobody", msg="匹配不到应原样保留作用域串")
  // guards 原样带过（保护断言只针对最终图，与作用域无关）
  let withg : @core.EditProgram = {
    ops: [scope_op("e1", "@hero")],
    guards: [
      {
        id: "keep",
        sel: { basis: @core.Base, expr: @core.Atom(@core.Geo({ x: 0.0, y: 0.0, w: 8.0, h: 4.0, feather: 0.0 }, "rect")) },
        max_de: 0.01,
        max_changed_ratio: 0.0,
      },
    ],
  }
  let ex3 = @core.expand_layer_scopes(withg, doc)
  assert_eq(ex3.guards.length(), 1, msg="guards 必须原样带过")
  assert_eq(ex3.guards[0].id, "keep", msg="guard id 不该变")
}

///|
test "带标签作用域的表仍然算「含图层级算子」（走两段式渲染）" {
  let p : @core.EditProgram = { ops: [scope_op("e1", "@hero")], guards: [] }
  assert_true(@core.program_has_layer_scope(p), msg="@tag 必须被判为图层级（否则走单段、作用域失效）")
  let ids = @core.program_layer_ids(p)
  assert_eq(ids.length(), 1, msg="未展开时只报出作用域串本身")
  assert_eq(ids[0], "@hero", msg="作用域串应原样报出（供入口校验识别）")
}


///|
test "算子字段的中性值：不给就是不起作用，不许因为默认值报「必须为 1」" {
  // 实测坐实：手搓 base64 时漏写 `relight_gain` 的 recolor 会被**静默拒装**，
  // 报错是「算子 e1 不是 relight，relight_gain 必须为 1」——用户写的是合法
  // 语义（不给这个字段 = 它不起作用），引擎却报得像"字段填错了"，而
  // `sel-schema` 的示例里三个数值字段都写着，谁也不会去猜哪个能省。
  // 病根：可选数值一律回落 0，而 relight_gain 的中性值是 **1**。
  let text = "{\"version\":1,\"ops\":[{\"id\":\"e1\",\"kind\":\"recolor\",\"sel\":{\"basis\":\"base\",\"expr\":{\"t\":\"luma\",\"l\":0.5,\"lh\":0.1,\"feather\":0.05}},\"amount\":1,\"hue_deg\":180}],\"guards\":[]}"
  match @core.program_from_json(text) {
    Ok(p) => {
      assert_eq(p.ops.length(), 1)
      let op = p.ops[0]
      assert_eq(op.hue_deg, 180.0)
      assert_eq(op.temp_kelvin, 0.0, msg="不给 temp_kelvin → 中性值 0")
      assert_eq(op.relight_gain, 1.0, msg="不给 relight_gain → 中性值必须是 1（不是 0）")
      // 规范化后照旧打得开（拒绝路径不许在"合法语义"上开火）
      match @core.validate_program(p) {
        Ok(_) => ()
        Err(e) => abort("缺省字段的合法语义不该被拒：\{e}")
      }
    }
    Err(e) => abort("缺省可选字段的算子应能解析：\{e}")
  }
  // 正控：**给了**非中性值就必须报（判据两头都咬，不能放宽成"不看这个字段"）
  let bad = "{\"version\":1,\"ops\":[{\"id\":\"e1\",\"kind\":\"recolor\",\"sel\":{\"basis\":\"base\",\"expr\":{\"t\":\"luma\",\"l\":0.5,\"lh\":0.1,\"feather\":0.05}},\"amount\":1,\"hue_deg\":180,\"relight_gain\":0.2}],\"guards\":[]}"
  match @core.program_from_json(bad) {
    Ok(p) =>
      match @core.validate_program(p) {
        Ok(_) => abort("recolor 上给 relight_gain=0.2 应当被拒（那个值渲染器不读）")
        Err(e) => assert_true(e.contains("relight_gain"), msg=e)
      }
    Err(e) => abort("解析不该在这一步失败：\{e}")
  }
}