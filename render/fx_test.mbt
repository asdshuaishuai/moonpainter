///|
/// 图层样式（fx）四件套的**像素级**判据：投影往哪边偏、描边画在哪一圈、
/// 发光随半径变大、内阴影只在层里面。
///
/// 每条都断言**具体坐标上的具体值**（不是"回了个图"）：断言写成形状契约的话，
/// 把 `shadow_dx` 丢掉、把 `outline_w` 换成常量 1、把内阴影的 `× A` 删掉，
/// 全都照过（PLAN 六之三十五那类实测）。

///|
/// 一块 60×40 的画布、白底、一个 16×10 的不透明蓝块（x 20..36 / y 15..25）。
fn fx_box_doc(fx : @core.LayerFx?) -> @core.Document {
  let doc = @core.new_document("fx", 60, 40)
  doc.layers.push({
    ..@core.default_layer("l1", "box", 20.0, 15.0, 16.0, 10.0),
    fill: @core.Fill::Solid(0xFF3366FF),
    fx,
  })
  doc
}

///|
fn fx_box_px(fx : @core.LayerFx?, x : Int, y : Int) -> Int {
  @codec.rgba_get(@render.render_doc(fx_box_doc(fx), @render.RenderEnv::new()), x, y)
}

///|
/// 逐位相同（比 sha 更直接：这里要比的是"哪几个像素被碰过"）。
fn fx_same(a : @core.Document, b : @core.Document) -> Bool {
  let ea = @render.RenderEnv::new()
  let ba = @render.render_doc(a, ea)
  let bb = @render.render_doc(b, ea)
  if ba.width != bb.width || ba.height != bb.height {
    return false
  }
  let mut i = 0
  let total = ba.width * ba.height
  while i < total {
    if ba.pixels[i] != bb.pixels[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn fx_all_off() -> @core.LayerFx {
  @core.default_fx()
}

///|
test "投影：往 (dx,dy) 那一侧偏、被层盖住的地方仍是层自己的颜色" {
  // 影：黑、不模糊、往右下偏 6px ⇒ 影区 = 蓝块平移 (6,6)（x 26..42 / y 21..31）
  let f = { ..fx_all_off(), shadow: true, shadow_dx: 6.0, shadow_dy: 6.0, shadow_blur: 0.0, shadow_color: 0xFF000000 }
  // ① 影区里、蓝块**之外**：影色
  assert_eq(fx_box_px(Some(f), 38, 26), 0xFF000000, msg="右下的影区是影色")
  // ② 蓝块与影的**重叠处**：还是蓝块自己的颜色（影压在层下面）
  assert_eq(fx_box_px(Some(f), 30, 22), 0xFF3366FF, msg="层盖住的像素不是影色")
  // ③ 左上角（影的反方向）：白底，一点影都不许有
  assert_eq(fx_box_px(Some(f), 10, 10), 0xFFFFFFFF, msg="影只往偏移那一侧")
  // ④ 方向真的由 dx/dy 决定：反过来偏，方向也跟着反过来
  let rev = { ..f, shadow_dx: -6.0, shadow_dy: -6.0 }
  assert_eq(fx_box_px(Some(rev), 16, 12), 0xFF000000, msg="负偏移要往左上打")
  assert_eq(fx_box_px(Some(rev), 38, 26), 0xFFFFFFFF, msg="反方向不该有影")
  // ⑤ 模糊半径真的参与：blur=0 时影在平移块外一格就没了，blur=3 时伸出去
  let soft = { ..f, shadow_blur: 3.0 }
  assert_eq(fx_box_px(Some(f), 43, 29), 0xFFFFFFFF, msg="没模糊时 (43,29) 在影外")
  assert_true(
    fx_box_px(Some(soft), 43, 29) != 0xFFFFFFFF,
    msg="blur=3 时影要糊出去（否则 blur 是个只改指纹的参数）",
  )
}

///|
test "描边：盒外一圈是描边色、盒内与更远处都不是" {
  // 红描边 3px：`dilate(A,3) − A` ⇒ 蓝块外 1..3px 的环
  let f = {
    ..fx_all_off(),
    outline: true,
    outline_w: 3.0,
    outline_color: 0xFFFF0000,
  }
  assert_eq(fx_box_px(Some(f), 18, 20), 0xFFFF0000, msg="左边 2px 处是描边色")
  assert_eq(fx_box_px(Some(f), 20, 13), 0xFFFF0000, msg="上边 2px 处是描边色")
  assert_eq(fx_box_px(Some(f), 28, 20), 0xFF3366FF, msg="盒中心是填充色、不是描边色")
  assert_eq(fx_box_px(Some(f), 12, 20), 0xFFFFFFFF, msg="5px 外没有描边")
  // 宽度真的由 outline_w 决定：1px 描边时 (19,20) 是红的、(18,20) 不是
  let thin = { ..f, outline_w: 1.0 }
  assert_eq(fx_box_px(Some(thin), 19, 20), 0xFFFF0000, msg="1px 描边贴着盒子")
  assert_eq(fx_box_px(Some(thin), 18, 20), 0xFFFFFFFF, msg="1px 描边不该有 2px 宽")
  // `outline_w=0` ⇒ 一个像素都不落（入口收得下、lint 报"画不出来"、
  // 画面与没有 fx **逐位相同**）
  let zero = { ..f, outline_w: 0.0 }
  assert_true(fx_same(fx_box_doc(Some(zero)), fx_box_doc(None)), msg="w=0 不许改画面")
}

///|
test "外发光：层周围亮起来、半径越大范围越大、层自己不变" {
  let f = {
    ..fx_all_off(),
    glow: true,
    glow_radius: 4.0,
    glow_color: 0xFF00FF00,
  }
  assert_true(
    fx_box_px(Some(f), 18, 20) != 0xFFFFFFFF,
    msg="紧贴盒子外侧要有发光",
  )
  assert_eq(fx_box_px(Some(f), 28, 20), 0xFF3366FF, msg="发光在层的下面：层自己不变")
  assert_eq(fx_box_px(Some(f), 4, 20), 0xFFFFFFFF, msg="远处没有发光")
  // 半径真的参与：radius=12 时 (12,20) 亮、radius=4 时不亮
  let wide = { ..f, glow_radius: 12.0 }
  assert_eq(fx_box_px(Some(f), 12, 20), 0xFFFFFFFF, msg="r=4 够不到 8px 外")
  assert_true(
    fx_box_px(Some(wide), 12, 20) != 0xFFFFFFFF,
    msg="r=12 要够得到（否则半径是个只改指纹的参数）",
  )
  // 半径 0：`blur(A,0) = A` 压在自己底下 ⇒ 逐位不变
  let zero = { ..f, glow_radius: 0.0 }
  assert_true(fx_same(fx_box_doc(Some(zero)), fx_box_doc(None)), msg="r=0 不许改画面")
}

///|
test "内阴影：只画在层的里面、层外一个像素都不动" {
  // 内影：黑、不模糊、往右偏 4px ⇒ 左内侧一条黑边
  let f = {
    ..fx_all_off(),
    inner: true,
    inner_dx: 4.0,
    inner_dy: 0.0,
    inner_blur: 0.0,
    inner_color: 0xFF000000,
  }
  assert_eq(fx_box_px(Some(f), 21, 20), 0xFF000000, msg="左内侧是内影色")
  assert_eq(fx_box_px(Some(f), 34, 20), 0xFF3366FF, msg="远离偏移侧的内侧不变")
  // 下面两格只是"层外是白的"的**弱判据**：它们在**工作窗之外**（窗 = 层的实际
  // 范围 + 内影扩散量 + 1，见 `fx_reach`），窗外的像素根本不参与求值——所以
  // "不乘 A"这种错在这一格上**照过**（变异 R122 实测存活）。
  assert_eq(fx_box_px(Some(f), 10, 20), 0xFFFFFFFF, msg="层外不许有内影")
  assert_eq(fx_box_px(Some(f), 45, 20), 0xFFFFFFFF, msg="层外（右侧）也不许有内影")
  // ⚠️ 这两格才守得住"内影要乘 A"：它们**在窗内、层外**（层 x 20..35，
  // reach = 0+4+0+1 = 5 ⇒ 窗 x 15..41）。不乘 A 时 `1 - blur(A)` 在这里≈1，
  // 会被整片涂成影色。
  assert_eq(fx_box_px(Some(f), 17, 20), 0xFFFFFFFF, msg="窗内层外（左）不许有内影")
  assert_eq(fx_box_px(Some(f), 39, 20), 0xFFFFFFFF, msg="窗内层外（右）不许有内影")
  // 同一件事在**模糊**的内影上再验一次：窗被模糊半径撑得更大，"窗内、层外"
  // 的格子更多（不乘 A 会把层周围一大片涂黑）。
  let soft = { ..f, inner_blur: 8.0 }
  assert_eq(fx_box_px(Some(soft), 45, 20), 0xFFFFFFFF, msg="模糊内影不许溢出到层外")
  assert_eq(fx_box_px(Some(soft), 12, 20), 0xFFFFFFFF, msg="模糊内影左侧同样不许溢出")
  // 方向由偏移决定：往左偏 ⇒ 黑边跑到右内侧
  let rev = { ..f, inner_dx: -4.0 }
  assert_eq(fx_box_px(Some(rev), 34, 20), 0xFF000000, msg="负偏移时黑边在右内侧")
  assert_eq(fx_box_px(Some(rev), 21, 20), 0xFF3366FF, msg="负偏移时左内侧不变")
}

///|
test "图层样式：四件都不落像素时走原路径，画面逐位不变" {
  let plain = fx_box_doc(None)
  assert_true(fx_same(fx_box_doc(Some(fx_all_off())), plain), msg="全 off 逐位相同")
  // 开关开着但参数画不出东西：影（不模糊不偏移）、发光（半径 0）、
  // 内影（不模糊不偏移）、描边（宽 0）
  for dead in [
    // ⚠️ 开关开着只是"这一件被打开"，`default_fx` 的偏移/模糊是 4/4/4，
    // 那是**会**落像素的——"画不出东西"必须把参数一起给到中性值。
    { ..fx_all_off(), shadow: true, shadow_dx: 0.0, shadow_dy: 0.0, shadow_blur: 0.0 },
    { ..fx_all_off(), glow: true, glow_radius: 0.0 },
    { ..fx_all_off(), inner: true, inner_dx: 0.0, inner_dy: 0.0, inner_blur: 0.0 },
    { ..fx_all_off(), outline: true, outline_w: 0.0 },
    // 颜色全透明：连"开了但看不见"都算不上
    { ..fx_all_off(), shadow: true, shadow_dx: 9.0, shadow_color: 0x00000000 },
    { ..fx_all_off(), outline: true, outline_w: 4.0, outline_color: 0x00FF0000 },
  ] {
    assert_eq(@core.fx_any_on(dead), false, msg="这一件本该画不出来")
    assert_true(fx_same(fx_box_doc(Some(dead)), plain), msg="画不出来的样式不许改画面")
  }
  // 判别力自证：真的有像素落下的样式必须与白坯不同（否则上面那批"逐位相同"
  // 可能只是因为整条 fx 路径根本没接上）
  let live = { ..fx_all_off(), shadow: true, shadow_dx: 6.0, shadow_dy: 6.0, shadow_blur: 0.0 }
  assert_false(fx_same(fx_box_doc(Some(live)), plain), msg="真样式必须改画面")
}

///|
test "图层样式：偏移的「半像素门槛」与 field_shift 的四舍五入是同一个数" {
  // 判据说"画不出来"（`fx_any_on == false`）⇔ 画面逐位不变。这两件事分别在
  // core（`fx_shift_draws`，门槛 0.5）与 pixel（`field_shift` 的 `iround`）里，
  // 差一点点就会一边说"不画"一边画了 1 像素。这条把两边钉在一起。
  for dx in [0.0, 0.4, 0.49, 0.5, 0.6, -0.4, -0.5, -1.4] {
    let f = {
      ..fx_all_off(),
      shadow: true,
      shadow_dx: dx,
      shadow_dy: 0.0,
      shadow_blur: 0.0,
      shadow_color: 0xFF000000,
    }
    let want_same = !@core.fx_any_on(f)
    assert_eq(
      fx_same(fx_box_doc(Some(f)), fx_box_doc(None)),
      want_same,
      msg="dx=\{dx} 时两条判据分叉了",
    )
  }
}

///|
test "图层样式：不透明度在最后一步统一乘一次（半透明层的描边不会消失）" {
  // 若把层的不透明度先烤进内容缓冲，A 整体打折 ⇒ 描边算成
  // `dilate(0.5A,3) − 0.5A`，实心层的描边**一个像素都不落**；正确做法是先在
  // "形状覆盖度"上加样式、最后整块乘一次不透明度。
  let f = {
    ..fx_all_off(),
    outline: true,
    outline_w: 3.0,
    outline_color: 0xFFFF0000,
  }
  let doc = {
    ..fx_box_doc(Some(f)),
    layers: [{ ..fx_box_doc(Some(f)).layers[0], opacity: 0.5 }],
  }
  // 参照：一整块**不透明红**（同一个像素上 alpha=1）以 opacity=0.5 叠白底
  // ——两条不同的路径（真图层 vs 样式块），走的都是 `compose_src` 那一处。
  let base = @core.new_document("fx-ref", 60, 40)
  base.layers.push({
    ..@core.default_layer("r", "r", 0.0, 0.0, 60.0, 40.0),
    fill: @core.Fill::Solid(0xFFFF0000),
    opacity: 0.5,
  })
  let env = @render.RenderEnv::new()
  let got = @codec.rgba_get(@render.render_doc(doc, env), 18, 20)
  let want = @codec.rgba_get(@render.render_doc(base, env), 18, 20)
  assert_true(got != 0xFFFFFFFF, msg="半透明层的描边不许消失")
  assert_eq(got, want, msg="样式块整块乘一次不透明度，与真图层的折扣逐位相同")
}

///|
/// 组里那个 16×10 的蓝块（`rotation_deg` = 90 的组之子），带不带样式。
fn fx_group_doc(fx : @core.LayerFx?) -> @core.Document {
  let doc = @core.new_document("fxg", 60, 40)
  doc.layers.push({
    ..@core.default_layer("g", "g", 0.0, 0.0, 60.0, 40.0),
    kind: @core.ShapeKind::Group,
    rotation_deg: 90.0,
    children: [
      {
        ..@core.default_layer("c", "c", 20.0, 15.0, 16.0, 10.0),
        fill: @core.Fill::Solid(0xFF3366FF),
        fx,
      },
    ],
  })
  doc
}

///|
test "图层样式：组里的层走同一条路（祖先变换必须带进 fx 的栅格化）" {
  // 样式层的"自己的像素"要先在**画布坐标**上栅格化出来，而组里的层要经过
  // 组的旋转。栅格化时丢掉祖先链 ⇒ 组里的层会画成没转过的样子：层的**内容**
  // 位置变了，而它上面盖着样式，谁也说不清是样式错还是变换错。
  // 判据：带不发散的样式（blur=3、不偏移）时，蓝块的**位置与面积逐点不变**
  // （只有周围那圈被糊到），位置集合一比就知道祖先链有没有丢。
  let bg = { ..fx_all_off(), shadow: true, shadow_blur: 3.0 }
  let env = @render.RenderEnv::new()
  let without = @render.render_doc(fx_group_doc(None), env)
  let with_ = @render.render_doc(fx_group_doc(Some(bg)), env)
  let bbox_of_box = fn(buf : @codec.RgbaBuf) -> (Int, Int, Int, Int, Int) {
    let mut n = 0
    let mut x0 = 1 << 30
    let mut y0 = 1 << 30
    let mut x1 = -1
    let mut y1 = -1
    let mut y = 0
    while y < buf.height {
      let mut x = 0
      while x < buf.width {
        if @codec.rgba_get(buf, x, y) == 0xFF3366FF {
          n = n + 1
          if x < x0 {
            x0 = x
          }
          if y < y0 {
            y0 = y
          }
          if x > x1 {
            x1 = x
          }
          if y > y1 {
            y1 = y
          }
        }
        x = x + 1
      }
      y = y + 1
    }
    (n, x0, y0, x1, y1)
  }
  // 判别力自证：这条组里的层确实被转过（否则"位置不变"这条断言是空的）
  assert_true(bbox_of_box(without).0 > 0, msg="前置状态：组里的蓝块要画出来")
  assert_eq(
    bbox_of_box(@render.render_doc(fx_group_doc(None), env)),
    bbox_of_box(without),
    msg="扫两遍同一张图必须得到同一个盒子（自检扫描器本身）",
  )
  assert_eq(
    bbox_of_box(with_),
    bbox_of_box(without),
    msg="带样式时蓝块的位置/面积必须逐点不变（祖先变换丢了就会变）",
  )
  // 样式确实起作用（不是"整条路都没接上"）
  let mut diff = false
  let mut i = 0
  let total = with_.width * with_.height
  while i < total {
    if with_.pixels[i] != without.pixels[i] {
      diff = true
    }
    i = i + 1
  }
  assert_true(diff, msg="组里的样式必须真的改画面")
}

///|
/// 画布 40×40 上一个贴住左上角的 20×20 块（x=0 y=0）——**样式在画布边上的
/// 那一侧**是最容易被裁剪写错的地方：窗算小一点，画面上只是"边的样式缺一角"，
/// 而"回了个图"的断言照样通过。
fn fx_corner_doc(fx : @core.LayerFx?) -> @core.Document {
  let doc = @core.new_document("fxc", 40, 40)
  doc.layers.push({
    ..@core.default_layer("l1", "c", 0.0, 0.0, 20.0, 20.0),
    fill: @core.Fill::Solid(0xFF3366FF),
    fx,
  })
  doc
}

///|
fn fx_corner_px(fx : @core.LayerFx?, x : Int, y : Int) -> Int {
  @codec.rgba_get(@render.render_doc(fx_corner_doc(fx), @render.RenderEnv::new()), x, y)
}

///|
test "贴着画布边缘的层：能看见的那一侧样式必须完整，画布外那侧不许 panic" {
  // ① 投影往右下偏 6px、不模糊：影落在 x 6..25 / y 6..25，可见部分必须整片都在
  let sh = {
    ..fx_all_off(),
    shadow: true,
    shadow_dx: 6.0,
    shadow_dy: 6.0,
    shadow_blur: 0.0,
    shadow_color: 0xFF000000,
  }
  assert_eq(fx_corner_px(Some(sh), 24, 10), 0xFF000000, msg="右侧的影要画到影区边缘")
  assert_eq(fx_corner_px(Some(sh), 10, 24), 0xFF000000, msg="下侧的影同理")
  assert_eq(fx_corner_px(Some(sh), 26, 10), 0xFFFFFFFF, msg="影区之外是白底")
  assert_eq(fx_corner_px(Some(sh), 10, 10), 0xFF3366FF, msg="层自己不变")
  // 反方向（往左上）那一半**在画布外**：x=0/y=0 处仍是层自己，不许出现影色
  let sh_ul = { ..sh, shadow_dx: -6.0, shadow_dy: -6.0 }
  assert_eq(fx_corner_px(Some(sh_ul), 0, 0), 0xFF3366FF, msg="左上角是层自己（影在画布外）")
  assert_eq(fx_corner_px(Some(sh_ul), 30, 30), 0xFFFFFFFF, msg="反方向那一侧没有影")
  // ② 描边 3px：右侧/下侧的环要整圈在，左上角那一圈在画布外 ⇒ 那里仍是层自己
  let ol = {
    ..fx_all_off(),
    outline: true,
    outline_w: 3.0,
    outline_color: 0xFFFF0000,
  }
  assert_eq(fx_corner_px(Some(ol), 21, 10), 0xFFFF0000, msg="右侧的描边")
  assert_eq(fx_corner_px(Some(ol), 10, 21), 0xFFFF0000, msg="下侧的描边")
  assert_eq(fx_corner_px(Some(ol), 24, 10), 0xFFFFFFFF, msg="3px 之外没有描边")
  assert_eq(fx_corner_px(Some(ol), 0, 10), 0xFF3366FF, msg="左边缘（画布外那侧）是层自己")
  assert_eq(fx_corner_px(Some(ol), 0, 0), 0xFF3366FF, msg="左上角同理")
  // ③ 发光半径 4：紧贴右侧外沿要亮、远端不亮
  let gl = {
    ..fx_all_off(),
    glow: true,
    glow_radius: 4.0,
    glow_color: 0xFF00FF00,
  }
  assert_true(fx_corner_px(Some(gl), 22, 10) != 0xFFFFFFFF, msg="右侧外沿要有发光")
  assert_true(fx_corner_px(Some(gl), 10, 22) != 0xFFFFFFFF, msg="下侧外沿要有发光")
  assert_eq(fx_corner_px(Some(gl), 30, 10), 0xFFFFFFFF, msg="远处不亮")
  assert_eq(fx_corner_px(Some(gl), 0, 0), 0xFF3366FF, msg="左上角是层自己")
  // ④ 内影往右偏 4：贴着左边缘的那条内影必须完整（它的窗口被画布边夹住了）
  let inn = {
    ..fx_all_off(),
    inner: true,
    inner_dx: 4.0,
    inner_dy: 0.0,
    inner_blur: 0.0,
    inner_color: 0xFF000000,
  }
  assert_eq(fx_corner_px(Some(inn), 0, 10), 0xFF000000, msg="左边缘内侧是内影")
  assert_eq(fx_corner_px(Some(inn), 3, 10), 0xFF000000, msg="内影带内")
  assert_eq(fx_corner_px(Some(inn), 10, 10), 0xFF3366FF, msg="内影带外是层自己")
  assert_eq(fx_corner_px(Some(inn), 21, 10), 0xFFFFFFFF, msg="层外还是白底")
}

///|
test "一半在画布外 / 完全在画布外的层：该有的部分仍然对，且不许 panic" {
  // 一半在外：x=-20 w=60 ⇒ 画布内只有 x 0..39 有内容
  let half = @core.new_document("fxh", 60, 40)
  half.layers.push({
    ..@core.default_layer("l1", "h", -20.0, 10.0, 60.0, 20.0),
    fill: @core.Fill::Solid(0xFF3366FF),
    fx: Some({
      ..fx_all_off(),
      outline: true,
      outline_w: 3.0,
      outline_color: 0xFFFF0000,
      shadow: true,
      shadow_dx: 6.0,
      shadow_dy: 6.0,
      shadow_blur: 0.0,
      shadow_color: 0xFF000000,
    }),
  })
  let env = @render.RenderEnv::new()
  let hb = @render.render_doc(half, env)
  let hpx = fn(x : Int, y : Int) -> Int { @codec.rgba_get(hb, x, y) }
  assert_eq(hpx(0, 20), 0xFF3366FF, msg="画布左边缘就是层的内容（没有左侧描边）")
  assert_eq(hpx(41, 20), 0xFFFF0000, msg="右侧的描边仍在")
  // 影：平移 (+6,+6) 之后 x 6..45 / y 16..35；层内容在 x 0..39 / y 10..29
  // ⇒ (42,20) 被影盖住而层没有像素（描边到 42 为止：41..43 是环，(43,20) 是环外）
  assert_eq(hpx(43, 31), 0xFF000000, msg="右下角的影仍在（层外那半边）")
  assert_eq(hpx(50, 20), 0xFFFFFFFF, msg="影区之外是白底")
  // 完全在外：层整个在画布左侧外 ⇒ 画面与"没有这层"逐位相同，且不 panic
  let gone = @core.new_document("fxg0", 60, 40)
  gone.layers.push({
    ..@core.default_layer("l1", "g", -100.0, 10.0, 50.0, 20.0),
    fill: @core.Fill::Solid(0xFF3366FF),
    fx: Some(fx_all_on_doc_style()),
  })
  let empty = @core.new_document("fxe", 60, 40)
  assert_true(
    fx_same(gone, empty),
    msg="完全在画布外的层：样式一个像素都不产出（也不 panic）",
  )
}

///|
/// 四件全开的一份样式（边界测试里"最容易崩"的那种配置）。
fn fx_all_on_doc_style() -> @core.LayerFx {
  {
    ..fx_all_off(),
    shadow: true,
    shadow_dx: 8.0,
    shadow_dy: 8.0,
    shadow_blur: 8.0,
    glow: true,
    glow_radius: 10.0,
    outline: true,
    outline_w: 4.0,
    inner: true,
    inner_dx: 3.0,
    inner_dy: 3.0,
    inner_blur: 6.0,
  }
}
