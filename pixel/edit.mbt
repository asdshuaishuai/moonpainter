/// pixel —— 选择子求值与算子执行（pixel/edit）。
///
/// 语义（PLAN-MVSL.md §1.2/§1.4）：
/// - 选择子输出**软权重场 [0,1]**（0=不选，1=完全在内，中间为过渡带）；
/// - 所有算子 `out = lerp(in, op(in), w)`，w ∈ [0,1]；
/// - 选择子求值基准**默认 = 不可变 base**；显式 STAGE(n) 才求值到
///   第 n 个算子之后的中间结果；
/// - 边界带**去污染**：`I = αF + (1−α)B` 只改 F，否则蓝边会变紫边。
///
/// 全部 O(N) 盒滤波/滑动窗，零第三方依赖，确定性（无哈希表迭代序、
/// 无时间戳、无随机数混入任何落盘字节）。

///|
/// 逻辑右移（本地实现；render 同款，避免符号扩展破坏通道提取）。
pub fn lsr32(x : Int, n : Int) -> Int {
  if n <= 0 {
    x
  } else if n >= 32 {
    0
  } else {
    (x >> n) & ((1 << (32 - n)) - 1)
  }
}

///|
/// 软权重场：宽 × 高的 Double 缓冲，值域 [0,1]。
pub(all) struct Field {
  w : Int
  h : Int
  v : FixedArray[Double]
}

///|
pub fn field_new(w : Int, h : Int) -> Field {
  { w, h, v: FixedArray::make(w * h, 0.0) }
}

///|
pub fn field_get(f : Field, x : Int, y : Int) -> Double {
  if x < 0 || x >= f.w || y < 0 || y >= f.h {
    0.0
  } else {
    f.v[y * f.w + x]
  }
}

///|
pub fn field_set(f : Field, x : Int, y : Int, t : Double) -> Unit {
  if x >= 0 && x < f.w && y >= 0 && y < f.h {
    let c = clamp01(t)
    let i = y * f.w + x
    if c > f.v[i] {
      f.v[i] = c
    }
  }
}

///|
/// 全图权重和（覆盖率证书用）。
pub fn field_sum(f : Field) -> Double {
  let mut s = 0.0
  for v in f.v {
    s = s + v
  }
  s
}

///|
/// 全图最大权重。
pub fn field_max(f : Field) -> Double {
  let mut m = 0.0
  for v in f.v {
    if v > m {
      m = v
    }
  }
  m
}

///|
/// 逐点并集（取 max）：把多个算子的权重场合成"整表支撑集"。
///
/// 用途：整表级的 diff 证书。**别拿零场冒充整表权重场**——零场会让每个像素
/// 都落在支撑集之外，于是 `leak_ratio` 退化成 `changed/total`、"选区外泄漏"
/// 变成"改动比例"的另一个写法，语义全错（见 `DiffReport.leak_ratio`）。
pub fn field_union(a : Field, b : Field) -> Field {
  let out = field_new(a.w, a.h)
  let mut i = 0
  let n = out.v.length()
  while i < n {
    let x = a.v[i]
    let y = b.v[i]
    out.v[i] = if x > y { x } else { y }
    i = i + 1
  }
  out
}

///|
/// 盒模糊均值（可分离滑动窗，O(N)）。
pub fn field_box_blur(f : Field, r : Double) -> Field {
  box_mean(f, trunc_pos(r))
}

///|
fn box_mean(f : Field, r : Int) -> Field {
  let out = field_new(f.w, f.h)
  let total = f.w * f.h
  if r < 1 {
    let mut i = 0
    while i < total {
      out.v[i] = f.v[i]
      i = i + 1
    }
    return out
  }
  let tmp = field_new(f.w, f.h)
  let win = 2 * r + 1
  let wd = win.to_double()
  let mut y = 0
  while y < f.h {
    let mut acc = 0.0
    let mut i = -r
    while i <= r {
      acc = acc + field_get(f, i, y)
      i = i + 1
    }
    let mut x = 0
    while x < f.w {
      tmp.v[y * f.w + x] = acc / wd
      acc = acc - field_get(f, x - r, y) + field_get(f, x + r + 1, y)
      x = x + 1
    }
    y = y + 1
  }
  // ⚠️ 第二趟是**竖着滑**：固定一列、窗口沿 y 滑；第一趟那个写法（固定一行、
  // 窗口沿 x 滑）**不能**照抄过来——窗口的"滑动方向"与"写出的方向"必须正交。
  // 实测照抄版（`acc` 只在第 0 列里滑、却写遍所有 x）会给出**负的均值**与斜向
  // 拖尾：`field_set` 一个 1.0 经它一遍变成一片 -0.11/0.11 的斜纹。这是
  // `box_mean` 自己的 bug（与调用方无关），所以修在**这一处**。
  let mut x2 = 0
  while x2 < f.w {
    let mut acc = 0.0
    let mut i = -r
    while i <= r {
      acc = acc + field_get(tmp, x2, i)
      i = i + 1
    }
    let mut y2 = 0
    while y2 < f.h {
      out.v[y2 * f.w + x2] = acc / wd
      acc = acc - field_get(tmp, x2, y2 - r) + field_get(tmp, x2, y2 + r + 1)
      y2 = y2 + 1
    }
    x2 = x2 + 1
  }
  out
}

