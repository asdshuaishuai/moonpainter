/// 画布尺寸的**回读**，以及"容器能存但渲染画不出来"的知会。
///
/// 这两条此前都是缺的，而且缺的是同一件事的两半：
/// ①`census` 把 `canvas` 报成**截断之后**的渲染尺寸（5000×200 的文档报
///   `canvas:[4096,200]`），而"文档到底多大"在**命令面上没有任何回读路径**
///   ——`fingerprint` 只给哈希、`probe` 只有点；
/// ②`open-mpd` 是第四个能装进超限画布的入口（前两个是 `new`/`set-canvas`），
///   却一个字不说。
///
/// ⚠️ 为什么 `new`/`set-canvas` 拒绝、而 `open-mpd` 只能知会：`81ff759` 之前的
/// 引擎**允许** `new 5000 200`，所以超限容器**真实存在**（本仓库自己的旧版本
/// 存下的）。拒绝打开就等于"用户连打开自己的文件再 `crop` 到 4096 这条自救路
/// 都没有"。这一格就是钉这条不对称的。

///|
test "旧引擎存下的超限容器：open 只知会不拒绝，census 分报 canvas / render" {
  // 造一个旧版本真的存得下的容器：`pack` 只受**容器限额**（单边 30000）约束，
  // 不受渲染上限约束 —— 这正是"遗留文件"的样子（现在的命令面已经建不出）。
  let doc = @core.new_document("legacy-canvas", 5000, 200)
  doc.layers.push(@core.default_layer("d1", "far", 4500.0, 0.0, 100.0, 100.0))
  let bytes = match @mpd.pack(@mpd.MpdDoc::new(doc)) {
    Ok(b) => b
    Err(e) => abort("pack 失败（5000 宽在容器限额 30000 之内）：\{e}")
  }

  let s = @agent.Session::new()
  // 视觉闸是每次会话都要先过的（`census`/`render` 都在闸后面）
  let _ = @agent.exec(s, "session-open full_image")
  let (fp, notice) = match @agent.load_mpd(s, bytes) {
    Ok(pair) => pair
    // 判据的另一头：这里**必须放行**。拒绝打开 = 用户没法 crop 自救。
    Err(e) => abort("超限容器必须打得开（只知会、不拒绝）：\{e}")
  }
  assert_true(fp.length() == 64, msg="打开成功要回指纹：\{fp}")
  assert_true(notice != "", msg="超限容器必须**明说**，不许静默：\{notice}")
  // 报错要回显两个数（实收尺寸 + 上限），只说"太大了"没法自查
  assert_true(notice.contains("5000"), msg="要回显文档实收宽：\{notice}")
  assert_true(notice.contains("4096"), msg="要回显可渲染上限：\{notice}")

  // `census` 分报两个尺寸：`canvas` = 文档记账尺寸、`render` = 实际渲染尺寸。
  // 两者不等就是"能存但画不出来"，调用方一眼能对账。
  let out = @agent.exec(s, "census")
  assert_true(out.contains("\"canvas\":[5000,200]"), msg="canvas 必须是文档真实尺寸：\{out}")
  assert_true(out.contains("\"render\":[4096,200]"), msg="render 必须是被截断后的渲染尺寸：\{out}")

  // 正控：正常画布上两个数必须**相等**。没有这一格的话，"把 render 写成常量
  // 4096"或"把 canvas 也写成 base 尺寸"这类变异会被放过——判据要两头都咬。
  let s2 = @agent.Session::new()
  let _ = @agent.exec(s2, "session-open full_image")
  let _ = @agent.exec(s2, "new 100 60")
  let ok = @agent.exec(s2, "census")
  assert_true(ok.contains("\"canvas\":[100,60]"), msg="正常文档 canvas 就是它自己：\{ok}")
  assert_true(ok.contains("\"render\":[100,60]"), msg="正常文档 render 等于 canvas：\{ok}")
}
