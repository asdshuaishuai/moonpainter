/// demo —— LLM SSE 流式传输（demo/streaming）。
///
/// deepOrca 接入模式的流式版：fetch + ReadableStream 逐行读 SSE `data:` 载荷，
/// 每行回调给 MoonBit 增量解析（ContentDelta / ToolCallDelta），
/// 实现上屏实时打字 + tool_calls 按 index 拼接。

///|
/// 流式 fetch：POST JSON，逐 SSE 行回调 on_data（每行去掉 "data: " 前缀后的
/// 原始 JSON 字符串）。返回 HTTP 状态码。
extern "js" fn js_fetch_sse(
  url : String,
  body : String,
  api_key : String,
  on_data : (String) -> Unit,
) -> @js_async.Promise[Int] =
  #| (url, body, apiKey, onData) => (async () => {
  #|   try {
  #|     const resp = await fetch(url, {
  #|       method: 'POST',
  #|       headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + apiKey },
  #|       body,
  #|     });
  #|     const reader = resp.body.getReader();
  #|     const dec = new TextDecoder();
  #|     let buf = '';
  #|     while (true) {
  #|       const { done, value } = await reader.read();
  #|       if (done) break;
  #|       buf += dec.decode(value, { stream: true });
  #|       const lines = buf.split('\n');
  #|       buf = lines.pop();
  #|       for (const line of lines) {
  #|         const t = line.trim();
  #|         if (t.startsWith('data: ')) onData(t.slice(6));
  #|       }
  #|     }
  #|     if (buf.trim().startsWith('data: ')) onData(buf.trim().slice(6));
  #|     return resp.status;
  #|   } catch (_) { return 0; }
  #| })()

///|
/// OpenAI 流式 chunk：choices[0].delta { content?, tool_calls?[{index,id,function:{name,arguments}}] }。
/// 解析单个 SSE data 载荷 → (content_delta, tc_index, tc_id, tc_name, tc_args_delta)。
/// 不含有效增量时返回 None。
fn parse_sse_chunk(
  payload : String,
) -> (String, Int, String, String, String)? {
  let j = parse_json(payload) catch {
    _ => return None
  }
  // choices[0]
  let choice = match json_field(j, "choices") {
    Some(Json::Array(arr)) => if arr.length() > 0 { arr[0] } else { return None }
    _ => return None
  }
  let delta = match json_field(choice, "delta") {
    Some(d) => d
    None => return None
  }
  let content = match json_field(delta, "content") {
    Some(Json::String(s)) => s
    _ => ""
  }
  // 第一个 tool_call 增量（多工具并行时 index > 0 的极少见，逐个处理）
  let mut tc_idx = -1
  let mut tc_id = ""
  let mut tc_name = ""
  let mut tc_args = ""
  match json_field(delta, "tool_calls") {
    Some(Json::Array(arr)) =>
      if arr.length() > 0 {
        let tc = arr[0]
        tc_idx = match json_field(tc, "index") {
          Some(Json::Number(n, ..)) => n.to_int()
          _ => 0
        }
        tc_id = json_path_str(tc, ["id"])
        tc_name = json_path_str(tc, ["function", "name"])
        tc_args = json_path_str(tc, ["function", "arguments"])
      }
    _ => ()
  }
  if content == "" && tc_idx < 0 {
    return None
  }
  Some((content, tc_idx, tc_id, tc_name, tc_args))
}
