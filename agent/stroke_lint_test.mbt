// 描边的两条「护栏改了输出却没人报」（PLAN 十九 / 四十六）。
//
// 它们与「读点矩阵」不是同一类：那里的组合是**字段根本不被读**（写进去
// 画面逐位不变），这里的值**被读了**，只是画出来不是调用方以为的东西：
//   ① 矩形/椭圆的描边朝内，`2*stroke_w >= min(w,h)` 时内缩盒退化成空
//      ⇒ fill 一个像素看不见（实测 20×20 + stroke_w=10 中心就是描边色）；
//   ② 线段描边以线段为中心，胶囊伸出层盒子，而渲染窗只有「盒子对角线为边
//      + 2px」⇒ 窗外的两侧与圆头**根本不画**（实测 8×4 盒 + stroke_w=20
//      只画出 13×13 的方块）。
// 两条都是 `lint` 报、命令面不拦——同 `adjust value=0` 那条分工。

///|
test "lint：描边盖满整层 / 伸出渲染窗都要报，正常描边一个字都不报" {
  let s = scene("lint-stroke")
  let _ = run(s, "new 60 60")

  // ① 盖满整层：20×20 的矩形 + 描边 10（正好是 min/2，等号也算退化）
  let _ = run(s, "add-rect id=r1 x=5 y=5 w=20 h=20 fill=#0000FFFF stroke=#FF0000FF stroke_w=10")
  let a = run(s, "lint")
  assert_true(jnum_field(a, "violations") == 1.0, msg="描边盖满整层要报且只报一条：\{a}")
  // 咬住**数值**（宽度与它盖住的盒子），不只咬措辞
  assert_true(
    a.contains("盖满整层") && a.contains("描边宽 10") && a.contains("20x20"),
    msg="要报出描边宽与盒子尺寸：\{a}",
  )
  // 正控（边界内侧）：9 ⇒ 内缩盒还剩 2px ⇒ 一个像素的 fill 都还看得见
  let _ = run(s, "set-style r1 stroke_w=9")
  let b = run(s, "lint")
  assert_true(jnum_field(b, "violations") == 0.0, msg="stroke_w=9 不该报（判据是 2*sw >= min）：\{b}")
  // 椭圆走同一条判据（它的描边也朝内）
  let _ = run(s, "add-ellipse id=e1 x=5 y=5 w=20 h=20 stroke=#FF0000FF stroke_w=10")
  let c = run(s, "lint")
  assert_true(jnum_field(c, "violations") == 1.0, msg="椭圆的描边也朝内、也要报：\{c}")
  let _ = run(s, "delete e1")

  // ② 伸出渲染窗：8×4 的盒子 + 20 宽的描边 ⇒ 实测只画出 13×13
  let _ = run(s, "add-line id=l1 x=16 y=28 w=8 h=4 points=0,2;8,2 stroke=#FF0000FF stroke_w=20")
  let d = run(s, "lint")
  assert_true(jnum_field(d, "violations") == 1.0, msg="描边伸出渲染窗要报：\{d}")
  assert_true(d.contains("渲染窗") && d.contains("描边（宽 20）"), msg="要说清是窗裁的、裁的是多宽：\{d}")
  // 正控①：**容差必须钉在"窗的 2px 松弛量"上**。8×4 盒 + 8 宽的描边时，右边
  // 圆头正好比窗多出 2.0px（= 松弛量）⇒ 不报；9 宽多出 2.5px ⇒ 报。这一对是
  // 把容差从「出窗即报」区分开的**唯一**判别点——原先拿 4 宽当正控（超出量 0），
  // 把 `> 2.0` 改成 `> 0.0` 的变异照样存活（实测 Q51 就是这样活的）。
  let _ = run(s, "set-style l1 stroke_w=8")
  let e0 = run(s, "lint")
  assert_true(jnum_field(e0, "violations") == 0.0, msg="超出量正好 = 松弛量时不该报：\{e0}")
  let _ = run(s, "set-style l1 stroke_w=9")
  let e1 = run(s, "lint")
  assert_true(jnum_field(e1, "violations") == 1.0, msg="超出松弛量一点就要报：\{e1}")
  // 正控①'：远在松弛量以内（4 宽只被切 0px）也不报
  let _ = run(s, "set-style l1 stroke_w=4")
  let e = run(s, "lint")
  assert_true(jnum_field(e, "violations") == 0.0, msg="松弛量以内不该报：\{e}")
  // 正控②：盒子大到窗装得下 ⇒ 不报（40×40 盒装 6 宽的描边）
  let _ = run(s, "add-line id=l2 x=5 y=5 w=40 h=40 points=0,0;40,40 stroke=#FF0000FF stroke_w=6")
  let f = run(s, "lint")
  assert_true(jnum_field(f, "violations") == 0.0, msg="窗装得下就不该报：\{f}")
  // 正控③：**窗是轴对齐的，胶囊不是** —— 同一层只差一个 `rot`：
  // 40×40 的对角线 + 12 宽的描边，不转时窗装得下（0 条），转 30° 后胶囊出窗（1 条）。
  // 这一对同时钉住"换算必须走 `to_canvas`"：用局部坐标加平移算就会漏掉旋转。
  let _ = run(s, "new 60 60")
  let _ = run(s, "add-line id=l3 x=5 y=5 w=40 h=40 points=0,0;40,40 stroke=#FF0000FF stroke_w=12")
  let h1 = run(s, "lint")
  assert_true(jnum_field(h1, "violations") == 0.0, msg="不转时窗装得下，不该报：\{h1}")
  let _ = run(s, "set-style l3 rot=30")
  let h2 = run(s, "lint")
  assert_true(jnum_field(h2, "violations") == 1.0, msg="转 30° 后胶囊出窗，必须报：\{h2}")

  // 正控④：多边形不画描边（读点矩阵里它就是「不读」）⇒ 再宽也不该按这两条报
  // （先清画布：上一条的 l3 还在，它本来就该报一条）
  let _ = run(s, "new 60 60")
  let _ = run(s, "add-polygon id=p1 x=5 y=5 w=20 h=20 points=0,0;20,0;0,20 fill=#00FF00FF")
  let _ = run(s, "set-style p1 stroke_w=40")
  let g = run(s, "lint")
  assert_true(jnum_field(g, "violations") == 0.0, msg="多边形没有描边实现，不该报窗裁：\{g}")
}

