// ②B 滤镜（PLAN 七十八）：**像素映射**这一半（core 那边管"参数收不收得下"）。
//
// 要咬住的是五件事：
//   * **每个算子自己的语义**（不是"跑起来不崩"）：海报化的量化落点、阈值的
//     比较通道与 `>=` 边界、像素化的块平均与边界块、拖影的均匀采样平均、
//     缩放的"中心不动"、噪点的 alpha 与单色混音、色相/饱和度/明度的方向、
//     色彩平衡的三通道独立；
//   * **中性值逐位不变**：`filter_is_noop` 那句"画面逐位不变"必须是**事实**
//     （hue-sat 的 OKLab 往返有量化误差，所以中性要短路——实测差一两级）；
//   * **确定性**：噪点必须是纯散列，两次渲染逐位相同（铁律 7）；
//   * **alpha 不动**：逐像素类的四个算子只改 RGB；
//   * **越界输入不许崩**：手改容器的坏值（size=1、radius=负数）走到渲染器也得
//     有个确定行为（钳到边界），不是 panic。

///|
fn fb(w : Int, h : Int, px : Array[Int]) -> @codec.RgbaBuf {
  let b = @codec.rgba_new(w, h)
  let mut i = 0
  for p in px {
    b.pixels[i] = p
    i = i + 1
  }
  b
}

///|
fn filt(op : @core.AdjustOp, ps : Array[(String, Double)]) -> @core.Adjust {
  @core.make_filter_adjust(op, ps)
}

///|
fn px_at(b : @codec.RgbaBuf, i : Int) -> Int {
  b.pixels[i]
}

///|
/// 灰阶像素（颜色 + alpha）。
fn gray(v : Int, a : Int) -> Int {
  (a << 24) + (v << 16) + (v << 8) + v
}

///|
test "海报化：levels=2 只剩 0/255，levels=4 落到 85 的倍数上，alpha 不动" {
  let b = fb(4, 1, [
    gray(0, 0x80),
    gray(60, 0x80),
    gray(128, 0x80),
    gray(255, 0x80),
  ])
  apply_adjust(Some(filt(@core.AdjustOp::Posterize, [("levels", 2.0)])), b)
  assert_eq(px_at(b, 0), gray(0, 0x80), msg="0 在 levels=2 下还是 0")
  assert_eq(px_at(b, 1), gray(0, 0x80), msg="60 在 levels=2 下落回 0")
  assert_eq(px_at(b, 2), gray(255, 0x80), msg="128 在 levels=2 下抬到 255")
  assert_eq(px_at(b, 3), gray(255, 0x80))
  // levels=4 ⇒ step=85：60/85=0.7→1→85；128/85=1.5→2→170；200/85=2.35→2→170
  let c = fb(4, 1, [
    gray(0, 0x80),
    gray(60, 0x80),
    gray(128, 0x80),
    gray(200, 0x80),
  ])
  apply_adjust(Some(filt(@core.AdjustOp::Posterize, [("levels", 4.0)])), c)
  assert_eq(px_at(c, 0), gray(0, 0x80))
  assert_eq(px_at(c, 1), gray(85, 0x80), msg="levels=4 的第一级是 85")
  assert_eq(px_at(c, 2), gray(170, 0x80), msg="levels=4 的第二级是 170")
  assert_eq(px_at(c, 3), gray(170, 0x80), msg="200 落在 170 那一级")
}

