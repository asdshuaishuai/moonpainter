/// agent —— census / probe affordance 命令（agent/affordance_cmds）。
///
/// PLAN-MVSL §2.2/§2.3 的命令面落点。两个命令解决的是同一个结构性问题：
/// **区域级事实有循环依赖**——AI 得先知道「画面里有什么」才能提选择子，
/// 而「知道画面里有什么」恰恰是 VLM 最弱的一环。所以引擎把区域事实直接
/// 算成数值：
///
/// - `census`：hue×sat 桶普查（12×3），可选 `within=` 收窄到某条选择子，
///   同时给出该区域的覆盖率/bbox/连通域事实；
/// - `probe`：单点 5×5 邻域统计（OKLab 均值与方差、环平均色相、边缘
///   置信度），外加**当前编辑表里每个算子的选择子在这个点的 membership
///   与所属连通域 id**——AI 于是能问「我说的那个点，引擎到底选中了什么」。
///
/// 纪律：只回事实，不回判断。VLM 负责语义（「这是头发吗」），
/// 引擎负责数值（「这个点 membership=0.87，属于第 3 个连通域」）。

///|
/// `ColorStats` → JSON 片段：**两套颜色坐标系并列摆出**。
///
/// `sel_*` 是直接喂 `color` 选择子的三个值（选择子的 h/s/l 用的是 OKLCh
/// 色相 / OKLCh 彩度 / OKLab 亮度）；`hsv_*` 只是对照。并列而不是二选一，
/// 是要让调用方**亲眼看到**两者不是一回事（纯红 sel_h≈29 而 hsv_h=0，
/// 彩度 0.18 而 HSV 饱和度 0.85）——否则它会在两个都叫"色相/饱和度"的
/// 字段之间猜，而猜错的表现是"命令成功但一个像素都没选中"。
///
/// census / probe / 连通域事实三处共用这一个实现，保证同一片像素在三处
/// 报出的数字逐位一致。
fn stats_json(st : @pixel.ColorStats) -> String {
  let sb = StringBuilder()
  sb.write_string(",\"sel_h\":\{@core.fmt_num(st.sel_h)}")
  sb.write_string(",\"sel_c\":\{@core.fmt_num(st.sel_c)}")
  sb.write_string(",\"sel_l\":\{@core.fmt_num(st.sel_l)}")
  sb.write_string(",\"hsv_h\":\{@core.fmt_num(st.hsv_h)}")
  sb.write_string(",\"hsv_s\":\{@core.fmt_num(st.hsv_s)}")
  sb.write_string(",\"hsv_v\":\{@core.fmt_num(st.hsv_v)}")
  sb.to_string()
}

///|
/// 解析 `within=<base64 sel>` 参数（可选）。返回 None 表示未指定。
fn parse_within(tokens : Array[String]) -> Result[Option[@core.SelSpec], String] {
  let mut raw : Option[String] = None
  for t in tokens {
    if t.has_prefix("within=") {
      raw = Some(t[7:].to_owned())
    }
  }
  match raw {
    None => Ok(None)
    Some(tok) => {
      let bytes : Bytes = @base64.decode(tok) catch {
        _ => return Err("within 载荷 base64 解码失败")
      }
      let text = match @codec.decode_utf8(bytes) {
        Some(x) => x
        None => return Err("within 载荷不是合法 UTF-8")
      }
      let spec = match @core.selspec_from_json(text) {
        Ok(x) => x
        Err(e) => return Err(e)
      }
      Ok(Some(spec))
    }
  }
}

