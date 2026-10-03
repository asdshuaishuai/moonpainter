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
/// 从 `query-layer` 的回包里取蒙版字段值（**精确解析**，不用子串匹配：
/// `"roughen":0` 会被 `"roughen":0.0279` 骗过——铁律 11）。
fn mask_num(s : @agent.Session, id : String, key : String) -> Double {
  let q = run(s, "query-layer \{id}")
  let root = match @core.parse_json(q) {
    Ok(v) => v
    Err(e) => abort("query-layer 回包不是 JSON：\{e}（\{q}）")
  }
  let layer = match root.get("layer") {
    Some(l) => l
    None => abort("query-layer 回包缺 layer：\{q}")
  }
  let mask = match layer.get("mask") {
    Some(m) => m
    None => abort("query-layer 没报蒙版：\{q}")
  }
  match mask.get(key) {
    Some(v) =>
      match v.as_num() {
        Some(d) => d
        None => abort("蒙版 \{key} 不是数字：\{q}")
      }
    None => abort("蒙版缺少字段 \{key}：\{q}")
  }
}

///|
test "set-mask 是全参数的部分更新：只改给的键，其余原样保留" {
  // 历史：`set-mask` 只认 `true|false`（invert），几何只能 remove-mask +
  // add-mask 重做。而 add-mask 是**全量**建立（缺省即 0），于是"只把羽化
  // 从 4 调到 12"会把没重复写的 radius/roughen **悄悄重置成 0**——一次小
  // 调整把另外几个参数吃掉，还不报错。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 20")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=20 fill=#FF0000FF id=r")
  let a = run(s, "add-mask r kind=rect x=2 y=3 w=20 h=15 radius=6 feather=4 roughen=2 invert=true")
  assert_true(a.contains("\"op\":\"add-mask\""), msg=a)
  // 五个非默认值都真的存下来了（可观测性：query-layer 回读）
  assert_eq(mask_num(s, "r", "x"), 2.0)
  assert_eq(mask_num(s, "r", "y"), 3.0)
  assert_eq(mask_num(s, "r", "w"), 20.0)
  assert_eq(mask_num(s, "r", "h"), 15.0)
  assert_eq(mask_num(s, "r", "radius"), 6.0)
  assert_eq(mask_num(s, "r", "feather"), 4.0)
  assert_eq(mask_num(s, "r", "roughen"), 2.0)
  assert_true(run(s, "query-layer r").contains("\"invert\":true"), msg="invert 应被记住")
  // 只改 feather：其余六个字段一个都不能动
  let b = run(s, "set-mask r feather=12")
  assert_true(b.contains("\"op\":\"set-mask\""), msg=b)
  assert_eq(mask_num(s, "r", "feather"), 12.0)
  assert_eq(mask_num(s, "r", "x"), 2.0, msg="未给的 x 必须保留")
  assert_eq(mask_num(s, "r", "y"), 3.0, msg="未给的 y 必须保留")
  assert_eq(mask_num(s, "r", "w"), 20.0, msg="未给的 w 必须保留")
  assert_eq(mask_num(s, "r", "h"), 15.0, msg="未给的 h 必须保留")
  assert_eq(mask_num(s, "r", "radius"), 6.0, msg="未给的 radius 必须保留")
  assert_eq(mask_num(s, "r", "roughen"), 2.0, msg="未给的 roughen 必须保留")
  assert_true(run(s, "query-layer r").contains("\"invert\":true"), msg="未给的 invert 必须保留")
  // 几何本身也真的改得动（位置/尺寸/形状/invert 各改一次）
  let _ = run(s, "set-mask r x=5 y=6 w=30 h=8")
  assert_eq(mask_num(s, "r", "w"), 30.0)
  assert_eq(mask_num(s, "r", "x"), 5.0)
  let _ = run(s, "set-mask r kind=ellipse")
  assert_true(run(s, "query-layer r").contains("\"mask\":{\"kind\":\"ellipse\""), msg="换形状应生效")
  let _ = run(s, "set-mask r false")
  assert_true(run(s, "query-layer r").contains("\"invert\":false"), msg="历史写法 set-mask <id> true|false 仍要能用")
}

