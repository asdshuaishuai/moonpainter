///|
/// **组的变换**（rot/flip）测试：组自己没画面，但它的变换要作用到**整棵子树**——
/// 渲染器把组压进"祖先变换链"（`to_local_in`），子层的 `to_local` 就会经过它。
/// 与 `agent.shift_layer_tree`（写侧：搬内容）对称的是这里的**读侧**。
///
/// ⚠️ 判据必须让"旋转"与"不旋转"给出**不同**的画面，而且要选在**判据边界**上：
/// 整块纯色方块的 rotate/flip 是**恒等变换**（这个坑在 `agent/ops.mbt` 的读点
/// 矩阵注释里记过），所以场景用**不对称**的长条 + 左右颜色不同。
test "组的 rotate：整棵子树跟着转（绕组矩形中心）" {
  let mk = fn(deg : Double) -> @core.Document {
    let d = @core.new_document("u-grot", 100, 100)
    // 60×10 的红条贴在左上角；下面 40px 处一条蓝条当"没被转"的参照
    let r = {
      ..@core.default_layer("r", "r", 0.0, 0.0, 60.0, 10.0),
      fill: @core.Fill::Solid(0xFFFF0000),
    }
    let grp = {
      ..@core.default_layer("g1", "g1", 0.0, 0.0, 60.0, 10.0),
      kind: @core.ShapeKind::Group,
      children: [r],
      rotation_deg: deg,
    }
    d.layers.push(grp)
    d
  }
  let env = @render.RenderEnv::new()
  let flat = @render.render_doc(mk(0.0), env)
  let turned = @render.render_doc(mk(90.0), env)
  // 判别力自证：两张图必须真的不同（否则下面断言是空的）
  let mut diff = 0
  let mut i = 0
  while i < 100 * 100 {
    if flat.pixels[i] != turned.pixels[i] {
      diff = diff + 1
    }
    i = i + 1
  }
  assert_true(diff > 100, msg="转 90° 只改了 \{diff} 个像素 —— 组的变换没生效")
  // 组盒 60×10、中心 (30,5)：横条 `x∈[0,60), y∈[0,10)` 绕 (30,5) 转 90° 后
  // 局部点 (x,y) ↦ 画布 (30+(y−5), 5−(x−30)) ⇒ **竖条 x∈[25,35)、y∈[−25,35)**
  // ——实测红像素包围盒正是 `x=25..34, y=0..34`（上半被画布裁掉，350 = 10×35）。
  // ⚠️ 断言按**实测**写：这组数字同时证明了"内容真的被转了"（否则是 60×10 的横条）
  assert_eq(@codec.rgba_get(flat, 5, 5), 0xFFFF0000, msg="前置状态：没转时 (5,5) 是红")
  assert_eq(@codec.rgba_get(turned, 30, 2), 0xFFFF0000, msg="转后竖条该盖到 (30,2)")
  assert_eq(@codec.rgba_get(turned, 30, 34), 0xFFFF0000, msg="转后竖条下端 (30,34) 仍是红")
  assert_eq(@codec.rgba_get(turned, 5, 5), 0xFFFFFFFF, msg="转后原点附近该空了（横条不在了）")
  // 边界要**两头咬**：竖条左侧 (24,5) 与右侧 (35,5) 必须是白（宽 10px 的竖条）
  assert_eq(@codec.rgba_get(turned, 24, 5), 0xFFFFFFFF, msg="竖条左边界之外是白")
  assert_eq(@codec.rgba_get(turned, 35, 5), 0xFFFFFFFF, msg="竖条右边界之外是白")
  assert_eq(@codec.rgba_get(turned, 30, 35), 0xFFFFFFFF, msg="竖条下端之外是白")
}

///|
test "组的 flip：整棵子树跟着镜像（子层的局部坐标被镜像）" {
  let mk = fn(flip : Bool) -> @core.Document {
    let d = @core.new_document("u-gflip", 60, 40)
    // 左右颜色不同的两条：镜像后它们必须**换位**（纯色方块是恒等变换，测不出来）
    let left = {
      ..@core.default_layer("L", "L", 0.0, 0.0, 30.0, 40.0),
      fill: @core.Fill::Solid(0xFFFF0000),
    }
    let right = {
      ..@core.default_layer("R", "R", 30.0, 0.0, 30.0, 40.0),
      fill: @core.Fill::Solid(0xFF00FF00),
    }
    let grp = {
      ..@core.default_layer("g1", "g1", 0.0, 0.0, 60.0, 40.0),
      kind: @core.ShapeKind::Group,
      children: [left, right],
      flip_h: flip,
    }
    d.layers.push(grp)
    d
  }
  let env = @render.RenderEnv::new()
  let plain = @render.render_doc(mk(false), env)
  let mir = @render.render_doc(mk(true), env)
  assert_eq(@codec.rgba_get(plain, 10, 20), 0xFFFF0000, msg="前置状态：没翻时左边红")
  assert_eq(@codec.rgba_get(plain, 50, 20), 0xFF00FF00, msg="前置状态：没翻时右边绿")
  assert_eq(@codec.rgba_get(mir, 10, 20), 0xFF00FF00, msg="翻后左边该是原来的右边（绿）")
  assert_eq(@codec.rgba_get(mir, 50, 20), 0xFFFF0000, msg="翻后右边该是原来的左边（红）")
}