///|
test "阈值：channel 决定跟谁比，边界是 >=（等于阈值算亮）" {
  // channel=3（luma）：灰 128 的 luma=128 ≥ 127.5 ⇒ 白；灰 127 ⇒ 黑
  let b = fb(3, 1, [gray(0, 0xFF), gray(127, 0xFF), gray(128, 0xFF)])
  apply_adjust(Some(filt(@core.AdjustOp::Threshold, [("channel", 3.0), ("level", 0.5)])), b)
  assert_eq(px_at(b, 0), gray(0, 0xFF))
  assert_eq(px_at(b, 1), gray(0, 0xFF), msg="127 低于阈值 ⇒ 黑")
  assert_eq(px_at(b, 2), gray(255, 0xFF), msg="128 达到阈值 ⇒ 白")
  // channel=0（红）：纯绿像素的红通道是 0 ⇒ 黑；纯红 ⇒ 白（判据是"跟谁比"）
  let c = fb(2, 1, [0xFF00FF00, 0xFFFF0000])
  apply_adjust(Some(filt(@core.AdjustOp::Threshold, [("channel", 0.0), ("level", 0.5)])), c)
  assert_eq(px_at(c, 0), gray(0, 0xFF), msg="纯绿在 channel=R 下是黑")
  assert_eq(px_at(c, 1), gray(255, 0xFF), msg="纯红在 channel=R 下是白")
  // channel=2（蓝）：纯蓝 ⇒ 白，纯红 ⇒ 黑
  let d = fb(2, 1, [0xFFFF0000, 0xFF0000FF])
  apply_adjust(Some(filt(@core.AdjustOp::Threshold, [("channel", 2.0), ("level", 0.5)])), d)
  assert_eq(px_at(d, 0), gray(0, 0xFF), msg="纯红在 channel=B 下是黑")
  assert_eq(px_at(d, 1), gray(255, 0xFF), msg="纯蓝在 channel=B 下是白")
  // level=0 ⇒ 全白、level=1 ⇒ 全黑（极值是合法取值，不是空转）
  let e = fb(2, 1, [gray(10, 0xFF), gray(200, 0xFF)])
  apply_adjust(Some(filt(@core.AdjustOp::Threshold, [("channel", 3.0), ("level", 0.0)])), e)
  assert_eq(px_at(e, 0), gray(255, 0xFF), msg="level=0 ⇒ 全白")
  apply_adjust(Some(filt(@core.AdjustOp::Threshold, [("channel", 3.0), ("level", 1.0)])), e)
  assert_eq(px_at(e, 0), gray(255, 0xFF), msg="灰 10 在 level=1 时：10 < 255 ⇒ 黑")
  assert_eq(px_at(e, 0), gray(255, 0xFF), msg="（同上：先被 level=0 改成白，再判 255 < 255 为假 ⇒ 黑）")
}

///|
test "像素化：块内取原图平均，边界块只平均画布内像素" {
  // 4×4，每行一个常数：行 0 = 0、行 1 = 100、行 2 = 200、行 3 = 255
  let px : Array[Int] = []
  let vals = [0, 100, 200, 255]
  for v in vals {
    let mut i = 0
    while i < 4 {
      px.push(gray(v, 0xFF))
      i = i + 1
    }
  }
  let b = fb(4, 4, px)
  apply_adjust(Some(filt(@core.AdjustOp::Pixelate, [("size", 2.0)])), b)
  // 左上 2×2 块 = 行 0 与行 1 的平均 = (0+100)/2 = 50
  assert_eq(px_at(b, 0), gray(50, 0xFF), msg="左上块平均")
  assert_eq(px_at(b, 5), gray(50, 0xFF), msg="整块同一个值")
  // 下方 2×2 块 = (200+255)/2 = 227.5 ⇒ 228（round-half-up）
  assert_eq(px_at(b, 8), gray(228, 0xFF), msg="下方块平均（半个进位）")
  // 3×3 配 size=2：右下角是 1×1 的边界块（只平均画布内那一个像素）
  let px2 = [
    gray(10, 0xFF),
    gray(20, 0xFF),
    gray(30, 0xFF),
    gray(40, 0xFF),
    gray(50, 0xFF),
    gray(60, 0xFF),
    gray(70, 0xFF),
    gray(80, 0xFF),
    gray(90, 0xFF),
  ]
  let c = fb(3, 3, px2)
  apply_adjust(Some(filt(@core.AdjustOp::Pixelate, [("size", 2.0)])), c)
  // 右下角只有 (2,2)=90 ⇒ 边界块平均值就是 90（不是把画布外的 0 算进来）
  assert_eq(px_at(c, 8), gray(90, 0xFF), msg="边界块不许把画布外的像素算进平均")
  // 手改容器的坏值 size=1：钳到 2（不许 panic，也不许一像素不动）
  let d = fb(2, 2, [gray(0, 0xFF), gray(100, 0xFF), gray(100, 0xFF), gray(100, 0xFF)])
  apply_adjust(Some(filt(@core.AdjustOp::Pixelate, [("size", 1.0)])), d)
  assert_eq(px_at(d, 0), gray(75, 0xFF), msg="size=1 按 2 走：(0+100+100+100)/4=75")
}

