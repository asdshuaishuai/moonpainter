// 色阶 / 曲线的参数面（PLAN 七十）：
//   * **判据一处**：`levels_error` / `curve_error` / `adjust_param_error` 三句话
//     同时被命令入口、容器读入端、`lint` 读——这里逐格咬住它们；
//   * **中性值**：`levels_identity` / `levels_is_identity` / `curve_is_identity`
//     是 `lint` 判"装了却什么都不干"的唯一依据，"每个参数各自偏离一格"都要报；
//   * **契约档**：用了 levels/curve 就必须声明第 6 档（老引擎会整层丢掉或按空
//     操作施加），负控是"亮度层照旧第 1 档"（一律抬档等于让版本闸失去分辨力）；
//   * **canonical**：老文档字节不变（没有 levels/curve 时字段压根不写），
//     新参数往返逐值一致。

///|
/// NaN（不引入 `moonbitlang/core/double`：仓库纪律是引擎包零第三方依赖，标准库
/// 子包虽允许，但为一个测试值多开一条 import 不值得——`inf - inf` 就是 NaN）。
fn nan_v() -> Double {
  1.0e308 * 10.0 - 1.0e308 * 10.0
}

///|
fn mk_levels(a : Double, b : Double, g : Double, c : Double, d : Double) -> @core.Levels {
  { in_lo: a, in_hi: b, gamma: g, out_lo: c, out_hi: d }
}

///|
test "色阶判据：每个参数各越一格都要拒，合法区间的边界要收" {
  // 正控：中性值必须收（"什么都不改"是合法配置，只是 lint 会说它是白装）
  assert_true(@core.levels_error(@core.levels_identity()) is None, msg="中性色阶要合法")
  assert_true(
    @core.levels_error(mk_levels(0.0, 1.0, 0.01, 0.0, 1.0)) is None,
    msg="gamma 下界 0.01 要收",
  )
  assert_true(
    @core.levels_error(mk_levels(0.0, 1.0, 100.0, 1.0, 1.0)) is None,
    msg="gamma 上界 100 要收",
  )
  assert_true(
    @core.levels_error(mk_levels(0.3, 0.7, 1.0, 0.2, 0.9)) is None,
    msg="典型非中性色阶要合法",
  )
  // 反例：每一条都对应一个"否则会静默错渲"的具体后果
  let bad : Array[(@core.Levels, String)] = [
    (mk_levels(-0.1, 1.0, 1.0, 0.0, 1.0), "in_lo 为负"),
    (mk_levels(0.0, 1.1, 1.0, 0.0, 1.0), "in_hi 超 1"),
    (mk_levels(0.6, 0.6, 1.0, 0.0, 1.0), "黑白点相等（除零）"),
    (mk_levels(0.7, 0.3, 1.0, 0.0, 1.0), "黑白点反序"),
    (mk_levels(0.0, 1.0, 0.0, 0.0, 1.0), "gamma=0（1/gamma 除零）"),
    (mk_levels(0.0, 1.0, -1.0, 0.0, 1.0), "gamma 为负"),
    (mk_levels(0.0, 1.0, 0.005, 0.0, 1.0), "gamma 小于下界"),
    (mk_levels(0.0, 1.0, 1.0, -0.1, 1.0), "out_lo 为负"),
    (mk_levels(0.0, 1.0, 1.0, 0.0, 1.5), "out_hi 超 1"),
    (mk_levels(0.0, 1.0, 1.0, 0.9, 0.2), "输出黑白点反序"),
    (
      mk_levels(
        nan_v(),
        nan_v(),
        nan_v(),
        nan_v(),
        nan_v(),
      ),
      "NaN（比较全 false，判据要写成 !(x>=lo && x<=hi)）",
    ),
  ]
  // 自检：nan_v 真的是 NaN（否则上面那格"NaN 要拒"其实什么都没验）
  assert_false(nan_v() == nan_v(), msg="nan_v() 必须是 NaN")
  for c in bad {
    assert_true(@core.levels_error(c.0) is Some(_), msg="\{c.1} 必须拒")
  }
}

