/// 修图操作测试：画笔/橡皮擦/裁剪/取色/像素滤镜/JSON 往返。
/// （run() 辅助复用 session_test.mbt 同包定义。）

///|
test "画笔：add-paint + brush 落点可见、sample 取色命中笔色、坏参数零容忍" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 200 uuid=brush-test")
  let rp = run(s, "add-paint name=涂鸦")
  assert_true(rp.contains("\"op\":\"add-paint\""), msg=rp)
  // 底色白
  let rs0 = run(s, "sample 100 100")
  assert_true(rs0.contains("#FFFFFFFF"), msg=rs0)
  // 画一笔（过 100,100）
  let rb = run(s, "brush layer=l1 pts=40,100;160,100 r=10 color=#FF0000FF")
  assert_true(rb.contains("\"op\":\"brush\""), msg=rb)
  let rs1 = run(s, "sample 100 100")
  assert_true(rs1.contains("#FF0000"), msg=rs1)
  // 非法：非 raster 层落笔 / 层不存在 / 半径越界 / 坏颜色
  let e1 = run(s, "brush layer=l9 pts=0,0;5,5 r=4")
  assert_true(e1.has_prefix("{\"error\":\"层不存在"), msg=e1)
  let e2 = run(s, "brush layer=l1 pts=0,0;5,5 r=0")
  assert_true(e2.has_prefix("{\"error\":\"r 越界"), msg=e2)
  let e3 = run(s, "brush layer=l1 pts=0,0;5,5 r=4 color=#GGGGGG")
  assert_true(e3.has_prefix("{\"error\":\"非法颜色"), msg=e3)
}

///|
test "橡皮擦：destination-out 擦除后采样点透出下层" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 200 uuid=erase-test")
  let _ = run(s, "add-rect x=0 y=0 w=200 h=200 fill=#0000FFFF name=bg")
  let _ = run(s, "add-paint name=笔层")
  let _ = run(s, "brush layer=l2 pts=100,100;120,100 r=20 color=#FFFFFFFF")
  let mid = run(s, "sample 110 100")
  assert_true(mid.contains("#FFFFFF"), msg=mid)
  // 擦掉同一点
  let re = run(s, "erase layer=l2 pts=110,100;110,100 r=15")
  assert_true(re.contains("\"op\":\"erase\""), msg=re)
  let after = run(s, "sample 110 100")
  // 透出蓝色底层（alpha 归一后 RGB 回蓝）
  assert_true(after.contains("#0000FF"), msg=after)
}

///|
test "裁剪：画布收窄 + 层同步平移 + 越界拒绝 + undo 恢复" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 400 300 uuid=crop-test")
  let _ = run(s, "add-rect x=100 y=50 w=200 h=150 fill=#FF0000FF name=块")
  let fp0 = run(s, "fingerprint")
  let rc = run(s, "crop 50 25 200 150")
  assert_true(rc.contains("\"op\":\"crop\""), msg=rc)
  assert_true(rc.contains("\"width\":200"), msg=rc)
  // 层平移：100-50=50, 50-25=25
  let q = run(s, "query-layer l1")
  assert_true(q.contains("\"x\":50") && q.contains("\"y\":25"), msg=q)
  // 越界拒绝
  let e1 = run(s, "crop 0 0 500 100")
  assert_true(e1.has_prefix("{\"error\":\"裁剪区域"), msg=e1)
  let e2 = run(s, "crop -5 0 100 100")
  assert_true(e2.has_prefix("{\"error\":\"裁剪区域"), msg=e2)
  // undo 恢复
  let _ = run(s, "undo")
  let fp1 = run(s, "fingerprint")
  assert_eq(fp0, fp1)
}

///|
test "像素滤镜：新调整算子全通过且渲染可解码" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 160 120 uuid=filter-test")
  let _ = run(s, "add-rect x=0 y=0 w=160 h=120 fill=#CC8844FF name=底")
  for op in ["blur", "sharpen", "smooth", "whiten", "warm", "vignette"] {
    let r = run(s, "add-adjust op=\{op} value=0.5")
    assert_true(r.contains("\"op\":\"add-adjust\""), msg=r)
  }
  // 未知算子拒绝
  let e = run(s, "add-adjust op=deep-fry value=1")
  assert_true(e.has_prefix("{\"error\":\"未知调整算子"), msg=e)
  let rr = run(s, "render 160")
  assert_true(rr.contains("\"png_b64\""), msg=rr)
}

///|
test "dab 与新调整算子的 canonical JSON 往返：指纹稳定" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 150 uuid=rt")
  let _ = run(s, "add-paint")
  let _ = run(s, "brush layer=l1 pts=10,10;100,60 r=8 color=#123456AA")
  let _ = run(s, "add-adjust op=vignette value=0.6")
  let fp0 = run(s, "fingerprint")
  let insp = run(s, "inspect")
  assert_true(insp.contains("\"raster\""), msg="inspect 应含 raster 层")
  assert_true(insp.contains("vignette"), msg="inspect 应含 vignette 调整")
  // save → open 字节往返 → 指纹一致
  let saved = run(s, "save-mpd-b64")
  let marker = "\"mpd_b64\":\""
  match saved.find(marker) {
    Some(start) => {
      let b64_start = start + marker.length()
      let mut end = b64_start
      while end < saved.length() && saved.get_char(end) != Some('"') {
        end = end + 1
      }
      let b64 = saved[b64_start:end].to_owned()
      let _ = run(s, "undo")
      let _ = run(s, "undo")
      let opened = run(s, "open-mpd-b64 \{b64}")
      assert_true(opened.has_prefix("{\"ok\":true,\"op\":\"open-mpd-b64\""), msg=opened)
      assert_eq(run(s, "fingerprint"), fp0)
    }
    None => abort("save 回包缺 mpd_b64")
  }
}

///|
test "undo：一笔一快照，undo 后笔触消失" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 200 uuid=undo-brush")
  let _ = run(s, "add-paint")
  let _ = run(s, "brush layer=l1 pts=50,50;150,50 r=10 color=#00FF00FF")
  let with_stroke = run(s, "sample 100 50")
  assert_true(with_stroke.contains("#00FF00"), msg=with_stroke)
  let _ = run(s, "undo")
  let after_undo = run(s, "sample 100 50")
  assert_true(after_undo.contains("#FFFFFF"), msg=after_undo)
}