///|
test "组的变换链：嵌套组的变换逐级叠加（父子各转 90° ⇒ 子层共 180°）" {
  let mk = fn(outer_deg : Double, inner_deg : Double) -> @core.Document {
    let d = @core.new_document("u-gnest", 100, 100)
    // ⚠️ 内容必须**左右不对称**：纯色横条转 180° 后逐位不变（旋转是恒等变换），
    // 那样"逐级叠加"这条判据会退化成空的——实测第一版就是 0 个像素差。
    // 左右两段不同色 ⇒ 180° 后必须互换。
    let hl = {
      ..@core.default_layer("hl", "hl", 0.0, 0.0, 30.0, 10.0),
      fill: @core.Fill::Solid(0xFFFF0000),
    }
    let hr = {
      ..@core.default_layer("hr", "hr", 30.0, 0.0, 30.0, 10.0),
      fill: @core.Fill::Solid(0xFF0000FF),
    }
    let inner = {
      ..@core.default_layer("gi", "gi", 0.0, 0.0, 60.0, 10.0),
      kind: @core.ShapeKind::Group,
      children: [hl, hr],
      rotation_deg: inner_deg,
    }
    let outer = {
      ..@core.default_layer("go", "go", 0.0, 0.0, 60.0, 10.0),
      kind: @core.ShapeKind::Group,
      children: [inner],
      rotation_deg: outer_deg,
    }
    d.layers.push(outer)
    d
  }
  let env = @render.RenderEnv::new()
  let zero = @render.render_doc(mk(0.0, 0.0), env)
  let both90 = @render.render_doc(mk(90.0, 90.0), env)
  // 两级各 90° ⇒ **合成 180°**（不是 0°、也不是 90°）：绕 (30,5) 转 180° 后，
  // 横条仍是 `x∈[0,60), y∈[0,10)` 这块**区域**，但内容**左右上下都翻了个身**。
  // 用不对称内容判：把右半段染成另一种颜色，180° 后左右必须互换。
  let mut diff = 0
  let mut i = 0
  while i < 100 * 100 {
    if zero.pixels[i] != both90.pixels[i] {
      diff = diff + 1
    }
    i = i + 1
  }
  assert_true(diff > 50, msg="父子各转 90° 应合成 180°，实际只改了 \{diff} 个像素")
  // 180° 绕 (30,5)：左半红（x∈[0,30)）该跑到右半，右半蓝该跑到左半
  assert_eq(@codec.rgba_get(zero, 5, 5), 0xFFFF0000, msg="前置状态：(5,5) 是红（左半）")
  assert_eq(@codec.rgba_get(zero, 55, 5), 0xFF0000FF, msg="前置状态：(55,5) 是蓝（右半）")
  assert_eq(@codec.rgba_get(both90, 5, 5), 0xFF0000FF, msg="180° 后 (5,5) 该是原来的右半蓝")
  assert_eq(@codec.rgba_get(both90, 55, 5), 0xFFFF0000, msg="180° 后 (55,5) 该是原来的左半红")
  // 只转一级 90° 与转两级 180° 必须是**不同**的画面（否则"逐级叠加"没被验到）
  let one90 = @render.render_doc(mk(90.0, 0.0), env)
  let mut d2 = 0
  let mut k = 0
  while k < 100 * 100 {
    if one90.pixels[k] != both90.pixels[k] {
      d2 = d2 + 1
    }
    k = k + 1
  }
  assert_true(d2 > 50, msg="一级 90° 与两级 180° 该不同，实际只差 \{d2} 个像素")
}

///|
test "组的变换与 pick 同一把尺子：转过之后 pick 报的是**新的**位置" {
  let d = @core.new_document("u-gpick", 100, 100)
  let r = {
    ..@core.default_layer("r", "r", 0.0, 0.0, 60.0, 10.0),
    fill: @core.Fill::Solid(0xFFFF0000),
  }
  let grp = {
    ..@core.default_layer("g1", "g1", 0.0, 0.0, 60.0, 10.0),
    kind: @core.ShapeKind::Group,
    children: [r],
    rotation_deg: 90.0,
  }
  d.layers.push(grp)
  // 转后竖条在 `x∈[25,35)、y∈[0,35)`（实测几何同上）：那里该拾到 r，
  // 原点附近（原来的位置）该拾不到——`pick` 与渲染必须是同一把尺子
  assert_eq(@render.pick(d, 30.0, 3.0), Some("r"), msg="转后的位置该拾到子层")
  assert_eq(@render.pick(d, 5.0, 5.0), None, msg="转走的位置不该再拾到（pick 与渲染同一把尺子）")
  assert_eq(@render.pick(d, 30.0, 40.0), None, msg="竖条范围外不该拾到")
  assert_eq(@render.pick(d, 24.0, 5.0), None, msg="竖条左边界外不该拾到")
}
