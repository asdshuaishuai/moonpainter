/// core —— IR 文档模型（core/document）。
///
/// 这是 .mpd 元参数层 `meta/design.json` 的内存形态：结构事实源。
/// 纪律（DESIGN.md §4）：
/// - 层序 = 数组序，自底向上（Compositor/PSD 约定）；
/// - 组（kind=Group）以 children 嵌套表达，直通合成：组只做组织与
///   可见性/不透明度传递，不建离屏缓冲；
/// - 变换与内容分离：x/y/w/h/rotation 是放置参数，资产像素永不重采样；
/// - Image 层引用 assets 里登记的内容寻址位图，置入矩形拉伸绘制。

///|
/// 引擎版本单一事实源：moon.mod 同步维护。
/// CLI banner、容器 provenance、previews 注册全部引用本常量。
pub const ENGINE_VERSION : String = "0.1.0"

///|
/// .mpd 容器格式标识与规范版本（DESIGN.md §5 / PLAN.md §4）。
pub const MPD_FORMAT_ID : String = "moonpainter.mpd"

///|
/// 容器规范版本。
///
/// v1 → v2：新增权威条目 `meta/mvsl.json`（当前 MVSL 编辑表）与
/// manifest 的 `mvsl` 版本块。**必须升版**而不是静默追加：MVSL 编辑表
/// 是渲染的真值输入，不认识它的旧引擎会「打开成功但少渲染一批编辑」，
/// 那正是 PLAN-MVSL 明令禁止的静默错渲。升版后旧引擎按
/// 「版本高于支持范围」直接拒绝打开，把问题暴露在入口。
pub const MPD_VERSION : Int = 2

///|
/// design.json 的文档格式标识（区别于容器标识，允许独立演进）。
pub const DOC_FORMAT_ID : String = "moonpainter.doc"

///|
pub const DOC_VERSION : Int = 1

///|
/// 节点类型。
pub(all) enum ShapeKind {
  Rect
  Ellipse
  Line
  Polygon
  Image
  Group
  Text
  Adjust
  /// 画笔层：dabs 笔触为唯一内容（画笔/橡皮擦落点），局部坐标
  Raster
  /// **钢笔/贝塞尔路径**（④）：锚点在 `points`、每锚两个控制柄偏移在 `handles`
  /// （局部坐标，`[in0,out0,in1,out1,…]`）。`fill` 非 `NoFill` = **闭合**路径
  /// （填充），`NoFill` = 开放路径（只描边，同 SVG 的语义）——不新增 `closed`
  /// 字段：闭合与否**本来就等价于"有没有面"**，多一个字段就多一处可能自相矛盾。
  Path
}

///|
/// 混合模式（首版 7 种，对齐 PLAN.md §5；PSD 全集属远期）。
pub(all) enum BlendMode {
  Normal
  Multiply
  Screen
  Overlay
  Darken
  Lighten
  Difference
}

///|
/// 填充：无 / 纯色 / 线性渐变（两色 + 局部 0..1 端点）。
pub(all) enum Fill {
  NoFill
  Solid(Int) // 0xAARRGGBB
  LinearGradient(
    Int,
    Int,
    Double,
    Double,
    Double,
    Double,
  ) // c0 c1 x0 y0 x1 y1
}

///|
/// 线性渐变端点的合法域检查：**归一化到本层 bbox 的 [0,1]**。
///
/// 这是 `Fill::LinearGradient` 的契约——`(0,0)` = 本层左上、`(1,1)` = 本层右下，
/// 与画布分辨率无关。返回空串表示合法，否则返回可直接呈现的错误文本。
///
/// **为什么必须在入口拦下**：`add-rect` 的其它几何参数（x/y/w/h/stroke_w）
/// **全是像素**，顺手把 `lgrad` 端点也写成像素是极自然的错误。写错之后引擎
/// 一切正常：层建好了、渲染成功了、颜色也确实是渐变——只是几乎看不出过渡。
/// 实测 `lgrad=…,0,0,60,40`（本想写像素）渲染出来与纯色无异，且没有任何提示。
/// 这类「看起来生效了」的静默错误，比直接报错难查得多。
///
/// 错误文本带上换算后的建议值，让调用方一步就能改对。
pub fn grad_endpoint_error(
  x0 : Double,
  y0 : Double,
  x1 : Double,
  y1 : Double,
  w : Double,
  h : Double,
) -> String {
  let bad = x0 < 0.0 ||
    x0 > 1.0 ||
    y0 < 0.0 ||
    y0 > 1.0 ||
    x1 < 0.0 ||
    x1 > 1.0 ||
    y1 < 0.0 ||
    y1 > 1.0
  if !bad {
    return ""
  }
  let sb = StringBuilder()
  sb.write_string("渐变端点必须落在 0..1（归一化到本层 bbox：(0,0)=本层左上，(1,1)=本层右下，与画布分辨率无关）；收到 ")
  sb.write_string("(\{fmt_num(x0)},\{fmt_num(y0)})→(\{fmt_num(x1)},\{fmt_num(y1)})")
  if w > 0.0 && h > 0.0 {
    sb.write_string("。若你写的是像素坐标，本层 \{fmt_num(w)}×\{fmt_num(h)} 应写作 ")
    sb.write_string(
      "(\{fmt_num(x0 / w)},\{fmt_num(y0 / h)})→(\{fmt_num(x1 / w)},\{fmt_num(y1 / h)})",
    )
  }
  sb.to_string()
}