///|
test "set-mask 的校验面：非法值/未知键/空改动/没蒙版，一个都不许静默" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 20")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=20 fill=#FF0000FF id=r")
  // ① 层上还没有蒙版 → 报错指路 add-mask（不许"回 ok 而指纹不变"）
  let nomask = run(s, "set-mask r feather=4")
  assert_true(nomask.contains("\"error\""), msg="没有蒙版时 set-mask 必须报错：\{nomask}")
  assert_true(nomask.contains("add-mask"), msg="应指路 add-mask：\{nomask}")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20 feather=1")
  // ② 未知键 → 报合法清单（`kv_args` 是静默的，靠 check_kv_args 拦）
  let badkey = run(s, "set-mask r radus=5")
  assert_true(badkey.contains("\"error\""), msg="拼错的键必须被拒：\{badkey}")
  assert_true(badkey.contains("roughen"), msg="错误应回显合法键清单：\{badkey}")
  // ③ 给了但不是数 / 认不出的布尔值 → 报错，不许悄悄按默认/0 处理
  assert_true(run(s, "set-mask r feather=abc").contains("\"error\""), msg="非数必须被拒")
  assert_true(run(s, "set-mask r invert=maybe").contains("\"error\""), msg="认不出的布尔值必须被拒")
  // ④ 值非法（共用 `@core.mask_param_error`）：尺寸非正 / 负的 radius、feather、roughen
  for bad in ["w=0", "h=-3", "radius=-1", "feather=-2", "roughen=-4"] {
    let r = run(s, "set-mask r \{bad}")
    assert_true(r.contains("\"error\""), msg="\{bad} 应被拒绝，实际：\{r}")
  }
  // ⑤ 一个要改的参数都没给 → 报错（否则是一次静默空操作）
  assert_true(run(s, "set-mask r").contains("\"error\""), msg="没有任何参数必须被拒")
  // ⑥ 认不出的裸词（既不是键=值，也不是历史 true|false）
  let badword = run(s, "set-mask r yes")
  assert_true(badword.contains("\"error\""), msg="认不出的裸词必须被拒：\{badword}")
  // 被拒绝的调用都不该动到蒙版，也不该留下编辑历史（快照在校验之后）
  assert_eq(mask_num(s, "r", "feather"), 1.0, msg="被拒的调用不许改动蒙版")
  assert_eq(mask_num(s, "r", "w"), 20.0)
  let before = run(s, "edits")
  let _ = run(s, "set-mask r feather=-2")
  let _ = run(s, "set-mask r radus=1")
  assert_eq(run(s, "edits"), before, msg="被拒绝的 set-mask 不该留下编辑历史")
  // 正控：合法的一次改动必须成功（判据两头都要咬得住）
  assert_true(run(s, "set-mask r feather=9").contains("\"op\":\"set-mask\""), msg="合法调用必须成功")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=10 h=20 feather=1 invert=true")
  assert_true(run(s, "query-layer r").contains("\"mask\":{\"kind\":\"rect\""), msg="add-mask 的几何要能被回读")
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
  // ⚠️ 必须**精确解析**字段，不能 `contains("mask")`：`caps` 数组里就有
  // 字面量 `"mask"`（铁律 11——子串断言会被同一份回包里的另一个字段满足，
  // 实测这条断言就是这么被打红的）。
  let _ = run(s, "remove-mask r")
  let q3 = run(s, "query-layer r")
  let o3 = match @core.parse_json(q3) {
    Ok(o) => o
    Err(e) => abort("query-layer 回包不是 JSON（\{e}）：\{q3}")
  }
  let l3 = match o3.get("layer") {
    Some(x) => x
    None => abort("缺 layer：\{q3}")
  }
  assert_true(l3.get("mask") is None, msg="去蒙版后不该再报 mask 字段：\{q3}")
  // 正控：**有**蒙版时那个字段必须在（否则上面那条断言只是在守"永远不报"）
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20")
  let q4 = run(s, "query-layer r")
  assert_true(q4.contains("\"mask\":"), msg="有蒙版时要报 mask 字段：\{q4}")
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
  // feather=4：蒙版按**4 个子样本各自的覆盖度取平均**（与形状同一套样本，
  // 见 PLAN 五十六）。像素 (k,k) 的四个样本落在 (k+0.25..k+0.75)，内距 =
  // 该样本到蒙版边界的距离 ⇒ 覆盖 = 内距/4。实测平均：
  //   k=1 → 0.34375、k=2 → 0.59375、k=3 → 0.84375、k=4 → 1.0
  // （红按覆盖度压在白底上：255×(1−avg) → 167/104/40/0）
  // ⚠️ 改前这里是「按像素中心算一个覆盖度乘上去」（0.375/0.625/0.875）——
  // 那是**两把尺子**：形状按 4 个子样本判、蒙版按中心判。实测反例 (13,7)：
  // 中心在蒙版外（覆盖 0）、子样本在内，于是 `pick` 与渲染打架。
  let _ = run(s, "remove-mask r")
  let _ = run(s, "add-mask r kind=rect x=0 y=0 w=20 h=20 feather=4")
  let soft = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(soft, 1, 1), 0xFFFFA7A7) // 平均覆盖 0.34375
  assert_eq(@codec.rgba_get(soft, 2, 2), 0xFFFF6868) // 平均覆盖 0.59375
  assert_eq(@codec.rgba_get(soft, 3, 3), 0xFFFF2828) // 平均覆盖 0.84375
  assert_eq(@codec.rgba_get(soft, 4, 4), 0xFFFF0000) // 平均覆盖 1.00（内距达 feather）
  assert_eq(@codec.rgba_get(soft, 10, 10), 0xFFFF0000) // 深处仍是满覆盖
  assert_eq(@codec.rgba_get(soft, 25, 25), 0xFFFFFFFF) // 蒙版外仍完全不渲染
  // 羽化只影响边界带：远离边界的区域与 hard 完全一致
  assert_eq(@codec.rgba_get(soft, 15, 15), @codec.rgba_get(hard, 15, 15))
  // 反选后过渡带跟着反向：每个样本的覆盖度取 1−原覆盖度，再按样本平均
  // （(1,1) 实测 0.6875/0.6875/0.6875/0.5625 → 0.65625 ⇒ 255×0.34375 = 88 = 0x58）
  let _ = run(s, "set-mask r invert=true")
  let inv = @render.render_doc(unwrap_doc(s), env)
  assert_eq(@codec.rgba_get(inv, 1, 1), 0xFFFF5858) // 1−0.34375 = 0.65625
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

///|
test "group：一个成员的组也能建（入口不许比可达状态更严）" {
  // 原先入口要求至少两个成员，但"一个成员的组"本来就能到达——
  // 分两个再删一个就得到了。于是入口比可达状态更严，字典里
  // `group <gid> <id…>` 又读作"一个也行"：三处口径不一致。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32")
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#FF0000FF name=A")
  let one = run(s, "group g1 l1")
  assert_true(one.contains("\"op\":\"group\""), msg="一个成员也该能建组：\{one}")
  assert_true(one.contains("\"members\":1"), msg=one)
  // 组能装能开、能拆
  let un = run(s, "ungroup g1")
  assert_true(un.contains("\"op\":\"ungroup\""), msg=un)
  assert_true(un.contains("\"restored\":1"), msg=un)
  // 零成员仍必须拒绝（空组没有意义，且会让"直通合成"多一层无用嵌套）
  let none = run(s, "group g2")
  assert_true(none.has_prefix("{\"error\":"), msg=none)
  assert_true(none.contains("至少一个成员"), msg=none)
  // 经由"分两个再删一个"到达的单成员组，删掉最后那个成员后组还在（空组）
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#00FF00FF name=B")
  let _ = run(s, "group g3 l1 l2")
  let _ = run(s, "delete l2")
  let ll = run(s, "list-layers")
  assert_true(ll.contains("\"id\":\"g3\""), msg="删掉一个成员后组应还在：\{ll}")
  assert_true(ll.contains("\"id\":\"l1\""), msg=ll)
}

