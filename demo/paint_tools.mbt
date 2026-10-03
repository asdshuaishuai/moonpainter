/// demo —— ToolProvider 端口：把 MoonPainter 命令面暴露为 LLM 工具
/// （demo/paint_tools）。
///
/// execute 的引擎交互全部经 wasm SDK 实例（engine_exec_line → in 槽 →
/// mp_exec_in），与 CLI/页面同一分发器。render 工具把渲染 PNG 以
/// SuccessWithAttachments(Content::Image) 附回——多模态模型下一轮真的看到图，
/// 这是"AI 同步修图"的视觉闭环通道。

///|
fn schema(props : Array[(String, String)]) -> Json {
  let m : Map[String, Json] = Map([])
  let props_map : Map[String, Json] = Map([])
  let required : Array[Json] = []
  for p in props {
    let kv : Array[String] = []
    for seg in p.1.split(":") {
      kv.push(seg.to_owned())
    }
    let typ = if kv.length() > 0 { kv[0] } else { "string" }
    let req = kv.length() > 1 && kv[1] == "req"
    let desc = if kv.length() > 2 { kv[2] } else { "" }
    let pm : Map[String, Json] = { "type": Json::string(typ) }
    if desc != "" {
      pm["description"] = Json::string(desc)
    }
    props_map[p.0] = Json::object(pm)
    if req {
      required.push(Json::string(p.0))
    }
  }
  m["properties"] = Json::object(props_map)
  if required.length() > 0 {
    m["required"] = Json::array(required)
  }
  Json::object(m)
}

///|
let tool_owner : @posoco.OwnerId = @posoco.OwnerId::unchecked("moonpainter")

///|
fn make_tool(name : String, desc : String, props : Array[(String, String)]) -> @posoco.ToolDef {
  {
    name: @posoco.ToolName::unchecked(name),
    description: desc,
    input_schema: schema(props),
    owner: tool_owner,
    policy: @posoco.ExecutionPolicy::Sequential,
    provenance: None,
  }
}

///|
/// 工具名清单。存在的意义是让「产品里的 AI 够不够得着某个能力」**变成可测的
/// 断言**——人类前端有某个按钮，不等于工具面暴露了对应工具。`redo` 就是这么
/// 漏掉的：`main.mbt` 一直有「↪ 重做」按钮，工具面却只有 `undo`。
pub fn paint_tool_names() -> Array[String] {
  paint_tool_defs().map(fn(t) { t.name.value })
}

///|
/// 工具名 → 引擎命令名（**单一事实源**）。
///
/// 原先这是 `execute` 内部的一个 match，于是"注册了工具、却忘了在这里接"
/// 只能靠人眼发现——`undo` 就这么坏了很久：`line` match 里有它、`cmd`
/// match 里没有，而 `cmd` **先求值**，所以 AI 每次调 undo 拿到的都是
/// "未知工具 undo"。人类前端有「↩ 撤销」按钮，没人从 AI 那条路走过去，
/// 于是它一直没暴露。现在与 `paint_tool_defs` 的一致性由
/// `undispatched_tools()` 断言守住。
fn tool_cmd(name : String) -> String? {
  match name {
    "new_canvas" => Some("new")
    "add_rect" => Some("add-rect")
    "add_ellipse" => Some("add-ellipse")
    "add_line" => Some("add-line")
    "add_polygon" => Some("add-polygon")
    "set_style" => Some("set-style")
    "move" => Some("move")
    "resize" => Some("resize")
    "rotate" => Some("rotate")
    "flip" => Some("flip")
    "delete" => Some("delete")
    "reorder" => Some("reorder")
    "render" => Some("render")
    "pick" => Some("pick")
    "list_layers" => Some("list-layers")
    "query_layer" => Some("query-layer")
    "stats" => Some("stats")
    "lint" => Some("lint")
    "save_mpd" => Some("save-mpd-b64")
    "sel_schema" => Some("sel-schema")
    "census" => Some("census")
    "probe" => Some("probe")
    "select_preview" => Some("select-preview")
    "mvsl_set" => Some("mvsl-set")
    "mvsl_show" => Some("mvsl-show")
    "mvsl_clear" => Some("mvsl-clear")
    "mvsl_impact" => Some("mvsl-impact")
    "mvsl_assert" => Some("mvsl-assert")
    // B4.5 起的工具：画笔 / 橡皮 / 调整层 / 分组 / 标签 / 裁剪 / 采样。
    // 它们当初只加进了 `line` match，**没加进这张表**，于是 `cmd` 求值阶段
    // 就直接返回"未知工具"——9 个工具在工具面上一直是坏的（人类走前端按钮，
    // 而这些工具的端到端回合从来没写过，所以没人发现）。
    "add_mask" => Some("add-mask")
    "set_mask" => Some("set-mask")
    "remove_mask" => Some("remove-mask")
    "add_text" => Some("add-text")
    "set_text" => Some("set-text")
    "visible" => Some("visible")
    "group" => Some("group")
    "ungroup" => Some("ungroup")
    "group_add" => Some("group-add")
    "group_remove" => Some("group-remove")
    "tag" => Some("tag")
    "untag" => Some("untag")
    "add_paint_layer" => Some("add-paint")
    "paint_stroke" => Some("brush")
    "erase_stroke" => Some("erase")
    "apply_filter" => Some("add-adjust")
    "set_adjust" => Some("set-adjust")
    "crop_canvas" => Some("crop")
    "sample_color" => Some("sample")
    "undo" => Some("undo")
    "redo" => Some("redo")
    "edits" => Some("edits")
    "rename" => Some("rename")
    "list_params" => Some("list-params")
    "set_param" => Some("set-param")
    "remove_param" => Some("remove-param")
    "set_canvas" => Some("set-canvas")
    _ => None
  }
}

