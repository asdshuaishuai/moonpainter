/// demo e2e（js/Node）：mock 模型 × 真实 wasm 引擎的完整修图回合。
/// 单一串行测试（引擎 wasm 会话是实例级全局状态）：
/// 断言 vision 闸、多轮工具调用全程可见、渲染 PNG 附件回传、
/// 指纹变化、容器保存、换色回合 + undo 生效。

///|
async test "AI 修图端到端：mock 模型 × wasm 引擎 × 全程可见 × undo" {
  // 加载引擎 + 版本信封
  @demo.ensure_engine()
  let version = @demo.engine_version_json()
  assert_true(version.contains("\"engine\":\"moonpainter\""), msg=version)
  let log_lines : Ref[Array[String]] = Ref([])
  let mut renders = 0
  // ── 回合 1：徽章（3 轮工具调用，第 3 轮渲染）──
  let summary = @demo.run_edit_turn(
    "在右上角加一个渐变圆形徽章",
    {
      provider: "mock",
      base_url: "",
      model: "mock-script",
      api_key: "",
    },
    log=fn(line) { log_lines.val.push(line) },
    on_image=fn(_png) { renders = renders + 1 },
  )
  // 1) 全程可见：初始化 + 回合事件 + AI 思考 + 工具执行逐条流过
  assert_true(log_lines.val.length() >= 12, msg="日志行过少：\{log_lines.val.length()}")
  assert_true(log_lines.val[0].contains("初始化引擎"), msg=log_lines.val[0])
  let mut think = 0
  let mut tool_started = 0
  let mut tool_ok = 0
  let mut render_previews = 0
  for l in log_lines.val {
    if l.contains("🤔 AI：") {
      think = think + 1
    }
    if l.contains("🔧 执行") {
      tool_started = tool_started + 1
    }
    if l.contains("✅") {
      tool_ok = tool_ok + 1
    }
    if l.contains("渲染预览已更新") {
      render_previews = render_previews + 1
    }
  }
  assert_true(think >= 3, msg="AI 思考轮次过少: \{think}")
  assert_true(tool_started >= 3, msg="工具调用过少: \{tool_started}")
  assert_eq(tool_ok, tool_started)
  // 2) 视觉闭环：render 工具的 PNG 以附件流经事件并更新预览
  assert_true(renders >= 1, msg="渲染预览缺失: \{renders}")
  assert_eq(render_previews, 1, msg="回合 1 渲染日志行数")
  assert_eq(renders, 1, msg="回合 1 渲染附件数")
  // 3) 引擎真的被修改：指纹信封存在
  let fingerprint = @demo.engine_exec_line("fingerprint")
  assert_true(fingerprint.contains("\"fingerprint\":\""), msg=fingerprint)
  // 4) 容器可保存
  let saved = @demo.engine_exec_line("save-mpd-b64")
  assert_true(saved.contains("\"mpd_b64\":\""), msg=saved)
  assert_true(summary.contains("徽章"), msg=summary)
  assert_eq(render_previews, 1, msg="回合 1 渲染日志行数")
  assert_eq(renders, 1, msg="回合 1 渲染附件数")
  // ── 回合 2：换色（同会话继续；set_style 真实生效）──
  let fp_before = @demo.engine_exec_line("fingerprint")
  let _ = @demo.run_edit_turn(
    "把背景换成冷色调",
    {
      provider: "mock",
      base_url: "",
      model: "mock-script",
      api_key: "",
    },
    log=fn(line) { log_lines.val.push(line) },
    on_image=fn(_png) { renders = renders + 1 },
  )
  let fp_cold = @demo.engine_exec_line("fingerprint")
  assert_true(fp_cold != fp_before, msg="换色回合应改变文档")
  // 5) undo：撤销 set_style 后指纹复原
  let undone = @demo.engine_exec_line("undo")
  assert_true(undone.contains("\"op\":\"undo\""), msg=undone)
  let fp_undo = @demo.engine_exec_line("fingerprint")
  assert_true(fp_undo != fp_cold, msg="undo 后指纹应变化")
  // 5b) redo：人类前端一直有「↪ 重做」按钮（main.mbt 的 __redo），
  //     工具面却只有 undo —— AI 撤销过头就回不去。锁住两侧能力对称，
  //     并验证 redo 真的把文档带回 set_style 之后的状态。
  let names = @demo.paint_tool_names()
  assert_true(names.contains("undo"), msg="工具面缺 undo")
  assert_true(names.contains("redo"), msg="工具面缺 redo（前端有按钮，AI 没有）")
  // 更强的断言：**每个注册的工具都必须接得上引擎命令行**。`undo` 正是栽在
  // 这里——它注册了很久，但 execute 的命令名映射（cmd）里没有它，而 cmd
  // 先于参数拼接求值，于是 AI 每次调 undo 都只拿到"未知工具 undo"。
  // 人类前端有「↩ 撤销」按钮、测试又都直接 engine_exec_line，所以一直没暴露。
  let bad = @demo.undispatched_tools()
  assert_eq(
    bad.length(),
    0,
    msg="有工具注册了却接不上引擎命令行：\{bad.join("、")}",
  )
  let redone = @demo.engine_exec_line("redo")
  assert_true(redone.contains("\"op\":\"redo\""), msg=redone)
  assert_eq(
    @demo.engine_exec_line("fingerprint"),
    fp_cold,
    msg="redo 后应回到 set_style 之后的状态",
  )
  // ── 回合 3：MVSL 精准改色闭环（普查 → 试选 → 装编辑表 → 影响/断言 → 渲染）──
  // 这条回合证明**产品里的 AI 能真的用到编辑引擎**：工具面可达、图像类
  // 回包走附件（试选覆盖图与结果图都要让模型真的看到）、编辑表进了渲染管线。
  let _ = @demo.engine_exec_line("mvsl-clear")
  let renders_before = renders
  let log_before = log_lines.val.length()
  let summary3 = @demo.run_edit_turn(
    "帮我把这张图精准调暖一点",
    {
      provider: "mock",
      base_url: "",
      model: "mock-script",
      api_key: "",
    },
    log=fn(line) { log_lines.val.push(line) },
    on_image=fn(_png) { renders = renders + 1 },
  )
  let mut mvsl_tools = 0
  let mut lint_calls = 0
  for i = log_before; i < log_lines.val.length(); i = i + 1 {
    let l = log_lines.val[i]
    if l.contains("sel_schema") ||
      l.contains("census") ||
      l.contains("select_preview") ||
      l.contains("mvsl_set") ||
      l.contains("mvsl_impact") ||
      l.contains("mvsl_assert") {
      mvsl_tools = mvsl_tools + 1
    }
    // lint 必须在 MVSL 回合里被调到：它是唯一会报出「装了表却什么都没改」
    // 与「保护断言被违反」的命令
    if l.contains("lint") {
      lint_calls = lint_calls + 1
    }
  }
  assert_true(mvsl_tools >= 6, msg="MVSL 工具调用过少：\{mvsl_tools}")
  assert_true(lint_calls >= 1, msg="MVSL 回合未调 lint（收工检查缺失）")
  // 图像附件：试选覆盖图 + 影响结果图 + 渲染 = 3 次
  assert_eq(renders - renders_before, 3, msg="MVSL 回合的图像附件数")
  // 编辑表真的装上了，且进了渲染管线
  let shown = @demo.engine_exec_line("mvsl-show")
  assert_true(shown.contains("\"ops\":1"), msg=shown)
  let fp_edited = @demo.engine_exec_line("fingerprint")
  let _ = fp_edited
  let impact = @demo.engine_exec_line("mvsl-impact")
  // 精确取值：子串匹配 `"leak_ratio":0` 会被 `0.0279` 这样的值骗过
  assert_true(impact.contains("\"leak_ratio\":0}"), msg=impact)
  assert_true(summary3.contains("精准改色"), msg=summary3)
  // 清空编辑表 → 渲染回到未编辑状态
  let cleared = @demo.engine_exec_line("mvsl-clear")
  assert_true(cleared.contains("\"ops\":0"), msg=cleared)
  // ── 回合 4：文字 + 可见性（前端有按钮，AI 工具面此前够不着）──
  // 和 redo 一样的不对称：前端一直有「加文字」与「👁 可见性」按钮，引擎也有
  // add-text/visible 命令，但工具面没有对应工具。补上后要验证的是**行为**，
  // 不只是"接得上"——所以这里让文字**带空格**：那正是"下划线代替空格"
  // 从未实现时会静默出错的地方（会存成 Hello_MoonPainter）。
  let _ = @demo.engine_exec_line("new 320 200")
  let renders_before4 = renders
  let summary4 = @demo.run_edit_turn(
    "给这张图加个文字标题",
    {
      provider: "mock",
      base_url: "",
      model: "mock-script",
      api_key: "",
    },
    log=fn(line) { log_lines.val.push(line) },
    on_image=fn(_png) { renders = renders + 1 },
  )
  let t1 = @demo.engine_exec_line("query-layer l1")
  assert_true(
    t1.contains("\"text\":\"Hello MoonPainter\""),
    msg="含空格的文字没有原样进文档（分词或工具拼串有问题）：\{t1}",
  )
  // 回合里的第二步把 l1 切成不可见
  assert_true(t1.contains("\"visible\":false"), msg="visible 工具未生效：\{t1}")
  assert_eq(renders - renders_before4, 1, msg="文字回合的图像附件数")
  assert_true(summary4.contains("标题"), msg=summary4)
}

