/// agent —— 选择子/算子 schema 自证命令（agent/schema_cmds）。
///
/// **为什么需要它**：`select-preview` / `mvsl-set` 收的是选择子 JSON，而字段名
/// 短到没法猜——色相窗是 `{"h":..,"hw":..,"s":..,"sh":..,"l":..,"lh":..}`，
/// 且 `l` 是 **OKLab L**（0..1），不是 HSV 的 V、也不是 0..255。真实多模态模型
/// 面对「把红苹果改成绿色」几乎必然猜错字段名或量纲，然后烧掉好几轮对话去试。
///
/// **为什么不是写在 prompt 里**：写死在 prompt 里的 schema 会随解析器漂移，
/// 而漂移的文档比没有文档更坏。这里每个例子都由 **canonical 写出器**
/// （`selspec_to_json` / `program_to_json`）生成，再用**同一个解析器**验回来；
/// 任何一条验不回就返回错误——宁可报「引擎 bug」，也不发给调用方一段
/// 它照着写必然失败的示例。
///
/// 与 `census`/`probe` 的分工：那两个给**数值**（这个区域的颜色是什么），
/// 这个给**语法**（怎么把数值写成一条选择子）。合起来才是「AI 不当色度计、
/// 也不当 schema 考古学家」。

///|
/// 一条示例选择子（文本 + 自证）。
fn sch_sel(s : @core.SelSpec) -> String {
  let text = @core.selspec_to_json(s)
  // 自证：写出器产出的例子必须能被同一个解析器读回来
  match @core.selspec_from_json(text) {
    Ok(_) => text
    Err(e) => abort("schema 示例不合法（引擎 bug）：\{text} → \{e}")
  }
}

///|
///|
/// schema 里的示例色窗。
///
/// 数值刻意为**真实可达**的量级：色相取 OKLCh 红区（≈28°），彩度取纯红量级
/// （0.20 ± 0.10，sRGB 上限 0.3225），亮度取中间调。示例若用 HSV 的量纲
/// （例如 s=0.85），它会是一条**必然空选**的选择子——照抄的调用方只会得到
/// 一张没变的图。这类"文档合法、语义为空"的示例比没有示例更坏。
fn sch_color() -> @core.ColorWindow {
  { h_center: 28.0, h_half: 25.0, s_center: 0.20, s_half: 0.10, l_center: 0.535, l_half: 0.15, feather: 0.1 }
}

///|
fn sch_geo(x : Double, y : Double, w : Double, h : Double) -> @core.GeoWindow {
  { x, y, w, h, feather: 2.0 }
}

///|
fn sch_atom(e : @core.SelExpr) -> @core.SelSpec {
  { basis: @core.Base, expr: e }
}

///|
/// 一条原子示例：文档 + 示例（示例自证）。
///
/// 两个字段是有意重复的，各服务一个用途：
/// - `example`：**嵌套对象**——给人/模型看清结构与字段名；
/// - `example_json`：同一份文本的**字符串**——直接粘进 `sel_json` /
///   `select-preview` 参数即可，不用模型自己做转义。
/// 只给嵌套对象的话，模型得把对象再序列化成字符串（转义错一个引号就废）；
/// 只给字符串的话，schema 就没法读。两个都给，两边都不将就。
fn sch_entry(t : String, doc : String, spec : @core.SelSpec) -> String {
  sch_entry_pc(t, doc, spec, "")
}

///|
/// 带前置条件的示例条目。
///
/// **`verified` 的准确含义**：示例**语法**由引擎自证（写出器产出 → 同一
/// 解析器读回 → 规范化往返稳定）。**能否求值**取决于画布与已登记资产——
/// `comp` 的种子必须落在色窗内，`assetmask` 的资产必须已登记。这类条目
/// 把条件写在 `precondition` 里，而不是假装示例一定能跑通：
/// 「语法合法」与「在此画布上有效」是两件事，含糊过去就是骗调用方。
fn sch_entry_pc(t : String, doc : String, spec : @core.SelSpec, pc : String) -> String {
  let text = sch_sel(spec)
  let sb = StringBuilder()
  sb.write_string("{\"t\":\"\{t}\",\"doc\":\"\{doc}\"")
  if pc != "" {
    sb.write_string(",\"precondition\":\"\{pc}\"")
  }
  sb.write_string(",\"example\":\{text}")
  sb.write_string(",\"example_json\":\"\{@core.json_escape(text)}\"}")
  sb.to_string()
}

