/// demo —— ModelPort 端口：OpenAI wire 协议的修图模型（demo/paint_model）。
///
/// 接入形态对齐 deepOrca：`POST {baseURL}/chat/completions` +
/// `Authorization: Bearer`；tools 为 function 定义；响应取
/// choices[0].message（content + tool_calls）转 posoco Completion，
/// tool 回放（role:"tool"）由 posoco 内核负责。provider=mock 时走
/// 内置脚本模型（逐轮吐工具调用），离线即可完整演示"AI 逐工具修图"。
/// 传输用 moonbitlang/async/http（js 后端 = 浏览器 fetch）。

///|
pub(all) struct LlmConfig {
  provider : String
  base_url : String
  model : String
  api_key : String
}

///|
struct PaintModel {
  cfg : LlmConfig
  /// mock 脚本的轮次游标
  mut mock_step : Int
}

///|
fn PaintModel::PaintModel(cfg : LlmConfig) -> PaintModel {
  { cfg, mock_step: 0 }
}

///|
pub impl @posoco.ModelPort for PaintModel with fn provider_config(
  _self,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
pub impl @posoco.ModelPort for PaintModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "PaintModel 未实现 compact（demo 会话很短，不会触发）",
  )
}

///|
pub impl @posoco.ModelPort for PaintModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  ignore(options)
  if self.cfg.provider == "mock" {
    return self.mock_chat(messages)
  }
  match stream {
    @posoco.StreamMode::Stream(emit) =>
      self.openai_chat_streamed(messages, tools, emit)
    _ => {
      // NoStream：仍走流式端点但不向调用方发增量（结果等价非流式）
      self.openai_chat_streamed(messages, tools, fn(_) { () })
    }
  }
}

// ---------------------------------------------------------------------------
// 真实 provider：OpenAI wire（非流式）
// ---------------------------------------------------------------------------

///|
/// posoco Message → OpenAI wire JSON。
fn message_to_wire(m : @posoco.Message) -> Json {
  let obj : Map[String, Json] = Map([])
  match m {
    @posoco.Message::SystemMessage(content~) => {
      obj["role"] = Json::string("system")
      obj["content"] = Json::string(content_text(content))
    }
    @posoco.Message::UserMessage(content~) => {
      obj["role"] = Json::string("user")
      let has_image = content_has_image(content)
      if has_image {
        let parts : Array[Json] = []
        for c in content {
          match c {
            @posoco.Content::Text(t) =>
              parts.push(
                wire_object(
                  [
                    ("type", Json::string("text")),
                    ("text", Json::string(t)),
                  ],
                ),
              )
            @posoco.Content::Image(media_type~, data~) =>
              parts.push(
                wire_object([
                  ("type", Json::string("image_url")),
                  (
                    "image_url",
                    wire_object([
                      (
                        "url",
                        Json::string("data:\{media_type};base64,\{data}"),
                      ),
                    ]),
                  ),
                ]),
              )
          }
        }
        obj["content"] = Json::array(parts)
      } else {
        obj["content"] = Json::string(content_text(content))
      }
    }
    @posoco.Message::AssistantMessage(content~, tool_calls~, ..) => {
      obj["role"] = Json::string("assistant")
      let text = content_text(content)
      obj["content"] = Json::string(text)
      if tool_calls.length() > 0 {
        let arr : Array[Json] = []
        for tc in tool_calls {
          arr.push(
            wire_object([
              ("id", Json::string(tc.call_id.to_string())),
              ("type", Json::string("function")),
              (
                "function",
                wire_object([
                  ("name", Json::string(tc.name.to_string())),
                  ("arguments", Json::string(tc.arguments.stringify())),
                ]),
              ),
            ]),
          )
        }
        obj["tool_calls"] = Json::array(arr)
      }
    }
    @posoco.Message::ToolMessage(call_id~, outcome~, ..) => {
      obj["role"] = Json::string("tool")
      obj["tool_call_id"] = Json::string(call_id.to_string())
      obj["content"] = Json::string(outcome_text(outcome))
    }
  }
  Json::object(obj)
}

