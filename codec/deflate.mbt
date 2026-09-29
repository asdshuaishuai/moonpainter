/// codec —— DEFLATE 压缩（codec/deflate）。
///
/// 来源：deepOffice/ooxml/deflate.mbt（自有 MIT，手写实现），
/// 移植时保持实现一致，仅调整文件头说明。
///
/// 与 `inflate.mbt` 共享同一套长度/距离码表（`len_base`/`len_extra`/
/// `dist_base`/`dist_extra` 就在那个文件里）。这不是巧合，是刻意的：
/// 编解码用同一份常量，**不可能出现“编码器按 A 表写、解码器按 B 表读”
/// 这类只在往返时才暴露的错**。
///
/// 实现选型：**固定 Huffman 块**（BTYPE=1）+ 哈希链 LZ77。
///
/// 为什么不用动态 Huffman（BTYPE=2）：它要多传一棵码树，对 1–20KB 的
/// JSON/PNG 扫描线部件省下的字节常常抵不过码树本身的开销；而实现复杂度
/// 是数倍（要统计频率、建 Huffman 树、限制码长到 15 位）。
///
/// 压缩级别可以通过 `max_chain` 调节：值越大搜匹配越深、压得越小、越慢。

///|
/// 位写入器（LSB 优先，deflate 的基本位序）。
pub(all) struct BitWriter {
  out : Array[Byte]
  mut acc : Int
  mut nbits : Int
}

///|
pub fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0, nbits: 0, }
}

///|
/// 写 n 位（LSB 优先）。n ≤ 24。
pub fn BitWriter::write_bits(self : BitWriter, bits : Int, count : Int) -> Unit {
  self.acc = self.acc | ((bits & ((1 << count) - 1)) << self.nbits)
  self.nbits = self.nbits + count
  while self.nbits >= 8 {
    self.out.push((self.acc & 0xFF).to_byte())
    self.acc = self.acc >> 8
    self.nbits = self.nbits - 8
  }
}

///|
/// 写一个 Huffman 码。**注意位序**：deflate 规定 Huffman 码按**高位优先**
/// 写入，而其他所有值（额外位、长度）按低位优先。这两个方向不一致，
/// 是实现里最容易搞反的地方——搞反的后果是压缩正常但解压全是乱码。
pub fn BitWriter::write_code(self : BitWriter, code : Int, len : Int) -> Unit {
  self.write_bits(reverse_bits(code, len), len)
}

///|
/// 反转低 len 位的顺序。
fn reverse_bits(code : Int, len : Int) -> Int {
  let mut v = code
  let mut r = 0
  let mut i = 0
  while i < len {
    r = (r << 1) | (v & 1)
    v = v >> 1
    i = i + 1
  }
  r
}

///|
/// 字节对齐（补零到整字节）。
pub fn BitWriter::align_byte(self : BitWriter) -> Unit {
  if self.nbits > 0 {
    self.out.push((self.acc & 0xFF).to_byte())
    self.acc = 0
    self.nbits = 0
  }
}

///|
/// 收尾并取出字节。
pub fn BitWriter::finish(self : BitWriter) -> Bytes {
  self.align_byte()
  Bytes::from_array(self.out)
}

///|
/// 固定 Huffman 的字面/长度码（RFC 1951 §3.2.6）。
/// 返回 (码值, 位长)。
///
/// 分段是规范定死的，抄错一段就会产出无法解压的流：
///   0–143   → 8 位，0x30 起
///   144–255 → 9 位，0x190 起
///   256–279 → 7 位，0x0 起
///   280–287 → 8 位，0xC0 起
fn fixed_lit_code(sym : Int) -> (Int, Int) {
  if sym <= 143 {
    (0x30 + sym, 8)
  } else if sym <= 255 {
    (0x190 + sym - 144, 9)
  } else if sym <= 279 {
    (sym - 256, 7)
  } else {
    (0xC0 + sym - 280, 8)
  }
}

///|
/// 固定 Huffman 的距离码：5 位，值即码（0–29），高位优先写出。
fn fixed_dist_code(sym : Int) -> (Int, Int) {
  (sym, 5)
}

///|
/// 长度 → (长度码, 额外位数, 额外位值)。
/// 与 inflate 端读的是同一组 `len_base`/`len_extra`。
fn length_code_info(len : Int) -> (Int, Int, Int) {
  let mut i = 0
  while i < len_base.length() {
    let base = len_base[i]
    let extra = len_extra[i]
    let max = base + ((1 << extra) - 1)
    if len >= base && len <= max {
      return (257 + i, extra, len - base)
    }
    i = i + 1
  }
  // 超出可编码范围：用最大码兜底（调用方不该走到这里）
  (285, 0, 0)
}

///|
/// 距离 → (距离码, 额外位数, 额外位值)。
fn dist_code_info(dist : Int) -> (Int, Int, Int) {
  let mut i = 0
  while i < dist_base.length() {
    let base = dist_base[i]
    let extra = dist_extra[i]
    let max = base + ((1 << extra) - 1)
    if dist >= base && dist <= max {
      return (i, extra, dist - base)
    }
    i = i + 1
  }
  (29, 13, 0)
}

