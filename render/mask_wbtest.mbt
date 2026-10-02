/// 圆角矩形内部判定（`rounded_rect_inside`）。
///
/// 这是 `add-mask ... radius=` 唯一的实现点。`radius` 在文档、工具面字典和
/// 容器序列化里被承诺了很久，但**渲染从来没读过它**——用户写 `radius=10`
/// 得到的是硬直角，而且不报错（静默失败）。现在接上了，边界值要钉死：
/// 差一个像素的圆角肉眼看不出来，但"有没有生效"必须能分辨。

/// 毛边噪声在 `mask_edge_offset(1.0, 2.0, 3.0)` 的实测值（跨 target 的回归锚点）。
const PINNED_OFFSET : Double = 0.6222709026187658

///|
/// 浮点近似相等（内距含开方，别用 ==）。
fn near_d(a : Double, b : Double) -> Bool {
  let d = if a > b { a - b } else { b - a }
  d < 0.000001
}

///|
test "rounded_rect_inside：radius=0 退化为硬直角矩形" {
  assert_true(rounded_rect_inside(0.0, 0.0, 20.0, 20.0, 0.0))
  assert_true(rounded_rect_inside(19.9, 19.9, 20.0, 20.0, 0.0))
  assert_true(rounded_rect_inside(10.0, 10.0, 20.0, 20.0, 0.0))
  assert_true(rounded_rect_inside(0.0, 19.9, 20.0, 20.0, 0.0))
}

///|
test "rounded_rect_inside：radius 切掉四角，(3,3) 在内而 (2,2) 在外" {
  // w=h=20、radius=10 → 夹到半边长，等价于内切圆：
  //   qx = |dx−10|、qy = |dy−10|，inside ⟺ qx²+qy² ≤ 100
  // (3,3) → 7²+7² = 98 ≤ 100 → 内；(2,2) → 8²+8² = 128 > 100 → 外。
  // 这两点只差 1 像素，正好卡在圆角边界两侧。
  assert_true(rounded_rect_inside(3.0, 3.0, 20.0, 20.0, 10.0))
  assert_true(!rounded_rect_inside(2.0, 2.0, 20.0, 20.0, 10.0))
  assert_true(rounded_rect_inside(10.0, 10.0, 20.0, 20.0, 10.0))
  // 四个角对称地都被切掉
  assert_true(!rounded_rect_inside(1.0, 1.0, 20.0, 20.0, 10.0))
  assert_true(!rounded_rect_inside(18.0, 1.0, 20.0, 20.0, 10.0))
  assert_true(!rounded_rect_inside(1.0, 18.0, 20.0, 20.0, 10.0))
  assert_true(!rounded_rect_inside(18.0, 18.0, 20.0, 20.0, 10.0))
  // 四条边的中点仍在（圆角不该啃到边中）
  assert_true(rounded_rect_inside(10.0, 0.0, 20.0, 20.0, 10.0))
  assert_true(rounded_rect_inside(0.0, 10.0, 20.0, 20.0, 10.0))
  assert_true(rounded_rect_inside(19.0, 10.0, 20.0, 20.0, 10.0))
  assert_true(rounded_rect_inside(10.0, 19.0, 20.0, 20.0, 10.0))
}

///|
test "rounded_rect_inside：radius 超过半边长按半边长夹住（不越界）" {
  // w=20,h=10 → 夹到 min(10,5)=5。radius=999 必须与 radius=5 逐点一致，
  // 否则"给个大圆角"会变成"整个蒙版消失"或溢出成负半径。
  assert_eq(
    rounded_rect_inside(0.0, 0.0, 20.0, 10.0, 999.0),
    rounded_rect_inside(0.0, 0.0, 20.0, 10.0, 5.0),
  );
  assert_eq(
    rounded_rect_inside(1.0, 1.0, 20.0, 10.0, 999.0),
    rounded_rect_inside(1.0, 1.0, 20.0, 10.0, 5.0),
  );
  assert_eq(
    rounded_rect_inside(10.0, 5.0, 20.0, 10.0, 999.0),
    rounded_rect_inside(10.0, 5.0, 20.0, 10.0, 5.0),
  );
  assert_eq(
    rounded_rect_inside(19.0, 9.0, 20.0, 10.0, 999.0),
    rounded_rect_inside(19.0, 9.0, 20.0, 10.0, 5.0),
  );
}

