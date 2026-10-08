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
/// 取布尔字段（缺字段/类型不对一律回 false；面板只做显示，不做判据）。
/// ⚠️ **别拿 `json_get_str` 读布尔**：JSON 的 `true` 不是字符串，`json_get_str`
/// 会回 ""（实测 `text_style.wrap` 就是这么被读成 false 的——面板显示"不折行"
/// 而引擎报的是 true，正是"前端报假话"那一类）。
pub fn json_get_bool(j : Json, key : String) -> Bool {
  match j.value(key) {
    Some(Json::True) => true
    _ => false
  }
}

///|
pub fn json_get(j : Json, key : String) -> Json? {
  j.value(key)
}

///|
/// 取数值字段（缺字段/类型不对一律回 0；面板只做显示，不做判据）。
/// ⚠️ 判据里**不许**用它——"缺字段"和"真的是 0"必须分得开（铁律 11 的
/// 子串匹配那课同源：判据要能区分"没有"与"是 0"）。
pub fn json_get_num(j : Json, key : String) -> Int {
  match j.value(key) {
    Some(Json::Number(d)) => d.to_int()
    _ => 0
  }
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
///|
/// 加载引擎 wasm。**字节缓存在 `globalThis.__mpWasmBytes`**：功能自检要另开一份
/// 引擎实例（在用户手上那份文档上折腾自检比不自检还坏），缓存之后第二次实例化
/// 只是 `new WebAssembly.Instance`，不重新下载 1.1 MB。
extern "js" fn js_load_wasm_node(url : String) -> WasmEngine =
  #| (url) => {
  #|   const fs = require('fs');
  #|   const path = require('path');
  #|   // ⚠️ 顺序要紧：**先 release 再 debug**。`./build_demo.sh` 用
  #|   // `moon build --target wasm`（release 目录），而这里此前只找 debug ——
  #|   // Node 侧自检加载的可能是**上一次 debug 构建**的产物。浏览器侧没这个问题
  #|   // （它拉的就是 dist/ 里刚拷的那份），所以坑只在 Node 路径上现形。
  #|   const candidates = [url,
  #|     path.resolve('_build/wasm/release/build/wasm/wasm.wasm'),
  #|     path.resolve('../../_build/wasm/release/build/wasm/wasm.wasm'),
  #|     path.resolve('moonpainter.wasm'),
  #|     path.resolve('_build/wasm/debug/build/wasm/wasm.wasm'),
  #|     path.resolve('../../_build/wasm/debug/build/wasm/wasm.wasm')];
  #|   for (const p of candidates) {
  #|     try {
  #|       if (fs.existsSync(p)) {
  #|         const bytes = fs.readFileSync(p);
  #|         globalThis.__mpWasmBytes = bytes;
  #|         return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  #|       }
  #|     } catch (_) {}
  #|   }
  #|   throw new Error('moonpainter.wasm not found');
  #| }

///|
/// 浏览器加载。⚠️ 查询串 `?v=<构建时间戳>` 是**必须**的：wasm 用同步 XHR 拉，
/// 浏览器会拿缓存里的旧副本——人对着旧引擎点半天、报出来的现象指向别的地方
/// （`./serve_demo.sh` 另外发 `Cache-Control: no-store`，两头都堵）。
extern "js" fn js_load_wasm_browser(url : String) -> WasmEngine =
  #| (url) => {
  #|   const xhr = new XMLHttpRequest();
  #|   xhr.open('GET', url + '?v=' + Date.now(), false);
  #|   xhr.overrideMimeType('text/plain; charset=x-user-defined');
  #|   xhr.send();
  #|   const text = xhr.responseText;
  #|   const bytes = new Uint8Array(text.length);
  #|   for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
  #|   globalThis.__mpWasmBytes = bytes;
  #|   const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
  #|   return inst.exports;
  #| }

///|
/// **再实例化一份引擎**（同一份 wasm 字节、独立状态）。功能自检第一句就是
/// `new`/`session-open`、还要装编辑表——那些都作用于会话状态，在用户正在编辑的
/// 那份文档上做，自检的副作用比不做自检更坏。没加载过引擎时抛错（自检按钮只在
/// 引擎就绪后才可能被点到）。
extern "js" fn js_clone_engine() -> WasmEngine =
  #| () => {
  #|   const bytes = globalThis.__mpWasmBytes;
  #|   if (!bytes) return globalThis.__mpEngine;   // 退路：至少给一份能用的引擎
  #|   return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
  #| }

///|
/// 克隆出来的还是不是原来那一份？**必须能问**：重放证明 `mvsl-set` 这类命令
/// 在克隆实例上改不到它的会话（`g_session` 是**实例级**全局，`mp_reset` 才换），
/// 所以"克隆"退化成"同一份引擎"时，自检会**在真实文档上跑**——那比不自检更坏。
/// 判据放在这里一处：`js_clone_engine` 的退路 + 这条相等性检查，缺一不可。
extern "js" fn js_same_engine(a : WasmEngine) -> Bool =
  #| (a) => a === globalThis.__mpEngine

///|
/// 构建元数据（`build_demo.sh` 写进 index.html 的 `window.__MP_BUILD__`）。
/// 缺了回 `"{}"`：页面徽标要能说"这页不是 build_demo.sh 产出的"，而不是静默
/// 显示一个假的版本号。
extern "js" fn js_remember_engine(e : WasmEngine) -> Unit =
  #| (e) => { globalThis.__mpEngine = e }

///|
/// 引擎 wasm 的字节缓存拿到了没有（页面上的"自检"第一个前置条件；也是
/// `js_clone_engine` 能不能给出**另一份**实例的前提）。诊断面读它。
extern "js" fn js_wasm_bytes_len() -> Int =
  #| () => (globalThis.__mpWasmBytes ? globalThis.__mpWasmBytes.length : -1)

///|
/// 构建元数据（`build_demo.sh` 写进 index.html 的 `window.__MP_BUILD__`）。
/// 缺了回 `"{}"`：页面徽标要能说"这页不是 build_demo.sh 产出的"，而不是静默
/// 显示一个假的版本号。
extern "js" fn js_build_info() -> String =
  #| () => JSON.stringify(globalThis.__MP_BUILD__ || {})

///|
/// 确保 wasm 引擎已加载（同步——浏览器 XHR / Node fs，无 async 运行时依赖）。
pub fn ensure_engine() -> Unit {
  if g_engine.val is Some(_) {
    return
  }
  // `globalThis.__mpEngine` = "当前这份引擎"：自检的克隆退路与相等性判据都读它。
  let e = if js_is_node() {
    js_load_wasm_node("moonpainter.wasm")
  } else {
    js_load_wasm_browser("moonpainter.wasm")
  }
  // ⚠️ 这里是**唯一**加载点，缓存的写入也在两条加载器里各一处（Node 走
  // `js_load_wasm_node`、浏览器走 `js_load_wasm_browser`）。实测踩过：仓里还
  // 躺着一份**没人调用**的 async 加载器（`js_load_wasm`），我把缓存写在它那里，
  // 于是 `globalThis.__mpWasmBytes` 恒为 null、克隆静默退回同一份引擎，
  // 自检就跑到用户文档上去了。**同一件事两个实现，烂的一定是没人读的那一处。**
  js_remember_engine(e)
  g_engine.val = Some(e)
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
