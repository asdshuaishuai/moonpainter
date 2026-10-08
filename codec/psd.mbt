/// codec —— PSD（Photoshop 文档）**读取**（③ PSD 兼容 · 读）。
///
/// 只做"读进来"这一半：把 PSD 字节解析成 `PsdImage`（尺寸 + 每层的名字/矩形/
/// 不透明度/可见性/混合模式/像素 + 合成图），**不碰文档模型**——建层、注册像素
/// 资产是 agent 层的事（依赖方向：codec 在最底下）。
///
/// 支持子集（**超出即明确报错，绝不降级**；边界声明见 README/DESIGN）：
/// - 位深 8；色彩模式 RGB(3) 与 Grayscale(1)。16/32 位、CMYK、Indexed、
///   多通道、Lab、Bitmap 一律**拒绝**并回显收到的是哪个。
/// - 压缩：0（RAW）/ 1（RLE / PackBits）。ZIP(2)/ZIP+预测(3) **拒绝**
///   （本仓库有 inflate，但"没被语料咬过的路径"不许默默接）。
/// - 图层类型：像素层。调整层/文本层/填充层/智能对象/**图层组**一律**拒绝**
///   （回显是哪种），因为本仓库的文档模型表达不了它们的语义。
/// - 图层**像素蒙版**（通道 -2/-3 或蒙版块非空）**拒绝**：静默丢掉蒙版比报错坏
///   得多（读进来的人会以为蒙版还在）。
/// - 图层效果（`lfx2`）、剪贴（clipping≠0）**拒绝**。
/// - 混合模式：norm/mul /scrn/over/dark/lite/diff 映射到本仓库 7 种；其余拒绝。
/// - `Layr` 之外的 `Lr16`/`Lr32` 段（16/32 位图层数据）拒绝。
///
/// 判据（`codec/psd_test.mbt`）：语料（`tools/make_psd_corpus.py` 用 psd-tools
/// 写出、Pillow + psd-tools 双读算期望）逐例比对合成图 sha 与层表；边界样本
/// 断言"回的错误里必须出现那句话"。所有读取都走 `Option` 辅助函数，
/// 坏字节只回错不 panic（`verify.sh#panic-hunt` 会喂敌意载荷）。
///
/// ⚠️ 这一层**不**做：跨通道色彩还原、图层效果的视觉重建、智能对象的矢量还原、
/// 蒙版的任何近似（拒绝）。丐版边界就写在上面这段——别在别处再抄一份。

///|
/// 一个 PSD 图层（自底向上；字段与 PSD 里的记录一一对应，不做解释）。
pub(all) struct PsdLayer {
  /// Unicode 层名（`luni`），没有就退回 Pascal 名。
  name : String
  /// 图层矩形（画布坐标）。
  x : Int
  y : Int
  w : Int
  h : Int
  /// 0..255（PSD 的 opacity 就是 8 位）。
  opacity : Int
  /// 图层可见（PSD flags 的 bit 1 取反）。
  visible : Bool
  /// 混合模式（本仓库的名字：normal/multiply/screen/overlay/darken/lighten/difference）。
  blend : String
  /// 该层自己的像素（w*h*4，RGBA，预乘**无**；缺失通道给默认值）。
  rgba : Array[Byte]
}

///|
/// 解码结果：画布 + 图层（自底向上）+ 合成图（PSD 自带的合成，与图层是两回事）。
pub(all) struct PsdImage {
  width : Int
  height : Int
  /// 头部声明的通道数（1=灰、3=RGB、4=RGBA）。
  channels : Int
  /// 色彩模式编号（3=RGB、1=Grayscale；其余在解码时已被拒）。
  mode : Int
  layers : Array[PsdLayer]
  /// 合成图（width*height*4 RGBA）——PSD 里"打开就看到的那张图"。
  composite : Array[Byte]
}

// ---------------------------------------------------------------------------
// 读取辅助：**每个都带边界检查**（坏字节回 None，绝不越界 panic）
// ---------------------------------------------------------------------------

///|
fn psd_u8(d : Bytes, off : Int) -> Int? {
  if off < 0 || off >= d.length() {
    return None
  }
  Some(d[off].to_int() & 0xFF)
}

///|
fn psd_be16(d : Bytes, off : Int) -> Int? {
  if off < 0 || off + 2 > d.length() {
    return None
  }
  Some(((d[off].to_int() & 0xFF) << 8) | (d[off + 1].to_int() & 0xFF))
}

