/// pixel —— 色彩语义与几何谓词的不变量（pixel/color 的回归锚点）。
///
/// 这里的每一条都对应一个**真实修掉过的 bug**，不是泛泛的
/// smoke test。它们共同的失败模式是「三原色恰好通过」：
/// 0 与 1 是各种幂/缩放的不动点，纯红/纯绿/纯蓝因此对下面
/// 三类错误完全免疫，只有中间色与灰阶才暴露问题。

///|
fn cargb(r : Int, g : Int, b : Int) -> Int {
  0xFF000000 + (r << 16) + (g << 8) + b
}

///|
test "sRGB→线性→sRGB 往返：覆盖灰阶与中间色（不只三原色）" {
  // 回归：srgb_to_linear 曾写成 a*a*a（指数 3）而不是 a^2.4。
  // 纯三原色的线性值是 0/1，两种指数都能往返，所以必须用中间色测。
  let mut v = 0
  while v <= 255 {
    let c = cargb(v, v, v)
    let lab = argb_to_oklab(c)
    let back = oklab_to_argb(lab, 255)
    let de = delta_e_argb(c, back)
    assert_true(
      de < 0.002,
      msg="灰阶 v=\{v} 往返 ΔE=\{de}（sRGB 指数必须是 2.4）",
    )
    v = v + 17
  }
  // 灰阶的 OKLab L 必须落在合理量级（0.5999 而不是 0.5279）
  let l128 = argb_to_oklab(cargb(128, 128, 128)).l
  assert_true(
    l128 > 0.59 && l128 < 0.61,
    msg="灰 128 的 OKLab L=\{l128} 不合理（srgb→linear 指数错）",
  )
}

///|
test "sRGB 传递函数与标准值逐点吻合（不依赖语言内建数学）" {
  // 手写 mexp/mln 的精度锚点：这几个值由标准公式独立算出。
  // 回归：mexp 曾「以 ln2 归约、却乘 e 放缩」，中间灰整体偏掉 ΔE≈0.1。
  let cases : Array[(Double, Double)] = [
    (0.0, 0.0),
    (0.04045, 0.04045 / 12.92),
    (0.5, 0.21404114048223255),
    (1.0, 1.0),
  ]
  for pair in cases {
    let (v, want) = pair
    let got = srgb_to_linear(v)
    let d = if got > want { got - want } else { want - got }
    assert_true(d < 0.0000001, msg="srgb_to_linear(\{v})=\{got} 期望 \{want}")
  }
  let lin = srgb_to_linear(0.5)
  let back = linear_to_srgb(lin)
  let e = if back > 0.5 { back - 0.5 } else { 0.5 - back }
  assert_true(e < 0.0000001, msg="线性往返误差 \{e}")
}

///|
test "OKLab/OKLCh 往返对饱和色稳定（msin/mcos 归约到半象限的精度）" {
  // 回归：msin 曾归约到 [−π, π]，7 项级数在 |x|≈2.1 处截断误差 ~3e-8，
  // 色相→OKLab→sRGB 往返会贴边。归约到 [0, π/2] 后降到 ~1e-11。
  let mut r = 0
  while r <= 255 {
    let mut g = 0
    while g <= 255 {
      let mut b = 0
      while b <= 255 {
        let c = cargb(r, g, b)
        let lch = oklab_to_oklch(argb_to_oklab(c))
        let back = oklab_to_argb(oklch_to_oklab(lch), 255)
        assert_eq(back, c, msg="OKLCh 往返不逐位：\{r},\{g},\{b}")
        b = b + 51
      }
      g = g + 51
    }
    r = r + 51
  }
}

///|
test "gamut compress：越界色收 chroma（保色相），不压成黑" {
  // 回归：旧实现是线性 RGB 等比缩放 —— 缩放的不动点是原点，
  // 负通道越缩越负，判据永不成立，纯红被压成纯黑。
  let (r, g, b) = oklab_to_linear({ l: 0.6279553606145516, a: 0.22486306106597398, b: 0.1258462985307351 })
  assert_true(r > 0.9, msg="纯红线性 R=\{r} 应接近 1")
  assert_true(
    g > -0.000001 && b > -0.000001,
    msg="浮点噪声级负值（\{g},\{b}）不应判成越界",
  )
  // 真·越界色（OKLab 的 chroma 远超 sRGB 色域）必须被收 chroma，
  // 而不是被压成黑，也不是被逐通道 clip 改掉色相。
  let wild = { l: 0.5, a: 0.30, b: 0.18 }
  let want_h = oklab_to_oklch(wild).h
  let out = oklab_to_argb(wild, 255)
  let rr = lsr32(out, 16) & 0xFF
  let gg = lsr32(out, 8) & 0xFF
  let bb = out & 0xFF
  assert_true(
    rr + gg + bb > 120,
    msg="越界色不应被压成近黑：\{rr},\{gg},\{bb}",
  )
  let got_h = oklab_to_oklch(argb_to_oklab(out)).h
  let dh = hue_ring_dist(want_h, got_h)
  assert_true(dh < 3.0, msg="收 chroma 后色相漂移 \{dh}°（应为 0）：\{rr},\{gg},\{bb}")
  assert_true(rr > bb, msg="色相方向被破坏：\{rr},\{gg},\{bb}")
}

///|
test "无彩色像素的 recolor 是恒等操作（OKLCh 没有色相可转）" {
  // 这是设计语义，不是缺陷：色相重映射对 chroma≈0 的像素无操作。
  // 把它写成测试，避免后续再拿灰底去测「换色是否生效」。
  let gray = cargb(128, 128, 128)
  let lab = argb_to_oklab(gray)
  let lch = oklab_to_oklch(lab)
  assert_true(lch.c < 0.000001, msg="灰阶 chroma=\{lch.c} 应≈0")
  let back = oklab_to_argb(oklch_to_oklab({ l: lch.l, c: lch.c, h: lch.h + 180.0 }), 255)
  assert_eq(back, gray, msg="无彩色像素转色相应逐位不变")
}

///|
test "HSV affordance：V 不是感知亮度（selector 侧只做分析）" {
  let green = cargb(0, 255, 0)
  let blue = cargb(0, 0, 255)
  let (_, _, vg) = argb_to_hsv(green)
  let (_, _, vb) = argb_to_hsv(blue)
  assert_true(vg > 0.99 && vb > 0.99, msg="HSV V 均为 1.0")
  assert_true(
    argb_to_oklab(green).l > argb_to_oklab(blue).l + 0.3,
    msg="OKLab L 必须区分绿/蓝",
  )
}
