/// demo —— Observer 端口：把 agent 循环的每个事件转成人类可读的实时日志
/// （demo/paint_observer）。"全程可见"的落点：模型思考、每次工具调用、
/// 每个引擎回包、每次渲染预览都从这里流给宿主（浏览器上屏 / headless 收集）。

///|
struct PaintObserver {
  /// 文本日志行
  log : (String) -> Unit
  /// 渲染预览（png base64；页面更新画布，headless 计数）
  on_image : (String) -> Unit
}

///|
fn PaintObserver::PaintObserver(
  log~ : (String) -> Unit,
  on_image~ : (String) -> Unit,
) -> PaintObserver {
  { log, on_image }
}

///|
fn brief_args(args : Json) -> String {
  match args {
    Json::Object(m) => {
      let parts : Array[String] = []
      for k, v in m {
        match v {
          Json::String(s) => parts.push("\{k}=\{shorten(s, 40)}")
          Json::Number(n, ..) => parts.push("\{k}=\{fmt_arg_num(n)}")
          Json::True => parts.push("\{k}=true")
          Json::False => parts.push("\{k}=false")
          _ => ()
        }
      }
      shorten(join_parts(parts, " "), 160)
    }
    _ => ""
  }
}

///|
/// 简易 join（避免依赖差异）。
fn join_parts(parts : Array[String], sep : String) -> String {
  let sb = StringBuilder()
  let mut f = true
  for p in parts {
    if f {
      f = false
    } else {
      sb.write_string(sep)
    }
    sb.write_string(p)
  }
  sb.to_string()
}

///|
pub impl @posoco.Observer for PaintObserver with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => (self.log)("▶ 修图回合开始")
    @posoco.TurnEvent::ModelResponseReceived(message~, ..) => {
      // AI 的"思考"：文本摘要 + 拟调用的工具清单
      match message {
        @posoco.Message::AssistantMessage(content~, tool_calls~, ..) => {
          let mut said = ""
          for c in content {
            match c {
              @posoco.Content::Text(t) => said = said + t
              _ => ()
            }
          }
          if said != "" {
            (self.log)("🤔 AI：\{shorten(said, 200)}")
          }
          if tool_calls.length() > 0 {
            let names : Array[String] = []
            for tc in tool_calls {
              names.push(tc.name.to_string())
            }
            (self.log)("🛠 拟调用工具：\{join_parts(names, ", ")}")
          }
        }
        _ => ()
      }
    }
    @posoco.TurnEvent::ToolCallStarted(call~) =>
      (self.log)("🔧 执行 \{call.name.to_string()}(\{brief_args(call.arguments)})")
    @posoco.TurnEvent::ToolCallSucceeded(call~, content~, attachments~, ..) => {
      (self.log)("✅ \{call.name.to_string()} → \{shorten(content, 220)}")
      // 渲染附件 → 页面画布更新 / headless 计数
      for a in attachments {
        match a {
          @posoco.Content::Image(media_type~, data~) => {
            if media_type == "image/png" {
              let approx = data.length() / 4 * 3
              (self.log)("🖼 渲染预览已更新（约 \{approx} 字节 PNG）")
              (self.on_image)(data)
            }
          }
          _ => ()
        }
      }
    }
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let f = failure.to_string()
      (self.log)("❌ \{call.name.to_string()} 失败：\{f}")
    }
    @posoco.TurnEvent::TurnCompleted => (self.log)("■ 修图回合完成")
    @posoco.TurnEvent::TurnFailed(reason) => (self.log)("■ 回合失败：\{reason}")
    _ => ()
  }
}
