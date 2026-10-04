/// 布尔运算（④ Stage A 的下一步）的**几何底座**：两个多边形环的 并/差/交/异或。
///
/// 设计取舍（每一条都有它的反例）：
/// ①**输入是两个闭合环**（画布坐标、CCW 规范化），输出是**一串环**：正面积 = 岛、
///   负面积 = 洞。调用方据此决定"一层 / 一层 + 反选蒙版 / 一个组"。
/// ②**一般位置（无共线重叠）走真正的裁剪**：把每条边按交点切碎、按"中点在不在
///   对方内部"分类、按操作挑边、再按端点串成环路。挑边规则是四个操作各一行：
///   并 = 两边"在外"的边；交 = 两边"在内"的边；差 = A 在外 + B 在内**反向**；
///   异或 = **所有边**，在对方内部的那些反向——同一条规则能同时给出并集边界与
///   洞，不需要给"洞"另写一段代码。
/// ③**退化情形按"没有面积交"处理**（共线重叠但不真的叠在一起、或干脆不相交、
///   或一个完全包住另一个而边界不碰）：并 = 两个环、交 = 空、差 = A、异或 = 两个环。
///   为什么必须显式接住"共线但只相接"：两个矩形并排共用一条边时，那条边上的
///   中点**正好落在对方边界上**，"在不在内部"这个问题本身没有稳定答案
///   （奇偶判定的边界行为），分类会随浮点抖动而变——于是环路接不上或接出一个
///   零面积的假环。相接不是裁剪问题，就不该走裁剪的路。
/// ④**共线重叠且真的叠在一起**（部分重合）⇒ 明确报错，不猜：真裁剪器要处理
///   重叠边的合并，那是另一个量级的事（见 PLAN 六十九的边界说明）。

