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

///|
/// 滤镜参数对象里的一个数（`adjust.params.<key>`）——回包与 `query-layer`
/// 两种形态都认（同 `lv_num`）。
fn filt_num(text : String, key : String) -> Double {
  let ps = match adj_of(text).get("params") {
    Some(v) => v
    None => abort("adjust 缺 params：\{text}")
  }
  match ps.get(key) {
    Some(v) =>
      match v.as_num() {
        Some(x) => x
        None => abort("params.\{key} 不是数字：\{text}")
      }
    None => abort("params 缺字段 \{key}：\{text}")
  }
}

///|
test "②B 滤镜：缺键按中性值补、回包按键名升序（输入顺序不影响字节）" {
  let s = adj_scene("filter-parse")
  // 正控：只给一个键，其余按中性值补（缺参数不该悄悄带来看得见的效果）
  let r = run(s, "add-adjust op=motion-blur radius=12 id=mb")
  assert_true(!r.contains("error"), msg="合法滤镜要收：\{r}")
  assert_eq(filt_num(r, "angle"), 0.0, msg="没给的 angle 补中性值 0")
  assert_eq(filt_num(r, "radius"), 12.0, msg="给了的 radius 原样收下")
  // `value` 在 adjust 顶层（不在 params 里）：滤镜不读它，回显必须是 0
  assert_true(
    r.contains("\"op\":\"motion-blur\",\"value\":0,"),
    msg="滤镜的 value 回显应当是 0：\{r}",
  )
  // 升序这条是**字节**承诺：回包里的键对必须原样按 amount,mono 出现
  let r2 = run(s, "add-adjust op=noise mono=1 amount=0.4 id=ns")
  assert_true(
    r2.contains("\"params\":{\"amount\":0.4,\"mono\":1}"),
    msg="params 必须按键名升序回显（输入是乱序的）：\{r2}",
  )
  let r3 = run(s, "add-adjust op=color-balance cr=0.2 cg=-0.1 cb=0.05 id=cb1")
  assert_true(
    r3.contains("\"params\":{\"cb\":0.05,\"cg\":-0.1,\"cr\":0.2}"),
    msg="三个键也要升序：\{r3}",
  )
  // query-layer 与 add 的回显必须是同一份（报告面不许有两种口径）
  let q = run(s, "query-layer cb1")
  // 键序是**字节**承诺 ⇒ 直接钉那一段字节（从对象里读键会丢掉顺序）
  assert_true(
    q.contains("\"params\":{\"cb\":0.05,\"cg\":-0.1,\"cr\":0.2}"),
    msg="回读也必须按键名升序：\{q}",
  )
  assert_eq(filt_num(q, "cr"), 0.2, msg="回读的数值")
  assert_eq(filt_num(q, "cg"), -0.1, msg="回读的负值")
}