///|
/// 描边（width ≤ 0 视为无描边）。
pub(all) struct Stroke {
  color : Int // 0xAARRGGBB
  width : Double
}

///|
/// 矢量蒙版：参数化形状，覆盖区内可见（invert 后反之）。
///
/// 坐标是**画布坐标**（不是层局部坐标）：`render/scene.mbt` 的 `mask_cover_at`
/// 直接拿画布点与 `x/y` 比，所以 `move`/`rotate` 图层时蒙版**不跟着走**
/// （DESIGN §8 有实测记录）。`radius` 是矩形蒙版的圆角半径
/// （`<=0` 为直角；超过半边长按半边长夹住）。`feather` 是边缘软过渡宽度
/// （像素，`0` 为硬边——与"还没有 feather"之前的行为逐位相同）。
/// `roughen` 是**边缘毛化幅度**（像素，`0` = 光滑边=历史行为）：在阈值化之前
/// 用一个**确定性**的值噪声扰动边界的内距，得到手绘/撕裂纸边那种不规则轮廓。
/// 噪声是画布坐标的纯函数（不含时间、随机数、迭代序——铁律 7），所以
/// 同一文档反复渲染逐位一致、取景不改语义。
pub(all) struct LayerMask {
  kind : ShapeKind // Rect 或 Ellipse
  x : Double
  y : Double
  w : Double
  h : Double
  radius : Double
  feather : Double // 边缘软过渡宽度（像素）；0 = 硬边（历史行为）
  /// 边缘毛化幅度（像素）；0 = 光滑边（历史行为）
  roughen : Double
  invert : Bool
  /// 多边形蒙版（`kind = Polygon`）的顶点：**蒙版盒子内的局部坐标**
  /// （0..w / 0..h，与 `Layer.points` 同规）；kind 不是 Polygon 时恒为空。
  ///
  /// 为什么是"一个盒子 + 一串顶点"：盒子就是**支持窗**（它决定这层的渲染窗口），
  /// 顶点跑出盒子那部分就画不出来，所以入口与 lint 都要求顶点落在盒子里
  /// （与多边形图层同一条纪律）。**任意形状选区**（套索）就是靠这个 kind 表达的。
  points : Array[(Double, Double)]
}

///|
/// 蒙版参数的**取值判据**（一处实现，入口与 lint 共用）。
///
/// 返回 "" = 合法，否则是给人看的错因。**一句话说清"这条蒙版装不上/装了也不
/// 干活"**：尺寸非正 → 覆盖区为空（`invert=false` 时整层被藏掉）；负的
/// radius/feather/roughen 没有任何意义（渲染器内部会各自折成 0，于是"给了
/// 参数但不生效"）。
///
/// 为什么要共用：入口拒绝（`add-mask`/`set-mask`）与 lint 兜住（手改容器、
/// 旧版本产物）是**两个出口、一个判断**——两处各写一份，先烂的一定是没人读的
/// 那处（本仓库的旧账）。
pub fn mask_param_error(m : LayerMask) -> String {
  if m.w <= 0.0 || m.h <= 0.0 {
    return "蒙版尺寸必须为正：w=\{fmt_num(m.w)} h=\{fmt_num(m.h)}（覆盖区为空，这层会被整层藏掉/整层露出）"
  }
  if m.radius < 0.0 {
    return "蒙版 radius 不能为负：\{fmt_num(m.radius)}（0 = 直角）"
  }
  if m.feather < 0.0 {
    return "蒙版 feather 不能为负：\{fmt_num(m.feather)}（0 = 硬边）"
  }
  if m.roughen < 0.0 {
    return "蒙版 roughen 不能为负：\{fmt_num(m.roughen)}（0 = 光滑边）"
  }
  match m.kind {
    ShapeKind::Polygon => ()
    _ =>
      if m.points.length() > 0 {
        return "只有多边形蒙版才带顶点：这份蒙版带着 \{m.points.length()} 个点（渲染器不读它 ⇒ 改了画面逐位不变，只会平白改变指纹）"
      }
  }
  match m.kind {
    ShapeKind::Polygon => {
      if m.points.length() < 3 {
        return "多边形蒙版至少要有 3 个顶点：现在 \{m.points.length()} 个（围不出面积 ⇒ invert=false 时这层被整层藏掉、invert=true 时整层露出）"
      }
      for p in m.points {
        if p.0 < 0.0 || p.1 < 0.0 || p.0 > m.w || p.1 > m.h {
          return "多边形蒙版的顶点必须落在蒙版盒子里（盒子 = 支持窗，跑出去的顶点画不出来）：顶点 (\{fmt_num(p.0)}, \{fmt_num(p.1)}) 不在 0..\{fmt_num(m.w)} × 0..\{fmt_num(m.h)} 之内"
        }
      }
    }
    _ => ()
  }
  ""
}

