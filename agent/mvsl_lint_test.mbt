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
test "lint：变换/混合/蒙版的读点矩阵（表里每一格都要报，且一格都不许多报）" {
  // 实测（**非退化探针**：非白底 + 左右不对称的位图 + 30° 旋转）：
  //   rotate/flip/blend 只在 **有面的层（几何/位图）** 上被读；
  //   text/raster/adjust/group 上写进去回 ok、指纹变、画面**逐位不变**；
  //   mask 除了 group 都读（adjust 是上一轮接上的）。
  // 命令面现在直接拒（下面第二条测试），这里兜住手改容器与**旧容器**。
  let b = @core.default_layer("k0", "k", 0.0, 0.0, 64.0, 64.0)
  let probe_mask = @core.LayerMask::{
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 8.0,
    h: 8.0,
    radius: 0.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
  }
  // ① 不读它的 kind：每格都必须报
  let bad = @core.new_document("lint-matrix-bad", 64, 64)
  bad.layers.push({
    ..b,
    id: "g1",
    kind: @core.ShapeKind::Group,
    children: [@core.default_layer("kid", "k", 0.0, 0.0, 4.0, 4.0)],
    rotation_deg: 45.0,
    flip_h: true,
    flip_v: true,
    blend: @core.BlendMode::Multiply,
    mask: Some(probe_mask),
  })
  bad.layers.push(
    {
      ..b,
      id: "t1",
      kind: @core.ShapeKind::Text,
      text: "Hi",
      font_size: 24.0,
      rotation_deg: 45.0,
      flip_h: true,
      blend: @core.BlendMode::Multiply,
    },
  )
  bad.layers.push(
    {
      ..b,
      id: "r1",
      kind: @core.ShapeKind::Raster,
      dabs: [@core.Dab::{ x: 1.0, y: 1.0, r: 2.0, color: 0xFF0000FF, erase: false }],
      rotation_deg: 45.0,
      blend: @core.BlendMode::Multiply,
    },
  )
  bad.layers.push(
    {
      ..b,
      id: "a1",
      kind: @core.ShapeKind::Adjust,
      adjust: Some(@core.Adjust::{ op: @core.AdjustOp::Invert, value: 1.0 }),
      rotation_deg: 45.0,
      blend: @core.BlendMode::Multiply,
    },
  )
  // 填充/描边的读点是同一张表的另外两格：折线只有描边（fill 死）、
  // 多边形/位图/文本没有描边（stroke 死）、位图的 fill 也不读。
  bad.layers.push({
    ..b,
    id: "ln1",
    kind: @core.ShapeKind::Line,
    points: [(0.0, 0.0), (8.0, 8.0)],
    fill: @core.Fill::Solid(0xFFFF0000),
  })
  bad.layers.push({
    ..b,
    id: "pg1",
    kind: @core.ShapeKind::Polygon,
    points: [(0.0, 0.0), (8.0, 0.0), (0.0, 8.0)],
    stroke: { color: 0xFF0000FF, width: 4.0 },
  })
  bad.layers.push({
    ..b,
    id: "im1",
    kind: @core.ShapeKind::Image,
    asset_hash: "deadbeef",
    fill: @core.Fill::Solid(0xFF00FF00),
    stroke: { color: 0xFF0000FF, width: 4.0 },
  })
  let items = @agent.lint_doc(bad)
  let j = items.join(" | ")
  for needle in [
    "rotation_deg=45", "flip_h=true", "flip_v=true", "blend=multiply", "mask=已设置",
    "fill=#FF0000FF", "stroke_w=4", "fill=#00FF00FF",
  ] {
    assert_true(j.contains(needle), msg="表里的 \{needle} 必须被报：\{j}")
  }
  // 格数也要对：group 5 + text 3 + raster 2 + adjust 2 + line 1（fill）
  // + polygon 1（stroke）+ image 2（fill+stroke）= 16。
  // 只查"含某个词"会被"多报/少报但恰好含这些词"骗过。
  let mut hits = 0
  for it in items {
    if it.contains("却带着") {
      hits = hits + 1
    }
  }
  assert_eq(hits, 16, msg="读点矩阵应报 16 格，实报 \{hits}：\{j}")

  // ② 正控：**读它的 kind** 上带着同样的字段，一格都不许报（漏报与误报都是 bug）
  let ok = @core.new_document("lint-matrix-ok", 64, 64)
  ok.layers.push({
    ..b,
    id: "rect1",
    kind: @core.ShapeKind::Rect,
    rotation_deg: 45.0,
    flip_h: true,
    flip_v: true,
    blend: @core.BlendMode::Multiply,
    mask: Some(probe_mask),
  })
  ok.layers.push({
    ..b,
    id: "img1",
    kind: @core.ShapeKind::Image,
    asset_hash: "h1",
    rotation_deg: 45.0,
    flip_h: true,
    blend: @core.BlendMode::Multiply,
    mask: Some(probe_mask),
  })
  // text/raster/adjust 只允许 mask（它们真的读蒙版）；各自的 kind 专属字段照给，
  // 但**不给别的 kind 的专属字段**——那些会命中表里别的行（那是对的行为，
  // 但会把这条正控的断言搅浑）。
  ok.layers.push({
    ..b,
    id: "t2",
    kind: @core.ShapeKind::Text,
    text: "Hi",
    font_size: 24.0,
    mask: Some(probe_mask),
  })
  ok.layers.push({
    ..b,
    id: "r2",
    kind: @core.ShapeKind::Raster,
    dabs: [@core.Dab::{ x: 1.0, y: 1.0, r: 2.0, color: 0xFF0000FF, erase: false }],
    mask: Some(probe_mask),
  })
  ok.layers.push({
    ..b,
    id: "a2",
    kind: @core.ShapeKind::Adjust,
    adjust: Some(@core.Adjust::{ op: @core.AdjustOp::Invert, value: 1.0 }),
    mask: Some(probe_mask),
  })
  let okj = @agent.lint_doc(ok).join(" | ")
  // 只断言**这五格**没被报（别的行可能因为别的字段开火，那是对的）
  for needle in [
    "rotation_deg", "flip_h", "flip_v", "blend=", "mask=已设置", "上的 fill 不生效", "上的 stroke 不生效",
  ] {
    assert_true(!okj.contains(needle), msg="读它的 kind 上不许报 \{needle}（误报也是 bug）：\{okj}")
  }
}