///|
/// 大端 u32（8 位量级的安全读法；超过 2^31 的长度字段在本仓库的规模下非法，
/// 我们会因为 `off + len > length` 拒绝）。
fn psd_be32(d : Bytes, off : Int) -> Int? {
  if off < 0 || off + 4 > d.length() {
    return None
  }
  Some(
    ((d[off].to_int() & 0xFF) << 24) |
    ((d[off + 1].to_int() & 0xFF) << 16) |
    ((d[off + 2].to_int() & 0xFF) << 8) |
    (d[off + 3].to_int() & 0xFF),
  )
}

///|
/// 大端 i32（矩形坐标可能为负——PSD 允许图层伸出画布）。
fn psd_i32(d : Bytes, off : Int) -> Int? {
  // MoonBit 的 Int 是 32 位：`(b0 << 24)` 自然落在符号位，所以**同一个读法**
  // 既当 u32 又当 i32（长 2097152 之类的大长度字段会变成负数 ⇒ 被边界检查拒掉）。
  psd_be32(d, off)
}

///|
fn psd_tag(d : Bytes, off : Int) -> String? {
  if off < 0 || off + 4 > d.length() {
    return None
  }
  Some(
    String::from_array(
      [
        (d[off].to_int() & 0xFF).unsafe_to_char(),
        (d[off + 1].to_int() & 0xFF).unsafe_to_char(),
        (d[off + 2].to_int() & 0xFF).unsafe_to_char(),
        (d[off + 3].to_int() & 0xFF).unsafe_to_char(),
      ],
    ),
  )
}

// ---------------------------------------------------------------------------
// PackBits（RLE）
// ---------------------------------------------------------------------------

///|
/// PackBits 解压**一行**，最多要 `want` 个字节（PSD 的 RLE 是逐行的）。
/// 返回（字节, 消耗的输入长度）。流提前结束就按拿到的算——多余/缺失由调用方
/// 按 `want` 对齐（缺的补 0，多的丢掉），不 panic。
fn psd_unpackbits(d : Bytes, off : Int, want : Int) -> (Array[Byte], Int) {
  let out : Array[Byte] = []
  let mut i = off
  while out.length() < want && i < d.length() {
    // ⚠️ **真 bug（第一版）**：PackBits 的控制字节是有符号的（-127..-1 = 重复段），
    // 而 `d[i].to_int()` 给 0..255 ⇒ `n >= 0` **恒真** ⇒ 重复段全被当字面量读，
    // 解出来的像素整片错位（语料里两例 RLE 合成图当场抓住："sha 不同"）。
    let nb = d[i].to_int() & 0xFF
    let n = if nb >= 128 { nb - 256 } else { nb }
    i = i + 1
    if n >= 0 {
      // literal：n+1 个字节
      let mut k = 0
      while k <= n && out.length() < want && i < d.length() {
        out.push(d[i])
        i = i + 1
        k = k + 1
      }
    } else if n != -128 {
      // repeat：1-n 次同一个字节
      if i >= d.length() {
        break
      }
      let b = d[i]
      i = i + 1
      let mut k = 0
      while k < 1 - n && out.length() < want {
        out.push(b)
        k = k + 1
      }
    }
    // n == -128：no-op（规范里是空操作）
  }
  while out.length() < want {
    out.push(b'\x00')
  }
  (out, i - off)
}