///|
test "工具面的第二张表：tool_line 真的拼得出命令行（含自由文本引号）" {
  // "注册了工具"与"接得上引擎命令行"是两件事，而且是**两张手写表**。
  // `undispatched_tools()` 守的是第一张（工具名 → 命令名）；这张（参数 →
  // 完整命令行）此前藏在 `execute` 内部，两条测试路径都照不到它——
  // `engine_exec_line` 直接调引擎、**绕过**参数拼接。提取成纯函数后，
  // 这里可以直接喂参数进来断言拼出的那一行。
  let empty : Json = Json::object(Map::from_array([]))
  assert_eq(@demo.tool_line("edits", empty), "edits")
  assert_eq(
    @demo.tool_line(
      "set_canvas",
      Json::object(
        Map::from_array([("w", Json::number(64.0)), ("h", Json::number(48.0))]),
      ),
    ),
    "set-canvas 64 48",
  )
  // 自由文本必须走引号：名字含空格时裸拼会把它切成两个 token
  assert_eq(
    @demo.tool_line(
      "rename",
      Json::object(
        Map::from_array([
          ("id", Json::string("l1")),
          ("new_name", Json::string("背景 层")),
        ]),
      ),
    ),
    "rename l1 \"背景 层\"",
  )
  // 顺手钉住一个老工具，证明这张表整体在用（也证明这条测试真的会红——
  // 第一版我把工具名猜成了 resolve_color，它当场失败）
  assert_eq(
    @demo.tool_line(
      "sample_color",
      Json::object(
        Map::from_array([("x", Json::number(8.0)), ("y", Json::number(8.0))]),
      ),
    ),
    "sample 8 8",
  )
}

