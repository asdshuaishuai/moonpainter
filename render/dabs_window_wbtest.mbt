/// dab 落笔窗口的不变量（白盒：`dabs_window` / `paint_dabs` 都是包内私有）。
///
/// `paint_raster` 只清、只扫 `dabs_window` 回报的那一块（12MP 上这一窗可能只有
/// 几百像素），前提是**落过笔的像素全在窗内**。这条前提不能靠"窗口和落笔都调
/// 同一个 `dab_box`"来自证——那是拿公式验公式：公式写小了它照样绿。所以这里
/// 从**真的画出来的墨**反推包围盒，断言它**严格落在窗内**（窗是半开区间
/// `[x0,x1)`，墨贴着 `x1-1` 是合法的，所以判据是"含于"而不是"离边还有几像素"
/// ——我第一版写成"离边至少 1 像素"，实测 r=1 时墨正当当地贴着 `x1-1`：那是
/// **判据写宽了**，不是实现错了）。
///
/// ⚠️ **光有"包含性"是不够的**：窗口和落笔都调同一个 `dab_box`，所以把松弛
/// 去掉时**两边一起变紧**——窗照样包住墨、包含性判据照样绿，而画面掉的是一列
/// 像素。实测注入"去掉 ±1 松弛"后，只有另一条测试的**公式**断言报 `8 != 7`，
/// 包含性一声不吭。所以这里再加一条**独立**判据：从 dab 自己的定义（圆心、半径、
/// 2×2 子采样）逐像素算"这一格该不该有墨"，与本实现无关——该有而没有就是被裁了。
/// 这条才是"笔迹不许缺角"的真正守卫。
///
/// 另加一条**代价**判据：窗不许退化成整幅画布（`x1-x0` 还得是 O(r)）——否则
/// "只扫一窗"白做，而功能上一切正常、没有任何东西会红。

///|
/// 2×2 子采样偏移（判据侧自己写一份：与实现共用同一份就验不出"实现写窄了"）。
let window_samples : Array[(Double, Double)] = [
  (0.25, 0.25),
  (0.75, 0.25),
  (0.25, 0.75),
  (0.75, 0.75),
]

///|
/// 只带一个 dab 的 Raster 层（层位在原点，dab 坐标即画布坐标）。
fn raster_layer_with_dab(x : Double, y : Double, r : Double) -> @core.Layer {
  let l = @core.default_layer("d1", "d1", 0.0, 0.0, 200.0, 200.0)
  {
    ..l,
    kind: @core.ShapeKind::Raster,
    dabs: [{ x, y, r, color: 0xFF0000FF, erase: false }],
  }
}

///|
/// 透明底的画布（`rgba_new` 的初值是**不透明黑**，不能直接用）。
fn transparent(w : Int, h : Int) -> @codec.RgbaBuf {
  let b = @codec.rgba_new(w, h)
  let total = w * h
  let mut i = 0
  while i < total {
    b.pixels[i] = 0
    i = i + 1
  }
  b
}

