/// 编辑表 lint（agent 层）。
///
/// 这一组测试钉住的是一类**每个命令都返回 ok 的失败**：装了编辑表却什么都
/// 没改、断言被违反、某条算子白装。它们的共同点是"引擎知道自己没干活，
/// 但没人告诉调用方"。

///|
/// 一条「不改动任何像素」的选择子：绿色窗，而画布只有红蓝。
fn dead_green_sel() -> @core.SelSpec {
  {
    basis: @core.Base,
    expr: @core.Atom(
      @core.Color({
        h_center: 145.0,
        h_half: 25.0,
        s_center: 0.18,
        s_half: 0.08,
        l_center: 0.7,
        l_half: 0.15,
        feather: 0.1,
      }),
    ),
  }
}

///|
/// 一条命中左半红块的选择子（OKLCh 红区）。
fn red_sel() -> @core.SelSpec {
  {
    basis: @core.Base,
    expr: @core.Atom(
      @core.Color({
        h_center: 28.0,
        h_half: 25.0,
        s_center: 0.20,
        s_half: 0.10,
        l_center: 0.535,
        l_half: 0.15,
        feather: 0.1,
      }),
    ),
  }
}

///|
fn lint_scene(tag : String) -> @agent.Session {
  let s = scene(tag)
  let _ = run(s, "add-rect x=0 y=0 w=160 h=240 fill=#C81E1EFF name=red")
  let _ = run(s, "add-rect x=160 y=0 w=160 h=240 fill=#1E5ACCFF name=blue")
  s
}

///|
fn lint_install(s : @agent.Session, prog : @core.EditProgram) -> String {
  let set = run(s, "mvsl-set \{b64_of(@core.program_to_json(prog))}")
  if !set.contains("\"ops\":") {
    abort("装表失败：\{set}")
  }
  run(s, "lint")
}

///|
/// 一条算子。kind 用 core 的枚举，缺省参数按各自语义给「有改动」的值。
fn eop(id : String, sel : @core.SelSpec) -> @core.EditOp {
  {
    id,
    kind: @core.Recolor,
    sel,
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [],
    note: "",
    evidence: None,
  }
}

///|
test "lint：装了表却什么都没改 = P0（这是唯一会说出真相的命令）" {
  let s = lint_scene("lint-noop")
  let prog : @core.EditProgram = { ops: [eop("e1", dead_green_sel())], guards: [] }
  // 前提：这一路命令全都返回 ok——正是问题所在
  let preview = run(
    s,
    "select-preview \{b64_of(@core.selspec_to_json(dead_green_sel()))}",
  )
  assert_true(
    jnum_field(preview, "coverage") == 0.0,
    msg="该选择子本就不该命中：\{preview}",
  )
  let r = lint_install(s, prog)
  assert_true(r.contains("P0 mvsl"), msg=r)
  assert_true(r.contains("整张图逐位未变"), msg=r)
  assert_true(r.contains("0 个像素改动"), msg=r)
  // 归因必须指向选择子（表里没有构造性空算子）
  assert_true(r.contains("选择子一个像素都没命中"), msg=r)
}

///|
test "lint：构造性空算子单独报 P1，且整表空操作归因给算子而不是选择子" {
  let s = lint_scene("lint-nullop")
  // recolor 转 0 度、覆盖全画布（选择子必然是命中的）
  let geo : @core.SelSpec = {
    basis: @core.Base,
    expr: @core.Atom(
      @core.Geo({ x: 0.0, y: 0.0, w: 320.0, h: 240.0, feather: 0.0 }, "rect"),
    ),
  }
  let op : @core.EditOp = { ..eop("e1", geo), hue_deg: 0.0 }
  let r = lint_install(s, { ops: [op], guards: [] })
  assert_true(r.contains("hue_deg=0"), msg=r)
  // 关键：不能把构造性空操作说成"选择子没命中"——那会把调用方引向错误的方向
  assert_true(r.contains("每一条都是构造性空操作"), msg=r)
  assert_true(!r.contains("选择子一个像素都没命中"), msg="归因错误：\{r}")
}