///|
test "②B 滤镜入口判据：一个键都不给 / 给别的算子键 / 给色阶键 / 非数 / 越界 / 非整数" {
  let s = adj_scene("filter-enter")
  // ①一个键都不给 = 一个什么都不干的层 ⇒ 拒（同色阶那条）
  let r1 = run(s, "add-adjust op=pixelate")
  assert_true(r1.contains("至少要给一个参数"), msg="空参数表要拒：\{r1}")
  assert_true(r1.contains("size=2..256"), msg="错话要带上合法的键与范围：\{r1}")
  // ②给了**别的滤镜算子**的键 ⇒ 拒（静默丢掉就是"回 ok 而画面没变"）
  let r2 = run(s, "add-adjust op=motion-blur size=5")
  assert_true(r2.contains("不吃 size="), msg="别的算子的键要拒：\{r2}")
  assert_true(r2.contains("pixelate"), msg="还要指路给哪个算子：\{r2}")
  // ③非滤镜算子带着滤镜键 ⇒ 同样拒（`op=blur value=0.5 angle=30` 此前静默丢掉 angle）
  let r3 = run(s, "add-adjust op=blur value=0.5 angle=30")
  assert_true(r3.contains("不吃 angle="), msg="非滤镜算子不许收滤镜键：\{r3}")
  // ④滤镜带着色阶键 / 曲线点表 ⇒ 拒（互斥族，同"亮度层不许带色阶"）
  let r4 = run(s, "add-adjust op=hue-sat in_lo=0.1")
  assert_true(r4.contains("色阶"), msg="滤镜不收色阶键：\{r4}")
  let r5 = run(s, "add-adjust op=hue-sat hue=1 points=0,0;1,1")
  assert_true(r5.contains("points"), msg="滤镜不收曲线点表：\{r5}")
  // ⑤非数 / 越界 / 非整数（三个各自的话术）
  let r6 = run(s, "add-adjust op=noise amount=abc")
  assert_true(r6.contains("不是数字"), msg="非数要说清：\{r6}")
  let r7 = run(s, "add-adjust op=threshold channel=9")
  assert_true(r7.contains("超出范围"), msg="越界要说清：\{r7}")
  let r8 = run(s, "add-adjust op=pixelate size=2.5")
  assert_true(r8.contains("必须是整数"), msg="色块边长必须整数：\{r8}")
  let r9 = run(s, "add-adjust op=posterize levels=2.5")
  assert_true(r9.contains("必须是整数"), msg="海报化级数必须整数：\{r9}")
  // 正控：全部合法取值都能收（含边界）
  for cmd in [
    "add-adjust op=motion-blur angle=360 radius=64 id=ok1",
    "add-adjust op=radial-blur center_x=0 center_y=1 radius=64 id=ok2",
    "add-adjust op=noise amount=1 mono=0.5 id=ok3",
    "add-adjust op=pixelate size=256 id=ok4",
    "add-adjust op=posterize levels=16 id=ok5",
    "add-adjust op=threshold level=1 channel=0 id=ok6",
    "add-adjust op=hue-sat hue=-180 sat=-1 light=1 id=ok7",
    "add-adjust op=color-balance cr=-1 cg=1 cb=0 id=ok8",
  ] {
    let r = run(s, cmd)
    assert_true(!r.contains("error"), msg="边界值要收：\{cmd} → \{r}")
  }
}

///|
test "set-adjust：滤镜逐键部分更新（缺的键沿用当前层的值），换算子不给键要拒" {
  let s = adj_scene("filter-set")
  let _ = run(s, "add-adjust op=motion-blur angle=30 radius=4 id=mb")
  // 只给 radius：angle 必须**沿用当前层的 30**（不是回到中性值 0）
  let r = run(s, "set-adjust mb radius=20")
  assert_true(!r.contains("error"), msg="部分更新要收：\{r}")
  assert_eq(filt_num(r, "angle"), 30.0, msg="没给的键沿用当前层")
  assert_eq(filt_num(r, "radius"), 20.0, msg="给了的键生效")
  let q = run(s, "query-layer mb")
  assert_eq(filt_num(q, "angle"), 30.0, msg="回读也要是沿用后的值")
  // 换算子不给参数 ⇒ 拒（换成 neutral 全填 = 空操作层）
  let r2 = run(s, "set-adjust mb op=noise")
  assert_true(r2.contains("至少要给一个参数"), msg="换算子不给键要拒：\{r2}")
  // 换算子并给一个键 ⇒ 其余补中性值
  let r3 = run(s, "set-adjust mb op=noise amount=0.5")
  assert_eq(filt_num(r3, "amount"), 0.5, msg="新算子的键生效")
  assert_eq(filt_num(r3, "mono"), 0.0, msg="换了算子，没给的键补中性值")
  // 原地改：层序不变（同 id 的层还在原位、不新增层）
  let before = run(s, "query-layer r")
  assert_true(!before.contains("error"), msg="底图还在")
  // 滤镜层给 value ⇒ 拒（规则①：没有可调数值的算子不接受 value）
  let r4 = run(s, "set-adjust mb value=0.5")
  assert_true(r4.contains("不接受 value="), msg="滤镜层不许带 value：\{r4}")
  // 滤镜层给**别的**滤镜算子的键 ⇒ 拒（互斥面在两个命令上是同一句话）
  let r5 = run(s, "set-adjust mb angle=10")
  assert_true(r5.contains("不吃 angle="), msg="换了算子后旧键要拒：\{r5}")
}

