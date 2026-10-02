// 白盒测试：**动态拼出来的**面板 HTML（图层列表 + 属性面板）。
//
// 为什么要把它提成纯函数再测（`layers_html` / `props_html`）：这两段 HTML 原先
// 长在 `refresh_ui` / `refresh_props` 里，只有浏览器点开某个图层才生成，
// `demo_test` 拿不到（它拿的是静态骨架 `app_html()`）。`build_demo.sh#html-wiring`
// 用源码级 grep 补了"引用的处理器有没有注册"这一半，但 grep 只能证明**写过**，
// 证明不了"拼出来的 HTML 里真的有"——一个 `if` 分支写错、或者名字拼错一个字母，
// grep 照样绿（它扫的是源码里所有字符串，包括那张从不执行的分支）。
//
// 于是判据分两侧咬：
//   ① **拼得出来**（这条测试）：该出现的处理器与选项必须真的在返回的 HTML 里；
//   ② **引用都已注册**（`build_demo.sh#html-wiring`）：HTML 里出现的 `globalThis.__x`
//      必须都能在 `js_reg*` 里找到——两条合起来才不会"点了没反应"或"永远不出现"。

///|
fn has_sub(h : String, sub : String) -> Bool {
  h.find(sub) is Some(_)
}

///|
/// 「不该出现」的判据单列一处：`!(has_sub(...))` 这种嵌套否定在多行断言里
/// 括号很容易配错（第一版就配错了），一个具名函数读起来也不容易看反。
fn lacks_sub(h : String, sub : String) -> Bool {
  !(h.find(sub) is Some(_))
}

///|
fn panel_layers() -> Array[Json] {
  match json_get(
    parse_json_safe(
      "{\"layers\":[{\"id\":\"l1\",\"name\":\"底\",\"kind\":\"rect\",\"visible\":true},{\"id\":\"g1\",\"name\":\"组一\",\"kind\":\"group\",\"children\":[{\"id\":\"c1\",\"name\":\"c1\",\"kind\":\"rect\"}]},{\"id\":\"g9\",\"name\":\"空组\",\"kind\":\"group\",\"children\":[]}]}",
    ),
    "layers",
  ) {
    Some(Json::Array(a)) => a
    _ => []
  }
}

///|
test "属性面板：组给「解组」、非组给「编组」+「父级」下拉（两个方向都有入口）" {
  let roots = panel_layers()
  // 组：只能解组（组不能再被编组——引擎侧 `group-add` 拒组当成员）
  let g = parse_json_safe(
    "{\"id\":\"g1\",\"name\":\"组一\",\"kind\":\"group\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\"}",
  )
  let hg = props_html(g, roots)
  assert_true(has_sub(hg, "globalThis.__ungroup_sel(\"g1\")"), msg=hg)
  assert_true(lacks_sub(hg, "__group_sel"), msg="组不该再有「编组」按钮：\{hg}")
  assert_true(lacks_sub(hg, "__reparent"), msg="组没有父级下拉（不支持嵌套编组）：\{hg}")
  // 非组、且在根级：给「编组」+ 父级下拉，且"根级"这一项是选中态
  let r = parse_json_safe(
    "{\"id\":\"l1\",\"name\":\"底\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\"}",
  )
  let hr = props_html(r, roots)
  assert_true(has_sub(hr, "globalThis.__group_sel(\"l1\")"), msg=hr)
  assert_true(has_sub(hr, "globalThis.__reparent(\"l1\",this.value)"), msg=hr)
  assert_true(has_sub(hr, "<option value='' selected>根级</option>"), msg=hr)
  assert_true(has_sub(hr, "<option value='g1'>g1 · 组一</option>"), msg=hr)
  // 嵌套的组（手改容器才造得出）不进候选：`group-add` 拒非根级组，
  // 列出来只会让人点出一个错误
  assert_true(lacks_sub(hr, "value='g2'"), msg=hr)
}

///|
test "属性面板：父级下拉如实回显当前所在组，嵌套时也显示真话" {
  let roots = panel_layers()
  // 在 g1 里的层：父级那项必须选中（否则用户以为它在根级，一点就把它摘出来）
  let c = parse_json_safe(
    "{\"id\":\"c1\",\"name\":\"c1\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\"}",
  )
  let hc = props_html(c, roots)
  assert_true(has_sub(hc, "<option value='g1' selected>g1 · 组一</option>"), msg=hc)
  assert_true(lacks_sub(hc, "<option value='' selected>"), msg="在组里就不该还把「根级」标成选中：\{hc}")
  // 嵌套层（手改容器造的）：父级不在根级组清单里，也要显示出来并标"嵌套"
  let nested = parse_json_safe(
    "{\"layers\":[{\"id\":\"g1\",\"name\":\"组一\",\"kind\":\"group\",\"children\":[{\"id\":\"g2\",\"name\":\"内层\",\"kind\":\"group\",\"children\":[{\"id\":\"n1\",\"name\":\"n1\",\"kind\":\"rect\"}]}]}]}",
  )
  let nroots = match json_get(nested, "layers") {
    Some(Json::Array(a)) => a
    _ => []
  }
  let n = parse_json_safe(
    "{\"id\":\"n1\",\"name\":\"n1\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\"}",
  )
  let hn = props_html(n, nroots)
  assert_true(has_sub(hn, "<option value='g2' selected>g2（嵌套）</option>"), msg=hn)
}

///|
test "图层列表：空组标「空」、选中态只落在被选中的那一层" {
  let h = layers_html(panel_layers(), "l1")
  // 三个层都在（列表是上层在前，这里只看出现与标识）
  assert_true(has_sub(h, ">底<"), msg=h)
  assert_true(has_sub(h, ">组一<"), msg=h)
  // 空组标记：`group-remove` 移走最后一个成员后组会留在原地，而 lint 会报它
  assert_true(has_sub(h, "title='空组：lint 会报「装了却什么都不干」'>空</span>"), msg=h)
  // 有成员的组不该被标成空（判据两头都要咬）
  let g_badge = match h.find(">组一</span>") {
    Some(i) => h[i : i + 60].to_owned()
    None => ""
  }
  assert_true(lacks_sub(g_badge, "空</span>"), msg="有成员的组被误标成空：\{g_badge}")
  // 选中态：只有 l1 那一条带 sel
  assert_true(has_sub(h, "class='li sel'"), msg=h)
  let sel_count = h.split("class='li sel'").length() - 1
  assert_true(sel_count == 1, msg="选中态出现 \{sel_count} 次（应该恰好 1）：\{h}")
}
