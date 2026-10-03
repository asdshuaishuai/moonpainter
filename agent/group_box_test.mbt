///|
/// **组的盒子 = 成员的并集**——这是"这个组的内容占哪儿"的**唯一定义**
/// （`@core.group_bbox` / `@core.effective_box`），报告面与渲染的旋转轴心
/// 共用它。
///
/// 实测过的错法：`group` 把组盒设成**画布尺寸**，于是
/// ①`query-layer grp` 报 `0,0,100,100` 而成员只占了 `10,10,60,10`
///   （一个谁都没读过的谎，人类前端的选中框照着它画）；
/// ②组的旋转轴心是**画布中心**（人类以为绕自己的内容转）；
/// ③`resize grp` 回 `ok`、指纹变，而且**把轴心挪走**——画面跟着变，
///   而 `caps` 报组没有 `resize`（两个信号打架，见 PLAN 五十七）。

///|
/// 建一个 200×200 的文档，一个红条 + 一个蓝条都在**偏离画布中心**处。
fn gbox_scene(uuid : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 200 uuid=\{uuid}")
  let _ = run(s, "add-rect id=r x=100 y=20 w=40 h=10 fill=#FF0000FF")
  let _ = run(s, "add-rect id=b x=100 y=60 w=40 h=10 fill=#0000FFFF")
  s
}

///|
fn gbox_probe(s : @agent.Session, x : Int, y : Int) -> String {
  jstr_field(run(s, "probe x=\{x} y=\{y}"), "color")
}

///|
fn gbox_sha(s : @agent.Session) -> String {
  jstr_field(run(s, "render 64"), "render_sha256")
}

///|
test "组的盒子 = 成员的包围盒（不是画布尺寸）" {
  let s = gbox_scene("gbox-1")
  // 建组前先钉住前置状态：成员确实在偏离画布中心处
  assert_eq(gmove_layer_num(s, "r", "x"), 100.0, msg="前置：r 的 x")
  let _ = run(s, "group grp r b")
  // 成员并集 = x∈[100,140)、y∈[20,70) ⇒ (100,20,40,50)
  assert_eq(gmove_layer_num(s, "grp", "x"), 100.0, msg="组盒 x")
  assert_eq(gmove_layer_num(s, "grp", "y"), 20.0, msg="组盒 y")
  assert_eq(gmove_layer_num(s, "grp", "w"), 40.0, msg="组盒 w")
  assert_eq(gmove_layer_num(s, "grp", "h"), 50.0, msg="组盒 h")
  // **判别力自证**：画布是 200×200，若还按"画布尺寸"报，上面四条全废
  assert_true(
    gmove_layer_num(s, "grp", "w") != 200.0,
    msg="组盒不该是画布尺寸（实测过的错法）",
  )
}

///|
test "嵌套组：外层组的盒子用内层组的**派生**盒（不是它存下来的快照）" {
  let s = gbox_scene("gbox-nest")
  let _ = run(s, "group gi r")
  // gi 的快照 = (100,20,40,10)。现在改**成员**的尺寸 ⇒ 快照立刻过期，
  // 而派生盒跟着内容走（这正是"实时派生"要保证的事）
  let _ = run(s, "resize r 40 90")
  assert_eq(gmove_layer_num(s, "gi", "w"), 40.0, msg="内层组的派生宽")
  assert_eq(gmove_layer_num(s, "gi", "h"), 90.0, msg="内层组的派生高（成员改了就该跟着改）")
  // 外层组建组时若直接读内层的 `x/w` 字段（过期的 10），这里会拿 10
  let _ = run(s, "group go gi")
  assert_eq(gmove_layer_num(s, "go", "h"), 90.0, msg="外层组的盒子必须用内层的派生盒")
  assert_eq(gmove_layer_num(s, "go", "y"), 20.0, msg="外层组的盒子 y")
}

