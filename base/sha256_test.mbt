/// SHA-256 已知答案测试（NIST/FIPS 180-4 公开向量）。
/// 内部测试按工具链要求使用 @base 限定。

///|
test "sha256 空串（NIST 标准向量）" {
  assert_eq(
    @base.sha256_hex(Bytes::from_array([])),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}

///|
test "sha256 \"abc\"（单块向量）" {
  assert_eq(
    @base.sha256_hex(@utf8.encode("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "sha256 双块消息（448 位边界，覆盖消息调度长尾）" {
  let src = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  assert_eq(
    @base.sha256_hex(@utf8.encode(src)),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
}

///|
test "sha256 长消息（百万个 a，覆盖多块累积）" {
  // 一百万字符约 1.5 万块：native 下可接受；用重复拼接构造
  let unit = "a".repeat(1000)
  let mut acc = ""
  let mut i = 0
  while i < 1000 {
    acc = acc + unit
    i = i + 1
  }
  assert_eq(acc.length(), 1000000)
  assert_eq(
    @base.sha256_hex(@utf8.encode(acc)),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  )
}

///|
test "sha256 输出确定性" {
  let a = @base.sha256_hex(@utf8.encode("MoonPainter"))
  let b = @base.sha256_hex(@utf8.encode("MoonPainter"))
  assert_eq(a, b)
  assert_eq(a.length(), 64)
}
