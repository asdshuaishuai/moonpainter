///|
/// **笔触层（raster）的变换链**：dab 存的是**层局部**偏移（`d.x/d.y` 相对
/// `l.x/l.y`），它的**画布**位置必须经 `dab_center` = 「平移 + 整条祖先链」
/// （`to_canvas_in`）算出来。
///
/// 这里抓的是一个真 bug（PLAN 五十八）：`paint_dabs` 原先写死 `l.x + d.x`——
/// 只算了「平移到层位」，**把祖先组的变换漏掉了**。于是 `rotate <组> 90` 而组里
/// 装着笔触层时：回包 `ok`、指纹变了、`query-layer` 报组转了，而**画面逐位不变**
/// （实测 `render_sha256` 前后同一个值）。形状层早就跟着转（`to_local` 一直经
/// 祖先链），只有笔触层是另一条路——同一个判断两处实现，先烂的一定是没人读的
/// 那一处。
///
/// ⚠️ 场景必须**不对称**：单个 dab 是圆斑，rotate/flip 对它本身是恒等变换；
/// 要看出「整层转了」必须让**多个** dab 的位置关系改变（这里是一条斜放的两点
/// 笔迹）。判据咬**实测几何**（下面每个数字都来自一次实测打印），不咬措辞。

///|
fn rdab_paint(dabs : Array[@core.Dab]) -> @core.Layer {
  {
    ..@core.default_layer("p1", "p1", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Raster,
    fill: @core.Fill::NoFill,
    dabs,
  }
}

///|
fn rdab_two() -> Array[@core.Dab] {
  [
    @core.Dab::{ x: 10.0, y: 10.0, r: 6.0, color: 0xFFFF0000, erase: false },
    @core.Dab::{ x: 80.0, y: 20.0, r: 6.0, color: 0xFFFF0000, erase: false },
  ]
}

///|
/// 笔触层包在一个组里（组转 `deg`、翻 `fh/fv`）；组的**盒子快照故意写成画布
/// 尺寸**——轴心必须走 `effective_box`（成员并集），不是这份快照。
fn rdab_grouped(deg : Double, fh : Bool, fv : Bool) -> @core.Document {
  let d = @core.new_document("u-rdab", 100, 100)
  let grp = {
    ..@core.default_layer("grp", "grp", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Group,
    children: [rdab_paint(rdab_two())],
    rotation_deg: deg,
    flip_h: fh,
    flip_v: fv,
  }
  d.layers.push(grp)
  d
}

///|
/// 不在任何组里的同一个笔触层（正控：组不加变换 = 没有组）。
fn rdab_bare() -> @core.Document {
  let d = @core.new_document("u-rdab-bare", 100, 100)
  d.layers.push(rdab_paint(rdab_two()))
  d
}

///|
/// 墨迹的包围盒与像素数（背景是**不透明白** `0xFFFFFFFF`，不是 0——实测踩过：
/// 按 `alpha > 0` 数会把整幅画布算成墨，断言全变空）。
fn rdab_ink(buf : @codec.RgbaBuf) -> (Int, Int, Int, Int, Int) {
  let mut x0 = 9999
  let mut y0 = 9999
  let mut x1 = -1
  let mut y1 = -1
  let mut n = 0
  for y in 0..<100 {
    for x in 0..<100 {
      if buf.pixels[y * 100 + x] != 0xFFFFFFFF {
        n = n + 1
        if x < x0 {
          x0 = x
        }
        if x > x1 {
          x1 = x
        }
        if y < y0 {
          y0 = y
        }
        if y > y1 {
          y1 = y
        }
      }
    }
  }
  (x0, y0, x1, y1, n)
}

///|
fn rdab_diff(a : @codec.RgbaBuf, b : @codec.RgbaBuf) -> Int {
  let mut diff = 0
  let mut i = 0
  while i < a.pixels.length() {
    if a.pixels[i] != b.pixels[i] {
      diff = diff + 1
    }
    i = i + 1
  }
  diff
}

///|
test "组的 rotate 作用到笔触层：dab 走祖先链（原先画面逐位不变）" {
  let env = @render.RenderEnv::new()
  let flat = @render.render_doc(rdab_grouped(0.0, false, false), env)
  let turned = @render.render_doc(rdab_grouped(90.0, false, false), env)
  // 判别力自证：没转与转 90° 必须是**两张图**（这就是原来漏掉的那件事）
  let d0 = rdab_diff(flat, turned)
  assert_true(d0 > 100, msg="组转 90° 只改了 \{d0} 个像素 —— dab 又没走祖先链")
  // 实测几何：横放的 (4,4)..(85,25) ↦ 竖放的 (74,4)..(95,85)
  assert_eq(rdab_ink(flat), (4, 4, 85, 25, 240), msg="不转时的墨迹")
  assert_eq(rdab_ink(turned), (74, 4, 95, 85, 240), msg="转 90° 后的墨迹")
  // **正控**：组不带变换时必须与「压根没有组」逐位相同（祖先链不能自己改画面）
  assert_eq(
    rdab_diff(flat, @render.render_doc(rdab_bare(), env)),
    0,
    msg="不带变换的组必须逐位不变（否则这条测试量的不是「组变换」而是「组」）",
  )
}

///|
test "组的 flip 作用到笔触层：v/h 各一格（镜像也要经祖先链）" {
  let env = @render.RenderEnv::new()
  let flat = @render.render_doc(rdab_grouped(0.0, false, false), env)
  let fv = @render.render_doc(rdab_grouped(0.0, false, true), env)
  let fh = @render.render_doc(rdab_grouped(0.0, true, false), env)
  // 实测几何：绕组盒中心 (50,50) 镜像
  assert_eq(rdab_ink(fv), (4, 74, 85, 95, 240), msg="flip_v 后的墨迹")
  assert_eq(rdab_ink(fh), (14, 4, 95, 25, 240), msg="flip_h 后的墨迹")
  let dv = rdab_diff(flat, fv)
  assert_true(dv > 100, msg="flip_v 没改画面（只改了 \{dv} 个像素）")
  let dh = rdab_diff(flat, fh)
  assert_true(dh > 100, msg="flip_h 没改画面（只改了 \{dh} 个像素）")
  // **两级各翻一次 = 恒等**（逐位相同）：这是 `to_canvas_in`/`to_local_in` 成对
  // 的一条硬判据——`flip_h` 是 Bool，写到同一层上"翻两遍"就等于没翻，只有
  // 把两次镜像放进**两级容器**里才真的考到链上的正逆是否成对。
  let d2 = @core.new_document("u-rdab-2", 100, 100)
  let inner = {
    ..@core.default_layer("gi", "gi", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Group,
    children: [rdab_paint(rdab_two())],
    flip_h: true,
  }
  let outer = {
    ..@core.default_layer("go", "go", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Group,
    children: [inner],
    flip_h: true,
  }
  d2.layers.push(outer)
  assert_eq(
    rdab_diff(flat, @render.render_doc(d2, env)),
    0,
    msg="两级各 flip_h 一次必须回到原图（正逆成对）",
  )
}

///|
test "嵌套组：祖先链逐级叠加，90°+90° 与单层 180° 逐位相同" {
  let env = @render.RenderEnv::new()
  let d = @core.new_document("u-rdab-nest", 100, 100)
  let gi = {
    ..@core.default_layer("gi", "gi", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Group,
    children: [rdab_paint(rdab_two())],
    rotation_deg: 90.0,
  }
  let go = {
    ..@core.default_layer("go", "go", 0.0, 0.0, 100.0, 100.0),
    kind: @core.ShapeKind::Group,
    children: [gi],
    rotation_deg: 90.0,
  }
  d.layers.push(go)
  let nested = @render.render_doc(d, env)
  // 实测几何：与单层 180° 完全一致（(14,74)..(95,95)）
  assert_eq(rdab_ink(nested), (14, 74, 95, 95, 240), msg="嵌套 90+90 的墨迹")
  assert_eq(
    rdab_diff(nested, @render.render_doc(rdab_grouped(180.0, false, false), env)),
    0,
    msg="两级各 90° 必须与一级 180° 逐位相同（级联唯一实现）",
  )
}

///|
test "pick 与渲染同一把尺子：转过之后报的是**新**位置" {
  let flat = rdab_grouped(0.0, false, false)
  let turned = rdab_grouped(90.0, false, false)
  // 不转时 (10,10) 在墨上（组盒 = 画布 ⇒ 组内点 = 画布点）
  assert_eq(@render.pick(flat, 10.0, 10.0), Some("p1"), msg="不转时 (10,10) 该拾到 p1")
  // 转 90° 之后原来那点在墨外、实测的新位置在墨上
  assert_eq(@render.pick(turned, 10.0, 10.0), None, msg="转过之后旧位置该空了")
  assert_eq(@render.pick(turned, 90.0, 10.0), Some("p1"), msg="转过之后新位置该拾到 p1")
  assert_eq(@render.pick(turned, 80.0, 80.0), Some("p1"), msg="转过之后另一个 dab 的新位置")
  // ⚠️ 判别力自证：这条在**修复前**是绿的（旧代码把 dab 留在原地不动 ⇒ 反而"对"）
  assert_eq(@render.pick(flat, 80.0, 80.0), None, msg="不转时 (80,80) 是空的（新位置只在转过之后有墨）")
}
