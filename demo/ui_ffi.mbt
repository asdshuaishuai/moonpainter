/// demo —— DOM FFI 绑定（demo/ui_ffi）。仅 js 后端。

///|
extern "js" fn js_text(id : String, text : String) -> Unit =
  #| (id, text) => { const el = document.getElementById(id); if (el) el.textContent = text; }

///|
extern "js" fn js_log_append(id : String, text : String) -> Unit =
  #| (id, text) => {
  #|     const el = document.getElementById(id);
  #|     if (!el) return;
  #|     const d = document.createElement('div');
  #|     d.textContent = text;
  #|     d.style.cssText = 'padding:3px 8px;font-size:12px;line-height:1.4';
  #|     el.appendChild(d);
  #|     el.scrollTop = el.scrollHeight;
  #|   }

///|
extern "js" fn js_set_img(id : String, b64 : String) -> Unit =
  #| (id, b64) => { const el = document.getElementById(id); if (el) el.src = 'data:image/png;base64,' + b64; }

///|
extern "js" fn js_val(id : String) -> String =
  #| (id) => { const el = document.getElementById(id); return el ? el.value : ''; }

///|
extern "js" fn js_disabled(id : String, d : Bool) -> Unit =
  #| (id, d) => { const el = document.getElementById(id); if (el) el.disabled = d; }

///|
extern "js" fn js_download_file(filename : String, b64 : String) -> Unit =
  #| (filename, b64) => {
  #|     const bin = atob(b64);
  #|     const bytes = new Uint8Array(bin.length);
  #|     for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  #|     const blob = new Blob([bytes], { type: 'application/octet-stream' });
  #|     const a = document.createElement('a');
  #|     a.href = URL.createObjectURL(blob);
  #|     a.download = filename;
  #|     a.click();
  #|     URL.revokeObjectURL(a.href);
  #|   }

///|
extern "js" fn js_click_global(id : String, fn_name : String) -> Unit =
  #| (id, fnName) => {
  #|     const el = document.getElementById(id);
  #|     if (el) el.addEventListener('click', async () => {
  #|       try { await globalThis[fnName](); } catch (e) {
  #|         console.error('MP:', e);
  #|         const log = document.getElementById('ailog');
  #|         if (log) { const d = document.createElement('div'); d.textContent = '❌ ' + String(e); d.style.color = '#f66'; log.appendChild(d); }
  #|       }
  #|     });
  #|   }

///|
extern "js" fn js_add_opt(id : String, value : String, text : String) -> Unit =
  #| (id, value, text) => {
  #|     const el = document.getElementById(id);
  #|     if (!el) return;
  #|     const o = document.createElement('option');
  #|     o.value = value; o.textContent = text; el.appendChild(o);
  #|   }

///|
extern "js" fn js_css(css : String) -> Unit =
  #| (css) => { const s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); }

///|
extern "js" fn js_html(id : String, html : String) -> Unit =
  #| (id, html) => { const el = document.getElementById(id); if (el) el.innerHTML = html; }

///|
extern "js" fn js_read_file_input(input_id : String) -> @js_async.Promise[Json] =
  #| (inputId) => (async () => {
  #|     const input = document.getElementById(inputId);
  #|     if (!input || !input.files || input.files.length === 0) return { ok: false, error: 'no file selected' };
  #|     const file = input.files[0];
  #|     input.value = '';
  #|     if (!file.type.startsWith('image/')) return { ok: false, error: 'not an image: ' + file.type };
  #|     const img = new Image();
  #|     const url = URL.createObjectURL(file);
  #|     await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = () => reject(new Error('image decode failed')); img.src = url; });
  #|     URL.revokeObjectURL(url);
  #|     const cv = document.createElement('canvas');
  #|     cv.width = img.naturalWidth;
  #|     cv.height = img.naturalHeight;
  #|     cv.getContext('2d').drawImage(img, 0, 0);
  #|     const dataUrl = cv.toDataURL('image/png');
  #|     const b64 = dataUrl.slice(dataUrl.indexOf(',') + 1);
  #|     return { ok: true, b64, name: file.name.replace(/\.[^.]+$/, '.png'), size: b64.length };
  #|   })()

