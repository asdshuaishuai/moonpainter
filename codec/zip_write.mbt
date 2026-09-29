/// codec —— ZIP 写入（codec/zip_write）。
///
/// 来源：deepOffice/ooxml/zip_write.mbt（自有 MIT，手写实现），移植时保持
/// 实现一致；差异：`trim_num` 换为本地实现、注释措辞改为 .mpd 语境。
///
/// 与 `zip.mbt`（读取）分开的理由：**读取必须宽容，写入必须精确**。
/// 读要应付追加数据、截断的中央目录、非标准偏移、ZIP64；写则必须产出
/// 严格合规的字节，因为接收方可能是任何解压器与未来的引擎版本。
///
/// **确定性输出**是这一层的一条硬约束：同一个文档打包两次，字节必须完全
/// 相同。所以时间戳固定为 DOS 纪元（1980-01-01），条目顺序由调用方给定
/// 而非哈希遍历。理由：不可 diff 的产物无法进版本管理，而 .mpd 恰恰是
/// 最需要进版本管理的东西。

///|
/// 要写进 ZIP 的一个条目。
pub(all) struct ZipOutEntry {
  /// 部件名（容器内路径，如 `meta/design.json`）。
  name : String
  data : Bytes
  /// 是否压缩。已压缩的媒体（png）用存储更划算——再压一遍几乎不省，
  /// 还多花 CPU。
  compress : Bool
}

///|
/// 新建一个待压缩条目。
pub fn ZipOutEntry::new(
  name : String,
  data : Bytes,
  compress? : Bool = true,
) -> ZipOutEntry {
  { name, data, compress, }
}

///|
/// 从字符串建条目（JSON 部件用）。
pub fn ZipOutEntry::of_text(
  name : String,
  text : String,
  compress? : Bool = true,
) -> ZipOutEntry {
  { name, data: @utf8.encode(text), compress, }
}

///|
/// 写小端 u16。
fn put_u16(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
}

///|
/// 写小端 u32。
fn put_u32(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 24) & 0xFF).to_byte())
}

///|
/// DOS 时间戳固定值：1980-01-01 00:00:00（DOS 纪元）。
/// dos_time = 0，dos_date = 0x0021（年 0 + 月 1 + 日 1）。
let dos_time : Int = 0

///|
let dos_date : Int = 0x0021

///|
/// 打包成一个 ZIP。
pub fn build_zip(entries : Array[ZipOutEntry]) -> Bytes {
  let lbuf : Array[Byte] = []
  // 中央目录每条记录的偏移与尺寸，写完本地数据后回填
  let offsets : Array[Int] = []
  let crcs : Array[Int] = []
  let comp_sizes : Array[Int] = []
  let raw_sizes : Array[Int] = []
  let methods : Array[Int] = []

  for e in entries {
    let name_bytes = @utf8.encode(e.name)
    let crc = crc32(e.data)
    let raw_len = e.data.length()
    // 太小的数据压不动（deflate 头尾开销就 5 字节），直接存储
    let use_deflate = e.compress && raw_len >= 64
    let payload = if use_deflate {
      deflate(e.data, level=Balanced)
    } else {
      e.data
    }
    // 压完反而更大时退回存储——不做这一步会产出比原始还大的“压缩”文件
    let (zmethod, body) = if use_deflate && payload.length() < raw_len {
      (8, payload)
    } else {
      (0, e.data)
    }

    offsets.push(lbuf.length())
    crcs.push(crc)
    comp_sizes.push(body.length())
    raw_sizes.push(raw_len)
    methods.push(zmethod)

    // 本地文件头
    put_u32(lbuf, 0x04034b50)
    put_u16(lbuf, 20) // version needed: 2.0
    put_u16(lbuf, 0x0800) // flags: bit 11 = UTF-8 文件名
    put_u16(lbuf, zmethod)
    put_u16(lbuf, dos_time)
    put_u16(lbuf, dos_date)
    put_u32(lbuf, crc)
    put_u32(lbuf, body.length())
    put_u32(lbuf, raw_len)
    put_u16(lbuf, name_bytes.length())
    put_u16(lbuf, 0) // extra len
    for i = 0; i < name_bytes.length(); i = i + 1 {
      lbuf.push(name_bytes[i])
    }
    for i = 0; i < body.length(); i = i + 1 {
      lbuf.push(body[i])
    }
  }

  let cd_start = lbuf.length()
  let central : Array[Byte] = []
  let mut i = 0
  while i < entries.length() {
    let e = entries[i]
    let name_bytes = @utf8.encode(e.name)
    put_u32(central, 0x02014b50)
    put_u16(central, 20) // version made by
    put_u16(central, 20) // version needed
    put_u16(central, 0x0800) // flags
    put_u16(central, methods[i])
    put_u16(central, dos_time)
    put_u16(central, dos_date)
    put_u32(central, crcs[i])
    put_u32(central, comp_sizes[i])
    put_u32(central, raw_sizes[i])
    put_u16(central, name_bytes.length())
    put_u16(central, 0) // extra
    put_u16(central, 0) // comment
    put_u16(central, 0) // disk number start
    put_u16(central, 0) // internal attrs
    put_u32(central, 0) // external attrs
    put_u32(central, offsets[i])
    for k = 0; k < name_bytes.length(); k = k + 1 {
      central.push(name_bytes[k])
    }
    i = i + 1
  }

  let out = lbuf.copy()
  for b in central {
    out.push(b)
  }
  // EOCD
  put_u32(out, 0x06054b50)
  put_u16(out, 0) // this disk
  put_u16(out, 0) // disk with CD
  put_u16(out, entries.length())
  put_u16(out, entries.length())
  put_u32(out, central.length())
  put_u32(out, cd_start)
  put_u16(out, 0) // comment length
  Bytes::from_array(out)
}

///|
/// 打包概览（用于日志与诊断）。
pub fn zip_report(entries : Array[ZipOutEntry], packed : Bytes) -> String {
  let mut raw = 0
  for e in entries {
    raw = raw + e.data.length()
  }
  let ratio = if raw > 0 {
    packed.length().to_double() / raw.to_double()
  } else {
    1.0
  }
  "\{entries.length()} 个部件 · 原始 \{raw} 字节 → 打包 \{packed.length()} 字节（\{trim_num1(ratio * 100.0)}%）"
}