///|
test "画笔坐标是画布坐标：层被 move 后落笔仍落在点击处" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 300 300 uuid=coord-test")
  let _ = run(s, "add-paint")
  // 画笔层平移 (50,40)
  let _ = run(s, "move l1 50 40")
  // 在画布坐标 (100,100) 落点
  let _ = run(s, "brush layer=l1 pts=100,100;100,100 r=10 color=#FF0000FF")
  let r = run(s, "sample 100 100")
  assert_true(r.contains("#FF0000"), msg=r)
  // 层的盒子**跟着落笔走**（PLAN 六十）：`query-layer` 报的是这一笔的范围
  // (90,90,20,20) = 点击处 (100,100) ± 半径 10，不再是 `add-paint` 那份
  // 300×300 的画布快照（此前 `query-layer` 会把整幅画布报成一支小笔迹的尺寸）。
  // 这同时**证明了 dab 存的是局部偏移**：x = 50（层位）+ 50（dab 局部）− 10（半径）
  // ——若 dab 存的是画布坐标 (100,100)，这里会是 50+100−10 = 140。
  assert_eq(gmove_layer_num(s, "l1", "x"), 90.0, msg="盒子 x = 层位 + dab 局部 − 半径")
  assert_eq(gmove_layer_num(s, "l1", "y"), 90.0, msg="盒子 y")
  assert_eq(gmove_layer_num(s, "l1", "w"), 20.0, msg="盒子宽 = 2×半径（一支圆头笔迹）")
  assert_eq(gmove_layer_num(s, "l1", "h"), 20.0, msg="盒子高")
}

///|
test "set-adjust：原地改值不丢层序，且调整层必须报得出 op/value" {
  // 调整层**整个层就由 op+value 定义**，此前 query-layer/list-layers 两者
  // 都不报——两个不同的调整层长得一模一样，调用方无法回读。
  // 而且只有 add-adjust：想微调只能删了重加，重加会推到栈顶，
  // 于是"只改数值"变成"连作用范围也变了"（调整层作用于其下全部可见层）。
  let s = scene("set-adjust")
  // value 用 0.3（原先写 1.3 —— **越界**，而当时入口不校验范围）。
  let _ = run(s, "add-adjust op=brightness value=0.3")
  let q0 = run(s, "query-layer l2")
  assert_true(q0.contains("brightness"), msg="调整层要报出算子：\{q0}")
  assert_true(q0.contains("0.3"), msg="调整层要报出数值：\{q0}")
  // 在它上面再压一层，制造"层序会被破坏"的场景
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF name=top")
  let before = run(s, "list-layers")
  assert_true(before.contains("l2"), msg=before)
  // 原地改值
  let r = run(s, "set-adjust l2 value=-0.5")
  assert_true(!r.contains("error"), msg=r)
  let q1 = run(s, "query-layer l2")
  assert_true(q1.contains("-0.5"), msg="值要改掉：\{q1}")
  assert_true(q1.contains("brightness"), msg="没给 op 时要沿用原算子：\{q1}")
  // 只给 op 时 value 保留
  let _ = run(s, "set-adjust l2 op=contrast")
  let q2 = run(s, "query-layer l2")
  assert_true(q2.contains("contrast"), msg="算子要改掉：\{q2}")
  assert_true(q2.contains("-0.5"), msg="没给 value 时要沿用原值：\{q2}")
  // **层序不变**：l2 仍在 l3 之前（删除重加会把它挪到末尾）
  let after = run(s, "list-layers")
  let i2 = after.find("l2").unwrap_or(-1)
  let i3 = after.find("l3").unwrap_or(-1)
  assert_true(i2 >= 0 && i3 >= 0, msg=after)
  assert_true(i2 < i3, msg="调整层必须留在原位（删除重加会挪到栈顶）：\{after}")
  // 边界：什么都不给 / 非调整层 / 不存在
  assert_true(run(s, "set-adjust l2").contains("至少要给"), msg="空参数要拒绝")
  assert_true(run(s, "set-adjust l1 value=0.5").contains("不是调整层"), msg="非调整层要拒绝")
  assert_true(run(s, "set-adjust l1").contains("不是调整层"), msg="非调整层要拒绝")
}

test "调整算子的取值契约：越界与「用不上的 value」都拒绝（双向）" {
  // 此前字典只有一句 `value=<-1..1>`，而它对一半算子是错的：
  // blur/sharpen/smooth/whiten/vignette 是 0..1，invert/grayscale 压根不读
  // value。三种静默收下都实测到了：
  //   ①`value=99` 被 brightness 内部 clamp —— 画面与 value=1.0 **逐位相同**，
  //     而指纹不同（两张"不同"的文档渲染一模一样，没有任何信号）；
  //   ②`op=invert value=0.5` 回 ok 而 0.5 被丢掉；
  //   ③`op=brightness`（不给 value）建出 value=0 的空操作层，lint 报 0 违规。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF name=A")
  // ① 越界：两端都要拒，且报出范围
  let hi = run(s, "add-adjust op=brightness value=99")
  assert_true(hi.contains("超出"), msg=hi)
  assert_true(hi.contains("[-1..1]"), msg="越界要报出范围：\{hi}")
  let lo = run(s, "add-adjust op=warm value=-3")
  assert_true(lo.contains("超出"), msg=lo)
  // 0..1 的算子给 -0.1 也要拒（别把两类算子混成一个范围）
  let neg = run(s, "add-adjust op=blur value=-0.1")
  assert_true(neg.contains("超出"), msg=neg)
  // ② 无值算子不接受 value=
  let iv = run(s, "add-adjust op=invert value=0.5")
  assert_true(iv.contains("不接受 value="), msg=iv)
  assert_true(iv.contains("不读 value"), msg="要说清为什么：\{iv}")
  // ③ 有值算子不给 value 要拒（否则建出空操作层）
  let nov = run(s, "add-adjust op=brightness")
  assert_true(nov.contains("需要 value="), msg=nov)
  assert_true(nov.contains("什么都不干"), msg="要说清后果：\{nov}")
  // **正控**：合法输入一个都不许被拒（判据要两头都咬得住）
  assert_true(!run(s, "add-adjust op=brightness value=1").contains("error"), msg="边界 1 要收")
  assert_true(!run(s, "add-adjust op=warm value=-1").contains("error"), msg="边界 -1 要收")
  assert_true(!run(s, "add-adjust op=blur value=1").contains("error"), msg="0..1 的边界 1 要收")
  assert_true(!run(s, "add-adjust op=blur value=0").contains("error"), msg="0..1 的边界 0 要收")
  assert_true(!run(s, "add-adjust op=invert").contains("error"), msg="无值算子不给 value 要收")
  assert_true(!run(s, "add-adjust op=grayscale").contains("error"), msg="同上")
  assert_true(!run(s, "add-adjust op=saturation value=0.5").contains("error"), msg="普通值要收")
  // 未知算子的清单从 core.all_adjust_ops 生成（含范围），不再手写
  let unk = run(s, "add-adjust op=deep-fry value=1")
  assert_true(unk.contains("未知调整算子"), msg=unk)
  assert_true(unk.contains("brightness=[-1..1]"), msg="清单要带范围：\{unk}")
  assert_true(unk.contains("invert（无数值）"), msg="无值算子要标出来：\{unk}")
  // set-adjust 走同一张表：给无值算子传 value 也要拒（此前静默丢掉）
  let inv = run(s, "add-adjust op=invert id=inv")
  assert_true(!inv.contains("error"), msg=inv)
  let bad = run(s, "set-adjust inv value=0.5")
  assert_true(bad.contains("不接受 value="), msg=bad)
  // 只改算子到有值算子：不许凭空塞 value=（否则会被自己的规则打回）
  let to_b = run(s, "set-adjust inv op=brightness")
  assert_true(to_b.contains("需要 value=") || !to_b.contains("error"), msg=to_b)
  // 反向：从有值算子改到无值算子，value 要**被丢掉**而不是残留
  let _ = run(s, "add-adjust op=brightness value=0.4 id=br")
  let back = run(s, "set-adjust br op=invert")
  assert_true(!back.contains("error"), msg=back)
  let q = run(s, "query-layer br")
  assert_true(q.contains("invert"), msg=q)
  assert_true(q.contains("\"value\":0"), msg="改成无值算子后 value 要归零：\{q}")
}

