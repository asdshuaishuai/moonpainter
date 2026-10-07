// `adjust-spec`（②B）：调整算子**参数面**的机器接口——前端画控件、模型查范围
// 都读它，所以它的判据是"报出来的必须与 core 的表逐字一致"：
//   * 滤镜算子：键名/范围/中性值/整数标记**逐个**对（漂移一处就红）；
//   * 非滤镜算子：`params` 必须是空表（不是缺字段），`uses_value` 与 value 的
//     范围从 `adjust_bounds` 出（面板据此决定画不画数值格）；
//   * 未知算子 / 不认识的键：入口拒绝，报错要指路。

///|
/// `adjust-spec op=<name>` 的回包（一行 JSON）。
fn spec_of(name : String) -> String {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 20 20 uuid=spec-\{name}")
  run(s, "adjust-spec op=\{name}")
}

///|
test "adjust-spec：每个滤镜算子的键表与 core.filter_param_rows 逐字一致" {
  for op in @core.all_adjust_ops() {
    let name = @core.adjust_op_name(op)
    if !@core.is_filter_op(op) {
      continue
    }
    let r = spec_of(name)
    assert_true(!r.contains("error"), msg="\{name} 该有参数面：\{r}")
    let rows = @core.filter_param_rows(op)
    assert_eq(
      count_of(r, "\"key\":"),
      rows.length(),
      msg="\{name} 报出来的键数必须等于表里的行数",
    )
    for row in rows {
      assert_true(
        r.contains(
          "{\"key\":\"" +
          row.key +
          "\",\"lo\":" +
          @core.fmt_num(row.lo) +
          ",\"hi\":" +
          @core.fmt_num(row.hi) +
          ",\"neutral\":" +
          @core.fmt_num(row.neutral) +
          ",\"integral\":" +
          (if row.integral { "true" } else { "false" }) +
          ",",
        ),
        msg="\{name} 的 \{row.key} 必须在接口里逐字对上（范围/中性值/整数标记）：\{r}",
      )
    }
    // 非滤镜算子不该漏进 params
    assert_true(!r.contains("\"uses_value\":true"), msg="滤镜不该读 value：\{r}")
  }
}

///|
test "adjust-spec：非滤镜算子 params 为空、value 有无与范围从表出" {
  // 无值算子：`uses_value` false，但 params 仍是**空表**（不是缺字段）
  let inv = spec_of("invert")
  assert_true(inv.contains("\"op\":\"invert\",\"uses_value\":false,"), msg="invert 无数值：\{inv}")
  assert_true(inv.contains("\"params\":[]"), msg="无数值算子的 params 也要是空表：\{inv}")
  // 0..1 那族（blur/sharpen/smooth/whiten/vignette）
  let bl = spec_of("blur")
  assert_true(bl.contains("\"uses_value\":true,\"lo\":0,\"hi\":1,"), msg="blur 的范围是 0..1：\{bl}")
  // -1..1 那族
  let br = spec_of("brightness")
  assert_true(br.contains("\"uses_value\":true,\"lo\":-1,\"hi\":1,"), msg="brightness 的范围：\{br}")
}

///|
test "adjust-spec：不给 op 报全部（条数 == all_adjust_ops），未知 op / 不认识的键要拒" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 20 20 uuid=spec-all")
  let all = run(s, "adjust-spec")
  assert_true(!all.contains("error"), msg="不给 op 要报全部：\{all}")
  assert_eq(
    count_of(all, "\"op\":\""),
    @core.all_adjust_ops().length(),
    msg="报出来的算子数必须等于 all_adjust_ops（少一个就是漏报，多一个就是幽灵）",
  )
  // 每个算子的名字都得出现（不是只有条数对）
  for op in @core.all_adjust_ops() {
    assert_true(
      all.contains("\"op\":\"" + @core.adjust_op_name(op) + "\""),
      msg="\{@core.adjust_op_name(op)} 没被报出来",
    )
  }
  let bad = run(s, "adjust-spec op=nope")
  assert_true(bad.contains("未知调整算子"), msg="未知算子要拒：\{bad}")
  assert_true(bad.contains("brightness"), msg="拒的时候要指路（给可选清单）：\{bad}")
  let bad2 = run(s, "adjust-spec zzz=1")
  assert_true(bad2.contains("不认识的参数"), msg="不认识的键要拒：\{bad2}")
}

///|
/// 回包里某个子串出现了几次（判"键数"这种条数口径）。
fn count_of(text : String, needle : String) -> Int {
  let mut n = 0
  let mut i = 0
  while i + needle.length() <= text.length() {
    if text[i:i + needle.length()] == needle {
      n = n + 1
      i = i + needle.length()
    } else {
      i = i + 1
    }
  }
  n
}
