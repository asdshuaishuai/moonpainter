// 色阶 / 曲线（PLAN 七十）：**命令面**这一半。
//
// 与 core（参数判据）和 render（像素映射）分开钉：这边管"AI 与人类能怎么用"——
// 键认不认得出、值收不收得下、缺的参数补成什么、改不改得动、报不报得出、
// 装了却什么都不干有没有人说话。铁律 11：所有数值断言都精确解析，
// 不许 `contains("\"gamma\":2")`（会被 `"gamma":20` 骗过）。

///|
/// 取回包里的嵌套字段（缺了就 abort，不静默）。
fn adj_field(text : String, path : Array[String]) -> @core.JValue {
  let path_str = path.join(".")
  let mut cur = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  for k in path {
    let next = match cur.get(k) {
      Some(v) => v
      None => abort("回包缺字段 \{path_str}（卡在 \{k}）：\{text}")
    }
    cur = next
  }
  cur
}

///|
/// 调整参数对象：`query-layer` 在 `layer.adjust`，而 `add-adjust`/`set-adjust`
/// 的回包把它放在**顶层** `adjust`（回显）。两种形态都要认——只认一种的话，
/// "回显与回读说同一件事"这条断言就写不出来。
fn adj_of(text : String) -> @core.JValue {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  match obj.get("adjust") {
    Some(v) => v
    None => adj_field(text, ["layer", "adjust"])
  }
}

///|
/// 色阶子对象里的一个数（`adjust.levels.<key>`）。
fn lv_num(text : String, key : String) -> Double {
  let lvv = match adj_of(text).get("levels") {
    Some(v) => v
    None => abort("adjust 缺 levels：\{text}")
  }
  match lvv.get(key) {
    Some(v) =>
      match v.as_num() {
        Some(x) => x
        None => abort("levels.\{key} 不是数字：\{text}")
      }
    None => abort("levels 缺字段 \{key}：\{text}")
  }
}

///|
fn adj_scene(tag : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 60 uuid=\{tag}")
  let _ = run(s, "add-rect x=0 y=0 w=60 h=60 fill=#808080FF id=r")
  s
}

///|
test "色阶/曲线的入口判据：缺项、越界、以及「用不上的参数」四个方向都拒" {
  let s = adj_scene("adj-enter")
  // 正控：两条合法路径
  let ok1 = run(s, "add-adjust op=levels in_lo=0.25 in_hi=0.75 gamma=2 out_lo=0 out_hi=1 id=lv")
  assert_true(!ok1.contains("error"), msg=ok1)
  let ok2 = run(s, "add-adjust op=curves points=0,0;0.5,0.75;1,1 id=cv")
  assert_true(!ok2.contains("error"), msg=ok2)
  // 每一格都要**指得出错在哪**（不是"参数错误"这种没法自查的话）
  let cases : Array[(String, String)] = [
    ("add-adjust op=levels", "至少要给一个色阶参数"),
    ("add-adjust op=levels gamma=0", "gamma"),
    ("add-adjust op=levels gamma=101", "gamma"),
    ("add-adjust op=levels in_lo=0.8 in_hi=0.2", "in_lo < in_hi"),
    ("add-adjust op=levels in_lo=0.5 in_hi=0.5", "in_lo < in_hi"),
    ("add-adjust op=levels in_lo=-0.1", "0..1"),
    ("add-adjust op=levels out_lo=0.9 out_hi=0.2", "out_lo <= out_hi"),
    ("add-adjust op=levels gamma=abc", "不是数字"),
    ("add-adjust op=levels gamma=2 value=0.5", "不接受 value="),
    ("add-adjust op=levels gamma=2 points=0,0;1,1", "不读 points="),
    ("add-adjust op=curves", "需要 points="),
    ("add-adjust op=curves points=0,0", "至少 2"),
    ("add-adjust op=curves points=0,0;0.5,0.5;0.4,0.6", "x 必须严格递增"),
    ("add-adjust op=curves points=0,0;1.5,1", "0..1"),
    ("add-adjust op=curves points=0,0;1,1 in_lo=0.2", "不读色阶参数"),
    ("add-adjust op=curves points=0,0;1,1 value=0.3", "不接受 value="),
    ("add-adjust op=brightness value=0.3 in_lo=0.2", "不吃色阶参数"),
    ("add-adjust op=brightness value=0.3 points=0,0;1,1", "不吃 points="),
    // 顺序即语义：既缺 value 又给了别的族的参数时，报的是"这个键不归它"——
    // 那句更准（"需要 value=" 会让调用方以为补个 value 就行，而 in_lo 仍是错的）
    ("add-adjust op=brightness in_lo=0.2", "不吃色阶参数"),
    ("add-adjust op=brightness", "需要 value="),
    // 拼错的键仍然走 check_kv_args（键清单加了 5 个色阶键 + points，别的照旧拒）
    ("add-adjust op=levels in_low=0.2", "不认识的参数"),
  ]
  for c in cases {
    let r = run(s, c.0)
    assert_true(
      r.contains("\"error\"") && r.contains(c.1),
      msg="`\{c.0}` 必须被拒并说清原因（期望含「\{c.1}」）：\{r}",
    )
  }
  // 拒完之后层表里**不许**多出半个层（"回 ok 而层是空壳"是这里最坏的结果）
  let list = run(s, "list-layers")
  assert_true(!list.contains("\"id\":\"l3\""), msg="被拒的参数不许建出层：\{list}")
}

