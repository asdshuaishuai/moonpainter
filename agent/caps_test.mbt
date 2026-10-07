// 能力表（`query-layer`/`list-layers` 的 `caps`）：人类前端据此决定**画不画控件**。
//
// 它回答的是"这条命令对这个 kind 的**画面**有没有效果"，**不是**"命令收不收"
// （入口门禁另有其人）。两件事真的不同：`move` 在组/调整层上回 `ok` 而画面
// 一像素不动、`resize` 在文本/笔触层上同样——控件画在那儿只会让人以为改坏了。
//
// 逐 kind 的名单来自 PLAN 五十一 的实测，而**这里就是那把尺子**：
// 下面第二条测试拿渲染 sha 去对——caps 说有 ⇒ 必须变，说没有 ⇒ 必须逐位相同。

/// 一张 4×2 的不对称 PNG（8 个不同颜色）：位图层的非退化探针
/// （整块纯色的 rotate/flip 是恒等变换，会把"读"误判成"不读"）。
const PNG_B64 : String = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAH0lEQVR4nB3HwQ0AIAADIer+O5/RDwmLFpbiDO+fcQGuAAgAemYB0AAAAABJRU5ErkJggg=="

///|
/// 取一层的 caps。缺失/类型不对一律**报错**，别静默当空表——
/// 空表会让"没有效果"看起来像"引擎没报"，而面板会因此什么都不画。
fn caps_of(s : @agent.Session, id : String) -> Array[String] {
  let r = run(s, "query-layer \{id}")
  let obj = match @core.parse_json(r) {
    Ok(o) => o
    Err(e) => abort("query-layer 回包不是 JSON（\{e}）：\{r}")
  }
  let l = match obj.get("layer") {
    Some(x) => x
    None => abort("query-layer 回包缺 layer：\{r}")
  }
  match l.get("caps") {
    Some(@core.JValue::JArr(a)) =>
      a.map(fn(x) {
        match x {
          @core.JValue::JStr(v) => v
          _ => abort("caps 里不是字符串：\{r}")
        }
      })
    _ => abort("query-layer 没有 caps 字段：\{r}")
  }
}

///|
fn caps_str(s : @agent.Session, id : String) -> String {
  caps_of(s, id).join(",")
}

///|
fn jstr_field(text : String, key : String) -> String {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  match obj.get(key) {
    Some(v) =>
      match v.as_str() {
        Some(x) => x
        None => abort("回包字段 \{key} 不是字符串：\{text}")
      }
    None => abort("回包缺字段 \{key}：\{text}")
  }
}

