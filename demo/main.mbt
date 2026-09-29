/// demo —— 入口与页面（demo/main）。
///
/// Node 环境（moon run/test）：headless 自检——mock 模型跑一轮真实修图回合，
/// 输出 JSON 摘要（工具调用数/渲染数/指纹变化），供构建脚本断言。
/// 浏览器：构建页面（画布预览 + 全程过程日志 + 需求输入），AI 修图全程可见。

///|
extern "js" fn js_set_textcontent(id : String, text : String) -> Unit =
  #| (id, text) => { const el = document.getElementById(id); if (el) el.textContent = text; }

///|
extern "js" fn js_append_log(id : String, text : String) -> Unit =
  #| (id, text) => {
  #|     const el = document.getElementById(id);
  #|     if (!el) return;
  #|     const line = document.createElement('div');
  #|     line.textContent = text;
  #|     line.style.padding = '2px 0';
  #|     line.style.borderBottom = '1px solid #22283a';
  #|     el.appendChild(line);
  #|     el.scrollTop = el.scrollHeight;
  #|   }

///|
extern "js" fn js_set_img_src(id : String, png_b64 : String) -> Unit =
  #| (id, b64) => {
  #|     const el = document.getElementById(id);
  #|     if (el) el.src = 'data:image/png;base64,' + b64;
  #|   }

///|
extern "js" fn js_get_value(id : String) -> String =
  #| (id) => { const el = document.getElementById(id); return el ? el.value : ''; }

///|
extern "js" fn js_set_disabled(id : String, disabled : Bool) -> Unit =
  #| (id, d) => { const el = document.getElementById(id); if (el) el.disabled = d; }

///|
extern "js" fn js_download(filename : String, b64 : String) -> Unit =
  #| (filename, b64) => {
  #|     const bin = atob(b64);
  #|     const bytes = new Uint8Array(bin.length);
  #|     for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  #|     const blob = new Blob([bytes], { type: 'application/zip' });
  #|     const a = document.createElement('a');
  #|     a.href = URL.createObjectURL(blob);
  #|     a.download = filename;
  #|     a.click();
  #|     URL.revokeObjectURL(a.href);
  #|   }

///|
///|
/// 点击处理器：globalThis[name]() 每次 click 触发新协程（非 eager）。
extern "js" fn js_on_click_global(id : String, fn_name : String) -> Unit =
  #| (id, fnName) => {
  #|     const el = document.getElementById(id);
  #|     if (el) el.addEventListener('click', async () => {
  #|       try { await globalThis[fnName](); } catch (e) {
  #|         console.error('MoonPainter:', e);
  #|         const log = document.getElementById('mp-log');
  #|         if (log) { const d = document.createElement('div'); d.textContent = '❌ ' + String(e); d.style.color = '#f66'; log.appendChild(d); }
  #|       }
  #|     });
  #|   }

///|
extern "js" fn js_register_global_fn(name : String, f : () -> @js_async.Promise[Unit]) -> Unit =
  #| (name, f) => { globalThis[name] = f; }

///|
async fn paint_once_async() -> Unit {
  let request = js_get_value("mp-request")
  if request.trim(char_set=" \t").length() == 0 {
    js_append_log("mp-log", "⚠ 请先输入修改需求")
    return
  }
  js_set_disabled("mp-run", true)
  errdefer js_set_disabled("mp-run", false)
  let provider = js_get_value("mp-provider")
  let base_url_input = js_get_value("mp-baseurl")
  let model = js_get_value("mp-model")
  let api_key = js_get_value("mp-key")
  let cfg : LlmConfig = {
    provider,
    base_url: if base_url_input != "" {
      base_url_input
    } else {
      preset_base_url(provider)
    },
    model: if model != "" {
      model
    } else {
      match models_for(provider).get(0) {
        Some(m) => m.id
        None => ""
      }
    },
    api_key,
  }
  if cfg.provider != "mock" && (cfg.base_url == "" || cfg.api_key == "") {
    js_append_log("mp-log", "⚠ 真实端点需要 baseURL 与 API Key（或改用 Mock 离线演示）")
    js_set_disabled("mp-run", false)
    return
  }
  js_append_log("mp-log", "── 新回合（provider=\{cfg.provider} model=\{cfg.model}）──")
  let summary = run_edit_turn(
    request,
    cfg,
    log=fn(line) { js_append_log("mp-log", line) },
    on_image=fn(png) { js_set_img_src("mp-canvas", png) },
  )
  js_append_log("mp-log", "💬 \{summary}")
  js_set_disabled("mp-run", false)
}

///|
extern "js" fn js_append_option(id : String, value : String, text : String) -> Unit =
  #| (id, value, text) => {
  #|     const el = document.getElementById(id);
  #|     if (!el) return;
  #|     const o = document.createElement('option');
  #|     o.value = value;
  #|     o.textContent = text;
  #|     el.appendChild(o);
  #|   }

///|
extern "js" fn js_set_style_raw(css : String) -> Unit =
  #| (css) => {
  #|     const s = document.createElement('style');
  #|     s.textContent = css;
  #|     document.head.appendChild(s);
  #|   }

///|
extern "js" fn js_set_html(id : String, html : String) -> Unit =
  #| (id, html) => {
  #|     const el = document.getElementById(id);
  #|     if (el) el.innerHTML = html;
  #|   }

