/// agent —— PSD 导出（③ PSD 兼容 · **写的出口**：把文档变成 `.psd` 字节）。
///
/// 分工与读侧对称：`codec/psd_out.mbt` 只认字节与像素（`PsdOutLayer` → 字节），
/// 这里认文档模型（`Document` → 每层像素 + 层表）。
///
/// **栅格化口径**：每层都按渲染器**真实画出来的样子**烤成像素（`@render.rasterize_layer`
/// 是唯一权威），于是"导出的 PSD 打开来是什么样"这件事不取决于我们在这里
/// 重新解释一遍层语义。三条具体做法：
/// 1. **层自己的像素按 opacity=1 / visible=true 烤**，`opacity`/`visible` 写进
///    PSD 的层记录字段 —— 而**不能**烤进去：组的 α 在渲染器里是烤进画面的
///    （`eff_opacity`），再写一遍 opacity 就成了平方。
/// 2. 隐藏层也烤（`visible=true` 的副本），PSD 里 flags 记隐藏 —— 否则"隐藏层
///    的内容"会在导出时被静默丢掉（Photoshop 存隐藏层内容，我们也存）。
/// 3. 盒子取**画面自己的 alpha 紧包围盒**（不是层的声明盒子）：层样式会溢出、
///    文本层的声明盒子与像素本来就可能对不上，取紧包围盒让"PSD 里的层"与
///    "图上看到的那块"一致。
///
/// **拒绝清单（不降级，理由里给下一步）**：
/// - 装了 MVSL 编辑表（PSD 表达不了编辑表：写出去等于假装那些编辑不存在）；
/// - 调整层（PSD 的调整层是另一套格式：`brit`/`levl`/`curv`/`mixr` 块）；
/// - 画布超出可渲染上限（`render_limit_error`：超了就只会导出被裁掉的一角）。
///
/// **已知的诚实边界**（README/DESIGN 同步）：蒙版与图层样式**烤进像素**（不写
/// PSD 的蒙版通道与 `lfx2` 效果块）；文本层是**位图**（不写文本层描述符）；
/// 组写成一个烤好的层（不写 `lsct` 分组标记）；对齐用的是画面包围盒。

///|
/// 一层烤出来的结果：紧包围盒 + 该盒内的非预乘 RGBA。
priv struct PsdBaked {
  x : Int
  y : Int
  w : Int
  h : Int
  rgba : Array[Byte]
}

///|
/// 把一层烤成"画面自己的像素"。`opacity=1`、`visible=true` 的副本进去烤：
/// 这两个字段**属于 PSD 的层记录**，烤进画面就重复生效了（组的 α 尤其明显）。
fn psd_bake_layer(
  l : @core.Layer,
  env : @render.RenderEnv,
  width : Int,
  height : Int,
) -> PsdBaked {
  let plain = { ..l, opacity: 1.0, visible: true }
  let buf = @render.rasterize_layer(plain, width, height, env)
  // alpha 紧包围盒：画面是哪一块，PSD 层就是哪一块
  let mut x0 = width
  let mut y0 = height
  let mut x1 = -1
  let mut y1 = -1
  let mut y = 0
  while y < height {
    let mut x = 0
    while x < width {
      let a = (@codec.rgba_get(buf, x, y) >> 24) & 0xFF
      if a != 0 {
        if x < x0 {
          x0 = x
        }
        if y < y0 {
          y0 = y
        }
        if x > x1 {
          x1 = x
        }
        if y > y1 {
          y1 = y
        }
      }
      x = x + 1
    }
    y = y + 1
  }
  // 没有墨的层（空组、全透明层、隐藏到没有子层的组）：PSD 的通道数据不能是
  // 0 字节，写成 1×1 全透明 —— 名字/不透明度/可见性照旧保真，画面无影响。
  if x1 < 0 || y1 < 0 {
    return PsdBaked::{ x: 0, y: 0, w: 1, h: 1, rgba: [0, 0, 0, 0] }
  }
  let w = x1 - x0 + 1
  let h = y1 - y0 + 1
  let rgba : Array[Byte] = []
  let mut yy = y0
  while yy <= y1 {
    let mut xx = x0
    while xx <= x1 {
      let p = @codec.rgba_get(buf, xx, yy)
      rgba.push(((p >> 16) & 0xFF).to_byte())
      rgba.push(((p >> 8) & 0xFF).to_byte())
      rgba.push((p & 0xFF).to_byte())
      rgba.push(((p >> 24) & 0xFF).to_byte())
      xx = xx + 1
    }
    yy = yy + 1
  }
  PsdBaked::{ x: x0, y: y0, w, h, rgba }
}

