/// agent 侧 PSD 导入：命令面（`psd-info` / `open-psd`）的行为判据。
///
/// **判据分三层**：
/// 1. 结构：层表逐字段对**第三方写出的文件**（`codec/testdata/psd/` 那批语料是
///    psd-tools 1.24.0 写、Pillow 12.3.0 读回来核过期望值的）。
/// 2. 画面：导入后 `render` 的像素 == PSD 自己的合成图**叠在白纸上**（本仓库的
///    画布是白纸）——这是"导入没读丢东西"的端到端证据，不是"命令回 ok"。
///    唯一例外见 `layered_two`：图层不透明度 128/255 的过渡带上，第三方（浮点）
///    与我们（定点）的混合差 **1**，断言里写明并只放过 1。
/// 3. 边界：第三方读得开的文件我们必须**明确拒绝**，且拒绝时**会话一个字节都
///    不许变**（"开了一半"比"没打开"坏得多）。

///|
const PSD_RLE : String = "OEJQUwABAAAAAAAAAAMAAAAFAAAADAAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

///|
const PSD_RGB_RAW : String = "OEJQUwABAAAAAAAAAAMAAAAEAAAACQAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

///|
const PSD_RGBA_ALPHA : String = "OEJQUwABAAAAAAAAAAQAAAAHAAAACQAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

///|
const PSD_GRAY : String = "OEJQUwABAAAAAAAAAAEAAAAIAAAACAAIAAEAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

///|
const PSD_1X1 : String = "OEJQUwABAAAAAAAAAAMAAAABAAAAAQAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAA="

///|
const PSD_7X3 : String = "OEJQUwABAAAAAAAAAAMAAAADAAAABwAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

///|
const PSD_RLE_COMP : String = "OEJQUwABAAAAAAAAAAMAAAAGAAAACwAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAEADAAMAAwADAAMAAwAAgACAAIAAgACAAIAAgACAAIAAgACAAIKAAsWISw3Qk1YY24KAAsWISw3Qk1YY24KAAsWISw3Qk1YY24KAAsWISw3Qk1YY24KAAsWISw3Qk1YY24KAAsWISw3Qk1YY272PPY89jz2PPY89jz2APYh9kL2Y/aE9qU="

///|
const PSD_RGBA_RLE_COMP : String = "OEJQUwABAAAAAAAAAAQAAAAGAAAABgAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAEAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIABwAHAAcABwAHAAf7APsA+wD7APsA+wD7//v/+//7//v/+//7APsA+wD7APsA+wAFAChQeKDIBQAoUHigyAUAKFB4oMgFAChQeKDIBQAoUHigyAUAKFB4oMg="

///|
const PSD_TWO : String = "OEJQUwABAAAAAAAAAAMAAAAHAAAACgAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAHgAAAB2AACAAAAAQAAAAEAAAAFAAAABwAF//8AAAASAAAAAAASAAEAAAASAAIAAAAS//4AAAASOEJJTW5vcm3/AAgAAAAAUAAAABQAAAABAAAAAQAAAAUAAAAHAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//CmJvdHRvbSByZWQAAAAAAgAAAAMAAAAGAAAABwAF//8AAAASAAAAAAASAAEAAAASAAIAAAAS//4AAAASOEJJTW5vcm2AAAgAAAAAUAAAABQAAAACAAAAAwAAAAYAAAAHAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//CHRvcCBibHVlAAAAAAEAAgACAAIAAvv/+//7//v/AAEAAgACAAIAAvv/+//7//v/AAEAAgACAAIAAvsA+wD7APsAAAEAAgACAAIAAvsA+wD7APsAAAEAAgACAAIAAvv/+//7//v/AAEAAgACAAIAAv3//f/9//3/AAEAAgACAAIAAv0A/QD9AP0AAAEAAgACAAIAAv0A/QD9AP0AAAEAAgACAAIAAv3//f/9//3/AAEAAgACAAIAAv3//f/9//3/AAAAAAAAAAAAAAAAAAAAAAAAAP///////wAAAAD//39/f38AAAAA//9/f39/AAAAAP//f39/fwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgICAgAAAAAAAAICAgIAAAAAAAACAgICAAAAAAAAA/////wAAAAAAAAAAAAAAAAA="

