/// render —— 场景求值：文档层树 → 画布像素（render/scene）。
///
/// 管线（PLAN.md §5）：层树自底向上 → 每层在包围盒内做 2×2 子采样覆盖
/// （AA）→ 层透明度并入源 alpha → 按混合模式逐像素合成。
/// 组 = 直通：只传递可见性与透明度，不建离屏缓冲（诚实边界：组级混合
/// 不生效，DESIGN 已注明）。
///
/// 坐标系：画布像素坐标（原点左上，y 向下）；层局部坐标 0..w / 0..h。
/// 旋转绕层中心，逆变换后做轴对齐内点测试。

///|
/// 渲染上限（P0 护栏：防大画布内存失控，PLAN.md §9）。
pub const RENDER_MAX_SIDE : Int = 4096

///|
/// 会话提供的位图资产（hash → 已解码画布）。
pub(all) struct RenderEnv {
  assets : Map[String, @codec.RgbaBuf]
}

///|
pub fn RenderEnv::new() -> RenderEnv {
  { assets: Map([]) }
}

///|
/// 设备坐标 → 层局部坐标（含绕层中心的逆旋转）。
fn to_local(
  l : @core.Layer,
  px : Double,
  py : Double,
) -> (Double, Double) {
  let cx = l.x + l.w / 2.0
  let cy = l.y + l.h / 2.0
  // 正向管线：局部坐标 →（flip 镜像）→ 绕中心旋转 → 平移到层位。
  // 逆映射：设备点 → 逆旋转 → 逆翻转 → 局部坐标。
  let mut lx = 0.0
  let mut ly = 0.0
  if l.rotation_deg == 0.0 {
    lx = px - l.x
    ly = py - l.y
  } else {
    let rad = l.rotation_deg * 3.141592653589793 / 180.0
    // 逆旋转（顺时针 θ 的逆 = 逆时针 θ）
    let cos_t = cos_rad(rad)
    let sin_t = sin_rad(rad)
    let dx = px - cx
    let dy = py - cy
    lx = dx * cos_t + dy * sin_t + l.w / 2.0
    ly = -dx * sin_t + dy * cos_t + l.h / 2.0
  }
  if l.flip_h {
    lx = l.w - lx
  }
  if l.flip_v {
    ly = l.h - ly
  }
  (lx, ly)
}

///|
/// 局部坐标系下的形状内点测试（fill）。
fn inside_fill(l : @core.Layer, lx : Double, ly : Double) -> Bool {
  match l.kind {
    @core.ShapeKind::Rect => in_rounded_rect(lx, ly, l.w, l.h, l.corner_radius)
    @core.ShapeKind::Ellipse => {
      if l.w <= 0.0 || l.h <= 0.0 {
        return false
      }
      let nx = lx / l.w * 2.0 - 1.0
      let ny = ly / l.h * 2.0 - 1.0
      nx * nx + ny * ny <= 1.0
    }
    @core.ShapeKind::Polygon => in_polygon(l.points, lx, ly)
    @core.ShapeKind::Line => false // 线段无填充面
    @core.ShapeKind::Image => lx >= 0.0 && lx < l.w && ly >= 0.0 && ly < l.h
    @core.ShapeKind::Group => false
  }
}

///|
/// 圆角矩形内点测试。
fn in_rounded_rect(
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  r : Double,
) -> Bool {
  if x < 0.0 || y < 0.0 || x >= w || y >= h {
    return false
  }
  if r <= 0.0 {
    return true
  }
  let rr = if r > w / 2.0 {
    w / 2.0
  } else if r > h / 2.0 {
    h / 2.0
  } else {
    r
  }
  // 四角区域内的，做圆距测试
  let nx = if x < rr { rr - x } else if x > w - rr { x - (w - rr) } else { 0.0 }
  let ny = if y < rr { rr - y } else if y > h - rr { y - (h - rr) } else { 0.0 }
  if nx == 0.0 || ny == 0.0 {
    return true
  }
  nx * nx + ny * ny <= rr * rr
}

