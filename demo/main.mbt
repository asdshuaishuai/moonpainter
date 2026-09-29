/// demo —— 专业修图软件 UI（demo/main）。

let g_sel : Ref[String] = Ref("")
let g_ready : Ref[Bool] = Ref(false)

fn eng(line : String) -> Json {
  parse_json_safe(engine_exec_line(line))
}

fn eng_ok(j : Json) -> Bool {
  json_has_ok(j)
}

fn eng_s(j : Json, key : String) -> String {
  json_get_str(j, key)
}

fn eng_render(w : Int) -> Unit {
  let r = eng("render \{w}")
  let b64 = eng_s(r, "png_b64")
  if b64 != "" {
    js_canvas_img(b64)
  }
}

fn bootstrap() -> Unit {
  if g_ready.val {
    return
  }
  let _ = engine_reset()
  let _ = engine_exec_line("session-open full_image")
  let _ = engine_exec_line("new 800 600 uuid=painter")
  let _ = engine_exec_line("add-rect x=0 y=0 w=800 h=600 fill=#F5F0EBFF name=画布底色 tag=background")
  let _ = engine_exec_line("add-rect x=80 y=100 w=300 h=200 fill=#2C3E6BFF radius=16 name=主卡片")
  let _ = engine_exec_line("add-ellipse x=440 y=120 w=180 h=180 lgrad=#FF7A45FF,#2E6FE8FF,0,0,1,1 name=渐变球")
  let _ = engine_exec_line("add-text x=100 y=340 text=MoonPainter font_size=32 fill=#2C3E6BFF name=标题")
  g_ready.val = true
  eng_render(800)
  refresh_ui()
}

