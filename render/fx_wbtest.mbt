///|
/// 样式工作窗的**白盒**判据：窗要不要裁、裁到哪儿、窗外有没有被碰过。
///
/// 黑盒那半（`fx_test.mbt`）钉的是"看得见的像素对不对"；这里钉的是**裁剪本身**
/// ——它的失效方式很隐蔽：窗算小了一点，画面上只是"边的样式缺了一角"，
/// 而所有"回了个图 / 有像素变了"的断言照样通过。

///|
/// 随便造一张内容缓冲（真栅格化就走渲染器，这里只要"有像素"的分布可控）。
fn fxbuf_solid(w : Int, h : Int, x0 : Int, y0 : Int, x1 : Int, y1 : Int) -> @codec.RgbaBuf {
  let b = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(b, 0, 0, w, h, 0x00000000)
  @codec.fill_rect_rgba(b, x0, y0, x1 - x0, y1 - y0, 0xFF3366FF)
  b
}

///|
/// 四件全开的样式（覆盖最大的扩散量：影 blur8+偏移8、发光 r10、内影 blur6+偏移3、描边 4）。
fn fx_all_on() -> @core.LayerFx {
  {
    ..@core.default_fx(),
    shadow: true,
    shadow_dx: 8.0,
    shadow_dy: 8.0,
    shadow_blur: 8.0,
    glow: true,
    glow_radius: 10.0,
    outline: true,
    outline_w: 4.0,
    inner: true,
    inner_dx: 3.0,
    inner_dy: 3.0,
    inner_blur: 6.0,
  }
}

///|
test "样式工作窗：中间那块层真的被裁了（窗严格小于画布，否则这条判据是空的）" {
  // 200×120 画布上一个 20×10 的小块 ⇒ 窗应该只比它大一圈，而不是整画布
  let buf = fxbuf_solid(200, 120, 60, 50, 80, 60)
  let win = fx_work_window(buf, fx_all_on())
  match win {
    Some(w) => {
      let (x0, y0, x1, y1) = w
      assert_eq(x0 > 0, true, msg="左边该留出扩散量、但不该从 0 开始")
      assert_eq(y0 > 0, true, msg="上边同理")
      assert_eq(x1 < 200, true, msg="右边同理")
      assert_eq(y1 < 120, true, msg="下边同理")
      // 窗必须把"层自己的盒子 + 最大扩散量"整个装进去（影 blur8 + 偏移8 = 16）
      assert_eq(x0 <= 60 - 16, true, msg="左边要装得下影")
      assert_eq(y0 <= 50 - 16, true, msg="上边要装得下影")
      assert_eq(x1 >= 80 + 16, true, msg="右边要装得下影")
      assert_eq(y1 >= 60 + 16, true, msg="下边要装得下影")
    }
    None => abort("中间有个 20×10 的块，窗不该是空的")
  }
}

///|
test "样式工作窗：窗外逐位等于入参（裁与不裁是同一张图）" {
  // 这是"裁剪安全"的那条判据：窗外只要有一个像素被碰过，就说明窗算小了。
  // 三种摆法各来一遍——中间、贴左上角、一半在画布外。
  let cases : Array[(Int, Int, Int, Int)] = [
    (60, 50, 80, 60),   // 中间
    (0, 0, 20, 10),     // 贴左上角（窗会被夹到画布边上）
    // 一半在外：内容从 x=0 到 79（左侧 20px 在画布外，压根没画上）
    (0, 20, 80, 40),
  ]
  for c in cases {
    let buf = fxbuf_solid(200, 120, c.0, c.1, c.2, c.3)
    let fx = fx_all_on()
    let out = apply_fx(buf, fx)
    let win = fx_work_window(buf, fx)
    let (x0, y0, x1, y1) = match win {
      Some(w) => w
      None => abort("这一层有像素，窗不该是空的")
    }
    let mut y = 0
    let mut bad = 0
    while y < out.height {
      let mut x = 0
      while x < out.width {
        let inside = x >= x0 && x < x1 && y >= y0 && y < y1
        if !inside {
          let got = @codec.rgba_get(out, x, y)
          let want = @codec.rgba_get(buf, x, y)
          if got != want {
            bad = bad + 1
          }
        }
        x = x + 1
      }
      y = y + 1
    }
    assert_eq(bad, 0, msg="窗外被碰过：层 [\{c.0},\{c.1})-\{c.2},\{c.3}) 的窗是 [\{x0},\{y0},\{x1},\{y1})")
  }
}

///|
test "样式工作窗：完全在画布外的层没有窗（也就什么都不做）" {
  // 层整个跑到画布左侧外：内容缓冲一个像素都没有 ⇒ 窗是 None。
  // （黑盒那半另有一条"不 panic 且画面与没有这层逐位相同"。）
  let buf = fxbuf_solid(40, 40, 0, 0, 0, 0)
  assert_eq(
    fx_work_window(buf, fx_all_on()) is None,
    true,
    msg="空内容 ⇒ 没有窗",
  )
  let out = apply_fx(buf, fx_all_on())
  let mut i = 0
  let total = out.width * out.height
  let mut diff = 0
  while i < total {
    if out.pixels[i] != buf.pixels[i] {
      diff = diff + 1
    }
    i = i + 1
  }
  assert_eq(diff, 0, msg="没有内容时不许凭空造出样式")
}