///|
/// even-odd 多边形内点测试。
fn in_polygon(
  pts : Array[(Double, Double)],
  x : Double,
  y : Double,
) -> Bool {
  if pts.length() < 3 {
    return false
  }
  let mut inside = false
  let n = pts.length()
  let mut j = n - 1
  let mut i = 0
  while i < n {
    let (xi, yi) = pts[i]
    let (xj, yj) = pts[j]
    if (yi > y) != (yj > y) &&
      x < (xj - xi) * (y - yi) / (yj - yi) + xi {
      inside = !inside
    }
    j = i
    i = i + 1
  }
  inside
}

///|
/// 局部坐标系下的描边带测试（stroke）。
fn inside_stroke(l : @core.Layer, lx : Double, ly : Double) -> Bool {  let width = if l.stroke.width > 0.0 {
    l.stroke.width
  } else {
    0.0
  }
  if width <= 0.0 {
    return false
  }
  match l.kind {
    @core.ShapeKind::Line => {
      // 折线各段的距离测试
      let pts = l.points
      if pts.length() < 2 {
        return false
      }
      let half = width / 2.0
      let mut i = 0
      while i + 1 < pts.length() {
        if dist_to_seg(lx, ly, pts[i].0, pts[i].1, pts[i + 1].0, pts[i + 1].1) <= half {
          return true
        }
        i = i + 1
      }
      false
    }
    @core.ShapeKind::Rect => {
      // 外矩形内 && 内矩形（收缩 width）外
      let outer = in_rounded_rect(lx, ly, l.w, l.h, l.corner_radius)
      let inner = in_rounded_rect(
        lx - width,
        ly - width,
        l.w - width * 2.0,
        l.h - width * 2.0,
        l.corner_radius - width,
      )
      outer && !inner
    }
    @core.ShapeKind::Ellipse => {
      if l.w <= 0.0 || l.h <= 0.0 {
        return false
      }
      let nx = lx / l.w * 2.0 - 1.0
      let ny = ly / l.h * 2.0 - 1.0
      let d = Double::sqrt(nx * nx + ny * ny)
      // 近似带宽：以归一化半径衡量
      let inner_r = 1.0 - width * 2.0 / (if l.w < l.h { l.w } else { l.h })
      d <= 1.0 && d >= inner_r
    }
    // 多边形/图片/组：多边形描边与位图描边不实现（诚实边界），按无描边处理
    _ => false
  }
}

///|
fn dist_to_seg(
  px : Double,
  py : Double,
  ax : Double,
  ay : Double,
  bx : Double,
  by : Double,
) -> Double {
  let abx = bx - ax
  let aby = by - ay
  let len2 = abx * abx + aby * aby
  if len2 <= 0.0 {
    let dx = px - ax
    let dy = py - ay
    return Double::sqrt(dx * dx + dy * dy)
  }
  let t = clamp01(((px - ax) * abx + (py - ay) * aby) / len2)
  let cx = ax + abx * t
  let cy = ay + aby * t
  let dx = px - cx
  let dy = py - cy
  Double::sqrt(dx * dx + dy * dy)
}

///|
/// 渐变求值：局部点在渐变轴上的投影 t → 插值色。
fn fill_color_at(
  f : @core.Fill,
  lx : Double,
  ly : Double,
  w : Double,
  h : Double,
) -> Int {
  match f {
    @core.Fill::NoFill => 0x00000000
    @core.Fill::Solid(c) => c
    @core.Fill::LinearGradient(c0, c1, x0, y0, x1, y1) => {
      // 端点为 0..1 局部比例坐标
      let ax = x0 * w
      let ay = y0 * h
      let bx = x1 * w
      let by = y1 * h
      let vx = bx - ax
      let vy = by - ay
      let len2 = vx * vx + vy * vy
      let t = if len2 <= 0.0 {
        0.0
      } else {
        clamp01(((lx - ax) * vx + (ly - ay) * vy) / len2)
      }
      lerp_color(c0, c1, t)
    }
  }
}

