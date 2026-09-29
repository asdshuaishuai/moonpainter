/// codec —— ZIP 容器读取（codec/zip）。
///
/// 来源：deepOffice/ooxml/zip.mbt（自有 MIT，手写实现），移植时保持实现
/// 一致；差异：错误措辞改为 .mpd 语境、`trim_num` 换为本地实现、
/// 读条目时提供 CRC 校验入口（.mpd 的拒绝式校验需要它）。
///
/// .mpd 的物理容器就是 ZIP：manifest + meta 文本 + 资产 + 预览。
///
/// 宽容原则（这几条决定了能不能打开真实世界的文件）：
/// - **不信任 EOCD 里的偏移**：文件尾部可能被追加过数据，所以从尾部
///   反向搜索 EOCD 签名，而不是按固定位置读。
/// - **优先用中央目录**：本地头的 size 字段在流式写入时可能为 0，
///   真实尺寸以中央目录为准。
/// - **不全量解压**：`entries` 只登记元数据，`read` 按需解压。

///|
/// ZIP 签名常量。
let sig_eocd : Int = 0x06054b50

///|
let sig_eocd64 : Int = 0x06064b50

///|
let sig_central : Int = 0x02014b50

///|
let sig_local : Int = 0x04034b50

///|
let sig_eocd64_locator : Int = 0x07064b50

///|
/// 从字节里读小端整数。越界返回 0（而不是抛错）——
/// 处理损坏 ZIP 时，一个越界读数不该让整个容器打不开。
fn rd_u16(b : Bytes, off : Int) -> Int {
  if off < 0 || off + 2 > b.length() {
    return 0
  }
  (b[off].to_int() & 0xFF) | ((b[off + 1].to_int() & 0xFF) << 8)
}

///|
fn rd_u32(b : Bytes, off : Int) -> Int {
  if off < 0 || off + 4 > b.length() {
    return 0
  }
  (b[off].to_int() & 0xFF) |
  ((b[off + 1].to_int() & 0xFF) << 8) |
  ((b[off + 2].to_int() & 0xFF) << 16) |
  ((b[off + 3].to_int() & 0xFF) << 24)
}

///|
/// 大端 u32 读取（PNG 这类网络字节序格式用；放这里与 rd_u32 对仗）。
fn rd_be32(b : Bytes, off : Int) -> Int {
  if off < 0 || off + 4 > b.length() {
    return 0
  }
  ((b[off].to_int() & 0xFF) << 24) |
  ((b[off + 1].to_int() & 0xFF) << 16) |
  ((b[off + 2].to_int() & 0xFF) << 8) |
  (b[off + 3].to_int() & 0xFF)
}

///|
/// 一个 ZIP 条目的元数据。
pub(all) struct ZipEntry {
  name : String
  /// 压缩方法：0 = 存储，8 = deflate。
  compression : Int
  compressed_size : Int
  uncompressed_size : Int
  crc32 : Int
  /// 本地头偏移——解压时需要从这里读数据起始位置。
  local_offset : Int
  /// 是否目录（名字以 / 结尾）。
  is_dir : Bool
}

///|
/// 打开的 ZIP 容器。持有原始字节与中央目录，按需解压。
pub(all) struct Zip {
  data : Bytes
  entries : Array[ZipEntry]
  /// 打开过程中积累的问题（不致命，但值得暴露给调用方）。
  warnings : Array[String]
}

