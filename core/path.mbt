/// 贝塞尔路径（④ 钢笔）的**几何底座**：采样、包含判定、最近距离、包围盒。
///
/// 为什么全放在 core 一处：同一个形状有**四个**读点——渲染的填充、渲染的描边、
/// `pick`/`sample` 的命中、`paint_window`/`lint` 的窗与盒子。四个读点各写一遍
/// 采样，分歧就是"看着画出来了、点它却拾不到"（`pick` 与渲染分叉那类 bug）。
/// 采样规则、控制柄的语义（in/out 偏移）、闭合与否的判断只有这一份。

///|
/// 第 i 段的两个控制点（**控制柄语义的唯一实现**：`handles[i*2]` 是锚点 i 的
/// in 偏移、`handles[i*2+1]` 是 out 偏移；长度不匹配时退化成"控制点 = 锚点"）。
///
/// ⚠️ 这一句曾在 `path_samples` / `path_contains` / `path_nearest_dist` 里
/// **抄了三遍**（当时的理由是热路径零分配）。三份拷贝就是三个"忽略控制柄"的
/// 机会：变异 R82 一注入，三个读点里只有一个退化成折线，画面自相矛盾（填充按
/// 曲线、描边按折线）。现在三处都调它——零分配靠的是调用点不新建数组，不是靠抄。
fn seg_controls(
  anchors : Array[(Double, Double)],
  handles : Array[(Double, Double)],
  i : Int,
  n : Int,
  pairs : Bool,
) -> ((Double, Double), (Double, Double)) {
  let a = anchors[i]
  let b = anchors[(i + 1) % n]
  if pairs {
    (
      (a.0 + handles[i * 2 + 1].0, a.1 + handles[i * 2 + 1].1),
      (b.0 + handles[((i + 1) % n) * 2].0, b.1 + handles[((i + 1) % n) * 2].1),
    )
  } else {
    (a, b)
  }
}

///|
/// 三次贝塞尔在参数 `t` 处的点（**求值公式的唯一实现**）。
/// 用 de Casteljau 的展开式（Bernstein 基）：确定性、无迭代收敛问题。
fn cubic_at(
  p0 : (Double, Double),
  c0 : (Double, Double),
  c1 : (Double, Double),
  p1 : (Double, Double),
  t : Double,
) -> (Double, Double) {
  let u = 1.0 - t
  let b0 = u * u * u
  let b1 = 3.0 * u * u * t
  let b2 = 3.0 * u * t * t
  let b3 = t * t * t
  (
    b0 * p0.0 + b1 * c0.0 + b2 * c1.0 + b3 * p1.0,
    b0 * p0.1 + b1 * c0.1 + b2 * c1.1 + b3 * p1.1,
  )
}

///|
/// 一条三次贝塞尔的采样（`k` 段折线，返回 `k+1` 个点）。
pub fn cubic_samples(
  p0 : (Double, Double),
  c0 : (Double, Double),
  c1 : (Double, Double),
  p1 : (Double, Double),
  k : Int,
) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let n = if k < 1 { 1 } else { k }
  let mut i = 0
  while i <= n {
    out.push(cubic_at(p0, c0, c1, p1, i.to_double() / n.to_double()))
    i = i + 1
  }
  out
}

///|
/// 每段折线取几段采样：**按弦长定**（曲率大的段不会看着是折线，直的段不浪费点）。
/// 规则固定 = 同一路径在任何机器上采样出同一串点（渲染 sha256 可复现的前提）。
pub fn cubic_segments_for(p0 : (Double, Double), p1 : (Double, Double)) -> Int {
  let dx = p1.0 - p0.0
  let dy = p1.1 - p0.1
  let chord = Double::sqrt(dx * dx + dy * dy)
  let k = 4 + (chord / 6.0).to_int()
  if k > 24 {
    24
  } else if k < 4 {
    4
  } else {
    k
  }
}

///|
/// 锚点 + 控制柄 → 折线点串（`closed` = 末尾再连回第一个锚点）。
///
/// `handles` 的长度与锚点数不匹配时**按缺省处理**（全 0 = 折线）：这个函数在
/// 渲染热路径上，不能因为容器被手改坏就 panic——非法状态由入口与 `lint` 报。
pub fn path_samples(
  anchors : Array[(Double, Double)],
  handles : Array[(Double, Double)],
  closed : Bool,
) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let n = anchors.length()
  if n == 0 {
    return out
  }
  if n == 1 {
    out.push(anchors[0])
    return out
  }
  let pairs = handles.length() == n * 2
  let segs = if closed { n } else { n - 1 }
  let mut i = 0
  while i < segs {
    let a = anchors[i]
    let b = anchors[(i + 1) % n]
    let (c0, c1) = seg_controls(anchors, handles, i, n, pairs)
    let k = cubic_segments_for(a, b)
    let pts = cubic_samples(a, c0, c1, b, k)
    // 段与段共享端点：每段少收最后一个点，避免重复点（重复点在奇偶判定里
    // 会让"正好落在顶点上"的点被数两次——判据要么两边都算、要么都不算）
    let mut j = 0
    while j < pts.length() - 1 {
      out.push(pts[j])
      j = j + 1
    }
    i = i + 1
  }
  if closed {
    // 闭合路径补上最后一个锚点（循环里最后一段的终点）
    let last = if n > 0 { anchors[n - 1] } else { anchors[0] }
    let _ = last
  } else {
    out.push(anchors[n - 1])
  }
  out
}