///|
/// 构建页面 DOM（全部结构由本函数生成；index.html 只挂一个根节点）。
fn build_page() -> Unit {
  js_set_style_raw(
    "body{margin:0;font-family:system-ui,-apple-system,'PingFang SC',sans-serif;background:#0d1020;color:#e8ebf5}" +
    "#mp-root{max-width:1180px;margin:0 auto;padding:18px}" +
    "h1{font-size:20px;margin:0 0 4px}" +
    ".sub{color:#8b93b8;font-size:12px;margin-bottom:14px}" +
    ".grid{display:grid;grid-template-columns:1.1fr 1fr;gap:14px}" +
    ".panel{background:#151a2e;border:1px solid #262d4a;border-radius:10px;padding:12px}" +
    "#mp-canvas{width:100%;image-rendering:auto;border-radius:6px;background:#fff}" +
    "#mp-log{height:420px;overflow-y:auto;font-size:12.5px;line-height:1.5;white-space:pre-wrap}" +
    "label{display:block;font-size:12px;color:#8b93b8;margin:8px 0 3px}" +
    "input,select{width:100%;box-sizing:border-box;background:#0d1020;color:#e8ebf5;border:1px solid #2c3554;border-radius:6px;padding:7px;font-size:13px}" +
    "button{margin-top:10px;width:100%;background:#3d63ff;color:#fff;border:0;border-radius:8px;padding:10px;font-size:14px;cursor:pointer}" +
    "button:disabled{opacity:.5;cursor:default}" +
    "button.ghost{background:#232a45}",
  )
  js_set_html(
    "mp-root",
    (
      #|<h1>MoonPainter · AI 修图 Demo</h1>
      #|<div class='sub'>wasm SDK 引擎 x posoco agent（MoonBit 全栈）— AI 每一步工具调用实时可见，非一键滤镜</div>
      #|<div class='grid'>
      #|<div class='panel'>
      #|<img id='mp-canvas' alt='画布预览'/>
      #|<button class='ghost' id='mp-save'>下载 .mpd 容器</button>
      #|</div>
      #|<div class='panel'>
      #|<label>模型端点</label><select id='mp-provider'></select>
      #|<label>Base URL（自定义端点时填写）</label><input id='mp-baseurl' placeholder='https://api.deepseek.com'/>
      #|<label>模型 ID</label><input id='mp-model' placeholder='deepseek-chat'/>
      #|<label>API Key（仅存本页，直接请求端点）</label><input id='mp-key' type='password' placeholder='sk-...'/>
      #|<label>修图需求（自然语言）</label><input id='mp-request' value='在右上角加一个渐变圆形徽章'/>
      #|<button id='mp-run'>AI 修图（全程可见）</button>
      #|<div id='mp-log'></div>
      #|</div>
      #|</div>
    ),
  )
  for p in provider_presets() {
    js_append_option("mp-provider", p.id, p.name)
  }
}

///|
async fn paint_save_async() -> Unit {
  ensure_engine()
  if !(g_bootstrapped.val) {
    js_append_log("mp-log", "⚠ 尚未开始修图，无容器可保存")
    return
  }
  let envelope = engine_exec_line("save-mpd-b64")
  let b64 = extract_json_string(envelope, "mpd_b64")
  if b64 != "" {
    js_download("moonpainter-demo.mpd", b64)
    js_append_log("mp-log", "📦 .mpd 容器已下载")
  } else {
    js_append_log("mp-log", "⚠ 打包失败：\{shorten_str(envelope, 200)}")
  }
}

///|
async fn main {
  if js_is_node() {
    // headless 自检：mock 模型完整修图回合 + wasm 引擎，输出 JSON 摘要
    let lines : Ref[Array[String]] = Ref([])
    let mut images = 0
    let summary = run_edit_turn(
      "在右上角加一个渐变圆形徽章",
      {
        provider: "mock",
        base_url: "",
        model: "mock-script",
        api_key: "",
      },
      log=fn(line) { lines.val.push(line) },
      on_image=fn(_png) { images = images + 1 },
    )
    let mut tool_starts = 0
    let mut tool_oks = 0
    for l in lines.val {
      if l.contains("🔧 执行") {
        tool_starts = tool_starts + 1
      }
      if l.contains("✅") {
        tool_oks = tool_oks + 1
      }
    }
    let saved_envelope = engine_exec_line("save-mpd-b64")
    let saved = extract_json_string(saved_envelope, "mpd_b64").length() > 0
    let log_json : Array[Json] = []
    for l in lines.val {
      log_json.push(Json::string(l))
    }
    println(
      "{\"headless_selftest\":true,\"tool_calls\":\{tool_starts},\"tool_ok\":\{tool_oks},\"renders\":\{images},\"saved_mpd\":\{saved},\"summary\":\"\{@core.json_escape(summary)}\",\"log\":\{Json::array(log_json).stringify()}}",
    )
  } else {
    build_page()
    js_register_global_fn("__mp_run", fn() -> @js_async.Promise[Unit] {
      @js_async.Promise::from_async(async fn() { paint_once_async() })
    })
    js_register_global_fn("__mp_save", fn() -> @js_async.Promise[Unit] {
      @js_async.Promise::from_async(async fn() { paint_save_async() })
    })
    js_on_click_global("mp-run", "__mp_run")
    js_on_click_global("mp-save", "__mp_save")
    js_set_textcontent(
      "mp-log",
      "提示：Mock 端点离线即可演示（AI 脚本模型逐工具修图）；接真实模型请选端点并填 Key。",
    )
  }
}
