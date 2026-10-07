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
///
/// ⚠️ 它同时是**能力上限**：超过这个边长的画布，渲染器**画不出来**。
/// 在本轮之前它是一处**静默截断**——`doc.width=5000` 时渲染器只画左上角
/// 4096×4096，`census` 把 canvas 报成 `[4096,200]`，而 `lint` 报 0 违规、
/// 画布尺寸/指纹/容器全都按 5000 记账：**放在 x=4500 的图层一个像素都不
/// 出现，且没有任何信号**（实测）。现在入口（`new`/`set-canvas`）直接拒绝、
/// `lint` 兜住手改容器，见 `render_limit_error`。
pub const RENDER_MAX_SIDE : Int = 4096

///|
/// **实际渲染尺寸**——"渲染多大"这件事的**唯一一处实现**。
///
/// 此前这段每边截断的写法在三个地方各抄了一遍（`impact_stages` 的两段式
/// 分支、`render_layers`、`render_layers_rasterized`），是"同一个判断两处
/// 实现，先烂的一定是没人读的那一处"的又一个温床。三处都改成调它。
pub fn render_size(w : Int, h : Int) -> (Int, Int) {
  let cw = if w > RENDER_MAX_SIDE { RENDER_MAX_SIDE } else { w }
  let ch = if h > RENDER_MAX_SIDE { RENDER_MAX_SIDE } else { h }
  (cw, ch)
}

///|
/// **可渲染上限判据**：空串 = 放行。
///
/// 报错要把"会发生什么"说清楚（静默丢内容比"参数非法"严重得多，调用方得
/// 知道画布并没有被拒绝、只是画不出来）：
///   * 说清**只画左上角多大**、**超出部分会怎样**（一个像素都不出现）；
///   * 说清**其余账目仍按原尺寸记**（尺寸/指纹/容器都不变）——这正是它
///     静默的原因；
///   * 给**可行的下一步**（缩画布，或先 `crop` 出要渲染的区域）。
///
/// 判据只有这一处；入口（`new`/`set-canvas`）与 `lint` 共用，不许各写一份。
pub fn render_limit_error(w : Int, h : Int) -> String {
  if w <= RENDER_MAX_SIDE && h <= RENDER_MAX_SIDE {
    return ""
  }
  "画布 \{w}×\{h} 超过可渲染上限（单边 ≤ \{RENDER_MAX_SIDE}）：渲染只会画出**左上角 \{RENDER_MAX_SIDE}×\{RENDER_MAX_SIDE}** 那块，画布其余部分里的图层**一个像素都不会出现**，而画布尺寸、指纹、容器内容仍按 \{w}×\{h} 记账（所以这是静默丢内容，不是拒绝）。请把画布缩到单边 ≤ \{RENDER_MAX_SIDE}，或先用 crop 裁出要渲染的区域"
}

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
/// 2×2 子采样的四个偏移。**放在循环外一份**：原先它写在最内层循环里，
/// 每个像素新建一个数组——12MP 渲染 = 每次 1200 万次分配（实测这是 12MP
/// 渲染的主要开销，见 PLAN 三十四）。数值与顺序一字未改。
///
/// 它必须与判据的"每像素 N 格"约定一致，所以格数取自这个数组的**长度**、
/// 别处不写死 4。
let subsample_2x2 : Array[(Double, Double)] = [
  (0.25, 0.25),
  (0.75, 0.25),
  (0.25, 0.75),
  (0.75, 0.75),
]

///|
/// 祖先链里有没有**真的会改变落点**的变换（rot/flip 非默认）。
/// 快速路径（`solid_rect_interior`/`mask_full_box`）都按"层自己的局部盒"算，
/// 只有恒等祖先下才成立——一处判据，别在每处各写一遍。
fn frame_transformed(frames : Transform) -> Bool {
  for f in frames {
    if f.rot != 0.0 || f.flip_h || f.flip_v {
      return true
    }
  }
  false
}

///|
/// 把一层压进祖先链（容器的变换在**子层之前**生效）。
fn frames_for(frames : Transform, l : @core.Layer) -> Transform {
  let out : Transform = []
  for f in frames {
    out.push(f)
  }
  out.push(frame_of(l))
  out
}

///|
/// **容器 → 预解算帧**：轴心（`@core.effective_box` 的中心）在**建链时**算一次。
/// 只有这一处算轴心，所以正逆两个方向读到的必然是同一个值。
fn frame_of(l : @core.Layer) -> Frame {
  let (bx, by, bw, bh) = @core.effective_box(l)
  {
    rot: l.rotation_deg,
    flip_h: l.flip_h,
    flip_v: l.flip_v,
    cx: bx + bw / 2.0,
    cy: by + bh / 2.0,
  }
}

///|
/// 层矩形上的点 → 该层的**父坐标系**（`to_local_in` + `to_local` 的组合）。
/// 蒙版/边界这类"贴着层矩形"的量都用它，别各自再算一遍。
fn screen(l : @core.Layer, frames : Transform, lx : Double, ly : Double) -> (Double, Double) {
  layer_to_canvas(l, frames, lx, ly)
}

///|
/// 层矩形上的点 → 该层的父坐标系（`canvas_to_layer` 的逆）。
fn layer_to_canvas(l : @core.Layer, frames : Transform, lx : Double, ly : Double) -> (Double, Double) {
  let (x, y) = to_canvas(l, lx, ly)
  to_canvas_in(frames, x, y)
}

///|
/// 该层父坐标系里的点 → 层矩形上的点（`screen` 的逆，`pick`/渲染共用）。
///|
/// `canvas_to_layer` 的**显式轴心**版本（逐像素路径用，轴心在循环外算好）。
fn canvas_to_layer_p(
  l : @core.Layer,
  frames : Transform,
  x : Double,
  y : Double,
  pvx : Double,
  pvy : Double,
) -> (Double, Double) {
  let (fx, fy) = to_local_in(frames, x, y)
  to_local_p(l, fx, fy, pvx, pvy)
}

///|
fn canvas_to_layer(l : @core.Layer, frames : Transform, x : Double, y : Double) -> (Double, Double) {
  let (fx, fy) = to_local_in(frames, x, y)
  to_local(l, fx, fy)
}

///|
/// 层矩形上的点 → 该层父坐标系（`layer_to_canvas` 的简写别名）。

///|
/// **祖先变换链**：把一个画布点逐级逆映射进某个容器的坐标系里。
///
/// `agent.shift_layer_tree` 是"搬内容"的写侧，这里是对称的读侧——**一处实现**
/// （渲染、`pick`、`paint_window`、`mask_cover_at` 都经它），正变换
/// `to_canvas_in` 与 `to_local_in` 成对（`to_canvas_frame_pt` / `to_local_frame`
/// 是单帧那一对）。空数组（根级层）就是恒等变换。
/// ⚠️ 帧里装的只会是**组**：组的 `x/y` 已被 `move` 折叠进后代，所以帧的变换
/// **不含平移**（见 `to_local_frame`）。
///
/// 帧里带的是**预解算**过的一份数据（`Frame`），不是整个 `Layer`：轴心来自
/// `effective_box`（组的盒子 = 成员的并集，要递归走一遍子树），而
/// `to_local_frame` 是**每个像素**都调一次 ⇒ 留着整个 `Layer` 就等于每像素重算
/// 一次子树并集（链长 d 时是每像素 O(d²)）。实测：同一份内容、同样的像素，只把
/// 嵌套深度从 1 改成 16，1000×1000 渲染从 0.30 s 变成 5.65 s（19 倍，PLAN 五十八）。
pub type Transform = Array[Frame]

///|
/// **预解算帧**：逆/正变换真正要的四样东西——翻转、旋转角、以及**算好一次的
/// 轴心**（画布坐标）。
///
/// 顺带把"正逆两处必须是同一个轴心"变成**结构上不可能违反**：`to_local_frame`
/// 与 `to_canvas_frame_pt` 读的是同一个 `Frame`，不再各自 `effective_box` 一遍
/// （PLAN 五十六那条教训）。
pub struct Frame {
  rot : Double
  flip_h : Bool
  flip_v : Bool
  cx : Double
  cy : Double
}

///|
/// **组帧的逆变换**：绕**内容中心**的 rot/flip，**不含平移**。
///
/// ⚠️ 为什么不复用 `to_local`：组的 `x/y` 已经被 `move` **折叠进每个后代**了
/// （`agent.shift_layer_tree` 把 delta 落到整棵子树、组盒自己也搬，PLAN 五十五）
/// ——再让祖先链减一次 `x/y` 就是**双重偏移**：实测 `move grp 15 10` 之后
/// 子层的窗被算到 2×15 之外，`probe (20,15)` 变白而 (30,15) 是红（PLAN 五十六）。
/// 所以组帧只做"绕中心旋转 + 绕中心镜像"。
///
/// ⚠️ 轴心走 `@core.effective_box`（组的盒子 = 成员的并集，**实时派生**），
/// 不读存下来的 `w/h`：那份只是建组时的快照，读它会让轴心固化成历史位置，
/// 而且 `resize grp` 能把它挪走（PLAN 五十七）。
fn to_local_frame(f : Frame, px : Double, py : Double) -> (Double, Double) {
  let cx = f.cx
  let cy = f.cy
  let mut u = px - cx
  let mut v = py - cy
  if f.rot != 0.0 {
    let (cos_t, sin_t) = rot_sincos(f.rot)
    let u2 = u * cos_t + v * sin_t
    let v2 = -u * sin_t + v * cos_t
    u = u2
    v = v2
  }
  if f.flip_h {
    u = -u
  }
  if f.flip_v {
    v = -v
  }
  // ⚠️ 加回**中心**（不是 `w/2`）：组的平移已经折叠进后代，所以"组的坐标系"
  // 与画布坐标系**同一个原点**——无变换时这一对正逆变换必须都是**恒等**
  // （加 `w/2` 会让子层的坐标再偏一个 `f.x/f.y`，实测 `move grp 15 10` 后
  // (20,15) 变白）。
  (u + cx, v + cy)
}

///|
/// 点 → 容器局部坐标（逆向：先到最外层容器，再逐级往里）。
///
/// `frames` 里装的只会是**组**（`frames_for` 只在组分支调用），所以这里走
/// 组帧的专用逆变换（不含平移，见 `to_local_frame`）。
pub fn to_local_in(frames : Transform, px : Double, py : Double) -> (Double, Double) {
  let mut x = px
  let mut y = py
  for f in frames {
    let (nx, ny) = to_local_frame(f, x, y)
    x = nx
    y = ny
  }
  (x, y)
}

///|
/// 组局部坐标 → 画布点（`to_local_frame` 的**逆**，与它成对）。
/// 轴心同样走 `@core.effective_box`——正逆两处必须**同一个**轴心，
/// 各写一遍就会有一边先烂（`to_local`/`to_canvas` 那条教训）。
fn to_canvas_frame_pt(f : Frame, lx : Double, ly : Double) -> (Double, Double) {
  let cx = f.cx
  let cy = f.cy
  let mut u = lx - cx
  let mut v = ly - cy
  if f.flip_h {
    u = -u
  }
  if f.flip_v {
    v = -v
  }
  if f.rot != 0.0 {
    let (cos_t, sin_t) = rot_sincos(f.rot)
    let u2 = u * cos_t - v * sin_t
    let v2 = u * sin_t + v * cos_t
    u = u2
    v = v2
  }
  // 与 `to_local_frame` 对称：加回中心（无变换时恒等，见那边的注释）
  (cx + u, cy + v)
}

///|
/// 容器局部坐标 → 画布点（`to_local_in` 的**逆**，与它成对——正逆分开写就会
/// 有一边先烂，`render/parent_transform_test.mbt` 用往返测试锁住）。
pub fn to_canvas_in(frames : Transform, lx : Double, ly : Double) -> (Double, Double) {
  let mut x = lx
  let mut y = ly
  let mut i = frames.length() - 1
  while i >= 0 {
    let (nx, ny) = to_canvas_frame_pt(frames[i], x, y)
    x = nx
    y = ny
    i = i - 1
  }
  (x, y)
}

///|
/// 设备坐标 → 层局部坐标（含绕层中心的逆旋转）。
///|
/// **本层局部坐标系里的轴心**（rot/flip 绕它转）。
///
/// 非组/非笔触层：`effective_box` 就是自己的盒子 ⇒ `(w/2, h/2)`——**返回原式**，
/// 别化简成 `bx + bw/2 - l.x`：那是消去，`l.x` 非整数时结果会差一个 ulp，
/// 而"差一个 ulp"就是画面差一列像素。
///
/// 笔触层：轴心 = **落笔范围的中心**（`raster_bbox`，与渲染/报告同一个
/// `effective_box`）。⚠️ 它要遍历全部 dab，所以**不许在逐像素循环里调**——
/// `paint_raster` 在循环外算一次（`to_local_p`），同 `Frame` 那条（PLAN 五十九）。
fn local_pivot(l : @core.Layer) -> (Double, Double) {
  let (bx, by, bw, bh) = @core.effective_box(l)
  if bx == l.x && by == l.y && bw == l.w && bh == l.h {
    (l.w / 2.0, l.h / 2.0)
  } else {
    (bx + bw / 2.0 - l.x, by + bh / 2.0 - l.y)
  }
}

///|
/// `to_local` 的**显式轴心**版本：轴心已经在外面算好了（逐像素路径用）。
fn to_local_p(
  l : @core.Layer,
  px : Double,
  py : Double,
  pvx : Double,
  pvy : Double,
) -> (Double, Double) {
  let mut lx = 0.0
  let mut ly = 0.0
  if l.rotation_deg == 0.0 {
    lx = px - l.x
    ly = py - l.y
  } else {
    let (cos_t, sin_t) = rot_sincos(l.rotation_deg)
    let dx = px - (l.x + pvx)
    let dy = py - (l.y + pvy)
    lx = dx * cos_t + dy * sin_t + pvx
    ly = -dx * sin_t + dy * cos_t + pvy
  }
  if l.flip_h {
    lx = 2.0 * pvx - lx
  }
  if l.flip_v {
    ly = 2.0 * pvy - ly
  }
  (lx, ly)
}

///|
pub fn to_local(
  l : @core.Layer,
  px : Double,
  py : Double,
) -> (Double, Double) {
  let (pvx, pvy) = local_pivot(l)
  to_local_p(l, px, py, pvx, pvy)
}

///|
/// 局部坐标 → 画布坐标（`to_local` 的**逆**）。
///
/// **与 `to_local` 成对**：正变换与逆变换分开写，就有一边先烂——这里靠
/// `render` 的往返测试锁住（`to_local(to_canvas(p)) == p`，含旋转 + 双向翻转）。
/// lint 要用它把"局部顶点"换算到画布坐标，才能和渲染窗（画布坐标）比。
pub fn to_canvas(l : @core.Layer, lx : Double, ly : Double) -> (Double, Double) {
  let (pvx, pvy) = local_pivot(l)
  to_canvas_p(l, lx, ly, pvx, pvy)
}

///|
/// `to_canvas` 的**显式轴心**版本（逐像素路径用，见 `local_pivot`）。
/// ⚠️ 轴心只有一个来源：正逆两处都读 `local_pivot`（同一处），别在这里再算一遍。
fn to_canvas_p(
  l : @core.Layer,
  lx : Double,
  ly : Double,
  pvx : Double,
  pvy : Double,
) -> (Double, Double) {
  let mut x = lx
  let mut y = ly
  // 正向管线：局部 →（绕轴心 flip 镜像）→ 绕轴心旋转 → 平移到层位
  if l.flip_h {
    x = 2.0 * pvx - x
  }
  if l.flip_v {
    y = 2.0 * pvy - y
  }
  if l.rotation_deg == 0.0 {
    return (l.x + x, l.y + y)
  }
  let (cos_t, sin_t) = rot_sincos(l.rotation_deg)
  let cx = l.x + pvx
  let cy = l.y + pvy
  let dx = x - pvx
  let dy = y - pvy
  (cx + dx * cos_t - dy * sin_t, cy + dx * sin_t + dy * cos_t)
}

///|
/// 路径**是不是闭合的**：唯一一处判据。`Fill` 没有 `Eq`（渐变/图案也是 `Fill`
/// 的变体，逐字段比较要另立规则），所以这里用 `match` 而不是 `!=`——顺便也把
/// "填充类型变了，闭合语义要不要跟着变"这个问题压缩成这一个函数：
/// **只有 `NoFill` 是开放**（只描边），其余一切填充都闭合。
fn path_closed(l : @core.Layer) -> Bool {
  @core.fill_closed(l.fill)
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
    // 路径的**面**只在闭合时有意义：`fill=NoFill` = 开放路径（只描边），
    // 这条"闭合与否"的语义只在这里与描边/`path_box` 三处读同一个判断——
    // 不新增 `closed` 字段，是为了让"有没有面"和"填不填"不可能互相矛盾。
    // 几何（采样/包含判定）全在 `@core.path_contains` 一处，`pick` 也读它。
    @core.ShapeKind::Path => @core.path_contains(l.points, l.handles, path_closed(l), lx, ly)
    @core.ShapeKind::Line => false // 线段无填充面
    @core.ShapeKind::Image => lx >= 0.0 && lx < l.w && ly >= 0.0 && ly < l.h
    @core.ShapeKind::Group => false
    // ⚠️ 文本层的墨是**字形位图**，不是盒子：盒子比墨大约一倍，且含字距空隙
    // 与字形上下的空行（实测 "H" 的盒子 24×28 里只有 208/672 个像素有墨）。
    // 只按盒子判 ⇒ `pick`/`sample` 会报出一个当点一个像素都没画的层
    // （`sample` 自相矛盾那条）。判据与渲染器**共用** `text_ink` 一处实现。
    @core.ShapeKind::Text => text_ink(l, lx, ly)
    @core.ShapeKind::Adjust => false
    @core.ShapeKind::Raster => false
  }
}

