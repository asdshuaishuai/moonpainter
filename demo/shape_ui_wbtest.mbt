///|
/// 形状绘制（矩形/椭圆拖拽 + 折线/多边形逐点）的**纯核心**测试。
/// 交互那一半（画布事件、预览层）只有浏览器里点得动，所以判据全部压在
/// 这些纯函数上：点列 → 命令行这一步错了，画出来就是另一块地方/另一条边。

///|
test "严格解析：非数不许静默退默认（否则\"读不出来\"会变成\"画在左上角\"）" {
  assert_eq(strict_int("12"), Some(12))
  assert_eq(strict_int("-3"), Some(-3))
  assert_eq(strict_int(" 40 "), Some(40))
  assert_eq(strict_int(""), None)
  assert_eq(strict_int("-"), None)
  assert_eq(strict_int("1x"), None)
  assert_eq(strict_int("1.5"), None)
  // 反例对照：宽松解析器（parse_double_safe）对同样的输入回 0.0——
  // 所以拿它当坐标就是"读失败 = 画在原点"，本条测试守的就是这个差别
  assert_eq(parse_double_safe("1x"), 0.0)
}

///|
test "拖拽框解析：四个整数，缺一个就整体放弃（不许部分成功）" {
  assert_eq(box4("10,20,30,40"), Some((10, 20, 30, 40)))
  assert_eq(box4("-5,-6,7,8"), Some((-5, -6, 7, 8)))
  assert_eq(box4("10,20,30"), None)
  assert_eq(box4("10,20,30,40,50"), None)
  assert_eq(box4("10,20,30,x"), None)
  assert_eq(box4(""), None)
  assert_eq(xy2("3,4"), Some((3, 4)))
  assert_eq(xy2("3,4,5"), None)
  assert_eq(xy2("3,"), None)
}

///|
test "落点：连点两次同一处只算一个点（双击会先落两个同坐标的点）" {
  let p0 : Array[(Int, Int)] = []
  let p1 = poly_add(p0, 5, 6)
  assert_eq(p1.length(), 1)
  assert_eq(p1[0], (5, 6))
  let p2 = poly_add(p1, 5, 6)
  assert_eq(p2.length(), 1)
  let p3 = poly_add(p2, 5, 7)
  assert_eq(p3.length(), 2)
  // 首尾相同不算重复（多边形要能闭合回起点）
  let tri = poly_add(poly_add(poly_add(p0, 0, 0), 10, 0), 0, 0)
  assert_eq(tri.length(), 3)
}

///|
test "包围盒：宽高至少 1（水平的折线盒高是 0，而引擎的 w/h>0 是硬下界）" {
  assert_eq(pts_box([(10, 20), (40, 60)]), (10, 20, 30, 40))
  // 水平线：h 会被引擎拒 → 取 1，点仍落在盒内（局部 y 都是 0）
  assert_eq(pts_box([(10, 20), (40, 20)]), (10, 20, 30, 1))
  assert_eq(pts_box([(10, 20), (10, 60)]), (10, 20, 1, 40))
  assert_eq(pts_box([(7, 7)]), (7, 7, 1, 1))
  assert_eq(pts_box([]), (0, 0, 1, 1))
  // 局部化：整体位移去掉，形状本身的形状不变
  assert_eq(pts_local([(10, 20), (40, 60), (25, 30)]), [(0, 0), (30, 40), (15, 10)])
}

///|
test "points= 串用分号分隔（引擎的 pts 语法）" {
  assert_eq(pts_str([(0, 0), (10, 20)]), "0,0;10,20")
  assert_eq(pts_str([(1, 2)]), "1,2")
  assert_eq(pts_str([]), "")
}

///|
test "点数下界与引擎同一把尺子：折线 ≥2、多边形 ≥3" {
  assert_true(!shape_ready("line", 0), msg="0 个点画不出折线")
  assert_true(!shape_ready("line", 1), msg="1 个点画不出折线")
  assert_true(shape_ready("line", 2), msg="2 个点就是一条线段")
  assert_true(!shape_ready("poly", 2), msg="2 个点画不出多边形（引擎 in_polygon 也要 ≥3）")
  assert_true(shape_ready("poly", 3))
  // 提示语要说出"还差几个"，而且空集也要说话（0 个点时人需要确认工具切过来了）
  assert_true(has_sub(poly_hint("poly", 0), "还差 3 个"), msg=poly_hint("poly", 0))
  assert_true(has_sub(poly_hint("line", 1), "还差 1 个"), msg=poly_hint("line", 1))
  assert_true(has_sub(poly_hint("poly", 4), "双击"), msg=poly_hint("poly", 4))
}

///|
test "形状命令行：盒子跟着点走、点是局部坐标、折线描边/多边形填充各取所需" {
  // 矩形块：x/y 取包围盒原点，points 相对它，w/h 是盒尺寸
  let tri : Array[(Int, Int)] = [(100, 50), (160, 50), (130, 110)]
  let l = shape_line("poly", tri, "#112233FF", "#445566FF", "2")
  assert_true(has_sub(l, "add-polygon x=100 y=50 w=60 h=60"), msg=l)
  assert_true(has_sub(l, "points=0,0;60,0;30,60"), msg=l)
  assert_true(has_sub(l, "fill=#112233FF"), msg=l)
  assert_true(lacks_sub(l, "stroke="), msg="多边形命令不吃 stroke：\{l}")
  let ln = shape_line("line", [(10, 20), (40, 80)], "#112233FF", "#445566FF", "3")
  assert_true(has_sub(ln, "add-line x=10 y=20 w=30 h=60"), msg=ln)
  assert_true(has_sub(ln, "points=0,0;30,60"), msg=ln)
  assert_true(has_sub(ln, "stroke=#445566FF stroke_w=3"), msg=ln)
  assert_true(lacks_sub(ln, "fill="), msg="折线命令不吃 fill：\{ln}")
  // 水平的折线：盒高被抬到 1，局部点仍在 y=0（不是被推到盒中间）
  let flat = shape_line("line", [(0, 5), (9, 5)], "#000000FF", "#000000FF", "1")
  assert_true(has_sub(flat, "x=0 y=5 w=9 h=1"), msg=flat)
  assert_true(has_sub(flat, "points=0,0;9,0"), msg=flat)
  // 命令名由 kind 决定：kind 只有这两种（do_shape_ready 那条路是 add-rect/add-ellipse）
  assert_true(has_sub(shape_line("poly", tri, "#112233FF", "#112233FF", "1"), "add-polygon"), msg="poly 必须发 add-polygon")
}

///|
test "工具条：两个拖拽形状 + 两个逐点形状都有按钮，且都切得过去" {
  let h = app_html()
  for t in ["rect", "ellipse", "line", "poly"] {
    assert_true(
      has_sub(h, "data-tool='" + t + "'"),
      msg="工具条少了 \{t} 的按钮：点了就没有入口",
    )
  }
  assert_true(has_sub(h, "globalThis.__tool(\"line\")"), msg=h)
  assert_true(has_sub(h, "globalThis.__tool(\"poly\")"), msg=h)
}