///|
/// 场的**整数位移**（`out(p) = in(p − (dx,dy))`，窗外取 0）。
///
/// 为什么在 pixel 而不是 render：投影/内阴影的"偏移"是**场**上的操作，与模糊
/// 同族；写在两处（模糊一处、位移一处）就先烂一处。四舍五入取最近的整数像素
/// （亚像素位移会让结果依赖浮点尾数，而"投影偏 4.5 还是 4 像素"没人分得出来）。
pub fn field_shift(f : Field, dx : Double, dy : Double) -> Field {
  let out = field_new(f.w, f.h)
  let ox = iround(dx)
  let oy = iround(dy)
  if ox == 0 && oy == 0 {
    return field_copy(f)
  }
  let mut y = 0
  while y < f.h {
    let sy = y - oy
    if sy >= 0 && sy < f.h {
      let mut x = 0
      while x < f.w {
        let sx = x - ox
        if sx >= 0 && sx < f.w {
          out.v[y * f.w + x] = f.v[sy * f.w + sx]
        }
        x = x + 1
      }
    }
    y = y + 1
  }
  out
}

///|
/// 场的一份拷贝（位移量为 0 / 膨胀半径为 0 时的恒等路径，同时也是"别在调用方
/// 手搓逐元素循环"的那一处）。
fn field_copy(f : Field) -> Field {
  let out = field_new(f.w, f.h)
  let mut i = 0
  let total = f.w * f.h
  while i < total {
    out.v[i] = f.v[i]
    i = i + 1
  }
  out
}

///|
/// 四舍五入到最近整数（**远离 0** 那一侧；负数不许借 `to_int` 的截断语义）。
fn iround(v : Double) -> Int {
  if v >= 0.0 {
    trunc_pos(v + 0.5)
  } else {
    -trunc_pos(0.0 - v + 0.5)
  }
}

///|
/// 场的**膨胀**（最大值滤波，半径 r 像素：窗口 `2r+1`，窗外取 0）。
///
/// 可分离 + **单调队列**（每趟 O(N)）：朴素窗口是 `(2r+1)²`，r=64 时在
/// 4096×4096 画布上是几十亿次比较。最大/最小滤波不能像盒均值那样用"加减
/// 前缀和"，但可以用单调队列把每趟压到 O(N)——这是它该有的复杂度，不是优化。
pub fn field_dilate(f : Field, r : Double) -> Field {
  let ri = trunc_pos(r)
  if ri < 1 {
    return field_copy(f)
  }
  let tmp = max_axis(f, ri, true)
  max_axis(tmp, ri, false)
}

