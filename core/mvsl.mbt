/// core —— MVSL 编辑表 IR（core/mvsl）。
///
/// MVSL = 面向 agentic image editing 的确定性声明式编辑 IR：
/// 不可变内容寻址 base + 谓词选择子（软权重场 [0,1]）+ 显式有序算子程序
/// + 保护断言。PLAN-MVSL.md 的执行落点。
///
/// 语义三决定（写进容器 manifest 与本 IR，评审共识 §1.4/§1.7）：
/// 1. **选择子求值基准 = base**（不可变底图），显式标注才允许 STAGE(n)；
///    选区因此稳定、可重放、GUI 可开关中间算子后语义不漂移。
/// 2. **算子显式有序**，canonical 化只做序列化契约（固定字段序 + 定点
///    数字格式），**绝不重排**——重排会改变 A∘B≠B∘A 的执行结果。
/// 3. **render contract version** 独立版本化：算子语义 / 选择子算法 /
///    色彩语义三者分别 pin；旧引擎遇未知 op 或更高版本一律拒绝，
///    不静默错渲（bit-exact 契约的诚实边界）。
///
/// 纪律：
/// - 选择子输出**软权重场**而非布尔：0=不选，1=完全在内，之间为过渡带；
/// - 所有算子 `out = lerp(in, op(in), w)`，w ∈ [0,1]；
/// - 色彩语义：recolor 在 OKLCh 改 h、preserve = OKLab L、chroma 做
///   gamut compress；HSV 降级为 selector/analysis affordance field
///   （V 不是感知亮度：纯绿 Y≈0.72 vs 纯蓝 Y≈0.07）；
/// - AI 语义必须编译成**确定性证据**（正/负种子点）进 canonical JSON，
///   不得引用不透明模型输出——否则 .mpd 退化为模型运行时 artifact；
/// - 历史日志（meta/agent.json）与当前 canonical program 分离：编辑表
///   是状态，edits 是轨迹。

///|
/// 编辑表 IR 版本（选择子/算子的**语法**版本）。
pub const MVSL_IR_VERSION : Int = 1

///|
/// render contract version：渲染契约（色彩+数值+算子语义）总版本。
/// 旧引擎遇更高版本直接拒绝打开。
///
/// 契约的**档位**（`required_render_contract` 报"这份文档实际用到的最低档"，
/// 读入端拿这里的**上限**拒）。加一档前先问一句："老引擎拿到这份文档会**画成
/// 什么**"——只要答案不是"拒绝"而是"画错"，就必须升档，否则就是静默错渲。
///   * 1 = 基础；
///   * 2 = **蒙版毛边**（`LayerMask.roughen`）：老引擎读不到这个字段，会把毛边
///         蒙版画成**光滑边**；
///   * 3 = **多边形蒙版**（`LayerMask.kind = Polygon`）：老引擎的 `mask_cover_at`
///         只认 Ellipse、其余一律当**矩形**画 ⇒ 套索选区会被画成一个方框。
///   * 4 = **仿制图章**（`Dab.clone` + 源偏移）：老引擎读不到这三个字段，会把
///         克隆笔触当成**普通笔色**画上去 ⇒ 整笔变成一块死色（而"污点被盖住了"
///         还很像成功了）。
pub const RENDER_CONTRACT_ROUGHEN : Int = 2

///|
pub const RENDER_CONTRACT_POLY_MASK : Int = 3

///|
pub const RENDER_CONTRACT_CLONE : Int = 4

///|
/// 引擎支持的**最高**档（读入端：`render_contract > 它` 一律拒绝打开，
/// 见 `mpd/mpd.mbt`）。
pub const RENDER_CONTRACT_VERSION : Int = 4

///|
/// 选择子算法版本（kernel/window/环距约定都属于算法的一部分）。
pub const SELECTOR_ALGO_VERSION : String = "mvsl-sel-1"

///|
/// 色彩语义版本（OKLab/OKLCh + gamut compress 策略）。
pub const COLOR_SEMANTICS_VERSION : String = "oklch-1"

///|
/// 算子语义版本。
pub const OP_SEMANTICS_VERSION : String = "mvsl-op-1"

// ---------------------------------------------------------------------------
// 选择子
// ---------------------------------------------------------------------------

///|
/// 选择子求值基准：默认 Base（不可变底图）；Stage(n) 显式标注才允许。
pub(all) enum SelBasis {
  Base
  Stage(Int)
}

///|
/// OKLCh 色相环 + 饱和度 + 亮度的软窗（h 按**环**处理，注意 wrap-around：
/// h=359° 与 h=1° 的距离是 2° 而非 358°）。
pub(all) struct ColorWindow {
  h_center : Double // 0..360
  h_half : Double // 色相半窗宽（度）
  s_center : Double // 0..1
  s_half : Double
  l_center : Double // OKLab L 0..1
  l_half : Double
  feather : Double // 0..1，窗内 smoothstep 过渡带宽（0=硬边）
}

///|
/// 空间谓词参数。
pub(all) struct GeoWindow {
  x : Double
  y : Double
  w : Double
  h : Double
  feather : Double // 边缘 softstep 带宽（像素）
}

///|
/// 渐变空间谓词（地平线渐变这类需要权重衰减的场景）。
pub(all) struct GradWindow {
  x0 : Double
  y0 : Double
  x1 : Double
  y1 : Double
  axis : String // "x" | "y"（沿该轴从 (x0,y0) 到 (x1,y1) 衰减）
  falloff : Double // 0..1 过渡带宽占比
}

///|
/// 原子选择子。**全部输出 [0,1] 软权重**，不输出布尔。
pub(all) enum AtomSel {
  /// OKLCh 色相环软窗（动漫/图形同色换色的主入口）
  Color(ColorWindow)
  /// OKLab L 亮度软窗（V 不是感知亮度，谓词一律走 L）
  Luma(Double, Double, Double) // l_center, l_half, feather
  /// 矩形/椭圆空间窗
  Geo(GeoWindow, String) // shape: "rect" | "ellipse"
  /// 渐变空间窗
  GeoGrad(GradWindow)
  /// 种子连通域：component_of(base 色窗, seed, ΔE 容差)——
  /// 同色异义干扰（红苹果 h=2° vs 红桌布 h=4°）的唯一真考题出口。
  Comp(Double, Double, Double, ColorWindow) // seed_x, seed_y, de_tol, 色窗
  /// 外部 mask 资产（内容寻址 hash）：照片场景的入口——
  /// SAM 类分割结果导入为资产，选择子引用，引擎保持零依赖。
  AssetMask(String)
}

///|
/// 选择子表达式：原子 + 布尔组合（组合仍是软场，逐点乘法/取极值）。
pub(all) enum SelExpr {
  Atom(AtomSel)
  /// 并集：max(w)
  Union(Array[SelExpr])
  /// 交：prod(w)
  And(Array[SelExpr])
  /// 差：clamp(w0 − w1)
  Diff(SelExpr, SelExpr)
}

///|
/// 选择子求值基准 + 表达式（求值基准必须显式进 IR）。
pub(all) struct SelSpec {
  basis : SelBasis
  expr : SelExpr
}

///|
/// 选区精修原语（作用于软权重场，顺序敏感）。
pub(all) enum Refine {
  Grow(Double) // 半径 px
  Shrink(Double)
  Feather(Double) // 半径 px
  FillHoles
  KeepLargest
  /// guided filter 边缘对齐精修：r=半径 px, eps=正则项
  Guided(Double, Double)
}

// ---------------------------------------------------------------------------
// 算子
// ---------------------------------------------------------------------------

///|
/// 算子种类。**色温偏移与色相重映射是两个算子**（天空调暖用 hue remap
/// 会变脏灰橙）——不做合并，这是评审点名的高价值区分。
pub(all) enum OpKind {
  /// OKLCh 色相重映射：改 h，preserve = OKLab L，chroma gamut compress
  Recolor
  /// 色温偏移：沿蓝↔黄轴平移（保留 h 的相对结构，不重映射）
  Temperature
  /// 局部重打光：OKLab L 上的增益
  Relight
}

