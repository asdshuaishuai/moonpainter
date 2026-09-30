/// sel-schema 自证 + 「数值 → 选择子」闭环（agent 层）。
///
/// 这一组测试要证明的是一件事：**模型不需要猜 schema，也不需要猜颜色**。
/// schema 由引擎自证给出，数值由 census/probe 给出，两者拼起来就能得到一条
/// 真正命中的选择子。

///|
fn jnum_field(text : String, key : String) -> Double {
  let obj = match @core.parse_json(text) {
    Ok(o) => o
    Err(e) => abort("回包不是 JSON（\{e}）：\{text}")
  }
  let v = match obj.get(key) {
    Some(x) => x
    None => abort("回包缺字段 \{key}：\{text}")
  }
  match v.as_num() {
    Some(x) => x
    None => abort("回包字段 \{key} 不是数字：\{text}")
  }
}

///|
test "sel-schema：自证清单齐备，且每条示例都能被 select-preview 接受" {
  let s = scene("schema-basic")
  let r = run(s, "sel-schema")
  let obj = match @core.parse_json(r) {
    Ok(o) => o
    Err(e) => abort("sel-schema 回包不是 JSON: \{e}")
  }
  assert_true(r.contains("\"verified\":"), msg="schema 缺 verified 自证标记")
  // 量纲必须点明两套坐标系的分工：sel_* 喂选择子，hsv_* 只是对照
  assert_true(r.contains("sel_h"), msg="schema 未指出数值应取自 sel_* 字段")
  assert_true(r.contains("hsv_s"), msg="schema 未点明 hsv_* 只是分析对照")
  // 引导文字不许再引用已废弃的 mean_h/mean_s/mean_l
  assert_true(
    !r.contains("mean_h") && !r.contains("mean_s"),
    msg="schema 仍在引导使用废弃字段名",
  )
  // 六种原子 + 三种组合子 + 三种算子
  for t in ["color", "luma", "geo", "geograd", "comp", "assetmask"] {
    assert_true(r.contains("\"t\":\"\{t}\""), msg="schema 缺原子 \{t}")
  }
  for t in ["union", "and", "diff"] {
    assert_true(r.contains("\"t\":\"\{t}\""), msg="schema 缺组合子 \{t}")
  }
  for k in ["recolor", "temperature", "relight"] {
    assert_true(r.contains("\"kind\":\"\{k}\""), msg="schema 缺算子 \{k}")
  }
  // 量纲与「数值从哪来」必须写明——模型错得最多的就是这两处
  assert_true(r.contains("OKLab 感知亮度"), msg="schema 未点明 l 是 OKLab L")
  assert_true(r.contains("where_numbers_come_from"), msg="schema 未说明数值来源")
  // 把 schema 里的每条选择子示例原样喂回命令面，必须全部被接受。
  // （示例是"照着写就能用"的承诺；有一条不成立，这个命令就在骗人。）
  let atoms = match obj.get("atoms") {
    Some(@core.JArr(a)) => a
    _ => abort("schema 缺 atoms 数组")
  }
  let combs = match obj.get("combinators") {
    Some(@core.JArr(a)) => a
    _ => abort("schema 缺 combinators 数组")
  }
  let mut checked = 0
  let mut evaluated = 0
  let mut preconditioned = 0
  for group in [atoms, combs] {
    for entry in group {
      // 用 example_json（paste-ready 字符串），这正是模型要粘进参数的那个字段
      let ex = match entry.get("example_json") {
        Some(e) => e
        None => abort("schema 条目缺 example_json")
      }
      let text = match ex.as_str() {
        Some(t) => t
        None => abort("example_json 不是字符串")
      }
      // (1) 语法必须合法，且规范化往返稳定（这是 verified 的全部含义）
      let parsed = match @core.selspec_from_json(text) {
        Ok(x) => x
        Err(e) => abort("schema 示例语法不合法：\{text} → \{e}")
      }
      let canon = @core.selspec_to_json(parsed)
      let again = match @core.selspec_from_json(canon) {
        Ok(x) => x
        Err(e) => abort("example_json 二次解析失败：\{e}")
      }
      assert_eq(@core.selspec_to_json(again), canon, msg="schema 示例往返不稳定")
      // (2) 无前置条件的示例还必须能真的求值——否则它就是个不能用的示例
      let has_pc = match entry.get("precondition") {
        Some(_) => true
        None => false
      }
      let rep = run(s, "select-preview \{b64_of(text)} max=64")
      if has_pc {
        // 有前置条件的：要么求值成功，要么给出**明确**的失败原因，不许静默返回空图
        let ok = rep.contains("\"ok\":true")
        let explicit = rep.contains("\"error\":")
        assert_true(ok || explicit, msg="前置条件型示例既没成功也没明确报错：\{rep}")
        preconditioned = preconditioned + 1
      } else {
        assert_true(
          rep.contains("\"ok\":true"),
          msg="无前置条件的 schema 示例竟求值失败：\{text} → \{rep}",
        )
        evaluated = evaluated + 1
      }
      checked = checked + 1
    }
  }
  assert_eq(checked, 9, msg="应校验 6 原子 + 3 组合子")
  assert_eq(preconditioned, 2, msg="comp 与 assetmask 各有一条前置条件")
  assert_eq(evaluated, 7, msg="其余 7 条必须在任意画布上可求值")
  // 完整编辑表示例也必须能装上
  let prog = match obj.get("program_example_json") {
    Some(p) => p
    None => abort("schema 缺 program_example_json")
  }
  let prog_text = match prog.as_str() {
    Some(t) => t
    None => abort("program_example_json 不是字符串")
  }
  let set = run(s, "mvsl-set \{b64_of(prog_text)}")
  assert_true(set.contains("\"ops\":1"), msg=set)
  assert_true(set.contains("\"guards\":1"), msg=set)
}

