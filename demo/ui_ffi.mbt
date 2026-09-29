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
  #|     if (!input || !input.files || input.files.length === 0) return { ok: false, error: 'no file' };
  #|     const file = input.files[0];
  #|     if (!file.type.startsWith('image/')) return { ok: false, error: 'not image: ' + file.type };
  #|     const buf = await file.arrayBuffer();
  #|     const bytes = new Uint8Array(buf);
  #|     let binary = '';
  #|     for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  #|     return { ok: true, b64: btoa(binary), name: file.name, size: file.size };
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
  #|       const buf = await file.arrayBuffer();
  #|       const bytes = new Uint8Array(buf);
  #|       let binary = '';
  #|       for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  #|       globalThis[fnName](btoa(binary), file.name);
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
extern "js" fn js_reg1(name : String, f : (String) -> Unit) -> Unit =
  #| (name, f) => { globalThis[name] = f; }

///|
extern "js" fn js_reg2s(name : String, f : (String, String) -> Unit) -> Unit =
  #| (name, f) => { globalThis[name] = f; }
