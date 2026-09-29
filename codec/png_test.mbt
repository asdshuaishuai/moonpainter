/// PNG 编解码测试：encode → decode 必须还原像素（同一底座往返），
/// 外加已知非法输入的拒绝路径。

///|
test "PNG 往返：1×1" {
  let buf = @codec.rgba_new(1, 1)
  @codec.rgba_set(buf, 0, 0, 0x80FF7A45) // 半透明橙
  let png = @codec.png_encode(buf)
  match @codec.png_decode(png) {
    Err(msg) => abort("1x1 解码失败: \{msg}")
    Ok(back) => {
      assert_eq(back.width, 1)
      assert_eq(back.height, 1)
      assert_eq(back.pixels[0], 0x80FF7A45)
    }
  }
}

///|
test "PNG 往返：64×64 渐变 + 随机 alpha" {
  let w = 64
  let h = 64
  let buf = @codec.rgba_new(w, h)
  let mut seed = 42
  let mut y = 0
  while y < h {
    let mut x = 0
    while x < w {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      let a = 0x40 + ((seed >> 17) & 0xFF) % 0xC0
      let r = x * 4
      let g = y * 4
      let b = ((x + y) * 2) & 0xFF
      @codec.rgba_set(buf, x, y, (a << 24) + (r << 16) + (g << 8) + b)
      x = x + 1
    }
    y = y + 1
  }
  let png = @codec.png_encode(buf)
  match @codec.png_decode(png) {
    Err(msg) => abort("渐变图解码失败: \{msg}")
    Ok(back) => {
      assert_eq(back.width, w)
      assert_eq(back.height, h)
      let mut i = 0
      while i < w * h {
        assert_eq(back.pixels[i], buf.pixels[i])
        i = i + 1
      }
    }
  }
}

///|
test "PNG 编码确定性 + 压缩真的生效" {
  let buf = @codec.rgba_new(32, 32)
  @codec.fill_rect_rgba(buf, 0, 0, 16, 32, @codec.color_from_hex("#FF0000"))
  @codec.fill_rect_rgba(buf, 16, 0, 16, 32, @codec.color_from_hex("#0000FF"))
  let a = @codec.png_encode(buf)
  let b = @codec.png_encode(buf)
  assert_eq(a.length(), b.length())
  let mut i = 0
  while i < a.length() {
    assert_eq(a[i].to_int(), b[i].to_int())
    i = i + 1
  }
  // 32×32 无滤波 + 真 deflate：双色块必须明显小于原始扫描线
  let raw_scanlines = 32 * (1 + 32 * 4)
  assert_true(a.length() < raw_scanlines, msg="PNG 应被压缩: \{a.length()} vs \{raw_scanlines}")
}

///|
test "PNG 解码拒绝：坏签名 / 截断 / 空" {
  match @codec.png_decode(Bytes::from_array([])) {
    Err(_) => assert_true(true)
    Ok(_) => abort("空输入不该解码成功")
  }
  let not_png = @utf8.encode("hello world, definitely not a png")
  match @codec.png_decode(not_png) {
    Err(msg) => assert_true(msg.length() > 0)
    Ok(_) => abort("非 PNG 不该解码成功")
  }
  let buf = @codec.rgba_new(8, 8)
  @codec.fill_rect_rgba(buf, 0, 0, 8, 8, @codec.color_from_hex("#336699"))
  let good = @codec.png_encode(buf)
  // 掐掉尾部若干字节 → 必须报错而不是崩溃
  let cut = slice_for_test(good, good.length() - 10)
  match @codec.png_decode(cut) {
    Err(_) => assert_true(true)
    Ok(_) => abort("截断 PNG 不该解码成功")
  }
}

///|
/// 测试辅助：取前 n 字节（slice_bytes 是 zip.mbt 私有，这里包一层可见性）。
fn slice_for_test(b : Bytes, n : Int) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  while i < n && i < b.length() {
    out.push(b[i])
    i = i + 1
  }
  Bytes::from_array(out)
}