///|
test "色阶的中性值：五个参数**各自**偏离一格都不再是中性" {
  assert_true(@core.levels_is_identity(@core.levels_identity()), msg="中性值要判成中性")
  let off : Array[(@core.Levels, String)] = [
    (mk_levels(0.1, 1.0, 1.0, 0.0, 1.0), "in_lo"),
    (mk_levels(0.0, 0.9, 1.0, 0.0, 1.0), "in_hi"),
    (mk_levels(0.0, 1.0, 1.5, 0.0, 1.0), "gamma"),
    (mk_levels(0.0, 1.0, 1.0, 0.1, 1.0), "out_lo"),
    (mk_levels(0.0, 1.0, 1.0, 0.0, 0.9), "out_hi"),
  ]
  for c in off {
    assert_false(@core.levels_is_identity(c.0), msg="\{c.1} 偏离 0.1 就不是中性了")
  }
  // 反面（本仓库反复栽的那种）：把中性值写成"任何值都不算中性"也能过上面五格，
  // 于是真正要守的"gamma=1.0000000001 这种量化噪声不该被报成白装"没人守。
  // 容差 1e-9 ⇒ 1e-12 的扰动必须是中性。
  assert_true(
    @core.levels_is_identity(mk_levels(1.0e-12, 1.0 - 1.0e-12, 1.0 + 1.0e-12, 0.0, 1.0)),
    msg="量化噪声不是「调过了」",
  )
}

///|
test "曲线判据：点数/递增/越界/NaN 各拒一格，单调点表要收" {
  let ok : Array[(Double, Double)] = [(0.0, 0.0), (0.5, 0.6), (1.0, 1.0)]
  assert_true(@core.curve_error(ok) is None, msg="常规 S 曲线要合法")
  assert_true(
    @core.curve_error([(0.25, 0.1), (0.75, 0.9)]) is None,
    msg="端点不到边（区间外钳住）也是合法的",
  )
  let bad : Array[(Array[(Double, Double)], String)] = [
    ([], "0 个点"),
    ([(0.5, 0.5)], "1 个点"),
    ([(0.0, 0.0), (0.0, 0.5), (1.0, 1.0)], "x 不递增（相等）"),
    ([(0.0, 0.0), (0.5, 0.5), (0.4, 0.6), (1.0, 1.0)], "x 反序"),
    ([(-0.1, 0.0), (1.0, 1.0)], "x 为负"),
    ([(0.0, 1.1), (1.0, 1.0)], "y 超 1"),
    ([(0.0, nan_v()), (1.0, 1.0)], "y 是 NaN"),
  ]
  for c in bad {
    assert_true(@core.curve_error(c.0) is Some(_), msg="\{c.1} 必须拒")
  }
  // 上界：33 个点要拒（"最多 32"是一句承诺，没有测试就只是注释）
  let many : Array[(Double, Double)] = []
  let mut i = 0
  while i < 33 {
    many.push((i.to_double() / 32.0, i.to_double() / 32.0))
    i = i + 1
  }
  assert_true(@core.curve_error(many) is Some(_), msg="33 个点要拒")
  let _ = many.pop()
  assert_true(@core.curve_error(many) is None, msg="32 个点要收（边界）")
}

///|
test "曲线的中性值：对角线才算，空表/单点**不算**" {
  assert_true(
    @core.curve_is_identity([(0.0, 0.0), (0.25, 0.25), (1.0, 1.0)]),
    msg="对角线上的点表是中性",
  )
  assert_false(
    @core.curve_is_identity([(0.0, 0.0), (0.5, 0.55), (1.0, 1.0)]),
    msg="一个点偏离就不是中性",
  )
  // 空集上的全称命题恒真 ⇒ 空表会被报成"控制点全在对角线上"（与"没有曲线"
  // 自相矛盾）。判据的空集也要说话。
  assert_false(@core.curve_is_identity([]), msg="空表不算中性（那是「没有曲线」）")
  assert_false(@core.curve_is_identity([(0.5, 0.5)]), msg="单点不算中性")
}