///|
test "lint：部分算子白装时点名是哪一个（其余正常时不报整表 P0）" {
  let s = lint_scene("lint-partial")
  let prog : @core.EditProgram = {
    ops: [eop("e1", red_sel()), eop("e2", dead_green_sel())],
    guards: [],
  }
  let r = lint_install(s, prog)
  assert_true(r.contains("算子 e2 未改动任何像素"), msg=r)
  assert_true(!r.contains("算子 e1 未改动"), msg="e1 是有效的，不该被点名：\{r}")
  // 有事发生 → 不该报整表空操作
  assert_true(!r.contains("整张图逐位未变"), msg=r)
}

///|
test "lint：保护断言被违反 = P0（用户的「别动 XX」不许静默失守）" {
  let s = lint_scene("lint-guard")
  // 改红区，却断言红区不许变——必然违反
  let prot : @core.Guard = {
    id: "keep_red",
    sel: red_sel(),
    max_de: 0.01,
    max_changed_ratio: 0.0,
  }
  let r = lint_install(s, { ops: [eop("e1", red_sel())], guards: [prot] })
  assert_true(r.contains("P0 mvsl 保护断言被违反"), msg=r)
  assert_true(r.contains("keep_red"), msg=r)
  // 生效的编辑 + 被违反的断言：整表并非空操作，两条信息互不干扰
  assert_true(!r.contains("整张图逐位未变"), msg=r)
  // 断言通过时不许误报
  let ok_prot : @core.Guard = {
    id: "keep_blue",
    sel: {
      basis: @core.Base,
      expr: @core.Atom(
        @core.Color({
          h_center: 264.0,
          h_half: 25.0,
          s_center: 0.19,
          s_half: 0.10,
          l_center: 0.50,
          l_half: 0.15,
          feather: 0.1,
        }),
      ),
    },
    max_de: 0.01,
    max_changed_ratio: 0.0,
  }
  let r2 = lint_install(s, { ops: [eop("e1", red_sel())], guards: [ok_prot] })
  assert_true(!r2.contains("保护断言被违反"), msg="未违反的断言不许误报：\{r2}")
}

///|
test "lint：空断言（选择子零命中）= P1 —— 它给的是虚假的安心" {
  let s = lint_scene("lint-vacuous")
  // 改红区，却拿「绿区不许变」当保护——而画布上根本没有绿
  let vacuous : @core.Guard = {
    id: "keep_green",
    sel: dead_green_sel(),
    max_de: 0.001,
    max_changed_ratio: 0.0,
  }
  let prog : @core.EditProgram = { ops: [eop("e1", red_sel())], guards: [vacuous] }
  // 前提：断言本身"通过"——这才是危险所在（0 违规 ≠ 约束被守住）
  let _ = lint_install(s, prog)
  let asr = run(s, "mvsl-assert")
  assert_true(asr.contains("\"violations\":0"), msg="空断言本就会通过：\{asr}")
  let r = run(s, "lint")
  assert_true(r.contains("空断言"), msg="lint 必须点出空断言：\{r}")
  assert_true(r.contains("keep_green"), msg=r)
  // 不得与"断言被违反"混淆：这条断言并没有被违反
  assert_true(!r.contains("保护断言被违反"), msg="空断言 ≠ 被违反：\{r}")
  // 非空的保护断言不许被误判为空断言
  let real : @core.Guard = {
    id: "keep_blue",
    sel: {
      basis: @core.Base,
      expr: @core.Atom(
        @core.Color({
          h_center: 264.0,
          h_half: 25.0,
          s_center: 0.19,
          s_half: 0.10,
          l_center: 0.50,
          l_half: 0.15,
          feather: 0.1,
        }),
      ),
    },
    max_de: 0.01,
    max_changed_ratio: 0.0,
  }
  let _ = lint_install(s, { ops: [eop("e1", red_sel())], guards: [real] })
  let r2 = run(s, "lint")
  assert_true(!r2.contains("空断言"), msg="命中的断言不该被判为空断言：\{r2}")
}

