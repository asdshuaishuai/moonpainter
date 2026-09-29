/// codec —— PNG 编码（codec/png）。
///
/// 来源：moonviz/playground/png.mbt（自有 MIT，手写实现）的编码半部；
/// 差异：IDAT 从 stored 换成真 DEFLATE（本包 deflate，自有实现）、
/// 像素缓冲 RgbaBuf 提为公开（render 包的画布底座）、统一用 Bytes、
/// CRC32 复用 zip.mbt 的单一实现（避免同包重名）。
///
/// 输出规格：8-bit RGBA（色彩类型 6）、非交错、filter 0 扫描线。

///|
/// RGBA 像素缓冲：引擎像素层的统一底座（编码输入 = 解码输出）。
/// pixels 内部按 0xAARRGGBB 打包。
pub(all) struct RgbaBuf {
  width : Int
  height : Int
  pixels : FixedArray[Int] // ARGB
}

///|
pub fn rgba_new(width : Int, height : Int) -> RgbaBuf {
  if width <= 0 || height <= 0 {
    abort("rgba_new: 画布尺寸必须为正（got \{width}x\{height}）")
  }
  { width, height, pixels: FixedArray::make(width * height, 0xFF000000), }
}

///|
pub fn rgba_set(buf : RgbaBuf, x : Int, y : Int, argb : Int) -> Unit {
  if x >= 0 && x < buf.width && y >= 0 && y < buf.height {
    buf.pixels[y * buf.width + x] = argb
  }
}

///|
pub fn rgba_get(buf : RgbaBuf, x : Int, y : Int) -> Int {
  if x >= 0 && x < buf.width && y >= 0 && y < buf.height {
    buf.pixels[y * buf.width + x]
  } else {
    0
  }
}

///|
/// 整块纯色填充（画布底色/快速路径）。
pub fn fill_rect_rgba(
  buf : RgbaBuf,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  argb : Int,
) -> Unit {
  let x0 = if x < 0 { 0 } else { x }
  let y0 = if y < 0 { 0 } else { y }
  let x1 = if x + w > buf.width { buf.width } else { x + w }
  let y1 = if y + h > buf.height { buf.height } else { y + h }
  for yy in y0..<y1 {
    for xx in x0..<x1 {
      rgba_set(buf, xx, yy, argb)
    }
  }
}

///|
/// 颜色解析：#RGB 形如 #RRGGBB / #RRGGBBAA（缺省不透明）。
/// 非法输入按 0 处理（AgentGate 在入口就应拒绝非法色值，这里是兜底）。
pub fn color_from_hex(hex : String) -> Int {
  let body = if hex.has_prefix("#") {
    hex[1:].to_owned()
  } else {
    hex
  }
  let r = hex2(body, 0)
  let g = hex2(body, 2)
  let b = hex2(body, 4)
  let a = if body.length() >= 8 { hex2(body, 6) } else { 0xFF }
  (a << 24) + (r << 16) + (g << 8) + b
}

///|
/// 颜色反解：0xAARRGGBB → "#RRGGBBAA"（canonical 序列化用，恒 8 位）。
pub fn color_to_hex(argb : Int) -> String {
  "#" + hex2s((argb >> 16) & 0xFF) + hex2s((argb >> 8) & 0xFF) + hex2s(argb & 0xFF) +
  hex2s((argb >> 24) & 0xFF)
}

///|
fn hex2s(v : Int) -> String {
  let digits = "0123456789ABCDEF"
  let sb = StringBuilder()
  match digits.get_char((v >> 4) & 0xF) {
    Some(c) => sb.write_char(c)
    None => ()
  }
  match digits.get_char(v & 0xF) {
    Some(c) => sb.write_char(c)
    None => ()
  }
  sb.to_string()
}

///|
fn hex_digit_c(s : String, i : Int) -> Int? {
  match s.get_char(i) {
    Some(c) => hex_digit(c)
    None => None
  }
}

///|
fn hex_digit(c : Char) -> Int? {
  let code = c.to_int()
  if code >= 48 && code <= 57 {
    Some(code - 48)
  } else if code >= 97 && code <= 102 {
    Some(code - 87)
  } else if code >= 65 && code <= 70 {
    Some(code - 55)
  } else {
    None
  }
}

