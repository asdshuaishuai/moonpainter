///|
fn ttx(mask_w : Double) -> @core.Layer {
  let l = {
    ..@core.default_layer("t1", "T", 20.0, 20.0, 24.0, 28.0),
    kind: @core.ShapeKind::Text,
    text: "H",
    font_size: 28.0,
    fill: @core.Fill::Solid(0xFF000000),
  }
  if mask_w <= 0.0 {
    l
  } else {
    {
      ..l,
      mask: Some(
        @core.LayerMask::{
          kind: @core.ShapeKind::Rect,
          x: 0.0,
          y: 0.0,
          w: mask_w,
          h: 28.0,
          radius: 0.0,
          feather: 0.0,
          roughen: 0.0,
          invert: false,
        },
      ),
    }
  }
}

///|
fn ttx_doc(id : String, deg : Double, fh : Bool, fv : Bool) -> @core.Document {
  let d = @core.new_document(id, 100, 100)
  d.layers.push({ ..ttx(0.0), rotation_deg: deg, flip_h: fh, flip_v: fv })
  d
}

///|
/// **祖先链**那一格：变换装在**组**上、子层一个字段都不带。
/// ⚠️ 第一版把 `rotation_deg` 装在了子层上（组不带变换），于是这一格是**空的**
/// ——变异 Q84（文本丢掉 `frames`）照样全绿。这与 PLAN 五十七"探针恰好没旋转"
/// 是同一课：**验证某条路径时，先确认探针的输入真的走了那条路径**。
fn ttx_group_doc(id : String, deg : Double, fh : Bool, fv : Bool) -> @core.Document {
  let d = @core.new_document(id, 100, 100)
  d.layers.push({
    ..@core.default_layer("g1", "g", 20.0, 20.0, 24.0, 28.0),
    kind: @core.ShapeKind::Group,
    children: [ttx(0.0)],
    rotation_deg: deg,
    flip_h: fh,
    flip_v: fv,
  })
  d
}

///|
fn ttx_ink(buf : @codec.RgbaBuf) -> (Int, Int, Int, Int, Int) {
  let mut x0 = 9999
  let mut y0 = 9999
  let mut x1 = -1
  let mut y1 = -1
  let mut n = 0
  for y in 0..<100 {
    for x in 0..<100 {
      if buf.pixels[y * 100 + x] != 0xFFFFFFFF {
        n = n + 1
        if x < x0 { x0 = x }
        if x > x1 { x1 = x }
        if y < y0 { y0 = y }
        if y > y1 { y1 = y }
      }
    }
  }
  (x0, y0, x1, y1, n)
}

///|
/// 单点有没有墨——**保中心**的变换（flip/180°）上包围盒没有判别力，
/// 这里也是点探针唯一有判别力的地方。
fn ttx_at(buf : @codec.RgbaBuf, x : Int, y : Int) -> Bool {
  buf.pixels[y * 100 + x] != 0xFFFFFFFF
}

///|
/// 不转的基准图。字形 `H = [17,17,31,17,17]`（5 列 × 行 2..6）：cols 0/1/3/4
/// 只有行 2 与 6（**上下两条横杠**）、col 2 是**整条竖笔**——实测形状，不是
/// 照字母形状猜的那个"两条竖笔 + 中间横杠"。
fn ttx_flat_doc(uuid : String) -> @core.Document {
  ttx_doc(uuid, 0.0, false, false)
}

