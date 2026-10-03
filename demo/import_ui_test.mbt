/// 导入一张**正经照片**时的落点：图片永远 1:1（绝不拉伸），装不下就把画布
/// 放大到装得下，装得下就居中。
///
/// 这组判据守的是"能把照片拿起来修"，不是"能把图放进来"——此前人类侧写死
/// `x=100 y=60 w=600 h=450`，一张 3024×2016（3:2）的照片被拉伸成 4:3 并落在
/// 画布外；更糟的是长边超过引擎可渲染上限（4096）时，画布根本建不出来而
/// 照片仍按原生尺寸落盘 ⇒ 预览看着正常、**导出只画左上角 4096²**。

///|
test "照片比画布大：画布长到照片原生尺寸，图片落 (0,0)" {
  assert_eq(@demo.import_placement(800, 600, 3024, 2016), (0, 0, 3024, 2016))
}

///|
test "照片比画布小：画布不动，图片居中（不拉伸）" {
  assert_eq(@demo.import_placement(800, 600, 400, 300), (200, 150, 800, 600))
}

///|
test "只超一个方向：画布只在该方向长大，另一个方向仍居中" {
  assert_eq(@demo.import_placement(800, 600, 1000, 300), (0, 150, 1000, 600))
  assert_eq(@demo.import_placement(800, 600, 300, 1000), (250, 0, 800, 1000))
}

///|
test "照片尺寸不合法（引擎没报出来）：不猜，原样退回" {
  assert_eq(@demo.import_placement(800, 600, 0, 0), (0, 0, 800, 600))
  assert_eq(@demo.import_placement(800, 600, 3024, 0), (0, 0, 800, 600))
}

///|
/// 套索落定：点列 → `add-mask kind=polygon`。守三件事——
/// ① 盒子是点列的**紧包围盒**（盒子就是支持窗，"盒子跟着内容走"）；
/// ② `points=` 是**盒内局部坐标**（相对盒原点；写成画布坐标 = 选区整体位移）；
/// ③ 每个顶点都**真的落在盒内**（引擎的硬判据，跑出去入口就拒）。
test "套索：紧包围盒 + 盒内局部顶点，且每个顶点都在盒内" {
  let line = @demo.lasso_mask_line("r", [(100, 100), (180, 100), (140, 160)], 0, 0.0, 0.0)
  assert_eq(
    line,
    "add-mask r kind=polygon x=100 y=100 w=80 h=60 points=0,0;80,0;40,60",
  )
}

///|
test "套索：四点不规则形状的盒子与顶点（顺序原样保留，不去重不排序）" {
  let pts = [(10, 20), (90, 22), (88, 74), (12, 70)]
  let line = @demo.lasso_mask_line("L3", pts, 0, 0.0, 0.0)
  assert_eq(
    line,
    "add-mask L3 kind=polygon x=10 y=20 w=80 h=54 points=0,0;80,2;78,54;2,50",
  )
}

///|
test "套索：退化点列（全在同一行/同一列）盒子宽高至少 1，顶点仍在盒内" {
  // 引擎的 `w/h > 0` 是硬下界，而水平点列的盒高本来是 0。
  let flat = @demo.lasso_mask_line("r", [(5, 5), (25, 5), (15, 5)], 0, 0.0, 0.0)
  assert_eq(flat, "add-mask r kind=polygon x=5 y=5 w=20 h=1 points=0,0;20,0;10,0")
  let tall = @demo.lasso_mask_line("r", [(7, 0), (7, 40), (7, 20)], 0, 0.0, 0.0)
  assert_eq(tall, "add-mask r kind=polygon x=7 y=0 w=1 h=40 points=0,0;0,40;0,20")
}

///|
test "套索：羽化只在设了才写进命令行（0 与「没设过」在日志里可分辨）" {
  assert_false(@demo.lasso_mask_line("r", [(0, 0), (10, 0), (5, 9)], 0, 0.0, 0.0).contains("feather"))
  assert_true(@demo.lasso_mask_line("r", [(0, 0), (10, 0), (5, 9)], 7, 0.0, 0.0).contains("feather=7"))
}

