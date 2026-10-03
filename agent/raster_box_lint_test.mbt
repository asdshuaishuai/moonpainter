// 笔触层盒子与画面分家（PLAN 四十八/四十九）。
//
// 这一条是文本层「盒子装不下自己的文字」的**兄弟**，但错位机制不同：
// 文本层的盒子参与渲染（不裁剪 ⇒ 字画到盒子外），而笔触层的 `w/h` **一条渲染
// 路径都不读**（`paint_raster` 的窗口是画布尺寸）——缩盒子画面**逐位不变**
// （另见 `render/raster_box_test.mbt` 的不变量测试），变的只有报告面：
// `query-layer` 与 `overlay=1` 的线框照盒子报。
// 命令面**不拦** `resize`（合法操作），所以 `lint` 是唯一的出口。

///|
test "lint：笔触层盒子装不下笔触要报（命令面 resize 那条路）" {
  let s = scene("lint-raster-box")
  let _ = run(s, "new 320 240")
  let _ = run(s, "add-paint id=p1")
  let _ = run(s, "brush layer=p1 pts=100,100;160,130 r=12 color=#FF0000FF")
  // 正控：全画布盒子装得下（笔触范围 x 88..172 / y 88..142）
  let a = run(s, "lint")
  assert_true(jnum_field(a, "violations") == 0.0, msg="全画布盒子装得下笔触，不该报：\{a}")
  // 正控：`move` 是安全的——盒子与笔触**一起**挪，两者仍然一致
  let _ = run(s, "move p1 5 7")
  let b = run(s, "lint")
  assert_true(jnum_field(b, "violations") == 0.0, msg="move 之后盒子与笔触一起挪，仍不该报：\{b}")
  // 缩盒子到 10×10：画面逐位不变，报告面分家 ⇒ 必须报，且咬住**数值**
  let _ = run(s, "resize p1 10 10")
  let c = run(s, "lint")
  assert_true(jnum_field(c, "violations") == 1.0, msg="缩到 10×10 要报且只报一条：\{c}")
  // ⚠️ 续行开头的 `&&` 是**解析错误**（本仓库踩过）——拼接写成一句，或先 let 成布尔
  let hit = c.contains("装不下自己的笔触") && c.contains("可见范围 93,95–177,149") && c.contains("盒子 5,7–15,17")
  assert_true(hit, msg="要报出可见范围与盒子边界（数值，不是措辞）：\{c}")
  // 放大回装得下 ⇒ 恢复 0 条（判据两头都咬得住）
  let _ = run(s, "resize p1 320 240")
  let d = run(s, "lint")
  assert_true(jnum_field(d, "violations") == 0.0, msg="盒子放大到装得下就回到 0 条：\{d}")
}

///|
test "lint：笔触盒子判据的边界（等号算装得下 / 半径要算 / 画布外不算错位）" {
  // dab 的局部范围 = 14,14–26,26（圆心 20 + 半径 6）
  let d1 = @core.new_document("lint-raster-edge", 100, 100)
  d1.layers.push(
    {
      ..@core.default_layer("r1", "r1", 0.0, 0.0, 26.0, 26.0),
      kind: @core.ShapeKind::Raster,
      dabs: [@core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFF0000FF, erase: false }],
    },
  )
  assert_true(@agent.lint_doc(d1).length() == 0, msg="盒子正好 26×26 = 笔触范围（等号）⇒ 不该报")
  // 边界外侧一点点：25.9 ⇒ 圆的**半径**算进去了（圆心 20 明明在盒内）
  let l0 = d1.layers[0]
  d1.layers[0] = { ..l0, w: 25.9 }
  let v = @agent.lint_doc(d1)
  let vs = v.join(" | ")
  assert_true(
    v.length() == 1 && v[0].contains("装不下自己的笔触") && v[0].contains("0,0–25.9,26"),
    msg="25.9 就该报（半径 6 要算进去）：\{vs}",
  )
  // 画布外不算错位：层挪到画布外 ⇒ 可见部分是空的。
  // ⚠️ 必须**单轴**出画布（l.x=200 但 y 在画布内）：整层都在画布外时，判据会在
  // 另一个轴上先判成"一个像素都剩不下"而提前 return —— 那样"x 轴忘了按画布裁剪"
  // 这个变异照旧存活（Q55 第一版就是这么活下来的）。
  let d2 = @core.new_document("lint-raster-off", 100, 100)
  d2.layers.push(
    {
      ..@core.default_layer("r2", "r2", 200.0, 0.0, 10.0, 10.0),
      kind: @core.ShapeKind::Raster,
      dabs: [@core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFF0000FF, erase: false }],
    },
  )
  // ⚠️ 只筛**自己这条规则**：盒子整个在画布外时，「层完全在画布外」那条旧规则
  // 本来就会报（它报的是另一件事），拿"总条数 == 0"当断言会误伤自己。
  let v2 = @agent.lint_doc(d2)
  let n2 = v2.filter(fn(m) { m.contains("装不下自己的笔触") }).length()
  assert_true(n2 == 0, msg="笔触整个在画布外（画不出一像素）⇒ 没有可见的错位，这条不该报：\{v2.join(" | ")}")
  // 对称的另一轴：l.y=200、x 在画布内
  let d2b = @core.new_document("lint-raster-off-y", 100, 100)
  d2b.layers.push(
    {
      ..@core.default_layer("r2b", "r2b", 0.0, 200.0, 10.0, 10.0),
      kind: @core.ShapeKind::Raster,
      dabs: [@core.Dab::{ x: 20.0, y: 20.0, r: 6.0, color: 0xFF0000FF, erase: false }],
    },
  )
  let v2b = @agent.lint_doc(d2b)
  let n2b = v2b.filter(fn(m) { m.contains("装不下自己的笔触") }).length()
  assert_true(n2b == 0, msg="y 轴出画布同理（画不出一像素 ⇒ 没有可见错位）：\{v2b.join(" | ")}")
  // 半径不落墨（r=0）的 dab 不算内容：盒子再小也不该报
  let d3 = @core.new_document("lint-raster-r0", 100, 100)
  d3.layers.push(
    {
      ..@core.default_layer("r3", "r3", 0.0, 0.0, 1.0, 1.0),
      kind: @core.ShapeKind::Raster,
      dabs: [@core.Dab::{ x: 90.0, y: 90.0, r: 0.0, color: 0xFF0000FF, erase: false }],
    },
  )
  let v3 = @agent.lint_doc(d3)
  let n3 = v3.filter(fn(m) { m.contains("装不下自己的笔触") }).length()
  assert_true(n3 == 0, msg="r=0 的 dab 不落墨，不该算进范围：\{v3.join(" | ")}")
}
