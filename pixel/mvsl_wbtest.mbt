/// pixel —— MVSL 引擎不变量与表达力上限测试（PLAN-MVSL P3 Phase 0/1）。
///
/// Phase 0 引擎不变量（无 AI）：identity / 重放 / 顺序敏感 / 环距 /
/// 色相 wrap-around / 软窗性质。
/// Phase 1 表达力上限（无 AI）：colorSel+lumSel 暴力搜索 vs 真值 mask
/// 的 IoU ≥ 0.9 —— <0.9 则**先改算子代数，不怪 AI**。

///|
fn argb(r : Int, g : Int, b : Int) -> Int {
  0xFF000000 + (r << 16) + (g << 8) + b
}

///|
fn mk_buf(w : Int, h : Int) -> @codec.RgbaBuf {
  @codec.rgba_new(w, h)
}

///|
fn fill(buf : @codec.RgbaBuf, x0 : Int, y0 : Int, w : Int, h : Int, c : Int) -> Unit {
  @codec.fill_rect_rgba(buf, x0, y0, w, h, c)
}

///|
test "色彩往返：OKLab→OKLCh→OKLab 稳定，ΔE 极小" {
  let cases = [
    argb(255, 0, 0),
    argb(0, 255, 0),
    argb(0, 0, 255),
    argb(128, 128, 128),
    argb(200, 30, 90),
  ]
  for c in cases {
    let lab = argb_to_oklab(c)
    let lch = oklab_to_oklch(lab)
    let back = oklab_to_argb(oklch_to_oklab(lch), lsr32(c, 24))
    let de = delta_e_argb(c, back)
    assert_true(de < 0.01, msg="往返 ΔE 过大: \{de}（色 \{c}）")
  }
}

///|
test "HSV V 不是感知亮度（绿色亮、蓝色暗）——证明弃 HSV 保明暗的必要性" {
  let green = argb(0, 255, 0)
  let blue = argb(0, 0, 255)
  let (_, _, vg) = argb_to_hsv(green)
  let (_, _, vb) = argb_to_hsv(blue)
  let lg = argb_to_oklab(green).l
  let lb = argb_to_oklab(blue).l
  // HSV V: 绿=1.0 蓝=1.0（都"最亮"，但感知亮度差极大）
  assert_true(vg > 0.99 && vb > 0.99, msg="HSV V 均为 1.0（无法区分感知亮度）")
  // OKLab L: 绿显著亮于蓝
  assert_true(lg > lb + 0.3, msg="OKLab L 应区分绿/蓝亮度：\{lg} vs \{lb}")
}

///|
test "色相环距离 wrap-around：359° 与 1° 距离为 2° 而非 358°" {
  assert_true(hue_ring_dist(359.0, 1.0) < 3.0, msg="wrap-around 失效")
  assert_true(hue_ring_dist(0.0, 180.0) > 179.0, msg="对跖应接近 180°")
}

///|
test "软窗性质：monotone、边界 0/1、硬边等价" {
  // feather=0 → 硬边阶跃
  assert_true(window_membership(1.0, 10.0, 0.0) == 1.0, msg="窗内应为 1")
  assert_true(window_membership(10.5, 10.0, 0.0) == 0.0, msg="窗外应为 0")
  // feather=1 → 无恒 1 区间，纯过渡
  assert_true(window_membership(0.0, 10.0, 1.0) == 1.0, msg="中心应为 1")
  assert_true(window_membership(9.99, 10.0, 1.0) < 0.01, msg="近边界应收敛到 0")
  // monotone 递减
  let mut prev = 1.1
  let mut d = 0.0
  while d < 10.0 {
    let m = window_membership(d, 10.0, 0.6)
    assert_true(m <= prev + 0.0001, msg="软窗非单调")
    prev = m
    d = d + 0.25
  }
}

///|
test "Phase 0：空编辑表逐位还原（identity，不经任何色彩变换）" {
  let base = mk_buf(8, 8)
  fill(base, 0, 0, 8, 8, argb(200, 30, 90))
  let (out, stages) = match run_program(base, @core.EditProgram::new()) {
    Ok(r) => r
    Err(e) => abort("run_program: \{e}")
  }
  assert_eq(stages.length(), 0, msg="空表不应产生中间阶段")
  let total = 8 * 8
  let mut i = 0
  while i < total {
    assert_eq(out.pixels[i], base.pixels[i], msg="identity 逐位还原被破坏 @\{i}")
    i = i + 1
  }
}