///|
test "文本层自己的 rotate/flip：字形逐点过完整变换链（原先画面逐位不变）" {
  // 这一步之前 `rotate t1 90` 在**入口就被拒**（读点矩阵里 text 不在允许集合里），
  // 而 `rotate <装着文本的组> 90` 回 ok、指纹变了、**画面逐位不变**——字形循环
  // 直接算 `l.x + 列*sc`，本层与祖先链的变换一个都不走（PLAN 五十八那颗 dab 的
  // bug 晚了一层）。现在两者都走 `canvas_to_layer`。
  let env = @render.RenderEnv::new()
  let flat = @render.render_doc(ttx_flat_doc("ttx-flat"), env)
  let r90 = @render.render_doc(ttx_doc("ttx-r90", 90.0, false, false), env)
  // 实测几何（100×100，字盒 24×28 ⇒ 轴心 (32,34)）：
  //   不转 (20,28)..(39,47) 墨 208；自转 90° (18,22)..(38,42) 墨 208（守恒，见下）
  assert_eq(ttx_ink(flat), (20, 28, 39, 47, 208), msg="不转时的墨迹")
  assert_eq(ttx_ink(r90), (18, 22, 38, 42, 208), msg="转 90° 后的墨迹")
  // 点探针（两个方向都咬）。`H` 的位图是 `[17,17,31,17,17]`：cols 0/1/3/4 只有
  // 行 2 与 6（上下两条横杠），col 2 是整条竖笔（行 2..6）——**不是**两条竖笔 +
  // 中间横杠（第一版照常识猜了个 H，探针当场红给我看）。转 90° 后它变成
  // "左/右两条竖杠 + 中间一条横杠"，正好是上面那个形状转过去的样子。
  //   (36,24)：不转时在盒外（盒从 y=28 起）⇒ 空；转 90° 后落在右侧那条竖杠
  //     （x 35..38、y 22..41）里 ⇒ 有墨
  assert_true(!ttx_at(flat, 36, 24), msg="不转时 (36,24) 在盒外，该是空的")
  assert_true(ttx_at(r90, 36, 24), msg="转 90° 后 (36,24) 该在右侧那条竖杠里")
  //   (20,24)：不转时盒外 ⇒ 空；转 90° 后落在左侧那条竖杠（x 19..22）里 ⇒ 有墨
  assert_true(!ttx_at(flat, 20, 24), msg="不转时 (20,24) 在盒外")
  assert_true(ttx_at(r90, 20, 24), msg="转 90° 后 (20,24) 该在左侧那条竖杠里")
  //   (30,40)：不转时是中间那条竖笔的深处 ⇒ 有墨；转 90° 后 (30,40) 落在
  //     "横杠之外又不在两条竖杠里" ⇒ 空
  assert_true(ttx_at(flat, 30, 40), msg="不转时 (30,40) 是中间那条竖笔")
  assert_true(!ttx_at(r90, 30, 40), msg="转 90° 后 (30,40) 该空了")
  //   (22,30)：不转时是上横杠，转 90° 后映到竖杠里 ⇒ 两边都有墨（**不是判据**，
  //     写出来是为了说明"挑一个点两边都变"不够，得挑映到空格的点）
  assert_true(ttx_at(flat, 22, 30) && ttx_at(r90, 22, 30), msg="(22,30) 两边都有墨")
  // **轴对齐的变换下像素数恰好守恒**（208 = 208）：字形的整数格在绕整数轴心转
  // 90°/180°/镜像下映射到自身，覆盖度逐点守恒。⚠️ 这条**来之不易**：字形是硬边
  // 位图（不像笔触有 2×2 子采样兜着），格判定里那个抗浮点误差的偏置必须
  // **大于整条链的误差**——`cos_rad`/`sin_rad` 是级数近似，90° 下单点误差实测
  // ~1.4e-6，偏置写 1e-9/1e-6 时这里就是 206/207，还当场翻掉一条点探针。
  // 偏置定在 1e-4（像素万分之一）后四格全部回到 208（PLAN 六十一）。
  assert_eq(ttx_ink(flat).4, 208, msg="原图 208")
  assert_eq(ttx_ink(r90).4, ttx_ink(flat).4, msg="转 90° 不该多也不该少一个像素")
  // flip 与 180°：包围盒会变（"H" 左右不对称），墨迹数同样守恒
  assert_eq(ttx_ink(@render.render_doc(ttx_doc("ttx-fh", 0.0, true, false), env)), (25, 28, 44, 47, 208), msg="flip_h 后的墨迹")
  assert_eq(ttx_ink(@render.render_doc(ttx_doc("ttx-fv", 0.0, false, true), env)), (20, 21, 39, 40, 208), msg="flip_v 后的墨迹")
  assert_eq(ttx_ink(@render.render_doc(ttx_doc("ttx-r180", 180.0, false, false), env)), (24, 20, 44, 40, 208), msg="180° 后的墨迹")
  // **两者逐位相同**：本层绕自己的盒子中心转，与"组绕（同一个）内容中心转"是
  // 同一条路径（同一个 `effective_box`）——这条相等本身就是判据。
  assert_eq(
    ttx_ink(@render.render_doc(ttx_group_doc("ttx-grp90", 90.0, false, false), env)),
    (18, 22, 38, 42, 208),
    msg="**组**转 90°（子层不带变换）的墨迹：与子层自转 90° 必须一格不差",
  )
  // **正控**：组不带变换时必须与"压根没有组"逐位相同
  assert_eq(
    ttx_ink(@render.render_doc(ttx_group_doc("ttx-grp0", 0.0, false, false), env)),
    (20, 28, 39, 47, 208),
    msg="不带变换的组必须逐位不变",
  )
  // 组的 flip 同理（另一格：走的是祖先链的镜像分支）
  assert_eq(
    ttx_ink(@render.render_doc(ttx_group_doc("ttx-grpfh", 0.0, true, false), env)),
    (25, 28, 44, 47, 208),
    msg="**组** flip_h 的墨迹：与子层自 flip_h 必须一格不差",
  )
  // ⚠️ 祖先链上还有**两个**祖先才到位的格（组里套组）：`frames` 是一条链，
  // 只用一层祖先的实现照样会漏（Q84 的加强版）
  let nested = @core.new_document("ttx-nested", 100, 100)
  nested.layers.push({
    ..@core.default_layer("g1", "g", 20.0, 20.0, 24.0, 28.0),
    kind: @core.ShapeKind::Group,
    children: [
      {
        ..@core.default_layer("g2", "g2", 20.0, 20.0, 24.0, 28.0),
        kind: @core.ShapeKind::Group,
        children: [ttx(0.0)],
        rotation_deg: 90.0,
      },
    ],
  })
  assert_eq(
    ttx_ink(@render.render_doc(nested, env)),
    (18, 22, 38, 42, 208),
    msg="两层组（内层转 90°）的墨迹：`frames` 是链，不许只看最外层",
  )
  // pick 与渲染同一把尺子：转过的文本在**新**位置拾得到、旧位置拾不到
  let flat_doc = ttx_flat_doc("ttx-pick-flat")
  let r90_doc = ttx_doc("ttx-pick-r90", 90.0, false, false)
  assert_eq(@render.pick(flat_doc, 22.0, 30.0), Some("t1"), msg="不转时上横杠拾得到")
  assert_eq(@render.pick(flat_doc, 36.0, 24.0), None, msg="不转时 (36,24) 在盒外")
  assert_eq(@render.pick(r90_doc, 36.0, 24.0), Some("t1"), msg="转 90° 后右侧竖杠拾得到")
  assert_eq(@render.pick(r90_doc, 30.0, 40.0), None, msg="转 90° 后旧的竖笔深处空了")
}

