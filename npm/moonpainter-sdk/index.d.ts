/// MoonPainter wasm SDK 类型声明。
///
/// JSON 信封：成功 { ok: true, op: string, ... }（变更类必带 fingerprint）；
/// 失败 { error: string }（精确原因，AgentGate 零容忍）。

export interface Envelope {
  ok: boolean;
  op?: string;
  fingerprint?: string;
  error?: string;
  [k: string]: unknown;
}

export interface RenderEnvelope extends Envelope {
  width: number;
  height: number;
  overlay: boolean;
  png_b64: string;
  render_sha256: string;
}

export interface SaveMpdEnvelope extends Envelope {
  mpd_b64: string;
}

export interface OpenMpdEnvelope extends Envelope {
  /** 载入后文档的 fingerprint（design.json 指纹，可与 saveMpd 前对照） */
  fingerprint: string;
}

export interface VersionInfo {
  ok: boolean;
  engine: 'moonpainter';
  version: string;
  container: string;
  vision_required: boolean;
}

/**
 * MoonPainter 引擎 wasm 门面。
 * 所有 exec 走同一分发器（与 CLI / AI demo 一致）；vision 闸未开门时
 * 除 session-open 外的一切命令返回 { error: "vision 闸未通过…" }。
 */
export interface MoonPainterEngine {
  /** 引擎版本与容器标识 */
  version(): VersionInfo;
  /** 重开默认会话（全部状态复位） */
  reset(): Envelope;
  /** 执行一行引擎命令，返回 JSON 信封 */
  exec(line: string): Envelope;
  /** 打开句柄会话（多文档），返回句柄（≥1） */
  open(): number;
  /** 关闭句柄会话；1=已关 0=不存在 */
  close(handle: number): number;
  /** 在句柄会话上执行命令 */
  execOn(handle: number, line: string): Envelope;
  /** 渲染当前画布（PNG base64 + sha256 + fingerprint） */
  render(width?: number, overlay?: boolean): RenderEnvelope;
  /** 打包当前文档为 .mpd 容器（base64） */
  saveMpd(): SaveMpdEnvelope;
  /**
   * 从 .mpd 容器（base64）载入当前会话——`saveMpd` 的对偶。
   * 容器是整个系统的唯一事实源，只有存没有开等于存了个死文件。
   */
  openMpd(mpdB64: string): OpenMpdEnvelope;
}

/**
 * 加载 MoonPainter 引擎 wasm。
 * @param url wasm 路径（浏览器 fetch / Node fs 均可）
 */
export declare function loadEngine(url?: string): Promise<MoonPainterEngine>;