///|
/// 圆角半径的**夹取**：`r` 先跟半宽比、再跟半高比（这个顺序是历史语义，
/// 不是 `min(r, w/2, h/2)`——两者在 `r > w/2 > h/2` 时不同）。
/// 渲染器（`in_rounded_rect`）与快速路径（`solid_rect_interior` 的内接盒）
/// **必须同一把尺子**：判宽一个像素就是静默改画面。
fn clamped_radius(w : Double, h : Double, r : Double) -> Double {
  if r <= 0.0 {
    0.0
  } else if r > w / 2.0 {
    w / 2.0
  } else if r > h / 2.0 {
    h / 2.0
  } else {
    r
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
  let rr = clamped_radius(w, h, r)
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
    // 路径描边：沿**同一份采样**（`@core.path_nearest_dist`）算最近距离——
    // 与填充用同一套控制柄语义、同一份弦长采样规则，不会"看着在这里、命中在那里"。
    @core.ShapeKind::Path => @core.path_nearest_dist(
      l.points,
      l.handles,
      path_closed(l),
      lx,
      ly,
    ) <=
      width / 2.0
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
/// 层的**保守渲染窗**（左闭右开）：以层盒中心为心、对角线长为边，再放宽 2px
/// （旋转 45° 的层也不会漏；`inside_fill` 再在窗内做精确判定）。
///
/// **`paint_layer` 与 `pick` 共用这一处**。此前两处各写一遍：`paint_layer`
/// 只在这个窗内落像素，`pick` 却直接用 `inside_fill`/`inside_stroke` —— 于是
/// 顶点伸出盒子的多边形（`add-polygon w=10 h=10 points=0,0;50,0;50,50`，
/// 窗只到 x≤25）在 (30,10) 被 `pick` 报成"有这层"，而 `probe` 是白纸。
/// 同一件事两个实现，就会一边说有一边说没有。
pub fn paint_window(l : @core.Layer) -> (Int, Int, Int, Int) {
  paint_window_in(l, [])
}

///|
/// 带**祖先变换链**的渲染窗：组的 rot/flip 会把子层的实际落点搬走，窗必须跟着
/// 走——否则旋转后的内容被裁在自己那个（没转的）盒子里（实测：组盒 60×10 的
/// 横条转 90° 后应是一根**竖条**，却被裁成 60×35 的一团，见 PLAN 五十六）。
///
/// 判据与 `paint_window` 同一处（这里就是它的实现），所以 `pick` 与渲染不可能
/// 分叉——窗只是"保守上界"，精确判定仍在 `inside_fill`/`inside_stroke`。
fn paint_window_in(l : @core.Layer, frames : Transform) -> (Int, Int, Int, Int) {
  let reach = Double::sqrt(l.w * l.w + l.h * l.h)
  if frames.length() == 0 {
    // 根级层（没有祖先变换）：保留**原式**，逐位不变——四角外接盒与它数学上
    // 等价，但浮点舍入可能差 1px，而"窗差一像素"就是画面差一像素。
    let cx0 = l.x + l.w / 2.0
    let cy0 = l.y + l.h / 2.0
    return (
      (cx0 - reach / 2.0).to_int() - 2,
      (cy0 - reach / 2.0).to_int() - 2,
      (cx0 + reach / 2.0).to_int() + 2,
      (cy0 + reach / 2.0).to_int() + 2,
    )
  }
  // 以对角线为边的方形（旋转任意角度都装得下），四个角逐点过祖先链，
  // 再取它们的外接盒——变换后的形状一定落在这四个角的外接盒里。
  let hx = reach / 2.0
  let hw = l.w / 2.0
  let hh = l.h / 2.0
  let mut x0 = 1.0e18
  let mut y0 = 1.0e18
  let mut x1 = -1.0e18
  let mut y1 = -1.0e18
  for c in [
    (hw - hx, hh - hx),
    (hw + hx, hh - hx),
    (hw - hx, hh + hx),
    (hw + hx, hh + hx),
  ] {
    let (px, py) = screen(l, frames, c.0, c.1)
    if px < x0 { x0 = px }
    if py < y0 { y0 = py }
    if px > x1 { x1 = px }
    if py > y1 { y1 = py }
  }
  (x0.to_int() - 2, y0.to_int() - 2, x1.to_int() + 2, y1.to_int() + 2)
}

///|
/// 把"覆盖度 + 取样色 + 蒙版因子 + 层透明度"折成**源色**（`source-over` 的输入）。
///
/// 这是唯一一处：通用逐像素路径与下面的实心矩形快速路径都调它，所以"颜色自带
/// 的 alpha 并进覆盖度""蒙版因子先于合成""层透明度并入源 alpha"这三条语义
/// 不可能在两条路径上分叉。
fn compose_src(cover : Int, color : Int, mf : Double, eff_opacity : Double) -> Int {
  // 颜色自带的 alpha 要并进覆盖度。`Fill::Solid(0xAARRGGBB)` 的类型注释
  // 和工具面的 `fill: #RRGGBB[AA]` 都承诺了它，但此前这里
  // `color & 0x00FFFFFF` 把 alpha 直接丢了——`fill=#FF000080`（半透明红）
  // 渲染成**完全不透明红**，而且不报错。仓库里没有任何测试用半透明
  // 填充，所以这个缺口一直没人踩到。
  let ca = (color >> 24) & 0xFF
  let cover = if ca >= 255 { cover } else { (cover * ca + 127) / 255 }
  let src_alpha = ((cover & 0xFF) << 24)
  let rgb = color & 0x00FFFFFF
  let mut src = src_alpha | rgb
  // 蒙版因子先于合成融入源 alpha（蒙版外→源透明→下层透出）
  if mf < 1.0 {
    let ma = ((src >> 24) & 0xFF).to_double() / 255.0 * mf
    let ma255 = (ma * 255.0 + 0.5).to_int()
    src = (ma255 << 24) | rgb
  }
  // 层透明度并入源 alpha
  let a = ((src >> 24) & 0xFF).to_double() / 255.0 * eff_opacity
  let a255 = (a * 255.0 + 0.5).to_int()
  (a255 << 24) | rgb
}

///|
/// 实心矩形层的**整块内部**（半开区间），落在 `[px0,px1)×[py0,py1)` 窗内。
///
/// 这些像素的 4 个 2×2 子样本**全都**在矩形内部，于是覆盖度恒为 255、取样色
/// 恒为 `fill`、蒙版因子恒为 1.0——逐像素跑 4 次 `to_local`/`inside_fill` 是
/// 白做的。12MP 的整幅矩形层因此从 ~0.5 s/层降到合成一遍的量级。
///
/// ⚠️ 这里是**性能**路径，一旦判宽了一个像素，画面就少/多一块而没人报错，
/// 所以前提全部写成"缺一不可"：
///   * `Rect` 且不旋转、不翻转、圆角 ≤ 0（否则内部不再是"整块"，或 `to_local`
///     走另一支）；
///   * 无蒙版（有蒙版时每像素的因子不同）、无描边（`inside_stroke` 优先级最高）；
///   * `Fill::Solid`（渐变/位图的颜色逐像素不同）。
/// 边界按**严格不等式留 EPS 余量**：`to_local` 里的浮点算式
/// （`(px + 0.25) - l.x`）与这里的 `px - (l.x - 0.25)` 在 ulp 级别可以不一样，
/// 而判宽一个像素是**静默**改画面。留余量的代价只是边界那一圈退回通用路径。
//// 返回 `None` = 没有可快速填充的内部（不满足前提，或内部为空）。
fn solid_rect_interior(
  l : @core.Layer,
  fill : @core.Fill,
  px0 : Int,
  py0 : Int,
  px1 : Int,
  py1 : Int,
) -> (Int, Int, Int, Int)? {
  match fill {
    @core.Fill::Solid(_) => ()
    _ => return None
  }
  if !(l.kind is @core.ShapeKind::Rect) {
    return None
  }
  if l.rotation_deg != 0.0 || l.flip_h || l.flip_v {
    return None
  }
  if l.stroke.width > 0.0 {
    return None
  }
  // 4 个样本全在内 ⇔ px + 0.25 - l.x ≥ 0 且 px + 0.75 - l.x < w（半开上界）。
  //
  // 圆角那一支：`in_rounded_rect` 的判据是 `nx == 0 || ny == 0 || nx²+ny² ≤ rr²`
  // ——**前两支是个 OR**，所以"x 落在那条竖向直边带里（nx == 0）"或者"y 落在
  // 横向直边带里（ny == 0）"**任一条**就够覆盖恒为 1。两条带的交集（= 各边内缩
  // `rr`）当然也够，而且是个矩形；代价是比单取一条带小（慢一点），换来的是
  // 一处不用分类讨论的保守盒。⚠️ 判宽一个像素就是静默改画面：
  // 圆弧内侧那圈像素**不在**这个盒里（它们靠通用路径画），这是有意的。
  let rr = clamped_radius(l.w, l.h, l.corner_radius)
  let ix0 = clamp_int((l.x + rr - 0.25 + INTERIOR_EPS).ceil(), px0, px1)
  let ix1 = clamp_int((l.x + l.w - rr - 0.75 - INTERIOR_EPS).ceil(), px0, px1)
  let iy0 = clamp_int((l.y + rr - 0.25 + INTERIOR_EPS).ceil(), py0, py1)
  let iy1 = clamp_int((l.y + l.h - rr - 0.75 - INTERIOR_EPS).ceil(), py0, py1)
  if ix1 <= ix0 || iy1 <= iy0 {
    return None
  }
  // 有蒙版时还得"覆盖恒为 1"——两个盒取交。蒙版盒取不到（`invert`/退化/太小）
  // 就整块放弃：那一层退回通用路径，画面不变，只是慢。
  match l.mask {
    None => Some((ix0, iy0, ix1, iy1))
    Some(m) =>
      match mask_full_box(l, m) {
        None => None
        Some((mx0, my0, mx1, my1)) => {
          let ax0 = if mx0 > ix0 { mx0 } else { ix0 }
          let ay0 = if my0 > iy0 { my0 } else { iy0 }
          let ax1 = if mx1 < ix1 { mx1 } else { ix1 }
          let ay1 = if my1 < iy1 { my1 } else { iy1 }
          if ax1 <= ax0 || ay1 <= ay0 {
            None
          } else {
            Some((ax0, ay0, ax1, ay1))
          }
        }
      }
  }
}

///|
/// 夹到 `[lo, hi]` 的整数转换（`v` 已是整数双精度，截断无损；先夹再转，
/// 免得手改容器里的极端坐标把 `to_int` 推出范围）。
fn clamp_int(v : Double, lo : Int, hi : Int) -> Int {
  if v <= lo.to_double() {
    lo
  } else if v >= hi.to_double() {
    hi
  } else {
    v.to_int()
  }
}

///|
/// 边界余量。见 `solid_rect_interior`：只用来把"卡在 ulp 边界上"的像素让给
/// 通用路径，1e-6 远大于 1e4 量级坐标的 ulp（~1e-12），又不影响任何真实几何。
const INTERIOR_EPS : Double = 1.0e-6

///|
/// 蒙版覆盖**恒为 1.0** 的像素盒（画布坐标、半开区间；`px`/`py` 是**像素中心**，
/// 因为 `mask_cover_at` 就是按中心求值的）。
///
/// 为什么能算出来：`soft_cover(t, Linear)` 在 `t ≥ 1.0` 时**精确**返回 1.0，
/// 而蒙版内距的算式是三支之一（见 `mask_inner_dist`）：
///   * 矩形（含圆角）：`inner_dist = 内距`；
///   * 椭圆：`inner_dist = (1 - ρ) × min(w,h)/2`；
///   * **多边形：没有这样的盒子**（见下面那一支，直接退回通用路径）；
/// 毛边噪声 `mask_edge_offset` 被 `roughen` 界住（`amp × (v*2-1)`，`v ∈ [0,1]`
/// ⇒ `offset ∈ [-roughen, +roughen]`）。所以取
/// `t = feather + roughen + ε`，凡 `inner_dist ≥ t` 的像素**必然** cover == 1.0：
///   * `d = inner_dist - offset ≥ t - roughen = feather + ε > feather` ⇒ 软覆盖 1.0；
///   * `feather == 0` 时 `d ≥ ε > 0` ⇒ 硬覆盖 1.0（且 `inner_dist > 0` 已严格在形内，
///     与"硬边只判在不在形状里"的边界约定（半开区间）不冲突）。
/// ⚠️ 这里给的是**盒**（内接矩形）而不是精确区域——**只会小不会大**是安全的
/// （小的那一圈退回通用路径，画面一样）；大了就是把 cover < 1 的像素按 1.0 合成，
/// 那是**静默加亮**。椭圆那一支用"内接正方形"（半轴 / √2）再配 `t` 里的 ε 余量。
/// `invert` 直接把区域变成"形状外"（无界），不在此路。
///
/// ⚠️ **坐标系**：蒙版的 `x/y` 是**本层局部**坐标（`mask_cover_at` 收的就是局部点，
/// 与它同一套），而本函数的调用方在**画布**坐标里算盒（`l.x + …`）。这里必须把
/// 局部盒平移回画布再求像素盒。实测不换算时：层在 (30,30)、蒙版局部 (40,40,10,10)
/// 会在画布 (40..50)² 多画一块"覆盖恒为 1"的红（本该只画 (70..80)²）——
/// 快速路径按 1.0 合成越界像素，正是本函数开头说的"静默加亮"。
///
/// 调用方已保证本层 `rotation_deg == 0`、两个 flip 都是假、且祖先链没有变换
/// （`frame_transformed`），所以"局部 → 画布"就是加 `(l.x, l.y)`；这两道闸在
/// `solid_rect_interior` 里，改那里时别拆掉。
fn mask_full_box(l : @core.Layer, m : @core.LayerMask) -> (Int, Int, Int, Int)? {
  if m.invert {
    return None
  }
  if m.w <= 0.0 || m.h <= 0.0 {
    return None
  }
  let t = m.feather + m.roughen + INTERIOR_EPS
  let (a0, a1, b0, b1) = match m.kind {
    @core.ShapeKind::Ellipse => {
      let short = if m.w < m.h { m.w } else { m.h }
      let half = short / 2.0
      let rho = 1.0 - t / half
      let hx = rho * m.w / 2.0 * INV_SQRT2
      let hy = rho * m.h / 2.0 * INV_SQRT2
      (m.w / 2.0 - hx, m.w / 2.0 + hx, m.h / 2.0 - hy, m.h / 2.0 + hy)
    }
    // 多边形（任意形状选区）：**没有这块**。多边形的"覆盖恒为 1"区域一般
    // 不是盒子（三角形的只有一个点，细长斜条一个点都没有），按矩形内域算就是
    // **比实际大** ⇒ 形状外的那一圈被按 cover=1 合成（实测：三角形蒙版盖在
    // 矩形层上，(15,15) 在三角形外却仍是原色 —— 静默不裁，正是本函数注释里
    // 说的"静默加亮"）。返回 None 只是这一层退回通用路径（慢一点，画面一样）。
    @core.ShapeKind::Polygon => return None
    // 其它 kind 走 `mask_inner_dist` 的圆角矩形支（与它同一套语义）。
    _ => {
      let r = if m.radius > 0.0 { m.radius } else { 0.0 }
      (r + t, m.w - r - t, r + t, m.h - r - t)
    }
  }
  if a1 <= a0 || b1 <= b0 {
    return None
  }
  // 局部盒 → 像素中心盒：`px - m.x ∈ [a0, a1]` ⇒ `px ∈ [ceil(m.x+a0), floor(m.x+a1)]`
  // （`m.x/m.y` 先平移回画布：见上面的坐标系说明）
  let ox = l.x + m.x
  let oy = l.y + m.y
  let bx0 = clamp_int((ox + a0).ceil(), -1000000000, 1000000000)
  let by0 = clamp_int((oy + b0).ceil(), -1000000000, 1000000000)
  let bx1 = clamp_int((ox + a1 - SUBSAMPLE_MAX).floor(), -1000000000, 1000000000)
  let by1 = clamp_int((oy + b1 - SUBSAMPLE_MAX).floor(), -1000000000, 1000000000)
  if bx1 < bx0 || by1 < by0 {
    return None
  }
  Some((bx0, by0, bx1 + 1, by1 + 1))
}

///|
///|
/// 2×2 子样本里最大的那个偏移（`subsample_2x2` 取 0.25/0.75 ⇒ **0.75**）。
///
/// 快速路径按 `cover = 1.0` 整块合成，所以"盒里的像素"必须连**最靠后的那个
/// 子样本**都恰好满覆盖：最后一列的样本落在 `px + 0.75`，若只按像素中心
/// （`floor(m.x + a1)`）收边，那一列会以 1.0 合成，而通用路径在那里其实不到 1
/// （`feather=4` 时约 0.94）—— 就是本文件反复说的"静默加亮"。
/// ⚠️ 这个常量与 `subsample_2x2` 是**同一件事**，改采样点必须同时改这里。
const SUBSAMPLE_MAX : Double = 0.75

///|
/// `1/√2`：椭圆那一支求"内接正方形"用。
const INV_SQRT2 : Double = 0.7071067811865476

///|
/// 整块内部按**常量源色**合成（`compose_src` 与通用路径同一处）。
fn paint_solid_rect_interior(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  color : Int,
  eff_opacity : Double,
  ix0 : Int,
  iy0 : Int,
  ix1 : Int,
  iy1 : Int,
) -> Unit {
  let src = compose_src(255, color, 1.0, eff_opacity)
  let stride = buf.width
  let mut py = iy0
  while py < iy1 {
    let row = py * stride
    let mut px = ix0
    while px < ix1 {
      let i = row + px
      buf.pixels[i] = composite_pixel(buf.pixels[i], src, l.blend)
      px = px + 1
    }
    py = py + 1
  }
}

///|
/// 渲染单个层到画布（含 2×2 子采样 AA 与混合）。
///|
/// **"这一层到底看不看得见"只有一处**：`visible` + **有效不透明度**（自己 × 继承）。
///
/// 返回 `0.0` 表示"不画/不拾/不画框"。三个消费者——渲染 `paint_layer`、
/// `pick_from`、选中线框 `draw_overlays_in`——**共用这一处**：同一条判断写三遍，
/// 先烂的一定是没人读的那两遍（PLAN 六十三：线框那遍是从 `pick` 抄的，当场把
/// 变异 R56 的锚点撞成"命中 2 处"——锚点撞车就是重复的体检报告）。
///
/// ⚠️ `l.opacity <= 0.0` 的早退**不能**省：`clamp01(0 × NaN)` 是 `NaN`，而
/// `NaN <= 0.0` 为假 ⇒ 省掉它会让"α=0 的层"在继承值是 NaN 时漏过去（`paint_layer`
/// 一直有这个早退，`pick` 没有——收成一处之后两者对齐）。
fn effective_opacity(l : @core.Layer, inherited_opacity : Double) -> Double {
  if !l.visible {
    return 0.0
  }
  if l.opacity <= 0.0 {
    return 0.0
  }
  clamp01(l.opacity * inherited_opacity)
}

///|
fn paint_layer(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  env : RenderEnv,
  inherited_opacity : Double,
  frames : Transform,
) -> Unit {
  let eff_opacity = effective_opacity(l, inherited_opacity)
  if eff_opacity <= 0.0 {
    return
  }
  // 图层样式（fx）：**这一层先栅格化到自己的透明缓冲 → 加四件套 → 再整块按
  // opacity/blend 混进目标**（DESIGN §8 写死的产品决定）。
  //
  // 为什么要另开一条路而不是"就地往 buf 上画"：影/发光会溢出层的盒子、描边画在
  // 层的上面——它们都属于**这一层的像素**，先被下面那些层看见就等于样式不跟着层走
  // （换层序就变样子）。所以必须先拿到"这一层自己的画面"。
  //
  // `opacity` 在**最后一步**才乘（`compose_src(…, eff_opacity)`）：若先烤进
  // 内容缓冲，半透明层的描边会算出 `dilate(A) − A = 0` —— 样式凭空消失。
  // 内容按 opacity=1 栅格化，样式作用在"形状的覆盖度"上，最后整块打折。
  //
  // `Adjust` 层没有自己的像素（它的画面是**它下面那张底图**），样式无从谈起：
  // 入口拒、lint 报，渲染器这里直接不认（于是"caps 说没有 ⇒ 逐位相同"成立）。
  if !(l.kind is @core.ShapeKind::Adjust) {
    match l.fx {
      Some(f) =>
        if @core.fx_any_on(f) {
          let style_src = { ..l, opacity: 1.0, fx: None }
          let content = @codec.rgba_new(buf.width, buf.height)
          @codec.fill_rect_rgba(content, 0, 0, buf.width, buf.height, 0x00000000)
          paint_layer(style_src, content, env, 1.0, frames)
          let styled = apply_fx(content, f)
          let total = buf.width * buf.height
          let mut i = 0
          while i < total {
            let p = styled.pixels[i]
            if (p & 0xFF000000) != 0 {
              // `compose_src` 是"层不透明度并入源 alpha"的唯一一处实现
              let src = compose_src(255, p, 1.0, eff_opacity)
              buf.pixels[i] = composite_pixel(buf.pixels[i], src, l.blend)
            }
            i = i + 1
          }
          return
        }
      None => ()
    }
  }
  match l.kind {
    @core.ShapeKind::Group => {
      // 组 α=1：逐子层直接叠到底图（与"没有这一层组"逐位相同的快路径）
      // **组的变换**（rot/flip）在这里落地：把组自己压进祖先链，子层的
      // `to_local` 就会经过它——渲染、`pick`、`mask_cover_at` 共用同一条链
      // （此前组只"搬内容"、不能变换，见 PLAN 五十六）。
      let inner = frames_for(frames, l)
      if eff_opacity >= 1.0 {
        for c in l.children {
          paint_layer(c, buf, env, 1.0, inner)
        }
        return
      }
      // 组 α<1：**先把子层叠成"这个组自己的画面"，再整体打折**——SVG
      // `<g opacity>` 的语义。逐子层各自打折会让**重叠区被混合两次**：实测两个
      // 不透明子层重叠、组 α=0.5 时重叠区是 `#7F3FBFFF`（蓝透过"红 α=0.5 的
      // 粉"），而整体打折是 `#7F7FFFFF`（与不重叠的蓝区一致）——重叠处多出一条
      // 谁都解释不清的接缝（PLAN 五十四）。
      let scratch = @codec.rgba_new(buf.width, buf.height)
      @codec.fill_rect_rgba(scratch, 0, 0, buf.width, buf.height, 0x00000000)
      for c in l.children {
        paint_layer(c, scratch, env, 1.0, inner)
      }
      // 组画面叠回父坐标系。组自身没有 rot/flip 时就是"同一张画布、逐像素叠"
      // ——与改前**逐位相同**的快路径（浮点重采样会差几个色阶，所以不能省）。
      let plain = l.rotation_deg == 0.0 && !l.flip_h && !l.flip_v
      let total = buf.width * buf.height
      let mut i = 0
      while i < total {
        if plain {
          let p = scratch.pixels[i]
          if (p & 0xFF000000) != 0 {
            // 源 alpha = 组画面的 alpha × 组 α：`compose_src` 是"层不透明度并入
            // 源 alpha"的**唯一**一处实现，别在这里再抄一遍舍入
            let src = compose_src(255, p, 1.0, eff_opacity)
            buf.pixels[i] = composite_pixel(buf.pixels[i], src, l.blend)
          }
        } else {
          // 组有变换：把这张画面当成贴在组矩形上的"一片纹素"，
          // 逐目标像素在**组的坐标系**里取样（与形状层同一条采样路径）。
          let px = i % buf.width
          let py = i / buf.width
          for sub in subsample_2x2 {
            // 先在**组坐标系**里取样，再正向映回画布去读那张画面
            let (gx, gy) = canvas_to_layer(l, frames, px.to_double() + sub.0, py.to_double() + sub.1)
            let (cx, cy) = screen(l, frames, gx, gy)
            let sx = cx.to_int()
            let sy = cy.to_int()
            if sx >= 0 && sy >= 0 && sx < buf.width && sy < buf.height {
              let p = scratch.pixels[sy * buf.width + sx]
              if (p & 0xFF000000) != 0 {
                let src = compose_src(255, p, 1.0, eff_opacity)
                buf.pixels[i] = composite_pixel(buf.pixels[i], src, l.blend)
              }
            }
          }
        }
        i = i + 1
      }
      // 组自身无面
      return
    }
    @core.ShapeKind::Adjust => {
      // 调整层：对当前缓冲（其下全部可见层的合成结果）施加算子；
      // **蒙版与层不透明度都在这里生效**，两者合成同一个"这一像素上算子生效
      // 多少"（见 `apply_adjust_layer`：软强度只有一处混合公式）
      apply_adjust_layer(l, buf, eff_opacity, frames)
      return
    }
    @core.ShapeKind::Text => {
      paint_text(l, buf, env, eff_opacity, frames)
      return
    }
    @core.ShapeKind::Raster => {
      paint_raster(l, buf, env, eff_opacity, frames)
      return
    }
    _ => ()
  }
  // 保守渲染窗（与 `pick` 共用 `paint_window`：一处实现，两处判断不许分叉）
  let (x0, y0, x1, y1) = paint_window_in(l, frames)
  let px0 = if x0 < 0 { 0 } else { x0 }
  let py0 = if y0 < 0 { 0 } else { y0 }
  let px1 = if x1 > buf.width { buf.width } else { x1 }
  let py1 = if y1 > buf.height { buf.height } else { y1 }
  // **实心矩形层的整块内部**：4 个子样本全在内 ⇒ 覆盖度/取样色/蒙版因子全是
  // 常量，逐像素的 4 次形状测试是白做的（12MP 整幅层上这是全部代价）。
  // 先按常量源色填掉，再让下面的通用循环**跳过**这块（窗内其余像素——边界、
  // 旋转、蒙版、描边、渐变——照旧走通用路径，一条语义都没分叉）。
  //
  // ⚠️ **祖先有变换时整块跳过**：`solid_rect_interior` 只看这一层自己的
  // rot/flip，不知道组把它转了 90°——于是它会按**没转**的盒子整块填色，
  // 通用段再画一遍转过的那份，画面里**两个副本**同时存在（实测 60×10 的横条
  // 转 90° 后红像素 850 个、范围 60×35：横条与竖条都在，PLAN 五十六）。
  // 快速段是**纯性能**优化，退化成通用路径画面一样，所以在变换下退出去最省心。
  let interior = if frame_transformed(frames) {
    None
  } else {
    solid_rect_interior(l, l.fill, px0, py0, px1, py1)
  }
  let (fx0, fy0, fx1, fy1) = match interior {
    Some(b) => b
    None => (0, 0, 0, 0)
  }
  match interior {
    Some(_) =>
      match l.fill {
        @core.Fill::Solid(c) =>
          paint_solid_rect_interior(l, buf, c, eff_opacity, fx0, fy0, fx1, fy1)
        _ => ()
      }
    None => ()
  }
  // 位图源
  let img : @codec.RgbaBuf? = if l.kind is @core.ShapeKind::Image {
    env.assets.get(l.asset_hash)
  } else {
    None
  }
  // 取样色缓冲**循环外一份、每像素覆写**（原先每像素新建动态数组 + 4 次
  // push，容量还一路长）。每像素都恰好写满全部格，判据读的也是这些格。
  let sample_scratch : FixedArray[Int] = FixedArray::make(subsample_2x2.length(), 0)
  let mut py = py0
  while py < py1 {
    let mut px = px0
    while px < px1 {
      // 整块内部已经填过：同行的这一段直接跳过去（不逐像素空转）。
      if px >= fx0 && px < fx1 && py >= fy0 && py < fy1 {
        px = fx1
        continue
      }
      // 2×2 子采样。`mask_sum` 累加**每个样本的蒙版覆盖度**（与形状命中同一套
      // 样本），最后除以 4 折进覆盖度——蒙版不再是"循环外按中心乘一次"。
      let mut fill_hits = 0
      let mut stroke_hits = 0
      let mut mask_sum = 0.0
      let sample_colors = sample_scratch
      for i, s in subsample_2x2 {
        let (lx, ly) = canvas_to_layer(l, frames, px.to_double() + s.0, py.to_double() + s.1)
        // ⚠️ 蒙版与形状必须用**同一套子样本**，而且软覆盖要**按比例累加**、
        // 不能二值命中：羽化蒙版的 4 个样本覆盖 0.31/0.31/0.31/0.44 取"都在
        // 蒙版里 ⇒ 覆盖 1.0"就把羽化量化成了 0/0.25/0.5/0.75/1 五档——实测
        // (1,1) 会从 0xFFFFBFBF 变成满红。实测反例还有：软羽化下 (13,7) 的中心
        // 在蒙版外、子样本 (·,7.75) 在内，一处按中心一处按样本 ⇒ pick 与渲染
        // 打架（PLAN 五十六）。
        let mf_sample = mask_cover_at(l, lx, ly)
        if mf_sample <= 0.0 {
          sample_colors[i] = 0x00000000
          continue
        }
        let stroke_in = inside_stroke(l, lx, ly)
        if stroke_in {
          stroke_hits = stroke_hits + 1
          // 只有**形状真的命中**的样本才把蒙版覆盖算进这笔账（形状不在、
          // 蒙版在的样本，这个像素上本来就没有这一层的墨）
          mask_sum = mask_sum + mf_sample
          sample_colors[i] = l.stroke.color
        } else if inside_fill(l, lx, ly) {
          mask_sum = mask_sum + mf_sample
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
          sample_colors[i] = color
        } else {
          sample_colors[i] = 0x00000000
        }
      }
      let (cover, color) = subsample_result(fill_hits, stroke_hits, sample_colors)
      // 蒙版因子 = **命中样本**上覆盖度的平均（不是除以 4：除以 4 就把
      // "形状只命中一半"也算进蒙版账，同一个量乘两遍——实测无蒙版的 golden
      // 都变浅了）。没有形状命中的样本这个像素根本不合成。
      let hits = fill_hits + stroke_hits
      let mf = if hits > 0 { mask_sum / hits.to_double() } else { 1.0 }
      if cover > 0 && mf > 0.0 {
        // 蒙版因子先于合成融入源 alpha（蒙版外→源透明→下层透出）；
        // 折算本身在 `compose_src` 一处，与快速路径共用。
        let src = compose_src(cover, color, mf, eff_opacity)
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
  frames : Transform,
) -> Unit {
  if l.dabs.length() == 0 {
    return
  }
  let _ = env
  let scratch = @codec.rgba_new(buf.width, buf.height)
  // ⚠️ `rgba_new` 的初值是**不透明黑**（0xFF000000），所以"没写过的地方是 0"
  // 是错的——**要读的每一格都必须先清成透明**。旧实现清整幅、扫整幅：12MP 上
  // 一次渲染白扫 1200 万像素 ×2（一笔小笔触也一样）。现在只清/只扫
  // `paint_dabs` 回报的那个窗口——窗外从来没被写过、旧代码也是靠 `sa > 0` 跳过，
  // 所以输出**逐位相同**。
  // 窗口必须**先**算出来：scratch 初值是不透明黑，得先把自己要读的那块清成
  // 透明，再落笔（顺序反过来就是把刚画的笔迹擦掉——实测被 4 条测试当场抓住）。
  let (wx0, wy0, wx1, wy1) = match dabs_window(l, frames, buf.width, buf.height) {
    None => return // 一个 dab 都没落下：整层透明，连清零都不必
    Some(w) => w
  }
  let mut wy = wy0
  while wy < wy1 {
    let row = wy * scratch.width
    let mut wx = wx0
    while wx < wx1 {
      scratch.pixels[row + wx] = 0
      wx = wx + 1
    }
    wy = wy + 1
  }
  paint_dabs(l, frames, scratch, buf)
  // 合成：src alpha ← dab alpha × 层透明度 × 蒙版（只扫落笔窗口）
  let mut y = wy0
  while y < wy1 {
    let mut x = wx0
    while x < wx1 {
      let sp = scratch.pixels[y * buf.width + x]
      let sa = (sp >> 24) & 0xFF
      if sa > 0 {
        let (mf_x, mf_y) = canvas_to_layer(l, frames, x.to_double() + 0.5, y.to_double() + 0.5)
        let mf = mask_cover_at(l, mf_x, mf_y)
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
///|
/// 单个 dab 的落笔盒（夹到画布；空盒 = None）。**dab 盒只有这一处实现**：
/// `paint_dabs` 与 `dabs_window` 都调它。分开各算一遍的话，一旦漂移（比如以后
/// 把松弛从 ±1 改成 ±2），少的那个方向就是**静默被裁**——画面少一块而没有
/// 任何东西会红。⚠️ `.to_int()` 是截断（负数朝零），别改成 floor。
///
/// 吃的是 dab 的**画布中心**（`dab_center`，已含本层与祖先的全部变换）：
/// 圆斑旋转/镜像后还是同一个圆，所以盒 = 中心 ± (r+1) 对任何变换都**精确**
/// ——不需要按旋转放大盒子。⚠️ 中心必须在**画布**坐标里算：写成
/// `l.x + d.x` 就是把祖先组的旋转漏掉（实测 `rotate <组> 90` 而组里有笔触层时
/// 画面**逐位不变**，见 PLAN 五十八）。
fn dab_box(
  cx : Double,
  cy : Double,
  r : Double,
  w : Int,
  h : Int,
) -> (Int, Int, Int, Int)? {
  if r <= 0.0 {
    return None
  }
  let x0 = (cx - r).to_int() - 1
  let y0 = (cy - r).to_int() - 1
  let x1 = (cx + r).to_int() + 1
  let y1 = (cy + r).to_int() + 1
  let px0 = if x0 < 0 { 0 } else { x0 }
  let py0 = if y0 < 0 { 0 } else { y0 }
  let px1 = if x1 > w { w } else { x1 }
  let py1 = if y1 > h { h } else { y1 }
  if px1 <= px0 || py1 <= py0 {
    return None
  }
  Some((px0, py0, px1, py1))
}

///|
/// 一个 dab 的**画布中心**：dab 存的是**层局部**偏移（`d.x/d.y` 相对 `l.x/l.y`）。
/// **只有这一处**——`paint_dabs`、`dabs_window`、`pick` 三边都从它拿。
///
/// ① 层局部 → 父坐标系：**只平移**（`l.x + d.x`，与 `to_canvas` 在无 rot/flip 时
///    逐位相同）。⚠️ 这里**故意不**写成 `screen(l, frames, d.x, d.y)`
///    （= `to_canvas` + 祖先链）：笔触层的**本层** `rot`/`flip` 还不生效
///    （读点矩阵 `kind_only_fields` 里 raster 不在 `rotation_deg`/`flip_h`/
///    `flip_v` 的允许集合里——入口拒、`lint` 报），顺手把本层变换也算进来
///    就会让"渲染器不读它"变成假话，而入口又拒着 ⇒ 两个信号当面打架。
///    等笔触层自己的轴心也能落到**内容中心**那一天（盒子跟着内容走 +
///    每次渲染只算一遍有效盒），这一行才换成 `screen`（见 PLAN 五十八）。
/// ② 父坐标系 → 画布：整条**祖先链**（组）。⚠️ 漏掉这一步就是本轮修的 bug：
///    `rotate <组> 90` 而组里装着笔触层时，回包 `ok`、指纹变了，画面**逐位不变**。
fn dab_center(
  l : @core.Layer,
  frames : Transform,
  d : @core.Dab,
  pvx : Double,
  pvy : Double,
) -> (Double, Double) {
  // 局部偏移 →（本层 rot/flip，绕 `local_pivot`）→ 祖先链 → 画布。
  // ⚠️ 两段都必须有：本层这一段漏掉就是"给笔触层加 rotate 回 ok、指纹变、
  // 画面逐位不动"（PLAN 五十八那条的同族），祖先那一段漏掉是"组转了而墨迹
  // 不动"（上一轮修的那条）。`to_canvas_p` + `to_canvas_in` 正是一对。
  let (ox, oy) = to_canvas_p(l, d.x, d.y, pvx, pvy)
  to_canvas_in(frames, ox, oy)
}

///|
/// 全部 dab 的落笔窗口（非空盒的并）= **真正可能被写过的像素集合**。
/// `paint_raster` 用它决定清哪块、扫哪块：窗外从来没有被写过，旧实现也是靠
/// `sa > 0` 跳过，所以只扫这窗输出**逐位相同**。没有落笔 → None。
fn dabs_window(
  l : @core.Layer,
  frames : Transform,
  w : Int,
  h : Int,
) -> (Int, Int, Int, Int)? {
  let mut touched = false
  let mut wx0 = 0
  let mut wy0 = 0
  let mut wx1 = 0
  let mut wy1 = 0
  // 轴心遍历全部 dab（`raster_bbox`）⇒ 循环外算一次
  let (pvx, pvy) = local_pivot(l)
  for d in l.dabs {
    let (cx, cy) = dab_center(l, frames, d, pvx, pvy)
    match dab_box(cx, cy, d.r, w, h) {
      None => continue
      Some((px0, py0, px1, py1)) => {
        if touched {
          if px0 < wx0 {
            wx0 = px0
          }
          if py0 < wy0 {
            wy0 = py0
          }
          if px1 > wx1 {
            wx1 = px1
          }
          if py1 > wy1 {
            wy1 = py1
          }
        } else {
          touched = true
          wx0 = px0
          wy0 = py0
          wx1 = px1
          wy1 = py1
        }
      }
    }
  }
  if touched {
    Some((wx0, wy0, wx1, wy1))
  } else {
    None
  }
}

///|
///|
/// 克隆笔触的源取样：把落点周围 4 个子样本各自对应的**源像素**取出来，按
/// **预乘**平均（不预乘的话，源里透明像素那三个通道的值会被平均进来，边缘出现
/// 黑边/彩边），返回（去预乘后的颜色, 平均源 alpha）。
///
/// 源就是"本层之下那张合成缓冲"（顶层就是画布合成结果连同白底），**画布坐标**
/// ⇒ 落点的画布坐标由 `dab_center` 给出、源偏移也是画布坐标，旋转/翻转过的层
/// 照样对得上。取样点出缓冲的样本按"那里什么都没有"（透明）跳过。
fn clone_sample(
  src_buf : @codec.RgbaBuf,
  d : @core.Dab,
  px : Int,
  py : Int,
) -> (Int, Double) {
  let mut sum_a = 0.0
  let mut sum_r = 0.0
  let mut sum_g = 0.0
  let mut sum_b = 0.0
  let mut n = 0
  for s in dab_samples {
    let sx = (px.to_double() + s.0 + d.sdx).floor().to_int()
    let sy = (py.to_double() + s.1 + d.sdy).floor().to_int()
    if sx >= 0 && sy >= 0 && sx < src_buf.width && sy < src_buf.height {
      let p = src_buf.pixels[sy * src_buf.width + sx]
      let a = ((p >> 24) & 0xFF).to_double() / 255.0
      sum_a = sum_a + a
      sum_r = sum_r + ((p >> 16) & 0xFF).to_double() * a
      sum_g = sum_g + ((p >> 8) & 0xFF).to_double() * a
      sum_b = sum_b + (p & 0xFF).to_double() * a
      n = n + 1
    }
  }
  if n == 0 || sum_a <= 0.0 {
    // 取样点全在缓冲外、或源全透明：这一笔没有颜色可取（合成时 alpha=0 ⇒ 不落墨）
    return (0x00000000, 0.0)
  }
  let cnt = n.to_double()
  let rgb = ((sum_r / sum_a + 0.5).to_int() << 16) +
    ((sum_g / sum_a + 0.5).to_int() << 8) +
    (sum_b / sum_a + 0.5).to_int()
  (0xFF000000 + rgb, sum_a / cnt)
}

///|
fn paint_dabs(
  l : @core.Layer,
  frames : Transform,
  scratch : @codec.RgbaBuf,
  src_buf : @codec.RgbaBuf,
) -> Unit {
  // 轴心遍历全部 dab ⇒ 循环外算一次（`local_pivot` 那条注释）
  let (pvx, pvy) = local_pivot(l)
  for d in l.dabs {
    let (cx, cy) = dab_center(l, frames, d, pvx, pvy)
    let (px0, py0, px1, py1) = match dab_box(cx, cy, d.r, scratch.width, scratch.height) {
      None => continue
      Some(b) => b
    }
    let r2 = d.r * d.r
    // 橡皮擦不受笔色 alpha 影响（恒全强度）；**克隆笔也不读笔色**——它的浓度
    // 来自源像素自己的 alpha 与层不透明度，而命令面给克隆的 `color` 是全 0
    // ⇒ 照读就是"覆盖度恒 0、整笔一个像素都不落"（实测：`clone` 回 ok、
    // 报告面认账、画面逐位不变——静默失败里最难查的那一种）。
    // 画笔才读 AA 通道当落点浓度。
    let dalpha = if d.erase || d.clone {
      1.0
    } else {
      ((d.color >> 24) & 0xFF).to_double() / 255.0
    }
    let mut py = py0
    while py < py1 {
      let mut px = px0
      while px < px1 {
        let mut hits = 0
        for s in dab_samples {
          let sx = px.to_double() + s.0 - cx
          let sy = py.to_double() + s.1 - cy
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
            // 非克隆：源色就是笔色、源 alpha 恒 1（乘 1.0 逐位不变 ⇒ 老画面不动）
            let (sc, sa_src) = if d.clone {
              clone_sample(src_buf, d, px, py)
            } else {
              (d.color, 1.0)
            }
            let sa = cover * sa_src
            let a255 = (sa * 255.0 + 0.5).to_int()
            if a255 > 0 {
              // 简单 over 合成（同一层内笔迹自叠）
              let da = ((dst >> 24) & 0xFF).to_double() / 255.0
              let oa = sa + da * (1.0 - sa)
              if oa > 0.0 {
                let sr = ((dst >> 16) & 0xFF).to_double() / 255.0
                let sg = ((dst >> 8) & 0xFF).to_double() / 255.0
                let sb = (dst & 0xFF).to_double() / 255.0
                let cr = (sc >> 16) & 0xFF
                let cg = (sc >> 8) & 0xFF
                let cb = sc & 0xFF
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
    // ②B 滤镜：这四个要读**邻域/整块**（拖影、缩放取样、色块平均、逐像素噪声），
    // 走专用实现；海报化/阈值/色相饱和度/色彩平衡只读自己那个像素 ⇒ 留在
    // `adjust_pixel` 那条路上（蒙版混合、scratch 路径都不用再写一遍）。
    @core.AdjustOp::MotionBlur => apply_motion_blur(buf, adj)
    @core.AdjustOp::RadialBlur => apply_radial_blur(buf, adj)
    @core.AdjustOp::Noise => apply_noise(buf, adj)
    @core.AdjustOp::Pixelate => apply_pixelate(buf, adj)
    _ => apply_adjust_pixel(adj, buf)
  }
}

///|
/// 蒙版**支撑窗**（覆盖度可能 > 0 的像素范围，左闭右开、已夹到画布）。
/// 保守取法：蒙版 bbox 外扩 `roughen`（毛边的噪声偏移最多能把覆盖度甩出形状
/// `roughen` 个像素），`invert`（区域无界）与退化蒙版（w/h ≤ 0）一律退回整幅。
fn mask_support_box(l : @core.Layer, buf : @codec.RgbaBuf) -> (Int, Int, Int, Int) {
  let all = (0, 0, buf.width, buf.height)
  let m = match l.mask {
    Some(m) => m
    None => return all
  }
  if m.invert || m.w <= 0.0 || m.h <= 0.0 {
    return all
  }
  let slack = m.roughen.ceil() + 1.0
  // 蒙版盒是**本层局部**坐标（`mask_cover_at` 那一套），而这个窗是**画布**像素窗
  // （循环遍历 `buf`）⇒ 两个角经正变换换算过去。旋转/翻转下四角外接盒只是保守
  // 上界（窗大一点只多花时间，覆盖度仍由 `mask_cover_at` 逐点精确算），
  // 而窗小了才会**静默漏掉**蒙版该管的那块像素。
  let (cx0, cy0) = to_canvas(l, m.x - slack, m.y - slack)
  let (cx1, cy1) = to_canvas(l, m.x + m.w + slack, m.y + m.h + slack)
  let (wx0, wx1) = if cx0 < cx1 { (cx0, cx1) } else { (cx1, cx0) }
  let (wy0, wy1) = if cy0 < cy1 { (cy0, cy1) } else { (cy1, cy0) }
  (
    clamp_int(wx0.floor(), 0, buf.width),
    clamp_int(wy0.floor(), 0, buf.height),
    clamp_int(wx1.ceil(), 0, buf.width),
    clamp_int(wy1.ceil(), 0, buf.height),
  )
}

///|
/// 施加调整层 —— **蒙版在这里生效**。
///
/// * 没有蒙版：逐位等于原来的 `apply_adjust`（整幅、就地），既有文档与 golden
///   一个像素都不动；
/// * 有蒙版：`p' = lerp(p, op(p), cover)`，复用编辑表那句唯一的软混合原语
///   `@pixel.lerp_argb`（软权重只有一处实现，编辑表与蒙版不分叉）。覆盖度恰好
///   1 的地方走 `op(p)` 直通，所以"蒙版盖满整幅"与"没有蒙版"逐位相同（有测试
///   钉住这一条）。
///
/// ⚠️ 邻域算子（blur/sharpen/smooth）的结果要读**原**缓冲的邻居，就地做会把
/// 已经改过的像素当成邻居；暗角（vignette）虽然只看位置，但走同一条路才不用
/// 维护第二张"哪些算子是邻域"的清单。所以带蒙版时一律先在 scratch 上整幅算完、
/// 再按覆盖度混合：代价是一次整幅拷贝（12MP ≈ 48MB），**只在"带蒙版的调整层"
/// 这条路上付**，而混合本身只扫蒙版支撑窗。
fn apply_adjust_layer(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  eff_opacity : Double,
  frames : Transform,
) -> Unit {
  if l.adjust is None || eff_opacity <= 0.0 {
    return
  }
  // 快路径：全强度且没有蒙版 ⇒ 就地施加（与"没有软混合"逐位相同的代码路径）
  if eff_opacity >= 1.0 && l.mask is None {
    apply_adjust(l.adjust, buf)
    return
  }
  let (wx0, wy0, wx1, wy1) = mask_support_box(l, buf)
  if wx1 <= wx0 || wy1 <= wy0 {
    return
  }
  let scratch = @codec.rgba_new(buf.width, buf.height)
  let total = buf.width * buf.height
  let mut i = 0
  while i < total {
    scratch.pixels[i] = buf.pixels[i]
    i = i + 1
  }
  apply_adjust(l.adjust, scratch)
  // 蒙版的读点要经本层的逆变换，而笔触层的轴心来自**落笔范围**（要遍历全部
  // dab）——所以在循环外算**一次**，别放进逐像素路径（PLAN 五十九那条）。
  let (pvx, pvy) = local_pivot(l)
  let mut y = wy0
  while y < wy1 {
    let mut x = wx0
    while x < wx1 {
      // 软强度 = 蒙版覆盖度 × 有效不透明度。**两件事乘在同一个数上**：
      // "蒙版半覆盖"与"α 一半"必须给出逐位相同的画面（测试钉住这条恒等式）。
      // 没有蒙版时覆盖度恒为 1（不是"跳过混合"）。
      let cover = match l.mask {
        Some(_) => {
          let (mf_x, mf_y) = canvas_to_layer_p(l, frames, x.to_double() + 0.5, y.to_double() + 0.5, pvx, pvy)
          mask_cover_at(l, mf_x, mf_y)
        }
        None => 1.0
      }
      let strength = cover * eff_opacity
      if strength > 0.0 {
        let at = y * buf.width + x
        let p = buf.pixels[at]
        let op = scratch.pixels[at]
        buf.pixels[at] = if strength >= 1.0 { op } else { @pixel.lerp_argb(p, op, strength) }
      }
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// **色阶的 256 项查找表**（`Levels` 的语义只有这一处实现，与 `core` 的文档
/// 注释逐字对应）：
///   `v' = clamp01((v - in_lo) / (in_hi - in_lo))`；`v'' = v'^(1/gamma)`；
///   `out = out_lo + v'' * (out_hi - out_lo)`
/// 三个通道用同一张表（色阶是逐通道同一条曲线），α 不动。
fn levels_lut(lv : @core.Levels) -> Array[Int] {
  let out : Array[Int] = []
  let span = lv.in_hi - lv.in_lo
  let mut i = 0
  while i < 256 {
    let v = i.to_double() / 255.0
    let t0 = (v - lv.in_lo) / span
    let t = if t0 < 0.0 { 0.0 } else if t0 > 1.0 { 1.0 } else { t0 }
    let g = @math.pow(t, 1.0 / lv.gamma)
    let o = lv.out_lo + g * (lv.out_hi - lv.out_lo)
    out.push(clamp8((o * 255.0 + 0.5).to_int()))
    i = i + 1
  }
  out
}

///|
/// **单调三次（PCHIP / Fritsch–Carlson）**曲线求值：控制点表 → `x` 处的 `y`。
///
/// 为什么不用普通三次样条：样条会**过冲**——把某个亮度拉高，邻近亮度会被压出
/// 一个坑（画面里就是"调完曲线反而脏了"）。单调插值保证"控制点单调则输出单调"。
/// 区间外用端点值**钳住**（与 PS 的"曲线不到边"一致）。
pub fn curve_map(pts : Array[(Double, Double)], x : Double) -> Double {
  let n = pts.length()
  if n == 0 {
    return x
  }
  if n == 1 {
    return pts[0].1
  }
  if x <= pts[0].0 {
    return pts[0].1
  }
  if x >= pts[n - 1].0 {
    return pts[n - 1].1
  }
  // 段斜率 d_i 与节点斜率 m_i
  let h : Array[Double] = []
  let d : Array[Double] = []
  let mut i = 0
  while i + 1 < n {
    let hi = pts[i + 1].0 - pts[i].0
    h.push(hi)
    d.push((pts[i + 1].1 - pts[i].1) / hi)
    i = i + 1
  }
  let m : Array[Double] = []
  m.push(d[0])
  let mut k = 1
  while k + 1 < n {
    let d0 = d[k - 1]
    let d1 = d[k]
    if d0 * d1 <= 0.0 {
      // 极值点：斜率取 0（这正是"不过冲"的来源）
      m.push(0.0)
    } else {
      let w1 = 2.0 * h[k] + h[k - 1]
      let w2 = h[k] + 2.0 * h[k - 1]
      m.push((w1 + w2) / (w1 / d0 + w2 / d1))
    }
    k = k + 1
  }
  m.push(d[n - 2])
  // 找到 x 落在哪一段
  let mut seg = 0
  while seg + 2 < n && x > pts[seg + 1].0 {
    seg = seg + 1
  }
  let hs = h[seg]
  let t = (x - pts[seg].0) / hs
  let t2 = t * t
  let t3 = t2 * t
  let h00 = 2.0 * t3 - 3.0 * t2 + 1.0
  let h10 = t3 - 2.0 * t2 + t
  let h01 = -2.0 * t3 + 3.0 * t2
  let h11 = t3 - t2
  let y = h00 * pts[seg].1 + h10 * hs * m[seg] + h01 * pts[seg + 1].1 + h11 * hs * m[seg + 1]
  if y < 0.0 {
    0.0
  } else if y > 1.0 {
    1.0
  } else {
    y
  }
}

///|
/// 曲线的 256 项查找表（与色阶同规：三通道一张表、α 不动）。
fn curve_lut(pts : Array[(Double, Double)]) -> Array[Int] {
  let out : Array[Int] = []
  let mut i = 0
  while i < 256 {
    let y = curve_map(pts, i.to_double() / 255.0)
    out.push(clamp8((y * 255.0 + 0.5).to_int()))
    i = i + 1
  }
  out
}

///|
/// 逐像素查表类算子的 LUT（整幅只算一次）。缓冲区变换类（模糊/锐化/磨皮/暗角）
/// 返回 `None`——它们在自己的分支里做。
fn adjust_map(adj : @core.Adjust) -> Array[Int]? {
  match adj.op {
    @core.AdjustOp::Levels =>
      match adj.levels {
        Some(lv) => Some(levels_lut(lv))
        None => None
      }
    @core.AdjustOp::Curves => if adj.curve.length() >= 2 {
      Some(curve_lut(adj.curve))
    } else {
      None
    }
    _ => None
  }
}

///|
/// **曲线采样**（面板画预览用）：在 `x = i/(n-1)` 处取引擎算出的 y。
/// 预览与渲染**共用** `curve_map` 一处——前端自己插值就会画出一条与画面不符的线。
pub fn curve_sample(pts : Array[(Double, Double)], n : Int) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  if n <= 0 {
    return out
  }
  let mut i = 0
  while i < n {
    let x = if n == 1 { 0.0 } else { i.to_double() / (n - 1).to_double() }
    out.push((x, curve_map(pts, x)))
    i = i + 1
  }
  out
}

///|
/// 单个像素的点位算子结果（纯函数）：整幅路径与上面那条蒙版路径共用**这一处**，
/// 所以两条路的数值不可能分叉。
fn adjust_pixel(adj : @core.Adjust, lut : Array[Int]?, p : Int) -> Int {
  let r = (p >> 16) & 0xFF
  let g = (p >> 8) & 0xFF
  let b = p & 0xFF
  // 查表类（色阶/曲线）：三通道同一张表
  match lut {
    Some(t) =>
      if t.length() == 256 {
        return (p & 0xFF000000) + (t[r] << 16) + (t[g] << 8) + t[b]
      }
    None => ()
  }
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
    // ---- ②B 滤镜（逐像素那一半；参数语义见 core.filter_param_rows 的表）----
    // 海报化：每通道量化到 `levels` 级（levels=2 ⇒ 只有 0/255）
    @core.AdjustOp::Posterize => {
      let levels = filter_d(adj, "levels", 2.0)
      let step = 255.0 / (levels - 1.0)
      (posterize_ch(r, step), posterize_ch(g, step), posterize_ch(b, step))
    }
    // 阈值：跟 `channel` 选的那个量比（0=R 1=G 2=B 3=luma），出纯黑白
    @core.AdjustOp::Threshold => {
      let level = clamp01(filter_d(adj, "level", 0.5)) * 255.0
      let src = match clamp_int(filter_d(adj, "channel", 3.0).floor(), 0, 3) {
        0 => r
        1 => g
        2 => b
        _ => (r * 30 + g * 59 + b * 11) / 100
      }
      let v = if src.to_double() >= level { 255 } else { 0 }
      (v, v, v)
    }
    // 色相/饱和度/明度：在 **OKLCh** 里做（与选择子同一套坐标，不引入第三套：
    // 色相转角度、彩度乘 (1+sat)（-1⇒全灰）、明度向 1 或 0 压。
    // 超出色域由 `oklab_to_argb` 的 gamut compress 收尾）。
    @core.AdjustOp::HueSat => {
      let hue = filter_d(adj, "hue", 0.0)
      let sat = filter_d(adj, "sat", 0.0)
      let light = filter_d(adj, "light", 0.0)
      // 中性参数 = **逐位不变**（显式短路，不靠浮点尾差的运气）：`filter_is_noop`
      // 那句"画面逐位不变"会被 `lint` 当事实说给调用方听，所以它必须是**保证**。
      // 实测（一次性 24-bit 全色域扫描，见 PLAN 七十八）：拿掉这段短路走 OKLab
      // 往返，16,777,216 个颜色里 0 个字节不同——8-bit 量化把浮点尾差吃干净了。
      // 也就是说这段短路**行为等价**（变异 R131 因此申报为等价），留下它是为了
      // 让这句承诺不依赖"量化恰好每次都吃得住"，并且省掉一次无用往返。
      if hue == 0.0 && sat == 0.0 && light == 0.0 {
        (r, g, b)
      } else {
      let lch = @pixel.oklab_to_oklch(@pixel.argb_to_oklab(p))
      let mut h2 = lch.h + hue
      while h2 < 0.0 {
        h2 = h2 + 360.0
      }
      while h2 >= 360.0 {
        h2 = h2 - 360.0
      }
      let c2 = lch.c * (1.0 + sat)
      let l2 = if light < 0.0 { lch.l * (1.0 + light) } else { lch.l + (1.0 - lch.l) * light }
      let out = @pixel.oklab_to_argb(
        @pixel.oklch_to_oklab({ l: l2, c: c2, h: h2 }),
        (p >> 24) & 0xFF,
      )
      ((out >> 16) & 0xFF, (out >> 8) & 0xFF, out & 0xFF)
      }
    }
    // 色彩平衡：三通道各均匀加减（±100 级 = 满量程约 40%）。
    // **边界（丐版）**：PS 的"阴影/中间调/高光"三段与"保持亮度"没做，只有整幅均匀加减。
    @core.AdjustOp::ColorBalance => (
      clamp8(r + round_i(filter_d(adj, "cr", 0.0) * 100.0)),
      clamp8(g + round_i(filter_d(adj, "cg", 0.0) * 100.0)),
      clamp8(b + round_i(filter_d(adj, "cb", 0.0) * 100.0)),
    )
    _ => (r, g, b)
  }
  (p & 0xFF000000) + (pair.0 << 16) + (pair.1 << 8) + pair.2
}

///|
fn apply_adjust_pixel(adj : @core.Adjust, buf : @codec.RgbaBuf) -> Unit {
  // LUT **在循环外算一次**（色阶/曲线是查表类；256 项里每一项都过一遍幂函数/
  // 三次插值，逐像素重算等于把整幅的开销乘 256）
  let lut = adjust_map(adj)
  let total = buf.width * buf.height
  let mut i = 0
  while i < total {
    buf.pixels[i] = adjust_pixel(adj, lut, buf.pixels[i])
    i = i + 1
  }
}

///|
/// ②B 滤镜的**采样上限**（能力上限，必须写出来）：动感/径向模糊各取
/// `FILTER_BLUR_SAMPLES` 个样本均匀铺满拖影范围——半径 ≤ 12px 时步长 ≤ 1px
/// （等于逐像素积分），更长的拖影就是**采样平均**（步长 > 1px，可能漏细节）。
/// 上限存在的理由是代价：12MP 上每像素 25 次取样已经 ≈ 3 亿次采样。
const FILTER_BLUR_SAMPLES : Int = 25

///|
/// 半径上限（与 `core.filter_param_rows` 的上界一致；容器里的坏值在这里兜底）。
const FILTER_BLUR_MAX_RADIUS : Double = 64.0

///|
/// 从调整层的参数表里取一个数（缺了用**中性值**——中性值表在 core，不在这里
/// 再写一份默认值；容器读入端已经拦过缺键，这里只兜"渲染器被喂了残缺 adj"）。
fn filter_d(adj : @core.Adjust, key : String, dflt : Double) -> Double {
  match @core.filter_param_value(adj.params, key) {
    Some(v) => v
    None => dflt
  }
}

///|
/// 平均值量化（拖影/缩放的累加器收尾）：round-half-up 后夹 0..255。
fn quant_avg(sum : Double, inv : Double) -> Int {
  let q = sum * inv + 0.5
  if q < 0.0 {
    0
  } else if q > 255.0 {
    255
  } else {
    q.to_int()
  }
}

///|
/// 缓冲区整幅拷贝（邻域算子要读**原**图；就地读会把改过的像素当邻居）。
fn clone_rgba(buf : @codec.RgbaBuf) -> @codec.RgbaBuf {
  let out = @codec.rgba_new(buf.width, buf.height)
  let total = buf.width * buf.height
  let mut i = 0
  while i < total {
    out.pixels[i] = buf.pixels[i]
    i = i + 1
  }
  out
}

///|
/// 海报化的单通道量化：`round(round(v/step)*step)`（step = 255/(levels-1)）。
fn posterize_ch(v : Int, step : Double) -> Int {
  clamp8(round_i((v.to_double() / step + 0.5).floor() * step))
}

///|
/// **确定性噪声**（②B）：`(x,y,salt)` → [-1,1]。不能用随机数（铁律 7：渲染
/// sha256 必须可复现），所以是一个纯整数散列——同样的坐标永远同样的噪声，
/// 于是"同一份文档渲染两次逐位相同"这条不变量对噪点层也成立。
fn noise_hash(x : Int, y : Int, salt : Int) -> Double {
  let mut h : Int64 = x.to_int64() * 374761393L + y.to_int64() * 668265263L +
    salt.to_int64() * 2246822519L
  h = (h ^ (h >> 13)) * 1274126177L
  h = h ^ (h >> 16)
  let u = (h & 0xFFFFL).to_double() / 65535.0
  u * 2.0 - 1.0
}

///|
/// 动感模糊（②B）：沿 `angle` 方向、长度 `±radius` 的**均匀采样平均**。
/// 采样数上限见 `FILTER_BLUR_SAMPLES`；取样点夹到画布内（边缘像素重复，与
/// PS 的"重复边缘像素"同口径）。alpha 一起平均（拖影会把透明区拖进来）。
fn apply_motion_blur(buf : @codec.RgbaBuf, adj : @core.Adjust) -> Unit {
  if buf.width <= 0 || buf.height <= 0 {
    return
  }
  let radius = filter_d(adj, "radius", 0.0)
  if radius <= 0.0 {
    return
  }
  let r = if radius > FILTER_BLUR_MAX_RADIUS { FILTER_BLUR_MAX_RADIUS } else { radius }
  let rad = filter_d(adj, "angle", 0.0) * 3.141592653589793 / 180.0
  let dx = cos_rad(rad)
  let dy = sin_rad(rad)
  let src = clone_rgba(buf)
  let n = FILTER_BLUR_SAMPLES
  let last = (n - 1).to_double()
  let inv = 1.0 / n.to_double()
  let mut y = 0
  while y < buf.height {
    let mut x = 0
    while x < buf.width {
      let mut sa = 0.0
      let mut sr = 0.0
      let mut sg = 0.0
      let mut sb = 0.0
      let mut j = 0
      while j < n {
        let t = -r + 2.0 * r * j.to_double() / last
        let sx = clamp_int((x.to_double() + dx * t).floor(), 0, buf.width - 1)
        let sy = clamp_int((y.to_double() + dy * t).floor(), 0, buf.height - 1)
        let p = src.pixels[sy * buf.width + sx]
        sa = sa + ((p >> 24) & 0xFF).to_double()
        sr = sr + ((p >> 16) & 0xFF).to_double()
        sg = sg + ((p >> 8) & 0xFF).to_double()
        sb = sb + (p & 0xFF).to_double()
        j = j + 1
      }
      buf.pixels[y * buf.width + x] = (quant_avg(sa, inv) << 24) + (quant_avg(sr, inv) << 16) +
        (quant_avg(sg, inv) << 8) + quant_avg(sb, inv)
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// 径向模糊（②B，"缩放"型）：以 `center` 为中心沿射线取样，最外层样本的缩放
/// 系数 = `1 + radius/64 × 0.25`（radius=64 时 25%）。
/// **越靠边拖影越强**：混合权重 = 该点到中心距离 / 最远角距（中心逐位不动）。
fn apply_radial_blur(buf : @codec.RgbaBuf, adj : @core.Adjust) -> Unit {
  if buf.width <= 0 || buf.height <= 0 {
    return
  }
  let radius = filter_d(adj, "radius", 0.0)
  if radius <= 0.0 {
    return
  }
  let r = if radius > FILTER_BLUR_MAX_RADIUS { FILTER_BLUR_MAX_RADIUS } else { radius }
  let k = r / FILTER_BLUR_MAX_RADIUS * 0.25
  let cx = filter_d(adj, "center_x", 0.5) * buf.width.to_double()
  let cy = filter_d(adj, "center_y", 0.5) * buf.height.to_double()
  // 最远角距（权重分母）：四个角里离中心最远的那个
  let w = buf.width.to_double()
  let hh = buf.height.to_double()
  let d00 = radial_dist(cx, cy, 0.0, 0.0)
  let d10 = radial_dist(cx, cy, w, 0.0)
  let d01 = radial_dist(cx, cy, 0.0, hh)
  let d11 = radial_dist(cx, cy, w, hh)
  let mut maxd = d00
  if d10 > maxd {
    maxd = d10
  }
  if d01 > maxd {
    maxd = d01
  }
  if d11 > maxd {
    maxd = d11
  }
  let src = clone_rgba(buf)
  let n = FILTER_BLUR_SAMPLES
  let last = (n - 1).to_double()
  let inv = 1.0 / n.to_double()
  let mut y = 0
  while y < buf.height {
    let mut x = 0
    while x < buf.width {
      let px = x.to_double() + 0.5
      let py = y.to_double() + 0.5
      let vx = px - cx
      let vy = py - cy
      let mut sa = 0.0
      let mut sr = 0.0
      let mut sg = 0.0
      let mut sb = 0.0
      let mut j = 0
      while j < n {
        let s = 1.0 + k * j.to_double() / last
        let sx = clamp_int((cx + vx * s).floor(), 0, buf.width - 1)
        let sy = clamp_int((cy + vy * s).floor(), 0, buf.height - 1)
        let p = src.pixels[sy * buf.width + sx]
        sa = sa + ((p >> 24) & 0xFF).to_double()
        sr = sr + ((p >> 16) & 0xFF).to_double()
        sg = sg + ((p >> 8) & 0xFF).to_double()
        sb = sb + (p & 0xFF).to_double()
        j = j + 1
      }
      let at = y * buf.width + x
      let avg = (quant_avg(sa, inv) << 24) + (quant_avg(sr, inv) << 16) +
        (quant_avg(sg, inv) << 8) + quant_avg(sb, inv)
      let t = if maxd <= 0.0 { 0.0 } else { clamp01(radial_dist(cx, cy, px, py) / maxd) }
      buf.pixels[at] = if t <= 0.0 { buf.pixels[at] } else { @pixel.lerp_argb(buf.pixels[at], avg, t) }
      x = x + 1
    }
    y = y + 1
  }
}

///|
fn radial_dist(cx : Double, cy : Double, x : Double, y : Double) -> Double {
  let dx = x - cx
  let dy = y - cy
  Double::sqrt(dx * dx + dy * dy)
}

///|
/// 噪点（②B）：逐像素确定性噪声。`mono` 是**连续**的混音（0=每个通道各自
/// 一条噪声、1=三通道共用一条；中间值就是两者的插值），不是布尔开关——
/// 布尔化的参数会有"0.3 被悄悄当成 0"的静默语义。
fn apply_noise(buf : @codec.RgbaBuf, adj : @core.Adjust) -> Unit {
  let amount = clamp01(filter_d(adj, "amount", 0.0))
  if amount <= 0.0 {
    return
  }
  let mono = clamp01(filter_d(adj, "mono", 0.0))
  // ±64 级是满强度噪声的幅度（与 PS 的"数量 100%"量级接近）
  let amp = amount * 64.0
  let mut y = 0
  while y < buf.height {
    let mut x = 0
    while x < buf.width {
      let at = y * buf.width + x
      let p = buf.pixels[at]
      let nm = noise_hash(x, y, 7)
      let dr = (1.0 - mono) * noise_hash(x, y, 0) + mono * nm
      let dg = (1.0 - mono) * noise_hash(x, y, 1) + mono * nm
      let db = (1.0 - mono) * noise_hash(x, y, 2) + mono * nm
      let r = (p >> 16) & 0xFF
      let g = (p >> 8) & 0xFF
      let b = p & 0xFF
      buf.pixels[at] = (p & 0xFF000000) + (clamp8(r + round_i(amp * dr)) << 16) +
        (clamp8(g + round_i(amp * dg)) << 8) + clamp8(b + round_i(amp * db))
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// 像素化（②B）：把画布切成 `size × size` 的色块，每块取块内**原图**平均
/// （含 alpha；不预乘——与 PS 的"平均"同口径是"未预乘平均"，这里按引擎的
/// 直通字节平均，边界块只平均画布内的像素）。
fn apply_pixelate(buf : @codec.RgbaBuf, adj : @core.Adjust) -> Unit {
  if buf.width <= 0 || buf.height <= 0 {
    return
  }
  // 手改容器可能是 1/0：至少按 2 走（"装了却什么都不干"由 lint 报，不在这里静默）
  let size = clamp_int(filter_d(adj, "size", 2.0).floor(), 2, 256)
  let src = clone_rgba(buf)
  let mut by = 0
  while by < buf.height {
    let mut bx = 0
    while bx < buf.width {
      let x1 = if bx + size > buf.width { buf.width } else { bx + size }
      let y1 = if by + size > buf.height { buf.height } else { by + size }
      let mut sa = 0
      let mut sr = 0
      let mut sg = 0
      let mut sb = 0
      let mut count = 0
      let mut yy = by
      while yy < y1 {
        let mut xx = bx
        while xx < x1 {
          let p = src.pixels[yy * buf.width + xx]
          sa = sa + ((p >> 24) & 0xFF)
          sr = sr + ((p >> 16) & 0xFF)
          sg = sg + ((p >> 8) & 0xFF)
          sb = sb + (p & 0xFF)
          count = count + 1
          xx = xx + 1
        }
        yy = yy + 1
      }
      if count > 0 {
        let inv = 1.0 / count.to_double()
        let avg = (quant_avg(sa.to_double(), inv) << 24) + (quant_avg(sr.to_double(), inv) << 16) +
          (quant_avg(sg.to_double(), inv) << 8) + quant_avg(sb.to_double(), inv)
        let mut y2 = by
        while y2 < y1 {
          let mut x2 = bx
          while x2 < x1 {
            buf.pixels[y2 * buf.width + x2] = avg
            x2 = x2 + 1
          }
          y2 = y2 + 1
        }
      }
      bx = bx + size
    }
    by = by + size
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
  colors : FixedArray[Int],
) -> (Int, Int) {
  let hits = fill_hits + stroke_hits
  if hits == 0 {
    return (0, 0x00000000)
  }
  let mut color = 0x00000000
  let mut got = false
  // 第一个不透明样本（stroke 优先已按序写格）。原先这里还有一个**空体循环**
  // （`if … { }`，什么都不做），每个像素白跑 4 次——顺手删掉。
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
/// 一个算子**真正被施加在哪张图、选择子在哪张图上求值**的事实（逐算子阶段）。
///
/// 存在的理由：编辑表有两条语义路径——文档级算子作用在**合成底图**上，而
/// `layer=` 算子作用在**该层自己的栅格**上（选择子也在那里求值）。分析类
/// 出口（`mvsl-impact` 的逐算子 diff、`mvsl-assert`/`lint` 的断言判定、
/// `probe` 的逐算子 membership）必须量的是**真渲染的那一步**，否则它们会
/// 拿合成底图上的近似值去描述一次根本不在那里发生的编辑（实测：`layer=l1`
/// 的表被报成"整幅 512 像素都改了"，而真渲染只改那一层的 256 个。
/// 更糟的是保护断言会在错的图上判定，安全网变成假安心）。
///
/// `basis` 是**该算子选择子的求值基底**（层栅格或合成底图），
/// `before`/`after` 是它在**同一条基线**上的前后缓冲——三者在同一个坐标系
/// （都是整幅画布尺寸的缓冲），所以既能逐算子做 diff，也能把某条算子的
/// 权重场搬到"整表支撑集"里求并。
pub(all) struct ImpactStage {
  op : @core.EditOp
  /// "" = 文档级；否则是**具体**层 id（`layer=@tag` 在这里已经展开）
  layer : String
  basis : @codec.RgbaBuf
  before : @codec.RgbaBuf
  after : @codec.RgbaBuf
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
///
/// **实现上它就是 `impact_stages` 的最终图那一半**：渲染与分析共用同一段
/// 执行代码，于是"分析出口量的是真渲染那一步"是构造性成立的，而不是靠
/// 两处各自小心（本仓库的旧账：同一个判断两处实现，先烂的一定是没人读的
/// 那处）。
///|
/// 渲染侧的编辑表规模闸：把文档画布与表交给 `@core.edit_cost_error`。
///
/// 单独一个小函数是为了让"画布尺寸从哪里取"只有一处说法（`doc.width`/
/// `doc.height`），而不是在渲染函数里散着算。
fn edit_cost_refusal(doc : @core.Document, prog : @core.EditProgram) -> String? {
  let e = @core.edit_cost_error(prog, doc.width, doc.height)
  if e == "" {
    None
  } else {
    Some(e)
  }
}

///|
pub fn render_doc_with(
  doc : @core.Document,
  env : RenderEnv,
  prog : @core.EditProgram,
) -> Result[@codec.RgbaBuf, String] {
  match impact_stages(doc, env, prog) {
    Ok(pair) => Ok(pair.1)
    Err(e) => Err(e)
  }
}

///|
/// 真渲染管线的**逐算子阶段**（渲染与分析出口的唯一实现）。
///
/// 返回 `(阶段数组, 最终图)`。
///
///   * 不含 `layer=` 算子 → 单段：合成底图 → 逐算子应用。这是与老路径
///     **逐位相同**的那条（`run_program` 的 bit-exact 契约），保留它是因为
///     既有 golden 与 open→save 断言都钉在这条路径上；
///   * 含 `layer=` 算子 → **两段式**：
///     1. 被引用的层各自栅格化到透明底，只施加"属于它的算子"——选择子因此在
///        **该层自己的栅格**上求值，这正是"只改这一层"的关键（合成底图上做
///        不到：那里前景与背景已经乘在一起了）；
///     2. 按原顺序合成：被改的层用改后的栅格，其余层照旧直接画；
///     3. 再对合成底图施加**文档级**算子。
///
/// 每个阶段的 `before`/`after` 都在它自己那条基线（层栅格 或 合成底图）上，
/// `basis` 是该算子选择子的求值基底。逐算子的口径因此与渲染器**逐位一致**：
/// 层算子的 diff 在层栅格上算，文档级算子的 diff 在合成图上算。
///
/// 段间顺序说明（DESIGN §8 已声明的边界）：两段式下**跨作用域的相对顺序不
/// 保留**——一条文档级算子无法插在两条图层级算子中间，所以阶段数组的顺序
/// 是"层算子（按层序、层内按表序）→ 文档级算子（按表序）"，而不是表格字面
/// 顺序。逐算子报告照这个顺序给出，并把 `layer` 一起报出来，调用方不必猜。
pub fn impact_stages(
  doc : @core.Document,
  env : RenderEnv,
  prog : @core.EditProgram,
) -> Result[(Array[ImpactStage], @codec.RgbaBuf), String] {
  // 规模护栏：**执行时再判一次**（画布以这里为准）。
  // 入口 `mvsl-set` 已经判过一次，但表装好之后画布还能被 `resize` 改大——
  // "装的时候合法、渲染时才变贵"只能在这里拦住。判据与入口/lint 同一句。
  match edit_cost_refusal(doc, prog) {
    Some(e) => return Err(e)
    None => ()
  }
  // 不含图层级算子 → 原来的单段路径，**逐位不变**。
  if !@core.program_has_layer_scope(prog) {
    let base = render_layers(doc, env)
    let (out, stages) = match @pixel.run_program(base, prog) {
      Ok(pair) => pair
      Err(e) => return Err("MVSL 编辑表执行失败：\{e}")
    }
    let list : Array[ImpactStage] = []
    let mut prev = base
    let mut i = 0
    while i < prog.ops.length() {
      let after = stages[i]
      // `basis` 是**该算子选择子实际求值的那个缓冲**（`stage:n` 落到哪张图），
      // 不是"本段的输入"——`agent` 侧三个消费者拿它重算权重场，报错了数字全错
      // 而渲染是对的。取值走 `@pixel.stage_basis_of`，与执行器同一处实现。
      let obasis = match prog.ops[i].sel.basis {
        @core.Base => base
        @core.Stage(n) => @pixel.stage_basis_of(base, stages, n)
      }
      list.push({
        op: prog.ops[i],
        layer: "",
        basis: obasis,
        before: prev,
        after,
      })
      prev = after
      i = i + 1
    }
    return Ok((list, out))
  }
  // `layer=@tag` 的标签作用域：先静态校验（落不到任何层 → 拒绝，不许静默不生效），
  // 再**展开**成具体层 id。展开与 agent 侧的分析命令共用 core 的同一个实现，
  // 于是"这条算子改哪些层"只有一处判断（标签是活的：打/摘标签即改作用范围）。
  match @core.tag_scope_error(prog, doc) {
    Some(e) => return Err(e)
    None => ()
  }
  let prog = @core.expand_layer_scopes(prog, doc)
  // ⚠️ `stage:n` 的判据必须在**展开之后**跑：一个 `layer=@tag` 的算子展开成
  // "标签命中几层就几条"，表序会变，而"同段 + 严格在前"正是按表序判的——
  // 判据看展开前的表、下面 `program_*_scope` 的重编号看展开后的表，就是同一个
  // 判断在**两张表**上各判一次（展开前说合法、执行时才发现指到别段）。
  match @core.layer_scope_error(prog) {
    Some(e) => return Err(e)
    None => ()
  }
  // 引用了不存在的层：`program_for_layer` 永远匹配不上，那个算子会**静默失效**
  // （表里有、跑得通、什么都不改）。这里兜底拒绝，agent 入口另有更早的友好报错。
  for id in @core.program_layer_ids(prog) {
    if @core.find_layer(doc.layers, id) is None {
      return Err("算子引用了不存在的图层：\{id}")
    }
  }
  let (w, h) = render_size(doc.width, doc.height)
  let out = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(out, 0, 0, w, h, 0xFFFFFFFF)
  let list : Array[ImpactStage] = []
  for l in doc.layers {
    let sub = @core.program_for_layer(prog, l.id)
    if sub.ops.length() == 0 {
      // 没被引用的层：与原来一样直接画（`paint_layer` 内部自行处理
      // visible/opacity/Group 短路）。
      paint_layer(l, out, env, 1.0, [])
    } else {
      let lb = rasterize_layer(l, w, h, env)
      let sub_stages = match @pixel.run_program(lb, sub) {
        Ok(pair) => pair
        Err(e) => return Err("MVSL 图层 \{l.id} 执行失败：\{e}")
      }
      // 层栅格上的逐算子阶段：`before/after` 都在**这一层**的缓冲上
      let mut prev = lb
      let mut k = 0
      while k < sub.ops.length() {
        let after = sub_stages.1[k]
        // 层算子的 `stage:n>0` 被判据拒（图层级与 STAGE(n>0) 不能共存），
        // 所以这里只可能是 `stage:0` = 本段输入 = 该层自己的栅格。
        let kbasis = match sub.ops[k].sel.basis {
          @core.Base => lb
          @core.Stage(n) => @pixel.stage_basis_of(lb, sub_stages.1, n)
        }
        list.push({
          op: sub.ops[k],
          layer: l.id,
          basis: kbasis,
          before: prev,
          after,
        })
        prev = after
        k = k + 1
      }
      blend_buffer(out, sub_stages.0, l.blend)
    }
  }
  let docprog = @core.program_doc_scope(prog)
  if docprog.ops.length() == 0 && docprog.guards.length() == 0 {
    return Ok((list, out))
  }
  let (final_buf, doc_stages) = match @pixel.run_program(out, docprog) {
    Ok(pair) => pair
    Err(e) => return Err("MVSL 编辑表执行失败：\{e}")
  }
  let mut prev = out
  let mut i = 0
  while i < docprog.ops.length() {
    let after = doc_stages[i]
    // 同单段：`stage:n` 指向的是哪个缓冲就报哪个（`out` 只对应 `stage:0`）。
    let dbasis = match docprog.ops[i].sel.basis {
      @core.Base => out
      @core.Stage(n) => @pixel.stage_basis_of(out, doc_stages, n)
    }
    list.push({
      op: docprog.ops[i],
      layer: "",
      basis: dbasis,
      before: prev,
      after,
    })
    prev = after
    i = i + 1
  }
  Ok((list, final_buf))
}

///|
/// 层合成底图（不含 MVSL；MVSL 求值与渲染的唯一基准）。
pub fn render_layers(
  doc : @core.Document,
  env : RenderEnv,
) -> @codec.RgbaBuf {
  let (w, h) = render_size(doc.width, doc.height)
  let buf = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(buf, 0, 0, w, h, 0xFFFFFFFF)
  for l in doc.layers {
    paint_layer(l, buf, env, 1.0, [])
  }
  buf
}

///|
/// 把**单个图层**栅格化到一张独立缓冲：透明底 + 只画这一层。
///
/// 这是「图层级编辑」的地基。`paint_layer` 只会往共享缓冲上叠，这里给它
/// 一张干净的白纸，于是能拿到"这一层自己的 RGBA"（alpha = 该像素的覆盖度）。
/// 连同下面的 `blend_buffer`，就能把"元素级混合"改写成"层级混合"。
pub fn rasterize_layer(
  l : @core.Layer,
  w : Int,
  h : Int,
  env : RenderEnv,
) -> @codec.RgbaBuf {
  rasterize_layer_in(l, w, h, env, [])
}

///|
/// 同上，但带上**祖先变换链**（`paint_layer` 那个 `frames` 参数）。
///
/// 为什么必须有它：`rasterize_layer` 只有"画布坐标系"这一种口径，而组里的层
/// 要经过组的旋转/翻转。样式那条路（`paint_layer` 的 fx 分支）是在**任意深度**
/// 上被调用的，拿不到链就会把组里的层画成没转过的样子——"同一个判断两处实现
/// 就必然有一处先烂"的那个老坑。
fn rasterize_layer_in(
  l : @core.Layer,
  w : Int,
  h : Int,
  env : RenderEnv,
  frames : Transform,
) -> @codec.RgbaBuf {
  let buf = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(buf, 0, 0, w, h, 0x00000000)
  paint_layer(l, buf, env, 1.0, frames)
  buf
}

///|
/// **图层样式的四件套**：把影/发光/描边/内影加到"这一层自己的像素"上。
///
/// `buf` = 只画了这一层（透明底）的缓冲；`A` = 它的 alpha = 这一层的覆盖度
/// （含蒙版/变换/笔触/子层）。返回**新缓冲**（不改入参，调用方拿它去合成）：
/// 于是"层自己的像素"与"带样式的像素"是两个不会互相污染的概念。
///
/// 顺序（产品决定，见 DESIGN §8）：投影 → 外发光 → **层自己** → 内阴影 → 描边。
/// 四个覆盖度场：
///   * 投影 `S = shift(blur(A, shadow_blur), shadow_dx, shadow_dy)`（画在层下面）
///   * 发光 `G = blur(A, glow_radius)`（不位移，画在层下面）
///   * 内影 `I = A × (1 − shift(blur(A, inner_blur), inner_dx, inner_dy))`（层上面）
///   * 描边 `O = dilate(A, outline_w) − A`（取 max 0，画在层上面）
/// 模糊走 `@pixel.field_box_blur`、膨胀走 `@pixel.field_dilate`、位移走
/// `@pixel.field_shift`——三件事都只有一处实现，render 里不许再抄一份。
pub fn apply_fx(buf : @codec.RgbaBuf, fx : @core.LayerFx) -> @codec.RgbaBuf {
  let w = buf.width
  let h = buf.height
  let out = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(out, 0, 0, w, h, 0x00000000)
  if !@core.fx_any_on(fx) {
    // 全 off：逐位等于入参（"装了却不干活"的画面那一半判据靠它）
    let mut i = 0
    let total = w * h
    while i < total {
      out.pixels[i] = buf.pixels[i]
      i = i + 1
    }
    return out
  }
  // **工作窗**：这一层**真的有像素**的范围（读数据，不是拿模型猜），再按四件套
  // 的最大扩散量往外扩一圈。窗外的覆盖度恒为 0 ⇒ 只算窗内与整画布算**逐位相同**，
  // 而代价从"画布面积"降到"这一层的面积 + 扩散量"。
  //
  // 为什么不另写一条"窗口判据"（`paint_window` 那种模型预测）：数据说的范围
  // 一定覆盖得住（组里的旋转子层、伸出盒子的多边形都算得进去），而预测型判据
  // 只能靠"保守上界"活着——两条判据迟早分叉。
  let (wx0, wy0, wx1, wy1) = match fx_work_window(buf, fx) {
    Some(win) => win
    None => {
      // 这一层一个像素都没画（空组/全透明/完全在画布外）：样式也无从谈起
      return out
    }
  }
  let a = fx_alpha_field(buf, wx0, wy0, wx1, wy1)
  let ww = wx1 - wx0
  let wh = wy1 - wy0
  if @core.fx_shadow_on(fx) {
    let s = @pixel.field_shift(
      @pixel.field_box_blur(a, fx_radius(fx.shadow_blur)),
      fx.shadow_dx,
      fx.shadow_dy,
    )
    fx_under(out, s, fx.shadow_color, wx0, wy0, wx1, wy1)
  }
  if @core.fx_glow_on(fx) {
    let g = @pixel.field_box_blur(a, fx_radius(fx.glow_radius))
    fx_under(out, g, fx.glow_color, wx0, wy0, wx1, wy1)
  }
  // 层自己压在影/发光之上（只扫工作窗；窗外这些缓冲本来就是空的）
  blend_buffer_window(out, buf, @core.BlendMode::Normal, wx0, wy0, wx1, wy1)
  if @core.fx_inner_on(fx) {
    let b = @pixel.field_shift(
      @pixel.field_box_blur(a, fx_radius(fx.inner_blur)),
      fx.inner_dx,
      fx.inner_dy,
    )
    let i_field = @pixel.field_new(ww, wh)
    let mut i = 0
    let total = ww * wh
    while i < total {
      // 内影**只在层的里面**（乘 A）：不乘 A 就会把影画到层外的背景上
      let v = @pixel.field_get(a, i % ww, i / ww) *
        (1.0 - @pixel.field_get(b, i % ww, i / ww))
      @pixel.field_set(i_field, i % ww, i / ww, v)
      i = i + 1
    }
    fx_under(out, i_field, fx.inner_color, wx0, wy0, wx1, wy1)
  }
  if @core.fx_outline_on(fx) {
    let d = @pixel.field_dilate(a, fx_radius(fx.outline_w))
    let o = @pixel.field_new(ww, wh)
    let mut i = 0
    let total = ww * wh
    while i < total {
      let x = i % ww
      let y = i / ww
      let v = @pixel.field_get(d, x, y) - @pixel.field_get(a, x, y)
      @pixel.field_set(o, x, y, if v > 0.0 { v } else { 0.0 })
      i = i + 1
    }
    // 描边画在层的**上面**：此时 out 里已经有"层自己"，描边覆盖在它之外的那圈
    fx_under(out, o, fx.outline_color, wx0, wy0, wx1, wy1)
  }
  out
}

///|
/// `apply_fx` 的**工作窗**（左闭右开）：这一层真的有像素的外接盒（读数据，
/// 不是拿模型猜）再按四件套的最大扩散量往外扩、最后夹进画布。
///
/// 空（这一层一个像素都没画 / 完全在画布外）时返回 `None`——调用方据此
/// **什么都不做**（不是"照常走一遍再得到空结果"）。
///
/// 为什么这不是"第二条判据"：窗只决定**算了哪块区域**，逐件的语义判据仍在
/// `@core.fx_*_on` 一处；窗外覆盖度恒为 0，所以裁与不裁**逐位相同**
/// （`render/fx_wbtest.mbt` 断言"窗外逐位等于入参"）。
fn fx_work_window(
  buf : @codec.RgbaBuf,
  fx : @core.LayerFx,
) -> (Int, Int, Int, Int)? {
  let (bx0, by0, bx1, by1) = fx_content_bounds(buf)
  if bx1 <= bx0 || by1 <= by0 {
    return None
  }
  let reach = fx_reach(fx)
  let wx0 = if bx0 - reach > 0 { bx0 - reach } else { 0 }
  let wy0 = if by0 - reach > 0 { by0 - reach } else { 0 }
  let wx1 = if bx1 + reach < buf.width { bx1 + reach } else { buf.width }
  let wy1 = if by1 + reach < buf.height { by1 + reach } else { buf.height }
  Some((wx0, wy0, wx1, wy1))
}

///|
/// 这一层**真的有像素**的范围（左闭右开）：内容缓冲里 alpha ≠ 0 的最小外接盒。
/// 空（一个像素都没有）时返回 `bx1 <= bx0`。
fn fx_content_bounds(buf : @codec.RgbaBuf) -> (Int, Int, Int, Int) {
  let mut x0 = buf.width
  let mut y0 = buf.height
  let mut x1 = 0
  let mut y1 = 0
  let mut y = 0
  while y < buf.height {
    let mut x = 0
    while x < buf.width {
      if (buf.pixels[y * buf.width + x] & 0xFF000000) != 0 {
        if x < x0 {
          x0 = x
        }
        if y < y0 {
          y0 = y
        }
        if x + 1 > x1 {
          x1 = x + 1
        }
        if y + 1 > y1 {
          y1 = y + 1
        }
      }
      x = x + 1
    }
    y = y + 1
  }
  (x0, y0, x1, y1)
}

///|
/// 四件套在这张画布上的**最大扩散量**（像素）：模糊半径 + 偏移 + 1px 取整余量。
///
/// 这是**代价上界**（多扩一圈只是慢一点），不是语义判据——所以用浮点直接算、
/// 不去复刻 `field_shift` 的四舍五入（复刻就是第二份判据）。
fn fx_reach(fx : @core.LayerFx) -> Int {
  let absd = fn(v : Double) -> Double { if v < 0.0 { 0.0 - v } else { v } }
  let mut reach = 0.0
  if @core.fx_shadow_on(fx) {
    let r = fx_radius(fx.shadow_blur) + absd(fx.shadow_dx) + absd(fx.shadow_dy)
    if r > reach {
      reach = r
    }
  }
  if @core.fx_glow_on(fx) {
    let r = fx_radius(fx.glow_radius)
    if r > reach {
      reach = r
    }
  }
  if @core.fx_inner_on(fx) {
    let r = fx_radius(fx.inner_blur) + absd(fx.inner_dx) + absd(fx.inner_dy)
    if r > reach {
      reach = r
    }
  }
  if @core.fx_outline_on(fx) {
    let r = fx_radius(fx.outline_w)
    if r > reach {
      reach = r
    }
  }
  reach.to_int() + 1
}

///|
/// 半径/宽度的**能力上限**（`@core.FX_MAX_RADIUS`）：超过它的部分按上限算。
/// 夹在唯一一处，与 `fx_param_error` 报出的上限是同一个常量——错误提示里那句
/// "超过上限的部分不会让效果更大"因此是真的（护栏 = 能力上限，PLAN 十九）。
fn fx_radius(v : Double) -> Double {
  if v > @core.FX_MAX_RADIUS {
    @core.FX_MAX_RADIUS
  } else {
    v
  }
}

///|
/// 从"这一层自己的像素"里取覆盖度场（alpha/255），只在工作窗
/// `[wx0,wx1) × [wy0,wy1)` 上取（场的局部坐标 = 画布坐标 − 窗原点）。
fn fx_alpha_field(
  buf : @codec.RgbaBuf,
  wx0 : Int,
  wy0 : Int,
  wx1 : Int,
  wy1 : Int,
) -> @pixel.Field {
  let f = @pixel.field_new(wx1 - wx0, wy1 - wy0)
  let mut y = wy0
  while y < wy1 {
    let mut x = wx0
    while x < wx1 {
      let p = @codec.rgba_get(buf, x, y)
      @pixel.field_set(f, x - wx0, y - wy0, ((p >> 24) & 0xFF).to_double() / 255.0)
      x = x + 1
    }
    y = y + 1
  }
  f
}

///|
/// 把"某个覆盖度场 × 某个颜色"以 source-over 叠到 `dst` 上（四件套共用的唯一
/// 一处合成：影/发光/内影/描边都只是"场 + 颜色"）。
fn fx_under(
  dst : @codec.RgbaBuf,
  f : @pixel.Field,
  color : Int,
  wx0 : Int,
  wy0 : Int,
  wx1 : Int,
  wy1 : Int,
) -> Unit {
  let ca = (color >> 24) & 0xFF
  if ca <= 0 {
    return
  }
  let mut y = wy0
  while y < wy1 {
    let mut x = wx0
    while x < wx1 {
      let cov = @pixel.field_get(f, x - wx0, y - wy0)
      if cov > 0.0 {
        let a255 = (ca.to_double() * cov + 0.5).to_int()
        if a255 > 0 {
          let src = (a255 << 24) + (color & 0x00FFFFFF)
          @codec.rgba_set(
            dst,
            x,
            y,
            composite_pixel(@codec.rgba_get(dst, x, y), src, @core.BlendMode::Normal),
          )
        }
      }
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// 把一张**带 alpha 的层缓冲**按混合模式叠到目标缓冲上。
/// alpha 为 0 的像素直接跳过（与 `paint_layer` 的短路一致，也是确定性的一部分：
/// 跳过的像素不会被写成"底与透明混合"的结果）。
fn blend_buffer(
  dst : @codec.RgbaBuf,
  src : @codec.RgbaBuf,
  mode : @core.BlendMode,
) -> Unit {
  blend_buffer_window(dst, src, mode, 0, 0, dst.width, dst.height)
}

///|
/// 同 `blend_buffer`，但只扫 `[x0,x1) × [y0,y1)` 那块矩形（画布外的部分照样
/// 会按两个缓冲的较小尺寸夹住）。
///
/// 住在同一处是为了**不出现第二份合成判据**：样式那条路（`apply_fx`）只需要
/// 它的工作窗，而"怎么把一个缓冲叠到另一个上"只有这一个循环说了算。
fn blend_buffer_window(
  dst : @codec.RgbaBuf,
  src : @codec.RgbaBuf,
  mode : @core.BlendMode,
  x0 : Int,
  y0 : Int,
  x1 : Int,
  y1 : Int,
) -> Unit {
  let cw = if dst.width < src.width { dst.width } else { src.width }
  let ch = if dst.height < src.height { dst.height } else { src.height }
  let ex = if x1 < cw { x1 } else { cw }
  let ey = if y1 < ch { y1 } else { ch }
  let mut y = if y0 > 0 { y0 } else { 0 }
  while y < ey {
    let mut x = if x0 > 0 { x0 } else { 0 }
    while x < ex {
      let fg = @codec.rgba_get(src, x, y)
      if (fg & 0xFF000000) != 0 {
        let bg = @codec.rgba_get(dst, x, y)
        @codec.rgba_set(dst, x, y, composite_pixel(bg, fg, mode))
      }
      x = x + 1
    }
    y = y + 1
  }
}

///|
/// 逐层栅格化再合成（「**层级混合**」语义）。
///
/// 与 `render_layers` 的唯一差别在"同一层内多个元素互相重叠"时：
///   * `render_layers`：每个元素各自与**当时的底**混合（元素级）；
///   * 本函数：先把整层叠到透明底上算出"这一层自己的颜色"，再与底混合（层级）。
/// 两者**逐位相同**——`over` 是结合的，所以"先叠出整层再与底混合"与
/// "每个元素各自与底混合"在 Normal 模式下数学等价（`render/layer_raster_test.mbt`
/// 对不透明层、层内半透明重叠两种情形都断言了这个相等）。**这个相等是好事**：
/// 它意味着把逐层栅格化接进渲染管线是零回归的——能单独拿出某一层、改完再放
/// 回去，而输出一个像素不变。图层级编辑要的是"能对某一层单独施加编辑"，
/// 不是改变混合语义。目前它只用于对照实验与测试，还没接进渲染管线。
pub fn render_layers_rasterized(
  doc : @core.Document,
  env : RenderEnv,
) -> @codec.RgbaBuf {
  let (w, h) = render_size(doc.width, doc.height)
  let out = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(out, 0, 0, w, h, 0xFFFFFFFF)
  for l in doc.layers {
    if !l.visible || l.opacity <= 0.0 {
      continue
    }
    let lb = rasterize_layer(l, w, h, env)
    blend_buffer(out, lb, l.blend)
  }
  out
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
/// 画全部层的**选中线框**与序号。
///
/// ⚠️ 框是**四边形**（四个角过完整变换链），不是轴对齐的盒子：`effective_box`
/// 是"层自己的坐标系里那个矩形"，它在画布上占的地方要过"自己的 rot/flip +
/// 整条祖先链"才知道。此前这里把盒子直接投影成轴对齐矩形，于是**转过之后线框
/// 还停在原地**（把矩形转 90°，线框仍在原来的位置——报告面与画面分家，PLAN 六十三）。
///
/// ⚠️ 遍历**递归带祖先链**（与 `pick_from`/`paint_layer` 同一把尺子）：组自己
/// 没有面、不画框，但子层要带着组的帧；`!visible` 与"有效不透明度 ≤ 0"时整棵
/// 子树都不画——这不是新规矩，而是与 `pick`/渲染**对齐**（此前那是平铺遍历，
/// 隐藏组的子层照样有线框，而渲染器一个像素都没画它）。
fn draw_overlays(
  doc : @core.Document,
  out : @codec.RgbaBuf,
  cx0 : Int,
  cy0 : Int,
  cw : Int,
  ch : Int,
) -> Unit {
  let _ = draw_overlays_in(doc.layers, [], 1.0, out, cx0, cy0, cw, ch, 0)
}

///|
/// `draw_overlays` 的递归体，返回下一个可用序号（层号 = 可见且有面的层按序数）。
fn draw_overlays_in(
  layers : Array[@core.Layer],
  frames : Transform,
  inherited_opacity : Double,
  out : @codec.RgbaBuf,
  cx0 : Int,
  cy0 : Int,
  cw : Int,
  ch : Int,
  start : Int,
) -> Int {
  let mut ordinal = start
  for l in layers {
    // 与 `paint_layer`/`pick_from` 同一把尺子（判据一处：`effective_opacity`）
    let eff = effective_opacity(l, inherited_opacity)
    if eff <= 0.0 {
      continue
    }
    if l.kind is @core.ShapeKind::Group {
      ordinal = draw_overlays_in(
        l.children, frames_for(frames, l), eff, out, cx0, cy0, cw, ch, ordinal,
      )
      continue
    }
    ordinal = ordinal + 1
    let color = overlay_palette[(ordinal - 1) % overlay_palette.length()]
    // ⚠️ 盒子走 `@core.effective_box`——**与 `query-layer` 同一个事实源**。
    // 读存下来的 `l.x/l.y/l.w/l.h` 会让两个报告面分家：笔触层/子组的存盒只是
    // 建层时的快照（笔触层那份还是整幅画布尺寸），于是"`query-layer` 报落笔
    // 范围、线框画整幅画布"（PLAN 六十实测抓到）。判据一处，报告面两处——所以两处必须读同一处。）
    let quad = box_quad_canvas(l, frames)
    // doc 坐标 → 视图像素坐标（与原先同一个映射）；顺带攒重心给序号用
    let pts : Array[(Int, Int)] = []
    let mut sx = 0
    let mut sy = 0
    for q in quad {
      let vx = ((q.0 - cx0.to_double()) * out.width.to_double() / cw.to_double()).to_int()
      let vy = ((q.1 - cy0.to_double()) * out.height.to_double() / ch.to_double()).to_int()
      pts.push((vx, vy))
      sx = sx + vx
      sy = sy + vy
    }
    stroke_poly_1px(out, pts, color)
    // 序号画在四边形的**重心**：框转过之后它仍在框里（此前画在盒子的左上角 +2，
    // 转过时那个点会飘到框外——"报告面"的字也得跟着画面）
    draw_number(out, ordinal, sx / 4 + 2, sy / 4 + 2, color)
  }
  ordinal
}

///|
/// 一层的**选中框**在画布坐标下的四个角（顺序：盒的左上 → 右上 → 右下 → 左下）。
///
/// 两个分支说的是同一件事——"盒子 → 画布"，差别只在**自己的变换怎么进坐标系**：
/// * 普通层：`effective_box` 是**父坐标系**里的盒子（笔触层那份还含 `l.x/l.y`，
///   见 `core.raster_bbox`），所以局部角要减掉 `l.x/l.y` 再交给 `screen`
///   （`screen` = 自己的 rot/flip 绕 `local_pivot` + 整条祖先链）；
/// * 组：`effective_box` 的原点就是父坐标系里的原点，组自己**没有平移**
///   （`x/y` 已被 `move` 折叠进后代，PLAN 五十五），所以先套自己的帧
///   （`frame_of` = 绕**派生**盒中心转/翻）再套祖先链。
///
/// ⚠️ 两个分支都要走**完整**的链：漏自己的变换 = "转过的层线框不转"，漏祖先链
/// = "组转了而子层线框不转"（两条都实测过，变异 Q91/Q92 各守一条）。
fn box_quad_canvas(l : @core.Layer, frames : Transform) -> Array[(Double, Double)] {
  let (ex, ey, ew, eh) = @core.effective_box(l)
  let corners = [(0.0, 0.0), (ew, 0.0), (ew, eh), (0.0, eh)]
  let out : Array[(Double, Double)] = []
  if l.kind is @core.ShapeKind::Group {
    let f = frame_of(l)
    for c in corners {
      let (qx, qy) = to_canvas_frame_pt(f, ex + c.0, ey + c.1)
      out.push(to_canvas_in(frames, qx, qy))
    }
  } else {
    for c in corners {
      out.push(screen(l, frames, ex - l.x + c.0, ey - l.y + c.1))
    }
  }
  out
}

///|
/// 1px 折线（自动闭合，含端点）。越界由 `rgba_set` 丢弃。
fn stroke_poly_1px(buf : @codec.RgbaBuf, pts : Array[(Int, Int)], color : Int) -> Unit {
  let n = pts.length()
  if n < 2 {
    return
  }
  for i in 0..<n {
    let a = pts[i]
    let b = pts[(i + 1) % n]
    stroke_line_1px(buf, a.0, a.1, b.0, b.1, color)
  }
}

///|
/// 线段 → 缓冲区矩形 的裁剪（Liang–Barsky）。返回 `(可见, x0', y0', x1', y1')`。
///
/// ⚠️ **这不是"优化"，是防卡死**：`rgba_set` 丢弃的是**越界写入**，而 Bresenham 的
/// **迭代次数由线段长度决定**——只画得下 1px，却要跑 1e20 步。
/// 实测：`add-rect w=99999999999999999999`（合法 Double，入口收下）之后
/// `render overlay=1`（overlay 给每个可见层画 bbox 线框）**渲染卡死**，
/// 同一份文档**不带** overlay 秒回（层填充被 `paint_window` 裁到画布）。
/// 两句真相：①"越界由 `rgba_set` 丢弃"只对**写**成立、对**循环**不成立；
/// ②**错误会挡住更深的问题**——`render overlay=1` 此前掉进 `to_i("overlay=1")`
/// 直接报错，于是这条线框路径在 fuzz 语料里**从来没被走到过**；一旦修好那个
/// 参数解析 bug（①C），同一个语料立刻把卡死暴露出来。判据只有这一处：
/// `stroke_line_1px` 的 Bresenham 只敢在裁完的段上跑。
fn clip_seg(
  buf : @codec.RgbaBuf,
  x0 : Int,
  y0 : Int,
  x1 : Int,
  y1 : Int,
) -> (Bool, Int, Int, Int, Int) {
  let dx = (x1 - x0).to_double()
  let dy = (y1 - y0).to_double()
  let xmin = 0.0
  let ymin = 0.0
  let xmax = (buf.width - 1).to_double()
  let ymax = (buf.height - 1).to_double()
  let mut t0 = 0.0
  let mut t1 = 1.0
  // 四条边各一次：p 是"参数增大会不会走进这条边"的符号，q 是当前点到该边的距离。
  let edges = [
    (0.0 - dx, x0.to_double() - xmin),
    (dx, xmax - x0.to_double()),
    (0.0 - dy, y0.to_double() - ymin),
    (dy, ymax - y0.to_double()),
  ]
  for e in edges {
    let p = e.0
    let q = e.1
    if p == 0.0 {
      if q < 0.0 {
        return (false, 0, 0, 0, 0)
      }
    } else {
      let r = q / p
      if p < 0.0 {
        if r > t1 {
          return (false, 0, 0, 0, 0)
        }
        if r > t0 {
          t0 = r
        }
      } else {
        if r < t0 {
          return (false, 0, 0, 0, 0)
        }
        if r < t1 {
          t1 = r
        }
      }
    }
  }
  (true, round_i(x0.to_double() + t0 * dx), round_i(y0.to_double() + t0 * dy),
   round_i(x0.to_double() + t1 * dx), round_i(y0.to_double() + t1 * dy))
}

///|
/// 四舍五入到整数（负数对称）。裁剪端点必须取整，否则 Bresenham 的起点会偏一个
/// 像素——**在边界上的**线框会与"不裁剪"时差一格，而 golden 锁的是像素。
fn round_i(v : Double) -> Int {
  if v >= 0.0 {
    (v + 0.5).to_int()
  } else {
    0 - ((0.0 - v + 0.5).to_int())
  }
}

///|
/// 1px 直线段（Bresenham，含两个端点）。**先把线段裁到缓冲区**（见 `clip_seg`）。
fn stroke_line_1px(
  buf : @codec.RgbaBuf,
  x0 : Int,
  y0 : Int,
  x1 : Int,
  y1 : Int,
  color : Int,
) -> Unit {
  let (vis, cx0, cy0, cx1, cy1) = clip_seg(buf, x0, y0, x1, y1)
  if !vis {
    return
  }
  let x0 = cx0
  let y0 = cy0
  let x1 = cx1
  let y1 = cy1
  let dx = if x1 > x0 { x1 - x0 } else { x0 - x1 }
  let dy = if y1 > y0 { y1 - y0 } else { y0 - y1 }
  let sx = if x0 < x1 { 1 } else { -1 }
  let sy = if y0 < y1 { 1 } else { -1 }
  let mut err = dx - dy
  let mut x = x0
  let mut y = y0
  while true {
    @codec.rgba_set(buf, x, y, color)
    if x == x1 && y == y1 {
      break
    }
    let e2 = 2 * err
    if e2 > -dy {
      err = err - dy
      x = x + sx
    }
    if e2 < dx {
      err = err + dx
      y = y + sy
    }
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
/// raster 层的笔触是否盖住这个**层局部**点。
///
/// 按先后取**最后一个**覆盖该点的笔触：`erase` 笔触表示那里被擦掉
/// （`paint_dabs` 就是按这个顺序把 alpha 乘减下去的）。这是对
/// "alpha 乘减"的一个保守近似——**不是**逐点重算覆盖度，够回答
/// "这层在这里有没有落过笔"。
fn raster_covers(l : @core.Layer, lx : Double, ly : Double) -> Bool {
  let mut i = l.dabs.length() - 1
  while i >= 0 {
    let d = l.dabs[i]
    let dx = lx - d.x
    let dy = ly - d.y
    if d.r > 0.0 && dx * dx + dy * dy <= d.r * d.r {
      return !d.erase
    }
    i = i - 1
  }
  false
}

///|
/// 自顶向下找最上层**真的在那里画了东西**的层（`paint_layer` 是唯一权威）。
///
/// 与 `paint_layer` 逐条对齐，因为"报出来的层"和"画出来的像素"必须是同一件事：
/// - `visible=false` 的层不画 → 不算（含**祖先组**不可见，故这里递归而不是走
///   压平的 `all_layers`：压平会丢掉组的可见性与透明度）；
/// - 有效透明度为 0 的层不画 → 不算（同样是继承乘下来的）；
/// - 蒙版盖不到的点不画 → 不算；
/// - 组自身无面 → 不算（只在子层里找）；**组上的 mask 渲染器也不读**，
///   所以这里同样不读——判据不能比渲染器更严；
/// - raster 层只在笔触覆盖处算"有东西"（它的 `inside_fill` 恒假）。
fn pick_from(
  layers : Array[@core.Layer],
  x : Double,
  y : Double,
  inherited_opacity : Double,
  frames : Transform,
) -> String? {
  let mut i = layers.length() - 1
  while i >= 0 {
    let l = layers[i]
    i = i - 1
    // 看得见吗（`visible` + 继承的 α）：判据一处，`effective_opacity`
    let eff = effective_opacity(l, inherited_opacity)
    if eff <= 0.0 {
      continue
    }
    if l.kind is @core.ShapeKind::Group {
      // 组的变换：与 `paint_layer` 同一条祖先链（判据一处，见 `to_local_in`）
      match pick_from(l.children, x, y, eff, frames_for(frames, l)) {
        Some(id) => return Some(id)
        None => ()
      }
      continue
    }
    let (lx, ly) = canvas_to_layer(l, frames, x, y)
    // 蒙版判据与**渲染同一把尺子**：渲染按 2×2 子样本累积覆盖度，
    // 所以只要**任一**子样本在蒙版里，这个像素上就有这一层的墨（实测反例：
    // 毛边 (26,6) 上 (26.75,6.75) 有覆盖、像素中心没有 ⇒ 只看中心会与渲染
    // 打架）。这里只看点本身就会把八分之一覆盖的像素判成"没画"。
    let (mx, my) = to_local(l, x, y)
    let mut cover_max = 0.0
    for sp in subsample_2x2 {
      let c = mask_cover_at(l, mx + sp.0, my + sp.1)
      if c > cover_max {
        cover_max = c
      }
    }
    if cover_max <= 0.0 {
      continue
    }
    if l.kind is @core.ShapeKind::Raster {
      if raster_covers(l, lx, ly) {
        return Some(l.id)
      }
      continue
    }
    // 渲染窗外的点 `paint_layer` 一个像素都不落 —— 判据要与它同一把尺子。
    // 只对**走窗内遍历**的那几种形状管：Text/Raster 在 `paint_layer` 里提前
    // return（Text 的字形可以画到盒子外），Group/Adjust 无面（前面已处理）。
    let windowed = match l.kind {
      @core.ShapeKind::Text => false
      @core.ShapeKind::Raster => false
      @core.ShapeKind::Group => false
      @core.ShapeKind::Adjust => false
      _ => true
    }
    if windowed {
      let (x0, y0, x1, y1) = paint_window(l)
      let px = x.to_int()
      let py = y.to_int()
      if px < x0 || px >= x1 || py < y0 || py >= y1 {
        continue
      }
    }
    if inside_fill(l, lx, ly) || inside_stroke(l, lx, ly) {
      return Some(l.id)
    }
  }
  None
}

///|
/// 画布坐标拾取：返回最上层**在那里画了东西**的层 id（旋转层用同样的内点测试）。
///
/// 此前这个函数走的是压平的 `all_layers`、且只查 `visible`，于是三类层会被
/// 报成"在那里"而实际一个像素都没画：**隐藏组的子层**、**opacity=0 的层**、
/// **被自己蒙版盖掉的点**。`sample` 同时回颜色与层 id，两个字段会当场互相
/// 矛盾（实测 `sample` 报 `color=#FFFFFFFF`（白纸）+ `layer='l1'`（全透明层））。
pub fn pick(
  doc : @core.Document,
  x : Double,
  y : Double,
) -> String? {
  // 画布外的点没有像素可画：`sample` 早就这么判了（"采样点超出画布"），
  // 而 `pick` 曾照 `inside_fill` 报出一个层 —— 同一个点，两个命令两种答案。
  if x < 0.0 || y < 0.0 || x >= doc.width.to_double() || y >= doc.height.to_double() {
    return None
  }
  pick_from(doc.layers, x, y, 1.0, [])
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
///|
/// ⚠️ 它是 `sin_rad(x + π/2)` ⇒ **在 `x = π/2` 处落到级数最差点**（求值点是
/// `sin(π)`，`x² ≈ 9.87` 超出级数设计的 `|v| ≤ π`）：实测 `cos(π/2)` 误差
/// **2.1e-5**（`sin` 路径只有 6.6e-10）。所以**象限角不要走这里**——走
/// `rot_sincos`（它给精确值，PLAN 六十二）。这里留着是为了任意角度的通用性。
fn cos_rad(x : Double) -> Double {
  sin_rad(x + 1.5707963267948966)
}

///|
/// **角度（度）→ (cos, sin)**，四处变换（`to_local_frame`/`to_canvas_frame_pt`/
/// `to_local_p`/`to_canvas_p`）**共用这一处**。
///
/// ⚠️ 象限角（90° 的整数倍）直接给**精确值**，这是必须的：`cos_rad(x)` 是
/// `sin_rad(x + π/2)`，在 `x = π/2` 处它落到级数最差点（`sin(π)`，`x² ≈ 9.87`
/// 超出级数设计的 `|v| ≤ π`），实测 `cos(π/2)` 误差 **2.1e-5**（`sin` 路径只有
/// 6.6e-10）、`cos(π/4)` 误差 2.9e-7。轴对齐的编辑（`rotate 90` 是最高频的
/// 那一个）因此会偏离整数格：实测"内层组转 90° + 外层组转 270°"（数学上恒等）
/// 复合后局部坐标差 **2.5e-4**，硬边字形整格翻过去、画面差 48 个像素（PLAN
/// 六十二）。给了精确值之后轴对齐的整条链**逐位恒等**。
fn rot_sincos(deg : Double) -> (Double, Double) {
  let k = deg / 90.0
  let ki = k.to_int()
  if k == ki.to_double() {
    // 归一到 0..3（`to_int`/取余都是向零截断，负数要补一圈）
    let m = ki % 4
    let q = if m < 0 { m + 4 } else { m }
    if q == 0 {
      (1.0, 0.0)
    } else if q == 1 {
      (0.0, 1.0)
    } else if q == 2 {
      (-1.0, 0.0)
    } else {
      (0.0, -1.0)
    }
  } else {
    let rad = deg * 3.141592653589793 / 180.0
    (cos_rad(rad), sin_rad(rad))
  }
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
/// 文本层的三个量，**一处算**：`sc` = 每像素放大倍数（`font_size/7` 向下取整、
/// 至少 1）、`adv` = 每字符推进（6 列）、`ox`/`oy` = 字形在**层局部**坐标系里的
/// 起点（复现旧实现的 `l.x.to_int()`：字形落在整数格上、分数坐标被截掉，于是
/// 不带变换的路径逐位不变）。
fn text_metrics(l : @core.Layer) -> (Int, Int, Double, Double) {
  let scale = (l.font_size / 7.0).to_int()
  let sc = if scale < 1 { 1 } else { scale }
  (sc, 6 * sc, l.x.to_int().to_double() - l.x, l.y.to_int().to_double() - l.y)
}

///|
/// **字形格索引**：把层局部坐标折算成（第几个字符，列，行）；越界返回 `None`。
///
/// ⚠️ 一处实现：`paint_text`（逐像素绘制）与 `text_ink`（`pick`/`sample`/
/// `inside_fill` 的读点）共用它——"这个点在不在墨上"只能有一个答案。
///
/// ⚠️ `+1e-4` 偏置（像素的万分之一）：字形是**硬边**位图，格边界上差一点点就
/// 整格翻过去，而 `lx`/`ly` 是经完整变换链算出来的——`cos_rad`/`sin_rad` 是
/// 级数近似，实测 90° 下单点误差 ~1.4e-6。偏置必须**大于**它：1e-9/1e-6 都太小
/// （"H" 转 90° 时墨迹 208→206/207、点探针当场翻格），1e-4 之后轴对齐的四格
/// 全部恰好 208（PLAN 六十一）。
fn text_cell(
  sc : Int,
  adv : Int,
  ox : Double,
  oy : Double,
  nchars : Int,
  lx : Double,
  ly : Double,
) -> (Int, Int, Int)? {
  let u = lx - ox + 1.0e-4
  let v = ly - oy + 1.0e-4
  if u < 0.0 || v < 0.0 {
    return None
  }
  let scf = sc.to_double()
  let ci = (u / adv.to_double()).to_int()
  if ci >= nchars {
    return None
  }
  let col = ((u - ci.to_double() * adv.to_double()) / scf).to_int()
  let row = (v / scf).to_int()
  // 第 5 列（6 列推进里的最后一列）是**字距空隙**，不算墨；行 0..6 之外同理
  if col >= 5 || row >= 7 {
    return None
  }
  Some((ci, col, row))
}

///|
/// 字形位图（一次取出；非 ASCII 用盒形占位 = 诚实边界）。
fn text_glyphs(text : String) -> Array[Array[Int]] {
  let out : Array[Array[Int]] = []
  for ch in text.iter() {
    out.push(
      match glyph_columns(ch) {
        Some(g) => g
        None => [31, 21, 21, 21, 31]
      },
    )
  }
  out
}

///|
/// 文本层在**层局部**坐标 `(lx, ly)` 上有没有墨。判据一处：`paint_text` 与
/// `inside_fill`（`pick`/`sample`）都经它 ⇒ 报告面与画面不可能分家。
fn text_ink(l : @core.Layer, lx : Double, ly : Double) -> Bool {
  let (sc, adv, ox, oy) = text_metrics(l)
  match text_cell(sc, adv, ox, oy, l.text.length(), lx, ly) {
    None => false
    Some((ci, col, row)) => {
      let bits = text_glyphs(l.text)[ci][col]
      (lsr(bits, 6 - row) & 1) == 1
    }
  }
}

///|
/// 文本层绘制：字形按 font_size/7 缩放，advance = 6 * scale。
///
/// **目标像素驱动**（与 `paint_raster` 同一条路）：扫"字形区域过完整变换链后的
/// 外接盒"，逐格把画布像素**逆向**映射回层局部，再查字形位图。旧实现是正向的
/// ——直接算 `l.x + 列*sc + 偏移` 就落像素，于是**本层与祖先链的变换一个都不走**
/// （实测 `rotate <组> 90`：回包 ok、指纹变了、`render_sha256` 逐位不变，与
/// PLAN 五十八那颗 dab 的 bug 是同一类，晚了一层）。逆向采样还顺带解决了
/// 任意角度下的空洞（正向点抽样会漏像素）。
///
/// ⚠️ **字形起点复现旧的 `l.x.to_int()`**（字形落在整数格上、分数坐标被截掉）：
/// 库里的 golden 全是不带变换的路径，这样它**逐位不变**。
///
/// ⚠️ 蒙版按**层局部**坐标采样（`add-mask` 的 x/y 默认 0；矩形实测：层在 (50,40)、
/// 蒙版 x=0 w=10 时左半保留）。旧实现拿**画布**坐标采样 ⇒ 定过位的文本层上蒙版
/// 整块错位：实测文本层在 (50,40)、蒙版 w=10 时 `sample 52 50` 回
/// `color=#FFFFFFFF`（画不出东西）而 `layer=t1`（pick 说层就在那儿）——**两个
/// 信号自相矛盾**，正是"同一个判断两处实现"的第三次现身。
fn paint_text(
  l : @core.Layer,
  buf : @codec.RgbaBuf,
  env : RenderEnv,
  eff_opacity : Double,
  frames : Transform,
) -> Unit {
  if l.text.length() == 0 {
    return
  }
  let (sc, adv, ox, oy) = text_metrics(l)
  let color = fill_color_at(l.fill, 0.0, 0.0, l.w, l.h)
  // 颜色自带的 alpha 并进覆盖度（与形状填充同理）。`NoFill` 的 alpha 是 0，
  // 语义就是"不画"；默认层是 `Solid(0xFF808080)`，所以默认路径不变。
  let color_a = ((color >> 24) & 0xFF).to_double() / 255.0
  let glyphs = text_glyphs(l.text)
  let gw = (adv * glyphs.length()).to_double()
  let gh = (7 * sc).to_double()
  // 渲染窗 = 字形矩形的四角过 `screen`（本层变换 + 祖先链）后的外接盒，各留 1px。
  // 仿射映射把矩形映成平行四边形 ⇒ 四角外接盒一定装得下。
  // ⚠️ 不用 `paint_window_in`：那是**保守**窗（对角线为边），一行长文本（w≫h）
  // 会被扫成 ~w² 个像素，比字形盒子大一个量级——"保守上界"给 `pick`/`lint` 用
  // 没问题，给逐像素循环用就是个性能坑。
  let mut minx = 1.0e18
  let mut miny = 1.0e18
  let mut maxx = -1.0e18
  let mut maxy = -1.0e18
  for c in [(ox, oy), (ox + gw, oy), (ox, oy + gh), (ox + gw, oy + gh)] {
    let (px, py) = screen(l, frames, c.0, c.1)
    if px < minx {
      minx = px
    }
    if py < miny {
      miny = py
    }
    if px > maxx {
      maxx = px
    }
    if py > maxy {
      maxy = py
    }
  }
  let mut x0 = minx.to_int() - 1
  let mut y0 = miny.to_int() - 1
  let mut x1 = maxx.to_int() + 2
  let mut y1 = maxy.to_int() + 2
  if x0 < 0 {
    x0 = 0
  }
  if y0 < 0 {
    y0 = 0
  }
  if x1 > buf.width {
    x1 = buf.width
  }
  if y1 > buf.height {
    y1 = buf.height
  }
  let mut y = y0
  while y < y1 {
    let mut x = x0
    while x < x1 {
      let (lx, ly) = canvas_to_layer(l, frames, x.to_double(), y.to_double())
      match text_cell(sc, adv, ox, oy, glyphs.length(), lx, ly) {
        None => ()
        Some((ci, col, row)) => {
          if (lsr(glyphs[ci][col], 6 - row) & 1) == 1 {
            // 蒙版按**层局部**坐标采样（`add-mask` 的 x/y 默认 0；矩形实测：
            // 层在 (50,40)、蒙版 x=0 w=10 时左半保留）。旧实现拿**画布**坐标
            // 采样 ⇒ 定过位的文本层上蒙版整块错位。
            let mf = mask_cover_at(l, lx, ly)
            let a = eff_opacity * mf * color_a
            let a255 = (a * 255.0 + 0.5).to_int()
            let src = (a255 << 24) + (color & 0x00FFFFFF)
            let dst = @codec.rgba_get(buf, x, y)
            @codec.rgba_set(buf, x, y, composite_pixel(dst, src, @core.BlendMode::Normal))
          }
        }
      }
      x = x + 1
    }
    y = y + 1
  }
  let _ = env
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
/// 圆角矩形的**有符号距离**：≤0 在内（值为到边界的负距离），>0 在外。
/// 羽化要的是"离边界多远"，所以这里必须给出距离而不是布尔——
/// `rounded_rect_inside` 保留平方比较（硬边路径与历史逐位一致），
/// 两者数学等价但浮点路径不同，不合并。
fn rounded_rect_sdf(
  dx : Double,
  dy : Double,
  w : Double,
  h : Double,
  radius : Double,
) -> Double {
  let hw = w / 2.0
  let hh = h / 2.0
  let r0 = if radius > hw { hw } else { radius }
  let r = if r0 > hh { hh } else { r0 }
  let ax = if dx > hw { dx - hw } else { hw - dx }
  let ay = if dy > hh { dy - hh } else { hh - dy }
  let qx = ax - (hw - r)
  let qy = ay - (hh - r)
  let ox = if qx > 0.0 { qx } else { 0.0 }
  let oy = if qy > 0.0 { qy } else { 0.0 }
  // 标准圆角矩形 SDF 的第二项：`min(max(qx,qy), 0)` 给出"在矩形内部时的
  // 内距"。**少了它，内部所有点的距离都会算成 0**（`ox/oy` 在内侧恒为 0），
  // 羽化就会变成"整块要么全 0 要么全 1"——这个错误只有实测像素才看得出来。
  let mx = if qx > qy { qx } else { qy }
  let mn = if mx < 0.0 { mx } else { 0.0 }
  Double::sqrt(ox * ox + oy * oy) + mn - r
}

///|
/// 到蒙版边界的"**内距**"：>0 = 在内且离边界这么远，≤0 = 在外。
/// 羽化按它做线性过渡。
///
/// 椭圆的距离用归一化半径差 `1 - ρ` 乘以**短半轴**近似——精确的椭圆
/// 距离要解四次方程，而羽化只是视觉过渡，短半轴尺度已经够用（圆形时精确）。
fn mask_inner_dist(mask : @core.LayerMask, dx : Double, dy : Double) -> Double {
  match mask.kind {
    @core.ShapeKind::Ellipse =>
      if mask.w <= 0.0 || mask.h <= 0.0 {
        -1.0
      } else {
        let nx = dx / mask.w * 2.0 - 1.0
        let ny = dy / mask.h * 2.0 - 1.0
        let rho = Double::sqrt(nx * nx + ny * ny)
        let short = if mask.w < mask.h { mask.w } else { mask.h }
        let half = short / 2.0
        (1.0 - rho) * half
      }
    @core.ShapeKind::Polygon => polygon_inner_dist(mask.points, dx, dy)
    _ => -rounded_rect_sdf(dx, dy, mask.w, mask.h, mask.radius)
  }
}

///|
/// 多边形到边界的**内距**：内部为正、外部为负（到最近一条边的距离，带符号）。
///
/// 为什么复用同一个"内距"而不是给多边形单独写一套羽化：蒙版的软边只有一个
/// 来源（`soft_cover(d / feather, Linear)`），内距的**符号与方向**就是它的
/// 全部语义。多边形自己算一套阈值，就会和矩形/椭圆的羽化方向悄悄相反
/// ——那正是"给参数但效果不对"的温床。
fn polygon_inner_dist(
  pts : Array[(Double, Double)],
  dx : Double,
  dy : Double,
) -> Double {
  let n = pts.length()
  if n < 3 {
    return -1.0
  }
  let mut best = -1.0
  for i in 0..<n {
    let ax = pts[i].0
    let ay = pts[i].1
    let j = if i + 1 == n { 0 } else { i + 1 }
    let bx = pts[j].0
    let by = pts[j].1
    let vx = bx - ax
    let vy = by - ay
    let len2 = vx * vx + vy * vy
    let t = if len2 <= 0.0 {
      0.0
    } else {
      let u = ((dx - ax) * vx + (dy - ay) * vy) / len2
      if u < 0.0 {
        0.0
      } else if u > 1.0 {
        1.0
      } else {
        u
      }
    }
    let px = ax + vx * t
    let py = ay + vy * t
    let d = Double::sqrt((dx - px) * (dx - px) + (dy - py) * (dy - py))
    if best < 0.0 || d < best {
      best = d
    }
  }
  if in_polygon(pts, dx, dy) {
    best
  } else {
    -best
  }
}

///|
/// 毛边的**晶格间距**（像素）：值噪声按这个间距铺点、再平滑插值。
/// 固定常数而不是参数，是为了让"毛化幅度"只有一个可调量（`roughen`）——
/// 两个可调量会互相掩盖对方是否生效。
const MASK_ROUGH_PITCH : Double = 4.0

///|
/// 一个与平台无关的确定性整数哈希 → [0,1)。
///
/// **为什么不是随机数**：渲染产物要按 sha 对账（铁律 7），任何时间戳/随机种子
/// 都会让同一文档渲染出两张不同的图。这里全部用掩到 24 位的整数乘法
/// （乘积 < 2^47，不依赖 Int 是 32 位还是 64 位，也不依赖溢出行为），
/// 所以 native 与 wasm-gc 给出**逐位相同**的毛边。
fn mask_hash01(ix : Int, iy : Int) -> Double {
  let mut h : Int64 = (ix & 0xFFFF).to_int64() * 4093L
  h = h + (iy & 0xFFFF).to_int64() * 8191L
  h = h & 0xFFFFFFL
  h = h * 2654435L
  h = h ^ (h >> 13)
  h = h & 0xFFFFFFL
  h = h * 1274126L
  h = h ^ (h >> 15)
  let u = h & 0xFFFFFFL
  u.to_double() / 16777216.0
}

///|
/// 向负无穷取整（`Double::to_int` 是向零截断，负数会落到错误的晶格上）。
fn mask_floor_i(v : Double) -> Int {
  let t = v.to_int()
  if v < 0.0 && t.to_double() != v {
    t - 1
  } else {
    t
  }
}

///|
/// 蒙版毛边的**边缘偏移量**（像素，`[-amp, amp]`）：画布坐标上的值噪声，
/// 双线性 + smoothstep 插值。
///
/// 它是**画布坐标的纯函数**——不依赖蒙版位置、图层变换、调用顺序，也不含
/// 随机数：同一份文档、同一个点，永远给出同一个偏移。取景（crop/zoom）不改
/// 语义，理由与选择子相同（蒙版坐标本来就是画布坐标）。
fn mask_edge_offset(amp : Double, px : Double, py : Double) -> Double {
  let gx = px / MASK_ROUGH_PITCH
  let gy = py / MASK_ROUGH_PITCH
  let ix = mask_floor_i(gx)
  let iy = mask_floor_i(gy)
  let fx = gx - ix.to_double()
  let fy = gy - iy.to_double()
  let sx = fx * fx * (3.0 - 2.0 * fx)
  let sy = fy * fy * (3.0 - 2.0 * fy)
  let v00 = mask_hash01(ix, iy)
  let v10 = mask_hash01(ix + 1, iy)
  let v01 = mask_hash01(ix, iy + 1)
  let v11 = mask_hash01(ix + 1, iy + 1)
  let a = v00 + (v10 - v00) * sx
  let b = v01 + (v11 - v01) * sx
  let v = a + (b - a) * sy
  amp * (v * 2.0 - 1.0)
}

///|
/// 蒙版覆盖度：画布坐标 (px,py) 在层蒙版内=1 外=0（invert 反选）。
/// 矩形蒙版按 `radius` 切圆角；`radius <= 0` 时**走原先的硬直角分支**。
///
/// `feather <= 0` 时**整段走硬边分支**，与"还没有 feather 这个参数"之前
/// 的行为逐位相同；`feather > 0` 时按内距做线性软过渡（边界处 0，向内
/// `feather` 像素处到 1）。
///
/// `roughen <= 0` 时**整段走没有毛边的老分支**（同样的逐位兼容承诺）；
/// `roughen > 0` 时先按画布坐标的确定性噪声扰动内距，再走同一套阈值/软过渡
/// —— 于是"毛边 + 羽化"是"先毛化再羽化"，而不是两种互斥模式。
/// 收的是**这个层矩形上的坐标**（局部）——蒙版就贴在这个矩形上，所以
/// "父坐标系 → 局部"这一步由调用方经 `canvas_to_layer` 完成（组变换进来之后
/// 这一步不能省，PLAN 五十六）。形状层、笔触层、调整层三条路径同一个入口。
fn mask_cover_at(l : @core.Layer, px : Double, py : Double) -> Double {
  let mask = match l.mask {
    Some(m) => m
    None => return 1.0
  }
  let dx = px - mask.x
  let dy = py - mask.y
  if mask.roughen > 0.0 {
    // 毛边路径：内距（圆角矩形/椭圆都算）减去噪声偏移，再做软/硬阈值。
    let d = mask_inner_dist(mask, dx, dy) - mask_edge_offset(mask.roughen, px, py)
    let rough_cover = if mask.feather > 0.0 {
      // 蒙版软覆盖 = 共享原语的「朝内 + 线性」预设：
      // t 从"覆盖为 0 的那一端"（边界）量起，即 t = 内距 / feather。
      @pixel.soft_cover(d / mask.feather, @pixel.Linear)
    } else if d > 0.0 {
      1.0
    } else {
      0.0
    }
    return if mask.invert { 1.0 - rough_cover } else { rough_cover }
  }
  let cover = if mask.feather > 0.0 {
    let d = mask_inner_dist(mask, dx, dy)
    @pixel.soft_cover(d / mask.feather, @pixel.Linear)
  } else {
    let inside = match mask.kind {
      // 任意形状选区（套索）：顶点是蒙版盒子内的局部坐标，判点复用多边形图层的
      // `in_polygon`——两处各写一份必然分叉（"窗内盒外有墨"那类 bug 就是这么来的）。
      @core.ShapeKind::Polygon => in_polygon(mask.points, dx, dy)
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
    if inside { 1.0 } else { 0.0 }
  }
  if mask.invert {
    1.0 - cover
  } else {
    cover
  }
}
