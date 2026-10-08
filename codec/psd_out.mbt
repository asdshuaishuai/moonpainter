/// codec —— PSD **写出**（③ PSD 兼容 · 写的方向：把像素与层表变成 `.psd` 字节）。
///
/// 与 `codec/psd.mbt`（读）**成对**：那边把字节解成 `PsdImage`，这边把
/// `PsdOutLayer` 数组编成字节。两边都只认字节与像素，**不认识文档模型**——
/// "文档 → 每层像素"的活是 agent 侧（`agent/psd_out.mbt`）干的。
///
/// 写出来的东西（规范 6.0 的子集，够第三方读回来）：
/// - 头 26 字节：`8BPS` / 版本 1 / 保留 6 字节 0 / **通道数** / 高 / 宽 / 位深 8 /
///   色彩模式 3（RGB，或 1 = Grayscale）。
/// - **合成图 RAW**（压缩 0）：逐通道、逐行，这就是"打开就看到的那张"。
///   写 RAW 不写 RLE 是**刻意的**：RLE 编码器是另一条要单独守的路径，而合成图
///   本来就是"我们渲染结果的字节存档"，RAW 让它逐字节可预测（读侧两种都认，
///   由第三方语料覆盖）。
/// - 图层段：层记录（矩形/通道表/混合模式/不透明度/flags/**Pascal 名 + `luni`**）
///   + 每通道 RAW 数据 + 全局蒙版长度 0。
///
/// 三条纪律：
/// 1. **不写我们读不回来的东西**：每个字段都能被 `psd_decode` 原样读回
///    （`psd_out_test.mbt` 用"编 → 解 → 比"把这句话变成判据）。
/// 2. **不写我们不能表达的语义**：蒙版/调整层/图层效果在 agent 侧就拒了
///    （见 `agent/psd_out.mbt` 的拒绝清单）——这里也不提供"假装有蒙版"的入口。
/// 3. **单位只有一处换算**：`opacity` 这一层就收 **0..255**（agent 侧从 0..1 折），
///    像素一律**非预乘 RGBA**。

///|
/// 要写出的一条图层。
///
/// - `rgba`：`w*h*4` 非预乘（R,G,B,A 字节序），**没有预乘**——PSD 的通道也是
///   非预乘，两边同一个口径才不会出现"半透明边缘发黑"。
/// - `has_alpha`：是否写 −1（透明度）通道。全不透明的层写 3 通道更小，
///   而第三方读回来的 `w×h` 与像素都一样。
pub(all) struct PsdOutLayer {
  name : String
  x : Int
  y : Int
  w : Int
  h : Int
  opacity : Int
  visible : Bool
  blend : String
  rgba : Array[Byte]
  has_alpha : Bool
}

///|
/// 本仓库的混合模式名 → PSD 的 4 字节签名。`None` = 没有对应（调用方拒绝）。
///
/// **与 `psd_blend_name` 成对**：两个方向写在同一处，`psd_out_test.mbt` 断言
/// 七种模式**两个方向都往返**——只有单向表的话，加了新模式会出现
/// "读得进来、写不回去"（或写出去没人认得）。
pub fn psd_blend_tag(name : String) -> String? {
  match name {
    "normal" => Some("norm")
    "multiply" => Some("mul ")
    "screen" => Some("scrn")
    "overlay" => Some("over")
    "darken" => Some("dark")
    "lighten" => Some("lite")
    "difference" => Some("diff")
    _ => None
  }
}

///|
fn psd_out_b(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
}

///|
fn psd_out_u16(out : Array[Byte], v : Int) -> Unit {
  psd_out_b(out, (v >> 8) & 0xFF)
  psd_out_b(out, v & 0xFF)
}

///|
fn psd_out_be32(out : Array[Byte], v : Int) -> Unit {
  psd_out_b(out, (v >> 24) & 0xFF)
  psd_out_b(out, (v >> 16) & 0xFF)
  psd_out_b(out, (v >> 8) & 0xFF)
  psd_out_b(out, v & 0xFF)
}

///|
/// 4 字节 ASCII 标签（长度必须正好 4——短了会把后面的字段读歪）。
fn psd_out_tag(out : Array[Byte], tag : String) -> Unit {
  let bs = @utf8.encode(tag)
  let mut i = 0
  while i < 4 {
    psd_out_b(out, if i < bs.length() { bs[i].to_int() } else { 0 })
    i = i + 1
  }
}

///|
/// UTF-8 字符串 → UTF-16BE 字节（`luni` 块体：先 u32 字符数，再 2×n 字节）。
fn psd_out_utf16be(s : String) -> Array[Byte] {
  let bs = @utf16.encode(s, endianness=Big)
  let out : Array[Byte] = []
  let mut i = 0
  while i < bs.length() {
    out.push(bs[i])
    i = i + 1
  }
  out
}

