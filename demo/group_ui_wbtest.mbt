// 白盒测试：人类侧分组 UI 的三个纯辅助（属性面板的「父级」下拉要用它们）。
//
// 为什么是白盒：这三个函数只服务面板拼 HTML，是包内私有的；而"父级"这个事实
// **只有它们能回读**——`query-layer` 不报父级，`list-layers` 的嵌套树得自己走。
// 走错了的表现是静默的：下拉显示"根级"而实际在某个组里，用户一点就把层从组里
// 摘出来（或反过来），画面跟着变。

///|
test "分组 UI：父级查找 / 根级组清单 / 新组 id 不撞车" {
  // 手搭一棵树：根级 [l1, g1(children:[c1, g2(children:[n1])]), g9]
  // —— 嵌套组引擎建不出来，但手改容器可能有，查找要照样认（"判据的空集也要说话"）。
  let tree = parse_json_safe(
    "{\"layers\":[{\"id\":\"l1\",\"name\":\"底\",\"kind\":\"rect\"},{\"id\":\"g1\",\"name\":\"组一\",\"kind\":\"group\",\"children\":[{\"id\":\"c1\",\"name\":\"c1\",\"kind\":\"rect\"},{\"id\":\"g2\",\"name\":\"组二\",\"kind\":\"group\",\"children\":[{\"id\":\"n1\",\"name\":\"n1\",\"kind\":\"rect\"}]}]},{\"id\":\"g9\",\"name\":\"空组\",\"kind\":\"group\"}]}",
  )
  let layers = match json_get(tree, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  assert_eq(layers.length(), 3)
  // 根级层 → `Some("")`；**必须与"找不到"（None）区分开**——下拉要据此
  // 决定显示"根级"还是什么都不显示（回到根级的动作要有东西可回读）。
  assert_eq(parent_group_of(layers, "l1", "").unwrap_or("?"), "")
  assert_eq(parent_group_of(layers, "c1", "").unwrap_or("?"), "g1")
  assert_eq(parent_group_of(layers, "n1", "").unwrap_or("?"), "g2")
  assert_eq(parent_group_of(layers, "nope", ""), None)
  // 下拉只列**根级**组：g2 是嵌套的，不该出现在候选里（`group-add` 拒非根级组，
  // 列出来只会让人点出一个错误）
  let gs = root_groups(layers)
  assert_eq(gs.length(), 2)
  assert_eq(gs[0].0, "g1")
  assert_eq(gs[0].1, "组一")
  assert_eq(gs[1].0, "g9")
  // 新组 id 取第一个没占用的：g1/g2 都被占（一个根级、一个嵌套），所以是 g3
  assert_eq(fresh_group_id(layers), "g3")
  let empty = match json_get(parse_json_safe("{\"layers\":[]}"), "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  assert_eq(fresh_group_id(empty), "g1")
}

///|
test "空组标识：最后一个成员被移走之后列表里看得见（lint 会报，人类看不到 lint）" {
  // 这条判据原本写在图层列表的拼 HTML 里，顺手提成了纯函数：`group-remove`
  // 把最后一个成员移走之后组会**留在原地**（引擎不替你删），而 lint 会把它算作
  // "装了却什么都不干"。人类侧看不到 lint，所以列表上必须标出来。
  let g = parse_json_safe("{\"id\":\"g1\",\"kind\":\"group\"}")
  let g0 = parse_json_safe("{\"id\":\"g1\",\"kind\":\"group\",\"children\":[]}")
  let g1 = parse_json_safe(
    "{\"id\":\"g1\",\"kind\":\"group\",\"children\":[{\"id\":\"a\",\"kind\":\"rect\"}]}",
  )
  let rect = parse_json_safe("{\"id\":\"r1\",\"kind\":\"rect\",\"children\":[]}")
  assert_true(is_empty_group(g), msg="没有 children 的组 = 空组")
  assert_true(is_empty_group(g0), msg="children 为空的组 = 空组")
  assert_false(is_empty_group(g1), msg="有成员的组不是空组")
  assert_false(is_empty_group(rect), msg="非组层不是空组（判据不许比渲染器松）")
}
