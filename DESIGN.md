# MoonPainter 设计书 v0.2

## PSD 家族兼容的 Agent 驱动图层绘制引擎（MoonBit 100%）

> 版本：0.2（2026-09-29）。v0.1（工程代号 moonphoto）为全量愿景稿，含 PSD/AI 格式兼容；
> v0.2 按决策收敛——**本轮聚焦 .mpd 容器 + 参数化绘制**，外部格式兼容整体移入"远期路线"。
> 本轮实施与验收详见 [PLAN.md](./PLAN.md)（已完成，51 项测试全绿）。

---

## 0. 定位与铁律

MoonPainter 是 moonviz 套路在位图绘制领域的引擎：`.mpd` 双层容器为唯一事实源，
人类与 Agent 的编辑都回写元参数层，一切预览从 canonical design.json + 内容寻址资产重建。

六条铁律：

1. **100% MoonBit、零第三方依赖**：ZIP/DEFLATE/PNG/SHA-256 全部手写或从家族自有 MIT 代码移植（出处注释保留）；moonviz 的 deflate.mbt 是第三方内嵌（Apache-2.0），明确不用。
2. **`.mpd` 是唯一事实源**：文本层权威（canonical design.json，固定字段序/数字格式），像素层内容寻址不可变；指纹 = sha256(canonical design.json)。
3. **视觉多模态是硬性前置**：`session-open full_image` 是唯一开门声明；纯文本/仅 OCR 模型被明确拒绝并给出三条出路。
4. **诚实分级**：能力与边界写进 README；错误精确到原因，绝不静默糊弄。
5. **非破坏优先**：变换是放置参数，不重采样；资产字节永不修改。
6. **拒绝式校验 + 增量版本 + 限额 + 原子写**：容器损坏宁可拒绝打开，绝不带病渲染。

## 1. 调研结论（v0.1 遗产，仍有效）

### 1.1 Compositor（github.com/robbietilton/Compositor，MIT）

macOS 原生类 Photoshop 编辑器。对本工程最有价值的三块遗产：

- **图层模型纪律**：非破坏变换与像素分离；栅格蒙版与图层同变换；live mask = 引用下层 alpha；组直通。
- **`.comp` 格式纪律**：v1→v6 纯增量版本；拒绝式校验（坏数据拒开）；原子保存；限额（单边 ≤30k px、总像素 ≤1 亿、层 ≤1 万、manifest ≤4MiB、单资产 ≤512MiB）。`.mpd` 全套继承。
- **能力参照系**：10 种混合 + 调整层全家（本轮实现其中 7 种混合，调整层远期）。

差异化判断：Compositor 是人类单机 GUI 编辑器，无 Agent 通道、无跨格式、目录包仅 macOS——MoonPainter 补这三块（跨格式为远期）。

### 1.2 moonviz 套路复用清单

工具能力字典单一事实源（`list_tools` 生成 help/文档）、JSON 信封（`{"ok":true,...}`/`{"error":"..."}` + 变更必带指纹）、CLI getchar 行协议 + `:exit` 哨兵 + base64 大载荷、undo 快照栈、`canonical 文本必须被宿主持久化`的会话纪律。PNG 编码器（crc32/adler32/chunk 结构）移植自其 playground。

### 1.3 AI（Illustrator）格式事实（远期路线用，已核实）

.ai v9+ = PDF 兼容壳 + PGF 私有流（AI Private Data）；策略是解析 PDF 层入矢量 IR + 原文保全，PGF 逆向明确不做。来源：Super User《Where is PGF hidden in non-compatible Adobe Illustrator files》、PTC 兼容性文档。

## 2. 总体架构（已落地）

```
宿主    cli（native 行协议 + 文件 FFI + 原子落盘）
交互    agent（34 命令 · vision 闸 · undo/redo · P0–P2 lint · 工具字典）
容器    mpd（pack/unpack · manifest/params/agent · 指纹对账 · 限额 · 预览生成）
渲染    render（RGBA 画布 · 2×2 子采样 AA · W3C 混合 · 旋转 · 取景 · pick · stats）
核心    core（IR 层树 · canonical JSON 双向 · 指纹 · 层定位原语）
基座    codec（ZIP 读写 · DEFLATE/inflate · PNG 编解码 · 颜色） + base（SHA-256）
```

依赖严格单向无环：`base ← codec ← core ← render ← mpd ← agent ← cli`。

## 3. IR 文档模型（core/document.mbt）

- 层类型：`Rect / Ellipse / Line / Polygon / Image / Group`；
- 层属性：id/name/visible/opacity(0..1)/blend/x/y/w/h/rotation_deg/corner_radius/points/fill/stroke/asset_hash/tags/children；
- 填充：`NoFill / Solid(#AARRGGBB) / LinearGradient(c0,c1,x0,y0,x1,y1 局部 0..1 端点)`；
- 层序 = 数组序自底向上；Group 以 children 嵌套，直通合成（组只传递可见性/透明度，组级混合不生效——诚实边界）；
- Image 层引用 `assets/sha256/<hash>` 内容寻址资产，置入矩形拉伸绘制（最近邻，诚实边界）；
- 文档：uuid/画布(可变，set-canvas 用)/dpi/profile("srgb")/layers/assets/params/next_layer_no。