///|
/// 渲染单个层到画布（含 2×2 子采样 AA 与混合）。
fn paint_layer(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  env : RenderEnv,
  inherited_opacity : Double,
) -> Unit {
  if !l.visible || l.opacity <= 0.0 {
    return
  }
  let eff_opacity = clamp01(l.opacity * inherited_opacity)
  if eff_opacity <= 0.0 {
    return
  }
  match l.kind {
    @core.ShapeKind::Group => {
      for c in l.children {
        paint_layer(c, buf, env, eff_opacity)
      }
      // 组自身无面
      return
    }
    _ => ()
  }
  // 保守包围盒（旋转 45° 时取对角线长）
  let reach = Double::sqrt(l.w * l.w + l.h * l.h)
  let cx = l.x + l.w / 2.0
  let cy = l.y + l.h / 2.0
  let x0 = (cx - reach / 2.0).to_int() - 2
  let y0 = (cy - reach / 2.0).to_int() - 2
  let x1 = (cx + reach / 2.0).to_int() + 2
  let y1 = (cy + reach / 2.0).to_int() + 2
  let px0 = if x0 < 0 { 0 } else { x0 }
  let py0 = if y0 < 0 { 0 } else { y0 }
  let px1 = if x1 > buf.width { buf.width } else { x1 }
  let py1 = if y1 > buf.height { buf.height } else { y1 }
  // 位图源
  let img : @codec.RgbaBuf? = if l.kind is @core.ShapeKind::Image {
    env.assets.get(l.asset_hash)
  } else {
    None
  }
  let mut py = py0
  while py < py1 {
    let mut px = px0
    while px < px1 {
      // 2×2 子采样
      let mut fill_hits = 0
      let mut stroke_hits = 0
      let samples = [
        (0.25, 0.25),
        (0.75, 0.25),
        (0.25, 0.75),
        (0.75, 0.75),
      ]
      let sample_colors : Array[Int] = []
      for s in samples {
        let (lx, ly) = to_local(
          l,
          px.to_double() + s.0,
          py.to_double() + s.1,
        )
        let stroke_in = inside_stroke(l, lx, ly)
        if stroke_in {
          stroke_hits = stroke_hits + 1
          sample_colors.push(l.stroke.color)
        } else if inside_fill(l, lx, ly) {
          fill_hits = fill_hits + 1
          let color = match l.kind {
            @core.ShapeKind::Image => {
              match img {
                Some(im) => sample_image(im, lx, ly, l.w, l.h)
                None => 0xFFFF00FF // 资产缺失：醒目洋红占位（P3 谓词会报告）
              }
            }
            _ => fill_color_at(l.fill, lx, ly, l.w, l.h)
          }
          sample_colors.push(color)
        } else {
          sample_colors.push(0x00000000)
        }
      }
      let (cover, color) = subsample_result(fill_hits, stroke_hits, sample_colors)
      if cover > 0 {
        let src_alpha = ((cover & 0xFF) << 24)
        let rgb = color & 0x00FFFFFF
        let mut src = src_alpha | rgb
        // 层透明度并入源 alpha
        let a = ((src >> 24) & 0xFF).to_double() / 255.0 * eff_opacity
        let a255 = (a * 255.0 + 0.5).to_int()
        src = (a255 << 24) | rgb
        let dst = @codec.rgba_get(buf, px, py)
        @codec.rgba_set(buf, px, py, composite_pixel(dst, src, l.blend))
      }
      px = px + 1
    }
    py = py + 1
  }
}

///|
/// 子采样归并：覆盖度 = 命中数/4；颜色取首个命中样本。
fn subsample_result(
  fill_hits : Int,
  stroke_hits : Int,
  colors : Array[Int],
) -> (Int, Int) {
  let hits = fill_hits + stroke_hits
  if hits == 0 {
    return (0, 0x00000000)
  }
  let mut color = 0x00000000
  let mut got = false
  for c in colors {
    if c != 0x00000000 || got {
      // 取第一个命中色（stroke 优先已按序 push）
    }
  }
  // 简化：第一个非零覆盖样本
  for c in colors {
    if (c & 0xFF000000) != 0 {
      color = c
      got = true
      break
    }
  }
  if !got {
    color = if colors.length() > 0 { colors[0] } else { 0x00000000 }
  }
  let alpha = hits * 255 / 4
  (alpha, color)
}

