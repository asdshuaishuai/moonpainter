/// pixel —— census / probe 数值事实（pixel/census）。
///
/// PLAN-MVSL §2.2/§2.3 的落点：区域级 census 有循环依赖（AI 先要定位区域，
/// 而定位恰恰是 VLM 最弱项），所以引擎必须自己把「区域是什么」算成事实：
/// hue×sat 桶 + 连通域事实（census），以及「这个点周围到底什么样」
/// （probe：5×5 邻域统计 + 边缘置信度）。
///
/// **AI 不当色度计**：这一层输出的全是确定性数值，VLM 只负责
/// 「选中的是不是头发」这类语义判断。

///|
/// 色相分桶数（每桶 30°）。
pub const CENSUS_HUE_BINS : Int = 12

///|
/// 饱和度分桶数（0–1/3 / 1/3–2/3 / 2/3–1）。
pub const CENSUS_SAT_BINS : Int = 3

///|
/// 饱和度分桶阈值（下界/上界）。
pub const CENSUS_SAT_CUT0 : Double = 0.3333333333333333

///|
pub const CENSUS_SAT_CUT1 : Double = 0.6666666666666666

///|
/// 全图（或选择子区域内）的颜色普查事实。
///
/// `hsl_bins` 的索引是 `sat_bin * 12 + hue_bin`（饱和度为外层，
/// 便于按「先看饱和度再看色相」的顺序读）。
pub(all) struct Census {
  total : Int
  counted : Int // 参与统计的像素数（within 为空时 = total）
  hue_bins : FixedArray[Int]
  sat_bins : FixedArray[Int]
  hsl_bins : FixedArray[Int]
  dominant_bin : Int // hsl_bins 的众数下标；无像素时为 -1
  mean_l : Double // OKLab L（感知亮度）
  mean_s : Double
  mean_v : Double // HSV V —— **仅作对照**：V 不是感知亮度
  mean_h : Double // 环平均色相
}

///|
/// 颜色普查。`within` 为空时统计全图；否则只统计 membership ≥ 阈值
/// （0.5，与证书同一口径）的像素。
pub fn census(base : @codec.RgbaBuf, within : Field?) -> Census {
  let total = base.width * base.height
  let hue_bins = FixedArray::make(CENSUS_HUE_BINS, 0)
  let sat_bins = FixedArray::make(CENSUS_SAT_BINS, 0)
  let hsl = FixedArray::make(CENSUS_HUE_BINS * CENSUS_SAT_BINS, 0)
  let deg2rad = 3.141592653589793 / 180.0
  let mut counted = 0
  let mut sl = 0.0
  let mut ss = 0.0
  let mut sv = 0.0
  let mut shx = 0.0
  let mut shy = 0.0
  let mut i = 0
  while i < total {
    let mut take = true
    match within {
      Some(f) => if f.v[i] < CERT_THRESHOLD {
        take = false
      }
      None => ()
    }
    if take {
      let c = base.pixels[i]
      let (h, s, v) = argb_to_hsv(c)
      let lab = argb_to_oklab(c)
      let mut hb = trunc_pos(h / 30.0)
      if hb >= CENSUS_HUE_BINS {
        hb = CENSUS_HUE_BINS - 1
      }
      if hb < 0 {
        hb = 0
      }
      let sb = if s < CENSUS_SAT_CUT0 {
        0
      } else if s < CENSUS_SAT_CUT1 {
        1
      } else {
        2
      }
      hue_bins[hb] = hue_bins[hb] + 1
      sat_bins[sb] = sat_bins[sb] + 1
      let idx = sb * CENSUS_HUE_BINS + hb
      hsl[idx] = hsl[idx] + 1
      counted = counted + 1
      sl = sl + lab.l
      ss = ss + s
      sv = sv + v
      let rad = h * deg2rad
      shx = shx + mcos(rad)
      shy = shy + msin(rad)
    }
    i = i + 1
  }
  let mut dom = -1
  let mut best = 0
  let mut k = 0
  while k < hsl.length() {
    if hsl[k] > best {
      best = hsl[k]
      dom = k
    }
    k = k + 1
  }
  let n = counted.to_double()
  {
    total,
    counted,
    hue_bins,
    sat_bins,
    hsl_bins: hsl,
    dominant_bin: dom,
    mean_l: if counted > 0 { sl / n } else { 0.0 },
    mean_s: if counted > 0 { ss / n } else { 0.0 },
    mean_v: if counted > 0 { sv / n } else { 0.0 },
    mean_h: if counted > 0 { ring_mean_angle(shx, shy) } else { 0.0 },
  }
}