///|
const PSD_HIDDEN : String = "OEJQUwABAAAAAAAAAAMAAAAIAAAACAAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAIAAAAB+AACAAAAAAAAAAAAAAAFAAAABQAF//8AAAAWAAAAAAAWAAEAAAAWAAIAAAAW//4AAAAWOEJJTW5vcm3/AAgAAAAATAAAABQAAAAAAAAAAAAAAAUAAAAFAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//BXNob3duAAAAAAACAAAAAgAAAAcAAAAHAAX//wAAABYAAAAAABYAAQAAABYAAgAAABb//gAAABY4QklNbm9ybf8ACgAAAABMAAAAFAAAAAIAAAACAAAABwAAAAcAAAAAAAAAKAAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8GaGlkZGVuAAABAAIAAgACAAIAAvz//P/8//z//P8AAQACAAIAAgACAAL8APwA/AD8APwAAAEAAgACAAIAAgAC/Mj8yPzI/Mj8yAABAAIAAgACAAIAAvwA/AD8APwA/AAAAQACAAIAAgACAAL8//z//P/8//z/AAEAAgACAAIAAgAC/P/8//z//P/8/wABAAIAAgACAAIAAvz//P/8//z//P8AAQACAAIAAgACAAL8//z//P/8//z/AAEAAgACAAIAAgAC/AD8APwA/AD8AAABAAIAAgACAAIAAvz//P/8//z//P8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADIyMjIyAAAAMjIyMjIAAAAyMjIyMgAAADIyMjIyAAAAMjIyMjIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="

///|
const PSD_THREE : String = "OEJQUwABAAAAAAAAAAMAAAAGAAAABgAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAGwAAABqAACAAAAAAAAAAAAAAADAAAAAwAF//8AAAAOAAAAAAAOAAEAAAAOAAIAAAAO//4AAAAOOEJJTW5vcm3/AAgAAAAATAAAABQAAAAAAAAAAAAAAAMAAAADAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//Bm9wYXF1ZQAAAAABAAAAAQAAAAQAAAAEAAX//wAAAA4AAAAAAA4AAQAAAA4AAgAAAA7//gAAAA44QklNbm9ybf8ACAAAAABMAAAAFAAAAAEAAAABAAAABAAAAAQAAAAAAAAAKAAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8Fc29saWQAAAABAAIAAgAC/v/+//7/AAEAAgACAAL+eP54/ngAAQACAAIAAv4e/h7+HgABAAIAAgAC/sj+yP7IAAEAAgACAAL+//7//v8AAQACAAIAAv7//v/+/wABAAIAAgAC/vr++v76AAEAAgACAAL++v76/voAAQACAAIAAv76/vr++gABAAIAAgAC/v/+//7/AAAAAAAAAAB4eHgAAAB4+vr6AAB4+vr6AAAA+vr6AAAAAAAAAAAAAAAAAAAeHh4AAAAe+vr6AAAe+vr6AAAA+vr6AAAAAAAAAAAAAAAAAADIyMgAAADI+vr6AADI+vr6AAAA+vr6AAAAAAAAAAAAAAAAAAA="

///|
const PSD_ALPHA : String = "OEJQUwABAAAAAAAAAAMAAAAEAAAABAAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAADwAAAA6AABAAAAAAAAAAAAAAAEAAAABAAF//8AAAASAAAAAAASAAEAAAASAAIAAAAS//4AAAASOEJJTW5vcm3/AAgAAAAATAAAABQAAAAAAAAAAAAAAAQAAAAEAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//BHNlbWkAAAAAAQACAAIAAgAC/YD9gP2A/YAAAQACAAIAAgAC/cj9yP3I/cgAAQACAAIAAgAC/WT9ZP1k/WQAAQACAAIAAgAC/TL9Mv0y/TIAAQACAAIAAgAC/f/9//3//f8AAAAAAADIyMjIyMjIyMjIyMjIyMjIZGRkZGRkZGRkZGRkZGRkZDIyMjIyMjIyMjIyMjIyMjI="

