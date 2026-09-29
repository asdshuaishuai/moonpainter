/// codec —— PNG 解码（codec/png_decode）。本仓库新写。
///
/// 支持子集（诚实边界，超出即明确报错）：
/// - 位深 8；色彩类型 0（灰）/ 2（RGB）/ 4（灰+alpha）/ 6（RGBA）
/// - 非交错（interlace 0）；调色板类型 3 不支持（外部素材请转 RGBA）
/// - 多 IDAT 拼接；chunk CRC 校验失败即拒绝（拒绝式校验纪律）
///
/// 解码结果直接落到 RgbaBuf（0xAARRGGBB），与编码输入同一底座——
/// decode(encode(x)) == x 由往返测试保证。

///|
/// PNG 解码：成功返回 RgbaBuf，失败返回精确原因（拒绝式校验）。
pub fn png_decode(data : Bytes) -> Result[RgbaBuf, String] {
  // 签名：89 50 4E 47 0D 0A 1A 0A
  if data.length() < 8 {
    return Err("PNG too short (\{data.length()} bytes)")
  }
  if data[0] != 0x89 ||
    data[1] != 0x50 ||
    data[2] != 0x4E ||
    data[3] != 0x47 ||
    data[4] != 0x0D ||
    data[5] != 0x0A ||
    data[6] != 0x1A ||
    data[7] != 0x0A {
    return Err("bad PNG signature")
  }

  // 遍历 chunk
  let mut pos = 8
  let mut width = 0
  let mut height = 0
  let mut color_type = -1
  let mut seen_ihdr = false
  let idat : Array[Byte] = []
  let mut seen_idat = false
  let mut done = false
  while !done && pos + 8 <= data.length() {
    let len = rd_be32(data, pos)
    let body_start = pos + 8
    if len < 0 || body_start + len + 4 > data.length() {
      return Err("truncated chunk at \{pos}")
    }
    let body = slice_bytes(data, body_start, len)
    let crc_stored = rd_be32(data, body_start + len)
    if crc32(tagged_crc(data, pos + 4, len)) != crc_stored {
      return Err("chunk CRC mismatch")
    }
    if chunk_is(data, pos + 4, "IHDR") {
      if len < 13 {
        return Err("IHDR too short")
      }
      width = rd_be32(body, 0)
      height = rd_be32(body, 4)
      let depth = body[8].to_int() & 0xFF
      color_type = body[9].to_int() & 0xFF
      let compression = body[10].to_int() & 0xFF
      let filter_method = body[11].to_int() & 0xFF
      let interlace = body[12].to_int() & 0xFF
      if width <= 0 || height <= 0 {
        return Err("bad IHDR size \{width}x\{height}")
      }
      if depth != 8 {
        return Err("unsupported bit depth \{depth} (only 8)")
      }
      if !(color_type == 0 ||
        color_type == 2 ||
        color_type == 4 ||
        color_type == 6) {
        return Err("unsupported color type \{color_type} (palette/other)")
      }
      if compression != 0 || filter_method != 0 {
        return Err("bad IHDR compression/filter method")
      }
      if interlace != 0 {
        return Err("interlaced PNG unsupported")
      }
      seen_ihdr = true
    } else if chunk_is(data, pos + 4, "IDAT") {
      if !seen_ihdr {
        return Err("IDAT before IHDR")
      }
      for b in body.iter() {
        idat.push(b)
      }
      seen_idat = true
    } else if chunk_is(data, pos + 4, "IEND") {
      done = true
    }
    // 其余 chunk（tEXt/pHYs/tRNS…）跳过
    pos = body_start + len + 4
  }
  if !seen_ihdr {
    return Err("missing IHDR")
  }
  if !seen_idat {
    return Err("missing IDAT")
  }
  if !done {
    return Err("missing IEND (truncated)")
  }

  // 解压：IDAT 是 zlib 流（2 字节头 + raw deflate + 4 字节 adler32 大端）
  if idat.length() < 6 {
    return Err("IDAT too short for zlib stream")
  }
  if idat[0] != 0x78 {
    return Err("bad zlib header in IDAT")
  }
  let raw_deflate : Array[Byte] = []
  let mut di = 2
  let adler_off = idat.length() - 4
  while di < adler_off {
    raw_deflate.push(idat[di])
    di = di + 1
  }
  let adler_expected = ((idat[adler_off].to_int() & 0xFF) << 24) |
    ((idat[adler_off + 1].to_int() & 0xFF) << 16) |
    ((idat[adler_off + 2].to_int() & 0xFF) << 8) |
    (idat[adler_off + 3].to_int() & 0xFF)
  let raw = inflate(Bytes::from_array(raw_deflate))
  if !raw.complete {
    return Err("IDAT inflate incomplete (corrupt stream)")
  }
  if adler32(raw.data) != adler_expected {
    return Err("zlib adler32 mismatch")
  }
  let channels : Int = match color_type {
    0 => 1
    2 => 3
    4 => 2
    _ => 4
  }
  let bpl = width * channels // 每行有效字节数（filter 字节另算）
  let expected = height * (bpl + 1)
  if raw.size < expected {
    return Err("pixel data truncated: got \{raw.size} bytes, need \{expected}")
  }

  // 拷到可写数组做逆滤波（Bytes 在当前版本只读）
  let px : Array[Byte] = []
  let mut ci = 0
  while ci < expected {
    px.push(raw.data[ci])
    ci = ci + 1
  }
  let stride = bpl + 1
  let mut y = 0
  while y < height {
    let row_start = y * stride
    let filter = px[row_start].to_int() & 0xFF
    let mut x = 0
    while x < bpl {
      let idx = row_start + 1 + x
      let cur = px[idx].to_int() & 0xFF
      let left : Int = if x >= channels {
        px[idx - channels].to_int() & 0xFF
      } else {
        0
      }
      let up : Int = if y > 0 {
        px[idx - stride].to_int() & 0xFF
      } else {
        0
      }
      let upleft : Int = if y > 0 && x >= channels {
        px[idx - stride - channels].to_int() & 0xFF
      } else {
        0
      }
      let v = match filter {
        0 => cur
        1 => cur + left
        2 => cur + up
        3 => cur + ((left + up) >> 1)
        4 => cur + paeth(left, up, upleft)
        _ => return Err("bad filter type \{filter} in row \{y}")
      }
      px[idx] = (v & 0xFF).to_byte()
      x = x + 1
    }
    y = y + 1
  }

  // 按通道数组装 ARGB
  let buf = rgba_new(width, height)
  y = 0
  while y < height {
    let row_start = y * stride + 1
    let mut x = 0
    while x < width {
      let o = row_start + x * channels
      let argb : Int = match color_type {
        0 => {
          let g = px[o].to_int() & 0xFF
          0xFF000000 + (g << 16) + (g << 8) + g
        }
        2 => {
          0xFF000000 +
          ((px[o].to_int() & 0xFF) << 16) +
          ((px[o + 1].to_int() & 0xFF) << 8) +
          (px[o + 2].to_int() & 0xFF)
        }
        4 => {
          let g = px[o].to_int() & 0xFF
          let a = px[o + 1].to_int() & 0xFF
          (a << 24) + (g << 16) + (g << 8) + g
        }
        _ => {
          ((px[o + 3].to_int() & 0xFF) << 24) +
          ((px[o].to_int() & 0xFF) << 16) +
          ((px[o + 1].to_int() & 0xFF) << 8) +
          (px[o + 2].to_int() & 0xFF)
        }
      }
      buf.pixels[y * width + x] = argb
      x = x + 1
    }
    y = y + 1
  }
  Ok(buf)
}

///|
/// chunk 类型比对（4 字节 ASCII）。
fn chunk_is(data : Bytes, tag_off : Int, expect : String) -> Bool {
  let mut ok = true
  let mut i = 0
  while i < 4 {
    match expect.get_char(i) {
      Some(c) => if data[tag_off + i].to_int() != c.to_int() {
        ok = false
      }
      None => ok = false
    }
    i = i + 1
  }
  ok
}

///|
/// Paeth 预测器（RFC 2083 §6，滤波类型 4 的逆变换核心）。
fn paeth(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = if p - a < 0 { a - p } else { p - a }
  let pb = if p - b < 0 { b - p } else { p - b }
  let pc = if p - c < 0 { c - p } else { p - c }
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// CRC 校验范围 = 类型字节 + 数据字节（PNG 规范）。
fn tagged_crc(data : Bytes, tag_off : Int, len : Int) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  while i < 4 + len {
    out.push(data[tag_off + i])
    i = i + 1
  }
  Bytes::from_array(out)
}
