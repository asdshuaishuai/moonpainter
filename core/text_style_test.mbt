/// core —— ②C 文本排版的判据（单位/边界/盒子/契约）。
///
/// 这一层咬的是**算法**（拆行、折行、行/列推进、盒子、默认值判据）；"画出来对不对"
/// 在 `render/text_style_test.mbt`（像素），"命令面收不收/报不报"在
/// `agent/text_style_test.mbt`。三层各自可被注入抓住。

///|
test "②C 拆行：\\n 是硬换行，wrap=false 时逐字照画（含多个空格）" {
  let d = @core.text_neutral_style()
  assert_eq(@core.text_lines("A", d, 0.0, 16.0), ["A"], msg="单行")
  assert_eq(@core.text_lines("A\nB", d, 0.0, 16.0), ["A", "B"], msg="硬换行")
  assert_eq(@core.text_lines("A\n\nB", d, 0.0, 16.0), ["A", "", "B"], msg="空行占一行")
  assert_eq(@core.text_lines("", d, 0.0, 16.0), [""], msg="空文本仍是 1 行")
  assert_eq(@core.text_lines("A\n", d, 0.0, 16.0), ["A", ""], msg="结尾换行留空行")
  // 不折行时**空格是字面字符**（历史行为）：wrap=false 的折行是空操作
  assert_eq(@core.text_lines("A B", d, 1.0, 16.0), ["A B"], msg="不折行时空格不进词界")
}

///|
test "②C 折行：按词折、超长词硬切、空段落保留" {
  // 字号 16 ⇒ sc=2、推进 6×2=12px/字符；盒子 60 ⇒ 一行 5 个字符
  let d = { ..@core.text_neutral_style(), wrap: true }
  assert_eq(@core.text_lines("AAA BB", d, 60.0, 16.0), ["AAA", "BB"], msg="装不下就换行")
  assert_eq(@core.text_lines("AAA BB CC", d, 60.0, 16.0), ["AAA", "BB CC"], msg="尽量塞满一行")
  assert_eq(
    @core.text_lines("ABCDEFGH", d, 60.0, 16.0),
    ["ABCDE", "FGH"],
    msg="超长词硬切（每 5 个字符一段）",
  )
  assert_eq(@core.text_lines("A B\nC D", d, 60.0, 16.0), ["A B", "C D"], msg="先硬后软")
  assert_eq(@core.text_lines("", d, 60.0, 16.0), [""], msg="空文本折行后仍是空行")
  assert_eq(@core.text_lines("A  B", d, 60.0, 16.0), ["A B"], msg="折行时空格当分隔符（合并）")
  // 盒子比一个字符还窄 ⇒ 夹到 1 列（不许出现 cols=0 的死循环/空结果）
  assert_eq(@core.text_lines("AB", d, 1.0, 16.0), ["A", "B"], msg="最窄也是一列")
}

///|
test "②C 盒子：单行与历史公式**逐位相同**、多行按行距长高、显式 w 优先" {
  // 历史公式：n × fs × 6/7（先乘后除的浮点顺序也要一样）
  for fs in [16.0, 21.0, 28.0] {
    for n in [1, 3, 11] {
      let txt = "x".repeat(n)
      let (w, h) = @core.text_box_of(txt, fs, @core.text_neutral_style(), 0.0)
      assert_eq(w, n.to_double() * fs * 6.0 / 7.0, msg="老公式逐位相同（fs=\{fs} n=\{n}）")
      assert_eq(h, fs, msg="单行高 = 字号")
    }
  }
  // 多行：h = fs + (行数-1) × 行距 × sc
  let st = { ..@core.text_neutral_style(), line_height: 12 }
  let (w3, h3) = @core.text_box_of("A\nBB\nCCC", 28.0, st, 0.0)
  // fs=28 ⇒ sc=4、行距 12×4=48；宽度取最长行（3 字符 ⇒ 3×28×6/7 = 72）
  assert_eq(h3, 28.0 + 2.0 * 48.0, msg="多行高")
  assert_eq(w3, 3.0 * 28.0 * 6.0 / 7.0, msg="宽度取最长行")
  // 显式 w 优先（wrap 拿它当折行宽度）
  let (w4, _) = @core.text_box_of("A\nBB", 28.0, st, 200.0)
  assert_eq(w4, 200.0, msg="显式 w 优先")
  // 字距进盒宽
  let ls = { ..@core.text_neutral_style(), letter_spacing: 2 }
  let (wl, _) = @core.text_box_of("ABCD", 28.0, ls, 0.0)
  assert_eq(wl, 4.0 * 28.0 * 6.0 / 7.0 + 3.0 * (2 * 4).to_double(), msg="字距进盒宽（n-1 个间隔）")
}