///|
/// 工具面自检：返回**注册了却接不上引擎命令行**的工具名（空 = 健康）。
///
/// 这是 `undo` 那个 bug 的根治手段——把"工具定义"与"命令分发"的一致性
/// 从"靠人眼比对两张表"变成一条断言。
pub fn undispatched_tools() -> Array[String] {
  let bad : Array[String] = []
  for t in paint_tool_defs() {
    match tool_cmd(t.name.value) {
      None => bad.push(t.name.value)
      Some(_) => ()
    }
  }
  bad
}

///|
/// 修图工具集（LLM 视角；底层是一一对应的引擎命令行）。
fn paint_tool_defs() -> Array[@posoco.ToolDef] {
  [
    make_tool("list_layers", "列出画布上全部图层（id/名称/类型/几何/混合/透明度）", []),
    make_tool(
      "query_layer",
      "查询单个图层详情",
      [("id", "string:req:图层 id，如 l1")],
    ),
    make_tool(
      "new_canvas",
      "新建画布（会清空现有内容）",
      [("w", "integer:req:宽度像素"), ("h", "integer:req:高度像素")],
    ),
    make_tool(
      "add_rect",
      "添加矩形（可圆角）",
      [
        ("x", "number:req:左上 x"),
        ("y", "number:req:左上 y"),
        ("w", "number:req:宽"),
        ("h", "number:req:高"),
        ("fill", "string:填充色 #RRGGBB[AA]"),
        ("radius", "number:圆角半径"),
        ("name", "string:图层名"),
        ("opacity", "number:透明度 0..1"),
        ("blend", "string:混合模式 normal/multiply/screen/overlay/darken/lighten/difference"),
      ],
    ),
    make_tool(
      "add_ellipse",
      "添加椭圆",
      [
        ("x", "number:req:左上 x"),
        ("y", "number:req:左上 y"),
        ("w", "number:req:宽"),
        ("h", "number:req:高"),
        ("fill", "string:填充色"),
        ("lgrad", "string:线性渐变 c0,c1,x0,y0,x1,y1（端点**归一化到本层 bbox**，0..1；注意不是像素，x/y/w/h 才是像素）"),
        ("name", "string:图层名"),
        ("blend", "string:混合模式"),
      ],
    ),
    make_tool(
      "add_line",
      "添加线段/折线（无填充面，用描边）",
      [
        ("x", "number:req:占位盒左上 x"),
        ("y", "number:req:占位盒左上 y"),
        ("w", "number:req:占位盒宽（>0）"),
        ("h", "number:req:占位盒高（>0）"),
        ("points", "string:顶点 x,y;x,y;…（局部坐标）"),
        ("stroke", "string:描边色"),
        ("stroke_w", "number:描边宽"),
        ("name", "string:图层名"),
      ],
    ),
    make_tool(
      "add_polygon",
      "添加多边形",
      [
        ("x", "number:req:占位盒左上 x"),
        ("y", "number:req:占位盒左上 y"),
        ("w", "number:req:占位盒宽"),
        ("h", "number:req:占位盒高"),
        ("points", "string:req:顶点 x,y;x,y;…（局部坐标）"),
        ("fill", "string:填充色"),
        ("name", "string:图层名"),
      ],
    ),
    make_tool(
      "set_style",
      "修改图层样式",
      [
        ("id", "string:req:图层 id"),
        ("fill", "string:填充色 #RRGGBB[AA] 或 none"),
        ("lgrad", "string:线性渐变 c0,c1,x0,y0,x1,y1（端点归一化 0..1，非像素）"),
        ("stroke", "string:描边色"),
        ("stroke_w", "number:描边宽"),
        ("opacity", "number:透明度 0..1"),
        ("blend", "string:混合模式"),
        ("radius", "number:圆角"),
        ("points", "string:顶点 x,y;x,y;…（层内局部坐标，只对 polygon/line 有效）"),
        ("rot", "number:旋转角度（顺时针度）"),
        ("visible", "string:true/false"),
        ("name", "string:新名称"),
      ],
    ),
    make_tool("move", "移动图层（选中组时整个搬走它里面的内容）", [("id", "string:req:图层 id"), ("x", "number:req:新 x"), ("y", "number:req:新 y")]),
    make_tool("resize", "改图层尺寸", [("id", "string:req:图层 id"), ("w", "number:req:新宽"), ("h", "number:req:新高")]),
    make_tool("rotate", "旋转图层", [("id", "string:req:图层 id"), ("deg", "number:req:角度")]),
    make_tool(
      "flip",
      "翻转图层",
      [("id", "string:req:图层 id"), ("how", "string:req:h/v/both/none")],
    ),
    make_tool("delete", "删除图层", [("id", "string:req:图层 id")]),
    make_tool(
      "reorder",
      "调整层序",
      [("id", "string:req:图层 id"), ("how", "string:req:front/back/up/down")],
    ),
    make_tool("stats", "画布统计与亮度直方图（客观视觉量）", []),
    make_tool("lint", "设计检查（引用/几何/限额违规）", []),
    make_tool(
      "render",
      "渲染当前画布为 PNG（图片会附回给你查看，并展示给用户）",
      [
        ("w", "integer:输出宽度像素（默认 640）"),
        ("overlay", "string:'1' 叠加层序号线框"),
      ],
    ),
    make_tool("pick", "查询画布坐标命中的图层", [("x", "number:req:x"), ("y", "number:req:y")]),
    make_tool(
      "group",
      "把多个根级图层编成组（直通合成）",
      [("gid", "string:req:新组 id"), ("ids", "string:req:成员 id 列表，逗号分隔")],
    ),
    make_tool("ungroup", "解组", [("gid", "string:req:组 id")]),
    make_tool(
      "group_add",
      "把一个或多个**已有根级**图层加进**已有**的组（组的 name/opacity/blend/tags/mask 都不动）。新成员追加到组栈顶；成员必须是根级层且不是组（不支持嵌套编组）",
      [("gid", "string:req:目标组 id"), ("ids", "string:req:成员 id 列表，逗号分隔")],
    ),
    make_tool(
      "group_remove",
      "把组的**直接**成员移回根级（落在该组的层序位置 = 组的下一层，与 ungroup 的落点一致）。解散整组用 ungroup",
      [("gid", "string:req:组 id"), ("ids", "string:req:成员 id 列表，逗号分隔")],
    ),
    make_tool("tag", "给图层打语义标签（如 hero/background/logo）。标签是容器里的元数据（进指纹、可回读），当前不参与渲染与选择子", [("id", "string:req:图层 id"), ("tag", "string:req:标签")]),
    make_tool("untag", "摘掉图层标签；tag 参数给 * 则清空该层全部标签。摘不存在/空的标签会报错，不会静默成功", [("id", "string:req:图层 id"), ("tag", "string:req:要摘的标签，* = 清空全部")]),
    make_tool(
      "list_params",
      "读命名元参数（如品牌主色、网点密度这类设计系统元数据）。它是**纯元数据**，不影响渲染——改画面要走 MVSL/图形命令，这里只读写「设计说明」。",
      [],
    ),
    make_tool(
      "set_param",
      "写一个命名元参数（同名覆盖）。纯元数据、不影响渲染；用来把设计意图写进容器让后续会话/人类看得到。",
      [("name", "string:req:参数名，如 主色"), ("value", "string:req:参数值，如 #C81E1E")],
    ),
    make_tool(
      "remove_param",
      "删掉一个命名元参数（set_param 的对偶；不存在会报错）。名字写错时用它撤销，而不是把值清空——清空只是把值改成空串，条目还在。",
      [("name", "string:req:参数名")],
    ),
    make_tool("undo", "撤销上一次修改（工具出错后自我纠正用）", []),
    make_tool("redo", "重做被撤销的修改（undo 的对偶；撤销过头时恢复）", []),
    make_tool(
      "edits",
      "编辑历史摘要：每一步快照的操作名与序号。用来判断还能撤几步、以及刚才那几步各自做了什么（撤销过头时先看它再决定 redo 到哪）。",
      [],
    ),
    make_tool(
      "rename",
      "给图层改名（只改显示名，不动 id 与渲染结果）。名字应当让用户一眼看懂这层是什么——它会进 list_layers 的输出，也是你自己后续决策的线索。",
      [
        ("id", "string:req:层 id"),
        ("new_name", "string:req:新名字（含空格用双引号包起来）"),
      ],
    ),
    make_tool(
      "set_canvas",
      "改画布尺寸。**只改画布，图层不会被移动或缩放**——尺寸变大就多出一块空白，变小就把超出的内容裁掉。想缩放内容请用各层自己的 resize/transform。",
      [("w", "integer:req:新画布宽 px"), ("h", "integer:req:新高 px")],
    ),
    make_tool(
      "add_mask",
      "给图层加几何蒙版 = **只让这一块渲染**（蒙版外不渲染）。任何参数都可用 set_mask 原地改",
      [
        ("id", "string:req:图层 id"),
        (
          "kind",
          "string:req:rect / ellipse / **polygon**（任意形状选区 = 套索：按颜色选出来的一块用 polygon 圈）",
        ),
        ("x", "number:req:蒙版左上 x —— **本层局部坐标**（不是画布坐标！根级不转不翻的层换算：局部 = 画布 − 该层 x；先 query-layer 取 x/y）"),
        ("y", "number:req:蒙版左上 y —— **本层局部坐标**（局部 = 画布 − 该层 y）"),
        ("w", "number:req:蒙版宽（像素）"),
        ("h", "number:req:蒙版高（像素）"),
        ("radius", "number:圆角（像素，仅 rect；超过半边长按半边长夹住）"),
        (
          "feather",
          "number:边缘羽化（像素，默认 0=硬边）。过渡带在**蒙版内侧**：边界处覆盖 0，向内 feather 像素处到满覆盖。矩形与椭圆都吃",
        ),
        (
          "roughen",
          "number:边缘毛化幅度（像素，默认 0=光滑边）。按画布坐标的确定性噪声扰动边界，得到手绘/撕裂纸边那种不规则轮廓；可与 feather 叠加（先毛化再羽化）",
        ),
        (
          "points",
          "string:仅 kind=polygon：顶点串 `x,y;x,y;…`，**蒙版盒内的局部坐标**（0..w / 0..h，相对 x/y），至少 3 个。盒子就是支持窗，顶点必须落在盒内（跑出去那部分画不出来，入口会拒）",
        ),
        ("invert", "string:true 则反选（蒙版内反而不渲染）"),
      ],
    ),
    make_tool(
      "set_mask",
      "原地改蒙版参数（**部分更新**：只给要改的，其余保留）",
      [
        ("id", "string:req:图层 id"),
        ("kind", "string:rect / ellipse / polygon（换形状）"),
        ("x", "number:蒙版左上 x —— **本层局部坐标**（局部 = 画布 − 该层 x）"),
        ("y", "number:蒙版左上 y —— **本层局部坐标**（局部 = 画布 − 该层 y）"),
        ("w", "number:蒙版宽（像素）"),
        ("h", "number:蒙版高（像素）"),
        ("radius", "number:圆角（像素，仅 rect）"),
        ("feather", "number:边缘羽化（像素，0=硬边）"),
        ("roughen", "number:边缘毛化幅度（像素，0=光滑边）"),
        (
          "points",
          "string:仅多边形蒙版：顶点串 `x,y;x,y;…`（盒内局部坐标，≥3 个）——**改选区形状就改它**",
        ),
        ("invert", "string:true 反选 / false 正常"),
      ],
    ),
    make_tool(
      "remove_mask",
      "移除图层蒙版（恢复整层渲染）",
      [("id", "string:req:图层 id")],
    ),
    make_tool(
      "add_text",
      "加文本层（ASCII 真字形）。文字可含空格（命令行层会自动加引号）",
      [
        ("x", "integer:req:左上 x（像素）"),
        ("y", "integer:req:左上 y（像素）"),
        ("text", "string:req:文字内容，可含空格"),
        ("font_size", "integer:字号 px（默认 16）"),
        ("fill", "string:颜色 #RRGGBB[AA]（默认黑）"),
        ("name", "string:图层名"),
      ],
    ),
    make_tool(
      "set_text",
      "改文本层的内容（位置/颜色保留）。盒子跟着内容与字号重算；要固定盒子用 resize",
      [
        ("id", "string:req:文本层 id"),
        ("text", "string:req:新内容，可含空格"),
        ("font_size", "integer:选填:新字号 px（不给则沿用当前字号）"),
      ],
    ),
    make_tool(
      "visible",
      "切换图层可见性（`visible=false` 的层不参与渲染，但仍留在文档里）",
      [("id", "string:req:图层 id"), ("visible", "string:req:true 或 false")],
    ),
    make_tool("save_mpd", "把当前文档打包为 .mpd 容器（页面会提供下载）", []),
    // 修图操作（B4.5）
    make_tool("add_paint_layer", "新建画笔层（自由手绘/涂抹的载体）", [("name", "string:图层名")]),
    make_tool(
      "paint_stroke",
      "画笔：沿折线落笔触（手绘/涂鸦/标注）",
      [
        ("layer", "string:req:画笔层 id（raster；先 add_paint_layer）"),
        ("pts", "string:req:折线 x,y;x,y;…（画布坐标）"),
        ("r", "number:笔触半径 px（默认 6）"),
        ("color", "string:颜色 #RRGGBB[AA]（默认黑）"),
      ],
    ),
    make_tool(
      "erase_stroke",
      "橡皮擦：擦除画笔层笔迹",
      [
        ("layer", "string:req:画笔层 id"),
        ("pts", "string:req:折线 x,y;x,y;…"),
        ("r", "number:半径 px（默认 10）"),
      ],
    ),
    make_tool(
      "apply_filter",
      "叠加调整层（非破坏，可撤销）：blur模糊/sharpen锐化/smooth磨皮/whiten美白/warm暖色(-负=冷)/vignette暗角/grayscale黑白/invert反色/brightness/contrast/saturation",
      [
        ("op", "string:req:算子名"),
        ("value", "number:req:强度 -1..1（0..1 为单向操作）"),
      ],
    ),
    make_tool(
      "set_adjust",
      "改一个已有调整层的算子/数值（**原地改，层序不变**）。要微调刚才那个滤镜时用它——删了重加会把调整层推到栈顶，作用范围跟着变。",
      [
        ("id", "string:req:调整层 id（list_layers 里 kind=adjust 的那个）"),
        ("op", "string:算子名（不给则沿用原算子）"),
        ("value", "number:新强度 -1..1（不给则沿用原值）"),
      ],
    ),
    make_tool(
      "crop_canvas",
      "裁剪画布到区域（全部层同步平移）",
      [
        ("x", "number:req:左上 x"),
        ("y", "number:req:左上 y"),
        ("w", "number:req:宽"),
        ("h", "number:req:高"),
      ],
    ),
    make_tool(
      "sample_color",
      "吸管：取画布坐标处合成像素颜色",
      [("x", "number:req:x"), ("y", "number:req:y")],
    ),
    // MVSL 确定性编辑表（B5）：谓词选择子 + 有序算子程序 + 保护断言。
    // 这些工具是"改颜色"的正路——比叠加调整层更精确、可断言、可随容器落盘。
    make_tool(
      "sel_schema",
      "选择子/算子语法自证清单：每种原子选择子与组合子的 canonical 示例 + 量纲/取值范围 + **颜色数值该从哪个字段取**。写任何选择子之前先调它——字段名与量纲猜错的表现是「命令成功但一个像素都没选中」，非常难自查。",
      [],
    ),
    make_tool(
      "census",
      "颜色普查：全图 hue×sat 桶（12×3）+ OKLab L 与 HSV V 均值。给 within_json 时只统计该选择子的区域，并附覆盖率/bbox/连通域事实。**先普查再选色**，不要靠猜。",
      [
        ("within_json", "string:选择子 JSON（留空 = 全图）"),
        ("components", "integer:最多回几条连通域事实（默认 16）"),
      ],
    ),
    make_tool(
      "probe",
      "探针：邻域 OKLab 均值/方差、环平均色相、边缘置信度，外加当前编辑表每个算子/断言在该点的 membership 与所属连通域 id。**逐算子条目带 layer=…：带 layer 的算子量的是「它自己那一层的栅格」**（不是合成图）；编辑表跑不起来时逐算子归属报不出来，会另给 ops_error 说明原因（点上的颜色/边缘统计照旧可用）。用于确认「我指的这个点，选择子到底选中没有」。**要探多个位置就用 points 一次拿全**（比如取景九宫格），不要重复调用单点。",
      [
        ("x", "integer:画布 x（单点模式；与 points 二选一）"),
        ("y", "integer:画布 y（单点模式；与 points 二选一）"),
        ("r", "integer:邻域半径 px（默认 2 → 5×5），两种模式都吃"),
        (
          "points",
          "string:批量：x1,y1;x2,y2;…（最多 64 点；返回 points 数组，每点字段与单点模式完全一致。与 x/y 同给时以 points 为准）",
        ),
      ],
    ),
    make_tool(
      "select_preview",
      "选择子试选：把选择子画成洋红覆盖图（附回给你看）+ 覆盖率/bbox/连通域事实。**改色前必须先试选**：看图确认选中的是不是你要的东西，用返回的连通域 id 说话，不要报坐标。",
      [
        ("sel_json", "string:req:选择子 JSON"),
        ("max", "integer:覆盖图最长边 px（默认 512）"),
      ],
    ),
    make_tool(
      "mvsl_set",
      "安装编辑表（覆盖当前编辑表）：有序算子程序 + 保护断言。**算子可带 layer=<层 id> 把作用域收窄到那一层**——该层先单独栅格化、选择子在「这一层自己的像素」上求值，再合成回去；这是「只改某个图层」的唯一正确做法（在合成图上做，前景与背景已经乘在一起了）。layer=@<标签> 则作用于**带该标签的全部层**（活绑定：打/摘标签即改作用范围；落不到任何层会被拒绝，不静默不生效）。带 layer 的算子先按序执行、然后合成、最后才跑文档级算子。装完必须 mvsl_impact 看差异、mvsl_assert 验约束。",
      [("program_json", "string:req:编辑表 JSON（{\"version\":1,\"ops\":[…],\"guards\":[…]}）；算子字段 layer=\"<层 id>\" 或 \"@<标签>\" 可选，空/缺省=文档级")],
    ),
    make_tool("mvsl_show", "查看当前编辑表（canonical JSON + 指纹）", []),
    make_tool("mvsl_clear", "清空编辑表（渲染回到未编辑状态）", []),
    make_tool(
      "mvsl_impact",
      "编辑表影响证书：逐算子改动像素数/平均与最大 ΔE/目标区 ΔE/选区外泄漏率，并附结果图。**逐算子条目带 layer=…，量的是它真正执行的那一步**（层算子 = 那一层的栅格、文档级 = 合成图）；`doc_stages` = 可被 stage:n 引用的阶段数，`executed` = 真正执行的算子级阶段数（layer=@标签 展开成几层就是几个）。**泄漏率是软边界是否越界的第一号指标**：>0 说明改到了不该改的地方。",
      [("max", "integer:结果图最长边 px（默认 512）")],
    ),
    make_tool(
      "mvsl_assert",
      "校验保护断言：有违反则工具直接报错并列出明细（「别动人物」从愿望变成机器可验证约束）。",
      [],
    ),
  ]
}

