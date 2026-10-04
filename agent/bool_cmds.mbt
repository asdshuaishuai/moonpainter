/// `bool-op` —— 两个形状的 并/差/交/异或（④ Stage B）。
///
/// 命令面（`bool-op op=union a=l1 b=l2 [id=] [name=]`）与几何（`@core.boolean_loops`
/// + `@render.face_ring`）分工：
/// - **几何**只回答"两个环的结果是什么环"（正面积=岛、负面积=洞）；
/// - **这里**回答"结果怎么装进容器"：岛的个数决定是**一层**还是**一个组**，
///   洞用**反选蒙版**表示（`fill` 之外的第二个面），并给出可读的回包。
///
/// 四个产品决定，都写在回包与文档里，不许调用方猜：
/// ①**两个操作数被结果替换**（删掉 a 和 b，结果插在它们原来最下面那个的位置）：
///   同 Illustrator 的路径查找器。这不是"顺手清理"——**留着操作数会让"洞"看不见**：
///   减出来的洞里会露出下面那层 b，用户看到的还是实心块，而回包一切正常；
/// ②结果层的填充/描边**继承 A**（A 是"主体"：`bool-op subtract a b` 读作 a 减 b）；
/// ③岛多于一个 ⇒ 编成一个组（组里每层一个岛），层序按包围盒排定（确定性）；
/// ④洞用**多边形蒙版 + invert**表示（`mask` 本来就是"这一层在哪儿生效"），
///   所以"减出一个环"之后洞里真的没有墨——这一条有像素判据（`sample` 洞心）。
///
/// 明确拒绝（入口拒绝 + 说清怎么办）：
/// - 操作数没有面（`fill=none` 的开放路径 / 线段 / 文本 / 位图 / 组 / 调整层）；
/// - 两个操作数是同一层；操作数不在根级（组内层：祖先变换没算进轮廓）；
/// - 结果为空（两个形状没有交集 / 相减什么都不剩）——不建一个空层糊弄；
/// - 一个岛里有两个以上的洞（一层一个蒙版，装不下；提示拆开做）。
fn cmd_bool_op(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err(
      "用法：bool-op op=union|subtract|intersect|xor a=<层 id> b=<层 id> [id=] [name=\"\"]（subtract 读作 a 减 b）",
    )
  }
  match check_kv_args(tokens, 1, bool_op_keys(), "bool-op") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 1)
  let op_name = match m.get("op") {
    Some(v) => v
    None =>
      return err("bool-op 需要 op=（四选一：union / subtract / intersect / xor）")
  }
  let op = match @core.bool_op_from_name(op_name) {
    Some(o) => o
    None =>
      return err(
        "不认识的布尔操作：\{op_name}（四选一：union 并 / subtract 差(a−b) / intersect 交 / xor 异或）",
      )
  }
  let a_id = match m.get("a") {
    Some(v) => v
    None => return err("bool-op 需要 a=<层 id>")
  }
  let b_id = match m.get("b") {
    Some(v) => v
    None => return err("bool-op 需要 b=<层 id>")
  }
  if a_id == b_id {
    return err("bool-op 的两个操作数不能是同一层（\{a_id}）：一个形状自己和自己运算没有意义")
  }
  let a = match root_face_layer(doc, a_id, "a") {
    Ok(l) => l
    Err(e) => return err(e)
  }
  let b = match root_face_layer(doc, b_id, "b") {
    Ok(l) => l
    Err(e) => return err(e)
  }
  let ring_a = match @render.face_ring(a) {
    Some(r) => r
    None => return err("a=\{a_id} 没有面…")
  }
  let ring_b = match @render.face_ring(b) {
    Some(r) => r
    None => return err("b=\{b_id} 没有面…")
  }
  let loops = match @core.boolean_loops(op, ring_a, ring_b) {
    Ok(l) => l
    Err(e) => return err(e)
  }
  if loops.length() == 0 {
    return err(
      "bool-op \{@core.bool_op_name(op)} 的结果是空的（两个形状没有共同区域，或相减后什么都不剩）：没有建层",
    )
  }
  // 岛（正面积）与洞（负面积）：方向就是语义，这里只做分配
  let islands : Array[Array[(Double, Double)]] = []
  let holes : Array[Array[(Double, Double)]] = []
  for r in loops {
    if @core.polygon_area(r) > 0.0 {
      islands.push(r)
    } else {
      holes.push(r)
    }
  }
  if islands.length() == 0 {
    return err("bool-op 的几何结果是空的（只有洞、没有岛）：不建层")
  }
  // 洞归属：洞顶上那个岛（洞的第一个顶点落在谁的内部）
  let hole_of : Array[Int] = []
  let mut hi = 0
  while hi < holes.length() {
    let v = holes[hi][0]
    let mut owner = -1
    let mut ii = 0
    while ii < islands.length() {
      if @core.path_contains(islands[ii], [], true, v.0, v.1) {
        owner = ii
      }
      ii = ii + 1
    }
    if owner < 0 {
      return err("bool-op 有个洞不在任何岛里（退化输入）：不建层")
    }
    hole_of.push(owner)
    hi = hi + 1
  }
  // 一层一个蒙版 ⇒ 一个岛最多一个洞。两个以上要拆开做，别给一个装不下的表示。
  let count : Array[Int] = []
  let mut ci = 0
  while ci < islands.length() {
    count.push(0)
    ci = ci + 1
  }
  for o in hole_of {
    count[o] = count[o] + 1
  }
  let mut ci2 = 0
  while ci2 < count.length() {
    if count[ci2] > 1 {
      return err(
        "bool-op 的结果里有一个岛带着 \{count[ci2]} 个洞：一层只能表示一个洞（一个反选蒙版），请拆成多次运算（先做一次，再拿结果减第二个）",
      )
    }
    ci2 = ci2 + 1
  }
  let base_name = match m.get("name") {
    Some(v) => v
    None => "bool \{@core.bool_op_name(op)}"
  }
  // 操作数的位置：结果插在**最下面那个**的位置（两个都删掉之后，层序留下的
  // 是"这一对原来占的那一格"）。层序在渲染里是语义，所以它有判据。
  let mut idx_a = -1
  let mut idx_b = -1
  let mut k = 0
  while k < doc.layers.length() {
    if doc.layers[k].id == a_id {
      idx_a = k
    }
    if doc.layers[k].id == b_id {
      idx_b = k
    }
    k = k + 1
  }
  let min_idx = if idx_a < idx_b { idx_a } else { idx_b }
  let id = match user_layer_id(doc, m, "bool-op") {
    Ok(v) => v
    Err(e) => return err(e)
  }
  snapshot(s, doc, "bool-op \{@core.bool_op_name(op)} \{a_id} \{b_id}")
  // 一个岛 ⇒ 一层（叫 id）；多个岛 ⇒ 一个组（叫 id），组里每层一个岛。
  let members : Array[@core.Layer] = []
  let mut ii = 0
  while ii < islands.length() {
    let ring = islands[ii]
    let (bx, by, bx1, by1) = @core.loop_box(ring)
    let bw = bx1 - bx
    let bh = by1 - by
    let lid = if islands.length() == 1 { id } else { free_id(doc, "\{id}_\{ii + 1}") }
    let pts : Array[(Double, Double)] = []
    for p in ring {
      pts.push((p.0 - bx, p.1 - by))
    }
    let l = {
      ..@core.default_layer(lid, if islands.length() == 1 { base_name } else { "\{base_name} \{ii + 1}" }, bx, by, bw, bh),
      kind: @core.ShapeKind::Path,
      points: pts,
      handles: [],
      fill: a.fill,
      stroke: a.stroke,
    }
    let mut cand = l
    // 洞 ⇒ 反选的多边形蒙版（坐标是层局部；蒙版自己的盒子 = 洞的包围盒）
    let mut hj = 0
    while hj < holes.length() {
      if hole_of[hj] == ii {
        let hr = holes[hj]
        let (hx, hy, hx1, hy1) = @core.loop_box(hr)
        let hpts : Array[(Double, Double)] = []
        for p in hr {
          hpts.push((p.0 - hx, p.1 - hy))
        }
        cand = {
          ..cand,
          mask: Some({
            kind: @core.ShapeKind::Polygon,
            x: hx - bx,
            y: hy - by,
            w: hx1 - hx,
            h: hy1 - hy,
            radius: 0.0,
            feather: 0.0,
            roughen: 0.0,
            invert: true,
            points: hpts,
          }),
        }
      }
      hj = hj + 1
    }
    members.push(cand)
    ii = ii + 1
  }
  let n_holes = holes.length()
  let n_islands = islands.length()
  // 先删操作数（从后往前删，索引才不乱），再把结果插回原来的位置
  let hi_idx = if idx_a > idx_b { idx_a } else { idx_b }
  let _ = doc.layers.remove(hi_idx)
  let _ = doc.layers.remove(min_idx)
  let pos = if min_idx > doc.layers.length() { doc.layers.length() } else { min_idx }
  if n_islands == 1 {
    doc.layers.insert(pos, members[0])
  } else {
    let (gx, gy, gw, gh) = match @core.group_bbox(members) {
      Some(box) => box
      None => (0.0, 0.0, doc.width.to_double(), doc.height.to_double())
    }
    doc.layers.insert(pos, {
      ..@core.default_layer(id, base_name, gx, gy, gw, gh),
      kind: @core.ShapeKind::Group,
      fill: @core.Fill::NoFill,
      children: members,
    })
  }
  "{\"ok\":true,\"op\":\"bool-op\",\"bool_op\":\"\{@core.bool_op_name(op)}\",\"id\":\"\{id}\",\"islands\":\{n_islands},\"holes\":\{n_holes},\"layers\":\{doc.layers.length()},\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}

