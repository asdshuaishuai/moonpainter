// ②B 滤镜库的参数面（PLAN 七十八）：
//   * **表不变量**：`filter_param_rows` 是键清单/范围/中性值/整数标记的**唯一**
//     来源——表序必须是键名升序（`filter_param_error` 按表序逐位对，而容器里
//     存的就是升序；表序错了容器就**读不回来**，实测 threshold 踩过）；
//   * **中性值**：`filter_is_noop` 是 `lint` 判"装了却什么都不干"的唯一依据；
//   * **契约档**：带滤镜参数的文档必须声明第 6 档（老引擎解析不到算子名会拒绝
//     打开，但"已知算子 + 手改 params"这种容器会被静静忽略）；
//   * **canonical**：`params` 按键名升序（`sort_params` 一处保证），老文档
//     （没有 params）字节一个都不变。

///|
/// 造一个滤镜调整值（参数按键名升序，走构造点）。
fn mk_filter(op : @core.AdjustOp, ps : Array[(String, Double)]) -> @core.Adjust {
  @core.make_filter_adjust(op, ps)
}

///|
test "滤镜表不变量：键名严格升序、中性值落在范围内、键名字符集" {
  let mut filters = 0
  for op in @core.all_adjust_ops() {
    let rows = @core.filter_param_rows(op)
    let name = @core.adjust_op_name(op)
    if rows.length() == 0 {
      // 非滤镜算子：表必须为空（`is_filter_op` 与"血管里有没有参数"是同一件事）
      assert_false(@core.is_filter_op(op), msg="\{name} 不该被当成滤镜")
      continue
    }
    filters = filters + 1
    assert_true(@core.is_filter_op(op), msg="\{name} 应当是滤镜")
    let mut prev = ""
    for r in rows {
      // ①键名升序（严格：不允许相等，重复键会让"按键名取值"有两种读法）
      if prev != "" {
        assert_true(
          @core.param_key_less(prev, r.key),
          msg="\{name} 的表序必须是键名升序：\{prev} 之后出现了 \{r.key}",
        )
      }
      prev = r.key
      // ②中性值在范围内（"缺参数填中性值"不能填出一个非法值）
      assert_true(
        r.neutral >= r.lo && r.neutral <= r.hi,
        msg="\{name} 的 \{r.key} 中性值 \{r.neutral} 不在 [\{r.lo}..\{r.hi}] 里",
      )
      assert_true(r.lo <= r.hi, msg="\{name} 的 \{r.key} 范围写反了")
      // ③键名只许小写字母/下划线/数字（要进命令行 k=v 与 JSON 键）
      for ch in r.key {
        let c = ch.to_int()
        let ok = (c >= 97 && c <= 122) || c == 95 || (c >= 48 && c <= 57)
        assert_true(ok, msg="\{name} 的键 \{r.key} 里有不该出现的字符")
      }
      // ④说明非空（字典是 LLM 唯一的说明书，键旁边没有话等于没说明）
      assert_true(r.doc.length() > 0, msg="\{name} 的 \{r.key} 缺说明")
    }
  }
  // ②B 一共 8 个滤镜（少一个就说明表被删了）
  assert_eq(filters, 8)
}

///|
test "滤镜键清单与算子表一致：每个算子都有自己的键，且并集覆盖 17 个键" {
  let union : Array[String] = []
  for op in @core.all_adjust_ops() {
    for k in @core.filter_param_keys(op) {
      if !union.contains(k) {
        union.push(k)
      }
    }
  }
  // 16 个**不同**键 = 2(motion-blur)+3(radial-blur)+2(noise)+1(pixelate)+1(posterize)
  //      +2(threshold)+3(hue-sat)+3(color-balance) 再减去重复的 `radius`
  assert_eq(union.length(), 16)
  // 正控：`filter_param_value` 取得到；负控：不存在的键取不到
  let adj = mk_filter(@core.AdjustOp::HueSat, [("hue", 12.0)])
  assert_eq(@core.filter_param_value(adj.params, "hue"), Some(12.0))
  assert_eq(@core.filter_param_value(adj.params, "sat"), None)
  assert_eq(@core.filter_param_value(adj.params, "nope"), None)
}

