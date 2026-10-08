/// agent —— PSD 导出的判据（③ PSD 兼容 · 写的出口）。
///
/// 三件事，全部**不依赖第三方**（第三方 oracle 在 `verify.sh#psd-roundtrip`）：
/// 1. **合成图逐字节**：`psd-info` 报的 `composite_sha256` 是"读回来的那张图"，
///    它必须等于我们自己 `render` 出来的像素 sha —— 这条把"我们写出去的字节
///    没有骗人"变成可判的：既证明了合成图是**平面序 RGB**，也证明了写出来的
///    文件结构（段长/填充/报头）能让读侧走到合成图那一步。
/// 2. **导出 → 再导入 → 渲染**与原来逐位比：这是"PSD 里存的就是画面"的整条链。
/// 3. **拒绝清单**：调整层 / 装了编辑表 / 超限画布都必须报错（不静默降级）。

///|
/// 造一个"什么都有"的场景：组 + 半透明混合层 + 带蒙版与图层样式的文本层 +
/// 隐藏层。导出/回读要把这些**全部**照顾到。
fn out_scene() -> @agent.Session {
  let s = psd_session()
  let _ = run(s, "new 24 18 uuid=psd-out")
  let _ = run(s, "add-rect x=1 y=1 w=10 h=8 fill=#CC2222FF name=底板 id=r1")
  let _ = run(s, "add-ellipse x=8 y=6 w=12 h=9 fill=#2244CCAA name=半透明蓝 id=e1")
  let _ = run(s, "set-style e1 blend=multiply")
  let _ = run(
    s,
    "add-text x=2 y=2 text=\"Hi\" fill=#000000FF name=字 id=t1 font_size=7",
  )
  let _ = run(s, "add-mask t1 kind=rect x=1 y=1 w=14 h=12 feather=1")
  let _ = run(s, "set-fx t1 shadow=true outline=true")
  let _ = run(s, "group g1 r1 e1")
  // 组的 α<1 是**最容易写错的一格**：渲染器把组 α 烤进画面（`eff_opacity`），
  // 而 PSD 的层记录里还有自己的 opacity 字段——两处都算就成了平方。
  // 变异 R170 就是拿掉"烤层时把 opacity 归 1"，必须有测试咬住它。
  let _ = run(s, "set-style g1 opacity=0.5")
  let _ = run(s, "visible t1 false")
  s
}

///|
/// 导出当前文档 → PSD 字节（失败直接 abort：测试用例里出不了就是 bug）。
fn out_export(s : @agent.Session) -> Bytes {
  let out = run(s, "export-psd-b64")
  if !out.contains("\"ok\":true") {
    abort("export-psd-b64 失败：\{out}")
  }
  @base64.decode(jstr_field(out, "psd_b64")) catch {
    _ => abort("psd_b64 解不开")
  }
}

///|
test "导出：合成图与 render 逐字节相同（写出去的字节没骗人）" {
  let s = out_scene()
  let (_w, _h, pix) = psd_render(s, 24)
  let bytes = out_export(s)
  let info = run(s, "psd-info b64=\{@base64.encode(bytes)}")
  assert_true(info.contains("\"ok\":true"), msg=info)
  // 读回来的合成图（RGBA）必须与我们渲染的像素一字不差
  let want = @base.sha256_hex(Bytes::from_array(pix))
  let got = jstr_field(info, "composite_sha256")
  assert_eq(got, want)
  // 层数 = 根级层数（组 1 + 文本 1）
  assert_eq(jnum_field(info, "layers"), 2.0)
  assert_eq(jnum_field(info, "width"), 24.0)
  assert_eq(jnum_field(info, "height"), 18.0)
}

///|
test "导出 → 再导入 → 渲染：与原来逐位相同（PSD 里存的就是画面）" {
  let s = out_scene()
  let (_w, _h, before) = psd_render(s, 24)
  let bytes = out_export(s)
  // 换一个会话打开，确保不是"同一个会话里的缓存"
  let s2 = psd_session()
  let opened = psd_open(s2, @base64.encode(bytes))
  assert_true(opened.contains("\"ok\":true"), msg=opened)
  let (_w2, _h2, after) = psd_render(s2, 24)
  let (diff, maxd) = psd_pixel_diff(before, after)
  assert_true(diff == 0 && maxd == 0, msg="导出再导入后画面变了：\{diff} 字节不同、最大差 \{maxd}")
}

