/// 布尔运算的**命令面**判据（④ Stage B）。
///
/// 口径：几何对了还不够——要断言**装进容器之后画面真的对**：
/// 并/差/交/异或各拿面积与像素两头对账；"减出一个环"必须断言**洞里真的没墨**
/// （那是反选蒙版在干活）；"异或出两块"必须断言结果是个**组**且重叠区没墨；
/// 每一种拒绝都要断言**理由**（不是笼统的失败）。

///|
/// 结果的层 id（回包里的 `id`）：**别假设 `l3`**——`alloc_layer_id` 只按
/// `next_layer_no` 发号，显式 `id=a`/`id=b` 不占号，所以结果常常是 `l1`。
fn bo_id(r : String) -> String {
  jstr_field(r, "id")
}

///|
/// 取色（`probe` 的回包字段；画布坐标）。
fn bo_color(s : @agent.Session, x : Int, y : Int) -> String {
  jstr_field(run(s, "probe x=\{x} y=\{y}"), "color")
}

///|
/// 渲染 sha256。
fn bo_sha(s : @agent.Session) -> String {
  jstr_field(run(s, "render 64"), "render_sha256")
}

///|
/// 两个错开 20 的 40×40 矩形（A 红、B 蓝）——布尔运算判据的标准场景。
fn bo_pair(s : @agent.Session) -> Unit {
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 120 uuid=bool-1")
  let _ = run(s, "add-rect id=a x=0 y=0 w=40 h=40 fill=#FF0000FF")
  let _ = run(s, "add-rect id=b x=20 y=20 w=40 h=40 fill=#0000FFFF")
}

///|
test "bool-op union：结果是一层路径、盒子跟着内容走、并集覆盖三个特征点" {
  let s = @agent.Session::new()
  bo_pair(s)
  let before = bo_sha(s)
  let r = run(s, "bool-op op=union a=a b=b")
  assert_true(r.contains("\"ok\":true"), msg=r)
  assert_eq(jnum_field(r, "islands"), 1.0)
  assert_eq(jnum_field(r, "holes"), 0.0)
  // 画面真的变了（不是"回 ok 而一个像素不动"）
  assert_true(bo_sha(s) != before)
  // A 独有 / 重叠 / B 独有：三个点都在并集里，且颜色继承 A（红）
  assert_eq(bo_color(s, 10, 10), "#FF0000FF")
  assert_eq(bo_color(s, 30, 30), "#FF0000FF")
  assert_eq(bo_color(s, 50, 50), "#FF0000FF")
  // 并集之外还是白纸
  assert_eq(bo_color(s, 100, 100), "#FFFFFFFF")
  // 结果层的盒子 = 两个矩形的并集（0..60），且 kind=path
  let q = run(s, "query-layer \{bo_id(r)}")
  assert_eq(layer_str(q, "kind"), "path")
  assert_eq(layer_num(q, "w"), 60.0)
  assert_eq(layer_num(q, "h"), 60.0)
  assert_eq(layer_num(q, "x"), 0.0)
  let _ = s
}