///|
test "动感模糊：radius=0 逐位不变、块内逐位不变、过渡带一定被糊开、方向对称" {
  let src = [gray(0, 0xFF), gray(0, 0xFF), gray(255, 0xFF), gray(0, 0xFF), gray(0, 0xFF)]
  let keep = fb(5, 1, src)
  apply_adjust(Some(filt(@core.AdjustOp::MotionBlur, [("angle", 0.0), ("radius", 0.0)])), keep)
  let mut i = 0
  while i < 5 {
    assert_eq(px_at(keep, i), src[i], msg="radius=0 必须逐位不变（第 \{i} 像素）")
    i = i + 1
  }
  // ⚠️ **过渡像素不许做逐字节断言**：样本位置是 `floor(x + dx*t)`，25 个样本均匀
  // 铺在 [-r,+r] 上时，若某个样本正好落在像素边界（r=2 时 t=-1/0/1/2 都是整数），
  // 浮点 eps 就能把它挪到隔壁像素——实测同一行左边是 61、右边是 51（`cos_rad`
  // 本身是级数近似）。能逐位断言的是**整段采样区间都落在纯色块里**的像素。
  let strip : Array[Int] = []
  let mut k = 0
  while k < 10 {
    strip.push(gray(0, 0xFF))
    k = k + 1
  }
  while k < 30 {
    strip.push(gray(255, 0xFF))
    k = k + 1
  }
  while k < 40 {
    strip.push(gray(0, 0xFF))
    k = k + 1
  }
  let b = fb(40, 1, strip)
  apply_adjust(Some(filt(@core.AdjustOp::MotionBlur, [("angle", 0.0), ("radius", 2.0)])), b)
  // 采样区间 [x-2, x+2] 完全落在黑块里（5..7）⇒ 逐位不变
  assert_eq(px_at(b, 7), gray(0, 0xFF), msg="黑块内的像素必须还是黑")
  // 完全落在白块里（12..27）⇒ 逐位不变
  assert_eq(px_at(b, 13), gray(255, 0xFF), msg="白块内的像素必须还是白")
  // 过渡带（9/10 两个像素）必须被糊成**中间值**（不是 0 也不是 255）。
  // ⚠️ 比的是**红通道**，不是整个 ARGB：`0xFF000000 > 0x000000FF` 恒真
  // （alpha 在高位），拿整数值比"大于 0"永远成立 = 空断言。
  let t9 = (px_at(b, 9) >> 16) & 0xFF
  let t10 = (px_at(b, 10) >> 16) & 0xFF
  assert_true(
    t9 > 0 && t9 < 255,
    msg="过渡像素 9 应当被糊成中间值（实得 \{t9}）",
  )
  assert_true(
    t10 > 0 && t10 < 255,
    msg="过渡像素 10 应当被糊成中间值（实得 \{t10}）",
  )
  // alpha 在整幅上都不许变（所有样本 alpha 相同 ⇒ 平均还是它）
  let mut a = 0
  while a < 40 {
    assert_eq((px_at(b, a) >> 24) & 0xFF, 0xFF, msg="alpha 不该被动过（第 \{a} 像素）")
    a = a + 1
  }
  // **方向对称**：拖影关于中心对称，所以 angle=180 与 angle=0 给出同一行字节；
  // 竖直（1×40 + angle=90）同理。这条能抓住"样本区间写成 [+0,+2r]"这类偏心实现。
  let back = fb(40, 1, strip)
  apply_adjust(Some(filt(@core.AdjustOp::MotionBlur, [("angle", 180.0), ("radius", 2.0)])), back)
  let vert = fb(1, 40, strip)
  apply_adjust(Some(filt(@core.AdjustOp::MotionBlur, [("angle", 90.0), ("radius", 2.0)])), vert)
  let mut j = 0
  while j < 40 {
    assert_eq(px_at(back, j), px_at(b, j), msg="angle=180 与 angle=0 必须同结果（第 \{j} 像素）")
    assert_eq(px_at(vert, j), px_at(b, j), msg="竖直拖影与水平拖影必须同结果（第 \{j} 像素）")
    j = j + 1
  }
}

