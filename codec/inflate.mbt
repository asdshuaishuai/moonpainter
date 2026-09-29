/// codec —— DEFLATE 解压（codec/inflate）。
///
/// 来源：deepOffice/ooxml/inflate.mbt（自有 MIT，手写 RFC 1951 实现），
/// 移植时保持实现一致，仅调整文件头说明。
///
/// 手写而不是引库：.mpd 的物理容器是 ZIP，ZIP 的载荷就是 raw deflate——
/// 这是引擎**唯一**的压缩依赖；解码是纯字节变换、无平台差异，手写更可控
/// （不会因为某个包不支持 wasm-gc 而卡住）。
///
/// 实现策略：先求正确，再求快。Huffman 解码用经典的逐位规范解码
/// （zlib 的 puff.c 思路），而不是查表——查表能快 3–5 倍，但代码量和
/// 出错面大得多。真要提速，`decode_symbol` 是唯一的改动点。

///|
/// Huffman 表最大码长（deflate 规定）。
let max_bits : Int = 15

///|
/// 长度码的基准值（码 257–285）。
let len_base : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
/// 长度码的额外位数。
let len_extra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// 距离码的基准值（码 0–29）。
let dist_base : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
/// 距离码的额外位数。
let dist_extra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// 码长码的传输顺序（RFC 1951 §3.2.7）——注意不是 0..18 的自然顺序，
/// 这个顺序是规范定死的，写错了动态块就全解不开。
let cl_order : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
/// 位读取器：deflate 的位流是**字节内 LSB 优先**、**Huffman 码 MSB 优先**，
/// 这两个方向不一致是实现时最容易搞反的地方。这里 read_bit 逐位读，
/// Huffman 解码时用 `code = (code << 1) | bit` 累积，天然对齐规范。
pub(all) struct BitReader {
  data : Bytes
  mut pos : Int
  /// 当前字节的剩余位（已右移处理过的部分）。
  mut bit_buf : Int
  mut bit_count : Int
  /// 是否已遇到流结束（供调用方判断而不是抛异常）。
  mut eof : Bool
}

///|
pub fn BitReader::new(data : Bytes) -> BitReader {
  { data, pos: 0, bit_buf: 0, bit_count: 0, eof: false, }
}

///|
/// 读一位；流耗尽返回 0 并置 eof。
/// 返回 0 而不是报错：解压失败时上层拿到的是「不完整的字节串」，
/// 这比在中途抛异常更容易降级处理。
pub fn BitReader::read_bit(self : BitReader) -> Int {
  if self.bit_count == 0 {
    if self.pos >= self.data.length() {
      self.eof = true
      return 0
    }
    self.bit_buf = self.data[self.pos].to_int() & 0xFF
    self.pos = self.pos + 1
    self.bit_count = 8
  }
  let b = self.bit_buf & 1
  self.bit_buf = self.bit_buf >> 1
  self.bit_count = self.bit_count - 1
  b
}

///|
/// 读 n 位（LSB 优先），n ≤ 24。
pub fn BitReader::read_bits(self : BitReader, n : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < n {
    v = v | (self.read_bit() << i)
    i = i + 1
  }
  v
}

///|
/// 丢弃当前字节的剩余位（存储块需要字节对齐）。
pub fn BitReader::align_byte(self : BitReader) -> Unit {
  self.bit_buf = 0
  self.bit_count = 0
}

///|
/// 规范 Huffman 表。
pub(all) struct Huffman {
  /// counts[len] = 该码长的码字数。
  counts : Array[Int]
  /// 按 (码长, 符号值) 排序的符号表。
  symbols : Array[Int]
  max_len : Int
  /// 表是否合法（过订阅 / 空表）。非法表在解码时被跳过而不是崩溃。
  valid : Bool
}