///|
test "已旋转的组：轴心是**内容中心**，且 resize 不再能把轴心挪走" {
  let s = gbox_scene("gbox-pivot")
  let _ = run(s, "group grp r")
  // 内容中心 (120,25)。转 90° 后 40×10 的横条变成 10×40 的竖条：
  // x∈[115,125)、y∈[5,45)（实测几何，见 PLAN 五十七）
  let _ = run(s, "rotate grp 90")
  assert_eq(gbox_probe(s, 120, 10), "#FF0000FF", msg="竖条上半该是红（绕内容中心转）")
  assert_eq(gbox_probe(s, 120, 40), "#FF0000FF", msg="竖条下半该是红")
  assert_eq(gbox_probe(s, 105, 25), "#FFFFFFFF", msg="原横条的左端该空了")
  assert_eq(gbox_probe(s, 120, 25), "#FF0000FF", msg="轴心处仍是红")
  // ⚠️ **判别力自证**：若轴心还是"画布中心"(100,100)，内容会跑到 y≈100 附近，
  // 上面 (120,10) 那条立刻变白——所以这组断言真的在咬"轴心在哪"
  assert_eq(gbox_probe(s, 100, 100), "#FFFFFFFF", msg="画布中心处不该有内容（轴心不是画布中心）")

  // caps 说组没有 `resize` ⇒ **必须逐位相同**；而且命令真的执行了（指纹变）
  let before = run(s, "render 64")
  let sha0 = gbox_sha(s)
  let fp0 = jstr_field(before, "fingerprint")
  let res = run(s, "resize grp 300 300")
  assert_true(!res.contains("\"error\":"), msg="resize 组仍回 ok：\{res}")
  assert_eq(
    gbox_sha(s),
    sha0,
    msg="caps 说组没有 resize ⇒ 改盒子必须逐位相同（轴心走派生盒，不读存下来的 w/h）",
  )
  assert_true(
    jstr_field(run(s, "render 64"), "fingerprint") != fp0,
    msg="但命令得真的执行了（指纹要变），否则这条断言是拿「没执行」充数",
  )
  // 报告面也还是派生盒：resize 写进去的 300 不该被报出来
  assert_eq(gmove_layer_num(s, "grp", "w"), 40.0, msg="报告面仍是成员并集的宽")
  assert_eq(gmove_layer_num(s, "grp", "h"), 10.0, msg="报告面仍是成员并集的高")
  // 轴心没被挪走（上面 sha 相同已经说明，这里再钉一次画面本身）
  assert_eq(gbox_probe(s, 120, 10), "#FF0000FF", msg="resize 之后竖条还在原处")
}

///|
test "轴心跟着**成员**走：把成员搬远之后旋转，绕的是新位置" {
  let s = gbox_scene("gbox-follow")
  let _ = run(s, "group grp r")
  // 把成员单搬到 (10,120)：派生盒 = (10,120,40,10)、中心 (30,125)
  let _ = run(s, "move r 10 120")
  assert_eq(gmove_layer_num(s, "grp", "x"), 10.0, msg="组盒跟着成员走")
  assert_eq(gmove_layer_num(s, "grp", "y"), 120.0, msg="组盒跟着成员走（y）")
  let _ = run(s, "rotate grp 90")
  // 绕 (30,125) 转 90° ⇒ 竖条 x∈[25,35)、y∈[105,145)
  assert_eq(gbox_probe(s, 30, 110), "#FF0000FF", msg="新轴心下方该是红")
  assert_eq(gbox_probe(s, 30, 140), "#FF0000FF", msg="新轴心下方该是红（远端）")
  assert_eq(gbox_probe(s, 120, 25), "#FFFFFFFF", msg="旧轴心处不该还有内容（快照没固化成轴心）")
}

