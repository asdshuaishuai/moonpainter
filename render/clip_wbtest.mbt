// 白盒测试：**overlay 线框必须先裁到缓冲区**（PLAN 七十五）。
//
// 为什么它值得一条判据：`rgba_set` 丢弃的是**越界写入**，而 Bresenham 的
// **迭代次数由线段长度决定**——只画得下 1px，却要跑 1e20 步。实测
// `add-rect w=99999999999999999999`（合法 Double，入口收下）之后
// `render overlay=1` **整条进程卡死**，而**不带** overlay 的同一份文档秒回
// （层填充被 `paint_window` 裁到画布）。更远的一句：这个 bug 一直被另一个
// bug 挡着——`render overlay=1` 此前掉进 `to_i("overlay=1")` 直接报错，
// 于是线框路径在 fuzz 语料里从来没被走到过（见 `verify.sh#panic-hunt`）。
//
// ⚠️ 端点必须**取整**：裁剪后的端点若截断，边界上的线框会与"不裁剪"时差一格，
// 而 golden 锁的是像素。`round_i` 就是为这一格写的（变异 R63 守着它）。

///|
test "clip_seg：段全在框内 → 端点原样不动" {
  let buf = @codec.rgba_new(10, 10)
  let (vis, x0, y0, x1, y1) = clip_seg(buf, 2, 3, 8, 9)
  assert_true(vis, msg="框内线段必须可见")
  assert_eq(x0, 2)
  assert_eq(y0, 3)
  assert_eq(x1, 8)
  assert_eq(y1, 9)
}

///|
test "clip_seg：段全在框外 → 不可见（这是卡死的入口）" {
  let buf = @codec.rgba_new(10, 10)
  // 与框平行、完全在右侧：p == 0 且 q < 0 的那一支
  let (vis, _, _, _, _) = clip_seg(buf, 100, 0, 100, 999999)
  assert_false(vis, msg="框外的竖线段不许可见")
  // 一般的斜线段也全在框外
  let (vis2, _, _, _, _) = clip_seg(buf, -100, -100, -5, -5)
  assert_false(vis2, msg="框外的斜线段不许可见")
}

///|
test "clip_seg：段跨界 → 端点落到框上且**四舍五入**" {
  let buf = @codec.rgba_new(10, 10)
  // (2,2) → (20,12)：右边界 x=9 处 t = 7/18，y = 2 + 10*7/18 = 5.888… ⇒ 6
  let (vis, x0, y0, x1, y1) = clip_seg(buf, 2, 2, 20, 12)
  assert_true(vis, msg="跨界线段必须可见")
  assert_eq(x0, 2)
  assert_eq(y0, 2)
  assert_eq(x1, 9)
  assert_eq(y1, 6) // 截断会给出 5 —— 那一格就是 R63 守的东西
  // 左上外侧进来：x = -10 处进入，t = 10/15，y = 3 + 5*(2/3) = 6.333… ⇒ 6
  let (vis2, a0, b0, _, _) = clip_seg(buf, -10, 3, 5, 8)
  assert_true(vis2, msg="从外侧进来的线段必须可见")
  assert_eq(a0, 0)
  assert_eq(b0, 6)
}

///|
test "clip_seg：退化成一点（两端相同）——在框内画得下，在框外不可见" {
  let buf = @codec.rgba_new(10, 10)
  let (vis, x0, y0, x1, y1) = clip_seg(buf, 4, 4, 4, 4)
  assert_true(vis, msg="框内的一点必须可见")
  assert_eq(x0, 4)
  assert_eq(y0, 4)
  assert_eq(x1, 4)
  assert_eq(y1, 4)
  let (vis2, _, _, _, _) = clip_seg(buf, 40, 40, 40, 40)
  assert_false(vis2, msg="框外的一点不许可见")
}
