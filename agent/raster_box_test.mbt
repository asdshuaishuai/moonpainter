// 笔触层的盒子是**派生**的（PLAN 六十）——报告面跟着**落笔范围**走。
//
// 这一格的历史：`w/h` 曾经"一条渲染路径都不读、只有报告面读"，于是缩盒子
// 画面逐位不变而 `query-layer`/`overlay` 线框照旧报小盒子 ⇒ 报告面与画面
// **分家**，靠一条 `lint`（`raster_box_error`）兜住。现在盒子由
// `@core.effective_box` 认 Raster（= `raster_bbox`，落笔范围的并集）**派生**，
// 那份分家**不可能**出现 ⇒ 那条 `lint` 与它的三条变异（Q53/Q54/Q55）一起退休。
//
// 退休不等于没人守：这一格现在守的是**反向**不变量——报告面（`query-layer` 的
// x/y/w/h、`overlay=1` 的线框）**必须**等于画面上的落笔范围，`resize` 那份
// 快照谁都读不到。

///|
test "报告面跟着落笔范围走：resize 改不动、move 一起挪、线框逐位不变" {
  let s = scene("raster-box-derived")
  let _ = run(s, "new 320 240")
  let _ = run(s, "add-paint id=p1")
  let _ = run(s, "brush layer=p1 pts=100,100;160,130 r=12 color=#FF0000FF")
  // 落笔范围 = 圆心 (100,100)/(160,130) ± 12 ⇒ (88,88)-(172,142)，宽高 84×54
  assert_eq(gmove_layer_num(s, "p1", "x"), 88.0, msg="报告 x = 落笔范围左边界")
  assert_eq(gmove_layer_num(s, "p1", "y"), 88.0, msg="报告 y")
  assert_eq(gmove_layer_num(s, "p1", "w"), 84.0, msg="报告 w = 落笔范围宽")
  assert_eq(gmove_layer_num(s, "p1", "h"), 54.0, msg="报告 h")
  // `overlay=1` 的线框走同一个盒子 ⇒ 它现在是"看得见的范围"的**忠实**线框
  let ov0 = jstr_field(run(s, "render 320 overlay=1"), "render_sha256")
  let sha0 = jstr_field(run(s, "render 320"), "render_sha256")
  // 缩盒子到 10×10：画面与**报告**都必须一动不动（盒子是派生的）
  let _ = run(s, "resize p1 10 10")
  assert_eq(gmove_layer_num(s, "p1", "w"), 84.0, msg="resize 改不动派生的盒子（仍报落笔范围）")
  assert_eq(gmove_layer_num(s, "p1", "h"), 54.0, msg="resize 改不动派生的盒子（高）")
  assert_eq(jstr_field(run(s, "render 320"), "render_sha256"), sha0, msg="缩盒子画面逐位不变")
  assert_eq(
    jstr_field(run(s, "render 320 overlay=1"), "render_sha256"),
    ov0,
    msg="线框也跟着派生盒走 ⇒ 缩盒子线框逐位不变（报告面与画面没有分家）",
  )
  // ⚠️ 这条 `lint`（"盒子装不下自己的笔触"）**已退休**：缩到 10×10 也不再报。
  // 断言写成"violations == 0"是**负控**——退休后若有人把它加回来（用旧语义），
  // 这条会红。
  assert_true(jnum_field(run(s, "lint"), "violations") == 0.0, msg="派生盒不可能装不下笔触")
  // `move` 是**真的挪笔触**：报告与画面一起走（两者仍然一致）
  let _ = run(s, "move p1 5 7")
  assert_eq(gmove_layer_num(s, "p1", "x"), 93.0, msg="move 之后报告跟着挪")
  assert_eq(gmove_layer_num(s, "p1", "y"), 95.0, msg="move 之后报告跟着挪（y）")
  assert_true(
    jstr_field(run(s, "render 320"), "render_sha256") != sha0,
    msg="move 必须真的改画面（笔触是画出来的）",
  )
}

///|
test "盒子的三个来源一致：`query-layer` 报的 == 渲染窗 == 落笔范围" {
  // 一处判据：`@core.effective_box` 同时喂报告面与渲染（`local_pivot`/
  // `dab_center` 的轴心）。这里用**局部坐标**造两个极端：一个 dab 在原点附近、
  // 一个远在天边——盒子必须横跨两者，而不是只看第一个（`group_bbox` 的并集
  // 初值就栽过：拿第一个成员存下来的盒子当初值会吞掉整个并集，Q80）。
  let d = @core.new_document("raster-box-union", 100, 100)
  d.layers.push(
    {
      ..@core.default_layer("r1", "r1", 3.0, 5.0, 100.0, 100.0),
      kind: @core.ShapeKind::Raster,
      dabs: [
        @core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFF0000FF, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
        @core.Dab::{ x: 70.0, y: 60.0, r: 4.0, color: 0xFF0000FF, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
      ],
    },
  )
  // 局部 (20,20)±6 与 (70,60)±4 ⇒ 并集 (14,14)-(74,64)，加层位 (3,5)
  // ⇒ 画布 (17,19)-(77,69)：宽 60、高 50
  let (bx, by, bw, bh) = @core.effective_box(d.layers[0])
  assert_eq((bx, by, bw, bh), (17.0, 19.0, 60.0, 50.0), msg="并集要横跨两个 dab")
  // 半径 0 的 dab **不落墨**（`dabs_window` 同样跳过）⇒ 不算进范围
  let l0 = d.layers[0]
  d.layers[0] = {
    ..l0,
    dabs: [
      @core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFF0000FF, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
      @core.Dab::{ x: 99.0, y: 99.0, r: 0.0, color: 0xFF0000FF, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
    ],
  }
  let (bx2, by2, bw2, bh2) = @core.effective_box(d.layers[0])
  assert_eq((bx2, by2, bw2, bh2), (17.0, 19.0, 12.0, 12.0), msg="r=0 的 dab 不算内容")
}