///|
/// 读一个通道的像素（`w*h` 字节）：压缩 0 = RAW，1 = RLE，其余报错。
fn psd_channel(
  d : Bytes,
  off : Int,
  w : Int,
  h : Int,
  ctx : String,
) -> Result[(Array[Byte], Int), String] {
  let comp = match psd_be16(d, off) {
    None => return Err("\{ctx}：读不到压缩方式（文件被截断）")
    Some(c) => c
  }
  let n = w * h
  match comp {
    0 => {
      let pos = off + 2
      if pos + n > d.length() {
        return Err("\{ctx}：RAW 通道数据不足（要 \{n} 字节，只剩 \{d.length() - pos}）")
      }
      let out : Array[Byte] = []
      let mut i = 0
      while i < n {
        out.push(d[pos + i])
        i = i + 1
      }
      Ok((out, pos + n))
    }
    1 => {
      let mut pos = off + 2
      // 每行的字节数（u16/行），然后逐行 PackBits
      if pos + 2 * h > d.length() {
        return Err("\{ctx}：RLE 行长度表不足")
      }
      let counts : Array[Int] = []
      let mut i = 0
      while i < h {
        match psd_be16(d, pos + 2 * i) {
          None => return Err("\{ctx}：RLE 行长度表被截断")
          Some(c) => counts.push(c)
        }
        i = i + 1
      }
      pos = pos + 2 * h
      let out : Array[Byte] = []
      let mut row = 0
      while row < h {
        let (bytes, used) = psd_unpackbits(d, pos, w)
        for b in bytes {
          out.push(b)
        }
        // ⚠️ 用**文件里声明的**行长度推进（而不是实际消耗）：声明与内容不符时
        // 也要按声明走，否则后面的行会读到别的行的流里 —— 那是"静默错像素"。
        pos = pos - used + counts[row]
        row = row + 1
      }
      Ok((out, pos))
    }
    _ =>
      Err(
        "\{ctx}：压缩方式 \{comp} 不支持（本仓库只认 0=RAW / 1=RLE；Photoshop 存成 ZIP 的话请另存为 RLE）",
      )
  }
}

// ---------------------------------------------------------------------------
// 混合模式
// ---------------------------------------------------------------------------

///|
/// PSD 的 4 字节混合模式签名 → 本仓库的名字。`None` = 不认识（调用方拒绝）。
fn psd_blend_name(tag : String) -> String? {
  match tag {
    "norm" => Some("normal")
    "mul " => Some("multiply")
    "scrn" => Some("screen")
    "over" => Some("overlay")
    "dark" => Some("darken")
    "lite" => Some("lighten")
    "diff" => Some("difference")
    _ => None
  }
}

// ---------------------------------------------------------------------------
// 图层记录
// ---------------------------------------------------------------------------

///|
/// 一条 layer record 解析出来的东西（像素在通道数据段里，这里只有元数据）。
priv struct PsdRec {
  name : String
  x : Int
  y : Int
  w : Int
  h : Int
  opacity : Int
  visible : Bool
  blend : String
  channels : Array[(Int, Int)] // (通道 id, 数据长度)
  /// 有蒙版块（长度 > 0）——它**不是**拒绝的理由：见通道走查里的判据。
  mask_declared : Bool
}

///|
/// 解析 `extra` 段里的附加信息（`8BIM` + 4 字节 key + u32 长度 + 数据，2 字节对齐）。
/// 返回（Unicode 名, 是否组, 拒绝原因）。**只认我们支持的**：`luni` 取名，
/// `lsct`=组、`lfx2`=图层效果、`TEXT`=文本层、`vmsk`/`vsms`=矢量蒙版一律拒绝。
fn psd_extra_info(
  d : Bytes,
  off : Int,
  len : Int,
) -> Result[(String?, Array[String]), String] {
  let mut p = off
  let end = off + len
  let mut uni : String? = None
  let refusals : Array[String] = []
  while p + 12 <= end && p + 12 <= d.length() {
    let sig = match psd_tag(d, p) {
      None => break
      Some(s) => s
    }
    let key = match psd_tag(d, p + 4) {
      None => break
      Some(s) => s
    }
    let blen = match psd_be32(d, p + 8) {
      None => break
      Some(v) => v
    }
    if sig != "8BIM" && sig != "8B64" {
      // 不是附加信息块：按规范这里应该结束了；继续会读到垃圾
      break
    }
    let body = p + 12
    if body + blen > d.length() {
      return Err("图层附加信息块 \{key} 越界（声明 \{blen} 字节）")
    }
    match key {
      "luni" => {
        match psd_be32(d, body) {
          None => ()
          Some(n) => {
            if body + 4 + n <= d.length() && n > 0 {
              let sb = StringBuilder()
              let mut i = 0
              // ⚠️ **真 bug（写侧第一次往返才暴露）**：`luni` 里那个 u32 是
              // **字符数**（psd-tools 的 `read_unicode_string` 读 `num_chars * 2`
              // 字节），第一版当成字节数 ⇒ 名字被截成一半（"bottom red" 读成
              // "botto"）。第三方语料照不出这个 bug：psd-tools 只在名字不是
              // MacRoman 能表示的时候才写 `luni`，纯 ASCII 的层名走 Pascal 名。
              while i + 1 < n * 2 {
                match psd_be16(d, body + 4 + i) {
                  None => break
                  Some(cp) => {
                    if cp != 0 {
                      sb.write_char(cp.unsafe_to_char())
                    }
                  }
                }
                i = i + 2
              }
              uni = Some(sb.to_string())
            }
          }
        }
      }
      "lsct" => refusals.push("图层组（section divider）")
      "lfx2" => refusals.push("图层效果（图层样式）")
      "TEXT" => refusals.push("文本层")
      "vmsk" | "vsms" => refusals.push("矢量蒙版")
      "SoCo" | "GdFl" | "PtFl" | "brit" | "levl" | "curv" | "mixr" => {
        let name = psd_fill_kind_name(key)
        refusals.push("填充/调整层（\{name}）")
      }
      _ => ()
    }
    p = body + blen
    if blen % 2 == 1 {
      p = p + 1
    }
  }
  Ok((uni, refusals))
}

