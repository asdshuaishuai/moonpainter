/// cli 文件层测试（native）：原子写 → 读回一致；.mpd 落盘往返。
/// 移植自 deepOffice 的 FFI 模式（自有 MIT），路径固定在 /tmp 下避免污染仓库。

///|
test "write_file_atomic → read_file 往返" {
  let path = "/tmp/moonpainter-cli-test-\{@core.ENGINE_VERSION}.bin"
  let payload = @utf8.encode("MoonPainter 原子写测试 payload 0123")
  assert_true(write_file_atomic(path, payload))
  match read_file(path) {
    Some(back) => assert_eq(back.length(), payload.length())
    None => abort("读回失败：\{path}")
  }
}

///|
test "cli dispatch：save-mpd / open-mpd 路径命令端到端" {
  let s = @agent.Session::new()
  let r0 = @agent.exec(s, "session-open full_image")
  assert_true(r0.has_prefix("{\"ok\":true"))
  let r1 = @agent.exec(s, "new 96 64 uuid=cli-e2e")
  assert_true(r1.has_prefix("{\"ok\":true"), msg=r1)
  let r2 = @agent.exec(s, "add-rect x=8 y=8 w=80 h=48 fill=#2E6FE8FF radius=6 name=card")
  assert_true(r2.has_prefix("{\"ok\":true"), msg=r2)
  let path = "/tmp/moonpainter-cli-e2e-\{@core.ENGINE_VERSION}.mpd"
  let save = dispatch(s, "save-mpd \{path}")
  assert_true(save.contains("\"op\":\"save-mpd\""), msg=save)
  // 原子写产物必须是合法容器：直接解包文件字节
  match read_file(path) {
    None => abort("落盘文件读取失败")
    Some(bytes) => {
      let back = match @mpd.unpack(bytes) {
        Ok(m) => m
        Err(e) => abort("落盘容器解包失败: \{e}")
      }
      let doc = @agent.Session::new()
      let _ = @agent.exec(doc, "session-open full_image")
      let opened = dispatch(doc, "open-mpd \{path}")
      assert_true(opened.contains("\"op\":\"open-mpd\""), msg=opened)
      let f1 = @agent.exec(s, "fingerprint")
      let f2 = @agent.exec(doc, "fingerprint")
      assert_eq(f2, f1) // 同一文档状态，指纹必须一致
      let _ = back
    }
  }
}
