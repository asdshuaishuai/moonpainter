// 白盒测试：直接调包内私有的 `build_shape_layer`。
//
// 为什么需要它：`add-rect points=…` 现在**先**被 `check_kv_args` 的键集拦下
// （`points` 不在 rect 的键集里），于是 `build_shape_layer` 里那道
// "points 只对 polygon/line 有意义" 的 kind 门**从命令面走不到**了。门本身
// 仍要留着（它是语义上的断言，且 `add-image` 这类不过键校验的调用方直通
// 这里），但"走不到"意味着没有测试守着它——变异注入进去会存活。所以直接
// 调它，让那道门可测。

///|
test "build_shape_layer：非 polygon/line 给 points 必须拒绝（命令面走不到的兜底门）" {
  let m : Map[String, String] = Map([])
  m.set("points", "0,0;5,5")
  m.set("w", "20")
  m.set("h", "20")
  // rect：必须拒绝（渲染器只在 in_polygon 与折线描边里读顶点）
  match build_shape_layer("r1", @core.ShapeKind::Rect, m) {
    Ok(_) => abort("rect 上的 points 必须被拒")
    Err(e) => assert_true(e.contains("只对 polygon/line 有意义"), msg=e)
  }
  // polygon：够数就接受（样本从 2 个顶点改成 3 个——不是"迁就测试"：
  // `in_polygon` 第一句就是 `if pts.length() < 3 { return false }`，
  // 2 顶点的 polygon 一个像素都不画，属于"装了却什么都不干"，现在入口就拒）
  m.set("points", "0,0;5,5;10,0")
  match build_shape_layer("p1", @core.ShapeKind::Polygon, m) {
    Ok(l) => assert_eq(l.points.length(), 3, msg="polygon 要收下顶点")
    Err(e) => abort("polygon 的 points 不该被拒：\{e}")
  }
  // 同一道门里再加一格：顶点数不足也要拒（哪怕 kind 是对的）
  m.set("points", "0,0;5,5")
  match build_shape_layer("p2", @core.ShapeKind::Polygon, m) {
    Ok(_) => abort("2 顶点的 polygon 必须被拒（渲染器不围面）")
    Err(e) => assert_true(e.contains("至少要 3 个顶点"), msg=e)
  }
  // line：2 个顶点就够（它画的是线段，不围面）
  m.set("points", "0,0;5,5")
  match build_shape_layer("l1", @core.ShapeKind::Line, m) {
    Ok(l) => assert_eq(l.points.length(), 2, msg="2 顶点的线段合法")
    Err(e) => abort("2 顶点的 line 不该被拒：\{e}")
  }
}