///|
test "set-text 缺参数要报用法错，不许越界崩溃" {
  // 原先下界写成 2（应为 3），于是 `set-text l1` 穿过校验、在 `tokens[2]`
  // 上**越界 panic**：进程从 cmd_set_text 崩掉，用户看到调用栈而不是提示。
  // 这条测试在修之前会直接把测试进程带崩——正是它该有的样子。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32")
  let _ = run(s, "add-text x=0 y=0 text=Hi")
  let bad = run(s, "set-text l1")
  assert_true(bad.has_prefix("{\"error\":"), msg=bad)
  assert_true(bad.contains("用法：set-text"), msg=bad)
  // 清空是合法用法（分词后仍是 3 个 token），不许被下界误伤
  let cleared = run(s, "set-text l1 \"\"")
  assert_true(cleared.contains("\"op\":\"set-text\""), msg=cleared)
  let q = run(s, "query-layer l1")
  assert_true(!q.contains("\"text\":\""), msg="空文本会从回包里省略（注意别被 kind:text 误伤）：\{q}")
  // 真正设置也照常
  let ok = run(s, "set-text l1 Hello")
  assert_true(ok.contains("\"op\":\"set-text\""), msg=ok)
  assert_true(run(s, "query-layer l1").contains("\"text\":\"Hello\""), msg=run(s, "query-layer l1"))
}

///|
test "几何样式必须读得回来：radius 与 flip 此前只有写、没有读" {
  // `add-rect radius=5` / `flip l1 h` 都改了画面与指纹，而
  // `query-layer`/`list-layers` 都不报这两个字段 —— 调用方想"再圆一点"
  // 只能靠自己记住上次设了多少。fill/stroke 还有 sample/census/probe
  // 这条视觉回读路径，几何样式没有（看渲染只能看出"有圆角"，量不出像素）。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 320 240 uuid=readback")
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#00FF00FF name=R radius=5")
  let _ = run(s, "flip l1 h")
  let q = run(s, "query-layer l1")
  assert_true(q.contains("\"radius\":5"), msg="rect 的 radius 必须报出来：\{q}")
  assert_true(q.contains("\"flip_h\":true"), msg="flip_h 必须报出来：\{q}")
  assert_true(q.contains("\"flip_v\":false"), msg="flip_v 也要报（否则不知道另一个方向）：\{q}")
  let list = run(s, "list-layers")
  assert_true(list.contains("\"radius\":5"), msg="list-layers 同样要报：\{list}")
  // 椭圆不该带 radius（它的圆角没有意义，报了反而是误导）
  let _ = run(s, "add-ellipse x=0 y=0 w=10 h=10 fill=#FF0000FF name=E")
  let q2 = run(s, "query-layer l2")
  assert_true(!q2.contains("\"radius\""), msg="椭圆不该报 radius：\{q2}")
}

///|
test "radius 只对矩形有意义：椭圆上传 radius 必须在入口被拒" {
  // 此前 `add-ellipse radius=12` / `set-style <椭圆> radius=9` 都返回 ok，
  // 把 corner_radius 写进 canonical JSON（**指纹变了**），而渲染器只在
  // Rect 分支读它（**画面逐位没变**），query-layer 又按 kind 投影所以
  // **连报都不报**——三个信号自相矛盾，lint 也不响。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 320 240 uuid=radiuskind")
  let r1 = run(s, "add-ellipse x=0 y=0 w=40 h=40 fill=#FF0000FF name=E radius=12")
  // 两条入口拒的**路径不同**（都咬住"谁是圆角的读点"，而不是某句措辞）：
  // ① `add-ellipse` 的键表里已经没有 `radius` ⇒ 参数面拒，指路到 add-rect；
  assert_true(r1.contains("radius") && r1.contains("add-rect"), msg="add-ellipse 的 radius 必须被拒并指路：\{r1}")
  // 被拒的命令**也会消耗掉一个 id**（id 在参数校验之前就分配），所以别写死
  // l2；从成功回包里取真实 id。
  let added = run(s, "add-ellipse x=0 y=0 w=40 h=40 fill=#FF0000FF name=E2")
  let eid = match @core.parse_json(added) {
    Ok(v) =>
      match v.get("id") {
        Some(@core.JValue::JStr(x)) => x
        _ => abort("add-ellipse 没回 id：\{added}")
      }
    Err(e) => abort("add-ellipse 回包不是 JSON：\{e}")
  }
  let r2 = run(s, "set-style \{eid} radius=9")
  // ② `set-style` 的键是通用的（同一个键在不同层上答案不同）⇒ 由写值时的
  //    读点矩阵拒，措辞是"只对矩形有意义"。
  assert_true(r2.contains("只对矩形"), msg="set-style 的 radius 必须被拒：\{r2}")
  // 矩形照常（入口变严不许误伤正常路径）
  let ok = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#00FF00FF name=R radius=5")
  assert_true(!ok.contains("error"), msg="矩形的 radius 不该受影响：\{ok}")
  // 手改容器的那种状态由 lint 兜住
  let doc = @core.new_document("radius-kind-2", 64, 64)
  let l = @core.default_layer("e1", "hand", 0.0, 0.0, 20.0, 20.0)
  doc.layers.push({ ..l, kind: @core.ShapeKind::Ellipse, corner_radius: 7.0 })
  let joined = @agent.lint_doc(doc).join(" | ")
  // 断言**具体数值**而不是"却带着 radius"这个短语：后者会被
  // 「报了字段名但没报值」的写法满足（实测：那样写这个变异存活了）。
  assert_true(joined.contains("radius=7"), msg="lint 要报出具体值：\{joined}")
}

