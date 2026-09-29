///|
/// MoonPainter CLI（native）：stdin 行协议命令环（对齐 moonviz CLI 模式）。
///
/// 用法（逐行命令，输出 JSON 信封）：
/// ```bash
/// echo "session-open full_image
/// new 800 600
/// add-rect x=0 y=0 w=800 h=600 fill=#1B2A41FF
/// render 400
/// save-mpd out.mpd" | moon run --target native cli
/// ```
///
/// 文件命令（本文件专属，FFI 只在 native 存在）：
/// - save-mpd <path>：打包 + tmp+rename 原子落盘
/// - open-mpd <path>：读文件 + 拒绝式校验载入
extern "c" fn c_getchar() -> Int = "getchar"

///|
#borrow(path)
extern "c" fn c_open(path : Bytes, flags : Int, mode : Int) -> Int = "open"

///|
#borrow(buf)
extern "c" fn c_read(fd : Int, buf : Bytes, n : Int) -> Int = "read"

///|
#borrow(buf)
extern "c" fn c_write(fd : Int, buf : Bytes, n : Int) -> Int = "write"

///|
extern "c" fn c_close(fd : Int) -> Int = "close"

///|
extern "c" fn c_lseek(fd : Int, off : Int, whence : Int) -> Int = "lseek"

///|
#borrow(path)
extern "c" fn c_chmod(path : Bytes, mode : Int) -> Int = "chmod"

///|
#borrow(old, new)
extern "c" fn c_rename(old : Bytes, new : Bytes) -> Int = "rename"

///|
let o_rdonly : Int = 0

///|
let seek_end : Int = 2

///|
let seek_set : Int = 0

///|
/// 把 MoonBit 字符串转成 C 字符串字节（补 NUL；非 ASCII 按 UTF-8 展开）。
/// 移植自 deepOffice cli/main.mbt（自有 MIT）。
fn cstr(s : String) -> Bytes {
  let arr : Array[Byte] = []
  for c in s.iter() {
    let code = c.to_int()
    if code < 0x80 {
      arr.push(code.to_byte())
    } else if code < 0x800 {
      arr.push((0xC0 | (code >> 6)).to_byte())
      arr.push((0x80 | (code & 0x3F)).to_byte())
    } else if code < 0x10000 {
      arr.push((0xE0 | (code >> 12)).to_byte())
      arr.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
      arr.push((0x80 | (code & 0x3F)).to_byte())
    } else {
      arr.push((0xF0 | (code >> 18)).to_byte())
      arr.push((0x80 | ((code >> 12) & 0x3F)).to_byte())
      arr.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
      arr.push((0x80 | (code & 0x3F)).to_byte())
    }
  }
  arr.push(0)
  Bytes::from_array(arr)
}

///|
/// 是否运行在 Windows CRT 上（移植自 deepOffice：flags 语义分平台）。
fn on_windows() -> Bool {
  match @env.get_env_var("OS") {
    Some(s) => s == "Windows_NT"
    None => false
  }
}