test "lint 兜住调整层的三种「装了不干活」（命令面拦两种，第三种只有 lint 会说）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF name=A")
  // 正控：正常调整层一个字都不报
  let _ = run(s, "add-adjust op=brightness value=0.5")
  let ok = run(s, "lint")
  assert_true(ok.contains("\"violations\":0"), msg="正常调整层不该报：\{ok}")
  // 第三种：value=0 的空操作层（命令面**不拦**——调到 0 是合法操作）
  let _ = run(s, "set-adjust l2 value=0")
  let r = run(s, "lint")
  assert_true(r.contains("noop 调整层"), msg="value=0 要报空操作：\{r}")
  assert_true(r.contains("value=0"), msg=r)
  // 手改容器：直接构造那种状态（命令面已拦，这里兜住外部/手改的容器）
  let doc = @core.new_document("lint-adj-oob", 32, 32)
  let dl = @core.default_layer("d1", "hand-edited", 0.0, 0.0, 20.0, 20.0)
  doc.layers.push({
    ..dl,
    kind: @core.ShapeKind::Adjust,
    adjust: Some({ op: @core.AdjustOp::Brightness, value: 99.0 }),
  })
  let text = (@agent.lint_doc(doc)).join(" | ")
  assert_true(text.contains("超出"), msg="手改的越界值要报：\{text}")
  // 手改容器：给无值算子存了非零 value（渲染器不读它，纯粹改指纹）
  let doc2 = @core.new_document("lint-adj-dead", 32, 32)
  let dl2 = @core.default_layer("d1", "hand-edited", 0.0, 0.0, 20.0, 20.0)
  doc2.layers.push({
    ..dl2,
    kind: @core.ShapeKind::Adjust,
    adjust: Some({ op: @core.AdjustOp::Invert, value: 0.5 }),
  })
  let text2 = (@agent.lint_doc(doc2)).join(" | ")
  assert_true(text2.contains("不接受数值"), msg="手改的用不上的 value 要报：\{text2}")
}

test "lint 兜住手改容器里的退化蒙版（入口拒绝什么，lint 必须报什么）" {
  // 蒙版参数的命令面已拦（`add-mask`/`set-mask` 共用 `@core.mask_param_error`），
  // 这里兜住**手改 design.json / 旧版本产物**。三条都是"给了参数但不生效"：
  //   ①尺寸非正：覆盖区为空 → invert=false 时整层被悄悄藏掉；
  //   ②③④负的 radius/feather/roughen：渲染器各自折成 0，画面与"没给"一样，
  //        而指纹变了、query-layer 也照旧报出来。
  let doc = @core.new_document("lint-mask-deg", 32, 32)
  let dl = @core.default_layer("d1", "hand-edited", 0.0, 0.0, 20.0, 20.0)
  let ok : @core.LayerMask = {
    kind: @core.ShapeKind::Rect,
    x: 0.0,
    y: 0.0,
    w: 10.0,
    h: 10.0,
    radius: 2.0,
    feather: 1.0,
    roughen: 1.0,
    invert: false,
    points: [],
  }
  doc.layers.push({ ..dl, mask: Some(ok) })
  // 正控：正常蒙版一个字都不报（判据两头都要咬得住）
  let t0 = (@agent.lint_doc(doc)).join(" | ")
  assert_true(!t0.contains("mask"), msg="正常蒙版不该报：\{t0}")
  // ① 尺寸非正
  doc.layers[0] = { ..doc.layers[0], mask: Some({ ..ok, w: 0.0 }) }
  let t1 = (@agent.lint_doc(doc)).join(" | ")
  assert_true(t1.contains("mask 层 d1"), msg="退化蒙版要报：\{t1}")
  assert_true(t1.contains("尺寸"), msg="要说清是尺寸问题：\{t1}")
  assert_true(t1.contains("w=0"), msg="要带上实际收到的值：\{t1}")
  // ②③④ 三个负参数（错误里要带上字段名，值也报出来）
  doc.layers[0] = { ..doc.layers[0], mask: Some({ ..ok, radius: 0.0 - 1.0 }) }
  assert_true((@agent.lint_doc(doc)).join(" | ").contains("radius"), msg="负 radius 要报")
  doc.layers[0] = { ..doc.layers[0], mask: Some({ ..ok, feather: 0.0 - 2.0 }) }
  assert_true((@agent.lint_doc(doc)).join(" | ").contains("feather"), msg="负 feather 要报")
  doc.layers[0] = { ..doc.layers[0], mask: Some({ ..ok, roughen: 0.0 - 3.5 }) }
  let t4 = (@agent.lint_doc(doc)).join(" | ")
  assert_true(t4.contains("roughen"), msg="负 roughen 要报：\{t4}")
  assert_true(t4.contains("-3.5"), msg="错误要带上实际值（不只字段名）：\{t4}")
}

