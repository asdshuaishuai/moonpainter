/// demo —— DOM FFI 绑定（demo/ui_ffi）。仅 js 后端。

///|
/// 有没有页面（DOM）？**headless 自检没有**（`build_demo.sh#4` 只给引擎，不给
/// 页面），而 `document` 未定义时任何 `getElementById` 都是 ReferenceError。
/// 判据放一处：要"画到页面上"的东西先问它，别改每一个 FFI（那会有十几份拷贝）。
extern "js" fn js_has_dom() -> Bool =
  #| () => typeof document !== 'undefined'

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
/// 装**唯一一份**"文件 → PNG base64"的读取器（`globalThis.__mpImageToPngB64`）。
///
/// 为什么只有一份：选文件（`js_read_file_input`）和拖文件（`js_setup_drop`）
/// 是两条入口，但"解码 → 缩到上限 → 转 PNG → 取尺寸"这件事**必须**同一份实现
/// ——抄两份的话，先烂的那份一定没人读（复制粘贴的代码没人会去同步）。
///
/// 返回 `{ ok, b64, name, w, h, scaled_from }`；失败给 `{ ok:false, error }`，
/// **error 是给人看的原话**（含 HEIC 这类最常见的坑）。`max_side` 由 MoonBit
/// 侧传进来（引擎可渲染单边上限，别在 JS 里再抄一个数字）。
extern "js" fn js_install_image_reader(max_side : Int) -> Unit =
  #| (maxSide) => {
  #|   globalThis.__MP_MAX_SIDE = maxSide;
  #|   if (globalThis.__mpImageToPngB64) return;
  #|   globalThis.__mpImageToPngB64 = async (file, maxSide) => {
  #|     const lower = (file.name || '').toLowerCase();
  #|     const heic = file.type === 'image/heic' || file.type === 'image/heif' ||
  #|                  lower.endsWith('.heic') || lower.endsWith('.heif');
  #|     const hint = heic
  #|       ? '（iPhone 的 HEIC 多数浏览器解不开：先在「照片」里导出/另存为 JPEG 再试）'
  #|       : '';
  #|     if (!file.type.startsWith('image/') && !heic) {
  #|       return { ok: false, error: '这不是图片：' + (file.type || '未知类型') + hint };
  #|     }
  #|     const url = URL.createObjectURL(file);
  #|     const img = new Image();
  #|     try {
  #|       await new Promise((res, rej) => {
  #|         img.onload = res;
  #|         img.onerror = () => rej(new Error('浏览器解不开这张图'));
  #|         img.src = url;
  #|       });
  #|     } catch (e) {
  #|       URL.revokeObjectURL(url);
  #|       return { ok: false, error: (e && e.message ? e.message : '解码失败') + hint };
  #|     }
  #|     URL.revokeObjectURL(url);
  #|     const ow = img.naturalWidth, oh = img.naturalHeight;
  #|     if (!ow || !oh) return { ok: false, error: '读不出图片尺寸' + hint };
  #|     // 超过引擎可渲染单边上限就**按比例缩到上限**——不缩的话画布会超出可渲染
  #|     // 上限（引擎会拒绝，或 lint 报 P0），人只会看到"导不进来"。
  #|     const k = Math.min(1, maxSide / Math.max(ow, oh));
  #|     const w = Math.max(1, Math.round(ow * k)), h = Math.max(1, Math.round(oh * k));
  #|     const cv = document.createElement('canvas');
  #|     cv.width = w; cv.height = h;
  #|     cv.getContext('2d').drawImage(img, 0, 0, w, h);
  #|     const dataUrl = cv.toDataURL('image/png');
  #|     const b64 = dataUrl.slice(dataUrl.indexOf(',') + 1);
  #|     if (!b64 || b64.length < 32) return { ok: false, error: '转 PNG 失败（图可能太大）' + hint };
  #|     return {
  #|       ok: true, b64, name: file.name.replace(/\.[^.]+$/, '.png'), w, h,
  #|       scaled_from: k < 1 ? ow + 'x' + oh : '',
  #|     };
  #|   };
  #| }

