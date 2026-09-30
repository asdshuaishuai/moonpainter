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

///|
test "文本层：add-text/set-text 命令 + 渲染像素可检出" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 100")
  let r = run(s, "add-text x=10 y=40 text=HELLO font_size=28 id=title")
  assert_true(r.contains("\"op\":\"add-text\""), msg=r)
  // 点阵字形渲染：画布上应有黑色像素（文本 H..O 均为黑）
  let env = @render.RenderEnv::new()
  let buf = @render.render_doc(unwrap_doc(s), env)
  let mut dark = 0
  let total = buf.width * buf.height
  let mut i = 0
  while i < total {
    let p = buf.pixels[i]
    let lum = ((p >> 16) & 0xFF)
    if lum < 128 && ((p >> 24) & 0xFF) > 0 {
      dark = dark + 1
    }
    i = i + 1
  }
  assert_true(dark > 0, msg="文本应渲染出非背景像素")
  // set-text 修改内容 → 指纹变化
  let f1 = run(s, "fingerprint")
  let r2 = run(s, "set-text title WORLD")
  assert_true(r2.contains("\"op\":\"set-text\""), msg=r2)
  let f2 = run(s, "fingerprint")
  assert_true(f1 != f2)
  // undo → 回到 HELLO
  let _ = run(s, "undo")
  let q = run(s, "query-layer title")
  assert_true(q.contains("HELLO"), msg=q)
}

///|
test "调整层：add-adjust 作用于下层合成 + 非法算子拒绝" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 8 8")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000 id=red")
  // 反相调整层置于栈顶 → 红变青
  let r = run(s, "add-adjust op=invert id=inv")
  assert_true(r.contains("\"op\":\"add-adjust\""), msg=r)
  let env = @render.RenderEnv::new()
  let buf = @render.render_doc(unwrap_doc(s), env)
  let p = @codec.rgba_get(buf, 4, 4)
  // 红 FF0000 反相 → 00FFFF
  assert_eq(p & 0x00FFFFFF, 0x00FFFF)
  // 亮度 +0.5：中灰 → 灰度 ~191
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let _ = run(s2, "new 4 4")
  let _ = run(s2, "add-rect x=0 y=0 w=4 h=4 fill=#808080")
  let _ = run(s2, "add-adjust op=brightness value=0.25")
  let buf2 = @render.render_doc(unwrap_doc(s2), env)
  let p2 = @codec.rgba_get(buf2, 2, 2)
  let g = (p2 >> 8) & 0xFF
  assert_true(g >= 180 && g <= 200, msg="亮度后灰度=\{g}")
  // 非法算子拒绝
  let bad = run(s2, "add-adjust op=vibrance")
  assert_true(bad.has_prefix("{\"error\":\"未知调整算子"), msg=bad)
}

///|
test "蒙版：rect 蒙版裁剪 + invert 反选 + remove-mask 还原" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 20 20")
  // 白底 + 全画布红层 + 蒙版只留左半（蒙版外透出白底）
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#FFFFFFFF id=bg")
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#FF0000 id=r")
  let env = @render.RenderEnv::new()
  let before = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(before, 5, 10), 0xFFFF0000)
  assert_eq(@codec.rgba_get(before, 15, 10), 0xFFFF0000)
  let rm = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=20")
  assert_true(rm.contains("\"op\":\"add-mask\""), msg=rm)
  let masked = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(masked, 5, 10), 0xFFFF0000) // 蒙版内保留
  assert_eq(@codec.rgba_get(masked, 15, 10), 0xFFFFFFFF) // 蒙版外变白底
  // invert：反选 → 右半保留
  let _ = run(s, "set-mask r invert=true")
  let inverted = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(inverted, 15, 10), 0xFFFF0000)
  assert_eq(@codec.rgba_get(inverted, 5, 10), 0xFFFFFFFF) // 反选后左半透出白底
  // 椭圆蒙版 + remove 还原
  let _ = run(s, "remove-mask r")
  let m2 = run(s, "add-mask r kind=ellipse x=0 y=0 w=20 h=20")
  assert_true(m2.contains("\"op\":\"add-mask\""), msg=m2)
  let ell = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(ell, 19, 0), 0xFFFFFFFF) // 椭圆外角点被裁
  let _ = run(s, "remove-mask r")
  let restored = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(restored, 5, 10), 0xFFFF0000)
  assert_eq(@codec.rgba_get(restored, 15, 10), 0xFFFF0000)
}

