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
pub const MPD_VERSION : Int = 1

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
/// 描边（width ≤ 0 视为无描边）。
pub(all) struct Stroke {
  color : Int // 0xAARRGGBB
  width : Double
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
  points : Array[(Double, Double)] // Line/Polygon 顶点（局部坐标，0..w / 0..h）
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
    points: [],
    fill: Solid(0xFF808080),
    stroke: { color: 0xFF000000, width: 0.0 },
    asset_hash: "",
    tags: [],
    children: [],
  }
}

///|
/// 递归找层。
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
