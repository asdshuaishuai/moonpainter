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
    "{\"id\":\"g1\",\"name\":\"组一\",\"kind\":\"group\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"opacity\",\"children\"]}",
  )
  let hg = props_html(g, roots)
  assert_true(has_sub(hg, "globalThis.__ungroup_sel(\"g1\")"), msg=hg)
  assert_true(lacks_sub(hg, "__group_sel"), msg="组不该再有「编组」按钮：\{hg}")
  assert_true(lacks_sub(hg, "__reparent"), msg="组没有父级下拉（不支持嵌套编组）：\{hg}")
  // 组的 x/y 与盒子都不读、旋转/翻转入口就拒、蒙版也不读 ⇒ 五个控件一个都不画
  for name in ["__setx", "__setw", "__rotate", "__flip", "__mask_invert"] {
    assert_true(lacks_sub(hg, name), msg="组不该有 \{name} 控件：\{hg}")
  }
  // 非组、且在根级：给「编组」+ 父级下拉，且"根级"这一项是选中态
  let r = parse_json_safe(
    "{\"id\":\"l1\",\"name\":\"底\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"move\",\"resize\",\"opacity\",\"rotate\",\"flip\",\"mask\"]}",
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

///|
test "属性面板：可改的属性都有入口（改名/坐标/尺寸/旋转/翻转/标签摘挂）" {
  // 这一批（rename / move / resize / rotate / flip / tag / untag）此前
  // **只有 AI 走得到**：人类想改个层名、挪 10 像素、把字放大，只能删了重加
  // （蒙版/标签/层序全丢，调整层还会被推到栈顶改变作用范围）。
  let roots = panel_layers()
  let r = parse_json_safe(
    "{\"id\":\"l1\",\"name\":\"底\",\"kind\":\"rect\",\"x\":10,\"y\":20,\"w\":30,\"h\":40,\"rot\":15,\"flip_h\":true,\"flip_v\":false,\"opacity\":1,\"blend\":\"normal\",\"tags\":[\"hero\",\"主体\"],\"caps\":[\"move\",\"resize\",\"opacity\",\"rotate\",\"flip\",\"mask\"]}",
  )
  let h = props_html(r, roots)
  for name in [
    "__rename", "__setx", "__sety", "__setw", "__seth", "__rotate", "__flip", "__tag_add",
  ] {
    assert_true(has_sub(h, "globalThis." + name + "("), msg="面板少了 \{name} 的入口：\{h}")
  }
  // 当前值必须回显（否则人一改就把别的分量写丢了：move/resize 是整对赋值）
  assert_true(has_sub(h, "value='10'"), msg=h)
  assert_true(has_sub(h, "value='40'"), msg=h)
  assert_true(has_sub(h, "value='15'"), msg=h)
  // 翻转按钮两个方向都在，各自带方向参数
  assert_true(has_sub(h, "globalThis.__flip(\"l1\",\"h\")"), msg=h)
  assert_true(has_sub(h, "globalThis.__flip(\"l1\",\"v\")"), msg=h)
  // 已有标签要看得见，而且**每个都能摘**（能打上就必须能摘下）
  assert_true(has_sub(h, "#hero"), msg=h)
  assert_true(has_sub(h, "globalThis.__tag_del(\"l1\",\"hero\")"), msg=h)
  assert_true(has_sub(h, "globalThis.__tag_del(\"l1\",\"主体\")"), msg=h)
  // 文字层/调整层专属的控件不许出现在矩形上
  assert_true(lacks_sub(h, "__text_set"), msg="矩形上出现了文字控件：\{h}")
  assert_true(lacks_sub(h, "__adj_op"), msg="矩形上出现了调整控件：\{h}")
}

///|
test "属性面板：文字层给内容+字号，调整层给算子+数值（各自专属）" {
  let roots = panel_layers()
  let t = parse_json_safe(
    "{\"id\":\"t1\",\"name\":\"标题\",\"kind\":\"text\",\"x\":0,\"y\":0,\"w\":40,\"h\":16,\"text\":\"你好\",\"font_size\":16,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"move\",\"opacity\",\"mask\",\"text\",\"font_size\"]}",
  )
  let ht = props_html(t, roots)
  assert_true(has_sub(ht, "globalThis.__text_set(\"t1\",this.value)"), msg=ht)
  assert_true(has_sub(ht, "globalThis.__text_font(\"t1\",this.value)"), msg=ht)
  assert_true(has_sub(ht, "value='你好'"), msg="文字内容没回显：\{ht}")
  assert_true(lacks_sub(ht, "__adj_op"), msg=ht)
  // caps 说没有的能力，**一个控件都不许画**（此前旋转/翻转对任何 kind 都画，
  // 人类点下去只换来状态栏里的引擎拒绝原话）：文本层读 x/y 与 text/font_size，
  // 但**不读**盒子与 rotation/flip（引擎侧 caps 逐格实测，见 PLAN 五十一）。
  assert_true(has_sub(ht, "globalThis.__setx("), msg="文本层的 x/y 是真的（字按 font_size 画在 x/y 上）：\{ht}")
  assert_true(lacks_sub(ht, "__setw"), msg="文本层不该有 W 输入框：\{ht}")
  assert_true(lacks_sub(ht, "__seth"), msg="文本层不该有 H 输入框：\{ht}")
  assert_true(lacks_sub(ht, "__rotate"), msg="文本层不该有旋转输入框：\{ht}")
  assert_true(lacks_sub(ht, "__flip"), msg="文本层不该有翻转按钮：\{ht}")
  assert_true(has_sub(ht, "globalThis.__op("), msg="文本层的 α 是真的（半透明字）：\{ht}")
  let a = parse_json_safe(
    "{\"id\":\"a1\",\"name\":\"调亮\",\"kind\":\"adjust\",\"adjust\":{\"op\":\"brightness\",\"value\":0.25},\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"opacity\",\"mask\",\"adjust\"]}",
  )
  let ha = props_html(a, roots)
  assert_true(has_sub(ha, "globalThis.__adj_op(\"a1\",this.value)"), msg=ha)
  assert_true(has_sub(ha, "globalThis.__adj_val(\"a1\",this.value)"), msg=ha)
  assert_true(has_sub(ha, "value='brightness'"), msg=ha)
  assert_true(has_sub(ha, "value='0.25'"), msg=ha)
  assert_true(lacks_sub(ha, "__text_set"), msg=ha)
  // 调整层作用于**其下的合成**，它的 x/y 与盒子都不读（实测 move/resize
  // 回 ok、指纹变、画面逐位不变）⇒ X/Y 与 W/H 都不该是输入框，而要印出理由
  assert_true(lacks_sub(ha, "__setx"), msg="调整层不该有 X 输入框：\{ha}")
  assert_true(lacks_sub(ha, "__setw"), msg="调整层不该有 W 输入框：\{ha}")
  assert_true(has_sub(ha, "不参与渲染"), msg="少画控件必须说明理由：\{ha}")
  // α 对所有 kind 都是能力（调整层：软强度 = 蒙版覆盖度 × α，PLAN 五十三）
  assert_true(has_sub(ha, "globalThis.__op(\"a1\""), msg="调整层的 α 是真的（算子生效多少）：\{ha}")
}

///|
test "HTML 转义：用户输入里的引号/尖括号不能把属性撑破" {
  // 层名、文字内容、标签都是用户输入。不转义的话一个 `'` 就把 `value='…'`
  // 提前闭合，后面的结构变成正文——画面"看起来还行"而控件全错位，
  // 浏览器里才看得出来。这条测试是那一类的机器判据。
  let roots = panel_layers()
  let evil = parse_json_safe(
    "{\"id\":\"l1\",\"name\":\"a'b<c>&d\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"tags\":[\"x'y\"]}",
  )
  let h = props_html(evil, roots)
  // 正文里的 `<c>` 不转义会被浏览器当成标签（名字后半截消失）
  assert_true(lacks_sub(h, "<c>"), msg="尖括号没转义：\{h}")
  assert_true(lacks_sub(h, "'d"), msg="单引号没转义（属性会被提前闭合）：\{h}")
  assert_true(has_sub(h, "&#39;"), msg=h)
  assert_true(has_sub(h, "&lt;c&gt;"), msg=h)
  assert_true(has_sub(h, "&amp;d"), msg=h)
  assert_true(has_sub(h, "globalThis.__tag_del(\"l1\",\"x&#39;y\")"), msg=h)
}

///|
test "flip 是设置不是取反：四个标志组合都要有对应的方向词" {
  // 按钮发的是**目标状态**。若顺手写成"再点一次发 h"，垂直翻转会被悄悄清掉。
  assert_eq(flip_word(true, false), "h")
  assert_eq(flip_word(false, true), "v")
  assert_eq(flip_word(true, true), "both")
  assert_eq(flip_word(false, false), "none")
  // 负控：两个输入换位不能得到同一个词（否则参数被写反也测不出来）
  assert_true(flip_word(true, false) != flip_word(false, true), msg="h 与 v 撞了")
}

///|
test "换图：文件选择走「原地换掉」还是「导入新层」由状态位决定（两条路一条命令）" {
  // 人类侧此前只有"导入新层"：选错了一张图，只能删掉重导——蒙版、标签、
  // 层序、翻转全丢（调整层还会被推到栈顶改变作用范围）。
  // 这条分叉抽成纯函数就是为了钉住"换图不是新层"。
  assert_true(
    has_sub(
      import_line("l1", "AAAA", "照片.png"),
      "set-image l1 b64=AAAA",
    ),
    msg="换图必须走 set-image（原地），不能是 add-image",
  )
  assert_true(
    lacks_sub(import_line("l1", "AAAA", "照片.png"), "add-image"),
    msg="换图那条路不许出现 add-image",
  )
  // 导入新层那条路保持历史参数不变（含名字要加引号）
  assert_eq(
    import_line("", "AAAA", "我的 照片"),
    "add-image x=100 y=60 w=600 h=450 b64=AAAA name=\"我的 照片\"",
  )
  // 面板：image 层才有「换图」按钮，且按钮先记状态再触发文件选择
  let roots = panel_layers()
  let img = parse_json_safe(
    "{\"id\":\"i1\",\"name\":\"照片\",\"kind\":\"image\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"asset\":\"deadbeef\",\"caps\":[\"move\",\"resize\",\"opacity\",\"rotate\",\"flip\",\"mask\",\"asset\"]}",
  )
  let hi = props_html(img, roots)
  assert_true(has_sub(hi, "globalThis.__img_swap(\"i1\");document.getElementById(\"file-in\").click()"), msg=hi)
  let rect = parse_json_safe(
    "{\"id\":\"l1\",\"name\":\"底\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"move\",\"resize\",\"opacity\",\"rotate\",\"flip\",\"mask\"]}",
  )
  assert_true(lacks_sub(props_html(rect, roots), "__img_swap"), msg="矩形上不该有「换图」")
}

///|
test "属性面板：笔触层不发 W/H 输入框（改了画面不动 = 静默入口），X/Y 照旧" {
  let roots = panel_layers()
  let r = parse_json_safe(
    "{\"id\":\"p1\",\"name\":\"笔触\",\"kind\":\"raster\",\"x\":0,\"y\":0,\"w\":320,\"h\":240,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"move\",\"opacity\",\"mask\"]}",
  )
  let h = props_html(r, roots)
  // 反控：不发那两个「改了不生效」的控件
  assert_true(lacks_sub(h, "__setw("), msg="笔触层不该有 W 输入框：\{h}")
  assert_true(lacks_sub(h, "__seth("), msg="笔触层不该有 H 输入框：\{h}")
  // 正控①：理由与当前值都要印出来（不是悄悄少一个框）
  assert_true(has_sub(h, "不参与渲染"), msg=h)
  assert_true(has_sub(h, "320×240"), msg=h)
  // 正控②：X/Y 照旧可改——`move` 是真的挪笔触（对笔触层有效果）
  assert_true(has_sub(h, "globalThis.__setx("), msg=h)
  assert_true(has_sub(h, "globalThis.__sety("), msg=h)
  // 正控③：别的 kind 照旧发 W/H（判据两头都咬得住）
  let rr = parse_json_safe(
    "{\"id\":\"r1\",\"name\":\"矩形\",\"kind\":\"rect\",\"x\":1,\"y\":2,\"w\":30,\"h\":40,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"move\",\"resize\",\"opacity\",\"rotate\",\"flip\",\"mask\"]}",
  )
  let hr = props_html(rr, roots)
  assert_true(has_sub(hr, "globalThis.__setw("), msg=hr)
  assert_true(has_sub(hr, "globalThis.__seth("), msg=hr)
}

///|
test "属性面板：引擎没报 caps 时一个能力控件都不画，并说清为什么（版本不匹配）" {
  // `caps` 是前端与引擎之间的**唯一**能力判据。缺了它只有两种诚实的做法：
  // 少画（人看到"这里没控件"）或报错。**不许猜 kind**——那就是把能力表在
  // demo 里抄了第二份，而两份必然先烂（PLAN 五十一）。
  let roots = panel_layers()
  let r = parse_json_safe(
    "{\"id\":\"z1\",\"name\":\"底\",\"kind\":\"rect\",\"x\":10,\"y\":20,\"w\":30,\"h\":40,\"opacity\":1,\"blend\":\"normal\"}",
  )
  let h = props_html(r, roots)
  for name in [
    "__setx", "__sety", "__setw", "__seth", "__rotate", "__flip", "__mask_invert", "__op",
  ] {
    assert_true(lacks_sub(h, name), msg="没有 caps 就不该画 \{name}：\{h}")
  }
  // 与 caps 无关的控件照旧（层名/删除/置顶/置底/标签）
  for name in ["__rename", "__del", "__front", "__back", "__tag_add"] {
    assert_true(has_sub(h, name), msg="没 caps 也要有的通用控件 \{name}：\{h}")
  }
  // 而且要**说清**为什么少了一排控件（静默少画会让人以为界面坏了）
  assert_true(has_sub(h, "没报 caps"), msg="少画必须说明理由：\{h}")
}

///|
test "拖动判据：caps 说没有 move 就不发命令，并说清为什么（不是拖了没反应）" {
  // `move` 在**调整层**上回 `ok` 而画面逐位不变（实测，PLAN 五十一）；组曾经同病，
  // 现在组会**搬内容**（连后代一起平移，PLAN 五十五）⇒ 组的 caps 里有 `move`，
  // 这一格不再是"拒绝"的例子，而是"允许"的例子（判据仍然只看 caps，不看 kind）。
  // 手势层照发就是**静默失败的手势**。判据提成纯函数（`move_gesture_refusal`），
  // 所以这条测试**不用引擎**就能把正反两向都咬住。
  let rect = parse_json_safe(
    "{\"id\":\"r1\",\"kind\":\"rect\",\"caps\":[\"move\",\"resize\",\"opacity\",\"rotate\",\"flip\",\"mask\"]}",
  )
  assert_true(move_gesture_refusal(rect) == "", msg="矩形能拖：\{move_gesture_refusal(rect)}")
  let p = parse_json_safe(
    "{\"id\":\"p1\",\"kind\":\"raster\",\"caps\":[\"move\",\"opacity\",\"mask\"]}",
  )
  assert_true(move_gesture_refusal(p) == "", msg="笔触的 x/y 是真的（挪笔触）：\{move_gesture_refusal(p)}")
  // 有内容的组：引擎报得出 `move` ⇒ 手势**必须**放行（它是真的搬内容）
  let g = parse_json_safe(
    "{\"id\":\"g1\",\"kind\":\"group\",\"caps\":[\"move\",\"opacity\",\"children\"]}",
  )
  assert_true(move_gesture_refusal(g) == "", msg="有内容的组能拖：\{move_gesture_refusal(g)}")
  // 空组 / 只装调整层的组：引擎不报 `move`（搬了画面逐位相同）⇒ 拒绝并点出 kind
  let ge = parse_json_safe("{\"id\":\"g2\",\"kind\":\"group\",\"caps\":[\"opacity\",\"children\"]}")
  let gr = move_gesture_refusal(ge)
  assert_true(gr.contains("不参与渲染"), msg=gr)
  assert_true(gr.contains("group"), msg="理由要点出是哪种层：\{gr}")
  let a = parse_json_safe("{\"id\":\"a1\",\"kind\":\"adjust\",\"caps\":[\"opacity\",\"mask\",\"adjust\"]}")
  assert_true(move_gesture_refusal(a).contains("adjust"), msg=move_gesture_refusal(a))
  // 没有 caps（版本不匹配）：停用并且**明说**是版本问题，别把锅甩给这个层
  let n = parse_json_safe("{\"id\":\"n1\",\"kind\":\"rect\"}")
  let nr = move_gesture_refusal(n)
  assert_true(nr.contains("没报 caps"), msg=nr)
  assert_true(!nr.contains("不参与渲染"), msg="缺 caps（版本不匹配）与「这个层没有能力」是两件事：\{nr}")
}

///|
test "属性面板：旧引擎的 caps 里没有 opacity ⇒ 不画 α 滑杆、并说清替代（版本偏斜）" {
  // `caps` 的意义就是"界面别抄第二份 kind 名单"——所以连"某一格缺失"也要
  // 按缺失处理（旧引擎/新前端），而不是回退去猜 kind。这条正好是那个 else 分支的
  // 活用例：引擎说这个层没有 opacity 能力时，界面给只读回显 + 替代说明。
  let l = parse_json_safe(
    "{\"id\":\"a1\",\"name\":\"调亮\",\"kind\":\"adjust\",\"adjust\":{\"op\":\"brightness\",\"value\":0.25},\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"mask\",\"adjust\"]}",
  )
  let h = props_html(l, panel_layers())
  assert_true(lacks_sub(h, "__op("), msg="caps 说没有 opacity 就不该画 α 滑杆：\{h}")
  assert_true(has_sub(h, "强度用「数值」"), msg="少画滑杆也要说清替代：\{h}")
  // 正控：同一份 JSON 只要 caps 里有 opacity，滑杆就在（判据两头都咬得住）
  let l2 = parse_json_safe(
    "{\"id\":\"a1\",\"name\":\"调亮\",\"kind\":\"adjust\",\"adjust\":{\"op\":\"brightness\",\"value\":0.25},\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"opacity\":1,\"blend\":\"normal\",\"caps\":[\"opacity\",\"mask\",\"adjust\"]}",
  )
  let h2 = props_html(l2, panel_layers())
  assert_true(has_sub(h2, "globalThis.__op(\"a1\""), msg="有 opacity 就必须画：\{h2}")
}
