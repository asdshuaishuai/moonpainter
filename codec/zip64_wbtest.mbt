/// ZIP64 读取路径合成样本测试（审计 D2 登记的未测路径）。
/// 手工构造带 ZIP64 EOCD + 定位器的容器（条目数 0xFFFF / cd_offset 0xFFFFFFFF
/// 触发读取器的 ZIP64 分支），验证偏移改道与条目解出。

///|
/// 字节构造辅助（小端）。
fn z64_put_u16(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn z64_put_u32(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 24) & 0xFF).to_byte())
}

///|
test "ZIP64 读取：EOCD 定位器改道中央目录" {
  // 布局：[本地头+数据 (a.txt)] [中央目录] [ZIP64 EOCD] [ZIP64 定位器] [标准 EOCD(0xFFFF 触发)]
  let out : Array[Byte] = []
  // 本地文件头 + 数据
  let name : Array[Byte] = []
  for c in "a.txt".iter() {
    name.push(c.to_int().to_byte())
  }
  let data_arr : Array[Byte] = []
  for c in "hi".iter() {
    data_arr.push(c.to_int().to_byte())
  }
  let data = Bytes::from_array(data_arr)
  z64_put_u32(out, 0x04034b50)
  z64_put_u16(out, 20)
  z64_put_u16(out, 0x0800)
  z64_put_u16(out, 0) // stored
  z64_put_u16(out, 0)
  z64_put_u16(out, 0x21)
  let crc = crc32(data)
  z64_put_u32(out, crc)
  z64_put_u32(out, data.length())
  z64_put_u32(out, data.length())
  z64_put_u16(out, name.length())
  z64_put_u16(out, 0)
  for b in name {
    out.push(b)
  }
  for b in data.iter() {
    out.push(b)
  }
  let local_end = out.length() // 中央目录起点
  // 中央目录
  let cd_start = local_end
  z64_put_u32(out, 0x02014b50)
  z64_put_u16(out, 20)
  z64_put_u16(out, 20)
  z64_put_u16(out, 0x0800)
  z64_put_u16(out, 0)
  z64_put_u16(out, 0)
  z64_put_u16(out, 0x21)
  z64_put_u32(out, crc)
  z64_put_u32(out, data.length())
  z64_put_u32(out, data.length())
  z64_put_u16(out, name.length())
  z64_put_u16(out, 0)
  z64_put_u16(out, 0)
  z64_put_u16(out, 0)
  z64_put_u16(out, 0)
  z64_put_u32(out, 0)
  z64_put_u32(out, 0) // 本地头偏移
  for b in name {
    out.push(b)
  }
  let cd_size = out.length() - cd_start
  // ZIP64 EOCD 记录
  let z64_eocd_start = out.length()
  z64_put_u32(out, 0x06064b50)
  z64_put_u64(out, 44) // 记录大小
  z64_put_u16(out, 20)
  z64_put_u16(out, 20)
  z64_put_u32(out, 0)
  z64_put_u32(out, 0)
  z64_put_u64(out, 1) // 条目数
  z64_put_u64(out, 1)
  z64_put_u64(out, cd_size)
  z64_put_u64(out, cd_start)
  // ZIP64 定位器
  z64_put_u32(out, 0x07064b50)
  z64_put_u32(out, 0)
  z64_put_u64(out, z64_eocd_start)
  z64_put_u32(out, 1)
  // 标准 EOCD：0xFFFF / 0xFFFFFFFF 触发 ZIP64 分支
  z64_put_u32(out, 0x06054b50)
  z64_put_u16(out, 0)
  z64_put_u16(out, 0)
  z64_put_u16(out, 0xFFFF)
  z64_put_u16(out, 0xFFFF)
  z64_put_u32(out, cd_size)
  z64_put_u32(out, 0xFFFFFFFF)
  z64_put_u16(out, 0)

  let z = Zip::open(Bytes::from_array(out))
  assert_eq(z.entries.length(), 1, msg="ZIP64 应解出 1 条目")
  assert_eq(z.entries[0].name, "a.txt")
  assert_eq(z.read_text("a.txt"), "hi")
  assert_eq(z.entries[0].uncompressed_size, 2)
}

///|
fn z64_put_u64(out : Array[Byte], v : Int) -> Unit {
  // 文件量级下 v < 2^31，直接按 4 段展开低 32 位 + 高位零
  z64_put_u32(out, v)
  z64_put_u32(out, 0)
}

///|
test "ZIP64 不触发：正常 EOCD 走普通路径" {
  let entries : Array[ZipOutEntry] = [
    ZipOutEntry::of_text("plain.json", "{\"p\":1}"),
  ]
  let packed = build_zip(entries)
  let z = Zip::open(packed)
  assert_eq(z.entries.length(), 1)
  assert_false(z.warnings.length() > 0)
  assert_eq(z.read_text("plain.json"), "{\"p\":1}")
}