///|
/// 确定性证据：AI 的语义判断编译成可序列化事实（种子点），随编辑表
/// 落盘、可重放、可人工复核。**不是**求值输入（除 Comp 选择子用 seed
/// 做区域生长），而是证书锚点与 provenance。
pub(all) struct Evidence {
  label : String // 语义名（如 "红苹果"）—— 记录，不参与求值
  pos_seeds : Array[(Double, Double)] // 正样本种子点
  neg_seeds : Array[(Double, Double)] // 负样本（不应被选中的点）
}

///|
/// 一条编辑（算子实例）。id 稳定——AI 反复修正时 update 而非 append
/// 堆叠（`hue+=20` 叠三次是「操作录像带」腐化的主因）。
pub(all) struct EditOp {
  id : String
  kind : OpKind
  sel : SelSpec
  amount : Double // 0..1 整体强度（乘到权重上）
  hue_deg : Double // Recolor: 目标色相偏移（度）
  temp_kelvin : Double // Temperature: 目标色温偏移（K，正=暖）
  relight_gain : Double // Relight: 增益（>1 提亮）
  layer : String // 作用域：""=文档级（合成底图上）；非空=只作用于该图层
  refine : Array[Refine]
  note : String
  evidence : Evidence?
}

///|
/// 保护断言：「别动人物」从自然语言愿望变成机器可验证约束。
pub(all) struct Guard {
  id : String
  sel : SelSpec // 保护区域
  max_de : Double // 区内平均 ΔE 上限（OKLab）
  max_changed_ratio : Double // 区内改动像素比例上限
}

///|
/// 编辑表：显式有序的算子程序 + 保护断言。
pub(all) struct EditProgram {
  ops : Array[EditOp] // 顺序即语义，canonical 化不重排
  guards : Array[Guard]
}

///|
pub fn EditProgram::new() -> EditProgram {
  { ops: [], guards: [] }
}

///|
/// 编辑表是否为空（空表 → 渲染逐位短路，不经任何色彩变换）。
pub fn EditProgram::is_empty(p : EditProgram) -> Bool {
  p.ops.length() == 0
}

///|
/// 是否含**图层级算子**（`layer` 非空）。渲染据此决定走单段还是两段式。
pub fn program_has_layer_scope(p : EditProgram) -> Bool {
  for op in p.ops {
    if op.layer != "" {
      return true
    }
  }
  false
}

///|
/// 该编辑表引用到的全部图层 id（去重，保持首次出现顺序）。
pub fn program_layer_ids(p : EditProgram) -> Array[String] {
  let out : Array[String] = []
  for op in p.ops {
    if op.layer == "" {
      continue
    }
    let mut seen = false
    for x in out {
      if x == op.layer {
        seen = true
      }
    }
    if !seen {
      out.push(op.layer)
    }
  }
  out
}

///|
/// 取出**一个段**的算子（`keep` = 该段算子的 `layer` 值：`""` = 文档级段），
/// 并把 `stage:n` 从**表序**改写成**段内序号**。
///
/// 这是"拆段 + 重编号"的**唯一实现**——文档级段与每个被引用的层段走同一段代码，
/// 于是"段内第 n 条不是表里第 n 条"只需要在一处处理（两段各写一遍必然有一边先烂）。
/// 返回值是直接交给 `pixel.run_program` 跑的段程序，而 `run_program` 的 `Stage(n)`
/// 是**段内**下标：不改写就会**静默指到别的缓冲**——`stage:n` 的声明含义是
/// "**表里**第 n 条算子之后的中间缓冲"，而别的段的算子被剔出去之后，段内第 n 条
/// 并不是表里第 n 条（前面每插一条**别段**的算子，取到的缓冲就整体前移一格）。
///
/// 实测（`render/mvsl_render_test.mbt`：表 = 层算子 · a · b · c(`stage:2`)）：
/// 改写前 `c` 的基准指到 **b** 的输出而不是声明的 **a**，而校验放行、lint 不报、
/// 渲染照做——正是本仓库最反对的那类"看起来成功了"。
///
/// 只改写到**与本段同段**的目标上（`p.ops[n-1].layer == keep`）：跨段引用是
/// `layer_scope_error` 的活（入口、lint、渲染共用同一句），这里原样保留，
/// 不发明第二种处置。
fn segment_ops(p : EditProgram, keep : String) -> Array[EditOp] {
  // 表序（1 基）→ 本段内序号（1 基）；别的段的算子填 0（本段用不到）。
  let seg_no : Array[Int] = []
  let mut next = 0
  for op in p.ops {
    if op.layer == keep {
      next = next + 1
      seg_no.push(next)
    } else {
      seg_no.push(0)
    }
  }
  let ops : Array[EditOp] = []
  for op in p.ops {
    if op.layer == keep {
      let sel = match op.sel.basis {
        Base => op.sel
        Stage(n) => {
          if n > 0 && n <= p.ops.length() && p.ops[n - 1].layer == keep {
            { ..op.sel, basis: Stage(seg_no[n - 1]) }
          } else {
            op.sel
          }
        }
      }
      ops.push({ ..op, sel })
    }
  }
  ops
}

///|
/// 取出**某一图层**的算子子集（`stage:n` 已重编号到本层段内）。
///
/// 不带 guards：保护断言是"针对**最终图**"的约束，统一在文档级段之后检查，
/// 否则一条"别动人物"的断言会被每一层各判一次，语义就散了。
pub fn program_for_layer(p : EditProgram, layer_id : String) -> EditProgram {
  { ops: segment_ops(p, layer_id), guards: [] }
}

///|
/// 取出**文档级**算子（`layer` 为空）与**全部** guards（`stage:n` 已重编号到
/// 文档级段内，理由见 `segment_ops`）。
///
/// `stage:0` 是"**本段的输入**"（单段时 = 底图；本文档级段里 = 层合成结果），
/// 段内无歧义，原样保留。
pub fn program_doc_scope(p : EditProgram) -> EditProgram {
  { ops: segment_ops(p, ""), guards: p.guards }
}

///|
/// STAGE 基准的作用域校验：**`stage:n` 一律按「表序」，且 n 严格小于引用者
/// 自己的表序**。
///
/// `STAGE(n)` 的 `n` 是"**表里**第 n 个算子之后的中间缓冲"——只有这一个口径。
///
/// ⚠️ 这条判据曾经写窄过两次（都不是"声明边界"，是缺陷，经过见 PLAN.md 二十三）：
///   ①只查了"第 n 条是不是文档级算子"，**没把序号搬进段内**——两段式渲染把表拆成
///     三段跑（①被引用的层各自的栅格 ②合成 ③文档级算子跑在合成图上），层算子被
///     剔出文档级段后段内第 n 条并不是表里第 n 条，于是"往表里插一条只改某层的
///     算子，会静默换掉后面文档级算子取到的像素"（实测：`stage:2` 声明指 a 的输出、
///     实际指到 b 的输出，而校验放行、lint 不报、渲染照做）；
///   ②没查上界——自指/前视（n 指向自己或后面那条）校验放行，执行期才报
///     "拒绝前视引用"，正是"命令面收下了、渲染时才失败"。
///
/// 判定（静态、只看表）：`n == 0` 恒等于"**本段的输入**"（单段时=底图；有
/// `layer=` 时文档级段里=层合成结果），段内无歧义 → 放行；`n > 0` 要求"表里第 n
/// 条算子"**既是文档级算子、又严格在引用者之前**——两条缺一不可。
/// 段内序号的重编号由 `program_doc_scope` 一并处理：**判据与重编号是同一句话的
/// 两半**，只做一半就是"判据说合法、跑的却是另一个缓冲"。
///
/// 与它同形的还有 `tag_scope_error`：入口、lint、渲染三处共用同一句话。
pub fn layer_scope_error(p : EditProgram) -> String? {
  let mut i = 0
  for op in p.ops {
    match op.sel.basis {
      Base => ()
      Stage(n) => {
        // `stage:n`（n>0）指向表里**第 n 条算子**之后的缓冲：该条必须存在、
        // **与本引用者同段**（同为文档级算子，或同为同一个层 id 的算子——
        // `layer=@tag` 在渲染前会先展开成具体层 id，所以这里比的是展开后的值）、
        // 且**严格在引用者之前**。
        let same_seg = if n > 0 && n <= p.ops.length() {
          p.ops[n - 1].layer == op.layer
        } else {
          false
        }
        // n 是 1 基"第 n 条"：第 n 条之后的缓冲就是第 n+1 条的输入，所以引用者
        // （0 基下标 i）允许的范围是 n ≤ i，即 n - 1 < i。
        let ok = same_seg && n - 1 < i
        if n > 0 && !ok {
          let scope = if op.layer == "" { "文档级" } else { "layer=\{op.layer}" }
          return Some(
            "算子 \{op.id}（表序 \{i}，\{scope}）用了 STAGE(\{n})：`stage:n` 一律指\"**表里**第 n 条算子之后的中间缓冲\"，所以第 n 条必须①与引用者**同段**（同为文档级算子，或同为同一个层的算子）②**严格在引用者之前**。跨段引用与自指/前视都在这里拒——两段式执行会把别的段的算子剔出去再跑，段内第 n 条不是表里第 n 条，放行就会静默换掉取到的像素。STAGE(0) 表示\"本段的输入\"（放行）",
          )
        }
      }
    }
    i = i + 1
  }
  None
}

