/// 布尔运算的**几何判据**（④ Stage B）。
///
/// 口径：每个操作都拿**面积**对账，而不是"环数对得上就算过"——
/// 两个 40×40 的矩形错开 20 时，并/交/差/异或的面积是**只有几何对才出得来**的四个数
/// （2800 / 400 / 1200 / 2400）。环数、方向（岛 vs 洞）、以及"某个点到底在不在结果里"
/// 都要分开咬：面积对而环路方向错，画面就是"洞被填上"。
/// 每条断言前先自证判别力（错的答案确实会不等于那个数）。

///|
/// 一个轴对齐矩形环（CCW：右下左上）。
fn rect_ring(x : Double, y : Double, w : Double, h : Double) -> Array[(Double, Double)] {
  [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
}

///|
/// 环列表面积之和（正负都算，用来对账"带洞"的结果：岛 − 洞）。
fn net_area(loops : Array[Array[(Double, Double)]]) -> Double {
  let mut s = 0.0
  for r in loops {
    s = s + @core.polygon_area(r)
  }
  s
}

///|
/// 点是否落在结果里：在某个岛内、且不在任何洞里（**奇偶**口径与填充一致）。
fn inside_result(loops : Array[Array[(Double, Double)]], x : Double, y : Double) -> Bool {
  let mut inside = false
  for r in loops {
    let a = @core.polygon_area(r)
    if a > 0.0 && @core.path_contains(r, [], true, x, y) {
      inside = true
    } else if a < 0.0 && @core.path_contains(r, [], true, x, y) {
      inside = false
    }
  }
  inside
}

///|
test "布尔运算：两个错开 20 的 40×40 矩形，四个操作面积各是 2800/1200/400/2400" {
  let a = rect_ring(0.0, 0.0, 40.0, 40.0)
  let b = rect_ring(20.0, 20.0, 40.0, 40.0)
  // 判别力自证：两个矩形的面积和是 3200，而下面四个数都不是它（否则断言是空的）
  assert_eq(@core.polygon_area(a), 1600.0)
  assert_eq(@core.polygon_area(b), 1600.0)
  let u = match @core.boolean_loops(@core.BoolOp::Union, a, b) {
    Ok(l) => l
    Err(e) => abort("并集失败：\{e}")
  }
  assert_eq(u.length(), 1)
  assert_eq(net_area(u), 2800.0)
  let s = match @core.boolean_loops(@core.BoolOp::Subtract, a, b) {
    Ok(l) => l
    Err(e) => abort("差集失败：\{e}")
  }
  assert_eq(s.length(), 1)
  assert_eq(net_area(s), 1200.0)
  // 差集是一个 L 形（6 个顶点）：形状也要对，不只是面积
  assert_eq(s[0].length(), 6)
  let it = match @core.boolean_loops(@core.BoolOp::Intersect, a, b) {
    Ok(l) => l
    Err(e) => abort("交集失败：\{e}")
  }
  assert_eq(it.length(), 1)
  assert_eq(net_area(it), 400.0)
  let x = match @core.boolean_loops(@core.BoolOp::Xor, a, b) {
    Ok(l) => l
    Err(e) => abort("异或失败：\{e}")
  }
  // 异或是两块 L（各 1200）——环数必须真的是 2（不是"一整块 2400"）
  assert_eq(x.length(), 2)
  assert_eq(net_area(x), 2400.0)
  // **方向**也要对：异或的两块是**两个岛**（正面积各 1200），不是一个"岛+洞"
  // ——只对账环数与净面积，会把"一个环走反了"放过去（净面积照样 2400）。
  for r in x {
    assert_true(@core.polygon_area(r) > 0.0, msg="异或的每一块都该是岛（正面积）")
  }
  assert_eq(@core.polygon_area(x[0]), 1200.0)
  assert_eq(@core.polygon_area(x[1]), 1200.0)
  // 每个点的归属用**四个操作分别问**：(30,30) 只属于交集，(10,10) 只在 A，
  // (50,50) 只在 B，(10,50) 两边都不在
  assert_true(inside_result(u, 10.0, 10.0) && inside_result(u, 50.0, 50.0))
  assert_true(inside_result(u, 10.0, 30.0) && inside_result(u, 50.0, 30.0))
  // 判别力自证：既不在 A 也不在 B 的点，四个操作里都不该有它
  assert_false(inside_result(u, 10.0, 50.0))
  assert_false(inside_result(u, 90.0, 90.0))
  assert_true(inside_result(u, 30.0, 30.0))
  assert_false(inside_result(it, 10.0, 10.0))
  assert_true(inside_result(it, 30.0, 30.0))
  assert_false(inside_result(it, 50.0, 50.0))
  // 差集 = A 里没被 B 盖住的那块 L：A 独有的三点在内，(30,30) 与 B 独有点在外
  assert_true(inside_result(s, 10.0, 10.0))
  assert_true(inside_result(s, 30.0, 10.0) && inside_result(s, 10.0, 30.0))
  assert_false(inside_result(s, 30.0, 30.0))
  assert_false(inside_result(s, 50.0, 50.0))
  assert_false(inside_result(s, 50.0, 50.0))
  assert_false(inside_result(x, 30.0, 30.0))
  // 异或 = 两块 L：A 独有与 B 独有都在内，重叠区不在
  assert_true(inside_result(x, 10.0, 30.0) && inside_result(x, 30.0, 10.0))
  assert_true(inside_result(x, 30.0, 50.0) && inside_result(x, 50.0, 30.0))
}

///|
test "布尔运算：一个环完全包住另一个 ⇒ 差集是「岛 + 洞」（负面积才是洞）" {
  let outer = rect_ring(0.0, 0.0, 100.0, 100.0)
  let inner = rect_ring(30.0, 30.0, 40.0, 40.0)
  let s = match @core.boolean_loops(@core.BoolOp::Subtract, outer, inner) {
    Ok(l) => l
    Err(e) => abort("差集失败：\{e}")
  }
  assert_eq(s.length(), 2)
  // 方向就是语义：一个是正面积的岛，一个是负面积的洞——**两者都要真的存在**
  let mut pos = 0
  let mut neg = 0
  for r in s {
    if @core.polygon_area(r) > 0.0 {
      pos = pos + 1
    } else {
      neg = neg + 1
    }
  }
  assert_eq(pos, 1)
  assert_eq(neg, 1)
  assert_eq(net_area(s), 10000.0 - 1600.0)
  // 洞里、环上、外面三个点
  assert_false(inside_result(s, 50.0, 50.0))
  assert_true(inside_result(s, 10.0, 50.0))
  assert_true(inside_result(s, 95.0, 95.0))
  assert_false(inside_result(s, 200.0, 200.0))
  // 并集与交集在"完全包住"时分别是外环、内环
  let u = match @core.boolean_loops(@core.BoolOp::Union, outer, inner) {
    Ok(l) => l
    Err(e) => abort("并集失败：\{e}")
  }
  assert_eq(u.length(), 1)
  assert_eq(net_area(u), 10000.0)
  let it = match @core.boolean_loops(@core.BoolOp::Intersect, outer, inner) {
    Ok(l) => l
    Err(e) => abort("交集失败：\{e}")
  }
  assert_eq(net_area(it), 1600.0)
  // 异或 = 差（内环是空的那一半）
  let x = match @core.boolean_loops(@core.BoolOp::Xor, outer, inner) {
    Ok(l) => l
    Err(e) => abort("异或失败：\{e}")
  }
  assert_eq(net_area(x), 8400.0)
}

///|
test "布尔运算：分离 / 相接（共边）/ 完全相同 —— 三种退化都按「没有面积交」走" {
  let a = rect_ring(0.0, 0.0, 40.0, 40.0)
  let far = rect_ring(100.0, 100.0, 40.0, 40.0)
  let side = rect_ring(40.0, 0.0, 40.0, 40.0)
  // 分离：并 = 2 环、交 = 空、差 = A、异或 = 2 环
  let u = match @core.boolean_loops(@core.BoolOp::Union, a, far) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(u.length(), 2)
  assert_eq(net_area(u), 3200.0)
  assert_true(inside_result(u, 10.0, 10.0) && inside_result(u, 110.0, 110.0))
  let it = match @core.boolean_loops(@core.BoolOp::Intersect, a, far) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(it.length(), 0)
  let s = match @core.boolean_loops(@core.BoolOp::Subtract, a, far) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(net_area(s), 1600.0)
  // **共边相接**：那条边上的中点正好落在对方边界上——"在不在内部"没有稳定答案，
  // 所以这一支必须显式接住（走裁剪会随浮点抖动接出零面积的假环）
  assert_true(@core.collinear_overlap(a, side))
  let u2 = match @core.boolean_loops(@core.BoolOp::Union, a, side) {
    Ok(l) => l
    Err(e) => abort("共边相接的并集必须按「没有面积交」处理：\{e}")
  }
  assert_eq(u2.length(), 2)
  assert_eq(net_area(u2), 3200.0)
  let it2 = match @core.boolean_loops(@core.BoolOp::Intersect, a, side) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(it2.length(), 0)
  // 完全相同：并/交 = 它自己（**不是两个环**——那会让面积记账翻倍），差/异或 = 空
  assert_true(@core.loops_identical(a, rect_ring(0.0, 0.0, 40.0, 40.0)))
  let u3 = match @core.boolean_loops(@core.BoolOp::Union, a, rect_ring(0.0, 0.0, 40.0, 40.0)) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(u3.length(), 1)
  assert_eq(net_area(u3), 1600.0)
  let s3 = match @core.boolean_loops(@core.BoolOp::Subtract, a, rect_ring(0.0, 0.0, 40.0, 40.0)) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(s3.length(), 0)
}

///|
test "布尔运算：部分共线重叠 ⇒ 明确拒绝（不猜），而不是给一个错的结果" {
  // A = 0..40，B = 20..60、同 y 同 h：上/下两条边共线且真的叠在一起
  let a = rect_ring(0.0, 0.0, 40.0, 40.0)
  let b = rect_ring(20.0, 0.0, 40.0, 40.0)
  assert_true(@core.collinear_overlap(a, b))
  match @core.boolean_loops(@core.BoolOp::Union, a, b) {
    Ok(l) => abort("部分重合必须被拒，却回了 \{l.length()} 个环")
    Err(e) => assert_true(e.contains("共线重叠"), msg=e)
  }
  // 正控：把 B 抬高 1px（不再共线）⇒ 同一对形状必须算得出并集（面积 1600+1600-19*40）
  let c = rect_ring(20.0, -1.0, 40.0, 40.0)
  let u = match @core.boolean_loops(@core.BoolOp::Union, a, c) {
    Ok(l) => l
    Err(e) => abort("一般位置必须算得出来：\{e}")
  }
  assert_eq(net_area(u), 1600.0 + 1600.0 - 20.0 * 39.0)
}

///|
test "布尔运算：斜边真的被切开（菱形一半在矩形里）——面积精确可算" {
  // 菱形中心摆在矩形右边线上：(100,40) (110,50) (100,60) (90,50)
  // 与 0..100 的矩形求交 = 左边那个三角形（100,40)(100,60)(90,50)，面积 100
  let diamond : Array[(Double, Double)] = [
    (100.0, 40.0),
    (110.0, 50.0),
    (100.0, 60.0),
    (90.0, 50.0),
  ]
  let rect = rect_ring(0.0, 0.0, 100.0, 100.0)
  assert_eq(@core.polygon_area(diamond), 200.0)
  let it = match @core.boolean_loops(@core.BoolOp::Intersect, rect, diamond) {
    Ok(l) => l
    Err(e) => abort("交集失败：\{e}")
  }
  assert_eq(it.length(), 1)
  assert_eq(net_area(it), 100.0)
  // 差集 = 矩形挖掉半个菱形 = 10000 − 100
  let s = match @core.boolean_loops(@core.BoolOp::Subtract, rect, diamond) {
    Ok(l) => l
    Err(e) => abort("差集失败：\{e}")
  }
  assert_eq(net_area(s), 9900.0)
  // 输入的环方向反过来（CW）必须给出同一结果：方向规范化只有入口一次
  let rect_cw = @core.reverse_loop(rect)
  let it2 = match @core.boolean_loops(@core.BoolOp::Intersect, rect_cw, diamond) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(net_area(it2), 100.0)
  assert_eq(it2.length(), it.length())
  assert_eq(@core.polygon_area(it2[0]) > 0.0, @core.polygon_area(it[0]) > 0.0)
}

///|
test "布尔运算：多边形完全在矩形内 ⇒ 交集就是它自己（面积逐位等于它的 shoelace 面积）" {
  // 八边形（顶点全是整数，不需要三角函数——`core` 里没有 cos/sin）
  let oct : Array[(Double, Double)] = [
    (60.0, 50.0),
    (57.0, 57.0),
    (50.0, 60.0),
    (43.0, 57.0),
    (40.0, 50.0),
    (43.0, 43.0),
    (50.0, 40.0),
    (57.0, 43.0),
  ]
  let rect = rect_ring(0.0, 0.0, 100.0, 100.0)
  let own = @core.polygon_area(oct)
  // 判别力自证：它明显小于外接正方形（否则"面积等于它自己"是句空话）
  assert_true(own > 250.0 && own < 320.0, msg="八边形面积=\{own}")
  let it = match @core.boolean_loops(@core.BoolOp::Intersect, rect, oct) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(it.length(), 1)
  assert_eq(net_area(it), own)
  // 差集 = 矩形挖掉它（洞）：净面积 = 10000 − own，且**环数是 2**（岛 + 洞）
  let s = match @core.boolean_loops(@core.BoolOp::Subtract, rect, oct) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(s.length(), 2)
  assert_eq(net_area(s), 10000.0 - own)
  assert_false(inside_result(s, 50.0, 50.0))
  assert_true(inside_result(s, 5.0, 5.0))
  assert_false(inside_result(s, 200.0, 200.0))
}

///|
test "布尔运算：顺序与确定性（同一对输入两次给出逐位相同的环）" {
  let a = rect_ring(0.0, 0.0, 40.0, 40.0)
  let b = rect_ring(20.0, 20.0, 40.0, 40.0)
  let one = match @core.boolean_loops(@core.BoolOp::Xor, a, b) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  let two = match @core.boolean_loops(@core.BoolOp::Xor, a, b) {
    Ok(l) => l
    Err(e) => abort(e)
  }
  assert_eq(one.length(), two.length())
  let mut i = 0
  while i < one.length() {
    assert_eq(one[i].length(), two[i].length())
    let mut j = 0
    while j < one[i].length() {
      assert_eq(one[i][j].0, two[i][j].0)
      assert_eq(one[i][j].1, two[i][j].1)
      j = j + 1
    }
    i = i + 1
  }
  // 名字表：四个名字双向自证（命令面/字典/报告都读它）
  for name in ["union", "subtract", "intersect", "xor"] {
    match @core.bool_op_from_name(name) {
      Some(op) => assert_eq(@core.bool_op_name(op), name)
      None => abort("认不出 \{name}")
    }
  }
  assert_true(@core.bool_op_from_name("unionn") is None)
}