///|
/// 从文件尾部反向搜索 EOCD 签名。
///
/// 反向搜索而不是从固定偏移读：ZIP 注释最长 65535 字节，且文件可能被
/// 追加过数据，EOCD 的实际位置是不确定的。只在最后 64KB + 22 字节范围内找
/// （规范允许的最大界限）。
fn find_eocd(b : Bytes) -> Int {
  let n = b.length()
  let max_back = 65557
  let start = if n > max_back { n - max_back } else { 0 }
  let mut i = n - 22
  while i >= start && i >= 0 {
    if rd_u32(b, i) == sig_eocd {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// 打开一份 ZIP。失败返回带 warnings 的空容器，而不是抛异常——
/// 调用方可以据此给出「这不是有效的 .mpd 文件」这类具体诊断。
pub fn Zip::open(data : Bytes) -> Zip {
  let warnings : Array[String] = []
  let eocd = find_eocd(data)
  if eocd < 0 {
    warnings.push("未找到 ZIP 中央目录（EOCD）签名——文件不是 ZIP 容器，或已损坏")
    return { data, entries: [], warnings, }
  }
  let mut total = rd_u16(data, eocd + 10)
  let mut cd_offset = rd_u32(data, eocd + 16)
  let cd_size = rd_u32(data, eocd + 12)

  // ZIP64：当条目数或偏移是 0xFFFF/0xFFFFFFFF 时，真实值在 ZIP64 结构里。
  if total == 0xFFFF || cd_offset == 0xFFFFFFFF {
    let loc = eocd - 20
    if loc >= 0 && rd_u32(data, loc) == sig_eocd64_locator {
      let z64 = rd_u32(data, loc + 8)
      if z64 >= 0 && rd_u32(data, z64) == sig_eocd64 {
        let t = rd_u32(data, z64 + 32)
        if t > 0 {
          total = t
        }
        let off = rd_u32(data, z64 + 48)
        if off > 0 {
          cd_offset = off
        }
        warnings.push("使用了 ZIP64 扩展结构")
      }
    }
  }

  let entries : Array[ZipEntry] = []
  let mut p = cd_offset
  let mut i = 0
  while i < total {
    if p + 46 > data.length() || rd_u32(data, p) != sig_central {
      // 中央目录被截断：把已读到的部分当作全部，并如实报告
      if i < total {
        warnings.push("中央目录在第 \{i} 项处截断（声明 \{total} 项）")
      }
      break
    }
    let comp_method = rd_u16(data, p + 10)
    let crc = rd_u32(data, p + 16)
    let csize = rd_u32(data, p + 20)
    let usize = rd_u32(data, p + 24)
    let nlen = rd_u16(data, p + 28)
    let elen = rd_u16(data, p + 30)
    let clen = rd_u16(data, p + 32)
    let lho = rd_u32(data, p + 42)
    let name_bytes = slice_bytes(data, p + 46, nlen)
    let name = decode_utf8_lossy(name_bytes)
    entries.push({
      name,
      compression: comp_method,
      compressed_size: csize,
      uncompressed_size: usize,
      crc32: crc,
      local_offset: lho,
      is_dir: name.has_suffix("/"),
    })
    p = p + 46 + nlen + elen + clen
    i = i + 1
  }
  let _ = cd_size
  { data, entries, warnings, }
}

///|
/// 切片辅助：钳制到合法范围（损坏文件里的长度字段可能是垃圾）。
fn slice_bytes(b : Bytes, off : Int, len : Int) -> Bytes {
  let start = if off < 0 { 0 } else { off }
  let end = if off + len > b.length() { b.length() } else { off + len }
  if end <= start {
    return Bytes::from_array([])
  }
  let out : Array[Byte] = []
  let mut i = start
  while i < end {
    out.push(b[i])
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
/// 按名字找一个条目。
pub fn Zip::find(self : Zip, name : String) -> ZipEntry? {
  for e in self.entries {
    if e.name == name {
      return Some(e)
    }
  }
  None
}

///|
/// 是否有某个部件。
pub fn Zip::has(self : Zip, name : String) -> Bool {
  self.find(name) is Some(_)
}

///|
/// 列出所有条目名。
pub fn Zip::names(self : Zip) -> Array[String] {
  let out : Array[String] = []
  for e in self.entries {
    out.push(e.name)
  }
  out
}

///|
/// 按前缀列出条目名（如 `meta/`）。
pub fn Zip::names_under(self : Zip, prefix : String) -> Array[String] {
  let out : Array[String] = []
  for e in self.entries {
    if e.name.has_prefix(prefix) {
      out.push(e.name)
    }
  }
  out
}

///|
/// 解压一个条目的内容。失败返回空字节（warnings 里可查原因）。
pub fn Zip::read(self : Zip, name : String) -> Bytes {
  match self.find(name) {
    None => Bytes::from_array([])
    Some(e) => self.read_entry(e)
  }
}

///|
/// 按条目解压。
pub fn Zip::read_entry(self : Zip, e : ZipEntry) -> Bytes {
  if e.is_dir {
    return Bytes::from_array([])
  }
  let lho = e.local_offset
  if lho < 0 || lho + 30 > self.data.length() {
    return Bytes::from_array([])
  }
  if rd_u32(self.data, lho) != sig_local {
    // 本地头签名不对：偏移可能是错的（有些工具写相对偏移），放弃读取。
    return Bytes::from_array([])
  }
  let nlen = rd_u16(self.data, lho + 26)
  let elen = rd_u16(self.data, lho + 28)
  let data_start = lho + 30 + nlen + elen
  // 用中央目录记录的长度，而不是本地头的（本地头在流式写入时为 0）
  let csize = e.compressed_size
  if data_start + csize > self.data.length() {
    return Bytes::from_array([])
  }
  let payload = slice_bytes(self.data, data_start, csize)
  if e.compression == 0 {
    payload
  } else if e.compression == 8 {
    inflate(payload).data
  } else {
    // 压缩方法 12 = bzip2、14 = LZMA、93 = zstd 等：一律返回空，
    // 由调用方报「不支持」。
    Bytes::from_array([])
  }
}

///|
/// 条目 CRC 校验：解压结果与中央目录记录的 CRC32 比对。
/// .mpd 打开时的拒绝式校验逐条走这里。
pub fn Zip::check_crc(self : Zip, e : ZipEntry) -> Bool {
  let raw = self.read_entry(e)
  raw.length() == e.uncompressed_size && crc32(raw) == e.crc32
}

///|
/// 解压并解码为文本（JSON 部件用）。
pub fn Zip::read_text(self : Zip, name : String) -> String {
  decode_utf8_lossy(self.read(name))
}

///|
/// 概览：条目数、压缩/原始总大小、涉及的方法。
pub fn Zip::summary(self : Zip) -> String {
  let mut raw = 0
  let mut comp = 0
  let mut stored = 0
  let mut deflated = 0
  for e in self.entries {
    raw = raw + e.uncompressed_size
    comp = comp + e.compressed_size
    if e.compression == 0 {
      stored = stored + 1
    } else if e.compression == 8 {
      deflated = deflated + 1
    }
  }
  let ratio = if raw > 0 {
    100.0 - comp.to_double() / raw.to_double() * 100.0
  } else {
    0.0
  }
  "\{self.entries.length()} 项 · 原始 \{raw} 字节 · 压缩 \{comp} 字节（省 \{trim_num1(ratio)}%）· 存储 \{stored} / deflate \{deflated}"
}

///|
/// CRC32（IEEE 802.3 多项式 0xEDB88320，反射）。
/// 用于校验解压结果——解压器写错时，CRC 不匹配是最早能发现的信号。
pub fn crc32(b : Bytes) -> Int {
  let mut crc = 0xFFFFFFFF
  let mut i = 0
  while i < b.length() {
    crc = crc ^ (b[i].to_int() & 0xFF)
    let mut k = 0
    while k < 8 {
      // 逻辑右移：MoonBit 的 >> 对 Int 是算术移位，所以先掩掉符号位
      let low = crc & 1
      crc = (crc >> 1) & 0x7FFFFFFF
      if low == 1 {
        crc = crc ^ 0xEDB88320
      }
      k = k + 1
    }
    i = i + 1
  }
  crc ^ 0xFFFFFFFF
}

///|
/// 保留 1 位小数的数字格式化（诊断字符串用，deepOffice core.trim_num 的
/// 本地替身；本包内取值恒 ≥ 0）。
fn trim_num1(v : Double) -> String {
  let rounded = (v * 10.0 + 0.5).to_int()
  let whole = rounded / 10
  let frac = rounded % 10
  "\{whole}.\{frac}"
}
