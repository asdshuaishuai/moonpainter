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
  assert_true(preview.contains("\"coverage\":0"), msg="该选择子本就不该命中：\{preview}")
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