///|
fn psd_fill_kind_name(key : String) -> String {
  match key {
    "SoCo" => "纯色"
    "GdFl" => "渐变"
    "PtFl" => "图案"
    "brit" => "亮度/对比度"
    "levl" => "色阶"
    "curv" => "曲线"
    "mixr" => "通道混合器"
    _ => key
  }
}

///|
fn psd_layer_record(d : Bytes, off : Int) -> Result[(PsdRec, Int), String] {
  let top = match psd_i32(d, off) {
    None => return Err("图层记录被截断（矩形）")
    Some(v) => v
  }
  let left = match psd_i32(d, off + 4) {
    None => return Err("图层记录被截断（矩形）")
    Some(v) => v
  }
  let bottom = match psd_i32(d, off + 8) {
    None => return Err("图层记录被截断（矩形）")
    Some(v) => v
  }
  let right = match psd_i32(d, off + 12) {
    None => return Err("图层记录被截断（矩形）")
    Some(v) => v
  }
  let nch = match psd_be16(d, off + 16) {
    None => return Err("图层记录被截断（通道数）")
    Some(v) => v
  }
  let mut p = off + 18
  let channels : Array[(Int, Int)] = []
  let mut ci = 0
  while ci < nch {
    let cid = match psd_be16(d, p) {
      None => return Err("图层记录被截断（通道 id）")
      Some(v) => if v >= 0x8000 { v - 0x10000 } else { v }
    }
    let clen = match psd_be32(d, p + 2) {
      None => return Err("图层记录被截断（通道长度）")
      Some(v) => v
    }
    channels.push((cid, clen))
    p = p + 6
    ci = ci + 1
  }
  // 混合模式是 **8 字节**：签名 `8BIM`（4）+ key（4）。⚠️ 第一版只读 4 字节，
  // 把签名当成了 key（语料报"混合模式 8BIM 不支持"）；第二版又以为整块是 4 字节，
  // 把后面所有字段的偏移算歪（报的还是同一句话——现象不指向真因）。
  let blend_sig = match psd_tag(d, p) {
    None => return Err("图层记录被截断（混合模式签名）")
    Some(s) => s
  }
  if blend_sig != "8BIM" && blend_sig != "8B64" {
    return Err(
      "图层记录的混合模式签名不是 8BIM（读到 \{psd_tag_text(blend_sig)}）—— 文件可能损坏",
    )
  }
  let blend_tag = match psd_tag(d, p + 4) {
    None => return Err("图层记录被截断（混合模式）")
    Some(s) => s
  }
  let blend = match psd_blend_name(blend_tag) {
    None => {
      return Err(
        "混合模式 \{psd_tag_text(blend_tag)} 不支持（本仓库只认 normal/multiply/screen/overlay/darken/lighten/difference）",
      )
    }
    Some(n) => n
  }
  // 布局（规范 6 字节/通道之后）：混合模式 4、不透明度 1、剪贴 1、flags 1、
  // filler 1、附加信息长度 4。**第一版全写大了 4**（照"混合模式也是 8 字节"的
  // 错觉写），于是第二条图层记录从垃圾里读起 —— 语料报的是"混合模式 8BIM 不支持"，
  // 现象指向别处（指向混合模式表），真因在偏移。
  let opacity = match psd_u8(d, p + 8) {
    None => return Err("图层记录被截断（不透明度）")
    Some(v) => v
  }
  let clipping = match psd_u8(d, p + 9) {
    None => return Err("图层记录被截断（剪贴）")
    Some(v) => v
  }
  if clipping != 0 {
    return Err("图层剪贴蒙版（clipping=\{clipping}）不支持：本仓库没有剪贴语义")
  }
  let flags = match psd_u8(d, p + 10) {
    None => return Err("图层记录被截断（flags）")
    Some(v) => v
  }
  let extra_len = match psd_be32(d, p + 12) {
    None => return Err("图层记录被截断（附加信息长度）")
    Some(v) => v
  }
  // 附加信息里：蒙版块（u32 长度 + 数据）、混合范围（u32 长度 + 数据）、
  // Pascal 名（4 字节对齐）、然后才是 8BIM 块。
  let extra = p + 16
  let mask_len = match psd_be32(d, extra) {
    None => return Err("图层附加信息被截断（蒙版长度）")
    Some(v) => v
  }
  // ⚠️ 蒙版块**存在**不等于"有蒙版"：psd-tools（以及 Photoshop）给每个像素层都写
  // 一个全白的占位蒙版（-2 通道全是 255）。判据必须是"它到底遮没遮住东西" ——
  // 见通道走查：真遮了才拒。第一版一见到蒙版块就拒，连第三方写出的普通分层文件
  // 都读不进来（语料当场红，现象指向"蒙版不支持"）。
  let mask_declared = mask_len > 0
  // ⚠️ **真 bug（第一版）**：蒙版块的**数据**（`mask_len` 字节）必须跳过 ——
  // 第一版从 `extra + 4` 就往下读"混合范围长度"，读到的其实是蒙版矩形里的字节
  // （长度 1/2/0），于是图层名字全空（语料报"层 0 名字： ≠ bottom red"）。
  // 现象（名字空）跟真因（少跳一段）隔了三层。
  let mut q = extra + 4 + mask_len
  let br_len = match psd_be32(d, q) {
    None => return Err("图层附加信息被截断（混合范围长度）")
    Some(v) => v
  }
  q = q + 4 + br_len
  let nlen = match psd_u8(d, q) {
    None => return Err("图层附加信息被截断（图层名）")
    Some(v) => v
  }
  let mut pascal = ""
  if q + 1 + nlen <= d.length() {
    let sb = StringBuilder()
    let mut i = 0
    while i < nlen {
      match psd_u8(d, q + 1 + i) {
        None => break
        Some(c) => sb.write_char(c.unsafe_to_char())
      }
      i = i + 1
    }
    pascal = sb.to_string()
  }
  // Pascal 名按 4 字节对齐 —— ⚠️ **真 bug（写侧第一次往返才暴露）**：对齐的参照物是
  // **Pascal 名这个字段自己**（1 字节长度 + n 字节名字），不是文件里的绝对偏移
  // （psd-tools 的 `write_pascal_string` 就是 `write_padding(fp, 1 + len(data), 4)`）。
  // 第一版按 `extra_off % 4` 算：某些层记录恰好让 extra 起点不等于 4 的倍数时，
  // 对齐量会多出 1..3 字节 ⇒ 后面的附加信息块（`luni` 名字、`lsct`/`lfx2` 这些
  // 该拒的标记）**全被跳过**，现象是"名字只有 Pascal 那半截、组/效果层当成普通层收下"。
  // 语料照不出来：psd-tools 写的层名之后如果没有附加信息块，多跳这几个字节
  // 谁都不会发现（没人再往下解析）。
  let mut extra_off = q + 1 + nlen
  let pad = (4 - ((1 + nlen) % 4)) % 4
  extra_off = extra_off + pad
  let info_len = if extra + extra_len > extra_off {
    extra + extra_len - extra_off
  } else {
    0
  }
  let (uni, refusals) = match psd_extra_info(d, extra_off, info_len) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if refusals.length() > 0 {
    return Err("图层 \{pascal}：\{refusals[0]} 不支持（本仓库的文档模型表达不了它）")
  }
  let name = match uni {
    Some(u) => if u.length() > 0 { u } else { pascal }
    None => pascal
  }
  let w = right - left
  let h = bottom - top
  Ok((
    {
      name,
      x: left,
      y: top,
      w: if w > 0 { w } else { 0 },
      h: if h > 0 { h } else { 0 },
      opacity,
      visible: (flags & 2) == 0,
      blend,
      channels,
      mask_declared,
    },
    p + 16 + extra_len,
  ))
}

