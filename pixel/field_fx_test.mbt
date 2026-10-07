///|
/// 图层样式（fx）用到的两个**场**原语：位移与膨胀。
///
/// 它们是"投影往哪边偏、描边多宽"的全部算术，判据必须咬住**具体格子**，
/// 而不是"回了个 Field"（那种断言对任何实现都成立）。
test "field_shift：位移是真的位移（含负方向、窗内裁剪、四舍五入）" {
  let f = @pixel.field_new(3, 3)
  @pixel.field_set(f, 1, 1, 1.0)
  // 正方向
  let s1 = @pixel.field_shift(f, 1.0, 1.0)
  assert_eq(@pixel.field_get(s1, 2, 2), 1.0)
  assert_eq(@pixel.field_get(s1, 1, 1), 0.0)
  // 负方向（投影往左上打）
  let s2 = @pixel.field_shift(f, -1.0, -1.0)
  assert_eq(@pixel.field_get(s2, 0, 0), 1.0)
  assert_eq(@pixel.field_get(s2, 1, 1), 0.0)
  // 四舍五入：0.4 不动、0.6 算一格、-0.6 往负方向一格
  assert_eq(@pixel.field_get(@pixel.field_shift(f, 0.4, 0.0), 1, 1), 1.0)
  assert_eq(@pixel.field_get(@pixel.field_shift(f, 0.6, 0.0), 2, 1), 1.0)
  assert_eq(@pixel.field_get(@pixel.field_shift(f, -0.6, 0.0), 0, 1), 1.0)
  // 移出窗外的部分不绕回、不留下残影
  let s3 = @pixel.field_shift(f, 5.0, 0.0)
  assert_eq(@pixel.field_sum(s3), 0.0)
}

///|
test "field_dilate：半径决定扩散范围，边界不越出画布" {
  let f = @pixel.field_new(5, 5)
  @pixel.field_set(f, 2, 2, 1.0)
  // 半径 1 → 3×3；半径 2 → 5×5（"范围随半径变大"必须真的变大，否则
  // `outline_w` 就是个只改指纹不改画面的参数）
  let d1 = @pixel.field_dilate(f, 1.0)
  assert_eq(@pixel.field_sum(d1), 9.0)
  assert_eq(@pixel.field_get(d1, 1, 1), 1.0)
  assert_eq(@pixel.field_get(d1, 0, 0), 0.0)
  let d2 = @pixel.field_dilate(f, 2.0)
  assert_eq(@pixel.field_sum(d2), 25.0)
  // 半径 0 = 恒等（不算"装了却什么都不干"，那是调用方的事）
  let d0 = @pixel.field_dilate(f, 0.0)
  assert_eq(@pixel.field_sum(d0), 1.0)
  // 角上的点在画布内扩散：不越界、不 panic
  let g = @pixel.field_new(3, 3)
  @pixel.field_set(g, 0, 0, 1.0)
  let dg = @pixel.field_dilate(g, 1.0)
  assert_eq(@pixel.field_get(dg, 0, 0), 1.0)
  assert_eq(@pixel.field_get(dg, 1, 1), 1.0)
  assert_eq(@pixel.field_get(dg, 2, 2), 0.0)
  assert_eq(@pixel.field_sum(dg), 4.0)
}

///|
/// 近似比较（盒模糊的期望值都是 1/3、1/9 这类无限小数）。
fn blur_near(a : Double, b : Double) -> Bool {
  let d = a - b
  let ad = if d < 0.0 { -d } else { d }
  ad < 0.000000001
}

///|
test "field_box_blur：两趟真的是两趟（竖着那一趟不是把横着那一趟抄一遍）" {
  // 实测踩过：`box_mean` 的第二趟照抄了第一趟（窗口沿 y 滑、却写遍所有 x），
  // 于是**任何**盒模糊都吐出斜纹与**负值**——而"全绿"的测试一条都没喊
  // （feather/grow/shrink/guided 只被定性断言看着）。判据要能咬住"轴向"：
  let f = @pixel.field_new(6, 4)
  // 沿 y 恒定的两列实心（1.0）：横着那一趟会把它抹成 0 / 1/3 / 2/3 / 2/3 / 1/3 / 0，
  // 而竖着那一趟对"沿 y 恒定"的场**必须是恒等**——轴抄错了这里立刻不同。
  let mut y0 = 0
  while y0 < 4 {
    @pixel.field_set(f, 2, y0, 1.0)
    @pixel.field_set(f, 3, y0, 1.0)
    y0 = y0 + 1
  }
  let b = @pixel.field_box_blur(f, 1.0)
  // ⚠️ 取**内部的 y**（第 1 行）：第 0 行在竖直趟的窗口里少了上一行（窗外取 0），
  // 值会是 2/9——那是"零填充"的正常语义，不是轴向错。
  assert_eq(@pixel.field_get(b, 0, 1), 0.0)
  assert_true(blur_near(@pixel.field_get(b, 1, 1), 1.0 / 3.0), msg="列 1")
  assert_true(blur_near(@pixel.field_get(b, 2, 1), 2.0 / 3.0), msg="列 2")
  assert_true(blur_near(@pixel.field_get(b, 4, 2), 1.0 / 3.0), msg="列 4（不同的内部 y 同一个值）")
  assert_eq(@pixel.field_get(b, 5, 1), 0.0)
  // 均值**不可能为负**（照抄版给出过 -0.111）：这一条最直白地钉住"轴向"
  let mut k = 0
  let n = b.w * b.h
  let mut neg = false
  while k < n {
    if b.v[k] < 0.0 {
      neg = true
    }
    k = k + 1
  }
  assert_false(neg, msg="盒均值出现负值 ⇒ 两趟的轴向一定错了")
  // 单点已知答案：3×3 邻域各 1/9，和 = 1（边界取样丢质量的事不在这里）
  let g = @pixel.field_new(5, 5)
  @pixel.field_set(g, 2, 2, 1.0)
  let bg = @pixel.field_box_blur(g, 1.0)
  assert_true(blur_near(@pixel.field_get(bg, 2, 2), 1.0 / 9.0), msg="中心")
  assert_true(blur_near(@pixel.field_get(bg, 1, 1), 1.0 / 9.0), msg="左上角格")
  assert_true(blur_near(@pixel.field_get(bg, 3, 3), 1.0 / 9.0), msg="右下角格")
  assert_eq(@pixel.field_get(bg, 0, 0), 0.0, msg="斜对角外不受影响")
  assert_true(blur_near(@pixel.field_sum(bg), 1.0), msg="整块质量守恒")
}