///|
fn hex2(s : String, i : Int) -> Int {
  let a = match hex_digit_c(s, i) {
    Some(x) => x
    None => 0
  }
  let b = match hex_digit_c(s, i + 1) {
    Some(x) => x
    None => 0
  }
  a * 16 + b
}

// ---------------------------------------------------------------------------
// PNG 字节流
// ---------------------------------------------------------------------------

///|
fn push_b(arr : Array[Byte], v : Int) -> Unit {
  arr.push((v & 0xFF).to_byte())
}

///|
fn push_be32(arr : Array[Byte], v : Int) -> Unit {
  push_b(arr, (v >> 24) & 0xFF)
  push_b(arr, (v >> 16) & 0xFF)
  push_b(arr, (v >> 8) & 0xFF)
  push_b(arr, v & 0xFF)
}

///|
fn push_tag(arr : Array[Byte], tag : String) -> Unit {
  for i in 0..<tag.length() {
    match tag.get_char(i) {
      Some(c) => push_b(arr, c.to_int())
      None => ()
    }
  }
}

///|
/// adler32（zlib 校验和，RFC 1950）。PNG 的 IDAT 外面是 zlib 流。
fn adler32(data : Bytes) -> Int {
  let mut a = 1
  let mut b = 0
  let mut i = 0
  while i < data.length() {
    a = (a + (data[i].to_int() & 0xFF)) % 65521
    b = (b + a) % 65521
    i = i + 1
  }
  (b << 16) + a
}

///|
/// zlib 包装：0x78 0x9C（deflate / 默认级别）+ raw deflate + adler32（大端）。
/// deepOffice pdf/zlib.mbt 同构，这里复用本包 deflate 实现。
fn zlib_wrap(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  push_b(out, 0x78)
  push_b(out, 0x9C)
  let packed = deflate(data, level=Balanced)
  for i = 0; i < packed.length(); i = i + 1 {
    out.push(packed[i])
  }
  push_be32(out, adler32(data))
  Bytes::from_array(out)
}

///|
/// PNG chunk：长度（大端）+ 类型 + 数据 + CRC32（对 类型+数据）。
fn png_chunk(tag : String, data : Bytes) -> Bytes {
  let body : Array[Byte] = []
  push_tag(body, tag)
  for x in data.iter() {
    body.push(x)
  }
  let out : Array[Byte] = []
  push_be32(out, data.length())
  for x in body.iter() {
    out.push(x)
  }
  push_be32(out, crc32(Bytes::from_array(body)))
  Bytes::from_array(out)
}

///|
/// 把 RGBA 画布编码为 PNG（8-bit RGBA、非交错、filter 0、真 DEFLATE）。
pub fn png_encode(buf : RgbaBuf) -> Bytes {
  let out : Array[Byte] = []
  // PNG 签名
  push_b(out, 137)
  push_b(out, 80)
  push_b(out, 78)
  push_b(out, 71)
  push_b(out, 13)
  push_b(out, 10)
  push_b(out, 26)
  push_b(out, 10)

  // IHDR：宽、高、8bit、色彩类型 6（RGBA）、压缩 0、滤波 0、非交错 0
  let ihdr : Array[Byte] = []
  push_be32(ihdr, buf.width)
  push_be32(ihdr, buf.height)
  push_b(ihdr, 8)
  push_b(ihdr, 6)
  push_b(ihdr, 0)
  push_b(ihdr, 0)
  push_b(ihdr, 0)
  let ihdr_chunk = png_chunk("IHDR", Bytes::from_array(ihdr))
  for x in ihdr_chunk.iter() {
    out.push(x)
  }

  // 扫描线：每行 filter 字节 0 + RGBA
  let raw : Array[Byte] = []
  for y in 0..<buf.height {
    push_b(raw, 0)
    for x in 0..<buf.width {
      let px = buf.pixels[y * buf.width + x]
      push_b(raw, (px >> 16) & 0xFF)
      push_b(raw, (px >> 8) & 0xFF)
      push_b(raw, px & 0xFF)
      push_b(raw, (px >> 24) & 0xFF)
    }
  }
  let idat = zlib_wrap(Bytes::from_array(raw))
  for x in png_chunk("IDAT", idat).iter() {
    out.push(x)
  }

  let iend = png_chunk("IEND", Bytes::from_array([]))
  for x in iend.iter() {
    out.push(x)
  }
  Bytes::from_array(out)
}