fn refresh_ui() -> Unit {
  let j = eng("list-layers")
  if !eng_ok(j) {
    return
  }
  let layers = match json_get(j, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  let count = layers.length()
  let sb = StringBuilder()
  let mut i = count - 1
  while i >= 0 {
    let l = layers[i]
    let lid = json_get_str(l, "id")
    let lnm = json_get_str(l, "name")
    let lkd = json_get_str(l, "kind")
    let vis = match json_get(l, "visible") {
      Some(Json::True) => true
      _ => false
    }
    let sel = if lid == g_sel.val { " sel" } else { "" }
    let eye = if vis { "👁" } else { "🚫" }
    let ico = match lkd {
      "text" => "T"
      "image" => "🖼"
      "group" => "📁"
      "adjust" => "◐"
      _ => "□"
    }
    sb.write_string("<div class='li")
    sb.write_string(sel)
    sb.write_string("' onclick='globalThis.__sel(\"")
    sb.write_string(lid)
    sb.write_string("\")'><span class='eye' onclick='event.stopPropagation();globalThis.__vis(\"")
    sb.write_string(lid)
    sb.write_string("\")'>")
    sb.write_string(eye)
    sb.write_string("</span><span class='ico'>")
    sb.write_string(ico)
    sb.write_string("</span><span class='lnm'>")
    sb.write_string(lnm)
    sb.write_string("</span><span class='lkd'>")
    sb.write_string(lkd)
    sb.write_string("</span></div>")
    i = i - 1
  }
  js_refresh_layers(sb.to_string())
  let fp_j = eng("fingerprint")
  let fp = json_get_str(fp_j, "fingerprint")
  js_status_bar("图层: \{count} │ 指纹: \{fp}")
  refresh_props()
}

fn refresh_props() -> Unit {
  let id = g_sel.val
  if id == "" {
    js_update_props("<div class='ns'>点击图层查看属性</div>")
    return
  }
  let j = eng("query-layer \{id}")
  if !eng_ok(j) {
    return
  }
  let l = match json_get(j, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let gid = json_get_str(l, "id")
  let gname = json_get_str(l, "name")
  let gkind = json_get_str(l, "kind")
  let gx = json_num_str(l, "x")
  let gy = json_num_str(l, "y")
  let gw = json_num_str(l, "w")
  let gh = json_num_str(l, "h")
  let gop = json_num_str(l, "opacity")
  let gbl = json_get_str(l, "blend")
  let sb = StringBuilder()
  sb.write_string("<div class='pg'>")
  sb.write_string("<span class='pk'>ID</span><span class='pv'>")
  sb.write_string(gid)
  sb.write_string("</span><span class='pk'>名称</span><span class='pv'>")
  sb.write_string(gname)
  sb.write_string("</span><span class='pk'>类型</span><span class='pv'>")
  sb.write_string(gkind)
  sb.write_string("</span><span class='pk'>X</span><span class='pv'>")
  sb.write_string(gx)
  sb.write_string("</span><span class='pk'>Y</span><span class='pv'>")
  sb.write_string(gy)
  sb.write_string("</span><span class='pk'>W</span><span class='pv'>")
  sb.write_string(gw)
  sb.write_string("</span><span class='pk'>H</span><span class='pv'>")
  sb.write_string(gh)
  sb.write_string("</span><span class='pk'>α</span><span class='pv'>")
  sb.write_string(gop)
  sb.write_string("</span><span class='pk'>混合</span><span class='pv'>")
  sb.write_string(gbl)
  sb.write_string("</span></div>")
  sb.write_string("<div class='pact'><button onclick='globalThis.__del(\"")
  sb.write_string(id)
  sb.write_string("\")'>删除</button><button onclick='globalThis.__dup(\"")
  sb.write_string(id)
  sb.write_string("\")'>复制</button></div>")
  js_update_props(sb.to_string())
}

fn json_num_str(j : Json, key : String) -> String {
  match json_get(j, key) {
    Some(Json::Number(n, ..)) => {
      let iv = n.to_int()
      if n == iv.to_double() {
        iv.to_string()
      } else {
        n.to_string()
      }
    }
    _ => "—"
  }
}

fn do_sel(id : String) -> Unit {
  g_sel.val = id
  refresh_ui()
}

fn do_vis(id : String) -> Unit {
  let q = eng("query-layer \{id}")
  let l = match json_get(q, "layer") {
    Some(x) => x
    None => parse_json_safe("null")
  }
  let cur = match json_get(l, "visible") {
    Some(Json::True) => "false"
    _ => "true"
  }
  let _ = engine_exec_line("visible \{id} \{cur}")
  eng_render(800)
  refresh_ui()
}

fn do_del(id : String) -> Unit {
  let _ = engine_exec_line("delete \{id}")
  g_sel.val = ""
  eng_render(800)
  refresh_ui()
}

fn do_dup(id : String) -> Unit {
  let _ = engine_exec_line("add-rect x=20 y=20 w=50 h=50 name=\{id}_copy")
  eng_render(800)
  refresh_ui()
}

fn do_undo() -> Unit {
  let _ = engine_exec_line("undo")
  eng_render(800)
  refresh_ui()
}

fn do_redo() -> Unit {
  let _ = engine_exec_line("redo")
  eng_render(800)
  refresh_ui()
}

fn do_new() -> Unit {
  let _ = engine_exec_line("new 800 600 uuid=n\{js_now_ms()}")
  let _ = engine_exec_line("add-rect x=0 y=0 w=800 h=600 fill=#FFFFFFFF name=背景")
  g_sel.val = ""
  eng_render(800)
  refresh_ui()
}

fn do_save() -> Unit {
  let r = eng("save-mpd-b64")
  let b64 = eng_s(r, "mpd_b64")
  if b64 != "" {
    js_download_file("painting.mpd", b64)
    js_log_line("📦 已保存", "#4a4")
  } else {
    js_log_line("⚠ 保存失败", "#f66")
  }
}

fn do_export() -> Unit {
  let r = eng("render 1200")
  let b64 = eng_s(r, "png_b64")
  if b64 != "" {
    js_download_file("export.png", b64)
    js_log_line("📷 PNG 已导出", "#4a4")
  }
}

fn do_import(b64 : String, name : String) -> Unit {
  bootstrap()
  let cmd = "add-image x=150 y=100 w=300 h=225 b64=\{b64} name=\{name}"
  let r = eng(cmd)
  if eng_ok(r) {
    js_log_line("📷 导入: \{name}", "#4a4")
    eng_render(800)
    refresh_ui()
  } else {
    js_log_line("❌ 导入失败", "#f66")
  }
}

async fn ai_turn() -> Unit {
  bootstrap()
  let req = js_val("ai-request")
  if req.trim(char_set=" \t").length() == 0 {
    js_log_line("⚠ 请输入需求", "#fa0")
    return
  }
  js_disabled("ai-run", true)
  errdefer js_disabled("ai-run", false)
  let provider = js_val("ai-provider")
  let base_in = js_val("ai-baseurl")
  let model_in = js_val("ai-model")
  let key = js_val("ai-key")
  let cfg : LlmConfig = {
    provider,
    base_url: if base_in != "" { base_in } else { preset_base_url(provider) },
    model: if model_in != "" {
      model_in
    } else {
      match models_for(provider).get(0) {
        Some(m) => m.id
        None => ""
      }
    },
    api_key: key,
  }
  if cfg.provider != "mock" && (cfg.base_url == "" || cfg.api_key == "") {
    js_log_line("⚠ 真实端点需要 Base URL + API Key", "#fa0")
    return
  }
  js_log_line("── AI 回合 (\{cfg.provider}:\{cfg.model}) ──", "#6af")
  let summary = run_edit_turn(
    req,
    cfg,
    log=fn(line) {
      let c = if line.has_prefix("🔧") || line.has_prefix("🛠") {
        "#8af"
      } else if line.has_prefix("✅") {
        "#4a4"
      } else if line.has_prefix("❌") {
        "#f66"
      } else if line.has_prefix("🖼") {
        "#fa0"
      } else {
        ""
      }
      js_log_line(line, c)
    },
    on_image=fn(png) { js_canvas_img(png) },
  )
  js_log_line("💬 \{summary}", "#afa")
  refresh_ui()
}

fn inject_css() -> Unit {
  js_css(
    #|*{margin:0;padding:0;box-sizing:border-box}
    #|body{font-family:-apple-system,'Segoe UI','PingFang SC',sans-serif;background:#111;color:#bbb;font-size:13px;overflow:hidden;user-select:none}
    #|#app{display:grid;grid-template-rows:38px 1fr 24px auto;grid-template-columns:44px 1fr 250px;height:100vh}
    #|.topbar{grid-column:1/4;display:flex;align-items:center;background:#1e1e32;border-bottom:1px solid #333;padding:0 10px;gap:2px;z-index:100}
    #|.topbar .logo{font-weight:700;color:#7ab8ff;font-size:14px;margin-right:14px;pointer-events:none}
    #|.topbar button{background:none;color:#99a;border:1px solid transparent;border-radius:4px;padding:4px 10px;font-size:12px;cursor:pointer;white-space:nowrap}
    #|.topbar button:hover{background:#2a2a4e;color:#dde}
    #|.topbar .sep{width:1px;height:18px;background:#333;margin:0 4px}
    #|.topbar .pri{background:#3d63ff;color:#fff;font-weight:500}
    #|.topbar .pri:hover{background:#5a7fff}
    #|.tools{background:#1e1e32;border-right:1px solid #333;display:flex;flex-direction:column;align-items:center;padding:6px 0;gap:2px}
    #|.tools .t{width:34px;height:34px;display:flex;align-items:center;justify-content:center;border-radius:6px;cursor:pointer;font-size:15px;color:#778;transition:background .12s}
    #|.tools .t:hover{background:#2a2a4e;color:#ccd}
    #|.tools .t.on{background:#3d63ff;color:#fff}
    #|.tools .ts{width:26px;height:1px;background:#333;margin:4px 0}
    #|.carea{background:#2a2a3e;display:flex;align-items:center;justify-content:center;overflow:auto;position:relative}
    #|.cwrap{border:1px solid #444;box-shadow:0 4px 24px #0008;background:repeating-conic-gradient(#3a3a4e 0% 25%,#2a2a3e 0% 50%) 0 0/16px 16px;transition:border-color .15s}
    #|.cwrap.dragover{border-color:#4a7cff;border-width:2px}
    #|#canvas-img{display:block;max-width:100%;max-height:75vh}
    #|.rpanel{background:#1e1e32;border-left:1px solid #333;display:flex;flex-direction:column;overflow:hidden}
    #|.ph{padding:7px 10px;font-size:10px;font-weight:600;color:#667;text-transform:uppercase;letter-spacing:.8px;border-bottom:1px solid #2a2a4e;user-select:none}
    #|#llist{flex:1;overflow-y:auto;min-height:80px}
    #|.li{display:flex;align-items:center;padding:5px 8px;cursor:pointer;border-bottom:1px solid #1e2340;gap:6px;font-size:12px;transition:background .1s}
    #|.li:hover{background:#22284a}
    #|.li.sel{background:#2a3a6e;border-left:2px solid #4a7cff}
    #|.li .eye{cursor:pointer;font-size:13px;width:20px;text-align:center;flex-shrink:0}
    #|.li .ico{width:18px;text-align:center;font-size:11px;color:#688;flex-shrink:0}
    #|.li .lnm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#bcc}
    #|.li .lkd{font-size:9px;color:#556;text-transform:uppercase}
    #|.ph2{padding:7px 10px;font-size:10px;font-weight:600;color:#667;text-transform:uppercase;letter-spacing:.8px;border-top:1px solid #2a2a4e;border-bottom:1px solid #2a2a4e}
    #|#pprops{padding:8px;max-height:220px;overflow-y:auto}
    #|.pg{display:grid;grid-template-columns:52px 1fr;gap:2px 6px;font-size:11px}
    #|.pk{color:#567;text-align:right}
    #|.pv{color:#99a;user-select:text}
    #|.ns{color:#456;font-size:11px;text-align:center;padding:14px}
    #|.pact{margin-top:8px;display:flex;gap:4px}
    #|.pact button{flex:1;background:#2a2a4e;color:#89a;border:0;border-radius:4px;padding:4px;font-size:11px;cursor:pointer}
    #|.pact button:hover{background:#3a3a5e;color:#dde}
    #|.sbar{grid-column:1/4;display:flex;align-items:center;background:#1e1e32;border-top:1px solid #333;padding:0 12px;font-size:11px;color:#567;gap:14px}
    #|.aip{grid-column:1/4;background:#12142a;border-top:1px solid #333;display:flex;flex-direction:column;max-height:280px;transition:max-height .2s}
    #|.aip.closed{max-height:36px;overflow:hidden}
    #|.aihead{display:flex;align-items:center;justify-content:space-between;padding:8px 14px;cursor:pointer;user-select:none}
    #|.aihead span{font-size:12px;font-weight:600;color:#7ab8ff}
    #|.aihead .tg{font-size:14px;color:#567;transition:transform .2s}
    #|.aibody{padding:6px 14px 10px;display:flex;flex-direction:column;gap:5px}
    #|.aicfg{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
    #|.aicfg select,.aicfg input{background:#0d1020;color:#99a;border:1px solid #2a2a4e;border-radius:4px;padding:4px 6px;font-size:11px}
    #|.aicfg select{width:150px}
    #|.aicfg input{flex:1;min-width:80px}
    #|.aireq{display:flex;gap:6px}
    #|.aireq input{flex:1;background:#0d1020;color:#ccc;border:1px solid #3a3a5e;border-radius:6px;padding:8px 12px;font-size:13px}
    #|.aireq button{background:#3d63ff;color:#fff;border:0;border-radius:6px;padding:8px 18px;font-size:13px;cursor:pointer;font-weight:500}
    #|.aireq button:disabled{opacity:.4}
    #|.aireq button:hover:not(:disabled){background:#5a7fff}
    #|#ailog{height:110px;overflow-y:auto;background:#0d1020;border-radius:6px;border:1px solid #1e2340}
  )
}

fn inject_html() -> Unit {
  js_html(
    "app",
    (
      #|<div class='topbar'>
      #|<span class='logo'>🎨 MoonPainter</span>
      #|<button onclick='globalThis.__new()'>新建</button>
      #|<button onclick="document.getElementById('file-in').click()">📷 导入</button>
      #|<span class='sep'></span>
      #|<button onclick='globalThis.__undo()'>↩ 撤销</button>
      #|<button onclick='globalThis.__redo()'>↪ 重做</button>
      #|<span class='sep'></span>
      #|<button onclick='globalThis.__save()'>💾 保存</button>
      #|<button onclick='globalThis.__export()'>🖼 导出</button>
      #|<span class='sep'></span>
      #|<button class='pri' onclick='globalThis.__toggle_ai()'>🤖 AI 修图</button>
      #|</div>
      #|<div class='tools'>
      #|<div class='t on' title='移动'>🖐</div>
      #|<div class='t' title='矩形'>□</div>
      #|<div class='t' title='椭圆'>◯</div>
      #|<div class='t' title='线段'>╱</div>
      #|<div class='t' title='文本'>T</div>
      #|<div class='ts'></div>
      #|<div class='t' title='统计' onclick='globalThis.__stats()'>📊</div>
      #|<div class='ts'></div>
      #|<div class='t' title='导入' onclick="document.getElementById('file-in').click()">📷</div>
      #|</div>
      #|<div class='carea'>
      #|<div class='cwrap' id='drop-zone'><img id='canvas-img' alt='画布'/></div>
      #|</div>
      #|<div class='rpanel'>
      #|<div class='ph'>图层</div>
      #|<div id='llist'></div>
      #|<div class='ph2'>属性</div>
      #|<div id='pprops'><div class='ns'>点击图层查看属性</div></div>
      #|</div>
      #|<div class='sbar'><span id='sbar-text'>就绪</span></div>
      #|<div class='aip' id='ai-panel'>
      #|<div class='aihead' onclick='globalThis.__toggle_ai()'>
      #|<span>🤖 AI 修图 — 人类提需求，AI 逐工具操作，全程可见</span>
      #|<span class='tg' id='ai-arrow'>▼</span>
      #|</div>
      #|<div class='aibody'>
      #|<div class='aicfg'>
      #|<select id='ai-provider'></select>
      #|<input id='ai-baseurl' placeholder='Base URL'/>
      #|<input id='ai-model' placeholder='模型 ID'/>
      #|<input id='ai-key' type='password' placeholder='API Key' style='max-width:150px'/>
      #|</div>
      #|<div class='aireq'>
      #|<input id='ai-request' placeholder='描述你的修图需求…' value='在右上角加一个渐变圆形徽章'/>
      #|<button id='ai-run'>🤖 执行</button>
      #|</div>
      #|<div id='ailog'></div>
      #|</div>
      #|</div>
      #|<input type='file' id='file-in' accept='image/*' style='display:none' onchange='globalThis.__file_sel()'/>
    ),
  )
  for p in provider_presets() {
    js_add_opt("ai-provider", p.id, p.name)
  }
}

async fn on_file_selected() -> Unit {
  bootstrap()
  let result = js_read_file_input("file-in").wait()
  let ok = match json_get(result, "ok") {
    Some(Json::True) => true
    _ => false
  }
  if ok {
    let b64 = match json_get(result, "b64") {
      Some(Json::String(s)) => s
      _ => ""
    }
    let name = match json_get(result, "name") {
      Some(Json::String(s)) => s
      _ => "image"
    }
    if b64 != "" {
      do_import(b64, name)
    }
  } else {
    let err = match json_get(result, "error") {
      Some(Json::String(s)) => s
      _ => "?"
    }
    js_log_line("⚠ 文件读取失败: \{err}", "#f66")
  }
}

fn register_globals() -> Unit {
  js_reg0("__run", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { ai_turn() }) })
  js_reg0("__save", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { do_save() }) })
  js_reg0("__export", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { do_export() }) })
  js_reg0("__file_sel", fn() -> @js_async.Promise[Unit] { @js_async.Promise::from_async(async fn() { on_file_selected() }) })
  js_reg1("__sel", fn(id : String) { do_sel(id) })
  js_reg1("__vis", fn(id : String) { do_vis(id) })
  js_reg1("__del", fn(id : String) { do_del(id) })
  js_reg1("__dup", fn(id : String) { do_dup(id) })
  js_reg1("__undo", fn(_ : String) { do_undo() })
  js_reg1("__redo", fn(_ : String) { do_redo() })
  js_reg1("__new", fn(_ : String) { do_new() })
  js_reg1("__save_sync", fn(_ : String) { do_save() })
  js_reg1("__export_sync", fn(_ : String) { do_export() })
  js_reg1("__stats", fn(_ : String) {
    let s = eng("stats")
    js_log_line("📊 \{s.stringify()}", "#8af")
  })
  js_reg1("__lint", fn(_ : String) {
    let l = eng("lint")
    js_log_line("📏 \{l.stringify()}", "#8af")
  })
  js_reg2s("__drop", fn(b64 : String, name : String) { do_import(b64, name) })
}