///|
/// 这份文档**要求的最低渲染契约版本**（容器据此声明自己需要什么渲染器）。
///
/// 存在的理由：新增的渲染语义若只加在数据里，**旧引擎会静默按老语义画**
/// （`roughen` 被忽略 = 边缘悄悄变光滑），而"静默错渲"是本项目明令禁止的。
/// 容器 manifest 的 `render_contract` 是既有的版本闸（读到高于自身支持的版本
/// 一律拒绝打开），所以只要**写的时候按实际用到的能力声明**，旧引擎就会在
/// 打开时失败得响。
///
/// 目前有两档需要升级：
///   * 2 = 用到蒙版毛边（`roughen > 0`）
///   * 3 = 用到**多边形蒙版**（`kind = Polygon`）
///   * 5 = 用到**贝塞尔路径**（`kind = Path`，老引擎不认识 ⇒ 整层不画）
/// 别在这里写"总是 3"——那等于把所有容器都标成新契约，闸就失去了分辨力。
/// ⚠️ 取**所有层里的最高档**（不是遇到第一档就 return）：一份文档完全可能既有
/// 毛边蒙版（2）又有套索蒙版（3），只看先遇到的那一层就会把 3 报成 2，
/// 于是老引擎打开它、把套索画成方框。
pub fn required_render_contract(doc : Document) -> Int {
  let mut rc = 1
  for l in doc.layers {
    // 贝塞尔路径：老引擎不认这个 kind（整层不画）⇒ 必须升档
    if l.kind is ShapeKind::Path && rc < RENDER_CONTRACT_PATH {
      rc = RENDER_CONTRACT_PATH
    }
    // 色阶/曲线（调整层的新参数）：老引擎的 `adjust_of` 读不出这两个字段，
    // 会把 `op=levels` 整层**丢掉**（作用范围凭空少一层）或按 value=0 施加一个
    // 空操作 ⇒ 静默错渲，必须升档。
    match l.adjust {
      Some(adj) =>
        if (adj.levels is Some(_) || adj.curve.length() > 0) &&
          rc < RENDER_CONTRACT_ADJUST_PARAMS {
          rc = RENDER_CONTRACT_ADJUST_PARAMS
        }
      None => ()
    }
    // 克隆笔触：老引擎会把它画成普通笔色（整笔一块死色）⇒ 必须升档
    for d in l.dabs {
      if d.clone && rc < RENDER_CONTRACT_CLONE {
        rc = RENDER_CONTRACT_CLONE
      }
    }
    match l.mask {
      Some(m) => {
        match m.kind {
          ShapeKind::Polygon => if rc < RENDER_CONTRACT_POLY_MASK {
            rc = RENDER_CONTRACT_POLY_MASK
          }
          _ => ()
        }
        if m.roughen > 0.0 && rc < RENDER_CONTRACT_ROUGHEN {
          rc = RENDER_CONTRACT_ROUGHEN
        }
      }
      None => ()
    }
  }
  rc
}

///|
/// 调整算子（调整层作用于其下全部可见层的合成结果；PSD 语义）。
pub(all) enum AdjustOp {
  Brightness // value: -1..1（加光）
  Contrast // value: -1..1
  Saturation // value: -1..1（负=去饱和）
  Invert
  Grayscale
  Blur // value: 0..1 → 框式模糊半径 1..24px（两趟近似高斯）
  Sharpen // value: 0..1 → 非锐化掩模强度
  Smooth // 磨皮：value 0..1，边缘感知平滑（平坦区强、纹理区弱）
  Whiten // 美白：value 0..1，暖色调像素加权提亮
  Warm // 色温：value -1..1，正=暖（R+/B-）负=冷
  Vignette // 暗角：value 0..1，径向渐暗
  Levels // 色阶：5 个参数（输入黑白点/gamma/输出黑白点），**不吃 value**
  Curves // 曲线：控制点表（每点 x,y ∈ 0..1，x 严格递增），**不吃 value**
}

///|
/// 给层追加一个标签（**已存在则不重复**）。
///
/// 这是"打标签"的**单一实现**：`tag <id> <tag>` 命令与 `add-*/set-style` 的
/// `tag=` 参数都走它。`apply_style_kv` 的注释里早就写着它会应用 `tag`，但实现
/// 里没有那条分支——于是 `add-rect … tag=background` **被静默忽略**（不报错、
/// `tags` 为空），而两条既有测试都用着它、又都没断言它真的落上。
pub fn layer_with_tag(l : Layer, tag : String) -> Layer {
  let tags = l.tags.copy()
  if !layer_has_tag(l, tag) {
    tags.push(tag)
  }
  { ..l, tags }
}

