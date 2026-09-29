/// wasm —— MoonPainter 的 wasm SDK 边界（wasm/main）。
///
/// 对齐 moonviz/wasm 家族契约（deepDesign/ddpView 已验证的胶水模式）：
/// - 纯 WASM MVP、零 import：任何规范运行时（浏览器/Node/wasmtime）可实例化；
/// - **写路径**：`in_reset()` → `in_push(chunk, n)`（UTF-8 分块，每块 ≤4 字节
///   小端压入 u32 + 有效长度）→ `mp_exec_in()` 用槽内命令行驱动会话；
/// - **读路径**：导出函数返回引擎分配的字符串指针，布局
///   `[len@ptr-4（低 28 位）][UTF-16LE@ptr+0]`，宿主同步读取（deepDesign
///   engReadStr 同款）；
/// - **会话**：实例内单全局会话——`mp_reset()` 重开（vision 闸复位），
///   `mp_exec_in()` 执行一行命令返回 JSON 信封（与 CLI/agent.exec 同一分发器，
///   变更信封必带 canonical 指纹）。AI 修图 demo 的全部引擎交互都走这里。

///|
/// 默认会话（legacy 面mp_reset/mp_exec_in 打在这里，demo/dist 兼容）。
let g_session : Ref[@agent.Session] = Ref(@agent.Session::new())

///|
/// 句柄会话表（审计 F1：多会话多路复用——宿主可同时开多文档）。
let g_sessions : Ref[Map[Int, @agent.Session]] = Ref(Map([]))

///|
let g_next_handle : Ref[Int] = Ref(1)

///|
/// 引擎信息（无参数直调）。
pub fn mp_version() -> String {
  "{\"ok\":true,\"engine\":\"moonpainter\",\"version\":\"\{@core.ENGINE_VERSION}\",\"container\":\"\{@core.MPD_FORMAT_ID}/v\{@core.MPD_VERSION}\",\"vision_required\":true}"
}

///|
/// 开一个新句柄会话（审计 F1）。返回句柄（≥1）。
pub fn mp_open() -> Int {
  let h = g_next_handle.val
  g_next_handle.val = h + 1
  g_sessions.val[h] = @agent.Session::new()
  h
}

///|
/// 关闭句柄会话。1 = 已关，0 = 句柄不存在。
pub fn mp_close(handle : Int) -> Int {
  if g_sessions.val.get(handle) is Some(_) {
    let _ = g_sessions.val.remove(handle)
    1
  } else {
    0
  }
}

///|
fn unknown_handle_envelope(handle : Int) -> String {
  "{\"error\":\"未知会话句柄 \{handle}\"}"
}

///|
/// 在句柄会话上执行槽内命令行（与 mp_exec_in 同一分发器）。
pub fn mp_exec_h(handle : Int) -> String {
  match g_sessions.val.get(handle) {
    Some(s) => @agent.exec(s, slot_string(g_in_bytes))
    None => unknown_handle_envelope(handle)
  }
}

///|
/// 重开会话：全部状态复位（文档/资产/undo/编辑历史/vision 闸）。
pub fn mp_reset() -> String {
  g_session.val = @agent.Session::new()
  "{\"ok\":true,\"op\":\"mp-reset\",\"version\":\"\{@core.ENGINE_VERSION}\"}"
}

// ---------------------------------------------------------------------------
// 写路径：分块字符串槽（classic wasm 双向调用，moonviz/wasm 同款协议）
//
// classic wasm 无法导出 GC 内部的字符串分配原语，宿主没有写引擎堆的通道。
// 协议：in_reset() → in_push(chunk, n)（小端 4 字节小块，n=有效字节 1-4）
// → mp_exec_in() 用槽内命令行调用会话分发器。UTF-8 解码失败时槽内字符串
// 为空（宿主应保证 in_len 与预期一致）。
// ---------------------------------------------------------------------------

let g_in_bytes : Ref[Array[Byte]] = Ref([])

///|
fn slot_push(slot : Ref[Array[Byte]], chunk : Int, n : Int) -> Unit {
  let count = if n < 1 {
    1
  } else if n > 4 {
    4
  } else {
    n
  }
  let mut i = 0
  while i < count {
    let b = ((chunk >> (i * 8)) & 0xFF).to_byte()
    slot.val.push(b)
    i = i + 1
  }
}

///|
fn slot_string(slot : Ref[Array[Byte]]) -> String {
  @utf8.decode(Bytes::from_iter(slot.val.iter())) catch {
    _ => ""
  }
}

///|
/// 输入槽：重置。
pub fn in_reset() -> Unit {
  g_in_bytes.val = []
}

///|
/// 输入槽：压入一小块（chunk 小端 4 字节，n 为有效字节数 1-4）。
pub fn in_push(chunk : Int, n : Int) -> Unit {
  slot_push(g_in_bytes, chunk, n)
}

///|
/// 输入槽当前字节数。
pub fn in_len() -> Int {
  g_in_bytes.val.length()
}

///|
/// 执行槽内一行命令（等价 agent.exec），返回 JSON 信封。
pub fn mp_exec_in() -> String {
  @agent.exec(g_session.val, slot_string(g_in_bytes))
}
