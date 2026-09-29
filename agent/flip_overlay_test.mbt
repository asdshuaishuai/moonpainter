/// flip 命令与 render 命令 overlay 参数的会话级测试（补齐能力轮）。

///|
test "flip 命令往返：h → pick 镜像 → none 还原（指纹回原）" {
  let s = @agent.Session::new()
  let r0 = @agent.exec(s, "session-open full_image")
  assert_true(r0.has_prefix("{\"ok\":true"), msg=r0)
  let r1 = @agent.exec(s, "new 60 40")
  assert_true(r1.has_prefix("{\"ok\":true"), msg=r1)
  let r2 = @agent.exec(s, "add-rect x=0 y=0 w=30 h=40 fill=#000000FF id=bg")
  assert_true(r2.has_prefix("{\"ok\":true"), msg=r2)
  let r3 = @agent.exec(s, "add-polygon x=36 y=10 w=20 h=20 points=0,0;20,10;0,20 fill=#00FF00FF id=tri")
  assert_true(r3.has_prefix("{\"ok\":true"), msg=r3)
  let f0 = @agent.exec(s, "fingerprint")
  // 翻转 h：三角形尖端从右缘（x≈56）镜像到左缘（x≈36）。
  // 探针取顶部 y=11（该高度内部仅 x∈[0,2] 局部，不对称性最大）。
  let p0 = @agent.exec(s, "pick 37.5 11")
  assert_true(p0.contains("\"id\":\"tri\""), msg=p0)
  let r4 = @agent.exec(s, "flip tri h")
  assert_true(r4.contains("\"flip_h\":true"), msg=r4)
  // 翻转后：左上探针落空（tri 内容镜像到右侧；bg 只覆盖 x≤30，该点为空）
  let p1 = @agent.exec(s, "pick 37.5 11")
  assert_true(p1.contains("\"id\":null"), msg=p1)
  let p2 = @agent.exec(s, "pick 54.5 11")
  assert_true(p2.contains("\"id\":\"tri\""), msg=p2)
  // 还原：指纹必须回到翻转前
  let r5 = @agent.exec(s, "flip tri none")
  assert_true(r5.contains("\"flip_h\":false"), msg=r5)
  let f1 = @agent.exec(s, "fingerprint")
  assert_eq(f1, f0)
  // 非法方向拒绝
  let r6 = @agent.exec(s, "flip tri diagonal")
  assert_true(r6.has_prefix("{\"error\":\"flip 方向"), msg=r6)
}


///|
test "render 命令 overlay=1 回包标记且 sha256 与无 overlay 不同" {
  let s = @agent.Session::new()
  let _ = @agent.exec(s, "session-open full_image")
  let _ = @agent.exec(s, "new 60 40")
  let _ = @agent.exec(s, "add-rect x=0 y=0 w=30 h=40 fill=#000000FF")
  let r1 = @agent.exec(s, "render 60")
  assert_true(r1.contains("\"overlay\":false"), msg=r1)
  let r2 = @agent.exec(s, "render 60 overlay=1")
  assert_true(r2.contains("\"overlay\":true"), msg=r2)
  match (r1.find("\"render_sha256\":\""), r2.find("\"render_sha256\":\"")) {
    (Some(a), Some(b)) => {
      let h1 = r1[a + 17:a + 81].to_owned()
      let h2 = r2[b + 17:b + 81].to_owned()
      assert_true(h1 != h2)
    }
    _ => abort("回包缺 render_sha256")
  }
}