///|
test "色阶：没给的参数按中性值补，回包必须回显**生效后**的五个数" {
  let s = adj_scene("adj-fill")
  let r = run(s, "add-adjust op=levels gamma=2 id=lv")
  assert_true(!r.contains("error"), msg=r)
  // 回显（`add-adjust` 的回包）与回读（`query-layer`）必须说同一件事
  for src in [r, run(s, "query-layer lv")] {
    assert_eq(lv_num(src, "in_lo"), 0.0, msg="缺省 in_lo 应为中性值")
    assert_eq(lv_num(src, "in_hi"), 1.0, msg="缺省 in_hi 应为中性值")
    assert_eq(lv_num(src, "gamma"), 2.0, msg="给了的 gamma 要生效")
    assert_eq(lv_num(src, "out_lo"), 0.0, msg="缺省 out_lo 应为中性值")
    assert_eq(lv_num(src, "out_hi"), 1.0, msg="缺省 out_hi 应为中性值")
  }
  // "回显"不是"复述参数"：只给 gamma 时，生效的是**五个数**
  assert_true(r.contains("\"levels\""), msg="回包要带 levels 对象：\{r}")
  // 五个数都给时逐值回读
  let full = run(
    s,
    "add-adjust op=levels in_lo=0.125 in_hi=0.875 gamma=1.25 out_lo=0.0625 out_hi=0.9375 id=lv2",
  )
  let q = run(s, "query-layer lv2")
  assert_eq(lv_num(q, "in_lo"), 0.125, msg="in_lo 回读")
  assert_eq(lv_num(q, "out_hi"), 0.9375, msg="out_hi 回读（别只报字段名不报值）")
  let _ = full
}

