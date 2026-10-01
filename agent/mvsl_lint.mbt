/// agent —— 编辑表 lint（agent/mvsl_lint）。
///
/// **为什么必须有**：编辑表有一整类"自我否定"的状态，而这些状态**每个命令
/// 都返回 ok**——`mvsl-set` 成功、`mvsl-impact` 成功、`mvsl-assert` 0 违规、
/// `render` 成功，只有 `changed_total=0` 这一个数字在暗示出了事，而它需要
/// 调用方先知道"0 意味着我的编辑什么都没做"。
///
/// 具体状态：
///   1. 装了非空编辑表，但整张图逐位未变（选择子一个像素都没命中）；
///   2. 某一条算子的选择子没命中任何像素（其余算子正常）；
///   3. 构造性空算子（recolor 转 0 度 / temperature 0K / relight 增益 1 /
///      amount 为 0）——与画布无关，必然无改动；
///   4. 保护断言被违反（用户的「别动 XX」被破坏）；
///   5. 编辑表执行失败（静态校验过得了，但求值时才失败，例如 mask 资产未登记）。
///
/// `lint` 是"收工前检查"的那个命令——它不查，就没人查。

///|
/// 构造性空算子（与画布无关的一眼可判项）。返回空串表示不是空算子。
fn null_op_reason(op : @core.EditOp) -> String {
  if op.amount <= 0.0 {
    return "amount 为 \{@core.fmt_num(op.amount)}——总强度为 0，该算子不产生任何改动"
  }
  match op.kind {
    @core.Recolor =>
      if op.hue_deg == 0.0 {
        "是 recolor 但 hue_deg=0——色相旋转 0 度，构造上无改动"
      } else {
        ""
      }
    @core.Temperature =>
      if op.temp_kelvin == 0.0 {
        "是 temperature 但 temp_kelvin=0——色温平移 0K，构造上无改动"
      } else {
        ""
      }
    @core.Relight =>
      if op.relight_gain == 1.0 {
        "是 relight 但 relight_gain=1——增益 1 倍，构造上无改动"
      } else {
        ""
      }
  }
}