///|
/// `sel-schema`：选择子/算子语法的自证清单（canonical 示例 + 量纲 + 范围）。
fn cmd_sel_schema(s : Session, _tokens : Array[String]) -> String {
  ignore(s)
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"sel-schema\"")
  // 量纲说明：模型最容易錯的就是这里
  sb.write_string(
    ",\"units\":\"color 选择子用的是 **OKLCh/OKLab** 坐标：h/hw = OKLCh 色相（度，0..360 环）；s/sh = **OKLCh 彩度**（sRGB 可达上限 0.3225，纯红 0.258 / 纯绿 0.295 / 纯蓝 0.313 / 纯洋红最高 —— **不是** 0..1 的 HSV 饱和度；整条窗高于上限会被直接拒绝，因为那必然空选）；l/lh = OKLab 感知亮度（0..1，**不是** HSV 的 V、也不是 0..255）；feather = 0..1 的窗宽软化比例。geo 的 x/y/w/h 与 feather 是画布像素，且 geo 的 feather 是**从窗边界向外**衰减到 0 的距离（边界上仍满覆盖、往外 feather 像素落选——**不是**窗内的羽化宽度，方向与蒙版的 feather 相反）\"",
  )
  sb.write_string(
    ",\"how_to_use\":\"每条 example 是给人看的嵌套对象；要传参时用同一行的 example_json 字段（字符串，直接粘进 select_preview 的 sel_json / mvsl_set 的 program_json，不需要自己转义）\"",
  )
  sb.write_string(",\"basis\":[\"base\",\"stage:<0..4096>（引用第 n 个算子之后的中间缓冲；前视引用会被拒绝）\"]")
  // 数值从哪来：把 census/probe 和 schema 接起来
  sb.write_string(
    ",\"where_numbers_come_from\":\"不要猜颜色：probe x= y= 或 census within_json=<区域选择子> 会给出 sel_h / sel_c / sel_l —— **只有这三个 sel_ 前缀的字段能喂选择子**（正是选择子那套坐标）。同一个回包里的 hsv_h / hsv_s / hsv_v 是分析对照，喂进去会一个像素都选不中：纯红 #C81E1E 的 sel_h≈29、sel_c≈0.18，而 hsv_h=0、hsv_s=0.85。把 sel_h→h、sel_c→s、sel_l→l，再用 hw/sh/lh 给容差（色相 ±15~30 度、彩度 ±0.05~0.10、亮度 ±0.10~0.20 起步），然后 select_preview 看图确认\"",
  )
  // 原子
  sb.write_string(",\"atoms\":[")
  let atoms : Array[String] = [
    sch_entry(
      "color",
      "三维软窗：OKLCh 色相环 ±hw 度、OKLCh 彩度中心 s±sh、OKLab 亮度中心 l±lh；三维都接近 1 才接近 1（软与，不是硬切）。三个中心直接取 probe/census 的 sel_h / sel_c / sel_l",
      sch_atom(@core.Atom(@core.Color(sch_color()))),
    ),
    sch_entry(
      "luma",
      "OKLab 亮度单维软窗（l±lh）。要「只改暗部/亮部」用它；**不是** HSV V。中心取 probe/census 的 sel_l",
      sch_atom(@core.Atom(@core.Luma(0.35, 0.15, 0.08))),
    ),
    sch_entry(
      "geo",
      "几何：shape=rect|ellipse，x/y/w/h 画布像素（w/h 必须为正），feather 是边界带宽（0..256px）",
      sch_atom(@core.Atom(@core.Geo(sch_geo(40.0, 30.0, 200.0, 160.0), "rect"))),
    ),
    sch_entry(
      "geograd",
      "沿轴线性渐变软窗：axis=x|y，falloff 是过渡带占比（0..1）。用于「越往下越强」这类",
      sch_atom(
        @core.Atom(
          @core.GeoGrad({
            x0: 0.0,
            y0: 0.0,
            x1: 640.0,
            y1: 0.0,
            axis: "x",
            falloff: 0.5,
          }),
        ),
      ),
    ),
    sch_entry_pc(
      "comp",
      "种子连通域：从 (sx,sy) 出发、颜色 ΔE ≤ de_tol（0..1] 且连通的一整块。**同色异义干扰的出口**（两张红只选一张）。最稳的种子是 select_preview 返回的 component 质心（cx,cy）",
      sch_atom(@core.Atom(@core.Comp(120.0, 90.0, 0.12, sch_color()))),
      "种子 (sx,sy) 自身的色窗 membership 必须 > 0.5，否则报错而不是返回空图",
    ),
    sch_entry_pc(
      "assetmask",
      "外部 mask 资产（内容寻址 sha256，必须先随容器登记）。引擎不内置任何分割模型——未登记会报精确错误，不降级",
      // 示例 hash 用全 0 占位：语法合法，但求值会报「未登记」——这正是要
      // 让调用方看到的边界（示例合法 ≠ 资产存在）
      sch_atom(@core.Atom(@core.AssetMask("0".repeat(64)))),
      "该 sha256 必须已随容器登记为 mask 资产；占位示例本身求值时会报「未登记」",
    ),
  ]
  let mut f = true
  for a in atoms {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(a)
  }
  sb.write_string("]")
  // 组合子
  sb.write_string(",\"combinators\":[")
  let g1 = @core.Geo(sch_geo(0.0, 0.0, 100.0, 100.0), "rect")
  let g2 = @core.Geo(sch_geo(80.0, 80.0, 100.0, 100.0), "ellipse")
  let combs : Array[String] = [
    sch_entry("union", "并集（逐像素取 max）：两块都要", sch_atom(@core.Union([@core.Atom(g1), @core.Atom(g2)]))),
    sch_entry("and", "交集（逐像素取积）：两块都要满足（例如「红色」∩「左半边」）", sch_atom(@core.And([@core.Atom(g1), @core.Atom(g2)]))),
    sch_entry("diff", "差集（clamp(a-b)）：前者减去后者", sch_atom(@core.Diff(@core.Atom(g1), @core.Atom(g2)))),
  ]
  f = true
  for c in combs {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(c)
  }
  sb.write_string("]")
  // 算子
  sb.write_string(",\"ops\":[")
  let ops : Array[String] = [
    "{\"kind\":\"recolor\",\"doc\":\"OKLCh 改色相、保 OKLab 亮度（明暗不变、只换颜色）；hue_deg 是相对旋转角度（-360..360）\",\"uses\":[\"sel\",\"amount\",\"hue_deg\"]}",
    "{\"kind\":\"temperature\",\"doc\":\"蓝↔黄轴平移（暖冷）；正=暖。与色相重映射明确分家\",\"uses\":[\"sel\",\"amount\",\"temp_kelvin\"]}",
    "{\"kind\":\"relight\",\"doc\":\"OKLab L 增益（提亮/压暗）；热增益 0..4\",\"uses\":[\"sel\",\"amount\",\"relight_gain\"]}",
  ]
  f = true
  for o in ops {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(o)
  }
  sb.write_string("]")
  // 完整编辑表示例（含一条保护断言）
  let op : @core.EditOp = {
    id: "e1",
    kind: @core.Recolor,
    sel: sch_atom(@core.Atom(@core.Color(sch_color()))),
    amount: 1.0,
    hue_deg: 120.0,
    temp_kelvin: 0.0,
    relight_gain: 1.0,
    layer: "",
    refine: [@core.Feather(2.0)],
    note: "把红色区域换成绿色",
    evidence: None,
  }
  let prot : @core.Guard = {
    id: "keep_bg",
    sel: sch_atom(@core.Atom(@core.Geo(sch_geo(0.0, 0.0, 640.0, 480.0), "rect"))),
    max_de: 0.01,
    max_changed_ratio: 0.0,
  }
  let prog : @core.EditProgram = { ops: [op], guards: [prot] }
  let prog_text = @core.program_to_json(prog)
  match @core.program_from_json(prog_text) {
    Ok(p) => match @core.validate_program(p) {
      Ok(_) => ()
      Err(e) => abort("schema 编辑表示例不合法（引擎 bug）：\{prog_text} → \{e}")
    }
    Err(e) => abort("schema 编辑表示例不合法（引擎 bug）：\{prog_text} → \{e}")
  }
  sb.write_string(",\"program_example\":\{prog_text}")
  sb.write_string(",\"program_example_json\":\"\{@core.json_escape(prog_text)}\"")
  // `layer` 字段的三种写法（作用域）。写进 schema 是因为"标签也能当作用域"
  // 这件事模型必须知道，而它只读 schema、不读 README。
  sb.write_string(",\"scopes\":[")
  let scopes : Array[String] = [
    "{\"form\":\"layer=\\\"\\\"\",\"doc\":\"文档级（默认）：作用于整幅合成图（层已经乘在一起，选择子看到的是混合色）\"}",
    "{\"form\":\"layer=<层 id>\",\"doc\":\"只作用于该层：这层单独栅格化，选择子在这层自己的像素上求值\"}",
    "{\"form\":\"layer=@<标签>\",\"doc\":\"标签作用域：作用于**带该标签的全部层**（先用 tag <id> <标签>）。活绑定——打/摘标签即改作用范围；落不到任何层会被拒绝，事后摘了标签由 lint 报 P4\"}",
  ]
  f = true
  for sc in scopes {
    if f {
      f = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(sc)
  }
  sb.write_string("]")
  sb.write_string(
    ",\"field_notes\":{\"amount\":\"0..1 总强度（选择子软权重之外的第二个乘子）\",\"refine\":\"数组：grow/shrink/feather/fill_holes/keep_largest/guided，在算子求值前作用于选择子软场\",\"guards\":\"保护断言：max_de 与 max_changed_ratio 是该区域内允许的最大 ΔE 与改动像素比例；用 mvsl-assert 验证\"}",
  )
  sb.write_string(
    ",\"verified\":\"示例语法由引擎自证：canonical 写出器产出 → 同一解析器读回 → 往返稳定。能否在具体画布上求值另见 precondition\"",
  )
  sb.write_string("}")
  sb.to_string()
}