// ---------------------------------------------------------------------------
// 编辑表规模护栏（限额，拒绝式；不静默降级）
// ---------------------------------------------------------------------------

/// 单张编辑表最多多少条算子。
///
/// 定这个数不是为了"整洁"，而是因为**代价与它线性相关且量级很大**（见
/// `edit_cost_error` 的实测）。256 条在任何画布上都已远超 agent 一轮能提出
/// 的编辑量，同时给"误把循环写进生成器"留了足够余量。
pub const MAX_EDIT_OPS : Int = 256

/// 单张编辑表最多多少条保护断言（同量级，独立计数）。
pub const MAX_EDIT_GUARDS : Int = 64

/// 编辑表的**像素·算子**预算：`算子数 × 画布像素数` 不得超过它。
///
/// 为什么用这个乘积而不是单纯限条数：实测代价**线性于两者之积**，单纯限条数
/// 挡不住"少数算子 × 巨幅画布"。native release 下逐像素做一次 `recolor`
/// ≈ **2 µs**（1024×1024、10 条算子、`mvsl-impact`，3 次中位 19.9 s），
/// 即 100 万像素的整幅 recolor ≈ 2 秒/条。2e8 对应 ≈ **400 秒**的单次
/// 渲染上限——超过这个量级，一条命令的等待时间已经不是"慢"而是"没法用"。
pub const MAX_EDIT_PIXEL_OPS : Double = 2.0E8

/// 实测得到的每「像素·算子」耗时（秒），只用于把预算**换算成人类可读的
/// 估算值**回给调用方。它是本机 native release 的一次实测值，不是承诺——
/// 写进错误信息是为了让调用方**看得见代价**，而不是让引擎假装知道墙钟时间。
pub const EDIT_SECONDS_PER_PIXEL_OP : Double = 2.0e-6

/// 实测得到的每「像素·算子」**保留内存**（字节），只用于把代价**换算成人类
/// 可读的估算值**回给调用方。
///
/// 保留量的布局是 12 B/像素·算子（每条算子一份整幅 `RgbaBuf` 4 B/px +
/// 每个互不相同的 BASE 选择子一份整幅浮点场 8 B/px，见 DESIGN §性能），而
/// `python3 bench_perf.py m3`（1024×1024、选择子逐条不同、K=2..16）实测峰值
/// RSS 斜率低 K 处 **14.4**、K=16 收敛到 12.4（瞬时场与分配器高水位摊在低 K）。
/// 报**保守上界 14.4**：这条数字的用途是让调用方**在装表时**就看见
/// "这张表可能要吃多少内存"，报小了对调用方没有任何好处。
pub const EDIT_BYTES_PER_PIXEL_OP : Double = 14.4

///|
/// 编辑表的**保留内存**估算（字节；`n_ops × 画布像素数 ×` 上面的系数）。
///
/// ⚠️ 这**不是判据**，只是把 DESIGN §性能 里那条"与画布尺寸无关的
/// 2.4–2.9 GB 上限"变成调用方看得见的数字：`edit_cost_error` 只管时间
/// （2 µs/像素·算子 ⇒ 2e8 预算 ≈ 400 秒），而内存与它**同源不同量**——
/// 一张恰好通过时间护栏的表（190 条 × 1024×1024 ≈ 2.0e8）可能要吃 ~2.9 GB。
/// 拦不拦是产品决定（浏览器 tab 里多少内存算可接受），所以这里只报。
pub fn edit_peak_bytes(n_ops : Int, w : Int, h : Int) -> Double {
  n_ops.to_double() * w.to_double() * h.to_double() * EDIT_BYTES_PER_PIXEL_OP
}

///|
/// **编辑表规模判据**——**一处判据，两个执行点**：入口 `mvsl-set`（装表时画布
/// 已知，挡住绝大多数）与唯一渲染实现 `render.impact_stages`（执行时以画布的
/// 权威值为准）。`lint` 不必单独接：它本来就经 `impact_stages` 执行，于是自动
/// 以 `P0` 报出同一句话——**少一处调用就少一处会分叉的判断**。
///
/// 空串 = 放行。三条限额按"条数 → 条数 → 代价"的顺序查，报第一条违反的，
/// 且**回显全部相关数字**（实收多少、上限多少、换算出的估算秒数）：
/// 一条"太大了"的报错如果不说清多大算大，调用方只能靠猜着试。
///
/// ⚠️ 为什么必须在这一处判、而不是各命令各判一遍：这是本仓库反复踩的
/// "同一个判断两处实现，先烂的一定是没人读的那一处"。`mvsl-set` 装表时判
/// 一次（画布已知），`render.impact_stages` 执行时再判一次——**两次是有意的
/// 重复**：表装好后画布还能被 `resize` 改大，只判入口就会漏掉
/// "装的时候合法、渲染时才变贵"的那条路。
pub fn edit_cost_error(p : EditProgram, w : Int, h : Int) -> String {
  let n = p.ops.length()
  if n > MAX_EDIT_OPS {
    return "编辑表算子过多：\{n} 条，上限 \{MAX_EDIT_OPS} 条"
  }
  let g = p.guards.length()
  if g > MAX_EDIT_GUARDS {
    return "编辑表保护断言过多：\{g} 条，上限 \{MAX_EDIT_GUARDS} 条"
  }
  // 画布尺寸非正（还没开门 / 空文档）时不判代价：没有像素就没有代价。
  if w <= 0 || h <= 0 {
    return ""
  }
  let pxops = n.to_double() * w.to_double() * h.to_double()
  if pxops > MAX_EDIT_PIXEL_OPS {
    let est = pxops * EDIT_SECONDS_PER_PIXEL_OP
    return "编辑表代价超出预算：\{n} 条算子 × \{w}×\{h} 画布 = \{fmt_num(pxops)} 像素·算子，上限 \{fmt_num(MAX_EDIT_PIXEL_OPS)}（按实测 2 µs/(像素·算子)，这一张表单次渲染约需 \{fmt_num(est)} 秒）。请减少算子数或缩小画布"
  }
  ""
}

// ---------------------------------------------------------------------------
// 标签作用域（`layer=@tag`）：把语义标签当**活选层器**
// ---------------------------------------------------------------------------