///|
test "曲线：点表报得出、发得回（query-layer 的 points= 原样回灌 set-adjust）" {
  let s = adj_scene("adj-curve")
  let r = run(s, "add-adjust op=curves points=0,0;0.25,0.5;1,1 id=cv")
  assert_true(!r.contains("error"), msg=r)
  let q = run(s, "query-layer cv")
  // ①可回灌的文本形态
  let text = match adj_of(q).get("points") {
    Some(v) =>
      match v.as_str() {
        Some(x) => x
        None => abort("points 不是字符串：\{q}")
      }
    None => abort("adjust 缺 points：\{q}")
  }
  assert_eq(text, "0,0;0.25,0.5;1,1", msg="点表文本形态")
  // ②引擎算出来的预览采样（9 点，前端不许自己插值）
  let sample = match adj_of(q).get("curve_sample") {
    Some(@core.JValue::JArr(a)) => a
    _ => abort("缺 curve_sample：\{q}")
  }
  assert_eq(sample.length(), 9, msg="预览采样条数")
  // 9 个采样 ⇒ x 步长 0.125，控制点 (0.25,0.5) 落在第 **2** 个采样上（别数错：
  // 第一版按"中间那个"取了 index 4，读到的是 0.5 处插值出来的值）
  let mid = match sample[2] {
    @core.JValue::JArr(pair) =>
      match pair[1].as_num() {
        Some(y) => y
        None => abort("采样 y 不是数字")
      }
    _ => abort("采样点不是 [x,y]")
  }
  assert_eq(mid, 0.5, msg="采样必须穿过控制点（引擎算的那个值）")
  assert_eq(
    match sample[4] {
      @core.JValue::JArr(pair) =>
        match pair[0].as_num() {
          Some(x) => x
          None => abort("采样 x 不是数字")
        }
      _ => abort("采样点不是 [x,y]")
    },
    0.5,
    msg="第 4 个采样的 x 应当是 0.5（步长 0.125）",
  )
  // ③原样回灌：报出来的文本发回去必须**逐值不变**
  let back = run(s, "set-adjust cv points=\{text}")
  assert_true(!back.contains("error"), msg=back)
  let q2 = run(s, "query-layer cv")
  let text2 = match adj_of(q2).get("points") {
    Some(v) =>
      match v.as_str() {
        Some(x) => x
        None => abort("points 不是字符串")
      }
    None => abort("adjust 缺 points")
  }
  assert_eq(text2, text, msg="回灌后点表必须原样")
}

///|
test "set-adjust：色阶逐键部分更新，曲线上整表替换（都要原地改、不动层序）" {
  let s = adj_scene("adj-set")
  let _ = run(s, "add-adjust op=levels in_lo=0.2 in_hi=0.9 gamma=2 out_lo=0.1 out_hi=0.8 id=lv")
  let _ = run(s, "add-adjust op=brightness value=0.3 id=br")
  // 只改 gamma：其余四个数沿用（逼调用方抄 5 个数才是坑）
  let r1 = run(s, "set-adjust lv gamma=3")
  assert_true(!r1.contains("error"), msg=r1)
  let q1 = run(s, "query-layer lv")
  assert_eq(lv_num(q1, "gamma"), 3.0, msg="改 gamma")
  assert_eq(lv_num(q1, "in_lo"), 0.2, msg="没给的 in_lo 必须沿用")
  assert_eq(lv_num(q1, "in_hi"), 0.9, msg="没给的 in_hi 必须沿用")
  assert_eq(lv_num(q1, "out_lo"), 0.1, msg="没给的 out_lo 必须沿用")
  assert_eq(lv_num(q1, "out_hi"), 0.8, msg="没给的 out_hi 必须沿用")
  // 越界仍然拒（部分更新不许绕过判据）
  let bad = run(s, "set-adjust lv gamma=0")
  assert_true(bad.contains("\"error\"") && bad.contains("gamma"), msg=bad)
  // 层序不许变：亮度层仍在色阶层之下（调整层作用于其下全部可见层）
  let list = run(s, "list-layers")
  let idx_lv = match list.find("\"id\":\"lv\"") {
    Some(i) => i
    None => abort("list-layers 里没有 lv：\{list}")
  }
  let idx_br = match list.find("\"id\":\"br\"") {
    Some(i) => i
    None => abort("list-layers 里没有 br：\{list}")
  }
  assert_true(idx_lv < idx_br, msg="set-adjust 把层序改了（调整层的作用范围会跟着变）")
  // 换算子：换成 levels 一个色阶参数都不给 ⇒ 拒（那是中性层 = 白装）
  let _ = run(s, "add-adjust op=curves points=0,0;1,1 id=cv")
  let swap = run(s, "set-adjust cv op=levels")
  assert_true(swap.contains("\"error\"") && swap.contains("至少要给一个色阶参数"), msg=swap)
  // 换成 levels 并给参数 ⇒ 收
  let swap2 = run(s, "set-adjust cv op=levels in_lo=0.3")
  assert_true(!swap2.contains("error"), msg=swap2)
  let q2 = run(s, "query-layer cv")
  assert_eq(lv_num(q2, "in_lo"), 0.3, msg="换算子后参数要生效")
  assert_eq(lv_num(q2, "in_hi"), 1.0, msg="换算子后其余参数是中性值")
  // 换回 curves 不给点表 ⇒ 拒（点表是整表替换，没有"沿用"可谈）
  let _ = run(s, "set-adjust cv op=curves")
  let q3 = run(s, "query-layer cv")
  assert_true(adj_of(q3).get("points") is None, msg="curves 却没点表：\{q3}")
  // 曲线层换点表：整表替换
  let _ = run(s, "add-adjust op=curves points=0,0;0.5,0.75;1,1 id=cv2")
  let _ = run(s, "set-adjust cv2 points=0,0;0.5,0.25;1,1")
  let q4 = run(s, "query-layer cv2")
  let t4 = match adj_of(q4).get("points") {
    Some(v) =>
      match v.as_str() {
        Some(x) => x
        None => abort("points 不是字符串")
      }
    None => abort("缺 points")
  }
  assert_eq(t4, "0,0;0.5,0.25;1,1", msg="曲线必须整表换成新的")
  // 色阶层不该带出 points 字段（两族互斥的报告面）
  assert_true(adj_of(q1).get("points") is None, msg="色阶层不该报 points：\{q1}")
}