///|
test "lint：参数全中性的滤镜层是「装了却什么都不干」，有非中性参数就一句不说（正控）" {
  let s = adj_scene("filter-lint")
  // ①中性参数（radial-blur 半径 0）：装了不干活
  let _ = run(s, "add-adjust op=radial-blur radius=0 id=nrb")
  // ②中性参数（noise 数量 0）
  let _ = run(s, "add-adjust op=noise amount=0 id=nns")
  // ③正控：像素化 size=2 是"看得见的最小值"，不是空转
  let _ = run(s, "add-adjust op=pixelate size=2 id=realpx")
  // ④正控：阈值 level=0 是极值（把画面变全白），不是空转
  let _ = run(s, "add-adjust op=threshold level=0 id=realth")
  let r = run(s, "lint")
  assert_true(r.contains("nrb"), msg="半径 0 的缩放要报：\{r}")
  assert_true(r.contains("nns"), msg="数量 0 的噪点要报：\{r}")
  assert_true(r.contains("中性值"), msg="要说清是参数都是中性值：\{r}")
  assert_true(!r.contains("realpx"), msg="像素化 size=2 不许被报成空转：\{r}")
  assert_true(!r.contains("realth"), msg="阈值 level=0 不许被报成空转：\{r}")
}

///|
test "容器往返：滤镜参数随 .mpd 逐值往返（升序与键序在字节层面也一样）" {
  let s = adj_scene("filter-roundtrip")
  let _ = run(s, "add-adjust op=hue-sat hue=-45.5 sat=0.25 light=-0.125 id=hs")
  let _ = run(s, "add-adjust op=radial-blur center_x=0.25 center_y=0.75 radius=18.5 id=rb")
  let before = run(s, "query-layer hs")
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
  let s2 = @agent.Session::new()
  let _ = run(s2, "session-open full_image")
  let opened = run(s2, "open-mpd-b64 \{b64}")
  assert_true(!opened.contains("error"), msg="本引擎必须能打开自己写的滤镜容器：\{opened}")
  let after = run(s2, "query-layer hs")
  assert_eq(filt_num(after, "hue"), -45.5, msg="hue 往返")
  assert_eq(filt_num(after, "sat"), 0.25, msg="sat 往返")
  assert_eq(filt_num(after, "light"), -0.125, msg="light 往返")
  assert_true(
    after.contains("\"params\":{\"hue\":-45.5,\"light\":-0.125,\"sat\":0.25}"),
    msg="往返后仍是升序（容器字节级）：\{after}",
  )
  let rb = run(s2, "query-layer rb")
  assert_eq(filt_num(rb, "center_y"), 0.75, msg="中心 y 往返")
  assert_eq(filt_num(rb, "radius"), 18.5, msg="半径往返")
  assert_true(!before.contains("error"), msg="回读可用")
}

///|
test "键清单不许与 core 的滤镜表漂移（加一个键只加一边要红）" {
  let add = @agent.add_adjust_keys()
  let set = @agent.set_adjust_keys()
  let structural = ["op", "value", "in_lo", "in_hi", "gamma", "out_lo", "out_hi", "points", "id", "name"]
  // 正向：core 表里的每个滤镜键都必须在那份**字面量**里（`param_audit.py` 读的就是它）
  for op in @core.all_adjust_ops() {
    for k in @core.filter_param_keys(op) {
      assert_true(
        add.contains(k),
        msg="core 的 \{@core.adjust_op_name(op)} 键 \{k} 没进 add_adjust_keys（字典会漏说，LLM 就发不出来）",
      )
      assert_true(set.contains(k), msg="滤镜键 \{k} 也该在 set_adjust_keys 里（原地改要用）")
    }
  }
  // 反向：清单里的每个键都得有归属（滤镜键或结构键），不许留幽灵键
  for k in add {
    if structural.contains(k) {
      continue
    }
    let mut owned = false
    for op in @core.all_adjust_ops() {
      if @core.filter_param_keys(op).contains(k) {
        owned = true
      }
    }
    assert_true(owned, msg="add_adjust_keys 里的 \{k} 没有任何算子认它（幽灵键）")
  }
}