///|
/// `layer` 作用域里的**标签作用域**语法：`@hero` → `Some("hero")`；
/// 其余（具体层 id）→ `None`。
///
/// 为什么复用 `layer` 字段、而不是新加一个 `layer_tag` 字段：新字段要升
/// `MVSL_IR_VERSION`，而**旧引擎会静默忽略**它——算子落到整幅合成图上，那是
/// "只该改一层的编辑扩散到全图"级别的静默失败。前缀写法在旧引擎上会走
/// **已有**的拒绝路径（`layer=@hero` 找不到同名的层 → 报"引用了不存在的
/// 图层"）：失败得响。
pub fn layer_scope_tag(scope : String) -> String? {
  if scope.has_prefix("@") {
    Some(scope[1:].to_owned())
  } else {
    None
  }
}

///|
/// 层 id 的命名空间规则（与 `layer_scope_tag` 是同一条规则的两面）：
/// **层 id 不许以 `@` 开头**——`@` 保留给 `layer=@tag`。
///
/// 放行一个 `@hero` 这样的层 id，同一个 `layer` 字符串就会按容器内容有两种
/// 读法（具体层？标签作用域？），而读错的那一边**不会报错**。所以入口拒绝，
/// `lint` 对旧容器兜底（同一个判据，同一句话）。
pub fn layer_id_error(id : String) -> String? {
  if id.has_prefix("@") {
    Some("层 id 不许以 `@` 开头（`@` 保留给 MVSL 的 layer=@tag 标签作用域；去掉 `@` 即可）")
  } else {
    None
  }
}

///|
/// 标签作用域的静态校验：`layer=@tag` 必须真的落到**至少一个层**上。
///
/// 落不到任何层 = 这条算子在表里、跑得通、什么都不改（本仓库最贵的一类
/// 失败）。入口（`mvsl-set`）、lint（手改容器 / 事后摘了标签）与渲染三处
/// **共用这一个判据**，与 `layer_scope_error` 同形。
pub fn tag_scope_error(p : EditProgram, doc : Document) -> String? {
  for op in p.ops {
    match layer_scope_tag(op.layer) {
      None => ()
      Some(tag) => {
        if tag == "" {
          return Some(
            "算子 \{op.id} 的 layer=\"@\" 后面没有标签名：写成 layer=@hero 才是「作用于带 hero 标签的全部层」",
          )
        }
        let mut n = 0
        for l in doc.layers {
          if layer_has_tag(l, tag) {
            n = n + 1
          }
        }
        if n == 0 {
          return Some(
            "算子 \{op.id} 的 layer=@\{tag} 落不到任何层：没有任何层带 \{tag} 标签，这条算子会静默不生效（先 `tag <id> \{tag}` 再装表；标签被摘掉也会变成这样）",
          )
        }
      }
    }
  }
  None
}

///|
/// 把 `layer=@tag` 展开成**带该标签的每个层各一份**算子（层序即
/// `doc.layers` 顺序，确定性）。
///
/// 这是"标签当活选层器"的**唯一实现**：渲染、`mvsl-impact`、`mvsl-assert`、
/// `lint` 在执行前各叫它一次，于是"这条算子到底改哪些层"只有一处判断。
/// 展开只依赖容器里已有的层与标签——没有隐式状态：
///
/// * **活的**：给一个层打上标签，它立刻进入作用范围；摘掉标签，立刻退出。
///   这正是"元参数↔视觉互链钩子"从承诺变成能力的地方（此前标签没有任何
///   消费者，见 README 的诚实边界）；
/// * `program_sha256` 仍按**未展开**的表算（程序身份稳定），而 `fingerprint`
///   覆盖标签（改标签即改指纹）——所以宿主缓存键仍是
///   `(fingerprint, program_sha256)`，标签变了指纹就变；
/// * 匹配不到的 `@tag` **原样留下**（绝不静默丢掉）：`tag_scope_error` 先给出
///   准话，render 侧还有"引用了不存在的图层"兜底。
pub fn expand_layer_scopes(p : EditProgram, doc : Document) -> EditProgram {
  let ops : Array[EditOp] = []
  for op in p.ops {
    match layer_scope_tag(op.layer) {
      None => ops.push(op)
      Some(tag) => {
        let mut hit = false
        for l in doc.layers {
          if layer_has_tag(l, tag) {
            ops.push({ ..op, layer: l.id })
            hit = true
          }
        }
        if !hit {
          ops.push(op)
        }
      }
    }
  }
  { ops, guards: p.guards }
}

// ---------------------------------------------------------------------------
// 校验（AgentGate 零容忍：坏输入在入口拒绝）
// ---------------------------------------------------------------------------

///|
fn is_recolor(k : OpKind) -> Bool {
  match k {
    Recolor => true
    Temperature => false
    Relight => false
  }
}

///|
fn is_temperature(k : OpKind) -> Bool {
  match k {
    Recolor => false
    Temperature => true
    Relight => false
  }
}

///|
fn is_relight(k : OpKind) -> Bool {
  match k {
    Recolor => false
    Temperature => false
    Relight => true
  }
}

///|
/// 编辑表指纹：canonical program JSON 的 sha256。
///
/// **与文档指纹并列，不可互相替代**：`fingerprint(document)` 覆盖
/// design.json，编辑表变了它**不会**变。宿主只按文档指纹做缓存/失效判断，
/// 就会在编辑表改动后继续用旧图。渲染结果的最终真值是 `render_sha256`
/// （PNG 的 sha256）；需要「文档 + 编辑表」这对身份时用这两者。
pub fn program_sha256(p : EditProgram) -> String {
  @base.sha256_hex(@utf8.encode(program_to_json(p)))
}