///|
test "rounded_rect_inside：小 radius 只啃掉角上一小块" {
  // w=h=20、radius=2 → qx = |dx−10| − 8
  // (0,0): qx=qy=2 → 4+4 = 8 > 4 → 外
  assert_true(!rounded_rect_inside(0.0, 0.0, 20.0, 20.0, 2.0))
  // (1,1): qx=qy=1 → 1+1 = 2 ≤ 4 → 内
  assert_true(rounded_rect_inside(1.0, 1.0, 20.0, 20.0, 2.0))
  // 边中点 (10,0): qx=−8、qy=2 → 0+4 = 4 ≤ 4 → 内（刚好在圆角切线上）
  assert_true(rounded_rect_inside(10.0, 0.0, 20.0, 20.0, 2.0))
}

///|
test "mask_inner_dist：内距是到边界的真实像素距离（SDF 的第二项不能漏）" {
  // 矩形蒙版 20×20、无圆角。内距 = 到最近边界的像素距离。
  let m : @core.LayerMask = {
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 20.0,
    h: 20.0,
    radius: 0.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
  }
  assert_true(near_d(mask_inner_dist(m, 1.0, 1.0), 1.0))
  assert_true(near_d(mask_inner_dist(m, 2.0, 5.0), 2.0))
  assert_true(near_d(mask_inner_dist(m, 3.0, 9.0), 3.0))
  // 中心到最近边界 10
  assert_true(near_d(mask_inner_dist(m, 10.0, 10.0), 10.0))
  // 边界外侧为负（点 x=25 → 出界 5）
  assert_true(near_d(mask_inner_dist(m, 25.0, 5.0), 0.0 - 5.0))
  // 角外侧：点在 (−3,−4) 时到角的距离是 5
  assert_true(near_d(mask_inner_dist(m, 0.0 - 3.0, 0.0 - 4.0), 0.0 - 5.0))
}

///|
test "mask_inner_dist：圆角矩形在圆角处按圆弧算内距" {
  // 20×20、radius=10（内切圆）。圆心 (10,10)、半径 10。
  let m : @core.LayerMask = {
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 20.0,
    h: 20.0,
    radius: 10.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
  }
  // 中心 → 内距 10
  assert_true(near_d(mask_inner_dist(m, 10.0, 10.0), 10.0))
  // (3,3)：到圆心距离 √98 ≈ 9.8995 → 内距 ≈ 0.1005（很贴近边界）
  let d = mask_inner_dist(m, 3.0, 3.0)
  assert_true(d > 0.0 && d < 0.11)
  // (2,2)：到圆心距离 √128 ≈ 11.3137 → 在外 1.3137
  assert_true(mask_inner_dist(m, 2.0, 2.0) < 0.0)
}

///|
test "mask_inner_dist：椭圆用短半轴做尺度（圆形时精确）" {
  // 10×10 的椭圆就是半径 5 的圆
  let c : @core.LayerMask = {
    kind: @core.ShapeKind::Ellipse,
    x: 0.0,
    y: 0.0,
    w: 10.0,
    h: 10.0,
    radius: 0.0,
    feather: 0.0,
    roughen: 0.0,
    invert: false,
  }
  assert_true(near_d(mask_inner_dist(c, 5.0, 5.0), 5.0))
  assert_true(near_d(mask_inner_dist(c, 0.0, 5.0), 0.0))
  assert_true(near_d(mask_inner_dist(c, 2.5, 5.0), 2.5))
  assert_true(mask_inner_dist(c, 0.0, 0.0) < 0.0)
}

///|
test "rounded_rect_sdf：radius 超过半边长也按半边长夹住（羽化路径不能溢出）" {
  // 羽化按 `-rounded_rect_sdf` 算内距，所以这条路径的夹住行为与硬边路径
  // 同等重要。上面那条"夹住"测的是 `rounded_rect_inside`（布尔版），
  // 这条补上 sdf 版——变异 R4 就是靠它才被抓住的。
  assert_true(
    near_d(
      rounded_rect_sdf(0.0, 0.0, 20.0, 10.0, 999.0),
      rounded_rect_sdf(0.0, 0.0, 20.0, 10.0, 5.0),
    ),
  )
  assert_true(
    near_d(
      rounded_rect_sdf(1.0, 1.0, 20.0, 10.0, 999.0),
      rounded_rect_sdf(1.0, 1.0, 20.0, 10.0, 5.0),
    ),
  )
  assert_true(
    near_d(
      rounded_rect_sdf(10.0, 5.0, 20.0, 10.0, 999.0),
      rounded_rect_sdf(10.0, 5.0, 20.0, 10.0, 5.0),
    ),
  )
  assert_true(
    near_d(
      rounded_rect_sdf(19.0, 9.0, 20.0, 10.0, 999.0),
      rounded_rect_sdf(19.0, 9.0, 20.0, 10.0, 5.0),
    ),
  )
  // 超大 radius 不能把内部点算成"在外"
  assert_true(rounded_rect_sdf(10.0, 5.0, 20.0, 10.0, 999.0) < 0.0)
  // 也不能把远处外部点算成"在内"
  assert_true(rounded_rect_sdf(0.0 - 50.0, 0.0 - 50.0, 20.0, 10.0, 999.0) > 0.0)
}