///|
fn psd_tag_text(tag : String) -> String {
  let sb = StringBuilder()
  for c in tag {
    sb.write_char(c)
  }
  sb.to_string()
}

// ---------------------------------------------------------------------------
// 通道数据 → RGBA
// ---------------------------------------------------------------------------

///|
/// 把一层的通道字典拼成 RGBA（缺失通道用默认值：颜色 0、alpha 255）。
fn psd_layer_rgba(
  rec : PsdRec,
  planes : Map[Int, Array[Byte]],
) -> Array[Byte] {
  let n = rec.w * rec.h
  let out : Array[Byte] = []
  let mut i = 0
  while i < n {
    let get = fn(cid : Int, dflt : Int) -> Int {
      match planes.get(cid) {
        Some(p) => {
          if i < p.length() {
            p[i].to_int() & 0xFF
          } else {
            dflt
          }
        }
        None => dflt
      }
    }
    out.push(get(0, 0).to_byte())
    out.push(get(1, get(0, 0)).to_byte())
    out.push(get(2, get(0, 0)).to_byte())
    out.push(get(-1, 255).to_byte())
    i = i + 1
  }
  out
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

///|
/// PSD 解码。失败回**精确原因**（含是哪个图层/哪个字段），不 panic。
pub fn psd_decode(data : Bytes) -> Result[PsdImage, String] {
  if data.length() < 26 {
    return Err("PSD 太短（\{data.length()} 字节，头部就要 26）")
  }
  let sig = match psd_tag(data, 0) {
    None => return Err("PSD 头部被截断")
    Some(s) => s
  }
  if sig != "8BPS" {
    return Err("不是 PSD（签名 \{psd_tag_text(sig)}，要 8BPS）")
  }
  let version = match psd_be16(data, 4) {
    None => return Err("PSD 头部被截断（版本）")
    Some(v) => v
  }
  if version != 1 {
    return Err("PSD 版本 \{version} 不支持（PSB 大文档格式要 1）")
  }
  let channels = match psd_be16(data, 12) {
    None => return Err("PSD 头部被截断（通道数）")
    Some(v) => v
  }
  let height = match psd_be32(data, 14) {
    None => return Err("PSD 头部被截断（高）")
    Some(v) => v
  }
  let width = match psd_be32(data, 18) {
    None => return Err("PSD 头部被截断（宽）")
    Some(v) => v
  }
  let depth = match psd_be16(data, 22) {
    None => return Err("PSD 头部被截断（位深）")
    Some(v) => v
  }
  let mode = match psd_be16(data, 24) {
    None => return Err("PSD 头部被截断（色彩模式）")
    Some(v) => v
  }
  if depth != 8 {
    return Err("位深 \{depth} 不支持（只认 8：16/32 位要另存为 8 位）")
  }
  if mode != 3 && mode != 1 {
    return Err(
      "色彩模式 \{psd_mode_name(mode)} 不支持（只认 RGB 与 Grayscale：CMYK/Lab/Indexed 请另存为 RGB）",
    )
  }
  if width <= 0 || height <= 0 {
    return Err("画布尺寸非法（\{width}×\{height}）")
  }
  if channels != 1 && channels != 3 && channels != 4 {
    return Err("通道数 \{channels} 不支持（RGB 要 3/4 通道、灰度要 1）")
  }
  let mut off = 26
  // 色彩模式数据
  let cmd_len = match psd_be32(data, off) {
    None => return Err("色彩模式数据段被截断")
    Some(v) => v
  }
  off = off + 4 + cmd_len
  // 图像资源
  let res_len = match psd_be32(data, off) {
    None => return Err("图像资源段被截断")
    Some(v) => v
  }
  off = off + 4 + res_len
  if off > data.length() {
    return Err("图像资源段越界")
  }
  // 图层与蒙版信息
  let layers : Array[PsdLayer] = []
  let lm_len = match psd_be32(data, off) {
    None => return Err("图层与蒙版信息段被截断")
    Some(v) => v
  }
  off = off + 4
  if lm_len > 0 {
    if off + lm_len > data.length() {
      return Err("图层与蒙版信息段越界（声明 \{lm_len} 字节）")
    }
    let (ls, after) = match psd_layer_section(data, off, lm_len) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    for l in ls {
      layers.push(l)
    }
    off = after
  }
  // 合成图（PSD 自带的"打开就看到的那张"）
  let composite = match psd_composite(data, off, width, height, channels, mode) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  Ok({ width, height, channels, mode, layers, composite })
}

///|
fn psd_mode_name(mode : Int) -> String {
  match mode {
    0 => "Bitmap"
    1 => "Grayscale"
    2 => "Indexed"
    3 => "RGB"
    4 => "CMYK"
    7 => "Multichannel"
    8 => "Duotone"
    9 => "Lab"
    _ => "\{mode}"
  }
}

///|
/// 图层段（`Layer info`）解析：层记录 → 通道数据 → 全局蒙版信息。
/// 返回（自底向上的层, 段之后的偏移）。
fn psd_layer_section(
  data : Bytes,
  off : Int,
  lm_len : Int,
) -> Result[(Array[PsdLayer], Int), String] {
  let info_len = match psd_be32(data, off) {
    None => return Err("图层信息段被截断")
    Some(v) => v
  }
  let mut p = off + 4
  let info_end = off + 4 + info_len
  if info_end > data.length() {
    return Err("图层信息段越界（声明 \{info_len} 字节）")
  }
  let count_raw = match psd_be16(data, p) {
    None => return Err("图层数被截断")
    Some(v) => if v >= 0x8000 { v - 0x10000 } else { v }
  }
  p = p + 2
  let nlayers = if count_raw < 0 { -count_raw } else { count_raw }
  if nlayers > 10000 {
    return Err("图层数 \{nlayers} 离谱（疑似损坏文件）")
  }
  let recs : Array[PsdRec] = []
  let mut i = 0
  while i < nlayers {
    let (rec, next) = match psd_layer_record(data, p) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    recs.push(rec)
    p = next
    i = i + 1
  }
  // 通道数据（顺序与每条记录里的 channels 表一致），紧跟在所有层记录之后
  let planes : Array[Map[Int, Array[Byte]]] = []
  let mut li = 0
  while li < recs.length() {
    let rec = recs[li]
    let m : Map[Int, Array[Byte]] = Map([])
    let mut mask_channel_seen = false
    for ch in rec.channels {
      let (cid, clen) = ch
      // 蒙版通道（-2 = 用户蒙版 / -3 = 真实蒙版）：**解码它，看它到底遮没遮住**。
      // 全 255 = 全可见 ⇒ 占位，丢掉不丢信息（照读）；有任何一个像素 < 255 ⇒
      // 真蒙版，本仓库表达不了 ⇒ **拒绝**（静默丢蒙版比读不进来坏得多）。
      if cid == -2 || cid == -3 {
        mask_channel_seen = true
        let ctx = "图层 \{rec.name} 的蒙版通道"
        let (bytes, next) = match psd_channel(data, p, rec.w, rec.h, ctx) {
          Err(e) => return Err(e)
          Ok(v) => v
        }
        let mut hidden = 0
        for b in bytes {
          if (b.to_int() & 0xFF) != 255 {
            hidden = hidden + 1
          }
        }
        if hidden > 0 {
          return Err(
            "图层 \{rec.name}：像素蒙版有 \{hidden} 个像素在遮挡 —— 本仓库表达不了像素蒙版，不静默丢（请先在 Photoshop 里删掉这个蒙版）",
          )
        }
        p = if clen > 0 { p + clen } else { next }
        continue
      }
      let ctx = "图层 \{rec.name} 的通道 \{cid}"
      let (bytes, next) = match psd_channel(data, p, rec.w, rec.h, ctx) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      m.set(cid, bytes)
      // 用**记录里声明的**长度推进（它包含压缩头与行长度表）——解码器的消耗量
      // 只作兜底：两者不一致时以声明为准，免得一条通道读歪把后面全读歪。
      p = if clen > 0 { p + clen } else { next }
    }
    if rec.mask_declared && !mask_channel_seen {
      return Err(
        "图层 \{rec.name}：蒙版块没有对应的像素通道（文件疑似损坏）—— 不敢当成没有蒙版读",
      )
    }
    planes.push(m)
    li = li + 1
  }
  let out : Array[PsdLayer] = []
  let mut k = 0
  while k < recs.length() {
    let rec = recs[k]
    out.push({
      name: rec.name,
      x: rec.x,
      y: rec.y,
      w: rec.w,
      h: rec.h,
      opacity: rec.opacity,
      visible: rec.visible,
      blend: rec.blend,
      rgba: psd_layer_rgba(rec, planes[k]),
    })
    k = k + 1
  }
  // 全局蒙版信息（u32 长度 + 数据）：非零就说明有全局蒙版 —— 也是表达不了的
  let gm_len = match psd_be32(data, info_end) {
    None => {
      // 段尾之后没有全局蒙版信息（有些文件到此为止）
      0
    }
    Some(v) => v
  }
  if gm_len > 0 {
    return Err("全局像素蒙版不支持（本仓库没有全图像素蒙版语义）")
  }
  let after = if info_end + 4 <= off + lm_len { info_end + 4 } else { info_end }
  Ok((out, after))
}

///|
/// 合成图：压缩 0 = 逐通道 RAW，1 = 逐通道 RLE（先各行长度、再各行的流）。
fn psd_composite(
  data : Bytes,
  off : Int,
  width : Int,
  height : Int,
  channels : Int,
  mode : Int,
) -> Result[Array[Byte], String] {
  let comp = match psd_be16(data, off) {
    None => return Err("合成图被截断（压缩方式）")
    Some(v) => v
  }
  let mut p = off + 2
  let n = width * height
  let planes : Array[Array[Byte]] = []
  if comp == 0 {
    let mut c = 0
    while c < channels {
      if p + n > data.length() {
        return Err("合成图 RAW 数据不足（通道 \{c}）")
      }
      let out : Array[Byte] = []
      let mut i = 0
      while i < n {
        out.push(data[p + i])
        i = i + 1
      }
      planes.push(out)
      p = p + n
      c = c + 1
    }
  } else if comp == 1 {
    // ⚠️ **真 bug（第一版）**：合成图的行长度表是 **rows × channels 一整张**
    // （规范：所有扫描线的字节数先排完，再排各通道的压缩数据），而**图层通道**
    // 是"每个通道自己一张表"。第一版照图层那套写，于是解析到第二个通道就读到了
    // 像素数据当长度表 —— 语料里 `flat_rgb_rle_comp` 当场抓住（"行长度表不足"）。
    let total_rows = height * channels
    if p + 2 * total_rows > data.length() {
      return Err("合成图 RLE 行长度表不足（要 \{total_rows} 行长度）")
    }
    let counts : Array[Int] = []
    let mut i = 0
    while i < total_rows {
      match psd_be16(data, p + 2 * i) {
        None => return Err("合成图 RLE 行长度表被截断")
        Some(v) => counts.push(v)
      }
      i = i + 1
    }
    p = p + 2 * total_rows
    let mut c = 0
    while c < channels {
      let out : Array[Byte] = []
      let mut row = 0
      while row < height {
        let (bytes, _used) = psd_unpackbits(data, p, width)
        for b in bytes {
          out.push(b)
        }
        // 按**声明的**行长度推进（与 psd_channel 同一口径）
        p = p + counts[c * height + row]
        row = row + 1
      }
      planes.push(out)
      c = c + 1
    }
  } else {
    return Err("合成图压缩方式 \{comp} 不支持（只认 0=RAW / 1=RLE）")
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < n {
    let get = fn(cid : Int, dflt : Int) -> Int {
      if cid >= planes.length() {
        dflt
      } else {
        let pl = planes[cid]
        if i < pl.length() {
          pl[i].to_int() & 0xFF
        } else {
          dflt
        }
      }
    }
    if mode == 1 || channels == 1 {
      let g = get(0, 0)
      out.push(g.to_byte())
      out.push(g.to_byte())
      out.push(g.to_byte())
    } else {
      out.push(get(0, 0).to_byte())
      out.push(get(1, 0).to_byte())
      out.push(get(2, 0).to_byte())
    }
    out.push(if channels == 4 { get(3, 255).to_byte() } else { b'\xFF' })
    i = i + 1
  }
  Ok(out)
}

///|
/// 只报结构、不建任何东西（`psd-info` 用；也给"读进来会丢什么"一个出口）。
pub fn psd_info(data : Bytes) -> Result[String, String] {
  match psd_decode(data) {
    Err(e) => Err(e)
    Ok(img) => {
      let sb = StringBuilder()
      sb.write_string(
        "PSD \{img.width}×\{img.height} 通道=\{img.channels} 模式=\{psd_mode_name(img.mode)} 图层=\{img.layers.length()}",
      )
      for l in img.layers {
        sb.write_string(
          "\n  \{l.name} [\{l.x},\{l.y} \{l.w}×\{l.h}] opacity=\{l.opacity} visible=\{l.visible} blend=\{l.blend}",
        )
      }
      Ok(sb.to_string())
    }
  }
}
