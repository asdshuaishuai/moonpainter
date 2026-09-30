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
        ("lgrad", "string:线性渐变 c0,c1,x0,y0,x1,y1（0..1 局部端点）"),
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
        ("lgrad", "string:线性渐变 c0,c1,x0,y0,x1,y1"),
        ("stroke", "string:描边色"),
        ("stroke_w", "number:描边宽"),
        ("opacity", "number:透明度 0..1"),
        ("blend", "string:混合模式"),
        ("radius", "number:圆角"),
        ("rot", "number:旋转角度（顺时针度）"),
        ("visible", "string:true/false"),
        ("name", "string:新名称"),
      ],
    ),
    make_tool("move", "移动图层", [("id", "string:req:图层 id"), ("x", "number:req:新 x"), ("y", "number:req:新 y")]),
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
    make_tool("tag", "给图层打语义标签（如 hero/background/logo）", [("id", "string:req:图层 id"), ("tag", "string:req:标签")]),
    make_tool("undo", "撤销上一次修改（工具出错后自我纠正用）", []),
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
      "census",
      "颜色普查：全图 hue×sat 桶（12×3）+ OKLab L 与 HSV V 均值。给 within_json 时只统计该选择子的区域，并附覆盖率/bbox/连通域事实。**先普查再选色**，不要靠猜。",
      [
        ("within_json", "string:选择子 JSON（留空 = 全图）"),
        ("components", "integer:最多回几条连通域事实（默认 16）"),
      ],
    ),
    make_tool(
      "probe",
      "单点探针：邻域 OKLab 均值/方差、环平均色相、边缘置信度，外加当前编辑表每个算子/断言在该点的 membership 与所属连通域 id。用于确认「我指的这个点，选择子到底选中没有」。",
      [
        ("x", "integer:req:画布 x"),
        ("y", "integer:req:画布 y"),
        ("r", "integer:邻域半径 px（默认 2 → 5×5）"),
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
      "安装编辑表（覆盖当前编辑表）：有序算子程序 + 保护断言。装完必须 mvsl_impact 看差异、mvsl_assert 验约束。",
      [("program_json", "string:req:编辑表 JSON（{\"version\":1,\"ops\":[…],\"guards\":[…]}）")],
    ),
    make_tool("mvsl_show", "查看当前编辑表（canonical JSON + 指纹）", []),
    make_tool("mvsl_clear", "清空编辑表（渲染回到未编辑状态）", []),
    make_tool(
      "mvsl_impact",
      "编辑表影响证书：逐算子改动像素数/平均与最大 ΔE/目标区 ΔE/选区外泄漏率，并附结果图。**泄漏率是软边界是否越界的第一号指标**：>0 说明改到了不该改的地方。",
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
  // 引擎命令行：工具名 → 命令名 + 参数
  let cmd = match name {
    "new_canvas" => "new"
    "add_rect" => "add-rect"
    "add_ellipse" => "add-ellipse"
    "add_line" => "add-line"
    "add_polygon" => "add-polygon"
    "set_style" => "set-style"
    "move" => "move"
    "resize" => "resize"
    "rotate" => "rotate"
    "flip" => "flip"
    "delete" => "delete"
    "reorder" => "reorder"
    "render" => "render"
    "pick" => "pick"
    "list_layers" => "list-layers"
    "query_layer" => "query-layer"
    "stats" => "stats"
    "lint" => "lint"
    "save_mpd" => "save-mpd-b64"
    // MVSL 编辑表（B5）
    "census" => "census"
    "probe" => "probe"
    "select_preview" => "select-preview"
    "mvsl_set" => "mvsl-set"
    "mvsl_show" => "mvsl-show"
    "mvsl_clear" => "mvsl-clear"
    "mvsl_impact" => "mvsl-impact"
    "mvsl_assert" => "mvsl-assert"
    _ => return @posoco.ToolOutcome::ToolReportedError(content="未知工具 \{name}", structured=None)
  }
  let line = match name {
    "list_layers" => "list-layers"
    "stats" => "stats"
    "lint" => "lint"
    "save_mpd" => "save-mpd-b64"
    "move" => {
      let id = arg(call, "id")
      "move \{id} \{arg(call, "x")} \{arg(call, "y")}"
    }
    "resize" => {
      let id = arg(call, "id")
      "resize \{id} \{arg(call, "w")} \{arg(call, "h")}"
    }
    "rotate" => {
      let id = arg(call, "id")
      "rotate \{id} \{arg(call, "deg")}"
    }
    "flip" => {
      let id = arg(call, "id")
      "flip \{id} \{arg(call, "how")}"
    }
    "delete" => {
      let id = arg(call, "id")
      "delete \{id}"
    }
    "reorder" => {
      let id = arg(call, "id")
      "reorder \{id} \{arg(call, "how")}"
    }
    "query_layer" => {
      let id = arg(call, "id")
      "query-layer \{id}"
    }
    "pick" => "pick \{arg(call, "x")} \{arg(call, "y")}"
    "group" => {
      let ids = arg(call, "ids")
      "group \{arg(call, "gid")} \{ids.replace(old=",", new=" ")}"
    }
    "ungroup" => {
      let gid = arg(call, "gid")
      "ungroup \{gid}"
    }
    "tag" => "tag \{arg(call, "id")} \{arg(call, "tag")}"
    "undo" => "undo"
    "new_canvas" => "new \{arg(call, "w")} \{arg(call, "h")}"
    "add_paint_layer" => {
      let tail = args_to_tail(call.arguments, ["name"])
      "add-paint \{tail}"
    }
    "paint_stroke" => {
      let lid = arg(call, "layer")
      let pts = arg(call, "pts")
      let r = opt(call, "r", "6")
      let color = opt(call, "color", "#222222FF")
      "brush layer=\{lid} pts=\{pts} r=\{r} color=\{color}"
    }
    "erase_stroke" => {
      let lid = arg(call, "layer")
      let pts = arg(call, "pts")
      let r = opt(call, "r", "10")
      "erase layer=\{lid} pts=\{pts} r=\{r}"
    }
    "apply_filter" =>
      "add-adjust op=\{arg(call, "op")} value=\{opt(call, "value", "0.5")}"
    "crop_canvas" => "crop \{arg(call, "x")} \{arg(call, "y")} \{arg(call, "w")} \{arg(call, "h")}"
    "sample_color" => "sample \{arg(call, "x")} \{arg(call, "y")}"
    "set_style" => {
      let id = arg(call, "id")
      let tail = args_to_tail(
        call.arguments,
        [
          "fill", "lgrad", "stroke", "stroke_w", "opacity", "blend", "radius",
          "rot", "visible", "name",
        ],
      )
      "set-style \{id} \{tail}"
    }
    "render" => {
      let w = opt(call, "w", "640")
      let mut l = "render \{w}"
      match call.arguments {
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
    "census" => {
      let mut l = "census"
      let within = arg(call, "within_json")
      if within != "" {
        l = l + " within=" + b64_text(within)
      }
      let n = arg(call, "components")
      if n != "" {
        l = l + " components=" + n
      }
      l
    }
    "probe" => {
      let mut l = "probe x=" + arg(call, "x") + " y=" + arg(call, "y")
      let r = arg(call, "r")
      if r != "" {
        l = l + " r=" + r
      }
      l
    }
    "select_preview" => {
      let mut l = "select-preview " + b64_text(arg(call, "sel_json"))
      let mx = arg(call, "max")
      if mx != "" {
        l = l + " max=" + mx
      }
      l
    }
    "mvsl_set" => "mvsl-set " + b64_text(arg(call, "program_json"))
    "mvsl_impact" => {
      let mx = arg(call, "max")
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
        call.arguments,
        [
          "id", "x", "y", "w", "h", "fill", "lgrad", "stroke", "stroke_w",
          "radius", "opacity", "blend", "points", "name",
        ],
      )
      "\{cmd} \{tail}"
    }
  }
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
/// 最近一次 save_mpd 的容器 base64（页面下载用；不进模型上下文）。
pub let g_last_mpd_b64 : Ref[String] = Ref("")

///|
fn arg(call : @posoco.ToolCall, key : String) -> String {
  match call.arguments {
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
fn opt(call : @posoco.ToolCall, key : String, dflt : String) -> String {
  let v = arg(call, key)
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