///|
/// 测试辅助：提取会话当前文档（供直接走 render 驱动断言像素）。
fn unwrap_doc(s : @agent.Session) -> @core.Document {
  match s.doc {
    Some(d) => d
    None => @core.new_document("empty", 1, 1)
  }
}


///|
test "自由文本的空格：引号包裹，下划线保持字面（一个用户可见的旧 bug）" {
  // 协议里原本写着"下划线代替空格"——它写在 `add-text` 的错误提示里，
  // 前端 `do_text_add` 也真的把空格换成了下划线，**但引擎从不还原**：
  // 用户输入 "Hello World"，存进去、渲染出来都是 "Hello_World"。
  // 现在用引号分词，含空格不必再牺牲下划线。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 100")
  let r = run(s, "add-text x=4 y=4 text=\"Hello World\" font_size=20 id=t1")
  assert_true(r.contains("\"op\":\"add-text\""), msg=r)
  let q = run(s, "query-layer t1")
  assert_true(q.contains("\"text\":\"Hello World\""), msg=q)
  // 没有引号时 `_` 仍是**字面下划线**：历史行为不变，向后兼容。
  let r2 = run(s, "add-text x=4 y=40 text=Hello_World font_size=20 id=t2")
  assert_true(r2.contains("\"op\":\"add-text\""), msg=r2)
  let q2 = run(s, "query-layer t2")
  assert_true(q2.contains("\"text\":\"Hello_World\""), msg=q2)
  // 图层名同样吃引号（它曾经也只能靠下划线，同样没被还原）
  let r3 = run(s, "add-rect x=0 y=0 w=8 h=8 name=\"My Layer\" id=box")
  assert_true(r3.contains("\"op\":\"add-rect\""), msg=r3)
  let q3 = run(s, "query-layer box")
  assert_true(q3.contains("\"name\":\"My Layer\""), msg=q3)
  // set-text 也走同一套分词
  let r4 = run(s, "set-text t2 \"Now With Spaces\"")
  assert_true(r4.contains("\"op\":\"set-text\""), msg=r4)
  let q4 = run(s, "query-layer t2")
  assert_true(q4.contains("\"text\":\"Now With Spaces\""), msg=q4)
  // 引号内的 \" 是字面引号
  let r5 = run(s, "set-text t2 \"say \\\"hi\\\"\"")
  assert_true(r5.contains("\"op\":\"set-text\""), msg=r5)
  let q5 = run(s, "query-layer t2")
  assert_true(q5.contains("\"text\":\"say \\\"hi\\\"\""), msg=q5)
}


///|
test "set-mask 只改 invert：几何参数必须被拒绝，不许静默无效" {
  // 这里曾经静默接受任何 tokens[2]（认不出 `true`/`1`/`invert=true` 就当
  // false）。于是照旧字典传 `set-mask r x=0 y=10 w=20 h=10` 会**什么都不改
  // 却返回 ok**（指纹一字未变），还会把原有的 invert 重置掉。
  // 铁律 3：不支持就报明确错误，不降级、不糊弄。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 20")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=20 fill=#FF0000FF id=r")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20")
  // 几何参数被拒绝，且错误里指路正确做法
  let bad = run(s, "set-mask r x=0 y=10 w=40 h=10")
  assert_true(bad.contains("\"error\""), msg="几何参数应被拒绝，实际：\{bad}")
  assert_true(bad.contains("remove-mask"), msg="错误应指路 remove-mask + add-mask：\{bad}")
  // 被拒绝的调用不该留下编辑历史（快照在校验之后）
  let before = run(s, "edits")
  let _ = run(s, "set-mask r w=1")
  let after = run(s, "edits")
  assert_eq(after, before, msg="被拒绝的 set-mask 不该留下编辑历史")
  // 真正的 invert 仍能改，且 query-layer 看得到（可观测性）
  let ok = run(s, "set-mask r true")
  assert_true(ok.contains("\"op\":\"set-mask\""), msg=ok)
  let q = run(s, "query-layer r")
  assert_true(q.contains("\"invert\":true"), msg="query-layer 应报告蒙版 invert：\{q}")
  // add-mask 的几何也要能被看见
  assert_true(q.contains("\"mask\":{\"kind\":\"rect\""), msg="query-layer 应报告蒙版几何：\{q}")
}