///|
test "lint：空编辑表是合法状态，不报任何条目（不制造噪音）" {
  let s = lint_scene("lint-empty")
  let _ = run(s, "mvsl-clear")
  let r = run(s, "lint")
  assert_true(!r.contains("mvsl"), msg="空表不该产生 mvsl 条目：\{r}")
  // 文档级 lint 照常工作（几何违规仍报）
  let s2 = scene("lint-doc")
  let _ = run(s2, "add-rect x=-999 y=0 w=50 h=50 fill=#FFFFFFFF name=off")
  let r2 = run(s2, "lint")
  assert_true(r2.contains("完全在画布外"), msg=r2)
}

///|
test "lint：空组与空文本层是「装了却什么都不干」，必须报" {
  // 这两类状态**每个命令都返回 ok**、渲染也"成功"（只是没有像素），
  // 所以只有 lint 会报。MVSL 侧早就有这条纪律（空算子/空断言），
  // 几何/文本侧此前没有——实测两者都是 `violations=0`。
  let s = scene("lint-noop")
  // 空组：建组后删掉唯一成员（`group` 本身要求 ≥1 成员，但状态可到达）
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#00FF00FF name=A")
  let _ = run(s, "group g1 l1")
  let r0 = run(s, "lint")
  assert_true(!r0.contains("没有任何成员"), msg="有成员的组不该被报：\{r0}")
  let _ = run(s, "delete l1")
  let r = run(s, "lint")
  assert_true(r.contains("没有任何成员"), msg="空组必须被报：\{r}")
  // 空文本层：`add-text` 拒绝空内容，但 `set-text ""` 能到达
  let _ = run(s, "add-text text=X x=0 y=0 w=40 h=10")
  let r1 = run(s, "lint")
  assert_true(!r1.contains("内容为空"), msg="有内容的文本层不该被报：\{r1}")
  // 注意 id：`scene()` 已经用掉了 l1，所以新 rect 是 l2、新文本层是 **l3**
  // （我第一版写成 l2，于是 set-text 作用在 rect 上、测试假通过——
  // 正是下面那条「非文本层不许 set-text」要找的东西）。
  let _ = run(s, "set-text l3 \"\"")
  let r2 = run(s, "lint")
  assert_true(r2.contains("内容为空"), msg="空文本层必须被报：\{r2}")
}

///|
test "lint：组上的蒙版不生效（收得下、画面逐位不变）必须报" {
  // 实测：`group g1 l1` 之后 `add-mask g1 x=0 y=0 w=5 h=10` 回 ok、`lint`
  // 报 0 违规、渲染 sha256 **逐位不变**——渲染器对组只递归子层、组自身无面。
  // 正控：同样一条蒙版装在**普通层**上不许被报（否则这条判据会把正常用法
  // 也一起骂了，而"漏报与误报都是 bug"）。
  let s = scene("lint-group-mask")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#00FF00FF name=A")
  let _ = run(s, "add-mask l1 x=0 y=0 w=5 h=10")
  let r0 = run(s, "lint")
  assert_true(!r0.contains("上的蒙版不生效"), msg="普通层上的蒙版不该被报：\{r0}")
  let _ = run(s, "group g1 l1")
  let r1 = run(s, "lint")
  assert_true(!r1.contains("上的蒙版不生效"), msg="普通的组（无蒙版）不该被报：\{r1}")
  let _ = run(s, "add-mask g1 x=0 y=0 w=5 h=10")
  let r2 = run(s, "lint")
  assert_true(
    r2.contains("上的蒙版不生效"),
    msg="组上的蒙版必须被报（渲染器根本不读它）：\{r2}",
  )
}