///|
/// `bool-op` 的键表（**唯一一处**：解析器与字典描述都读它）。
fn bool_op_keys() -> Array[String] {
  ["op", "a", "b", "id", "name"]
}

///|
/// 一个还没被占用的层 id（多岛编组时给成员起名用）。
fn free_id(doc : @core.Document, base : String) -> String {
  let mut cand = base
  let mut n = 2
  while @core.find_layer(doc.layers, cand) is Some(_) {
    cand = "\{base}_\{n}"
    n = n + 1
  }
  cand
}

///|
/// **只在根级**找层（`@core.find_layer` 是**递归**的：它连组里的层一起找出来，
/// 于是"这个 id 在不在根级"用它会永远回"在"——组内层会带着没算祖先变换的
/// 轮廓进几何）。这一句与 `cmd_group` 的成员校验是同一个口径。
fn root_layer(doc : @core.Document, id : String) -> @core.Layer? {
  for l in doc.layers {
    if l.id == id {
      return Some(l)
    }
  }
  None
}

///|
/// 取一个**根级、有面**的操作数层。
///
/// 三条拒绝都在这里、每一条都说清怎么办：
/// - 层不存在；
/// - 不在根级（组内层的祖先变换没算进轮廓 ⇒ 宁可不做，也不给错的结果）；
/// - 没有面（开放路径 / 线段 / 文本 / 位图 / 组 / 调整层）。
fn root_face_layer(
  doc : @core.Document,
  id : String,
  slot : String,
) -> Result[@core.Layer, String] {
  let l = match root_layer(doc, id) {
    Some(l) => l
    None => {
      // 只在根级找得到：组内的层要给出"它在组里"这个更准的理由
      match @core.find_layer(doc.layers, id) {
        Some(_) =>
          return Err(
            "\{slot}=\{id} 在组里：布尔运算只支持根级层（组内层的祖先变换还没算进轮廓）——先 ungroup 或把它移出组",
          )
        None => return Err("\{slot}=\{id} 层不存在")
      }
    }
  }
  match @render.face_ring(l) {
    Some(_) => Ok(l)
    None =>
      Err(
        "\{slot}=\{id} 没有面，布尔运算要两个有面的形状：只有矩形/椭圆/多边形/**有填充的闭合路径**有面——fill=none 的开放路径、线段、文本、位图、组、调整层都不行（要轮廓就先给路径加填充，或用 add-mask 那条任意形状选区的路）",
      )
  }
}