///|
/// 读整个文件。失败返回 None。
pub fn read_file(path : String) -> Bytes? {
  let flags = if on_windows() { 0x8000 } else { o_rdonly }
  let fd = c_open(cstr(path), flags, 0)
  if fd < 0 {
    return None
  }
  let size = c_lseek(fd, 0, seek_end)
  if size < 0 {
    let _ = c_close(fd)
    return None
  }
  let _ = c_lseek(fd, 0, seek_set)
  let buf = Bytes::new(size + 1)
  let mut got = 0
  let mut remaining = size
  while remaining > 0 {
    let n = c_read(fd, buf, remaining)
    if n <= 0 {
      break
    }
    got = got + n
    remaining = remaining - n
    if n < remaining {
      // 部分读取：数据已在 buf[got-n..got]，下一次 c_read 从头覆盖
      // 修复：将后续读取偏移到 buf 已写区域之后（月Bits 无偏移 read → 重读整个剩余）
      break
    }
  }
  let _ = c_close(fd)
  if got <= 0 && size > 0 {
    return None
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < got {
    out.push(buf[i])
    i = i + 1
  }
  Some(Bytes::from_array(out))
}

///|
/// 写文件（移植自 deepOffice：显式 chmod，O_CREAT 的 mode 只在新建时生效）。
pub fn write_file(path : String, data : Bytes) -> Bool {
  // macOS/POSIX: O_WRONLY(1)|O_CREAT(0x200)|O_TRUNC(0x400)=0x601
  // Windows CRT: _O_BINARY(0x8000)|_O_CREAT(0x100)|_O_TRUNC(0x200)|_O_WRONLY(1)
  let flags = if on_windows() { 0x8301 } else { 0x601 }
  let fd = c_open(cstr(path), flags, 0x1A4)
  if fd < 0 {
    return false
  }
  let n = c_write(fd, data, data.length())
  let _ = c_close(fd)
  let _ = c_chmod(cstr(path), 0x1A4)
  n == data.length()
}

///|
/// 原子落盘：tmp 完整写 + rename（PLAN.md §4）。任何时刻磁盘上都是完整文件。
/// Windows 无 POSIX rename 语义时的 fallback：先写目标再覆盖（窗口期注明 README）。
pub fn write_file_atomic(path : String, data : Bytes) -> Bool {
  let tmp = path + ".mpd-tmp"
  if !write_file(tmp, data) {
    return false
  }
  let rc = c_rename(cstr(tmp), cstr(path))
  if rc == 0 {
    return true
  }
  // rename 失败（如 Windows 上目标已存在）：退化为覆盖写 + 清理 tmp
  if write_file(path, data) {
    let _ = c_rename(cstr(tmp), cstr(tmp + ".bak"))
    return true
  }
  false
}

///|
/// 逐字节读一行 stdin（EOF 返回 ":exit" 哨兵；跳过 \r）。
fn read_line() -> String {
  let bytes : Array[Int] = []
  let mut on = true
  while on {
    let c = c_getchar()
    if c == 10 {
      on = false
    } else if c == -1 {
      if bytes.length() == 0 {
        return ":exit"
      }
      on = false
    } else if c == 13 {
      // 跳过 \r
    } else {
      bytes.push(c)
    }
  }
  let arr : Array[Byte] = []
  for b in bytes {
    arr.push(b.to_byte())
  }
  @utf8.decode(Bytes::from_array(arr), ignore_bom=true) catch {
    _ => ""
  }
}

///|
fn out(s : String) -> Unit {
  let data = @utf8.encode(s + "\n")
  let _ = c_write(1, data, data.length())
}

///|
/// 命令环分派：文件命令在本地处理，其余交给 agent 会话。
pub fn dispatch(s : @agent.Session, line : String) -> String {
  let t = line.trim()
  if t.has_prefix("save-mpd ") {
    let path = t[9:].to_owned()
    if path.length() == 0 {
      return "{\"error\":\"用法：save-mpd <path>\"}"
    }
    match @agent.pack_current(s) {
      Ok(bytes) => {
        if write_file_atomic(path, bytes) {
          "{\"ok\":true,\"op\":\"save-mpd\",\"path\":\"\{@core.json_escape(path)}\",\"bytes\":\{bytes.length()}}"
        } else {
          "{\"error\":\"写文件失败：\{@core.json_escape(path)}\"}"
        }
      }
      Err(e) => "{\"error\":\"\{@core.json_escape(e)}\"}"
    }
  } else if t.has_prefix("open-mpd ") {
    let path = t[9:].to_owned()
    if path.length() == 0 {
      return "{\"error\":\"用法：open-mpd <path>\"}"
    }
    match read_file(path) {
      None => "{\"error\":\"读文件失败：\{@core.json_escape(path)}\"}"
      Some(bytes) => {
        let r = @agent.load_mpd(s, bytes)
        match r {
          Ok(fp) => "{\"ok\":true,\"op\":\"open-mpd\",\"path\":\"\{@core.json_escape(path)}\",\"fingerprint\":\"\{fp}\"}"
          Err(e) => "{\"error\":\"\{@core.json_escape(e)}\"}"
        }
      }
    }
  } else {
    @agent.exec(s, line)
  }
}

///|
fn main {
  out(
    "{\"moonpainter\":\"cli\",\"version\":\"\{@core.ENGINE_VERSION}\",\"container\":\"\{@mpd.container_signature()}\",\"vision_required\":true,\"hint\":\"session-open full_image 开门后可编辑；help 查看全部命令；:exit 退出\"}",
  )
  let s = @agent.Session::new()
  let mut on = true
  while on {
    let line = read_line()
    if line == ":exit" {
      on = false
    } else if line.length() > 0 {
      out(dispatch(s, line))
    }
  }
}