///|
test "sort_params：反序输入要排成键名升序（String 的 `>` 不是字典序，实测踩过）" {
  let sorted = @core.sort_params([
    ("radius", 3.0),
    ("mono", 1.0),
    ("amount", 0.5),
    ("level", 0.25),
    ("channel", 2.0),
    ("center_y", 0.75),
    ("center_x", 0.25),
  ])
  let keys = sorted.map(fn(p) { p.0 })
  assert_eq(
    keys,
    ["amount", "center_x", "center_y", "channel", "level", "mono", "radius"],
  )
  // 正控：已经是升序的不许被改坏（排序必须是幂等的）
  assert_eq(@core.sort_params(sorted).map(fn(p) { p.0 }), keys)
  // 构造点存的就是升序（不是"调用方自己记得排"）
  let adj = mk_filter(@core.AdjustOp::ColorBalance, [
    ("cr", 0.2),
    ("cg", -0.1),
    ("cb", 0.05),
  ])
  assert_eq(adj.params.map(fn(p) { p.0 }), ["cb", "cg", "cr"])
}

///|
test "滤镜判据：缺键/多键/乱序/越界/非整数 五类都要报，合法值要收" {
  // 正控：表里每个键都取中性值 ⇒ 合法（"什么都不干"是合法配置，lint 才说话）
  for op in @core.all_adjust_ops() {
    if !@core.is_filter_op(op) {
      continue
    }
    let rows = @core.filter_param_rows(op)
    let neutral = rows.map(fn(r) { (r.key, r.neutral) })
    assert_true(
      @core.filter_param_error(op, @core.sort_params(neutral)) is None,
      msg="\{@core.adjust_op_name(op)} 的中性参数必须合法",
    )
    // 缺一个键
    let short = @core.sort_params(neutral).copy()
    let _ = short.pop()
    match @core.filter_param_error(op, short) {
      Some(e) => assert_true(e.contains("需要"), msg="缺键的话要说清需要几个：\{e}")
      None => abort("\{@core.adjust_op_name(op)} 少给一个键竟然合法")
    }
    // 多一个键（渲染器不读它 = 收了也是丢掉）
    let long = @core.sort_params(neutral).copy()
    long.push(("zzz", 1.0))
    assert_true(
      @core.filter_param_error(op, long) is Some(_),
      msg="\{@core.adjust_op_name(op)} 多给一个键要报",
    )
  }
  // 乱序：把 motion-blur 的两个键反过来给（canonical 字节要确定 ⇒ 必须报）
  match @core.filter_param_error(@core.AdjustOp::MotionBlur, [("radius", 4.0), ("angle", 30.0)]) {
    Some(e) => assert_true(e.contains("升序"), msg="乱序的话要指名升序：\{e}")
    None => abort("乱序的参数竟然合法")
  }
  // 越界：每个键各越上界一格
  for op in @core.all_adjust_ops() {
    if !@core.is_filter_op(op) {
      continue
    }
    let rows = @core.filter_param_rows(op)
    let mut i = 0
    for r in rows {
      let bad = rows.map(fn(x) { (x.key, x.neutral) })
      bad[i] = (r.key, r.hi + 1.0)
      match @core.filter_param_error(op, bad) {
        Some(e) =>
          assert_true(
            e.contains(r.key) && e.contains("超出"),
            msg="\{@core.adjust_op_name(op)} 的 \{r.key} 越界要说键名与范围：\{e}",
          )
        None => abort("\{@core.adjust_op_name(op)} 的 \{r.key}=\{r.hi + 1.0} 竟然合法")
      }
      i = i + 1
    }
    // 非整数：只对标的 `integral` 键（阈值 channel / 像素化 size / 海报化 levels）
    let mut j = 0
    for r in rows {
      if r.integral {
        let bad = rows.map(fn(x) { (x.key, x.neutral) })
        // 取 `lo + 0.5`：**在范围内但非整数**（用 neutral+0.5 会先被范围判据接住，
        // 那条路测的是范围不是整数；threshold 的 neutral 恰好等于上界，实测踩过）
        bad[j] = (r.key, r.lo + 0.5)
        match @core.filter_param_error(op, bad) {
          Some(e) =>
            assert_true(
              e.contains("必须是整数"),
              msg="\{@core.adjust_op_name(op)} 的 \{r.key}=…+0.5 要报整数：\{e}",
            )
          None => abort("\{@core.adjust_op_name(op)} 的 \{r.key} 非整数竟然合法")
        }
      }
      j = j + 1
    }
  }
}