///|
test "蒙版反选的读-改-写往返（前端「蒙版反选」按钮依赖的两步）" {
  // 引擎没有 toggle 命令，所以前端的反选按钮只能：先 query-layer 读
  // `mask.invert`，再 set-mask 写反值。这条把那条路在引擎侧锁住——
  // 前端读不到或写不进，按钮就是坏的，而那种坏**编译不报错**。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 20")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=20 fill=#FF0000FF id=r")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20")
  // 1) 读得到初始值
  let q0 = run(s, "query-layer r")
  assert_true(q0.contains("\"invert\":false"), msg="应读得到 invert 初值：\{q0}")
  // 2) 写反值 → 读回来是反的
  let _ = run(s, "set-mask r true")
  let q1 = run(s, "query-layer r")
  assert_true(q1.contains("\"invert\":true"), msg=q1)
  // 3) 再反一次 → 回到原值（一个完整的 toggle 往返）
  let _ = run(s, "set-mask r false")
  let q2 = run(s, "query-layer r")
  assert_true(q2.contains("\"invert\":false"), msg=q2)
  // 4) 去蒙版后 query-layer 上不再有 mask 字段（前端据此把标记撤掉）
  let _ = run(s, "remove-mask r")
  let q3 = run(s, "query-layer r")
  assert_true(!q3.contains("\"mask\""), msg="去蒙版后不该再报 mask：\{q3}")
}

///|
test "蒙版圆角：radius 真的切掉四角（曾经是存了不用的死参数）" {
  // `radius` 曾经**存了、报了、序列化了，但渲染时完全没读**：写 radius=10
  // 得到的是硬直角，而且**不报错**——这正是它藏了这么久的原因（用户看不出
  // "圆角没生效"和"圆角很小"的区别）。这条从命令面一路断到渲染像素。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 20 20")
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#FF0000FF id=r")
  let env = @render.RenderEnv::new()
  // 无 radius：四角都在蒙版内（硬直角）
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10")
  let hard = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(hard, 0, 0), 0xFFFF0000)
  assert_eq(@codec.rgba_get(hard, 9, 9), 0xFFFF0000)
  // radius=5（半边长，等价内切圆）：四角被切掉，中心与边中点保留
  let _ = run(s, "remove-mask r")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10 radius=5")
  let round = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(round, 0, 0), 0xFFFFFFFF) // 左上角被切
  assert_eq(@codec.rgba_get(round, 9, 0), 0xFFFFFFFF) // 右上角被切
  assert_eq(@codec.rgba_get(round, 0, 9), 0xFFFFFFFF)
  assert_eq(@codec.rgba_get(round, 9, 9), 0xFFFFFFFF)
  assert_eq(@codec.rgba_get(round, 5, 5), 0xFFFF0000) // 中心保留
  assert_eq(@codec.rgba_get(round, 5, 0), 0xFFFF0000) // 边中点保留（圆角不该啃到边中）
  assert_eq(@codec.rgba_get(round, 0, 5), 0xFFFF0000)
  // 圆角之外的区域不受影响
  assert_eq(@codec.rgba_get(round, 15, 15), 0xFFFFFFFF)
  // 坏 radius 不再静默变 0（原先 radius=abc 悄悄当 0、radius=-5 也收下）
  let e1 = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10 radius=abc")
  assert_true(e1.contains("radius=abc 不是数字"), msg=e1)
  let e2 = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10 radius=-5")
  assert_true(e2.contains("不能为负"), msg=e2)
  // 椭圆蒙版不吃 radius（kind 上就没这个语义），给了也不该改变结果
  let _ = run(s, "remove-mask r")
  let _ = run(s, "add-mask r kind=ellipse x=0 y=0 w=10 h=10")
  let ell = @render.render_doc(unwrap_doc(s), env)
  let _ = run(s, "remove-mask r")
  let _ = run(s, "add-mask r kind=ellipse x=0 y=0 w=10 h=10 radius=5")
  let ell_r = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(ell_r, 0, 0), @codec.rgba_get(ell, 0, 0))
  assert_eq(@codec.rgba_get(ell_r, 5, 5), @codec.rgba_get(ell, 5, 5))
}