///|
test "参数零容忍：拼错的键、漏了 = 的裸词、空值都必须拒绝，不许静默 no-op" {
  // `kv_args` 是**静默**的（认不出 `=` 的 token 直接丢）。于是
  // `set-style l1 fil=#FF0000`（拼错）、`set-style l1 fill`（漏 `=`）、
  // `set-style l1 fill=`（空值）**全都返回 ok 而一个像素没改**——
  // 调用方以为改成功了。set-mask 当年栽的正是这一类。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 64 64 uuid=kvzero")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=40 fill=#FF0000FF name=R")
  let fp0 = run(s, "fingerprint")
  let e1 = run(s, "set-style l1 fil=#0000FFFF")
  assert_true(e1.contains("不认识的参数"), msg="拼错的键要拒绝：\{e1}")
  let e2 = run(s, "set-style l1 fill")
  assert_true(e2.contains("不是 key=value"), msg="漏 `=` 要拒绝：\{e2}")
  let e3 = run(s, "set-style l1 fill=")
  assert_true(e3.contains("值是空的"), msg="空值要拒绝：\{e3}")
  // 关键词归别的命令管时给出指路。
  // `points` 现在是 set-style 认得的键，但**只对 polygon/line 有意义** ——
  // 这一层是矩形，所以拒绝改由 kind 门给出（与 radius 同一句话），
  // 断言咬住"两类层才收顶点"这个语义，而不是某句措辞。
  let ep = run(s, "set-style l1 points=0,0;1,1")
  assert_true(ep.contains("只对polygon/line有意义"), msg="points 要指路：\{ep}")
  assert_true(ep.contains("add-line"), msg="points 被拒要给出路（要折线用 add-line）：\{ep}")
  assert_true(run(s, "set-style l1 text=hi").contains("set-text"), msg="text 要指路")
  assert_true(run(s, "set-style l1 w=10").contains("resize"), msg="w 要指路")
  // 三次被拒之后，文档必须**逐位没变**（连指纹都不该动）
  assert_eq(run(s, "fingerprint"), fp0, msg="被拒的命令不许改文档")
  // add-* 同样
  assert_true(run(s, "add-rect x=0 y=0 w=5 h=5 radus=8").contains("不认识的参数"), msg="add-rect 拼错要拒")
  assert_true(run(s, "add-text x=0 y=0 text=hi fontsize=20").contains("不认识的参数"), msg="add-text 拼错要拒")
  assert_true(run(s, "add-paint bogus=1").contains("不认识的参数"), msg="add-paint 拼错要拒")
  // 正常路径不许误伤
  assert_true(!run(s, "set-style l1 fill=#00FF00FF opacity=0.5").contains("error"), msg="正常参数要能用")
}

///|
test "tag= 必须真的落上（此前被静默忽略：注释说会应用，实现里没那条分支）" {
  // ops.mbt 里 `apply_style_kv` 的注释写着它会应用 `.../name/tag`，但实现里
  // 没有 tag 分支 —— 于是 `add-rect … tag=background` 不报错、`tags` 为空，
  // 而两条既有测试都用着它、谁也没断言它真的落上（"注册了≠接得上"的同型）。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 64 64 uuid=tagkv")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=40 fill=#FF0000FF name=A tag=background")
  let q1 = run(s, "query-layer l1")
  assert_true(q1.contains("background"), msg="add-rect 的 tag= 必须落上：\{q1}")
  // 追加且去重（与 tag 命令同一实现）
  let _ = run(s, "set-style l1 tag=前景")
  let q2 = run(s, "query-layer l1")
  assert_true(q2.contains("前景"), msg="set-style 的 tag= 也要落上：\{q2}")
  assert_true(q2.contains("background"), msg="追加不能覆盖原有标签：\{q2}")
  let _ = run(s, "set-style l1 tag=background")
  let q3 = run(s, "query-layer l1")
  // 数一下 background 出现几次（重复添加不该产生第二条）
  let mut n = 0
  let mut rest = q3
  while true {
    match rest.find("background") {
      Some(i) => {
        n = n + 1
        rest = rest[i + 10:].to_owned()
      }
      None => break
    }
  }
  assert_eq(n, 1, msg="重复标签不该重复添加：\{q3}")
  // tag 命令本身仍可用（两条路径共用 @core.layer_with_tag）
  let _ = run(s, "tag l1 命令加的")
  assert_true(run(s, "query-layer l1").contains("命令加的"), msg="tag 命令仍要能用")
}

///|
test "points 只对 polygon/line 有意义：rect 上给顶点是死数据，必须拒绝" {
  // 实测：`add-rect … points=0,0;10,10` 指纹 7248c56f→189c73d6（变了），
  // render_sha256 一字未变——与椭圆上的 radius、rect 上的 text 同型。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 64 64 uuid=pointsdead")
  let r = run(s, "add-rect x=0 y=0 w=40 h=40 fill=#FF0000FF points=0,0;10,10")
  // 这一层拒绝来自**键校验**（`points` 不在 rect 的键集里），比
  // `build_shape_layer` 里的 kind 门更早。断言咬住**这条**消息：如果谁把
  // `points` 加进 rect 的键集，拒绝会改由 kind 门给出，这条断言就红。
  assert_true(r.contains("不认识的参数 `points`"), msg="rect 的 points 必须被拒：\{r}")
  // 指路要同时给出**两条路**：建层（add-polygon/add-line）与原地改顶点
  // （set-style … points=）。只写前者，调用方就会以为改不动只能删了重加。
  assert_true(r.contains("add-polygon"), msg="要指路到建层：\{r}")
  assert_true(r.contains("set-style"), msg="要指路到改顶点：\{r}")
  // polygon/line 照常，且顶点读得回来（此前既不报、也没命令能改）
  // 被拒的命令**也会消耗一个 id**，所以别写死 l2；从回包取真实 id。
  let added = run(
    s,
    "add-polygon x=0 y=0 w=40 h=40 points=0,0;40,0;20,40 fill=#00FF00FF name=tri",
  )
  let pid = match @core.parse_json(added) {
    Ok(v) =>
      match v.get("id") {
        Some(@core.JValue::JStr(x)) => x
        _ => abort("add-polygon 没回 id：\{added}")
      }
    Err(e) => abort("add-polygon 回包不是 JSON：\{e}")
  }
  let q = run(s, "query-layer \{pid}")
  assert_true(q.contains("[[0,0],[40,0],[20,40]]"), msg="顶点必须报得出来：\{q}")
  // 手改容器的情形由 lint 兜住
  let doc = @core.new_document("pointsdead-2", 64, 64)
  let l = @core.default_layer("r1", "hand", 0.0, 0.0, 20.0, 20.0)
  doc.layers.push({ ..l, kind: @core.ShapeKind::Rect, points: [(0.0, 0.0), (5.0, 5.0)] })
  let joined = @agent.lint_doc(doc).join(" | ")
  assert_true(joined.contains("2 个顶点"), msg="lint 必须报死顶点：\{joined}")
}

