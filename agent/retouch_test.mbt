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