///|
/// arguments Json → k=v 命令行尾段。字符串原样、数字 to_string、布尔 1/0。
fn args_to_tail(args : Json, keys : Array[String]) -> String {
  let parts : Array[String] = []
  let obj = match args {
    Json::Object(m) => Some(m)
    _ => None
  }
  for k in keys {
    match obj {
      Some(m) =>
        match m.get(k) {
          Some(Json::String(s)) => parts.push("\{k}=\{s}")
          Some(Json::Number(n, ..)) => parts.push("\{k}=\{fmt_arg_num(n)}")
          Some(Json::True) => parts.push("\{k}=1")
          Some(Json::False) => parts.push("\{k}=0")
          _ => ()
        }
      None => ()
    }
  }
  let sb = StringBuilder()
  let mut f = true
  for p in parts {
    if f {
      f = false
    } else {
      sb.write_string(" ")
    }
    sb.write_string(p)
  }
  sb.to_string()
}

///|
/// 模型给的是 JSON 文本，命令面要的是 base64 —— 转换是 SDK 的职责，
/// 不该让 LLM 手搓 base64（它会算错，而且错了很难自查）。
fn b64_text(text : String) -> String {
  @base64.encode(@utf8.encode(text))
}

///|
fn fmt_arg_num(n : Double) -> String {
  if n == n.to_int().to_double() {
    n.to_int().to_string()
  } else {
    "\{n}"
  }
}