///|
/// 单点探针事实：半径 r 的方形邻域（默认 r=2 → 5×5）统计。
pub(all) struct Probe {
  x : Int
  y : Int
  r : Int
  color : Int
  mean_l : Double
  var_l : Double // OKLab L 的方差（平坦 vs 纹理）
  mean_a : Double
  mean_b : Double
  mean_h : Double
  mean_s : Double
  mean_v : Double
  edge : Double // OKLab L 的中心差分梯度幅值（每像素 L 单位）
  edge_conf : Double // clamp01(edge / EDGE_SCALE)：边缘置信度
}

///|
/// 边缘置信度的归一化尺度：0.25 L/px 以上视为满置信。
/// 取值的来历：sRGB 里 1 个量化级在中间调约合 0.002 L，而一条真实
/// 硬边（前景/背景色差）通常在 0.05–0.4 L/px。0.25 让「硬边」接近 1、
/// 「渐变」落在 0.1 以下，阈值语义稳定。
pub const EDGE_SCALE : Double = 0.25

///|
/// 探针：单点 + 方形邻域统计。越界点报精确错误（不静默夹取，
/// 否则 AI 会以为自己在看另一个位置）。
pub fn probe(base : @codec.RgbaBuf, x : Int, y : Int, r : Int) -> Result[Probe, String] {
  if x < 0 || x >= base.width || y < 0 || y >= base.height {
    return Err("探针点 (\{x},\{y}) 超出画布 \{base.width}x\{base.height}")
  }
  if r < 0 || r > 32 {
    return Err("探针半径 \{r} 越界（0..32）")
  }
  let deg2rad = 3.141592653589793 / 180.0
  let mut n = 0
  let mut sl = 0.0
  let mut sa = 0.0
  let mut sb = 0.0
  let mut ss = 0.0
  let mut sv = 0.0
  let mut shx = 0.0
  let mut shy = 0.0
  let mut dy = -r
  while dy <= r {
    let mut dx = -r
    while dx <= r {
      let sx = x + dx
      let sy = y + dy
      if sx >= 0 && sx < base.width && sy >= 0 && sy < base.height {
        let c = base.pixels[sy * base.width + sx]
        let lab = argb_to_oklab(c)
        let (h, s, v) = argb_to_hsv(c)
        sl = sl + lab.l
        sa = sa + lab.a
        sb = sb + lab.b
        ss = ss + s
        sv = sv + v
        let rad = h * deg2rad
        shx = shx + mcos(rad)
        shy = shy + msin(rad)
        n = n + 1
      }
      dx = dx + 1
    }
    dy = dy + 1
  }
  let nd = n.to_double()
  let mean_l = sl / nd
  // 第二趟：方差（需要先有均值）
  let mut var_l = 0.0
  dy = -r
  while dy <= r {
    let mut dx = -r
    while dx <= r {
      let sx = x + dx
      let sy = y + dy
      if sx >= 0 && sx < base.width && sy >= 0 && sy < base.height {
        let lab = argb_to_oklab(base.pixels[sy * base.width + sx])
        let d = lab.l - mean_l
        var_l = var_l + d * d
      }
      dx = dx + 1
    }
    dy = dy + 1
  }
  // 中心差分梯度（越界用中心像素兜底，保证确定性且不引入 0 假边）
  let lc = argb_to_oklab(base.pixels[y * base.width + x]).l
  let lx0 = if x - 1 >= 0 { argb_to_oklab(base.pixels[y * base.width + x - 1]).l } else { lc }
  let lx1 = if x + 1 < base.width {
    argb_to_oklab(base.pixels[y * base.width + x + 1]).l
  } else {
    lc
  }
  let ly0 = if y - 1 >= 0 {
    argb_to_oklab(base.pixels[(y - 1) * base.width + x]).l
  } else {
    lc
  }
  let ly1 = if y + 1 < base.height {
    argb_to_oklab(base.pixels[(y + 1) * base.width + x]).l
  } else {
    lc
  }
  let gx = (lx1 - lx0) * 0.5
  let gy = (ly1 - ly0) * 0.5
  let edge = msqrt(gx * gx + gy * gy)
  Ok({
    x,
    y,
    r,
    color: base.pixels[y * base.width + x],
    mean_l,
    var_l: var_l / nd,
    mean_a: sa / nd,
    mean_b: sb / nd,
    mean_h: ring_mean_angle(shx, shy),
    mean_s: ss / nd,
    mean_v: sv / nd,
    edge,
    edge_conf: clamp01(edge / EDGE_SCALE),
  })
}

///|
/// 标签场在某点的连通域 id（0 = 不在任何连通域内）。
pub fn component_id_at(labels : Field, x : Int, y : Int) -> Int {
  if x < 0 || x >= labels.w || y < 0 || y >= labels.h {
    0
  } else {
    trunc_pos(labels.v[y * labels.w + x])
  }
}
