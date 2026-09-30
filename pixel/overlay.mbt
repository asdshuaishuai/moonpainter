/// pixel —— 选择子覆盖预览与盒平均降采样（pixel/overlay）。
///
/// PLAN-MVSL §2.4 的分工：**数值 certificate 给 agent 做闭环，overlay 图
/// 给人/VLM 做语义确认**。两者并存，谁也替代不了谁——「render 是最后的
/// 视觉审查，不应是第一次发现 selector 错的地方」。
///
/// 铁律：**先按全分辨率生成 overlay，再降采样**。反过来（先降采样再算
/// 覆盖）会把发丝/树枝级的软边界平均掉，VLM 看到一片干净背景就会判定
/// 「没选中」——预览与终渲染不一致的经典翻车点。

///|
/// 覆盖预览色：洋红。自然图像里极少出现，不会被误当成原图内容。
pub const OVERLAY_ARGb : Int = 0xFFFF00FF

///|
/// 覆盖混色上限（0.7）：留一部分原色，人眼/VLM 都要能把选区对位到
/// 原图内容上；盖满会让人分不清「选中的是什么」。
pub const OVERLAY_ALPHA : Double = 0.7

///|
/// 选择子覆盖预览：选中处向洋红软过渡（强度随 membership），
/// 未选中处逐位保持原像素。alpha 一律 255（预览是不透明图）。
pub fn overlay_buf(base : @codec.RgbaBuf, f : Field, cap : Int) -> @codec.RgbaBuf {
  let full = @codec.rgba_new(base.width, base.height)
  let total = base.width * base.height
  let mut i = 0
  while i < total {
    let c = base.pixels[i]
    let w = clamp01(f.v[i])
    if w <= 0.0 {
      full.pixels[i] = c
    } else {
      let mixed = lerp_argb(c, OVERLAY_ARGb, OVERLAY_ALPHA * w)
      full.pixels[i] = (0xFF << 24) + (mixed & 0x00FFFFFF)
    }
    i = i + 1
  }
  downsample_box(full, cap)
}

///|
/// 整数倍盒平均降采样：任一边降到手 `max_side` 以内。
/// 确定性（无插值核、无浮点权重），预览与终渲染同管线的收口手段。
pub fn downsample_box(src : @codec.RgbaBuf, max_side : Int) -> @codec.RgbaBuf {
  if max_side <= 0 {
    return src
  }
  let mut k = 1
  while ceil_div(src.width, k) > max_side || ceil_div(src.height, k) > max_side {
    k = k + 1
  }
  if k == 1 {
    return src
  }
  let ow = ceil_div(src.width, k)
  let oh = ceil_div(src.height, k)
  let out = @codec.rgba_new(ow, oh)
  let mut y = 0
  while y < oh {
    let mut x = 0
    while x < ow {
      let mut sa = 0
      let mut sr = 0
      let mut sg = 0
      let mut sb = 0
      let mut n = 0
      let mut dy = 0
      while dy < k {
        let mut dx = 0
        while dx < k {
          let sx = x * k + dx
          let sy = y * k + dy
          if sx < src.width && sy < src.height {
            let c = src.pixels[sy * src.width + sx]
            sa = sa + lsr32(c, 24)
            sr = sr + (lsr32(c, 16) & 0xFF)
            sg = sg + (lsr32(c, 8) & 0xFF)
            sb = sb + (c & 0xFF)
            n = n + 1
          }
          dx = dx + 1
        }
        dy = dy + 1
      }
      out.pixels[y * ow + x] = (round_div(sa, n) << 24) +
        (round_div(sr, n) << 16) +
        (round_div(sg, n) << 8) +
        round_div(sb, n)
      x = x + 1
    }
    y = y + 1
  }
  out
}

///|
fn ceil_div(a : Int, b : Int) -> Int {
  if b <= 0 {
    a
  } else {
    (a + b - 1) / b
  }
}

///|
/// 整数四舍五入除法（round-half-up，确定性）。
fn round_div(s : Int, n : Int) -> Int {
  if n <= 0 {
    0
  } else {
    (s * 2 + n) / (n * 2)
  }
}
