/// pixel —— 编辑表执行与数值证书（pixel/program）。
///
/// 三条不可让渡的语义（PLAN-MVSL.md §1.4/§1.5/§1.6）：
///
/// 1. **求值基准 = base**：选择子默认对不可变底图求值（选区稳定、
///    可重放、GUI 可开关中间算子后语义不漂移）；显式 STAGE(n) 才
///    求值到第 n 个算子之后。基准语义**写进 IR**，不靠隐式约定。
/// 2. **AI 不当色度计、render 不是 verifier**：数值收敛靠确定性指标
///    （区域 ΔE、选区外泄漏率、覆盖率、组件数）+ 断言；VLM 只做语义
///    判断（"选中的是不是头发"）。
/// 3. **AI 语义编译成确定性证据**：正/负种子点、覆盖率、组件事实 →
///    全部可序列化、可重放、可人工复核。
///
/// 计算缓存架构：(base_hash, field_spec) → field 缓存。同一选择子被
/// 多个算子引用时只求值一次——内容寻址从存储设计升级为**计算缓存**
/// 设计，这是大图软 mask 的性能前提。

///|
/// 选择子求值缓存：键是选择子 spec 的 canonical 文本。
pub(all) struct FieldCache {
  map : Map[String, Field]
}

///|
pub fn FieldCache::new() -> FieldCache {
  { map: Map([]) }
}

///|
pub fn selspec_key(s : @core.SelSpec) -> String {
  let basis = match s.basis {
    @core.Base => "b"
    @core.Stage(n) => "s\{n}"
  }
  basis + ":" + expr_key(s.expr)
}

///|
fn expr_key(e : @core.SelExpr) -> String {
  match e {
    @core.Atom(a) => atom_key(a)
    @core.Union(items) => "U(" + items_key(items) + ")"
    @core.And(items) => "A(" + items_key(items) + ")"
    @core.Diff(a, b) => "D(\{expr_key(a)},\{expr_key(b)})"
  }
}

///|
fn items_key(items : Array[@core.SelExpr]) -> String {
  let sb = StringBuilder()
  let mut f = true
  for it in items {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(expr_key(it))
  }
  sb.to_string()
}

///|
fn atom_key(a : @core.AtomSel) -> String {
  match a {
    @core.Color(w) =>
      "C(\{@core.fmt_num(w.h_center)},\{@core.fmt_num(w.h_half)},\{@core.fmt_num(w.s_center)},\{@core.fmt_num(w.s_half)},\{@core.fmt_num(w.l_center)},\{@core.fmt_num(w.l_half)},\{@core.fmt_num(w.feather)})"
    @core.Luma(lc, lh, f) =>
      "L(\{@core.fmt_num(lc)},\{@core.fmt_num(lh)},\{@core.fmt_num(f)})"
    @core.Geo(g, shape) =>
      "G\{shape}(\{@core.fmt_num(g.x)},\{@core.fmt_num(g.y)},\{@core.fmt_num(g.w)},\{@core.fmt_num(g.h)},\{@core.fmt_num(g.feather)})"
    @core.GeoGrad(gw) =>
      "GG(\{@core.fmt_num(gw.x0)},\{@core.fmt_num(gw.y0)},\{@core.fmt_num(gw.x1)},\{@core.fmt_num(gw.y1)},\{gw.axis},\{@core.fmt_num(gw.falloff)})"
    @core.Comp(sx, sy, tol, w) =>
      "K(\{@core.fmt_num(sx)},\{@core.fmt_num(sy)},\{@core.fmt_num(tol)})" + atom_key(@core.Color(w))
    @core.AssetMask(h) => "M(\{h})"
  }
}

///|
/// 求一个选择子（带缓存），返回精修前的软权重场。
/// 精修顺序敏感（grow→feather→guided 结果不同），故缓存原子场，
/// 精修在算子侧按各自 refine 列表施加。
pub fn eval_sel(
  s : @core.SelSpec,
  ctx : SelCtx,
  cache : FieldCache,
) -> Result[Field, String] {
  let key = selspec_key(s)
  match cache.map.get(key) {
    Some(f) => Ok(f)
    None => {
      let f = match expr_field(s.expr, ctx) {
        Ok(x) => x
        Err(msg) => return Err(msg)
      }
      cache.map.set(key, f)
      Ok(f)
    }
  }
}