///|
/// 层是否带着这个标签（"打/摘"两侧共用的**唯一**成员判断）。
///
/// 写成一处是因为它本来要出现在至少三处：`tag` 报 `added`、`untag` 判断
/// "有没有这个标签可摘"、`layer_with_tag` 判重复。三份手写循环就是三处会
/// 各自烂掉的判断。
pub fn layer_has_tag(l : Layer, tag : String) -> Bool {
  for t in l.tags {
    if t == tag {
      return true
    }
  }
  false
}

///|
/// 摘掉层上**所有**等于 `tag` 的标签（`layer_with_tag` 的对偶）。
///
/// 这是"摘标签"的**单一实现**：`untag <id> <tag>` 命令走它，`untag <id> *`
/// 的"清空"也走它（对每个现有标签各叫一次）——于是"摘一个"与"清空"不可能
/// 分叉成两份判断。只增不减的字段是坑：标签进 canonical JSON 与指纹、被
/// `query-layer` 回读，而此前 `tag=`/`tag` 都只会追加 —— 打错一个标签只能
/// 删层重加（层被推到栈顶，蒙版/翻转/透明度/层序/id 引用全丢）。
pub fn layer_without_tag(l : Layer, tag : String) -> Layer {
  let tags : Array[String] = []
  for t in l.tags {
    if t != tag {
      tags.push(t)
    }
  }
  { ..l, tags }
}

///|
/// 算子名（canonical JSON 的 `op` 值 / 命令面 `op=` 的取值，**单一实现**）。
/// 这名字此前只写在 `core/json.mbt` 的 `adjust_json` 里（私有），而
/// `query-layer` 又要报同一个名字——两处各写一遍就是把"故意不一致"的
/// 温床。提到这里，三处共用。
pub fn adjust_op_name(op : AdjustOp) -> String {
  match op {
    Brightness => "brightness"
    Contrast => "contrast"
    Saturation => "saturation"
    Invert => "invert"
    Grayscale => "grayscale"
    Blur => "blur"
    Sharpen => "sharpen"
    Smooth => "smooth"
    Whiten => "whiten"
    Warm => "warm"
    Vignette => "vignette"
    Levels => "levels"
    Curves => "curves"
  }
}

///|
/// 算子名 → 算子（`adjust_op_name` 的**逆**，同一个事实源）。
///
/// 此前这个方向被手写了两份：`core/json.mbt` 的 `adjust_of`（读容器）与
/// `agent/session.mbt` 的 `parse_adjust`（读命令行），各 11 条臂——加一个算子
/// 要记得改三处，而漏改哪一处都**不会报错**（命令行报"未知算子"，容器则静默
/// 把 adjust 字段整块丢掉）。逆映射现在只此一份。
pub fn adjust_op_from_name(name : String) -> AdjustOp? {
  match name {
    "brightness" => Some(Brightness)
    "contrast" => Some(Contrast)
    "saturation" => Some(Saturation)
    "invert" => Some(Invert)
    "grayscale" => Some(Grayscale)
    "blur" => Some(Blur)
    "sharpen" => Some(Sharpen)
    "smooth" => Some(Smooth)
    "whiten" => Some(Whiten)
    "warm" => Some(Warm)
    "vignette" => Some(Vignette)
    "levels" => Some(Levels)
    "curves" => Some(Curves)
    _ => None
  }
}

///|
/// 全部调整算子（**声明顺序**）。错误提示、工具字典描述、测试遍历都从这里
/// 出——手写第二份清单就是"加算子时漏改一处"的温床。
pub fn all_adjust_ops() -> Array[AdjustOp] {
  [
    Brightness,
    Contrast,
    Saturation,
    Invert,
    Grayscale,
    Blur,
    Sharpen,
    Smooth,
    Whiten,
    Warm,
    Vignette,
    Levels,
    Curves,
  ]
}

///|
/// 笔触落点（Raster 层内容原子）：局部坐标圆斑。
pub(all) struct Dab {
  x : Double
  y : Double
  r : Double
  color : Int // 0xAARRGGBB（erase=true 时仅 alpha 生效；clone=true 时不读）
  erase : Bool
  // **仿制图章**（克隆）：不落本色，改从"本层之下的合成结果"里按源偏移取样。
  // `sdx`/`sdy` 是**画布坐标**的源偏移（取样点 = 落点画布坐标 + 偏移），
  // 于是旋转/翻转过的层也对得上（落点先由 `dab_center` 换成画布坐标再加偏移）。
  // 一次落笔里偏移恒定（PS 的"对齐"模式）= 同一条命令的每个 dab 写同一个值。
  clone : Bool
  sdx : Double
  sdy : Double
}

