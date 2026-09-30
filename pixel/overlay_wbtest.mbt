/// pixel —— 覆盖预览与降采样的不变量（pixel/overlay 的回归锚点）。

///|
fn obuf(w : Int, h : Int, c : Int) -> @codec.RgbaBuf {
  let b = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(b, 0, 0, w, h, c)
  b
}

///|
test "overlay：未选中处逐位保持原像素，选中处被洋红覆盖" {
  let base = obuf(8, 8, 0xFF3366CC)
  let f = field_new(8, 8)
  for x in 0..<4 {
    f.v[3 * 8 + x] = 1.0
  }
  let ov = overlay_buf(base, f, 0)
  assert_eq(ov.width, 8, msg="cap=0 不应降采样（宽）")
  assert_eq(ov.height, 8, msg="cap=0 不应降采样（高）")
  // 第 0 行（未选中）逐位不变
  for x in 0..<8 {
    assert_eq(ov.pixels[x], base.pixels[x], msg="未选中处被改动 @x=\{x}")
  }
  // 第 3 行前 4 像素被覆盖：w=1 → 洋红权重 0.7
  for x in 0..<4 {
    assert_true(ov.pixels[3 * 8 + x] != base.pixels[x], msg="选中处未覆盖 @x=\{x}")
  }
  // 覆盖后 alpha 恒 255（预览是不透明图，不因 base alpha 变化）
  assert_eq(lsr32(ov.pixels[3 * 8], 24), 255, msg="覆盖层 alpha 必须为 255")
}

///|
test "overlay：membership 软过渡（w 越小越接近原图）" {
  let base = obuf(2, 1, 0xFF000000)
  let f = field_new(2, 1)
  f.v[0] = 1.0
  f.v[1] = 0.25
  let ov = overlay_buf(base, f, 0)
  let strong = ov.pixels[0] & 0xFF
  let weak = ov.pixels[1] & 0xFF
  assert_true(strong > weak, msg="w=1 的洋红分量应强于 w=0.25：\{strong} vs \{weak}")
  assert_true(weak > 0, msg="w=0.25 也应被着色")
}

///|
test "downsample_box：整数倍盒平均，尺寸与均值都正确" {
  // 4×4 一半黑一半白 → 2×2，每格 = 4 像素均值
  let b = obuf(4, 4, 0xFF000000)
  @codec.fill_rect_rgba(b, 2, 0, 2, 4, 0xFFFFFFFF)
  let d = downsample_box(b, 2)
  assert_eq(d.width, 2, msg="降采样宽度")
  assert_eq(d.height, 2, msg="降采样高度")
  // 左格 = 黑，右格 = 白
  assert_eq(d.pixels[0] & 0xFF, 0, msg="左格应为黑")
  assert_eq(d.pixels[1] & 0xFF, 255, msg="右格应为白")
  // 混合格：2×2 内两黑两白 → 127 或 128（round-half-up）
  let b2 = obuf(4, 4, 0xFF000000)
  @codec.fill_rect_rgba(b2, 1, 0, 1, 1, 0xFFFFFFFF)
  let d2 = downsample_box(b2, 2)
  assert_eq(d2.pixels[0] & 0xFF, 64, msg="1/4 白 → 64")
}

///|
test "downsample_box：不超上限且不放大" {
  let b = obuf(10, 6, 0xFF123456)
  let same = downsample_box(b, 64)
  assert_eq(same.width, 10, msg="已在限额内不应缩")
  let d = downsample_box(b, 4)
  assert_true(d.width <= 4 && d.height <= 4, msg="降采样超上限：\{d.width}×\{d.height}")
  // 纯色块降采样后仍是同色（盒平均的不动点）
  assert_eq(d.pixels[0], 0xFF123456, msg="纯色降采样应保持原色")
}

///|
test "overlay 必须全分辨率生成后再降采样（顺序不可交换）" {
  // 1px 宽的细线选区：先降采样再算覆盖会整条消失。
  let b = obuf(8, 1, 0xFF000000)
  let f = field_new(8, 1)
  f.v[7] = 1.0
  let ov = overlay_buf(b, f, 4)
  assert_eq(ov.width, 4, msg="应降采样到 4 宽")
  // 细线落在最后一格，降采样后该格必须带洋红分量
  let last = ov.pixels[3] & 0xFF
  assert_true(last > 0, msg="细线选区在降采样后丢失（顺序反了）")
}
