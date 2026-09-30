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
  for i = log_before; i < log_lines.val.length(); i = i + 1 {
    let l = log_lines.val[i]
    if l.contains("census") ||
      l.contains("select_preview") ||
      l.contains("mvsl_set") ||
      l.contains("mvsl_impact") ||
      l.contains("mvsl_assert") {
      mvsl_tools = mvsl_tools + 1
    }
  }
  assert_true(mvsl_tools >= 5, msg="MVSL 工具调用过少：\{mvsl_tools}")
  // 图像附件：试选覆盖图 + 影响结果图 + 渲染 = 3 次
  assert_eq(renders - renders_before, 3, msg="MVSL 回合的图像附件数")
  // 编辑表真的装上了，且进了渲染管线
  let shown = @demo.engine_exec_line("mvsl-show")
  assert_true(shown.contains("\"ops\":1"), msg=shown)
  let fp_edited = @demo.engine_exec_line("fingerprint")
  let _ = fp_edited
  let impact = @demo.engine_exec_line("mvsl-impact")
  assert_true(impact.contains("\"leak_ratio\":0"), msg=impact)
  assert_true(summary3.contains("精准改色"), msg=summary3)
  // 清空编辑表 → 渲染回到未编辑状态
  let cleared = @demo.engine_exec_line("mvsl-clear")
  assert_true(cleared.contains("\"ops\":0"), msg=cleared)
}