///|
/// 判据两头咬：对**任意**点列，`lasso_mask_line` 产出的每个顶点都必须落在
/// 它自己声明的盒子里（`0 ≤ px ≤ w`、`0 ≤ py ≤ h`）。只断言某一条具体串的话，
/// "把局部坐标写成画布坐标"这种变异会活下来。
test "套索：产出的每个顶点都在盒内（任意点列，含负坐标）" {
  let cases : Array[Array[(Int, Int)]] = [
    [(0, 0), (10, 0), (5, 9)],
    [(100, 100), (180, 100), (140, 160)],
    [(-30, -40), (-10, -40), (-20, -1)],
    [(3, 3), (3, 3), (4, 4)],
  ]
  for pts in cases {
    let line = @demo.lasso_mask_line("r", pts, 0, 0.0, 0.0)
    // 从命令行里读回 x/y/w/h 与 points（判据不去猜内部状态）
    let toks = line.split(" ").collect()
    let mut x = 0
    let mut y = 0
    let mut w = 0
    let mut h = 0
    let mut pts_s = ""
    for t in toks {
      if t.has_prefix("x=") {
        x = t_int(t[2:])
      } else if t.has_prefix("y=") {
        y = t_int(t[2:])
      } else if t.has_prefix("w=") {
        w = t_int(t[2:])
      } else if t.has_prefix("h=") {
        h = t_int(t[2:])
      } else if t.has_prefix("points=") {
        pts_s = t[7:].to_owned()
      }
    }
    assert_true(w >= 1 && h >= 1, msg="盒子宽高必须 ≥ 1：\{line}")
    for q in pts_s.split(";") {
      let pair = q.split(",").collect()
      let px = t_int(pair[0])
      let py = t_int(pair[1])
      assert_true(
        px >= 0 && px <= w && py >= 0 && py <= h,
        msg="顶点 (\{px},\{py}) 必须落在 0..\{w} × 0..\{h} 内：\{line}",
      )
    }
    // 盒子必须真的框住所有原始点（不是"随便一个小盒子"）
    for p in pts {
      assert_true(
        p.0 >= x && p.0 <= x + w && p.1 >= y && p.1 <= y + h,
        msg="原始点 \{p} 必须落在盒 (\{x},\{y},\{w},\{h}) 内：\{line}",
      )
    }
  }
}

///|
/// 测试自己的**读回**小工具（带符号）：`@demo.parse_int_safe` 按设计只认非负
/// （它服务于 radius/feather），拿它读 `x=-30` 会得到 0 —— 第一版就这么错了，
/// 测试当场报"原始点 (-30,-40) 必须落在盒 (0,0,20,39) 内"。
fn t_int(s : StringView) -> Int {
  let body = s.to_owned()
  let neg = body.has_prefix("-")
  let digits = if neg { body[1:].to_owned() } else { body }
  let mut v = 0
  for ch in digits.iter() {
    v = v * 10 + (ch.to_int() - 48)
  }
  if neg {
    0 - v
  } else {
    v
  }
}

///|
/// 层**不在原点**时：盒要平移到层局部（`x - l.x`），而顶点是相对盒原点的整数差
/// —— 层的位置有小数也不丢顶点的精度。
///
/// 这条守的是"套索拖在画布上的那块 = 实际裁掉的那块"：蒙版盒是**层局部**坐标
/// （`mask_cover_at` 收局部点），此前人侧直接把画布坐标当局部用，层在 (20,20)
/// 时整块蒙版偏移了一层的位置（实测：三角形跑到了画布 (40,40) 那一带）。
test "套索：盒平移到层局部，顶点保持整数差（层位置带小数也不丢精度）" {
  let pts = [(20, 20), (80, 20), (50, 70)]
  // 层在画布 (20,20) ⇒ 局部盒从 (0,0) 起
  assert_eq(
    @demo.lasso_mask_line("r", pts, 0, 20.0, 20.0),
    "add-mask r kind=polygon x=0 y=0 w=60 h=50 points=0,0;60,0;30,50",
  )
  // 层在画布 (10.3,7.7) ⇒ 盒是小数，顶点仍是同一串整数（相对盒原点）
  assert_eq(
    @demo.lasso_mask_line("r", pts, 0, 10.3, 7.7),
    "add-mask r kind=polygon x=9.7 y=12.3 w=60 h=50 points=0,0;60,0;30,50",
  )
}

///|
/// 人侧入口的**拒绝面**：旋转/翻转/在组里的层，蒙版坐标换算人侧不做（局部盒
/// 不再是轴对齐矩形）——必须说清而不是猜一个位置。
///
/// 这里判的是纯函数 `shift_rect`（`mask_local_offset` 的引擎查询部分靠
/// clickthrough 驱动断言）：画布框平移后仍是同宽同高。
test "蒙版坐标换算：只平移盒，宽高不动（矩形/椭圆蒙版走同一条）" {
  assert_eq(
    @demo.shift_rect(["20", "20", "60", "50"], 20.0, 20.0),
    ["0", "0", "60", "50"],
  )
  assert_eq(
    @demo.shift_rect(["20", "20", "60", "50"], 10.3, 7.7),
    ["9.7", "12.3", "60", "50"],
  )
}
