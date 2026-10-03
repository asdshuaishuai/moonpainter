///|
/// **预解算帧**（`Frame`）：祖先链里每一级只带"翻转 + 旋转角 + 算好一次的轴心"。
///
/// 这条测试钉两件事：
/// ① 轴心来自 `@core.effective_box`（组的盒子 = 成员的并集、**实时派生**），
///    不是 `Layer` 里存的那份快照——组盒故意写成画布尺寸，轴心仍须是内容中心；
/// ② 正逆两个方向（`to_local_frame` / `to_canvas_frame_pt`）读的是**同一个
///    `Frame`**，所以"同一个轴心"不再靠人自觉（原先两处各 `effective_box`
///    一遍，PLAN 五十六那条教训）。

///|
/// 一个 100×100 的组，**存下来的**盒子是画布尺寸，内容只在 (10,10)-(70,20)。
fn fw_grp() -> @core.Layer {
  let r = {
    ..@core.default_layer("r", "r", 10.0, 10.0, 60.0, 10.0),
    fill: @core.Fill::Solid(0xFFFF0000),
  }
  {
    ..@core.default_layer("g1", "g1", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Group,
    children: [r],
    rotation_deg: 90.0,
    flip_v: true,
  }
}

///|
test "预解算帧：轴心 = 内容中心（组盒快照是画布尺寸也不许读）" {
  let fr = frame_of(fw_grp())
  // 内容并集 = (10,10,60,10) ⇒ 中心 (40,15)
  assert_eq(fr.cx, 40.0, msg="轴心 x 必须是成员并集的中心，不是 100×100 快照的中心 50")
  assert_eq(fr.cy, 15.0, msg="轴心 y")
  assert_eq(fr.rot, 90.0, msg="旋转角要带过来")
  assert_eq(fr.flip_h, false, msg="flip_h 要带过来（这里没翻）")
  assert_eq(fr.flip_v, true, msg="flip_v 要带过来")
  // 反向也钉一次：轴心若读快照会落在 (50,50)，这两个数当场合不上
  assert_true(fr.cx != 50.0, msg="50 是快照盒的中心（实测过的错法）")
}

///|
test "预解算帧：正逆两个方向同一个轴心（往返=恒等，不经 Layer）" {
  let fr = frame_of(fw_grp())
  // 四个点（含轴心本身与四角）过一遍正变换再逆回来，必须逐个回到原处。
  // 容差按**实测**：`cos_rad`/`sin_rad` 是本仓库的**级数近似**，90° 往返实测漂
  // 7.09e-8（30° 那处实测是 ~1.7e-6，见 PLAN「渲染窗的第三个出口」那一节）
  // ——别写 1e-9 然后以为变换写错了：真正的错（符号/顺序/少一步 flip）差 O(1)。
  for p in [
    (0.0, 0.0),
    (40.0, 15.0),
    (60.0, 10.0),
    (10.0, 20.0),
  ] {
    let (cx, cy) = to_canvas_frame_pt(fr, p.0, p.1)
    let (lx, ly) = to_local_frame(fr, cx, cy)
    let dx = if lx > p.0 { lx - p.0 } else { p.0 - lx }
    let dy = if ly > p.1 { ly - p.1 } else { p.1 - ly }
    assert_true(dx < 1.0e-6, msg="往返 x 漂了 \{dx}（正逆不同轴心就会漂到像素级）")
    assert_true(dy < 1.0e-6, msg="往返 y 漂了 \{dy}")
  }
  // ⚠️ 判别力自证：轴心若读快照（50,50）而不是内容中心（40,15），往返**照样**
  // 是恒等（正逆用的是同一个错值）——所以上面那条只能守"两处一致"，
  // "轴心对不对"由上面那条断言数值的测试守。两条各守一面。
  let fr_wrong : Frame = { ..fr, cx: 50.0, cy: 50.0 }
  let (wx, wy) = to_canvas_frame_pt(fr_wrong, 10.0, 20.0)
  let (ax, ay) = to_canvas_frame_pt(fr, 10.0, 20.0)
  assert_true(
    (wx - ax) * (wx - ax) + (wy - ay) * (wy - ay) > 1.0,
    msg="轴心换了 10px 而落点没变 —— 说明这条测试量的不是轴心",
  )
}