///|
/// 参数范围校验（所有算子/选择子共用）。返回精确错误文本。
///
/// 两处**静态可判**的语义错误必须在这里拦下，而不是留到执行期：
/// 1. 算子的 `stage:n` 前视引用（`n > 自身序号`）永远不可能满足——
///    留到执行期会变成「命令面收下了、渲染时才失败」；
/// 2. 断言带 `stage:` 基准。保护断言问的是「原图这块有没有被乱动」，
///    求值基准必须是不可变底图；挂 `stage:n` 会让保护区随中间算子漂移，
///    断言也就失去了意义（而且现有实现根本不认这个基准，会静默按 base
///    求值——声明与行为不一致比直接拒绝更坏）。
pub fn validate_program(p : EditProgram) -> Result[Unit, String] {
  let seen : Array[String] = []
  let mut index = 0
  for op in p.ops {
    if op.id == "" {
      return Err("算子缺 id（编辑表 id 稳定，禁止空 id）")
    }
    if seen.contains(op.id) {
      return Err("算子 id 重复：\{op.id}")
    }
    seen.push(op.id)
    if op.amount < 0.0 || op.amount > 1.0 {
      return Err("算子 \{op.id} 的 amount=\{fmt_num(op.amount)} 越界（0..1）")
    }
    if op.hue_deg < -360.0 || op.hue_deg > 360.0 {
      return Err("算子 \{op.id} 的 hue_deg=\{fmt_num(op.hue_deg)} 越界（-360..360）")
    }
    if op.temp_kelvin < -4000.0 || op.temp_kelvin > 4000.0 {
      return Err("算子 \{op.id} 的 temp_kelvin=\{fmt_num(op.temp_kelvin)} 越界（-4000..4000 K）")
    }
    if op.relight_gain < 0.0 || op.relight_gain > 4.0 {
      return Err("算子 \{op.id} 的 relight_gain=\{fmt_num(op.relight_gain)} 越界（0..4）")
    }
    if !is_recolor(op.kind) && op.hue_deg != 0.0 {
      return Err("算子 \{op.id} 不是 recolor，hue_deg 必须为 0")
    }
    if !is_temperature(op.kind) && op.temp_kelvin != 0.0 {
      return Err("算子 \{op.id} 不是 temperature，temp_kelvin 必须为 0")
    }
    if !is_relight(op.kind) && op.relight_gain != 1.0 {
      return Err("算子 \{op.id} 不是 relight，relight_gain 必须为 1")
    }
    for r in op.refine {
      match r {
        Grow(v) => if v < 0.0 || v > 256.0 {
            return Err("算子 \{op.id} 的 grow=\{fmt_num(v)} 越界（0..256px）")
          }
        Shrink(v) => if v < 0.0 || v > 256.0 {
            return Err("算子 \{op.id} 的 shrink=\{fmt_num(v)} 越界（0..256px）")
          }
        Feather(v) => if v < 0.0 || v > 256.0 {
            return Err("算子 \{op.id} 的 feather=\{fmt_num(v)} 越界（0..256px）")
          }
        Guided(rv, eps) => {
          if rv < 0.5 || rv > 64.0 {
            return Err("算子 \{op.id} 的 guided 半径=\{fmt_num(rv)} 越界（0.5..64px）")
          }
          if eps <= 0.0 || eps > 1.0 {
            return Err("算子 \{op.id} 的 guided eps=\{fmt_num(eps)} 越界（0..1]）")
          }
        }
        FillHoles => ()
        KeepLargest => ()
      }
    }
    match op.sel.basis {
      Base => ()
      Stage(n) => if n > index {
          return Err(
            "算子 \{op.id} 的 STAGE(\{n}) 是前视引用（自身序号 \{index}）——前视永远无法满足，拒绝",
          )
        }
    }
    let r0 = validate_sel(op.sel, "算子 \{op.id}")
    if r0 is Err(_) {
      let msg = match r0 {
        Err(e) => e
        Ok(_) => ""
      }
      return Err(msg)
    }
    index = index + 1
  }
  let gseen : Array[String] = []
  for g in p.guards {
    if g.id == "" {
      return Err("断言缺 id")
    }
    if gseen.contains(g.id) {
      return Err("断言 id 重复：\{g.id}")
    }
    gseen.push(g.id)
    if g.max_de < 0.0 || g.max_de > 1.0 {
      return Err("断言 \{g.id} 的 max_de=\{fmt_num(g.max_de)} 越界（0..1）")
    }
    if g.max_changed_ratio < 0.0 || g.max_changed_ratio > 1.0 {
      return Err(
        "断言 \{g.id} 的 max_changed_ratio=\{fmt_num(g.max_changed_ratio)} 越界（0..1）",
      )
    }
    match g.sel.basis {
      Base => ()
      Stage(n) =>
        return Err(
          "断言 \{g.id} 的保护区域以 stage:\{n} 为基准：保护断言必须对不可变底图求值，否则保护区会随中间算子漂移",
        )
    }
    let r1 = validate_sel(g.sel, "断言 \{g.id}")
    if r1 is Err(_) {
      let msg = match r1 {
        Err(e) => e
        Ok(_) => ""
      }
      return Err(msg)
    }
  }
  Ok(())
}

///|
fn in_unit(v : Double) -> Bool {
  v >= 0.0 && v <= 1.0
}

///|
fn in_hue(v : Double) -> Bool {
  v >= -360.0 && v <= 720.0
}

///|
fn validate_sel(s : SelSpec, owner : String) -> Result[Unit, String] {
  match s.basis {
    Base => ()
    // 拒绝式护栏：极大编辑表 / 恶意谓词 DoS
    Stage(n) => if n < 0 || n > 4096 {
        return Err("选择子基准 stage:\{n} 越界（0..4096）")
      }
  }
  validate_expr(s.expr, owner)
}

///|
fn validate_expr(e : SelExpr, owner : String) -> Result[Unit, String] {
  match e {
    Atom(a) => validate_atom(a, owner)
    Union(items) => {
      if items.length() < 2 {
        return Err("union 至少 2 个子选择子（\{owner}）")
      }
      for it in items {
        let r = validate_expr(it, owner)
        if r is Err(_) {
          let msg = match r {
            Err(e) => e
            Ok(_) => ""
          }
          return Err(msg)
        }
      }
      Ok(())
    }
    And(items) => {
      if items.length() < 2 {
        return Err("and 至少 2 个子选择子（\{owner}）")
      }
      for it in items {
        let r = validate_expr(it, owner)
        if r is Err(_) {
          let msg = match r {
            Err(e) => e
            Ok(_) => ""
          }
          return Err(msg)
        }
      }
      Ok(())
    }
    Diff(a, b) => {
      let ra = validate_expr(a, owner)
      if ra is Err(_) {
        let msg = match ra {
          Err(e) => e
          Ok(_) => ""
        }
        return Err(msg)
      }
      let rb = validate_expr(b, owner)
      if rb is Err(_) {
        let msg = match rb {
          Err(e) => e
          Ok(_) => ""
        }
        return Err(msg)
      }
      Ok(())
    }
  }
}

///|
fn validate_atom(a : AtomSel, owner : String) -> Result[Unit, String] {
  match a {
    Color(w) => validate_cwin(w, owner)
    Luma(lc, lh, f) => {
      if !in_unit(lc) || !in_unit(lh) || !in_unit(f) {
        return Err("luma 选择子参数越界（l_center/l_half/feather 需 0..1，\{owner}）")
      }
      Ok(())
    }
    Geo(g, shape) => {
      if g.w <= 0.0 || g.h <= 0.0 {
        return Err("geo 选择子 w/h 必须为正（\{owner}）")
      }
      if g.feather < 0.0 || g.feather > 256.0 {
        return Err("geo 选择子 feather 越界（0..256px，\{owner}）")
      }
      if shape != "rect" && shape != "ellipse" {
        return Err("geo 形状只支持 rect|ellipse（收到 \{shape}，\{owner}）")
      }
      Ok(())
    }
    GeoGrad(gw) => {
      if gw.axis != "x" && gw.axis != "y" {
        return Err("grad 轴只支持 x|y（收到 \{gw.axis}，\{owner}）")
      }
      if !in_unit(gw.falloff) {
        return Err("grad falloff 越界（0..1，\{owner}）")
      }
      Ok(())
    }
    Comp(_sx, _sy, tol, w) => {
      if tol <= 0.0 || tol > 1.0 {
        return Err("comp 选择子 ΔE 容差越界（0..1]，\{owner}）")
      }
      validate_cwin(w, owner)
    }
    AssetMask(h) => {
      if h == "" {
        return Err("assetmask 选择子缺资产 hash（\{owner}）")
      }
      Ok(())
    }
  }
}

///|
/// sRGB 全色域下 OKLCh 彩度的上确界。
///
/// 取值的来历：OKLab/OKLCh 的彩度是无量纲的，sRGB 立方体只能覆盖其中一段。
/// 在 8bit sRGB 立方体上扫描（步长 17 + 全部 8 个顶点），最大值出现在洋红
/// #FF00FF，C ≈ 0.3225（纯红 0.2577 / 纯绿 0.2948 / 纯蓝 0.3132）。
/// 取 0.3225 作为判据：色窗完全落在这之上就**不可能**命中任何像素。
///
/// 为什么不直接把 s_center 限制在 0..0.3225：色窗是 `center ± half`，
/// `center=0.4, half=0.2` 覆盖 0.2..0.6，与可达区间相交，是**合法**的宽窗；
/// 只有「整条窗都在可达区间之上」才是必然空选。所以判据是下沿而非中心。
const SRGB_MAX_CHROMA : Double = 0.3225