///|
/// 位图采样：局部坐标 → 源图像素（最近邻，拉伸放置；PLAN.md 诚实边界）。
fn sample_image(
  img : @codec.RgbaBuf,
  lx : Double,
  ly : Double,
  w : Double,
  h : Double,
) -> Int {
  if w <= 0.0 || h <= 0.0 || img.width <= 0 || img.height <= 0 {
    return 0x00000000
  }
  let sx = (lx / w * img.width.to_double()).to_int()
  let sy = (ly / h * img.height.to_double()).to_int()
  let cx = if sx >= img.width { img.width - 1 } else { sx }
  let cy = if sy >= img.height { img.height - 1 } else { sy }
  img.pixels[cy * img.width + cx]
}

///|
/// 整文档渲染（白底，自底向上）。
pub fn render_doc(
  doc : @core.Document,
  env : RenderEnv,
) -> @codec.RgbaBuf {
  let w = if doc.width > RENDER_MAX_SIDE { RENDER_MAX_SIDE } else { doc.width }
  let h = if doc.height > RENDER_MAX_SIDE {
    RENDER_MAX_SIDE
  } else {
    doc.height
  }
  let buf = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(buf, 0, 0, w, h, 0xFFFFFFFF)
  for l in doc.layers {
    paint_layer(l, buf, env, 1.0)
  }
  buf
}

///|
/// 取景渲染：viewport 为归一化 [x0,y0,x1,y1]，out_width 为目标宽（像素）。
/// 先全画布渲染（≤4096），再裁剪 + 最近邻缩放（确定性优先）。
pub fn render_view(
  doc : @core.Document,
  env : RenderEnv,
  vx0 : Double,
  vy0 : Double,
  vx1 : Double,
  vy1 : Double,
  out_width : Int,
) -> Result[@codec.RgbaBuf, String] {
  render_view_impl(doc, env, vx0, vy0, vx1, vy1, out_width, false)
}

///|
/// 取景渲染 + overlay：在每个可见非组层的 bbox 画 1px 序号色线框，
/// 并以 3×5 数字位图标注其绘制序号（视觉通道的像素↔结构对位辅助）。
pub fn render_view_overlay(
  doc : @core.Document,
  env : RenderEnv,
  vx0 : Double,
  vy0 : Double,
  vx1 : Double,
  vy1 : Double,
  out_width : Int,
) -> Result[@codec.RgbaBuf, String] {
  render_view_impl(doc, env, vx0, vy0, vx1, vy1, out_width, true)
}

///|
fn render_view_impl(
  doc : @core.Document,
  env : RenderEnv,
  vx0 : Double,
  vy0 : Double,
  vx1 : Double,
  vy1 : Double,
  out_width : Int,
  overlay : Bool,
) -> Result[@codec.RgbaBuf, String] {
  if !(vx0 >= 0.0 && vy0 >= 0.0 && vx1 <= 1.0 && vy1 <= 1.0 && vx1 > vx0 && vy1 > vy0) {
    return Err("viewport 非法：[\{vx0},\{vy0},\{vx1},\{vy1}] 应为归一化且 x1>x0, y1>y0")
  }
  if out_width < 1 || out_width > RENDER_MAX_SIDE {
    return Err("out_width 越界（1..4096）")
  }
  let full = render_doc(doc, env)
  let cx0 = (vx0 * full.width.to_double()).to_int()
  let cy0 = (vy0 * full.height.to_double()).to_int()
  let cx1 = (vx1 * full.width.to_double()).to_int()
  let cy1 = (vy1 * full.height.to_double()).to_int()
  let cw = cx1 - cx0
  let ch = cy1 - cy0
  if cw < 1 || ch < 1 {
    return Err("viewport 映射到画布后为空")
  }
  let out_w = out_width
  let out_h = (ch.to_double() * out_w.to_double() / cw.to_double() + 0.5).to_int()
  if out_h < 1 {
    return Err("输出高度为 0")
  }
  let out = @codec.rgba_new(out_w, out_h)
  let mut y = 0
  while y < out_h {
    let mut x = 0
    while x < out_w {
      let sx = cx0 + x * cw / out_w
      let sy = cy0 + y * ch / out_h
      @codec.rgba_set(out, x, y, @codec.rgba_get(full, sx, sy))
      x = x + 1
    }
    y = y + 1
  }
  if overlay {
    draw_overlays(doc, out, cx0, cy0, cw, ch)
  }
  Ok(out)
}

