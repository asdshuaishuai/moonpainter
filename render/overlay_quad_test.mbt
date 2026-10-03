// 选中线框跟着变换（PLAN 六十三）。
//
// 线框是**报告面**：它必须画在该层真正落像素的地方。此前它把
// `@core.effective_box` 直接投影成轴对齐矩形，于是"把矩形转 90°，线框还停在
// 原地"——盒子在**层自己的坐标系**里，中间隔着"自己的 rot/flip + 整条祖先链"。
// 这一格钉四件事：①四个角过本层变换（转 90° 的框 = 转过的那个正方形）；
// ②过祖先链（组转了子层的框也转）；③45° 下是**四边形**而不是外接矩形；
// ④可见性/不透明度的判据与 `pick`/渲染**同一把尺子**。

///|
/// 120×90：一个 60×40 的实心矩形，盒 (30,20)-(90,60)、轴心 (60,40)。
fn oq_doc(uuid : String, deg : Double) -> @core.Document {
  let doc = @core.new_document(uuid, 120, 90)
  doc.layers.push({
    ..@core.default_layer("r1", "R", 30.0, 20.0, 60.0, 40.0),
    rotation_deg: deg,
    fill: @core.Fill::Solid(0xFFFF0000),
  })
  doc
}

///|
/// 同一个矩形装进一个带 `deg` 的组（守**祖先链**那一格）。
fn oq_group_doc(uuid : String, deg : Double) -> @core.Document {
  let doc = @core.new_document(uuid, 120, 90)
  doc.layers.push({
    ..@core.default_layer("g1", "G", 30.0, 20.0, 60.0, 40.0),
    kind: @core.ShapeKind::Group,
    rotation_deg: deg,
    children: [
      {
        ..@core.default_layer("r1", "R", 30.0, 20.0, 60.0, 40.0),
        fill: @core.Fill::Solid(0xFFFF0000),
      },
    ],
  })
  doc
}

///|
fn oq_mark(doc : @core.Document) -> @codec.RgbaBuf {
  let env = @render.RenderEnv::new()
  match @render.render_view_overlay(doc, env, 0.0, 0.0, 1.0, 1.0, 120) {
    Ok(b) => b
    Err(e) => abort(e)
  }
}

///|
/// 序号 1 的线框色（`overlay_palette[0]`）。
const OQ_COLOR : Int = 0xFFFF3355

///|
fn oq_is_mark(buf : @codec.RgbaBuf, x : Int, y : Int) -> Bool {
  if x < 0 || y < 0 || x >= buf.width || y >= buf.height {
    return false
  }
  @codec.rgba_get(buf, x, y) == OQ_COLOR
}

///|
/// `(x,y)` 周围 `±r` 内有没有线框色（45° 那种角落在小数上时用）。
fn oq_near(buf : @codec.RgbaBuf, x : Double, y : Double, r : Int) -> Bool {
  let mut dx = -r
  while dx <= r {
    let mut dy = -r
    while dy <= r {
      if oq_is_mark(buf, x.to_int() + dx, y.to_int() + dy) {
        return true
      }
      dy = dy + 1
    }
    dx = dx + 1
  }
  false
}

///|
test "选中线框跟着本层的旋转：转 90° 后是转过的那个正方形（原先停在原地）" {
  // 正控：不转时线框就是盒子的四个角（行为不变）
  let flat = oq_mark(oq_doc("oq-flat", 0.0))
  assert_true(oq_is_mark(flat, 30, 20), msg="不转时线框在盒子左上角")
  assert_true(oq_is_mark(flat, 90, 60), msg="不转时线框在盒子右下角")
  // 盒 (30,20)-(90,60) 绕中心 (60,40) 转 90° ⇒ (40,10)-(80,70)
  let r90 = oq_mark(oq_doc("oq-r90", 90.0))
  assert_true(oq_is_mark(r90, 40, 10), msg="转 90° 后线框在**转过**的左上角")
  assert_true(oq_is_mark(r90, 80, 10), msg="转 90° 后线框在转过的右上角")
  assert_true(oq_is_mark(r90, 80, 70), msg="转 90° 后线框在转过的右下角")
  assert_true(oq_is_mark(r90, 40, 70), msg="转 90° 后线框在转过的左下角")
  // 两头都要咬：原盒子的角上**不再**有线框（那里现在在画面外/是别的颜色）
  assert_true(!oq_is_mark(r90, 30, 20), msg="原盒子左上角（现在框外）不该有线框")
  assert_true(!oq_is_mark(r90, 90, 60), msg="原盒子右下角不该有线框")
  assert_true(!oq_is_mark(r90, 60, 60), msg="原盒子下边中点不该有线框（那里现在是填充色）")
}