///|
/// 路径包围盒（`(x0,y0,x1,y1)`，局部坐标）。空路径回全 0。
pub fn path_box(
  anchors : Array[(Double, Double)],
  handles : Array[(Double, Double)],
  closed : Bool,
) -> (Double, Double, Double, Double) {
  let pts = path_samples(anchors, handles, closed)
  if pts.length() == 0 {
    return (0.0, 0.0, 0.0, 0.0)
  }
  let mut x0 = pts[0].0
  let mut y0 = pts[0].1
  let mut x1 = pts[0].0
  let mut y1 = pts[0].1
  for p in pts {
    if p.0 < x0 { x0 = p.0 }
    if p.1 < y0 { y0 = p.1 }
    if p.0 > x1 { x1 = p.0 }
    if p.1 > y1 { y1 = p.1 }
  }
  (x0, y0, x1, y1)
}

///|
/// 路径填充的包含判定（奇偶规则）：**不分配数组**——`inside_fill` 是逐像素
/// 调用的，给每个像素摊一次 `Array` 分配会在整幅画布上放大成 GC 抖动。
/// 逐曲边按同样的弦长规则采子段、就地做射线交叉。
pub fn path_contains(
  anchors : Array[(Double, Double)],
  handles : Array[(Double, Double)],
  closed : Bool,
  x : Double,
  y : Double,
) -> Bool {
  let n = anchors.length()
  if n < 3 || !closed {
    return false
  }
  let pairs = handles.length() == n * 2
  let mut inside = false
  let mut i = 0
  while i < n {
    let a = anchors[i]
    let b = anchors[(i + 1) % n]
    let (c0, c1) = seg_controls(anchors, handles, i, n, pairs)
    let k = cubic_segments_for(a, b)
    let mut j = 0
    let mut px = a.0
    let mut py = a.1
    while j < k {
      let (qx, qy) = cubic_at(a, c0, c1, b, (j + 1).to_double() / k.to_double())
      if (py > y) != (qy > y) && x < (qx - px) * (y - py) / (qy - py) + px {
        inside = !inside
      }
      px = qx
      py = qy
      j = j + 1
    }
    i = i + 1
  }
  inside
}

///|
/// 路径到最近一条曲边的距离（描边用；同样不分配）。
pub fn path_nearest_dist(
  anchors : Array[(Double, Double)],
  handles : Array[(Double, Double)],
  closed : Bool,
  x : Double,
  y : Double,
) -> Double {
  let n = anchors.length()
  if n < 2 {
    return 1.0e18
  }
  let pairs = handles.length() == n * 2
  let segs = if closed { n } else { n - 1 }
  let mut best = 1.0e18
  let mut i = 0
  while i < segs {
    let a = anchors[i]
    let b = anchors[(i + 1) % n]
    let (c0, c1) = seg_controls(anchors, handles, i, n, pairs)
    let k = cubic_segments_for(a, b)
    let mut j = 0
    let mut px = a.0
    let mut py = a.1
    while j < k {
      let (qx, qy) = cubic_at(a, c0, c1, b, (j + 1).to_double() / k.to_double())
      let d = seg_dist(px, py, qx, qy, x, y)
      if d < best {
        best = d
      }
      px = qx
      py = qy
      j = j + 1
    }
    i = i + 1
  }
  best
}

///|
/// 点到线段距离（描边判定用）。
fn seg_dist(
  x0 : Double,
  y0 : Double,
  x1 : Double,
  y1 : Double,
  x : Double,
  y : Double,
) -> Double {
  let dx = x1 - x0
  let dy = y1 - y0
  let len2 = dx * dx + dy * dy
  if len2 <= 0.0 {
    let ex = x - x0
    let ey = y - y0
    return Double::sqrt(ex * ex + ey * ey)
  }
  let mut t = ((x - x0) * dx + (y - y0) * dy) / len2
  if t < 0.0 {
    t = 0.0
  } else if t > 1.0 {
    t = 1.0
  }
  let cx = x0 + t * dx
  let cy = y0 + t * dy
  let ex = x - cx
  let ey = y - cy
  Double::sqrt(ex * ex + ey * ey)
}

///|
/// 控制柄条数的**唯一判据**：每个锚点两个偏移（in/out）。空数组 = 全折线
/// （合法：省掉一堆 0）；给就要给全。入口与 `lint` 共用这一句。
pub fn handles_count_error(anchors : Int, handles : Int) -> String {
  if handles == 0 {
    return ""
  }
  let need = anchors * 2
  if handles != need {
    // 插值里只放标识符（铁律 9）：`\{anchors * 2}` 这种二元表达式不许写在插值里
    return "handles 要给\{need} 个数（每个锚点 in/out 两个偏移，共 \{anchors} 个锚点），收到 \{handles} 个"
  }
  ""
}

///|
/// 路径**是不是闭合的**：唯一一处判据（`fill != NoFill` ⇒ 闭合）。
///
/// 为什么不是 `layer` 上的一个 `closed` 字段：闭合与否**本来就等价于"有没有面"**，
/// 多一个字段就多一处可能与 `fill` 自相矛盾的状态（`fill=solid` 却 `closed=false`
/// 该画成什么样？）。渲染的填充/描边与命令面的盒子重算都读这一句。
pub fn fill_closed(f : Fill) -> Bool {
  match f {
    NoFill => false
    _ => true
  }
}
