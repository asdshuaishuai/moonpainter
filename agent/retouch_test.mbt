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
  // dab 实际存储为局部坐标 (50,60)
  let q = run(s, "query-layer l1")
  assert_true(q.contains("\"x\":50"), msg=q)
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