test "数值参数的「值面」第六批：非数与越界都不许静默退默认" {
  // 上一轮推平了调整算子的 value（越界 / 用不上的 value）。这里问同一件事的
  // 另一半：**笔宽与字号**，以及"给了但根本不是数"这种输入。
  // 实测（修前）：
  //   set-style l1 stroke_w=-3   → ok，写进 JSON、改指纹、query-layer 报得出来，
  //                                而 inside_stroke 第一句就把 ≤0 折成 0 → 描边一个像素不画
  //   add-text font_size=-3      → ok，建出 -5.14x-3 的**负尺寸**层（只有 lint 说话）
  //   add-text font_size=abc     → ok，**静默按 16**（同一个函数里 w/h/x/y 四兄弟一样）
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 40")
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#FF0000FF")
  // 笔宽：两种给法（stroke= + stroke_w=、只给 stroke_w=）都要拒
  let a = run(s, "set-style l1 stroke_w=-3")
  assert_true(a.contains("stroke_w 不能为负"), msg=a)
  let b = run(s, "set-style l1 stroke=#0000FFFF stroke_w=-1")
  assert_true(b.contains("stroke_w 不能为负"), msg=b)
  // **正控**：stroke_w=0（不画描边）与正值都要收
  assert_true(!run(s, "set-style l1 stroke_w=0").contains("error"), msg="0 要收")
  assert_true(!run(s, "set-style l1 stroke_w=2.5").contains("error"), msg="正值要收")
  // 字号：非正与非数都拒
  let c = run(s, "add-text x=0 y=0 text=Hi font_size=0")
  assert_true(c.contains("font_size 必须为正"), msg=c)
  let d = run(s, "add-text x=0 y=0 text=Hi font_size=-3")
  assert_true(d.contains("font_size 必须为正"), msg=d)
  let e = run(s, "add-text x=0 y=0 text=Hi font_size=abc")
  assert_true(e.contains("不是数字"), msg=e)
  // 同一个函数的 w/h/x/y 也是非数即拒（此前静默退成默认值）
  assert_true(run(s, "add-text x=0 y=0 text=Hi w=abc").contains("不是数字"), msg="w=abc")
  assert_true(run(s, "add-text x=0 y=0 text=Hi h=abc").contains("不是数字"), msg="h=abc")
  assert_true(run(s, "add-text x=abc y=0 text=Hi").contains("不是数字"), msg="x=abc")
  assert_true(run(s, "add-text x=0 y=abc text=Hi").contains("不是数字"), msg="y=abc")
  // **正控**：不给 w/h 时按 6px/字符 × 字高估算占位盒（有意的默认，不是静默）
  let okw = run(s, "add-text x=0 y=0 text=Hi id=t9")
  assert_true(!okw.contains("error"), msg="不给 w/h 要能建层：\{okw}")
  let q = run(s, "query-layer t9")
  // 咬数值：2 字符 × 16px × 6/7 ≈ 27.43，高就是字号
  assert_true(q.contains("\"w\":27.4"), msg="估算盒宽度要咬住数值：\{q}")
  assert_true(q.contains("\"h\":16"), msg="估算盒高度 = 字号：\{q}")
  // 边界写清楚：**显式** w=0 不是"估算"，而是 w/h 必须为正
  assert_true(
    run(s, "add-text x=0 y=0 text=Hi w=0 id=t10").contains("w/h 必须为正"),
    msg="显式 w=0 归 build_shape_layer 的正数校验管",
  )
  // lint 兜住手改容器：负笔宽与非正字号
  let doc = @core.new_document("lint-num", 32, 32)
  let l = @core.default_layer("n1", "hand", 0.0, 0.0, 20.0, 20.0)
  doc.layers.push({ ..l, stroke: { color: 0xFF0000FF, width: -2.0 } })
  let t1 = (@agent.lint_doc(doc)).join(" | ")
  assert_true(t1.contains("stroke_w 为负"), msg="手改的负笔宽要报：\{t1}")
  let doc2 = @core.new_document("lint-num2", 32, 32)
  let l2 = @core.default_layer("n2", "hand", 0.0, 0.0, 20.0, 20.0)
  doc2.layers.push({ ..l2, kind: @core.ShapeKind::Text, text: "Hi", font_size: 0.0 })
  let t2 = (@agent.lint_doc(doc2)).join(" | ")
  assert_true(t2.contains("font_size 非正"), msg="手改的非正字号要报：\{t2}")
}

test "set-text：字号改得动，盒子跟着内容走（改得动吗 + 报得准吗）" {
  // 三件事此前都不成立：
  //  ① 字号只能 add-text 定 —— 想改大一点只能删了重加（层被推到栈顶、
  //     蒙版/标签/透明度全丢），同 set-adjust / set-mask 那条"改得动吗"纪律；
  //  ② set-text 只换文字**不动盒子** —— add-text text=Hi（盒子 27.43）之后
  //     set-text 成 "Hello World"，渲染器把 11 个字全画出来（实测两种建法
  //     render sha256 逐位相同），而 query-layer 仍报 w=27.43；
  //  ③ 于是层报出来的范围装不下自己的像素：pick 拾不到、overlay 线框画小了、
  //     lgrad 的归一化端点算错。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 20")
  let _ = run(s, "add-text x=0 y=0 text=Hi id=t1")
  assert_true(run(s, "query-layer t1").contains("\"w\":27.4"), msg="初始盒子 = 2×16×6/7")
  // ①+② 改内容：盒子涨到 11×16×6/7
  let a = run(s, "set-text t1 \"Hello World\"")
  assert_true(!a.contains("error"), msg=a)
  let q1 = run(s, "query-layer t1")
  assert_true(q1.contains("\"w\":150.8"), msg="盒子要跟着内容走：\{q1}")
  assert_true(q1.contains("\"h\":16"), msg="高仍是字号：\{q1}")
  // ① 改字号：盒子按新字号重算（2×32×6/7 = 54.86）
  let b = run(s, "set-text t1 Hi font_size=32")
  assert_true(!b.contains("error"), msg=b)
  let q2 = run(s, "query-layer t1")
  assert_true(q2.contains("\"w\":54.8"), msg="字号变了盒子要重算：\{q2}")
  assert_true(q2.contains("\"h\":32"), msg="高 = 新字号：\{q2}")
  assert_true(q2.contains("\"font_size\":32"), msg="字号要报得出来：\{q2}")
  // 范围：非正与非数都拒（与 add-text 同一条规则）
  assert_true(run(s, "set-text t1 Hi font_size=0").contains("font_size 必须为正"), msg="0")
  assert_true(run(s, "set-text t1 Hi font_size=-2").contains("font_size 必须为正"), msg="-2")
  assert_true(run(s, "set-text t1 Hi font_size=abc").contains("不是数字"), msg="abc")
  // 显式盒子：给了就用给的（必须为正），不给就重算
  let c = run(s, "set-text t1 Hi w=100 h=20")
  assert_true(!c.contains("error"), msg=c)
  let q3 = run(s, "query-layer t1")
  assert_true(q3.contains("\"w\":100"), msg="显式盒子要生效：\{q3}")
  assert_true(q3.contains("\"h\":20"), msg="显式盒子要生效：\{q3}")
  assert_true(run(s, "set-text t1 Hi w=0").contains("w/h 必须为正"), msg="w=0")
  assert_true(run(s, "set-text t1 Hi h=-1").contains("w/h 必须为正"), msg="h=-1")
  // 不认识的键：报合法清单（字典是 LLM 唯一的说明书）
  let e = run(s, "set-text t1 Hi bogus=1")
  assert_true(e.contains("font_size/w/h"), msg="要报出认得的键：\{e}")
  // 清空文字仍是合法写法，且不会因为盒子归零而误报文字装不下
  assert_true(!run(s, "set-text t1 \"\"").contains("error"), msg="清空合法")
  // **正控**：空文字的盒子归零，不该被"装不下自己的文字"误报（那是"空文本层"
  // 那条规则的活）。判据的空集也要说话。
  let docz = @core.new_document("empty-text", 64, 64)
  let lz = @core.default_layer("z1", "hand", 0.0, 0.0, 0.0, 16.0)
  docz.layers.push({ ..lz, kind: @core.ShapeKind::Text, text: "", font_size: 16.0 })
  let tz = (@agent.lint_doc(docz)).join(" | ")
  assert_true(!tz.contains("装不下自己的文字"), msg="空文字不该报'装不下'：\{tz}")
  // lint 兜住手改容器 / resize 缩小：盒子装不下自己的文字
  let doc = @core.new_document("stale-box", 64, 64)
  let l = @core.default_layer("x1", "hand", 0.0, 0.0, 27.428571428571427, 16.0)
  doc.layers.push({ ..l, kind: @core.ShapeKind::Text, text: "Hello World", font_size: 16.0 })
  let t = (@agent.lint_doc(doc)).join(" | ")
  assert_true(t.contains("装不下自己的文字"), msg="手改的窄盒子要报：\{t}")
  // **正控**：同一层把盒子给足，lint 一个字都不报（漏报与误报都是 bug）
  let doc2 = @core.new_document("ok-box", 64, 64)
  let l2 = @core.default_layer("x2", "hand", 0.0, 0.0, 150.85714285714286, 16.0)
  doc2.layers.push({ ..l2, kind: @core.ShapeKind::Text, text: "Hello World", font_size: 16.0 })
  let t2 = (@agent.lint_doc(doc2)).join(" | ")
  assert_true(!t2.contains("装不下自己的文字"), msg="盒子够大不该报：\{t2}")
}