///|
test "蒙版羽化：feather 按内距线性过渡，0 时仍是硬边" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 40")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=40 fill=#FF0000FF id=r")
  let env = @render.RenderEnv::new()
  // feather=0（默认）：硬边，(1,1) 已是满覆盖
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20")
  let hard = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(hard, 1, 1), 0xFFFF0000)
  // feather=4：内距 1/2/3/4 → 覆盖 0.25/0.5/0.75/1.0
  // （红 25/50/75/100% 压在白底上 → 255×0.75=191、×0.5=127、×0.25=64）
  let _ = run(s, "remove-mask r")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20 feather=4")
  let soft = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(soft, 1, 1), 0xFFFFBFBF) // 覆盖 0.25
  assert_eq(@codec.rgba_get(soft, 2, 2), 0xFFFF7F7F) // 覆盖 0.50
  assert_eq(@codec.rgba_get(soft, 3, 3), 0xFFFF4040) // 覆盖 0.75
  assert_eq(@codec.rgba_get(soft, 4, 4), 0xFFFF0000) // 覆盖 1.00（内距达 feather）
  assert_eq(@codec.rgba_get(soft, 10, 10), 0xFFFF0000) // 深处仍是满覆盖
  assert_eq(@codec.rgba_get(soft, 25, 25), 0xFFFFFFFF) // 蒙版外仍完全不渲染
  // 羽化只影响边界带：远离边界的区域与 hard 完全一致
  assert_eq(@codec.rgba_get(soft, 15, 15), @codec.rgba_get(hard, 15, 15))
  // 反选后过渡带跟着反向：覆盖度 = 1 − 原覆盖度
  let _ = run(s, "set-mask r invert=true")
  let inv = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(inv, 1, 1), 0xFFFF4040) // 1−0.25 = 0.75
  assert_eq(@codec.rgba_get(inv, 4, 4), 0xFFFFFFFF) // 1−1.00 = 0（原满覆盖处全透）
  assert_eq(@codec.rgba_get(inv, 25, 25), 0xFFFF0000) // 原蒙版外反而满覆盖
  // 坏 feather 不再静默变 0
  let e1 = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10 feather=abc")
  assert_true(e1.contains("feather=abc 不是数字"), msg=e1)
  let e2 = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=10 feather=-1")
  assert_true(e2.contains("不能为负"), msg=e2)
}

///|
test "填充色自带的 alpha 从命令面一路生效" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 24 20")
  let env = @render.RenderEnv::new()
  // 50% 红压白底 → #FF7F7F
  let _ = run(s, "add-rect x=0 y=0 w=24 h=20 fill=#FF000080 id=r")
  assert_eq(
    @codec.rgba_get(@render.render_doc(unwrap_doc(s), env), 10, 10),
    0xFFFF7F7F,
  )
  // 同色 50% 再叠一层 → 1−0.5² = 0.75 → #FF3F3F
  let _ = run(s, "add-rect x=0 y=0 w=24 h=20 fill=#FF000080 id=r2")
  assert_eq(
    @codec.rgba_get(@render.render_doc(unwrap_doc(s), env), 10, 10),
    0xFFFF3F3F,
  )
}

///|
test "add-text 的显式 fill 不再被写死的黑色盖掉" {
  // 此前 `cmd_add_text` 无条件 `fill: Solid(0xFF000000)`，把
  // `build_shape_layer`（内部走 `apply_style_kv`）已经解析好的用户 fill
  // 覆盖掉了：`add-text ... fill=#0000FFFF` 静默渲染成黑字——参数被接受、
  // 被落盘、被上报，只有渲染不看它。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 24 20")
  let _ = run(s, "add-text x=0 y=0 text=H fill=#0000FFFF id=t")
  let env = @render.RenderEnv::new()
  let buf = @render.render_doc(unwrap_doc(s), env)
  let mut found = 0
  let mut wrong = 0
  let mut y = 0
  while y < 20 {
    let mut x = 0
    while x < 24 {
      let c = @codec.rgba_get(buf, x, y)
      if c != 0xFFFFFFFF {
        found = found + 1
        if c != 0xFF0000FF {
          wrong = wrong + 1
        }
      }
      x = x + 1
    }
    y = y + 1
  }
  // 必须先有像素，否则下面那条"都是蓝色"是空断言
  assert_true(found > 0, msg="文本必须真的画出像素，否则这条断言没有意义")
  assert_eq(wrong, 0, msg="文本像素应全是用户给的蓝（\{wrong} 个不是）")
  // 半透明文本色：50% 蓝压白 → #7F7FFF
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let _ = run(s2, "new 24 20")
  let _ = run(s2, "add-text x=0 y=0 text=H fill=#0000FF80 id=t")
  let buf2 = @render.render_doc(unwrap_doc(s2), env)
  let mut any = false
  let mut y2 = 0
  while y2 < 20 {
    let mut x2 = 0
    while x2 < 24 {
      if @codec.rgba_get(buf2, x2, y2) != 0xFFFFFFFF {
        any = true
        assert_eq(@codec.rgba_get(buf2, x2, y2), 0xFF7F7FFF)
      }
      x2 = x2 + 1
    }
    y2 = y2 + 1
  }
  assert_true(any, msg="半透明文本也必须真的画出像素")
}