///|
const PSD_CMYK : String = "OEJQUwABAAAAAAAAAAQAAAAEAAAABAAIAAQAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

///|
const PSD_D16 : String = "OEJQUwABAAAAAAAAAAMAAAAEAAAABAAQAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

///|
const PSD_ZIP : String = "OEJQUwABAAAAAAAAAAMAAAAFAAAABQAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAADgAAAA2AABAAAAAAAAAAAAAAAEAAAABAAF//8AAAAOAAAAAAANAAEAAAAOAAIAAAAN//4AAAAOOEJJTW5vcm3/AAgAAAAAUAAAABQAAAAAAAAAAAAAAAQAAAAEAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//CXppcCBsYXllcgAAAAJ4nPv/HxUAAIeID/EAAnic4+JCBQAFYAChAAJ4nDtxAhUAAGpQDIEAAnic4+JCBQAFYAChAAJ4nPv/HxUAAIeID/EAAAAAAAAAAAoKCgoACgoKCgAKCgoKAAoKCgoAAAAAAADIyMjIAMjIyMgAyMjIyADIyMjIAAAAAAAACgoKCgAKCgoKAAoKCgoACgoKCgAAAAAAAA=="

///|
const PSD_ZIP2 : String = "OEJQUwABAAAAAAAAAAMAAAAFAAAABQAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAADwAAAA6AABAAAAAAAAAAAAAAAEAAAABAAF//8AAAARAAAAAAAQAAEAAAARAAIAAAAQ//4AAAAROEJJTW5vcm3/AAgAAAAAUAAAABQAAAAAAAAAAAAAAAQAAAAEAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//CXppcCBsYXllcgAAAAN4nPvPwMDwHwkDACfoA/0AA3ic42JgYOBCwgABoAApAAN4nDvBwMBwAgkDAB9QAyEAA3ic42JgYOBCwgABoAApAAN4nPvPwMDwHwkDACfoA/0AAAAAAAAAAAAKCgoKAAoKCgoACgoKCgAKCgoKAAAAAAAAyMjIyADIyMjIAMjIyMgAyMjIyAAAAAAAAAoKCgoACgoKCgAKCgoKAAoKCgoAAAAAAAA="

///|
const PSD_GROUP : String = "OEJQUwABAAAAAAAAAAMAAAAGAAAABgAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAAJMAAACRAADAAAAAAAAAAAAAAAAAAAAAAAE//8AAAACAAAAAAACAAEAAAACAAIAAAACOEJJTW5vcm3/AAgAAAAAfAAAAAAAAAAoAAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//w48L0xheWVyIGdyb3VwPgA4QklNbHNjdAAAAAQAAAADOEJJTWx1bmkAAAAgAAAADgA8AC8ATABhAHkAZQByACAAZwByAG8AdQBwAD4AAAAAAAAAAAAAAAMAAAADAAX//wAAAA4AAAAAAA4AAQAAAA4AAgAAAA7//gAAAA44QklNbm9ybf8ACAAAAABMAAAAFAAAAAAAAAAAAAAAAwAAAAMAAAAAAAAAKAAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8FaW5uZXIAAAAAAAAAAAAAAAAAAAAAAAAABP//AAAAAgAAAAAAAgABAAAAAgACAAAAAjhCSU1ub3Jt/wAIAAAAAHAAAAAAAAAAKAAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8HYSBncm91cDhCSU1sc2N0AAAADAAAAAE4QklNcGFzczhCSU1sdW5pAAAAFAAAAAcAYQAgAGcAcgBvAHUAcAAAAAAAAAAAAAAAAQACAAIAAv7//v/+/wABAAIAAgAC/v/+//7/AAEAAgACAAL+AP4A/gAAAQACAAIAAv4A/gD+AAABAAIAAgAC/v/+//7/AAAAAAAAAAAAAAAAAAD///8AAAD///8AAAD///8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

