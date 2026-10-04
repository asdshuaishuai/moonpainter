///|
/// **笔触层的变换链**：dab 存的是**层局部**偏移（`d.x/d.y` 相对 `l.x/l.y`），
/// 它的**画布**位置要经两段——①本层的 rot/flip（绕 `local_pivot`）②整条祖先链
/// （`to_canvas_in`）。两段各对应一个真 bug：
///   * 漏掉祖先链（PLAN 五十八）：`rotate <组> 90` 回 ok、指纹变了、画面逐位不变；
///   * 漏掉本层（PLAN 六十）：`rotate <笔触层> 90` 同病——而它的轴心还必须是
///     **落笔范围中心**（`effective_box` 认 Raster），不是画布中心。
///
/// ⚠️ 场景必须**不对称**：单个 dab 是圆斑，rotate/flip 对圆斑本身是恒等变换；
/// 要看出"整层转了"必须让**多个** dab 的位置关系改变。判据咬**实测几何**与
/// **逐像素差**（下面每个数字都来自一次实测打印），不咬措辞。
///
/// ⚠️ **包围盒对"保中心"的变换没有判别力**：flip 与 180° 都把"以轴心为中心的
/// 盒"映到它自己 ⇒ 包围盒**必然**与不转时相同（实测那几格都是 `(24,24,71,65)`）。
/// 所以那几格靠**点探针**（某点的墨去了哪）+ 逐像素差来咬，别拿盒当判据。

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
/// 三个 dab：局部 (30,30)、(66,46)、(45,60)，半径 6。落笔范围 = (24,24)-(72,66)
/// ⇒ 轴心 **(48,45)**；三格两两不重叠 ⇒ 每格 120 像素、共 **360**。
/// 取奇数个且不对称，是为了让 flip/180 的点集真的变（两个对称的 dab 转 180°
/// 会**逐位相同**，那就不再是判据）。
fn rdab_two() -> Array[@core.Dab] {
  [
    @core.Dab::{ x: 30.0, y: 30.0, r: 6.0, color: 0xFFFF0000, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
    @core.Dab::{ x: 66.0, y: 46.0, r: 6.0, color: 0xFFFF0000, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
    @core.Dab::{ x: 45.0, y: 60.0, r: 6.0, color: 0xFFFF0000, erase: false, clone: false, sdx: 0.0, sdy: 0.0 },
  ]
}

///|
/// 笔触层包在一个组里（组转 `deg`、翻 `fh/fv`）；组的**盒子快照故意写成画布
/// 尺寸**——轴心必须走 `effective_box`（成员的并集，成员是笔触层时 = 落笔范围）。
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
/// **本层自己**转 `deg` 翻 `fv`（不经任何组）。
fn rdab_self(deg : Double, fv : Bool) -> @core.Document {
  let d = @core.new_document("u-rdab-self", 100, 100)
  let l = {
    ..rdab_paint(rdab_two()),
    rotation_deg: deg,
    flip_v: fv,
  }
  d.layers.push(l)
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
/// 单点有没有墨——**保中心变换**唯一有判别力的几何判据（见文件头那条警告）。
fn rdab_at(buf : @codec.RgbaBuf, x : Int, y : Int) -> Bool {
  buf.pixels[y * 100 + x] != 0xFFFFFFFF
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
  // 实测几何：轴心 (48,45)、绕它转 90°（y 轴向下 ⇒ 顺时针）
  assert_eq(rdab_ink(flat), (24, 24, 71, 65, 360), msg="不转时的墨迹")
  assert_eq(rdab_ink(turned), (27, 21, 68, 68, 360), msg="转 90° 后的墨迹")
  // 点探针：dab (30,30) 绕 (48,45) 转 90° ↦ (63,27)
  assert_true(rdab_at(flat, 30, 30), msg="不转时 (30,30) 是 dab 心")
  assert_true(!rdab_at(flat, 63, 27), msg="不转时 (63,27) 是空的（否则下面一条没判别力）")
  assert_true(rdab_at(turned, 63, 27), msg="转 90° 后 (30,30) 该落在 (63,27)")
  assert_true(!rdab_at(turned, 30, 30), msg="转 90° 后原位该空了")
  // 像素数**恰好不变**：轴心是整数点 ⇒ 2×2 子样本 ({0.25,0.75}²) 在绕整数点
  // 转 90° 下映射到自身，覆盖度逐点守恒；而且这一转没有任何 dab 出画布
  assert_eq(rdab_ink(flat).4, rdab_ink(turned).4, msg="转 90° 不该多也不该少一个像素")
  // **正控**：组不带变换时必须与「压根没有组」逐位相同（祖先链不能自己改画面）
  assert_eq(
    rdab_diff(flat, @render.render_doc(rdab_bare(), env)),
    0,
    msg="不带变换的组必须逐位不变（否则这条测试量的不是「组变换」而是「组」）",
  )
}

///|
test "组的 flip 与 180°：包围盒必然相同，靠点探针与逐像素差咬" {
  let env = @render.RenderEnv::new()
  let flat = @render.render_doc(rdab_grouped(0.0, false, false), env)
  let fv = @render.render_doc(rdab_grouped(0.0, false, true), env)
  let fh = @render.render_doc(rdab_grouped(0.0, true, false), env)
  let r180 = @render.render_doc(rdab_grouped(180.0, false, false), env)
  // 包围盒四格相同（**这不是判据**，是"保中心"的必然结果，写出来是为了别让人
  // 误以为它咬住了什么）
  for b in [fv, fh, r180] {
    assert_eq(rdab_ink(b), (24, 24, 71, 65, 360), msg="保中心变换的盒必然与不转相同")
  }
  // 点探针：flip_v 绕 y=45 镜像 —— dab (30,30) ↦ (30,60)
  assert_true(!rdab_at(flat, 30, 60), msg="不转时 (30,60) 是空的")
  assert_true(rdab_at(fv, 30, 60), msg="flip_v 后 (30,30) 该落在 (30,60)")
  assert_true(!rdab_at(fv, 30, 30), msg="flip_v 后原位该空了")
  // flip_h 绕 x=48 镜像 —— dab (30,30) ↦ (66,30)
  assert_true(rdab_at(fh, 66, 30), msg="flip_h 后 (30,30) 该落在 (66,30)")
  assert_true(!rdab_at(fh, 30, 30), msg="flip_h 后原位该空了")
  // 180° —— dab (30,30) ↦ (66,60)
  assert_true(!rdab_at(flat, 66, 60), msg="不转时 (66,60) 是空的")
  assert_true(rdab_at(r180, 66, 60), msg="180° 后 (30,30) 该落在 (66,60)")
  // 三种变换都必须真的改画面（逐像素差）
  for pair in [("flip_v", fv), ("flip_h", fh), ("180", r180)] {
    let d = rdab_diff(flat, pair.1)
    assert_true(d > 100, msg="\{pair.0} 只改了 \{d} 个像素 —— 变换没走到 dab 上")
  }
  // **两级各翻一次 = 恒等**（逐位相同）：`flip_h` 是 Bool，写到同一层上"翻两遍"
  // 就等于没翻，只有把两次镜像放进**两级容器**里才真的考到链上的正逆是否成对。
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
  assert_eq(rdab_ink(nested), (24, 24, 71, 65, 360), msg="嵌套 90+90 的墨迹")
  assert_eq(
    rdab_diff(nested, @render.render_doc(rdab_grouped(180.0, false, false), env)),
    0,
    msg="两级各 90° 必须与一级 180° 逐位相同（级联唯一实现）",
  )
}

///|
test "笔触层**自己**的 rotate/flip：轴心 = 落笔范围中心，且与组转同一条路径" {
  let env = @render.RenderEnv::new()
  let flat = @render.render_doc(rdab_bare(), env)
  let turned = @render.render_doc(rdab_self(90.0, false), env)
  // 本层绕 (48,45) 转 90° 与"组绕 (48,45) 转 90°"必须**逐位相同**：
  // 两条路径（`local_pivot` 与 `frame_of`）读的是同一个 `effective_box`。
  // 这条断言钉住"两处一致"；轴心的**数值**由下面那条包围盒断言守
  // （只写"两边一致"会被"两边一起错"骗过）。
  assert_eq(
    rdab_diff(turned, @render.render_doc(rdab_grouped(90.0, false, false), env)),
    0,
    msg="本层转 90° 与组转 90° 必须是同一张图（同一个轴心）",
  )
  assert_eq(rdab_ink(turned), (27, 21, 68, 68, 360), msg="本层转 90° 的墨迹")
  assert_true(rdab_at(flat, 30, 30), msg="不转时 (30,30) 是 dab 心")
  assert_true(!rdab_at(turned, 30, 30), msg="本层转 90° 后原位该空了")
  assert_true(rdab_at(turned, 63, 27), msg="本层转 90° 后 (30,30) 该落在 (63,27)")
  // flip_v 绕 y=45
  let fv = @render.render_doc(rdab_self(0.0, true), env)
  assert_true(rdab_at(fv, 30, 60), msg="本层 flip_v 后 (30,30) 该落在 (30,60)")
  assert_eq(rdab_ink(fv).4, 360, msg="flip 下像素数恰好不变")
}

///|
test "笔触层的盒子是**派生**的：resize 只改快照，画面逐位不变" {
  let env = @render.RenderEnv::new()
  let before = @render.render_doc(rdab_bare(), env)
  // 显式 `w/h` 是 `add-paint` 那份快照；它不参与渲染（窗口是落笔范围），
  // 也不参与报告（`query-layer` 走 `effective_box`）⇒ 改了画面必须逐位不变。
  // 这正是 `caps` 对 raster 说"没有 resize"的实物证据（对照测试要求
  // "说没有 ⇒ 逐位相同"）。
  let d = @core.new_document("u-rdab-resize", 100, 100)
  let l = {
    ..rdab_paint(rdab_two()),
    w: 20.0,
    h: 20.0,
  }
  d.layers.push(l)
  let after = @render.render_doc(d, env)
  assert_eq(rdab_diff(before, after), 0, msg="改盒子不该动画面（盒子是派生的）")
  assert_eq(rdab_ink(after), (24, 24, 71, 65, 360), msg="派生盒仍报落笔范围")
}

///|
test "pick 与渲染同一把尺子：转过之后报的是**新**位置" {
  let flat = rdab_grouped(0.0, false, false)
  let turned = rdab_grouped(90.0, false, false)
  // 不转时 (30,30) 在墨上（组盒 = 落笔范围 ⇒ 组内点 = 画布点）
  assert_eq(@render.pick(flat, 30.0, 30.0), Some("p1"), msg="不转时 (30,30) 该拾到 p1")
  // 转 90° 之后原来那点在墨外、实测的新位置在墨上
  assert_eq(@render.pick(turned, 30.0, 30.0), None, msg="转过之后旧位置该空了")
  assert_eq(@render.pick(turned, 63.0, 27.0), Some("p1"), msg="转过之后新位置该拾到 p1")
  // ⚠️ 判别力自证：这条在**修复前**是绿的（旧代码把 dab 留在原地不动 ⇒ 反而"对"）
  assert_eq(@render.pick(flat, 63.0, 27.0), None, msg="新位置只在转过之后有墨")
}