///|
/// 单趟（水平/垂直）最大值滤波。
fn max_axis(f : Field, r : Int, horizontal : Bool) -> Field {
  let out = field_new(f.w, f.h)
  let n = if horizontal { f.w } else { f.h }
  let lines = if horizontal { f.h } else { f.w }
  // 单调队列：队列里存下标，值从队头到队尾**递减**。窗口大小 2r+1，
  // 所以队列最多装 2r+1 个（队头是最小的下标，出窗即弹）。
  let dq : FixedArray[Int] = FixedArray::make(2 * r + 2, 0)
  let idx = fn(a : Int, b : Int) -> Int {
    if horizontal {
      a * f.w + b
    } else {
      b * f.w + a
    }
  }
  let mut line = 0
  while line < lines {
    let mut head = 0
    let mut tail = 0
    // 预填窗口的**左半边** [0, r]：`i=0` 时窗口是 `[-r, r]`，窗外取 0，
    // 所以只需要这一半（先 add 后 out 的写法会把 `i=0` 自己漏掉——实测角上的
    // 点被自己吃掉：3×3 的 (0,0) 膨胀后 (0,0) 是 0）。
    let mut k = 0
    while k <= r && k < n {
      let kv = f.v[idx(line, k)]
      while tail > head && f.v[idx(line, dq[tail - 1])] <= kv {
        tail = tail - 1
      }
      dq[tail] = k
      tail = tail + 1
      k = k + 1
    }
    let mut i = 0
    while i < n {
      if i > 0 {
        let add = i + r
        if add < n {
          let av = f.v[idx(line, add)]
          while tail > head && f.v[idx(line, dq[tail - 1])] <= av {
            tail = tail - 1
          }
          dq[tail] = add
          tail = tail + 1
        }
      }
      let drop = i - r - 1
      if drop >= 0 && head < tail && dq[head] == drop {
        head = head + 1
      }
      out.v[idx(line, i)] = if head < tail { f.v[idx(line, dq[head])] } else { 0.0 }
      i = i + 1
    }
    line = line + 1
  }
  out
}

// ---------------------------------------------------------------------------
// guided filter：软权重场边缘对齐（O(N) 盒滤波实现）
// ---------------------------------------------------------------------------

///|
/// He et al. guided filter，1 通道引导（base 的 OKLab L 作引导）。
/// 把颜色谓词得到的软场**对齐到图像真实边缘**——发丝级轮廓。纯算术。
pub fn guided_refine(
  guide : Field,
  p : Field,
  radius : Int,
  eps : Double,
) -> Field {
  let r = if radius < 1 { 1 } else { radius }
  let n = guide.w * guide.h
  let mean_i = box_mean(guide, r)
  let mean_p = box_mean(p, r)
  let ii = field_new(guide.w, guide.h)
  let mut k = 0
  while k < n {
    ii.v[k] = guide.v[k] * guide.v[k]
    k = k + 1
  }
  let mean_ii = box_mean(ii, r)
  let ip = field_new(guide.w, guide.h)
  k = 0
  while k < n {
    ip.v[k] = guide.v[k] * p.v[k]
    k = k + 1
  }
  let mean_ip = box_mean(ip, r)
  let a = field_new(guide.w, guide.h)
  let b = field_new(guide.w, guide.h)
  k = 0
  while k < n {
    let var_i = mean_ii.v[k] - mean_i.v[k] * mean_i.v[k]
    let cov_ip = mean_ip.v[k] - mean_i.v[k] * mean_p.v[k]
    let av = cov_ip / (var_i + eps)
    a.v[k] = av
    b.v[k] = mean_p.v[k] - av * mean_i.v[k]
    k = k + 1
  }
  let mean_a = box_mean(a, r)
  let mean_b = box_mean(b, r)
  let out = field_new(guide.w, guide.h)
  k = 0
  while k < n {
    let q = mean_a.v[k] * guide.v[k] + mean_b.v[k]
    out.v[k] = clamp01(q)
    k = k + 1
  }
  out
}

// ---------------------------------------------------------------------------
// 选择子求值
// ---------------------------------------------------------------------------

///|
/// 求值上下文：base 缓冲 + base 亮度引导场 + 外部 mask 资产。
pub(all) struct SelCtx {
  /// 不可变底图（求值基准 = base 的来源）
  base : @codec.RgbaBuf
  /// base 的 OKLab L 引导场（guided filter 用）
  luma : Field
  /// 外部 mask 资产（照片场景入口：SAM 类分割结果导入为内容寻址
  /// 资产，选择子引用它；引擎零依赖，不内置任何分割模型）
  masks : Map[String, Field]
}

///|
pub fn SelCtx::new(base : @codec.RgbaBuf) -> SelCtx {
  let luma = field_new(base.width, base.height)
  let total = base.width * base.height
  let mut i = 0
  while i < total {
    luma.v[i] = argb_to_oklab(base.pixels[i]).l
    i = i + 1
  }
  { base, luma, masks: Map([]) }
}

