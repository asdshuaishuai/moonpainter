/// pixel —— OKLab/OKLCh 色彩语义（pixel/color）。
///
/// 纪律（PLAN-MVSL.md §1.3）：**弃 HSV「保明暗」**。V 不是感知亮度
/// （纯绿 Y≈0.72 vs 纯蓝 Y≈0.07），用它 preserve 明暗会让蓝色变黑。
/// recolor 一律在 OKLCh 改 h、preserve = OKLab L、chroma 做 gamut
/// compress；HSV 降级为 selector/analysis affordance field。
///
/// 数学全部自写（sqrt/cbrt/atan2/sin/cos 走泰勒+Padé），与 render 包
/// 同款纪律：三个 target（native/wasm-gc/js）逐位一致，bit-exact 契约
/// 的数值基础。管线内浮点、末端一次量化（不在中间步 round）。

///|
pub const PI : Double = 3.141592653589793

///|
pub const PI_2 : Double = 1.5707963267948966

///|
pub const TWO_PI : Double = 6.283185307179586

///|
/// OKLab 坐标（L 0..1，a/b 约 -0.4..0.4）。
pub(all) struct Oklab {
  l : Double
  a : Double
  b : Double
}

///|
/// OKLCh 坐标（h 度 0..360，C ≥ 0）。
pub(all) struct Oklch {
  l : Double
  c : Double
  h : Double
}

// ---------------------------------------------------------------------------
// 基础数学（自写，保证跨 target 逐位一致）
// ---------------------------------------------------------------------------

///|
/// sqrt（牛顿迭代，8 次收敛到双精度极限；初值取量级估计）。
pub fn msqrt(v : Double) -> Double {
  if v <= 0.0 {
    return 0.0
  }
  let mut x = if v >= 1.0 { v } else { 1.0 }
  let mut i = 0
  while i < 40 {
    let nx = 0.5 * (x + v / x)
    if nx == x {
      return nx
    }
    x = nx
    i = i + 1
  }
  x
}

///|
/// cbrt（牛顿迭代，支持负数）。
fn mcbrt(v : Double) -> Double {
  if v == 0.0 {
    return 0.0
  }
  let neg = v < 0.0
  let a = if neg { -v } else { v }
  let mut x = if a >= 1.0 { a } else { 1.0 }
  let mut i = 0
  while i < 60 {
    let nx = (2.0 * x + a / (x * x)) / 3.0
    if nx == x {
      break
    }
    x = nx
    i = i + 1
  }
  if neg {
    -x
  } else {
    x
  }
}

///|
/// sin(x)：先取非负（奇对称），归约到 [0, π/2]（周期 + 轴对称），
/// 再展开泰勒级数。
///
/// **为什么归约到半象限而不是 [−π, π]**：同样的 7 项级数在 |x| ≤ π/2
/// 的截断误差是 ~1e-11，在 |x| ≈ 2.1（[−π, π] 区间内）则是 ~3e-8。
/// 色相 → OKLab → sRGB 的往返精度直接吃这个误差。
fn msin(x : Double) -> Double {
  let neg = x < 0.0
  let a = if neg { -x } else { x }
  // sin(r + kπ) = (−1)^k · sin(r)，r ∈ [0, π)
  let k = trunc_pos(a / PI)
  let mut r = a - PI * k.to_double()
  let sign = if k % 2 == 1 { -1.0 } else { 1.0 }
  // sin(r) = sin(π − r)：把 r 折回 [0, π/2]
  if r > PI_2 {
    r = PI - r
  }
  let x2 = r * r
  let s = r *
  (1.0 +
  x2 * (-0.16666666666666666 +
  x2 * (0.008333333333333333 +
  x2 * (-0.0001984126984126984 +
  x2 * (2.755731922398589E-06 +
  x2 * (-2.505210838544172E-08 +
  x2 * (1.605904383682161E-10 + x2 * (-7.647163731819816E-13))))))))
  if neg { -sign * s } else { sign * s }
}

///|
fn mcos(x : Double) -> Double {
  msin(x + PI_2)
}