///|
/// 写一个长度/距离对。
fn BitWriter::write_match(
  self : BitWriter,
  length : Int,
  distance : Int,
) -> Unit {
  let (lcode, lextra, lval) = length_code_info(length)
  let (lc, ll) = fixed_lit_code(lcode)
  self.write_code(lc, ll)
  if lextra > 0 {
    self.write_bits(lval, lextra)
  }
  let (dcode, dextra, dval) = dist_code_info(distance)
  let (dc, dl) = fixed_dist_code(dcode)
  self.write_code(dc, dl)
  if dextra > 0 {
    self.write_bits(dval, dextra)
  }
}

// ---------------------------------------------------------------------------
// LZ77 匹配
// ---------------------------------------------------------------------------

///|
/// 最短可编码匹配长度（deflate 的下限）。
let min_match : Int = 3

///|
/// 最长可编码匹配长度（deflate 的上限）。
let max_match : Int = 258

///|
/// 滑动窗口大小（deflate 的规定值）。
let window_size : Int = 32768

///|
/// 哈希表桶数。必须是 2 的幂，用掩码取模。
/// 16 位（65536 桶）对文本与扫描线都足够，且表本身只占 256KB。
let hash_bits : Int = 16

///|
let hash_mask : Int = (1 << hash_bits) - 1

///|
/// 三字节哈希。deflate 的最小匹配是 3 字节，所以用 3 字节做键最自然。
fn hash3(data : Bytes, pos : Int) -> Int {
  let a = data[pos].to_int() & 0xFF
  let b = data[pos + 1].to_int() & 0xFF
  let c = data[pos + 2].to_int() & 0xFF
  ((a << 10) ^ (b << 5) ^ c) & hash_mask
}

///|
/// 把 pos 处的 3 字节插入哈希链。
fn insert_hash(
  data : Bytes,
  pos : Int,
  head : FixedArray[Int],
  prev : FixedArray[Int],
) -> Unit {
  if pos + 2 >= data.length() {
    return
  }
  let h = hash3(data, pos)
  prev[pos] = head[h]
  head[h] = pos
}

///|
/// 压缩级别：哈希链搜索深度。越高越慢、压得越小。
pub(all) enum DeflateLevel {
  /// 快（链深 8）：适合大量小部件
  Fast
  /// 均衡（链深 32）：默认
  Balanced
  /// 高压缩（链深 128）：适合大媒体/长文本
  Best
}

///|
fn chain_limit(level : DeflateLevel) -> Int {
  match level {
    Fast => 8
    Balanced => 32
    Best => 128
  }
}

///|
/// 把数据压成 raw deflate 流（单个固定 Huffman 块）。
///
/// 不切分成多块：ZIP 的载荷本身没有大小限制，而单块省掉了块头的开销，
/// 也让实现少一处状态机。对 .mpd 的部件尺寸（KB 级到 MB 级）都合适。
pub fn deflate(data : Bytes, level? : DeflateLevel = Balanced) -> Bytes {
  let w = BitWriter::new()
  // 块头：BFINAL=1, BTYPE=01（固定 Huffman），低位优先
  w.write_bits(1, 1)
  w.write_bits(1, 2)

  let n = data.length()
  if n == 0 {
    // 空输入也要写一个结束码，否则解压端读不到块尾
    let (c, l) = fixed_lit_code(256)
    w.write_code(c, l)
    return w.finish()
  }

  let head : FixedArray[Int] = FixedArray::make(1 << hash_bits, -1)
  let prev : FixedArray[Int] = FixedArray::make(n, -1)
  let max_chain = chain_limit(level)

  let mut pos = 0
  while pos < n {
    let remaining = n - pos
    let mut best_len = 0
    let mut best_dist = 0

    if remaining >= min_match {
      let h = hash3(data, pos)
      let mut candidate = head[h]
      let limit = if pos > window_size { pos - window_size } else { 0 }
      let max_len = if remaining < max_match { remaining } else { max_match }
      let mut chain = 0
      while candidate >= limit && chain < max_chain {
        // 先比首字节和末字节（快速否定），再比全长
        if data[candidate].to_int() == data[pos].to_int() &&
          data[candidate + 1].to_int() == data[pos + 1].to_int() &&
          data[candidate + 2].to_int() == data[pos + 2].to_int() {
          let mut l = min_match
          while l < max_len &&
                data[candidate + l].to_int() == data[pos + l].to_int() {
            l = l + 1
          }
          if l > best_len {
            best_len = l
            best_dist = pos - candidate
            if l >= max_len {
              break
            }
          }
        }
        candidate = prev[candidate]
        chain = chain + 1
      }
    }

    if best_len >= min_match {
      w.write_match(best_len, best_dist)
      // 匹配覆盖的每个位置都要入表，否则后续匹配会漏掉这些起点
      let mut i = 0
      while i < best_len {
        insert_hash(data, pos + i, head, prev)
        i = i + 1
      }
      pos = pos + best_len
    } else {
      let (c, l) = fixed_lit_code(data[pos].to_int() & 0xFF)
      w.write_code(c, l)
      insert_hash(data, pos, head, prev)
      pos = pos + 1
    }
  }
  // 块结束码 256
  let (ec, el) = fixed_lit_code(256)
  w.write_code(ec, el)
  w.finish()
}

///|
/// 无损压缩率（1.0 = 没压下去）。
pub fn compression_ratio(original : Int, compressed : Int) -> Double {
  if original <= 0 {
    1.0
  } else {
    compressed.to_double() / original.to_double()
  }
}
