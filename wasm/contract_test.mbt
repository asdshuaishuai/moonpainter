/// wasm 面合同测试：与 deepDesign 胶水同款的调用次序在本包内直接可测
/// （这些导出在 native/js 下就是普通 MoonBit 函数）。

///|
test "wasm 面：版本 + 槽执行闭环（vision 闸→new→绘制→render）" {
  // 版本
  let v = @wasm.mp_version()
  assert_true(v.contains("\"engine\":\"moonpainter\""), msg=v)
  assert_true(v.contains("\"vision_required\":true"), msg=v)
  // 槽协议：UTF-8 分块压入
  fn load(line : String) -> Unit {
    @wasm.in_reset()
    let bytes = @utf8.encode(line)
    let mut i = 0
    while i < bytes.length() {
      let n = if bytes.length() - i < 4 { bytes.length() - i } else { 4 }
      let mut le = 0
      let mut j = 0
      while j < n {
        le = le | ((bytes[i + j].to_int() & 0xFF) << (8 * j))
        j = j + 1
      }
      @wasm.in_push(le, n)
      i = i + n
    }
  }

  let _ = @wasm.mp_reset()
  // vision 闸：未开门拒绝
  load("new 100 100")
  let r0 = @wasm.mp_exec_in()
  assert_true(r0.contains("vision 闸未通过"), msg=r0)
  // 开门 → 建档 → 绘制 → 渲染
  load("session-open full_image")
  assert_true(@wasm.mp_exec_in().contains("\"op\":\"session-open\""))
  load("new 200 150 uuid=wasm-e2e")
  assert_true(@wasm.mp_exec_in().contains("\"op\":\"new\""))
  load("add-rect x=10 y=10 w=100 h=60 fill=#2E6FE8FF radius=8 name=card")
  let r3 = @wasm.mp_exec_in()
  assert_true(r3.contains("\"op\":\"add-rect\""), msg=r3)
  assert_true(r3.contains("\"fingerprint\":\""), msg=r3)
  load("render 200 overlay=1")
  let r4 = @wasm.mp_exec_in()
  assert_true(r4.contains("\"overlay\":true"), msg=r4)
  assert_true(r4.contains("\"png_b64\":\"iVBOR"), msg=r4) // PNG 魔数 base64 头
  // 中文命令（UTF-8 多字节）过槽
  load("add-rect x=0 y=0 w=10 h=10 name=中文层")
  assert_true(@wasm.mp_exec_in().contains("\"op\":\"add-rect\""))
  // 中文回读：槽长一致性与解码
  @wasm.in_reset()
  assert_eq(@wasm.in_len(), 0)
}

///|
test "wasm 面：undo 生命周期跨 mp_reset 复位" {
  let _ = @wasm.mp_reset()
  fn load(line : String) -> Unit {
    @wasm.in_reset()
    let bytes = @utf8.encode(line)
    let mut i = 0
    while i < bytes.length() {
      let n = if bytes.length() - i < 4 { bytes.length() - i } else { 4 }
      let mut le = 0
      let mut j = 0
      while j < n {
        le = le | ((bytes[i + j].to_int() & 0xFF) << (8 * j))
        j = j + 1
      }
      @wasm.in_push(le, n)
      i = i + n
    }
  }

  load("session-open full_image")
  let _ = @wasm.mp_exec_in()
  load("new 50 50")
  let _ = @wasm.mp_exec_in()
  load("add-rect x=0 y=0 w=10 h=10")
  let _ = @wasm.mp_exec_in()
  load("undo")
  assert_true(@wasm.mp_exec_in().contains("\"op\":\"undo\""))
  // reset 后 undo 栈清空：undo 报错
  let _ = @wasm.mp_reset()
  load("session-open full_image")
  let _ = @wasm.mp_exec_in()
  load("new 50 50")
  let _ = @wasm.mp_exec_in()
  load("undo")
  assert_true(@wasm.mp_exec_in().contains("撤销栈为空"))
}

///|
test "wasm 面：多会话句柄——隔离 / 关闭 / 未知句柄" {
  @wasm.in_reset()
  // 两个独立句柄，互不影响
  let h1 = @wasm.mp_open()
  let h2 = @wasm.mp_open()
  assert_true(h1 != h2)
  @wasm.in_reset()
  // （槽面向默认会话；句柄会话直接用 exec_h 前先压槽）
  let bytes1 = @utf8.encode("session-open full_image")
  @wasm.in_reset()
  push_bytes(bytes1)
  let _ = @wasm.mp_exec_h(h1)
  let bytes2 = @utf8.encode("new 111 222 uuid=h1-doc")
  @wasm.in_reset()
  push_bytes(bytes2)
  let r1 = @wasm.mp_exec_h(h1)
  assert_true(r1.contains("\"uuid\":\"h1-doc\""), msg=r1)
  // h2 未开门：exec 应被 vision 闸拒绝（会话隔离的证据）
  @wasm.in_reset()
  push_bytes(@utf8.encode("new 10 10"))
  let r2 = @wasm.mp_exec_h(h2)
  assert_true(r2.contains("vision 闸未通过"), msg=r2)
  // 关闭 h2 后再执行 → 未知句柄
  assert_eq(@wasm.mp_close(h2), 1)
  assert_eq(@wasm.mp_close(h2), 0)
  @wasm.in_reset()
  push_bytes(@utf8.encode("new 10 10"))
  let r3 = @wasm.mp_exec_h(h2)
  assert_true(r3.contains("未知会话句柄"), msg=r3)
  // h1 不受影响
  @wasm.in_reset()
  push_bytes(@utf8.encode("fingerprint"))
  let rf = @wasm.mp_exec_h(h1)
  assert_true(rf.contains("\"fingerprint\":\""), msg=rf)
  let _ = @wasm.mp_close(h1)
}

///|
/// 槽压入辅助（与既有合同测试同款协议）。
fn push_bytes(bytes : Bytes) -> Unit {
  let mut i = 0
  while i < bytes.length() {
    let n = if bytes.length() - i < 4 { bytes.length() - i } else { 4 }
    let mut le = 0
    let mut j = 0
    while j < n {
      le = le | ((bytes[i + j].to_int() & 0xFF) << (8 * j))
      j = j + 1
    }
    @wasm.in_push(le, n)
    i = i + n
  }
}
