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
  let within = match parse_within(tokens) {
    Ok(x) => x
    Err(e) => return err(e)
  }
  let mut max_comp = 16
  for t in tokens {
    if t.has_prefix("components=") {
      match to_i(t[11:].to_owned()) {
        Some(v) => if v > 0 {
          max_comp = v
        }
        None => return err("components=\{t[11:].to_owned()} 不是整数")
      }
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
  let m = match kv_args(tokens, 1).get("x") {
    Some(v) => v
    None => return err("用法：probe x=<像素坐标> y=<像素坐标> [r=2]")
  }
  let yv = match kv_args(tokens, 1).get("y") {
    Some(v) => v
    None => return err("用法：probe x=<像素坐标> y=<像素坐标> [r=2]")
  }
  let x = match to_i(m) {
    Some(v) => v
    None => return err("x=\{m} 不是整数")
  }
  let y = match to_i(yv) {
    Some(v) => v
    None => return err("y=\{yv} 不是整数")
  }
  let mut r = 2
  match kv_args(tokens, 1).get("r") {
    Some(v) => match to_i(v) {
      Some(n) => r = n
      None => return err("r=\{v} 不是整数")
    }
    None => ()
  }
  let base = match mvsl_base(s) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let pr = match @pixel.probe(base, x, y, r) {
    Ok(p) => p
    Err(e) => return err(e)
  }
  let sb = StringBuilder()
  sb.write_string("{\"ok\":true,\"op\":\"probe\"")
  sb.write_string(",\"x\":\{pr.x},\"y\":\{pr.y},\"r\":\{pr.r}")
  sb.write_string(",\"color\":\"\{@codec.color_to_hex(pr.color)}\"")
  sb.write_string(",\"mean_l\":\{@core.fmt_num(pr.mean_l)}")
  sb.write_string(",\"var_l\":\{@core.fmt_num(pr.var_l)}")
  sb.write_string(",\"mean_a\":\{@core.fmt_num(pr.mean_a)}")
  sb.write_string(",\"mean_b\":\{@core.fmt_num(pr.mean_b)}")
  sb.write_string(stats_json(pr.stats))
  sb.write_string(",\"edge\":\{@core.fmt_num(pr.edge)}")
  sb.write_string(",\"edge_conf\":\{@core.fmt_num(pr.edge_conf)}")
  // 逐算子的选择子归属（同色异义干扰在这里暴露：membership 高但成分不同）
  sb.write_string(",\"ops\":[")
  let ctx = @pixel.SelCtx::new(base)
  let mut first = true
  for op in s.mvsl.ops {
    let wf = match @pixel.op_weight(op, ctx, @pixel.FieldCache::new()) {
      Ok(w) => w
      Err(e) => return err(e)
    }
    let labels = @pixel.label_components(base, wf)
    let cid = @pixel.component_id_at(labels, x, y)
    if first {
      first = false
    } else {
      sb.write_string(",")
    }
    sb.write_string("{\"id\":\"\{@core.json_escape(op.id)}\"")
    sb.write_string(",\"membership\":\{@core.fmt_num(@pixel.field_get(wf, x, y))}")
    sb.write_string(",\"component\":\{cid}}")
  }
  sb.write_string("]")
  // 当前编辑表的保护断言在这一点上是否覆盖（「这里能不能动」的即答）
  sb.write_string(",\"guards\":[")
  let mut gfirst = true
  for g in s.mvsl.guards {
    let wf = match @pixel.eval_sel(g.sel, ctx, @pixel.FieldCache::new()) {
      Ok(w) => w
      Err(e) => return err(e)
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
  sb.to_string()
}