///|
/// 组上的变换会作用到**整棵子树**，而 `ungroup` / `group-remove` 会把变换丢掉
/// ——画面上内容会跳一下，而回包说 `ok`（实测：`rotate grp 90` 之后
/// `ungroup grp`，`render_sha256` 从 `c09a3d3b…` 变成 `e4ef0899…`）。
/// 判据一处（`@agent.group_transform_error`），两个入口共用；**正控是清掉变换
/// 之后必须放行**——否则这条判据会退化成"这两个命令永远不能用"。
test "有变换的组：ungroup / group-remove 被拒且理由可操作，清掉变换后放行" {
  let s = gbox_scene("gbox-ungroup")
  let _ = run(s, "group grp r b")
  let _ = run(s, "rotate grp 90")
  let sha0 = gbox_sha(s)
  // ① 拒绝：理由要说清**为什么**（变换会丢）和**怎么办**（先清零）
  let bad = run(s, "ungroup grp")
  assert_true(bad.contains("\"error\":"), msg="有旋转时 ungroup 必须被拒：\{bad}")
  assert_true(bad.contains("rot=90"), msg="理由里要回显挂着的变换：\{bad}")
  assert_true(bad.contains("rotate grp 0"), msg="理由要给出可操作的下一条命令：\{bad}")
  let bad2 = run(s, "group-remove grp r")
  assert_true(bad2.contains("\"error\":"), msg="有旋转时 group-remove 必须被拒：\{bad2}")
  // 被拒**不是"什么都没发生"**：文档与画面都不许动
  assert_eq(gbox_sha(s), sha0, msg="被拒之后画面必须逐位不变")
  assert_eq(gmove_layer_num(s, "r", "x"), 100.0, msg="被拒之后成员盒子不动（它还在组里）")

  // ② 正控：清掉变换之后两个命令都要放行
  let _ = run(s, "rotate grp 0")
  let okr = run(s, "group-remove grp r")
  assert_true(!okr.contains("\"error\":"), msg="清零之后 group-remove 必须放行：\{okr}")
  let _ = run(s, "ungroup grp")
  assert_true(
    @core.find_layer(unwrap_doc(s).layers, "grp") is None,
    msg="清零之后 ungroup 必须真的解散",
  )
}

///|
/// 同一条判据的另一半：**flip** 也要能触发它（只判 `rot` 会漏掉一半的状态）。
/// 而且两种翻转都要认出来（本层只 `flip_h`，理由里必须写 `flip=h`）。
test "有 flip 的组同样被拒，理由写出是哪种翻转" {
  let s = gbox_scene("gbox-flip")
  let _ = run(s, "group grp r b")
  let _ = run(s, "flip grp h")
  let bad = run(s, "ungroup grp")
  assert_true(bad.contains("\"error\":"), msg="有 flip 时 ungroup 必须被拒：\{bad}")
  assert_true(bad.contains("flip=h"), msg="理由里要写明是哪种翻转：\{bad}")
  let _ = run(s, "flip grp both")
  let bad2 = run(s, "group-remove grp r")
  assert_true(bad2.contains("flip=both"), msg="both 也要认出来：\{bad2}")
  // 正控：`flip grp none` 之后放行
  let _ = run(s, "flip grp none")
  let ok = run(s, "group-remove grp r")
  assert_true(!ok.contains("\"error\":"), msg="flip none 之后必须放行：\{ok}")
}

///|
/// 恒等变换的组（绝大多数）**一个字都不该被挡**——实测这条判据的空集：
/// 组上 rot=0 且没有翻转时 `group_transform_error` 必须返回空串。
test "恒等变换的组：ungroup 与 group-remove 照常（判据的空集也要说话）" {
  let s = gbox_scene("gbox-ident")
  let _ = run(s, "group grp r b")
  let ok = run(s, "group-remove grp r")
  assert_true(!ok.contains("\"error\":"), msg="恒等组上 group-remove 必须放行：\{ok}")
  // 只加了成员、没碰变换的组同样是恒等的
  let _ = run(s, "group-add grp r")
  let ok2 = run(s, "ungroup grp")
  assert_true(!ok2.contains("\"error\":"), msg="恒等组上 ungroup 必须放行：\{ok2}")
}