///|
const PSD_MASK : String = "OEJQUwABAAAAAAAAAAMAAAAGAAAABgAIAAMAAAAAAAAAXjhCSU0EIQAAAAAAUQAAAAEBAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAEABwAHMAZAAtAHQAbwBvAGwAcwAgADEALgAyADQALgAwAAAAAQAAAADwAAAA6AABAAAAAAAAAAAAAAAEAAAABAAF//8AAAASAAAAAAASAAEAAAASAAIAAAAS//4AAAASOEJJTW5vcm3/AAgAAAAATAAAABQAAAAAAAAAAAAAAAQAAAAEAAAAAAAAACgAAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//Bm1hc2tlZAAAAQACAAIAAgAC/f/9//3//f8AAQACAAIAAgAC/f/9//3//f8AAQACAAIAAgAC/QD9AP0A/QAAAQACAAIAAgAC/QD9AP0A/QAAAQACAAIAAgAC/QD9//3//f8AAAAAAAD/////AAD/////AAD/////AAD/////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="


///|
fn psd_open(s : @agent.Session, b64 : String) -> String {
  @agent.exec(s, "open-psd b64=\{b64}")
}

///|
fn psd_session() -> @agent.Session {
  let s = @agent.Session::new()
  let _ = @agent.exec(s, "session-open full_image")
  s
}

///|
/// 渲染当前文档并解出像素：`(宽, 高, RGBA 字节)`。渲染宽度显式给，别让它
/// 偷偷缩放到 1024（那样比的是"缩放算法"而不是"导入对不对"）。
fn psd_render(s : @agent.Session, w : Int) -> (Int, Int, Array[Byte]) {
  let png : Bytes = @base64.decode(jstr_field(@agent.exec(s, "render \{w}"), "png_b64")) catch {
    _ => abort("render 的 png_b64 解不开")
  }
  psd_pixels(png)
}

///|
/// PNG 字节 → `(宽, 高, RGBA 字节)`。
fn psd_pixels(png : Bytes) -> (Int, Int, Array[Byte]) {
  let img = match @codec.png_decode(png) {
    Err(e) => abort("PNG 解不开：\{e}")
    Ok(v) => v
  }
  let out : Array[Byte] = []
  let mut y = 0
  while y < img.height {
    let mut x = 0
    while x < img.width {
      let c = @codec.rgba_get(img, x, y)
      out.push(((c >> 16) & 0xFF).to_byte())
      out.push(((c >> 8) & 0xFF).to_byte())
      out.push((c & 0xFF).to_byte())
      out.push(((c >> 24) & 0xFF).to_byte())
      x = x + 1
    }
    y = y + 1
  }
  (img.width, img.height, out)
}

///|
/// 逐通道比两块像素，返回 `(不同字节数, 最大差)`；尺寸不同直接 abort
/// （尺寸对不上的"差异很小"没有意义）。
fn psd_pixel_diff(a : Array[Byte], b : Array[Byte]) -> (Int, Int) {
  if a.length() != b.length() {
    abort("像素长度不同：\{a.length()} vs \{b.length()}")
  }
  let mut diff = 0
  let mut maxd = 0
  let mut i = 0
  while i < a.length() {
    let x = a[i].to_int() & 0xFF
    let y = b[i].to_int() & 0xFF
    let d = if x > y { x - y } else { y - x }
    if d > 0 {
      diff = diff + 1
    }
    if d > maxd {
      maxd = d
    }
    i = i + 1
  }
  (diff, maxd)
}