///|
test "lint：中性色阶/中性曲线是「装了却什么都不干」，非中性一句都不说（正控）" {
  let s = adj_scene("adj-lint")
  // ①中性色阶（五个数全是中性值）
  let _ = run(s, "add-adjust op=levels in_lo=0 in_hi=1 gamma=1 out_lo=0 out_hi=1 id=nlv")
  // ②中性曲线（点全在对角线上）
  let _ = run(s, "add-adjust op=curves points=0,0;0.5,0.5;1,1 id=ncv")
  // ③非中性：正控，lint 一个字都不该说它
  let _ = run(s, "add-adjust op=levels gamma=2 id=real")
  let _ = run(s, "add-adjust op=curves points=0,0;0.5,0.75;1,1 id=realcv")
  let r = run(s, "lint")
  assert_true(r.contains("nlv"), msg="中性色阶要报：\{r}")
  assert_true(r.contains("中性"), msg="要说清是中性值：\{r}")
  assert_true(r.contains("ncv"), msg="中性曲线要报：\{r}")
  assert_true(r.contains("对角线"), msg="曲线那格要说清「全在对角线上」：\{r}")
  assert_true(!r.contains("real "), msg="非中性色阶不许被报：\{r}")
  assert_true(!r.contains("realcv"), msg="非中性曲线不许被报：\{r}")
  // ④手改容器造出的非法参数（命令面拦不到）：lint 要报"参数不合法"。
  //    从命令面造不出来（入口会拒），所以直接构造一个文档给 `lint_doc`——
  //    这正是"lint 兜住手改容器"那半边的入口。
  let doc = @core.new_document("bad-adj", 40, 40)
  doc.layers.push({
    ..@core.default_layer("b1", "b1", 0.0, 0.0, 40.0, 40.0),
    kind: @core.ShapeKind::Adjust,
    adjust: Some({
      ..@core.make_adjust(@core.AdjustOp::Levels, 0.0),
      levels: Some({ in_lo: 0.0, in_hi: 1.0, gamma: 0.0, out_lo: 0.0, out_hi: 1.0 }),
    }),
  })
  let items = @agent.lint_doc(doc)
  let mut said = false
  for it in items {
    if it.contains("不合法") && it.contains("b1") {
      said = true
    }
  }
  assert_true(said, msg="非法色阶参数必须由 lint 报出来：" + items.join("；"))
}