///|
/// 读文件为 base64（**任意二进制**）。`.mpd` 容器走这条——上面那条
/// `js_read_file_input` 是图片专用：它会经 `Image` 解码再重编码成 PNG，
/// 容器是 ZIP 字节，走那边会被"not an image"挡掉或直接解码失败。
extern "js" fn js_read_file_b64(input_id : String) -> @js_async.Promise[Json] =
  #| (inputId) => (async () => {
  #|     const input = document.getElementById(inputId);
  #|     if (!input || !input.files || input.files.length === 0) return { ok: false, error: 'no file selected' };
  #|     const file = input.files[0];
  #|     input.value = '';
  #|     const buf = new Uint8Array(await file.arrayBuffer());
  #|     let bin = '';
  #|     const CH = 0x8000;   // 分块，避免 fromCharCode.apply 的参数个数上限
  #|     for (let i = 0; i < buf.length; i += CH) bin += String.fromCharCode.apply(null, buf.subarray(i, i + CH));
  #|     return { ok: true, b64: btoa(bin), name: file.name, size: buf.length };
  #|   })()

///|
extern "js" fn js_setup_drop(target_id : String, global_fn : String) -> Unit =
  #| (targetId, fnName) => {
  #|     const el = document.getElementById(targetId);
  #|     if (!el) return;
  #|     el.addEventListener('dragover', (e) => { e.preventDefault(); el.style.borderColor = '#4a7cff'; });
  #|     el.addEventListener('dragleave', () => { el.style.borderColor = '#333'; });
  #|     el.addEventListener('drop', async (e) => {
  #|       e.preventDefault(); el.style.borderColor = '#333';
  #|       const files = e.dataTransfer?.files;
  #|       if (!files || files.length === 0) return;
  #|       const file = files[0];
  #|       if (!file.type.startsWith('image/')) return;
  #|       try {
  #|         const img = new Image();
  #|         const url = URL.createObjectURL(file);
  #|         await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = url; });
  #|         URL.revokeObjectURL(url);
  #|         const cv = document.createElement('canvas');
  #|         cv.width = img.naturalWidth; cv.height = img.naturalHeight;
  #|         cv.getContext('2d').drawImage(img, 0, 0);
  #|         const dataUrl = cv.toDataURL('image/png');
  #|         const b64 = dataUrl.slice(dataUrl.indexOf(',') + 1);
  #|         globalThis[fnName](b64, file.name);
  #|       } catch (err) { console.error('drop import failed:', err); }
  #|     });
  #|   }

///|
extern "js" fn js_toggle_ai() -> Unit =
  #| () => {
  #|   const p = document.getElementById('ai-panel');
  #|   const arrow = document.getElementById('ai-arrow');
  #|   if (p) p.classList.toggle('closed');
  #|   if (arrow) arrow.textContent = p?.classList.contains('closed') ? '▲' : '▼';
  #| }

///|
extern "js" fn js_refresh_layers(html : String) -> Unit =
  #| (html) => { const el = document.getElementById('llist'); if (el) el.innerHTML = html; }

///|
extern "js" fn js_update_props(html : String) -> Unit =
  #| (html) => { const el = document.getElementById('pprops'); if (el) el.innerHTML = html; }

///|
extern "js" fn js_status_bar(text : String) -> Unit =
  #| (text) => { const el = document.getElementById('sbar-text'); if (el) el.textContent = text; }

///|
extern "js" fn js_canvas_img(png_b64 : String) -> Unit =
  #| (b64) => { const el = document.getElementById('canvas-img'); if (el) el.src = 'data:image/png;base64,' + b64; }

///|
extern "js" fn js_log_line(text : String, color : String) -> Unit =
  #| (text, color) => {
  #|     const el = document.getElementById('ailog');
  #|     if (!el) return;
  #|     const d = document.createElement('div');
  #|     d.textContent = text;
  #|     d.style.cssText = 'padding:3px 8px;font-size:12px;line-height:1.4;' + (color ? 'color:' + color : '');
  #|     el.appendChild(d);
  #|     el.scrollTop = el.scrollHeight;
  #|   }

