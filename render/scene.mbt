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
    @core.ShapeKind::Text => lx >= 0.0 && lx < l.w && ly >= 0.0 && ly < l.h
    @core.ShapeKind::Adjust => false
    @core.ShapeKind::Raster => false
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
    @core.ShapeKind::Adjust => {
      // 调整层：对当前缓冲（其下全部可见层的合成结果）就地施加算子
      apply_adjust(l.adjust, buf)
      return
    }
    @core.ShapeKind::Text => {
      paint_text(l, buf, env, eff_opacity)
      return
    }
    @core.ShapeKind::Raster => {
      paint_raster(l, buf, env, eff_opacity)
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
        // 蒙版因子先于合成融入源 alpha（蒙版外→源透明→下层透出）
        let mf = mask_cover_at(l, px.to_double(), py.to_double())
        if mf < 1.0 {
          let ma = ((src >> 24) & 0xFF).to_double() / 255.0 * mf
          let ma255 = (ma * 255.0 + 0.5).to_int()
          src = (ma255 << 24) | rgb
        }
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
/// Raster 层绘制：离屏缓冲逐 dab 落点（含橡皮擦 destination-out），
/// 再一次性合成到文档缓冲——擦除只作用于本层笔迹，透出其下层内容。
/// 层透明度与蒙版在合成阶段统一并入。
fn paint_raster(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  env : RenderEnv,
  eff_opacity : Double,
) -> Unit {
  if l.dabs.length() == 0 {
    return
  }
  let _ = env
  let scratch = @codec.rgba_new(buf.width, buf.height)
  // 透明底
  let total = scratch.width * scratch.height
  let mut i = 0
  while i < total {
    scratch.pixels[i] = 0
    i = i + 1
  }
  paint_dabs(l, scratch)
  // 合成：src alpha ← dab alpha × 层透明度 × 蒙版
  let mut y = 0
  while y < buf.height {
    let mut x = 0
    while x < buf.width {
      let sp = scratch.pixels[y * buf.width + x]
      let sa = (sp >> 24) & 0xFF
      if sa > 0 {
        let mf = mask_cover_at(l, x.to_double() + 0.5, y.to_double() + 0.5)
        let a = sa.to_double() / 255.0 * eff_opacity * mf
        let a255 = (a * 255.0 + 0.5).to_int()
        if a255 > 0 {
          let src = (a255 << 24) + (sp & 0x00FFFFFF)
          let dst = buf.pixels[y * buf.width + x]
          buf.pixels[y * buf.width + x] = composite_pixel(dst, src, @core.BlendMode::Normal)
        }
      }
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// 逐 dab 圆斑绘制到透明缓冲，2×2 子采样 AA；erase=true 按覆盖度乘减
/// 缓冲 alpha（destination-out）。笔色 alpha 通道作为落点浓度。
fn paint_dabs(l : @core.Layer, scratch : @codec.RgbaBuf) -> Unit {
  for d in l.dabs {
    if d.r <= 0.0 {
      continue
    }
    let x0 = (l.x + d.x - d.r).to_int() - 1
    let y0 = (l.y + d.y - d.r).to_int() - 1
    let x1 = (l.x + d.x + d.r).to_int() + 1
    let y1 = (l.y + d.y + d.r).to_int() + 1
    let px0 = if x0 < 0 { 0 } else { x0 }
    let py0 = if y0 < 0 { 0 } else { y0 }
    let px1 = if x1 > scratch.width { scratch.width } else { x1 }
    let py1 = if y1 > scratch.height { scratch.height } else { y1 }
    let r2 = d.r * d.r
    // 橡皮擦不受笔色 alpha 影响（恒全强度）；画笔的 AA 通道=落点浓度
    let dalpha = if d.erase { 1.0 } else { ((d.color >> 24) & 0xFF).to_double() / 255.0 }
    let mut py = py0
    while py < py1 {
      let mut px = px0
      while px < px1 {
        let mut hits = 0
        for s in dab_samples {
          let sx = px.to_double() + s.0 - (l.x + d.x)
          let sy = py.to_double() + s.1 - (l.y + d.y)
          if sx * sx + sy * sy <= r2 {
            hits = hits + 1
          }
        }
        if hits > 0 {
          let cover = hits.to_double() / 4.0 * dalpha
          let dst = scratch.pixels[py * scratch.width + px]
          if d.erase {
            let da = ((dst >> 24) & 0xFF).to_double() * (1.0 - cover)
            let na = (da + 0.5).to_int()
            scratch.pixels[py * scratch.width + px] = (na << 24) + (dst & 0x00FFFFFF)
          } else {
            let a255 = (cover * 255.0 + 0.5).to_int()
            if a255 > 0 {
              // 简单 over 合成（同一层内笔迹自叠）
              let da = ((dst >> 24) & 0xFF).to_double() / 255.0
              let sa = cover
              let oa = sa + da * (1.0 - sa)
              if oa > 0.0 {
                let sr = ((dst >> 16) & 0xFF).to_double() / 255.0
                let sg = ((dst >> 8) & 0xFF).to_double() / 255.0
                let sb = (dst & 0xFF).to_double() / 255.0
                let cr = (d.color >> 16) & 0xFF
                let cg = (d.color >> 8) & 0xFF
                let cb = d.color & 0xFF
                let or_ = (cr.to_double() / 255.0 * sa + sr * da * (1.0 - sa)) / oa
                let og = (cg.to_double() / 255.0 * sa + sg * da * (1.0 - sa)) / oa
                let ob = (cb.to_double() / 255.0 * sa + sb * da * (1.0 - sa)) / oa
                let nv = ((oa * 255.0 + 0.5).to_int() << 24) +
                  ((or_ * 255.0 + 0.5).to_int() << 16) +
                  ((og * 255.0 + 0.5).to_int() << 8) +
                  (ob * 255.0 + 0.5).to_int()
                scratch.pixels[py * scratch.width + px] = nv
              }
            }
          }
        }
        px = px + 1
      }
      py = py + 1
    }
  }
}

///|
let dab_samples : Array[(Double, Double)] = [
  (0.25, 0.25),
  (0.75, 0.25),
  (0.25, 0.75),
  (0.75, 0.75),
]

///|
/// 调整算子：就地施加于缓冲（调整层语义=作用于其下全部可见层的合成）。
/// 逐像素类走统一循环；缓冲变换类（模糊/锐化/磨皮）走专用实现。
fn apply_adjust(a : @core.Adjust?, buf : @codec.RgbaBuf) -> Unit {
  let adj = match a {
    Some(x) => x
    None => return
  }
  match adj.op {
    @core.AdjustOp::Blur => apply_blur(buf, adj.value)
    @core.AdjustOp::Sharpen => apply_sharpen(buf, adj.value)
    @core.AdjustOp::Smooth => apply_smooth(buf, adj.value)
    @core.AdjustOp::Vignette => apply_vignette(buf, adj.value)
    _ => apply_adjust_pixel(adj, buf)
  }
}

///|
fn apply_adjust_pixel(adj : @core.Adjust, buf : @codec.RgbaBuf) -> Unit {
  let total = buf.width * buf.height
  let mut i = 0
  while i < total {
    let p = buf.pixels[i]
    let r = (p >> 16) & 0xFF
    let g = (p >> 8) & 0xFF
    let b = p & 0xFF
    let pair : (Int, Int, Int) = match adj.op {
      @core.AdjustOp::Invert => (255 - r, 255 - g, 255 - b)
      @core.AdjustOp::Grayscale => {
        let lum = (r * 30 + g * 59 + b * 11) / 100
        (lum, lum, lum)
      }
      @core.AdjustOp::Brightness => {
        let d = (adj.value * 255.0).to_int()
        (clamp8(r + d), clamp8(g + d), clamp8(b + d))
      }
      @core.AdjustOp::Contrast => {
        // value: -1..1 → 系数 0..2（0=原样）
        let k = adj.value + 1.0
        (
          clamp8(((r.to_double() - 128.0) * k + 128.0 + 0.5).to_int()),
          clamp8(((g.to_double() - 128.0) * k + 128.0 + 0.5).to_int()),
          clamp8(((b.to_double() - 128.0) * k + 128.0 + 0.5).to_int()),
        )
      }
      @core.AdjustOp::Saturation => {
        let lum = (r * 30 + g * 59 + b * 11) / 100
        let k = if adj.value < 0.0 { 1.0 + adj.value } else { 1.0 }
        (
          clamp8((lum.to_double() + (r.to_double() - lum.to_double()) * k + 0.5).to_int()),
          clamp8((lum.to_double() + (g.to_double() - lum.to_double()) * k + 0.5).to_int()),
          clamp8((lum.to_double() + (b.to_double() - lum.to_double()) * k + 0.5).to_int()),
        )
      }
      // 美白：暖色调（R>B）像素按皮肤相似度加权提亮
      @core.AdjustOp::Whiten => {
        let s = if r > b { (r - b).to_double() / 60.0 } else { 0.0 }
        let sk = if s > 1.0 { 1.0 } else { s }
        let d = (adj.value * 70.0 * sk + 0.5).to_int()
        (clamp8(r + d), clamp8(g + d), clamp8(b + d))
      }
      // 色温：正=暖（R+/B-），负=冷
      @core.AdjustOp::Warm => {
        let d = (adj.value * 45.0 + 0.5).to_int()
        (clamp8(r + d), g, clamp8(b - d))
      }
      _ => (r, g, b)
    }
    buf.pixels[i] = (p & 0xFF000000) + (pair.0 << 16) + (pair.1 << 8) + pair.2
    i = i + 1
  }
}

///|
/// 径向暗角：中心亮、四角按 value 渐暗（平滑过渡带 0.35..1.0）。
fn apply_vignette(buf : @codec.RgbaBuf, value : Double) -> Unit {
  let cx = buf.width.to_double() / 2.0
  let cy = buf.height.to_double() / 2.0
  let md = Double::sqrt(cx * cx + cy * cy)
  if md <= 0.0 {
    return
  }
  let mut y = 0
  while y < buf.height {
    let mut x = 0
    while x < buf.width {
      let dx = x.to_double() - cx
      let dy = y.to_double() - cy
      let d = Double::sqrt(dx * dx + dy * dy) / md
      let t0 = (d - 0.35) / 0.65
      let t = if t0 < 0.0 { 0.0 } else if t0 > 1.0 { 1.0 } else { t0 }
      let f = 1.0 - value * t
      let i = y * buf.width + x
      let p = buf.pixels[i]
      let r = ((p >> 16) & 0xFF).to_double() * f
      let g = ((p >> 8) & 0xFF).to_double() * f
      let b = (p & 0xFF).to_double() * f
      buf.pixels[i] = (p & 0xFF000000) + (clamp8((r + 0.5).to_int()) << 16) +
        (clamp8((g + 0.5).to_int()) << 8) +
        clamp8((b + 0.5).to_int())
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// 预乘 alpha 拆包/打包辅助（模糊需预乘空间插值，避免边缘色晕）。
fn premul(p : Int) -> (Int, Int, Int, Int) {
  let a = (p >> 24) & 0xFF
  (a, ((p >> 16) & 0xFF) * a, ((p >> 8) & 0xFF) * a, (p & 0xFF) * a)
}

///|
/// 单趟可分离盒式模糊（水平或垂直），滑窗求和 O(n)。
/// horizontal=true：逐行处理，line=行号，count=宽；
/// horizontal=false：逐列处理，line=列号，count=高。
fn blur_axis(
  src : FixedArray[Int],
  out : FixedArray[Int],
  count : Int,
  lines : Int,
  radius : Int,
  horizontal : Bool,
) -> Unit {
  let w = if horizontal { count } else { lines } // 画布宽
  let mut line = 0
  while line < lines {
    let hi0 = if radius < count - 1 { radius } else { count - 1 }
    let mut sa = 0
    let mut sr = 0
    let mut sg = 0
    let mut sb = 0
    let mut k = 0
    while k <= hi0 {
      let (a, r, g, b) = premul(blur_at(src, line, k, w, horizontal))
      sa = sa + a
      sr = sr + r
      sg = sg + g
      sb = sb + b
      k = k + 1
    }
    let mut i = 0
    while i < count {
      let lo = if i - radius > 0 { i - radius } else { 0 }
      let hi = if i + radius < count - 1 { i + radius } else { count - 1 }
      let win = hi - lo + 1
      let a = sa / win
      let mut nr = 0
      let mut ng = 0
      let mut nb = 0
      if a > 0 {
        nr = sr / a
        ng = sg / a
        nb = sb / a
      }
      blur_set(out, line, i, w, horizontal, (a << 24) + (nr << 16) + (ng << 8) + nb)
      let add_i = i + radius + 1
      if add_i < count {
        let (a2, r2, g2, b2) = premul(blur_at(src, line, add_i, w, horizontal))
        sa = sa + a2
        sr = sr + r2
        sg = sg + g2
        sb = sb + b2
      }
      let rem_i = i - radius
      if rem_i >= 0 {
        let (a3, r3, g3, b3) = premul(blur_at(src, line, rem_i, w, horizontal))
        sa = sa - a3
        sr = sr - r3
        sg = sg - g3
        sb = sb - b3
      }
      i = i + 1
    }
    line = line + 1
  }
}

///|
/// 模糊轴索引：水平时 line=行、idx=列（行基址 + idx）；垂直时 line=列、idx=行。
fn blur_at(
  src : FixedArray[Int],
  line : Int,
  idx : Int,
  w : Int,
  horizontal : Bool,
) -> Int {
  if horizontal {
    src[line * w + idx]
  } else {
    src[idx * w + line]
  }
}

///|
fn blur_set(
  out : FixedArray[Int],
  line : Int,
  idx : Int,
  w : Int,
  horizontal : Bool,
  v : Int,
) -> Unit {
  if horizontal {
    out[line * w + idx] = v
  } else {
    out[idx * w + line] = v
  }
}

///|
/// 两趟盒式模糊近似高斯。value 0..1 → 半径 1..24。
fn apply_blur(buf : @codec.RgbaBuf, value : Double) -> Unit {
  let v = if value < 0.0 { 0.0 } else if value > 1.0 { 1.0 } else { value }
  let mut radius = (v * 24.0).to_int()
  if radius < 1 {
    radius = 1
  }
  let total = buf.width * buf.height
  let a1 = buf.pixels.copy()
  let t = FixedArray::make(total, 0)
  let a2 = FixedArray::make(total, 0)
  blur_axis(a1, t, buf.width, buf.height, radius, true)
  blur_axis(t, a2, buf.height, buf.width, radius, false)
  blur_axis(a2, t, buf.width, buf.height, radius, true)
  blur_axis(t, buf.pixels, buf.height, buf.width, radius, false)
}

///|
/// 非锐化掩模：out = orig + value·(orig − blur(半径2))。
fn apply_sharpen(buf : @codec.RgbaBuf, value : Double) -> Unit {
  let v = if value < 0.0 { 0.0 } else if value > 1.0 { 1.0 } else { value }
  let total = buf.width * buf.height
  let blurred = buf.pixels.copy()
  let tmp = FixedArray::make(total, 0)
  let nxt = FixedArray::make(total, 0)
  blur_axis(blurred, tmp, buf.width, buf.height, 2, true)
  blur_axis(tmp, nxt, buf.height, buf.width, 2, false)
  let mut i = 0
  while i < total {
    let p = buf.pixels[i]
    let q = nxt[i]
    let r = (p >> 16) & 0xFF
    let g = (p >> 8) & 0xFF
    let b = p & 0xFF
    let qr = (q >> 16) & 0xFF
    let qg = (q >> 8) & 0xFF
    let qb = q & 0xFF
    let nr = clamp8((r.to_double() + (r - qr).to_double() * v * 1.5 + 0.5).to_int())
    let ng = clamp8((g.to_double() + (g - qg).to_double() * v * 1.5 + 0.5).to_int())
    let nb = clamp8((b.to_double() + (b - qb).to_double() * v * 1.5 + 0.5).to_int())
    buf.pixels[i] = (p & 0xFF000000) + (nr << 16) + (ng << 8) + nb
    i = i + 1
  }
}

///|
/// 磨皮：边缘感知平滑。平坦区（|orig−blur| 小）按 value 混入模糊，
/// 纹理/边缘区保留 → 皮肤变净、五官不糊。
fn apply_smooth(buf : @codec.RgbaBuf, value : Double) -> Unit {
  let v = if value < 0.0 { 0.0 } else if value > 1.0 { 1.0 } else { value }
  let total = buf.width * buf.height
  let blurred = buf.pixels.copy()
  let tmp = FixedArray::make(total, 0)
  let nxt = FixedArray::make(total, 0)
  blur_axis(blurred, tmp, buf.width, buf.height, 4, true)
  blur_axis(tmp, nxt, buf.height, buf.width, 4, false)
  let mut i = 0
  while i < total {
    let p = buf.pixels[i]
    let q = nxt[i]
    let r = (p >> 16) & 0xFF
    let g = (p >> 8) & 0xFF
    let b = p & 0xFF
    let qr = (q >> 16) & 0xFF
    let qg = (q >> 8) & 0xFF
    let qb = q & 0xFF
    let dr = r - qr
    let dg = g - qg
    let db = b - qb
    let diff = dr * dr + dg * dg + db * db
    // w = value·255·300/(300+diff²)：平坦区→value·255，强边缘→0
    let w = (v * 255.0 * 300.0 / (300.0 + diff.to_double())).to_int()
    let nr = clamp8(r + (qr - r) * w / 255)
    let ng = clamp8(g + (qg - g) * w / 255)
    let nb = clamp8(b + (qb - b) * w / 255)
    buf.pixels[i] = (p & 0xFF000000) + (nr << 16) + (ng << 8) + nb
    i = i + 1
  }
}

///|
fn clamp8(v : Int) -> Int {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
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
///
/// 这是**底图**（base）：MVSL 编辑表求值与渲染都以它为准。
/// 需要「底图 + 编辑表」时用 `render_doc_with`。
///
/// 与 `render_doc_with(doc, env, 空程序)` 逐位相等——`pixel.run_program`
/// 在 ops 为空时直接返回 base 本身、不经任何色彩变换。所以这里直接调
/// `render_layers` 是等价改写，不是"抄近路"。
pub fn render_doc(
  doc : @core.Document,
  env : RenderEnv,
) -> @codec.RgbaBuf {
  render_layers(doc, env)
}

///|
/// 整文档渲染 + 施加 MVSL 编辑表（最终一遍）。
///
/// 语义（PLAN-MVSL §P0）：`最终图 = apply(program, 层合成底图)`。
/// **编辑表的 base 就是这个层合成底图**，不是上一次的最终图——否则
/// 编辑表会自己吃自己（反复渲染导致选区漂移，且不可重放）。
///
/// 空编辑表时**逐位等于** `render_doc`：`run_program` 在 ops 为空时直接
/// 返回 base 本身，不经过任何色彩变换。这是既有 golden 与
/// open→save 字节一致断言不受影响的前提。
///
/// 编辑表里出现前视 STAGE 引用、未知算子等坏程序时返回 Err，**绝不当空
/// 程序糊过去**——静默漏渲染一批编辑正是 PLAN-MVSL 明令禁止的错渲。
pub fn render_doc_with(
  doc : @core.Document,
  env : RenderEnv,
  prog : @core.EditProgram,
) -> Result[@codec.RgbaBuf, String] {
  let base = render_layers(doc, env)
  match @pixel.run_program(base, prog) {
    Ok(pair) => Ok(pair.0)
    Err(e) => Err("MVSL 编辑表执行失败：\{e}")
  }
}

///|
/// 层合成底图（不含 MVSL；MVSL 求值与渲染的唯一基准）。
pub fn render_layers(
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
  render_view_impl(
    doc,
    env,
    vx0,
    vy0,
    vx1,
    vy1,
    out_width,
    false,
    @core.EditProgram::new(),
  )
}

///|
/// 取景渲染 + MVSL 编辑表。
///
/// 顺序不可交换：**先全画布求编辑表，再裁剪缩放**。选择子定义在画布
/// 坐标系里（`geo` 的 x/y/w/h 是画布像素），先裁剪会让同一条选择子在
/// 不同取景下命中不同的东西——取景只是观看方式，不该改变语义。
pub fn render_view_with(
  doc : @core.Document,
  env : RenderEnv,
  vx0 : Double,
  vy0 : Double,
  vx1 : Double,
  vy1 : Double,
  out_width : Int,
  prog : @core.EditProgram,
) -> Result[@codec.RgbaBuf, String] {
  render_view_impl(doc, env, vx0, vy0, vx1, vy1, out_width, false, prog)
}

///|
/// 取景渲染 + 编辑表 + overlay 序号线框（三者叠加，顺序同上）。
pub fn render_view_overlay_with(
  doc : @core.Document,
  env : RenderEnv,
  vx0 : Double,
  vy0 : Double,
  vx1 : Double,
  vy1 : Double,
  out_width : Int,
  prog : @core.EditProgram,
) -> Result[@codec.RgbaBuf, String] {
  render_view_impl(doc, env, vx0, vy0, vx1, vy1, out_width, true, prog)
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
  render_view_impl(
    doc,
    env,
    vx0,
    vy0,
    vx1,
    vy1,
    out_width,
    true,
    @core.EditProgram::new(),
  )
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
  prog : @core.EditProgram,
) -> Result[@codec.RgbaBuf, String] {
  if !(vx0 >= 0.0 && vy0 >= 0.0 && vx1 <= 1.0 && vy1 <= 1.0 && vx1 > vx0 && vy1 > vy0) {
    return Err("viewport 非法：[\{vx0},\{vy0},\{vx1},\{vy1}] 应为归一化且 x1>x0, y1>y0")
  }
  if out_width < 1 || out_width > RENDER_MAX_SIDE {
    return Err("out_width 越界（1..4096）")
  }
  // 编辑表必须在全画布上求值，之后再裁剪/缩放（取景不改变选择子语义）
  let full = match render_doc_with(doc, env, prog) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
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
  if out_h < 1 || out_h > RENDER_MAX_SIDE {
    return Err("输出高度越界（\{out_h}）")
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

// ---------------------------------------------------------------------------
// 文本层：5x7 点阵字形（审计已知边界：ASCII 真字形，非 ASCII 盒形占位）
// ---------------------------------------------------------------------------

///|
/// 逻辑右移（本地实现；render 不依赖 base）。
fn lsr(x : Int, n : Int) -> Int {
  if n <= 0 {
    x
  } else if n >= 32 {
    0
  } else {
    (x >> n) & ((1 << (32 - n)) - 1)
  }
}

///|
/// 5x7 字形，按列编码（5 列 × 7 位，bit=该列自上而下）。覆盖 ASCII 32..126。
fn glyph_columns(ch : Char) -> Array[Int]? {
  let n = ch.to_int()
  if n < 32 || n > 126 {
    return None
  }
  let table : Array[(Int, Array[Int])] = [
    (32, [0, 0, 0, 0, 0]), // space
    (33, [4, 4, 4, 0, 4]), // !
    (34, [10, 10, 0, 0, 0]), // "
    (35, [10, 31, 10, 31, 10]), // #
    (36, [4, 15, 20, 15, 5]), // $
    (37, [25, 2, 4, 8, 19]), // %
    (38, [8, 20, 8, 21, 14]), // &
    (39, [4, 4, 0, 0, 0]), // '
    (40, [2, 4, 4, 4, 2]), // (
    (41, [4, 2, 2, 2, 4]), // )
    (42, [0, 4, 21, 4, 0]), // *
    (43, [0, 4, 14, 4, 0]), // +
    (44, [0, 0, 0, 4, 4]), // ,
    (45, [0, 0, 14, 0, 0]), // -
    (46, [0, 0, 0, 12, 12]), // .
    (47, [1, 2, 4, 8, 16]), // /
    (48, [14, 17, 19, 21, 13]), // 0
    (49, [4, 12, 4, 4, 14]), // 1
    (50, [14, 17, 1, 2, 31]), // 2
    (51, [31, 2, 4, 2, 31]), // 3
    (52, [2, 6, 10, 31, 2]), // 4
    (53, [31, 16, 14, 1, 14]), // 5
    (54, [6, 8, 14, 17, 14]), // 6
    (55, [31, 1, 2, 4, 8]), // 7
    (56, [14, 17, 14, 17, 14]), // 8
    (57, [14, 17, 15, 1, 14]), // 9
    (58, [0, 12, 12, 0, 0]), // :
    (59, [0, 4, 4, 0, 4]), // ;
    (60, [2, 4, 8, 4, 2]), // <
    (61, [0, 14, 0, 14, 0]), // =
    (62, [8, 4, 2, 4, 8]), // >
    (63, [14, 1, 6, 0, 4]), // ?
    (64, [14, 17, 23, 21, 14]), // @
    (65, [14, 17, 31, 17, 17]), // A
    (66, [30, 17, 30, 17, 30]), // B
    (67, [14, 17, 16, 17, 14]), // C
    (68, [28, 18, 17, 18, 28]), // D
    (69, [31, 16, 30, 16, 31]), // E
    (70, [31, 16, 30, 16, 16]), // F
    (71, [14, 17, 23, 17, 15]), // G
    (72, [17, 17, 31, 17, 17]), // H
    (73, [14, 4, 4, 4, 14]), // I
    (74, [1, 1, 1, 17, 14]), // J
    (75, [17, 10, 4, 10, 17]), // K
    (76, [16, 16, 16, 16, 31]), // L
    (77, [17, 27, 21, 17, 17]), // M
    (78, [17, 25, 21, 19, 17]), // N
    (79, [14, 17, 17, 17, 14]), // O
    (80, [30, 17, 30, 16, 16]), // P
    (81, [14, 17, 21, 18, 13]), // Q
    (82, [30, 17, 30, 10, 17]), // R
    (83, [15, 16, 14, 1, 30]), // S
    (84, [31, 4, 4, 4, 4]), // T
    (85, [17, 17, 17, 17, 14]), // U
    (86, [17, 17, 10, 4, 4]), // V
    (87, [17, 21, 21, 21, 10]), // W
    (88, [17, 10, 4, 10, 17]), // X
    (89, [17, 10, 4, 4, 4]), // Y
    (90, [31, 2, 4, 8, 31]), // Z
    (91, [14, 8, 8, 8, 14]), // [
    (92, [16, 8, 4, 2, 1]), // backslash
    (93, [14, 2, 2, 2, 14]), // ]
    (94, [4, 10, 0, 0, 0]), // ^
    (95, [0, 0, 0, 0, 31]), // _
    (96, [4, 2, 0, 0, 0]), // `
    (97, [0, 14, 1, 15, 15]), // a
    (98, [16, 16, 14, 17, 14]), // b
    (99, [0, 14, 16, 16, 14]), // c
    (100, [1, 1, 15, 17, 15]), // d
    (101, [0, 14, 17, 30, 16]), // e
    (102, [6, 8, 30, 8, 8]), // f
    (103, [15, 17, 15, 1, 14]), // g
    (104, [16, 16, 14, 17, 17]), // h
    (105, [4, 0, 4, 4, 4]), // i
    (106, [1, 0, 1, 17, 14]), // j
    (107, [16, 10, 4, 10, 16]), // k
    (108, [14, 4, 4, 4, 4]), // l
    (109, [0, 26, 21, 21, 21]), // m
    (110, [0, 14, 17, 17, 17]), // n
    (111, [0, 14, 17, 17, 14]), // o
    (112, [14, 17, 14, 16, 16]), // p
    (113, [15, 17, 15, 1, 1]), // q
    (114, [0, 14, 16, 16, 16]), // r
    (115, [0, 15, 16, 14, 1]), // s
    (116, [8, 30, 8, 8, 6]), // t
    (117, [0, 17, 17, 19, 13]), // u
    (118, [0, 17, 10, 10, 4]), // v
    (119, [0, 17, 21, 21, 10]), // w
    (120, [0, 10, 4, 10, 0]), // x
    (121, [17, 15, 1, 14, 0]), // y
    (122, [0, 31, 2, 4, 31]), // z
    (123, [2, 4, 8, 4, 2]), // {
    (124, [4, 4, 4, 4, 4]), // |
    (125, [8, 4, 2, 4, 8]), // }
    (126, [5, 20, 0, 0, 0]), // ~
  ]
  for pair in table {
    if pair.0 == n {
      return Some(pair.1)
    }
  }
  None
}

///|
/// 文本层绘制：字形按 font_size/7 缩放，advance = 6 * scale。
fn paint_text(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  env : RenderEnv,
  eff_opacity : Double,
) -> Unit {
  let scale = (l.font_size / 7.0).to_int()
  let sc = if scale < 1 { 1 } else { scale }
  let advance = 6 * sc
  let color = fill_color_at(l.fill, 0.0, 0.0, l.w, l.h)
  let px0 = l.x.to_int()
  let py0 = l.y.to_int()
  let mut cx = 0
  for ch in l.text.iter() {
    let glyph : Array[Int] = match glyph_columns(ch) {
      Some(g) => g
      None => [31, 21, 21, 21, 31] // 非 ASCII：盒形占位（诚实边界）
    }
    // 每列 5 bit 自上而下
    for col in 0..<5 {
      let bits = glyph[col]
      for row in 0..<7 {
        if (lsr(bits, 6 - row) & 1) == 1 {
          let mut sy = 0
          while sy < sc {
            let mut sx = 0
            while sx < sc {
              let px = px0 + cx + col * sc + sx
              let py = py0 + row * sc + sy
              let mf = mask_cover_at(l, px.to_double(), py.to_double())
              let a = eff_opacity * mf
              let a255 = (a * 255.0 + 0.5).to_int()
              let src = (a255 << 24) + (color & 0x00FFFFFF)
              let dst = @codec.rgba_get(buf, px, py)
              @codec.rgba_set(buf, px, py, composite_pixel(dst, src, @core.BlendMode::Normal))
              sx = sx + 1
            }
            sy = sy + 1
          }
        }
      }
    }
    cx = cx + advance
  }
  let _ = env
  let _ = eff_opacity
}

///|
/// 圆角矩形内部判定（SDF；比较距离平方与半径平方，不开方）。
/// `dx/dy` 是相对矩形左上角的偏移，调用方已保证落在 `[0,w)×[0,h)` 内。
/// `radius` 超过半边长时按半边长夹住——正方形半径到极限就是一个圆。
fn rounded_rect_inside(
  dx : Double,
  dy : Double,
  w : Double,
  h : Double,
  radius : Double,
) -> Bool {
  let hw = w / 2.0
  let hh = h / 2.0
  let r0 = if radius > hw { hw } else { radius }
  let r = if r0 > hh { hh } else { r0 }
  let ax = if dx > hw { dx - hw } else { hw - dx }
  let ay = if dy > hh { dy - hh } else { hh - dy }
  let qx = ax - (hw - r)
  let qy = ay - (hh - r)
  if qx <= 0.0 && qy <= 0.0 {
    true
  } else {
    let ox = if qx > 0.0 { qx } else { 0.0 }
    let oy = if qy > 0.0 { qy } else { 0.0 }
    ox * ox + oy * oy <= r * r
  }
}

///|
/// 蒙版覆盖度：画布坐标 (px,py) 在层蒙版内=1 外=0（invert 反选）。
/// 矩形蒙版按 `radius` 切圆角；`radius <= 0` 时**走原先的硬直角分支**，
/// 与"radius 还没被实现"之前的行为逐位相同。
fn mask_cover_at(l : @core.Layer, px : Double, py : Double) -> Double {
  let mask = match l.mask {
    Some(m) => m
    None => return 1.0
  }
  let dx = px - mask.x
  let dy = py - mask.y
  let inside = match mask.kind {
    @core.ShapeKind::Ellipse => {
      if mask.w <= 0.0 || mask.h <= 0.0 {
        false
      } else {
        let nx = dx / mask.w * 2.0 - 1.0
        let ny = dy / mask.h * 2.0 - 1.0
        nx * nx + ny * ny <= 1.0
      }
    }
    _ =>
      if dx < 0.0 || dy < 0.0 || dx >= mask.w || dy >= mask.h {
        false
      } else if mask.radius <= 0.0 {
        true
      } else {
        rounded_rect_inside(dx, dy, mask.w, mask.h, mask.radius)
      }
  }
  let cover = if inside { 1.0 } else { 0.0 }
  if mask.invert {
    1.0 - cover
  } else {
    cover
  }
}