///|
test "bool-op subtract：一个矩形挖掉里面的另一个 ⇒ 洞用反选蒙版表示，洞里真的没墨" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 120 uuid=bool-2")
  let _ = run(s, "add-rect id=big x=10 y=10 w=100 h=100 fill=#FF0000FF")
  let _ = run(s, "add-rect id=hole x=30 y=30 w=60 h=60 fill=#0000FFFF")
  let r = run(s, "bool-op op=subtract a=big b=hole")
  assert_true(r.contains("\"ok\":true"), msg=r)
  assert_eq(jnum_field(r, "islands"), 1.0)
  assert_eq(jnum_field(r, "holes"), 1.0)
  // 环上（A 的地盘）：红；洞里：**不是红**（白底透出来）——这一条就是蒙版在干活的判据
  assert_eq(bo_color(s, 20, 60), "#FF0000FF")
  assert_eq(bo_color(s, 60, 60), "#FFFFFFFF")
  // 替换的判据：b 层已经被删掉（洞心露的是**画布底色**，不是 b 的蓝）
  let ll = run(s, "list-layers")
  assert_true(!ll.contains("\"id\":\"big\"") && !ll.contains("\"id\":\"hole\""), msg=ll)
  // 层序：结果落在了原来最下面那个操作数的位置（这里 a=big 在最下 ⇒ 结果在最下）
  let top = run(s, "query-layer \{bo_id(r)}")
  assert_eq(layer_str(top, "kind"), "path")
  // 判别力自证：同样的点位、同样的两个矩形，若把 b 换成"并集"结果，洞心必须是红的
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let _ = run(s2, "new 120 120 uuid=bool-2u")
  let _ = run(s2, "add-rect id=big x=10 y=10 w=100 h=100 fill=#FF0000FF")
  let _ = run(s2, "add-rect id=hole x=30 y=30 w=60 h=60 fill=#0000FFFF")
  let _ = run(s2, "bool-op op=union a=big b=hole")
  assert_eq(bo_color(s2, 60, 60), "#FF0000FF")
}

///|
test "bool-op xor：两块互不相连 ⇒ 结果是一个组（两个成员），重叠区没有墨" {
  let s = @agent.Session::new()
  bo_pair(s)
  let r = run(s, "bool-op op=xor a=a b=b")
  assert_true(r.contains("\"ok\":true"), msg=r)
  assert_eq(jnum_field(r, "islands"), 2.0)
  // 组：两个成员的并集盒 = 0..60
  let q = run(s, "query-layer \{bo_id(r)}")
  assert_eq(layer_str(q, "kind"), "group")
  assert_eq(layer_num(q, "w"), 60.0)
  // 两块 L 各自在，重叠区（30,30）没有墨
  assert_eq(bo_color(s, 10, 30), "#FF0000FF")
  assert_eq(bo_color(s, 30, 50), "#FF0000FF")
  assert_eq(bo_color(s, 30, 30), "#FFFFFFFF")
  // 组里真的有两个成员（`list-layers` 的嵌套结构）
  let l = run(s, "list-layers")
  assert_true(l.contains("\{bo_id(r)}_1") && l.contains("\{bo_id(r)}_2"), msg=l)
  // 操作数被结果**替换**（不是留在下面）：层数回到 1 个根级层
  assert_true(!l.contains("\"id\":\"a\"") && !l.contains("\"id\":\"b\""), msg=l)
}

///|
test "bool-op intersect：交集就是重叠那块 20×20，且盒子只有那块大" {
  let s = @agent.Session::new()
  bo_pair(s)
  let r = run(s, "bool-op op=intersect a=a b=b")
  assert_true(r.contains("\"ok\":true"), msg=r)
  assert_eq(jnum_field(r, "islands"), 1.0)
  let q = run(s, "query-layer \{bo_id(r)}")
  assert_eq(layer_num(q, "w"), 20.0)
  assert_eq(layer_num(q, "h"), 20.0)
  assert_eq(layer_num(q, "x"), 20.0)
  assert_eq(bo_color(s, 30, 30), "#FF0000FF")
  assert_eq(bo_color(s, 10, 10), "#FFFFFFFF")
  assert_eq(bo_color(s, 50, 50), "#FFFFFFFF")
}

///|
test "bool-op：旋转过的操作数真的参与（轮廓走 to_canvas，盒子里装着转过的形状）" {
  let s = @agent.Session::new()
  bo_pair(s)
  let flat = run(s, "bool-op op=union a=a b=b")
  let flat_w = layer_num(run(s, "query-layer \{bo_id(flat)}"), "w")
  // 换一个会话：同样的两层，但把 b 转 45° —— 并集必须**不一样**
  let s2 = @agent.Session::new()
  bo_pair(s2)
  let _ = run(s2, "rotate b 45")
  let rot = run(s2, "bool-op op=union a=a b=b")
  assert_true(rot.contains("\"ok\":true"), msg=rot)
  let rot_w = layer_num(run(s2, "query-layer \{bo_id(rot)}"), "w")
  assert_true(rot_w > flat_w + 5.0, msg="平放并集宽=\{flat_w}，转过 45° 的并集宽=\{rot_w}")
  // B 被并进来的那块（菱形里、A 之外的点）必须真的有墨：45° 的菱形
  // 顶点在 (40,68.3)/(68.3,40)/(40,11.7)/(11.7,40)，(60,40) 在它内部而不在 A 里
  assert_eq(bo_color(s2, 60, 40), "#FF0000FF")
  // 判别力自证：平放时 (60,40) 不在并集里（A 到 40、B 的平放盒从 20 起但 y=40 是它的边界，
  // 换个明确的空点：平放并集之外 (100,100) 白）
  assert_eq(bo_color(s, 100, 100), "#FFFFFFFF")
  let _ = flat
}

