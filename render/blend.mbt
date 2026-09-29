/// render —— 像素合成：混合模式与 source-over（render/blend）。
///
/// 公式对齐 W3C Compositing and Blending Level 1（Photoshop 同源语义）：
///   Co = αs·(1−αb)·Cs + αs·αb·B(Cb,Cs) + (1−αs)·αb·Cb   （预乘）
///   αo = αs + αb·(1−αs)
/// B 为按通道的混合函数（normal/multiply/screen/overlay/darken/lighten/difference）。
/// Double 运算是 IEEE 精确确定的——golden 渲染的 sha256 因此可复现。

///|
/// 按通道混合函数（cb/cs ∈ 0..1，为背景/源的非预乘通道值）。
fn blend_channel(b : @core.BlendMode, cb : Double, cs : Double) -> Double {
  match b {
    @core.BlendMode::Normal => cs
    @core.BlendMode::Multiply => cb * cs
    @core.BlendMode::Screen => cb + cs - cb * cs
    @core.BlendMode::Overlay => {
      // overlay(cs, cb) = hardlight(cs, cb)：以背景明暗选段
      if cb <= 0.5 {
        2.0 * cb * cs
      } else {
        1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
      }
    }
    @core.BlendMode::Darken => if cb < cs { cb } else { cs }
    @core.BlendMode::Lighten => if cb > cs { cb } else { cs }
    @core.BlendMode::Difference => {
      let d = cb - cs
      if d < 0.0 { -d } else { d }
    }
  }
}

///|
fn clamp01(v : Double) -> Double {
  if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// 把 src 以指定混合模式合成到 dst 上（两者都是 0xAARRGGBB 直通 alpha）。
pub fn composite_pixel(
  dst : Int,
  src : Int,
  mode : @core.BlendMode,
) -> Int {
  let sa = ((src >> 24) & 0xFF).to_double() / 255.0
  let da = ((dst >> 24) & 0xFF).to_double() / 255.0
  let ao = sa + da * (1.0 - sa)
  if ao <= 0.0 {
    // 双方全透明：保留 dst 的通道为零形态
    return 0x00000000
  }
  let sb = ((src >> 16) & 0xFF).to_double() / 255.0
  let sg = ((src >> 8) & 0xFF).to_double() / 255.0
  let sr = (src & 0xFF).to_double() / 255.0
  let db = ((dst >> 16) & 0xFF).to_double() / 255.0
  let dg = ((dst >> 8) & 0xFF).to_double() / 255.0
  let dr = (dst & 0xFF).to_double() / 255.0
  let o_r = sa * (1.0 - da) * sr + sa * da * blend_channel(mode, dr, sr) +
    (1.0 - sa) * da * dr
  let o_g = sa * (1.0 - da) * sg + sa * da * blend_channel(mode, dg, sg) +
    (1.0 - sa) * da * dg
  let o_b = sa * (1.0 - da) * sb + sa * da * blend_channel(mode, db, sb) +
    (1.0 - sa) * da * db
  // 去预乘回直通
  let ur = unpremul(o_r, ao)
  let ug = unpremul(o_g, ao)
  let ub = unpremul(o_b, ao)
  let a255 = (ao * 255.0 + 0.5).to_int()
  (a255 << 24) + (ub << 16) + (ug << 8) + ur
}

///|
fn unpremul(premul : Double, alpha : Double) -> Int {
  let v = clamp01(premul / alpha) * 255.0 + 0.5
  v.to_int()
}

///|
/// 两个直通色按 t（0..1）线性插值（渐变求值用）。
pub fn lerp_color(c0 : Int, c1 : Int, t : Double) -> Int {
  let t = clamp01(t)
  let a0 = ((c0 >> 24) & 0xFF).to_double()
  let a1 = ((c1 >> 24) & 0xFF).to_double()
  let b0 = ((c0 >> 16) & 0xFF).to_double()
  let b1 = ((c1 >> 16) & 0xFF).to_double()
  let g0 = ((c0 >> 8) & 0xFF).to_double()
  let g1 = ((c1 >> 8) & 0xFF).to_double()
  let r0 = (c0 & 0xFF).to_double()
  let r1 = (c1 & 0xFF).to_double()
  let mix = fn(x : Double, y : Double) -> Int {
    (x + (y - x) * t + 0.5).to_int()
  }
  (mix(a0, a1) << 24) + (mix(b0, b1) << 16) + (mix(g0, g1) << 8) + mix(r0, r1)
}
