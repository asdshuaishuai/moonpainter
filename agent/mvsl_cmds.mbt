/// agent —— MVSL 编辑表命令面（agent/mvsl_cmds）。
///
/// PLAN-MVSL §4 P1「闭环 affordance」到命令面的落点：
/// - `mvsl-set` / `mvsl-show` / `mvsl-clear`：人机同一 IR 的读写口
///   （GUI 与 AI 走同一编辑表、同一撤销栈）；
/// - `select-preview`：选择子 → overlay PNG + 数值 certificate
///   （覆盖率/bbox/连通域事实），**图与数一并返回**；
/// - `mvsl-impact`：执行前后 diff 证书（改动像素数、目标区 ΔE、
///   选区外泄漏率、变化热力的数值形态）；
/// - `mvsl-assert`：保护断言 ——「别动人物」从自然语言愿望变成
///   机器可验证约束，违反时命令信封直接 fail。
///
/// **求值基准 = 当前文档的渲染结果**。因此 base 由文档指纹隐式内容
/// 寻址；命令信封回传 `base_sha256`，agent 可据此显式 pin 住一轮
/// 交互的底图（底图变了就重新探测，而不是让选区悄悄漂移）。
///
/// 纪律：AI 不当色度计 —— 所有收敛判据都是确定性数值；VLM 只做
/// 「选中的是不是头发」这类语义判断，输入是 overlay 图。

///|
/// 一轮 MVSL 分析的**公共上下文**：同一份 `env`、同一张合成底图。
///
/// 为什么合成一对返回：分析出口（impact/assert/lint/probe）既要用 env 跑真
/// 渲染管线，又要合成底图当基准。若各自算一遍，就会出现"两个命令的 base 不
/// 是同一张图"这种没人会发现的漂移——本仓库的旧账（同一个判断两处实现，先
/// 烂的一定是没人读的那一处）在这里的形态就是"同一个基准两处合成"。
/// 顺带省掉重复的资产解码。
fn mvsl_context(
  s : Session,
) -> Result[(@render.RenderEnv, @codec.RgbaBuf), String] {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return Err(e)
  }
  let env = match session_env(s) {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  Ok((env, @render.render_doc(doc, env)))
}

///|
/// 一轮 MVSL 求值的底图：当前文档的全尺寸渲染。
fn mvsl_base(s : Session) -> Result[@codec.RgbaBuf, String] {
  match mvsl_context(s) {
    Ok(pair) => Ok(pair.1)
    Err(e) => Err(e)
  }
}

///|
/// 编辑表回包（canonical JSON + 指纹 + 版本 pin）。
fn mvsl_reply(op : String, prog : @core.EditProgram, extra : String) -> String {
  let text = @core.program_to_json(prog)
  let hash = @base.sha256_hex(@utf8.encode(text))
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"\{op}\"")
  sb.write_string(",\"ops\":\{prog.ops.length()}")
  sb.write_string(",\"guards\":\{prog.guards.length()}")
  sb.write_string(",\"program_sha256\":\"\{hash}\"")
  sb.write_string(",\"ir\":\{@core.MVSL_IR_VERSION}")
  sb.write_string(",\"render_contract\":\{@core.RENDER_CONTRACT_VERSION}")
  sb.write_string(",\"selector_algo\":\"\{@core.SELECTOR_ALGO_VERSION}\"")
  sb.write_string(",\"color_semantics\":\"\{@core.COLOR_SEMANTICS_VERSION}\"")
  sb.write_string(",\"op_semantics\":\"\{@core.OP_SEMANTICS_VERSION}\"")
  if extra != "" {
    sb.write_string(",")
    sb.write_string(extra)
  }
  sb.write_string(",\"program\":\"\{@core.json_escape(text)}\"}")
  sb.to_string()
}

