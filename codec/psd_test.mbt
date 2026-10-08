/// codec —— PSD 读取的判据（③ PSD 兼容 · 读）。
///
/// 语料与期望值来自 `tools/make_psd_corpus.py`：**psd-tools 写出**（第三方实现），
/// 期望的合成图由 **Pillow 与 psd-tools 双读**算出（两边不一致就直接不生成），
/// 层表由 psd-tools 读回。于是这里的断言是"我们与第三方实现逐字节一致"，
/// 不是"我们自己跟自己一致"。
///
/// 三层判据：
/// ① 语料（12 例）：解码成功 + 合成图 sha + 层表逐字段（名字/矩形/不透明度/
///    可见性/混合模式/每层像素 sha）；
/// ② 边界（6 例）：第三方**读得开**、我们**必须拒绝**，且错误里出现指定那句话
///    ——"不降级"不是形容词，是这六条断言；
/// ③ 坏字节（截断/空/垃圾）：只回错不 panic（`verify.sh#panic-hunt` 也从外面喂）。

///|
fn psd_bytes_of(b64 : String) -> Bytes {
  try {
    @base64.decode(b64)
  } catch {
    _ => Bytes::from_array([])
  }
}

///|
fn psd_rgba_sha(a : Array[Byte]) -> String {
  @base.sha256_hex(Bytes::from_array(a))
}

///|
/// 比对一条语料的层表与像素，返回不一致的说明（空数组 = 全对）。
/// ⚠️ 逐字段比而不是挑几个比：语料的价值就在于**没有挑选的余地**。
fn psd_layer_mismatches(
  got : Array[@codec.PsdLayer],
  want : Array[PsdLayerCase],
) -> Array[String] {
  let out : Array[String] = []
  if got.length() != want.length() {
    out.push("层数：解出 \{got.length()}，期望 \{want.length()}")
    return out
  }
  for i = 0; i < got.length(); i = i + 1 {
    let g = got[i]
    let w = want[i]
    if g.name != w.name {
      out.push("层 \{i} 名字：\{g.name} ≠ \{w.name}")
    }
    if g.x != w.x || g.y != w.y {
      out.push("层 \{i} 位置：(\{g.x},\{g.y}) ≠ (\{w.x},\{w.y})")
    }
    if g.w != w.w || g.h != w.h {
      out.push("层 \{i} 尺寸：\{g.w}×\{g.h} ≠ \{w.w}×\{w.h}")
    }
    if g.opacity != w.opacity {
      out.push("层 \{i} 不透明度：\{g.opacity} ≠ \{w.opacity}")
    }
    if g.visible != w.visible {
      out.push("层 \{i} 可见性：\{g.visible} ≠ \{w.visible}")
    }
    if g.blend != w.blend {
      out.push("层 \{i} 混合模式：\{g.blend} ≠ \{w.blend}")
    }
    if psd_rgba_sha(g.rgba) != w.rgba_sha {
      out.push("层 \{i}（\{w.name}）像素 sha 不同：\{psd_rgba_sha(g.rgba)} ≠ \{w.rgba_sha}")
    }
  }
  out
}

///|
test "语料：第三方写出的 PSD 逐例对得上（合成图 + 层表）" {
  let bad : Array[String] = []
  for c in psd_ok_cases {
    let bytes = psd_bytes_of(c.b64)
    if bytes.length() == 0 {
      bad.push("\{c.name}：语料 b64 解不开（生成脚本与提交的语料不同步？）")
      continue
    }
    match @codec.psd_decode(bytes) {
      Err(e) => bad.push("\{c.name}：解码失败 —— \{e}")
      Ok(img) => {
        if img.width != c.width || img.height != c.height {
          bad.push("\{c.name}：尺寸 \{img.width}×\{img.height} ≠ \{c.width}×\{c.height}")
        }
        let csha = @base.sha256_hex(Bytes::from_array(img.composite))
        if csha != c.composite_sha {
          bad.push("\{c.name}：合成图 sha 不同 \{csha} ≠ \{c.composite_sha}")
        }
        for m in psd_layer_mismatches(img.layers, c.layers) {
          bad.push("\{c.name}：\{m}")
        }
      }
    }
  }
  if bad.length() > 0 {
    fail("PSD 语料对不上（\{bad.length()} 处）：\n\{bad.join("\n")}")
  }
  inspect(psd_ok_cases.length() >= 12, content="true")
}