///|
test "选中线框跟着祖先链：组转 90° 时子层的框也转（渲染/pick 早就转了）" {
  // 正控：组不转时与单层逐位相同
  let g0 = oq_mark(oq_group_doc("oq-g0", 0.0))
  assert_true(oq_is_mark(g0, 30, 20), msg="组不转时子层线框在盒子角上")
  assert_true(oq_is_mark(g0, 90, 60), msg="组不转时子层线框在盒子右下角")
  let g90 = oq_mark(oq_group_doc("oq-g90", 90.0))
  assert_true(oq_is_mark(g90, 40, 10), msg="组转 90° 后子层线框在转过的地方")
  assert_true(oq_is_mark(g90, 80, 70), msg="组转 90° 后子层线框（右下角）")
  assert_true(!oq_is_mark(g90, 30, 20), msg="组转 90° 后原盒子角上不该有线框")
  assert_true(!oq_is_mark(g90, 90, 60), msg="组转 90° 后原盒子右下角不该有线框")
}

///|
test "选中线框在 45° 下是四边形，不是外接矩形（那是「最小包围盒」的错法）" {
  // 盒的四角绕 (60,40) 转 45° ⇒ (52.93,4.64)/(95.36,47.07)/(67.07,75.36)/(24.64,32.93)
  let r45 = oq_mark(oq_doc("oq-r45", 45.0))
  assert_true(oq_near(r45, 52.9, 4.6, 2), msg="转 45° 后左上角在 (52.9,4.6) 附近")
  assert_true(oq_near(r45, 95.4, 47.1, 2), msg="转 45° 后右上角在 (95.4,47.1) 附近")
  assert_true(oq_near(r45, 67.1, 75.4, 2), msg="转 45° 后右下角在 (67.1,75.4) 附近")
  assert_true(oq_near(r45, 24.6, 32.9, 2), msg="转 45° 后左下角在 (24.6,32.9) 附近")
  // 两头都要咬：**外接矩形**的四个角上不许有线框（拿 AABB 当框，这里必红）
  assert_true(!oq_near(r45, 24.6, 4.6, 2), msg="外接矩形左上角不该有线框")
  assert_true(!oq_near(r45, 95.4, 4.6, 2), msg="外接矩形右上角不该有线框")
  assert_true(!oq_near(r45, 95.4, 75.4, 2), msg="外接矩形右下角不该有线框")
  assert_true(!oq_near(r45, 24.6, 75.4, 2), msg="外接矩形左下角不该有线框")
}

///|
test "线框的可见性判据与 pick/渲染同一把尺子（隐藏的组、α=0 的层都不画）" {
  // 可见组：子层有框（正控）
  assert_true(oq_is_mark(oq_mark(oq_group_doc("oq-vis", 0.0)), 30, 20), msg="可见组的子层有线框")
  // 隐藏组：整棵子树不画——渲染与 `pick` 都不认它，线框也不该认（此前平铺遍历照画）
  let hid = oq_group_doc("oq-hid", 0.0)
  hid.layers[0] = { ..hid.layers[0], visible: false }
  assert_true(!oq_is_mark(oq_mark(hid), 30, 20), msg="隐藏组的子层不该有线框")
  // α=0 的层：渲染不落一个像素（与 `pick` 的 eff<=0 同一句判据）
  let op0 = oq_doc("oq-op0", 0.0)
  op0.layers[0] = { ..op0.layers[0], opacity: 0.0 }
  assert_true(!oq_is_mark(oq_mark(op0), 30, 20), msg="α=0 的层不该有线框")
  // ⚠️ **祖先** α=0：子层自己的 α=1，但它照样看不见——判据必须看**继承**下来的
  // α（只看自己的 α 会漏；变异 R56 就守这一格）。两个消费者一起咬：线框与 `pick`。
  let gop0 = oq_group_doc("oq-gop0", 0.0)
  gop0.layers[0] = { ..gop0.layers[0], opacity: 0.0 }
  assert_true(!oq_is_mark(oq_mark(gop0), 30, 20), msg="组 α=0 时子层不该有线框")
  assert_eq(@render.pick(gop0, 60.0, 40.0), None, msg="组 α=0 时子层也拾不到（同一把尺子）")
  // 反面对照：同一张图里另一个可见层照样有线框（别把整块画丢了）
  let op0b = oq_doc("oq-op0b", 0.0)
  op0b.layers[0] = { ..op0b.layers[0], opacity: 0.0 }
  op0b.layers.push({
    ..@core.default_layer("r2", "R2", 10.0, 70.0, 20.0, 10.0),
    fill: @core.Fill::Solid(0xFF000000),
  })
  let m0b = oq_mark(op0b)
  assert_true(oq_is_mark(m0b, 10, 70), msg="同一张图里可见层的线框还在（序号 1 换成它）")
}