///|
/// 单算子的软权重场（含精修，w 已乘 amount）。
pub fn op_weight(
  op : @core.EditOp,
  ctx : SelCtx,
  cache : FieldCache,
) -> Result[Field, String] {
  let raw = match eval_sel(op.sel, ctx, cache) {
    Ok(f) => f
    Err(msg) => return Err(msg)
  }
  let refined = apply_refines(raw, op.refine, ctx)
  let out = field_new(refined.w, refined.h)
  let total = refined.w * refined.h
  let mut k = 0
  while k < total {
    out.v[k] = clamp01(refined.v[k] * op.amount)
    k = k + 1
  }
  Ok(out)
}

// ---------------------------------------------------------------------------
// 执行管线
// ---------------------------------------------------------------------------

///|
/// 算子选择子的**求值基底**：`stage:n` 落在哪个缓冲上。
///
/// `n == 0` = **本段的输入**（单段时=底图；文档级段里=层合成结果），否则是
/// 第 n 个算子之后的中间缓冲。这是这句判断的**唯一实现**——执行器
/// （`run_program`）与"逐算子报告"（`render.ImpactStage.basis`）都必须用它，
/// 否则报告出去的基底与真渲染用的不是同一张图：`agent` 侧三个消费者
/// （`mvsl-impact` 的逐算子数字、`lint` 的空操作判定、`census` 的连通域标签）
/// 都拿 `basis` **重算**选择子权重，基底错 = 报出去的每个数字都错，而渲染是对的。
pub fn stage_basis_of(
  base : @codec.RgbaBuf,
  stages : Array[@codec.RgbaBuf],
  n : Int,
) -> @codec.RgbaBuf {
  if n == 0 {
    base
  } else {
    stages[n - 1]
  }
}

///|
/// 执行整张编辑表：base → 逐算子应用 → 最终缓冲。
/// 返回 (最终缓冲, 各步中间缓冲数组)。
///
/// **空编辑表逐位还原短路**：`ops.length() == 0` 时直接返回 base 本身，
/// 不经任何色彩变换——bit-exact 契约的基石（P0 语义 2）。
pub fn run_program(
  base : @codec.RgbaBuf,
  prog : @core.EditProgram,
) -> Result[(@codec.RgbaBuf, Array[@codec.RgbaBuf]), String] {
  if prog.ops.length() == 0 {
    return Ok((base, []))
  }
  // 求值上下文与缓存：BASE 基准算子共享（选区稳定 + 只求值一次）
  let base_ctx = SelCtx::new(base)
  let base_cache = FieldCache::new()
  let stages : Array[@codec.RgbaBuf] = []
  let mut cur = base
  let mut i = 0
  while i < prog.ops.length() {
    let op = prog.ops[i]
    let w = match op.sel.basis {
      @core.Base => match op_weight(op, base_ctx, base_cache) {
        Ok(f) => f
        Err(msg) => return Err(msg)
      }
      @core.Stage(n) => {
        if n > i {
          return Err(
            "算子 \{op.id} 的 STAGE(\{n}) 超出可用前置阶段（自身序号 \{i}）——拒绝前视引用",
          )
        }
        // STAGE(0) = 本段输入；STAGE(n) = 第 n 个算子之后的中间缓冲
        // （与"逐算子报告"共用 `stage_basis_of` 一处实现）。
        let sbuf = stage_basis_of(base, stages, n)
        let sctx = SelCtx::new(sbuf)
        match op_weight(op, sctx, FieldCache::new()) {
          Ok(f) => f
          Err(msg) => return Err(msg)
        }
      }
    }
    cur = apply_op(cur, op, w)
    stages.push(cur)
    i = i + 1
  }
  Ok((cur, stages))
}

// ---------------------------------------------------------------------------
// 数值证书：覆盖率 / bbox / 连通域 / ΔE / 泄漏率
// ---------------------------------------------------------------------------

///|
/// 二值化阈值（证书与断言统一口径）。
pub const CERT_THRESHOLD : Double = 0.5

///|
/// 一个连通域的确定性事实（AI 选 ID、不报坐标——引擎从实际 selector
/// 推导，纯数学）。
pub(all) struct Component {
  id : Int
  x0 : Int
  y0 : Int
  x1 : Int
  y1 : Int
  cx : Double // 质心
  cy : Double
  area : Int
  mean_l : Double
  mean_a : Double
  mean_b : Double
  /// 颜色摘要（与 probe/census 共用同一实现——三处报的数字必须同源）
  stats : ColorStats
}

