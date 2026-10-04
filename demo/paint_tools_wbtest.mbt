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

///|
test "调整层两条工具行：参数键表**一处**，没给的键一个都不许拼（尤其 value）" {
  // 此前 `apply_filter` 无条件拼 `value=0.5`：`op=levels` 会被引擎拒
  // （"不接受 value="）——而模型并不知道自己多发了一个键。曲线同理。
  assert_eq(
    tool_line("apply_filter", parse_json_safe("{\"op\":\"levels\"}")),
    "add-adjust op=levels",
    msg="没给任何参数时不许凭空塞 value=",
  )
  assert_eq(
    tool_line("apply_filter", parse_json_safe("{\"op\":\"levels\",\"gamma\":2,\"in_lo\":0.2}")),
    "add-adjust op=levels in_lo=0.2 gamma=2",
    msg="给了的键按键表顺序原样拼",
  )
  assert_eq(
    tool_line(
      "apply_filter",
      parse_json_safe("{\"op\":\"curves\",\"points\":\"0,0;0.5,0.75;1,1\"}"),
    ),
    "add-adjust op=curves points=0,0;0.5,0.75;1,1",
    msg="曲线的点表要原样发过去（分号/逗号都是引擎的语法）",
  )
  // 数值类算子的老路径不许被这次改动弄坏
  assert_eq(
    tool_line("apply_filter", parse_json_safe("{\"op\":\"blur\",\"value\":0.4}")),
    "add-adjust op=blur value=0.4",
    msg="数值类算子照旧",
  )
  // set_adjust：只给 gamma 就只发 gamma（其余由引擎沿用当前值）
  assert_eq(
    tool_line("set_adjust", parse_json_safe("{\"id\":\"a1\",\"gamma\":1.4}")),
    "set-adjust a1 gamma=1.4",
    msg="色阶只改一格时不许把别的键也发过去",
  )
  assert_eq(
    tool_line("set_adjust", parse_json_safe("{\"id\":\"a1\",\"op\":\"levels\",\"value\":0.5}")),
    "set-adjust a1 op=levels value=0.5",
    msg="两族混发是引擎的事（它会拒），工具行只负责原样转达",
  )
}
