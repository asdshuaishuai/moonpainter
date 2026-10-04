/// 步骤/历史（③ 每步可见、可跳回）：`history` + `goto`。
///
/// 这一组判据要两头咬：
/// ①**跳回去真的是那一刻**——不是"指纹对上了"就算：指纹只描述 design.json，
///   而画面是渲染出来的。所以每一步都同时记**指纹 + render sha256**，跳回后
///   两个都要逐位相同；并且先自证"第 2 步与第 3 步的 sha 本来不同"，
///   否则这条断言在"渲染没跟上"时也会绿。
/// ②**跳回去之后动手，未来真的没了**——面板上不许留"看得见、跳不回去"的幽灵步骤。

/// 字符串字段取值复用 `caps_test.mbt` 里的 `jstr_field`（同包一处实现）。

/// 布尔字段取值（`can_undo`/`can_redo` 这类；数值/字符串辅助各自有实现）。
fn jbool_field(text : String, key : String) -> Bool {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  match obj.get(key).bind(fn(v) { v.as_bool() }) {
    Some(b) => b
    None => abort("回包字段 \{key} 不是布尔：\{text}")
  }
}

/// `steps` 数组里第 i 项的 `done`（面板据此画灰行）。
fn step_done(text : String, idx : Int) -> Bool {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("history 不是 JSON（\{e}）：\{text}")
  }
  let arr = match obj.get("steps").bind(fn(v) { v.as_arr() }) {
    Some(a) => a
    None => abort("history 缺 steps 数组：\{text}")
  }
  let d = match arr[idx].get("done").bind(fn(v) { v.as_bool() }) {
    Some(b) => b
    None => abort("steps[\{idx}] 缺 done（或不是布尔）：\{text}")
  }
  d
}

/// 干 `n` 步，返回 `marks[i]` = **第 i 步那个状态**的（指纹, 渲染 sha），
/// 含 `i = 0`（初始）与 `i = n`（收尾）⇒ 长度 `n + 1`、下标即步号。
fn step_marks(s : @agent.Session, n : Int) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let mut i = 0
  while i <= n {
    let f = jstr_field(run(s, "fingerprint"), "fingerprint")
    let r = run(s, "render 60")
    let sha = jstr_field(r, "render_sha256")
    out.push((f, sha))
    if i < n {
      // 每一步都必须真的改变画面——不改的话"跳回去 = 那一刻"就是空话
      let _ = run(s, "add-rect x=\{i * 6} y=0 w=4 h=4 fill=#FF0000FF")
    }
    i = i + 1
  }
  out
}

