///|
/// 容器（组）的 `move` 语义：**搬内容**，不是只改盒子。
///
/// 实测过的错法（只改盒子）：`move grp 15 10` 回 `ok`、指纹变、组的盒子
/// 0,0 → 15,10，而**子层盒子不动、`render_sha256` 逐位相同、`lint` 报 0 违规**
/// ——AI 看到的三个信号里有两个说"改了"，画面说"没改"（PLAN 五十五）。

///|
/// 红 0..20 + 蓝 20..40 的组，画布 60×40，**没有背景层**。
///
/// `scene()` 自带一个 320×240 的蓝底矩形 `l1`——那层才是"原处的墨"，会让
/// "搬走后原处变白"的断言变成在测背景色（实测踩过：期望 `#FFFFFFFF`、拿到
/// `#1E5ACCFF`）。所以这里自己建文档，并另加一条"背景层原地不动"的断言。
fn gmove_scene(uuid : String) -> @agent.Session {
  let s = @agent.Session::new()
  let _ = run(s, "session-open full_image")
  let _ = run(s, "new 60 40 uuid=\{uuid}")
  let _ = run(s, "add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF")
  let _ = run(s, "add-rect id=b x=20 y=0 w=20 h=20 fill=#0000FFFF")
  let _ = run(s, "group grp r b")
  s
}

///|
fn gmove_probe(s : @agent.Session, x : Int, y : Int) -> String {
  let r = run(s, "probe x=\{x} y=\{y}")
  jstr_field(r, "color")
}

///|
/// `query-layer` 把层的字段**套在 `layer` 里**（`list-layers` 则套在 `layers[]`
/// 里）——读位置的辅助要把这一层剥掉，别拿去喂 `jnum_field`（会报"回包缺字段 x"）。
fn gmove_layer_num(s : @agent.Session, id : String, key : String) -> Double {
  let r = run(s, "query-layer \{id}")
  let obj = match @core.parse_json(r) {
    Ok(o) => o
    Err(e) => abort("query-layer 回包不是 JSON（\{e}）：\{r}")
  }
  let lay = match obj.get("layer") {
    Some(@core.JValue::JObj(_)) => obj.get("layer").unwrap()
    _ => abort("query-layer 回包缺 layer：\{r}")
  }
  let v = match lay.get(key) {
    Some(x) => x
    None => abort("layer 缺字段 \{key}：\{r}")
  }
  match v.as_num() {
    Some(x) => x
    None => abort("layer 字段 \{key} 不是数字：\{r}")
  }
}

///|
test "move：组连后代一起搬（盒子与画面一起动，不再是「回 ok 而画面不动」）" {
  let s = gmove_scene("gmove-1")
  let before = jstr_field(run(s, "render 64"), "render_sha256")
  // 前置状态：内容在左上（确认探针真的指着它——手工证据的第一步）
  assert_eq(gmove_probe(s, 5, 5), "#FF0000FF", msg="搬之前 (5,5) 是红的")
  let mv = run(s, "move grp 15 10")
  assert_true(!mv.contains("\"error\":"), msg="move 组不该报错：\{mv}")
  assert_eq(jnum_field(mv, "moved_layers"), 3.0, msg="组 + 两个子层")
  // 画面真的变了
  assert_true(
    jstr_field(run(s, "render 64"), "render_sha256") != before,
    msg="move 组必须改变画面",
  )
  // 内容挪到了 (15,10) 起：原处变白、新处是红
  assert_eq(gmove_probe(s, 5, 5), "#FFFFFFFF", msg="原处的墨搬走了")
  assert_eq(gmove_probe(s, 20, 15), "#FF0000FF", msg="新处（15+5, 10+5）是红")
  // 子层的**盒子**也跟着动（盒子与内容一致，两处不能各说各话）
  assert_eq(gmove_layer_num(s, "r", "x"), 15.0, msg="子层 r 的盒子 x")
  assert_eq(gmove_layer_num(s, "r", "y"), 10.0, msg="子层 r 的盒子 y")
  // 组外的层一个像素都不许动（"搬内容"不是"搬整张画布"）
  assert_eq(gmove_layer_num(s, "grp", "x"), 15.0, msg="组自己的盒子也搬")
  assert_eq(gmove_layer_num(s, "b", "x"), 35.0, msg="兄弟子层同搬")
}

///|
test "move：嵌套组的后代只搬一次（三层只挪一个 delta，不叠加）" {
  let s = scene("gmove-nest")
  let _ = run(s, "add-rect id=a x=0 y=0 w=10 h=10 fill=#FF0000FF")
  let _ = run(s, "group gi a")
  let _ = run(s, "add-rect id=c x=20 y=0 w=10 h=10 fill=#00FF00FF")
  let _ = run(s, "group go gi c")
  let mv = run(s, "move go 7 3")
  assert_eq(jnum_field(mv, "moved_layers"), 4.0, msg="go + gi + a + c")
  // 内层子层 a 只挪一次 (7,3)：它的盒子应当是 7,3
  assert_eq(gmove_layer_num(s, "a", "x"), 7.0, msg="嵌套后代不许被搬两遍（x）")
  assert_eq(gmove_layer_num(s, "a", "y"), 3.0, msg="嵌套后代不许被搬两遍（y）")
  assert_eq(gmove_layer_num(s, "gi", "x"), 7.0, msg="内层组自己的盒子也搬一次")
}

///|
test "move：空组 / 只装调整层的组，caps 不报 move（搬了画面也逐位相同）" {
  // 空组：造得出来（分两个再删一个的等价路径 → 这里直接建再删）
  let s = scene("gmove-empty")
  let _ = run(s, "add-rect id=tmp x=0 y=0 w=10 h=10 fill=#FF0000FF")
  let _ = run(s, "group ge tmp")
  let _ = run(s, "delete tmp")
  let caps_e = caps_of(s, "ge").join(",")
  assert_true(!caps_of(s, "ge").contains("move"), msg="空组不报 move：\{caps_e}")
  // 只装调整层的组
  let s2 = scene("gmove-adj")
  let _ = run(s2, "add-rect id=base x=0 y=0 w=60 h=40 fill=#808080FF")
  let _ = run(s2, "add-adjust id=adj op=brightness value=0.5")
  let _ = run(s2, "group ga adj")
  let caps_a = caps_of(s2, "ga").join(",")
  assert_true(!caps_of(s2, "ga").contains("move"), msg="只装调整层的组不报 move：\{caps_a}")
  // 正控：往里放一个读位置的层，move 立刻报出来
  let _ = run(s2, "add-rect id=vis x=0 y=0 w=10 h=10 fill=#FF0000FF")
  let _ = run(s2, "group-add ga vis")
  let caps_b = caps_of(s2, "ga").join(",")
  assert_true(caps_of(s2, "ga").contains("move"), msg="有内容后要报 move：\{caps_b}")
}

///|
test "move：非组层的 x/y 语义一个像素不变（只有组走递归搬法）" {
  let s = scene("gmove-plain")
  let _ = run(s, "add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF")
  let mv = run(s, "move r 15 10")
  assert_eq(jnum_field(mv, "moved_layers"), 1.0, msg="单层只搬自己")
  assert_eq(gmove_layer_num(s, "r", "x"), 15.0)
  assert_eq(gmove_probe(s, 20, 15), "#FF0000FF")
}