async fn main {
  if js_is_node() {
    let lines : Ref[Array[String]] = Ref([])
    let mut images = 0
    let summary = run_edit_turn(
      "在右上角加一个渐变圆形徽章",
      { provider: "mock", base_url: "", model: "mock-script", api_key: "" },
      log=fn(line) { lines.val.push(line) },
      on_image=fn(_png) { images = images + 1 },
    )
    let mut tc = 0
    let mut tok = 0
    for l in lines.val {
      if l.contains("🔧 执行") {
        tc = tc + 1
      }
      if l.contains("✅") {
        tok = tok + 1
      }
    }
    let sv = engine_exec_line("save-mpd-b64")
    let saved = match json_get(parse_json_safe(sv), "mpd_b64") {
      Some(Json::String(s)) => s.length() > 0
      _ => false
    }
    let esc_summary = @core.json_escape(summary)
    let arr : Array[Json] = []
    for l in lines.val {
      arr.push(Json::string(l))
    }
    let log_str = Json::array(arr).stringify()
    println(
      "{\"headless_selftest\":true,\"tool_calls\":\{tc},\"tool_ok\":\{tok},\"renders\":\{images},\"saved_mpd\":\{saved},\"summary\":\"\{esc_summary}\",\"log\":\{log_str}}",
    )
  } else {
    ensure_engine()
    inject_css()
    inject_html()
    register_globals()
    js_click_global("ai-run", "__run")
    js_setup_drop("drop-zone", "__drop")
    bootstrap()
    js_status_bar("就绪 — Mock 端点离线可演示；接真实模型选端点填 Key")
    js_log_line("🎨 MoonPainter 就绪。输入需求点「执行」，或拖拽图片到画布导入。", "#6af")
  }
}
