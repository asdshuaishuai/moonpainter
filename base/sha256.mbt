/// base —— SHA-256（base/sha256）。本仓库新写，FIPS 180-4。
///
/// 用途有二：.mpd 资产的内容寻址键（assets/sha256/<hash>）与
/// canonical design.json 的文档指纹。两者都要求跨实现稳定，
/// 所以这里只做标准实现 + NIST 向量测试，不做任何"聪明"优化。
///
/// Int 即 32 位补码：加法自然回绕；逻辑右移用 lsr 显式屏蔽符号位扩展。

///|
/// SHA-256 轮常数（FIPS 180-4 §4.2.2，立方根小数部分的前 64 位）。
let sha_k : Array[Int] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

///|
/// 初始哈希值（§5.3.3）。
let sha_h0 : Array[Int] = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
  0x1f83d9ab, 0x5be0cd19,
]

///|
/// 逻辑右移（MoonBit 的 >> 对 Int 是算术移位，需显式屏蔽符号位扩展）。
fn lsr(x : Int, n : Int) -> Int {
  if n <= 0 {
    x
  } else {
    (x >> n) & ((1 << (32 - n)) - 1)
  }
}

///|
/// 循环右移（n ∈ 1..31）。
fn rotr(x : Int, n : Int) -> Int {
  lsr(x, n) | (x << (32 - n))
}

///|
/// 小 sigma 0 / 1 与大 sigma 0 / 1（§4.1.2）。
fn ssig0(x : Int) -> Int {
  rotr(x, 7) ^ rotr(x, 18) ^ lsr(x, 3)
}

///|
fn ssig1(x : Int) -> Int {
  rotr(x, 17) ^ rotr(x, 19) ^ lsr(x, 10)
}

///|
fn bsig0(x : Int) -> Int {
  rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22)
}

///|
fn bsig1(x : Int) -> Int {
  rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25)
}

///|
/// 大端读 4 字节为一个 Int（块内字装载）。
fn be_word(b : Array[Byte], off : Int) -> Int {
  ((b[off].to_int() & 0xFF) << 24) |
  ((b[off + 1].to_int() & 0xFF) << 16) |
  ((b[off + 2].to_int() & 0xFF) << 8) |
  (b[off + 3].to_int() & 0xFF)
}

///|
/// SHA-256 摘要（32 字节）。
pub fn sha256(data : Bytes) -> Bytes {
  // 填充：0x80 + 零 + 8 字节大端比特长度（Int64 承载，实际文件远小于 2^32 位）
  let len = data.length()
  let bit_len : Int64 = len.to_int64() * 8L
  let total = ((len + 8) / 64 + 1) * 64
  let padded : Array[Byte] = []
  let mut i = 0
  while i < len {
    padded.push(data[i])
    i = i + 1
  }
  padded.push((0x80).to_byte())
  while padded.length() < total - 8 {
    padded.push((0).to_byte())
  }
  // 比特长度大端 8 字节（高位 4 字节在此场景恒 0）
  let mut sh : Int64 = bit_len
  let tail : Array[Int] = []
  let mut t = 0
  while t < 8 {
    tail.push((sh & 0xFFL).to_int())
    sh = sh >> 8
    t = t + 1
  }
  let mut k = 7
  while k >= 0 {
    padded.push(tail[k].to_byte())
    k = k - 1
  }

  let h = sha_h0.copy()
  let w : FixedArray[Int] = FixedArray::make(64, 0)
  let mut block = 0
  while block < total {
    let off = block
    let mut j = 0
    while j < 16 {
      w[j] = be_word(padded, off + j * 4)
      j = j + 1
    }
    j = 16
    while j < 64 {
      w[j] = ssig1(w[j - 2]) + w[j - 7] + ssig0(w[j - 15]) + w[j - 16]
      j = j + 1
    }
    let a = h[0]
    let b = h[1]
    let c = h[2]
    let d = h[3]
    let e = h[4]
    let f = h[5]
    let g = h[6]
    let hh = h[7]
    let mut va = a
    let mut vb = b
    let mut vc = c
    let mut vd = d
    let mut ve = e
    let mut vf = f
    let mut vg = g
    let mut vh = hh
    let mut t2 = 0
    while t2 < 64 {
      let t1 = vh + bsig1(ve) + ((ve & vf) ^ ((-1 - ve) & vg)) + sha_k[t2] + w[t2]
      let t2v = bsig0(va) + ((va & vb) ^ (va & vc) ^ (vb & vc))
      vh = vg
      vg = vf
      vf = ve
      ve = vd + t1
      vd = vc
      vc = vb
      vb = va
      va = t1 + t2v
      t2 = t2 + 1
    }
    h[0] = h[0] + va
    h[1] = h[1] + vb
    h[2] = h[2] + vc
    h[3] = h[3] + vd
    h[4] = h[4] + ve
    h[5] = h[5] + vf
    h[6] = h[6] + vg
    h[7] = h[7] + vh
    block = block + 64
  }

  let out : Array[Byte] = []
  let mut q = 0
  while q < 8 {
    push_be(out, h[q])
    q = q + 1
  }
  Bytes::from_array(out)
}

///|
fn push_be(arr : Array[Byte], v : Int) -> Unit {
  arr.push(((v >> 24) & 0xFF).to_byte())
  arr.push(((v >> 16) & 0xFF).to_byte())
  arr.push(((v >> 8) & 0xFF).to_byte())
  arr.push((v & 0xFF).to_byte())
}

///|
/// SHA-256 十六进制摘要（小写 64 字符）。资产键与文档指纹都用这个形态。
pub fn sha256_hex(data : Bytes) -> String {
  let digest = sha256(data)
  let sb = StringBuilder()
  let mut i = 0
  while i < digest.length() {
    let v = digest[i].to_int() & 0xFF
    sb.write_string(hex_byte((v >> 4) & 0xF))
    sb.write_string(hex_byte(v & 0xF))
    i = i + 1
  }
  sb.to_string()
}

///|
fn hex_byte(v : Int) -> String {
  let digits = "0123456789abcdef"
  match digits.get_char(v) {
    Some(c) => c.to_string()
    None => "0"
  }
}