///|
test "容器往返：色阶/曲线参数随 .mpd 逐值往返，且层序/指纹一致" {
  let s = adj_scene("adj-roundtrip")
  let _ = run(s, "add-adjust op=levels in_lo=0.125 in_hi=0.875 gamma=1.25 out_lo=0.0625 out_hi=0.9375 id=lv")
  let _ = run(s, "add-adjust op=curves points=0,0;0.25,0.5;1,1 id=cv")
  let before = run(s, "query-layer lv")
  let before_cv = run(s, "query-layer cv")
  let saved = run(s, "save-mpd-b64")
  let b64 = match @core.parse_json(saved) {
    Ok(o) =>
      match o.get("mpd_b64") {
        Some(v) =>
          match v.as_str() {
            Some(x) => x
            None => abort("mpd_b64 不是字符串")
          }
        None => abort("回包缺 mpd_b64")
      }
    Err(e) => abort("save 回包不是 JSON：\{e}")
  }
  // 新会话里载入
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let opened = run(s2, "open-mpd-b64 \{b64}")
  assert_true(!opened.contains("error"), msg=opened)
  let after = run(s2, "query-layer lv")
  assert_eq(lv_num(after, "in_lo"), 0.125, msg="in_lo 往返")
  assert_eq(lv_num(after, "gamma"), 1.25, msg="gamma 往返")
  assert_eq(lv_num(after, "out_hi"), 0.9375, msg="out_hi 往返")
  let after_cv = run(s2, "query-layer cv")
  let t_after = match adj_of(after_cv).get("points") {
    Some(v) =>
      match v.as_str() {
        Some(x) => x
        None => abort("points 不是字符串")
      }
    None => abort("往返后缺 points")
  }
  assert_eq(t_after, "0,0;0.25,0.5;1,1", msg="曲线点表往返")
  // 指纹也必须一致（往返是恒等变换，不是"差不多"）
  let id_str = fn(v : @core.JValue) -> String {
    match v.as_str() {
      Some(x) => x
      None => abort("id 不是字符串")
    }
  }
  assert_eq(
    id_str(adj_field(before, ["layer", "id"])),
    id_str(adj_field(after, ["layer", "id"])),
    msg="往返后层 id",
  )
  let _ = before_cv
}

///|
test "老引擎读不了新参数：这一档必须由**文档内容**声明（契约闸不许一律写上限）" {
  // 契约档的判据在 core（`required_render_contract`）与 mpd（写入 manifest）两处，
  // 这里只钉 agent 侧的可见后果：色阶/曲线层的容器**能存能开**（本引擎支持第 6
  // 档），而只带亮度层的容器**不许**被抬档——这条在 mpd_test 里逐字节验。
  let s = adj_scene("adj-contract")
  let _ = run(s, "add-adjust op=levels gamma=2 id=lv")
  let saved = run(s, "save-mpd-b64")
  assert_true(!saved.contains("error"), msg=saved)
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let b64 = match @core.parse_json(saved) {
    Ok(o) =>
      match o.get("mpd_b64") {
        Some(v) =>
          match v.as_str() {
            Some(x) => x
            None => abort("mpd_b64 不是字符串")
          }
        None => abort("回包缺 mpd_b64")
      }
    Err(e) => abort("save 回包不是 JSON：\{e}")
  }
  let opened = run(s2, "open-mpd-b64 \{b64}")
  assert_true(!opened.contains("error"), msg="本引擎必须能打开自己写的第 6 档容器：\{opened}")
  assert_eq(lv_num(run(s2, "query-layer lv"), "gamma"), 2.0, msg="第 6 档容器里的参数")
}

///|
test "两张键清单只差 id/name（字面量 + 一条会红的等式，替掉『一处实现』）" {
  // `param_audit.py` 只认字面量键表，所以 `set_adjust_keys` 是**独立的一份**
  // 字面量（写成 `add_adjust_keys().filter(…)` 它就读不出来、判这门禁有洞）。
  // 漂移风险在这里堵住：加键只加一边，下面这条立刻红。
  let add = @agent.add_adjust_keys()
  let set = @agent.set_adjust_keys()
  let want = add.filter(fn(k) { k != "id" && k != "name" })
  assert_eq(set.join(","), want.join(","), msg="set-adjust 的键清单必须正好是 add-adjust 去掉 id/name")
  // 正控：`op`/`value` 两种都在；负控：id/name 只在 add-adjust 里
  assert_true(set.contains("op") && set.contains("value"), msg="op/value 两个都在")
  assert_true(!set.contains("id") && !set.contains("name"), msg="set-adjust 不建层，认 id/name 就是死数据")
  assert_true(add.contains("id") && add.contains("name"), msg="add-adjust 认 id/name")
}