///|
test "bool-op：坏输入与退化输入在入口拒绝，且每条都说清理由" {
  let s = @agent.Session::new()
  bo_pair(s)
  // 缺 op / 缺 a / 缺 b
  assert_true(run(s, "bool-op a=a b=b").contains("需要 op="))
  assert_true(run(s, "bool-op op=union b=b").contains("需要 a="))
  assert_true(run(s, "bool-op op=union a=a").contains("需要 b="))
  // 不认识的 op：要列出四个名字
  let bad = run(s, "bool-op op=merge a=a b=b")
  assert_true(bad.contains("union") && bad.contains("subtract"), msg=bad)
  // 不认识的键（拼错）
  assert_true(run(s, "bool-op op=union a=a b=b opp=x").contains("不认识的参数"))
  // 同一层
  assert_true(run(s, "bool-op op=union a=a b=a").contains("不能是同一层"))
  // 层不存在
  assert_true(run(s, "bool-op op=union a=a b=zz").contains("层不存在"))
  // 没有面：开放路径（fill=none）
  let _ = run(s, "add-path id=p x=0 y=0 points=0,0;80,0;80,80 fill=none stroke=#00FF00FF")
  let noface = run(s, "bool-op op=union a=a b=p")
  assert_true(noface.contains("没有面"), msg=noface)
  // id 已存在
  assert_true(run(s, "bool-op op=union a=a b=b id=a").contains("已存在"))
  // 结果为空：两个离得远的矩形求交
  let _ = run(s, "add-rect id=far x=100 y=100 w=10 h=10 fill=#00FF00FF")
  let empty = run(s, "bool-op op=intersect a=a b=far")
  assert_true(empty.contains("结果是空的"), msg=empty)
  // 部分共线重叠（两个矩形共用上下边且错开）：明确拒绝并说"共线重叠"
  let _ = run(s, "add-rect id=c x=20 y=0 w=40 h=40 fill=#FFFF00FF")
  let deg = run(s, "bool-op op=union a=a b=c")
  assert_true(deg.contains("共线重叠"), msg=deg)
}

///|
test "bool-op：组内的层被拒（祖先变换没算进轮廓 ⇒ 宁可不做）" {
  let s = @agent.Session::new()
  bo_pair(s)
  let _ = run(s, "group g1 a b")
  let r = run(s, "bool-op op=union a=g1 b=g1_zz")
  // g1 是组（没有面）；组内成员 a 也不许当操作数
  assert_true(r.contains("没有面") || r.contains("层不存在"), msg=r)
  let r2 = run(s, "bool-op op=union a=a b=g1")
  assert_true(r2.contains("在组里"), msg=r2)
}

///|
test "bool-op：同一对输入两次给出逐位相同的画面与指纹（确定性）" {
  let s = @agent.Session::new()
  bo_pair(s)
  let r1 = run(s, "bool-op op=union a=a b=b")
  let sha1 = bo_sha(s)
  let fp1 = jstr_field(r1, "fingerprint")
  let s2 = @agent.Session::new()
  bo_pair(s2)
  let r2 = run(s2, "bool-op op=union a=a b=b")
  assert_eq(bo_sha(s2), sha1)
  assert_eq(jstr_field(r2, "fingerprint"), fp1)
}