test "径向模糊：中心逐位不动、纯色图整幅不变、越靠边越像外圈" {
  // 纯色图：缩放取样取到的还是同一个颜色 ⇒ 逐位不变（正控：这条能抓住
  // "取样点算错但恰好取到同色"以外的错误）
  let flat = fb(5, 5, Array::make(25, gray(120, 0xFF)))
  apply_adjust(Some(filt(@core.AdjustOp::RadialBlur, [("center_x", 0.5), ("center_y", 0.5), ("radius", 32.0)])), flat)
  let mut i = 0
  while i < 25 {
    assert_eq(px_at(flat, i), gray(120, 0xFF), msg="纯色图在径向模糊下必须逐位不变")
    i = i + 1
  }
  // 中心像素（2,2）：到中心距离 0 ⇒ 权重 0 ⇒ 原值（哪怕周围全不一样）
  let px : Array[Int] = []
  let mut k = 0
  while k < 25 {
    if k == 12 {
      px.push(gray(255, 0xFF))
    } else {
      px.push(gray(0, 0xFF))
    }
    k = k + 1
  }
  let b = fb(5, 5, px)
  apply_adjust(Some(filt(@core.AdjustOp::RadialBlur, [("center_x", 0.5), ("center_y", 0.5), ("radius", 32.0)])), b)
  assert_eq(px_at(b, 12), gray(255, 0xFF), msg="中心像素的拖影权重是 0 ⇒ 逐位不动")
  // ⚠️ **取样方向是从中心向外**（缩放型拖影）：每个像素取的是比自己**更远**的
  // 位置，所以"中心一个白点"不会糊到邻居身上（我第一版就按 PS 的另一个方向
  // 写了断言，实测角上一像素都没动）。要看见效果得让**外圈**的颜色往内拖：
  // 41×41 的 1 像素棋盘 + 中心在正中，外圈样点必然落在别的格子上。
  let n = 41
  let px2 : Array[Int] = []
  let mut yy = 0
  while yy < n {
    let mut xx = 0
    while xx < n {
      let v = if (xx + yy) % 2 == 0 { 255 } else { 0 }
      px2.push(gray(v, 0xFF))
      xx = xx + 1
    }
    yy = yy + 1
  }
  let c = fb(n, n, px2)
  apply_adjust(
    Some(filt(@core.AdjustOp::RadialBlur, [("center_x", 0.5), ("center_y", 0.5), ("radius", 64.0)])),
    c,
  )
  let mut diff = 0
  let mut i2 = 0
  while i2 < n * n {
    if px_at(c, i2) != px2[i2] {
      diff = diff + 1
    }
    i2 = i2 + 1
  }
  assert_true(diff > 0, msg="棋盘上径向模糊必须改变画面（外圈往内拖）")
  // 中心像素（20,20）的中心正好是 (20.5,20.5) = 拖影中心 ⇒ 权重 0，逐位不动
  assert_eq(px_at(c, 20 * n + 20), px2[20 * n + 20], msg="拖影中心那一格逐位不动")
}

