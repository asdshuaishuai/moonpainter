/// 贝塞尔路径几何的判据（④ 钢笔）。
///
/// 这一组要能抓住的三类注入 bug（对应 `mutation_scan.py` 里 path 那几条）：
/// ①**控制柄被忽略**（曲线退化成锚点折线——形状"看着还行"但完全不是画的那条）；
/// ②**采样规则变了**（同一路径在不同地方采出不同的点 ⇒ 填充/描边/拾取分叉）；
/// ③**闭合语义**（开放路径被当成闭合面填上）。
/// 所以每条判据都先自证判别力：先断言"这样算和那样算**结果不同**"，再断言对的答案。

///|
test "贝塞尔采样：控制柄真的改变形状（不是把锚点连成折线）" {
  // 两个锚点、控制柄把曲线拉成一条向上鼓的弧：中点必须离开弦
  let a = (0.0, 0.0)
  let b = (100.0, 0.0)
  let straight = @core.path_samples([a, b], [], false)
  let curved = @core.path_samples([a, b], [(0.0, 0.0), (0.0, -80.0), (0.0, -80.0), (0.0, 0.0)], false)
  // 判别力自证：两份采样必须不同（否则下面的断言是空的）
  let mut differs = straight.length() != curved.length()
  let mut i = 0
  while i < straight.length() && i < curved.length() {
    if (straight[i].0 - curved[i].0).abs() > 1.0e-9 || (straight[i].1 - curved[i].1).abs() > 1.0e-9 {
      differs = true
    }
    i = i + 1
  }
  assert_true(differs)
  // 折线（控制柄全 0）的每个采样点都必须落在弦上
  for p in straight {
    assert_true((p.1 - 0.0).abs() < 1.0e-9)
  }
  // 曲线采样点必须**离开**弦（弧高 > 1px），且两端仍钉在锚点上
  let mut off = 0.0
  for p in curved {
    if p.1.abs() > off {
      off = p.1.abs()
    }
  }
  assert_true(off > 1.0)
  assert_true((curved[0].0 - a.0).abs() < 1.0e-9 && (curved[0].1 - a.1).abs() < 1.0e-9)
  let last = curved[curved.length() - 1]
  assert_true((last.0 - b.0).abs() < 1.0e-9 && (last.1 - b.1).abs() < 1.0e-9)
}

///|
test "贝塞尔采样：同一条路径采两次逐位相同（确定性）" {
  let anchors = [(0.0, 0.0), (40.0, 0.0), (40.0, 30.0)]
  let handles = [(0.0, 0.0), (10.0, 0.0), (-10.0, 0.0), (0.0, 10.0), (0.0, -10.0), (0.0, 0.0)]
  let one = @core.path_samples(anchors, handles, true)
  let two = @core.path_samples(anchors, handles, true)
  assert_eq(one.length(), two.length())
  let mut i = 0
  while i < one.length() {
    assert_eq(one[i].0, two[i].0)
    assert_eq(one[i].1, two[i].1)
    i = i + 1
  }
}

///|
test "闭合语义：开放路径没有面、闭合路径有面（同一条折线两种读法）" {
  // 一个"L"形折线：开放时围不出面，闭合成三角形（补上收口那条边）
  let anchors = [(10.0, 10.0), (90.0, 10.0), (90.0, 90.0)]
  // 开放：三条边之外的点一律不算"里面"——
  // (60,60) 在三角内部，但开放折线不闭合 ⇒ 必须 false
  assert_false(@core.path_contains(anchors, [], false, 60.0, 60.0))
  // 闭合 ⇒ 同一个点在面内（自证：两种读法结论不同）
  assert_true(@core.path_contains(anchors, [], true, 60.0, 60.0))
  // 面外的点两种读法都不算
  assert_false(@core.path_contains(anchors, [], true, 5.0, 5.0))
}