///|
test "滤镜与其他参数字族互斥：滤镜带色阶/曲线要报，非滤镜带 params 要报" {
  let hue = mk_filter(@core.AdjustOp::HueSat, [("sat", 0.5)])
  match @core.adjust_param_error({ ..hue, levels: Some(@core.levels_identity()) }) {
    Some(e) => assert_true(e.contains("色阶"), msg="要说清不吃色阶：\{e}")
    None => abort("滤镜带色阶参数竟然合法")
  }
  match @core.adjust_param_error({ ..hue, curve: [(0.0, 0.0), (1.0, 1.0)] }) {
    Some(e) => assert_true(e.contains("points"), msg="要说清不吃 points：\{e}")
    None => abort("滤镜带曲线控制点竟然合法")
  }
  // 反方向：亮度层带着 params（手改容器）——渲染器不读它，必须报
  let bright = @core.make_adjust(@core.AdjustOp::Brightness, 0.3)
  match @core.adjust_param_error({ ..bright, params: [("hue", 12.0)] }) {
    Some(e) => assert_true(e.contains("不吃参数表"), msg="要说清不吃参数表：\{e}")
    None => abort("亮度层带 params 竟然合法")
  }
  // 滤镜全都不吃 value（`adjust_uses_value` 一处说了算）
  for op in @core.all_adjust_ops() {
    if @core.is_filter_op(op) {
      assert_false(
        @core.adjust_uses_value(op),
        msg="\{@core.adjust_op_name(op)} 不该读 value",
      )
    }
  }
}

///|
test "滤镜空转判据：中性参数要报，非中性要收（阈值恒不空转）" {
  // 正控：每个多键滤镜给一个非中性值 ⇒ 不空转
  assert_false(@core.filter_is_noop(@core.AdjustOp::MotionBlur, [("angle", 0.0), ("radius", 1.0)]))
  assert_false(@core.filter_is_noop(@core.AdjustOp::Noise, [("amount", 0.01), ("mono", 0.0)]))
  assert_false(@core.filter_is_noop(@core.AdjustOp::HueSat, [("hue", 0.0), ("light", 0.5), ("sat", 0.0)]))
  assert_false(@core.filter_is_noop(@core.AdjustOp::ColorBalance, [("cb", 0.0), ("cg", 0.0), ("cr", 0.01)]))
  // 负控：中性 ⇒ 空转
  assert_true(@core.filter_is_noop(@core.AdjustOp::MotionBlur, [("angle", 0.0), ("radius", 0.0)]))
  assert_true(@core.filter_is_noop(@core.AdjustOp::RadialBlur, [("center_x", 0.5), ("center_y", 0.5), ("radius", 0.0)]))
  assert_true(@core.filter_is_noop(@core.AdjustOp::Noise, [("amount", 0.0), ("mono", 1.0)]))
  // ⚠️ 像素化/海报化的"中性值"本来就是**看得见的最小值**（size=2 / levels=2）：
  // 它们不空转，别把中性值当成"什么都不干"的同义词（那是两件事）。
  assert_false(@core.filter_is_noop(@core.AdjustOp::Pixelate, [("size", 2.0)]))
  assert_false(@core.filter_is_noop(@core.AdjustOp::Posterize, [("levels", 2.0)]))
  // 阈值任何取值都把画面变成纯黑白：level=0/1 是极值，不是空转
  assert_false(@core.filter_is_noop(@core.AdjustOp::Threshold, [("channel", 3.0), ("level", 0.0)]))
  assert_false(@core.filter_is_noop(@core.AdjustOp::Threshold, [("channel", 3.0), ("level", 1.0)]))
}

///|
test "滤镜契约档：带 params 的文档声明第 6 档，负控是不带的照旧第 1 档" {
  let doc = @core.new_document("uuid-rc-2b", 64, 64)
  let l = @core.default_layer("l1", "grain", 0.0, 0.0, 64.0, 64.0)
  let base = { ..l, kind: @core.ShapeKind::Adjust }
  // 负控：亮度层（老参数）不该抬档
  let plain = { ..base, adjust: Some(@core.make_adjust(@core.AdjustOp::Brightness, 0.3)) }
  doc.layers.push(plain)
  assert_eq(@core.required_render_contract(doc), 1)
  // 正控：滤镜层（params 非空）必须抬到"adjust 扩展参数"那一档
  let filt = {
    ..base,
    adjust: Some(mk_filter(@core.AdjustOp::Noise, [("amount", 0.4), ("mono", 1.0)])),
  }
  doc.layers.push(filt)
  assert_eq(
    @core.required_render_contract(doc),
    @core.RENDER_CONTRACT_ADJUST_PARAMS,
    msg="带滤镜参数的文档必须声明第 6 档",
  )
}