///|
test "参数组合判据：哪个算子读哪些参数，四个方向都要说话" {
  // 正控：三条合法路径
  let lv = mk_levels(0.2, 0.8, 1.2, 0.0, 1.0)
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Levels, 0.0), levels: Some(lv) })
    is None,
    msg="levels + levels 要合法",
  )
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.5, 0.7), (1.0, 1.0)]
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Curves, 0.0), curve: pts })
    is None,
    msg="curves + curve 要合法",
  )
  assert_true(
    @core.adjust_param_error(@core.make_adjust(@core.AdjustOp::Brightness, 0.3)) is None,
    msg="brightness + value 要合法",
  )
  // 反例：四类错配各一格
  assert_true(
    @core.adjust_param_error(@core.make_adjust(@core.AdjustOp::Levels, 0.0)) is Some(_),
    msg="levels 缺参数要报（不是静默按中性建层）",
  )
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Curves, 0.0), curve: [] })
    is Some(_),
    msg="curves 缺参数要报",
  )
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Levels, 0.0), curve: pts })
    is Some(_),
    msg="levels 带点表要报（两族互斥）",
  )
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Curves, 0.0), levels: Some(lv) })
    is Some(_),
    msg="curves 带色阶要报",
  )
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Brightness, 0.3), levels: Some(lv) })
    is Some(_),
    msg="亮度算子带色阶要报（收了也不读 = 静默丢参数）",
  )
  assert_true(
    @core.adjust_param_error({ ..@core.make_adjust(@core.AdjustOp::Invert, 0.0), curve: pts })
    is Some(_),
    msg="反相算子带点表要报",
  )
  // 取值范围也要经这条判据转达（不是"形状对了就算过"）
  assert_true(
    @core.adjust_param_error({
      ..@core.make_adjust(@core.AdjustOp::Levels, 0.0),
      levels: Some(mk_levels(0.0, 1.0, 0.0, 0.0, 1.0)),
    })
    is Some(_),
    msg="形状对了但 gamma=0 仍要报",
  )
}

///|
test "哪个算子读 value：清单与 all_adjust_ops 对齐（加算子时漏一格会红）" {
  let no_value : Array[String] = []
  for op in @core.all_adjust_ops() {
    if !@core.adjust_uses_value(op) {
      no_value.push(@core.adjust_op_name(op))
    }
  }
  // 断言的是**集合**：这四族不读 value，其余**每一个**都读。加算子忘了登记就会被
  // 这条抓住（`param_audit`/`field_audit` 都照不到这个语义）。⚠️ 别用 `sort()`
  // 再比数组：本仓库的 `Array::sort()` 不是按字典序（实测给出
  // `[curves, invert, levels, grayscale]`），断言会以"看起来像排序问题"的形式
  // 失败，而真正要守的"有没有漏一格"反而被噪声埋掉。
  let no_value_names = ["invert", "grayscale", "levels", "curves"]
  assert_eq(no_value.length(), no_value_names.length(), msg="不读 value 的算子条数")
  for n in no_value_names {
    assert_true(
      no_value.contains(n),
      msg=n + " 应当不读 value（实际：" + no_value.join(" ") + "）",
    )
  }
  for op in @core.all_adjust_ops() {
    let n = @core.adjust_op_name(op)
    if !no_value_names.contains(n) {
      assert_true(@core.adjust_uses_value(op), msg="\{n} 应当读 value（漏登记？）")
    }
  }
  assert_true(@core.adjust_uses_value(@core.AdjustOp::Vignette), msg="暗角读 value")
  assert_true(@core.adjust_uses_value(@core.AdjustOp::Smooth), msg="磨皮读 value")
}