///|
/// census [within=<base64 sel>] [components=<n>]
///
/// 无 within：全图 hue×sat 普查 + OKLab L / HSV 均值对照。
/// 有 within：额外给出该区域的覆盖率 / bbox / 连通域事实（前 n 个）。
fn cmd_census(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, ["within", "components"], "census") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let within = match parse_within(tokens) {
    Ok(x) => x
    Err(e) => return err(e)
  }
  let mut max_comp = 16
  for t in tokens {
    if t.has_prefix("components=") {
      // `components=0` 此前被**静默忽略**（保留默认 16）——"我要 0 个
      // 连通域"不是个能办到的请求，静默换成 16 就是另一种意思了。
      let v = match to_i(t[11:].to_owned()) {
        Some(v) => v
        None => return err("components=\{t[11:].to_owned()} 不是整数")
      }
      if v <= 0 {
        return err("components=\{v} 必须为正（连通域个数的上限）")
      }
      max_comp = v
    }
  }
  let base = match mvsl_base(s) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let mut field : Option[@pixel.Field] = None
  match within {
    Some(spec) => {
      let ctx = @pixel.SelCtx::new(base)
      let f = match @pixel.eval_sel(spec, ctx, @pixel.FieldCache::new()) {
        Ok(x) => x
        Err(e) => return err(e)
      }
      field = Some(f)
    }
    None => ()
  }
  let cen = @pixel.census(base, field)
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"census\"")
  sb.write_string(",\"canvas\":[\{base.width},\{base.height}]")
  sb.write_string(",\"total\":\{cen.total}")
  sb.write_string(",\"counted\":\{cen.counted}")
  sb.write_string(",\"hue_bins\":[")
  let mut i = 0
  while i < cen.hue_bins.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("\{cen.hue_bins[i]}")
    i = i + 1
  }
  sb.write_string("]")
  sb.write_string(",\"sat_bins\":[")
  i = 0
  while i < cen.sat_bins.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("\{cen.sat_bins[i]}")
    i = i + 1
  }
  sb.write_string("]")
  sb.write_string(",\"hsl_bins\":[")
  i = 0
  while i < cen.hsl_bins.length() {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("\{cen.hsl_bins[i]}")
    i = i + 1
  }
  sb.write_string("]")
  sb.write_string(",\"dominant_bin\":\{cen.dominant_bin}")
  // 桶直方图是 HSV 的（粗粒度可视辅助）；精确均值按选择子坐标给出。
  sb.write_string(
    ",\"bin_space\":\"hue_bins/sat_bins/hsl_bins 是 HSV 粗粒度桶（可视辅助）；要喂选择子请用下面的 sel_h/sel_c/sel_l\"",
  )
  sb.write_string(stats_json(cen.stats))
  match field {
    Some(f) => {
      let cert = @pixel.certify(base, f)
      let (bx0, by0, bx1, by1) = cert.bbox
      sb.write_string(",\"coverage\":\{@core.fmt_num(cert.coverage)}")
      sb.write_string(",\"components\":\{cert.components.length()}")
      sb.write_string(",\"bbox\":[\{bx0},\{by0},\{bx1},\{by1}]")
      sb.write_string(",\"component_facts\":[")
      let mut k = 0
      while k < cert.components.length() && k < max_comp {
        if k > 0 {
          sb.write_string(",")
        }
        sb.write_string(component_json(cert.components[k]))
        k = k + 1
      }
      sb.write_string("]")
    }
    None => ()
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// probe x= y= [r=2]
///
/// 单点事实 + 逐算子的选择子归属。返回的 `ops[]` 是**当前编辑表**里每个
/// 算子在这一点上的 membership 与所属连通域 id —— 「我指的这个点，
/// 你的选择子到底选中没有、属于哪一块」，比让模型看 mask 猜要可靠得多。
fn cmd_probe(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, ["x", "y", "r", "points"], "probe") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let kv = kv_args(tokens, 1)
  let mut r = 2
  match kv.get("r") {
    Some(v) =>
      match to_i(v) {
        Some(n) => r = n
        None => return err("r=\{v} 不是整数")
      }
    None => ()
  }
  let (env, base) = match mvsl_context(s) {
    Ok(pair) => pair
    Err(e) => return err(e)
  }
  // 逐算子 membership 的基底：真渲染管线一次算好，所有点共用（见 probe_one_json）。
  // 表坏了（如落空的 `@tag`）不阻断颜色/边缘诊断，但原因必须报出来。
  let stages : Array[@render.ImpactStage] = []
  let mut ops_error = ""
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  match mvsl_resolved(s, doc) {
    Ok(prog) =>
      match @render.impact_stages(doc, env, prog) {
        Ok(pair) => {
          let mut i = 0
          while i < pair.0.length() {
            stages.push(pair.0[i])
            i = i + 1
          }
        }
        Err(e) => ops_error = e
      }
    Err(e) => ops_error = e
  }
  // ── 批量模式：points=x1,y1;x2,y2;... ──
  // 单点模式一次往返只能问一个位置，模型探一圈（比如 9 宫格）要 9 次调用。
  // 每个点的字段与单点模式**逐字段一致**（同一个 probe_one_json），所以调用方
  // 的解析不用分叉。
  match kv.get("points") {
    Some(spec) => {
      let pts = match parse_probe_points(spec) {
        Ok(p) => p
        Err(e) => return err(e)
      }
      let sb = StringBuilder()
      sb.write_string("{\"ok\":true,\"op\":\"probe\",\"count\":\{pts.length()}")
      sb.write_string(",\"r\":\{r},\"points\":[")
      let mut first = true
      for pt in pts {
        let one = match probe_one_json(s, base, stages, ops_error, pt.0, pt.1, r, false) {
          Ok(j) => j
          Err(e) => return err(e)
        }
        if first {
          first = false
        } else {
          sb.write_string(",")
        }
        sb.write_string(one)
      }
      sb.write_string("]}")
      return sb.to_string()
    }
    None => ()
  }
  // ── 单点模式（输出与加入批量入口之前逐位相同）──
  let m = match kv.get("x") {
    Some(v) => v
    None => return err("用法：probe x=<像素坐标> y=<像素坐标> [r=2]，或 points=x1,y1;x2,y2;...")
  }
  let yv = match kv.get("y") {
    Some(v) => v
    None => return err("用法：probe x=<像素坐标> y=<像素坐标> [r=2]，或 points=x1,y1;x2,y2;...")
  }
  let x = match to_i(m) {
    Some(v) => v
    None => return err("x=\{m} 不是整数")
  }
  let y = match to_i(yv) {
    Some(v) => v
    None => return err("y=\{yv} 不是整数")
  }
  let one = match probe_one_json(s, base, stages, ops_error, x, y, r, true) {
    Ok(j) => j
    Err(e) => return err(e)
  }
  one
}