///|
/// 引擎信封里的 ok 标记。
fn envelope_ok(envelope : String) -> Bool {
  envelope.contains("\"ok\":true")
}

///|
struct PaintTools {}

///|
fn PaintTools::PaintTools() -> PaintTools {
  PaintTools::{  }
}

///|
pub impl @posoco.ToolProvider for PaintTools with fn list_tools(
  _self,
) -> Array[@posoco.ToolDef] {
  paint_tool_defs()
}

///|
pub impl @posoco.ToolProvider for PaintTools with fn execute(
  _self,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise {
  // 未知工具在这里拦（`tool_line` 内部也会取一次命令名，那是给测试用的纯入口）
  if tool_cmd(name) is None {
    return @posoco.ToolOutcome::ToolReportedError(
      content="未知工具 \{name}",
      structured=None,
    )
  }
  let line = tool_line(name, call.arguments)
  let envelope = engine_exec_line(line)
  if !envelope_ok(envelope) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="引擎拒绝（请读错误修正参数重试）：\{envelope}",
      structured=None,
    )
  }
  // 图像类工具：把 PNG 附回（多模态视觉闭环）；同时页面侧经 Observer 上屏。
  // render / select_preview / mvsl_impact 都必须让模型**真的看到图**——
  // 试选不看图就等于闭眼改色，影响证书不看图就发现不了选区跑偏。
  let (img_field, label) = if name == "render" {
    ("png_b64", "渲染完成")
  } else if name == "select_preview" {
    ("overlay_png_b64", "试选覆盖图已生成（洋红 = 选择子命中）")
  } else if name == "mvsl_impact" {
    ("result_png_b64", "编辑结果图已生成")
  } else {
    ("", "")
  }
  if img_field != "" {
    let png = extract_json_string(envelope, img_field)
    if png != "" {
      return @posoco.ToolOutcome::SuccessWithAttachments(
        content="\{label}：\{shorten(envelope, 240)}",
        structured=None,
        attachments=[@posoco.Content::Image(media_type="image/png", data=png)],
      )
    }
  }
  // save：b64 不回吐给模型（省 token），页面经全局缓存下载
  if name == "save_mpd" {
    let b64 = extract_json_string(envelope, "mpd_b64")
    g_last_mpd_b64.val = b64
    let approx_bytes = b64.length() / 4 * 3
    return @posoco.ToolOutcome::Success(
      content="已打包 .mpd 容器（约 \{approx_bytes} 字节），页面可下载；指纹见信封。",
      structured=None,
    )
  }
  @posoco.ToolOutcome::Success(content=shorten(envelope, 600), structured=None)
}