///|
test "remove-param：只有它是 set-param 的对偶，删不掉就删不掉" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32")
  let _ = run(s, "set-param 主色 #C81E1E")
  let _ = run(s, "set-param 网点 300")
  assert_true(run(s, "list-params").contains("\"count\":2"), msg=run(s, "list-params"))
  // **这是补它的理由**：`set-param 主色 ""` 只是把值清空，条目还在
  let _ = run(s, "set-param 主色 \"\"")
  assert_true(
    run(s, "list-params").contains("\"count\":2"),
    msg="清空值不该删掉条目（这正是需要 remove-param 的原因）",
  )
  // 真删
  let rm = run(s, "remove-param 主色")
  assert_true(rm.contains("\"op\":\"remove-param\""), msg=rm)
  assert_true(rm.contains("\"count\":1"), msg=rm)
  let lp = run(s, "list-params")
  assert_true(lp.contains("\"count\":1"), msg=lp)
  assert_true(!lp.contains("主色"), msg="删掉的参数不该还在列表里：\{lp}")
  assert_true(lp.contains("网点"), msg="不该误删别的参数：\{lp}")
  // 不存在 → 明确报错（静默成功会让调用方以为删掉了）
  let miss = run(s, "remove-param 不存在")
  assert_true(miss.has_prefix("{\"error\":"), msg=miss)
  assert_true(miss.contains("元参数不存在"), msg=miss)
  // 删得掉也要撤得回
  let fp_after = @agent.exec(s, "fingerprint")
  let _ = run(s, "undo")
  assert_true(run(s, "list-params").contains("\"count\":2"), msg="undo 应把参数恢复回来")
  assert_true(@agent.exec(s, "fingerprint") != fp_after, msg="undo 后指纹应变")
}

///|
/// 解开 `save-mpd-b64` 的回包，数一数容器里**真的**有几个资产条目。
/// 这是"孤儿资产有没有被打包"的直接判据。
fn container_assets(envelope : String) -> Int {
  let bytes : Bytes = @base64.decode(@agent.mp_b64(envelope)) catch {
    _ => abort("b64 解码失败")
  }
  match @mpd.unpack(bytes) {
    Ok(m) => m.assets.length()
    Err(e) => abort("解容器失败: \{e}")
  }
}

///|
test "孤儿资产不进容器：删掉图片层后，那份字节不该再被打包" {
  // `doc.assets` 与 `s.assets` 都是**只增不减**的表，所以"谁还被引用"只能从
  // **层**上问。第一版拿 `doc.assets` 当引用表，清理完全没生效——`delete l1`
  // 之后 `design.layers` 是 0 层，而 `design.assets` 里那条还在。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 64 64")
  let img = @codec.rgba_new(8, 8)
  @codec.fill_rect_rgba(img, 0, 0, 8, 8, @codec.color_from_hex("#CC3366"))
  let b64 = @base64.encode(@codec.png_encode(img))
  let added = run(s, "add-image x=0 y=0 w=32 h=32 b64=\{b64} name=A")
  assert_true(added.contains("\"op\":\"add-image\""), msg=added)
  let doc = match s.doc {
    Some(d) => d
    None => abort("无文档")
  }
  assert_eq(
    @core.referenced_asset_hashes(doc).length(),
    1,
    msg="图片层应引用 1 份资产",
  )
  let kept = run(s, "save-mpd-b64")
  assert_true(kept.contains("\"mpd_b64\""), msg=kept)
  // **判据是容器里真的有几个资产条目**，不是"字节数变小了"——后者太弱：
  // 一张能压缩的 PNG 进 ZIP 后差异很小，我第一版就是拿长度比，结果变异
  // （打包时不过滤）活了下来。解容器直接数条目才咬得住。
  let kept_n = container_assets(kept)
  assert_eq(kept_n, 1, msg="有层引用时容器里应有 1 个资产")
  // 删层后再打包：必须仍然成功，而且变短
  let _ = run(s, "delete l1")
  assert_eq(
    @core.referenced_asset_hashes(doc).length(),
    0,
    msg="删层后应无引用（注意不是看 doc.assets，那张表不会减）",
  )
  let after = run(s, "save-mpd-b64")
  let hint = "删层后仍必须能保存——早先 pack 拿只增的 doc.assets 做正向对账，这里会报「文档引用的资产未登记字节」"
  assert_true(after.contains("\"mpd_b64\""), msg="\{hint}。回包：\{after}")
  let after_n = container_assets(after)
  assert_eq(
    after_n,
    0,
    msg="删层后容器里不该再有资产条目（孤儿资产被打包进去了）",
  )
  // 容器仍然自洽：装得回来
  let back = run(s, "open-mpd-b64 \{@agent.mp_b64(after)}")
  assert_true(back.contains("\"op\":\"open-mpd-b64\""), msg=back)
}