///|
test "②C 默认值判据与取值边界（两头都咬）" {
  let d = @core.text_neutral_style()
  assert_true(@core.text_style_is_default(d), msg="中性样式就是默认")
  assert_true(
    !@core.text_style_is_default({ ..d, align: @core.TextAlign::Right }),
    msg="align 非默认",
  )
  assert_true(!@core.text_style_is_default({ ..d, line_height: 9 }), msg="line_height 非默认")
  assert_true(!@core.text_style_is_default({ ..d, letter_spacing: 1 }), msg="letter_spacing 非默认")
  assert_true(!@core.text_style_is_default({ ..d, wrap: true }), msg="wrap 非默认")
  // 边界：合法端点不报，越界一格就报
  assert_eq(@core.text_style_param_error({ ..d, line_height: 1 }), None, msg="行距下界")
  assert_eq(@core.text_style_param_error({ ..d, line_height: 64 }), None, msg="行距上界")
  assert_true(@core.text_style_param_error({ ..d, line_height: 0 }) is Some(_), msg="行距 0 要报")
  assert_true(@core.text_style_param_error({ ..d, line_height: 65 }) is Some(_), msg="行距 65 要报")
  assert_eq(@core.text_style_param_error({ ..d, letter_spacing: -5 }), None, msg="字距下界")
  assert_eq(@core.text_style_param_error({ ..d, letter_spacing: 32 }), None, msg="字距上界")
  assert_true(
    @core.text_style_param_error({ ..d, letter_spacing: -6 }) is Some(_),
    msg="字距 -6 要报（推进只剩 0 格）",
  )
  assert_true(
    @core.text_style_param_error({ ..d, letter_spacing: 33 }) is Some(_),
    msg="字距 33 要报",
  )
}

///|
test "②C 名字表与单位换算：三个对齐名字、sc 取整、推进格数" {
  let names = @core.all_text_aligns().map(fn(a) { @core.text_align_name(a) })
  assert_eq(names, ["left", "center", "right"], msg="对齐名字表")
  for a in @core.all_text_aligns() {
    match @core.text_align_from_name(@core.text_align_name(a)) {
      Some(b) =>
        assert_eq(@core.text_align_name(b), @core.text_align_name(a), msg="名字往返")
      None => abort("名字读不回来")
    }
  }
  assert_true(@core.text_align_from_name("middle") is None, msg="不认识的对齐必须读不出来")
  // sc = floor(fs/7)，至少 1
  assert_eq(@core.text_scale(6.0), 1, msg="6px 也要有 1 倍")
  assert_eq(@core.text_scale(7.0), 1)
  assert_eq(@core.text_scale(16.0), 2)
  assert_eq(@core.text_scale(28.0), 4)
  // 推进格数 = 6 + 字距
  assert_eq(@core.text_adv_cols(@core.text_neutral_style()), 6)
  assert_eq(
    @core.text_adv_cols({ ..@core.text_neutral_style(), letter_spacing: -5 }),
    1,
    msg="字距 -5 时只剩 1 格",
  )
}

///|
test "②C 渲染契约：非默认排版抬到第 8 档，全默认与 None 都不抬（负控）" {
  let base = {
    ..@core.default_layer("t1", "T", 10.0, 10.0, 100.0, 20.0),
    kind: @core.ShapeKind::Text,
    text: "Hi",
    font_size: 16.0,
  }
  let doc0 = @core.new_document("tstyle-rc", 200, 60)
  doc0.layers.push(base)
  assert_true(
    @core.required_render_contract(doc0) < @core.RENDER_CONTRACT_TEXT_STYLE,
    msg="没有排版的老文本层不许抬档",
  )
  let doc1 = @core.new_document("tstyle-rc2", 200, 60)
  doc1.layers.push({ ..base, text_style: Some(@core.text_neutral_style()) })
  assert_true(
    @core.required_render_contract(doc1) < @core.RENDER_CONTRACT_TEXT_STYLE,
    msg="全默认的排版渲染逐位相同 ⇒ 不抬档（否则版本闸失去分辨力）",
  )
  let doc2 = @core.new_document("tstyle-rc3", 200, 60)
  doc2.layers.push({ ..base, text_style: Some({ ..@core.text_neutral_style(), wrap: true }) })
  assert_eq(
    @core.required_render_contract(doc2),
    @core.RENDER_CONTRACT_TEXT_STYLE,
    msg="真排版必须抬档（老引擎只会画单行左对齐）",
  )
}