///|
/// 反解一行编辑表载荷：base64(canonical JSON) → 校验过的编辑表。
///
/// 走 base64 而不是内联 JSON：行协议是空白分隔的，canonical JSON 里的
/// 引号/空格会在分词阶段就被切碎（这类「传输层吃掉语义」的坑不该由
/// 调用方来猜）。
fn mvsl_decode(tok : String) -> Result[@core.EditProgram, String] {
  let raw : Bytes = @base64.decode(tok) catch {
    _ => return Err("编辑表载荷 base64 解码失败")
  }
  let text = match @codec.decode_utf8(raw) {
    Some(t) => t
    None => return Err("编辑表载荷不是合法 UTF-8")
  }
  let prog = match @core.program_from_json(text) {
    Ok(p) => p
    // 回显收到的 JSON：`mvsl-set` 的载荷是**手搓的 base64**（模型/脚本自己拼），
    // 而"编辑表缺 version"这种话不带上原文，调用方根本看不出自己漏了哪个字段
    // ——实测我自己手搓的载荷就漏了 version，看到"缺 version"却在几千字符的
    // base64 里找不到北（同 session-open 那条"报错要回显收到的参数"）。
    Err(e) => {
      let shown = if text.length() > 400 {
        "\{text[0:400].to_owned()}…（共 \{text.length()} 字符）"
      } else {
        text
      }
      return Err("\{e}；收到的载荷：\{shown}")
    }
  }
  match @core.validate_program(prog) {
    Ok(_) => Ok(prog)
    Err(e) => Err(e)
  }
}

///|
/// 图层级算子的入口校验（共享给 mvsl-set 与 lint）。
///
/// 三类静默失败必须在这里拦掉：
///   * `layer=@tag` **落不到任何层** —— 展开后一个算子都不剩，算子在表里、
///     跑得通、什么都不改（判据在 core 里只有一份，render 侧同用）；
///   * 引用了**不存在的层** —— `program_for_layer` 永远匹配不上，同上；
///   * `stage:n` 指向**别的段**或**自己/后面那条** —— 两段式分段执行后段内第 n 条
///     不是表里第 n 条，放行会取到错的中间缓冲（render 侧同一句判据）。
///
/// ⚠️ 最后那条必须在 **`layer=@tag` 展开之后**的表上判：一个标签算子展开成
/// "标签命中几层就几条"，表序会变，而"同段 + 严格在前"正是按表序判的。
/// 展开前说合法、展开后非法（或反过来）就是同一个判断在两张表上各判一次
/// ——`render.impact_stages` 里判据也在展开之后，两处口径必须一致。
fn layer_scope_check(doc : @core.Document, prog : @core.EditProgram) -> String? {
  match @core.tag_scope_error(prog, doc) {
    Some(e) => return Some(e)
    None => ()
  }
  for id in @core.program_layer_ids(prog) {
    // `@tag` 已由上面那条判据负责：这里再看 `find_layer` 只会说出"层不存在：
    // @hero"这种把人往错方向带的话。
    if @core.layer_scope_tag(id) is Some(_) {
      continue
    }
    if @core.find_layer(doc.layers, id) is None {
      let known = StringBuilder()
      let mut n = 0
      for l in doc.layers {
        if n > 0 {
          known.write_string("、")
        }
        known.write_string(l.id)
        n = n + 1
      }
      return Some(
        "算子引用了不存在的图层：\{id}（现有层：\{known.to_string()}）",
      )
    }
  }
  // 判据要在**展开后**的同一张表上跑（理由见本函数文档）：入口与唯一渲染实现
  // 于是判的是同一张表，不会出现"装的进、渲染才拒"。
  @core.layer_scope_error(@core.expand_layer_scopes(prog, doc))
}

///|
/// mvsl-set <base64(canonical json)>：安装编辑表（校验 + 规范化）。
fn cmd_mvsl_set(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：mvsl-set <base64(canonical program json)>")
  }
  // 载荷之后不该再有任何 token（作用域 `layer=` 是写在载荷 JSON 里的，
  // 不是命令行参数）。此前 `mvsl-set <b64> layr=l1` 静默忽略后半句。
  match check_kv_args(tokens, 2, [], "mvsl-set") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let prog = match mvsl_decode(tokens[1]) {
    Ok(p) => p
    Err(e) => return err(e)
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  // 先校验再赋值：坏表不该留在 session 里（否则报错之后状态已被污染）。
  match layer_scope_check(doc, prog) {
    Some(e) => return err(e)
    None => ()
  }
  // 规模护栏（判据在 @core.edit_cost_error，与渲染/lint 共用同一句）。
  // 装表时画布已知，所以这里能挡住绝大多数"太贵"的表；装完之后画布还能被
  // `resize` 改大，那条路由 render 侧的同一句判据兜住。
  let cost = @core.edit_cost_error(prog, doc.width, doc.height)
  if cost != "" {
    return err(cost)
  }
  s.mvsl = prog
  mvsl_reply(
    "mvsl-set",
    prog,
    "\"fingerprint\":\"\{@core.fingerprint(doc)}\"",
  )
}