///|
/// 一例一验：导入 → 渲染 → 与该例的**参考图**（psd-tools 按层重算叠白纸）
/// 逐通道比。`tol` 是本例声明的容差（0 = 必须逐位相同）。
fn psd_render_case(
  s : @agent.Session,
  b64 : String,
  ref_png : String,
  name : String,
  tol : Int,
) -> Unit raise {
  let r = psd_open(s, b64)
  if !r.has_prefix("{\"ok\":true") {
    abort("\{name}：open-psd 失败 \{r}")
  }
  let (w, h, px) = psd_render(s, jnum_field(r, "width").to_int())
  let raw_png : Bytes = @base64.decode(ref_png) catch {
    _ => abort("\{name}：参考图 b64 坏了")
  }
  let (rw, rh, want) = psd_pixels(raw_png)
  assert_eq(w, rw, msg="\{name}：渲染宽 \{w} ≠ 参考宽 \{rw}")
  assert_eq(h, rh, msg="\{name}：渲染高 \{h} ≠ 参考高 \{rh}")
  let (diff, maxd) = psd_pixel_diff(px, want)
  if tol == 0 {
    assert_eq(maxd, 0, msg="\{name}：与参考图有差（不同字节=\{diff} 最大差=\{maxd}）")
  } else {
    assert_true(maxd <= tol, msg="\{name}：最大差 \{maxd} 超过声明的 \{tol}")
    // 也不许"整张图都在差 1"：那是位置/尺寸错了，不是舍入。
    assert_true(diff * 10 <= px.length(),
      msg="\{name}：不同字节 \{diff}/\{px.length()} 超过一成，不像舍入")
  }
}

///|
/// 边界样本：必须明确拒绝、理由里带着承诺的那句话，且**会话原封不动**。
fn psd_refuse_case(
  s : @agent.Session,
  b64 : String,
  name : String,
  want : String,
) -> Unit raise {
  let before = @agent.exec(s, "render 16")
  let n0 = jnum_field(@agent.exec(s, "list-layers"), "count")
  let r = psd_open(s, b64)
  assert_true(r.has_prefix("{\"error\":"), msg="\{name}：本该被拒，却回了 \{r}")
  assert_true(r.contains(want), msg="\{name}：拒绝理由里没有「\{want}」：\{r}")
  let after = @agent.exec(s, "render 16")
  assert_eq(jstr_field(after, "render_sha256"), jstr_field(before, "render_sha256"),
    msg="\{name}：拒绝之后会话被改了")
  assert_eq(jnum_field(@agent.exec(s, "list-layers"), "count"), n0,
    msg="\{name}：拒绝之后层数变了")
}

///|
/// 从回包的 `layer_table[i]` 取**数值**字段（`jnum_field` 只认平铺顶层键，
/// 这里要进数组；解析走 `@core.parse_json`，不做子串匹配）。
fn psd_table_num(text : String, i : Int, key : String) -> Double {
  let rows = psd_table_rows(text)
  if i >= rows.length() {
    abort("layer_table 只有 \{rows.length()} 行，取第 \{i}")
  }
  match rows[i].get(key).bind(fn(v) { v.as_num() }) {
    None => abort("layer_table[\{i}].\{key} 不是数：\{text}")
    Some(n) => n
  }
}

///|
/// 取 `layer_table[i]` 的字符串字段。
fn psd_table_str(text : String, i : Int, key : String) -> String {
  let rows = psd_table_rows(text)
  match rows[i].get(key).bind(fn(v) { v.as_str() }) {
    None => abort("layer_table[\{i}].\{key} 不是字符串：\{text}")
    Some(n) => n
  }
}

///|
/// 取 `layer_table[i]` 的布尔字段（`visible` 是 JSON 布尔）。
fn psd_table_bool(text : String, i : Int, key : String) -> Bool {
  let rows = psd_table_rows(text)
  match rows[i].get(key).bind(fn(v) { v.as_bool() }) {
    None => abort("layer_table[\{i}].\{key} 不是布尔：\{text}")
    Some(n) => n
  }
}

///|
fn psd_table_rows(text : String) -> Array[@core.JValue] {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  match obj.get("layer_table").bind(fn(v) { v.as_arr() }) {
    None => abort("回包缺 layer_table：\{text}")
    Some(a) => a
  }
}

