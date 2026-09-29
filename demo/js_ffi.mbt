/// demo —— JS FFI 桥（demo/js_ffi）。
///
/// 三类绑定：① wasm 引擎实例（经典 wasm 零 import：浏览器 fetch / Node fs
/// 双通道加载，字符串经 in 槽写入 + 指针解码读出）；② 基础 JS 互操作；
/// ③ DOM（页面壳用；headless 路径不触碰）。
/// Promise 桥一律走 moonbitlang/async/js_async（Promise::wait）。

// ---------------------------------------------------------------------------
// JSON 安全解析 + 字段访问（builtin Json API）
// ---------------------------------------------------------------------------

///|
/// JSON 安全解析（失败返回 Null 值——用 Json::null() 工厂）。
pub fn parse_json_safe(text : String) -> Json {
  @json.parse(text) catch { _ => Json::null() }
}

///|
pub fn json_has_ok(j : Json) -> Bool {
  match j.value("ok") {
    Some(v) => v is Json::True
    _ => false
  }
}

///|
pub fn json_get_str(j : Json, key : String) -> String {
  match j.value(key) {
    Some(Json::String(s)) => s
    _ => ""
  }
}

///|
pub fn json_get(j : Json, key : String) -> Json? {
  j.value(key)
}

// ---------------------------------------------------------------------------
// JS 互操作底座
// ---------------------------------------------------------------------------

///|
#external
priv type JsValue

///|
extern "js" fn js_is_node() -> Bool =
  #| () => typeof window === 'undefined'

///|
extern "js" fn js_load_wasm(url : String) -> @js_async.Promise[WasmEngine] =
  #| (url) => (async () => {
  #|   const instantiate = (buf) =>
  #|     new WebAssembly.Instance(new WebAssembly.Module(buf), {}).exports;
  #|   if (typeof window === 'undefined') {
  #|     const fs = await import('node:fs');
  #|     const candidates = [
  #|       url,
  #|       '../_build/wasm/release/build/wasm/wasm.wasm',
  #|       '../../_build/wasm/release/build/wasm/wasm.wasm',
  #|       '_build/wasm/release/build/wasm/wasm.wasm',
  #|       '_build/wasm/debug/build/wasm/wasm.wasm',
  #|       '../../_build/wasm/debug/build/wasm/wasm.wasm',
  #|     ];
  #|     for (const p of candidates) {
  #|       try {
  #|         if (fs.existsSync(p)) return instantiate(fs.readFileSync(p));
  #|       } catch (_) {}
  #|     }
  #|     throw new Error('moonpainter.wasm not found (run moon build --target wasm)');
  #|   } else {
  #|     const resp = await fetch(url);
  #|     if (!resp.ok) throw new Error('wasm fetch failed: ' + resp.status);
  #|     return instantiate(await resp.arrayBuffer());
  #|   }
  #| })()

///|
/// 加载 moonpainter 引擎 wasm 并返回其导出表。
/// Node：fs.readFileSync + 实例化；浏览器：fetch + arrayBuffer。
async fn load_engine_wasm(url : String) -> WasmEngine raise {
  js_load_wasm(url).wait()
}

// ---------------------------------------------------------------------------
// wasm 引擎导出包装（经典 wasm ABI：字符串指针 [len@ptr-4][UTF-16LE@ptr]）
// ---------------------------------------------------------------------------

///|
priv type WasmEngine

///|
let g_engine : Ref[WasmEngine?] = Ref(None)

///|
/// 已加载的引擎实例；未加载时 panic（调用方先 ensure_engine）。
fn engine() -> WasmEngine {
  match g_engine.val {
    Some(e) => e
    None => abort("engine wasm not loaded: call ensure_engine() first")
  }
}

///|
extern "js" fn js_load_wasm_node(url : String) -> WasmEngine =
  #| (url) => {
  #|   const fs = require('fs');
  #|   const path = require('path');
  #|   const candidates = [url,
  #|     path.resolve('_build/wasm/debug/build/wasm/wasm.wasm'),
  #|     path.resolve('../../_build/wasm/debug/build/wasm/wasm.wasm'),
  #|     path.resolve('moonpainter.wasm')];
  #|   for (const p of candidates) {
  #|     try { if (fs.existsSync(p)) { return new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(p)), {}).exports; } } catch (_) {}
  #|   }
  #|   throw new Error('moonpainter.wasm not found');
  #| }

///|
extern "js" fn js_load_wasm_browser(url : String) -> WasmEngine =
  #| (url) => {
  #|   const xhr = new XMLHttpRequest();
  #|   xhr.open('GET', url, false);
  #|   xhr.overrideMimeType('text/plain; charset=x-user-defined');
  #|   xhr.send();
  #|   const text = xhr.responseText;
  #|   const bytes = new Uint8Array(text.length);
  #|   for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
  #|   const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
  #|   return inst.exports;
  #| }

///|
/// 确保 wasm 引擎已加载（同步——浏览器 XHR / Node fs，无 async 运行时依赖）。
pub fn ensure_engine() -> Unit {
  if g_engine.val is Some(_) {
    return
  }
  if js_is_node() {
    g_engine.val = Some(js_load_wasm_node("moonpainter.wasm"))
  } else {
    g_engine.val = Some(js_load_wasm_browser("moonpainter.wasm"))
  }
}