///|
test "history/goto：跳回去 = 那一刻（指纹 + 渲染 sha 逐位相同），且未来步骤按 PS 语义截断" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 40 uuid=hist-test")
  // 空集也要说话：刚开始一步都没有，游标 0、总数 0
  let h0 = run(s, "history")
  assert_true(jnum_field(h0, "cursor") == 0.0, msg=h0)
  assert_true(jnum_field(h0, "count") == 0.0, msg=h0)
  assert_true(jnum_field(h0, "total") == 0.0, msg=h0)
  assert_true(jnum_field(h0, "base") == 0.0, msg=h0)
  // 干 4 步，记下每一步之后的指纹 + 渲染 sha
  let marks = step_marks(s, 4)
  let h1 = run(s, "history")
  assert_true(jnum_field(h1, "cursor") == 4.0, msg=h1)
  assert_true(jnum_field(h1, "total") == 4.0, msg=h1)
  assert_true(jbool_field(h1, "can_undo"), msg=h1)
  assert_true(!jbool_field(h1, "can_redo"), msg=h1)
  // 判别力自证：第 1 步与第 2 步的渲染结果**本来就不一样**
  assert_true(marks[1].1 != marks[2].1, msg="第 1/2 步渲染 sha 相同 ⇒ 下面的断言是空的")
  // 跳回第 2 步
  let g = run(s, "goto 2")
  assert_true(jstr_field(g, "op") == "goto", msg=g)
  assert_true(jnum_field(g, "step") == 2.0, msg=g)
  let f2 = jstr_field(run(s, "fingerprint"), "fingerprint")
  let r2 = jstr_field(run(s, "render 60"), "render_sha256")
  assert_true(f2 == marks[2].0, msg="指纹没回到第 2 步：\{f2} vs \{marks[2].0}")
  assert_true(r2 == marks[2].1, msg="画面没回到第 2 步：\{r2} vs \{marks[2].1}")
  // 面板口径：游标 2、未来 2 行标 done=false
  let h2 = run(s, "history")
  assert_true(jnum_field(h2, "cursor") == 2.0, msg=h2)
  assert_true(jnum_field(h2, "count") == 4.0, msg=h2)
  assert_true(jbool_field(h2, "can_redo"), msg=h2)
  assert_true(step_done(h2, 0), msg=h2)
  assert_true(step_done(h2, 1), msg=h2)
  assert_true(!step_done(h2, 2), msg="第 3 步是未来步骤，面板必须知道：\{h2}")
  assert_true(!step_done(h2, 3), msg=h2)
  // 往前也走得回去（复用 redo 原语）
  let g4 = run(s, "goto 4")
  assert_true(jnum_field(g4, "step") == 4.0, msg=g4)
  assert_true(jstr_field(run(s, "fingerprint"), "fingerprint") == marks[4].0, msg="没回到第 4 步")
  assert_true(jstr_field(run(s, "render 60"), "render_sha256") == marks[4].1, msg="第 4 步画面不对")
  // 回到第 2 步再动手 ⇒ 未来那 3 步**真的没了**（不是"留在面板上跳不回去"）
  let _ = run(s, "goto 2")
  let _ = run(s, "add-rect x=50 y=0 w=3 h=3 fill=#0000FFFF")
  let h3 = run(s, "history")
  assert_true(jnum_field(h3, "cursor") == 3.0, msg=h3)
  assert_true(jnum_field(h3, "total") == 3.0, msg=h3)
  assert_true(jnum_field(h3, "count") == 3.0, msg=h3)
  assert_true(!jbool_field(h3, "can_redo"), msg=h3)
  let red = run(s, "redo")
  assert_true(red.has_prefix("{\"error\":\"重做栈为空"), msg=red)
  // `goto 0` = `new` 之后的初始文档
  let g0 = run(s, "goto 0")
  assert_true(jnum_field(g0, "step") == 0.0, msg=g0)
  let h4 = run(s, "history")
  assert_true(jnum_field(h4, "cursor") == 0.0, msg=h4)
  assert_true(!jbool_field(h4, "can_undo"), msg=h4)
  assert_true(!step_done(h4, 0), msg=h4)
  // 再往前（跳回来之后的 undo 也不会把游标带下 0）
  let un = run(s, "undo")
  assert_true(un.has_prefix("{\"error\":\"撤销栈为空"), msg=un)
  assert_true(jnum_field(run(s, "history"), "cursor") == 0.0, msg="游标不许变成负数")
}

///|
test "history/goto：越界与坏参数在入口拒绝，并把能回去的范围报出来" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 40 30 uuid=hist-bad")
  let _ = run(s, "add-rect x=0 y=0 w=10 h=10 fill=#FF0000FF")
  let e1 = run(s, "goto 99")
  assert_true(e1.has_prefix("{\"error\":\"第 99 步还不存在"), msg=e1)
  assert_true(e1.contains("当前总步数是 1"), msg=e1)
  let e2 = run(s, "goto abc")
  assert_true(e2.has_prefix("{\"error\":\"goto 的步号=abc 不是整数"), msg=e2)
  let e3 = run(s, "goto")
  assert_true(e3.has_prefix("{\"error\":\"用法：goto <步号>"), msg=e3)
  let e4 = run(s, "goto -1")
  assert_true(e4.has_prefix("{\"error\":\"回不到第 -1 步"), msg=e4)
  // 正控：边界上的 1 与 0 都收
  assert_true(run(s, "goto 1").contains("\"ok\":true"), msg="第 1 步必须跳得到")
  assert_true(run(s, "goto 0").contains("\"ok\":true"), msg="第 0 步必须跳得到")
}

