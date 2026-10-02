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
  #|   // 逐点绘制（折线/多边形）的预览：一张 SVG 覆盖层，点由前端存、这里只画
  #|   const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  #|   svg.id = 'poly-ov';
  #|   svg.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;display:none';
  #|   svg.innerHTML = "<polyline fill='rgba(106,156,255,.28)' stroke='#6a9cff' stroke-width='1.5' points=''/><circle r='3.5' fill='#fff' stroke='#6a9cff'/>";
  #|   wrap.appendChild(svg);
  #|   const pl = svg.querySelector('polyline');
  #|   const pc = svg.querySelector('circle');
  #|   window.__polyPreview = (pts) => {
  #|     if (!pts) { svg.style.display = 'none'; return; }
  #|     const r = img.getBoundingClientRect();
  #|     const sx = r.width / (img.naturalWidth || 1), sy = r.height / (img.naturalHeight || 1);
  #|     const arr = pts.split(';').filter(Boolean).map((q) => q.split(',').map(Number));
  #|     pl.setAttribute('points', arr.map((p) => (p[0] * sx).toFixed(1) + ',' + (p[1] * sy).toFixed(1)).join(' '));
  #|     const last = arr[arr.length - 1];
  #|     if (last) {
  #|       pc.setAttribute('cx', (last[0] * sx).toFixed(1));
  #|       pc.setAttribute('cy', (last[1] * sy).toFixed(1));
  #|       pc.style.display = '';
  #|     } else { pc.style.display = 'none'; }
  #|     svg.style.display = 'block';
  #|   };
  #|   window.__hideCrop = () => { ov.style.display = 'none'; globalThis.__crop_ready(''); };
  #|   window.__hideMask = () => { maskStart = null; ov.style.display = 'none'; };
  #|   let drawing = false; let toolDown = 'move';
  #|   let lastPt = null; let lastSend = 0;
  #|   let cropStart = null; let moveStart = null; let maskStart = null; let shapeStart = null;
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
  #|     } else if (t === 'rect' || t === 'ellipse') {
  #|       shapeStart = { dx, dy, x, y, kind: t };
  #|       ov.style.display = 'block';
  #|       ov.style.left = dx + 'px'; ov.style.top = dy + 'px';
  #|       ov.style.width = '0px'; ov.style.height = '0px';
  #|     } else if (t === 'line' || t === 'poly') {
  #|       globalThis.__poly_click(x + ',' + y);
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
  #|     } else if (shapeStart) {
  #|       const [dx, dy] = toDisp(e);
  #|       ov.style.left = Math.min(dx, shapeStart.dx) + 'px';
  #|       ov.style.top = Math.min(dy, shapeStart.dy) + 'px';
  #|       ov.style.width = Math.abs(dx - shapeStart.dx) + 'px';
  #|       ov.style.height = Math.abs(dy - shapeStart.dy) + 'px';
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
  #|     if (shapeStart) {
  #|       const [x, y] = toDoc(e);
  #|       const x0 = Math.min(shapeStart.x, x), y0 = Math.min(shapeStart.y, y);
  #|       const w = Math.abs(x - shapeStart.x), h = Math.abs(y - shapeStart.y);
  #|       const k = shapeStart.kind;
  #|       shapeStart = null;
  #|       ov.style.display = 'none';
  #|       // 太小算不算画，交给前端判（同一句话只有一处说）：这里只管把框报上去
  #|       globalThis.__shape_ready(k, x0 + ',' + y0 + ',' + w + ',' + h);
  #|     }
  #|   });
  #|   // 逐点绘制：双击 / 回车结束，Esc 放弃。双击本身会先落两个同坐标的点，
  #|   // 前端去重（poly_add）——所以这里不需要额外防抖。
  #|   img.addEventListener('dblclick', (e) => {
  #|     const t = window.MPST ? window.MPST.tool : 'move';
  #|     if (t !== 'line' && t !== 'poly') return;
  #|     e.preventDefault();
  #|     globalThis.__poly_finish();
  #|   });
  #|   document.addEventListener('keydown', (e) => {
  #|     const t = window.MPST ? window.MPST.tool : 'move';
  #|     if (t !== 'line' && t !== 'poly') return;
  #|     if (e.key === 'Enter') { e.preventDefault(); globalThis.__poly_finish(); }
  #|     else if (e.key === 'Escape') { e.preventDefault(); globalThis.__poly_cancel(); }
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
/// **headless（Node）专用**：把引擎的命令行入口暴露给驱动器。
/// 为什么必须有它：没有这个钩子，"点击穿透"（`demo/clickthrough.mjs`）就只能
/// 断言"调用没抛异常"——那等于没验。有了它才能从引擎把状态读回来，
/// 断言"点了处理器之后引擎里真的多了/改了什么"。
extern "js" fn js_expose_exec(f : (String) -> String) -> Unit =
  #| (f) => { globalThis.__headless_exec = f; }

///|
/// 逐点绘制的预览（空串 = 隐藏）。点是**画布坐标**，换算成显示坐标由 JS 做
/// （缩放/适配窗口都在那一侧）。
extern "js" fn js_poly_preview(pts : String) -> Unit =
  #| (pts) => { if (window.__polyPreview) window.__polyPreview(pts); }

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
      #|// 蒙版圆角/羽化。椭圆那个滑块写同一个 feather 键——圆角对椭圆无效，
      #|// 而羽化两者都吃，所以两个工具条共用一份羽化值。
      #|bind('mask-radius', 'mask_radius');
      #|const bindFeather = () => {
      #|  const es = [document.getElementById('mask-feather'), document.getElementById('mask-feather-e')];
      #|  const up = (src) => { window.MPST.mask_feather = src.value; es.forEach((e) => { if (e && e !== src) e.value = src.value; }); };
      #|  es.forEach((e) => { if (!e) return; e.addEventListener('input', () => up(e)); e.addEventListener('change', () => up(e)); });
      #|  // 同步标签
      #|  const pair = (id, label) => { const e = document.getElementById(id), l = document.getElementById(label); if (!e || !l) return;
      #|    const upd = () => { l.textContent = e.value; }; e.addEventListener('input', upd); e.addEventListener('change', upd); upd(); };
      #|  pair('mask-radius', 'mask-radius-v'); pair('mask-feather', 'mask-feather-v'); pair('mask-feather-e', 'mask-feather-e-v');
      #|};
      #|bindFeather();
      #|window.MPST.mask_radius = '0'; window.MPST.mask_feather = '0';
    ),
  )
}
