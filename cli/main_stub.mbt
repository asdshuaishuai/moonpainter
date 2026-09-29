///|
/// 非 native 目标的入口占位：文件 FFI 只在 native 存在（deepOffice 同款门控）。
/// 这里把全部导入都摸一遍，避免分目标编译的 unused 假警报。
fn main {
  let probe = @utf8.encode(@core.ENGINE_VERSION)
  let ver = @utf8.decode(probe, ignore_bom=true) catch {
    _ => @core.ENGINE_VERSION
  }
  let os_kind = match @env.get_env_var("OS") {
    Some(v) => v
    None => "unknown"
  }
  println("moonpainter \{ver} — native 目标专用（moon run --target native cli），当前 OS 探测: \{os_kind}")
  println("container: \{@mpd.container_signature()}")
  let _ = @agent.vision_required()
}