///|
/// 造一个蒙版值（只测覆盖度，与层无关）。
fn mm(kind : @core.ShapeKind, w : Double, h : Double, feather : Double, roughen : Double) -> @core.LayerMask {
  { kind, x: 0.0, y: 0.0, w, h, radius: 0.0, feather, roughen, invert: false }
}

///|
/// 造一个带蒙版的层（`mask_cover_at` 只读 `l.mask`）。
fn ml(m : @core.LayerMask) -> @core.Layer {
  { ..@core.default_layer("m", "m", 0.0, 0.0, 100.0, 100.0), mask: Some(m) }
}

///|
test "毛边：roughen=0 时逐位走老路径（边界点上与『内距 > 0』不等价，别顺手改判据）" {
  // 这条守的是**兼容承诺**：`roughen` 与 `feather` 都是"0 = 历史行为"。
  // 实测差别就在边界点上：矩形蒙版 x=0 时 `px=0.0` 这个点，
  //   * 老路径（`inside`：dx>=0 && dx<w）→ 覆盖 1；
  //   * 若把硬边重写成 `内距 > 0` → 内距恰好 0 → 覆盖 0。
  // 一个像素的差别肉眼看不出来，但"逐位不变"的承诺就断了。
  let l = ml(mm(@core.ShapeKind::Rect, 10.0, 10.0, 0.0, 0.0))
  assert_eq(mask_cover_at(l, 0.0, 5.0), 1.0, msg="左边界（含）应在内")
  assert_eq(mask_cover_at(l, 10.0, 5.0), 0.0, msg="右边界（不含）应在外")
  assert_eq(mask_cover_at(l, 5.0, 0.0), 1.0)
  assert_eq(mask_cover_at(l, 5.0, 10.0), 0.0)
  assert_eq(mask_cover_at(l, 5.0, 5.0), 1.0)
  assert_eq(mask_cover_at(l, 0.0 - 0.5, 5.0), 0.0)
}

///|
test "毛边：确定性（同一点多次取值一致、与调用顺序无关、幅度有界）" {
  let amp = 3.0
  // 幅度上界：|偏移| ≤ roughen
  for i in 0..<200 {
    let x = i.to_double() * 1.7
    let y = (i * 3 % 97).to_double() * 0.9
    let off = mask_edge_offset(amp, x, y)
    assert_true(off >= 0.0 - amp && off <= amp, msg="偏移必须在 [-amp, amp] 内：\{off}")
  }
  // 同一点 → 同一个值；中间穿插别的点不影响（无隐藏状态）
  let a = mask_edge_offset(amp, 12.25, 7.5)
  let _ = mask_edge_offset(amp, 999.0, 1.0)
  let b = mask_edge_offset(amp, 12.25, 7.5)
  assert_eq(a, b, msg="噪声必须是纯函数（同点同值）")
  // 幅度为 0 → 恒 0（不引入任何扰动）
  assert_eq(mask_edge_offset(0.0, 12.25, 7.5), 0.0)
  // 噪声真的在动（不是常数）：相邻晶格上的值不全相同
  let mut differing = 0
  for i in 0..<32 {
    let v0 = mask_edge_offset(amp, i.to_double() * 4.0, 0.0)
    let v1 = mask_edge_offset(amp, (i + 1).to_double() * 4.0, 0.0)
    if v0 != v1 {
      differing = differing + 1
    }
  }
  assert_true(differing >= 20, msg="相邻晶格取值几乎都该不同，实际只有 \{differing}/32")
  // 与具体数值钉死的回归点：跨 target（native / wasm-gc）必须给出同一个值
  // ——哈希全部走 24 位掩码整数乘法，不依赖 Int 是 32 位还是 64 位。
  // 这个常数是**实测出来的**（改哈希 = 毛边图案全变 = 渲染 sha 全变，
  // 必须是有意为之）。
  assert_true(near_d(mask_edge_offset(1.0, 2.0, 3.0), PINNED_OFFSET), msg="毛边噪声值漂移了：\{mask_edge_offset(1.0, 2.0, 3.0)}")
}