///|
/// mvsl-show：当前编辑表（canonical 全文 + 指纹 + 版本 pin）。
fn cmd_mvsl_show(s : Session) -> String {
  mvsl_reply("mvsl-show", s.mvsl, "")
}

///|
/// mvsl-clear：清空编辑表（空程序 = 渲染逐位还原 base）。
fn cmd_mvsl_clear(s : Session) -> String {
  s.mvsl = @core.EditProgram::new()
  mvsl_reply("mvsl-clear", s.mvsl, "")
}

///|
/// 连通域事实 → JSON（AI 选 ID，不报坐标——定位是 VLM 最弱项）。
fn component_json(c : @pixel.Component) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":\{c.id}")
  sb.write_string(",\"bbox\":[\{c.x0},\{c.y0},\{c.x1},\{c.y1}]")
  sb.write_string(",\"area\":\{c.area}")
  sb.write_string(",\"centroid\":[\{@core.fmt_num(c.cx)},\{@core.fmt_num(c.cy)}]")
  sb.write_string(",\"mean_l\":\{@core.fmt_num(c.mean_l)}")
  sb.write_string(stats_json(c.stats))
  sb.write_string("}")
  sb.to_string()
}

///|
/// select-preview <base64(selector json)> [max=1024]
///
/// 选择子 → overlay PNG + 数值 certificate。载荷是一条 `SelSpec` 的
/// canonical JSON（用 `{"basis":"base","expr":{...}}` 直接喂；也可以
/// 从某个算子的 sel 里抄出来）。
fn cmd_select_preview(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 2 {
    return err("用法：select-preview <base64(sel json)> [max=<预览最长边>]")
  }
  match check_kv_args(tokens, 2, ["max"], "select-preview") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let raw : Bytes = @base64.decode(tokens[1]) catch {
    _ => return err("选择子载荷 base64 解码失败")
  }
  let text = match @codec.decode_utf8(raw) {
    Some(t) => t
    None => return err("选择子载荷不是合法 UTF-8")
  }
  let spec = match @core.selspec_from_json(text) {
    Ok(x) => x
    Err(e) => return err(e)
  }
  let mut max_side = 1024
  for t in tokens {
    if t.has_prefix("max=") {
      let v = match to_i(t[4:].to_owned()) {
        Some(v) => v
        None => return err("max=\{t[4:].to_owned()} 不是整数")
      }
      if v <= 0 {
        return err("max=\{v} 必须为正（预览最长边像素）")
      }
      max_side = v
    }
  }
  let base = match mvsl_base(s) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let ctx = @pixel.SelCtx::new(base)
  let f = match @pixel.eval_sel(spec, ctx, @pixel.FieldCache::new()) {
    Ok(x) => x
    Err(e) => return err(e)
  }
  let cert = @pixel.certify(base, f)
  let png = @codec.png_encode(@pixel.overlay_buf(base, f, max_side))
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"select-preview\"")
  sb.write_string(",\"source_sha256\":\"\{@base.sha256_hex(@codec.png_encode(base))}\"")
  sb.write_string(",\"base\":[\{base.width},\{base.height}]")
  sb.write_string(",\"coverage\":\{@core.fmt_num(cert.coverage)}")
  sb.write_string(",\"components\":\{cert.components.length()}")
  let (bx0, by0, bx1, by1) = cert.bbox
  sb.write_string(",\"bbox\":[\{bx0},\{by0},\{bx1},\{by1}]")
  sb.write_string(",\"component_facts\":[")
  let mut first = true
  for c in cert.components {
    if first {
      first = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(component_json(c))
  }
  sb.write_string("]")
  sb.write_string(",\"overlay_png_b64\":\"\{@base64.encode(png)}\"}")
  sb.to_string()
}