///|
extern "js" fn js_reg0(name : String, f : () -> @js_async.Promise[Unit]) -> Unit =
  #| (name, f) => { globalThis[name] = async () => { try { await f(); } catch (e) { console.error('MP:', e); } }; }

///|
///|
/// `globalThis` 上有没有一个叫 `name` 的函数（页面接线检查用：HTML 里
/// `onclick='globalThis.__x()'` 引用的处理器必须真的注册过）。
pub extern "js" fn js_global_is_fn(name : String) -> Bool =
  #| (name) => typeof globalThis[name] === 'function'

///|
extern "js" fn js_reg1(name : String, f : (String) -> Unit) -> Unit =
  #| (name, f) => { globalThis[name] = f; }

///|
extern "js" fn js_reg2s(name : String, f : (String, String) -> Unit) -> Unit =
  #| (name, f) => { globalThis[name] = f; }

// ---------------------------------------------------------------------------
// 画布交互（B4）：工具状态、指针事件、裁剪覆盖层、缩放、提示输入
// ---------------------------------------------------------------------------

///|
/// 注入一段原生 <script>（MPST 工具状态、输入绑定、裁剪覆盖层辅助）。
extern "js" fn js_script(code : String) -> Unit =
  #| (code) => { const s = document.createElement('script'); s.textContent = code; document.head.appendChild(s); }