///|
test "契约档：用了色阶/曲线必须声明第 6 档，亮度层照旧第 1 档（负控）" {
  let doc = @core.new_document("uuid-adj-0001", 40, 40)
  let l = @core.default_layer("l1", "pic", 0.0, 0.0, 40.0, 40.0)
  // 负控：只有亮度层 ⇒ 老引擎完全支持它，不许抬档
  let plain = {
    ..doc,
    layers: [{ ..l, kind: @core.ShapeKind::Adjust, adjust: Some(@core.make_adjust(@core.AdjustOp::Brightness, 0.3)) }],
  }
  assert_eq(@core.required_render_contract(plain), 1, msg="亮度层 → 基础档")
  // 色阶：老引擎的 `adjust_of` 读不出 levels ⇒ 整层丢掉 / 按空操作施加
  let lv = mk_levels(0.2, 0.8, 1.2, 0.0, 1.0)
  let with_lv = {
    ..doc,
    layers: [
      {
        ..l,
        kind: @core.ShapeKind::Adjust,
        adjust: Some({ ..@core.make_adjust(@core.AdjustOp::Levels, 0.0), levels: Some(lv) }),
      },
    ],
  }
  assert_eq(
    @core.required_render_contract(with_lv),
    @core.RENDER_CONTRACT_ADJUST_PARAMS,
    msg="色阶 → 第 6 档",
  )
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.5, 0.6), (1.0, 1.0)]
  let with_cv = {
    ..doc,
    layers: [
      {
        ..l,
        kind: @core.ShapeKind::Adjust,
        adjust: Some({ ..@core.make_adjust(@core.AdjustOp::Curves, 0.0), curve: pts }),
      },
    ],
  }
  assert_eq(
    @core.required_render_contract(with_cv),
    @core.RENDER_CONTRACT_ADJUST_PARAMS,
    msg="曲线 → 第 6 档",
  )
  // 最高档必须 ≥ 每一档（读入端拿它当闸）
  assert_true(
    @core.RENDER_CONTRACT_VERSION >= @core.RENDER_CONTRACT_ADJUST_PARAMS,
    msg="RENDER_CONTRACT_VERSION 必须覆盖新档",
  )
}

///|
test "canonical：老文档字节不变（没参数就不写字段），新参数往返逐值一致" {
  let doc = @core.new_document("uuid-adj-0002", 40, 40)
  let l = @core.default_layer("l1", "pic", 0.0, 0.0, 40.0, 40.0)
  // ①亮度层：JSON 里**不许**出现 levels/curve 字段（老文档字节一个都不变）
  let plain = {
    ..doc,
    layers: [{ ..l, kind: @core.ShapeKind::Adjust, adjust: Some(@core.make_adjust(@core.AdjustOp::Brightness, 0.3)) }],
  }
  let t1 = @core.doc_to_json(plain)
  assert_true(t1.contains("\"op\":\"brightness\""), msg="算子名要写出来")
  assert_false(t1.contains("levels"), msg="没给色阶就不许写 levels 字段：\{t1}")
  assert_false(t1.contains("curve"), msg="没给曲线就不许写 curve 字段：\{t1}")
  // ②色阶 + 曲线：往返字节一致，且五个数/点表逐值相等
  let lv = mk_levels(0.125, 0.875, 1.25, 0.0625, 0.9375)
  let pts : Array[(Double, Double)] = [(0.0, 0.0), (0.25, 0.125), (1.0, 1.0)]
  let two = {
    ..doc,
    layers: [
      {
        ..l,
        kind: @core.ShapeKind::Adjust,
        adjust: Some({ ..@core.make_adjust(@core.AdjustOp::Levels, 0.0), levels: Some(lv) }),
      },
      {
        ..@core.default_layer("l2", "curve", 0.0, 0.0, 40.0, 40.0),
        kind: @core.ShapeKind::Adjust,
        adjust: Some({ ..@core.make_adjust(@core.AdjustOp::Curves, 0.0), curve: pts }),
      },
    ],
  }
  let t2 = @core.doc_to_json(two)
  let back = match @core.doc_from_json(t2) {
    Ok(d) => d
    Err(e) => abort("往返读回失败：\{e}")
  }
  assert_eq(@core.doc_to_json(back), t2, msg="canonical 往返必须字节一致")
  match back.layers[0].adjust {
    Some(a) => {
      match a.levels {
        Some(got) => {
          assert_eq(got.in_lo, 0.125, msg="in_lo")
          assert_eq(got.in_hi, 0.875, msg="in_hi")
          assert_eq(got.gamma, 1.25, msg="gamma")
          assert_eq(got.out_lo, 0.0625, msg="out_lo")
          assert_eq(got.out_hi, 0.9375, msg="out_hi")
        }
        None => abort("色阶参数在往返里丢了")
      }
    }
    None => abort("调整字段在往返里丢了")
  }
  match back.layers[1].adjust {
    Some(a) => {
      assert_eq(a.curve.length(), 3, msg="点表条数")
      assert_eq(a.curve[1].0, 0.25, msg="第 2 点的 x")
      assert_eq(a.curve[1].1, 0.125, msg="第 2 点的 y")
    }
    None => abort("调整字段在往返里丢了")
  }
}