///|
///|
/// **色阶（Levels）**：输入黑/白点、中间调 gamma、输出黑/白点。
/// 映射只有一处（`render.levels_lut` 与它逐字对应）：
///   `v' = clamp01((v - in_lo) / (in_hi - in_lo))`
///   `v'' = v' ^ (1/gamma)`
///   `out = out_lo + v'' * (out_hi - out_lo)`
/// 逐 RGB 通道同样处理，**α 不动**（PS 的"复合通道"口径：色阶不改透明度）。
pub(all) struct Levels {
  in_lo : Double
  in_hi : Double
  gamma : Double
  out_lo : Double
  out_hi : Double
}

///|
/// 色阶的**中性值**（= 什么都不改）。命令面缺省、`lint` 判"装了却什么都不干"、
/// 文档里的默认值都读它——写第二份"0/1/1/0/1"就必然有一处先烂。
pub fn levels_identity() -> Levels {
  { in_lo: 0.0, in_hi: 1.0, gamma: 1.0, out_lo: 0.0, out_hi: 1.0 }
}

///|
/// 色阶参数合法性（**一处判据**：命令入口、`set-adjust`、`lint` 共用同一句话）。
/// NaN 也在这里被抓住：判据写成 `!(x >= lo && x <= hi)` 而不是 `x < lo || x > hi`
/// （NaN 与任何数比较都是 false，后一种写法会把它放过去）。
pub fn levels_error(lv : Levels) -> String? {
  let in_range = fn(v : Double) -> Bool { v >= 0.0 && v <= 1.0 }
  if !in_range(lv.in_lo) || !in_range(lv.in_hi) {
    return Some("色阶的输入黑白点必须都在 0..1（in_lo < in_hi）")
  }
  if !(lv.in_lo < lv.in_hi) {
    return Some("色阶要求 in_lo < in_hi（输入黑点必须低于白点；想反相请用 invert）")
  }
  if !(lv.gamma >= 0.01 && lv.gamma <= 100.0) {
    return Some("色阶 gamma 必须在 0.01..100（1 = 不动；>1 压暗中间调，<1 提亮）")
  }
  if !in_range(lv.out_lo) || !in_range(lv.out_hi) {
    return Some("色阶的输出黑白点必须都在 0..1")
  }
  if !(lv.out_lo <= lv.out_hi) {
    return Some("色阶要求 out_lo <= out_hi（想反相请用 invert）")
  }
  None
}

///|
/// 色阶是不是**中性**（做了但什么都不改 ⇒ `lint` 要报）。
pub fn levels_is_identity(lv : Levels) -> Bool {
  let d = levels_identity()
  (lv.in_lo - d.in_lo).abs() <= 1.0e-9 &&
  (lv.in_hi - d.in_hi).abs() <= 1.0e-9 &&
  (lv.gamma - d.gamma).abs() <= 1.0e-9 &&
  (lv.out_lo - d.out_lo).abs() <= 1.0e-9 &&
  (lv.out_hi - d.out_hi).abs() <= 1.0e-9
}

///|
/// **曲线（Curves）**的控制点表：每点 `(x, y)`，x/y ∈ 0..1、x **严格递增**、
/// 至少 2 点、至多 32 点。两端不要求落在 (0,0)/(1,1)——区间外按端点值**钳住**
/// （与 PS 的"曲线不到边"一致）。中点用**单调三次（PCHIP）**插值：不过冲，
/// 于是"把某个亮度拉高"不会在邻近亮度上压出一个坑。
pub fn curve_error(pts : Array[(Double, Double)]) -> String? {
  if pts.length() < 2 {
    return Some("曲线至少要 2 个控制点（points=x,y;x,y；例如 0,0;0.5,0.6;1,1）")
  }
  if pts.length() > 32 {
    return Some("曲线最多 32 个控制点（点太多时手拖不住，也没有对应的 UI）")
  }
  let mut i = 0
  for p in pts {
    if !(p.0 >= 0.0 && p.0 <= 1.0) || !(p.1 >= 0.0 && p.1 <= 1.0) {
      return Some("曲线的每个点都要在 0..1 见方里（第 \{i + 1} 个点是 \{p.0},\{p.1}）")
    }
    if i > 0 && !(p.0 > pts[i - 1].0) {
      return Some("曲线的 x 必须严格递增（第 \{i + 1} 个点的 x 没有大于前一个）")
    }
    i = i + 1
  }
  None
}

///|
/// 曲线点表的**文本形态**（`x,y;x,y;…`）：命令面回显、`set-adjust` 的沿用、
/// 报告面共用**一处**格式（两处各拼一遍就必然有一处先烂）。
pub fn curve_points_text(pts : Array[(Double, Double)]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  for p in pts {
    if i > 0 {
      sb.write_string(";")
    }
    sb.write_string("\{fmt_num(p.0)},\{fmt_num(p.1)}")
    i = i + 1
  }
  sb.to_string()
}