///|
/// 选择子求值的数值证书。
pub(all) struct Certificate {
  total : Int
  coverage : Double // Σw / total
  bbox : (Int, Int, Int, Int)
  components : Array[Component]
}

///|
/// 证书 + 连通域**标签场**（0 = 背景，k = 第 k 个连通域）。
///
/// 标签是 `probe` 能回答「这个点在哪个连通域里」的前提：只给组件事实
/// 列表的话，调用方得自己拿 bbox 做包含判断——bbox 重叠时就会指错。
/// 标签场与 `components()` 共用同一趟扫描，编号严格一致。
pub(all) struct Certified {
  cert : Certificate
  labels : Field
}

///|
/// 求选择子证书（阈值化后取连通域；覆盖率用全软场）。
pub fn certify(base : @codec.RgbaBuf, w : Field) -> Certificate {
  certify_full(base, w).cert
}

///|
/// 求选择子证书 + 标签场（probe / 组件 id 查询用）。
pub fn certify_full(base : @codec.RgbaBuf, w : Field) -> Certified {
  let total = w.w * w.h
  let cov = field_sum(w) / total.to_double()
  let mut bx0 = w.w
  let mut by0 = w.h
  let mut bx1 = -1
  let mut by1 = -1
  let mut y = 0
  while y < w.h {
    let mut x = 0
    while x < w.w {
      if w.v[y * w.w + x] >= CERT_THRESHOLD {
        if x < bx0 {
          bx0 = x
        }
        if x > bx1 {
          bx1 = x
        }
        if y < by0 {
          by0 = y
        }
        if y > by1 {
          by1 = y
        }
      }
      x = x + 1
    }
    y = y + 1
  }
  if bx1 < 0 {
    bx0 = 0
    by0 = 0
    bx1 = 0
    by1 = 0
  }
  let labels = field_new(w.w, w.h)
  let comps = scan_components(base, w, Some(labels))
  {
    cert: { total, coverage: cov, bbox: (bx0, by0, bx1, by1), components: comps },
    labels,
  }
}

///|
/// 选择子的连通域标签场（0 = 背景；k = 按栅格序发现的第 k 个连通域）。
pub fn label_components(base : @codec.RgbaBuf, f : Field) -> Field {
  let labels = field_new(f.w, f.h)
  let _ = scan_components(base, f, Some(labels))
  labels
}

///|
/// 8 邻域连通域（洪泛，纯数学；颜色事实取自不可变 base）。
/// `labels` 非空时同时写出逐像素标签（编号 = 发现先后 + 1）。
fn scan_components(
  base : @codec.RgbaBuf,
  f : Field,
  labels : Field?,
) -> Array[Component] {
  let visited = field_new(f.w, f.h)
  let comps : Array[Component] = []
  let n = f.w * f.h
  let mut i = 0
  while i < n {
    if f.v[i] < CERT_THRESHOLD || visited.v[i] > 0.0 {
      i = i + 1
      continue
    }
    let sx = i % f.w
    let sy = i / f.w
    // 编号在洪泛前就确定（= 已发现组件数 + 1），洪泛期间即可写标签
    let cid = comps.length() + 1
    visited.v[i] = 1.0
    match labels {
      Some(lb) => lb.v[i] = cid.to_double()
      None => ()
    }
    let stack : Array[(Int, Int)] = [(sx, sy)]
    let mut area = 0
    let mut x0 = sx
    let mut x1 = sx
    let mut y0 = sy
    let mut y1 = sy
    let mut sumx = 0.0
    let mut sumy = 0.0
    let acc = color_acc_new()
    let mut sl = 0.0
    let mut sa = 0.0
    let mut sb = 0.0
    while stack.length() > 0 {
      let top = stack.length() - 1
      let (cx, cy) = stack[top]
      let _ = stack.remove(top)
      area = area + 1
      sumx = sumx + cx.to_double()
      sumy = sumy + cy.to_double()
      if cx < x0 {
        x0 = cx
      }
      if cx > x1 {
        x1 = cx
      }
      if cy < y0 {
        y0 = cy
      }
      if cy > y1 {
        y1 = cy
      }
      let argb = base.pixels[cy * f.w + cx]
      let lab = argb_to_oklab(argb)
      sl = sl + lab.l
      sa = sa + lab.a
      sb = sb + lab.b
      color_acc_add(acc, argb)
      let mut dy = -1
      while dy <= 1 {
        let mut dx = -1
        while dx <= 1 {
          if !(dx == 0 && dy == 0) {
            let nx = cx + dx
            let ny = cy + dy
            if nx >= 0 && nx < f.w && ny >= 0 && ny < f.h {
              let ni = ny * f.w + nx
              if visited.v[ni] == 0.0 && f.v[ni] >= CERT_THRESHOLD {
                visited.v[ni] = 1.0
                match labels {
                  Some(lb) => lb.v[ni] = cid.to_double()
                  None => ()
                }
                stack.push((nx, ny))
              }
            }
          }
          dx = dx + 1
        }
        dy = dy + 1
      }
    }
    let ad = area.to_double()
    comps.push({
      id: cid,
      x0,
      y0,
      x1,
      y1,
      cx: sumx / ad,
      cy: sumy / ad,
      area,
      mean_l: sl / ad,
      mean_a: sa / ad,
      mean_b: sb / ad,
      stats: color_acc_finish(acc),
    })
    i = i + 1
  }
  comps
}

