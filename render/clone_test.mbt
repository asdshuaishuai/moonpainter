// 仿制图章（克隆笔触）的渲染判据。
//
// 语义：克隆 dab **不落本色**，改从"本层之下那张合成缓冲"里按源偏移取样——
// 于是"污点被干净的地方盖住"这件事是**真的取到了画面**，而不是涂了一块死色。
// 判据必须两头咬：①克隆**取到了源的颜色**（正控：源区是什么色就该是什么色）；
// ②它**没有**落下自己的笔色（负控：普通画笔在同一位置会落下笔色）。

///|
/// 20×20 画布：左上一块红（0..8），其余白；上面盖一个笔触层。
fn clone_doc(dabs : Array[@core.Dab]) -> @core.Document {
  let doc = @core.new_document("u-clone", 20, 20)
  let red = @core.default_layer("src", "红块", 0.0, 0.0, 8.0, 8.0)
  let red2 = { ..red, fill: @core.Fill::Solid(0xFFFF0000) }
  doc.layers.push(red2)
  let paint = @core.default_layer("p", "修补", 0.0, 0.0, 20.0, 20.0)
  let paint2 = { ..paint, kind: @core.ShapeKind::Raster, dabs }
  doc.layers.push(paint2)
  doc
}

///|
fn clone_dab(x : Double, y : Double, sdx : Double, sdy : Double) -> @core.Dab {
  {
    x,
    y,
    r: 3.0,
    color: 0xFF00FF00, // 故意给一个**醒目的笔色**：克隆若退化成普通画笔，一眼就红
    erase: false,
    clone: true,
    sdx,
    sdy,
  }
}

///|
test "克隆：取的是本层之下的画面（笔色不是自己的）" {
  let env = @render.RenderEnv::new()
  // 落点在 (16,16)（白区），源偏移 (-12,-12) ⇒ 取样 (4,4) = 红块
  let m = @render.render_doc(clone_doc([clone_dab(16.0, 16.0, -12.0, -12.0)]), env)
  assert_eq(
    @codec.rgba_get(m, 16, 16),
    0xFFFF0000,
    msg="克隆处必须变成**源区的颜色**（红），不是笔色（绿）",
  )
  assert_eq(@codec.rgba_get(m, 2, 2), 0xFFFF0000, msg="源区自己不动")
  // 负控：同样的落点、同样的"醒目笔色"，普通画笔落下的是**笔色**（绿）
  let brush = @core.Dab::{
    x: 16.0,
    y: 16.0,
    r: 3.0,
    color: 0xFF00FF00,
    erase: false,
    clone: false,
    sdx: 0.0,
    sdy: 0.0,
  }
  let mb = @render.render_doc(clone_doc([brush]), env)
  assert_eq(
    @codec.rgba_get(mb, 16, 16),
    0xFF00FF00,
    msg="负控：普通画笔落的是笔色——不然上面那条断言分不出克隆与画笔",
  )
}

///|
test "克隆：源偏移真的被用上（偏移不同 ⇒ 取到不同的地方）" {
  let env = @render.RenderEnv::new()
  // 同一个落点，两个不同的源偏移：一个取到红块、一个取到白区
  let hit = @render.render_doc(clone_doc([clone_dab(16.0, 16.0, -12.0, -12.0)]), env)
  let miss = @render.render_doc(clone_doc([clone_dab(16.0, 16.0, -2.0, -2.0)]), env)
  assert_eq(@codec.rgba_get(hit, 16, 16), 0xFFFF0000, msg="偏移指向红块 ⇒ 红")
  assert_eq(
    @codec.rgba_get(miss, 16, 16),
    0xFFFFFFFF,
    msg="偏移指向白区 ⇒ 白（把 sdx/sdy 丢掉不管，这条就会红）",
  )
  assert_true(
    @codec.rgba_get(hit, 16, 16) != @codec.rgba_get(miss, 16, 16),
    msg="两条渲染必须不同——否则这一格什么都没在判（判别力自证）",
  )
}

///|
test "克隆：源取样**先于**本层自己的笔迹（不是自己喂自己）" {
  let env = @render.RenderEnv::new()
  // 两个克隆 dab，都把源指向 (4,4) 的红块；第一个落在 (16,16)，
  // 第二个落在 (12,16) 且源偏移指向**第一个 dab 画过的地方**（画布 (16,16)）。
  // 语义是"从本层之下取样"，所以第二个 dab 取到的是**底下的白**，而不是
  // 第一个 dab 刚画上的红 —— 这条钉住"取样源 = 本层之下"，顺带排除
  // "边画边喂自己"那种顺序依赖的实现。
  let dabs = [
    clone_dab(16.0, 16.0, -12.0, -12.0),
    clone_dab(12.0, 16.0, 4.0, 0.0),
  ]
  let m = @render.render_doc(clone_doc(dabs), env)
  assert_eq(@codec.rgba_get(m, 16, 16), 0xFFFF0000, msg="第一笔取到红块")
  assert_eq(
    @codec.rgba_get(m, 12, 16),
    0xFFFFFFFF,
    msg="第二笔的源指向第一笔画过的地方 ⇒ 取到底下的白（本层之下取样）",
  )
}

///|
test "克隆：源取样点跑出画布 ⇒ 那里什么都不落（不是黑边）" {
  let env = @render.RenderEnv::new()
  // 落点 (16,16)、源偏移 +12 ⇒ 取样 (28,28) 在 20×20 画布外
  let m = @render.render_doc(clone_doc([clone_dab(16.0, 16.0, 12.0, 12.0)]), env)
  assert_eq(
    @codec.rgba_get(m, 16, 16),
    0xFFFFFFFF,
    msg="取样点出画布 ⇒ 不落墨（白底透出来），不许落成黑/半透明黑边",
  )
}

///|
test "克隆：源偏移是**画布向量**，层挪走也不许再叠一次层原点" {
  let env = @render.RenderEnv::new()
  // 层原点 (6,6)、dab 是**层局部** (10,10) ⇒ 落点画布 (16,16)；
  // 源偏移 (-12,-12) 是**画布向量** ⇒ 取样画布 (4,4) = 红块（0..8）✓。
  // 把源偏移当"层局部"、于是又叠一次层原点的错误实现会取到 (10,10) =
  // 白区（红块只到 8）——这一格就是为这个而设的。
  let doc = clone_doc([clone_dab(10.0, 10.0, -12.0, -12.0)])
  let moved = {
    ..doc,
    layers: [
      doc.layers[0],
      { ..doc.layers[1], x: 6.0, y: 6.0 },
    ],
  }
  let m = @render.render_doc(moved, env)
  assert_eq(
    @codec.rgba_get(m, 16, 16),
    0xFFFF0000,
    msg="落点画布 (16,16) 取到源 (4,4) 的红；把偏移当层局部会取到 (10,10) 的白",
  )
}