///|
/// 从码长表构建规范 Huffman 表。
pub fn Huffman::build(lengths : Array[Int], n : Int) -> Huffman {
  let counts : Array[Int] = []
  let mut i = 0
  while i <= max_bits {
    counts.push(0)
    i = i + 1
  }
  let mut sym = 0
  while sym < n {
    let l = if sym < lengths.length() { lengths[sym] } else { 0 }
    if l > max_bits {
      return { counts, symbols: [], max_len: 0, valid: false, }
    }
    counts[l] = counts[l] + 1
    sym = sym + 1
  }
  counts[0] = 0
  // 检查是否过订阅：left 变成负数说明码长表给出的码数超过了该长度能容纳的
  let mut left = 1
  let mut len = 1
  while len <= max_bits {
    left = left << 1
    left = left - counts[len]
    if left < 0 {
      return { counts, symbols: [], max_len: 0, valid: false, }
    }
    len = len + 1
  }
  // 偏移表
  let offsets : Array[Int] = []
  let mut acc = 0
  let mut l2 = 0
  while l2 <= max_bits {
    offsets.push(acc)
    acc = acc + counts[l2]
    l2 = l2 + 1
  }
  let symbols : Array[Int] = []
  let mut k = 0
  while k < acc {
    symbols.push(0)
    k = k + 1
  }
  let cursor = offsets.copy()
  let mut s = 0
  while s < n {
    let sl = if s < lengths.length() { lengths[s] } else { 0 }
    if sl != 0 {
      symbols[cursor[sl]] = s
      cursor[sl] = cursor[sl] + 1
    }
    s = s + 1
  }
  let mut maxl = 0
  let mut ml = 1
  while ml <= max_bits {
    if counts[ml] > 0 {
      maxl = ml
    }
    ml = ml + 1
  }
  { counts, symbols, max_len: maxl, valid: maxl > 0, }
}

///|
/// 规范解码：逐位累积码字，用「码字 - 该长度首码 < 该长度码数」判断命中。
/// 返回 -1 表示表非法或流耗尽。
pub fn Huffman::decode_symbol(self : Huffman, br : BitReader) -> Int {
  if !self.valid {
    return -1
  }
  let mut code = 0
  let mut first = 0
  let mut index = 0
  let mut len = 1
  while len <= self.max_len {
    code = code | br.read_bit()
    if br.eof {
      return -1
    }
    let count = self.counts[len]
    if code - first < count {
      return self.symbols[index + (code - first)]
    }
    index = index + count
    first = (first + count) << 1
    code = code << 1
    len = len + 1
  }
  -1
}

///|
/// 从码长码构建：读 HCLEN+4 个 3 位码长，然后建表。
fn read_code_length_table(br : BitReader) -> (Array[Int], Int)? {
  let hlit = br.read_bits(5) + 257
  let hdist = br.read_bits(5) + 1
  let hclen = br.read_bits(4) + 4
  if br.eof {
    return None
  }
  let cl_lengths : Array[Int] = []
  let mut i = 0
  while i < 19 {
    cl_lengths.push(0)
    i = i + 1
  }
  let mut k = 0
  while k < hclen {
    cl_lengths[cl_order[k]] = br.read_bits(3)
    k = k + 1
  }
  let cl_table = Huffman::build(cl_lengths, 19)
  if !cl_table.valid {
    return None
  }
  // 用码长表解出 lit/len 与 dist 的码长
  let total = hlit + hdist
  let lengths : Array[Int] = []
  let mut produced = 0
  while produced < total {
    let sym = cl_table.decode_symbol(br)
    if sym < 0 {
      return None
    }
    if sym < 16 {
      lengths.push(sym)
      produced = produced + 1
    } else if sym == 16 {
      // 重复上一个码长 3–6 次
      if lengths.length() == 0 {
        return None
      }
      let prev = lengths[lengths.length() - 1]
      let rep = br.read_bits(2) + 3
      let mut r = 0
      while r < rep && produced < total {
        lengths.push(prev)
        produced = produced + 1
        r = r + 1
      }
    } else if sym == 17 {
      let rep = br.read_bits(3) + 3
      let mut r = 0
      while r < rep && produced < total {
        lengths.push(0)
        produced = produced + 1
        r = r + 1
      }
    } else {
      let rep = br.read_bits(7) + 11
      let mut r = 0
      while r < rep && produced < total {
        lengths.push(0)
        produced = produced + 1
        r = r + 1
      }
    }
  }
  Some((lengths, hlit))
}

///|
/// 固定 Huffman 表（BTYPE=1）：码长由规范写死，不需要传输。
fn fixed_literal_table() -> Huffman {
  let lengths : Array[Int] = []
  let mut i = 0
  while i < 288 {
    if i < 144 {
      lengths.push(8)
    } else if i < 256 {
      lengths.push(9)
    } else if i < 280 {
      lengths.push(7)
    } else {
      lengths.push(8)
    }
    i = i + 1
  }
  Huffman::build(lengths, 288)
}

///|
fn fixed_dist_table() -> Huffman {
  let lengths : Array[Int] = []
  let mut i = 0
  while i < 30 {
    lengths.push(5)
    i = i + 1
  }
  Huffman::build(lengths, 30)
}