///|
fn atom_field(a : @core.AtomSel, ctx : SelCtx) -> Result[Field, String] {
  match a {
    @core.Color(w) => Ok(color_field(w, ctx))
    @core.Luma(lc, lh, f) => Ok(luma_field(lc, lh, f, ctx))
    @core.Geo(g, shape) => Ok(geo_field(g, shape, ctx))
    @core.GeoGrad(gw) => Ok(grad_field(gw, ctx))
    @core.Comp(sx, sy, tol, w) => comp_field(sx, sy, tol, w, ctx)
    @core.AssetMask(h) => match ctx.masks.get(h) {
      Some(m) => Ok(m)
      None =>
        Err(
          "外部 mask 资产未登记：\{h}（照片场景需先导入内容寻址 mask 资产；引擎零依赖，不内置分割）",
        )
    }
  }
}

///|
/// 彩窗三项（色相 / 彩度 / 亮度）的**单一实现点**。
///
/// 三项的域不同（色相是环上角距、彩度/亮度是绝对差），但判据与羽化完全同构。
/// 写成三行手写调用就是"三处各自算一遍"——实测往其中一行插入
/// `feather: 0.0`（只让色相项失去羽化）时，全部 154 条测试通过：其中一行
/// 被漏掉的羽化没有任何测试能发现。同一条教训见 AGENTS 铁律 7。
fn window3(dh : Double, ds : Double, dl : Double, w : @core.ColorWindow) -> Double {
  window_membership(dh, w.h_half, w.feather) *
  window_membership(ds, w.s_half, w.feather) *
  window_membership(dl, w.l_half, w.feather)
}

///|
/// OKLCh 色相环 + 饱和度 + 亮度三维软窗。
fn color_field(w : @core.ColorWindow, ctx : SelCtx) -> Field {
  let f = field_new(ctx.base.width, ctx.base.height)
  let total = ctx.base.width * ctx.base.height
  let mut i = 0
  while i < total {
    let lch = oklab_to_oklch(argb_to_oklab(ctx.base.pixels[i]))
    let hd = hue_ring_dist(lch.h, w.h_center)
    let sd = if lch.c > w.s_center {
      lch.c - w.s_center
    } else {
      w.s_center - lch.c
    }
    let ld = if lch.l > w.l_center {
      lch.l - w.l_center
    } else {
      w.l_center - lch.l
    }
    f.v[i] = window3(hd, sd, ld, w)
    i = i + 1
  }
  f
}

///|
/// OKLab L 亮度软窗（**不是** HSV V——V 不是感知亮度）。
fn luma_field(lc : Double, lh : Double, feather : Double, ctx : SelCtx) -> Field {
  let f = field_new(ctx.base.width, ctx.base.height)
  let total = ctx.base.width * ctx.base.height
  let mut i = 0
  while i < total {
    let v = ctx.luma.v[i]
    let d = if v > lc { v - lc } else { lc - v }
    f.v[i] = window_membership(d, lh, feather)
    i = i + 1
  }
  f
}

///|
/// 空间软窗（rect/ellipse，边缘 smoothstep）。
fn geo_field(g : @core.GeoWindow, shape : String, ctx : SelCtx) -> Field {
  let f = field_new(ctx.base.width, ctx.base.height)
  let w = ctx.base.width
  let h = ctx.base.height
  // ⚠️ **逐像素的最内层里不许有"解释型"的工作**：这里曾经把它写成
  // `if shape == "ellipse" { … } else { … }` 放在循环体里，等于**每个像素做一次
  // 字符串比较**。现在把判断提到循环外、宽度与下标收成局部量。
  //
  // ⚠️ **但别以为这能提速——实测在噪声内**（1024×1024、10 条整幅 recolor、
  // native release、`mvsl-impact`，各 3 次取中位）：改前 19.86 s / 1.894
  // µs/(像素·算子)，改后 20.05 s / 1.912 µs——**没有可分辨的差异**。
  // 真正的开销是**逐像素色彩变换**（OKLab/OKLCh 互转，手写 `msqrt`/`mcbrt`
  // 牛顿迭代），约 1.5 µs/像素；选择子求值只占约 0.4。保留这个写法的理由
  // 不是速度，而是**不依赖优化器**把字符串比较提出循环（wasm-gc 上未必做得到），
  // 而它的代价为零。白盒测试「geo_field 逐位对账 window_membership」钉住这次
  // 改写**没有改任何数值**。详见 PLAN 补遗十七。
  let is_ellipse = shape == "ellipse"
  let mut i = 0
  let mut y = 0
  while y < h {
    let mut x = 0
    while x < w {
      let px = x.to_double() + 0.5
      let py = y.to_double() + 0.5
      let d = if is_ellipse {
        ellipse_dist(px, py, g)
      } else {
        rect_dist(px, py, g)
      }
      // geo 选择子软覆盖 = 共享原语的「朝外 + smoothstep」预设。
      // `GeoWindow.feather` 在这里是**从窗边界向外**衰减到 0 的距离
      // （不是"窗内羽化宽度"，方向与蒙版的 feather 相反——实测见
      // `mvsl_wbtest.mbt` 的「软覆盖的方向」）。
      //
      // ⚠️ 两条都必须照抄旧实现，别`顺手化简`：
      // ①`t` 用 `(feather - d) / feather`，**不是** `1.0 - d / feather`——
      //   两者数学等价但浮点舍入不同（feather=3,d=1 时分别是 …666 与 …667），
      //   化简就等于悄悄改了每个软边像素；
      // ②`feather <= 0` 必须单独走硬边。若照公式算 `t=(0-d)/0`，边界上恰好
      //   `d=0` 会得到 `0/0 = NaN`（旧实现对 `d<=0` 给 1.0，这里照旧）。
      //   注：`soft_cover` 现在也接住 NaN（全函数），所以漏掉本分支不会再
      //   "挂死"，但仍会给出错的值——两道都要在。
      let cov = if g.feather <= 0.0 {
        if d <= 0.0 { 1.0 } else { 0.0 }
      } else {
        soft_cover((g.feather - d) / g.feather, Smooth)
      }
      f.v[i] = cov
      i = i + 1
      x = x + 1
    }
    y = y + 1
  }
  f
}