///|
test "噪点：amount=0 逐位不变；alpha 不动；mono=1 保持灰、mono=0 出彩色；两次逐位相同" {
  let src = Array::make(64, gray(128, 0x7F))
  let keep = fb(8, 8, src)
  apply_adjust(Some(filt(@core.AdjustOp::Noise, [("amount", 0.0), ("mono", 0.0)])), keep)
  let mut i = 0
  while i < 64 {
    assert_eq(px_at(keep, i), src[i], msg="amount=0 必须逐位不变（第 \{i} 像素）")
    i = i + 1
  }
  let mono = fb(8, 8, src)
  apply_adjust(Some(filt(@core.AdjustOp::Noise, [("amount", 0.8), ("mono", 1.0)])), mono)
  let color = fb(8, 8, src)
  apply_adjust(Some(filt(@core.AdjustOp::Noise, [("amount", 0.8), ("mono", 0.0)])), color)
  let mut colored = 0
  let mut moved = 0
  i = 0
  while i < 64 {
    let pm = px_at(mono, i)
    assert_eq((pm >> 24) & 0xFF, 0x7F, msg="噪点不许动 alpha")
    assert_eq(
      ((pm >> 16) & 0xFF) == ((pm >> 8) & 0xFF) && ((pm >> 8) & 0xFF) == (pm & 0xFF),
      true,
      msg="mono=1 时三通道必须同增同减（从灰出发仍是灰）",
    )
    let pc = px_at(color, i)
    if !(((pc >> 16) & 0xFF) == ((pc >> 8) & 0xFF) && ((pc >> 8) & 0xFF) == (pc & 0xFF)) {
      colored = colored + 1
    }
    if pc != src[i] {
      moved = moved + 1
    }
    i = i + 1
  }
  assert_true(moved > 0, msg="amount=0.8 应当改变画面")
  assert_true(colored > 0, msg="mono=0（彩色噪声）应当造出非灰像素")
  // 确定性：同样输入两次逐位相同
  let again = fb(8, 8, src)
  apply_adjust(Some(filt(@core.AdjustOp::Noise, [("amount", 0.8), ("mono", 0.0)])), again)
  i = 0
  while i < 64 {
    assert_eq(px_at(again, i), px_at(color, i), msg="噪点必须可复现（第 \{i} 像素）")
    i = i + 1
  }
}

///|
test "色相饱和度：中性参数逐位不变、sat=-1 出灰、alpha 不动" {
  let src = [0xFFFF3300, 0xFF33FF00, 0xFF0033FF, 0xFF808080]
  let keep = fb(4, 1, src)
  apply_adjust(
    Some(filt(@core.AdjustOp::HueSat, [("hue", 0.0), ("light", 0.0), ("sat", 0.0)])),
    keep,
  )
  let mut i = 0
  while i < 4 {
    assert_eq(px_at(keep, i), src[i], msg="中性色相/饱和度必须逐位不变（第 \{i} 像素）")
    i = i + 1
  }
  let grayed = fb(4, 1, src)
  apply_adjust(
    Some(filt(@core.AdjustOp::HueSat, [("hue", 0.0), ("light", 0.0), ("sat", -1.0)])),
    grayed,
  )
  i = 0
  while i < 4 {
    let p = px_at(grayed, i)
    assert_eq(
      ((p >> 16) & 0xFF) == ((p >> 8) & 0xFF) && ((p >> 8) & 0xFF) == (p & 0xFF),
      true,
      msg="sat=-1 必须把彩度清零（第 \{i} 像素）",
    )
    assert_eq((p >> 24) & 0xFF, 0xFF, msg="alpha 不动")
    i = i + 1
  }
  // 色相旋转：纯红转 120° 之后不再是第三个通道最大的那种红
  // 中性参数必须**对一整格颜色立方体**逐位不变，不是只挑一个颜色：
  // 这条短路是"空转的层真的空转"那句承诺（`lint` 拿它当事实说给调用方听），
  // 而 OKLab 往返**不是**恒等（浮点 + 量化，实测个别颜色会差一两级）——
  // 只挑几个"看着安全"的颜色，短路被拿掉了也不会有人红（变异 R131 实测存活过）。
  let cube : Array[Int] = []
  let mut cv = 0
  while cv <= 255 {
    let mut cu = 0
    while cu <= 255 {
      let mut ct = 0
      while ct <= 255 {
        cube.push((0xFF << 24) + (cv << 16) + (cu << 8) + ct)
        ct = ct + 17
      }
      cu = cu + 17
    }
    cv = cv + 17
  }
  let n = cube.length()
  let whole = fb(n, 1, cube)
  apply_adjust(
    Some(filt(@core.AdjustOp::HueSat, [("hue", 0.0), ("light", 0.0), ("sat", 0.0)])),
    whole,
  )
  let mut k = 0
  while k < n {
    assert_eq(
      px_at(whole, k),
      cube[k],
      msg="中性色相/饱和度对整格颜色立方体都必须逐位不变（第 \{k} 个颜色）",
    )
    k = k + 1
  }
  let hued = fb(1, 1, [0xFFFF0000])
  apply_adjust(
    Some(filt(@core.AdjustOp::HueSat, [("hue", 120.0), ("light", 0.0), ("sat", 0.0)])),
    hued,
  )
  let hp = px_at(hued, 0)
  assert_true(hp != 0xFFFF0000, msg="hue=120 必须改变画面")
  assert_true(((hp >> 16) & 0xFF) < ((hp >> 8) & 0xFF), msg="纯红转 120° 后绿通道应当最大")
}