///|
fn validate_cwin(w : ColorWindow, owner : String) -> Result[Unit, String] {
  if !in_hue(w.h_center) {
    return Err("color 选择子 h_center 越界（\{owner}）")
  }
  if w.h_half < 0.0 || w.h_half > 180.0 {
    return Err("color 选择子 h_half 越界（0..180 度，\{owner}）")
  }
  if !in_unit(w.s_center) || !in_unit(w.s_half) {
    return Err("color 选择子 s_center/s_half 越界（0..1，\{owner}）")
  }
  // s 是 **OKLCh 彩度**（不是 HSV 饱和度）。窗整条高于 sRGB 可达彩度时，
  // 权重恒为 0——命令会「成功」但一个像素都不选中。这种静默空选必须在
  // 装表前就拒绝，并说明真实上限，否则调用方只会看到一张没变的图。
  if w.s_center - w.s_half >= SRGB_MAX_CHROMA {
    return Err(
      "color 选择子的彩度窗 [\{fmt_num(w.s_center - w.s_half)}, \{fmt_num(w.s_center + w.s_half)}] 整条高于 sRGB 可达彩度上限 \{fmt_num(SRGB_MAX_CHROMA)}，必然空选——s 是 OKLCh 彩度（纯洋红最高 ≈0.3225），不是 0..1 的 HSV 饱和度（\{owner}）",
    )
  }
  if !in_unit(w.l_center) || !in_unit(w.l_half) {
    return Err("color 选择子 l_center/l_half 越界（0..1，\{owner}）")
  }
  if !in_unit(w.feather) {
    return Err("color 选择子 feather 越界（0..1，\{owner}）")
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// canonical 序列化（固定字段序 + fmt_num 定点纪律）
// ---------------------------------------------------------------------------

///|
fn cwin_json(w : ColorWindow) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"h\":\{fmt_num(w.h_center)}")
  sb.write_string(",\"hw\":\{fmt_num(w.h_half)}")
  sb.write_string(",\"s\":\{fmt_num(w.s_center)}")
  sb.write_string(",\"sh\":\{fmt_num(w.s_half)}")
  sb.write_string(",\"l\":\{fmt_num(w.l_center)}")
  sb.write_string(",\"lh\":\{fmt_num(w.l_half)}")
  sb.write_string(",\"feather\":\{fmt_num(w.feather)}}")
  sb.to_string()
}

///|
fn gwin_json(g : GeoWindow) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"x\":\{fmt_num(g.x)},\"y\":\{fmt_num(g.y)}")
  sb.write_string(",\"w\":\{fmt_num(g.w)},\"h\":\{fmt_num(g.h)}")
  sb.write_string(",\"feather\":\{fmt_num(g.feather)}}")
  sb.to_string()
}

///|
fn gradwin_json(g : GradWindow) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"x0\":\{fmt_num(g.x0)},\"y0\":\{fmt_num(g.y0)}")
  sb.write_string(",\"x1\":\{fmt_num(g.x1)},\"y1\":\{fmt_num(g.y1)}")
  sb.write_string(",\"axis\":\"\{g.axis}\"")
  sb.write_string(",\"falloff\":\{fmt_num(g.falloff)}}")
  sb.to_string()
}

///|
fn atom_json(a : AtomSel) -> String {
  match a {
    Color(w) => "{\"t\":\"color\",\"w\":\{cwin_json(w)}}"
    Luma(lc, lh, f) => {
      let sb = StringBuilder()
      sb.write_string("{\"t\":\"luma\",\"l\":\{fmt_num(lc)}")
      sb.write_string(",\"lh\":\{fmt_num(lh)}")
      sb.write_string(",\"feather\":\{fmt_num(f)}}")
      sb.to_string()
    }
    Geo(g, shape) => "{\"t\":\"geo\",\"shape\":\"\{shape}\",\"w\":\{gwin_json(g)}}"
    GeoGrad(gw) => "{\"t\":\"geograd\",\"w\":\{gradwin_json(gw)}}"
    Comp(sx, sy, tol, w) => {
      let sb = StringBuilder()
      sb.write_string("{\"t\":\"comp\",\"sx\":\{fmt_num(sx)}")
      sb.write_string(",\"sy\":\{fmt_num(sy)}")
      sb.write_string(",\"de_tol\":\{fmt_num(tol)}")
      sb.write_string(",\"w\":\{cwin_json(w)}}")
      sb.to_string()
    }
    AssetMask(h) => "{\"t\":\"assetmask\",\"asset\":\"\{h}\"}"
  }
}

///|
fn expr_json(e : SelExpr) -> String {
  match e {
    Atom(a) => atom_json(a)
    Union(items) => "{\"t\":\"union\",\"items\":[\{arr_atom_json(items)}]}"
    And(items) => "{\"t\":\"and\",\"items\":[\{arr_atom_json(items)}]}"
    Diff(a, b) =>
      "{\"t\":\"diff\",\"a\":\{expr_json(a)},\"b\":\{expr_json(b)}}"
  }
}

///|
fn arr_atom_json(items : Array[SelExpr]) -> String {
  let sb = StringBuilder()
  let mut f = true
  for it in items {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(expr_json(it))
  }
  sb.to_string()
}

///|
fn basis_json(b : SelBasis) -> String {
  match b {
    Base => "\"base\""
    Stage(n) => "\"stage:\{n}\""
  }
}

///|
fn selspec_json(s : SelSpec) -> String {
  "{\"basis\":\{basis_json(s.basis)},\"expr\":\{expr_json(s.expr)}}"
}

///|
fn refine_json(r : Refine) -> String {
  match r {
    Grow(v) => "{\"op\":\"grow\",\"v\":\{fmt_num(v)}}"
    Shrink(v) => "{\"op\":\"shrink\",\"v\":\{fmt_num(v)}}"
    Feather(v) => "{\"op\":\"feather\",\"v\":\{fmt_num(v)}}"
    FillHoles => "{\"op\":\"fill_holes\"}"
    KeepLargest => "{\"op\":\"keep_largest\"}"
    Guided(rv, eps) =>
      "{\"op\":\"guided\",\"r\":\{fmt_num(rv)},\"eps\":\{fmt_num(eps)}}"
  }
}

///|
fn arr_refine_json(items : Array[Refine]) -> String {
  let sb = StringBuilder()
  let mut f = true
  for it in items {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(refine_json(it))
  }
  sb.to_string()
}

///|
fn seeds_json(seeds : Array[(Double, Double)]) -> String {
  let sb = StringBuilder()
  let mut f = true
  for p in seeds {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("[\{fmt_num(p.0)},\{fmt_num(p.1)}]")
  }
  sb.to_string()
}

///|
fn evidence_json(e : Evidence?) -> String {
  match e {
    None => "null"
    Some(ev) => {
      let sb = StringBuilder()
      sb.write_string("{\"label\":\"\{json_escape(ev.label)}\"")
      sb.write_string(",\"pos\":[\{seeds_json(ev.pos_seeds)}]")
      sb.write_string(",\"neg\":[\{seeds_json(ev.neg_seeds)}]}")
      sb.to_string()
    }
  }
}

///|
fn opkind_str(k : OpKind) -> String {
  match k {
    Recolor => "recolor"
    Temperature => "temperature"
    Relight => "relight"
  }
}

///|
fn op_json(o : EditOp) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":\"\{json_escape(o.id)}\"")
  sb.write_string(",\"kind\":\"\{opkind_str(o.kind)}\"")
  sb.write_string(",\"sel\":\{selspec_json(o.sel)}")
  sb.write_string(",\"amount\":\{fmt_num(o.amount)}")
  sb.write_string(",\"hue_deg\":\{fmt_num(o.hue_deg)}")
  sb.write_string(",\"temp_kelvin\":\{fmt_num(o.temp_kelvin)}")
  sb.write_string(",\"relight_gain\":\{fmt_num(o.relight_gain)}")
  // `layer` 只在非空时写：空作用域（文档级）是绝大多数情形，写进去会让
  // 所有既有编辑表的 canonical JSON 与 program_sha256 无谓地全变一遍。
  if o.layer != "" {
    sb.write_string(",\"layer\":\"\{json_escape(o.layer)}\"")
  }
  sb.write_string(",\"refine\":[\{arr_refine_json(o.refine)}]")
  sb.write_string(",\"note\":\"\{json_escape(o.note)}\"")
  sb.write_string(",\"evidence\":\{evidence_json(o.evidence)}}")
  sb.to_string()
}