///|
fn color_win(h : Double, hw : Double) -> @core.ColorWindow {
  {
    h_center: h,
    h_half: hw,
    s_center: 0.0,
    s_half: 1.0,
    l_center: 0.5,
    l_half: 1.0,
    feather: 0.0,
  }
}

///|
fn sel_color(h : Double, hw : Double) -> @core.SelSpec {
  let expr : @core.SelExpr = @core.Atom(@core.Color(color_win(h, hw)))
  { basis: @core.Base, expr }
}

///|
fn sel_geo(x : Double, y : Double, w : Double, h : Double) -> @core.SelSpec {
  let g : @core.GeoWindow = { x, y, w, h, feather: 0.0 }
  let expr : @core.SelExpr = @core.Atom(@core.Geo(g, "rect"))
  { basis: @core.Base, expr }
}

///|
fn op_recolor(id : String, sel : @core.SelSpec, hue : Double) -> @core.EditOp {
  {
    id,
    kind: @core.Recolor,
    sel,
    amount: 1.0,
    hue_deg: hue,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
}

///|
test "Phase 0：parse→canonicalize→render 重放逐位一致" {
  let base = mk_buf(16, 16)
  fill(base, 0, 0, 16, 16, argb(40, 90, 200))
  fill(base, 4, 4, 8, 8, argb(220, 40, 40))
  let ops = [op_recolor("e1", sel_color(30.0, 40.0), 120.0)]
  let prog : @core.EditProgram = { ops, guards: [] }
  let (r1, _) = match run_program(base, prog) {
    Ok(r) => r
    Err(e) => abort("run1: \{e}")
  }
  // canonicalize → 反解 → 重放
  let text = @core.program_to_json(prog)
  let prog2 = match @core.program_from_json(text) {
    Ok(p) => p
    Err(e) => abort("反解失败: \{e}")
  }
  assert_eq(@core.program_to_json(prog2), text, msg="canonical 往返不幂等")
  let (r2, _) = match run_program(base, prog2) {
    Ok(r) => r
    Err(e) => abort("run2: \{e}")
  }
  let total = 16 * 16
  let mut i = 0
  while i < total {
    assert_eq(r2.pixels[i], r1.pixels[i], msg="重放不一致 @\{i}")
    i = i + 1
  }
}

///|
test "Phase 0：A∘B ≠ B∘A（顺序即语义，canonical 化不重排）" {
  // 先暖后换色 vs 先换色后暖——两个不同的算子，交换顺序应产生不同结果
  let base = mk_buf(8, 8)
  fill(base, 0, 0, 8, 8, argb(60, 120, 200))
  let warm : @core.EditOp = {
    id: "warm",
    kind: @core.Temperature,
    sel: sel_geo(0.0, 0.0, 8.0, 8.0),
    amount: 1.0,
    hue_deg: 0.0,
    temp_kelvin: 1500.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  let hue = op_recolor("hue", sel_geo(0.0, 0.0, 8.0, 8.0), 90.0)
  let (ab, _) = match run_program(base, { ops: [warm, hue], guards: [] }) {
    Ok(r) => r
    Err(e) => abort("AB: \{e}")
  }
  let (ba, _) = match run_program(base, { ops: [hue, warm], guards: [] }) {
    Ok(r) => r
    Err(e) => abort("BA: \{e}")
  }
  assert_true(ab.pixels[0] != ba.pixels[0], msg="A∘B 应 ≠ B∘A（顺序是语义）")
}

///|
test "Phase 0：软边界——w=0 处逐位保持原像素（零泄漏）" {
  let base = mk_buf(8, 8)
  // 底图必须**有彩色**：recolor 是 OKLCh 色相重映射，无彩色像素
  // （chroma≈0）没有色相可转，是设计上的恒等操作（见本文件末尾的
  // 「无彩色 recolor 是恒等」回归测试）。用灰底测「选区内生效」会
  // 把正确行为误判成失败。
  fill(base, 0, 0, 8, 8, argb(30, 90, 200))
  // 只选左上角 2x2
  let op : @core.EditOp = op_recolor("e1", sel_geo(0.0, 0.0, 2.0, 2.0), 180.0)
  let (out, _) = match run_program(base, { ops: [op], guards: [] }) {
    Ok(r) => r
    Err(e) => abort("run: \{e}")
  }
  // 选区外必须逐位相同
  let mut y = 0
  while y < 8 {
    let mut x = 0
    while x < 8 {
      if !(x < 2 && y < 2) {
        assert_eq(
          out.pixels[y * 8 + x],
          base.pixels[y * 8 + x],
          msg="选区外泄漏 @(\{x},\{y})",
        )
      }
      x = x + 1
    }
    y = y + 1
  }
  // 选区内应改变
  assert_true(out.pixels[0] != base.pixels[0], msg="选区内未生效")
}

///|
test "Phase 0：undo 逐位回底（程序增删后重放回到 base）" {
  let base = mk_buf(8, 8)
  fill(base, 0, 0, 8, 8, argb(180, 60, 40))
  let op : @core.EditOp = op_recolor("e1", sel_geo(0.0, 0.0, 8.0, 8.0), 200.0)
  let (_after, _) = match run_program(base, { ops: [op], guards: [] }) {
    Ok(r) => r
    Err(e) => abort("after: \{e}")
  }
  // 撤销 = 编辑表清空 → 逐位回 base
  let (restored, _) = match run_program(base, @core.EditProgram::new()) {
    Ok(r) => r
    Err(e) => abort("restore: \{e}")
  }
  let total = 8 * 8
  let mut i = 0
  while i < total {
    assert_eq(restored.pixels[i], base.pixels[i], msg="undo 未逐位回底 @\{i}")
    i = i + 1
  }
}

///|
test "同色异义：纯色窗选中红苹果+红桌布，comp 种子只选中苹果（连通性）" {
  // 左半 = 苹果（圆），右半 = 桌布（矩形），中间留 4px 间隙
  let base = mk_buf(40, 20)
  fill(base, 0, 0, 40, 20, argb(240, 240, 240))
  fill(base, 2, 4, 16, 12, argb(215, 20, 20)) // 苹果
  fill(base, 24, 4, 14, 12, argb(214, 22, 22)) // 桌布（色差 2° 内）
  let ctx = SelCtx::new(base)
  let cache = FieldCache::new()
  // 纯色窗：两者都在窗内
  let pure : Field = match eval_sel(sel_color(25.0, 30.0), ctx, cache) {
    Ok(f) => f
    Err(e) => abort("pure: \{e}")
  }
  let cov_pure = field_sum(pure) / (40.0 * 20.0)
  // 种子连通域：只在苹果内（种子 (9,10)）
  let comp_expr : @core.SelExpr = @core.Atom(
    @core.Comp(9.0, 10.0, 0.02, color_win(25.0, 30.0)),
  )
  let comp_sel : @core.SelSpec = { basis: @core.Base, expr: comp_expr }
  let comp : Field = match eval_sel(comp_sel, ctx, FieldCache::new()) {
    Ok(f) => f
    Err(e) => abort("comp: \{e}")
  }
  let cov_comp = field_sum(comp) / (40.0 * 20.0)
  // 纯色窗覆盖两区域（更大），连通域只覆盖一个（更小）
  assert_true(cov_comp < cov_pure * 0.75, msg="连通域应显著收窄选区：\{cov_comp} vs \{cov_pure}")
  // 连通域内不应触及右侧桌布
  assert_true(
    field_get(comp, 30, 10) < 0.5,
    msg="连通域泄漏到右侧桌布 @x=30",
  )
}

///|
test "Phase 1 表达力上限：colorSel+lumSel 暴力搜索对真值 mask 的 IoU ≥ 0.9" {
  // 真值：画面中央一个纯色方块（真值 mask = 该方块）
  let base = mk_buf(60, 60)
  fill(base, 0, 0, 60, 60, argb(250, 250, 245)) // 近白背景
  fill(base, 20, 20, 20, 20, argb(30, 90, 200)) // 目标色块
  let truth = field_new(60, 60)
  for y in 0..<60 {
    for x in 0..<60 {
      if x >= 20 && x < 40 && y >= 20 && y < 40 {
        truth.v[y * 60 + x] = 1.0
      }
    }
  }
  let ctx = SelCtx::new(base)
  let target = oklab_to_oklch(argb_to_oklab(argb(30, 90, 200)))
  // 暴力搜索：色相窗 × 亮度窗 网格
  let mut best = 0.0
  let mut hw = 5.0
  while hw <= 60.0 {
    let mut lw = 0.05
    while lw <= 0.5 {
      let win : @core.ColorWindow = {
        h_center: target.h,
        h_half: hw,
        s_center: target.c,
        s_half: 0.35,
        l_center: 0.5,
        l_half: 1.0,
        feather: 0.0,
      }
      let expr : @core.SelExpr = @core.Atom(@core.Color(win))
      let spec : @core.SelSpec = { basis: @core.Base, expr }
      let f : Field = match eval_sel(spec, ctx, FieldCache::new()) {
        Ok(x) => x
        Err(e) => abort("search: \{e}")
      }
      let v = iou(f, truth)
      if v > best {
        best = v
      }
      lw = lw + 0.05
    }
    hw = hw + 5.0
  }
  assert_true(best >= 0.9, msg="表达力上限不足：最佳 IoU=\{best} < 0.9（应先改算子代数，不怪 AI）")
}

///|
test "证书：覆盖率/bbox/连通域正确" {
  let base = mk_buf(20, 20)
  fill(base, 0, 0, 20, 20, argb(240, 240, 240))
  fill(base, 5, 5, 4, 4, argb(200, 30, 30))
  fill(base, 14, 14, 3, 3, argb(200, 30, 30))
  let ctx = SelCtx::new(base)
  let f : Field = match eval_sel(sel_color(25.0, 40.0), ctx, FieldCache::new()) {
    Ok(x) => x
    Err(e) => abort("sel: \{e}")
  }
  let cert = certify(base, f)
  assert_eq(cert.components.length(), 2, msg="应检出 2 个连通域")
  // bbox 覆盖两块
  let (bx0, by0, bx1, by1) = cert.bbox
  assert_true(bx0 <= 5 && by0 <= 5, msg="bbox 左上角不对")
  assert_true(bx1 >= 16 && by1 >= 16, msg="bbox 右下角不对")
  // 覆盖率：两块 16+9=25 像素 / 400
  assert_true(cert.coverage > 0.05 && cert.coverage < 0.09, msg="覆盖率 \{cert.coverage} 不合理")
  // 组件面积
  assert_true(cert.components[0].area >= 15, msg="组件 0 面积 \{cert.components[0].area}")
}

///|
test "断言：保护区 ΔE 超限则拒绝（别动人物 = 机器可验证约束）" {
  let base = mk_buf(10, 10)
  // 有彩色底图：无彩色像素的 recolor 是恒等操作，会让断言的
  // 「ΔE 超限 / 改动比例超限」两条都无从触发。
  fill(base, 0, 0, 10, 10, argb(100, 140, 220))
  // 保护区 = 右侧一半；算子 = 全图换色（会侵犯保护区）
  let prot : @core.Guard = {
    id: "g1",
    sel: sel_geo(5.0, 0.0, 5.0, 10.0),
    max_de: 0.01,
    max_changed_ratio: 0.0,
  }
  let op : @core.EditOp = op_recolor("e1", sel_geo(0.0, 0.0, 10.0, 10.0), 180.0)
  let prog : @core.EditProgram = { ops: [op], guards: [prot] }
  let (out, _) = match run_program(base, prog) {
    Ok(r) => r
    Err(e) => abort("run: \{e}")
  }
  let fails = match check_guards(base, out, prog) {
    Ok(f) => f
    Err(e) => abort("guards: \{e}")
  }
  assert_eq(fails.length(), 2, msg="应报两条违反（ΔE + 改动比例）")
}

///|
test "断言通过：无侵犯保护区则零失败" {
  let base = mk_buf(10, 10)
  fill(base, 0, 0, 10, 10, argb(100, 140, 220))
  // 保护区 = 右侧；算子只作用于左侧
  let prot : @core.Guard = {
    id: "g1",
    sel: sel_geo(5.0, 0.0, 5.0, 10.0),
    max_de: 0.05,
    max_changed_ratio: 0.0,
  }
  let op : @core.EditOp = op_recolor("e1", sel_geo(0.0, 0.0, 5.0, 10.0), 180.0)
  let prog : @core.EditProgram = { ops: [op], guards: [prot] }
  let (out, _) = match run_program(base, prog) {
    Ok(r) => r
    Err(e) => abort("run: \{e}")
  }
  let fails = match check_guards(base, out, prog) {
    Ok(f) => f
    Err(e) => abort("guards: \{e}")
  }
  assert_eq(fails.length(), 0, msg="不应有违反")
}

///|
test "diff 证书：选区外泄漏率为 0（软边界不越界）" {
  let base = mk_buf(12, 12)
  fill(base, 0, 0, 12, 12, argb(80, 120, 180))
  let ctx = SelCtx::new(base)
  let cache = FieldCache::new()
  let op : @core.EditOp = op_recolor("e1", sel_geo(2.0, 2.0, 4.0, 4.0), 150.0)
  let w : Field = match op_weight(op, ctx, cache) {
    Ok(f) => f
    Err(e) => abort("weight: \{e}")
  }
  let after = apply_op(base, op, w)
  let rep = diff_report(base, after, w)
  assert_true(rep.leak_ratio == 0.0, msg="选区外泄漏 \{rep.leak_ratio} 应为 0")
  assert_true(rep.changed > 0, msg="选区内应有改动")
  assert_true(rep.sel_de > 0.0, msg="选区内应有 ΔE")
}

///|
test "STAGE(n) 基准：前视引用被拒绝" {
  let base = mk_buf(8, 8)
  fill(base, 0, 0, 8, 8, argb(50, 50, 50))
  // 第 0 个算子引用 STAGE(1)（尚不存在）→ 必须拒绝
  let op0 : @core.EditOp = {
    id: "e0",
    kind: @core.Recolor,
    sel: {
      basis: @core.Stage(1),
      expr: @core.Atom(@core.Color(color_win(30.0, 40.0))),
    },
    amount: 1.0,
    hue_deg: 90.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  let res = run_program(base, { ops: [op0], guards: [] })
  assert_true(res is Err(_), msg="前视 STAGE 引用必须被拒绝")
}

///|
test "旧引擎拒绝未知算子/选择子（不静默错渲）" {
  // 未知算子 kind
  let bad_op = "{\"version\":1,\"ops\":[{\"id\":\"x\",\"kind\":\"neural_gen\",\"sel\":{\"basis\":\"base\",\"expr\":{\"t\":\"color\",\"w\":{\"h\":30,\"hw\":40,\"s\":0.2,\"sh\":0.3,\"l\":0.5,\"lh\":0.5,\"feather\":0}}},\"amount\":1,\"hue_deg\":0,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}],\"guards\":[]}"
  assert_true(@core.program_from_json(bad_op) is Err(_), msg="未知算子必须拒绝")
  // 未知选择子 t
  let bad_sel = "{\"version\":1,\"ops\":[{\"id\":\"x\",\"kind\":\"recolor\",\"sel\":{\"basis\":\"base\",\"expr\":{\"t\":\"hair_sel\",\"w\":{}}},\"amount\":1,\"hue_deg\":0,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}],\"guards\":[]}"
  assert_true(@core.program_from_json(bad_sel) is Err(_), msg="未知选择子必须拒绝")
  // 更高 IR 版本
  let future = "{\"version\":99,\"ops\":[],\"guards\":[]}"
  assert_true(@core.program_from_json(future) is Err(_), msg="更高 IR 版本必须拒绝")
}

///|
test "参数校验：越界/重复 id/隐式参数错配一律拒绝" {
  // amount 越界
  let bad_amount : @core.EditOp = {
    id: "a",
    kind: @core.Recolor,
    sel: sel_geo(0.0, 0.0, 1.0, 1.0),
    amount: 1.5,
    hue_deg: 30.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    refine: [],
    note: "",
    evidence: None,
  }
  assert_true(
    @core.validate_program({ ops: [bad_amount], guards: [] }) is Err(_),
    msg="amount 越界必须拒绝",
  )
  // 非 recolor 却带 hue_deg
  let mismatch : @core.EditOp = {
    id: "b",
    kind: @core.Relight,
    sel: sel_geo(0.0, 0.0, 1.0, 1.0),
    amount: 1.0,
    hue_deg: 30.0,
    temp_kelvin: 0.0,
    relight_gain: 1.2,
    refine: [],
    note: "",
    evidence: None,
  }
  assert_true(
    @core.validate_program({ ops: [mismatch], guards: [] }) is Err(_),
    msg="relight 带 hue_deg 必须拒绝",
  )
  // 重复 id
  let dup = [
    op_recolor("d", sel_geo(0.0, 0.0, 1.0, 1.0), 10.0),
    op_recolor("d", sel_geo(0.0, 0.0, 1.0, 1.0), 20.0),
  ]
  assert_true(
    @core.validate_program({ ops: dup, guards: [] }) is Err(_),
    msg="重复 id 必须拒绝",
  )
}

///|
test "外部 mask 资产未登记时报精确错误（照片入口的诚实边界）" {
  let base = mk_buf(4, 4)
  let ctx = SelCtx::new(base)
  let expr : @core.SelExpr = @core.Atom(@core.AssetMask("deadbeef"))
  let spec : @core.SelSpec = { basis: @core.Base, expr }
  let res = eval_sel(spec, ctx, FieldCache::new())
  assert_true(res is Err(_), msg="未登记 mask 资产必须报错")
}

///|
test "geo 矩形谓词：命中区就是矩形本身（到边界的距离，不是到中心的距离）" {
  // 回归：rect_dist 曾写成「到矩形中心的距离」。后果是矩形中心
  // 只有落在半宽内才算命中，选区整体缩到 1/4，全图选区的算子在
  // 图像中心之外一律不生效（A∘B 与 B∘A 因此都变成恒等）。
  let base = mk_buf(8, 8)
  fill(base, 0, 0, 8, 8, argb(30, 90, 200))
  let ctx = SelCtx::new(base)
  let f = match eval_sel(sel_geo(2.0, 2.0, 4.0, 4.0), ctx, FieldCache::new()) {
    Ok(x) => x
    Err(e) => abort("geo: \{e}")
  }
  let mut inside = 0
  let mut outside = 0.0
  for y in 0..<8 {
    for x in 0..<8 {
      let w = field_get(f, x, y)
      if x >= 2 && x < 6 && y >= 2 && y < 6 {
        assert_true(w == 1.0, msg="矩形内 (\{x},\{y}) 权重应为 1，实为 \{w}")
        inside = inside + 1
      } else {
        assert_true(w == 0.0, msg="矩形外 (\{x},\{y}) 权重应为 0，实为 \{w}")
        outside = outside + w
      }
    }
  }
  assert_eq(inside, 16, msg="矩形命中像素数应为 4×4")
  assert_true(outside == 0.0, msg="矩形外不得有泄漏")
}

///|
test "对全图做 recolor：图像中心必须生效（geo 全图选区回归）" {
  let base = mk_buf(8, 8)
  fill(base, 0, 0, 8, 8, argb(60, 120, 200))
  let op = op_recolor("e1", sel_geo(0.0, 0.0, 8.0, 8.0), 90.0)
  let (out, _) = match run_program(base, { ops: [op], guards: [] }) {
    Ok(r) => r
    Err(e) => abort("run: \{e}")
  }
  let center = 4 * 8 + 4
  assert_true(out.pixels[center] != base.pixels[center], msg="图像中心未被选中")
  assert_true(out.pixels[0] != base.pixels[0], msg="图像左上角未被选中")
}

///|
test "canonical 往返：evidence=null 不被膨胀成空证据对象" {
  // 回归：evidence_of 曾把 Some(JNull) 也构造成 Some(空 Evidence)，
  // 于是 program_to_json ∘ program_from_json 不再幂等
  // （"evidence":null 被改写成一整块 {"label":"","pos":[],"neg":[]}）。
  let op0 = op_recolor("e1", sel_geo(0.0, 0.0, 1.0, 1.0), 30.0)
  let t0 = @core.program_to_json({ ops: [op0], guards: [] })
  assert_true(t0.contains("\"evidence\":null"), msg="无证据应序列化为 null：\{t0}")
  let p0 = match @core.program_from_json(t0) {
    Ok(p) => p
    Err(e) => abort("反解: \{e}")
  }
  assert_eq(@core.program_to_json(p0), t0, msg="evidence=null 往返被改写")
  // 带确定性证据（AI 语义编译成种子点）也要能逐字节往返
  let ev : @core.Evidence = {
    label: "红苹果",
    pos_seeds: [(9.0, 10.0), (11.0, 12.0)],
    neg_seeds: [(30.0, 10.0)],
  }
  let op1 : @core.EditOp = { ..op0, id: "e2", evidence: Some(ev) }
  let t1 = @core.program_to_json({ ops: [op1], guards: [] })
  let p1 = match @core.program_from_json(t1) {
    Ok(p) => p
    Err(e) => abort("反解: \{e}")
  }
  assert_eq(@core.program_to_json(p1), t1, msg="带证据往返不幂等")
  let back = match p1.ops[0].evidence {
    Some(x) => x
    None => abort("证据丢失")
  }
  assert_eq(back.label, "红苹果", msg="证据 label 丢失")
  assert_eq(back.pos_seeds.length(), 2, msg="正种子丢失")
  assert_eq(back.neg_seeds.length(), 1, msg="负种子丢失")
}


///|