///|
/// 点到**矩形边界**的距离（矩形内为 0）。
///
/// 注意：不是「到中心的距离」。写成到中心的距离会让矩形中心只有
/// 半宽处才算命中，选区整体缩小一半以上——geo 谓词的第一号错误。
fn rect_dist(px : Double, py : Double, g : @core.GeoWindow) -> Double {
  let lo_x = g.x
  let hi_x = g.x + g.w
  let lo_y = g.y
  let hi_y = g.y + g.h
  let mut dx = 0.0
  if px < lo_x {
    dx = lo_x - px
  } else if px > hi_x {
    dx = px - hi_x
  }
  let mut dy = 0.0
  if py < lo_y {
    dy = lo_y - py
  } else if py > hi_y {
    dy = py - hi_y
  }
  msqrt(dx * dx + dy * dy)
}

///|
fn ellipse_dist(px : Double, py : Double, g : @core.GeoWindow) -> Double {
  let cx = g.x + g.w * 0.5
  let cy = g.y + g.h * 0.5
  let ax = g.w * 0.5
  let ay = g.h * 0.5
  if ax <= 0.0 || ay <= 0.0 {
    let ddx = px - cx
    let ddy = py - cy
    return msqrt(ddx * ddx + ddy * ddy)
  }
  let nx = (px - cx) / ax
  let ny = (py - cy) / ay
  let r = msqrt(nx * nx + ny * ny)
  let minor = if ax < ay { ax } else { ay }
  (r - 1.0) * minor
}

///|
/// 渐变空间谓词（地平线渐变这类需要权重衰减的场景）。
fn grad_field(gw : @core.GradWindow, ctx : SelCtx) -> Field {
  let f = field_new(ctx.base.width, ctx.base.height)
  let ax = gw.x1 - gw.x0
  let ay = gw.y1 - gw.y0
  let fo = if gw.falloff <= 0.0 { 0.000000001 } else { gw.falloff }
  let mut y = 0
  while y < ctx.base.height {
    let mut x = 0
    while x < ctx.base.width {
      let px = x.to_double() + 0.5
      let py = y.to_double() + 0.5
      let mut t = 0.0
      if ax != 0.0 || ay != 0.0 {
        if gw.axis == "x" {
          if ax != 0.0 {
            t = (px - gw.x0) / ax
          }
        } else if ay != 0.0 {
          t = (py - gw.y0) / ay
        }
      }
      f.v[y * ctx.base.width + x] = window_membership(t, 1.0 + fo, fo)
      x = x + 1
    }
    y = y + 1
  }
  f
}