///|
test "psd-info 报结构：层名字/几何/不透明度/可见性/混合都对上第三方那张表" {
  let s = psd_session()
  let r = @agent.exec(s, "psd-info b64=\{PSD_TWO}")
  assert_true(r.has_prefix("{\"ok\":true,\"op\":\"psd-info\""), msg=r)
  assert_eq(jnum_field(r, "width"), 10)
  assert_eq(jnum_field(r, "height"), 7)
  assert_eq(jnum_field(r, "channels"), 3)
  assert_eq(jnum_field(r, "layers"), 2)
  assert_eq(psd_table_num(r, 0, "x"), 1)
  assert_eq(psd_table_num(r, 0, "y"), 1)
  assert_eq(psd_table_num(r, 0, "w"), 6)
  assert_eq(psd_table_num(r, 0, "h"), 4)
  assert_eq(psd_table_num(r, 0, "opacity"), 255)
  assert_eq(psd_table_num(r, 1, "opacity"), 128)
  assert_eq(psd_table_str(r, 0, "name"), "bottom red")
  assert_eq(psd_table_str(r, 1, "name"), "top blue")
  assert_eq(psd_table_str(r, 0, "blend"), "normal")
  assert_true(psd_table_bool(r, 1, "visible"))
  // 合成图 sha：我们的解码 vs Pillow 的解码（语料里那张表按 Pillow 算）。
  assert_eq(jstr_field(r, "composite_sha256"), "30f27710ba50baf35a0eb493f558e377c05155f78791a839563973d13f7dadda")
  // 隐藏层：visible=false 要报出来（不是"看不见就不报"）。
  let r2 = @agent.exec(s, "psd-info b64=\{PSD_HIDDEN}")
  assert_true(!psd_table_bool(r2, 1, "visible"))
}

///|
test "拼合文件（0 图层）当唯一一层导进来：盒子 = 画布，名字叫 composite" {
  let s = psd_session()
  let r = psd_open(s, PSD_RGB_RAW)
  assert_true(r.has_prefix("{\"ok\":true,\"op\":\"open-psd\""), msg=r)
  assert_eq(jnum_field(r, "layers"), 1)
  let q = @agent.exec(s, "list-layers")
  assert_true(q.contains("composite"), msg=q)
  let (w, h, px) = psd_render(s, 9)
  assert_eq(w, 9)
  assert_eq(h, 4)
  let raw_png : Bytes = @base64.decode(PSD_REF_FLAT_RGB_RAW_PNG) catch {
    _ => abort("参考图坏了")
  }
  let (_rw, _rh, want) = psd_pixels(raw_png)
  assert_eq(psd_pixel_diff(px, want), (0, 0))
}

///|
test "导入后渲染 == 参考图（psd-tools 按层重算叠白纸；逐位，例外已在断言里写明）" {
  let s = psd_session()
  psd_render_case(s, PSD_RLE, PSD_REF_FLAT_RGB_RLE_PNG, "flat_rgb_rle", PSD_REF_FLAT_RGB_RLE_TOL)
  psd_render_case(s, PSD_RGB_RAW, PSD_REF_FLAT_RGB_RAW_PNG, "flat_rgb_raw", PSD_REF_FLAT_RGB_RAW_TOL)
  psd_render_case(s, PSD_RGBA_ALPHA, PSD_REF_FLAT_RGBA_ALPHA_PNG, "flat_rgba_alpha", PSD_REF_FLAT_RGBA_ALPHA_TOL)
  psd_render_case(s, PSD_GRAY, PSD_REF_FLAT_GRAY_PNG, "flat_gray", PSD_REF_FLAT_GRAY_TOL)
  psd_render_case(s, PSD_1X1, PSD_REF_FLAT_1X1_PNG, "flat_1x1", PSD_REF_FLAT_1X1_TOL)
  psd_render_case(s, PSD_7X3, PSD_REF_FLAT_7X3_PNG, "flat_7x3", PSD_REF_FLAT_7X3_TOL)
  psd_render_case(s, PSD_RLE_COMP, PSD_REF_FLAT_RGB_RLE_COMP_PNG, "flat_rgb_rle_comp", PSD_REF_FLAT_RGB_RLE_COMP_TOL)
  psd_render_case(s, PSD_RGBA_RLE_COMP, PSD_REF_FLAT_RGBA_RLE_COMP_PNG, "flat_rgba_rle_comp", PSD_REF_FLAT_RGBA_RLE_COMP_TOL)
  psd_render_case(s, PSD_TWO, PSD_REF_LAYERED_TWO_PNG, "layered_two", PSD_REF_LAYERED_TWO_TOL)
  psd_render_case(s, PSD_HIDDEN, PSD_REF_LAYERED_HIDDEN_PNG, "layered_hidden", PSD_REF_LAYERED_HIDDEN_TOL)
  psd_render_case(s, PSD_THREE, PSD_REF_LAYERED_THREE_PNG, "layered_three", PSD_REF_LAYERED_THREE_TOL)
  psd_render_case(s, PSD_ALPHA, PSD_REF_LAYERED_ALPHA_PNG, "layered_alpha", PSD_REF_LAYERED_ALPHA_TOL)

}

