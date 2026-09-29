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
  add("add-rect", "add-rect x= y= w= h= [id= name= fill= radius= lgrad= stroke= stroke_w= opacity= blend= rot=]", "meta")
  add("add-ellipse", "同 add-rect（椭圆）", "meta")
  add("add-polygon", "同 add-rect，另需 points=x,y;x,y;…（局部坐标）", "meta")
  add("add-line", "同 add-rect，默认对角线，可 points= 自定义折线；fill 不生效", "meta")
  add("add-image", "add-image x= y= w= h= b64=<png base64>：导入位图资产并置入", "both")
  add("set-style", "set-style <id> fill=/lgrad=/stroke=/stroke_w=/opacity=/blend=/radius=/rot=/visible=/name=", "meta")
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
  // 元参数
  add("list-params", "元参数表", "meta")
  add("set-param", "set-param <name> <value>（纯元数据；live 绑定属下轮）", "meta")
  // 视觉
  add("render", "render [width] [vx0 vy0 vx1 vy1] [overlay=1]：取景渲染 → PNG b64 + sha256；overlay 叠加层 bbox 序号线框", "vision")
  add("pick", "pick <x> <y>：画布坐标 → 最上层层 id", "both")
  add("stats", "直方图 32 桶 + 覆盖统计（引擎给数值，模型给判断）", "vision")
  // 历史 / 容器
  add("fingerprint", "当前 canonical design.json 指纹", "meta")
  add("inspect", "元参数层实时视图：manifest 摘要 + design.json 全文 + params + 编辑历史", "meta")
  add("edits", "编辑历史摘要", "meta")
  add("undo", "撤销（canonical 快照栈，≤64）", "meta")
  add("redo", "重做", "meta")
  add("save-mpd-b64", "会话打包为 .mpd 容器字节（base64）", "meta")
  add("open-mpd-b64", "open-mpd-b64 <b64>：载入容器（拒绝式校验）", "meta")
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