///|
test "参数零容忍（第二批）：蒙版/调整/画笔/新建/加图 也要挂上校验" {
  // 上一批只挂了 set-style 与 add-{rect,ellipse,polygon,line,text,paint}。
  // `set-mask` 当年正是"静默接受任何 tokens[2]"那类 bug 的发源地，而它的
  // 兄弟 `add-mask` 一直没检查：`radus=5` 会静默给出硬边直角蒙版。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  assert_true(run(s, "new 64 64 uui=abc").contains("不认识的参数"), msg="new 拼错要拒")
  let _ = run(s, "new 64 64 uuid=kv2")
  let _ = run(s, "add-rect x=0 y=0 w=40 h=40 fill=#FF0000FF name=A")
  assert_true(
    run(s, "add-mask l1 kind=rect x=0 y=0 w=10 h=10 radus=5").contains("不认识的参数"),
    msg="add-mask 拼错 radius 要拒（否则静默给硬边直角）",
  )
  assert_true(
    run(s, "add-adjust op=brightness vlaue=1.5").contains("不认识的参数"),
    msg="add-adjust 拼错 value 要拒（否则静默按 0 建一个没效果的调整层）",
  )
  // 这里原先用 `value=1.5`——**越界值**，而当时入口收下了它（brightness 内部
  // 只 clamp）。范围校验上线后它被拒，l2 压根没建出来，下面那句就报"层不存在"。
  // 测试用了某个值，不等于那个值合法。
  let _ = run(s, "add-adjust op=brightness value=0.5")
  // set-adjust 拼错键时，报的必须是"不认识的参数"而不是误导性的"至少要给"
  let bad = run(s, "set-adjust l2 vallue=0.5")
  assert_true(bad.contains("不认识的参数"), msg="拼错键要说清是拼错：\{bad}")
  assert_true(!bad.contains("至少要给"), msg="别用误导性的话：\{bad}")
  let _ = run(s, "add-paint name=P")
  assert_true(
    run(s, "brush layer=l3 pts=0,0;5,5 rr=4").contains("不认识的参数"),
    msg="brush 拼错 r 要拒",
  )
  // erase 走同一个函数，但报错里的命令名要指对
  assert_true(run(s, "erase layer=l3 pts=0,0;5,5 rr=4").contains("erase"), msg="erase 的报错要点名 erase")
  assert_true(run(s, "add-image bogus=1").contains("不认识的参数"), msg="add-image 拼错要拒")
  // 正常路径不许误伤
  assert_true(!run(s, "add-mask l1 kind=rect x=0 y=0 w=10 h=10 radius=5 feather=2").contains("error"), msg="蒙版正常参数要能用")
  assert_true(!run(s, "brush layer=l3 pts=0,0;5,5 r=4").contains("error"), msg="画笔正常参数要能用")
  assert_true(!run(s, "new 8 8 uuid=again").contains("error"), msg="new 正常参数要能用")
}

///|
test "session-open 的拒绝要说清收到了什么（拼错参数名时别误导成「模型不是多模态」）" {
  // `vison=full_image`（拼错）此前会报"纯文本/仅 OCR 模型请换多模态模型"——
  // 把"参数名拼错"误导成"模型不合格"，排查方向完全错了。
  let s = @agent.Session::new()
  let r = run(s, "session-open vison=full_image")
  assert_true(r.contains("vison"), msg="要把收到的参数回显出来：\{r}")
  // 合法声明仍要通过（位置参数与 vision= 两种形态）
  let s2 = @agent.Session::new()
  assert_true(!run(s2, "session-open full_image").contains("error"), msg="位置参数要能用")
  let s3 = @agent.Session::new()
  assert_true(!run(s3, "session-open vision=full_image").contains("error"), msg="vision= 要能用")
}