///|
/// 递归找调整层（组里的也算）：调整层是"作用在其下全部可见层"的算子，
/// PSD 里得写成调整层块（另一套格式）—— 我们**不假装**能写，拒。
fn psd_adjust_layer_name(layers : Array[@core.Layer]) -> String? {
  for l in layers {
    if l.kind is @core.ShapeKind::Adjust {
      return Some(l.name)
    }
    match psd_adjust_layer_name(l.children) {
      Some(n) => return Some(n)
      None => ()
    }
  }
  None
}

///|
/// 文档 → `.psd` 字节。
pub fn psd_export(s : Session) -> Result[Bytes, String] {
  let doc = match s.doc {
    None => return Err("没有打开的文档（先 session-open 或 new）")
    Some(d) => d
  }
  if s.mvsl.ops.length() > 0 {
    return Err(
      "文档装了 MVSL 编辑表（\{s.mvsl.ops.length()} 条算子）—— PSD 表达不了编辑表，写出去等于丢掉这些编辑；先 mvsl-set 一张空表（或另存为 .mpd）再导出",
    )
  }
  match psd_adjust_layer_name(doc.layers) {
    Some(n) => {
      return Err(
        "调整层「\{n}」没有 PSD 对应表达（PSD 的调整层是另一套块格式）—— 先删掉它或另存为 .mpd",
      )
    }
    None => ()
  }
  let limit = @render.render_limit_error(doc.width, doc.height)
  if limit != "" {
    return Err("画布 \{doc.width}×\{doc.height} 超出可渲染上限：\{limit}（导出会只剩一角）")
  }
  let env = @render.RenderEnv::new()
  let base = @render.render_doc(doc, env)
  let composite = @codec.psd_composite_planes(base)
  let out : Array[@codec.PsdOutLayer] = []
  for l in doc.layers {
    let baked = psd_bake_layer(l, env, doc.width, doc.height)
    let opacity = (l.opacity * 255.0 + 0.5).to_int()
    out.push({
      name: l.name,
      x: baked.x,
      y: baked.y,
      w: baked.w,
      h: baked.h,
      opacity: if opacity < 0 {
        0
      } else if opacity > 255 {
        255
      } else {
        opacity
      },
      visible: l.visible,
      blend: @core.blend_name(l.blend),
      rgba: baked.rgba,
      has_alpha: true,
    })
  }
  @codec.psd_encode(doc.width, doc.height, composite, out)
}

///|
/// `export-psd-b64`：把当前文档写成 PSD，回 b64 + 尺寸/层数/sha256。
///
/// 为什么不直接给路径：路径写入在 CLI 侧（`save-mpd` 那条路），而 b64 让
/// **两侧**（CLI 与 wasm 宿主）都能拿到字节 —— 与 `save-mpd-b64` 同一个口径。
pub fn cmd_export_psd_b64(s : Session, tokens : Array[String]) -> String {
  match check_kv_args(tokens, 1, [], "export-psd-b64") {
    Ok(_) => ()
    Err(e) => return err(e)
  }
  let doc = match s.doc {
    None => return err("没有打开的文档（先 session-open 或 new）")
    Some(d) => d
  }
  let bytes = match psd_export(s) {
    Ok(b) => b
    Err(e) => return err(e)
  }
  let n = doc.layers.length()
  "{\"ok\":true,\"op\":\"export-psd-b64\",\"width\":\{doc.width},\"height\":\{doc.height},\"layers\":\{n},\"bytes\":\{bytes.length()},\"sha256\":\"\{@base.sha256_hex(bytes)}\",\"psd_b64\":\"\{@base64.encode(bytes)}\"}"
}
