///|
/// 工具能力字典的单一事实源（对齐 moonviz agent_api 模式）：
/// CLI help / list-tools 输出全部由此生成；修改 session.mbt 的分发时
/// 必须同步这里（反之亦然）。channel 标注双通道归属：
/// meta（元参数通道）/ vision（视觉通道）/ both。
pub(all) struct AgentTool {
  name : String
  description : String
  channel : String
}

///|
/// 首版命令集（PLAN.md §6）。
pub fn list_tools() -> Array[AgentTool] {
  let t : Array[AgentTool] = []
  let add = fn(name : String, desc : String, channel : String) {
    t.push({ name, description: desc, channel })
  }
  // 会话
  add("session-open", "打开会话；强制 vision 能力闸（唯一合法声明 full_image）", "meta")
  add("list-tools", "工具能力字典（本表）", "meta")
  add("help", "同 list-tools 的别名", "meta")
  // 文档
  add("new", "new <w> <h> [uuid=..]：新建画布", "meta")
  add("set-canvas", "set-canvas <w> <h>：改画布尺寸", "meta")
  add("list-layers", "层树总览（含嵌套 children）", "meta")
  add("query-layer", "query-layer <id>：单层详情", "meta")
  add("lint", "P0–P2 谓词检查（引用/几何/限额）", "both")
  // 绘制
  add(
    "add-rect",
    "add-rect x= y= w= h= [id= name= fill= radius= lgrad= stroke= stroke_w= opacity= blend= rot=]。**x/y/w/h/stroke_w 是像素，但 lgrad 端点是归一化 0..1**（lgrad=c0,c1,x0,y0,x1,y1，(0,0)=本层左上，(1,1)=本层右下，与画布分辨率无关）——把像素写进端点会被拒绝",
    "meta",
  )
  add("add-ellipse", "同 add-rect（椭圆）", "meta")
  add("add-polygon", "同 add-rect，另需 points=x,y;x,y;…（局部坐标）", "meta")
  add("add-line", "同 add-rect，默认对角线，可 points= 自定义折线；fill 不生效", "meta")
  add("add-image", "add-image x= y= w= h= b64=<png base64>：导入位图资产并置入", "both")
  add(
    "set-style",
    "set-style <id> fill=/lgrad=/stroke=/stroke_w=/opacity=/blend=/radius=/rot=/visible=/name=（lgrad 端点归一化 0..1，非像素）",
    "meta",
  )
  add("move", "move <id> <x> <y>", "meta")
  add("resize", "resize <id> <w> <h>", "meta")
  add("rotate", "rotate <id> <deg>（绕层中心，顺时针）", "meta")
  add("flip", "flip <id> h|v|both|none（翻转；先翻转后旋转）", "meta")
  add("rename", "rename <id> <new-name>", "meta")
  add("tag", "tag <id> <tag>：语义标签（元参数↔视觉互链钩子）", "both")
  add("delete", "delete <id>", "meta")
  add("visible", "visible <id> <true|false>", "meta")
  add("reorder", "reorder <id> front|back|up|down", "meta")
  add("group", "group <gid> <id…>：把根级层编成组（直通合成）", "meta")
  add("ungroup", "ungroup <gid>", "meta")
  // 文本 / 调整 / 蒙版
  add("add-text", "add-text x= y= text=<内容> [font_size=] [fill=<#RRGGBB[AA]，默认黑>]：文本层（ASCII 真字形）；**含空格用双引号包住** text=\"Hello World\"，name= 同理", "meta")
  add("set-text", "set-text <id> <新内容>（含空格用双引号包住）", "meta")
  add("add-adjust", "add-adjust op=<算子> value=<-1..1>：调整层（PSD 语义）。算子：brightness/contrast/saturation/invert/grayscale/blur/sharpen/smooth/whiten/warm/vignette", "meta")
  add("add-mask", "add-mask <id> kind=rect|ellipse x= y= w= h= [radius=<圆角 px，仅矩形，默认 0>] [feather=<边缘羽化 px，默认 0=硬边；过渡带在蒙版内侧>] [invert=true]：蒙版坐标是**画布坐标**（x/y/w/h 用像素，不随图层 move/rotate 走）", "meta")
  add(
    "set-mask",
    "set-mask <id> true|false：**只改蒙版的 invert**（几何 x/y/w/h/radius 不可改，要改用 remove-mask + add-mask）",
    "meta",
  )
  add("remove-mask", "remove-mask <id>", "meta")
  // 修图操作
  add("add-paint", "add-paint [name=]：新建画笔层（raster，全画布）", "meta")
  add("brush", "brush layer=<raster层> pts=x1,y1;x2,y2[;…] r=<半径px> [color=#RRGGBB[AA]]：沿折线落笔触", "meta")
  add("erase", "erase layer=<raster层> pts=… r=<半径px>：橡皮擦（destination-out）", "meta")
  add("crop", "crop <x> <y> <w> <h>：裁剪画布，全部层同步平移", "meta")
  add("sample", "sample <x> <y>：吸管取色（合成像素 hex + 命中层）", "vision")
  // 元参数
  add("list-params", "元参数表", "meta")
  add("set-param", "set-param <name> <value>（纯元数据；live 绑定属下轮）", "meta")
  // 视觉
  add("render", "render [width] [vx0 vy0 vx1 vy1] [overlay=1]：取景渲染 → PNG b64 + sha256；overlay 叠加层 bbox 序号线框", "vision")
  add("pick", "pick <x> <y>：画布坐标 → 最上层层 id", "both")
  add("stats", "直方图 32 桶 + 覆盖统计（引擎给数值，模型给判断）", "vision")
  add("census", "census [within=<base64 sel>] [components=n]：hue×sat 桶普查（12×3）+ OKLab L 与 HSV V 均值对照；给 within 时附覆盖率/bbox/连通域事实", "both")
  add("probe", "probe x= y= [r=2]：单点邻域统计（OKLab 均值/方差、环平均色相、边缘置信度）+ 当前编辑表每个算子的选择子在该点的 membership 与所属连通域 id。**要探多个位置用 `points=x1,y1;x2,y2;…`（上限 64 点，一次往返；返回 points 数组，每点的字段与单点模式完全一致）**，别重复调用——同给 x/y 与 points 时以 points 为准", "both")
  add("sel-schema", "选择子/算子语法自证清单：每种原子选择子与组合子的 canonical 示例（由写出器产出、由同一解析器验回）+ 量纲/取值范围 + 数值该从哪来。**写选择子前先看它**，别猜字段名与量纲", "both")
  // 历史 / 容器
  add("fingerprint", "当前 canonical design.json 指纹", "meta")
  add("inspect", "元参数层实时视图：manifest 摘要 + design.json 全文 + params + 编辑历史", "meta")
  add("edits", "编辑历史摘要", "meta")
  add("undo", "撤销（canonical 快照栈，≤64）", "meta")
  add("redo", "重做", "meta")
  add("save-mpd-b64", "会话打包为 .mpd 容器字节（base64）", "meta")
  add("open-mpd-b64", "open-mpd-b64 <b64>：载入容器（拒绝式校验）", "meta")
  // MVSL 编辑表（确定性编辑 IR）：人机同一张表，AI 与 GUI 同一撤销栈
  add("mvsl-set", "mvsl-set <base64(canonical program json)>：安装 MVSL 编辑表（校验+规范化，空 ops 表示逐位还原底图）。算子可带 layer=<层 id> 把作用域收窄到那一层——该层先单独栅格化、选择子在**这一层自己的像素**上求值，再合成回去；带 layer 的算子先按序执行、然后合成、最后才跑文档级算子（跨作用域的相对顺序不保留），且 layer 与 STAGE 基准的组合会被拒绝", "meta")
  add("mvsl-show", "当前 MVSL 编辑表 canonical 全文 + program_sha256 + 三个算法版本 pin", "meta")
  add("mvsl-clear", "清空 MVSL 编辑表（渲染逐位还原底图）", "meta")
  add("select-preview", "select-preview <base64(sel json)> [max=1024]：选择子 → overlay PNG（洋红覆盖）+ 覆盖率/bbox/连通域事实（AI 选 ID 不报坐标）", "both")
  add("mvsl-impact", "mvsl-impact [max=1024]：执行编辑表 → 逐算子 diff 证书（改动数/ΔE/选区外泄漏率）+ 结果 PNG", "both")
  add("mvsl-assert", "保护断言检查：保护区 ΔE / 改动比例超限则命令信封直接 fail（别动人物 = 机器可验证约束）", "both")
  t
}

///|
/// MoonPainter 的硬性前置声明：宿主必须是有完整图片视觉的多模态模型。
pub fn vision_required() -> Bool {
  true
}

///|
/// 视觉能力闸：session-open 的硬性校验。
/// 唯一合法取值 "full_image"；其余（纯文本/仅 OCR/仅缩略图）一律明确拒绝。
pub fn vision_gate(model_vision : String) -> Bool {
  model_vision == "full_image"
}

///|
pub fn engine_banner() -> String {
  "moonpainter \{@core.ENGINE_VERSION} (vision-required: \{vision_required()})"
}