///|
test "写不生效的字段在入口就拒；写默认值（清字段）必须放行" {
  // 铁律 6：不支持就报明确错误，不降级。判据与 lint 共用同一张表，传**候选层**，
  // 于是"写默认值 = 清字段"自动放行——旧容器里的死数据靠它洗回来。
  // ⚠️ 层 id 全部显式给：`scene()` 自己会加一个背景层，靠自动编号会让
  // "rotate 的是哪一层"整个错位（第一版就因此把矩形当成了文本层）。
  let s = scene("matrix-entry")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#00FF00FF name=R id=r0")
  let _ = run(s, "add-text x=0 y=0 w=40 h=16 text=Hi name=T id=t0")
  let _ = run(s, "add-paint name=P id=p0")
  let _ = run(s, "brush layer=p0 pts=8,8;20,20 r=4 color=#FF0000FF")
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#0000FFFF name=B id=r1")
  let _ = run(s, "add-adjust op=invert name=A id=a0")
  // 不生效的组合：一个都不能悄悄成功（text/raster/adjust 各自三条）
  for bad in [
    "rotate t0 30", "flip t0 h", "set-style t0 blend=multiply",
    "rotate p0 30", "flip p0 v", "set-style p0 blend=screen",
    "rotate a0 30", "flip a0 h", "set-style a0 blend=multiply",
  ] {
    let r = run(s, bad)
    assert_true(
      r.contains("不生效") && r.contains("渲染器只对"),
      msg="`\{bad}` 必须被拒并说清读点：\{r}",
    )
  }
  // 折线/多边形/位图：填充与描边的读点也在这张表里
  let _ = run(s, "add-line id=n0 x=0 y=0 w=20 h=20 points=0,0;20,20")
  let _ = run(s, "add-polygon id=g0 x=0 y=0 w=20 h=20 points=0,0;20,0;0,20")
  let _ = run(s, "add-ellipse id=e0 x=0 y=0 w=10 h=10")
  let _ = run(s, "add-image id=m0 x=0 y=0 w=8 h=4 b64=\{solid_png_b64(8, 4, "#FF0000")}")
  // ① fill：折线只有描边 ⇒ 死；位图/笔触/调整层/组没有填充面 ⇒ 死
  for bad in [
    "set-style n0 fill=#FF0000FF", "set-style m0 fill=#FF0000FF",
    "set-style p0 fill=#FF0000FF", "set-style a0 fill=#FF0000FF",
  ] {
    let r = run(s, bad)
    assert_true(r.contains("fill") && r.contains("stroke="), msg="`\{bad}` 必须被拒并指路：\{r}")
  }
  // ② stroke：只实现了矩形/椭圆/线段
  for bad in [
    "set-style g0 stroke=#0000FFFF stroke_w=4", "set-style t0 stroke_w=4",
    "set-style m0 stroke_w=4", "set-style p0 stroke_w=4", "set-style a0 stroke_w=4",
  ] {
    let r = run(s, bad)
    assert_true(r.contains("stroke") && r.contains("矩形/椭圆/线段"), msg="`\{bad}` 必须被拒：\{r}")
  }
  // ③ **键表**这一层：`add-*` 的字典里不再广告这些键 ⇒ 报"不认识的参数"+理由
  //    （字典是 LLM 唯一的说明书，广告一个必然被拒的键就是在骗它）
  for bad in ["add-polygon x=0 y=0 w=4 h=4 points=0,0;4,0;0,4 stroke=#0000FFFF", "add-ellipse x=0 y=0 w=4 h=4 radius=3"] {
    let r = run(s, bad)
    // 理由必须来自**同一张表**（描边的读点 / 圆角的出路），不是某句泛泛的报错
    let why = r.contains("描边只实现了矩形/椭圆/线段") || r.contains("要给图形加圆角请用 add-rect")
    assert_true(r.contains("不认识的参数") && why, msg="`\{bad}` 的参数面必须带理由拒：\{r}")
  }
  // ④ 字典承诺的键 == 这个 kind 真读的键（**正着咬**：把整串键列出来，
  //    它同时证明"该有的都在"与"不该有的不在"——用 contains 反着断言
  //    某个片段不存在会被别的命令的行骗过，实测踩过一次）。
  let lt = run(s, "list-tools")
  for needle in [
    "[id=][name=][x=][y=][w=][h=][fill=][lgrad=][opacity=][blend=][rot=][visible=][tag=][points=]：多边形",
    "[id=][name=][x=][y=][w=][h=][stroke=][stroke_w=][opacity=][blend=][rot=][visible=][tag=][points=]：折线",
    "[id=][name=][x=][y=][w=][h=][opacity=][blend=][rot=][visible=][tag=][b64=]。",
  ] {
    assert_true(lt.contains(needle), msg="字典的键要与读点矩阵一致（见这句）：\{needle}")
  }
  // ④ 清字段照样放行（旧容器里的死数据洗得回来）
  for ok in ["set-style n0 fill=none", "set-style g0 stroke_w=0", "set-style e0 radius=0"] {
    let r = run(s, ok)
    assert_true(r.contains("\"ok\":true"), msg="`\{ok}` 是清字段，必须放行：\{r}")
  }
  // ⑤ 正控：读它的 kind 上照旧成功（几何全覆盖、椭圆只碰 fill/stroke）
  for ok in [
    "set-style g0 fill=#00FF00FF", "set-style n0 stroke=#00FF00FF stroke_w=2",
    "set-style t0 fill=#123456FF", "set-style e0 stroke_w=1",
  ] {
    let r = run(s, ok)
    assert_true(r.contains("\"ok\":true"), msg="`\{ok}` 必须成功：\{r}")
  }
  // 组：连同蒙版一起拒（mask 在 group 上也不被读）
  let _ = run(s, "group g1 r0")
  for bad in [
    "rotate g1 45", "flip g1 both", "set-style g1 blend=multiply",
    "add-mask g1 x=0 y=0 w=5 h=10", "set-mask g1 invert=true",
  ] {
    let r = run(s, bad)
    assert_true(r.contains("不生效"), msg="组上的 `\{bad}` 必须被拒：\{r}")
  }
  // 清字段的写法要放行（否则旧容器里存着死数据的层再也洗不回来）
  for ok in [
    "rotate t0 0", "flip t0 none", "set-style t0 blend=normal", "rotate g1 0", "flip g1 none",
  ] {
    let r = run(s, ok)
    assert_true(r.contains("\"ok\":true"), msg="`\{ok}` 是清字段，必须放行：\{r}")
  }
  // 正控：**读它的 kind** 上同样四条命令必须照旧成功（位图也读，一起控住）
  for ok in [
    "rotate r1 45", "flip r1 h", "set-style r1 blend=multiply", "add-mask r1 x=0 y=0 w=5 h=10",
  ] {
    let r = run(s, ok)
    assert_true(r.contains("\"ok\":true"), msg="矩形层上的 `\{ok}` 必须成功：\{r}")
  }
  // 蒙版在 text/raster/adjust 上是**真的生效**的（上一轮实测），不许被拒
  for ok in [
    "add-mask t0 x=0 y=0 w=20 h=16", "add-mask p0 x=0 y=0 w=20 h=20",
    "add-mask a0 x=0 y=0 w=20 h=20",
  ] {
    let r = run(s, ok)
    assert_true(r.contains("\"ok\":true"), msg="`\{ok}` 必须成功（这些 kind 读蒙版）：\{r}")
  }
  // 与死字段无关的更新不许被误伤（门禁只在"写那个字段"的分支里问）
  let r = run(s, "set-style t0 opacity=0.5")
  assert_true(r.contains("\"ok\":true"), msg="文本层改透明度必须成功：\{r}")
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