///|
/// 解析 `points=x1,y1;x2,y2;...`：分号分组、逗号分坐标，坐标是**整数像素**。
///
/// 为什么不复用 `ops.mbt` 的 `parse_points`（同名同格式）：那个是**多边形顶点**
/// 解析——返回 `Double`、要求 ≥2 个（一个顶点不成形）、错误文案说的是"顶点"。
/// 探针这里要的是整数像素（`1.5` 该被拒绝，而不是悄悄取整）、单点也该合法、
/// 错误要说清是探针坐标。把两种约束塞进一个函数，只能让两边互相妥协。
/// 注：这里**不需要**检查 `spec` 为空——`kv_args` 只收「键=非空值」的 token
/// （`points=` 这种空值会被整个丢弃，于是根本进不到批量分支，而是落到单点
/// 模式的用法提示）。空段仍可能出现（`points=;`），由下面的 `out.length()==0`
/// 兜住。
fn parse_probe_points(spec : String) -> Result[Array[(Int, Int)], String] {
  let out : Array[(Int, Int)] = []
  for seg in spec.split(";") {
    if seg.length() > 0 {
      let parts : Array[String] = []
      for p in seg.split(",") {
        parts.push(p.to_owned())
      }
      if parts.length() != 2 {
        return Err("points 每段应为 x,y：got \{seg}")
      }
      let px = match to_i(parts[0]) {
        Some(v) => v
        None => return Err("points 里的 x=\{parts[0]} 不是整数")
      }
      let py = match to_i(parts[1]) {
        Some(v) => v
        None => return Err("points 里的 y=\{parts[1]} 不是整数")
      }
      out.push((px, py))
    }
  }
  if out.length() == 0 {
    return Err("points= 没解析出任何点")
  }
  if out.length() > 64 {
    return Err("points 一次最多 64 个点（got \{out.length()}）；全图统计请用 census")
  }
  Ok(out)
}