///|
test "lint：非文本层带 text 字段是死数据（渲染器不读，却改变指纹）" {
  // 这个字段的一整条通路：`set-text` 写 → canonical JSON 存 → 指纹变 →
  // query-layer 报 → **渲染器只对 Text 层读它** → 画面一个像素没变。
  // 于是"改成功了吗"的三种信号自相矛盾。入口已拒绝，lint 兜住手改容器。
  let s = scene("lint-deadtext")
  let bad = run(s, "set-text l1 hello")
  assert_true(bad.contains("不是文本层"), msg="非文本层必须拒绝：\{bad}")
  assert_true(bad.contains("rect"), msg="报错要说清它是什么层：\{bad}")
  // 直接构造「手改容器」的那种状态，看 lint 兜不兜得住
  let doc = @core.new_document("lint-deadtext-2", 64, 64)
  let l = @core.default_layer("d1", "hand-edited", 0.0, 0.0, 20.0, 20.0)
  doc.layers.push({ ..l, text: "幽灵文字" })
  let items = @agent.lint_doc(doc)
  let joined = items.join(" | ")
  assert_true(joined.contains("却带着 text 字段"), msg="lint 必须报死数据：\{joined}")
}

///|
test "lint：8 个 kind 专属字段逐格覆盖 —— 错的 kind 上带着死数据一律要报" {
  // 这张表此前只有 3 格（text / radius / points），另 5 格（font_size /
  // adjust / asset / dabs / children）**谁都没查**。同一个类别的字段，
  // 特例化的检查一定漏——现在 Nature 上是「一行一个字段」的表，
  // 而这条测试**逐格喂一个死值**，漏加一行会在这里红。
  //
  // 注意：这些状态从命令面**进不来**（入口都有 kind 守卫，实测
  // `set-adjust l1`（rect）报「不是调整层」、`brush layer=l1`（rect）报
  // 「不是画笔层」），容器侧也被 open 的**指纹对账**挡住（手改
  // design.json 会「指纹对账失败」）。lint 是第三道防线：万一有人
  // 连 manifest 的指纹一起改了，它就是唯一会说话的东西。
  // 不写 `Array[(A -> B, String)]`：`Array[...]` 见到逗号会当成两个类型实参
  // （类型别名也救不了），让闭包各自标参数类型、由编译器推断元组类型。
  let cases = [
    (fn(l : @core.Layer) { { ..l, text: "幽灵" } }, "text 字段"),
    (fn(l : @core.Layer) { { ..l, font_size: 42.0 } }, "font_size=42"),
    // 基准层是 rect，而圆角对 rect 是**合法**的——只有这一格要换 kind
    (fn(l : @core.Layer) { { ..l, kind: @core.ShapeKind::Ellipse, corner_radius: 7.0 } }, "radius=7"),
    (fn(l : @core.Layer) { { ..l, points: [(0.0, 0.0), (1.0, 1.0)] } }, "2 个顶点"),
    (fn(l : @core.Layer) { { ..l, adjust: Some(@core.Adjust::{ op: @core.AdjustOp::Brightness, value: 0.5 }) } }, "adjust 字段"),
    (fn(l : @core.Layer) { { ..l, asset_hash: "deadbeef" } }, "asset 引用"),
    (fn(l : @core.Layer) { { ..l, dabs: [@core.Dab::{ x: 1.0, y: 1.0, r: 2.0, color: 0xFF0000FF, erase: false }] } }, "1 个笔触"),
    (fn(l : @core.Layer) { { ..l, children: [@core.default_layer("kid", "k", 0.0, 0.0, 4.0, 4.0)] } }, "1 个子层"),
  ]
  for c in cases {
    // `\{...}` 里只放标识符，所以先把元组字段取出来
    let tamper = c.0
    let want = c.1
    let doc = @core.new_document("lint-grid", 64, 64)
    // 基准层是 rect：上表每一格都是「rect 上带着别人家的字段」
    let base = @core.default_layer("g1", "grid", 0.0, 0.0, 20.0, 20.0)
    doc.layers.push(tamper(base))
    let joined = @agent.lint_doc(doc).join(" | ")
    assert_true(joined.contains(want), msg="lint 必须报 \{want}：\{joined}")
    assert_true(joined.contains("rect"), msg="报错要说清是哪一层什么 kind：\{joined}")
  }
  // 反向：每格都要有**正控**——字段落在对的 kind 上不许误报。
  //
  // 这一半不是装饰：最初只做了"错的 kind 要报"，结果「把某一行的合法 kind
  // 写错」这种变异**存活了一轮**（把 rect 加进 text 的合法 kind，
  // "rect 带 text 要报"仍然成立，因为判据是"不在允许集合里"）——只有
  // 正控能咬住它。**一个判据要在两个方向上都咬得住。**
  let okdoc = @core.new_document("lint-grid-ok", 64, 64)
  okdoc.assets.push(@core.Asset::{ hash: "h1", width: 4, height: 4 })
  let b = @core.default_layer("k0", "x", 0.0, 0.0, 20.0, 20.0)
  okdoc.layers.push(
    { ..b, id: "t1", kind: @core.ShapeKind::Text, text: "真的文字", font_size: 24.0 },
  )
  okdoc.layers.push({ ..b, id: "r1", kind: @core.ShapeKind::Rect, corner_radius: 7.0 })
  okdoc.layers.push(
    {
      ..b,
      id: "p1",
      kind: @core.ShapeKind::Polygon,
      points: [(0.0, 0.0), (4.0, 0.0), (2.0, 4.0)],
    },
  )
  okdoc.layers.push(
    {
      ..b,
      id: "a1",
      kind: @core.ShapeKind::Adjust,
      adjust: Some(@core.Adjust::{ op: @core.AdjustOp::Brightness, value: 0.5 }),
    },
  )
  okdoc.layers.push({ ..b, id: "i1", kind: @core.ShapeKind::Image, asset_hash: "h1" })
  okdoc.layers.push(
    {
      ..b,
      id: "d1",
      kind: @core.ShapeKind::Raster,
      dabs: [@core.Dab::{ x: 1.0, y: 1.0, r: 2.0, color: 0xFF0000FF, erase: false }],
    },
  )
  okdoc.layers.push(
    {
      ..b,
      id: "g1",
      kind: @core.ShapeKind::Group,
      children: [@core.default_layer("kid", "k", 0.0, 0.0, 4.0, 4.0)],
    },
  )
  let okj = @agent.lint_doc(okdoc).join(" | ")
  for f in [
    "text 字段", "font_size", "radius=", "个顶点", "adjust 字段", "asset 引用", "个笔触", "个子层",
  ] {
    assert_true(!okj.contains(f), msg="对的 kind 上不该报 \{f}：\{okj}")
  }
}