///|
test "caps：逐 kind 的完整能力表（人类面板据此画控件）" {
  let s = scene("caps-table")
  let _ = run(s, "add-rect id=r1 x=10 y=10 w=40 h=30")
  let _ = run(s, "add-ellipse id=e1 x=60 y=10 w=40 h=30")
  let _ = run(s, "add-polygon id=g1 x=110 y=10 w=40 h=30 points=0,0;30,10;20,25")
  let _ = run(s, "add-line id=l1 x=160 y=10 w=40 h=30")
  let _ = run(s, "add-text id=t1 x=10 y=60 text=Hi font_size=20")
  let _ = run(s, "add-paint id=p1")
  let _ = run(s, "brush layer=p1 pts=20,100;60,120 r=8 color=#FF0000FF")
  let _ = run(s, "add-rect id=c1 x=10 y=140 w=40 h=30")
  let _ = run(s, "group grp c1")
  let _ = run(s, "add-adjust id=a1 op=brightness value=0.5")
  let _ = run(s, "add-image id=i1 x=200 y=10 w=40 h=20 b64=" + PNG_B64)
  // 有面的层：这几条都在（矩形的圆角、位图的资产另算）；
  // `opacity` **所有 kind 都报**（调整层的 α 是"算子生效多少"，见 PLAN 五十三）；
  // `blend` 只报给**有面的层**（读点矩阵：组/文本/笔触/调整层上写 blend 是
  // 死数据 ⇒ 入口拒、`lint` 兜、人类面板画只读回显）
  for id in ["r1", "e1", "g1", "l1"] {
    assert_true(
      caps_str(s, id) == "move,resize,opacity,blend,rotate,flip,mask,fx",
      msg="\{id} 的能力表：\{caps_str(s, id)}",
    )
  }
  // 文本：位置读、盒子不参与渲染（`resize` 改不动画面 ⇒ 不报）、
  // `rotate`/`flip` 从 PLAN 六十一起读（字形逐点过完整变换链，绕自己的盒子中心）
  assert_true(
    caps_str(s, "t1") == "move,opacity,rotate,flip,mask,text,font_size,fx",
    msg="文本层的能力表：\{caps_str(s, "t1")}",
  )
  // 笔触：位置挪笔触、`rotate`/`flip` 从本轮起也读（绕**落笔范围中心**转，
  // 见 PLAN 六十）；盒子（resize）不参与渲染——它是**派生**的，`resize` 只改
  // 那份没人读的快照
  assert_true(
    caps_str(s, "p1") == "move,opacity,rotate,flip,mask,fx",
    msg="笔触层：\{caps_str(s, "p1")}",
  )
  // 组：`move` 是"搬后代"（组自己没画面，后代里有读位置的层才算有能力——
  // 见 `group_has_movable`）；`rotate`/`flip` 从本轮起也读（渲染器把组压进
  // 祖先链、子层的 `to_local` 会经过它，见 PLAN 五十六）；另有 `children`；
  // 盒子（resize）不读，`mask` 也不读（渲染器对组不看 mask）
  assert_true(
    caps_str(s, "grp") == "move,opacity,rotate,flip,fx,children",
    msg="组的能力表：\{caps_str(s, "grp")}",
  )
  // 调整层：只有蒙版与算子；位置/盒子/旋转/翻转都不读
  assert_true(caps_str(s, "a1") == "opacity,mask,adjust", msg="调整层：\{caps_str(s, "a1")}")
  // 位图：换图是一条能力（`set-image`）
  assert_true(
    caps_str(s, "i1") == "move,resize,opacity,blend,rotate,flip,mask,fx,asset",
    msg="位图的能力表：\{caps_str(s, "i1")}",
  )
  // 正控的反面：`list-layers` 也报同一张表（两处报同一件事，别只报一条路）
  let ll = run(s, "list-layers")
  assert_true(ll.contains("\"caps\":["), msg="list-layers 也该带 caps：\{ll}")
}