///|
fn wire_object(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  Json::object(m)
}

///|
fn content_text(content : Array[@posoco.Content]) -> String {
  let sb = StringBuilder()
  for c in content {
    match c {
      @posoco.Content::Text(t) => {
        sb.write_string(t)
        sb.write_string("\n")
      }
      @posoco.Content::Image(..) => sb.write_string("[图像]")
    }
  }
  sb.to_string()
}

///|
fn content_has_image(content : Array[@posoco.Content]) -> Bool {
  for c in content {
    match c {
      @posoco.Content::Image(..) => return true
      _ => ()
    }
  }
  false
}

///|
/// ToolOutcome → 工具消息文本（图像附件以占位说明，图像本体走视觉通道）。
fn outcome_text(o : @posoco.ToolOutcome) -> String {
  match o {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::SuccessWithAttachments(content~, ..) =>
      content + "\n[渲染 PNG 已附于本条消息]"
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    @posoco.ToolOutcome::RuntimeFailure(message~, ..) => "运行时失败：\{message}"
    @posoco.ToolOutcome::NotExecuted(reason~, ..) => "未执行：\{reason.to_string()}"
  }
}

///|
fn tool_defs_to_wire(tools : Array[@posoco.ToolDef]) -> Json {
  let arr : Array[Json] = []
  for t in tools {
    arr.push(
      wire_object([
        ("type", Json::string("function")),
        (
          "function",
          wire_object([
            ("name", Json::string(t.name.to_string())),
            ("description", Json::string(t.description)),
            ("parameters", t.input_schema),
          ]),
        ),
      ]),
    )
  }
  Json::array(arr)
}

///|
async fn PaintModel::openai_chat_streamed(
  self : PaintModel,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  emit : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  // 请求体（deepOrca 同款 OpenAI wire；非流式已足够演示工具循环）
  let body_map : Map[String, Json] = Map([])
  body_map["model"] = Json::string(self.cfg.model)
  let msgs : Array[Json] = []
  for m in messages {
    msgs.push(message_to_wire(m))
  }
  body_map["messages"] = Json::array(msgs)
  if tools.length() > 0 {
    body_map["tools"] = tool_defs_to_wire(tools)
    body_map["tool_choice"] = Json::string("auto")
  }
  body_map["stream"] = Json::boolean(true)
  let body = Json::object(body_map).stringify()
  let url = self.cfg.base_url.trim(char_set="/").to_owned() + "/chat/completions"
  let mut content_buf = ""
  // tool_calls 按 index 拼接（deepOrca 模式）
  let tc_ids : Map[Int, String] = Map([])
  let tc_names : Map[Int, String] = Map([])
  let tc_args : Map[Int, StringBuilder] = Map([])
  let on_line = fn(payload : String) {
    match parse_sse_chunk(payload) {
      None => ()
      Some((content, tc_idx, tc_id, tc_name, tc_args_delta)) => {
        if content != "" {
          content_buf = content_buf + content
          emit(@posoco.StreamChunk::TextDelta(token=content))
        }
        if tc_idx >= 0 {
          if tc_id != "" {
            tc_ids[tc_idx] = tc_id
          }
          if tc_name != "" {
            tc_names[tc_idx] = tc_name
          }
          if tc_args_delta != "" {
            match tc_args.get(tc_idx) {
              Some(sb) => sb.write_string(tc_args_delta)
              None => {
                let sb = StringBuilder()
                sb.write_string(tc_args_delta)
                tc_args[tc_idx] = sb
              }
            }
          }
        }
      }
    }
  }
  let status : Int = js_fetch_sse(url, body, self.cfg.api_key, on_line).wait() catch {
    _ => 0
  }
  if status != 200 {
    raise @posoco.ModelError::Transport("HTTP \{status}（流式请求失败）")
  }
  // 拼接完整 tool_calls
  let calls : Array[@posoco.ToolCall] = []
  let mut max_idx = -1
  for k, _ in tc_args {
    if k > max_idx {
      max_idx = k
    }
  }
  let mut idx = 0
  while idx <= max_idx {
    let cid = tc_ids.get(idx).unwrap_or("call_\{idx}")
    let cname = tc_names.get(idx).unwrap_or("")
    let cargs = match tc_args.get(idx) {
      Some(sb) => sb.to_string()
      None => "{}"
    }
    if cname != "" {
      calls.push({
        call_id: @posoco.CallId::unchecked(cid),
        name: @posoco.ToolName::unchecked(cname),
        arguments: @json.parse(cargs) catch { _ => Json::object(Map([])) },
      })
    }
    idx = idx + 1
  }
  let finish = if calls.length() > 0 {
    @posoco.FinishReason::ToolCalls
  } else {
    @posoco.FinishReason::Stop
  }
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text(content_buf)],
    tool_calls=calls,
    reasoning=None,
    finish_reason=finish,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