///|
/// 工具调用 → 引擎命令行（**第二张表**，与 `tool_cmd` 一样只此一处）。
///
/// 它原先藏在 `execute` 内部，于是"注册了工具、`tool_cmd` 里也接了、但这里
/// 漏了"仍然只能靠人眼——`undispatched_tools()` 只查前一张表，而
/// `engine_exec_line` 直接调引擎、**绕过**这里，两条测试路径都照不到。
/// 提取成接受 `Json` 的纯函数后，测试可以直接喂参数进来断言拼出的命令行。
pub fn tool_line(name : String, args : Json) -> String {
  let cmd = tool_cmd(name).unwrap_or("")
  let out = match name {
    "list_layers" => "list-layers"
    "stats" => "stats"
    "lint" => "lint"
    "save_mpd" => "save-mpd-b64"
    "move" => {
      let id = arg_of(args, "id")
      "move \{id} \{arg_of(args, "x")} \{arg_of(args, "y")}"
    }
    "resize" => {
      let id = arg_of(args, "id")
      "resize \{id} \{arg_of(args, "w")} \{arg_of(args, "h")}"
    }
    "rotate" => {
      let id = arg_of(args, "id")
      "rotate \{id} \{arg_of(args, "deg")}"
    }
    "flip" => {
      let id = arg_of(args, "id")
      "flip \{id} \{arg_of(args, "how")}"
    }
    "delete" => {
      let id = arg_of(args, "id")
      "delete \{id}"
    }
    "reorder" => {
      let id = arg_of(args, "id")
      "reorder \{id} \{arg_of(args, "how")}"
    }
    "query_layer" => {
      let id = arg_of(args, "id")
      "query-layer \{id}"
    }
    "pick" => "pick \{arg_of(args, "x")} \{arg_of(args, "y")}"
    "add_mask" => {
      let id = arg_of(args, "id")
      let kind = arg_of(args, "kind")
      let tail = args_to_tail(
        args,
        ["x", "y", "w", "h", "radius", "feather", "roughen", "invert"],
      )
      "add-mask \{id} kind=\{kind} \{tail}"
    }
    "set_mask" => {
      // 参数面从这里整条拼出去（含 `invert`）：工具面能改的正是引擎 `set-mask`
      // 认的那些键，别在这里手写第二份键清单（漂移一次就是"改了没反应"）。
      let tail = args_to_tail(
        args,
        ["kind", "x", "y", "w", "h", "radius", "feather", "roughen", "invert"],
      )
      "set-mask \{arg_of(args, "id")} \{tail}"
    }
    "remove_mask" => "remove-mask \{arg_of(args, "id")}"
    "add_text" => {
      let x = arg_of(args, "x")
      let y = arg_of(args, "y")
      let txt = quote_arg(arg_of(args, "text"))
      let fs = opt_of(args, "font_size", "16")
      let fill = opt_of(args, "fill", "#000000FF")
      let name = quote_arg(opt_of(args, "name", "文本"))
      "add-text x=\{x} y=\{y} text=\{txt} font_size=\{fs} fill=\{fill} name=\{name}"
    }
    "set_text" => {
      let id = arg_of(args, "id")
      let fs = arg_of(args, "font_size")
      // 字号可选：不给就不写这个 kv（引擎按"沿用当前字号"处理）
      let head = "set-text \{id} \{quote_arg(arg_of(args, "text"))}"
      if fs == "" {
        head
      } else {
        "\{head} font_size=\{fs}"
      }
    }
    "visible" => "visible \{arg_of(args, "id")} \{arg_of(args, "visible")}"
    "group" => {
      let ids = arg_of(args, "ids")
      "group \{arg_of(args, "gid")} \{ids.replace(old=",", new=" ")}"
    }
    "ungroup" => {
      let gid = arg_of(args, "gid")
      "ungroup \{gid}"
    }
    "group_add" => {
      let ids = arg_of(args, "ids")
      "group-add \{arg_of(args, "gid")} \{ids.replace(old=",", new=" ")}"
    }
    "group_remove" => {
      let ids = arg_of(args, "ids")
      "group-remove \{arg_of(args, "gid")} \{ids.replace(old=",", new=" ")}"
    }
    "tag" => "tag \{arg_of(args, "id")} \{arg_of(args, "tag")}"
    "untag" => "untag \{arg_of(args, "id")} \{arg_of(args, "tag")}"
    "list_params" => "list-params"
    "set_param" => {
      let name = quote_arg(arg_of(args, "name"))
      let value = quote_arg(arg_of(args, "value"))
      "set-param \{name} \{value}"
    }
    "remove_param" => "remove-param \{quote_arg(arg_of(args, "name"))}"
    "undo" => "undo"
    "redo" => "redo"
    "edits" => "edits"
    "rename" => {
      let id = arg_of(args, "id")
      "rename \{id} \{quote_arg(arg_of(args, "new_name"))}"
    }
    "set_canvas" => "set-canvas \{arg_of(args, "w")} \{arg_of(args, "h")}"
    "new_canvas" => "new \{arg_of(args, "w")} \{arg_of(args, "h")}"
    "add_paint_layer" => {
      let tail = args_to_tail(args, ["name"])
      "add-paint \{tail}"
    }
    "paint_stroke" => {
      let lid = arg_of(args, "layer")
      let pts = arg_of(args, "pts")
      let r = opt_of(args, "r", "6")
      let color = opt_of(args, "color", "#222222FF")
      "brush layer=\{lid} pts=\{pts} r=\{r} color=\{color}"
    }
    "erase_stroke" => {
      let lid = arg_of(args, "layer")
      let pts = arg_of(args, "pts")
      let r = opt_of(args, "r", "10")
      "erase layer=\{lid} pts=\{pts} r=\{r}"
    }
    "apply_filter" =>
      "add-adjust op=\{arg_of(args, "op")} value=\{opt_of(args, "value", "0.5")}"
    "set_adjust" => {
      // `arg_of` 对缺键返回空串；op/value 都不可能是合法的空串，
      // 所以"空=没给"（没给就让引擎沿用原值）。
      let id = arg_of(args, "id")
      let op = arg_of(args, "op")
      let val = arg_of(args, "value")
      let mut cmd = "set-adjust \{id}"
      if op != "" {
        cmd = cmd + " op=\{op}"
      }
      if val != "" {
        cmd = cmd + " value=\{val}"
      }
      cmd
    }
    "crop_canvas" => "crop \{arg_of(args, "x")} \{arg_of(args, "y")} \{arg_of(args, "w")} \{arg_of(args, "h")}"
    "sample_color" => "sample \{arg_of(args, "x")} \{arg_of(args, "y")}"
    "set_style" => {
      let id = arg_of(args, "id")
      let tail = args_to_tail(
        args,
        [
          "fill", "lgrad", "stroke", "stroke_w", "opacity", "blend", "radius",
          "points", "rot", "visible", "name",
        ],
      )
      "set-style \{id} \{tail}"
    }
    "render" => {
      let w = opt_of(args, "w", "640")
      let mut l = "render \{w}"
      match args {
        Json::Object(m) =>
          match m.get("overlay") {
            Some(Json::String("1")) | Some(Json::True) => l = l + " overlay=1"
            _ => ()
          }
        _ => ()
      }
      l
    }
    // MVSL：模型只写 JSON，base64 由 SDK 做（不该让 LLM 手搓 base64）
    "sel_schema" => "sel-schema"
    "census" => {
      let mut l = "census"
      let within = arg_of(args, "within_json")
      if within != "" {
        l = l + " within=" + b64_text(within)
      }
      let n = arg_of(args, "components")
      if n != "" {
        l = l + " components=" + n
      }
      l
    }
    "probe" => {
      // 批量优先：给了 points 就不再看 x/y（引擎侧同此约定）
      let mut l = if arg_of(args, "points") != "" {
        "probe points=" + arg_of(args, "points")
      } else {
        "probe x=" + arg_of(args, "x") + " y=" + arg_of(args, "y")
      }
      let r = arg_of(args, "r")
      if r != "" {
        l = l + " r=" + r
      }
      l
    }
    "select_preview" => {
      let mut l = "select-preview " + b64_text(arg_of(args, "sel_json"))
      let mx = arg_of(args, "max")
      if mx != "" {
        l = l + " max=" + mx
      }
      l
    }
    "mvsl_set" => "mvsl-set " + b64_text(arg_of(args, "program_json"))
    "mvsl_impact" => {
      let mx = arg_of(args, "max")
      if mx == "" {
        "mvsl-impact"
      } else {
        "mvsl-impact max=" + mx
      }
    }
    "mvsl_show" => "mvsl-show"
    "mvsl_clear" => "mvsl-clear"
    "mvsl_assert" => "mvsl-assert"
    _ => {
      // add-*：几何必带 + 样式可选
      let tail = args_to_tail(
        args,
        [
          "id", "x", "y", "w", "h", "fill", "lgrad", "stroke", "stroke_w",
          "radius", "opacity", "blend", "points", "name",
        ],
      )
      "\{cmd} \{tail}"
    }
  }
  out
}

///|
/// 最近一次 save_mpd 的容器 base64（页面下载用；不进模型上下文）。
pub let g_last_mpd_b64 : Ref[String] = Ref("")

///|
fn arg_of(args : Json, key : String) -> String {
  match args {
    Json::Object(m) =>
      match m.get(key) {
        Some(Json::String(s)) => s
        Some(Json::Number(n, ..)) => fmt_arg_num(n)
        Some(Json::True) => "1"
        Some(Json::False) => "0"
        _ => ""
      }
    _ => ""
  }
}

///|
fn opt_of(args : Json, key : String, dflt : String) -> String {
  let v = arg_of(args, key)
  if v == "" {
    dflt
  } else {
    v
  }
}

///|
fn extract_json_string(text : String, key : String) -> String {
  try {
    let j = @json.parse(text)
    match json_field(j, key) {
      Some(Json::String(s)) => s
      _ => ""
    }
  } catch {
    _ => ""
  }
}

///|
fn shorten(s : String, max : Int) -> String {
  if s.length() <= max {
    s
  } else {
    s[0:max].to_owned() + "…"
  }
}

///|
/// 工具数（e2e 断言用；与 paint_tool_defs 同源）。
pub fn tool_count() -> Int {
  paint_tool_defs().length()
}
