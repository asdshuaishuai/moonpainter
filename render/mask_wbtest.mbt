/// 圆角矩形内部判定（`rounded_rect_inside`）。
///
/// 这是 `add-mask ... radius=` 唯一的实现点。`radius` 在文档、工具面字典和
/// 容器序列化里被承诺了很久，但**渲染从来没读过它**——用户写 `radius=10`
/// 得到的是硬直角，而且不报错（静默失败）。现在接上了，边界值要钉死：
/// 差一个像素的圆角肉眼看不出来，但"有没有生效"必须能分辨。

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