///|
/// mvsl-impact：以当前文档渲染为 base 执行编辑表 → diff 证书 + 结果 PNG。
///
/// 只回事实，不判好坏：改动像素数、平均/最大 ΔE、目标区 ΔE、选区外
/// 泄漏率。**泄漏率是软边界是否越界的第一号指标**（<1% 是评审给的线）。
fn cmd_mvsl_impact(s : Session, tokens : Array[String]) -> String {
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  match check_kv_args(tokens, 1, ["max"], "mvsl-impact") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let mut max_side = 1024
  for t in tokens {
    if t.has_prefix("max=") {
      let v = match to_i(t[4:].to_owned()) {
        Some(v) => v
        None => return err("max=\{t[4:].to_owned()} 不是整数")
      }
      if v <= 0 {
        return err("max=\{v} 必须为正（预览最长边像素）")
      }
      max_side = v
    }
  }
  let (env, base) = match mvsl_context(s) {
    Ok(pair) => pair
    Err(e) => return err(e)
  }
  let prog = match mvsl_resolved(s, doc) {
    Ok(p) => p
    Err(e) => return err(e)
  }
  // **必须量真渲染那一步**：`layer=` 算子在**该层自己的栅格**上执行、选择子也
  // 在那里求值，文档级算子才在合成底图上。此前这里直接 `run_program(base, prog)`
  // （合成底图上跑整张表，`run_program` 根本不看 `layer`），于是 `layer=l1` 的
  // 表被报成"整幅 512 个像素都改了"（真渲染只改那一层的 256 个），且与文档级
  // 程序给出**同一个哈希**——README 那句"三条出口同一张图"在层作用域下是假的。
  // 现在逐算子阶段、选择子基底、最终图都取自 `@render.impact_stages`，
  // 与 `render` 共用同一段执行代码（构造性一致，不是两处各自小心）。
  let (stages, out) = match @render.impact_stages(doc, env, prog) {
    Ok(r) => r
    Err(e) => return err(e)
  }
  // 逐算子的泄漏率：第一个越界的算子才是要修的那个
  let cache = @pixel.FieldCache::new()
  // 信封里的 `result_sha256` 必须是**回吐那张 PNG** 的 sha——与 `render` 的
  // `render_sha256` 同一份契约（"渲染产物缓存的唯一真值"）。此前它哈希的是
  // **全分辨率** `out`，而 `result_png_b64` 是 `downsample_box(out, max_side)`
  // 之后才编码的：画布 64×64、max=16 时，宿主拿到 16×16 的图，却配着一个
  // 算不到它头上的 sha。**同一个信封里两个字段描述的不是同一张图**，
  // 而拿 sha 当缓存键/对账凭据的宿主会静默错配（比报错难查得多）。
  let preview = @pixel.downsample_box(out, max_side)
  let preview_png = @codec.png_encode(preview)
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"mvsl-impact\"")
  sb.write_string(",\"base_sha256\":\"\{@base.sha256_hex(@codec.png_encode(base))}\"")
  sb.write_string(",\"result_sha256\":\"\{@base.sha256_hex(preview_png)}\"")
  sb.write_string(",\"full_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"")
  sb.write_string(",\"canvas\":[\{base.width},\{base.height}]")
  // `doc_stages` = 能写进 `stage:n` 的阶段数（= 文档级算子数；`layer=` 与
  // `stage:` 的组合在入口就被拒，见 core.layer_scope_error）。`executed` =
  // 真正执行到的算子级阶段数（`layer=@tag` 展开成几层就是几个）。
  sb.write_string(
    ",\"doc_stages\":\{@core.program_doc_scope(prog).ops.length()},\"executed\":\{stages.length()}",
  )
  sb.write_string(",\"per_op\":[")
  let mut first = true
  // 整表支撑集 = 各算子权重场的逐点并集。**不能用零场**：零场里每个像素都在
  // 支撑集之外，total 的 leak_ratio 会退化成 changed/total（语义全错）。
  let mut total_field = @pixel.field_new(base.width, base.height)
  for st in stages {
    // 选择子在**该算子自己的基底**上求值：层算子是层栅格，文档级是合成底图。
    // 拿合成底图去算层算子的权重场，就是"用 A 的选区解释 B 上的改动"。
    let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(st.basis), cache) {
      Ok(w) => w
      Err(e) => return err(e)
    }
    total_field = @pixel.field_union(total_field, wf)
    let rep = @pixel.diff_report(st.before, st.after, wf)
    if first {
      first = false
    } else {
      sb.write_string(",")
    }
    sb.write_string(
      "{\"id\":\"\{@core.json_escape(st.op.id)}\",\"layer\":\"\{@core.json_escape(st.layer)}\",\"changed\":\{rep.changed},\"total\":\{rep.total},\"mean_de\":\{@core.fmt_num(rep.mean_de)},\"max_de\":\{@core.fmt_num(rep.max_de)},\"sel_de\":\{@core.fmt_num(rep.sel_de)},\"leak_ratio\":\{@core.fmt_num(rep.leak_ratio)}}",
    )
  }
  sb.write_string("]")
  let total_rep = @pixel.diff_report(base, out, total_field)
  sb.write_string(",\"changed_total\":\{total_rep.changed}")
  sb.write_string(",\"mean_de_total\":\{@core.fmt_num(total_rep.mean_de)}")
  sb.write_string(",\"result_png_b64\":\"\{@base64.encode(preview_png)}\"")
  sb.write_string(",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}")
  sb.to_string()
}