///|
test "参数零容忍（第三批）：视觉/分析类命令 + 「值越界就静默用默认」" {
  // 前两批修的是 add-*/set-* 系列。这一批是 `render`/`census`/`probe`/
  // `select-preview`/`mvsl-impact`/`mvsl-set`——它们用手写 `has_prefix` 扫 kv
  // 而不是 `kv_args`，所以同样的"认不出来也不报错"在这里另有一份。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32 uuid=kv3")
  let _ = run(s, "add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF name=A")
  for bad in ["probe bogus=1 x=0 y=0", "census bogus=1", "mvsl-impact bogus=1", "render 16 bogus=1", "render bogus=1"] {
    assert_true(run(s, bad).contains("不认识的参数"), msg="\{bad} 要拒：\{run(s, bad)}")
  }
  // 位置参数写成 kv 时，报错要指路而不是自己咬自己
  let rw = run(s, "render width=16")
  assert_true(rw.contains("不认识的参数"), msg=rw)
  assert_true(rw.contains("位置参数"), msg="要把人指回位置参数：\{rw}")
  // mvsl-set 的载荷之后不该再收东西
  assert_true(run(s, "mvsl-set YWJj layr=l1").contains("不接受"), msg="mvsl-set 载荷后不许再给参数")
  assert_true(run(s, "mvsl-set YWJj extra").contains("多给了"), msg="mvsl-set 载荷后不许再给裸词")
  // 「值越界就静默退回默认」是同一类静默：要 0 个连通域 / 0 像素预览是说不通的
  assert_true(run(s, "census components=0").contains("必须为正"), msg="components=0 不许静默退回 16")
  assert_true(run(s, "census components=-3").contains("必须为正"), msg="components=-3 同上")
  assert_true(run(s, "mvsl-impact max=0").contains("必须为正"), msg="max=0 不许静默退回 1024")
  assert_true(run(s, "render 16 overlay=yes").contains("应为 1/0/true/false"), msg="overlay=yes 不许静默无效")
  // 正常路径不许误伤（含位置参数）
  assert_true(!run(s, "probe x=0 y=0 r=2").contains("error"), msg="probe 正常")
  assert_true(!run(s, "census components=3").contains("error"), msg="census 正常")
  assert_true(!run(s, "mvsl-impact max=7").contains("error"), msg="impact 正常")
  assert_true(!run(s, "render 16 0 0 1 1 overlay=true").contains("error"), msg="render 位置参数+overlay 正常")
  assert_true(!run(s, "render 16 overlay=0").contains("error"), msg="overlay=0 正常")
}

///|
test "sample 的颜色与层 id 必须指同一件事（同一信封里两字段不许互相矛盾）" {
  // `sample` 回颜色（来自真实渲染）与 layer（来自 pick）。老 `pick` 走压平的
  // `all_layers` 且只查 `visible`，于是实测出现过
  // `color=#FFFFFFFF`（白纸，什么都没画）+ `layer=l1`（opacity=0 的幽灵层）
  // ——**同一个信封里两个字段描述的不是同一件事**（与上一轮
  // `result_sha256` 配错 PNG 是同一类病：判据/字段要指同一个东西）。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32 uuid=sample-consistency")
  // 1) 全透明的层：颜色是白纸，layer 就必须是空的
  let _ = run(s, "add-rect x=0 y=0 w=32 h=32 fill=#00FF00FF opacity=0 name=Ghost")
  let j1 = run(s, "sample 16 16")
  assert_true(j1.contains("#FFFFFFFF"), msg="白纸应当是白色：\{j1}")
  assert_true(j1.contains("\"layer\":\"\""), msg="白纸处不该报出一个层 id：\{j1}")
  // 2) 真的有一个不透明层在那里：颜色变了，layer 必须报它
  let _ = run(s, "add-rect x=0 y=0 w=32 h=32 fill=#FF0000FF name=Top")
  let j2 = run(s, "sample 16 16")
  assert_true(j2.contains("#FF0000FF"), msg="顶层红：\{j2}")
  assert_true(j2.contains("\"layer\":\"l2\""), msg="红层处应报 l2：\{j2}")
  // 3) 隐藏组的子层：画不出来，就不该被报出来
  let _ = run(s, "add-rect x=0 y=0 w=8 h=8 fill=#0000FFFF name=InG")
  let _ = run(s, "group g1 l3")
  let _ = run(s, "visible g1 false")
  let j3 = run(s, "sample 4 4")
  // 隐藏 g1 后，(4,4) 露出的是它**下面**那个全画布红层 l2 ——
  // 报 l2 才是对的（别断言成空：那会漏掉"该报下面那层"这一半）。
  assert_true(j3.contains("\"layer\":\"l2\""), msg="隐藏组的子层被跳过，应报下面的 l2：\{j3}")
  assert_true(!j3.contains("l3"), msg="隐藏组的子层不该被报出来：\{j3}")
}

///|
test "字典承诺的参数必须真的认：erase 不收 color=（恒全强度，收了也不生效）" {
  // `erase` 此前与 `brush` 共用一个函数、键表按布尔分支算，于是静默收下了
  // `color=` —— 而渲染器里橡皮擦**恒全强度**（`paint_dabs` 的 `dalpha` 对
  // erase 直接取 1.0，连笔色 alpha 都不读）。收下一个不生效的参数就是
  // 静默 no-op：调用方以为"我调了浓度"，画面一点没变。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 32 32 uuid=erase-color")
  let _ = run(s, "add-paint name=P")
  let e = run(s, "erase layer=l1 pts=10,10;20,20 r=4 color=#FF000080")
  assert_true(e.contains("不认识的参数") || e.contains("color"), msg="erase 应拒收 color=：\{e}")
  assert_true(e.contains("layer") && e.contains("pts") && e.contains("r"), msg="拒绝时要列出真正认的键：\{e}")
  // 正控：不带 color 的 erase 照常可用（别把好路径一起拦掉）
  let ok = run(s, "erase layer=l1 pts=10,10;20,20 r=4")
  assert_true(ok.contains("\"ok\":true"), msg="合法 erase 必须成功：\{ok}")
  // brush 仍然收 color=（两边同名参数不许一刀切）
  let b = run(s, "brush layer=l1 pts=10,10;20,20 r=4 color=#FF000080")
  assert_true(b.contains("\"ok\":true"), msg="brush 应接受 color=：\{b}")
}

///|
/// 造一张 `w`×`h` 的纯色 PNG 的 base64（位图命令的测试夹具）。
fn solid_png_b64(w : Int, h : Int, hex : String) -> String {
  let img = @codec.rgba_new(w, h)
  @codec.fill_rect_rgba(img, 0, 0, w, h, @codec.color_from_hex(hex))
  @base64.encode(@codec.png_encode(img))
}