///|
/// 环上平均角度（atan2(sin 均值, cos 均值)）。
fn ring_mean_angle(cos_sum : Double, sin_sum : Double) -> Double {
  let h = matan2(sin_sum, cos_sum) * 180.0 / 3.141592653589793
  let mut r = h
  while r < 0.0 {
    r = r + 360.0
  }
  while r >= 360.0 {
    r = r - 360.0
  }
  r
}

// ---------------------------------------------------------------------------
// ΔE / 泄漏率 / 断言
// ---------------------------------------------------------------------------

///|
/// 前后差异统计（impact / dry-run 证书）。w = 该算子的软权重场。
pub(all) struct DiffReport {
  changed : Int
  total : Int
  mean_de : Double // 全图平均 ΔE
  max_de : Double
  sel_de : Double // 选择子**核心区**（membership ≥ CERT_THRESHOLD）平均 ΔE
  /// 支撑集之外（membership 精确为 0）被改动的像素占比。
  ///
  /// **这是一个不变量，结构上恒为 0**：算子写成 `out = lerp(in, op(in), w)`，
  /// w=0 处逐位取原像素，任何算子都不可能写到选择子支撑集之外。所以它不度量
  /// "选择子有多软"，而是兜住"某个算子的实现越界写了"这类引擎 bug。
  ///
  /// 曾经这里是按 `CERT_THRESHOLD`（0.5）判"选区内"的：那会把软选择子的
  /// 过渡带（0 < w < 0.5）算成"选区外"，于是每个带柔边的选择子都报出非零
  /// "泄漏率"——而过渡带本来就是要改的区域。这既是错的，又会把模型引向
  /// "我改到了选区外，得收缩选择子"的错误结论。
  leak_ratio : Double
}

///|
pub fn diff_report(
  before : @codec.RgbaBuf,
  after : @codec.RgbaBuf,
  w : Field,
) -> DiffReport {
  let total = before.width * before.height
  let mut changed = 0
  let mut de_sum = 0.0
  let mut max_de = 0.0
  let mut sel_de_sum = 0.0
  let mut sel_n = 0
  let mut leak = 0
  let mut out_n = 0
  let mut i = 0
  while i < total {
    let c0 = before.pixels[i]
    let c1 = after.pixels[i]
    let de = delta_e_argb(c0, c1)
    de_sum = de_sum + de
    if de > max_de {
      max_de = de
    }
    if c0 != c1 {
      changed = changed + 1
    }
    // 两个判据服务于两件事，别合并：
    //   core       —— "选择子核心区"，给 sel_de 用（核心区才是「要改的地方」）
    //   in_support —— "选择子支撑集"，给 leak_ratio 用（支撑集外必须逐位不变）
    // 合并成一个 0.5 判据就会把软过渡带误报成泄漏，见 DiffReport.leak_ratio。
    if w.v[i] >= CERT_THRESHOLD {
      sel_de_sum = sel_de_sum + de
      sel_n = sel_n + 1
    }
    if w.v[i] > 0.0 {
      ()
    } else {
      out_n = out_n + 1
      if c0 != c1 {
        leak = leak + 1
      }
    }
    i = i + 1
  }
  {
    changed,
    total,
    mean_de: de_sum / total.to_double(),
    max_de,
    sel_de: if sel_n > 0 { sel_de_sum / sel_n.to_double() } else { 0.0 },
    leak_ratio: if out_n > 0 { leak.to_double() / out_n.to_double() } else { 0.0 },
  }
}