fn parse_openai_response(
  text : String,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let j = @json.parse(text) catch {
    e => raise @posoco.ModelError::ResponseParse("响应 JSON 解析失败: \{e}")
  }
  // choices[0]
  let choice : Json = match json_field(j, "choices") {
    Some(Json::Array(arr)) =>
      if arr.length() > 0 {
        arr[0]
      } else {
        raise @posoco.ModelError::ResponseParse("choices 为空")
      }
    _ => raise @posoco.ModelError::ResponseParse("响应缺 choices：\{shorten_str(text, 200)}")
  }
  let msg = json_field(choice, "message")
  // content
  let content : Array[@posoco.Content] = match msg {
    Some(m) =>
      match json_field(m, "content") {
        Some(Json::String(s)) => if s != "" { [@posoco.Content::Text(s)] } else { [] }
        _ => []
      }
    None => []
  }
  // tool_calls
  let calls : Array[@posoco.ToolCall] = []
  let wire_calls : Array[Json] = match msg {
    Some(m) =>
      match json_field(m, "tool_calls") {
        Some(Json::Array(arr)) => arr
        _ => []
      }
    None => []
  }
  for tc in wire_calls {
    let id = json_path_str(tc, ["id"])
    let name = json_path_str(tc, ["function", "name"])
    let args_str = json_path_str(tc, ["function", "arguments"])
    if name != "" {
      let args : Json = @json.parse(if args_str == "" { "{}" } else { args_str }) catch {
        _ => Json::object(Map([]))
      }
      calls.push(
        {
          call_id: @posoco.CallId::unchecked(
            if id == "" { "call_\{calls.length()}" } else { id },
          ),
          name: @posoco.ToolName::unchecked(name),
          arguments: args,
        },
      )
    }
  }
  let finish = match json_field(choice, "finish_reason") {
    Some(Json::String("tool_calls")) => @posoco.FinishReason::ToolCalls
    Some(Json::String("length")) => @posoco.FinishReason::Length
    Some(Json::String("stop")) => @posoco.FinishReason::Stop
    Some(Json::String(other)) => @posoco.FinishReason::Other(other)
    _ => if calls.length() > 0 {
      @posoco.FinishReason::ToolCalls
    } else {
      @posoco.FinishReason::Stop
    }
  }
  let completion : @posoco.Completion = @posoco.Completion(
    content=content,
    tool_calls=calls,
    reasoning=None,
    finish_reason=finish,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
/// 从 js_http_post_json_wait 的包装信封里取状态码。
fn extract_json_number(text : String, key : String) -> Int {
  try {
    let j = @json.parse(text)
    match json_field(j, key) {
      Some(Json::Number(n, ..)) => n.to_int()
      _ => 0
    }
  } catch {
    _ => 0
  }
}

///|
/// 剥掉包装信封，取正文原文（body 字段是字符串化 JSON）。
fn strip_status_envelope(text : String) -> String {
  try {
    let j = @json.parse(text)
    match json_field(j, "body") {
      Some(Json::String(s)) => s
      _ => text
    }
  } catch {
    _ => text
  }
}

///|
/// Json 对象取字段（.value() 已弃用，统一走模式匹配）。
fn json_field(j : Json, key : String) -> Json? {
  match j {
    Json::Object(m) => m.get(key)
    _ => None
  }
}

///|
fn json_path_str(j : Json, path : Array[String]) -> String {
  let mut cur = j
  for k in path {
    match json_field(cur, k) {
      Some(next) => cur = next
      None => return ""
    }
  }
  if cur is Json::String(s) {
    s
  } else {
    ""
  }
}

///|
fn shorten_str(s : String, max : Int) -> String {
  if s.length() <= max {
    s
  } else {
    s[0:max].to_owned() + "…"
  }
}

// ---------------------------------------------------------------------------
// Mock 模型：离线脚本（逐轮真实工具调用，演示全过程）
// ---------------------------------------------------------------------------

///|
fn PaintModel::mock_chat(
  self : PaintModel,
  messages : ArrayView[@posoco.Message],
) -> @posoco.ModelCallResult {
  // 取最后一条用户文本做脚本路由
  let mut request = ""
  for m in messages {
    match m {
      @posoco.Message::UserMessage(content~) =>
        request = content_text(content)
      _ => ()
    }
  }
  let step = self.mock_step
  self.mock_step = self.mock_step + 1
  fn call(id : String, name : String, args : String) -> @posoco.ToolCall {
    {
      call_id: @posoco.CallId::unchecked(id),
      name: @posoco.ToolName::unchecked(name),
      arguments: @json.parse(args) catch {
        _ => Json::object(Map([]))
      },
    }
  }

  fn say(text : String) -> @posoco.Completion {
    @posoco.Completion(
      content=[@posoco.Content::Text(text)],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=None,
    )
  }

  fn with_calls(
    text : String,
    calls : Array[@posoco.ToolCall],
  ) -> @posoco.ModelCallResult {
    {
      completion: @posoco.Completion(
        content=[@posoco.Content::Text(text)],
        tool_calls=calls,
        reasoning=None,
        finish_reason=@posoco.FinishReason::ToolCalls,
        usage=None,
      ),
      processed_messages: [],
    }
  }

  let wants_badge = request.contains("徽章") || request.contains("圆")
  let wants_cool = request.contains("冷") || request.contains("蓝")
  let wants_precise = request.contains("精准") || request.contains("编辑表")
  // 脚本：精准改色 = MVSL 闭环 5 轮（先看语法再取数值）；
  // 徽章 = 3 工具轮；换色 = 2 轮；默认 = 2 轮
  if wants_precise {
    // 选择子：整幅画布（demo 场景小，几何谓词足够）
    let sel = "{\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":640,\"h\":480,\"feather\":0}}}"
    let prog = "{\"version\":1,\"ops\":[{\"id\":\"e1\",\"kind\":\"temperature\",\"sel\":" + sel + ",\"amount\":1,\"hue_deg\":0,\"temp_kelvin\":900,\"relight_gain\":1,\"refine\":[],\"note\":\"整体转暖\",\"evidence\":null}],\"guards\":[]}"
    match step {
      0 =>
        return with_calls(
          "先看选择子语法，再取数值——不猜字段名和量纲。",
          [call("p1", "sel_schema", "{}")],
        )
      1 =>
        return with_calls(
          "普查画面颜色，数值只取 sel_ 前缀的字段。",
          [call("p2", "census", "{}")],
        )
      2 =>
        return with_calls(
          "试选一下目标区域，看图确认。",
          [
            call(
              "p3",
              "select_preview",
              "{\"sel_json\":" + json_quote(sel) + ",\"max\":320}",
            ),
          ],
        )
      3 =>
        return with_calls(
          "装编辑表：整体转暖。",
          [call("p4", "mvsl_set", "{\"program_json\":" + json_quote(prog) + "}")],
        )
      4 =>
        return with_calls(
          "看影响证书 + 校验保护断言 + lint 收工检查 + 渲染确认。",
          [
            call("p5", "mvsl_impact", "{\"max\":320}"),
            call("p6", "mvsl_assert", "{}"),
            call("p7", "lint", "{}"),
            call("p8", "render", "{\"w\":480}"),
          ],
        )
      _ => {
        self.mock_step = 0
        return {
          completion: say(
            "精准改色完成：普查 → 试选 → 装编辑表（整体转暖 +900K）→ 影响证书无选区外泄漏 → 断言通过 → 渲染确认。",
          ),
          processed_messages: [],
        }
      }
    }
  }
  if wants_badge {
    match step {
      0 =>
        return with_calls(
          "好的，我来在右上角加一个渐变圆形徽章——先画圆。",
          [
            call(
              "m1",
              "add_ellipse",
              "{\"id\":\"badge\",\"x\":500,\"y\":40,\"w\":110,\"h\":110,\"lgrad\":\"#FF7A45FF,#2E6FE8FF,0,0,1,1\",\"name\":\"badge\"}",
            ),
          ],
        )
      1 =>
        return with_calls(
          "圆形就位，加一圈描边让徽章更立体。",
          [
            call(
              "m2",
              "set_style",
              "{\"id\":\"badge\",\"stroke\":\"#FFFFFFCC\",\"stroke_w\":4}",
            ),
          ],
        )
      2 =>
        return with_calls(
          "渲染看一眼效果。",
          [call("m3", "render", "{\"w\":480}")],
        )
      _ => {
        self.mock_step = 0
        return {
          completion: say(
            "徽章完成：右上角渐变圆形 + 白色描边，已渲染确认。全过程共 3 次工具调用。",
          ),
          processed_messages: [],
        }
      }
    }
  } else if wants_cool {
    match step {
      0 =>
        return with_calls(
          "把主背景换成冷色调，先看当前图层。",
          [call("m1", "list_layers", "{}")],
        )
      1 =>
        return with_calls(
          "背景是第一层，直接改填充色并渲染确认。",
          [
            call("m2", "set_style", "{\"id\":\"l1\",\"fill\":\"#16324FFF\"}"),
            call("m3", "render", "{\"w\":480}"),
          ],
        )
      _ => {
        self.mock_step = 0
        return {
          completion: say("已把主背景切换为深冷蓝（#16324F），渲染确认完成。"),
          processed_messages: [],
        }
      }
    }
  }
  match step {
    0 =>
      return with_calls(
        "我先看一下画布现状。",
        [call("m1", "stats", "{}")],
      )
    1 =>
      return with_calls(
        "加一个点缀色块，然后渲染确认。",
        [
          call(
            "m2",
            "add_rect",
            "{\"x\":40,\"y\":390,\"w\":180,\"h\":50,\"fill\":\"#33CC66FF\",\"radius\":10,\"name\":\"accent\"}",
          ),
          call("m3", "render", "{\"w\":480}"),
        ],
      )
    _ => {
      self.mock_step = 0
      {
        completion: say("完成：查看统计后添加了绿色点缀块并渲染确认。"),
        processed_messages: [],
      }
    }
  }
}

///|
/// 把字符串包成 JSON 字符串字面量（mock 脚本里嵌套 JSON 载荷用）。
fn json_quote(s : String) -> String {
  let sb = StringBuilder()
  sb.write_string("\"")
  for c in s {
    if c == '\"' {
      sb.write_string("\\\"")
    } else if c == '\\' {
      sb.write_string("\\\\")
    } else {
      sb.write_char(c)
    }
  }
  sb.write_string("\"")
  sb.to_string()
}

///|
/// JSON 对象取字段（pub 转发，streaming.mbt 跨文件可见）。
pub fn json_field_pub(j : Json, key : String) -> Json? {
  json_field(j, key)
}

///|
/// JSON 路径取字符串（pub 转发）。
pub fn json_path_str_pub(j : Json, path : Array[String]) -> String {
  json_path_str(j, path)
}