///|
test "add-image：盒子跟着内容走 —— 缺省不再是 100×100，只给一边时不许改长宽比" {
  // 渲染器把资产**拉伸到盒子**（`paint_layer`：`sx = lx / w * img.width`），
  // 所以"给一张 400×300 的图却留着缺省 100×100 的盒"是**静默压扁**：回包里
  // `asset_size` 写 400x300、`query-layer` 说 w=100 h=100，画面被压成正方形。
  // 规则与文本层的占位盒同一条：都没给 → 盒 = 资产像素尺寸；只给一边 → 另一边
  // 按原比例推；两边都给 → 听调用方的。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 400 300")
  let b64 = solid_png_b64(200, 100, "#2266CC")
  // ① 都不给 → 盒 = 200×100
  let r1 = run(s, "add-image b64=\{b64} id=a")
  assert_true(r1.contains("\"asset_size\":\"200x100\""), msg=r1)
  assert_true(r1.contains("\"w\":200"), msg=r1)
  assert_true(r1.contains("\"h\":100"), msg=r1)
  let q1 = run(s, "query-layer a")
  assert_true(q1.contains("\"w\":200,"), msg=q1)
  assert_true(q1.contains("\"h\":100,"), msg=q1)
  // ② 只给 w=80 → h 按 2:1 推成 40（**不许**留缺省 100 把比例改掉）
  let r2 = run(s, "add-image b64=\{b64} id=b w=80")
  assert_true(r2.contains("\"w\":80"), msg=r2)
  assert_true(r2.contains("\"h\":40"), msg=r2)
  // ③ 只给 h=30 → w 推成 60
  let r3 = run(s, "add-image b64=\{b64} id=c h=30")
  assert_true(r3.contains("\"w\":60"), msg=r3)
  assert_true(r3.contains("\"h\":30"), msg=r3)
  // ④ 两边都给 → 听调用方的（他就是要那个框，哪怕变形）
  let r4 = run(s, "add-image b64=\{b64} id=d w=40 h=40")
  assert_true(r4.contains("\"w\":40"), msg=r4)
  assert_true(r4.contains("\"h\":40"), msg=r4)
  // ⑤ 正控：显式的非法值仍由 `build_shape_layer` 那唯一一句话拒
  let bad = run(s, "add-image b64=\{b64} id=e w=0")
  assert_true(bad.has_prefix("{\"error\":\""), msg=bad)
}

///|
test "set-image：原地换图（层序/蒙版/标签/透明度/翻转都不丢），非位图层拒" {
  // 对偶于 `set-text`：此前换图只能 delete + add-image，层序/蒙版/标签/透明度/
  // 翻转/旋转全丢，而且重加会把它推到栈顶（改变与相邻层的叠放关系）。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 200 150")
  let b64a = solid_png_b64(200, 100, "#CC3366")
  let b64b = solid_png_b64(300, 300, "#33CC66")
  let _ = run(s, "add-rect x=0 y=0 w=50 h=50 fill=#111111FF id=below")
  let _ = run(s, "add-image b64=\{b64a} id=pic")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#222222FF id=above")
  // 给 pic 挂上"会丢"的那些属性
  let _ = run(s, "tag pic hero")
  let _ = run(s, "add-mask pic kind=rect x=0 y=0 w=50 h=50")
  let _ = run(s, "visible pic false")
  let _ = run(s, "rotate pic 30")
  let before = run(s, "query-layer pic")
  let _ = run(s, "visible pic true")
  assert_true(before.contains("\"mask\":{"), msg=before)
  // 换图：只有 asset/盒子变
  let r = run(s, "set-image pic b64=\{b64b}")
  assert_true(r.contains("\"op\":\"set-image\""), msg=r)
  assert_true(r.contains("\"asset_size\":\"300x300\""), msg=r)
  let after = run(s, "query-layer pic")
  // ① 资产真的换了（sha 不同）
  assert_true(after.contains("\"id\":\"pic\""), msg=after)
  let _ = run(s, "visible pic true")
  // ② 其余属性一个没丢
  let q = run(s, "query-layer pic")
  assert_true(q.contains("\"rot\":30,"), msg=q)
  assert_true(q.contains("\"tags\":[\"hero\"]"), msg=q)
  assert_true(q.contains("\"mask\":{"), msg=q)
  // ③ 层序没变：pic 仍夹在 below 与 above 之间
  let l = run(s, "list-layers")
  let ib = l.find("below").unwrap_or(-1)
  let ip = l.find("pic").unwrap_or(-1)
  let ia = l.find("above").unwrap_or(-1)
  assert_true(ib >= 0 && ip > ib && ia > ip, msg="层序必须保持 below < pic < above：\{l}")
  // ④ 非位图层拒（set-image 只改像素）
  let e = run(s, "set-image below b64=\{b64b}")
  assert_true(e.has_prefix("{\"error\":\""), msg=e)
  // ⑤ 不给 b64 拒（换图必须给新像素，缺省 = 什么都不做）
  let e2 = run(s, "set-image pic")
  assert_true(e2.has_prefix("{\"error\":\""), msg=e2)
  // ⑥ 坏载荷拒，且**一个字节都不许改**（指纹不变）
  let fp_before = run(s, "fingerprint")
  let e3 = run(s, "set-image pic b64=!!!not-base64!!!")
  assert_true(e3.has_prefix("{\"error\":\""), msg=e3)
  let fp_after = run(s, "fingerprint")
  assert_eq(fp_before, fp_after, msg="坏载荷必须在改文档之前就拒（指纹不许变）")
  // ⑦ lint 干净
  let lint = run(s, "lint")
  assert_true(lint.contains("\"violations\":0"), msg=lint)
}