///|
extern "js" fn js_read_file_input(input_id : String) -> @js_async.Promise[Json] =
  #| (inputId) => (async () => {
  #|     const input = document.getElementById(inputId);
  #|     if (!input || !input.files || input.files.length === 0) {
  #|       return { ok: false, error: '没有选到文件' };
  #|     }
  #|     const file = input.files[0];
  #|     input.value = '';
  #|     return await globalThis.__mpImageToPngB64(file, globalThis.__MP_MAX_SIDE || 4096);
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
  #|       try {
  #|         // 与"选文件"**同一个**读取器（解码/缩到上限/转 PNG 只有一处实现）
  #|         const r = await globalThis.__mpImageToPngB64(files[0], globalThis.__MP_MAX_SIDE || 4096);
  #|         if (!r.ok) { globalThis.__mpErr(fnName, new Error(r.error)); return; }
  #|         globalThis[fnName](r.b64, r.name, r.scaled_from || '');
  #|       } catch (err) {
  #|         // 静默失败是最坏的一种：拖进来没反应，人会以为"这个功能根本没有"
  #|         globalThis.__mpErr(fnName, err);
  #|       }
  #|     });
  #|   }

///|
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
///处理器抛异常时的用户面反馈**只有这一处实现**（`js_reg0`/`js_reg1`/`js_reg2s`
/// 共用 `globalThis.__mpErr`）。原先只有 `js_reg0` 包了 try/catch（吞进
/// `console.error`），而 `js_reg1`/`js_reg2s` 是裸赋值——同一个"点了会不会
/// 静默失败"的问题在两处有两种答案，而**两处都不给用户看**。
/// 装钩子（幂等）：状态栏 + AI 日志报原话，并记进 `__handler_errors` 供驱动器断言。
extern "js" fn js_install_handler_error_hook() -> Unit =
  #| () => {
  #|     if (globalThis.__mpErr) return;
  #|     globalThis.__handler_errors = globalThis.__handler_errors || [];
  #|     globalThis.__mpErr = (name, e) => {
  #|       const msg = String((e && (e.message || e)) || e);
  #|       console.error('MP:', e);
  #|       globalThis.__handler_errors.push({ name, msg });
  #|       const s = document.getElementById('sbar-text');
  #|       if (s) s.textContent = '⚠ ' + name + ' 出错：' + msg;
  #|       const l = document.getElementById('ailog');
  #|       if (l) {
  #|         const d = document.createElement('div');
  #|         d.textContent = '❌ ' + name + ' 出错：' + msg;
  #|         d.style.cssText = 'padding:3px 8px;font-size:12px;color:#f66';
  #|         l.appendChild(d);
  #|       }
  #|     };
  #|   }

///|
extern "js" fn js_reg0(name : String, f : () -> @js_async.Promise[Unit]) -> Unit =
  #| (name, f) => {
  #|     globalThis[name] = async () => {
  #|       try {
  #|         await f();
  #|       } catch (e) {
  #|         globalThis.__mpErr(name, e);
  #|       }
  #|     };
  #|   }

///|
///|
/// `globalThis` 上有没有一个叫 `name` 的函数（页面接线检查用：HTML 里
/// `onclick='globalThis.__x()'` 引用的处理器必须真的注册过）。
pub extern "js" fn js_global_is_fn(name : String) -> Bool =
  #| (name) => typeof globalThis[name] === 'function'

///|
extern "js" fn js_reg1(name : String, f : (String) -> Unit) -> Unit =
  #| (name, f) => {
  #|     globalThis[name] = (a) => {
  #|       try {
  #|         f(a);
  #|       } catch (e) {
  #|         globalThis.__mpErr(name, e);
  #|       }
  #|     };
  #|   }

///|
extern "js" fn js_reg2s(name : String, f : (String, String) -> Unit) -> Unit =
  #| (name, f) => {
  #|     globalThis[name] = (a, b) => {
  #|       try {
  #|         f(a, b);
  #|       } catch (e) {
  #|         globalThis.__mpErr(name, e);
  #|       }
  #|     };
  #|   }

///|
extern "js" fn js_reg3s(name : String, f : (String, String, String) -> Unit) -> Unit =
  #| (name, f) => {
  #|     globalThis[name] = (a, b, c) => {
  #|       try {
  #|         f(a, b, c);
  #|       } catch (e) {
  #|         globalThis.__mpErr(name, e);
  #|       }
  #|     };
  #|   }

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
/// **headless（Node）专用**的第二个钩子：把**页面初始化**也暴露给驱动器。
/// 浏览器是在 `main` 里 `bootstrap()` 的（引擎复位 + 装载示例场景 + 首次渲染），
/// Node 分支没有 DOM 可注入、但**初始化本身与 DOM 无关**——驱动器必须与浏览器
/// 从同一个状态出发，否则第一个调用 `bootstrap()` 的处理器会把它自己的测试
/// 文档整个换成示例场景（实测被坑：吸管点在第一处时文档被重置，四条后续断言
/// 全跟着错，而报出来的现象看着像"pick 报错了层"）。
extern "js" fn js_expose_boot(boot : () -> Unit) -> Unit =
  #| (boot) => { globalThis.__headless_boot = boot; }

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