## 4. `.mpd` 容器 v1（mpd/mpd.mbt）

```
foo.mpd (ZIP, deflate)
├── manifest.json        # format/version/engine/uuid/canvas/counts/fingerprint/asset_index（固定字段序）
├── meta/
│   ├── design.json      # 结构事实源（canonical：固定字段序 + 固定数字格式）
│   ├── params.json      # 命名元参数（纯元数据；live 绑定属下轮）
│   ├── vision.json      # 预览注册表 + 视觉锚点（本轮锚点为空占位）
│   └── agent.json       # 编辑历史摘要 + engine 版本
├── previews/flat.png    # 保存时渲染（长边 ≤2048）
├── previews/thumb.png   # 缩略图（长边 ≤512）
└── assets/sha256/<hash> # 内容寻址 PNG 资产（stored 条目）
```

**纪律**（全部有测试守护）：

- **确定性 pack**：固定条目顺序 + 固定 ZIP 时间戳（DOS 纪元）+ canonical JSON → 同状态两次 pack 字节一致、pack→unpack→pack 字节一致；
- **拒绝式 unpack**：垃圾/截断 ZIP、路径穿越（`..`/绝对路径）、逐条目 CRC、manifest 缺失/坏 format/前向版本、design.json 非法 UTF-8 或解析失败、**manifest 指纹与 design.json 实际 sha256 对账**、资产名字与字节 sha256 对账、文档引用的资产必须存在、限额复检；
- **限额**：单边 ≤30000、总像素 ≤1e8、层 ≤10000、meta 层总量 ≤4MiB、单资产 ≤512MiB；
- **原子落盘**（cli）：完整写 `<path>.mpd-tmp` → `rename`；Windows rename 失败时退化为覆盖写（窗口期已知，README 注明）。

## 5. 视觉多模态交互协议（agent/session.mbt）

- **vision 闸**：除 `help`/`session-open`/`list-tools` 外的一切命令都要求已 `session-open full_image`；其他声明（text_only 等）被明确拒绝并附三条出路；
- **双通道闭环**：读元参数（list-layers/query-layer/list-params）→ 拟命令 → 应用（闸 + 零容忍参数校验 + 快照）→ `render`（取景 PNG b64 + sha256）→ 校验（pick/stats 给客观数值，模型看图判断）→ commit（save-mpd）；
- **编辑唯一写入通道是元参数层的结构化命令**——保证 canonical、可撤销、可门禁；视觉通道负责 grounding 与验收；
- 归一化坐标协议：viewport 用 `[0,1]` 表述，消除分辨率歧义；
- P0–P2 谓词（lint）：画布限额（P0）、重复 id/幽灵资产引用（P1）、零尺寸/完全越界/opacity 越界（P2）。

## 6. 命令集（34 个；字典 = agent/tools.mbt 单一事实源）

会话：`session-open` `list-tools` `help`；文档：`new` `set-canvas` `list-layers` `query-layer` `lint`；
绘制：`add-rect/ellipse/polygon/line` `add-image`（b64）`set-style` `move` `resize` `rotate` `rename` `tag` `delete` `visible` `reorder` `group` `ungroup`；
元参数：`list-params` `set-param`；视觉：`render` `pick` `stats`；
历史/容器：`fingerprint` `edits` `undo` `redo` `save-mpd-b64` `open-mpd-b64`；
cli 专属：`save-mpd <path>`（原子落盘）`open-mpd <path>` `:exit`。

## 7. 远期路线（本轮明确不做，排期见 PLAN.md §8）

- **P4 蒙版**（栅程/矢量/live）、**P5 调整层**（levels/curves/hue_sat…）、文本层、贝塞尔、图层样式 fx、多色渐变/径向渐变；
- **PSD L1 读 → L3 写**（PSD 为第一公民，Photopea 天然覆盖）、AI（PDF 层）导入、Sketch/XCF/KRA；原文保全策略（source/ 层）；
- MCP server / WASM 面向宿主、SKILL.md、mpdView 只读查看器（ddpView 模式）、collab 合并、变体（fork/score/merge）；
- 动态 Huffman、16/32-bit、色彩管理（本轮 sRGB 恒定）。

## 8. 风险与已知边界

- 固定 Huffman 压缩率一般（deepOffice 同款，可接受）；
- 2×2 子采样 AA 是"够用"级：椭圆/斜线边缘在 1px 尺度可见锯齿（golden 锁定当前行为，升级 AA 需同步更新 golden）；
- 大画布全量渲染 + 取景后再缩放（简单正确优先）；4096 渲染护栏；
- Windows 原子写退化路径存在窗口期（README 已注明）；
- params 为纯元数据（无 live 绑定）——DESIGN 与 README 双处声明。

## 附录：与家族的协同

moonviz（PNG 编码器、行协议、会话纪律）、deepOffice（ZIP/DEFLATE/inflate、FFI 模式、容器纪律）、
Compositor（格式纪律与能力参照）。三者出处均在源文件头注明。