///|
/// 编辑表 lint。
///
/// 空编辑表是**合法状态**（= 未编辑），不报任何条目——lint 不该对"我还没改
/// 任何东西"这件事报警。
///
/// **判据必须量真渲染那一步**：`layer=` 算子在**该层自己的栅格**上执行、选择子
/// 也在那里求值，文档级算子才在合成底图上。此前这里拿 `run_program(合成底图, 整表)`
/// 当执行结果，于是"某条算子白装"和"保护断言被违反"都在**错的图**上判定——
/// 前者会误报/漏报，后者是安全网失效（假安心比报错坏得多）。
/// 现在执行与逐算子阶段都取自 `@render.impact_stages`，与 `render` 同一段代码。
pub fn lint_mvsl(
  doc : @core.Document,
  env : @render.RenderEnv,
  base : @codec.RgbaBuf,
  prog : @core.EditProgram,
) -> Array[String] {
  let v : Array[String] = []
  if prog.ops.length() == 0 {
    return v
  }
  // ── 静态：图层级算子的硬约束（不依赖画布）──
  //
  // `layer=` 与 `STAGE` 基准组合会被两段式渲染拒绝，但那张表**能装进 session**
  // 只要走的是不经过校验的路径（手改容器、旧版本产物）。lint 的价值就在这：
  // 引擎知道自己没干活时得有人告诉调用方。
  match @core.layer_scope_error(prog) {
    Some(msg) => v.push("P4 \{msg}")
    None => ()
  }
  // ── 静态：构造性空算子（不依赖画布）──
  let statically_null : Map[String, Bool] = Map([])
  for op in prog.ops {
    let why = null_op_reason(op)
    if why != "" {
      statically_null.set(op.id, true)
      v.push("P1 mvsl 算子 \{op.id} \{why}")
    }
  }
  // ── 动态：执行（真管线）+ 逐算子命中 + 断言 ──
  // `base` 由调用方经 `mvsl_context` 给出：全仓库只有一处合成底图，
  // 别在这里再渲染一遍（那会造出第二个基准，而两个基准必然有一天不一致）。
  let (stages, out) = match @render.impact_stages(doc, env, prog) {
    Ok(r) => r
    Err(e) => {
      v.push("P0 mvsl 编辑表执行失败：\{e}（表已装上，渲染会直接报错——必须修掉）")
      return v
    }
  }
  let cache = @pixel.FieldCache::new()
  let zero = @pixel.field_new(base.width, base.height)
  let total_rep = @pixel.diff_report(base, out, zero)
  // 逐算子（在各自基底上）的真实改动总量：用来把"改了但看不见"与"什么都没命中"
  // 分开归因。层栅格与合成底图同为画布尺寸，所以同一个零场够用。
  let mut stage_changed = 0
  for st in stages {
    let rep = @pixel.diff_report(st.before, st.after, zero)
    stage_changed = stage_changed + rep.changed
  }
  // 整表空操作：最响的一条。逐算子再报一遍就只是噪音了。
  if total_rep.changed == 0 {
    // 归因要准：全是构造性空算子时，怪选择子是误导（它其实命中了，
    // 是算子本身不产生改动）。
    let all_null = statically_null.length() == prog.ops.length()
    if all_null {
      v.push(
        "P0 mvsl 编辑表装了 \{prog.ops.length()} 条算子，但每一条都是构造性空操作——整张图逐位未变。检查 hue_deg / temp_kelvin / relight_gain / amount 是否给了「不变」的值",
      )
    } else if stage_changed > 0 {
      // 改了，但改的是**层栅格**，最终图里看不见（该层被隐藏 / 被上层完全遮住 /
      // 被组 opacity=0 吃掉）。归因说准：这不是"选择子没命中"——它命中了，
      // 是这次编辑对外不可见。这两种情况的修法完全不同（改选择子 vs 改层）。
      v.push(
        "P0 mvsl 编辑表装了 \{prog.ops.length()} 条算子：算子确实改动了图层栅格（\{stage_changed} 个像素），但**最终图逐位未变**——改动落在看不见的层上（层被隐藏 / 被上层完全遮住 / 组 opacity=0）。先 query-layer 确认层可见性与层序",
      )
    } else {
      v.push(
        "P0 mvsl 编辑表装了 \{prog.ops.length()} 条算子，但整张图逐位未变（0 个像素改动）——选择子一个像素都没命中。用 census/probe 取 sel_h/sel_c/sel_l 重取颜色，或 select-preview 先确认选区再装表",
      )
    }
  } else {
    // 有事发生，但可能有个别算子白装——指出是哪一条
    for st in stages {
      let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(st.basis), cache) {
        Ok(w) => w
        Err(e) => return { v.push("P0 mvsl 算子 \{st.op.id} 求值失败：\{e}"); v }
      }
      let rep = @pixel.diff_report(st.before, st.after, wf)
      // 已经因静态原因报过的，不再重复
      let dup = match statically_null.get(st.op.id) {
        Some(_) => true
        None => false
      }
      if rep.changed == 0 && !dup {
        let scope_note = if st.layer == "" {
          ""
        } else {
          "（层 \{st.layer}）"
        }
        v.push(
          "P1 mvsl 算子 \{st.op.id}\{scope_note} 未改动任何像素（选择子没命中）——先 select-preview 确认它选中的是你要改的东西",
        )
      }
    }
  }
  // 保护断言：用户的「别动 XX」被破坏时必须响
  match @pixel.check_guards(base, out, prog) {
    Ok(fails) => for f in fails {
      v.push("P0 mvsl 保护断言被违反：\{f}")
    }
    Err(e) => v.push("P0 mvsl 保护断言无法求值：\{e}")
  }
  // 空断言：选择子一个像素都没命中 → 断言恒真，永远不会失败。
  // 这比"断言被违反"更坏：它给出的是**虚假的安心**——用户以为"别动背景"
  // 被机器守着，实际上什么都没守。
  for g in prog.guards {
    let f = match @pixel.eval_sel(g.sel, @pixel.SelCtx::new(base), cache) {
      Ok(f) => f
      Err(_) => continue
    }
    let cert = @pixel.certify(base, f)
    if cert.coverage <= 0.0 {
      v.push(
        "P1 mvsl 保护断言 \{g.id} 的选择子一个像素都没命中——它是空断言，永远不会失败。用户以为这条约束被守着，实际上什么都没守；请用 probe/census 重新取数",
      )
    }
  }
  v
}