///|
/// 种子连通域选择子：component_of(colorSel, seed, ΔEtol)。
///
/// 同色异义干扰（红苹果 h=2°/s=80% vs 红桌布 h=4°/s=78%）是唯一真
/// 考题——纯颜色谓词分不开，必须靠**连通性**（区域生长）。
/// 8 邻域洪泛，ΔE 超容差不连通。纯数学，无模型。
fn comp_field(
  sx : Double,
  sy : Double,
  de_tol : Double,
  w : @core.ColorWindow,
  ctx : SelCtx,
) -> Result[Field, String] {
  let soft = color_field(w, ctx)
  let wpx = ctx.base.width
  let hpx = ctx.base.height
  let seed_x = trunc_pos(sx)
  let seed_y = trunc_pos(sy)
  if seed_x < 0 || seed_x >= wpx || seed_y < 0 || seed_y >= hpx {
    return Err("comp 选择子种子点（\{@core.fmt_num(sx)},\{@core.fmt_num(sy)}）不在画布内")
  }
  if soft.v[seed_y * wpx + seed_x] <= 0.5 {
    return Err(
      "comp 选择子种子点不在 color 窗内（membership ≤ 0.5），无法区域生长——先放宽色窗或改种子点",
    )
  }
  let out = field_new(wpx, hpx)
  let visited = field_new(wpx, hpx)
  let ref_lab = argb_to_oklab(ctx.base.pixels[seed_y * wpx + seed_x])
  let stack : Array[(Int, Int)] = [(seed_x, seed_y)]
  visited.v[seed_y * wpx + seed_x] = 1.0
  while stack.length() > 0 {
    let top = stack.length() - 1
    let (cx, cy) = stack[top]
    let _ = stack.remove(top)
    out.v[cy * wpx + cx] = soft.v[cy * wpx + cx]
    let cur = argb_to_oklab(ctx.base.pixels[cy * wpx + cx])
    let mut dy = -1
    while dy <= 1 {
      let mut dx = -1
      while dx <= 1 {
        if !(dx == 0 && dy == 0) {
          let nx = cx + dx
          let ny = cy + dy
          if nx >= 0 && nx < wpx && ny >= 0 && ny < hpx {
            let ni = ny * wpx + nx
            if visited.v[ni] == 0.0 && soft.v[ni] > 0.5 {
              let nl = argb_to_oklab(ctx.base.pixels[ni])
              if delta_e(cur, nl) <= de_tol || delta_e(ref_lab, nl) <= de_tol {
                visited.v[ni] = 1.0
                stack.push((nx, ny))
              }
            }
          }
        }
        dx = dx + 1
      }
      dy = dy + 1
    }
  }
  Ok(out)
}

///|
/// 选择子表达式求值（递归；组合仍是软场）。
fn expr_field(e : @core.SelExpr, ctx : SelCtx) -> Result[Field, String] {
  match e {
    @core.Atom(a) => atom_field(a, ctx)
    @core.Union(items) => {
      let out = field_new(ctx.base.width, ctx.base.height)
      let total = out.w * out.h
      for it in items {
        let sub = match expr_field(it, ctx) {
          Ok(f) => f
          Err(msg) => return Err(msg)
        }
        let mut k = 0
        while k < total {
          if sub.v[k] > out.v[k] {
            out.v[k] = sub.v[k]
          }
          k = k + 1
        }
      }
      Ok(out)
    }
    @core.And(items) => {
      let result = field_new(ctx.base.width, ctx.base.height)
      let total = result.w * result.h
      for it in items {
        let sub = match expr_field(it, ctx) {
          Ok(f) => f
          Err(msg) => return Err(msg)
        }
        let mut k = 0
        while k < total {
          result.v[k] = result.v[k] * sub.v[k]
          k = k + 1
        }
      }
      Ok(result)
    }
    @core.Diff(a, b) => {
      let fa = match expr_field(a, ctx) {
        Ok(f) => f
        Err(msg) => return Err(msg)
      }
      let fb = match expr_field(b, ctx) {
        Ok(f) => f
        Err(msg) => return Err(msg)
      }
      let out = field_new(ctx.base.width, ctx.base.height)
      let total = out.w * out.h
      let mut k = 0
      while k < total {
        let d = fa.v[k] - fb.v[k]
        out.v[k] = if d > 0.0 { d } else { 0.0 }
        k = k + 1
      }
      Ok(out)
    }
  }
}

// ---------------------------------------------------------------------------
// 选区精修原语（作用于软权重场，顺序敏感）
// ---------------------------------------------------------------------------