///|
/// 曲线是不是**中性**（所有点都落在对角线上 ⇒ 什么都不改）。
pub fn curve_is_identity(pts : Array[(Double, Double)]) -> Bool {
  // 空表/单点**不算中性**：那不是"什么都不改的曲线"，那是"没有曲线"（参数不
  // 合法，由 `curve_error` 说话）。空集上的全称命题恒真，照字面写会让一张空表
  // 被报成"控制点全在对角线上"——判据的空集也要说话。
  if pts.length() < 2 {
    return false
  }
  let mut out = true
  for p in pts {
    if (p.1 - p.0).abs() > 1.0e-9 {
      out = false
    }
  }
  out
}

///|
/// 调整层（`op` 决定读哪几个参数）。
///
/// 参数面**不是**只有 `value`：色阶要 5 个数、曲线要一张点表。`levels`/`curve`
/// 是**可选**字段（缺省时 canonical JSON 里整个字段都不写 ⇒ 老文档字节不变），
/// 而"哪个算子读哪些参数"由 `adjust_param_error` 一处说了算（入口与 `lint`
/// 共用同一句话，见 `agent` 的 `parse_adjust`）。
pub(all) struct Adjust {
  op : AdjustOp
  value : Double
  levels : Levels?
  curve : Array[(Double, Double)]
}

///|
/// 造一个调整参数（其余字段缺省）。加参数时**只改这一处**：8 个构造点都读它。
pub fn make_adjust(op : AdjustOp, value : Double) -> Adjust {
  { op, value, levels: None, curve: [] }
}

///|
/// 这个算子**读不读** `value`（"用不上的 value 要拒"那条的唯一判据）。
pub fn adjust_uses_value(op : AdjustOp) -> Bool {
  match op {
    Invert | Grayscale | Levels | Curves => false
    _ => true
  }
}

///|
/// 参数组合合法性（**一处判据**）：哪个算子读哪些参数、缺了要说什么。
///
/// 这里管的是"形状"（该有的有没有、不该有的有没有），取值范围由各参数的
/// 判据（`levels_error`/`curve_error`）与 `agent` 的范围表说。
pub fn adjust_param_error(adj : Adjust) -> String? {
  let name = adjust_op_name(adj.op)
  match adj.op {
    Levels =>
      match adj.levels {
        Some(lv) =>
          if adj.curve.length() > 0 {
            Some("算子 \{name} 读 levels=，不读 points=（曲线的控制点请用 op=curves）")
          } else {
            levels_error(lv)
          }
        None => Some("算子 \{name} 需要 5 个色阶参数（in_lo= in_hi= gamma= out_lo= out_hi=）")
      }
    Curves =>
      match adj.levels {
        Some(_) => Some("算子 \{name} 读 points=，不读色阶参数（in_lo=… 请用 op=levels）")
        None => curve_error(adj.curve)
      }
    _ =>
      if adj.levels is Some(_) {
        Some("算子 \{name} 不吃色阶参数（in_lo=… 只对 op=levels 有意义）")
      } else if adj.curve.length() > 0 {
        Some("算子 \{name} 不吃 points=（曲线控制点只对 op=curves 有意义）")
      } else {
        None
      }
  }
}

///|
/// 层记录：结构事实源的原子单元。
pub(all) struct Layer {
  id : String
  name : String
  kind : ShapeKind
  visible : Bool
  opacity : Double // 0..1
  blend : BlendMode
  x : Double
  y : Double
  w : Double
  h : Double
  rotation_deg : Double // 顺时针，绕层中心
  corner_radius : Double // Rect 圆角
  flip_h : Bool // 水平翻转（局部坐标镜像；先翻转后旋转）
  flip_v : Bool // 垂直翻转
  text : String // Text 层内容（ASCII 真字形；非 ASCII 盒形占位，诚实边界）
  font_size : Double // Text 层字号（像素，5x7 点阵缩放基准 7）
  mask : LayerMask? // 矢量蒙版（与层同变换；None=无）
  adjust : Adjust? // Adjust 层的算子参数；其余恒 None
  points : Array[(Double, Double)] // Line/Polygon 顶点、Path 的**锚点**（局部坐标，0..w / 0..h）
  /// Path 的贝塞尔控制柄**偏移**（相对锚点，局部坐标；长度恒为 2×锚点数，
  /// 依次为 `[in0,out0,in1,out1,…]`）。其余 kind 恒空。
  /// ⚠️ 缺省（全 0）= 折线（控制柄贴在锚点上），所以"画一条折线路径"不需要
  /// 任何新语法：`handles` 全 0 的路径就是折线。
  handles : Array[(Double, Double)]
  dabs : Array[Dab] // Raster 层笔触（局部坐标）；其余层恒空
  fill : Fill
  stroke : Stroke
  asset_hash : String // Image 层引用的资产键；其余为 ""
  tags : Array[String] // 语义标签（元参数 ↔ 视觉互链钩子）
  children : Array[Layer] // Group 子层（自底向上）；非 Group 恒空
}

///|
/// 内容寻址位图资产（像素字节由会话/容器持有，IR 只登记元信息）。
pub(all) struct Asset {
  hash : String
  mut width : Int
  mut height : Int
}

///|
/// 命名元参数（纯元数据；live 绑定属下轮，PLAN.md 诚实边界）。
pub(all) struct Param {
  name : String
  value : String
}