///|
/// 断言检查：保护区域「别动人物」——命令信封直接 fail。
/// 返回失败原因列表（空 = 全过）。
pub fn check_guards(
  before : @codec.RgbaBuf,
  after : @codec.RgbaBuf,
  prog : @core.EditProgram,
) -> Result[Array[String], String] {
  let fails : Array[String] = []
  let ctx = SelCtx::new(before)
  let cache = FieldCache::new()
  for g in prog.guards {
    let raw = match eval_sel(g.sel, ctx, cache) {
      Ok(f) => f
      Err(msg) => return Err(msg)
    }
    let total = before.width * before.height
    let mut de_sum = 0.0
    let mut n = 0
    let mut changed = 0
    let mut i = 0
    while i < total {
      if raw.v[i] >= CERT_THRESHOLD {
        let c0 = before.pixels[i]
        let c1 = after.pixels[i]
        de_sum = de_sum + delta_e_argb(c0, c1)
        n = n + 1
        if c0 != c1 {
          changed = changed + 1
        }
      }
      i = i + 1
    }
    if n == 0 {
      // 保护区域为空：无约束可验（如实跳过，不算失败）
      continue
    }
    let mean_de = de_sum / n.to_double()
    let ratio = changed.to_double() / n.to_double()
    if mean_de > g.max_de {
      fails.push(
        "断言 \{g.id} 违反：保护区平均 ΔE=\{@core.fmt_num(mean_de)} > 上限 \{@core.fmt_num(g.max_de)}",
      )
    }
    if ratio > g.max_changed_ratio {
      fails.push(
        "断言 \{g.id} 违反：保护区改动比例=\{@core.fmt_num(ratio)} > 上限 \{@core.fmt_num(g.max_changed_ratio)}",
      )
    }
  }
  Ok(fails)
}

///|
/// IoU（两张软场按阈值二值化）。Phase 1 表达力上限测试用。
pub fn iou(a : Field, b : Field) -> Double {
  let n = a.w * a.h
  let mut inter = 0.0
  let mut union = 0.0
  let mut k = 0
  while k < n {
    let ia = a.v[k] >= CERT_THRESHOLD
    let ib = b.v[k] >= CERT_THRESHOLD
    if ia && ib {
      inter = inter + 1.0
    }
    if ia || ib {
      union = union + 1.0
    }
    k = k + 1
  }
  if union <= 0.0 {
    0.0
  } else {
    inter / union
  }
}

///|
/// 选中率有限差分：参数 ±δ 时的覆盖率变化（参数敏感性诊断）。
/// 「覆盖率对色窗宽度不敏感」= 选择子没有真正收窄区域。
pub fn coverage_delta(
  ctx : SelCtx,
  op : @core.EditOp,
  delta : Double,
) -> Result[(Double, Double), String] {
  let cache = FieldCache::new()
  let w0 = match op_weight(op, ctx, cache) {
    Ok(f) => f
    Err(msg) => return Err(msg)
  }
  let shifted = shift_hue_window(op, delta)
  let probe = { ..op, sel: shifted }
  let w1 = match op_weight(probe, ctx, FieldCache::new()) {
    Ok(f) => f
    Err(msg) => return Err(msg)
  }
  let n0 = (w0.w * w0.h).to_double()
  let n1 = (w1.w * w1.h).to_double()
  Ok((field_sum(w0) / n0, field_sum(w1) / n1))
}

///|
/// 色窗色相平移（有限差分探针用；不改原 IR）。
fn shift_hue_window(op : @core.EditOp, delta : Double) -> @core.SelSpec {
  match op.sel.expr {
    @core.Atom(@core.Color(w)) => {
      let w2 = { ..w, h_center: w.h_center + delta }
      let expr : @core.SelExpr = @core.Atom(@core.Color(w2))
      { basis: op.sel.basis, expr }
    }
    _ => op.sel
  }
}
