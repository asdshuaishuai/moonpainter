/// 压缩与打包往返测试。
///
/// 来源：deepOffice/ooxml/deflate_test.mbt（自有 MIT），移植时去掉 XML 专项，
/// 其余保持判据一致：**压出来的东西必须能被解回去**，且输出确定、边界完备。

///|
test "deflate/inflate 往返：纯 ASCII 高冗余文本" {
  let src = "Hello, MoonPainter! ".repeat(200)
  let raw = @utf8.encode(src)
  let packed = @codec.deflate(raw)
  let back = @codec.inflate(packed)
  assert_true(back.complete)
  assert_eq(back.size, raw.length())
  assert_eq(@codec.decode_utf8_lossy(back.data), src)
  // 高冗余文本必须真的被压下去，否则说明 LZ77 匹配没生效
  assert_true(
    packed.length() < raw.length() / 4,
    msg="压缩率异常：\{packed.length()} / \{raw.length()}",
  )
}

///|
test "deflate/inflate 往返：UTF-8 中文" {
  let src = "元参数层与设计稿层：一个容器，两种读法。".repeat(50)
  let raw = @utf8.encode(src)
  let packed = @codec.deflate(raw)
  let back = @codec.inflate(packed)
  assert_true(back.complete)
  assert_eq(@codec.decode_utf8_lossy(back.data), src)
}

///|
test "deflate/inflate 往返：JSON 形态（.mpd meta 部件载荷特征）" {
  let src = "{\"format\":\"moonpainter.mpd\",\"version\":1,\"canvas\":{\"w\":800,\"h\":600}," +
    "\"layers\":[{\"id\":\"bg\",\"kind\":\"rect\",\"x\":0,\"y\":0,\"w\":800,\"h\":600}]}"
  let raw = @utf8.encode(src)
  let packed = @codec.deflate(raw)
  let back = @codec.inflate(packed)
  assert_true(back.complete)
  assert_eq(@codec.decode_utf8_lossy(back.data), src)
}

///|
test "deflate/inflate 往返：随机字节（不可压缩）" {
  // 不可压缩数据走全字面量路径，覆盖"没有匹配"的分支
  let arr : Array[Byte] = []
  let mut seed = 12345
  let mut i = 0
  while i < 3000 {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    arr.push(((seed >> 16) & 0xFF).to_byte())
    i = i + 1
  }
  let raw = Bytes::from_array(arr)
  let packed = @codec.deflate(raw)
  let back = @codec.inflate(packed)
  assert_true(back.complete)
  assert_eq(back.size, raw.length())
  // 逐字节比对
  let mut j = 0
  while j < raw.length() {
    assert_eq(back.data[j].to_int(), raw[j].to_int())
    j = j + 1
  }
}

///|
test "deflate/inflate 往返：空输入" {
  let empty : Bytes = Bytes::from_array([])
  let packed = @codec.deflate(empty)
  let back = @codec.inflate(packed)
  assert_true(back.complete)
  assert_eq(back.size, 0)
}

///|
test "deflate/inflate 往返：边界长度（1/2/3/258/259 字节）" {
  // 2 字节以下无法产生匹配，258 是最大匹配长度，259 会跨过它
  for n in [1, 2, 3, 257, 258, 259, 260] {
    let arr : Array[Byte] = []
    let mut i = 0
    while i < n {
      arr.push((65 + i % 26).to_byte())
      i = i + 1
    }
    let raw = Bytes::from_array(arr)
    let packed = @codec.deflate(raw)
    let back = @codec.inflate(packed)
    assert_eq(back.size, n)
    assert_eq(@codec.decode_utf8_lossy(back.data), @codec.decode_utf8_lossy(raw))
  }
}

///|
test "deflate 输出是确定性的" {
  // 同一份输入压两次必须字节相同——否则 .mpd 无法 diff、指纹失去意义。
  let raw = @utf8.encode("确定性测试 ".repeat(100))
  let a = @codec.deflate(raw)
  let b = @codec.deflate(raw)
  assert_eq(a.length(), b.length())
  let mut i = 0
  while i < a.length() {
    assert_eq(a[i].to_int(), b[i].to_int())
    i = i + 1
  }
}

///|
test "三种压缩级别的输出都能解回原文" {
  let raw = @utf8.encode("级别测试：同一份数据在不同搜索深度下都要正确。".repeat(80))
  for lvl in [@codec.DeflateLevel::Fast, @codec.DeflateLevel::Balanced, @codec.DeflateLevel::Best] {
    let packed = @codec.deflate(raw, level=lvl)
    let back = @codec.inflate(packed)
    assert_true(back.complete)
    assert_eq(@codec.decode_utf8_lossy(back.data), @codec.decode_utf8_lossy(raw))
  }
}

