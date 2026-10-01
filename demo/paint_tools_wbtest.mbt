// 白盒测试：直接调包内私有的 `paint_tool_defs` / `tool_cmd`。
//
// 为什么需要它：工具面到引擎命令的映射是**两张手写表**——`tool_cmd`
// （工具名 → 命令名）与 `tool_line` 的每个 match 臂（工具名 → 整行命令行）。
// `undispatched_tools()` 只查"臂在不在"，**不查两张表说的是不是同一条命令**：
// 把 `tool_cmd("move")` 改成 `Some("move-layer")`、而 match 臂里仍写
// `"move …"`，自检照样全绿，工具在**运行时**才炸——更糟的是"静默调到另一条
// 命令"：参数按 A 命令拼、名字却发给 B，画面上改的是别的东西。
//
// 默认臂（`add-*` 那一族）已经用 `"\{cmd} \{tail}"` 把两张表绑在一起了，
// 所以这里主要罩住**显式臂**：46 条各自又抄了一遍命令名。

///|
test "工具面两张表必须说同一条命令（tool_cmd ↔ tool_line 首词）" {
  let bad : Array[String] = []
  // 空对象 = 全部参数缺失；`arg_of` 对缺键返回空串，工具函数照样拼得出命令行，
  // 所以不需要为 52 个工具各造一份参数。
  let empty : Json = Json::object(Map::from_array([]))
  for t in paint_tool_defs() {
    let name = t.name.value
    match tool_cmd(name) {
      None => bad.push("\{name}：tool_cmd 不认识它")
      Some(c) => {
        let line = tool_line(name, empty)
        let head = match line.find(" ") {
          Some(i) => line[0:i]
          None => line
        }
        if head != c {
          bad.push("\{name}：tool_cmd 说 \{c}，tool_line 打出来的首词是 \{head}")
        }
      }
    }
  }
  assert_eq(
    bad.length(),
    0,
    msg="两张工具表说的不是同一条命令：\{bad.join("；")}",
  )
}

///|
test "正控：默认臂那一族（add-rect 等）走的是同一个 cmd 变量" {
  // 上面那条判据在"两张表都对"时不报；这条用**具体命令**证明它真的在比，
  // 而不是比了个空集（`paint_tool_defs` 万一变空，第一条会静默通过）。
  let empty : Json = Json::object(Map::from_array([]))
  assert_eq(tool_line("add_rect", empty).find("add-rect"), Some(0), msg="add_rect 应发给 add-rect")
  assert_eq(tool_line("move", empty).find("move"), Some(0), msg="move 应发给 move")
  assert_eq(
    tool_line("paint_stroke", empty).find("brush"),
    Some(0),
    msg="paint_stroke 应发给 brush（工具名与命令名本来就不同）",
  )
  assert_eq(
    tool_line("apply_filter", empty).find("add-adjust"),
    Some(0),
    msg="apply_filter 应发给 add-adjust",
  )
  // 工具数不为空（否则第一条测试是在空集上巡逻）
  assert_true(paint_tool_defs().length() >= 50, msg="工具面不该只剩这么几个")
}