///|
test "history：撤销栈容量上限（64）后如实报出「还能回去的最早一步」" {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 30 30 uuid=hist-cap")
  let mut i = 0
  // 70 步 > 64 的容量：最早的几步快照会被丢掉
  while i < 70 {
    let _ = run(s, "add-rect x=0 y=0 w=1 h=1 fill=#FF0000FF")
    i = i + 1
  }
  let h = run(s, "history")
  assert_true(jnum_field(h, "cursor") == 70.0, msg=h)
  assert_true(jnum_field(h, "base") == 70.0 - jnum_field(h, "count"), msg=h)
  assert_true(jnum_field(h, "count") <= 64.0, msg=h)
  assert_true(jnum_field(h, "base") > 0.0, msg="70 步之后 base 必须已经往后挪：\{h}")
  // 越过早于 base 的步号 ⇒ 入口拒绝并说清只保留最近多少步（不是静默跳错）
  let e = run(s, "goto 0")
  assert_true(e.has_prefix("{\"error\":\"回不到第 0 步"), msg=e)
  assert_true(e.contains("只保留最近"), msg=e)
  // 窗口内最老的一步仍跳得回去
  let base = jnum_field(h, "base")
  let ok = run(s, "goto \{base.to_int()}")
  assert_true(ok.contains("\"ok\":true"), msg=ok)
}

///|
/// **类级判据**：任何"会改文档"的命令，撤销之后都必须**逐位**回到命令之前
/// （指纹相等，不只是"画面看着一样"）。
///
/// 这条不是为了抓某一个命令，而是抓**这一类**：快照必须在命令之前抓（`exec`
/// 入口一处），而 `next_layer_no` 这种"看着不重要、其实进 canonical JSON"的
/// 字段最容易漏——实测 4 次 `add-rect` 后 `undo` 两次得到的 `next_layer_no` 是 4
/// 而直接建两层是 3：画面一模一样，只有指纹（与它代表的"同一状态必须同一指纹"）
/// 露馅。新增命令若在快照之前动了 doc，这里立刻红。
test "撤销逐位回到那一刻：一批变更命令逐个验（含自证「这些命令真的改了文档」）" {
  // (准备命令, 被测命令)——准备命令先在干净文档上跑完，再记指纹。
  let cases : Array[(Array[String], String)] = [
    ([], "add-rect x=1 y=1 w=6 h=6 fill=#FF0000FF"),
    ([], "add-ellipse x=1 y=1 w=6 h=6 fill=#00FF00FF"),
    ([], "add-polygon x=0 y=0 w=9 h=9 points=0,0;8,0;8,8 fill=#0000FFFF"),
    ([], "add-line x=0 y=0 w=9 h=9 points=0,0;8,8"),
    ([], "add-text x=1 y=1 text=Hi font_size=12"),
    ([], "add-paint name=涂鸦"),
    ([], "add-adjust op=brightness value=0.4"),
    (["add-paint name=层"], "brush layer=l1 pts=2,2;9,9 r=3 color=#FF0000FF"),
    (["add-paint name=层"], "erase layer=l1 pts=2,2;9,9 r=3"),
    (["add-rect x=0 y=0 w=4 h=4 fill=#FF0000FF"], "add-mask l1 kind=rect x=1 y=1 w=3 h=3"),
    ([], "set-canvas 40 30"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "group g1 l1"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "rename l1 新名字"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "move l1 3 4"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "resize l1 7 8"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "rotate l1 30"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "flip l1 h"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "visible l1 false"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "set-style l1 stroke_w=2 stroke=#000000FF"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "tag l1 背景"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF", "tag l1 背景"], "untag l1 背景"),
    (["add-rect x=0 y=0 w=2 h=2 fill=#FF0000FF"], "delete l1"),
    ([], "set-param k v"),
  ]
  let mut i = 0
  for pair in cases {
    let (setup, cmd) = pair
    let s = @agent.Session::new()
    let _ = run(s, "session-open full_image")
    let _ = run(s, "new 48 32 uuid=undo-bit-\{i}")
    let mut j = 0
    while j < setup.length() {
      let r = run(s, setup[j])
      assert_true(r.contains("\"ok\":true"), msg="准备命令失败（\{setup[j]}）：\{r}")
      j = j + 1
    }
    let pre = jstr_field(run(s, "fingerprint"), "fingerprint")
    let rm = run(s, cmd)
    assert_true(rm.contains("\"ok\":true"), msg="被测命令失败（\{cmd}）：\{rm}")
    let after = jstr_field(run(s, "fingerprint"), "fingerprint")
    assert_true(
      after != pre,
      msg="这条命令一个字节都没改文档（那下面的断言是空的）：\{cmd} → \{rm}",
    )
    let ru = run(s, "undo")
    assert_true(ru.contains("\"ok\":true"), msg="undo 失败（\{cmd}）：\{ru}")
    let back = jstr_field(run(s, "fingerprint"), "fingerprint")
    assert_true(back == pre, msg="撤销没逐位回到那一刻：\{cmd} → \{back} vs \{pre}")
    i = i + 1
  }
}