///|
/// 文档：画布 + 自底向上的层树 + 资产表 + 元参数表。
pub(all) struct Document {
  uuid : String
  mut width : Int
  mut height : Int
  dpi : Int
  profile : String // 工作色彩空间，本轮恒 "srgb"
  layers : Array[Layer] // 自底向上
  assets : Array[Asset]
  params : Array[Param]
  mut next_layer_no : Int // 自动 id 分配器（l1, l2, …）
}

///|
/// 新建空文档。
pub fn new_document(uuid : String, width : Int, height : Int) -> Document {
  {
    uuid,
    width,
    height,
    dpi: 72,
    profile: "srgb",
    layers: [],
    assets: [],
    params: [],
    next_layer_no: 1,
  }
}

///|
/// 分配下一个层 id（l1, l2, …）。
pub fn alloc_layer_id(doc : Document) -> String {
  let id = "l\{doc.next_layer_no}"
  doc.next_layer_no = doc.next_layer_no + 1
  id
}

///|
/// 造一个默认矩形层（形状类 op 的公共底座：改 kind/几何即可变其他形状）。
pub fn default_layer(
  id : String,
  name : String,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
) -> Layer {
  {
    id,
    name,
    kind: Rect,
    visible: true,
    opacity: 1.0,
    blend: Normal,
    x,
    y,
    w,
    h,
    rotation_deg: 0.0,
    corner_radius: 0.0,
    flip_h: false,
    flip_v: false,
    text: "",
    font_size: 16.0,
    mask: None,
    adjust: None,
    points: [],
    handles: [],
    dabs: [],
    fill: Solid(0xFF808080),
    stroke: { color: 0xFF000000, width: 0.0 },
    asset_hash: "",
    tags: [],
    children: [],
  }
}

///|
/// 递归找层。
///|
/// 文档当前**真正被引用**的资产 hash（去重）。
///
/// 判据是**层的 `asset_hash`**，不是 `doc.assets`。第一版我用了后者，结果
/// 清理完全没生效——因为 `doc.assets` 自己就是一张**只增不减**的表：
/// `delete l1` 之后 `design.layers` 是 0 层，而 `design.assets` 那条还在
/// （实测 `add-image` 后 `delete`，`doc.assets` 仍有该 hash）。拿一张只增的
/// 表当"引用表"去判断引用，等于什么都没判断。
///
/// 打包用它过滤会话的资产登记簿（`s.assets` 是内容寻址的登记簿，只增是对的
/// ——撤销要把字节还回来）；`doc.assets` 里的元数据条目本身无害，留着不动。
///|
/// 把 `doc.assets` 收敛到"当前真的被引用的那些"。**返回值是删掉的 hash 数**。
///
/// 少了这一步，`design.json` 会留下**指向不存在字节的悬空引用**：
/// `add-image` → `delete l1` 之后实测 `design.assets` 仍是 1 条、而容器里
/// 0 个资产条目。而 DESIGN 说"文本层权威（canonical design.json）"，
/// README 又承诺外部工具可以 `unzip` 后直接读元参数层——外部读者会照着
/// 那条引用去找一份不存在的资产。同一张表还喂着 `manifest.json` 的
/// `counts.assets`，于是**容器自述里写着 1 个资产、里面其实 0 个**。
///
/// 判据只有一处实现（`referenced_asset_hashes`，按层的 `asset_hash`）：
/// 这张表是只增的，拿它自己判断引用等于没判断。
pub fn prune_unreferenced_assets(doc : Document) -> Int {
  let referenced = referenced_asset_hashes(doc)
  let before = doc.assets.length()
  let keep : Array[Asset] = []
  for a in doc.assets {
    if referenced.contains(a.hash) {
      keep.push(a)
    }
  }
  doc.assets.clear()
  for a in keep {
    doc.assets.push(a)
  }
  before - keep.length()
}

///|
pub fn referenced_asset_hashes(doc : Document) -> Array[String] {
  let out : Array[String] = []
  for l in doc.layers {
    if l.asset_hash != "" && !out.contains(l.asset_hash) {
      out.push(l.asset_hash)
    }
  }
  out
}

