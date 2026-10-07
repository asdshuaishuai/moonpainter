/// 图层样式（fx）命令面：`set-fx`。
///
/// 语义（产品决定，见 PLAN「②A 图层样式」）：
///   * **样式属于这一层自己的像素**：先把这一层栅格化到它自己的透明缓冲，
///     在"这一层的覆盖度"上算四件套，最后整块按 `blend`/`opacity` 合成一次；
///   * 四件套：**投影**（`shadow`）→ **外发光**（`glow`）→ 层自己 →
///     **内阴影**（`inner`）→ **描边**（`outline`），顺序写在 `render.apply_fx`；
///   * 半径/宽度上限 `@core.FX_MAX_RADIUS`（64px），超过的部分渲染器按上限算
///     ——入口拒绝并说清"不会更大、只是更慢"；
///   * 调整层**没有自己的像素**（它的画面是它下面那张底图）⇒ 入口拒、lint 兜。

///|
/// `set-fx` 认的全部键（**唯一键清单**：解析器 allow-list + 字典用法串都从它出）。
///
/// ⚠️ 字面量（不是拼出来的）：`param_audit.py` 从 `check_kv_args` 的第三个实参 /
/// `*_keys()` 的函数体里读键表，读不出字面量就判失败（静默跳过 = 这门禁有洞）。
/// 键序即"四件套 + 每件自己的参数"的文档顺序。
pub fn fx_keys() -> Array[String] {
  [
    "clear",
    "shadow",
    "shadow_dx",
    "shadow_dy",
    "shadow_blur",
    "shadow_color",
    "outline",
    "outline_w",
    "outline_color",
    "glow",
    "glow_radius",
    "glow_color",
    "inner",
    "inner_dx",
    "inner_dy",
    "inner_blur",
    "inner_color",
  ]
}

///|
/// 字典里的用法串（从键清单生成，顺序即清单顺序）。**单位写在这里**（铁律 8）：
/// 偏移/半径/宽度都是**像素**（相对这一层自己的盒子），偏移可以是负的。
pub fn fx_key_doc() -> String {
  let mut s = ""
  for k in fx_keys() {
    let part = match k {
      "clear" => " [clear=1]"
      "shadow" => " [shadow=true]"
      "shadow_dx" => " [shadow_dx=<px，可负，默认 4>]"
      "shadow_dy" => " [shadow_dy=<px，可负，默认 4>]"
      "shadow_blur" => " [shadow_blur=<px 0..64，默认 4>]"
      "shadow_color" => " [shadow_color=#RRGGBB|#RRGGBBAA，默认 #00000080]"
      "outline" => " [outline=true]"
      "outline_w" => " [outline_w=<px 0..64，默认 3>]"
      "outline_color" => " [outline_color=#RRGGBB|#RRGGBBAA，默认 #000000FF]"
      "glow" => " [glow=true]"
      "glow_radius" => " [glow_radius=<px 0..64，默认 6>]"
      "glow_color" => " [glow_color=#RRGGBB|#RRGGBBAA，默认 #FFD70080]"
      "inner" => " [inner=true]"
      "inner_dx" => " [inner_dx=<px，可负，默认 2>]"
      "inner_dy" => " [inner_dy=<px，可负，默认 2>]"
      "inner_blur" => " [inner_blur=<px 0..64，默认 4>]"
      "inner_color" => " [inner_color=#RRGGBB|#RRGGBBAA，默认 #00000080]"
      _ => " [" + k + "=]"
    }
    s = s + part
  }
  s
}

///|
/// 四件套的**一行一件**表：开关键名、读取开关、以及"这一件画不画得出像素"。
///
/// 存在的理由（铁律 6 那条"别再加手写 if"）：lint 要逐件说清"哪个开关开着却
/// 画不出东西"，而"画不画得出"的判据在 core 一处（`fx_*_on`，与渲染器跳过
/// 它的是**同一句**）。表里再抄一遍判据就是第二处实现。
pub fn fx_effects() -> Array[(String, String, (@core.LayerFx) -> Bool, (@core.LayerFx) -> Bool, (@core.LayerFx) -> String)] {
  [
    (
      "shadow",
      "投影",
      fn(f) { f.shadow },
      @core.fx_shadow_on,
      fn(f) {
        if ((f.shadow_color >> 24) & 0xFF) == 0 {
          "颜色是全透明的"
        } else {
          "既不模糊也不偏移（blur<1 且 dx=dy=0）"
        }
      },
    ),
    (
      "outline",
      "描边",
      fn(f) { f.outline },
      @core.fx_outline_on,
      fn(f) {
        if ((f.outline_color >> 24) & 0xFF) == 0 {
          "颜色是全透明的"
        } else {
          "宽度 <1 像素（outline_w 取整后为 0）"
        }
      },
    ),
    (
      "glow",
      "外发光",
      fn(f) { f.glow },
      @core.fx_glow_on,
      fn(f) {
        if ((f.glow_color >> 24) & 0xFF) == 0 {
          "颜色是全透明的"
        } else {
          "半径 <1 像素（取整后为 0）"
        }
      },
    ),
    (
      "inner",
      "内阴影",
      fn(f) { f.inner },
      @core.fx_inner_on,
      fn(f) {
        if ((f.inner_color >> 24) & 0xFF) == 0 {
          "颜色是全透明的"
        } else {
          "既不模糊也不偏移（blur<1 且 dx=dy=0）"
        }
      },
    ),
  ]
}