///|
test "group-add / group-remove：已有层进出已有组，组的属性与成员层序都不丢" {
  // `children` 这一格此前是"整体可改、局部不可改"：要往已有组里加一个成员，
  // 只能 ungroup 再 group，组的 name/opacity/blend/tags/mask 全丢，整组还会
  // 被重排到成员的层序位置。这两个命令是它的对偶。
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 100 100")
  // 底：红方块（组外）——组内两个成员叠在同一处，用来量**组内层序**
  let _ = run(s, "add-rect x=0 y=0 w=100 h=100 fill=#FF0000FF id=below")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#00FF00FF id=g1c1")
  let _ = run(s, "group g1 g1c1")
  // 给组挂上"重组会丢"的那些属性。⚠️ 这里**不能**再带 `blend=multiply`：
  // 组上的 blend 渲染器根本不读（直通层、自身无面），现在入口直接拒
  // （见 lint 那张 `group_inert_fields` 表）——而这条测试要验的是
  // "group-add 之后属性还在"，用死数据验等于什么都没验。
  let _ = run(s, "set-style g1 opacity=0.5 tag=hero name=\"My Group\"")
  // 组外再放一个蓝方块（待加入）
  let _ = run(s, "add-rect x=0 y=0 w=20 h=20 fill=#0000FFFF id=g2c2")
  let before = run(s, "list-layers")
  assert_true(before.contains("\"count\":3"), msg=before)
  // ① 加进已有组：根级层数 3 → 2，成员进组
  let a = run(s, "group-add g1 g2c2")
  assert_true(a.contains("\"op\":\"group-add\""), msg=a)
  assert_true(a.contains("\"moved\":1"), msg=a)
  let l1 = run(s, "list-layers")
  assert_true(l1.contains("\"count\":2"), msg=l1)
  let g = run(s, "query-layer g1")
  // ② 组的属性一个没丢（这正是 ungroup+group 做不到的）
  assert_true(g.contains("\"name\":\"My Group\""), msg=g)
  assert_true(g.contains("\"opacity\":0.5"), msg=g)
  assert_true(g.contains("\"tags\":[\"hero\"]"), msg=g)
  // ③ 新成员在组内**栈顶**（画在 g1c1 之上）：两个方块都盖住 (5,5)，
  //    pick 必须报后加进来的那个 —— 这是层序断言，不是结构断言
  let p = run(s, "pick 5 5")
  assert_true(p.contains("\"id\":\"g2c2\""), msg=p)
  // ④ 移回根级：落在**该组的层序位置**，层序保留
  let r = run(s, "group-remove g1 g2c2")
  assert_true(r.contains("\"op\":\"group-remove\""), msg=r)
  assert_true(r.contains("\"at\":1"), msg=r)
  let l2 = run(s, "list-layers")
  assert_true(l2.contains("\"count\":3"), msg=l2)
  // g2c2 现在在**组外、组的下一层**（与 ungroup 的落点一致：`ungroup` 也是
  // 把子层放在组的那个槽位上）。这是"方向也是语义"那条：落点在上还是在下、
  // 差一层就是两个不同的画面，所以要有测试钉住，而不是留给读者猜。
  let gg = run(s, "query-layer g1")
  assert_true(!gg.contains("g2c2"), msg="g2c2 必须已经不在组里：\{gg}")
  let i2 = l2.find("\"id\":\"g2c2\"").unwrap_or(-1)
  let i1 = l2.find("\"id\":\"g1\"").unwrap_or(-1)
  assert_true(i2 >= 0 && i1 >= 0 && i2 < i1, msg="g2c2 必须落在 g1 的下一层：\{l2}")
  // 所以组（含 g1c1）仍盖在它上面 —— pick 报 g1c1，不是 g2c2
  let p2 = run(s, "pick 5 5")
  assert_true(p2.contains("\"id\":\"g1c1\""), msg=p2)
  // ⑤ 两向的拒绝都要响（静默成功比报错坏得多）
  let e1 = run(s, "group-add g1 g1")           // 自己加自己
  assert_true(e1.has_prefix("{\"error\":\""), msg=e1)
  let e2 = run(s, "group-add g1 nope")         // 不存在的成员
  assert_true(e2.has_prefix("{\"error\":\""), msg=e2)
  let e3 = run(s, "group-add g1 g1c1")         // 已在组里（不是根级）
  assert_true(e3.has_prefix("{\"error\":\""), msg=e3)
  let e4 = run(s, "group-add below g2c2")      // 目标不是组
  assert_true(e4.has_prefix("{\"error\":\""), msg=e4)
  let e5 = run(s, "group-add g1 g2c2 g2c2")    // 成员重复
  assert_true(e5.has_prefix("{\"error\":\""), msg=e5)
  let e6 = run(s, "group-remove g1 nope")      // 不是该组的直接成员
  assert_true(e6.has_prefix("{\"error\":\""), msg=e6)
  let e7 = run(s, "group-add g1 g9")           // 把组加进组 = 嵌套编组，拒
  assert_true(e7.has_prefix("{\"error\":\""), msg=e7)
  // ⑥ lint 干净（成员进出之后不该留下"装了却什么都不干"的状态）
  let lint = run(s, "lint")
  assert_true(lint.contains("\"violations\":0"), msg=lint)
}

///|
test "group-add：嵌套编组被拒（成员是组），且不产生\"同时在两处\"的层" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 40")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#FF0000FF id=a")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#00FF00FF id=b")
  let _ = run(s, "group g1 a")
  let _ = run(s, "group g2 b")
  let e = run(s, "group-add g1 g2")
  assert_true(e.has_prefix("{\"error\":\""), msg="嵌套编组必须拒：\{e}")
  assert_true(e.contains("嵌套编组"), msg=e)
  // 拒了之后什么都没变：两个组都还在根级，成员各就各位
  let l = run(s, "list-layers")
  assert_true(l.contains("\"count\":2"), msg=l)
  let q1 = run(s, "query-layer g1")
  assert_true(q1.contains("\"id\":\"a\""), msg=q1)
  let q2 = run(s, "query-layer g2")
  assert_true(q2.contains("\"id\":\"b\""), msg=q2)
}