///|
test "边界：第三方读得开的文件我们必须明确拒绝，且拒绝时不碰会话" {
  let s = psd_session()
  let _ = @agent.exec(s, "new 4 4")
  let _ = @agent.exec(s, "add-rect w=2 h=2 fill=#FF0000FF")
  psd_refuse_case(s, PSD_CMYK, "boundary_cmyk", "色彩模式 CMYK 不支持")
  psd_refuse_case(s, PSD_D16, "boundary_depth16", "位深 16 不支持")
  psd_refuse_case(s, PSD_ZIP, "boundary_zip", "压缩方式 2 不支持")
  psd_refuse_case(s, PSD_ZIP2, "boundary_zip_pred", "压缩方式 3 不支持")
  psd_refuse_case(s, PSD_GROUP, "boundary_group", "图层组")
  psd_refuse_case(s, PSD_MASK, "boundary_mask", "像素蒙版")
  // 另一头：同一批命令在合法文件上必须回 ok 且真的改了会话——
  // 否则"拒绝"可以靠"什么都不干"伪装。
  let ok = psd_open(s, PSD_THREE)
  assert_true(ok.has_prefix("{\"ok\":true"), msg=ok)
  assert_eq(jnum_field(ok, "layers"), 2)
}

///|
test "坏字节：空/短/垃圾一律回错，不 panic，也不改会话" {
  let s = psd_session()
  let _ = @agent.exec(s, "new 3 3")
  let sha0 = jstr_field(@agent.exec(s, "render 3"), "render_sha256")
  for bad in ["", "OEJQUw==", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"] {
    let r = psd_open(s, bad)
    assert_true(r.has_prefix("{\"error\":"), msg="坏载荷 \{bad} 竟然回 \{r}")
    assert_eq(jstr_field(@agent.exec(s, "render 3"), "render_sha256"), sha0,
      msg="坏载荷 \{bad} 之后会话被改了")
  }
  let r1 = @agent.exec(s, "open-psd")
  assert_true(r1.contains("b64"), msg=r1)
  let r2 = @agent.exec(s, "psd-info b64=\{PSD_1X1} wat=1")
  assert_true(r2.contains("wat"), msg=r2)
}

///|
test "psd-info 只读：报完结构，会话一个字节都没变" {
  let s = psd_session()
  let _ = @agent.exec(s, "new 5 5")
  let _ = @agent.exec(s, "add-ellipse w=3 h=3 fill=#00FF00FF")
  let before = @agent.exec(s, "fingerprint")
  let r = @agent.exec(s, "psd-info b64=\{PSD_TWO}")
  assert_true(r.has_prefix("{\"ok\":true"), msg=r)
  assert_eq(@agent.exec(s, "fingerprint"), before)
}

///|
test "导入的文档能进容器：save → open 之后渲染逐位相同、指纹一致" {
  let s = psd_session()
  let r = psd_open(s, PSD_THREE)
  assert_true(r.has_prefix("{\"ok\":true"), msg=r)
  let fp0 = jstr_field(r, "fingerprint")
  let sha0 = jstr_field(@agent.exec(s, "render 6"), "render_sha256")
  let packed = jstr_field(@agent.exec(s, "save-mpd-b64"), "mpd_b64")
  let s2 = psd_session()
  let o = @agent.exec(s2, "open-mpd-b64 \{packed}")
  assert_true(o.has_prefix("{\"ok\":true"), msg=o)
  assert_eq(jstr_field(o, "fingerprint"), fp0)
  assert_eq(jstr_field(@agent.exec(s2, "render 6"), "render_sha256"), sha0)
}