///|
/// arctan(|t| ≤ 1)：atan(t) = 2·atan(t/(1+√(1+t²))) 半角降阶 +
/// atan(u) Maclaurin 交错级数 17 项（|u| ≤ tan(π/8) ≈ 0.414，
/// 系数 +−+− 交错：x − x³/3 + x⁵/5 − …）。
fn atan_unit(t : Double) -> Double {
  if t == 0.0 {
    return 0.0
  }
  let neg = t < 0.0
  let a = if neg { -t } else { t }
  // 半角降阶：atan(a) = 2 atan(u)，u = a/(1+sqrt(1+a²))
  let u = a / (1.0 + msqrt(1.0 + a * a))
  let u2 = u * u
  let mut acc = 0.0
  let mut p = u
  let mut s = 1.0
  let mut i = 1
  while i <= 33 {
    acc = acc + s * p / i.to_double()
    p = p * u2
    s = -s
    i = i + 2
  }
  let r = 2.0 * acc
  if neg {
    -r
  } else {
    r
  }
}

///|
/// atan2(y, x)，四象限展开。base = 到 +x 轴的**锐角**（0..π/2），
/// 用 ax/ay 的比值选用 atan_unit（|arg| ≤ 1 恒成立）+ 象限修正。
pub fn matan2(y : Double, x : Double) -> Double {
  if x == 0.0 {
    if y > 0.0 {
      return PI_2
    } else if y < 0.0 {
      return -PI_2
    } else {
      return 0.0
    }
  }
  let ax = if x < 0.0 { -x } else { x }
  let ay = if y < 0.0 { -y } else { y }
  // base = 到 +x 轴的锐角：atan(ay/ax) 在 ay≤ax 时 |arg|≤1；
  // ay>ax 时用余角恒等 atan(ay/ax) = π/2 − atan(ax/ay)
  let base = if ay > ax {
    PI_2 - atan_unit(ax / ay)
  } else if ax == 0.0 {
    PI_2
  } else {
    atan_unit(ay / ax)
  }
  if x > 0.0 {
    if y >= 0.0 {
      base
    } else {
      -base
    }
  } else if y >= 0.0 {
    PI - base
  } else {
    base - PI
  }
}

// ---------------------------------------------------------------------------
// sRGB ⇄ 线性 ⇄ OKLab/OKLCh
// ---------------------------------------------------------------------------

///|
fn srgb_to_linear(v : Double) -> Double {
  if v <= 0.04045 {
    v / 12.92
  } else {
    let a = (v + 0.055) / 1.055
    // **a^2.4，不是 a*a*a**。sRGB 的编码指数是 2.4；写成三次方是
    // 最容易混进来的「近似」——纯三原色碰巧仍能往返（0/1 是幂的不动
    // 点），中间灰一测就现原形（ΔE ≈ 0.078）。
    mexp(mln(a) * 2.4)
  }
}

///|
fn linear_to_srgb(v : Double) -> Double {
  if v <= 0.0031308 {
    v * 12.92
  } else {
    // sRGB 需要 v^(1/2.4)；家族无内建 pow，走 exp(ln(v)/2.4) 级数
    exp_1_2p4(v) * 1.055 - 0.055
  }
}

///|
/// v^(1/2.4)（v ≥ 0）：exp(ln(v)/2.4)，两个级数都是确定性的。
fn exp_1_2p4(v : Double) -> Double {
  if v <= 0.0 {
    return 0.0
  }
  if v == 1.0 {
    return 1.0
  }
  mexp(mln(v) / 2.4)
}