///|
/// 手改容器那条路：`lint_doc` 直接吃一个文档，命令面进不来的状态也要判得对。
/// 这里钉住三件事——**多边形/位图/文本上带着描边不该按这两条报**（它们压根
/// 没有描边实现，读点矩阵里就是「不读」）；**整层在画布外时不该报**（窗外
/// 那部分本来就不在画布里，没有可见损失）。
test "lint：描边两条规则的边界（没有描边实现的 kind / 整层在画布外）" {
  let doc = @core.new_document("lint-stroke-edge", 60, 60)
  let b = @core.default_layer("k0", "k", 0.0, 0.0, 20.0, 20.0)
  let sw = fn(w : Double) { @core.Stroke::{ color: 0xFF0000FF, width: w } }
  // 多边形/位图/文本：带着再宽的描边也不该报这两条（渲染器不读）
  doc.layers.push({
    ..b,
    id: "pg",
    kind: @core.ShapeKind::Polygon,
    points: [(0.0, 0.0), (20.0, 0.0), (0.0, 20.0)],
    stroke: sw(40.0),
  })
  doc.layers.push({ ..b, id: "im", kind: @core.ShapeKind::Image, asset_hash: "x", stroke: sw(40.0) })
  doc.layers.push({ ..b, id: "tx", kind: @core.ShapeKind::Text, text: "A", stroke: sw(40.0) })
  let v1 = @agent.lint_doc(doc)
  // 只看**这两条新规则**的话（「读点矩阵」那条会报它们带着描边，那是对的：
  // 那些字段在渲染器里根本不被读）
  let stroke_hits = v1.filter(fn(s) { s.contains("盖满整层") || s.contains("伸出渲染窗") })
  assert_true(stroke_hits.length() == 0, msg="没有描边实现的 kind 不该报这两条：\{v1.join(" | ")}")
  // 整层在画布外（x=-500）：窗外那部分不在画布里，没有可见损失 ⇒ 不报
  doc.layers.push({
    ..b,
    id: "off",
    x: -500.0,
    y: 28.0,
    w: 8.0,
    h: 4.0,
    kind: @core.ShapeKind::Line,
    points: [(0.0, 2.0), (8.0, 2.0)],
    stroke: sw(20.0),
  })
  let v2 = @agent.lint_doc(doc)
  let off_hits = v2.filter(fn(s) { s.contains("伸出渲染窗") || s.contains("盖满整层") })
  assert_true(off_hits.length() == 0, msg="整层在画布外时不该报窗裁：\{v2.join(" | ")}")
}