///|
test "caps 与渲染器对照：说有必须有画面变化，说没有必须逐位相同" {
  // 每一维都要有独立用例（四十八那课的教训）：`opacity` 这一维是量出来的
  // ——调整层的 α 一条渲染路径都不读（`value` 才是它的强度），
  // 而面板上那个滑杆对任何 kind 都画着 ⇒ 又一个静默入口。
  // (标签, 建层行们, 目标 id)。每条都在**新会话**里造，互不干扰。
  let probes : Array[(String, Array[String], String)] = [
    (
      "矩形",
      [
        "add-rect id=t x=20 y=20 w=120 h=60 lgrad=#FF0000FF,#FF00FF00,0,0.5,1,0.5",
      ],
      "t",
    ),
    (
      "椭圆",
      [
        "add-ellipse id=t x=20 y=20 w=120 h=60 lgrad=#FF0000FF,#FF00FF00,0,0.5,1,0.5",
      ],
      "t",
    ),
    ("多边形", ["add-polygon id=t x=20 y=20 w=120 h=60 points=0,0;100,10;60,50 fill=#FF0000FF"], "t"),
    ("线段", ["add-line id=t x=20 y=20 w=120 h=60 stroke=#FF0000FF stroke_w=6"], "t"),
    ("文本", ["add-text id=t x=20 y=20 text=Hi font_size=24 fill=#FF0000FF"], "t"),
    (
      "笔触",
      ["add-paint id=t", "brush layer=t pts=40,40;100,70 r=12 color=#FF0000FF"],
      "t",
    ),
    (
      "组",
      [
        // 子层用**渐变**：整块纯色的 rotate/flip 是恒等变换（会把"读"误判成
        // "不读"），这一条对 `flip` 尤其要紧（纯色横条绕自身中心翻转 = 逐位相同）
        "add-rect id=c1 x=30 y=30 w=60 h=40 lgrad=#FF0000FF,#FF00FF00,0,0.5,1,0.5",
        "group t c1",
      ],
      "t",
    ),
    (
      // *** 装着笔触层的组 *** 又是一格：`rotate`/`flip` 对形状子层是走
      // `to_local`（早就经祖先链），而对**笔触**子层历史上是另一条路
      // （`paint_dabs` 写死 `l.x + d.x`）——于是"caps 说组有 rotate"与"画面
      // 真的转了"在这格上分家（PLAN 五十八修的就是它）。两点笔迹是**不对称**
      // 的，`flip` 才有判别力。
      "组（含笔触层）",
      [
        "add-paint id=c1",
        "brush layer=c1 pts=40,40;100,70 r=12 color=#FF0000FF",
        "group t c1",
      ],
      "t",
    ),
    (
      // *** 有旋转的组 *** 是单独一格：组盒（= 成员并集的派生值）在 rot!=0 时
      // 会被**读**（它是轴心），rot=0 时读不读都一样。上面那条正是"探针恰好
      // 没旋转"，于是 `resize` 那一格静默地少覆盖了状态（PLAN 五十七）。
      "组（有旋转）",
      [
        "add-rect id=c1 x=30 y=30 w=60 h=40 lgrad=#FF0000FF,#FF00FF00,0,0.5,1,0.5",
        "group t c1",
        "rotate t 90",
      ],
      "t",
    ),
    (
      "调整层",
      ["add-rect id=b x=0 y=0 w=320 h=240 fill=#808080FF", "add-adjust id=t op=brightness value=0.5"],
      "t",
    ),
    ("位图", ["add-image id=t x=20 y=20 w=40 h=20 b64=" + PNG_B64], "t"),
  ]
  let ops : Array[(String, String)] = [
    ("move", "move t 27 25"),
    ("resize", "resize t 80 40"),
    ("rotate", "rotate t 30"),
    ("flip", "flip t h"),
    ("opacity", "set-style t opacity=0.3"),
    // `multiply` 压在**白底**上是恒等变换（PLAN 五十一那课已经把 blend 判成过
    // "全都不读"），所以下面每条探针都垫一层灰底——判据的白底就是"探针退化"。
    ("blend", "set-style t blend=multiply"),
  ]
  for p in probes {
    let label = p.0
    // 垫一层灰底：见上面 `blend` 那条（白底上 multiply 恒等）
    let mk : Array[String] = ["add-rect id=bgc x=0 y=0 w=320 h=240 fill=#808080FF"]
    mk.append(p.1)
    let s = scene("caps-diff")
    for line in mk {
      let _ = run(s, line)
    }
    let before = run(s, "render 64")
    let sha0 = jstr_field(before, "render_sha256")
    let fp0 = jstr_field(before, "fingerprint")
    for o in ops {
      let op = o.0
      let s2 = scene("caps-diff-after")
      for line in mk {
        let _ = run(s2, line)
      }
      let _ = run(s2, "render 64")
      let res = run(s2, o.1)
      let err = res.contains("\"error\":")
      let after = run(s2, "render 64")
      let sha1 = jstr_field(after, "render_sha256")
      let fp1 = jstr_field(after, "fingerprint")
      let want = caps_of(s2, "t").contains(op)
      let got = sha1 != sha0
      let pic = if got { "画面变了" } else { "画面逐位相同" }
      assert_true(
        want == got,
        msg="\{label} 的 \{op}：caps 说 \{want}，而 \{pic}（\{sha0} → \{sha1}）",
      )
      // 判别力自证："没有效果"必须是真的没有效果——要么入口拒绝（回 error），
      // 要么**改了不算数**（指纹变了 = 命令真的执行了，别拿"压根没执行"充数）
      if !want {
        let dead = fp1 != fp0
        assert_true(
          err || dead,
          msg="\{label} 的 \{op}：caps 说没有效果，但命令既没被拒也没改指纹 ⇒ 它压根没执行",
        )
      }
    }
  }
}