///|
/// 画布指针交互：坐标换算（显示尺寸→文档像素）、笔刷分段节流上送、
/// 裁剪矩形拖拽、吸管/文本点击、移动图层增量。工具状态读 window.MPST.tool。
extern "js" fn js_setup_canvas(img_id : String) -> Unit =
  #| (imgId) => {
  #|   const img = document.getElementById(imgId);
  #|   if (!img) return;
  #|   const wrap = img.parentElement;
  #|   wrap.style.position = 'relative';
  #|   const ov = document.createElement('div');
  #|   ov.id = 'crop-ov';
  #|   ov.style.cssText = 'position:absolute;border:1px dashed #6a9cff;box-shadow:0 0 0 9999px rgba(10,10,20,.55);display:none;pointer-events:none';
  #|   wrap.appendChild(ov);
  #|   window.__hideCrop = () => { ov.style.display = 'none'; globalThis.__crop_ready(''); };
  #|   window.__hideMask = () => { maskStart = null; ov.style.display = 'none'; };
  #|   let drawing = false; let toolDown = 'move';
  #|   let lastPt = null; let lastSend = 0;
  #|   let cropStart = null; let moveStart = null; let maskStart = null;
  #|   const toDoc = (e) => {
  #|     const r = img.getBoundingClientRect();
  #|     const sx = (img.naturalWidth || 1) / r.width, sy = (img.naturalHeight || 1) / r.height;
  #|     return [Math.round((e.clientX - r.left) * sx), Math.round((e.clientY - r.top) * sy)];
  #|   };
  #|   const toDisp = (e) => {
  #|     const r = img.getBoundingClientRect();
  #|     return [e.clientX - r.left, e.clientY - r.top];
  #|   };
  #|   img.addEventListener('mousedown', (e) => {
  #|     e.preventDefault();
  #|     const t = window.MPST ? window.MPST.tool : 'move';
  #|     toolDown = t;
  #|     const [x, y] = toDoc(e);
  #|     const [dx, dy] = toDisp(e);
  #|     if (t === 'brush' || t === 'erase') {
  #|       drawing = true; lastPt = [x, y]; lastSend = 0;
  #|     } else if (t === 'pick') {
  #|       globalThis.__pick_at(x + ',' + y);
  #|     } else if (t === 'text') {
  #|       globalThis.__text_at(x + ',' + y);
  #|     } else if (t === 'crop') {
  #|       cropStart = { dx, dy, x, y };
  #|       ov.style.display = 'block';
  #|       ov.style.left = dx + 'px'; ov.style.top = dy + 'px';
  #|       ov.style.width = '0px'; ov.style.height = '0px';
  #|     } else if (t === 'mask' || t === 'mask_e') {
  #|       maskStart = { dx, dy, x, y };
  #|       ov.style.display = 'block';
  #|       ov.style.left = dx + 'px'; ov.style.top = dy + 'px';
  #|       ov.style.width = '0px'; ov.style.height = '0px';
  #|     } else if (t === 'move') {
  #|       moveStart = [x, y];
  #|     }
  #|   });
  #|   document.addEventListener('mousemove', (e) => {
  #|     if (drawing) {
  #|       const [x, y] = toDoc(e);
  #|       const now = performance.now();
  #|       if (now - lastSend > 60 && lastPt) {
  #|         globalThis.__stroke(toolDown, lastPt[0] + ',' + lastPt[1] + ';' + x + ',' + y);
  #|         lastPt = [x, y]; lastSend = now;
  #|       }
  #|     } else if (cropStart) {
  #|       const [dx, dy] = toDisp(e);
  #|       ov.style.left = Math.min(dx, cropStart.dx) + 'px';
  #|       ov.style.top = Math.min(dy, cropStart.dy) + 'px';
  #|       ov.style.width = Math.abs(dx - cropStart.dx) + 'px';
  #|       ov.style.height = Math.abs(dy - cropStart.dy) + 'px';
  #|     } else if (maskStart) {
  #|       const [dx, dy] = toDisp(e);
  #|       ov.style.left = Math.min(dx, maskStart.dx) + 'px';
  #|       ov.style.top = Math.min(dy, maskStart.dy) + 'px';
  #|       ov.style.width = Math.abs(dx - maskStart.dx) + 'px';
  #|       ov.style.height = Math.abs(dy - maskStart.dy) + 'px';
  #|     }
  #|   });
  #|   document.addEventListener('mouseup', (e) => {
  #|     if (drawing) {
  #|       const [x, y] = toDoc(e);
  #|       if (lastPt && (lastPt[0] !== x || lastPt[1] !== y)) {
  #|         globalThis.__stroke(toolDown, lastPt[0] + ',' + lastPt[1] + ';' + x + ',' + y);
  #|       }
  #|       drawing = false; lastPt = null;
  #|       if (globalThis.__refresh) setTimeout(() => globalThis.__refresh(), 0);
  #|     }
  #|     if (cropStart) {
  #|       const [x, y] = toDoc(e);
  #|       const x0 = Math.min(cropStart.x, x), y0 = Math.min(cropStart.y, y);
  #|       const w = Math.abs(x - cropStart.x), h = Math.abs(y - cropStart.y);
  #|       if (w > 4 && h > 4) globalThis.__crop_ready(x0 + ',' + y0 + ',' + w + ',' + h);
  #|       else window.__hideCrop();
  #|       cropStart = null;
  #|     }
  #|     if (maskStart) {
  #|       const [x, y] = toDoc(e);
  #|       const x0 = Math.min(maskStart.x, x), y0 = Math.min(maskStart.y, y);
  #|       const w = Math.abs(x - maskStart.x), h = Math.abs(y - maskStart.y);
  #|       if (w > 4 && h > 4)
  #|         globalThis.__mask_ready(toolDown === 'mask_e' ? 'ellipse' : 'rect',
  #|                                  x0 + ',' + y0 + ',' + w + ',' + h);
  #|       else window.__hideMask();
  #|       maskStart = null;
  #|     }
  #|     if (moveStart) {
  #|       const [x, y] = toDoc(e);
  #|       globalThis.__move_delta(String(x - moveStart[0]), String(y - moveStart[1]));
  #|       moveStart = null;
  #|     }
  #|   });
  #| }

///|
extern "js" fn js_set_tool(name : String) -> Unit =
  #| (name) => {
  #|   if (!window.MPST) window.MPST = { tool: 'move', color: '#ff3366', size: 10, strength: 0.5, zoom: 1 };
  #|   window.MPST.tool = name;
  #|   document.querySelectorAll('#tools .t[data-tool]').forEach((el) => {
  #|     el.classList.toggle('on', el.dataset.tool === name);
  #|   });
  #|   document.querySelectorAll('#optbar .ctx').forEach((el) => {
  #|     el.style.display = el.dataset.for === name ? 'flex' : 'none';
  #|   });
  #|   if (name !== 'crop' && window.__hideCrop) window.__hideCrop();
  #|   if (name !== 'mask' && name !== 'mask_e' && window.__hideMask) window.__hideMask();
  #| }

