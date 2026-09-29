/// 会话级端到端：vision 闸 → 建档 → 绘制 → 渲染 → pick/lint → undo/redo → 容器往返。

///|
fn run(s : @agent.Session, line : String) -> String {
  @agent.exec(s, line)
}

///|
test "vision 闸：未开门拒绝一切 / 非法声明拒绝 / full_image 通过" {
  let s = @agent.Session::new()
  // 未开门
  let r = run(s, "new 100 100")
  assert_true(r.has_prefix("{\"error\":\"vision 闸未通过"), msg=r)
  // 非法声明
  let r2 = run(s, "session-open text_only")
  assert_true(r2.has_prefix("{\"error\":\"vision 闸拒绝"), msg=r2)
  // 合法开门
  let r3 = run(s, "session-open full_image")
  assert_true(r3.has_prefix("{\"ok\":true,\"op\":\"session-open\""), msg=r3)
  // 开门后可用
  let r4 = run(s, "new 100 100")
  assert_true(r4.has_prefix("{\"ok\":true,\"op\":\"new\""), msg=r4)
}

///|
test "AgentGate 零容忍：坏参数精确报错且不落半截状态" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 100")
  // 非法颜色
  let r = run(s, "add-rect x=10 y=10 w=50 h=30 fill=#ZZZZZZ")
  assert_true(r.has_prefix("{\"error\":\"非法颜色"), msg=r)
  // 层未增加
  let ls = run(s, "list-layers")
  assert_true(ls.contains("\"count\":0"), msg=ls)
  // 非法 opacity
  let r2 = run(s, "add-rect x=0 y=0 w=10 h=10 opacity=1.5")
  assert_true(r2.has_prefix("{\"error\":\"opacity"), msg=r2)
  // 非法 blend
  let r3 = run(s, "add-rect x=0 y=0 w=10 h=10 blend=burn")
  assert_true(r3.has_prefix("{\"error\":\"未知混合模式"), msg=r3)
  // 层不存在
  let r4 = run(s, "move l9 10 10")
  assert_true(r4.has_prefix("{\"error\":\"层不存在"), msg=r4)
  // 未知命令
  let r5 = run(s, "fly-to-the-moon")
  assert_true(r5.has_prefix("{\"error\":\"未知命令"), msg=r5)
}

///|
test "端到端：绘制 → 渲染（可解码 PNG）→ pick → lint → undo/redo → 容器往返" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 300 200 uuid=demo-001")
  let r1 = run(s, "add-rect x=0 y=0 w=300 h=200 fill=#1B2A41FF name=bg tag=background")
  assert_true(r1.contains("\"id\":\"l1\""), msg=r1)
  let r2 = run(
    s,
    "add-ellipse x=100 y=40 w=100 h=100 lgrad=#FF7A45FF,#2E6FE8FF,0,0,1,1 blend=screen name=orb",
  )
  assert_true(r2.contains("\"id\":\"l2\""), msg=r2)
  let _ = run(s, "set-style l2 stroke=#FFFFFFCC stroke_w=3 opacity=0.9")
  let _ = run(s, "rotate l2 15")
  let _ = run(s, "add-line x=20 y=170 w=260 h=0 points=0,1;260,1 stroke=#33CC66FF stroke_w=4 name=baseline")
  let _ = run(s, "set-param palette.primary #FF7A45")
  // lint：0 违规
  let lint = run(s, "lint")
  assert_true(lint.contains("\"violations\":0"), msg=lint)
  // pick：椭圆中心 → l2；角落 → l1
  let p1 = run(s, "pick 150 90")
  assert_true(p1.contains("\"id\":\"l2\""), msg=p1)
  let p2 = run(s, "pick 10 10")
  assert_true(p2.contains("\"id\":\"l1\""), msg=p2)
  // render：b64 可解回 PNG，尺寸正确
  let rr = run(s, "render 300")
  assert_true(rr.contains("\"width\":300"), msg=rr)
  assert_true(rr.contains("\"render_sha256\":\""), msg=rr)
  // 从回包抠出 png_b64 解码验证（找到字段起点，取到下一个引号）
  let marker = "\"png_b64\":\""
  match rr.find(marker) {
    Some(start) => {
      let b64_start = start + marker.length()
      let mut end = b64_start
      while end < rr.length() && rr.get_char(end) != Some('"') {
        end = end + 1
      }
      let b64 = rr[b64_start:end].to_owned()
      let png : Bytes = @base64.decode(b64) catch {
        _ => abort("render b64 解码失败")
      }
      match @codec.png_decode(png) {
        Ok(img) => {
          assert_eq(img.width, 300)
          assert_eq(img.height, 200)
        }
        Err(e) => abort("render 输出不是合法 PNG: \{e}")
      }
    }
    None => abort("回包缺 png_b64")
  }
  // 指纹链
  let f1 = run(s, "fingerprint")
  // undo（撤销 set-param）→ 指纹变化
  let u = run(s, "undo")
  assert_true(u.has_prefix("{\"ok\":true,\"op\":\"undo\""), msg=u)
  let f2 = run(s, "fingerprint")
  assert_true(f1 != f2)
  // redo → 回到 f1
  let rd = run(s, "redo")
  assert_true(rd.has_prefix("{\"ok\":true,\"op\":\"redo\""), msg=rd)
  let f3 = run(s, "fingerprint")
  assert_eq(f3, f1)
  // 容器往返：save → open → 指纹一致
  let saved = run(s, "save-mpd-b64")
  let marker2 = "\"mpd_b64\":\""
  match saved.find(marker2) {
    Some(start) => {
      let b64_start = start + marker2.length()
      let mut end = b64_start
      while end < saved.length() && saved.get_char(end) != Some('"') {
        end = end + 1
      }
      let b64 = saved[b64_start:end].to_owned()
      let opened = run(s, "open-mpd-b64 \{b64}")
      assert_true(opened.contains("\"fingerprint\":\""), msg=opened)
      // 打开后指纹与保存前一致（同一文档状态）
      let f4 = run(s, "fingerprint")
      assert_eq(f4, f3)
    }
    None => abort("save 回包缺 mpd_b64")
  }
}