///|
/// 图层样式的**回读**（`query-layer` 的 `fx` 字段）。
///
/// 只报**开着的**那几件（`fx=none` = 压根没有样式；`fx=all-off` = 挂着一份
/// 但四个开关全关，画面逐位不变）。这就是"能打上的名字必须能摘下、能报出来"：
/// 参数名与**数值**都在（`contains("shadow(")` 那种只报名字的断言会被满足而
/// 其实没在守护）。
pub fn fx_report(fx : @core.LayerFx?) -> String {
  let f = match fx {
    None => return "none"
    Some(f) => f
  }
  let parts : Array[String] = []
  if f.shadow {
    parts.push(
      "shadow(\{@core.fmt_num(f.shadow_dx)},\{@core.fmt_num(f.shadow_dy)},\{@core.fmt_num(f.shadow_blur)},\{@codec.color_to_hex(f.shadow_color)})",
    )
  }
  if f.outline {
    parts.push(
      "outline(\{@core.fmt_num(f.outline_w)},\{@codec.color_to_hex(f.outline_color)})",
    )
  }
  if f.glow {
    parts.push(
      "glow(\{@core.fmt_num(f.glow_radius)},\{@codec.color_to_hex(f.glow_color)})",
    )
  }
  if f.inner {
    parts.push(
      "inner(\{@core.fmt_num(f.inner_dx)},\{@core.fmt_num(f.inner_dy)},\{@core.fmt_num(f.inner_blur)},\{@codec.color_to_hex(f.inner_color)})",
    )
  }
  if parts.length() == 0 {
    "all-off"
  } else {
    parts.join(",")
  }
}

///|
/// 布尔参数的读取器（`1/0/true/false`）——**参数化**的那一份：
/// `mask_arg_bool` 与 `set-fx` 的四个开关共用它（同一个判断写两遍就必然有一处
/// 先烂）。错误提示带上**上下文**（"蒙版 invert" / "图层样式的 shadow"）。
fn kv_bool_arg(
  m : Map[String, String],
  key : String,
  cur : Bool,
  ctx : String,
) -> Result[Bool, String] {
  match m.get(key) {
    None => Ok(cur)
    Some("true") | Some("1") => Ok(true)
    Some("false") | Some("0") => Ok(false)
    Some(other) => Err("\{ctx} 应为 true|false（也收 1/0），got \{other}")
  }
}

///|
/// 图层样式的**部分更新**读取器（`set-fx`）。
///
/// 给了就必须收得下（非数/非法颜色/越界一律报错——铁律 11 那条"非数不许静默退
/// 默认、越界不许静默夹紧"）；没给就沿用**当前层**的值（层上还没有样式时以
/// `@core.default_fx()` 为底）。
fn fx_merge(
  m : Map[String, String],
  base : @core.LayerFx,
) -> Result[@core.LayerFx, String] {
  let shadow = match kv_bool_arg(m, "shadow", base.shadow, "图层样式的 shadow") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let outline = match kv_bool_arg(m, "outline", base.outline, "图层样式的 outline") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let glow = match kv_bool_arg(m, "glow", base.glow, "图层样式的 glow") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let inner = match kv_bool_arg(m, "inner", base.inner, "图层样式的 inner") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let dx = match arg_d(m, "shadow_dx", base.shadow_dx) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let dy = match arg_d(m, "shadow_dy", base.shadow_dy) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let sblur = match arg_d(m, "shadow_blur", base.shadow_blur) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let ow = match arg_d(m, "outline_w", base.outline_w) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let gr = match arg_d(m, "glow_radius", base.glow_radius) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let idx = match arg_d(m, "inner_dx", base.inner_dx) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let idy = match arg_d(m, "inner_dy", base.inner_dy) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let iblur = match arg_d(m, "inner_blur", base.inner_blur) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // 颜色：给了就要是合法颜色（`#RRGGBB`/`#RRGGBBAA`，见 `parse_color`）
  let mut sc = base.shadow_color
  let mut oc = base.outline_color
  let mut gc = base.glow_color
  let mut ic = base.inner_color
  for pair in [("shadow_color", 0), ("outline_color", 1), ("glow_color", 2), ("inner_color", 3)] {
    match m.get(pair.0) {
      Some(v) => {
        let c = match parse_color(v) {
          Ok(c) => c
          Err(e) => return Err(e)
        }
        if pair.1 == 0 {
          sc = c
        } else if pair.1 == 1 {
          oc = c
        } else if pair.1 == 2 {
          gc = c
        } else {
          ic = c
        }
      }
      None => ()
    }
  }
  Ok({
    shadow,
    shadow_dx: dx,
    shadow_dy: dy,
    shadow_blur: sblur,
    shadow_color: sc,
    outline,
    outline_w: ow,
    outline_color: oc,
    glow,
    glow_radius: gr,
    glow_color: gc,
    inner,
    inner_dx: idx,
    inner_dy: idy,
    inner_blur: iblur,
    inner_color: ic,
  })
}