///|
/// exp(x)：O(1) 归约 + 泰勒 20 项 + 2^k 精确缩放。
///
/// 归约必须是**自洽**的：若以 ln2 为步长分离整数指数 k
/// （`x = k·ln2 + r`，`|r| ≤ ln2/2`），放缩就必须乘 **2^k**，
/// 而不是乘 e^k——「减 ln2、乘 e」会把 e^(x) 算成 e^(x−k+k/ln2)，
/// 中间灰的 sRGB→线性转换因此整体偏掉（ΔE ≈ 0.1）。
/// 乘 2 在二进制浮点里是精确的，不引入额外误差。
///
/// 上下界饱和与 IEEE 语义一致（不产生 NaN/Inf 混进画布字节）。
fn mexp(x : Double) -> Double {
  if x > 709.0 {
    return 1.7976931348623157E308
  }
  if x < -745.0 {
    return 0.0
  }
  let ln2 = 0.6931471805599453
  // 1/ln2，O(1) 求 k = round(x/ln2)（不走会随 |x| 线性增长的循环）
  let q = x * 1.4426950408889634
  let k = if q >= 0.0 { trunc_pos(q + 0.5) } else { -trunc_pos(-q + 0.5) }
  let xx = x - k.to_double() * ln2
  let mut acc = 1.0
  let mut term = 1.0
  let mut i = 1
  while i <= 20 {
    term = term * xx / i.to_double()
    acc = acc + term
    i = i + 1
  }
  let mut r = acc
  let mut j = 0
  if k >= 0 {
    while j < k {
      r = r * 2.0
      j = j + 1
    }
  } else {
    while j > k {
      r = r * 0.5
      j = j - 1
    }
  }
  r
}

///|
/// ln(v)，v > 0：range reduction 到 [1,2) 后 atanh 级数。
fn mln(v : Double) -> Double {
  if v <= 0.0 {
    return 0.0
  }
  // 提取 2 的幂指数 m，使 v / 2^m ∈ [0.75, 1.5)
  let mut m = 0
  let mut x = v
  while x >= 1.5 {
    x = x / 2.0
    m = m + 1
  }
  while x < 0.75 {
    x = x * 2.0
    m = m - 1
  }
  // ln(x) = 2*(t + t³/3 + t⁵/5 + …)，t = (x-1)/(x+1)
  let t = (x - 1.0) / (x + 1.0)
  let t2 = t * t
  let mut acc = 0.0
  let mut p = t
  let mut i = 1
  while i <= 31 {
    acc = acc + p / i.to_double()
    p = p * t2
    i = i + 2
  }
  2.0 * acc + m.to_double() * 0.6931471805599453
}