///|
test "编组/解组往返 + 层级操作" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 200")
  let _ = run(s, "add-rect x=0 y=0 w=100 h=100 id=a")
  let _ = run(s, "add-rect x=0 y=0 w=100 h=100 id=b")
  let _ = run(s, "add-rect x=0 y=0 w=100 h=100 id=c")
  // 编组 a、c（根级）
  let g = run(s, "group g1 a c")
  assert_true(g.contains("\"members\":2"), msg=g)
  // 组内查询
  let q = run(s, "query-layer g1")
  assert_true(q.contains("\"children\":["), msg=q)
  assert_true(q.contains("\"id\":\"a\""), msg=q)
  // 解组恢复
  let ug = run(s, "ungroup g1")
  assert_true(ug.contains("\"restored\":2"), msg=ug)
  let ls = run(s, "list-layers")
  assert_true(ls.contains("\"count\":3"), msg=ls)
  // reorder：c 置顶后 pick 顶层命中
  let _ = run(s, "reorder c front")
  let p = run(s, "pick 50 50")
  assert_true(p.contains("\"id\":\"c\""), msg=p)
  // delete + undo
  let _ = run(s, "delete c")
  let p2 = run(s, "pick 50 50")
  assert_true(p2.contains("\"id\":\"b\""), msg=p2)
  let _ = run(s, "undo")
  let p3 = run(s, "pick 50 50")
  assert_true(p3.contains("\"id\":\"c\""), msg=p3)
}

///|
test "add-image：资产登记 + 指纹入链 + lint 通过" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 120 90")
  // 构造 4x3 纯色 PNG
  let img = @codec.rgba_new(4, 3)
  @codec.fill_rect_rgba(img, 0, 0, 4, 3, @codec.color_from_hex("#CC3366"))
  let b64 = @base64.encode(@codec.png_encode(img))
  let r = run(s, "add-image x=40 y=20 w=40 h=30 b64=\{b64} name=badge")
  assert_true(r.contains("\"op\":\"add-image\""), msg=r)
  assert_true(r.contains("\"asset\":\""), msg=r)
  assert_true(r.contains("\"asset_size\":\"4x3\""), msg=r)
  let lint = run(s, "lint")
  assert_true(lint.contains("\"violations\":0"), msg=lint)
  // pick 命中图片层
  let p = run(s, "pick 60 35")
  assert_true(p.contains("\"id\":\"l1\""), msg=p)
}

///|
test "list-tools 与 help 输出工具字典" {
  let s = @agent.Session::new()
  let r = run(s, "list-tools")
  assert_true(r.contains("\"name\":\"add-rect\""), msg=r)
  assert_true(r.contains("\"name\":\"save-mpd-b64\""), msg=r)
  let h = run(s, "help")
  assert_true(h.contains("\"op\":\"help\""), msg=h)
  assert_eq(@agent.list_tools().length() >= 30, true)
}

///|
test "inspect：元参数层实时视图（manifest/design/params/edits）" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 100 80 uuid=inspect-e2e")
  let _ = run(s, "add-rect x=0 y=0 w=100 h=80 fill=#223344FF name=bg tag=background")
  let _ = run(s, "set-param palette.primary #FF7A45")
  let r = run(s, "inspect")
  assert_true(r.contains("\"op\":\"inspect\""), msg=r)
  assert_true(r.contains("\"format\":\"moonpainter.mpd\""), msg=r)
  assert_true(r.contains("moonpainter.doc"), msg=r) // design.json 全文内嵌
  assert_true(r.contains("palette.primary"), msg=r)
  assert_true(r.contains("\"counts\":{\"layers\":1,"), msg=r)
  // 未建档时 inspect 报错（与其它命令一致）
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let r2 = run(s2, "inspect")
  assert_true(r2.has_prefix("{\"error\":\"尚未创建文档"), msg=r2)
}