///|
test "包含判定与描边最近距离：曲线上/曲线外的答案与几何直觉一致" {
  // 一条从 (0,0) 到 (100,0)、控制柄上抬 80 的弧：顶点大约在 (50,-60)
  let anchors = [(0.0, 0.0), (100.0, 0.0)]
  let handles = [(0.0, 0.0), (0.0, -80.0), (0.0, -80.0), (0.0, 0.0)]
  // 弧最高处的采样点：y 应该接近 -60（三次贝塞尔 t=0.5 时 y = 3/4 * -80 = -60）
  let pts = @core.path_samples(anchors, handles, false)
  let mut top = 0.0
  for p in pts {
    if p.1 < top {
      top = p.1
    }
  }
  assert_true((top + 60.0).abs() < 0.5)
  // 最近距离：曲线上的点距离≈0；离得很远的点距离很大
  let d_on = @core.path_nearest_dist(anchors, handles, false, 50.0, top)
  assert_true(d_on < 1.0)
  let d_far = @core.path_nearest_dist(anchors, handles, false, 50.0, 400.0)
  assert_true(d_far > 300.0)
}

///|
test "控制柄条数：0 个 = 合法（全折线），否则必须正好 2×锚点数" {
  assert_eq(@core.handles_count_error(3, 0), "")
  assert_eq(@core.handles_count_error(3, 6), "")
  // 少一个 / 多一个 / 只给了一半，都要报出"应该给几个"
  for bad in [1, 5, 7, 12] {
    let e = @core.handles_count_error(3, bad)
    assert_true(e != "")
    assert_true(e.contains("6"))
  }
}

///|
test "路径包围盒：采样后的外接盒（盒子跟着内容走的那把尺子）" {
  let anchors = [(0.0, 0.0), (100.0, 0.0)]
  let handles = [(0.0, 0.0), (0.0, -80.0), (0.0, -80.0), (0.0, 0.0)]
  let b = @core.path_box(anchors, handles, false)
  assert_eq(b.0, 0.0)
  assert_true((b.2 - 100.0).abs() < 1.0e-6)
  // 盒子的高度必须**跟着曲线**（而不是锚点的 0）：曲线鼓到 -60，盒子就该到 -60
  assert_true(b.1 < -59.0 && b.1 > -61.0)
  // 折线（无控制柄）的盒子 = 锚点盒
  let b2 = @core.path_box([(0.0, 0.0), (100.0, 0.0)], [], false)
  assert_eq(b2.1, 0.0)
  assert_eq(b2.3, 0.0)
}

///|
test "路径的 canonical 往返：handles 字节一致（非 Path 层逐位不变）" {
  let doc = @core.new_document("path-rt", 40, 40)
  let l = @core.default_layer("p1", "钢笔", 0.0, 0.0, 30.0, 20.0)
  let layer = {
    ..l,
    kind: @core.ShapeKind::Path,
    points: [(0.0, 0.0), (30.0, 0.0)],
    handles: [(0.0, 0.0), (0.0, 10.0), (0.0, 10.0), (0.0, 0.0)],
    fill: @core.Fill::Solid(0xFF102030),
  }
  doc.layers.push(layer)
  let one = @core.doc_to_json(doc)
  // 判别力自证：控制柄真的写进了 canonical 字节（不写就没有这一行）
  assert_true(one.contains("\"handles\""), msg=one)
  let back = match @core.doc_from_json(one) {
    Ok(d) => d
    Err(e) => abort("往返失败：\{e}")
  }
  let two = @core.doc_to_json(back)
  assert_eq(two, one)
  // 非 Path 层**一个字节都不多**：`handles` 空 ⇒ 不写（老 golden 不动）
  let doc2 = @core.new_document("plain", 10, 10)
  let plain = @core.doc_to_json(doc2)
  assert_false(plain.contains("\"handles\""), msg=plain)
}

///|
test "渲染合同档：带路径的文档要求更高档，且引擎自身支持它" {
  // 没有路径：合同档停在基础档（不许"总是报最高档"——闸会失去分辨力）
  let doc = @core.new_document("rc-1", 20, 20)
  assert_eq(@core.required_render_contract(doc), 1)
  let l = @core.default_layer("p1", "p", 0.0, 0.0, 10.0, 10.0)
  doc.layers.push({ ..l, kind: @core.ShapeKind::Path, points: [(0.0, 0.0), (10.0, 0.0)] })
  // 老引擎不认 path（整层不画）⇒ 必须声明 5，否则静默错渲
  assert_eq(@core.required_render_contract(doc), @core.RENDER_CONTRACT_PATH)
  // 引擎自己的最高档必须 ≥ 它（否则自己写的容器自己打不开）
  assert_true(@core.RENDER_CONTRACT_VERSION >= @core.RENDER_CONTRACT_PATH)
}