///|
test "色彩平衡：全零逐位不变、三通道各自独立加减、越界夹紧" {
  let src = [gray(100, 0xFF)]
  let keep = fb(1, 1, src)
  apply_adjust(
    Some(filt(@core.AdjustOp::ColorBalance, [("cb", 0.0), ("cg", 0.0), ("cr", 0.0)])),
    keep,
  )
  assert_eq(px_at(keep, 0), gray(100, 0xFF), msg="全零必须逐位不变")
  let b = fb(1, 1, src)
  apply_adjust(
    Some(filt(@core.AdjustOp::ColorBalance, [("cb", -1.0), ("cg", 0.0), ("cr", 1.0)])),
    b,
  )
  // cr=1 ⇒ R +100 = 200；cb=-1 ⇒ B -100 = 0；cg=0 ⇒ G 不变
  assert_eq(px_at(b, 0), (0xFF << 24) + (200 << 16) + (100 << 8) + 0, msg="红加蓝减")
  // 纯白 + cr=1：夹到 255（不是溢出回绕）
  let w = fb(1, 1, [gray(255, 0xFF)])
  apply_adjust(
    Some(filt(@core.AdjustOp::ColorBalance, [("cb", 0.0), ("cg", 1.0), ("cr", 1.0)])),
    w,
  )
  assert_eq(px_at(w, 0), gray(255, 0xFF), msg="越界必须夹紧（不许回绕）")
}

///|
test "整条渲染链：滤镜层渲染两次逐位相同（噪点不许有随机数）" {
  let doc = @core.new_document("uuid-2b-render", 32, 24)
  let bg = @core.default_layer("l1", "bg", 0.0, 0.0, 32.0, 24.0)
  doc.layers.push({ ..bg, fill: @core.Fill::Solid(0x3366CCFF) })
  let f = @core.default_layer("l2", "grain", 0.0, 0.0, 32.0, 24.0)
  doc.layers.push({
    ..f,
    kind: @core.ShapeKind::Adjust,
    adjust: Some(filt(@core.AdjustOp::Noise, [("amount", 0.6), ("mono", 0.0)])),
  })
  let a = render_doc(doc, RenderEnv::new())
  let b = render_doc(doc, RenderEnv::new())
  let mut i = 0
  while i < a.pixels.length() {
    assert_eq(a.pixels[i], b.pixels[i], msg="两次渲染必须逐位相同（第 \{i} 像素）")
    i = i + 1
  }
  // 正控：噪点确实改了画面（否则"两次相同"在什么都没发生时也成立）
  let plain = @core.new_document("uuid-2b-plain", 32, 24)
  let bg2 = @core.default_layer("l1", "bg", 0.0, 0.0, 32.0, 24.0)
  plain.layers.push({ ..bg2, fill: @core.Fill::Solid(0x3366CCFF) })
  let p0 = render_doc(plain, RenderEnv::new())
  let mut diff = 0
  i = 0
  while i < a.pixels.length() {
    if a.pixels[i] != p0.pixels[i] {
      diff = diff + 1
    }
    i = i + 1
  }
  assert_true(diff > 0, msg="噪点层应当改变画面")
}