///|
test "容器读入端：不认识/不完整的参数**失败得响**，不静默丢掉整块 adjust" {
  // 老引擎读本引擎写的 levels 容器时的现场：算子名认识、参数读不出来。此处用
  // 手改 JSON 模拟三类坏容器——丢掉 adjust 会让"我调过色阶"与画面不一致，
  // 而回包一切正常。
  let doc = @core.new_document("uuid-adj-0003", 40, 40)
  let l = @core.default_layer("l1", "pic", 0.0, 0.0, 40.0, 40.0)
  let lv = mk_levels(0.2, 0.8, 1.2, 0.0, 1.0)
  let base = {
    ..doc,
    layers: [
      {
        ..l,
        kind: @core.ShapeKind::Adjust,
        adjust: Some({ ..@core.make_adjust(@core.AdjustOp::Levels, 0.0), levels: Some(lv) }),
      },
    ],
  }
  let text = @core.doc_to_json(base)
  // 正控：原样的容器读得回来
  assert_true(@core.doc_from_json(text) is Ok(_), msg="正控：合法容器要读得进")
  // ①算子名不认识（别的版本写的）
  let unknown = text.replace_all(old="\"levels\"", new="\"posterize\"")
  assert_true(@core.doc_from_json(unknown) is Err(_), msg="未知算子要拒，不是丢掉")
  // ②色阶参数少一个（整块字段还在）
  let missing = text.replace_all(old="\"gamma\":1.2,", new="")
  assert_true(@core.doc_from_json(missing) is Err(_), msg="参数不完整要拒")
  // ③参数越界（gamma=0）
  let out_of_range = text.replace_all(old="\"gamma\":1.2", new="\"gamma\":0")
  assert_true(@core.doc_from_json(out_of_range) is Err(_), msg="参数越界要拒")
  // ④曲线点表形态不对
  let curve_doc = {
    ..doc,
    layers: [
      {
        ..l,
        kind: @core.ShapeKind::Adjust,
        adjust: Some({
          ..@core.make_adjust(@core.AdjustOp::Curves, 0.0),
          curve: [(0.0, 0.0), (1.0, 1.0)],
        }),
      },
    ],
  }
  let ctext = @core.doc_to_json(curve_doc)
  assert_true(@core.doc_from_json(ctext) is Ok(_), msg="正控：曲线容器要读得进")
  assert_true(
    @core.doc_from_json(ctext.replace_all(old="\"curve\":[[0,0],[1,1]]", new="\"curve\":[[0,0],[1]]")) is Err(_),
    msg="点不是 [x,y] 要拒",
  )
}