///|
pub fn apply_refines(
  f : Field,
  list : Array[@core.Refine],
  ctx : SelCtx,
) -> Field {
  let mut cur = f
  let total = f.w * f.h
  for r in list {
    match r {
      @core.Grow(v) => {
        let b = field_box_blur(cur, v)
        let mut k = 0
        while k < total {
          if b.v[k] > cur.v[k] {
            cur.v[k] = b.v[k]
          }
          k = k + 1
        }
      }
      @core.Shrink(v) => {
        let b = field_box_blur(cur, v)
        let mut k = 0
        while k < total {
          if b.v[k] < cur.v[k] {
            cur.v[k] = b.v[k]
          }
          k = k + 1
        }
      }
      @core.Feather(v) => cur = field_box_blur(cur, v)
      @core.FillHoles => cur = fill_holes(cur)
      @core.KeepLargest => cur = keep_largest(cur)
      @core.Guided(r, eps) => cur = guided_refine(ctx.luma, cur, trunc_pos(r), eps)
    }
  }
  cur
}

///|
/// 填洞（外背景洪泛；未被前景包围的 0 → 1）。
fn fill_holes(f : Field) -> Field {
  let out = field_new(f.w, f.h)
  let visited = field_new(f.w, f.h)
  let stack : Array[(Int, Int)] = []
  let n = f.w * f.h
  let mut i = 0
  while i < n {
    let x = i % f.w
    let y = i / f.w
    if f.v[i] < 0.5 && visited.v[i] == 0.0 {
      if x == 0 || y == 0 || x == f.w - 1 || y == f.h - 1 {
        visited.v[i] = 1.0
        stack.push((x, y))
      }
    }
    i = i + 1
  }
  while stack.length() > 0 {
    let top = stack.length() - 1
    let (cx, cy) = stack[top]
    let _ = stack.remove(top)
    let mut d = 0
    while d < 4 {
      let (nx, ny) = step4(d, cx, cy)
      if nx >= 0 && nx < f.w && ny >= 0 && ny < f.h {
        let ni = ny * f.w + nx
        if visited.v[ni] == 0.0 && f.v[ni] < 0.5 {
          visited.v[ni] = 1.0
          stack.push((nx, ny))
        }
      }
      d = d + 1
    }
  }
  let mut k = 0
  while k < n {
    out.v[k] = if f.v[k] < 0.5 && visited.v[k] == 0.0 { 1.0 } else { f.v[k] }
    k = k + 1
  }
  out
}

///|
fn step4(d : Int, x : Int, y : Int) -> (Int, Int) {
  if d == 0 {
    (x - 1, y)
  } else if d == 1 {
    (x + 1, y)
  } else if d == 2 {
    (x, y - 1)
  } else {
    (x, y + 1)
  }
}

///|
/// 只保留最大连通域（4 邻域洪泛，阈值 0.5）。
fn keep_largest(f : Field) -> Field {
  let out = field_new(f.w, f.h)
  let visited = field_new(f.w, f.h)
  let n = f.w * f.h
  let mut best_count = 0
  let mut best : Array[(Int, Int)] = []
  let mut i = 0
  while i < n {
    if f.v[i] >= 0.5 && visited.v[i] == 0.0 {
      let comp = flood(f, visited, i)
      if comp.length() > best_count {
        best_count = comp.length()
        best = comp
      }
    }
    i = i + 1
  }
  for p in best {
    out.v[p.1 * f.w + p.0] = f.v[p.1 * f.w + p.0]
  }
  out
}

///|
fn flood(f : Field, visited : Field, start : Int) -> Array[(Int, Int)] {
  let comp : Array[(Int, Int)] = []
  let stack : Array[(Int, Int)] = [(start % f.w, start / f.w)]
  visited.v[start] = 1.0
  while stack.length() > 0 {
    let top = stack.length() - 1
    let (cx, cy) = stack[top]
    let _ = stack.remove(top)
    comp.push((cx, cy))
    let mut d = 0
    while d < 4 {
      let (nx, ny) = step4(d, cx, cy)
      if nx >= 0 && nx < f.w && ny >= 0 && ny < f.h {
        let ni = ny * f.w + nx
        if visited.v[ni] == 0.0 && f.v[ni] >= 0.5 {
          visited.v[ni] = 1.0
          stack.push((nx, ny))
        }
      }
      d = d + 1
    }
  }
  comp
}

// ---------------------------------------------------------------------------
// 算子应用
// ---------------------------------------------------------------------------

