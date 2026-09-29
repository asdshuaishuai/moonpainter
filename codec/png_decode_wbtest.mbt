/// PNG 解码补测（审计 D2 登记的未测路径）：色彩类型 0/2/4 与多 IDAT。
/// 白盒测试——直接用包内私有 png_chunk/zlib_wrap 构造手工帧。

///|
/// 手工构造 PNG：给定 IHDR 尾三元组与 IDAT 载荷（可拆多块）。
fn build_png(
  width : Int,
  height : Int,
  color_type : Int,
  idat_parts : Array[Bytes],
) -> Bytes {
  let ihdr : Array[Byte] = []
  fn push_be(arr : Array[Byte], v : Int) -> Unit {
    arr.push(((v >> 24) & 0xFF).to_byte())
    arr.push(((v >> 16) & 0xFF).to_byte())
    arr.push(((v >> 8) & 0xFF).to_byte())
    arr.push((v & 0xFF).to_byte())
  }
  push_be(ihdr, width)
  push_be(ihdr, height)
  ihdr.push((8).to_byte()) // bit depth
  ihdr.push(color_type.to_byte())
  ihdr.push((0).to_byte()) // compression
  ihdr.push((0).to_byte()) // filter
  ihdr.push((0).to_byte()) // interlace
  let out : Array[Byte] = []
  let sig : Array[Byte] = [
    (137).to_byte(),
    (80).to_byte(),
    (78).to_byte(),
    (71).to_byte(),
    (13).to_byte(),
    (10).to_byte(),
    (26).to_byte(),
    (10).to_byte(),
  ]
  for b in sig {
    out.push(b)
  }
  for b in png_chunk("IHDR", Bytes::from_array(ihdr)).iter() {
    out.push(b)
  }
  // IDAT：单块或多块
  if idat_parts.length() == 1 {
    for b in png_chunk("IDAT", idat_parts[0]).iter() {
      out.push(b)
    }
  } else {
    for part in idat_parts {
      for b in png_chunk("IDAT", part).iter() {
        out.push(b)
      }
    }
  }
  for b in png_chunk("IEND", Bytes::from_array([])).iter() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
test "PNG 解码：灰度（色彩类型 0）" {
  // 2x1 灰度：filter 0 + 两像素 [0x33, 0xEE]
  let raw : Array[Byte] = [0, 51, 238]
  let raw_b : Array[Byte] = []
  for v in raw {
    raw_b.push(v)
  }
  let png = build_png(2, 1, 0, [zlib_wrap(Bytes::from_array(raw_b))])
  match png_decode(png) {
    Err(m) => abort("灰度解码失败: \{m}")
    Ok(img) => {
      assert_eq(img.width, 2)
      let p0 = img.pixels[0]
      let g0 = (p0 >> 16) & 0xFF
      assert_eq(g0, 0x33) // 灰度展开 R=G=B
      assert_eq((p0 >> 8) & 0xFF, 0x33)
      assert_eq(p0 & 0xFF, 0x33)
      assert_eq((p0 >> 24) & 0xFF, 0xFF) // 灰度无 alpha → 不透明
      let p1 = img.pixels[1]
      assert_eq((p1 >> 16) & 0xFF, 0xEE)
    }
  }
}

///|
test "PNG 解码：RGB（色彩类型 2）" {
  // 1x1 RGB：filter 0 + [R,G,B]
  let raw : Array[Byte] = [0, 0x12, 0x34, 0x56]
  let raw_b : Array[Byte] = []
  for v in raw {
    raw_b.push(v)
  }
  let png = build_png(1, 1, 2, [zlib_wrap(Bytes::from_array(raw_b))])
  match png_decode(png) {
    Err(m) => abort("RGB 解码失败: \{m}")
    Ok(img) => {
      let p = img.pixels[0]
      assert_eq(p, 0xFF123456) // alpha 补满
    }
  }
}

///|
test "PNG 解码：灰+alpha（色彩类型 4）" {
  // 1x1 灰+alpha：filter 0 + [G, A]
  let raw : Array[Byte] = [0, 0xAB, 0x80]
  let raw_b : Array[Byte] = []
  for v in raw {
    raw_b.push(v)
  }
  let png = build_png(1, 1, 4, [zlib_wrap(Bytes::from_array(raw_b))])
  match png_decode(png) {
    Err(m) => abort("灰alpha 解码失败: \{m}")
    Ok(img) => {
      let p = img.pixels[0]
      assert_eq((p >> 24) & 0xFF, 0x80)
      assert_eq((p >> 16) & 0xFF, 0xAB)
      assert_eq(p & 0xFF, 0xAB)
    }
  }
}

///|
test "PNG 解码：多 IDAT 拼接" {
  // 1x1 RGBA，deflate 流拆两半分别放两个 IDAT
  let raw : Array[Byte] = [0, 0xDE, 0xAD, 0xBE, 0xEF]
  let raw_b : Array[Byte] = []
  for v in raw {
    raw_b.push(v)
  }
  let z = zlib_wrap(Bytes::from_array(raw_b))
  let mid = z.length() / 2
  let a : Array[Byte] = []
  let b : Array[Byte] = []
  let mut i = 0
  while i < z.length() {
    if i < mid {
      a.push(z[i])
    } else {
      b.push(z[i])
    }
    i = i + 1
  }
  let png = build_png(1, 1, 6, [Bytes::from_array(a), Bytes::from_array(b)])
  match png_decode(png) {
    Err(m) => abort("多 IDAT 解码失败: \{m}")
    Ok(img) => {
      // 原始 [R=DE, G=AD, B=BE, A=EF] → ARGB = EF DE AD BE
      assert_eq(img.pixels[0], (0xEF << 24) + 0xDEADBE)
    }
  }
}

///|
test "PNG 解码：filter 1/2（Sub/Up 逆滤波）" {
  // 2x1 RGB，Sub 滤波（filter 1）：原始像素 [10,20,30 | 20,40,60]
  // Sub 行字节 = [1, 10,20,30, 10,20,30]（第二像素存差分）
  let raw : Array[Byte] = [1, 10, 20, 30, 10, 20, 30]
  let raw_b : Array[Byte] = []
  for v in raw {
    raw_b.push(v)
  }
  let png = build_png(2, 1, 2, [zlib_wrap(Bytes::from_array(raw_b))])
  match png_decode(png) {
    Err(m) => abort("Sub 滤波解码失败: \{m}")
    Ok(img) => {
      assert_eq(img.pixels[0], 0xFF0A141E)
      assert_eq(img.pixels[1], 0xFF14283C) // 差分还原：10+10, 20+20, 30+30
    }
  }
}
