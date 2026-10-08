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
  add("new", "new <w> <h> [uuid=..]：新建画布。**可渲染上限是单边 ≤4096**（容器能存到单边 30000，但渲染器只画左上角 4096×4096，超限的画布画出来的东西和你以为的不是一回事），所以超过 4096 会在入口被拒并说明原因", "meta")
  add("set-canvas", "set-canvas <w> <h>：改画布尺寸（**只改画布，图层不会被移动或缩放**）。同样受**可渲染上限单边 ≤4096** 约束（超了拒绝，理由同 new）", "meta")
  add("list-layers", "层树总览（含嵌套 children）", "meta")
  add("query-layer", "query-layer <id>：单层详情", "meta")
  add("lint", "P0–P2 谓词检查（引用/几何/限额）", "both")
  // 绘制
  // 四条 add-* 的键清单都从 `add_shape_keys(kind)` 生成——它与解析器
  // 用的是**同一个函数**，所以不会再出现"手写清单漏了 visible="这种漂移
  // （实测漏过）。单位说明留在正文里，见铁律 8。
  add(
    "add-rect",
    "add-rect x= y= w= h= " + add_shape_keys(@core.ShapeKind::Rect).map(fn(k) { "[\{k}=]" }).join("") + "。**x/y/w/h/stroke_w 是像素，但 lgrad 端点是归一化 0..1**（lgrad=c0,c1,x0,y0,x1,y1，(0,0)=本层左上，(1,1)=本层右下，与画布分辨率无关）——把像素写进端点会被拒绝",
    "meta",
  )
  add(
    "add-ellipse",
    "add-ellipse x= y= w= h= " + add_shape_keys(@core.ShapeKind::Ellipse).map(fn(k) { "[\{k}=]" }).join("") + "：椭圆（键见上；**没有 radius=**——圆角只对矩形有意义，要圆角请用 add-rect）",
    "meta",
  )
  add(
    "path-preview",
    "path-preview points=x,y;x,y;… [handles=dx,dy;…] [closed=true|false]：把锚点/控制柄**采样成折线**回报（只读）。钢笔在落定之前的预览走它——采样规则只有引擎一处（@core.path_samples），界面照它给的折线画，预览与落定不可能不一致",
    "both",
  )
  add(
    "add-path",
    "add-path x= y= points=x,y;x,y;…（锚点，局部坐标）[handles=dx,dy;dx,dy;…]" + add_shape_keys(@core.ShapeKind::Path).map(fn(k) { "[\{k}=]" }).join("") + "：**钢笔/贝塞尔路径**（④）。锚点在 points，控制柄在 handles——每个锚点 in/out 两个**相对锚点的偏移**（共 2×锚点数，不给 = 全 0 = 折线）。**fill=none ⇒ 开放路径（只描边）；给了填充 ⇒ 闭合路径（自动收口）**：闭合与否等价于「有没有面」，没有单独的 closed 键。默认 fill=none（钢笔先画线，填色要显式说）",
    "meta",
  )
  add(
    "bool-op",
    "bool-op op=union|subtract|intersect|xor a=<层 id> b=<层 id> [id=] [name=]：两个**有面**的形状做布尔运算，结果是一个新的**路径层**（path，可继续 set-style/edit）。op=subtract 读作 **a 减 b**。结果层的填充/描边继承 **a**。**一个岛 ⇒ 一层；多个岛 ⇒ 自动编成一个组**（每层一个岛）；**洞用反选蒙版表示**（所以洞里真的没有墨）。拒绝：操作数没有面（没有填充的开放路径/线段/文本/位图/组/调整层）、操作数在组里（祖先变换没算进轮廓）、两个操作数是同一层、结果为空、一个岛带两个以上洞",
    "meta",
  )
  add(
    "add-polygon",
    "add-polygon x= y= w= h= points=x,y;x,y;…（局部坐标）" + add_shape_keys(@core.ShapeKind::Polygon).map(fn(k) { "[\{k}=]" }).join("") + "：多边形（键见上，另需 points；**没有 stroke=/stroke_w=**——描边只实现了矩形/椭圆/线段）",
    "meta",
  )
  add(
    "add-line",
    "add-line x= y= w= h= " + add_shape_keys(@core.ShapeKind::Line).map(fn(k) { "[\{k}=]" }).join("") + "：折线，默认对角线，可 points= 自定义；**只有描边**（没有 fill=/lgrad=/radius=：要颜色用 stroke=）",
    "meta",
  )
  add(
    "add-image",
    "add-image x= y= w= h= b64=<png base64>：导入位图资产并置入。可选：" + add_image_keys().map(fn(k) { "[\{k}=]" }).join("") + "。**盒子跟着内容走**：不给 w=/h= 时盒 = 资产像素尺寸（400×300 的图不会缩进 100×100 的方框里），只给一边时另一边按原比例推，两边都给才听你的",
    "both",
  )
  add(
    "set-image",
    "set-image <id> b64=<png base64> [" + set_image_keys().map(fn(k) { "\{k}=/" }).join("") + "]：**原地换掉**一个位图层的资产——层序、蒙版、标签、透明度、翻转、旋转都不动（此前换图只能 delete 再 add-image，那些全丢、而且层被推到栈顶）。缺省盒子跟随新图（规则同 add-image）",
    "both",
  )
  add(
    "set-style",
    "set-style <id> " + set_style_keys().map(fn(k) { "\{k}=/" }).join("") + "（lgrad 端点归一化 0..1，非像素；**points=x,y;x,y;… 是层内局部坐标**，对 polygon/line/path 有意义，用来原地改顶点/锚点；**handles=… 只对 path 有意义**（锚点的 in/out 偏移，条数 = 2×锚点数）；tag= 追加标签，与 tag 命令同一实现）",
    "meta",
  )
  add("move", "move <id> <x> <y>：改层的位置。**组**是搬内容——连后代一起平移（回包给 `moved_layers`）；其余层只改自己的 x/y", "meta")
  add("resize", "resize <id> <w> <h>", "meta")
  add("rotate", "rotate <id> <deg>（绕层中心，顺时针）", "meta")
  add("flip", "flip <id> h|v|both|none（翻转；先翻转后旋转）", "meta")
  add(
    "transform",
    "transform <id> [x=] [y=] [w=] [h=] [rot=]：**自由变换**——位置 + 盒子 + 旋转一次写完，**一步历史**（move+resize+rotate 分开发是三步，撤销要按三次）。至少要给一个键；`w`/`h` 必须为正；`rot` 的 kind 门禁与 rotate 同一条（写不生效的字段照旧被拒）；`x`/`y` 对**组**是搬整棵子树（回包给 `moved_layers`）",
    "meta",
  )
  add("rename", "rename <id> <new-name>", "meta")
  add(
    "tag",
    "tag <id> <tag>：给层打语义标签。**标签当前只是容器里的元数据**：进 canonical JSON 与指纹、被 query-layer/list-layers 回读——**没有任何东西按标签筛选**（选择子还不认标签，见 DESIGN §8 边界）。重复打是幂等的（回包 `added:false`），空标签与 `*` 被拒；要摘用 untag",
    "both",
  )
  add(
    "untag",
    "untag <id> <tag|*>：摘掉标签（* = 清空全部）；没得摘就报错（不静默成功）——此前标签只增不减，打错一个只能删层重加（蒙版/调整/层序/id 引用全丢）",
    "both",
  )
  add("delete", "delete <id>", "meta")
  add("visible", "visible <id> <true|false>", "meta")
  add("reorder", "reorder <id> front|back|up|down", "meta")
  add(
    "group",
    "group <gid> <id> [id...]：把一个或多个**根级**层编成组（直通合成；嵌套编组请先 ungroup）。组的盒子 = 成员的并集，也是它的旋转/翻转**轴心**（改成员的位置/尺寸，轴心跟着走）",
    "meta",
  )
  add(
    "ungroup",
    "ungroup <gid>：解散整组。⚠️ 组上挂着 rot/flip 时会被**拒绝**——变换存在组自己身上，拆了就没有地方安放（画面会跳）；先 `rotate <gid> 0` / `flip <gid> none` 清掉",
    "meta",
  )
  add(
    "group-add",
    "group-add <gid> <id> [id...]：把**已有**的根级层加进**已有**的组（此前只能 ungroup + group 整体重组，组的 name/opacity/blend/tags/mask 全丢）。新成员追加到该组栈顶（children 自底向上 = 画在原有成员之上，要精确层序用 reorder）；成员必须是根级层**且不是组**（不支持嵌套编组）",
    "meta",
  )
  add(
    "group-remove",
    "group-remove <gid> <id> [id...]：把组的**直接成员**移回根级，落在**该组的槽位上（组的下一层，即画在组的下面**——与 `ungroup` 的落点一致；成员的相对次序保留，要精确层序用 reorder）。解散整组仍用 ungroup。⚠️ 组上挂着 rot/flip 时会被拒绝（同 ungroup：摘出来的成员不再经过那个变换，画面会跳）",
    "meta",
  )
  // 文本 / 调整 / 蒙版
  add(
    "add-text",
    "add-text x= y= text=<内容>：文本层（ASCII 真字形）；**含空格用双引号包住** text=\"Hello World\"，name= 同理。可选：" + add_text_keys().map(fn(k) { "[\{k}=]" }).join(""),
    "meta",
  )
  add(
    "set-text",
    "set-text <id> <新内容> [font_size=<px>] [w=<px>] [h=<px>]：改文字内容；**盒子跟着内容与字号重算**（不给 w/h 时按 6/7 字宽 × 字数 × 字号估算），要固定盒子就显式给 w=/h=（必须为正）。含空格用双引号包住。可选：" + set_text_keys().map(fn(k) { "[\{k}=]" }).join(""),
    "meta",
  )
  add(
    "add-adjust",
    // 算子清单与取值范围从 `adjust_value_range` 那张表生成（单一事实源）
    "add-adjust op=<算子> [value=<数>]：调整层（PSD 语义，作用于其下全部可见层）。算子：" + adjust_op_doc() + "。可选：" + add_adjust_keys().map(fn(k) { "[\{k}=]" }).join(""),
    "meta",
  )
  add(
    "set-adjust",
    "set-adjust <id> [op=<算子>] [value=<数>]：原地改调整层的算子/数值（**层序不变**——删了重加会把它推到栈顶，作用范围跟着变）。算子与范围同 add-adjust：" + adjust_op_doc() + "。可选：" + set_adjust_keys().map(fn(k) { "[\{k}=]" }).join(""),
    "meta",
  )
  add(
    "adjust-spec",
    "adjust-spec [op=<算子>]：报出每个调整算子**吃哪些参数键**（键名/范围/中性值/要不要整数）——前端据此画控件，别抄算子名单。不给 op= 就报全部。可选：" +
    adjust_spec_keys().map(fn(k) { "[\{k}=]" }).join(""),
    "both",
  )
  add("add-mask", "add-mask <id> " + mask_key_doc() + "：蒙版坐标是**画布坐标**（x/y/w/h 用像素，不随图层 move/rotate 走）", "meta")
  add(
    "set-mask",
    "set-mask <id> " + mask_key_doc() + "：**部分更新**，只改给的参数、其余原样保留（历史写法 `set-mask <id> true|false` 等价于只给 invert=）",
    "meta",
  )
  add("remove-mask", "remove-mask <id>：移除蒙版（层不存在、或本来没有蒙版 → 报错，不静默成功）", "meta")
  add(
    "set-fx",
    "set-fx <id> " + fx_key_doc() + "：图层样式（投影/描边/外发光/内阴影，PSD 语义）。**部分更新**：只改给的参数、其余沿用当前值（层上还没有样式时以缺省样式为底）。样式作用在**这一层自己的像素**上（先栅格化再整块按 blend/opacity 合成），**调整层没有自己的像素、装不了**。半径/宽度上限 64px（超过按上限算：不会更大、只是更慢）。clear=1 摘掉整份样式",
    "meta",
  )
  // 修图操作
  add(
    "add-paint",
    "add-paint：新建画笔层（raster；盒子跟着**落笔范围**走，所以 resize 只改一份没人读的快照——画面与 query-layer 都不变）。可选：" + add_paint_keys().map(fn(k) { "[\{k}=]" }).join(""),
    "meta",
  )
  add("brush", "brush layer=<raster层> pts=x1,y1;x2,y2[;…] r=<半径px> [color=#RRGGBB[AA]]：沿折线落笔触", "meta")
  add("erase", "erase layer=<raster层> pts=… r=<半径px>：橡皮擦（destination-out）。橡皮擦**恒全强度**，不接受 color 参数（收了也没用，所以入口直接拒绝）", "meta")
  add("clone", "clone layer=<raster层> pts=x1,y1;x2,y2[;…] r=<半径px> src=x,y：**仿制图章**（去污点）——沿 pts 落笔，但每一笔的颜色取自**本层之下**那张合成图的 src 处；整笔的源偏移 = src − 第一个落点，恒定（要换源就再发一条 = 非对齐）。src 是**画布坐标**（同 pts），必须在画布内；不接受 color（颜色来自画面）", "meta")
  add("crop", "crop <x> <y> <w> <h>：裁剪画布，全部层同步平移", "meta")
  add("sample", "sample <x> <y>：吸管取色（合成像素 hex + 命中层）", "vision")
  // 元参数
  add("list-params", "元参数表", "meta")
  add("set-param", "set-param <name> <value>（纯元数据，不影响渲染；同名覆盖。live 绑定属下轮）", "meta")
  add("remove-param", "remove-param <name>：删掉一个命名元参数（set-param 的对偶；不存在则报错，不静默成功）", "meta")
  // 视觉
  add("render", "render [width] [vx0 vy0 vx1 vy1] [overlay=1]：取景渲染 → PNG b64 + sha256；overlay 叠加层 bbox 序号线框", "vision")
  add("pick", "pick <x> <y>：画布坐标 → 最上层层 id", "both")
  add("stats", "直方图 32 桶 + 覆盖统计（引擎给数值，模型给判断）", "vision")
  add("census", "census [within=<base64 sel>] [components=n]：hue×sat 桶普查（12×3）+ OKLab L 与 HSV V 均值对照；给 within 时附覆盖率/bbox/连通域事实（components= **只在给了 within= 时可用**：不给选区时连通域事实不产出，入口直接拒）", "both")
  add("probe", "probe x= y= [r=2]：单点邻域统计（OKLab 均值/方差、环平均色相、边缘置信度）+ 当前编辑表每个算子的选择子在该点的 membership 与所属连通域 id。**要探多个位置用 `points=x1,y1;x2,y2;…`（上限 64 点，一次往返；返回 points 数组，每点的字段与单点模式完全一致）**，别重复调用——同给 x/y 与 points 时以 points 为准", "both")
  add("sel-schema", "选择子/算子语法自证清单：每种原子选择子与组合子的 canonical 示例（由写出器产出、由同一解析器验回）+ 量纲/取值范围 + 数值该从哪来。**写选择子前先看它**，别猜字段名与量纲", "both")
  // 历史 / 容器
  add("fingerprint", "当前 canonical design.json 指纹", "meta")
  add("inspect", "元参数层实时视图：manifest 摘要 + design.json 全文 + params + 编辑历史", "meta")
  add("edits", "编辑历史摘要（事件日志：连 undo/redo/goto 也记）", "meta")
  add(
    "history",
    "步骤历史：每一步的**人话标签** + 当前游标 + 还能回去的最早一步（`base`）与总步数；`done=false` 的行是「跳回后还没重做的未来步骤」（再动手就没了）",
    "both",
  )
  add(
    "goto",
    "goto <步号>：跳到第 k 步（0 = 初始状态；步号见 history）。跳回后再做新操作会**丢掉后面的步骤**（同 PS 历史面板）",
    "both",
  )
  add("undo", "撤销（canonical 快照栈，≤64）", "meta")
  add("redo", "重做", "meta")
  add("save-mpd-b64", "会话打包为 .mpd 容器字节（base64）", "meta")
  add("open-mpd-b64", "open-mpd-b64 <b64>：载入容器（拒绝式校验）", "meta")
  add(
    "psd-info",
    "psd-info b64=<psd base64>：只读地报一份 PSD 的结构（画布/通道/模式/层表：名字、x/y/w/h、opacity 0..255、visible、blend、合成图 sha256），**不改会话**——先看清会读成什么，再决定 open-psd。读不了的（位深 16/32、CMYK/索引/Lab/位图、ZIP 压缩、图层组、像素蒙版、图层效果、剪贴、未知混合模式）在这里**报明确错误**，不降级",
    "meta",
  )
  add(
    "open-psd",
    "open-psd b64=<psd base64> [uuid=..]：把 PSD 打开成当前文档（替换整份文档，语义同 new/open-mpd-b64）。每个 PSD 图层 → 一个 Image 层（像素按 PNG 内容寻址进资产表），**层序即渲染序**；0 图层的拼合文件 → 唯一一层 composite（盒子=画布）；opacity 由 0..255 折成 0..1（唯一一处换算）。**边界（明确拒绝，不静默丢）**：位深 16/32、CMYK/索引/Lab/位图、ZIP/ZIP+pred 压缩、图层组、**真**像素蒙版（全可见的占位蒙版照读）、图层效果、剪贴蒙版、未知混合模式、8 位以外的通道数",
    "meta",
  )
  // MVSL 编辑表（确定性编辑 IR）：人机同一张表，AI 与 GUI 同一撤销栈
  add("mvsl-set", "mvsl-set <base64(canonical program json)>：安装 MVSL 编辑表（校验+规范化，空 ops 表示逐位还原底图）。算子 JSON 里可带 layer 字段（值是层 id）把作用域收窄到那一层——该层先单独栅格化、选择子在**这一层自己的像素**上求值，再合成回去；带 layer 的算子先按序执行、然后合成、最后才跑文档级算子（跨作用域的相对顺序不保留）。`stage:n` 一律指**表里**第 n 条算子之后的中间缓冲，而被引用那条必须与引用者**同段**（同为文档级算子，或同为同一个层的算子）且**严格在引用者之前**——跨段引用、自指、前视都在入口/lint/渲染三处同一句判据上拒，所以图层级算子也能用 STAGE(n>0)（目标在同层且更早即可）；`stage:0` = **本段的输入**（单段=底图，有 layer 时=层合成结果）。**规模限额**（超了拒绝装表，不静默降级）：算子 ≤ 256 条、保护断言 ≤ 64 条、且 算子数×画布像素数 ≤ 2e8（按实测 2 µs/(像素·算子)，这是约 400 秒的单次渲染上限——巨幅画布上几十条算子就会超）；装表后 set-canvas 放大画布同样会在渲染时被拦", "meta")
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
