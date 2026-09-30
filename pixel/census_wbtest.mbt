/// pixel —— census / probe 数值事实的不变量（pixel/census 的回归锚点）。

///|
fn cbuf(w : Int, h : Int, c : Int) -> @codec.RgbaBuf {
  let b = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(b, 0, 0, w, h, c)
  b
}

///|
fn cfield(w : Int, h : Int) -> Field {
  field_new(w, h)
}

///|
test "census：hue×sat 桶与 dominant_bin（索引 = sat*12 + hue）" {
  // 左半纯红（hue≈29°，s≈1）右半纯蓝（hue≈264°，s≈0.85）
  let b = cbuf(20, 10, 0xFFC81E1E)
  @codec.fill_rect_rgba(b, 10, 0, 10, 10, 0xFF1E5ACC)
  let c = census(b, None)
  assert_eq(c.total, 200, msg="总像素")
  assert_eq(c.counted, 200, msg="无 within 时统计全图")
  // #C81E1E 的 HSV 色相 ≈ 0° → 桶 0；#1E5ACC ≈ 220° → 桶 7（每桶 30°）
  assert_eq(c.hue_bins[0], 100, msg="红落在色相桶 0")
  assert_eq(c.hue_bins[7], 100, msg="蓝落在色相桶 7")
  // 两者饱和度都高 → sat 桶 2
  assert_eq(c.sat_bins[2], 200, msg="高饱和桶")
  // 无彩色桶应为 0
  assert_eq(c.sat_bins[0], 0, msg="无无彩色像素")
  // dominant_bin = 2*12 + hue_bin（红蓝各 100，栅格序先遇红 → 桶 0 先到 100）
  assert_eq(c.dominant_bin, 24, msg="众数桶下标")
  // 桶计数自洽：hsl 桶总数 = counted
  let mut sum = 0
  for v in c.hsl_bins {
    sum = sum + v
  }
  assert_eq(sum, 200, msg="hsl 桶总数")
  // **V 不是感知亮度**：纯红与纯蓝的 HSV V 都接近 1，OKLab L 差很多
  assert_true(c.mean_v > 0.79, msg="HSV V 均值应接近 1（\{c.mean_v}）")
  assert_true(c.mean_l < 0.58, msg="OKLab L 均值应明显低于 V（\{c.mean_l}）")
}

///|
test "census：within 收窄统计范围，且与覆盖率口径一致" {
  let b = cbuf(20, 10, 0xFFC81E1E)
  @codec.fill_rect_rgba(b, 10, 0, 10, 10, 0xFF1E5ACC)
  // within = 左半
  let f = cfield(20, 10)
  let mut y = 0
  while y < 10 {
    let mut x = 0
    while x < 10 {
      f.v[y * 20 + x] = 1.0
      x = x + 1
    }
    y = y + 1
  }
  let c = census(b, Some(f))
  assert_eq(c.counted, 100, msg="within 应只统计左半 100 像素")
  assert_eq(c.hue_bins[0], 100, msg="左半全是红")
  assert_eq(c.hue_bins[7], 0, msg="蓝被排除")
  // 全图模式的 counted = 200（对照）
  assert_eq(census(b, None).counted, 200, msg="全图口径")
}

///|
test "census：空区域不产生 NaN（counted=0 时均值归 0）" {
  let b = cbuf(4, 4, 0xFF123456)
  let f = cfield(4, 4)
  let c = census(b, Some(f))
  assert_eq(c.counted, 0, msg="空区域")
  assert_eq(c.dominant_bin, -1, msg="空区域无众数桶")
  assert_true(c.mean_l == 0.0, msg="空区域均值应为 0 而不是 NaN")
  assert_true(c.mean_h == 0.0, msg="空区域色相均值应为 0 而不是 NaN")
}