///|
test "闭环：用 probe 报出来的数字拼选择子，精确命中该区域（模型零猜测）" {
  let s = scene("schema-closed-loop")
  // 场景：整幅蓝底 + 左半红块
  let _ = run(s, "add-rect x=0 y=0 w=160 h=240 fill=#C81E1EFF name=red")
  // 1) 引擎报数值（模型不需要知道「红」的色相是几度）
  let pr = run(s, "probe x=80 y=120 r=4")
  // **只取 sel_ 前缀的字段**：它们是选择子自己那套坐标（OKLCh 色相/彩度 +
  // OKLab 亮度）。同一回包里的 hsv_* 是分析对照，喂进 h/s 会一个像素都选不中
  // ——这正是本条测试要钉住的陷阱。
  let h = jnum_field(pr, "sel_h")
  let chroma = jnum_field(pr, "sel_c")
  let l = jnum_field(pr, "sel_l")
  // 两套坐标系在同一回包里就能看出不是一回事（纯红：#C81E1E）
  assert_true(
    jnum_field(pr, "hsv_h") != h || jnum_field(pr, "hsv_s") != chroma,
    msg="sel_* 与 hsv_* 不应雷同（雷同说明报告层串了坐标系）",
  )
  // 2) 照 sel-schema 的字面量纲拼一条 color 选择子（容差是唯一的人类输入）
  let sel = "{\"basis\":\"base\",\"expr\":{\"t\":\"color\",\"w\":{\"h\":\{h},\"hw\":20,\"s\":\{chroma},\"sh\":0.06,\"l\":\{l},\"lh\":0.15,\"feather\":0.1}}}"
  let rep = run(s, "select-preview \{b64_of(sel)} max=64")
  assert_true(rep.contains("\"ok\":true"), msg=rep)
  // 3) 命中面积必须正好是左半（0.5），且只有一个连通域
  assert_true(rep.contains("\"coverage\":0.5"), msg="从引擎数值拼出的选择子没命中左半：\{rep}")
  assert_true(rep.contains("\"components\":1"), msg=rep)
  assert_true(rep.contains("\"bbox\":[0,0,159,239]"), msg=rep)
  // 4) 同一条选择子装进编辑表后，改动像素数必须等于该区域面积
  let prog = "{\"version\":1,\"ops\":[{\"id\":\"e1\",\"kind\":\"recolor\",\"sel\":\{sel},\"amount\":1,\"hue_deg\":120,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}],\"guards\":[]}"
  let set = run(s, "mvsl-set \{b64_of(prog)}")
  assert_true(set.contains("\"ops\":1"), msg=set)
  let imp = run(s, "mvsl-impact")
  assert_true(imp.contains("\"changed\":38400"), msg="改动像素数应为 160×240：\{imp}")
  assert_true(imp.contains("\"leak_ratio\":0"), msg="选区外不得有泄漏：\{imp}")
}

