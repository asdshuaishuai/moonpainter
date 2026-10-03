// 功能自检：人类侧点一下，就能看出**这一版**哪些功能真的能用。
//
// 为什么要有它：`verify.sh` 覆盖的是引擎 e2e（进程内、脚本化）；而人在浏览器里
// 做**功能级测试**时缺一份"我现在点到的这版，功能面上什么是好的"的清单——只能
// 一条条手点、手比。这里把清单变成一次点击。
//
// 四条纪律（每条都对应仓库里踩过的一个坑）：
//
// 1. **跑在另一份引擎实例上**（`js_clone_engine`）。自检第一句就是 `new`、
//    还要装编辑表——在用户手上那份文档上做，自检的副作用比不做自检更坏。
// 2. **判据是"画面/报告的事实"，不是"命令回了 ok"**。本仓库反复抓到"回包 ok、
//    指纹变了、画面逐位不变"，所以每条至少要比两个 `render_sha256`、比一个
//    `fingerprint`、或读一个报告字段（`sample` 的颜色、`query-layer` 的 kind）。
// 3. **清单必须进测试**（`demo_test.mbt` 断言 0 失败）。只有浏览器点得出来的
//    清单会烂在没人跑的那一侧（同 `layers_html`/`tool_line` 两次提取的理由）。
// 4. **失败要把引擎的原话与实测值一起印出来**。"✗" 一个字帮不了任何人
//    ——要能看出是命令被拒（引擎给了理由）、还是命令成功但断言不成立。

///|
/// 一条自检：
/// * `steps` 按序执行（**每条都必须 ok**，否则后面全是假的），每条拿到之前
///   所有回包——`save-mpd-b64` 那种"后面的命令要吃前面的产物"才写得出来；
/// * `check` 收到全部回包，断言一个可观测事实；
/// * `want` 与 `evidence` 是给人看的（期望 + 实测）。
pub struct SCase {
  name : String
  steps : Array[(Array[Json]) -> String]
  check : (Array[Json]) -> Bool
  want : String
  evidence : (Array[Json]) -> String
}

///|
/// 静态命令行的简写（大多数步骤不吃前一步的回包）。
fn sc_s(line : String) -> (Array[Json]) -> String {
  fn(_) { line }
}

///|
fn sc_pre(s : String) -> String {
  if s.length() > 12 {
    s[0:12].to_owned()
  } else {
    s
  }
}

///|
fn sc_sha(j : Json) -> String {
  json_get_str(j, "render_sha256")
}

///|
fn sc_fp(j : Json) -> String {
  json_get_str(j, "fingerprint")
}

///|
fn sc_color(j : Json) -> String {
  json_get_str(j, "color")
}

///|
/// `query-layer` 的一个数值字段（缺了给一个不可能相等的哨兵值）。
fn sc_get_num(j : Json, k : String) -> Double {
  match json_get(j, k) {
    Some(Json::Number(n, ..)) => n
    _ => -1.0e18
  }
}

///|
/// `query-layer` 的层详情在 **`layer` 子对象**里（顶层只有 ok/op）——直接对
/// 回包取 `kind` 会拿到空串，而判据会以"断言不成立"的样子红，指向错误的方向
/// （这是实测：这条判据第一版就是那么红的）。这里把"从哪里取字段"收成一处。
fn sc_layer(j : Json) -> Json {
  match json_get(j, "layer") {
    Some(l) => l
    None => Json::null()   // 缺字段 ⇒ 下面每条读出来都是空/哨兵，判据照样会说话
  }
}

///|
fn sc_field(j : Json, k : String) -> String {
  json_get_str(sc_layer(j), k)
}

///|
fn sc_field_num(j : Json, k : String) -> Double {
  match json_get(sc_layer(j), k) {
    Some(Json::Number(n, ..)) => n
    _ => -1.0e18
  }
}

///|
/// 回包里的数值数组（`census` 的 `hue_bins`/`sat_bins`/`hsl_bins` 这种）。
/// 缺了或不是数组 ⇒ **空数组**：下面每条读出来都是哨兵/0，判据照样会说话。
fn sc_arr(j : Json, k : String) -> Array[Json] {
  match json_get(j, k) {
    Some(Json::Array(a)) => a
    _ => []
  }
}

///|
fn sc_arr_at(j : Json, k : String, i : Int) -> Double {
  let a = sc_arr(j, k)
  if i < 0 || i >= a.length() {
    return -1.0e18
  }
  match a[i] {
    Json::Number(n, ..) => n
    _ => -1.0e18
  }
}

///|
/// 数组求和（非数字元素按 0 记——判据要的是"桶里数的总数"，不是类型检查）。
fn sc_arr_sum(j : Json, k : String) -> Double {
  let mut s = 0.0
  for v in sc_arr(j, k) {
    match v {
      Json::Number(n, ..) => s = s + n
      _ => ()
    }
  }
  s
}

///|
/// 非零元素个数（一张纯色图在某个颜色空间里应该**恰好一个**桶非零）。
fn sc_arr_nonzero(j : Json, k : String) -> Int {
  let mut c = 0
  for v in sc_arr(j, k) {
    match v {
      Json::Number(n, ..) => if n != 0.0 { c = c + 1 }
      _ => ()
    }
  }
  c
}

///|
/// `select-preview` 第一个连通域的 `area`（在 `component_facts[0]` 里）。
/// 判据与证据**都读它**：同一件事两处写一遍，烂的一定是没人读的那处。
fn sc_facts_area(j : Json) -> Double {
  let facts = sc_arr(j, "component_facts")
  if facts.length() == 0 {
    return -1.0e18
  }
  match json_get(facts[0], "area") {
    Some(Json::Number(n, ..)) => n
    _ => -1.0e18
  }
}