test "lint 兜住「顶点落在渲染窗外」：判据与渲染窗同一把尺子（不许比它严）" {
  // 渲染器只在保守渲染窗里落像素（对角线为边 + 2px 松弛），窗**比盒子大**。
  // 于是"顶点出盒"本身不是错，只有出**窗**才是真的画不出来 —— 判据若拿盒子
  // 当尺子就会误报，拿窗外当尺子才是与渲染器一致。
  let mk = fn(pts : Array[(Double, Double)], w : Double, h : Double) {
    let doc = @core.new_document("win", 60, 60)
    let l = @core.default_layer("g1", "g1", 0.0, 0.0, w, h)
    doc.layers.push({ ..l, kind: @core.ShapeKind::Polygon, points: pts })
    doc
  }
  // ① 顶点伸到 50（10×10 盒的窗只到 x≤14）→ 报
  let far = mk([(0.0, 0.0), (50.0, 0.0), (50.0, 50.0)], 10.0, 10.0).layers[0]
  let d1 = @core.new_document("far", 60, 60)
  d1.layers.push(far)
  let j1 = (@agent.lint_doc(d1)).join(" | ")
  assert_true(j1.contains("渲染窗外"), msg="窗外顶点要报：\{j1}")
  // ② **正控**：顶点到 13 —— 出盒（10×10）但在窗内（窗 = [-4,14]²），
  //    那里**真的有墨**（实测 probe 13,2 非白），一个都不许报
  let d2 = mk([(0.0, 0.0), (13.0, 0.0), (13.0, 13.0)], 10.0, 10.0)
  let j2 = (@agent.lint_doc(d2)).join(" | ")
  assert_true(!j2.contains("渲染窗外"), msg="盒外窗内不该报：\{j2}")
  // ③ **正控**：正常顶点（都在盒内）不报；旋转层同样不报（要经 to_canvas 换算）
  let d3 = mk([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0)], 10.0, 10.0)
  assert_true(!(@agent.lint_doc(d3)).join(" | ").contains("渲染窗外"), msg="盒内不报")
  let d4 = mk([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0)], 10.0, 10.0)
  d4.layers[0] = { ..d4.layers[0], rotation_deg: 45.0, flip_h: true }
  assert_true(!(@agent.lint_doc(d4)).join(" | ").contains("渲染窗外"), msg="旋转+翻转也不许误报")
  // ④ 线段同样管（它的笔触也只在窗内落像素）
  let d5 = @core.new_document("line", 60, 60)
  let ln = @core.default_layer("g1", "g1", 0.0, 0.0, 10.0, 10.0)
  d5.layers.push({ ..ln, kind: @core.ShapeKind::Line, points: [(0.0, 0.0), (200.0, 5.0)] })
  let j5 = (@agent.lint_doc(d5)).join(" | ")
  assert_true(j5.contains("渲染窗外"), msg="线段的窗外顶点要报：\{j5}")
}