///|
/// 单点探针的 JSON——单点与批量两种入口共用同一段字段拼装，保证两条路
/// 报出的字段永远不会走样。`envelope=true` 时前面带 `"ok":true,"op":"probe",`
/// （单点模式的输出因此与加入批量入口之前**逐位相同**）。
fn probe_one_json(
  s : Session,
  base : @codec.RgbaBuf,
  stages : Array[@render.ImpactStage],
  ops_error : String,
  x : Int,
  y : Int,
  r : Int,
  envelope : Bool,
) -> Result[String, String] {
  let pr = match @pixel.probe(base, x, y, r) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let sb = StringBuilder()
  if envelope {
    sb.write_string("{\"ok\":true,\"op\":\"probe\",")
  } else {
    sb.write_string("{")
  }
  sb.write_string("\"x\":\{pr.x},\"y\":\{pr.y},\"r\":\{pr.r}")
  sb.write_string(",\"color\":\"\{@codec.color_to_hex(pr.color)}\"")
  sb.write_string(",\"mean_l\":\{@core.fmt_num(pr.mean_l)}")
  sb.write_string(",\"var_l\":\{@core.fmt_num(pr.var_l)}")
  sb.write_string(",\"mean_a\":\{@core.fmt_num(pr.mean_a)}")
  sb.write_string(",\"mean_b\":\{@core.fmt_num(pr.mean_b)}")
  sb.write_string(stats_json(pr.stats))
  sb.write_string(",\"edge\":\{@core.fmt_num(pr.edge)}")
  sb.write_string(",\"edge_conf\":\{@core.fmt_num(pr.edge_conf)}")
  // 逐算子的选择子归属（同色异义干扰在这里暴露：membership 高但成分不同）。
  //
  // **在该算子自己的基底上求值**：`layer=` 算子在层栅格上执行、选择子也在那里
  // 求值，文档级算子才在合成底图上。此前这里一律用合成底图，于是层算子的
  // membership/连通域报的是"另一张图上的数"——调用方照它调参，渲染器却在
  // 别处求值。基底由 `@render.impact_stages` 一次算好传进来（不在每个点里
  // 重跑整条管线：64 点 × 全图渲染是不可接受的）。
  let ctx = @pixel.SelCtx::new(base)
  sb.write_string(",\"ops\":[")
  let mut first = true
  let mut k = 0
  while k < stages.length() {
    let st = stages[k]
    let wf = match @pixel.op_weight(st.op, @pixel.SelCtx::new(st.basis), @pixel.FieldCache::new()) {
      Ok(w) => w
      Err(e) => return Err(e)
    }
    let labels = @pixel.label_components(st.basis, wf)
    let cid = @pixel.component_id_at(labels, x, y)
    if first {
      first = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"id\":\"\{@core.json_escape(st.op.id)}\"")
    sb.write_string(",\"layer\":\"\{@core.json_escape(st.layer)}\"")
    sb.write_string(",\"membership\":\{@core.fmt_num(@pixel.field_get(wf, x, y))}")
    sb.write_string(",\"component\":\{cid}}")
    k = k + 1
  }
  sb.write_string("]")
  // 表跑不起来时**不许静默少一段**：逐算子归属报不出来，就把原因报出来
  // （点上的颜色/边缘统计与编辑表无关，照旧可用——probe 是诊断工具，
  // 坏表时期正是最需要它的时候）。
  if ops_error != "" {
    sb.write_string(",\"ops_error\":\"\{@core.json_escape(ops_error)}\"")
  }
  // 当前编辑表的保护断言在这一点上是否覆盖（「这里能不能动」的即答）
  sb.write_string(",\"guards\":[")
  let mut gfirst = true
  for g in s.mvsl.guards {
    let wf = match @pixel.eval_sel(g.sel, ctx, @pixel.FieldCache::new()) {
      Ok(w) => w
      Err(e) => return Err(e)
    }
    if gfirst {
      gfirst = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"id\":\"\{@core.json_escape(g.id)}\"")
    sb.write_string(",\"membership\":\{@core.fmt_num(@pixel.field_get(wf, x, y))}}")
  }
  sb.write_string("]}")
  Ok(sb.to_string())
}