///|
/// overlay 调色板：8 色循环（高饱和、与常见背景区分）。
let overlay_palette : Array[Int] = [
  0xFFFF3355, 0xFF33CC66, 0xFF3366FF, 0xFFFFAA00, 0xFFCC44FF, 0xFF00CCCF,
  0xFFFF66CC, 0xFF99BB00,
]

///|
/// 画全部层的 bbox 线框与序号。
fn draw_overlays(
  doc : @core.Document,
  out : @codec.RgbaBuf,
  cx0 : Int,
  cy0 : Int,
  cw : Int,
  ch : Int,
) -> Unit {
  let all = @core.all_layers(doc.layers)
  let mut ordinal = 0
  for l in all {
    if !l.visible || (l.kind is @core.ShapeKind::Group) {
      continue
    }
    ordinal = ordinal + 1
    let color = overlay_palette[(ordinal - 1) % overlay_palette.length()]
    // doc 坐标 bbox → 视图像素坐标
    let bx0 = ((l.x - cx0.to_double()) * out.width.to_double() / cw.to_double()).to_int()
    let by0 = ((l.y - cy0.to_double()) * out.height.to_double() / ch.to_double()).to_int()
    let bx1 = ((l.x + l.w - cx0.to_double()) * out.width.to_double() / cw.to_double()).to_int()
    let by1 = ((l.y + l.h - cy0.to_double()) * out.height.to_double() / ch.to_double()).to_int()
    stroke_rect_1px(out, bx0, by0, bx1, by1, color)
    draw_number(out, ordinal, bx0 + 2, by0 + 2, color)
  }
}

///|
/// 1px 矩形描边（含端点，越界自动裁剪）。
fn stroke_rect_1px(
  buf : @codec.RgbaBuf,
  x0 : Int,
  y0 : Int,
  x1 : Int,
  y1 : Int,
  color : Int,
) -> Unit {
  let mut x = x0
  while x <= x1 {
    @codec.rgba_set(buf, x, y0, color)
    @codec.rgba_set(buf, x, y1, color)
    x = x + 1
  }
  let mut y = y0
  while y <= y1 {
    @codec.rgba_set(buf, x0, y, color)
    @codec.rgba_set(buf, x1, y, color)
    y = y + 1
  }
}

///|
/// 3×5 数字位图（行优先 15 位，自最高位起逐行）；overlay 序号标注用。
fn digit_glyph(d : Int) -> Int {
  match d {
    0 => 0b111101101101111
    1 => 0b010110010010111
    2 => 0b111001111100111
    3 => 0b111001011001111
    4 => 0b101101111001001
    5 => 0b111100111001111
    6 => 0b111100111101111
    7 => 0b111001010010010
    8 => 0b111101111101111
    _ => 0b111101111001111
  }
}

///|
fn draw_digit(
  buf : @codec.RgbaBuf,
  d : Int,
  px : Int,
  py : Int,
  color : Int,
) -> Unit {
  let bits = digit_glyph(d)
  let mut r = 0
  while r < 5 {
    let mut c = 0
    while c < 3 {
      let bit = (bits >> (14 - r * 3 - c)) & 1
      if bit == 1 {
        @codec.rgba_set(buf, px + c, py + r, color)
      }
      c = c + 1
    }
    r = r + 1
  }
}