///|
test "导出：层表（名字/不透明度/可见性/混合）在文件里保真" {
  let s = out_scene()
  // ⚠️ 组上**改不了 blend**（命令面按 caps 拒：组 α=1 时渲染器不读它的 blend），
  // 所以混合模式用另一个根级层来验——判据要打在"能装进去的值"上
  let _ = run(s, "set-style g1 opacity=0.5")
  let _ = run(s, "add-rect x=16 y=10 w=6 h=6 fill=#22AA22FF name=滤色 id=r2")
  let _ = run(s, "set-style r2 blend=screen opacity=0.25")
  let bytes = out_export(s)
  let info = run(s, "psd-info b64=\{@base64.encode(bytes)}")
  let rows = psd_table_rows(info)
  assert_eq(rows.length(), 3)
  // 层序即渲染序：组在底、文本在中、滤色层在顶
  assert_eq(psd_table_str(info, 0, "name"), "g1")
  assert_eq(psd_table_str(info, 1, "name"), "字")
  assert_eq(psd_table_str(info, 2, "name"), "滤色")
  // 不透明度 0.5 → 128（四舍五入；PSD 是 8 位）
  assert_eq(psd_table_num(info, 0, "opacity"), 128.0)
  assert_eq(psd_table_str(info, 2, "blend"), "screen")
  assert_eq(psd_table_num(info, 2, "opacity"), 64.0)
  // 隐藏层：flags 写对了才读得回 false
  assert_eq(psd_table_bool(info, 1, "visible"), false)
  assert_eq(psd_table_bool(info, 0, "visible"), true)
  // 盒子是**画面自身的紧包围盒**（组覆盖两块形状，文本被蒙版裁过）：都必须在画布内
  assert_true(psd_table_num(info, 0, "w") > 0.0 && psd_table_num(info, 0, "w") <= 24.0, msg=info)
  assert_true(psd_table_num(info, 0, "h") > 0.0 && psd_table_num(info, 0, "h") <= 18.0, msg=info)
}

///|
test "导出：调整层 / 装了编辑表 / 超限画布三条都**明确拒绝**" {
  // ① 调整层：PSD 的调整层是另一套块格式，我们不假装能写
  let s = psd_session()
  let _ = run(s, "new 8 6 uuid=psd-out-refuse")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=6 fill=#112233FF")
  let _ = run(s, "add-adjust op=brightness value=0.2 name=亮一点 id=a1")
  let e0 = run(s, "export-psd-b64")
  assert_true(e0.contains("调整层"), msg=e0)
  assert_true(e0.contains("亮一点"), msg="拒绝理由要点名是哪一层：\{e0}")
  // 正控：删掉它就该写得出来（判据两头都咬）
  let _ = run(s, "delete a1")
  assert_true(run(s, "export-psd-b64").contains("\"ok\":true"), msg="删掉调整层后应能导出")

  // ② 装了 MVSL 编辑表：PSD 表达不了编辑表
  let s2 = psd_session()
  let _ = run(s2, "new 32 24 uuid=psd-out-mvsl")
  let _ = run(s2, "add-rect x=0 y=0 w=32 h=24 fill=#3366CCFF")
  let prog = @core.program_to_json(recolor_program([]))
  let set = run(s2, "mvsl-set \{b64_of(prog)}")
  assert_true(set.contains("\"ok\":true"), msg=set)
  let e1 = run(s2, "export-psd-b64")
  assert_true(e1.contains("编辑表"), msg=e1)
  // 清空后必须能导出（同一条判据的正控）
  let _ = run(s2, "mvsl-clear")
  assert_true(run(s2, "export-psd-b64").contains("\"ok\":true"), msg="清空编辑表后应能导出")

  // ③ 超限画布：只可能从容器进来（`new`/`set-canvas` 在入口就拒），
  //    但"能存却画不出来"的文档**真实存在**（本仓库旧版本存下的）
  let big = @core.new_document("psd-out-big", 5000, 200)
  let bytes = match @mpd.pack(@mpd.MpdDoc::new(big)) {
    Ok(b) => b
    Err(e) => abort("pack 失败：\{e}")
  }
  let s3 = psd_session()
  match @agent.load_mpd(s3, bytes) {
    Ok(_) => ()
    Err(e) => abort("超限容器必须打得开（用户要能 crop 自救）：\{e}")
  }
  let e2 = run(s3, "export-psd-b64")
  assert_true(e2.contains("4096"), msg="超限画布要回显可渲染上限：\{e2}")
}

///|
test "导出：没有墨的层写成 1×1 全透明（PSD 的通道数据不能是 0 字节）" {
  let s = psd_session()
  let _ = run(s, "new 6 5 uuid=psd-out-empty")
  let _ = run(s, "add-rect x=1 y=1 w=2 h=2 fill=#00AA00FF name=点 id=r1")
  // 一个空组：渲染器不画任何东西，但没有墨的层也要在 PSD 里有一格
  let _ = run(s, "group g1 r1")
  let _ = run(s, "group-remove g1 r1")
  let bytes = out_export(s)
  let info = run(s, "psd-info b64=\{@base64.encode(bytes)}")
  assert_eq(jnum_field(info, "layers"), 2.0)
  // `group-remove` 把成员落在**组的槽位上**（组的下一层）⇒ 根序 = [r1, 空组]
  assert_eq(psd_table_str(info, 0, "name"), "点")
  assert_eq(psd_table_num(info, 0, "w"), 2.0)
  // 空组读回来是 1×1（不是 0×0：读侧对非正盒子会报文件损坏）
  assert_eq(psd_table_num(info, 1, "w"), 1.0)
  assert_eq(psd_table_num(info, 1, "h"), 1.0)
  // 合成图仍然逐字节对得上（空层不许把画面改掉）
  let (_w, _h, pix) = psd_render(s, 6)
  assert_eq(jstr_field(info, "composite_sha256"), @base.sha256_hex(Bytes::from_array(pix)))
}
