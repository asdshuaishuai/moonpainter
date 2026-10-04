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
extern "js" fn js_refresh_history(html : String) -> Unit =
  #| (html) => { const el = document.getElementById('hlist'); if (el) el.innerHTML = html; }

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
  #|   // 仿制图章的**源点标记**（十字）：Alt 点一下画出来，让人看得见"从哪儿取样"。
  #|   // 它只是**显示**——源锚点的真值在引擎侧（`clone_off`），前端不存第二份。
  #|   const cm = document.createElement('div');
  #|   cm.id = 'clone-src';
  #|   cm.textContent = '✛';
  #|   cm.style.cssText = 'position:absolute;display:none;pointer-events:none;color:#ff4d4d;font:14px/14px sans-serif;text-shadow:0 0 2px #000;transform:translate(-7px,-7px)';
  #|   wrap.appendChild(cm);
  #|   window.__cloneMark = (dx, dy, on) => {
  #|     cm.style.display = on ? 'block' : 'none';
  #|     if (on) { cm.style.left = dx + 'px'; cm.style.top = dy + 'px'; }
  #|   };
  #|   // 逐点绘制（折线/多边形）的预览：一张 SVG 覆盖层，点由前端存、这里只画
  #|   const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  #|   svg.id = 'poly-ov';
  #|   svg.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;display:none';
  #|   svg.innerHTML = "<polyline fill='rgba(106,156,255,.28)' stroke='#6a9cff' stroke-width='1.5' points=''/><circle r='3.5' fill='#fff' stroke='#6a9cff'/>";
  #|   wrap.appendChild(svg);
  #|   const pl = svg.querySelector('polyline');
  #|   const pc = svg.querySelector('circle');
  #|   // 自由变换的**框 + 手柄**（PS 的 Ctrl+T）：框从引擎来（`window.__MP_TF`，
  #|   // 由 `js_tf_box` 在每次刷新属性面板时推来），这里只负责**画**与**命中判定**。
  #|   // 手柄画不画由能力位决定（`resize` 才有八个缩放手柄；`move` 才能框内拖动）
  #|   // ——能力只有引擎一处算（`caps`），前端不猜 kind。
  #|   const tf = document.createElement('div');
  #|   tf.id = 'tf-ov';
  #|   tf.style.cssText = 'position:absolute;display:none;border:1px solid #6a9cff;pointer-events:none;z-index:3';
  #|   wrap.appendChild(tf);
  #|   const TF_POS = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
  #|   const tfHandles = {};
  #|   for (const pos of TF_POS) {
  #|     const h = document.createElement('div');
  #|     h.dataset.pos = pos;
  #|     h.style.cssText = 'position:absolute;width:7px;height:7px;background:#fff;border:1px solid #6a9cff;transform:translate(-50%,-50%)';
  #|     tf.appendChild(h);
  #|     tfHandles[pos] = h;
  #|   }
  #|   const tfRot = document.createElement('div');
  #|   tfRot.id = 'tf-rot';
  #|   tfRot.style.cssText = 'position:absolute;width:9px;height:9px;border-radius:50%;background:#ffd166;border:1px solid #b8860b;transform:translate(-50%,-50%)';
  #|   tf.appendChild(tfRot);
  #|   window.__MP_TF = null;
  #|   // 画布显示尺寸 ↔ 文档像素（与 `toDoc` 同一对比例；正反各算一处就会分叉，
  #|   // 所以两边都从这里出）
  #|   const tfScale = () => {
  #|     const r = img.getBoundingClientRect();
  #|     return [r.width / (img.naturalWidth || 1), r.height / (img.naturalHeight || 1), r];
  #|   };
  #|   // 画一个**文档坐标**的框：框、八个手柄、旋转圆点一次画完。
  #|   // 拖动过程中画的是"草稿框"（还没发命令），松手才落定——预览与落定**同一个
  #|   // 函数**，所以"看到的框"与"报出去的框"不可能不一致。
  #|   window.__tfPaint = (t) => {
  #|     const sc = tfScale();
  #|     const x = t.x * sc[0], y = t.y * sc[1], w = t.w * sc[0], h = t.h * sc[1];
  #|     tf.style.left = x + 'px'; tf.style.top = y + 'px';
  #|     tf.style.width = Math.max(1, w) + 'px'; tf.style.height = Math.max(1, h) + 'px';
  #|     const at = {
  #|       nw: [0, 0], n: [w / 2, 0], ne: [w, 0], e: [w, h / 2],
  #|       se: [w, h], s: [w / 2, h], sw: [0, h], w: [0, h / 2],
  #|     };
  #|     for (const pos of TF_POS) {
  #|       const el = tfHandles[pos];
  #|       el.style.display = t.resize ? '' : 'none';
  #|       el.style.left = at[pos][0] + 'px'; el.style.top = at[pos][1] + 'px';
  #|     }
  #|     tfRot.style.left = (w / 2) + 'px'; tfRot.style.top = '-18px';
  #|   };
  #|   // 工具/选中态变了就重画（工具不是 transform 或没选中层 ⇒ 整块藏起来）
  #|   window.__tfRefresh = () => {
  #|     const t = window.__MP_TF;
  #|     const tool = window.MPST ? window.MPST.tool : 'move';
  #|     if (!t || tool !== 'transform') { tf.style.display = 'none'; return; }
  #|     tf.style.display = '';
  #|     window.__tfPaint(t);
  #|   };
  #|   // 命中判定：8 个手柄（±6 显示像素）→ 旋转圆点 → 框内（能挪才认）→ 空白。
  #|   // **先判手柄再判框内**：角上那 7px 既在框内也压着手柄，顺序反了就永远拉不到角。
  #|   const tfHit = (px, py, b) => {
  #|     const sc = tfScale();
  #|     const x = b.x * sc[0], y = b.y * sc[1], w = b.w * sc[0], h = b.h * sc[1];
  #|     const TOL = 6;
  #|     const near = (hx, hy) => Math.abs(px - hx) <= TOL && Math.abs(py - hy) <= TOL;
  #|     if (near(x + w / 2, y - 18)) return 'rot';
  #|     if (b.resize) {
  #|       const pts = {
  #|         nw: [x, y], n: [x + w / 2, y], ne: [x + w, y], e: [x + w, y + h / 2],
  #|         se: [x + w, y + h], s: [x + w / 2, y + h], sw: [x, y + h], w: [x, y + h / 2],
  #|       };
  #|       for (const pos of TF_POS) {
  #|         if (near(pts[pos][0], pts[pos][1])) return pos;
  #|       }
  #|     }
  #|     if (b.move && px > x && px < x + w && py > y && py < y + h) return 'in';
  #|     return null;
  #|   };
  #|   // 这一手的草稿框：**纯函数**（起点 + 当前指针 + Shift ⇒ 新框），
  #|   // 预览与落定都调它 ⇒ 两处不可能给出不同的数。
  #|   // 角手柄拖的是"对角固定"；边手柄只改一个方向；框内拖 = 平移；圆点 = 绕中心转。
  #|   const tfDraft = (st, x, y, shift) => {
  #|     const b = st.b;
  #|     if (st.hit === 'in') {
  #|       return { x: b.x + (x - st.x), y: b.y + (y - st.y), w: b.w, h: b.h, rot: b.rot };
  #|     }
  #|     if (st.hit === 'rot') {
  #|       const cx = b.x + b.w / 2, cy = b.y + b.h / 2;
  #|       const a0 = Math.atan2(st.y - cy, st.x - cx);
  #|       const a1 = Math.atan2(y - cy, x - cx);
  #|       let deg = b.rot + (a1 - a0) * 180 / Math.PI;
  #|       if (shift) deg = Math.round(deg / 15) * 15;
  #|       return { x: b.x, y: b.y, w: b.w, h: b.h, rot: Math.round(deg * 100) / 100 };
  #|     }
  #|     // 缩放：先按"抓到的那个手柄"算出新的左边/上边/宽/高（对角固定）
  #|     let x0 = b.x, y0 = b.y, x1 = b.x + b.w, y1 = b.y + b.h;
  #|     const west = st.hit.includes('w'), east = st.hit.includes('e');
  #|     const north = st.hit.includes('n'), south = st.hit.includes('s');
  #|     if (west) x0 = Math.min(x, x1 - 1); else if (east) x1 = Math.max(x, x0 + 1);
  #|     if (north) y0 = Math.min(y, y1 - 1); else if (south) y1 = Math.max(y, y0 + 1);
  #|     let w = x1 - x0, h = y1 - y0;
  #|     if (shift && (west || east) && (north || south) && b.w > 0 && b.h > 0) {
  #|       // 等比：按"变化更大的那一维"定倍数（PS 的 Shift 手感）
  #|       const k = Math.max(w / b.w, h / b.h);
  #|       const nw = b.w * k, nh = b.h * k;
  #|       if (west) x0 = x1 - nw; 
  #|       if (north) y0 = y1 - nh;
  #|       w = nw; h = nh;
  #|     }
  #|     return { x: x0, y: y0, w: Math.max(1, w), h: Math.max(1, h), rot: b.rot };
  #|   };
  #|   // **点拾取类工具只有这一份清单**：折线/多边形逐点建层、套索逐点圈选区。
  #|   // 三处（点击/双击/按键）都读它——抄第二遍就是"加了个工具而某个入口没跟上"。
  #|   window.__MP_POLY_TOOLS = ['line', 'poly', 'lasso', 'pen'];
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
  #|   let penDown = null;
  #| let tfStart = null;  // 自由变换这一手的起点（画布坐标 + 抓到了哪儿 + 起始框）
  #| let tfStartBox = { x: 0, y: 0, w: 0, h: 0, rot: 0 };  // 钢笔这一笔的起点（画布坐标），松开时算控制柄位移
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
  #|     if (t === 'clone' && (e.altKey || e.metaKey)) {
  #|       // Alt（或 Mac 的 ⌘）点一下 = 定源，**不落笔**。源点交给引擎算偏移，
  #|       // 前端只把它报上去 + 画个十字。
  #|       globalThis.__clone_src(x + ',' + y);
  #|       window.__cloneMark(dx, dy, true);
  #|     } else if (t === 'brush' || t === 'erase' || t === 'clone') {
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
  #|     } else if (t === 'transform') {
  #|       // 自由变换：**按下就先看清抓到了什么**（手柄 / 框内 / 空白），抓空就什么都
  #|       // 不做（不许"以为在拖手柄、其实在挪别的东西"）
  #|       const b = window.__MP_TF;
  #|       if (!b) {
  #|         globalThis.__tf_hint('');
  #|       } else {
  #|         const r0 = img.getBoundingClientRect();
  #|         const hit = tfHit(e.clientX - r0.left, e.clientY - r0.top, b);
  #|         if (hit) {
  #|           tfStart = { hit, x, y, b: { x: b.x, y: b.y, w: b.w, h: b.h, rot: b.rot } };
  #|           tfStartBox = tfStart.b;
  #|         }
  #|       }
  #|    } else if (window.__MP_POLY_TOOLS.includes(t)) {
  #|       globalThis.__poly_click(x + ',' + y);
  #|       // 钢笔：拖拽 = 给**刚落的那个锚点**拉控制柄（曲线）。
  #|       // 起止点都记在画布坐标里，松开时只报**位移**——前端不猜锚点，
  #|       // 锚点归属由引擎侧 do_pen_handle 自己认（它知道刚落了几个点）。
  #|       if (t === 'pen') penDown = [x, y];
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
  #|     } else if (tfStart) {
  #|       const [x, y] = toDoc(e);
  #|       window.__tfPaint(tfDraft(tfStart, x, y, e.shiftKey));
  #|    } else if (shapeStart) {
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
  #|     if (penDown && toolDown === 'pen') {
  #|       const [x, y] = toDoc(e);
  #|       const dx = x - penDown[0], dy = y - penDown[1];
  #|       penDown = null;
  #|       if (Math.abs(dx) > 2 || Math.abs(dy) > 2) {
  #|         globalThis.__pen_handle(dx + ',' + dy);
  #|       }
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
  #|     if (tfStart) {
  #|       const [x, y] = toDoc(e);
  #|       const box = tfDraft(tfStart, x, y, e.shiftKey);
  #|       tfStart = null;
  #|       // 一个手势 = **一条** `transform`（一步历史）：数值收口（非数/夹紧）在
  #|       // MoonBit 那侧的 `do_tf_ready` **一处**做，这里只把框报上去。
  #|       // 一点没变（只是点了一下）就不发命令——不发空动作。
  #|       if (Math.abs(box.x - tfStartBox.x) > 0.001 || Math.abs(box.y - tfStartBox.y) > 0.001 ||
  #|           Math.abs(box.w - tfStartBox.w) > 0.001 || Math.abs(box.h - tfStartBox.h) > 0.001 ||
  #|           Math.abs(box.rot - tfStartBox.rot) > 0.001) {
  #|         globalThis.__tf_ready(box.x + ',' + box.y + ',' + box.w + ',' + box.h + ',' + box.rot);
  #|       }
  #|     }
  #|    if (shapeStart) {
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
  #|     if (!window.__MP_POLY_TOOLS.includes(t)) return;
  #|     e.preventDefault();
  #|     globalThis.__poly_finish();
  #|   });
  #|   document.addEventListener('keydown', (e) => {
  #|     const t = window.MPST ? window.MPST.tool : 'move';
  #|     if (!window.__MP_POLY_TOOLS.includes(t)) return;
  #|     if (e.key === 'Enter') { e.preventDefault(); globalThis.__poly_finish(); }
  #|     else if (e.key === 'Escape') { e.preventDefault(); globalThis.__poly_cancel(); }
  #|   });
  #| }

///|
/// 把**自由变换框**推给画布：`id` 空 = 撤框；`box` = `x,y,w,h,rot`（画布像素，
/// 与 `__tf_ready` 回来时同一格式）；`flags` 两位 = 能不能挪 / 能不能缩放
/// （来自引擎的 `caps`，前端只按位画手柄与判定命中，不猜 kind）。
extern "js" fn js_tf_box(id : String, box : String, flags : String) -> Unit =
  #| (id, box, flags) => {
  #|   if (!id) { window.__MP_TF = null; if (window.__tfRefresh) window.__tfRefresh(); return; }
  #|   const p = box.split(',').map(Number);
  #|   window.__MP_TF = {
  #|     id, x: p[0], y: p[1], w: p[2], h: p[3], rot: p[4] || 0,
  #|     move: flags[0] === '1', resize: flags[1] === '1',
  #|   };
  #|   if (window.__tfRefresh) window.__tfRefresh();
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
  #|   if (window.__tfRefresh) window.__tfRefresh();
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
      #|bind('csize', 'csize', (v) => Number(v));
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