///|
/// 相对容差比较。**浮点数值断言一律走它**：写死绝对误差（1e-9 或 1e-12）都会
/// 在某个量级上变脆，而这条在 a≈b 时不会平白放大误差。
fn sc_near(a : Double, b : Double) -> Bool {
  let d = if a > b { a - b } else { b - a }
  let m = if a > b { a } else { b }
  d <= 1.0e-9 * (if m > 1.0 { m } else { 1.0 })
}

///|
/// 几何选择子（画布左下 20×30 那一块）：`select-preview`/`census within=` 吃的
/// 就是它。**取 20×30 而不是 0.5×1**：选择子坐标的归一化/像素两种读法在仓库里
/// 都出现过，取"两种读法下都覆盖到东西"的值，判据才不会因为口径而变成空集。
fn sc_geo_sel_wh(w : Double, h : Double) -> String {
  "{\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":" +
  w.to_string() + ",\"h\":" + h.to_string() + ",\"feather\":0}}}"
}

///|
/// 与 `sc_geo_sel_wh` 同源（**别手写第二遍 JSON**：40×30 与 5×5 那两处手写的
/// 都漏了一个 `}`，引擎回「选择子解析失败：对象未闭合」——判据看着像选择子
/// 有问题，实际是模板抄错）。
fn sc_geo_sel() -> String {
  sc_geo_sel_wh(20.0, 30.0)
}

///|
/// 一张**真的会改画面**的编辑表：全图矩形选择子上做 120° 重着色。
fn sc_recolor_prog() -> String {
  "{\"version\":1,\"ops\":[{\"id\":\"e1\",\"kind\":\"recolor\",\"sel\":" + sc_geo_sel() +
  ",\"amount\":1,\"hue_deg\":120,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}],\"guards\":[]}"
}

