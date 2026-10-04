/// 一个层的**面轮廓**：布尔运算的操作数（④ Stage B）。
///
/// 为什么放在 `render` 而不是 `core`：**"这个层是什么形状"只有渲染器说了算**
/// （`inside_fill` 是权威）。轮廓如果在别处按另一套口径算，布尔运算的结果就会
/// 与画面对不上——典型表现是"减掉一半之后，剩下的边界偏了半个像素，而每条
/// 命令都回 ok"。这里读的是与 `inside_fill` 相同的字段与相同的夹取
/// （`clamped_radius`），所以轮廓与画面是同一个形状的两副面孔。
///
/// 椭圆与圆角用**固定段数的折线**近似（椭圆 64 段、圆角每角 8 段）：布尔运算
/// 的结果是折线路径，分辨率必须是确定的（渲染 sha256 要可复现），而且要在文档
/// 里写明——"椭圆求并之后变成 64 边形"是能力边界，不是 bug。
///
/// 返回的是**画布坐标**（含本层的 rot/flip/平移，走 `to_canvas` 一处实现）。
/// 组内层不在这里拒绝（那是命令面的门）：但调用方拿到的坐标是对的，只有
/// 祖先变换这一层它没算——所以命令面只收根级层，见 `cmd_bool_op`。

///|
/// 椭圆轮廓的段数（唯一常量：轮廓逼近与文档里的数字都读它）。
pub const ELLIPSE_RING_SEG : Int = 64

///|
/// 圆角每个角的段数。
pub const CORNER_RING_SEG : Int = 8

///|
/// 一个层的面轮廓（画布坐标、闭合环）；**没有面的层回 `None`**。
///
/// `None` 的判据由**同一句话**决定：`@core.fill_closed(l.fill)`
/// （`fill = NoFill` ⇒ 没有面）。所以"开放路径"在这里就自然回 `None`，
/// 命令面不必再判一遍"闭合与否"。
pub fn face_ring(l : @core.Layer) -> Array[(Double, Double)]? {
  let ring0 : Array[(Double, Double)] = match l.kind {
    @core.ShapeKind::Rect =>
      match l.w <= 0.0 || l.h <= 0.0 {
        true => return None
        false => rounded_rect_ring(l.w, l.h, clamped_radius(l.w, l.h, l.corner_radius))
      }
    @core.ShapeKind::Ellipse =>
      match l.w <= 0.0 || l.h <= 0.0 {
        true => return None
        false => ellipse_ring(l.w, l.h)
      }
    @core.ShapeKind::Polygon =>
      match l.points.length() < 3 {
        true => return None
        false => l.points
      }
    @core.ShapeKind::Path => {
      // 开放路径没有面（"闭合与否 ⇒ 有没有面"的唯一判据）
      if !@core.fill_closed(l.fill) || l.points.length() < 3 {
        return None
      }
      @core.path_samples(l.points, l.handles, true)
    }
    _ => return None
  }
  if ring0.length() < 3 {
    return None
  }
  let out : Array[(Double, Double)] = []
  for p in ring0 {
    out.push(to_canvas(l, p.0, p.1))
  }
  Some(out)
}

///|
/// 轴对齐矩形的环（局部坐标、CCW：(0,0)→(w,0)→(w,h)→(0,h)）。
fn rect_ring_local(w : Double, h : Double) -> Array[(Double, Double)] {
  [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
}

///|
/// 圆角矩形的环：四条直边 + 四个 1/4 圆弧（每角 `CORNER_RING_SEG` 段）。
/// 圆角半径走渲染器自己的夹取 `clamped_radius`（**同一把尺子**：别在这里
/// 再写一个 `min(r, w/2, h/2)`，两者在 r 大于半宽时给出的形状不同）。
fn rounded_rect_ring(
  w : Double,
  h : Double,
  r : Double,
) -> Array[(Double, Double)] {
  if r <= 0.0 {
    return rect_ring_local(w, h)
  }
  let out : Array[(Double, Double)] = []
  // 四个圆心（局部坐标）+ 每个角起始/结束角（度）
  let cx4 = [w - r, w - r, r, r]
  let cy4 = [r, h - r, h - r, r]
  let a0s = [270.0, 0.0, 90.0, 180.0]
  // 从 (r, 0) 起画：上边右行 → 右上角 → 右边下行 → 右下 → 下边左行 → 左下 → 左边上行 → 左上
  out.push((r, 0.0))
  out.push((w - r, 0.0))
  let mut c = 0
  while c < 4 {
    let cx = cx4[c]
    let cy = cy4[c]
    let a0 = a0s[c]
    let mut k = 1
    while k <= CORNER_RING_SEG {
      let ang = a0 + 90.0 * k.to_double() / CORNER_RING_SEG.to_double()
      let rad = ang * 3.141592653589793 / 180.0
      out.push((cx + r * cos_rad(rad), cy + r * sin_rad(rad)))
      k = k + 1
    }
    // 直边到下一个圆心
    if c == 0 {
      out.push((w, h - r))
    } else if c == 1 {
      out.push((r, h))
    } else if c == 2 {
      out.push((0.0, r))
    }
    c = c + 1
  }
  out
}

///|
/// 椭圆的环（局部坐标、CCW，`ELLIPSE_RING_SEG` 段）。
/// 用渲染器自己的 `cos_rad`/`sin_rad`（级数近似）：轮廓与画面共用同一套
/// 三角函数，不引入第二套精度。
fn ellipse_ring(w : Double, h : Double) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let cx = w / 2.0
  let cy = h / 2.0
  let mut i = 0
  while i < ELLIPSE_RING_SEG {
    let rad = 2.0 * 3.141592653589793 * i.to_double() / ELLIPSE_RING_SEG.to_double()
    out.push((cx + cx * cos_rad(rad), cy + cy * sin_rad(rad)))
    i = i + 1
  }
  out
}