///|
test "文本层的蒙版按**层局部**坐标采样（旧实现拿画布坐标 ⇒ 定过位的层整块错位）" {
  // 实测：矩形（层在 (50,40)、蒙版 x=0 w=10）左半保留 ⇒ 蒙版是**层局部**坐标
  // （`add-mask` 的 x/y 默认 0）。文本层旧实现把**画布**像素直接喂给
  // `mask_cover_at` ⇒ 同一个蒙版在文本上错位到厘米级：实测文本层在 (50,40)、
  // 蒙版 w=10 时 `sample 52 50` 回 `color=#FFFFFFFF`（画不出东西）而
  // `layer=t1`（`pick` 说层就在那儿）——**两个信号自相矛盾**。
  let env = @render.RenderEnv::new()
  let d = @core.new_document("ttx-mask", 100, 100)
  d.layers.push({
    ..ttx_doc("x", 0.0, false, false).layers[0],
    mask: Some(
      @core.LayerMask::{
        kind: @core.ShapeKind::Rect,
        x: 0.0,
        y: 0.0,
        w: 10.0,
        h: 28.0,
        radius: 0.0,
        feather: 0.0,
        roughen: 0.0,
        invert: false,
      },
    ),
  })
  // 局部 x∈[0,10) = 画布 x∈[20,30)：留下的是上下两条横杠的左段（cols 0/1，
  // 局部 x 0..7）与中间竖笔的左半（col 2 的局部 x 8/9 两列）。实测墨迹 =
  // (20,28)..(29,47)、墨 **104 = 208/2**（旧实现这里是 **0**，整层被误挡：
  // 画布 x≥20 全落在蒙版 w=10 之外——**坐标空间错了，蒙版就整块错位**）
  let masked = @render.render_doc(d, env)
  assert_eq(ttx_ink(masked), (20, 28, 29, 47, 104), msg="蒙版只留左半：墨迹该是原图的一半")
  assert_true(ttx_at(masked, 22, 30), msg="蒙版内（局部 x=2）该有墨")
  assert_true(!ttx_at(masked, 37, 30), msg="蒙版外（局部 x=17）该没有墨")
  // `pick` 与渲染同一把尺子（它一直用局部坐标 ⇒ 旧实现下这两个信号是矛盾的）
  assert_eq(@render.pick(d, 22.0, 30.0), Some("t1"), msg="蒙版内的点拾得到")
  assert_eq(@render.pick(d, 37.0, 30.0), None, msg="蒙版外的点拾不到（判据不许比渲染器松）")
}