///|
/// DEFLATE 解压结果：字节 + 是否完整。
/// 不抛异常：损坏的容器在打开场景里很常见（下载中断、写入中断），
/// 能解出多少算多少，由上层决定接受还是拒绝。
pub(all) struct InflateResult {
  data : Bytes
  /// 是否干净地走到了 BFINAL 块结束。
  complete : Bool
  /// 已解压的字节数。
  size : Int
}

///|
/// 解压一份 raw deflate 流（ZIP 里的载荷就是 raw deflate，无 zlib 头）。
pub fn inflate(input : Bytes) -> InflateResult {
  let br = BitReader::new(input)
  let out : Array[Byte] = []
  let mut complete = false
  let mut ticks = 0
  // guard 防止损坏数据把循环卡死（每个块至少消费 3 位，上限给足够大）
  while ticks < 100000000 {
    ticks = ticks + 1
    let bfinal = br.read_bit()
    if br.eof {
      break
    }
    let btype = br.read_bits(2)
    if br.eof {
      break
    }
    if btype == 0 {
      br.align_byte()
      let len = br.read_bits(16)
      let nlen = br.read_bits(16)
      if br.eof {
        break
      }
      // NLEN 应该是 LEN 的反码；不匹配说明流已损坏，但仍尽力读完
      let _ = nlen
      let mut i = 0
      while i < len {
        if br.pos >= br.data.length() {
          br.eof = true
          break
        }
        out.push(br.data[br.pos])
        br.pos = br.pos + 1
        i = i + 1
      }
    } else if btype == 1 || btype == 2 {
      // 两张表一次性求出来：MoonBit 不支持「先声明后赋值」的分步初始化，
      // 用元组 + match 表达反而更清楚——两张表总是同时确定。
      let tables : (Huffman, Huffman)? = if btype == 1 {
        Some((fixed_literal_table(), fixed_dist_table()))
      } else {
        match read_code_length_table(br) {
          None => None
          Some(pair) => {
            let (lengths, hlit) = pair
            let lit_lengths : Array[Int] = []
            let mut a = 0
            while a < hlit {
              lit_lengths.push(lengths[a])
              a = a + 1
            }
            let dist_lengths : Array[Int] = []
            let mut b = hlit
            while b < lengths.length() {
              dist_lengths.push(lengths[b])
              b = b + 1
            }
            Some(
              (
                Huffman::build(lit_lengths, hlit),
                Huffman::build(dist_lengths, dist_lengths.length()),
              ),
            )
          }
        }
      }
      let (lit, dst) = match tables {
        None => {
          br.eof = true
          (Huffman::build([], 0), Huffman::build([], 0))
        }
        Some(t) => t
      }
      if !lit.valid {
        break
      }
      let mut done = false
      while !done {
        let sym = lit.decode_symbol(br)
        if sym < 0 {
          done = true
          br.eof = true
        } else if sym < 256 {
          out.push(sym.to_byte())
        } else if sym == 256 {
          done = true
        } else {
          let li = sym - 257
          if li >= len_base.length() {
            done = true
            br.eof = true
          } else {
            let length = len_base[li] + br.read_bits(len_extra[li])
            let dsym = dst.decode_symbol(br)
            if dsym < 0 || dsym >= dist_base.length() {
              done = true
              br.eof = true
            } else {
              let distance = dist_base[dsym] + br.read_bits(dist_extra[dsym])
              if distance <= 0 || distance > out.length() {
                done = true
                br.eof = true
              } else {
                // 逐字节复制：不能用 slice 一次拷，因为 length 可能大于
                // distance（自重叠复制，这是 deflate 压缩重复串的核心机制）
                let mut c = 0
                while c < length {
                  let src = out.length() - distance
                  out.push(out[src])
                  c = c + 1
                }
              }
            }
          }
        }
      }
    } else {
      // BTYPE == 3 是保留值
      break
    }
    if bfinal == 1 {
      complete = true
      break
    }
    if br.eof {
      break
    }
  }
  let bytes = Bytes::from_array(out)
  { data: bytes, complete, size: bytes.length(), }
}

///|
/// 仅供测试/诊断：把 deflate 流解成字符串（UTF-8 宽松解码）。
pub fn inflate_to_string(input : Bytes) -> String {
  let r = inflate(input)
  decode_utf8_lossy(r.data)
}

///|
/// 宽松 UTF-8 解码：非法字节替换为 U+FFFD。
pub fn decode_utf8_lossy(b : Bytes) -> String {
  @utf8.decode_lossy(b, ignore_bom=true)
}

///|
/// 严格 UTF-8 解码，失败返回 None。
pub fn decode_utf8(b : Bytes) -> String? {
  Some(@utf8.decode(b, ignore_bom=true)) catch {
    _ => None
  }
}