///|
/// mvsl-assert：保护断言检查。有违反 → 信封 fail（error 里带全部明细）。
///
/// 「别动人物」从自然语言愿望变成机器可验证约束：这里的失败不是警告，
/// 是拒绝——agent 必须回去改编辑表，而不是带着违规结果交付。
fn cmd_mvsl_assert(s : Session) -> String {
  // 展开 `layer=@tag` 需要看容器里谁带标签，所以先取文档（同 impact）。
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let (env, base) = match mvsl_context(s) {
    Ok(pair) => pair
    Err(e) => return err(e)
  }
  let prog = match mvsl_resolved(s, doc) {
    Ok(p) => p
    Err(e) => return err(e)
  }
  // 断言必须在**真渲染的最终图**上判定：`layer=` 算子的效果不在合成底图上，
  // 拿近似图去判"保护区被没被破坏"会得出反向结论——安全网变成假安心
  // （或冤枉一条本来合规的表）。同 impact，取自同一次真管线。
  let (_, out) = match @render.impact_stages(doc, env, prog) {
    Ok(r) => r
    Err(e) => return err(e)
  }
  let fails = match @pixel.check_guards(base, out, prog) {
    Ok(f) => f
    Err(e) => return err(e)
  }
  if fails.length() > 0 {
    let sb = StringBuilder()
    sb.write_string("断言未通过（\{fails.length()} 条）：")
    let mut i = 0
    while i < fails.length() {
      if i > 0 {
        sb.write_string("；")
      }
      sb.write_string(fails[i])
      i = i + 1
    }
    return err(sb.to_string())
  }
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"mvsl-assert\"")
  sb.write_string(",\"guards\":\{s.mvsl.guards.length()}")
  sb.write_string(",\"violations\":0")
  // 这条命令**不回吐 PNG**（只有断言结论），所以两个 sha 描述的是全分辨率
  // 缓冲，名字里写明 `full`，免得宿主以为能拿去对某张图。回吐 PNG 的
  // `mvsl-impact` 才用 `result_sha256`（= 那张 PNG 的 sha）。
  sb.write_string(",\"base_sha256\":\"\{@base.sha256_hex(@codec.png_encode(base))}\"")
  sb.write_string(",\"result_full_sha256\":\"\{@base.sha256_hex(@codec.png_encode(out))}\"}")
  sb.to_string()
}