///|
test "lint：超出可渲染上限的画布必须报出来（此前是静默截断）" {
  // 背景：`RENDER_MAX_SIDE = 4096` 此前是一处**静默截断**——`doc.width=5000`
  // 时渲染器只画左上角 4096×4096，放在 x=4500 的图层**一个像素都不出现**，
  // 而 `census` 把 canvas 报成 `[4096,200]`、`lint` 报 0 违规、画布尺寸与
  // 指纹仍按 5000 记账（实测）。这一格守的是"兜住手改容器"那一半。
  //
  // 判据两头都要咬：**超限必须报**，**不超限一个字都不许报**
  // （否则"把判据写成恒真"这条变异会被判抓住）。
  let lim = @render.render_limit_error(4096, 4096)
  assert_true(lim == "", msg="4096 是上限本身，必须放行：\{lim}")
  let over_w = @render.render_limit_error(4097, 200)
  assert_true(over_w != "", msg="宽超 1 像素就该报")
  let over_h = @render.render_limit_error(200, 4097)
  assert_true(over_h != "", msg="高超 1 像素就该报")
  // 报错要把**两个数**都说出来（收到的尺寸 + 上限），只说"太大了"没法自查
  assert_true(over_w.contains("4097"), msg="要回显实收宽度：\{over_w}")
  assert_true(over_w.contains("4096"), msg="要回显上限：\{over_w}")

  // 正控：恰好 4096 的文档，lint 不许报这一条
  let ok = @core.new_document("lint-canvas-ok", 4096, 200)
  let okl = @agent.lint_doc(ok).join(" | ")
  assert_true(
    !okl.contains("可渲染上限"),
    msg="恰好 4096 的文档不该被报（判据写宽了）：\{okl}",
  )
  // 手改容器：直接构造 5000 宽的文档（`new`/`set-canvas` 已经建不出这种文档了）
  let big = @core.new_document("lint-canvas-big", 5000, 200)
  let l = @core.default_layer("d1", "far", 4500.0, 0.0, 100.0, 100.0)
  big.layers.push(l)
  let joined = @agent.lint_doc(big).join(" | ")
  assert_true(joined.contains("可渲染上限"), msg="超限画布必须被报：\{joined}")
  assert_true(joined.contains("5000"), msg="要回显实收画布宽：\{joined}")
  assert_true(joined.contains("4096"), msg="要回显上限：\{joined}")
  assert_true(joined.contains("P0"), msg="静默丢内容是最严重的一档：\{joined}")
}