///|
pub fn find_layer(layers : Array[Layer], id : String) -> Layer? {
  for l in layers {
    if l.id == id {
      return Some(l)
    }
    match find_layer(l.children, id) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  None
}

///|
/// 层的轴对齐包围盒（未计旋转；旋转层的严格 bbox 属 P2 谓词增强项）。
pub fn layer_bbox(l : Layer) -> (Double, Double, Double, Double) {
  (l.x, l.y, l.w, l.h)
}

///|
/// **一组成员盒的并集**（轴对齐，未计成员自身的旋转，同 `layer_bbox`）。
/// 空成员返回 `None`——空组没有"内容范围"可言。
pub fn group_bbox(children : Array[Layer]) -> (Double, Double, Double, Double)? {
  if children.length() == 0 {
    return None
  }
  // ⚠️ 初值必须是**第一个成员的派生盒**（`effective_box`），不是它存下来的
  // `x/y/w/h`：成员自己是组/笔触层时存盒是建层时的快照（笔触层那份还是整幅
  // 画布尺寸），拿它当并集初值就会把整个并集**吞掉**——组的盒子仍是画布、
  // 轴心落在画布中心，而"盒子跟着内容走"这条在成员那一级白做了（实测：
  // 笔触层当第一个成员时，整组的轴心是 (50,50) 而不是落笔范围中心 (45,15)，
  // PLAN 六十）。
  let (fx, fy, fw, fh) = effective_box(children[0])
  let mut x0 = fx
  let mut y0 = fy
  let mut x1 = fx + fw
  let mut y1 = fy + fh
  for c in children {
    let (cx, cy, cw, ch) = effective_box(c)
    if cx < x0 {
      x0 = cx
    }
    if cy < y0 {
      y0 = cy
    }
    if cx + cw > x1 {
      x1 = cx + cw
    }
    if cy + ch > y1 {
      y1 = cy + ch
    }
  }
  Some((x0, y0, x1 - x0, y1 - y0))
}

///|
/// 层的**有效盒子**——"这个层的内容占哪儿"的**唯一定义**。
///
/// 组没有自己的画面，它的盒子**定义**为成员的并集（`group_bbox`）：
/// 实时派生而不是读存下来的 `w/h`。存下来的那份只是建组那一刻的快照
/// （canonical JSON 要有个值、旧引擎要读得懂），**渲染与报告面都不读它**
/// ——实测过的错法：`group` 曾把组盒设成**画布尺寸**，于是组的旋转轴心是
/// 画布中心（人类以为绕自己的内容转），而 `resize grp` 还会**悄悄把轴心挪走**
/// （回 `ok`、指纹变、画面也变，而 `caps` 报组没有 `resize`——两个信号打架，
/// 见 PLAN 五十七）。派生之后两件事一起没了：轴心永远跟着内容走，
/// `resize` 对画面真的是恒等（`caps` 那句话才是真的）。
///
/// 空组没有并集可算，退回存下来的盒子（空组另由 `lint` 报 P2）。
pub fn effective_box(l : Layer) -> (Double, Double, Double, Double) {
  if l.kind is ShapeKind::Group {
    match group_bbox(l.children) {
      Some(b) => b
      None => (l.x, l.y, l.w, l.h)
    }
  } else if l.kind is ShapeKind::Raster {
    // 笔触层同理：**内容**（落笔范围）决定盒子。存下来的那份是画布尺寸的快照
    // （`add-paint` 建的），拿它当"这个层占了哪儿"就是把整幅画布报成一支小笔迹
    // 的尺寸（PLAN 六十）。
    match raster_bbox(l) {
      Some(b) => b
      None => (l.x, l.y, l.w, l.h)
    }
  } else {
    (l.x, l.y, l.w, l.h)
  }
}

///|
/// **笔触层的落笔范围**（画布坐标，轴对齐）：全部 dab 的盒（圆心 ± 半径）的并集。
///
/// 与 `layer_bbox`/`group_bbox` 同一把尺子——"内容决定盒子"。`r <= 0` 的 dab
/// 不落墨、不计（同 `dabs_window`）。一个都不剩就返回 `None`
/// （空笔触层没有"内容范围"可言，同空组）。
pub fn raster_bbox(l : Layer) -> (Double, Double, Double, Double)? {
  let mut x0 = 0.0
  let mut y0 = 0.0
  let mut x1 = 0.0
  let mut y1 = 0.0
  let mut any = false
  for d in l.dabs {
    if d.r <= 0.0 {
      continue
    }
    // dab 存的是**层局部**偏移 ⇒ 画布坐标要加 `l.x/l.y`（与
    // `@render.dab_center` 的"平移"那一半同一件事）
    let dx0 = l.x + d.x - d.r
    let dy0 = l.y + d.y - d.r
    let dx1 = l.x + d.x + d.r
    let dy1 = l.y + d.y + d.r
    if any {
      if dx0 < x0 {
        x0 = dx0
      }
      if dy0 < y0 {
        y0 = dy0
      }
      if dx1 > x1 {
        x1 = dx1
      }
      if dy1 > y1 {
        y1 = dy1
      }
    } else {
      any = true
      x0 = dx0
      y0 = dy0
      x1 = dx1
      y1 = dy1
    }
  }
  if any {
    Some((x0, y0, x1 - x0, y1 - y0))
  } else {
    None
  }
}

///|
/// 收集全部层（含嵌套，按绘制序）。
pub fn all_layers(layers : Array[Layer]) -> Array[Layer] {
  let out : Array[Layer] = []
  collect_layers(layers, out)
  out
}

///|
fn collect_layers(layers : Array[Layer], out : Array[Layer]) -> Unit {
  for l in layers {
    out.push(l)
    collect_layers(l.children, out)
  }
}