///|
/// 一条图层的额外信息段（`extra`）：
/// `蒙版长度 0` + `混合范围长度 0` + Pascal 名（4 字节对齐）+ `luni` 块。
///
/// ⚠️ Pascal 名是**字节**名（≤255），`luni` 才是完整名字。两个都写：
/// 老工具只认 Pascal，而 `luni` 让中文名往返不坏（读侧 `psd_extra_info`
/// 优先 `luni`）。
fn psd_out_extra(l : PsdOutLayer) -> Array[Byte] {
  let name_bytes = @utf8.encode(l.name)
  let n = if name_bytes.length() > 255 { 255 } else { name_bytes.length() }
  let out : Array[Byte] = []
  psd_out_be32(out, 0) // 蒙版块长度：**不写蒙版**（我们只写像素，见文件头注释）
  psd_out_be32(out, 0) // 混合范围长度：本仓库没有"混合范围"语义
  psd_out_b(out, n)
  let mut i = 0
  while i < n {
    psd_out_b(out, name_bytes[i].to_int())
    i = i + 1
  }
  // Pascal 名按 4 字节对齐（对齐的起点是 extra 段起点：4+4 之后）
  let used = 4 + 4 + 1 + n
  let pad = (4 - (used % 4)) % 4
  let mut k = 0
  while k < pad {
    psd_out_b(out, 0)
    k = k + 1
  }
  // 附加信息块：`luni`（Unicode 层名）
  let uni = psd_out_utf16be(l.name)
  psd_out_tag(out, "8BIM")
  psd_out_tag(out, "luni")
  psd_out_be32(out, uni.length() + 4)
  psd_out_be32(out, l.name.length())
  for b in uni {
    out.push(b)
  }
  out
}

///|
/// 一条图层记录（通道表 + 混合 + 不透明度 + flags + extra）。
/// `chan_lens` = 该层各通道的数据字节数（含每个通道的 2 字节压缩头）。
fn psd_out_record(l : PsdOutLayer, chan_lens : Array[Int]) -> Array[Byte] {
  let extra = psd_out_extra(l)
  let out : Array[Byte] = []
  psd_out_be32(out, l.y) // top
  psd_out_be32(out, l.x) // left
  psd_out_be32(out, l.y + l.h) // bottom
  psd_out_be32(out, l.x + l.w) // right
  let nchan = if l.has_alpha { 4 } else { 3 }
  psd_out_u16(out, nchan)
  // 通道表：通道 id（i16）+ 数据长度（u32）。顺序：alpha(-1) 在前，再 R,G,B
  // ——与 Photoshop 一致，也与我们读侧的"按 id 认通道"无关（id 说了算）。
  let mut c = 0
  while c < nchan {
    let cid = if l.has_alpha && c == 0 { -1 } else { c - (if l.has_alpha { 1 } else { 0 }) }
    psd_out_u16(out, cid & 0xFFFF)
    psd_out_be32(out, chan_lens[c])
    c = c + 1
  }
  psd_out_tag(out, "8BIM")
  let tag = match psd_blend_tag(l.blend) {
    None => "norm"
    Some(t) => t
  }
  psd_out_tag(out, tag)
  psd_out_b(out, l.opacity)
  psd_out_b(out, 0) // 剪贴：本仓库没有剪贴语义，恒 0
  psd_out_b(out, if l.visible { 0 } else { 2 }) // flags bit1 = 隐藏
  psd_out_b(out, 0) // filler
  psd_out_be32(out, extra.length())
  for b in extra {
    out.push(b)
  }
  out
}

///|
/// 一条图层的通道数据体（不含压缩头）：**非预乘** 逐通道、逐行。
fn psd_out_planes(l : PsdOutLayer) -> Array[Array[Byte]] {
  let nchan = if l.has_alpha { 4 } else { 3 }
  let planes : Array[Array[Byte]] = []
  let mut c = 0
  while c < nchan {
    // 通道顺序与记录里的 id 表一致：alpha 在最前，然后 R,G,B
    let comp = if l.has_alpha { if c == 0 { 3 } else { c - 1 } } else { c }
    let plane : Array[Byte] = []
    let mut i = 0
    while i < l.w * l.h {
      plane.push(l.rgba[i * 4 + comp])
      i = i + 1
    }
    planes.push(plane)
    c = c + 1
  }
  planes
}

///|
/// 渲染缓冲（RGBA、逐像素）→ **合成图平面序** RGB（先整块 R、再 G、再 B）。
///
/// 这是"逐像素 ↔ 逐通道平面"的**唯一一处**转换：写侧的合成图必须是平面序
/// （PSD 硬规定），而我们的渲染缓冲是逐像素的——**别在调用方手搓这段循环**，
/// 交错序写出去会把画面变成一整片灰（写侧第一次往返实测）。
///
/// 白纸语义：渲染缓冲的 alpha 恒 255（画布是不透明的），所以这里直接丢掉
/// alpha，不做预乘还原。
pub fn psd_composite_planes(buf : RgbaBuf) -> Array[Byte] {
  let n = buf.width * buf.height
  let out : Array[Byte] = []
  let mut c = 0
  while c < 3 {
    // `pixels` 是 ARGB（0xAARRGGBB）：平面 0=R 在 16 位、1=G 在 8 位、2=B 在 0 位
    let shift = (2 - c) * 8
    let mut i = 0
    while i < n {
      out.push(((buf.pixels[i] >> shift) & 0xFF).to_byte())
      i = i + 1
    }
    c = c + 1
  }
  out
}