test "顶点改得动：set-style points= 原地改，蒙版/标签/层序都不丢（改得动吗）" {
  // 此前顶点只能在建层时给（`set-style p1 points=…` 报"建完没有改顶点的命令"），
  // 想改一个三角形的顶点只能删了重加 —— 而重加把层推到栈顶，蒙版/标签/
  // 透明度/层序全丢。同 set-text / set-adjust 那条纪律。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 60")
  let _ = run(s, "add-rect x=0 y=0 w=60 h=60 fill=#000000FF id=bg")
  let _ = run(s, "add-polygon x=0 y=0 w=40 h=40 points=0,0;40,0;40,40 fill=#FF0000FF id=p1")
  // 给这层挂上"重加就会丢"的东西：蒙版 + 标签 + 非默认透明度 + 名称
  let _ = run(s, "add-mask p1 kind=ellipse x=0 y=0 w=30 h=30 invert=true")
  let _ = run(s, "tag p1 hero")
  let _ = run(s, "set-style p1 opacity=0.5 name=Tri")
  let before = run(s, "query-layer p1")
  assert_true(before.contains("\"points\":[[0,0],[40,0],[40,40]]"), msg=before)
  assert_true(before.contains("hero"), msg=before)
  // ① 改顶点：原地改，全部附带状态还在
  let a = run(s, "set-style p1 points=0,0;20,0;20,20")
  assert_true(!a.contains("error"), msg=a)
  let after = run(s, "query-layer p1")
  assert_true(after.contains("\"points\":[[0,0],[20,0],[20,20]]"), msg="顶点要真的换掉：\{after}")
  assert_true(after.contains("hero"), msg="标签不能丢：\{after}")
  assert_true(after.contains("0.5"), msg="透明度不能丢：\{after}")
  assert_true(after.contains("invert"), msg="蒙版不能丢：\{after}")
  // 层序也不能变（层还是第 2 个；重加会跑到最后）
  let ls = run(s, "list-layers")
  let ib = ls.find("bg").unwrap_or(-1)
  let ip = ls.find("p1").unwrap_or(-1)
  assert_true(ib >= 0 && ip > ib, msg="层序不能变：\{ls}")
  // ② 改顶点要真的到像素：渲染 sha 必须变（"改成功了吗"的三个信号里最硬的那个）
  let sh1 = run(s, "render 60")
  let _ = run(s, "set-style p1 points=0,0;40,0;40,40")
  let sh2 = run(s, "render 60")
  assert_true(sh1 != sh2, msg="顶点改了画面必须变")
  // ③ 线段也改得动（默认对角线 → 自定义折线）
  let _ = run(s, "add-line x=0 y=0 w=40 h=40 id=l1")
  let b = run(s, "set-style l1 points=0,0;0,40;40,40")
  assert_true(!b.contains("error"), msg=b)
  assert_true(run(s, "query-layer l1").contains("[[0,0],[0,40],[40,40]]"), msg="线段顶点要换掉")
  // ④ 非 polygon/line 上写 points 是死数据（写进 JSON、改指纹、画面不变）→ 入口拒
  let r = run(s, "set-style bg points=1,1;2,2;3,3")
  assert_true(r.contains("只对polygon/line有意义"), msg="矩形要拒：\{r}")
  let e = run(s, "set-style bg points=0,0;1")
  assert_true(e.contains("只对polygon/line有意义"), msg="种类检查要在形态检查之前（同一句话）：\{e}")
}

test "顶点数不足 = 什么都不画：入口拒 + lint 兜（判据的空集也要说话）" {
  // 实测 `add-polygon w=40 h=40 points=0,0;40,40` 回 ok、`lint` 报 0 违规，
  // 而渲染器 `in_polygon` 第一句就是 `if pts.length() < 3 { return false }`
  // —— 一个像素都不落，只有"指纹变了"这一个信号在说"改过了"。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 60")
  let a = run(s, "add-polygon x=0 y=0 w=40 h=40 points=0,0;40,40 id=p2")
  assert_true(a.contains("至少要 3 个顶点"), msg="2 顶点的多边形要拒：\{a}")
  assert_true(run(s, "add-line x=0 y=0 w=40 h=40 points=0,0 id=l1").contains("至少 2 个顶点"), msg="1 顶点的线要拒")
  // 根本不给 points 的 polygon：入口也要拒（0 顶点同样是"什么都不画"）
  let nop = run(s, "add-polygon x=0 y=0 w=40 h=40 id=p0")
  assert_true(nop.contains("至少要 3 个顶点") && nop.contains("0 个 = 什么都不画"), msg="不给顶点要拒：\{nop}")
  // 正控：不给 points 的 line 合法（默认对角线）
  assert_true(!run(s, "add-line x=0 y=0 w=40 h=40 id=l0").contains("error"), msg="line 的默认对角线要保留")
  // 非数顶点同样不许静默（parse_points 走 to_d，一律报错）
  assert_true(run(s, "add-polygon x=0 y=0 w=40 h=40 points=0,0;x,0;1,1 id=p3").contains("不是数字"), msg="非数顶点")
  assert_true(run(s, "add-polygon x=0 y=0 w=40 h=40 points=0,0;1 id=p4").contains("x,y 形态"), msg="形态错")
  // lint 兜住手改容器（命令面进不去的状态）
  let mk = fn(pts : Array[(Double, Double)], kind : @core.ShapeKind) {
    let doc = @core.new_document("few", 60, 60)
    let l = @core.default_layer("g1", "g1", 0.0, 0.0, 40.0, 40.0)
    doc.layers.push({ ..l, kind, points: pts })
    doc
  }
  // lint 与命令面**同一句**说明（`points_count_error`），所以断言咬数值：
  // "至少要 N 个顶点" + "n 个 = 什么都不画"
  let j1 = (@agent.lint_doc(mk([(0.0, 0.0), (40.0, 40.0)], @core.ShapeKind::Polygon))).join(" | ")
  assert_true(j1.contains("至少要 3 个顶点") && j1.contains("2 个 = 什么都不画"), msg="2 顶点多边形要报：\{j1}")
  let j2 = (@agent.lint_doc(mk([(0.0, 0.0)], @core.ShapeKind::Line))).join(" | ")
  assert_true(j2.contains("至少要 2 个顶点") && j2.contains("1 个 = 什么都不画"), msg="1 顶点线段要报：\{j2}")
  // **正控**：够数的顶点一个都不许报（漏报与误报都是 bug）
  let j3 = (@agent.lint_doc(mk([(0.0, 0.0), (40.0, 0.0), (0.0, 40.0)], @core.ShapeKind::Polygon))).join(" | ")
  assert_true(!j3.contains("顶点只有"), msg="3 顶点多边形不该报：\{j3}")
  let j4 = (@agent.lint_doc(mk([(0.0, 0.0), (40.0, 40.0)], @core.ShapeKind::Line))).join(" | ")
  assert_true(!j4.contains("顶点只有"), msg="2 顶点线段不该报：\{j4}")
  // 空的顶点表（0 个）也要报——判据的空集也要说话
  let j5 = (@agent.lint_doc(mk([], @core.ShapeKind::Polygon))).join(" | ")
  assert_true(j5.contains("0 个 = 什么都不画"), msg="0 顶点要报：\{j5}")
  // **正控**：矩形/椭圆/文本层不用顶点定义形状，不该被这条规则误报
  let j6 = (@agent.lint_doc(mk([], @core.ShapeKind::Rect))).join(" | ")
  assert_true(!j6.contains("个顶点才画得出东西"), msg="矩形不该被顶点规则误报：\{j6}")
}