///|
test "dab 窗口：窗必须包住墨迹且留有余量（小数中心 × 半径全组合）" {
  let n = 200
  let mut r = 1.0
  while r <= 8.0 {
    let mut fx = 0.0
    while fx < 1.0 {
      let mut fy = 0.0
      while fy < 1.0 {
        let l = raster_layer_with_dab(40.5 + fx, 40.5 + fy, r)
        let win = dabs_window(l, [], n, n)
        let (wx0, wy0, wx1, wy1) = match win {
          None =>
            fail("r=\{r} fx=\{fx} fy=\{fy}：窗口是空的，可这一点明明要落笔")
          Some(w) => w
        }
        let scratch = transparent(n, n)
        paint_dabs(l, [], scratch)
        // 独立判据：按定义（圆心/半径/2×2 子采样）逐像素算该不该有墨。
        // 浮点算式与实现**逐字相同**（`px + 0.25 - 圆心`、`dx*dx + dy*dy <= r*r`）
        // 才不会有边界假阳性；`cx` 由测试自己从同一个表达式算出（不是反读 d.x）。
        let cx = 40.5 + fx
        let cy = 40.5 + fy
        let r2 = r * r
        let mut missing = 0
        let mut my = 0
        while my < n {
          let mut mx = 0
          while mx < n {
            let mut expect = false
            for smp in window_samples {
              let dx = mx.to_double() + smp.0 - cx
              let dy = my.to_double() + smp.1 - cy
              if dx * dx + dy * dy <= r2 {
                expect = true
              }
            }
            if expect && ((scratch.pixels[my * n + mx] >> 24) & 0xFF) == 0 {
              missing = missing + 1
            }
            mx = mx + 1
          }
          my = my + 1
        }
        assert_true(
          missing == 0,
          msg="r=\{r} fx=\{fx} fy=\{fy}：有 \{missing} 个该落墨的像素是空的——笔迹被裁了（窗/落笔盒太紧？）",
        )
        let mut ix0 = n
        let mut iy0 = n
        let mut ix1 = -1
        let mut iy1 = -1
        let mut y = 0
        while y < n {
          let mut x = 0
          while x < n {
            if ((scratch.pixels[y * n + x] >> 24) & 0xFF) > 0 {
              if x < ix0 {
                ix0 = x
              }
              if y < iy0 {
                iy0 = y
              }
              if x > ix1 {
                ix1 = x
              }
              if y > iy1 {
                iy1 = y
              }
            }
            x = x + 1
          }
          y = y + 1
        }
        assert_true(ix1 >= 0, msg="r=\{r} fx=\{fx}：一个像素都没画出来（笔触成了 no-op）")
        assert_true(
          ix0 >= wx0 && iy0 >= wy0 && ix1 <= wx1 - 1 && iy1 <= wy1 - 1,
          msg="r=\{r} fx=\{fx} fy=\{fy}：墨 [\{ix0},\{iy0},\{ix1},\{iy1}] 跑到窗 [\{wx0},\{wy0},\{wx1},\{wy1}] 外面了——扫窗会切掉笔迹（松弛不够？）",
        )
        assert_true(
          wx1 - wx0 <= (2.0 * r).to_int() + 6 && wy1 - wy0 <= (2.0 * r).to_int() + 6,
          msg="r=\{r} fx=\{fx}：窗 [\{wx0},\{wx1}] 比墨大太多（r 才 \{r}）——窗口退化了，扫窗就不省了",
        )
        fy = fy + 0.5
      }
      fx = fx + 0.5
    }
    r = r + 1.0
  }
}

///|
test "dab 窗口：多个 dab 取并集、空盒不算落笔、画布外的 dab 给出空窗" {
  let l = @core.default_layer("d1", "d1", 0.0, 0.0, 200.0, 200.0)
  let l = {
    ..l,
    kind: @core.ShapeKind::Raster,
    dabs: [
      { x: 10.0, y: 10.0, r: 2.0, color: 0xFF0000FF, erase: false },
      { x: 150.0, y: 150.0, r: 2.0, color: 0xFF0000FF, erase: false },
    ],
  }
  let (wx0, wy0, wx1, wy1) = match dabs_window(l, [], 200, 200) {
    None => fail("两个 dab 都在画布内，窗口不该是空的")
    Some(w) => w
  }
  // 公式：x0=(x-r).to_int()-1、x1=(x+r).to_int()+1。
  // dab1(10,10,r=2) ⇒ [7,13)；dab2(150,150,r=2) ⇒ [147,153)；并集 = [7,153)。
  // ⚠️ 这里断的是**并集**：上稿我照单 dab 的算式写成了 [7,13)，实测报
  // `153 != 13`——错的是断言不是实现（`wx1` 已经并到第二个 dab 上了）。
  assert_eq(wx0, 7)
  assert_eq(wy0, 7)
  assert_eq(wx1, 153)
  assert_eq(wy1, 153)

  // r=0 的 dab 不落笔（`dab_box` 直接 None）
  let zero = { ..l, dabs: [{ x: 10.0, y: 10.0, r: 0.0, color: 0xFF0000FF, erase: false }] }
  assert_true(dabs_window(zero, [], 200, 200) is None, msg="r=0 的 dab 不该占窗口")

  // 完全在画布外 ⇒ 空窗（此时 `paint_raster` 连清零都不做）
  let outside = {
    ..l,
    dabs: [{ x: -100.0, y: -100.0, r: 4.0, color: 0xFF0000FF, erase: false }],
  }
  assert_true(dabs_window(outside, [], 200, 200) is None, msg="画布外的 dab 不该占窗口")

  // **部分**在画布外 ⇒ 窗口要夹到画布内（不能越界）
  let partial = {
    ..l,
    dabs: [{ x: 2.0, y: 2.0, r: 6.0, color: 0xFF0000FF, erase: false }],
  }
  let (px0, py0, px1, py1) = match dabs_window(partial, [], 200, 200) {
    None => fail("部分在画布内的 dab 不该给出空窗")
    Some(w) => w
  }
  assert_eq(px0, 0)
  assert_eq(py0, 0)
  assert_true(px1 <= 200 && py1 <= 200, msg="窗口越过了画布：\{px1},\{py1}")
}
