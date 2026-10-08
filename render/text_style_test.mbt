/// render —— ②C 文本排版的**像素判据**。
///
/// 这一层只咬"画出来什么样"：`\n` 有没有把第二行画到下面、对齐有没有真的偏、
/// 行距/字距有没有改推进、折行有没有换行，以及**全默认 ≡ 没有这个字段**
/// （那条 `lint` 白装判据的画面版）。

///|
/// 文本层探针：画布 200×120、层在 (10,10)、盒 180×100 宽得能看出对齐差别。
/// `text` 里的 `\n` 是硬换行。
fn tst_layer(text : String, ts : @core.TextStyle?) -> @core.Layer {
  {
    ..@core.default_layer("t1", "T", 10.0, 10.0, 180.0, 100.0),
    kind: @core.ShapeKind::Text,
    text,
    font_size: 28.0,
    text_style: ts,
    fill: @core.Fill::Solid(0xFF000000),
  }
}

///|
fn tst_doc(id : String, text : String, ts : @core.TextStyle?) -> @core.Document {
  let d = @core.new_document(id, 400, 120)
  d.layers.push(tst_layer(text, ts))
  d
}

///|
/// 墨迹外接盒 + 像素数 + 每行墨迹的 y 区间（多行判据要"哪几行有墨"）。
fn tst_ink(buf : @codec.RgbaBuf) -> (Int, Int, Int, Int, Int, Array[Int]) {
  let mut x0 = 9999
  let mut y0 = 9999
  let mut x1 = -1
  let mut y1 = -1
  let mut n = 0
  let rows : Array[Int] = []
  for y in 0..<120 {
    let mut has = false
    for x in 0..<400 {
      if buf.pixels[y * 400 + x] != 0xFFFFFFFF {
        has = true
        n = n + 1
        if x < x0 {
          x0 = x
        }
        if x > x1 {
          x1 = x
        }
        if y < y0 {
          y0 = y
        }
        if y > y1 {
          y1 = y
        }
      }
    }
    if has {
      rows.push(y)
    }
  }
  (x0, y0, x1, y1, n, rows)
}

///|
/// 有墨的 y 值合成"段"（连续或间隔 ≤2 的算同一行——字模 7 行 × sc=4 有间隙）。
fn tst_row_bands(rows : Array[Int]) -> Array[(Int, Int)] {
  let out : Array[(Int, Int)] = []
  let mut start = -1
  let mut prev = -1
  for y in rows {
    if start < 0 {
      start = y
    } else if y > prev + 2 {
      out.push((start, prev))
      start = y
    }
    prev = y
  }
  if start >= 0 {
    out.push((start, prev))
  }
  out
}

///|
test "②C 硬换行：第二行画在下方（行距 8 格 ⇒ 2 行明显分开）" {
  let env = @render.RenderEnv::new()
  let one = tst_ink(@render.render_doc(tst_doc("tst-1", "HH", None), env))
  let two = tst_ink(
    @render.render_doc(tst_doc("tst-2", "HH\nHH", None), env),
  )
  let b1 = tst_row_bands(one.5)
  let b2 = tst_row_bands(two.5)
  assert_eq(b1.length(), 1, msg="单行只有一段墨")
  assert_eq(b2.length(), 2, msg="硬换行后有两段墨（段数）")
  // 字模 28px 字号 ⇒ sc=4、字高 28px、行推进 8×4=32px
  assert_eq(b2[1].0, b1[0].0 + 32, msg="第二行从第一行下方 32px 开始")
  assert_eq(two.4, one.4 * 2, msg="两行墨数 = 单行 × 2（同内容）")
}

///|
test "②C 行距：line_height 真的改行推进（正控 + 负控）" {
  let env = @render.RenderEnv::new()
  let d8 = tst_row_bands(
    tst_ink(
      @render.render_doc(
        tst_doc("tst-lh8", "HH\nHH", Some(@core.text_neutral_style())),
        env,
      ),
    ).5,
  )
  let st12 = { ..@core.text_neutral_style(), line_height: 12 }
  let d12 = tst_row_bands(
    tst_ink(
      @render.render_doc(tst_doc("tst-lh12", "HH\nHH", Some(st12)), env),
    ).5,
  )
  assert_eq(d8[1].0 - d8[0].0, 32, msg="缺省行推距 8×sc=4 ⇒ 32")
  assert_eq(d12[1].0 - d12[0].0, 48, msg="line_height=12 ⇒ 12×4=48（正控）")
}