test "标签下得来：untag 摘一个/清空，画面与别的状态逐位不动（改得动吗·标签面）" {
  // 此前标签**只增不减**：`tag=` 与 `tag` 都只会追加，`set-style tags=` 不认，
  // 也没有 untag。打错一个标签只能删层重加 —— 层被推到栈顶，蒙版/翻转/
  // 透明度/层序/id 引用全丢（同 set-adjust / set-text / set-style points 那条）。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 60")
  let _ = run(s, "add-rect x=0 y=0 w=60 h=60 fill=#000000FF id=bg")
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#FF0000FF id=a tag=sky")
  // 挂上"重加就会丢"的东西：蒙版（带 invert，好逐字比对）+ 翻转 + 非默认透明度
  let _ = run(s, "add-mask a kind=ellipse x=0 y=0 w=16 h=16 invert=true")
  let _ = run(s, "flip a h")
  let _ = run(s, "set-style a opacity=0.5")
  // 打标签：幂等要**直答**（`added`），不许让调用方靠比指纹才发现什么都没变
  let t1 = run(s, "tag a hero")
  assert_true(t1.contains("\"added\":true"), msg="第一次要报 added:true：\{t1}")
  let t2 = run(s, "tag a hero")
  assert_true(t2.contains("\"added\":false"), msg="重复打要报 added:false：\{t2}")
  let q1 = run(s, "query-layer a")
  assert_true(q1.contains("\"tags\":[\"sky\",\"hero\"]"), msg="两个标签都要在：\{q1}")
  let px1 = run(s, "render 60")
  // ① 摘一个：回包说清摘掉几个、还剩什么
  let u1 = run(s, "untag a hero")
  assert_true(u1.contains("\"op\":\"untag\""), msg=u1)
  assert_true(u1.contains("\"removed\":1"), msg="removed 要咬住数值：\{u1}")
  assert_true(u1.contains("\"tags\":[\"sky\"]"), msg="回包要报剩下的标签：\{u1}")
  let q2 = run(s, "query-layer a")
  assert_true(q2.contains("\"tags\":[\"sky\"]"), msg="标签要真的少一个：\{q2}")
  assert_true(q2.contains("\"flip_h\":true"), msg="翻转不能丢：\{q2}")
  assert_true(q2.contains("\"opacity\":0.5"), msg="透明度不能丢：\{q2}")
  assert_true(q2.contains("invert"), msg="蒙版不能丢：\{q2}")
  let ls = run(s, "list-layers")
  // 用 `"id":"…"` 精确锚，别用裸层名：`ls.find("a")` 会先命中 JSON 里的 "layers"
  let ib = ls.find("\"id\":\"bg\"").unwrap_or(-1)
  let ia = ls.find("\"id\":\"a\"").unwrap_or(-1)
  assert_true(ib >= 0 && ia > ib, msg="层序不能变：\{ls}")
  // 标签是**元数据**：摘掉它画面逐位不动（与"改顶点/改文字"那条刚好相反，
  // 这也是"标签当前不参与渲染、也不参与选择子"的机器证据）。
  // 比的是 `render_sha256`（像素），**不是整个回包**——回包里的 fingerprint
  // 按定义就该变（标签进 canonical JSON）。第一版直接比整串，红得对。
  let px2 = run(s, "render 60")
  assert_true(
    jfield(px1, "render_sha256") == jfield(px2, "render_sha256"),
    msg="摘标签不该动画面：\{jfield(px1, "render_sha256")} vs \{jfield(px2, "render_sha256")}",
  )
  assert_true(
    jfield(px1, "fingerprint") != jfield(px2, "fingerprint"),
    msg="标签进 canonical JSON，指纹按定义要变（否则说明摘标签什么都没做）",
  )
  // ② 清空：`*` 一次摘光，removed 说得准
  let u2 = run(s, "untag a *")
  assert_true(u2.contains("\"removed\":1"), msg=u2)
  assert_true(u2.contains("\"tags\":[]"), msg=u2)
  let q3 = run(s, "query-layer a")
  assert_true(!q3.contains("\"tags\""), msg="清空后不该再报 tags：\{q3}")
  // ③ 没得摘就不许静默成功（同 remove-param 那条纪律：静默成功会让调用方以为摘掉了）
  let e1 = run(s, "untag a sky")
  assert_true(e1.contains("没有任何标签"), msg=e1)
  let _ = run(s, "tag a hero")
  let e2 = run(s, "untag a sky")
  assert_true(e2.contains("没有标签 sky"), msg=e2)
  assert_true(e2.contains("现有：hero"), msg="报错要说清现在有什么：\{e2}")
  // ④ 层不存在 / 用法下界 / 空标签 / `*` 不是合法的标签名
  let e3 = run(s, "untag nosuch sky")
  assert_true(e3.contains("层不存在"), msg=e3)
  let e4 = run(s, "untag a")
  assert_true(e4.contains("用法：untag"), msg=e4)
  let e5 = run(s, "tag a \"\"")
  assert_true(e5.contains("不能是空串"), msg="空标签打不上：\{e5}")
  let e6 = run(s, "tag a *")
  assert_true(e6.contains("保留给 untag"), msg="`*` 不许当标签名：\{e6}")
  let e7 = run(s, "untag a \"\"")
  assert_true(e7.contains("不能是空串"), msg=e7)
  // **正控**：普通名字（点/下划线/横线）打得上也摘得下 —— "能打上的名字都必须能摘下"
  let _ = run(s, "tag a bg.sky_layer-2")
  assert_true(run(s, "query-layer a").contains("bg.sky_layer-2"), msg="正控：普通名字要打得上")
  let u3 = run(s, "untag a bg.sky_layer-2")
  assert_true(u3.contains("\"removed\":1"), msg=u3)
  assert_true(run(s, "query-layer a").contains("\"tags\":[\"hero\"]"), msg="正控：摘完只剩 hero")
}