///|
pub fn clamp01(v : Double) -> Double {
  if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
fn ch8(v : Int) -> Double {
  (v & 0xFF).to_double() / 255.0
}

///|
/// 0xAARRGGBB → OKLab（alpha 不参与色彩变换）。
pub fn argb_to_oklab(argb : Int) -> Oklab {
  let a8 = lsr32(argb, 24)
  let rr = lsr32(argb, 16) & 0xFF
  let gg = lsr32(argb, 8) & 0xFF
  let bb = argb & 0xFF
  let r = srgb_to_linear(ch8(rr))
  let g = srgb_to_linear(ch8(gg))
  let b = srgb_to_linear(ch8(bb))
  let _ = a8
  let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
  let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
  let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
  let l_ = mcbrt(l)
  let m_ = mcbrt(m)
  let s_ = mcbrt(s)
  let ol = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
  let oa = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
  let ob = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
  { l: ol, a: oa, b: ob }
}

///|
fn oklab_to_linear(c : Oklab) -> (Double, Double, Double) {
  let l_ = c.l + 0.3963377774 * c.a + 0.2158037573 * c.b
  let m_ = c.l - 0.1055613458 * c.a - 0.0638541728 * c.b
  let s_ = c.l - 0.0894841775 * c.a - 1.2914855480 * c.b
  let l3 = l_ * l_ * l_
  let m3 = m_ * m_ * m_
  let s3 = s_ * s_ * s_
  let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
  let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
  let b = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
  (r, g, b)
}

///|
/// gamut 容差：IEEE-754 的算不准不是越界。纯红的线性 G/B ≈ −1.8e-8，
/// 若按 v ≥ 0 判定就会误判整条色为越界（进而整像素被压成黑）。
/// 1e-6 的容差在末端量化里的最大影响远小于 1/255 LSB。
const GAMUT_EPS : Double = 1.0E-6

///|
fn in_gamut(v : Double) -> Bool {
  v >= -GAMUT_EPS && v <= 1.0 + GAMUT_EPS
}

///|
/// gamut compress：**在 OKLCh 里收 chroma**（保持 h 与 L 不变），
/// 而不是逐通道 clip、也不是线性 RGB 等比缩放。
///
/// - 逐通道 clip 会改色相（「蓝边变紫边」的同源问题）；
/// - 线性 RGB 等比缩放修不了负通道：缩放的不动点是原点，负值越缩越是
///   负数，判据永远不成立——纯红会被压成纯黑（这正是修掉的那个 bug）。
/// - OKLCh 收 chroma 保持 h（色相）与 L（感知亮度）不变，越界越多的
///   颜色被收得越狠，落在色域边界上，符合「chroma 做 gamut compress」
///   的既定语义。
///
/// 24 步二分（确定性，非搜索）：求最大 chroma 缩放 s ∈ [0,1]，使
/// OKLab{L, a·s, b·s} 落入 sRGB 线性域。L 本身越界时 s 收敛到 0
/// （灰度），末端由 clamp01 收口。
fn gamut_compress(c : Oklab) -> (Double, Double, Double) {
  let (r0, g0, b0) = oklab_to_linear(c)
  if in_gamut(r0) && in_gamut(g0) && in_gamut(b0) {
    return (r0, g0, b0)
  }
  let mut lo = 0.0
  let mut hi = 1.0
  let mut i = 0
  while i < 24 {
    let mid = 0.5 * (lo + hi)
    let (r, g, b) = oklab_to_linear({ l: c.l, a: c.a * mid, b: c.b * mid })
    if in_gamut(r) && in_gamut(g) && in_gamut(b) {
      lo = mid
    } else {
      hi = mid
    }
    i = i + 1
  }
  oklab_to_linear({ l: c.l, a: c.a * lo, b: c.b * lo })
}

///|
/// OKLab → 0xAARRGGBB（gamut compress + 末端一次量化）。
/// 通道顺序：(alpha << 24) + (R << 16) + (G << 8) + B（与全引擎一致）。
pub fn oklab_to_argb(c : Oklab, alpha : Int) -> Int {
  let (cr, cg, cb) = gamut_compress(c)
  let r = quant8(linear_to_srgb(clamp01(cr)))
  let g = quant8(linear_to_srgb(clamp01(cg)))
  let b = quant8(linear_to_srgb(clamp01(cb)))
  (alpha << 24) + (r << 16) + (g << 8) + b
}

///|
fn quant8(v : Double) -> Int {
  // 像素是 0..255 小数：不走 Double::to_int（那是 32 位饱和语义）。
  // 手写 round-half-up（与 render/blend 的 unpremul 同款 +0.5 截断）。
  let q = v * 255.0 + 0.5
  if q < 0.0 {
    0
  } else if q > 255.0 {
    255
  } else {
    quant8_loop(q, 0)
  }
}

///|
/// trunc(q)：q ∈ [0, 256)，逐次减一定位到整数（慢但确定、无饱和坑）。
fn quant8_loop(q : Double, acc : Int) -> Int {
  if q < 1.0 {
    acc
  } else {
    quant8_loop(q - 1.0, acc + 1)
  }
}

///|
pub fn oklab_to_oklch(c : Oklab) -> Oklch {
  let ch = msqrt(c.a * c.a + c.b * c.b)
  if ch < 1.0E-9 {
    { l: c.l, c: 0.0, h: 0.0 }
  } else {
    let mut h = matan2(c.b, c.a) * 180.0 / PI
    if h < 0.0 {
      h = h + 360.0
    }
    if h >= 360.0 {
      h = h - 360.0
    }
    { l: c.l, c: ch, h }
  }
}

///|
pub fn oklch_to_oklab(c : Oklch) -> Oklab {
  let rad = c.h * PI / 180.0
  { l: c.l, a: c.c * mcos(rad), b: c.c * msin(rad) }
}

///|
/// OKLab ΔE（欧氏距离，感知近似）。断言与 impact 证书统一用它。
pub fn delta_e(a : Oklab, b : Oklab) -> Double {
  let dl = a.l - b.l
  let da = a.a - b.a
  let db = a.b - b.b
  msqrt(dl * dl + da * da + db * db)
}

///|
/// 0xAARRGGBB 对的 ΔE（alpha 不计入色彩距离）。
pub fn delta_e_argb(c0 : Int, c1 : Int) -> Double {
  delta_e(argb_to_oklab(c0), argb_to_oklab(c1))
}

// ---------------------------------------------------------------------------
// 谓词基础：色相环距离 / 软窗 / HSV affordance
// ---------------------------------------------------------------------------

///|
/// 色相**环**距离（0..180）：h=359° 与 h=1° 的距离是 2° 而非 358°。
/// wrap-around 是颜色谓词的第一视觉失败点。
pub fn hue_ring_dist(h0 : Double, h1 : Double) -> Double {
  let mut d = if h0 > h1 { h0 - h1 } else { h1 - h0 }
  while d > 180.0 {
    d = 360.0 - d
  }
  d
}

///|
/// smoothstep 软窗：t ∈ [0,1] → 0..1，边界连续可导。
/// 「软边界 ≠ 模糊 mask」：软窗在**谓词空间**收窄，不是把 mask 模糊。
pub fn smoothstep(t : Double) -> Double {
  if t <= 0.0 {
    0.0
  } else if t >= 1.0 {
    1.0
  } else {
    t * t * (3.0 - 2.0 * t)
  }
}

///|
/// 软窗隶属度：d=到中心距离，half=半窗宽，feather=过渡带占比
/// （0=硬边；1=窗内无恒 1 区间，纯过渡）。窗内恒 1 区间宽 = half*(1-feather)。
pub fn window_membership(d : Double, half : Double, feather : Double) -> Double {
  if feather <= 1.0E-9 {
    return if d <= half { 1.0 } else { 0.0 }
  }
  let core = half * (1.0 - feather)
  if d <= core {
    return 1.0
  }
  if d >= half {
    return 0.0
  }
  if core <= 0.0 {
    return smoothstep((half - d) / half)
  }
  smoothstep((half - d) / (half - core))
}

///|
/// 0xAARRGGBB → HSV 亲和度三元组 (h 0..360, s 0..1, v 0..1)。
///
/// **仅供 selector / analysis affordance**（census 桶、probe 报告）；
/// 算子一律走 OKLab/OKLCh——V 不是感知亮度（纯绿 Y≈0.72 vs 纯蓝
/// Y≈0.07），用它 preserve 明暗会把蓝色压成黑色。
pub fn argb_to_hsv(argb : Int) -> (Double, Double, Double) {
  let r = ch8(lsr32(argb, 16) & 0xFF)
  let g = ch8(lsr32(argb, 8) & 0xFF)
  let b = ch8(argb & 0xFF)
  let mx = rmax3(r, g, b)
  let mn = rmin3(r, g, b)
  let d = mx - mn
  let mut hh = 0.0
  if d > 1.0E-9 {
    if mx == r {
      hh = 60.0 * (((g - b) / d) % 6.0)
    } else if mx == g {
      hh = 60.0 * (((b - r) / d) + 2.0)
    } else {
      hh = 60.0 * (((r - g) / d) + 4.0)
    }
    while hh < 0.0 {
      hh = hh + 360.0
    }
    while hh >= 360.0 {
      hh = hh - 360.0
    }
  }
  let ss = if mx > 1.0E-9 { d / mx } else { 0.0 }
  (hh, ss, mx)
}

///|
fn rmax3(a : Double, b : Double, c : Double) -> Double {
  let mut m = a
  if b > m {
    m = b
  }
  if c > m {
    m = c
  }
  m
}

///|
fn rmin3(a : Double, b : Double, c : Double) -> Double {
  let mut m = a
  if b < m {
    m = b
  }
  if c < m {
    m = c
  }
  m
}