///|
/// `PsdOutLayer` 数组 → `.psd` 字节。
///
/// - `composite`：`width*height*3` 的 RGB，**逐通道平面序**（先整块 R，再整块 G，
///   再整块 B）——"打开就看到的那张"。⚠️ 「平面序」是 PSD 的**硬规定**，写成
///   逐像素交错（`RGBRGB…`）不会报错：读的人会把前 1/3 当成 R 平面，画面变成
///   一整片灰（写侧第一次往返就是这么红的）。所以别手搓这块缓冲，走
///   `psd_composite_planes`（唯一一处转换）。
///   它是**我们渲染结果的字节存档**，不做二次合成。
pub fn psd_encode(
  width : Int,
  height : Int,
  composite : Array[Byte],
  layers : Array[PsdOutLayer],
) -> Result[Bytes, String] {
  if width <= 0 || height <= 0 {
    return Err("画布尺寸非正（\{width}×\{height}）—— 写不出 PSD")
  }
  let comp_channels = 3
  let want = width * height * comp_channels
  if composite.length() != want {
    return Err("合成图字节数 \{composite.length()}，要 \{want}（\{width} 宽 × \{height} 高 × \{comp_channels} 通道）")
  }
  if layers.length() > 10000 {
    return Err("图层数 \{layers.length()} 超过 PSD 的 i16 记账上限（10000 就是我们的实用上限）")
  }
  for l in layers {
    if l.w <= 0 || l.h <= 0 {
      return Err("图层 \{l.name} 的盒子非正（\{l.w}×\{l.h}）—— PSD 的通道数据不能是 0 字节")
    }
    let need = l.w * l.h * 4
    if l.rgba.length() != need {
      return Err("图层 \{l.name} 的像素长度 \{l.rgba.length()} ≠ w×h×4（\{need}）")
    }
    if l.opacity < 0 || l.opacity > 255 {
      return Err("图层 \{l.name} 的不透明度 \{l.opacity} 不在 0..255（PSD 是 8 位）")
    }
    match psd_blend_tag(l.blend) {
      None => return Err("图层 \{l.name} 的混合模式 \{l.blend} 没有 PSD 对应签名")
      Some(_) => ()
    }
  }

  let out : Array[Byte] = []
  // ── 头部 ──
  psd_out_tag(out, "8BPS")
  psd_out_u16(out, 1) // 版本：PSB（2）不支持
  let mut z = 0
  while z < 6 {
    psd_out_b(out, 0)
    z = z + 1
  }
  psd_out_u16(out, comp_channels)
  psd_out_be32(out, height)
  psd_out_be32(out, width)
  psd_out_u16(out, 8)
  psd_out_u16(out, 3)
  // ── 色彩模式数据 / 图像资源：都空（我们没有 ICC/分辨率块的表达，不假装有）──
  psd_out_be32(out, 0)
  psd_out_be32(out, 0)

  // ── 图层与蒙版信息段 ──
  let layer_info : Array[Byte] = []
  psd_out_u16(layer_info, layers.length())
  let chans : Array[Array[Array[Byte]]] = []
  let recs : Array[Array[Byte]] = []
  for l in layers {
    let planes = psd_out_planes(l)
    let lens : Array[Int] = []
    for p in planes {
      // 每个通道的数据 = 2 字节压缩头（0 = RAW）+ 平面字节
      lens.push(2 + p.length())
    }
    recs.push(psd_out_record(l, lens))
    chans.push(planes)
  }
  for r in recs {
    for b in r {
      layer_info.push(b)
    }
  }
  for planes in chans {
    for p in planes {
      psd_out_u16(layer_info, 0) // 压缩 0 = RAW
      for b in p {
        layer_info.push(b)
      }
    }
  }
  // 图层信息段长度（u32）**必须是偶数**（规范：段长按 2 字节对齐，Photoshop
  // 与 psd-tools 都按这个读；奇数字节会让后面的全局蒙版长度读歪一格）
  let info_len = layer_info.length()
  let info_pad = info_len % 2
  let lm_body : Array[Byte] = []
  psd_out_be32(lm_body, info_len + info_pad)
  for b in layer_info {
    lm_body.push(b)
  }
  if info_pad == 1 {
    psd_out_b(lm_body, 0)
  }
  psd_out_be32(lm_body, 0) // 全局蒙版信息：长度 0（我们没有全图蒙版语义）
  psd_out_be32(out, lm_body.length())
  for b in lm_body {
    out.push(b)
  }

  // ── 合成图（RAW）──
  psd_out_u16(out, 0)
  for b in composite {
    out.push(b)
  }
  Ok(Bytes::from_array(out))
}