///|
/// 抠出 `s` 里所有 `prefix` 之后、`stop` 之前的那一段。
/// 用于从 HTML 里取 `globalThis.__x` 的名字与 `getElementById('y')` 的 id。
fn collect_between(s : String, prefix : String, stop : String) -> Array[String] {
  let out : Array[String] = []
  let mut from = 0
  while from < s.length() {
    let rest = s[from:].to_owned()
    let i = match rest.find(prefix) {
      Some(i) => i
      None => break
    }
    let after = rest[i + prefix.length():].to_owned()
    let j = match after.find(stop) {
      Some(j) => j
      None => break
    }
    out.push(after[:j].to_owned())
    from = from + i + prefix.length() + j
  }
  out
}

///|
test "页面接线：HTML 引用的处理器都注册了，getElementById 的 id 都在同一份 HTML 里" {
  // 这类断链以前只有"在浏览器里点一下"才能发现，而走不到那条路的人就永远
  // 发现不了——仓库里 `undo`（工具面无映射）与蒙版 UI 都栽过这个形状。
  // 点击的**视觉语义**仍然只能人工看，但"按钮背后有没有那个函数""那个 id
  // 存不存在"是可以机器验的，而且正是最容易断的两处。
  let html = @demo.app_html()
  assert_true(html.length() > 2000, msg="HTML 不像页面骨架，长度 \{html.length()}")
  // 1) 事件处理器必须真的挂在 globalThis 上
  @demo.register_globals()
  let handlers = collect_between(html, "globalThis.__", "(")
  assert_true(
    handlers.length() > 20,
    msg="只抠到 \{handlers.length()} 个处理器，扫描大概坏了（应远多于 20）",
  )
  let missing : Array[String] = []
  for h in handlers {
    if !@demo.js_global_is_fn("__" + h) {
      missing.push(h)
    }
  }
  assert_eq(
    missing.length(),
    0,
    msg="HTML 引用了没注册的处理器（点了就是 JS 报错）：\{missing.join("、")}",
  )
  // 2) getElementById 的 id 必须在同一份 HTML 里存在（两种引号都要扫）
  let ids : Array[String] = []
  ids.append(collect_between(html, "getElementById('", "'"))
  ids.append(collect_between(html, "getElementById(\"", "\""))
  assert_true(ids.length() > 0, msg="没抠到任何 getElementById，扫描大概坏了")
  let no_el : Array[String] = []
  for i in ids {
    if !html.contains("id='" + i + "'") {
      no_el.push(i)
    }
  }
  assert_eq(
    no_el.length(),
    0,
    msg="HTML 里 getElementById 指向了不存在的 id：\{no_el.join("、")}",
  )
}