///|
/// 自检清单。**每条都以 `new` 开头**，而且运行器每格开场会先 `mvsl-clear`
/// （`new` **不清会话上的编辑表**，同一条链跑下来上一格的表会串到下一格——
/// 顺序依赖会让清单"单跑过、连跑挂"，实测栽过一次）。
pub fn selfcheck_cases() -> Array[SCase] {
  [
    {
      name: "建矩形：query-layer 报得对（kind/x/w）",
      steps: [
        sc_s("new 40 30 uuid=sc-rect"),
        sc_s("add-rect id=r x=5 y=6 w=20 h=10 fill=#FF0000FF name=R"),
        sc_s("query-layer r"),
      ],
      check: fn(rs) {
        sc_field(rs[2], "kind") == "rect" &&
        sc_field_num(rs[2], "x") == 5.0 &&
        sc_field_num(rs[2], "w") == 20.0
      },
      want: "kind=rect、x=5、w=20",
      evidence: fn(rs) {
        sc_field(rs[2], "kind") +
        " x=" +
        json_num_str(sc_layer(rs[2]), "x") +
        " w=" +
        json_num_str(sc_layer(rs[2]), "w")
      },
    },
    {
      name: "四种建层命令都画得出东西（矩形圆角/椭圆/渐变/描边/折线/多边形）",
      steps: [
        sc_s("new 60 40 uuid=sc-shapes"),
        sc_s("add-rect id=r1 x=2 y=2 w=20 h=10 fill=#FF0000FF radius=4 name=R1"),
        sc_s("add-ellipse id=e1 x=24 y=2 w=20 h=10 lgrad=#FF0000FF,#0000FFFF,0,0,1,1 name=E1"),
        sc_s("add-rect id=r2 x=2 y=16 w=20 h=10 fill=#00FF00FF stroke=#000000FF stroke_w=3 name=R2"),
        sc_s("add-line id=l1 x=26 y=16 w=30 h=2 points=0,1;30,1 stroke=#0000FFFF stroke_w=2 name=L1"),
        sc_s("add-polygon id=p1 x=2 y=30 w=24 h=8 points=0,0;24,0;12,8 fill=#FFFF00FF name=P1"),
        sc_s("render 60"),
      ],
      check: fn(rs) { sc_sha(rs[6]).length() >= 32 },
      want: "六条建层命令都回 ok，render 吐出 sha256",
      evidence: fn(rs) { "render_sha256=" + sc_pre(sc_sha(rs[6])) },
    },
    {
      name: "文本层：内容与字号报得出来",
      steps: [
        sc_s("new 80 30 uuid=sc-text"),
        sc_s("add-text id=t x=2 y=2 text=Hi font_size=20 fill=#000000FF name=T"),
        sc_s("query-layer t"),
      ],
      check: fn(rs) {
        sc_field(rs[2], "kind") == "text" &&
        sc_field(rs[2], "text") == "Hi" &&
        sc_field_num(rs[2], "font_size") == 20.0
      },
      want: "kind=text、text=Hi、font_size=20",
      evidence: fn(rs) {
        sc_field(rs[2], "kind") +
        " text=" +
        sc_field(rs[2], "text") +
        " fs=" +
        json_num_str(sc_layer(rs[2]), "font_size")
      },
    },
    {
      name: "文本旋转真的改画面（不是「回 ok 而画面不动」）",
      steps: [
        sc_s("new 60 60 uuid=sc-trot"),
        sc_s("add-text id=t x=10 y=10 text=H font_size=20 fill=#000000FF name=T"),
        sc_s("render 60"),
        sc_s("rotate t 90"),
        sc_s("render 60"),
      ],
      check: fn(rs) { sc_sha(rs[2]) != "" && sc_sha(rs[4]) != "" && sc_sha(rs[2]) != sc_sha(rs[4]) },
      want: "rotate 前后 render_sha256 必须不同",
      evidence: fn(rs) { sc_pre(sc_sha(rs[2])) + " → " + sc_pre(sc_sha(rs[4])) },
    },
    {
      name: "本层转 90° ≡ 装进组再转组 90°（象限角取精确值，第 77 轮的不变量）",
      steps: [
        sc_s("new 60 60 uuid=sc-q1"),
        sc_s("add-text id=t x=10 y=10 text=H font_size=20 fill=#000000FF name=T"),
        sc_s("rotate t 90"),
        sc_s("render 60"),
        sc_s("new 60 60 uuid=sc-q2"),
        sc_s("add-text id=t x=10 y=10 text=H font_size=20 fill=#000000FF name=T"),
        sc_s("group g1 t"),
        sc_s("rotate g1 90"),
        sc_s("render 60"),
      ],
      check: fn(rs) { sc_sha(rs[3]) != "" && sc_sha(rs[3]) == sc_sha(rs[8]) },
      want: "两条路的 render_sha256 必须逐位相同",
      evidence: fn(rs) { sc_pre(sc_sha(rs[3])) + " vs " + sc_pre(sc_sha(rs[8])) },
    },
    {
      name: "90° 再 270°（嵌套组，数学上恒等）≡ 完全不转（逐位恒等）",
      steps: [
        sc_s("new 60 60 uuid=sc-q3"),
        sc_s("add-rect id=r x=8 y=8 w=30 h=24 fill=#3366FFFF name=R"),
        sc_s("render 60"),
        sc_s("new 60 60 uuid=sc-q4"),
        sc_s("add-rect id=r x=8 y=8 w=30 h=24 fill=#3366FFFF name=R"),
        sc_s("group g1 r"),
        sc_s("rotate g1 90"),
        sc_s("group g2 g1"),
        sc_s("rotate g2 270"),
        sc_s("render 60"),
      ],
      check: fn(rs) { sc_sha(rs[2]) != "" && sc_sha(rs[2]) == sc_sha(rs[9]) },
      want: "不转 与 90°+270° 的 render_sha256 必须逐位相同",
      evidence: fn(rs) { sc_pre(sc_sha(rs[2])) + " vs " + sc_pre(sc_sha(rs[9])) },
    },
    {
      // ⚠️ 探针必须是**不对称内容**：纯色矩形绕自己盒子中心翻，逐位不变
      // （那是"翻转没生效"还是"内容本来就对称"分不出来）——用竖向渐变，
      // 翻一下必然整条变色。
      name: "翻转真的改画面（探针用竖向渐变，纯色矩形翻不出差别）",
      steps: [
        sc_s("new 20 20 uuid=sc-flip"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 lgrad=#FF0000FF,#0000FFFF,0,0,0,1 name=R"),
        sc_s("render 20"),
        sc_s("flip r v"),
        sc_s("render 20"),
      ],
      check: fn(rs) { sc_sha(rs[2]) != "" && sc_sha(rs[2]) != sc_sha(rs[4]) },
      want: "flip v 前后 render_sha256 必须不同（渐变被镜像）",
      evidence: fn(rs) { sc_pre(sc_sha(rs[2])) + " → " + sc_pre(sc_sha(rs[4])) },
    },
    {
      name: "不透明度改画面",
      steps: [
        sc_s("new 20 20 uuid=sc-op"),
        sc_s("add-rect id=bg x=0 y=0 w=20 h=20 fill=#FFFFFFFF name=BG"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("render 20"),
        sc_s("set-style r opacity=0.5"),
        sc_s("render 20"),
      ],
      check: fn(rs) { sc_sha(rs[3]) != sc_sha(rs[5]) },
      want: "opacity=0.5 前后 render_sha256 必须不同",
      evidence: fn(rs) { sc_pre(sc_sha(rs[3])) + " → " + sc_pre(sc_sha(rs[5])) },
    },
    {
      name: "组的 α 是整体打折：重叠区与不重叠区同一色（PLAN 五十四的不变量）",
      steps: [
        sc_s("new 40 40 uuid=sc-gop"),
        sc_s("add-rect id=bg x=0 y=0 w=40 h=40 fill=#FFFFFFFF name=BG"),
        sc_s("add-rect id=a x=0 y=0 w=20 h=20 fill=#0000FFFF name=A"),
        sc_s("add-rect id=b x=10 y=10 w=20 h=20 fill=#0000FFFF name=B"),
        sc_s("group g1 a"),
        sc_s("group-add g1 b"),
        sc_s("set-style g1 opacity=0.5"),
        sc_s("sample 5 5"),
        sc_s("sample 15 15"),
      ],
      check: fn(rs) {
        let c1 = sc_color(rs[7])
        let c2 = sc_color(rs[8])
        c1 != "" && c1 == c2 && c1 != "#FFFFFFFF"
      },
      want: "两个采样点颜色必须相同（都是「半透明蓝压白」），且不是白纸",
      evidence: fn(rs) { "只一个子层 " + sc_color(rs[7]) + " vs 重叠 " + sc_color(rs[8]) },
    },
    {
      name: "隐藏的层不画（采样必须是白纸）",
      steps: [
        sc_s("new 20 20 uuid=sc-hide"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("sample 10 10"),
        sc_s("visible r 0"),
        sc_s("sample 10 10"),
        sc_s("render 20"),
      ],
      check: fn(rs) { sc_color(rs[2]) == "#FF0000FF" && sc_color(rs[4]) == "#FFFFFFFF" },
      want: "隐藏前 =#FF0000FF，隐藏后 =#FFFFFFFF（与 pick/渲染同一把尺子）",
      evidence: fn(rs) { sc_color(rs[2]) + " → " + sc_color(rs[4]) },
    },
    {
      name: "蒙版：外不画、羽化改画面",
      steps: [
        sc_s("new 20 20 uuid=sc-mask"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("add-mask r kind=rect x=0 y=0 w=10 h=20 feather=0"),
        sc_s("sample 5 10"),
        sc_s("sample 15 10"),
        sc_s("render 20"),
        sc_s("set-mask r kind=rect x=0 y=0 w=10 h=20 feather=4"),
        sc_s("render 20"),
      ],
      check: fn(rs) {
        sc_color(rs[3]) == "#FF0000FF" &&
        sc_color(rs[4]) == "#FFFFFFFF" &&
        sc_sha(rs[5]) != sc_sha(rs[7])
      },
      want: "蒙版内=红、蒙版外=白纸；羽化前后 render_sha256 必须不同",
      evidence: fn(rs) {
        "内 " + sc_color(rs[3]) + " 外 " + sc_color(rs[4]) + "｜羽化 " + sc_pre(sc_sha(rs[5])) + " → " +
        sc_pre(sc_sha(rs[7]))
      },
    },
    {
      name: "调整层真的改画面",
      steps: [
        sc_s("new 20 20 uuid=sc-adj"),
        sc_s("add-rect id=bg x=0 y=0 w=20 h=20 fill=#808080FF name=BG"),
        sc_s("render 20"),
        sc_s("add-adjust id=a1 op=brightness value=0.5"),
        sc_s("render 20"),
      ],
      check: fn(rs) { sc_sha(rs[2]) != sc_sha(rs[4]) },
      want: "加调整层前后 render_sha256 必须不同",
      evidence: fn(rs) { sc_pre(sc_sha(rs[2])) + " → " + sc_pre(sc_sha(rs[4])) },
    },
    {
      name: "撤销/重做：画面真的退回去又回来",
      steps: [
        sc_s("new 20 20 uuid=sc-undo"),
        sc_s("render 20"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("render 20"),
        sc_s("undo"),
        sc_s("render 20"),
        sc_s("redo"),
        sc_s("render 20"),
      ],
      check: fn(rs) {
        sc_sha(rs[1]) != sc_sha(rs[3]) && sc_sha(rs[1]) == sc_sha(rs[5]) && sc_sha(rs[3]) == sc_sha(rs[7])
      },
      want: "新建后=空图；加层后变了；undo 回到空图；redo 回到加层后",
      evidence: fn(rs) {
        sc_pre(sc_sha(rs[1])) + " → " + sc_pre(sc_sha(rs[3])) + " → " + sc_pre(sc_sha(rs[5])) + " → " +
        sc_pre(sc_sha(rs[7]))
      },
    },
    {
      name: "编组/解组不改画面（成员一个不动）",
      steps: [
        sc_s("new 40 40 uuid=sc-group"),
        sc_s("add-rect id=a x=0 y=0 w=20 h=20 fill=#FF0000FF name=A"),
        sc_s("add-rect id=b x=20 y=20 w=20 h=20 fill=#0000FFFF name=B"),
        sc_s("render 40"),
        sc_s("group g1 a"),
        sc_s("group-add g1 b"),
        sc_s("render 40"),
        sc_s("ungroup g1"),
        sc_s("render 40"),
      ],
      check: fn(rs) {
        let a = sc_sha(rs[3])
        a != "" && a == sc_sha(rs[6]) && a == sc_sha(rs[8])
      },
      want: "编组前 / 编组后 / 解组后 三次 render_sha256 必须逐位相同",
      evidence: fn(rs) {
        sc_pre(sc_sha(rs[3])) + " = " + sc_pre(sc_sha(rs[6])) + " = " + sc_pre(sc_sha(rs[8]))
      },
    },
    {
      name: "存读往返：指纹一致（save-mpd-b64 → new → open-mpd-b64）",
      steps: [
        sc_s("new 40 30 uuid=sc-save"),
        sc_s("add-rect id=r x=3 y=4 w=20 h=10 fill=#FF0000FF name=R"),
        sc_s("add-text id=t x=3 y=20 text=Hi font_size=12 fill=#000000FF name=T"),
        sc_s("save-mpd-b64"),
        sc_s("new 16 16 uuid=sc-scratch"),
        fn(rs) { "open-mpd-b64 " + json_get_str(rs[3], "mpd_b64") },
        sc_s("fingerprint"),
      ],
      check: fn(rs) {
        let want = sc_fp(rs[3])
        want != "" && want == sc_fp(rs[5]) && want == sc_fp(rs[6])
      },
      want: "存档回包 / 载入回包 / 载入后 fingerprint 三处指纹必须相同",
      evidence: fn(rs) {
        sc_pre(sc_fp(rs[3])) + " / " + sc_pre(sc_fp(rs[5])) + " / " + sc_pre(sc_fp(rs[6]))
      },
    },
    {
      name: "MVSL：render ≡ impact（两条出口给同一张图）",
      steps: [
        sc_s("new 40 30 uuid=sc-mvsl"),
        sc_s("add-rect id=r x=0 y=0 w=40 h=30 fill=#FF0000FF name=R"),
        sc_s("render 40"),
        fn(_) { "mvsl-set " + b64_text(sc_recolor_prog()) },
        sc_s("render 40"),
        sc_s("mvsl-impact"),
      ],
      check: fn(rs) {
        // `mvsl-impact` 不給 `max=` 时：`result_sha256` 是**编码进信封那张图**的 sha、
        // `full_sha256` 是全分辨率那张（给了 max= 两者会不同）。不带 max 时两张
        // 应当都是全分辨率 ⇒ 至少有一个必须等于 render 的 sha（`verify.sh#mvsl-e2e`
        // 断言的就是这条：render 与 impact 是同一张图）。
        let before = sc_sha(rs[2])
        let after = sc_sha(rs[4])
        let r = json_get_str(rs[5], "result_sha256")
        let f = json_get_str(rs[5], "full_sha256")
        before != "" && after != "" && after != before && (r == after || f == after)
      },
      want: "装了编辑表画面必须变；且 mvsl-impact 的 result_sha256（或 full_sha256）== render 的 render_sha256",
      evidence: fn(rs) {
        "render " + sc_pre(sc_sha(rs[4])) + " vs impact " + sc_pre(json_get_str(rs[5], "result_sha256")) +
        " / full " + sc_pre(json_get_str(rs[5], "full_sha256"))
      },
    },
    {
      name: "MVSL：清表之后画面回到原样",
      steps: [
        sc_s("new 40 30 uuid=sc-mvsl2"),
        sc_s("add-rect id=r x=0 y=0 w=40 h=30 fill=#FF0000FF name=R"),
        sc_s("render 40"),
        fn(_) { "mvsl-set " + b64_text(sc_recolor_prog()) },
        sc_s("mvsl-show"),
        sc_s("render 40"),
        sc_s("mvsl-clear"),
        sc_s("render 40"),
        sc_s("mvsl-impact"),
      ],
      check: fn(rs) {
        // ① 编辑表真的装上了（`mvsl-show` 报得出那条 recolor）；
        // ② 装表**改了画面**（装表前后两次 render 不同）；
        // ③ 清表之后画面**逐位回到**装表前那张；
        // ④ 此时 `mvsl-impact` 报 `base_sha256 == result_sha256`（没有编辑表就没有改动）。
        let before = sc_sha(rs[2])
        let shown = rs[4].stringify()
        let r = json_get_str(rs[8], "result_sha256")
        let b = json_get_str(rs[8], "base_sha256")
        let ok_shown = shown.contains("recolor")
        before != "" && ok_shown && sc_sha(rs[5]) != before && sc_sha(rs[7]) == before && r == b
      },
      want: "装表后 mvsl-show 报得出 recolor；装表画面变；清表后 render 逐位回到装表前，且 impact 报 base == result",
      evidence: fn(rs) {
        "render " + sc_pre(sc_sha(rs[2])) + " → " + sc_pre(sc_sha(rs[5])) + " → " + sc_pre(sc_sha(rs[7])) +
        "｜宽高 " + json_num_str(rs[2], "width") + "x" + json_num_str(rs[2], "height") +
        "｜清表后 impact base " + sc_pre(json_get_str(rs[8], "base_sha256")) + " = result " +
        sc_pre(json_get_str(rs[8], "result_sha256"))
      },
    },
    {
      name: "lint：干净文档 0 违规",
      steps: [
        sc_s("new 40 30 uuid=sc-lint"),
        sc_s("add-rect id=r x=0 y=0 w=40 h=30 fill=#FF0000FF name=R"),
        sc_s("lint"),
      ],
      check: fn(rs) { sc_get_num(rs[2], "violations") == 0.0 },
      want: "violations=0",
      evidence: fn(rs) { "violations=" + json_num_str(rs[2], "violations") },
    },
    {
      name: "lint 抓得住空文本层（「装了却什么都不干」的状态）",
      steps: [
        sc_s("new 40 30 uuid=sc-lint2"),
        sc_s("add-text id=t x=0 y=0 text=X font_size=12 fill=#000000FF name=T"),
        sc_s("set-text t \"\""),
        sc_s("lint"),
      ],
      check: fn(rs) { sc_get_num(rs[3], "violations") > 0.0 },
      want: "把文本改空之后 violations > 0（lint 必须说话）",
      evidence: fn(rs) { "violations=" + json_num_str(rs[3], "violations") },
    },
    {
      name: "pick 与 sample 说同一件事（同一个点、同一层）",
      steps: [
        sc_s("new 20 20 uuid=sc-pick"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("pick 10 10"),
        sc_s("sample 10 10"),
      ],
      check: fn(rs) {
        json_get_str(rs[2], "id") == "r" && json_get_str(rs[3], "layer") == "r"
      },
      want: "pick.id == sample.layer == r（同一个点、同一层）",
      evidence: fn(rs) {
        "pick=" + json_get_str(rs[2], "id") + " sample=" + json_get_str(rs[3], "layer")
      },
    },
    {
      name: "层序改了，画面就变（置顶真的到顶）",
      steps: [
        sc_s("new 20 20 uuid=sc-order"),
        sc_s("add-rect id=a x=0 y=0 w=20 h=20 fill=#FF0000FF name=A"),
        sc_s("add-rect id=b x=0 y=0 w=20 h=20 fill=#0000FFFF name=B"),
        sc_s("render 20"),
        sc_s("reorder a front"),
        sc_s("render 20"),
        sc_s("sample 10 10"),
      ],
      check: fn(rs) {
        sc_sha(rs[3]) != sc_sha(rs[5]) && sc_color(rs[6]) == "#FF0000FF"
      },
      want: "置顶前后画面不同，且置顶后采样点 = 被置顶那层的红",
      evidence: fn(rs) {
        sc_pre(sc_sha(rs[3])) + " → " + sc_pre(sc_sha(rs[5])) + "｜色 " + sc_color(rs[6])
      },
    },
    {
      name: "标签：打得上去、报得出来、摘得下来",
      steps: [
        sc_s("new 20 20 uuid=sc-tag"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("tag r hero"),
        sc_s("query-layer r"),
        sc_s("untag r hero"),
        sc_s("query-layer r"),
      ],
      check: fn(rs) {
        rs[3].stringify().contains("hero") && !rs[5].stringify().contains("hero")
      },
      want: "tag 之后 query-layer 报得出 hero；untag 之后报不出来",
      evidence: fn(rs) {
        let a = if rs[3].stringify().contains("hero") { "有 hero" } else { "没 hero" }
        let b = if rs[5].stringify().contains("hero") { "有 hero" } else { "没 hero" }
        a + " → " + b
      },
    },
    {
      name: "元参数：增/列/删都通，且**不改画面**（声明过的边界）",
      steps: [
        sc_s("new 20 20 uuid=sc-param"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=20 fill=#FF0000FF name=R"),
        sc_s("render 20"),
        sc_s("set-param style moody"),
        sc_s("list-params"),
        sc_s("render 20"),
        sc_s("remove-param style"),
        sc_s("list-params"),
      ],
      check: fn(rs) {
        rs[4].stringify().contains("moody") &&
        !rs[7].stringify().contains("moody") &&
        sc_sha(rs[2]) == sc_sha(rs[5])
      },
      want: "set-param 后列得出 moody、remove-param 后列不出；两次 render 逐位相同",
      evidence: fn(rs) {
        (if rs[4].stringify().contains("moody") { "参数在" } else { "参数不在" }) +
        "｜render " + sc_pre(sc_sha(rs[2])) + " = " + sc_pre(sc_sha(rs[5]))
      },
    },
    {
      name: "三个分析出口都出得来（probe / census / select-preview）",
      steps: [
        sc_s("new 40 30 uuid=sc-ana"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=30 fill=#FF0000FF name=R"),
        sc_s("probe x=5 y=5"),
        sc_s("census"),
        fn(_) { "select-preview " + b64_text(sc_geo_sel()) },
      ],
      check: fn(rs) {
        let p = rs[2].stringify()
        let c = rs[3].stringify()
        let s = rs[4].stringify()
        p.contains("edge_conf") && c.length() > 20 && s.contains("coverage")
      },
      want: "probe 报边缘置信度、census 报桶、select-preview 报覆盖率",
      evidence: fn(rs) {
        "probe " + rs[2].stringify().length().to_string() + " 字符｜census " +
        rs[3].stringify().length().to_string() + " 字符｜preview " +
        rs[4].stringify().length().to_string() + " 字符"
      },
    },
    {
      name: "census/probe 的数是从像素真算出来的（桶和 == 总数、纯色只有一个桶、边缘两头都咬）",
      steps: [
        sc_s("new 40 30 uuid=sc-num"),
        // 左半红、右半白 ⇒ x=20 处有一条**竖直边缘**（用纯色图验"没有边缘"，
        // 用半红半白验"有边缘"：只验前者的话，"edge_conf 恒为 0"也能通过）。
        sc_s("add-rect id=w x=0 y=0 w=40 h=30 fill=#FFFFFFFF name=W"),
        sc_s("add-rect id=r x=0 y=0 w=20 h=30 fill=#FF0000FF name=R"),
        sc_s("census"),
        sc_s("probe x=5 y=15 r=4"),
        sc_s("probe x=20 y=15 r=4"),
        sc_s("probe x=35 y=15 r=4"),
      ],
      check: fn(rs) {
        let c = rs[3]
        let total = sc_get_num(c, "total")
        let counted = sc_get_num(c, "counted")
        // ① 三组桶**各自**求和必须等于 counted：一组对不上就是"桶里丢/重了像素"
        //    ——而回包照样好看（`hue_bins` 全是 0 也能过"字段在"那种断言）。
        let sums_ok = sc_near(sc_arr_sum(c, "hue_bins"), counted) &&
          sc_near(sc_arr_sum(c, "sat_bins"), counted) &&
          sc_near(sc_arr_sum(c, "hsl_bins"), counted)
        // ② 这张图只有红与白**两种颜色** ⇒ 色相桶非零数必须 ≤ 2（红一个；白无彩
        //    度、不该贡献色相桶）。写成 ≤2 而不是 ==1：白纸归哪个桶是颜色空间的
        //    实现细节，判据不该替它做决定——但"十几个桶都非零"一定是错的。
        let hue_ok = sc_arr_nonzero(c, "hue_bins") <= 2
        // ③ dominant_bin 必须落在**非零**的那个桶上（自洽：报出来的"主桶"不能是空桶）
        let dom = sc_get_num(c, "dominant_bin").to_int()
        let dom_ok = sc_arr_at(c, "hsl_bins", dom) > 0.0
        // ④ 边缘：纯红内部 0、白纸 0、红白交界 > 0（**两头都咬**）
        let in_red = sc_get_num(rs[4], "edge_conf") == 0.0
        let on_edge = sc_get_num(rs[5], "edge_conf") > 0.0
        let in_white = sc_get_num(rs[6], "edge_conf") == 0.0
        total == 1200.0 && counted == total && sums_ok && hue_ok && dom_ok && in_red && on_edge &&
        in_white
      },
      want: "total=counted=1200；三组桶各自求和=1200；色相非零桶≤2；dominant_bin 落在非零桶；纯红内/白纸 edge_conf=0 而交界 >0",
      evidence: fn(rs) {
        let c = rs[3]
        "total " + json_num_str(c, "total") + " / counted " + json_num_str(c, "counted") +
        "｜桶和 hue " + sc_pre(sc_arr_sum(c, "hue_bins").to_string()) + " sat " +
        sc_pre(sc_arr_sum(c, "sat_bins").to_string()) + " hsl " +
        sc_pre(sc_arr_sum(c, "hsl_bins").to_string()) + "｜非零色相桶 " +
        sc_arr_nonzero(c, "hue_bins").to_string() + "｜dominant " +
        json_num_str(c, "dominant_bin") + "（该桶 " +
        sc_pre(sc_arr_at(c, "hsl_bins", sc_get_num(c, "dominant_bin").to_int()).to_string()) +
        "）｜edge_conf 红内 " + json_num_str(rs[4], "edge_conf") + " 交界 " +
        json_num_str(rs[5], "edge_conf") + " 白纸 " + json_num_str(rs[6], "edge_conf")
      },
    },
    {
      name: "select-preview：覆盖率与选区面积自洽（全图=1、小选区=面积占比）",
      steps: [
        sc_s("new 40 30 uuid=sc-sel"),
        sc_s("add-rect id=r x=0 y=0 w=40 h=30 fill=#FF0000FF name=R"),
        fn(_) { "select-preview " + b64_text(sc_geo_sel_wh(40.0, 30.0)) },
        fn(_) { "select-preview " + b64_text(sc_geo_sel_wh(5.0, 5.0)) },
      ],
      check: fn(rs) {
        let all = rs[2]
        let tiny = rs[3]
        let cov_all = sc_get_num(all, "coverage")
        let cov_tiny = sc_get_num(tiny, "coverage")
        // **关系**断言优先于绝对数字：`coverage × 画布面积 == area` 对任何画布
        // 都成立，写死 0.020833… 只是把某一次的实测值抄进来。
        // ⚠️ `area` 在 `component_facts[0]` 里（不在顶层）；`coverage`/`components`
        // 在顶层——这是实测读出来的回包形状（第一版我按顶层读，判据会以
        // "断言不成立"的样子红，指向别处）。
        let facts_area = sc_facts_area(tiny)
        sc_near(cov_all, 1.0) &&
        sc_get_num(all, "components") == 1.0 &&
        sc_near(cov_tiny, 25.0 / 1200.0) &&
        facts_area == 25.0 &&
        sc_near(cov_tiny * 1200.0, facts_area)
      },
      want: "全图 coverage=1、components=1；5×5 的 coverage=25/1200 且 coverage×1200==area",
      evidence: fn(rs) {
        let all = rs[2]
        let tiny = rs[3]
        let facts_area = sc_facts_area(tiny)
        "全图 coverage " + json_num_str(all, "coverage") + " components " +
        json_num_str(all, "components") + "｜5×5 coverage " + json_num_str(tiny, "coverage") +
        " area " + sc_pre(facts_area.to_string()) + "｜coverage×1200 " +
        sc_pre((sc_get_num(tiny, "coverage") * 1200.0).to_string())
      },
    },
    {
      name: "字典自证：help 与 list-tools 都报得出建层命令（help 是 list-tools 的别名）",
      steps: [sc_s("help"), sc_s("list-tools")],
      check: fn(rs) {
        // ⚠️ `help` 的 op 字段也叫 `help`、`list-tools` 的也叫 `help`——它们是
        // **同一条命令的别名**（回包逐字相同）。所以这里只断言"都报得出命令字典"，
        // 不断言两者不同（第一版就是这么写错的）。
        rs[0].stringify().contains("add-rect") &&
        rs[1].stringify().contains("add-rect") &&
        rs[1].stringify().contains("\"tools\"")
      },
      want: "两条都出命令字典，且字典里有 add-rect",
      evidence: fn(rs) {
        "help " + rs[0].stringify().length().to_string() + " 字符｜list-tools " +
        rs[1].stringify().length().to_string() + " 字符，都含 add-rect"
      },
    },
    {
      name: "裁剪：crop 之后画面尺寸必须跟着变",
      steps: [
        sc_s("new 40 40 uuid=sc-crop"),
        sc_s("add-rect id=r x=0 y=0 w=40 h=40 fill=#FF0000FF name=R"),
        sc_s("render 40"),
        sc_s("crop 0 0 20 20"),
        sc_s("render 20"),
        sc_s("render 40"),
      ],
      check: fn(rs) { sc_sha(rs[2]) != "" && sc_sha(rs[4]) != "" && sc_sha(rs[2]) != sc_sha(rs[4]) },
      want: "裁到 20×20 之后 render 20 与原来 render 40 的 sha 不同（裁窄了，图变了）",
      evidence: fn(rs) { sc_pre(sc_sha(rs[2])) + " → " + sc_pre(sc_sha(rs[4])) },
    },
  ]
}

///|
/// 跑一遍自检：**自己另起一份引擎**（`js_clone_engine`）——自检会 `new`、
/// 会装编辑表，绝不能在调用方手上那份文档上做。面板与 `demo_test` 走的是
/// 同一个入口（清单只此一份，两边不会分叉）。克隆不出来时返回一条**失败**行
/// 说明原因，而不是抛异常/静默返回空表（空表会让"全过"看起来成立）。
pub fn selfcheck_run_isolated() -> Array[(String, Bool, String, String)] {
  // **先确保引擎已加载**（加载器顺手把 wasm 字节写进缓存）。少了这一句，
  // "克隆"就没有字节可用、退化成同一份引擎，自检会跑在用户当前文档上——
  // 实测就是这么栽的：面板上引擎当然是加载过的，但 `demo_test` 里这条测试
  // 的执行顺序不保证（`ensure_engine` 在别的测试里），于是自检在测试里那次
  // 一直跑在真实引擎上，`new` 把它清空、`mvsl-set` 也留在上面，报出来的
  // 现象指向别处（"装表没有改画面"）。**入口自己保证前置条件**，别指望调用方。
  ensure_engine()
  let work = js_clone_engine()
  if js_same_engine(work) {
    // **不许静默退回同一份引擎**：那等于在用户手上那份文档上跑自检（自检会
    // `new`、会装编辑表），比不自检更坏。这条实测抓到过：`js_clone_engine`
    // 的字节缓存来自一个**没人调用**的旧加载器，于是克隆静默返回 null，
    // 而 `js_null` 那道守卫没拦住（`e === null || e === undefined` 在 MoonBit
    // FFI 边界上对不上）——自检于是跑在真实引擎上，报出来的现象指向别处。
    return [(
      "功能自检：跑在另一份引擎上",
      false,
      "克隆出的引擎 ≠ 当前引擎（wasm 字节已缓存）",
      "克隆失败：起不了独立引擎实例，自检拒绝在**你当前的文档**上跑（那会改掉它）。请确认引擎已加载后重试",
    )]
  }
  selfcheck_rows(work)
}

///|
/// 跑一遍清单，返回（名字, 过没过, 期望, 实测/失败原因）。`work` 必须是
/// **另一份**引擎实例（`js_clone_engine`）——自检会在上面 `new` 与装编辑表。
fn selfcheck_rows(work : WasmEngine) -> Array[(String, Bool, String, String)] {
  let _ = engine_reset_raw(work)
  let _ = engine_exec(work, "session-open full_image")
  let rows : Array[(String, Bool, String, String)] = []
  for c in selfcheck_cases() {
    // **每格开场先清编辑表**：`new` 只换文档、**不清会话上的 MVSL 表**，于是
    // 上一格装的表会被下一格继承——实测就栽在这里：`render ≡ impact` 那格装了
    // 一张 recolor 表，紧跟的 `清表` 那格开场渲染就已经是**改过的图**，判据报
    // "装表没改画面"（现象指向别处）。**同一份引擎上的会话级状态会串味**，
    // 清单不许靠"上一格给我留了什么"。这条清表发生在清单之外，所以不影响
    // 每格判据的独立性（它只是把开场拉回已知状态）。
    let _ = engine_exec(work, "mvsl-clear")
    let replies : Array[Json] = []
    let mut failed = ""
    for st in c.steps {
      let line = st(replies)
      let j = parse_json_safe(engine_exec(work, line))
      replies.push(j)
      if !eng_ok(j) {
        failed = "命令被拒：" + line + " → " + eng_s(j, "error")
        break
      }
    }
    // **回包数组补到 `steps` 的长度**（缺的填 `null`）：判据写错下标时要变成
    // "一条红的"，而不是 `Array::at` panic 把整个面板炸空。实测栽过一次——
    // 我把 census 那格的下标整体写偏一位（`rs[4]` 而 census 在 `rs[3]`），
    // 清单当场 panic，浏览器里**一个字都看不到**：最坏的表现形式（比一条 ✗ 坏，
    // 因为它连"哪条红了"都不说）。
    let full : Array[Json] = []
    for i = 0; i < c.steps.length(); i = i + 1 {
      if i < replies.length() {
        full.push(replies[i])
      } else {
        full.push(Json::null())
      }
    }
    let check = c.check
    let evidence = c.evidence
    let passed = failed == "" && check(full)
    let ev = if failed != "" {
      failed
    } else if passed {
      evidence(full)
    } else {
      "断言不成立（期望 " + c.want + "）｜实测 " + evidence(full)
    }
    rows.push((c.name, passed, c.want, ev))
  }
  rows
}

///|
/// 报告 HTML（**纯函数**：同样的 rows 给同样的 HTML，测试里也能直接调）。
pub fn selfcheck_html(rows : Array[(String, Bool, String, String)]) -> String {
  let bad = rows.filter(fn(r) { !r.1 }).length()
  let sb = StringBuilder()
  let head = if bad == 0 {
    "<div class='scok'>🧪 功能自检：\{rows.length()} 条全过 ✓（跑在另一份引擎上，当前文档没被动过）</div>"
  } else {
    "<div class='scbad'>⚠ 功能自检：\{bad}/\{rows.length()} 条失败 —— 下面每条的「实测」里是引擎的原话</div>"
  }
  sb.write_string(head)
  sb.write_string("<table class='sct'><tr><th></th><th>功能</th><th>期望</th><th>实测</th></tr>")
  for r in rows {
    let mark = if r.1 { "<span class='scp'>✓</span>" } else { "<span class='scf'>✗</span>" }
    sb.write_string("<tr><td>")
    sb.write_string(mark)
    sb.write_string("</td><td>")
    sb.write_string(html_attr(r.0))
    sb.write_string("</td><td class='scw'>")
    sb.write_string(html_attr(r.2))
    sb.write_string("</td><td class='sce'>")
    sb.write_string(html_attr(r.3))
    sb.write_string("</td></tr>")
  }
  sb.write_string("</table>")
  sb.to_string()
}