test "remove-mask：层不存在 / 没有蒙版都要报错（remove-* 家族不许静默成功）" {
  // `remove-param` 早就写着"不存在就明确报错，不静默成功——静默成功会让调用方
  // 以为删掉了"，而它的兄弟 `remove-mask` 既不查层也不查蒙版：`remove-mask typo`
  // 回 ok、指纹不变。同一个家族一条纪律。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 40")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=40 id=r")
  let e1 = run(s, "remove-mask r")
  assert_true(e1.contains("本来就没有蒙版"), msg=e1)
  let e2 = run(s, "remove-mask nosuch")
  assert_true(e2.contains("层不存在"), msg=e2)
  let e3 = run(s, "remove-mask")
  assert_true(e3.contains("用法：remove-mask"), msg=e3)
  // 正控：加了蒙版就删得掉，删完再删又是"没有蒙版"
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10")
  let ok = run(s, "remove-mask r")
  assert_true(ok.contains("\"op\":\"remove-mask\""), msg=ok)
  let e4 = run(s, "remove-mask r")
  assert_true(e4.contains("本来就没有蒙版"), msg=e4)
}
///|
test "仿制图章：命令面收下克隆笔触、报告面报得出源偏移、坏参数零容忍" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 200 uuid=clone-test")
  let _ = run(s, "add-rect x=20 y=20 w=40 h=40 fill=#FF0000FF id=src")
  let _ = run(s, "add-paint id=retouch")
  // 源锚点 (40,40)（红块里）、第一个落点 (140,60) ⇒ 偏移 (-100,-20)
  let rc = run(s, "clone layer=retouch pts=140,60;160,60 r=10 src=40,40")
  assert_true(rc.contains("\"op\":\"clone\""), msg=rc)
  // 段长 20、spacing = r*0.45 = 4.5 ⇒ 段内 4 个点 + 末点 = 5 个 dab
  assert_eq(jnum_field(rc, "dabs"), 5.0, msg=rc)
  // 报告面：笔触数、克隆笔数、第一笔的源偏移（画布向量）
  // 报告面：笔触数 / 克隆笔数 / 第一笔的源偏移都在 `layer` 里（值用**精确文本**
  // 锚住，别用 `contains("clone_dabs")` 那种只看字段名的写法）
  let q = run(s, "query-layer retouch")
  assert_true(q.contains("\"dabs\":5,"), msg=q)
  assert_true(q.contains("\"clone_dabs\":5,"), msg="整笔都是克隆笔：" + q)
  assert_true(q.contains("\"clone_off\":[-100,-20]"), msg="源偏移必须报得出来：" + q)
  // 非克隆笔触不许被报成克隆（负控：否则上面两条对"全都报成克隆"也成立）
  let _ = run(s, "add-paint id=plain")
  // ⚠️ 落笔的 pts 有"至少 2 个顶点"的下界（画得出线），单点会被拒
  let _ = run(s, "brush layer=plain pts=30,30;60,30 r=6 color=#000000FF")
  let qp = run(s, "query-layer plain")
  // 段长 30、spacing = 2.7 ⇒ 段内 11 个点 + 末点 = 12 个 dab。
  // 锚点要连**紧跟其后的字符**一起锚：这层的 `dabs` 是最后一个字段（后面是 `}`），
  // 没有克隆字段时它后面不会是逗号——写成 `"dabs":12,` 就是一个永远为假的锚。
  assert_true(qp.contains("\"dabs\":12}"), msg=qp)
  assert_true(!qp.contains("clone_dabs"), msg="普通笔触不许报出克隆字段：" + qp)
  // 克隆真的改画面（不是收了不干活）：取色处从白变成红块的颜色
  let before = run(s, "sample 140 60")
  assert_true(before.contains("#FF0000") || before.contains("#FF000"), msg=before)
  // 坏参数：缺 src / src 越界 / 源与落点重合 / 非 raster 层 / 认不出的键。
  // ⚠️ `pts` 自己有"至少 2 个顶点"的下界，坏参数用例必须给合法 pts——
  // 不然测到的是那条下界（报的话与被测的参数不是一回事）。
  let e1 = run(s, "clone layer=retouch pts=10,10;20,10 r=4")
  assert_true(e1.has_prefix("{\"error\":\"clone 需要 src=x,y"), msg=e1)
  let e2 = run(s, "clone layer=retouch pts=10,10;20,10 r=4 src=999,10")
  assert_true(e2.has_prefix("{\"error\":\"源锚点 (999,10) 超出画布"), msg=e2)
  let e3 = run(s, "clone layer=retouch pts=10,10;20,10 r=4 src=10,10")
  assert_true(e3.has_prefix("{\"error\":\"源锚点与第一个落点重合"), msg=e3)
  let e4 = run(s, "clone layer=src pts=10,10;20,10 r=4 src=20,20")
  assert_true(e4.has_prefix("{\"error\":\"层 src 不是画笔层"), msg=e4)
  let e5 = run(s, "clone layer=retouch pts=10,10;20,10 r=4 src=20,20 color=#FF0000FF")
  assert_true(e5.has_prefix("{\"error\":\"clone：不认识的参数"), msg=e5)
  assert_true(
    e5.contains("layer/pts/r/src"),
    msg="拒绝时必须报出**认得的**键清单（否则调用方只能猜）：" + e5,
  )
  // 正控：同样的形状、去掉 color 就必须收下（否则上面那条对"clone 什么都不收"也成立）
  let ok = run(s, "clone layer=retouch pts=10,10;20,10 r=4 src=20,20")
  assert_true(ok.contains("\"op\":\"clone\""), msg=ok)
}

///|
///|
test "lint 兜住三种克隆笔触的装法（命令面给不出来的那些）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 120 uuid=clone-lint")
  let _ = run(s, "add-rect x=10 y=10 w=40 h=40 fill=#FF0000FF id=src")
  let _ = run(s, "add-paint id=p")
  let _ = run(s, "clone layer=p pts=80,80;100,80 r=6 src=30,30")
  // 正控：命令面造出来的克隆笔触，lint 一个字都不该说
  let ok = run(s, "lint")
  assert_true(ok.contains("\"violations\":0"), msg="正当的克隆笔触不该被 lint 报：" + ok)
  // ①手改容器：非克隆笔触带源偏移（渲染器不读 ⇒ 画面不变而指纹变了）
  let doc = match s.doc {
    Some(d) => d
    None => abort("没有文档")
  }
  let d = @core.Dab::{
    x: 20.0,
    y: 20.0,
    r: 4.0,
    color: 0xFF0000FF,
    erase: false,
    clone: false,
    sdx: -9.0,
    sdy: 0.0,
  }
  doc.layers[1] = { ..doc.layers[1], dabs: [d] }
  let r1 = run(s, "lint")
  assert_true(r1.contains("不是克隆却带着源偏移"), msg=r1)
  // ②手改容器：克隆笔触的取样窗完全在画布外（那一笔什么都不落）
  let d2 = @core.Dab::{
    x: 20.0,
    y: 20.0,
    r: 4.0,
    color: 0x00000000,
    erase: false,
    clone: true,
    sdx: 500.0,
    sdy: 500.0,
  }
  doc.layers[1] = { ..doc.layers[1], dabs: [d2] }
  let r2 = run(s, "lint")
  assert_true(r2.contains("取样窗完全在画布外"), msg=r2)
  // ③把层放进 α<1 的组：取样源变成"组自己那张画面"（P3 说清，不拦）
  let d3 = @core.Dab::{
    x: 20.0,
    y: 20.0,
    r: 4.0,
    color: 0x00000000,
    erase: false,
    clone: true,
    sdx: -9.0,
    sdy: -9.0,
  }
  doc.layers[1] = { ..doc.layers[1], dabs: [d3] }
  // `group <gid> <id>…`（组 id 是显式给的）
  let rg = run(s, "group g1 p")
  assert_true(rg.contains("\"ok\":true"), msg=rg)
  let _ = run(s, "set-style g1 opacity=0.4")
  let r3 = run(s, "lint")
  assert_true(r3.contains("P3 caveat"), msg=r3)
  assert_true(r3.contains("组自己那张画面"), msg="要说清画成什么：" + r3)
}