///|
test "容器自述不许撒谎：manifest 的 assets 计数 == design.json 的引用数 == 容器里的条目数" {
  // 上一版只修了"孤儿字节不进容器"，容器里没有 asset 条目了，但**自述还写着 1**：
  // `manifest.counts.assets` 与 `meta/design.json` 都来自只增的 `doc.assets`。
  // DESIGN 说"文本层权威"，README 承诺外部工具能 `unzip` 后直接读元参数层——
  // 那条悬空引用是给外部读者的，只有把三个数字摆在一起才看得见它撒谎。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 64 64")
  let img = @codec.rgba_new(8, 8)
  @codec.fill_rect_rgba(img, 0, 0, 8, 8, @codec.color_from_hex("#22AA66"))
  let b64 = @base64.encode(@codec.png_encode(img))
  let _ = run(s, "add-image x=0 y=0 w=32 h=32 b64=\{b64} name=A")
  let del = run(s, "delete l1")
  assert_true(del.contains("\"op\":\"delete\""), msg=del)
  assert_true(del.contains("\"pruned_assets\":1"), msg="delete 应报出收敛掉的资产数：\{del}")
  let saved = run(s, "save-mpd-b64")
  let bytes : Bytes = @base64.decode(@agent.mp_b64(saved)) catch {
    _ => abort("b64 解码失败")
  }
  let m = match @mpd.unpack(bytes) {
    Ok(m) => m
    Err(e) => abort("解容器失败: \{e}")
  }
  // 三项必须同时成立：自述的计数、权威文本层的引用、容器里的真实条目
  assert_eq(m.doc.assets.length(), 0, msg="design.json 不该留悬空引用")
  assert_eq(m.assets.length(), 0, msg="容器里不该有资产条目")
  // 直接从容器字节里读 manifest.json——这是**外部读者**看到的那一份
  let z = @codec.Zip::open(bytes)
  let mf = match @core.parse_json(z.read_text("manifest.json")) {
    Ok(v) => v
    Err(e) => abort("manifest 解析失败: \{e}")
  }
  let counts = match mf.get("counts") {
    Some(c) => c
    None => abort("manifest 缺 counts")
  }
  let claimed = match counts.get("assets") {
    Some(v) => match v.as_num() {
      Some(n) => n.to_int()
      None => abort("counts.assets 不是数字")
    }
    None => abort("manifest 缺 counts.assets")
  }
  assert_eq(
    claimed,
    m.assets.length(),
    msg="manifest 自述的资产数与容器里真实条目数不一致——容器在撒谎",
  )
  // 而且撤销之后三者也必须同时回来
  let _ = run(s, "undo")
  let again_bytes : Bytes = @base64.decode(@agent.mp_b64(run(s, "save-mpd-b64"))) catch {
    _ => abort("b64 解码失败")
  }
  let again = match @mpd.unpack(again_bytes) {
    Ok(mm) => mm
    Err(e) => abort("解容器失败: \{e}")
  }
  assert_eq(again.doc.assets.length(), 1, msg="undo 应把资产引用还回来")
  assert_eq(again.assets.length(), 1, msg="undo 后容器里应重新有那份字节")
}