///|
test "CRC32 已知答案（IEEE 802.3，标准检验向量）" {
  // 用位模式比对，避免 32 位无符号值落在 Int 负区的歧义
  let c = @codec.crc32(@utf8.encode("123456789")).to_int64() & 0xFFFFFFFFL
  assert_eq(c, 0xCBF43926L)
  assert_eq(@codec.crc32(Bytes::from_array([])), 0)
}

///|
test "ZIP 打包后能被自己的读取器解回" {
  let entries : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::of_text("manifest.json", "{\"format\":\"moonpainter.mpd\"}"),
    @codec.ZipOutEntry::of_text("meta/design.json", "{\"layers\":[]}"),
    @codec.ZipOutEntry::of_text(
      "meta/params.json",
      "{\"named\":{" + "\"k\":\"v\"".repeat(100) + "}}",
    ),
  ]
  let packed = @codec.build_zip(entries)
  let z = @codec.Zip::open(packed)
  assert_eq(z.entries.length(), 3)
  assert_eq(z.read_text("manifest.json"), "{\"format\":\"moonpainter.mpd\"}")
  assert_eq(z.read_text("meta/design.json"), "{\"layers\":[]}")
  assert_eq(
    z.read_text("meta/params.json"),
    "{\"named\":{" + "\"k\":\"v\"".repeat(100) + "}}",
  )
}

///|
test "ZIP 打包保留 CRC 且读回时校验一致" {
  let text = "CRC 校验载荷：" + "重复内容".repeat(200)
  let entries : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::of_text("meta/agent.json", text),
  ]
  let packed = @codec.build_zip(entries)
  let z = @codec.Zip::open(packed)
  let e = z.entries[0]
  assert_true(z.check_crc(e))
  assert_eq(e.uncompressed_size, z.read_entry(e).length())
}

///|
test "ZIP 打包是确定性的（.mpd 指纹的前提）" {
  let entries : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::of_text("a.json", "{\"a\":1}"),
    @codec.ZipOutEntry::of_text("b.json", "{\"b\":2}".repeat(100)),
  ]
  let p1 = @codec.build_zip(entries)
  let p2 = @codec.build_zip(entries)
  assert_eq(p1.length(), p2.length())
  let mut i = 0
  while i < p1.length() {
    assert_eq(p1[i].to_int(), p2[i].to_int())
    i = i + 1
  }
}

///|
test "小部件走存储路径，大部件走压缩路径" {
  // 小于阈值的数据压了反而更大（deflate 块头+码表开销），必须存储
  let small : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::of_text("tiny.json", "{}"),
  ]
  let p_small = @codec.build_zip(small)
  let z_small = @codec.Zip::open(p_small)
  assert_eq(z_small.entries[0].compression, 0)

  let large : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::of_text("big.json", "{\"row\":\"数据\"}".repeat(100)),
  ]
  let p_large = @codec.build_zip(large)
  let z_large = @codec.Zip::open(p_large)
  assert_eq(z_large.entries[0].compression, 8)
  assert_eq(z_large.read_text("big.json"), "{\"row\":\"数据\"}".repeat(100))
}

///|
test "已压缩媒体条目应存储而非再压" {
  let arr : Array[Byte] = []
  let mut seed = 999
  let mut i = 0
  while i < 5000 {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    arr.push(((seed >> 15) & 0xFF).to_byte())
    i = i + 1
  }
  let media : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::new(
      "assets/sha256/abc000.png",
      Bytes::from_array(arr),
      compress=false,
    ),
  ]
  let packed = @codec.build_zip(media)
  let z = @codec.Zip::open(packed)
  assert_eq(z.entries[0].compression, 0)
  assert_eq(z.entries[0].uncompressed_size, 5000)
}

///|
test "UTF-8 部件名能正确往返" {
  let entries : Array[@codec.ZipOutEntry] = [
    @codec.ZipOutEntry::of_text("assets/sha256/图片一.png", "fake png data"),
  ]
  let packed = @codec.build_zip(entries)
  let z = @codec.Zip::open(packed)
  assert_eq(z.entries[0].name, "assets/sha256/图片一.png")
  assert_eq(z.read_text("assets/sha256/图片一.png"), "fake png data")
}
