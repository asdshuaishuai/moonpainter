/// codec —— PSD **写出**的往返判据（③ PSD 兼容 · 写的方向）。
///
/// 这里不碰第三方（那是 `verify.sh#psd-roundtrip` 的活）：本文件问的是
/// **"写出去的东西我们自己的读侧能不能原样读回来"**——写/读是一对，
/// 只有这一条先成立，"第三方也能读"才有意义。

///|
/// 造一块 `w*h*3` 的 **RGB 合成图**，**平面序**（先整块 R、再 G、再 B）——
/// PSD 的硬规定；写成交错序不会报错，只会把画面读成一整片灰。
fn out_rgb(w : Int, h : Int, r : Int, g : Int, b : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  for v in [r, g, b] {
    let mut i = 0
    while i < w * h {
      out.push(v.to_byte())
      i = i + 1
    }
  }
  out
}

///|
/// 造一块 `w*h*4` 的非预乘 RGBA（每像素同色）。
fn out_solid(w : Int, h : Int, r : Int, g : Int, b : Int, a : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < w * h {
    out.push(r.to_byte())
    out.push(g.to_byte())
    out.push(b.to_byte())
    out.push(a.to_byte())
    i = i + 1
  }
  out
}

///|
/// 一条测试用的图层（默认：可见、不透明、normal、带 alpha）。
fn out_layer(
  name : String,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  rgba : Array[Byte],
) -> @codec.PsdOutLayer {
  @codec.PsdOutLayer::{
    name,
    x,
    y,
    w,
    h,
    opacity: 255,
    visible: true,
    blend: "normal",
    rgba,
    has_alpha: true,
  }
}

///|
/// 两步走出来的 PSD：底红（不透明、不带 alpha）4×3 @ (1,1)，上蓝（半透明、
/// 带 alpha）2×2 @ (3,2)，合成图 8×6。
fn out_sample() -> Bytes {
  let comp = out_rgb(8, 6, 240, 10, 30)
  let bottom : @codec.PsdOutLayer = @codec.PsdOutLayer::{
    name: "bottom red",
    x: 1,
    y: 1,
    w: 4,
    h: 3,
    opacity: 255,
    visible: true,
    blend: "normal",
    rgba: out_solid(4, 3, 255, 0, 0, 255),
    has_alpha: false,
  }
  let top = @codec.PsdOutLayer::{
    ..out_layer("top 蓝", 3, 2, 2, 2, out_solid(2, 2, 0, 0, 255, 128)),
    opacity: 128,
    blend: "multiply",
  }
  match @codec.psd_encode(8, 6, comp, [bottom, top]) {
    Err(e) => abort("psd_encode 失败：\{e}")
    Ok(b) => b
  }
}

///|
test "PSD 写 → 读：结构（尺寸/通道/层表逐字段）原样回来" {
  let img = match @codec.psd_decode(out_sample()) {
    Err(e) => abort("自写的 PSD 读不回来：\{e}")
    Ok(i) => i
  }
  assert_eq(img.width, 8)
  assert_eq(img.height, 6)
  assert_eq(img.channels, 3)
  assert_eq(img.mode, 3)
  assert_eq(img.layers.length(), 2)
  let bottom = img.layers[0]
  assert_eq(bottom.name, "bottom red")
  assert_eq((bottom.x, bottom.y, bottom.w, bottom.h), (1, 1, 4, 3))
  assert_eq(bottom.opacity, 255)
  assert_true(bottom.visible)
  assert_eq(bottom.blend, "normal")
  let top = img.layers[1]
  // `luni` 让**非 ASCII 名字**也能往返（Pascal 名是字节串，中文会坏）
  assert_eq(top.name, "top 蓝")
  assert_eq((top.x, top.y, top.w, top.h), (3, 2, 2, 2))
  assert_eq(top.opacity, 128)
  assert_eq(top.blend, "multiply")
  // 像素：底的 R 通道全 255、G/B 全 0、A 全 255；顶的 B 通道全 255、A 全 128
  let mut i = 0
  while i < 4 * 3 {
    assert_eq(bottom.rgba[i * 4], (255 : Byte))
    assert_eq(bottom.rgba[i * 4 + 1], (0 : Byte))
    assert_eq(bottom.rgba[i * 4 + 3], (255 : Byte))
    i = i + 1
  }
  let mut j = 0
  while j < 2 * 2 {
    assert_eq(top.rgba[j * 4], (0 : Byte))
    assert_eq(top.rgba[j * 4 + 2], (255 : Byte))
    assert_eq(top.rgba[j * 4 + 3], (128 : Byte))
    j = j + 1
  }
}