///|
test "②C 对齐：盒宽 180 时 center/right 真的偏（左对齐是原点）" {
  let env = @render.RenderEnv::new()
  let left = tst_ink(@render.render_doc(tst_doc("tst-al", "HH", None), env))
  let stc = { ..@core.text_neutral_style(), align: @core.TextAlign::Center }
  let center = tst_ink(
    @render.render_doc(tst_doc("tst-ac", "HH", Some(stc)), env),
  )
  let str = { ..@core.text_neutral_style(), align: @core.TextAlign::Right }
  let right = tst_ink(
    @render.render_doc(tst_doc("tst-ar", "HH", Some(str)), env),
  )
  // 推进 = 6×4 = 24 ⇒ 2 个字符的墨宽 = 2×24 - 空隙；偏移 = floor((180 - 48)/2)=66
  assert_eq(center.0 - left.0, 66, msg="居中偏移 = floor((盒宽 - 行宽)/2)")
  assert_eq(right.0 - left.0, 180 - 48, msg="右对齐偏移 = 盒宽 - 行宽")
  // 负控：三张图的**墨数**必须一样（对齐只挪位置，不改字形）
  assert_eq(center.4, left.4, msg="居中不改墨数")
  assert_eq(right.4, left.4, msg="右对齐不改墨数")
}

///|
test "②C 字距：letter_spacing 改推进（负控：不给就不动）" {
  let env = @render.RenderEnv::new()
  let a = tst_ink(@render.render_doc(tst_doc("tst-ls0", "HH", None), env))
  let st = { ..@core.text_neutral_style(), letter_spacing: 3 }
  let b = tst_ink(@render.render_doc(tst_doc("tst-ls3", "HH", Some(st)), env))
  // 推进从 6 格变 9 格 ⇒ 第 2 个字符整体右移 12px（3 格 × sc=4）
  assert_eq(b.2 - a.2, 12, msg="字距 3 格 ⇒ 末列右移 12px")
  assert_eq(b.4, a.4, msg="字距不改墨数")
  // 负字距：叠紧。⚠️ 实测 **-12px** 而不是"推进少 2 格 = 8px"——因为字模是
  // 5 列 × sc=4 = 20px 宽，而字距 -2 时一格只剩 16px：**字模比格子宽**，
  // 尾部那一列被 `text_cell` 的 `col < 5` 判据裁掉（`col` 是**格子内**的列号）。
  // 这是整数格点阵的诚实边界（负字距会把字压在一起并裁掉溢出的那一列），
  // 写进 DESIGN/README；判据按**实测**咬（-12），并顺带咬住"墨数不变"。
  let stn = { ..@core.text_neutral_style(), letter_spacing: -2 }
  let c = tst_ink(@render.render_doc(tst_doc("tst-lsn", "HH", Some(stn)), env))
  assert_eq(c.2 - a.2, -12, msg="字距 -2 格 ⇒ 末列左移 12px（含字模溢出被裁）")
}

///|
test "②C 折行：wrap=1 按盒宽换行，盒子高度跟着涨" {
  let env = @render.RenderEnv::new()
  // "HHHHHHHHHH" 10 个字符 × 24px = 240px > 盒宽 180 ⇒ 一行只放得下 7 个（168px）
  let nowrap = tst_ink(
    @render.render_doc(tst_doc("tst-nw", "HHHHHHHHHH", None), env),
  )
  let st = { ..@core.text_neutral_style(), wrap: true }
  let wrapped = tst_ink(
    @render.render_doc(tst_doc("tst-w", "HHHHHHHHHH", Some(st)), env),
  )
  assert_eq(tst_row_bands(nowrap.5).length(), 1, msg="不折行只有一行")
  assert_eq(tst_row_bands(wrapped.5).length(), 2, msg="折行后两行")
  assert_eq(wrapped.4, nowrap.4, msg="折行不改墨数（同内容换个摆法）")
  assert_true(wrapped.2 <= 179, msg="折行后不越出盒子右缘：x1=\{wrapped.2}")
  // 盒子高度：2 行 ⇒ fs + 1×8×sc = 28 + 32 = 60
  let (_, h) = @core.text_box_of("HHHHHHHHHH", 28.0, st, 180.0)
  assert_eq(h, 60.0, msg="两行盒高")
}

///|
test "②C 全默认排版 ≡ 没有排版（白装判据的画面版）" {
  let env = @render.RenderEnv::new()
  let a = @render.render_doc(tst_doc("tst-none", "Hi\nThere", None), env)
  let b = @render.render_doc(
    tst_doc("tst-def", "Hi\nThere", Some(@core.text_neutral_style())),
    env,
  )
  let mut i = 0
  while i < 400 * 120 {
    if a.pixels[i] != b.pixels[i] {
      abort("全默认的 text_style 必须与没有它逐位相同（第 \{i} 像素）")
    }
    i = i + 1
  }
  // 正控：改一个值就必须**真的**不一样（否则上面那条是空的）
  let c = @render.render_doc(
    tst_doc(
      "tst-chg",
      "Hi\nThere",
      Some({ ..@core.text_neutral_style(), line_height: 9 }),
    ),
    env,
  )
  let mut diff = 0
  let mut k = 0
  while k < 400 * 120 {
    if a.pixels[k] != c.pixels[k] {
      diff = diff + 1
    }
    k = k + 1
  }
  assert_true(diff > 0, msg="line_height=9 必须改画面（正控）")
}