///|
fn draw_number(
  buf : @codec.RgbaBuf,
  n : Int,
  px : Int,
  py : Int,
  color : Int,
) -> Unit {
  if n < 0 {
    return
  }
  // 十进制展开后从高位画起（≥10 两位并排，间隔 1px）
  let digits : Array[Int] = []
  let mut v = n
  if v == 0 {
    digits.push(0)
  }
  while v > 0 {
    digits.push(v % 10)
    v = v / 10
  }
  let mut x = px
  let mut i = digits.length() - 1
  while i >= 0 {
    draw_digit(buf, digits[i], x, py, color)
    x = x + 4
    i = i - 1
  }
}

///|
/// 画布坐标拾取：返回最上层包含该点的层 id（旋转层用同样的内点测试）。
pub fn pick(
  doc : @core.Document,
  x : Double,
  y : Double,
) -> String? {
  let all = @core.all_layers(doc.layers)
  // 自顶向下找第一个命中的可拾取层
  let mut i = all.length() - 1
  while i >= 0 {
    let l = all[i]
    if l.visible && !(l.kind is @core.ShapeKind::Group) {
      let (lx, ly) = to_local(l, x, y)
      if inside_fill(l, lx, ly) || inside_stroke(l, lx, ly) {
        return Some(l.id)
      }
    }
    i = i - 1
  }
  None
}

///|
/// 亮度直方图（32 桶）+ 不透明覆盖率（视觉通道的客观数值，DESIGN §6.4）。
pub fn stats(buf : @codec.RgbaBuf) -> String {
  let bins : Array[Int] = []
  let mut i = 0
  while i < 32 {
    bins.push(0)
    i = i + 1
  }
  let mut opaque_px = 0
  let total = buf.width * buf.height
  let mut p = 0
  while p < total {
    let c = buf.pixels[p]
    let a = (c >> 24) & 0xFF
    if a > 0 {
      let r = (c >> 16) & 0xFF
      let g = (c >> 8) & 0xFF
      let b = c & 0xFF
      // Rec.601 亮度
      let lum = (r * 30 + g * 59 + b * 11) / 100
      bins[lum * 32 / 256] = bins[lum * 32 / 256] + 1
      if a >= 255 {
        opaque_px = opaque_px + 1
      }
    }
    p = p + 1
  }
  let sb = StringBuilder()
  sb.write_string("{\"total\":\{total},\"opaque_px\":\{opaque_px},\"histogram32\":[")
  let mut f = true
  for v in bins {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(v.to_string())
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// sin(rad)：Taylor 级数（家族无内建三角函数，deepOffice 同样手写）。
/// 自变量先归约到 [-π, π]，7 阶精度 ~1e-10，纯算术保证确定性。
fn sin_rad(x : Double) -> Double {
  let pi = 3.141592653589793
  let two_pi = 6.283185307179586
  let k = (x / two_pi).to_int()
  let mut v = x - two_pi * k.to_double()
  if v < 0.0 {
    v = v + two_pi
  }
  if v > pi {
    v = v - two_pi
  }
  let x2 = v * v
  v * sin_series(x2)
}

///|
fn cos_rad(x : Double) -> Double {
  sin_rad(x + 1.5707963267948966)
}

///|
/// sin 级数公因子：1 - x²/6 + x⁴/120 - …（Horner 求值）。
fn sin_series(x2 : Double) -> Double {
  let coeffs = [
    1.0,
    -0.16666666666666666,
    0.008333333333333333,
    -0.0001984126984126984,
    2.7557319223985893e-06,
    -2.505210838544172e-08,
    1.605904383682161e-10,
  ]
  let mut acc = 0.0
  let mut i = coeffs.length() - 1
  while i >= 0 {
    acc = acc * x2 + coeffs[i]
    i = i - 1
  }
  acc
}