///|
test "毛边：只啃边界（内部/远处不受影响），且真的改变了边界像素" {
  let w = 40.0
  let h = 40.0
  let smooth = ml(mm(@core.ShapeKind::Rect, w, h, 0.0, 0.0))
  let rough = ml(mm(@core.ShapeKind::Rect, w, h, 0.0, 3.0))
  let mut flipped = 0
  let mut deep_in_bad = 0
  let mut deep_out_bad = 0
  let mut y = 0
  while y < 40 {
    let mut x = 0
    while x < 40 {
      let px = x.to_double() + 0.5
      let py = y.to_double() + 0.5
      let a = mask_cover_at(smooth, px, py)
      let b = mask_cover_at(rough, px, py)
      if a != b {
        flipped = flipped + 1
      }
      // 离边界 4px 以上的内部点必须仍是 1，离边界 4px 以上的外部点必须仍是 0
      // （幅度 3 < 4）：毛边只能啃边界，不能把整块啃穿。
      let inside_deep = px >= 4.0 && px <= w - 4.0 && py >= 4.0 && py <= h - 4.0
      if inside_deep && b != 1.0 {
        deep_in_bad = deep_in_bad + 1
      }
      let outside_deep = px < 0.0 - 1.0 || px > w + 1.0 || py < 0.0 - 1.0 || py > h + 1.0
      if outside_deep && b != 0.0 {
        deep_out_bad = deep_out_bad + 1
      }
      x = x + 1
    }
    y = y + 1
  }
  assert_true(flipped > 20, msg="毛边必须真的改变边界像素，实际只改了 \{flipped} 个")
  assert_eq(deep_in_bad, 0, msg="深处内部不许被啃掉")
  assert_eq(deep_out_bad, 0, msg="远处外部不许被啃进来")
}

///|
test "毛边：与 feather 叠加（先毛化再羽化）——过渡带仍在，且不是二值" {
  let l = ml(mm(@core.ShapeKind::Rect, 40.0, 40.0, 6.0, 2.0))
  let mut mid = 0
  let mut y = 0
  while y < 40 {
    let mut x = 0
    while x < 40 {
      let c = mask_cover_at(l, x.to_double() + 0.5, y.to_double() + 0.5)
      if c > 0.0 && c < 1.0 {
        mid = mid + 1
      }
      x = x + 1
    }
    y = y + 1
  }
  assert_true(mid > 100, msg="羽化过渡带必须还在（先毛化再羽化），实际 \{mid} 个中间值像素")
}

///|
test "毛边：椭圆路径同样吃 roughen，且 invert 与之正交" {
  let e_smooth = ml(mm(@core.ShapeKind::Ellipse, 40.0, 40.0, 0.0, 0.0))
  let e_rough = ml(mm(@core.ShapeKind::Ellipse, 40.0, 40.0, 0.0, 2.5))
  let mut flipped = 0
  let mut y = 0
  while y < 40 {
    let mut x = 0
    while x < 40 {
      let px = x.to_double() + 0.5
      let py = y.to_double() + 0.5
      if mask_cover_at(e_smooth, px, py) != mask_cover_at(e_rough, px, py) {
        flipped = flipped + 1
      }
      x = x + 1
    }
    y = y + 1
  }
  assert_true(flipped > 10, msg="椭圆边界也该被毛化，实际 \{flipped} 个")
  // invert 与毛边正交：反选后的覆盖 = 1 − 未反选覆盖（逐点）
  let inv = { ..mm(@core.ShapeKind::Rect, 40.0, 40.0, 4.0, 3.0), invert: true }
  let plain = mm(@core.ShapeKind::Rect, 40.0, 40.0, 4.0, 3.0)
  assert_true(
    near_d(mask_cover_at(ml(inv), 7.0, 9.0), 1.0 - mask_cover_at(ml(plain), 7.0, 9.0)),
    msg="invert 必须是 1−覆盖（含毛边）",
  )
}