///|
test "probe：邻域统计 + 平坦区边缘置信度为 0" {
  let b = cbuf(9, 9, 0xFF3366CC)
  let p = match probe(b, 4, 4, 2) {
    Ok(x) => x
    Err(e) => abort("probe: \{e}")
  }
  assert_eq(p.x, 4, msg="x")
  assert_eq(p.y, 4, msg="y")
  assert_eq(p.r, 2, msg="r 默认 2（5×5）")
  assert_true(p.var_l < 1.0E-12, msg="纯色邻域方差应为 0（\{p.var_l}）")
  assert_true(p.edge == 0.0, msg="纯色区不应有边缘（\{p.edge}）")
  assert_true(p.edge_conf == 0.0, msg="平坦区边缘置信度应为 0")
  assert_true(p.mean_s > 0.7, msg="蓝色饱和度应高（\{p.mean_s}）")
}

///|
test "probe：硬边处 edge/edge_conf 显著（黑|白交界）" {
  // 左半黑、右半白：x=4 是交界列
  let b = cbuf(9, 1, 0xFF000000)
  @codec.fill_rect_rgba(b, 5, 0, 4, 1, 0xFFFFFFFF)
  let p = match probe(b, 4, 0, 1) {
    Ok(x) => x
    Err(e) => abort("probe: \{e}")
  }
  // L: 黑 0、白 1 → 中心差分 (1-0)/2 = 0.5
  assert_true(p.edge > 0.4, msg="交界处 edge 应显著（\{p.edge}）")
  assert_true(p.edge_conf == 1.0, msg="硬边应满置信（\{p.edge_conf}）")
  // 远离边界的点无边缘
  let p2 = match probe(b, 1, 0, 1) {
    Ok(x) => x
    Err(e) => abort("probe2: \{e}")
  }
  assert_true(p2.edge == 0.0, msg="纯色区 edge 应为 0")
}

///|
test "probe：越界点报精确错误（不静默夹取）" {
  let b = cbuf(4, 4, 0xFF000000)
  match probe(b, 4, 0, 0) {
    Ok(_) => abort("越界点不该成功")
    Err(e) => assert_true(e.has_prefix("探针点 (4,0) 超出画布 4x4"), msg=e)
  }
  match probe(b, 0, 0, 99) {
    Ok(_) => abort("越界半径不该成功")
    Err(e) => assert_true(e.has_prefix("探针半径 99 越界"), msg=e)
  }
}

///|
test "label_components：标签编号与 components id 严格一致" {
  let b = cbuf(20, 10, 0xFF000000)
  @codec.fill_rect_rgba(b, 1, 1, 3, 3, 0xFFFFFFFF)
  @codec.fill_rect_rgba(b, 12, 5, 2, 2, 0xFFFFFFFF)
  let f = cfield(20, 10)
  let mut y = 1
  while y < 4 {
    let mut x = 1
    while x < 4 {
      f.v[y * 20 + x] = 1.0
      x = x + 1
    }
    y = y + 1
  }
  y = 5
  while y < 7 {
    let mut x = 12
    while x < 14 {
      f.v[y * 20 + x] = 1.0
      x = x + 1
    }
    y = y + 1
  }
  let cert = certify(b, f)
  let labels = label_components(b, f)
  assert_eq(cert.components.length(), 2, msg="应有两个连通域")
  // 第一个连通域的 bbox 覆盖 (2,2)，第二个覆盖 (12,5)
  assert_eq(component_id_at(labels, 2, 2), 1, msg="左上块应为组件 1")
  assert_eq(component_id_at(labels, 12, 5), 2, msg="右下块应为组件 2")
  assert_eq(component_id_at(labels, 0, 0), 0, msg="背景为 0")
  assert_eq(component_id_at(labels, 19, 9), 0, msg="背景为 0")
  // 标签场里每个非零值都必须在 components 里存在
  let mut k = 0
  let n = labels.w * labels.h
  while k < n {
    let id = trunc_pos(labels.v[k])
    if id > 0 {
      assert_true(
        id >= 1 && id <= cert.components.length(),
        msg="标签 \{id} 超出组件数",
      )
      assert_eq(cert.components[id - 1].id, id, msg="标签与组件 id 对齐")
    }
    k = k + 1
  }
}
