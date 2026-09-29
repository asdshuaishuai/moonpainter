/// demo —— 会话装配（demo/session）：posoco Agent + 三个端口扩展。
/// run_edit_turn 是 demo 的主入口：人类需求 → AI 逐工具修图 → 全程事件流出。

///|
struct PaintExtension {
  model : PaintModel
  tools : PaintTools
  observer : PaintObserver
  sessions : Map[String, @posoco.Session]
}

///|
fn PaintExtension::PaintExtension(
  cfg : LlmConfig,
  log~ : (String) -> Unit,
  on_image~ : (String) -> Unit,
) -> PaintExtension {
  {
    model: PaintModel::PaintModel(cfg),
    tools: PaintTools::PaintTools(),
    observer: PaintObserver::PaintObserver(log~, on_image~),
    sessions: Map([]),
  }
}

///|
pub impl @posoco.Extension for PaintExtension with fn extension_id(
  _self,
) -> String {
  "moonpainter-demo"
}

///|
pub impl @posoco.Extension for PaintExtension with fn manifest(
  self : PaintExtension,
) -> @posoco.ExtensionManifest {
  let m = @posoco.ExtensionManifest::default(id="moonpainter-demo")
  { ..m, models: [self.model], tools: [self.tools], observers: [self.observer] }
}

///|
pub impl @posoco.SessionStore for PaintExtension with fn load(
  self : PaintExtension,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(s) => { messages: s.messages.copy(), metadata: s.metadata.copy() }
    None => { messages: [], metadata: Map([]) }
  }
}

///|
pub impl @posoco.SessionStore for PaintExtension with fn save(
  self : PaintExtension,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = {
    messages: session.messages.copy(),
    metadata: session.metadata.copy(),
  }
}

///|
/// 初始示例画布（首次运行时载入引擎）。
fn bootstrap_canvas_lines() -> Array[String] {
  [
    "session-open full_image",
    "new 640 480 uuid=ai-paint-demo",
    "add-rect x=0 y=0 w=640 h=480 fill=#F4F1EAFF name=canvas-bg tag=background",
    "add-rect x=60 y=120 w=280 h=180 fill=#1B2A41FF radius=12 name=hero-card",
    "add-ellipse x=390 y=140 w=170 h=170 fill=#FF7A45FF blend=screen name=warm-orb",
    "add-line x=60 y=360 w=520 h=2 points=0,1;520,1 stroke=#8A8A8AFF stroke_w=2 name=baseline",
  ]
}

///|
let g_bootstrapped : Ref[Bool] = Ref(false)

///|
/// 修图回合：人类需求 → AI 工具循环（全程事件经 log/on_image 流出）。
/// 返回 AI 的最终中文总结。
pub async fn run_edit_turn(
  request : String,
  cfg : LlmConfig,
  log~ : (String) -> Unit,
  on_image~ : (String) -> Unit,
) -> String raise {
  ensure_engine()
  if !(g_bootstrapped.val) {
    (log)("初始化引擎（wasm SDK 实例）…")
    let _ = engine_reset()
    for line in bootstrap_canvas_lines() {
      let _ = engine_exec_line(line)
    }
    g_bootstrapped.val = true
    (log)("示例画布就绪：640×480，含背景/主卡/暖色球/基线四层")
  }
  (log)("引擎版本：\{shorten_str(engine_version_json(), 120)}")
  let extension = PaintExtension::PaintExtension(cfg, log~, on_image~)
  let agent = @posoco.Agent(
    exts=[extension],
    config=@posoco.agent_config(
      max_tool_rounds=Some(12),
      temperature=None,
      max_output_tokens=None,
      model_context_window=None,
      compact_threshold=None,
      system_prompt=Some(paint_system_prompt()),
      memory_inbound_timeout_ms=None,
    ),
  )
  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(request),
  ])
  let result = agent.run_turn(input, "paint-demo")
  agent.shutdown()
  let mut summary = ""
  match result.message {
    @posoco.Message::AssistantMessage(content~, ..) =>
      for c in content {
        match c {
          @posoco.Content::Text(t) => summary = summary + t
          _ => ()
        }
      }
    _ => ()
  }
  if summary == "" {
    summary = "（AI 未给出文字总结；查看上方工具日志了解已执行的修改）"
  }
  summary
}