///|
/// **共线重叠的每一段**：返回 (重叠段中点, 该边的单位法向)。
///
/// 这是"两条边重合了多少"的**唯一一趟遍历**：`collinear_overlap`（有没有）与
/// "有没有面积重叠"（往两侧探针）都读它——两处各写一遍平行/距离/区间投影，
/// 必然有一处先烂。
fn collinear_hits(
  a : Array[(Double, Double)],
  b : Array[(Double, Double)],
) -> Array[((Double, Double), (Double, Double))] {
  let out : Array[((Double, Double), (Double, Double))] = []
  let na = a.length()
  let nb = b.length()
  let mut i = 0
  while i < na {
    let p = a[i]
    let q = a[(i + 1) % na]
    let dx = q.0 - p.0
    let dy = q.1 - p.1
    let len2 = dx * dx + dy * dy
    if len2 > 0.0 {
      let len = Double::sqrt(len2)
      // 单位法向（往两侧探针时用）
      let nx = -dy / len
      let ny = dx / len
      let mut j = 0
      while j < nb {
        let s = b[j]
        let t = b[(j + 1) % nb]
        let ex = t.0 - s.0
        let ey = t.1 - s.1
        if (dx * ey - dy * ex).abs() <= 1.0e-9 * len {
          let dist = ((s.0 - p.0) * dy - (s.1 - p.1) * dx).abs() / len
          if dist <= 1.0e-6 {
            let (t0, t1) = seg_param_range(p, q, s, t)
            if t1 - t0 > 1.0e-6 {
              let tm = (t0 + t1) / 2.0
              out.push(((p.0 + dx * tm, p.1 + dy * tm), (nx, ny)))
            }
          }
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  out
}

///|
/// 环上有没有**共线重叠边**：命中就说明"部分重合"这类退化输入，命令面据此拒绝。
pub fn collinear_overlap(
  a : Array[(Double, Double)],
  b : Array[(Double, Double)],
) -> Bool {
  collinear_hits(a, b).length() > 0
}

///|
/// 两个环的面积交是否**正**（用来区分"相接/共边"与"真的叠在一起"）。
///
/// 两条路都要走，缺一条就会错：
/// ①某个顶点**严格落在**对方内部（一般的斜交重叠）；
/// ②共线重叠的那一段**往两侧各挪 1e-3**：有一点同时严格在两边内部 ⇒ 面积真的叠了。
///   为什么非要有②：两个矩形"错开半格"时，双方的顶点**全都落在对方边界上或外面**
///   （重叠区是个条带，没有一个顶点在对方内部），①问不出来——于是本该报错的
///   "部分重合"会被当成"相接"放过去，并给出一个**看着像对**的结果。
fn bool_has_area_overlap(
  a : Array[(Double, Double)],
  b : Array[(Double, Double)],
) -> Bool {
  for p in a {
    if path_nearest_dist(b, [], true, p.0, p.1) > 1.0e-6 &&
      path_contains(b, [], true, p.0, p.1) {
      return true
    }
  }
  for p in b {
    if path_nearest_dist(a, [], true, p.0, p.1) > 1.0e-6 &&
      path_contains(a, [], true, p.0, p.1) {
      return true
    }
  }
  for hit in collinear_hits(a, b) {
    let (m, n) = hit
    for sgn in [-1.0, 1.0] {
      let px = m.0 + sgn * 1.0e-3 * n.0
      let py = m.1 + sgn * 1.0e-3 * n.1
      if path_nearest_dist(a, [], true, px, py) > 1.0e-4 &&
        path_contains(a, [], true, px, py) &&
        path_nearest_dist(b, [], true, px, py) > 1.0e-4 &&
        path_contains(b, [], true, px, py) {
        return true
      }
    }
  }
  false
}

///|
/// 两条共线线段在**第一条**上的参数区间交集（`[0,1]` 内）。
fn seg_param_range(
  p : (Double, Double),
  q : (Double, Double),
  s : (Double, Double),
  t : (Double, Double),
) -> (Double, Double) {
  let dx = q.0 - p.0
  let dy = q.1 - p.1
  let len2 = dx * dx + dy * dy
  if len2 <= 0.0 {
    return (0.0, 0.0)
  }
  let proj = fn(v : (Double, Double)) -> Double {
    ((v.0 - p.0) * dx + (v.1 - p.1) * dy) / len2
  }
  let a0 = proj(s)
  let a1 = proj(t)
  let lo = if a0 < a1 { a0 } else { a1 }
  let hi = if a0 < a1 { a1 } else { a0 }
  let c0 = if lo < 0.0 { 0.0 } else { lo }
  let c1 = if hi > 1.0 { 1.0 } else { hi }
  if c1 < c0 {
    (0.0, 0.0)
  } else {
    (c0, c1)
  }
}

///|
/// 两个环**逐点相同**（同一个形状的两份拷贝）：按"完全相同"处理，而不是按
/// "共线重叠"报错——同形状求并/交天经地义，报错是把可用场景推走。
pub fn loops_identical(
  a : Array[(Double, Double)],
  b : Array[(Double, Double)],
) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    let p = a[i]
    let q = b[i]
    if (p.0 - q.0).abs() > 1.0e-6 || (p.1 - q.1).abs() > 1.0e-6 {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 有向面积（shoelace；**CCW 为正**）。判"岛还是洞"、也判"A 覆盖了多少"。
pub fn polygon_area(pts : Array[(Double, Double)]) -> Double {
  let n = pts.length()
  if n < 3 {
    return 0.0
  }
  let mut s = 0.0
  let mut i = 0
  while i < n {
    let p = pts[i]
    let q = pts[(i + 1) % n]
    s = s + (p.0 * q.1 - q.0 * p.1)
    i = i + 1
  }
  s / 2.0
}

///|
/// 逆序（正面积 ↔ 负面积互换）。环的方向**只在入口规范化一次**：规范化之后
/// "正 = 岛、负 = 洞"这条约定才成立。
pub fn reverse_loop(pts : Array[(Double, Double)]) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  let mut i = pts.length()
  while i > 0 {
    i = i - 1
    out.push(pts[i])
  }
  out
}

///|
/// 规范化成 CCW（正面积）。
pub fn ccw(pts : Array[(Double, Double)]) -> Array[(Double, Double)] {
  if polygon_area(pts) < 0.0 {
    reverse_loop(pts)
  } else {
    pts
  }
}

///|
/// 两个环的包围盒是否相交（差一点点也算，浮点容差）。
fn bbox_touch(
  a : Array[(Double, Double)],
  b : Array[(Double, Double)],
) -> Bool {
  let (ax0, ay0, ax1, ay1) = loop_box(a)
  let (bx0, by0, bx1, by1) = loop_box(b)
  !(ax1 < bx0 - 1.0e-9 || bx1 < ax0 - 1.0e-9 || ay1 < by0 - 1.0e-9 || by1 < ay0 - 1.0e-9)
}

///|
/// 环的包围盒。
pub fn loop_box(pts : Array[(Double, Double)]) -> (Double, Double, Double, Double) {
  if pts.length() == 0 {
    return (0.0, 0.0, 0.0, 0.0)
  }
  let mut x0 = pts[0].0
  let mut y0 = pts[0].1
  let mut x1 = pts[0].0
  let mut y1 = pts[0].1
  for p in pts {
    if p.0 < x0 {
      x0 = p.0
    }
    if p.1 < y0 {
      y0 = p.1
    }
    if p.0 > x1 {
      x1 = p.0
    }
    if p.1 > y1 {
      y1 = p.1
    }
  }
  (x0, y0, x1, y1)
}

///|
/// 四个布尔操作。**只有这一处枚举**：命令面、报告、字典、错误提示都从这里出。
pub(all) enum BoolOp {
  Union
  Subtract
  Intersect
  Xor
}

///|
/// 四个布尔操作的**名字表**（只有这一处：命令面、报告、字典、错误提示都读它）。
pub fn bool_op_name(op : BoolOp) -> String {
  match op {
    Union => "union"
    Subtract => "subtract"
    Intersect => "intersect"
    Xor => "xor"
  }
}

///|
/// 名字 → 操作（认不出来回 `None`，命令面据此拒绝并列出四个名字）。
pub fn bool_op_from_name(s : String) -> BoolOp? {
  match s {
    "union" => Some(Union)
    "subtract" => Some(Subtract)
    "intersect" => Some(Intersect)
    "xor" => Some(Xor)
    _ => None
  }
}

///|
/// 两个环不真的互相裁剪时的答案（相接 / 共边 / 完全分离 / 环相同）：
/// 并 = 两个环、交 = 空、差 = A、异或 = 两个环。
///
/// 这个分支不是"偷懒的快路径"：相接时"边上的中点在不在对方内部"**没有稳定答案**
/// （共线的中点正好落在对方边界上），走裁剪会随浮点抖动给出不同的环路。
fn no_clip(
  op : BoolOp,
  a : Array[(Double, Double)],
  b : Array[(Double, Double)],
) -> Array[Array[(Double, Double)]] {
  match op {
    Union => [a, b]
    Intersect => []
    Subtract => [a]
    Xor => [a, b]
  }
}

///|
/// 一条**有向子边**（环被交点切碎之后的一段）。
priv struct BoolSeg {
  p : (Double, Double)
  q : (Double, Double)
}

///|
/// 把 `loop` 的每条边按它与 `other` 的**真交点**切碎（`t` 在开区间内），
/// 并给出每一段的中点与"在不在 other 内部"。
///
/// 只收 `t ∈ (0,1)` 的交点：端点上的相交（T 形接触、共点）不是裁剪问题
/// ——那些情形在 `collinear_overlap` / `no_clip` 那一支就被接住了。
fn split_edges(
  lp : Array[(Double, Double)],
  other : Array[(Double, Double)],
) -> Result[Array[(BoolSeg, Bool)], String] {
  let n = lp.length()
  let m = other.length()
  let out : Array[(BoolSeg, Bool)] = []
  let mut i = 0
  while i < n {
    let p = lp[i]
    let q = lp[(i + 1) % n]
    let dx = q.0 - p.0
    let dy = q.1 - p.1
    let ts : Array[Double] = [0.0, 1.0]
    if dx != 0.0 || dy != 0.0 {
      let mut j = 0
      while j < m {
        let s = other[j]
        let t = other[(j + 1) % m]
        let ex = t.0 - s.0
        let ey = t.1 - s.1
        let den = dx * ey - dy * ex
        if den.abs() > 1.0e-12 {
          let u = ((s.0 - p.0) * ey - (s.1 - p.1) * ex) / den
          let v = ((s.0 - p.0) * dy - (s.1 - p.1) * dx) / den
          if u > 1.0e-9 && u < 1.0 - 1.0e-9 && v >= -1.0e-9 && v <= 1.0 + 1.0e-9 {
            ts.push(u)
          }
        }
        j = j + 1
      }
    }
    ts.sort()
    let mut k = 0
    while k + 1 < ts.length() {
      let t0 = ts[k]
      let t1 = ts[k + 1]
      if t1 - t0 > 1.0e-12 {
        let p0 = (p.0 + dx * t0, p.1 + dy * t0)
        let p1 = (p.0 + dx * t1, p.1 + dy * t1)
        let mx = (p0.0 + p1.0) / 2.0
        let my = (p0.1 + p1.1) / 2.0
        // 中点在对方**边界**上 ⇒ 这条边与对方共线（上面那一支该接住的情形）。
        // 到这一步说明输入比我们声明的定义域更退化，报错而不是猜内外。
        if path_nearest_dist(other, [], true, mx, my) <= 1.0e-6 {
          return Err("判不出内外：有边落在对方边界上（部分重合的输入，非一般位置）")
        }
        out.push(({ p: p0, q: p1 }, path_contains(other, [], true, mx, my)))
      }
      k = k + 1
    }
    i = i + 1
  }
  Ok(out)
}

///|
/// 从同一个点出发的多条候选边里挑**下一条**：取"从来向逆时针转得最少"的那条
/// （角序用无三角函数的比较，见 `rank_less`）。
///
/// 为什么非要挑：走到**捏合点**（两块只在一个点相接）时会有两条候选边，随手取
/// 一条会把两块拼成一个"8 字"，其中一块被走成**反向**——净面积照样对、环数照样
/// 是 2，而它被当成"洞"（画面就是那里被挖掉）。实测就是这么栽的：异或两个错开的
/// 矩形回 `islands:1 holes:1`，而正确结果是两个岛。判据也补严了：不只对账环数与
/// 净面积，还要**每一块都是正面积**。
fn rank_less(
  dx : Double,
  dy : Double,
  e1x : Double,
  e1y : Double,
  e2x : Double,
  e2y : Double,
) -> Bool {
  let c1 = dx * e1y - dy * e1x
  let t1 = dx * e1x + dy * e1y
  let c2 = dx * e2y - dy * e2x
  let t2 = dx * e2x + dy * e2y
  // θ ∈ [0,π) 与 [π,2π) 先分两半（θ 是相对来向的逆时针角）
  let h1 = if c1 > 0.0 || (c1 == 0.0 && t1 > 0.0) { 0 } else { 1 }
  let h2 = if c2 > 0.0 || (c2 == 0.0 && t2 > 0.0) { 0 } else { 1 }
  if h1 != h2 {
    h1 < h2
  } else {
    e1x * e2y - e1y * e2x > 0.0
  }
}

///|
/// 在候选里挑下一条（跳过用过的、起点接不上的）。
fn pick_next(
  kept : Array[BoolSeg],
  used : Array[Bool],
  cur : BoolSeg,
) -> Int {
  let dx = cur.q.0 - cur.p.0
  let dy = cur.q.1 - cur.p.1
  let mut best = -1
  let mut w = 0
  while w < kept.length() {
    if !used[w] &&
      (kept[w].p.0 - cur.q.0).abs() <= 1.0e-6 &&
      (kept[w].p.1 - cur.q.1).abs() <= 1.0e-6 {
      if best < 0 {
        best = w
      } else {
        let bx = kept[best].q.0 - kept[best].p.0
        let by = kept[best].q.1 - kept[best].p.1
        let ex = kept[w].q.0 - kept[w].p.0
        let ey = kept[w].q.1 - kept[w].p.1
        if rank_less(dx, dy, ex, ey, bx, by) {
          best = w
        }
      }
    }
    w = w + 1
  }
  best
}

///|
/// 挑边：按操作决定"留哪一侧、要不要反向"。
/// 并 = 两边**在外**；交 = 两边**在内**；差 = A 在外 + B 在内**反向**；
/// 异或（`keep_all`）= **全都留**，在对方内部的那些**反向**（于是洞自然成环）。
fn select_segments(
  segs : Array[(BoolSeg, Bool)],
  a_len : Int,
  keep_a : Bool,
  rev_a : Bool,
  keep_b : Bool,
  rev_b : Bool,
  keep_all : Bool,
) -> Array[BoolSeg] {
  let kept : Array[BoolSeg] = []
  let mut i = 0
  for s in segs {
    let is_a = i < a_len
    let inside = s.1
    let keep = if is_a { keep_a } else { keep_b }
    let rev = if is_a { rev_a } else { rev_b }
    if keep_all {
      if inside {
        kept.push({ p: s.0.q, q: s.0.p })
      } else {
        kept.push(s.0)
      }
    } else if inside == keep {
      if rev {
        kept.push({ p: s.0.q, q: s.0.p })
      } else {
        kept.push(s.0)
      }
    }
    i = i + 1
  }
  kept
}

///|
/// 把一串**定向**子边串成环路（每个环闭合、去掉重复收尾点、丢掉零面积的假环）。
fn chain_kept(
  kept : Array[BoolSeg],
) -> Result[Array[Array[(Double, Double)]], String] {
  let used : Array[Bool] = []
  let mut u = 0
  while u < kept.length() {
    used.push(false)
    u = u + 1
  }
  let loops : Array[Array[(Double, Double)]] = []
  let mut hops = 0
  while hops <= kept.length() {
    hops = hops + 1
    let mut start = -1
    let mut z = 0
    while z < kept.length() {
      if !used[z] && start < 0 {
        start = z
      }
      z = z + 1
    }
    if start < 0 {
      break
    }
    let walk : Array[(Double, Double)] = []
    let mut cur = kept[start]
    used[start] = true
    walk.push(cur.p)
    let mut closed = false
    let mut steps = 0
    while steps <= kept.length() {
      steps = steps + 1
      walk.push(cur.q)
      let head = walk[0]
      if (cur.q.0 - head.0).abs() <= 1.0e-6 && (cur.q.1 - head.1).abs() <= 1.0e-6 {
        closed = true
        break
      }
      let nxt = pick_next(kept, used, cur)
      if nxt < 0 {
        return Err("环路没接上：有一段边界找不到下一条（退化输入）")
      }
      used[nxt] = true
      cur = kept[nxt]
    }
    if !closed {
      return Err("环路没闭合（退化输入）")
    }
    let ring : Array[(Double, Double)] = []
    let mut r = 0
    while r + 1 < walk.length() {
      ring.push(walk[r])
      r = r + 1
    }
    if polygon_area(ring).abs() > 1.0e-9 {
      loops.push(ring)
    }
  }
  Ok(loops)
}

///|
/// **两个闭合环的布尔运算**（唯一的实现）。
///
/// 返回的环里**正面积 = 岛、负面积 = 洞**（方向就是语义：调用方不必再判一次）。
/// 顺序按包围盒 (x0,y0) 排定——输出必须确定性（组里的层序进 canonical JSON）。
pub fn boolean_loops(
  op : BoolOp,
  a0 : Array[(Double, Double)],
  b0 : Array[(Double, Double)],
) -> Result[Array[Array[(Double, Double)]], String] {
  if a0.length() < 3 || b0.length() < 3 {
    return Err("布尔运算的每个操作数至少要 3 个顶点（环才围得出面）")
  }
  let a = ccw(a0)
  let b = ccw(b0)
  if !bbox_touch(a, b) {
    return Ok(no_clip(op, a, b))
  }
  if loops_identical(a, b) {
    let out : Array[Array[(Double, Double)]] = match op {
      Union | Intersect => [a]
      Subtract | Xor => []
    }
    return Ok(out)
  }
  if collinear_overlap(a, b) {
    if bool_has_area_overlap(a, b) {
      return Err(
        "两个形状有**共线重叠且真的叠在一起**（部分重合）：本轮布尔运算只支持一般位置（无共线重叠）——把其中一个挪开/转一点，或改成 xor",
      )
    }
    return Ok(no_clip(op, a, b))
  }
  let sa = match split_edges(a, b) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let sb = match split_edges(b, a) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let all : Array[(BoolSeg, Bool)] = []
  for s in sa {
    all.push(s)
  }
  for s in sb {
    all.push(s)
  }
  // 四个操作各一行（挑"在外/在内" + 要不要反向）：
  //   并 = 两边在外；交 = 两边在内；差 = A 在外 + B 在内**反向**；
  //   异或 = 全都留，在对方内部的那些**反向**（于是洞自然成环）。
  // 四个操作各一行（挑"在外/在内" + 要不要反向），规则见 `select_segments`。
  let kept = match op {
    Union => select_segments(all, sa.length(), false, false, false, false, false)
    Intersect => select_segments(all, sa.length(), true, false, true, false, false)
    Subtract => select_segments(all, sa.length(), false, false, true, true, false)
    Xor => select_segments(all, sa.length(), false, false, false, false, true)
  }
  let loops = chain_kept(kept)
  match loops {
    Err(e) => Err(e)
    Ok(ls) => Ok(sort_loops(ls))
  }
}

///|
/// 输出顺序：按包围盒 (x0, y0) 排（确定性；组里的层序会进 canonical JSON）。
fn sort_loops(
  ls : Array[Array[(Double, Double)]],
) -> Array[Array[(Double, Double)]] {
  let out = ls.copy()
  let n = out.length()
  let mut i = 0
  while i < n {
    let mut j = i + 1
    while j < n {
      let (ax, ay, _, _) = loop_box(out[i])
      let (bx, by, _, _) = loop_box(out[j])
      let swap = if bx < ax - 1.0e-9 {
        true
      } else if (bx - ax).abs() <= 1.0e-9 {
        by < ay - 1.0e-9
      } else {
        false
      }
      if swap {
        let t = out[i]
        out[i] = out[j]
        out[j] = t
      }
      j = j + 1
    }
    i = i + 1
  }
  out
}