///|
extern "js" fn js_zoom_canvas(factor : Double) -> Unit =
  #| (f) => {
  #|   const img = document.getElementById('canvas-img');
  #|   if (!img || !img.naturalWidth) return;
  #|   if (!window.MPST) window.MPST = { zoom: 1 };
  #|   let z = window.MPST.zoom * f;
  #|   if (z < 0.1) z = 0.1; if (z > 8) z = 8;
  #|   window.MPST.zoom = z;
  #|   img.style.maxWidth = 'none';
  #|   img.style.maxHeight = 'none';
  #|   img.style.width = Math.round(img.naturalWidth * z * 0.5) + 'px';
  #|   img.style.height = 'auto';
  #| }

///|
extern "js" fn js_zoom_fit() -> Unit =
  #| () => {
  #|   const img = document.getElementById('canvas-img');
  #|   if (!img) return;
  #|   img.style.width = ''; img.style.height = '';
  #|   img.style.maxWidth = '100%'; img.style.maxHeight = '72vh';
  #|   if (window.MPST) window.MPST.zoom = 1;
  #| }

///|
extern "js" fn js_show_crop_btns(show : Bool, rect : String) -> Unit =
  #| (show, rect) => {
  #|   const el = document.getElementById('crop-btns');
  #|   if (el) el.style.display = show ? 'flex' : 'none';
  #|   if (window.MPST) window.MPST.crop = show ? rect : '';
  #| }

///|
extern "js" fn js_state_get(key : String) -> String =
  #| (key) => (window.MPST && window.MPST[key] !== undefined) ? String(window.MPST[key]) : ''

///|
/// 吸管回填笔色（#RRGGBBAA → 取前 6 位给 color input）。
extern "js" fn js_set_brush_color(hex : String) -> Unit =
  #| (hex) => {
  #|   const el = document.getElementById('bcolor');
  #|   if (el) el.value = hex.slice(0, 7);
  #|   if (window.MPST) window.MPST.color = hex.slice(0, 7);
  #| }

///|
/// 画布光标随工具切换。
extern "js" fn js_canvas_cursor(tool : String) -> Unit =
  #| (tool) => {
  #|   const img = document.getElementById('canvas-img');
  #|   if (img) img.className = 'tool-' + tool;
  #| }

///|
extern "js" fn js_hide_crop() -> Unit =
  #| () => { if (window.__hideCrop) window.__hideCrop(); }

///|
/// 文本工具目标位置存取。
extern "js" fn js_set_text_target(coords : String) -> Unit =
  #| (coords) => { if (!window.MPST) window.MPST = {}; window.MPST.textAt = coords; }

///|
extern "js" fn js_val_clear(id : String) -> Unit =
  #| (id) => { const el = document.getElementById(id); if (el) el.value = ''; }

///|
/// 笔径/强度滑杆数值标签联动。
extern "js" fn js_bind_size_labels() -> Unit =
  #| () => {
  #|   const pair = (slider, label, fmt) => {
  #|     const s = document.getElementById(slider), l = document.getElementById(label);
  #|     if (!s || !l) return;
  #|     const up = () => { l.textContent = fmt(s.value); };
  #|     s.addEventListener('input', up); up();
  #|   };
  #|   pair('bsize', 'bsize-v', (v) => v + ' px');
  #|   pair('fstr', 'fstr-v', (v) => (Number(v) / 100).toFixed(2));
  #| }

///|
/// 注入 MPST 初始化与选项输入绑定。
pub fn setup_tool_state() -> Unit {
  js_script(
    (
      #|window.MPST = { tool: 'move', color: '#ff3366', size: 10, strength: 0.5, zoom: 1, crop: '' };
      #|const bind = (id, key, tx) => { const el = document.getElementById(id); if (!el) return;
      #|  const up = () => { window.MPST[key] = tx ? tx(el.value) : el.value; };
      #|  el.addEventListener('input', up); el.addEventListener('change', up); up(); };
      #|bind('bcolor', 'color');
      #|bind('bsize', 'size', (v) => Number(v));
      #|bind('esize', 'size', (v) => Number(v));
      #|bind('fstr', 'strength', (v) => (Number(v) / 100).toFixed(2));
    ),
  )
}