///|
test "入口：超限画布在 new / set-canvas 就拒绝（画布是唯一能改大的入口）" {
  // `scene()` 已经建好一个文档，所以这里的"没有副作用"用**指纹**核对：
  // `fingerprint` 是 canonical design.json（含 width/height）的哈希，文档结构
  // 动一个字段它就变——比"看画布尺寸"更精确（当时还**没有**单独回读画布的命令；
  // 现在有了：`census` 的 `canvas` 是文档记账尺寸、`render` 是实际渲染尺寸）。
  let s = scene("canvas-limit")
  let fp0 = run(s, "fingerprint")
  let bad = run(s, "new 5000 200")
  assert_true(bad.contains("可渲染上限"), msg="new 必须拒绝超限画布：\{bad}")
  assert_true(bad.contains("5000"), msg="要回显实收尺寸：\{bad}")
  assert_true(bad.contains("4096"), msg="要回显上限：\{bad}")
  // 被拒的命令**不许有副作用**（不是"先建了再报错"）
  let fp1 = run(s, "fingerprint")
  assert_true(fp1 == fp0, msg="被拒的 new 不许改动文档：\{fp0} → \{fp1}")
  // 正控：4096 恰好放行（不许把上限写成"< 4096"）
  let ok = run(s, "new 4096 200")
  assert_true(ok.contains("\"ok\":true"), msg="4096 必须放行：\{ok}")
  let fp2 = run(s, "fingerprint")
  // **判别力自证**：画布真的换了，指纹就必须变。少了这一条，上面那句
  // "指纹没变"就可能是因为指纹根本不反映画布，而断言照旧绿。
  assert_true(fp2 != fp1, msg="指纹必须反映画布尺寸变化：\{fp1} → \{fp2}")
  // set-canvas 是**表装好之后**唯一能把画布改大的命令：同一句判据必须也在这里
  let sc = run(s, "set-canvas 4097 200")
  assert_true(sc.contains("可渲染上限"), msg="set-canvas 必须拒绝超限画布：\{sc}")
  assert_true(sc.contains("4097"), msg="要回显实收尺寸：\{sc}")
  let fp3 = run(s, "fingerprint")
  assert_true(fp3 == fp2, msg="被拒的 set-canvas 不许改动画布：\{fp2} → \{fp3}")
}