///|
test "文档里的范围就是执行时的范围（文档不许漂移）" {
  let s = scene("schema-ranges")
  // geo：w/h 必须为正、shape 只支持 rect|ellipse、feather 0..256px
  let zero_w = "{\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":0,\"h\":10,\"feather\":0}}}"
  assert_true(
    run(s, "select-preview \{b64_of(zero_w)}").contains("w/h 必须为正"),
    msg="geo 零宽必须拒绝",
  )
  let bad_shape = "{\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"triangle\",\"w\":{\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"feather\":0}}}"
  assert_true(
    run(s, "select-preview \{b64_of(bad_shape)}").contains("只支持 rect|ellipse"),
    msg="未知形状必须拒绝",
  )
  let big_feather = "{\"basis\":\"base\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":10,\"h\":10,\"feather\":999}}}"
  assert_true(
    run(s, "select-preview \{b64_of(big_feather)}").contains("feather 越界"),
    msg="feather 上限必须与文档一致",
  )
  // color：h_half 0..180 度、s/sh/l/lh 0..1
  let hue_half = "{\"basis\":\"base\",\"expr\":{\"t\":\"color\",\"w\":{\"h\":0,\"hw\":200,\"s\":0.5,\"sh\":0.1,\"l\":0.5,\"lh\":0.1,\"feather\":0}}}"
  assert_true(
    run(s, "select-preview \{b64_of(hue_half)}").contains("h_half 越界"),
    msg="h_half 上限必须与文档一致",
  )
  let sat_out = "{\"basis\":\"base\",\"expr\":{\"t\":\"color\",\"w\":{\"h\":0,\"hw\":10,\"s\":1.5,\"sh\":0.1,\"l\":0.5,\"lh\":0.1,\"feather\":0}}}"
  assert_true(
    run(s, "select-preview \{b64_of(sat_out)}").contains("s_center/s_half 越界"),
    msg="饱和度范围必须与文档一致",
  )
  // luma：0..1
  let luma_out = "{\"basis\":\"base\",\"expr\":{\"t\":\"luma\",\"l\":1.4,\"lh\":0.1,\"feather\":0}}"
  assert_true(
    run(s, "select-preview \{b64_of(luma_out)}").contains("luma 选择子参数越界"),
    msg="luma 范围必须与文档一致",
  )
  // color 的彩度窗整条高于 sRGB 可达彩度 → 必然空选，必须在装表前拒绝。
  // （这是"命令成功但一个像素都没选中"最典型的入口：把 HSV 饱和度填进来。）
  let impossible_chroma = "{\"basis\":\"base\",\"expr\":{\"t\":\"color\",\"w\":{\"h\":28,\"hw\":25,\"s\":0.85,\"sh\":0.15,\"l\":0.535,\"lh\":0.15,\"feather\":0.1}}}"
  let imp = run(s, "select-preview \{b64_of(impossible_chroma)}")
  assert_true(imp.contains("必然空选"), msg="整条高于可达彩度的窗必须被拒绝：\{imp}")
  assert_true(imp.contains("OKLCh 彩度"), msg="错误信息必须点明 s 是彩度：\{imp}")
  // 宽窗覆盖到可达区间则是合法的（判据是窗的下沿，不是中心）
  let wide_ok = "{\"basis\":\"base\",\"expr\":{\"t\":\"color\",\"w\":{\"h\":28,\"hw\":25,\"s\":0.4,\"sh\":0.2,\"l\":0.535,\"lh\":0.15,\"feather\":0.1}}}"
  assert_true(
    run(s, "select-preview \{b64_of(wide_ok)}").contains("\"ok\":true"),
    msg="下沿落在可达区间内的宽窗不该被误拒",
  )
  // comp：de_tol 0..1]
  let tol_out = "{\"basis\":\"base\",\"expr\":{\"t\":\"comp\",\"sx\":1,\"sy\":1,\"de_tol\":2.0,\"w\":{\"h\":0,\"hw\":10,\"s\":0.5,\"sh\":0.1,\"l\":0.5,\"lh\":0.1,\"feather\":0}}}"
  assert_true(
    run(s, "select-preview \{b64_of(tol_out)}").contains("ΔE 容差越界"),
    msg="comp 容差范围必须与文档一致",
  )
  // geograd：axis 只支持 x|y、falloff 0..1
  let grad_axis = "{\"basis\":\"base\",\"expr\":{\"t\":\"geograd\",\"w\":{\"x0\":0,\"y0\":0,\"x1\":1,\"y1\":0,\"axis\":\"z\",\"falloff\":0.5}}}"
  assert_true(
    run(s, "select-preview \{b64_of(grad_axis)}").contains("grad 轴只支持 x|y"),
    msg="未知轴必须拒绝",
  )
  // union/and 至少两个子选择子
  let one_union = "{\"basis\":\"base\",\"expr\":{\"t\":\"union\",\"items\":[{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":5,\"h\":5,\"feather\":0}}]}}"
  assert_true(
    run(s, "select-preview \{b64_of(one_union)}").contains("至少 2 个子选择子"),
    msg="单元素 union 必须拒绝",
  )
  // 前视 stage 基准（schema 里写明了会被拒绝）
  let fwd = "{\"basis\":\"stage:3\",\"expr\":{\"t\":\"geo\",\"shape\":\"rect\",\"w\":{\"x\":0,\"y\":0,\"w\":5,\"h\":5,\"feather\":0}}}"
  let fwd_prog = "{\"version\":1,\"ops\":[{\"id\":\"e1\",\"kind\":\"recolor\",\"sel\":\{fwd},\"amount\":1,\"hue_deg\":10,\"temp_kelvin\":0,\"relight_gain\":1,\"refine\":[],\"note\":\"\",\"evidence\":null}],\"guards\":[]}"
  assert_true(
    run(s, "mvsl-set \{b64_of(fwd_prog)}").contains("前视引用"),
    msg="前视 stage 必须拒绝",
  )
}