///|
fn guard_json(g : Guard) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":\"\{json_escape(g.id)}\"")
  sb.write_string(",\"sel\":\{selspec_json(g.sel)}")
  sb.write_string(",\"max_de\":\{fmt_num(g.max_de)}")
  sb.write_string(",\"max_changed_ratio\":\{fmt_num(g.max_changed_ratio)}}")
  sb.to_string()
}

///|
/// 编辑表 canonical JSON。固定字段序；**不重排算子**（顺序即语义）。
pub fn program_to_json(p : EditProgram) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"version\":\{MVSL_IR_VERSION}")
  sb.write_string(",\"ops\":[")
  let mut f = true
  for o in p.ops {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(op_json(o))
  }
  sb.write_string("]")
  sb.write_string(",\"guards\":[")
  let mut f2 = true
  for g in p.guards {
    if f2 {
      f2 = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(guard_json(g))
  }
  sb.write_string("]}")
  sb.to_string()
}

// ---------------------------------------------------------------------------
// 反解（拒绝式：未知 op / 更高版本一律拒绝，不静默错渲）
// ---------------------------------------------------------------------------

///|
fn jnum(v : JValue, f : String) -> Result[Double, String] {
  match v.get(f) {
    Some(JNum(n)) => Ok(n)
    _ => Err("编辑表字段 \{f} 缺失或不是数字")
  }
}

///|
fn jstr(v : JValue, f : String) -> Result[String, String] {
  match v.get(f) {
    Some(JStr(s)) => Ok(s)
    _ => Err("编辑表字段 \{f} 缺失或不是字符串")
  }
}

///|
/// 可选数值字段：缺失 → 0。用于**中性值本来就是 0** 的那些（选择子窗口、
/// 精修幅度、断言阈值）——它们的"不给"与"给 0"语义一致。
fn jfin(v : JValue, f : String) -> Double {
  match v.get(f) {
    Some(JNum(n)) => n
    _ => 0.0
  }
}

///|
/// 可选数值字段：**缺失时取该字段的"中性值"**（不是 0）。
///
/// ⚠️ 三种算子各有一个"不是本 kind 就必须为中性值"的字段，而它们的中性值
/// **不都是 0**：`hue_deg`/`temp_kelvin` 的中性值是 0，`relight_gain` 是 **1**。
/// 早先这里一律回落 0，于是"手搓 base64 时漏写 `relight_gain`"的 recolor 会
/// 触发 `relight_gain 必须为 1`——**用户写的是合法语义（不给就等于不起作用），
/// 引擎却报了一个看起来在说"字段填错了"的错**，而 `sel-schema` 的示例里
/// 三个字段都写着，谁也不会去猜哪个能省。默认值表现在与校验表同源
/// **就写在调用点上**（`jfneutral(v, f, 中性值)`），与下面校验那几句紧挨着，
/// 改一处时另一处就在几行之外。
fn jfneutral(v : JValue, f : String, neutral : Double) -> Double {
  match v.get(f) {
    Some(JNum(n)) => n
    _ => neutral
  }
}

///|
fn jfstr(v : JValue, f : String) -> String {
  match v.get(f) {
    Some(JStr(s)) => s
    _ => ""
  }
}

///|
fn finite(d : Double) -> Bool {
  d == d && !(d * 2.0 == d && d != 0.0)
}