///|
/// OKLCh 色相重映射：改 h、preserve = OKLab L，chroma 在编码时 gamut
/// compress。**不是** HSV 色相旋转（那会连带改明暗）。
fn apply_recolor(argb : Int, hue_deg : Double) -> Int {
  let alpha = lsr32(argb, 24)
  let lch = oklab_to_oklch(argb_to_oklab(argb))
  let mut h = lch.h + hue_deg
  while h < 0.0 {
    h = h + 360.0
  }
  while h >= 360.0 {
    h = h - 360.0
  }
  oklab_to_argb(oklch_to_oklab({ l: lch.l, c: lch.c, h }), alpha)
}

///|
/// 色温偏移：沿蓝↔黄轴平移。**与 recolor 明确分家**——天空调暖用
/// hue remap 会变脏灰橙，因为色相重映射打散了原有色相关系。
fn apply_temperature(argb : Int, kelvin : Double) -> Int {
  let alpha = lsr32(argb, 24)
  let lab = argb_to_oklab(argb)
  let t = kelvin / 2000.0
  oklab_to_argb(
    { l: clamp01(lab.l + 0.02 * t), a: lab.a + 0.03 * t, b: lab.b + 0.10 * t },
    alpha,
  )
}

///|
/// 局部重打光：OKLab L 上的增益。
fn apply_relight(argb : Int, gain : Double) -> Int {
  let alpha = lsr32(argb, 24)
  let lab = argb_to_oklab(argb)
  oklab_to_argb({ l: clamp01(lab.l * gain), a: lab.a, b: lab.b }, alpha)
}

///|
/// 施加单个算子：out = lerp(in, op(in), w)，w = 软权重场。
/// w=0 处**逐位**保持 in（软边界 + 去污染的基石）。
pub fn apply_op(
  base : @codec.RgbaBuf,
  op : @core.EditOp,
  wfield : Field,
) -> @codec.RgbaBuf {
  let out = @codec.rgba_new(base.width, base.height)
  let total = base.width * base.height
  let mut i = 0
  while i < total {
    let in_c = base.pixels[i]
    let w = clamp01(wfield.v[i] * op.amount)
    if w <= 0.0 {
      out.pixels[i] = in_c
    } else {
      let op_c = match op.kind {
        @core.Recolor => apply_recolor(in_c, op.hue_deg)
        @core.Temperature => apply_temperature(in_c, op.temp_kelvin)
        @core.Relight => apply_relight(in_c, op.relight_gain)
      }
      out.pixels[i] = lerp_argb(in_c, op_c, w)
    }
    i = i + 1
  }
  out
}

///|
/// 逐通道软插值（out = lerp(in, op, t)）。
pub fn lerp_argb(c0 : Int, c1 : Int, t : Double) -> Int {
  let a0 = (lsr32(c0, 24)).to_double()
  let a1 = (lsr32(c1, 24)).to_double()
  let r0 = (lsr32(c0, 16) & 0xFF).to_double()
  let r1 = (lsr32(c1, 16) & 0xFF).to_double()
  let g0 = (lsr32(c0, 8) & 0xFF).to_double()
  let g1 = (lsr32(c1, 8) & 0xFF).to_double()
  let b0 = (c0 & 0xFF).to_double()
  let b1 = (c1 & 0xFF).to_double()
  let mix = fn(x : Double, y : Double) -> Int { quant8d(x + (y - x) * t) }
  (mix(a0, a1) << 24) + (mix(r0, r1) << 16) + (mix(g0, g1) << 8) + mix(b0, b1)
}

///|
fn quant8d(v : Double) -> Int {
  let q = v + 0.5
  if q < 0.0 {
    0
  } else if q > 255.0 {
    255
  } else {
    quant8d_loop(q, 0)
  }
}

///|
fn quant8d_loop(q : Double, acc : Int) -> Int {
  if q < 1.0 {
    acc
  } else {
    quant8d_loop(q - 1.0, acc + 1)
  }
}

///|
/// trunc(d)：d ≥ 0 的小数截断（像素坐标/半径用；不走饱和语义的 to_int）。
pub fn trunc_pos(d : Double) -> Int {
  if d <= 0.0 {
    0
  } else {
    trunc_loop(d, 0)
  }
}

///|
fn trunc_loop(d : Double, acc : Int) -> Int {
  if d < 1.0 {
    acc
  } else {
    trunc_loop(d - 1.0, acc + 1)
  }
}
