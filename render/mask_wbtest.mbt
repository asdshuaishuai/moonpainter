/// 圆角矩形内部判定（`rounded_rect_inside`）。
///
/// 这是 `add-mask ... radius=` 唯一的实现点。`radius` 在文档、工具面字典和
/// 容器序列化里被承诺了很久，但**渲染从来没读过它**——用户写 `radius=10`
/// 得到的是硬直角，而且不报错（静默失败）。现在接上了，边界值要钉死：
/// 差一个像素的圆角肉眼看不出来，但"有没有生效"必须能分辨。

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