///|
extern "js" fn engine_version_raw(e : WasmEngine) -> Int =
  #| (e) => e.mp_version()

///|
extern "js" fn engine_reset_raw(e : WasmEngine) -> Int =
  #| (e) => e.mp_reset()

///|
extern "js" fn engine_exec_in_raw(e : WasmEngine) -> Int =
  #| (e) => e.mp_exec_in()

///|
extern "js" fn engine_in_reset_raw(e : WasmEngine) -> Unit =
  #| (e) => e.in_reset()

///|
extern "js" fn engine_in_push_raw(e : WasmEngine, chunk : Int, n : Int) -> Unit =
  #| (e, chunk, n) => e.in_push(chunk, n)

///|
extern "js" fn engine_memory_raw(e : WasmEngine) -> JsValue =
  #| (e) => e.memory

///|
extern "js" fn js_data_view_of_memory(mem : JsValue) -> JsValue =
  #| (m) => new DataView(m.buffer)

///|
extern "js" fn js_read_u32(v : JsValue, off : Int) -> Int =
  #| (dv, off) => dv.getUint32(off, true)

///|
extern "js" fn js_read_u16(v : JsValue, off : Int) -> Int =
  #| (dv, off) => dv.getUint16(off, true)

///|
extern "js" fn js_memory_byte_length(mem : JsValue) -> Int =
  #| (m) => m.buffer.byteLength

///|
/// deepDesign engReadStr 同款：引擎返回的字符串指针 → JS 字符串。
/// 布局 [len@ptr-4（低 28 位）][UTF-16LE@ptr+0]，同步读取（调用期间无 GC 移动）。
fn engine_read_str(e : WasmEngine, ptr : Int) -> String {
  let mem = engine_memory_raw(e)
  let dv = js_data_view_of_memory(mem)
  let total = js_memory_byte_length(mem)
  let len = js_read_u32(dv, ptr - 4) & 0x0FFFFFFF
  let limit = (total - ptr) / 2
  let n = if len > limit { limit } else { len }
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    sb.write_char(Int::unsafe_to_char(js_read_u16(dv, ptr + i * 2)))
    i = i + 1
  }
  sb.to_string()
}

///|
fn engine_exec(e : WasmEngine, line : String) -> String {
  engine_in_reset_raw(e)
  let bytes = @utf8.encode(line)
  let mut i = 0
  while i < bytes.length() {
    let n = if bytes.length() - i < 4 { bytes.length() - i } else { 4 }
    let mut le = 0
    let mut j = 0
    while j < n {
      le = le | ((bytes[i + j].to_int() & 0xFF) << (8 * j))
      j = j + 1
    }
    engine_in_push_raw(e, le, n)
    i = i + n
  }
  let ptr = engine_exec_in_raw(e)
  engine_read_str(e, ptr)
}

///|
/// 引擎信息 JSON（加载后调用）。
pub fn engine_version_json() -> String {
  engine_read_str(engine(), engine_version_raw(engine()))
}

///|
/// 重开会话（vision 闸复位）。
pub fn engine_reset() -> String {
  engine_read_str(engine(), engine_reset_raw(engine()))
}

///|
/// 执行一行引擎命令（与 CLI/agent.exec 同一分发器），返回 JSON 信封。
pub fn engine_exec_line(line : String) -> String {
  engine_exec(engine(), line)
}

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------

///|
/// JSON 解析（失败抛精确错误——调用方按需降级）。
pub fn parse_json(text : String) -> Json raise {
  @json.parse(text)
}

///|
///|
/// POST JSON（OpenAI 兼容端点）。返回包装信封 JSON：
/// {"http_status":200,"body":"<响应原文>"}——状态与正文一起带回 MoonBit 侧。
extern "js" fn js_http_post_json(
  url : String,
  body : String,
  api_key : String,
) -> @js_async.Promise[JsValue] =
  #| (url, body, apiKey) => (async () => {
  #|   try {
  #|     const resp = await fetch(url, {
  #|       method: 'POST',
  #|       headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + apiKey },
  #|       body,
  #|     });
  #|     const text = await resp.text();
  #|     return { http_status: resp.status, body: text };
  #|   } catch (err) {
  #|     return { http_status: 0, body: 'transport error: ' + String(err) };
  #|   }
  #| })()

///|
async fn js_http_post_json_wait(
  url : String,
  body : String,
  api_key : String,
) -> String raise {
  let v = js_http_post_json(url, body, api_key).wait()
  let status = js_value_get(v, "http_status")
  let body_text = js_value_get(v, "body")
  "{\"http_status\":\{js_number_to_int(status)},\"body\":\{js_json_stringify(body_text)}"
}

///|
extern "js" fn js_value_get(v : JsValue, key : String) -> JsValue =
  #| (v, k) => v[k]

///|
extern "js" fn js_number_to_int(v : JsValue) -> Int =
  #| (v) => Number(v) | 0

///|
extern "js" fn js_json_stringify(v : JsValue) -> String =
  #| (v) => JSON.stringify(v)

///|
extern "js" fn js_now_ms() -> Int =
  #| () => Date.now()

///|
pub fn now_ms() -> Int {
  js_now_ms()
}