///|
fn cwin_of(v : JValue) -> Result[ColorWindow, String] {
  let h = jnum(v, "h")
  let hw = jnum(v, "hw")
  let s = jnum(v, "s")
  let sh = jnum(v, "sh")
  let l = jnum(v, "l")
  let lh = jnum(v, "lh")
  let f = jnum(v, "feather")
  if h is Err(_) || hw is Err(_) {
    return Err("color 选择子缺 h/hw")
  }
  if s is Err(_) || sh is Err(_) {
    return Err("color 选择子缺 s/sh")
  }
  if l is Err(_) || lh is Err(_) {
    return Err("color 选择子缺 l/lh")
  }
  if f is Err(_) {
    return Err("color 选择子缺 feather")
  }
  let hv = match h {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let hwv = match hw {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let sv = match s {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let shv = match sh {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let lv = match l {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let lhv = match lh {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let fv = match f {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  Ok({
    h_center: hv,
    h_half: hwv,
    s_center: sv,
    s_half: shv,
    l_center: lv,
    l_half: lhv,
    feather: fv,
  })
}

///|
fn gwin_of(v : JValue) -> Result[GeoWindow, String] {
  let x = jnum(v, "x")
  let y = jnum(v, "y")
  let w = jnum(v, "w")
  let h = jnum(v, "h")
  let f = jfin(v, "feather")
  if x is Err(_) || y is Err(_) {
    return Err("geo 选择子缺 x/y")
  }
  if w is Err(_) || h is Err(_) {
    return Err("geo 选择子缺 w/h")
  }
  let xv = match x {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let yv = match y {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let wv = match w {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let hv = match h {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  Ok({ x: xv, y: yv, w: wv, h: hv, feather: f })
}

///|
fn gradwin_of(v : JValue) -> Result[GradWindow, String] {
  let x0 = jnum(v, "x0")
  let y0 = jnum(v, "y0")
  let x1 = jnum(v, "x1")
  let y1 = jnum(v, "y1")
  let axis = jstr(v, "axis")
  let f = jnum(v, "falloff")
  if x0 is Err(_) || y0 is Err(_) || x1 is Err(_) || y1 is Err(_) {
    return Err("geograd 选择子缺端点")
  }
  if f is Err(_) {
    return Err("geograd 选择子缺 falloff")
  }
  if axis is Err(_) {
    return Err("geograd 选择子缺 axis")
  }
  let a0 = match x0 {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let b0 = match y0 {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let a1 = match x1 {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let b1 = match y1 {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let ff = match f {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let ax = match axis {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  Ok({ x0: a0, y0: b0, x1: a1, y1: b1, axis: ax, falloff: ff })
}

///|
fn atom_of(v : JValue) -> Result[AtomSel, String] {
  let t = jstr(v, "t")
  let tt = match t {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  match tt {
    "color" => {
      let w = match v.get("w") {
        Some(wv) => wv
        None => return Err("color 选择子缺 w")
      }
      let c = match cwin_of(w) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(Color(c))
    }
    "luma" => Ok(Luma(jfin(v, "l"), jfin(v, "lh"), jfin(v, "feather")))
    "geo" => {
      let shape = jstr(v, "shape")
      let w = match v.get("w") {
        Some(wv) => wv
        None => return Err("geo 选择子缺 w")
      }
      let g = match gwin_of(w) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      let sh = match shape {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(Geo(g, sh))
    }
    "geograd" => {
      let w = match v.get("w") {
        Some(wv) => wv
        None => return Err("geograd 选择子缺 w")
      }
      let g = match gradwin_of(w) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(GeoGrad(g))
    }
    "comp" => {
      let w = match v.get("w") {
        Some(wv) => wv
        None => return Err("comp 选择子缺 w")
      }
      let c = match cwin_of(w) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      let tol = jnum(v, "de_tol")
      if tol is Err(_) {
        return Err("comp 选择子缺 de_tol")
      }
      let tv = match tol {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(Comp(jfin(v, "sx"), jfin(v, "sy"), tv, c))
    }
    "assetmask" => {
      let h = jstr(v, "asset")
      if h is Err(_) {
        return Err("assetmask 选择子缺 asset")
      }
      let hv = match h {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(AssetMask(hv))
    }
    _ => Err("未知选择子类型 \{tt}（引擎版本不认这个 selector，旧引擎拒绝而非静默错渲）")
  }
}

///|
fn expr_of(v : JValue) -> Result[SelExpr, String] {
  let t = jstr(v, "t")
  let tt = match t {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  match tt {
    "color" | "luma" | "geo" | "geograd" | "comp" | "assetmask" => {
      let a = match atom_of(v) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(Atom(a))
    }
    "union" | "and" => {
      let items = match v.get("items") {
        Some(JArr(arr)) => arr
        _ => return Err("\{tt} 选择子缺 items")
      }
      let out : Array[SelExpr] = []
      for it in items {
        let e = match expr_of(it) {
          Ok(q) => q
          Err(err) => return Err(err)
        }
        out.push(e)
      }
      if tt == "union" {
        Ok(Union(out))
      } else {
        Ok(And(out))
      }
    }
    "diff" => {
      let a = match v.get("a") {
        Some(av) => av
        None => return Err("diff 缺 a")
      }
      let b = match v.get("b") {
        Some(bv) => bv
        None => return Err("diff 缺 b")
      }
      let ea = match expr_of(a) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      let eb = match expr_of(b) {
        Ok(q) => q
        Err(e) => return Err(e)
      }
      Ok(Diff(ea, eb))
    }
    _ => Err("未知选择子表达式 \{tt}（引擎版本不认这个 selector）")
  }
}

///|
fn selspec_of(v : JValue) -> Result[SelSpec, String] {
  let b = jstr(v, "basis")
  let bv = match b {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let basis = if bv == "base" {
    Base
  } else if bv.has_prefix("stage:") {
    let rest = bv[6:].to_owned()
    match to_int_strict(rest) {
      Some(n) => Stage(n)
      None => return Err("选择子基准 \{bv} 非法（stage:需整数）")
    }
  } else {
    return Err("选择子基准 \{bv} 非法（只允许 base|stage:n）")
  }
  let ev = match v.get("expr") {
    Some(x) => x
    None => return Err("选择子缺 expr")
  }
  let e = match expr_of(ev) {
    Ok(q) => q
    Err(err) => return Err(err)
  }
  Ok({ basis, expr: e })
}

///|
fn to_int_strict(s : String) -> Int? {
  let v = @string.parse_int(s) catch { _ => return None }
  Some(v)
}

///|
fn refine_of(v : JValue) -> Result[Refine, String] {
  let o = jstr(v, "op")
  let ov = match o {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  match ov {
    "grow" => Ok(Grow(jfin(v, "v")))
    "shrink" => Ok(Shrink(jfin(v, "v")))
    "feather" => Ok(Feather(jfin(v, "v")))
    "fill_holes" => Ok(FillHoles)
    "keep_largest" => Ok(KeepLargest)
    "guided" => Ok(Guided(jfin(v, "r"), jfin(v, "eps")))
    _ => Err("未知选区精修原语 \{ov}（引擎版本不认这个 refine）")
  }
}

///|
fn opkind_of(s : String) -> Result[OpKind, String] {
  match s {
    "recolor" => Ok(Recolor)
    "temperature" => Ok(Temperature)
    "relight" => Ok(Relight)
    _ => Err("未知算子 \{s}（引擎版本不认这个 op，拒绝执行而非静默错渲）")
  }
}

///|
fn seeds_of(v : JValue?) -> Array[(Double, Double)] {
  let out : Array[(Double, Double)] = []
  match v {
    Some(JArr(arr)) => for item in arr {
        match item.as_arr() {
          Some(pair) => {
            if pair.length() >= 2 {
              let a = pair[0].as_num()
              let b = pair[1].as_num()
              match (a, b) {
                (Some(x), Some(y)) => if finite(x) && finite(y) {
                    out.push((x, y))
                  }
                _ => ()
              }
            }
          }
          None => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn evidence_of(v : JValue?) -> Evidence? {
  match v {
    // canonical JSON 用 null 表示「无证据」：反解必须还原成 None，
    // 否则 canonical 往返不幂等（None → Some(空证据) 会改写字节）。
    Some(JNull) | None => None
    Some(ev) => {
      let label = jfstr(ev, "label")
      let pos = seeds_of(ev.get("pos"))
      let neg = seeds_of(ev.get("neg"))
      Some({ label, pos_seeds: pos, neg_seeds: neg })
    }
  }
}

///|
fn op_of(v : JValue) -> Result[EditOp, String] {
  let id = jstr(v, "id")
  let kind = jstr(v, "kind")
  let selv = match v.get("sel") {
    Some(x) => x
    None => return Err("算子缺 sel")
  }
  let amount = jnum(v, "amount")
  let sel = match selspec_of(selv) {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let kindv = match kind {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let k = match opkind_of(kindv) {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let idv = match id {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let av = match amount {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let refines : Array[Refine] = []
  match v.get("refine") {
    Some(JArr(arr)) => for rv in arr {
        let r = match refine_of(rv) {
          Ok(q) => q
          Err(e) => return Err(e)
        }
        refines.push(r)
      }
    _ => ()
  }
  Ok({
    id: idv,
    kind: k,
    sel,
    amount: av,
    hue_deg: jfneutral(v, "hue_deg", 0.0),
    temp_kelvin: jfneutral(v, "temp_kelvin", 0.0),
    relight_gain: jfneutral(v, "relight_gain", 1.0),
    layer: jfstr(v, "layer"),
    refine: refines,
    note: jfstr(v, "note"),
    evidence: evidence_of(v.get("evidence")),
  })
}

///|
fn guard_of(v : JValue) -> Result[Guard, String] {
  let id = jstr(v, "id")
  let selv = match v.get("sel") {
    Some(x) => x
    None => return Err("断言缺 sel")
  }
  let sel = match selspec_of(selv) {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  let idv = match id {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  Ok({
    id: idv,
    sel,
    max_de: jfin(v, "max_de"),
    max_changed_ratio: jfin(v, "max_changed_ratio"),
  })
}

///|
/// 单条 `SelSpec` 的 canonical 序列化（affordance 命令的入参格式，
/// 与 `selspec_from_json` 严格互逆）。
///
/// 有它调用方就不必手写选择子 JSON——手写少一个大括号就会得到
/// 「json: 第 N 字符后有多余内容」这种指不到病根的报错。
pub fn selspec_to_json(s : SelSpec) -> String {
  selspec_json(s)
}

///|
/// 单条 `SelSpec` 的反解入口。
///
/// affordance 命令（select-preview / probe / census within=）要能直接喂
/// 一条选择子，不该被迫裹一张完整编辑表——「先造一条假编辑」是调用方
/// 最容易出错的地方。
pub fn selspec_from_json(text : String) -> Result[SelSpec, String] {
  let v = match parse_json(text) {
    Ok(x) => x
    Err(e) => return Err("选择子解析失败：\{e}")
  }
  let s = match selspec_of(v) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  match validate_sel(s, "选择子") {
    Ok(_) => Ok(s)
    Err(e) => Err(e)
  }
}

///|
/// 编辑表反解。缺字段 → 空编辑表（旧容器可开）。
/// 更高 IR 版本 / 未知算子 / 未知选择子一律拒绝。
pub fn program_from_json(text : String) -> Result[EditProgram, String] {
  if text == "" {
    return Ok(EditProgram::new())
  }
  let v = match parse_json(text) {
    Ok(x) => x
    Err(e) => return Err("编辑表解析失败：\{e}")
  }
  let ver = match v.get("version") {
    Some(JNum(n)) => n
    _ => return Err("编辑表缺 version")
  }
  if ver > MVSL_IR_VERSION.to_double() {
    return Err(
      "编辑表 IR 版本 \{fmt_num(ver)} 高于引擎支持的 \{MVSL_IR_VERSION}，拒绝执行（不静默错渲）",
    )
  }
  let ops : Array[EditOp] = []
  match v.get("ops") {
    Some(JArr(arr)) => for ov in arr {
        let o = match op_of(ov) {
          Ok(q) => q
          Err(e) => return Err(e)
        }
        ops.push(o)
      }
    _ => return Err("编辑表缺 ops")
  }
  let guards : Array[Guard] = []
  match v.get("guards") {
    Some(JArr(arr)) => for gv in arr {
        let g = match guard_of(gv) {
          Ok(q) => q
          Err(e) => return Err(e)
        }
        guards.push(g)
      }
    _ => return Err("编辑表缺 guards")
  }
  Ok({ ops, guards })
}
