/// demo —— Provider 预设与模型微目录（demo/catalog）。
///
/// 呼应 deepOrca 的接入方案：连接配置只有 {baseURL, apiKey, model}
/// （OpenAI wire，`POST {base}/chat/completions` + Bearer）；模型能力数据
/// （context window / 视觉 / tool_call）来自 models.dev 的形态——这里内嵌
/// 一个极小的微目录（数据摘自 models.dev 公开目录的常用条目形态），
/// 供页面下拉与能力判断；完整目录可由宿主注入 models.dev api.json 替换。

///|
pub(all) struct ProviderPreset {
  id : String
  name : String
  base_url : String
}

///|
pub fn provider_presets() -> Array[ProviderPreset] {
  [
    { id: "mock", name: "Mock（离线演示，无需 Key）", base_url: "" },
    { id: "deepseek", name: "DeepSeek", base_url: "https://api.deepseek.com" },
    {
      id: "stepfun",
      name: "StepFun",
      base_url: "https://api.stepfun.com/v1",
    },
    {
      id: "openai",
      name: "OpenAI",
      base_url: "https://api.openai.com/v1",
    },
    {
      id: "custom",
      name: "自定义 OpenAI 兼容端点",
      base_url: "",
    },
  ]
}

///|
pub fn preset_base_url(id : String) -> String {
  for p in provider_presets() {
    if p.id == id {
      return p.base_url
    }
  }
  ""
}

///|
/// 模型微目录条目（models.dev 字段子集）。
pub(all) struct ModelMeta {
  id : String
  /// 上下文窗口（tokens）
  context : Int
  /// 是否具备完整图片视觉（可读取图像输入）
  vision : Bool
  tool_call : Bool
}

///|
/// 微目录：按 provider 给推荐模型（数据形态对齐 models.dev api.json）。
pub fn models_for(provider : String) -> Array[ModelMeta] {
  match provider {
    "deepseek" => [
      { id: "deepseek-chat", context: 128000, vision: false, tool_call: true },
    ]
    "stepfun" => [
      { id: "step-2-16k", context: 16000, vision: false, tool_call: true },
      {
        id: "step-1v-8k",
        context: 8000,
        vision: true,
        tool_call: true,
      },
    ]
    "openai" => [
      { id: "gpt-4o-mini", context: 128000, vision: true, tool_call: true },
    ]
    _ => []
  }
}

///|
/// 修图系统提示词：告知 AI 引擎工具面与操作约定（中文，页面语境）。
pub fn paint_system_prompt() -> String {
  let lines = [
    "你是 MoonPainter 的修图 Agent。用户用自然语言提出修改需求；你通过工具真实操作引擎（每个工具调用都会实时展示给用户），不是一键滤镜。",
    "工作约定：",
    "1. 先 list_layers 或 stats 了解现状，再动手；",
    "2. 修改用 add_rect/add_ellipse/add_line/add_polygon/set_style/move/resize/rotate/flip/delete/reorder；坐标是画布像素（左上原点），颜色用 #RRGGBB 或 #RRGGBBAA；",
    "3. 关键步骤后调 render 生成预览（渲染图会以附件附回给你，请真的看图确认效果后再继续）；",
    "4. 结束前调 lint 检查违规；全部完成后用一段简短中文总结你做了什么。",
    "5. 工具报错（如非法颜色）时读错误信息修正参数重试，不要放弃。",
    "6. 用户要求「把某块改成某色」这类精准改色时，走 MVSL 编辑表，不要叠加调整层：",
    "   a) census 先普查颜色（给 within_json 时只统计该区域）——不要靠猜色号；",
    "   b) select_preview 试选：会附回洋红覆盖图，**看图确认**选中的是你想改的东西；",
    "      用返回的连通域 id（components）描述区域，不要向用户报坐标；",
    "   c) mvsl_set 装编辑表：ops 是有序算子数组，每个算子形如",
    "      {\"id\":\"e1\",\"kind\":\"recolor\",\"sel\":<选择子>,\"amount\":1,\"hue_deg\":120,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}；",
    "      kind 可选 recolor（改色相）/temperature（暖冷）/relight（明暗）；",
    "      选择子形如 {\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":200,\"h\":200,\"feather\":0}}}；",
    "   d) mvsl_impact 看影响证书：**leak_ratio 必须为 0**（否则说明改到了选区外）；",
    "   e) 用户说「别动 XX」时把它写成 guards 里的保护断言，再用 mvsl_assert 验证；",
    "   f) 最后 render 渲染确认。编辑表会随 .mpd 落盘，是渲染的真值输入。",
  ]
  join_lines(lines)
}

///|
fn join_lines(lines : Array[String]) -> String {
  let sb = StringBuilder()
  let mut f = true
  for l in lines {
    if f {
      f = false
    } else {
      sb.write_string("\n")
    }
    sb.write_string(l)
  }
  sb.to_string()
}
