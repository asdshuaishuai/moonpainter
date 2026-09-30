/// MoonPainter wasm SDK —— JS 宿主胶水（宿主侧适配器；引擎本体 100% MoonBit）。
///
/// 用法：
/// ```js
/// import { loadEngine } from 'moonpainter-sdk';
/// const mp = await loadEngine('moonpainter.wasm');
/// await mp.open();                     // vision 闸开门
/// mp.exec('new 640 480 uuid=demo');    // 一行命令 → JSON 信封对象
/// const r = mp.exec('render 480');     // r.png_b64 / r.fingerprint
/// ```
///
/// ABI（与引擎 wasm/main.mbt 契约一致）：
/// - 写：in_reset() → in_push(u32 小端 4 字节块, n) → mp_exec_in()
/// - 读：返回值为引擎分配字符串指针 [len@ptr-4 低 28 位][UTF-16LE@ptr]

const WASM_CANDIDATES = [
  'moonpainter.wasm',
  './moonpainter.wasm',
  '../dist/moonpainter.wasm',
  './dist/moonpainter.wasm',
];

function readStr(exports, ptr) {
  const mem = new DataView(exports.memory.buffer);
  const len = Math.min(
    mem.getUint32(ptr - 4, true) & 0x0fffffff,
    (mem.buffer.byteLength - ptr) / 2,
  );
  let s = '';
  for (let i = 0; i < len; i++) s += String.fromCharCode(mem.getUint16(ptr + i * 2, true));
  return s;
}

function slotLoad(exports, text) {
  exports.in_reset();
  const bytes = new TextEncoder().encode(text);
  for (let i = 0; i < bytes.length; i += 4) {
    const n = Math.min(4, bytes.length - i);
    let le = 0;
    for (let j = 0; j < n; j++) le |= bytes[i + j] << (8 * j);
    exports.in_push(le, n);
  }
}

async function instantiateFromBuffer(buf) {
  const inst = new WebAssembly.Instance(new WebAssembly.Module(buf), {});
  return inst.exports;
}

/**
 * 加载 MoonPainter 引擎 wasm。
 * @param {string} [url='moonpainter.wasm'] wasm 路径（浏览器）或文件路径（Node）。
 * @returns {Promise<MoonPainterEngine>} 引擎门面。
 */
export async function loadEngine(url = 'moonpainter.wasm') {
  let exports;
  if (typeof window === 'undefined') {
    const fs = await import('node:fs');
    const path = await import('node:path');
    // 模块自身目录优先（npm 包自带 wasm），再退调用方 cwd 的候选
    const moduleDir = path.dirname(new URL(import.meta.url).pathname);
    for (const p of WASM_CANDIDATES) {
      const full = path.isAbsolute(p) ? p : path.resolve(moduleDir, p);
      try {
        if (fs.existsSync(full)) {
          exports = await instantiateFromBuffer(fs.readFileSync(full));
          break;
        }
      } catch (_) { /* 尝试下一个候选 */ }
    }
    if (!exports) {
      for (const p of WASM_CANDIDATES) {
        try {
          const full = path.resolve(p);
          if (fs.existsSync(full)) {
            exports = await instantiateFromBuffer(fs.readFileSync(full));
            break;
          }
        } catch (_) { /* 尝试下一个候选 */ }
      }
    }
    if (!exports) throw new Error('moonpainter.wasm not found（先跑 moon build --target wasm 或 build_demo.sh，且确认副本与本 SDK 同源）');
  } else {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`wasm fetch failed: ${resp.status}`);
    exports = await instantiateFromBuffer(await resp.arrayBuffer());
  }

  function execRaw(line) {
    slotLoad(exports, line);
    return readStr(exports, exports.mp_exec_in());
  }

  /** @returns {Promise<MoonPainterEngine>} */
  const engine = {
    /** 引擎版本 JSON 信封 */
    version() {
      return JSON.parse(readStr(exports, exports.mp_version()));
    },
    /** 重开默认会话（vision 闸复位） */
    reset() {
      return JSON.parse(readStr(exports, exports.mp_reset()));
    },
    /**
     * 执行一行引擎命令（vision 闸/undo/指纹等完整语义）。
     * @param {string} line
     * @returns {object} JSON 信封 {ok:true,...} 或 {error:"..."}
     */
    exec(line) {
      return JSON.parse(execRaw(line));
    },
    /** 打开句柄会话（多文档多路复用），返回句柄 */
    open() {
      return exports.mp_open();
    },
    /** 关闭句柄会话；1=已关 0=句柄不存在 */
    close(handle) {
      return exports.mp_close(handle);
    },
    /** 在句柄会话上执行命令 */
    execOn(handle, line) {
      slotLoad(exports, line);
      return JSON.parse(readStr(exports, exports.mp_exec_h(handle)));
    },
    /** 渲染当前画布并返回 {png_b64, render_sha256, fingerprint}（视觉通道入口） */
    render(width = 640, overlay = false) {
      const r = this.exec(`render ${width}${overlay ? ' overlay=1' : ''}`);
      if (!r.ok) throw new Error(r.error);
      return r;
    },
    /** 打包当前文档为 .mpd 容器字节（base64） */
    saveMpd() {
      const r = this.exec('save-mpd-b64');
      if (!r.ok) throw new Error(r.error);
      return r;
    },
    /** 从 .mpd 容器字节（base64）载入当前会话（saveMpd 的对偶） */
    openMpd(mpdB64) {
      const r = this.exec(`open-mpd-b64 ${mpdB64}`);
      if (!r.ok) throw new Error(r.error);
      return r;
    },
  };
  return engine;
}

/** @typedef {Object} MoonPainterEngine @see loadEngine */