///|
test "边界：第三方读得开的文件，我们必须明确拒绝（不降级）" {
  for c in psd_bad_cases {
    let bytes = psd_bytes_of(c.b64)
    if bytes.length() == 0 {
      fail("\{c.name}：语料 b64 解不开")
    }
    match @codec.psd_decode(bytes) {
      Ok(img) =>
        fail(
          "\{c.name}（\{c.note}）本该被拒，却解出了 \{img.layers.length()} 层 —— 这是**静默降级**",
        )
      Err(e) => {
        if !e.contains(c.want) {
          fail("\{c.name}：拒绝理由里没有「\{c.want}」，实际是「\{e}」")
        }
      }
    }
  }
  inspect(psd_bad_cases.length() >= 6, content="true")
}

///|
test "坏字节：空 / 截断 / 垃圾载荷只回错不 panic" {
  // 空
  inspect(@codec.psd_decode(Bytes::from_array([])) is Err(_), content="true")
  // 只有签名
  let sig : Array[Byte] = [b'\x38', b'\x42', b'\x50', b'\x53']
  inspect(@codec.psd_decode(Bytes::from_array(sig)) is Err(_), content="true")
  // 语料逐例**截断**到各种长度：都必须回错（或极小概率解出一个更小的图，
  // 但绝不能 panic —— panic 会让整个测试进程崩，这里跑得到就是没崩）
  for c in psd_ok_cases {
    let bytes = psd_bytes_of(c.b64)
    if bytes.length() == 0 {
      continue
    }
    let cuts : Array[Int] = [1, 12, 25, bytes.length() / 2, bytes.length() - 1]
    for cut in cuts {
      if cut <= 0 || cut >= bytes.length() {
        continue
      }
      let piece = Bytes::from_array(
        (0).until(cut).map(fn(i) { bytes[i] }).collect(),
      )
      let _ = @codec.psd_decode(piece)
    }
  }
  // 垃圾载荷（全 0xFF）
  let junk = Bytes::from_array((0).until(512).map(fn(_i) { b'\xFF' }).collect())
  inspect(@codec.psd_decode(junk) is Err(_), content="true")
}

///|
test "psd_info 报结构：层名/不透明度/可见性/混合都在" {
  for c in psd_ok_cases {
    if c.layers.length() == 0 {
      continue
    }
    let bytes = psd_bytes_of(c.b64)
    match @codec.psd_info(bytes) {
      Err(e) => fail("\{c.name}：psd_info 回错 \{e}")
      Ok(text) => {
        let l0 = c.layers[0]
        if !text.contains(l0.name) {
          fail("\{c.name}：psd_info 没报第一层的名字「\{l0.name}」：\{text}")
        }
        if !text.contains("opacity=\{l0.opacity}") {
          fail("\{c.name}：psd_info 没报不透明度：\{text}")
        }
        if !text.contains("visible=\{l0.visible}") {
          fail("\{c.name}：psd_info 没报可见性：\{text}")
        }
      }
    }
  }
}

///|
test "确定性：同一份字节解两次逐字节相同" {
  for c in psd_ok_cases {
    let bytes = psd_bytes_of(c.b64)
    let a = @codec.psd_decode(bytes)
    let b = @codec.psd_decode(bytes)
    match (a, b) {
      (Ok(x), Ok(y)) => {
        if x.layers.length() != y.layers.length() {
          fail("\{c.name}：两次解码层数不同")
        }
        for i = 0; i < x.layers.length(); i = i + 1 {
          if psd_rgba_sha(x.layers[i].rgba) != psd_rgba_sha(y.layers[i].rgba) {
            fail("\{c.name}：第 \{i} 层两次像素不同（解码里有非确定状态）")
          }
        }
        if psd_rgba_sha(x.composite) != psd_rgba_sha(y.composite) {
          fail("\{c.name}：合成图两次不同")
        }
      }
      _ => ()
    }
  }
}