///|
test "PSD 写 → 读：合成图逐字节回来（RAW 合成图是我们的字节存档）" {
  let img = match @codec.psd_decode(out_sample()) {
    Err(e) => abort(e)
    Ok(i) => i
  }
  assert_eq(img.composite.length(), 8 * 6 * 4)
  let mut i = 0
  while i < 8 * 6 {
    assert_eq(img.composite[i * 4], (240 : Byte))
    assert_eq(img.composite[i * 4 + 1], (10 : Byte))
    assert_eq(img.composite[i * 4 + 2], (30 : Byte))
    assert_eq(img.composite[i * 4 + 3], (255 : Byte))
    i = i + 1
  }
}

///|
test "隐藏层：flags 写对了（读回来 visible=false，而不是「看不见却报可见」）" {
  let comp = out_rgb(2, 2, 9, 9, 9)
  let hidden = @codec.PsdOutLayer::{
    ..out_layer("hid", 0, 0, 2, 2, out_solid(2, 2, 200, 0, 0, 255)),
    visible: false,
  }
  let bytes = match @codec.psd_encode(2, 2, comp, [hidden]) {
    Err(e) => abort(e)
    Ok(b) => b
  }
  let img = match @codec.psd_decode(bytes) {
    Err(e) => abort(e)
    Ok(i) => i
  }
  assert_eq(img.layers.length(), 1)
  assert_true(!img.layers[0].visible)
}

///|
test "混合模式两个方向都往返（单向表会让新模式读得进、写不出）" {
  let names = [
    "normal", "multiply", "screen", "overlay", "darken", "lighten", "difference",
  ]
  for n in names {
    let tag = match @codec.psd_blend_tag(n) {
      None => abort("混合模式 \{n} 没有 PSD 签名（写不出去）")
      Some(t) => t
    }
    assert_eq(tag.length(), 4)
    let comp = out_rgb(1, 1, 0, 0, 0)
    let l = @codec.PsdOutLayer::{ ..out_layer("m", 0, 0, 1, 1, out_solid(1, 1, 1, 2, 3, 255)), blend: n }
    let bytes = match @codec.psd_encode(1, 1, comp, [l]) {
      Err(e) => abort(e)
      Ok(b) => b
    }
    let img = match @codec.psd_decode(bytes) {
      Err(e) => abort("混合模式 \{n} 写出去读不回来：\{e}")
      Ok(i) => i
    }
    assert_eq(img.layers[0].blend, n)
  }
}

///|
test "写侧的拒绝路径：非正盒子 / 不透明度越界 / 未知混合模式 / 合成图长度" {
  let comp = out_rgb(2, 2, 0, 0, 0)
  let base = out_layer("x", 0, 0, 2, 2, out_solid(2, 2, 1, 2, 3, 255))
  // ① 盒子非正（PSD 的通道数据不能是 0 字节）
  let zero = @codec.PsdOutLayer::{ ..base, w: 0, h: 0, rgba: ([] : Array[Byte]) }
  match @codec.psd_encode(2, 2, comp, [zero]) {
    Ok(_) => abort("0 尺寸的层该被拒")
    Err(e) => assert_true(e.contains("非正"), msg=e)
  }
  // ② 不透明度越界（PSD 是 8 位：这里不做 clamp，越界是调用方的 bug）
  let big = @codec.PsdOutLayer::{ ..base, opacity: 300 }
  match @codec.psd_encode(2, 2, comp, [big]) {
    Ok(_) => abort("不透明度 300 该被拒")
    Err(e) => assert_true(e.contains("0..255"), msg=e)
  }
  // ③ 未知混合模式
  let weird = @codec.PsdOutLayer::{ ..base, blend: "vivid" }
  match @codec.psd_encode(2, 2, comp, [weird]) {
    Ok(_) => abort("未知混合模式该被拒")
    Err(e) => assert_true(e.contains("混合模式"), msg=e)
  }
  // ⑤ 合成图长度不对
  match @codec.psd_encode(2, 2, out_rgb(1, 1, 0, 0, 0), [base]) {
    Ok(_) => abort("合成图长度不对该被拒")
    Err(e) => assert_true(e.contains("合成图"), msg=e)
  }
  // 正控：同样的参数改对了必须写得出来（判据两头都咬）
  match @codec.psd_encode(2, 2, comp, [base]) {
    Ok(_) => ()
    Err(e) => abort("正控失败（参数没问题却写不出来）：\{e}")
  }
}