///|
/// `set-fx <id> [clear=1] [shadow=…] …`：给层装/改/摘图层样式（投影/描边/
/// 外发光/内阴影）。
pub fn cmd_set_fx(s : Session, tokens : Array[String]) -> String {
  if tokens.length() < 3 {
    return err(
      "用法：set-fx <id> " + fx_key_doc() + "（至少要给一个参数；摘掉整份样式用 clear=1）",
    )
  }
  let doc = match require_doc(s) {
    Ok(d) => d
    Err(e) => return err(e)
  }
  let id = tokens[1]
  let target = match @core.find_layer(doc.layers, id) {
    Some(l) => l
    None => return err("层不存在：\{id}")
  }
  // 键要在**改之前**查（拼错的键会被 `kv_args` 静默丢掉，然后报"什么都没改"
  // 这句误导的话——同 `set-adjust` 那条）
  match check_kv_args(tokens, 2, fx_keys(), "set-fx") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let m = kv_args(tokens, 2)
  if m.length() == 0 {
    return err("set-fx 至少要给一个要改的参数（例如 shadow=1；摘掉整份样式用 clear=1）")
  }
  let clear = match kv_bool_arg(m, "clear", false, "图层样式的 clear") {
    Ok(v) => v
    Err(e) => return err(e)
  }
  if clear && m.length() > 1 {
    return err("set-fx 的 clear=1 与其它参数不能同时给（摘掉 vs 改，两件事）")
  }
  if clear {
    // `clear` **不查 kind**：它只会把字段摘掉，而"能打上的名字必须能摘下"
    // ——手改容器给调整层塞了 fx 时，这里必须仍摘得掉（否则那个字段就永远
    // 洗不掉了，而 lint 还在报它）。
    if target.fx is None {
      return err("层 \{id} 本来就没有图层样式（`clear=1` 是摘掉已有样式，不是空操作）")
    }
    snapshot(s, doc, "set-fx \{id} clear")
    let _ = update_layer(doc.layers, id, fn(l) { { ..l, fx: None } })
    return "{\"ok\":true,\"op\":\"set-fx\",\"id\":\"\{id}\",\"fx\":\"none\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
  }
  // 部分更新：以"当前层上的样式"为底（没有就用缺省样式——四件都是关的）
  let base = match target.fx {
    Some(f) => f
    None => @core.default_fx()
  }
  let cand = match fx_merge(m, base) {
    Ok(f) => f
    Err(e) => return err(e)
  }
  // 写（不是摘）：调整层没有自己的像素 ⇒ 走 `kind_only_fields` 那张表
  // （入口拒绝与 lint 兜底共用同一格），不在这里手写第二个 kind 判断。
  //
  // ⚠️ 必须拿**候选值**去问：那张表的判据是"这层**带着**这个字段、而它的 kind
  // 又不读它"，对"还没有 fx 的调整层"（`dead` 判空）会直接放行——实测就是把
  // `set-fx a1 shadow=1` 收下了（回 ok、指纹变、画面逐位不变，最坏的那种）。
  match kind_only_write_error({ ..target, fx: Some(cand) }, "fx") {
    Some(e) => return err(e)
    None => ()
  }
  // 取值判据**只有一句**（`@core.fx_param_error`）：入口拒绝与 lint 报的是同一句
  match @core.fx_param_error(cand) {
    Some(e) => return err(e)
    None => ()
  }
  snapshot(s, doc, "set-fx \{id}")
  let _ = update_layer(doc.layers, id, fn(l) { { ..l, fx: Some(cand) } })
  "{\"ok\":true,\"op\":\"set-fx\",\"id\":\"\{id}\",\"fx\":\"\{fx_report(Some(cand))}\",\"fingerprint\":\"\{@core.fingerprint(doc)}\"}"
}
