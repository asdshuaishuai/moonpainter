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
交互    agent（54 命令 · vision 闸 · undo/redo · P0–P2 lint · MVSL 闭环 · 工具字典）
容器    mpd（pack/unpack · manifest/params/agent/mvsl · 指纹对账 · 限额 · 预览生成）
渲染    render（RGBA 画布 · 2×2 子采样 AA · W3C 混合 · 旋转 · 取景 · pick · stats）
核心    core（IR 层树 · canonical JSON 双向 · 指纹 · 层定位原语 · MVSL 编辑表 IR）
编辑    pixel（选择子软场 · 有序算子程序 · 数值证书 · 覆盖预览 · OKLab/OKLCh）
基座    codec（ZIP 读写 · DEFLATE/inflate · PNG 编解码 · 颜色） + base（SHA-256）
```

依赖严格单向无环：`base ← codec ← core ← pixel ← render ← mpd ← agent ← cli`。

`render` 依赖 `pixel`：MVSL 编辑表是渲染的**最终一遍**
（`最终图 = apply(program, 层合成底图)`）。三个约束：
- `pixel` 绝不反向依赖 `render`（选择子/算子是纯数值层，不认识图层）；
- 编辑表的求值基准是**层合成底图**（`render_layers`），不是上一次的最终图——
  否则编辑表会自己吃自己，重复渲染不再幂等；
- 空编辑表必须与"没有编辑表"走**逐位相同**的代码路径（`run_program` 在
  `ops` 为空时直接返回 base），既有 golden 与 open→save 字节一致断言才不受影响。

## 3. IR 文档模型（core/document.mbt）

- 层类型：`Rect / Ellipse / Line / Polygon / Image / Group`；
- 层属性：id/name/visible/opacity(0..1)/blend/x/y/w/h/rotation_deg/corner_radius/points/fill/stroke/asset_hash/tags/children；
- 填充：`NoFill / Solid(#AARRGGBB) / LinearGradient(c0,c1,x0,y0,x1,y1 局部 0..1 端点)`；
- 层序 = 数组序自底向上；Group 以 children 嵌套，直通合成（组只传递可见性/透明度，组级混合不生效——诚实边界）；
- Image 层引用 `assets/sha256/<hash>` 内容寻址资产，置入矩形拉伸绘制（最近邻，诚实边界）；
- 文档：uuid/画布(可变，set-canvas 用)/dpi/profile("srgb")/layers/assets/params/next_layer_no。

## 4. `.mpd` 容器 v2（mpd/mpd.mbt）

```
foo.mpd (ZIP, deflate)
├── manifest.json        # format/version/engine/uuid/canvas/counts/fingerprint/mvsl/asset_index
├── meta/
│   ├── design.json      # 结构事实源（canonical：固定字段序 + 固定数字格式）
│   ├── params.json      # 命名元参数（纯元数据；live 绑定属下轮）
│   ├── vision.json      # 预览注册表 + 视觉锚点（本轮锚点为空占位）
│   ├── agent.json       # 编辑历史摘要 + engine 版本（**轨迹**）
│   └── mvsl.json        # 当前 MVSL 编辑表（canonical program，**状态/渲染真值输入**）
├── previews/flat.png    # 保存时渲染（长边 ≤2048）
├── previews/thumb.png   # 缩略图（长边 ≤512）
└── assets/sha256/<hash> # 内容寻址 PNG 资产（stored 条目）
```

**v1 → v2 升版理由**：MVSL 编辑表是渲染的真值输入。若只追加条目而不升版，
不认识它的旧引擎会「打开成功但少渲染一批编辑」——正是 PLAN-MVSL 明令禁止的
静默错渲。升版后旧引擎按「版本高于支持范围」在入口直接拒绝。

manifest 的 `mvsl` 版本块 pin 住四个独立版本号（`render_contract` /
`selector_algo` / `color_semantics` / `op_semantics`）与 `program_sha256`：
**选择子算法变了，微调过的编辑表会漂移**，所以算法版本必须随容器走、
不匹配即拒绝，而不是「尽量渲染」。

**纪律**（全部有测试守护）：

- **确定性 pack**：固定条目顺序 + 固定 ZIP 时间戳（DOS 纪元）+ canonical JSON → 同状态两次 pack 字节一致、pack→unpack→pack 字节一致；
- **拒绝式 unpack**：垃圾/截断 ZIP、路径穿越（`..`/绝对路径）、逐条目 CRC、manifest 缺失/坏 format/前向版本、design.json 非法 UTF-8 或解析失败、**manifest 指纹与 design.json 实际 sha256 对账**、资产名字与字节 sha256 对账、文档引用的资产必须存在、限额复检；
- **MVSL 拒绝式 unpack**：`meta/mvsl.json` 非 canonical 形式、manifest `program_sha256` 与编辑表字节对账失败、更高 `render_contract`、`selector_algo`/`color_semantics` 与引擎不符、manifest 声明了 `mvsl` 却缺条目（或反之）——半截状态一律拒绝；
- **限额**：单边 ≤30000、总像素 ≤1e8、层 ≤10000、meta 层总量 ≤4MiB、单资产 ≤512MiB；
- **原子落盘**（cli）：完整写 `<path>.mpd-tmp` → `rename`；Windows rename 失败时退化为覆盖写（窗口期已知，README 注明）。

## 4.5 MVSL 编辑表（core/mvsl.mbt + pixel/）

**定位**：面向 agentic image editing 的确定性声明式编辑 IR —— 不可变内容寻址
底图 + 谓词选择子（软权重场 [0,1]）+ 有序算子程序 + AI 感知-行动 affordance。
规划与 8 份外部评审的比对见 [PLAN-MVSL.md](./PLAN-MVSL.md)。

- **选择子**：`color`（OKLCh 色相**环** + 饱和度 + 亮度三维软窗）/`luma`（OKLab L，
  **不是** HSV V）/`geo`（rect 到**边界**的距离/ellipse）/`geograd`/`comp`
  （种子连通域，同色异义干扰的出口）/`assetmask`（外部 mask 资产，引擎零依赖）；
  组合 `Union`(max)/`And`(prod)/`Diff`(clamp 差)，组合后仍是软场；
- **算子**：`recolor`（OKLCh 改 h、preserve OKLab L、gamut 在 chroma 上收）/
  `temperature`（蓝↔黄轴平移，与色相重映射**明确分家**）/`relight`（L 增益）；
  一律 `out = lerp(in, op(in), w)`，`w=0` 处逐位保持原像素（零泄漏）；
- **精修**：`grow/shrink/feather/fill_holes/keep_largest/guided`（guided filter
  把颜色谓词得到的软场对齐到图像真实边缘）；
- **语义三决定**：求值基准默认 `base`（显式 `stage:n` 才允许，且**拒绝前视引用**）；
  算子顺序即语义（canonical 化只做序列化契约，**绝不重排**）；版本化拒绝；
- **数值证书**：覆盖率 / bbox / 连通域事实（id/bbox/质心/面积/均值色/环平均色相）/
  ΔE / 选区外泄漏率；AI 当色度计禁止，收敛判据全部是确定性数值；
- **affordance 命令**：`select-preview`（overlay PNG + 证书）、`mvsl-impact`
  （逐算子 diff 证书 + 结果 PNG）、`mvsl-assert`（保护断言，违反即信封 fail）、
  `mvsl-set/show/clear`。`base = 层合成底图`（`render_layers`，
  **不含**编辑表本身），由文档指纹隐式内容寻址，信封回传 `base_sha256`
  供显式 pin；
- **区域级事实（破除循环依赖）**：`census`（hue×sat 12×3 桶 + OKLab L 与
  HSV V 均值对照； `within=<sel>` 时附覆盖率/bbox/连通域事实）与 `probe`
  （单点 r≤32 邻域：OKLab 均值/方差、环平均色相、边缘置信度 = 中心差分
  梯度 / 0.25 L·px⁻¹；外加**当前编辑表每个算子与断言在该点的 membership
  与所属连通域 id**）。连通域 id 由 `pixel` 的标签场给出，与 `components()`
  共用同一趟栅格序扫描——用 bbox 做包含判断在重叠时会指错；
- **覆盖预览顺序**：**先全分辨率生成 overlay，再盒平均降采样**——反过来会把
  发丝级软边界平均掉，VLM 看到干净背景就判「没选中」；
- **在渲染管线里的位置**：编辑表是**文档级的最终一遍**
  （`最终图 = apply(program, 层合成底图)`，`render_doc_with` / `render_view_with`
  / `render_view_overlay_with`）。三条约束见 §2；三条出口
  （`render` / `previews/` / `mvsl-impact`）必须给出**同一张图**，
  `verify.sh` 第 7 步把 `render` 与 `mvsl-impact` 的 sha256 相等做成硬断言。
  取景顺序不可交换：**先全画布求编辑表、再裁剪缩放**——选择子定义在画布坐标里，
  先裁剪会让同一条选择子在不同取景下命中不同的东西；
- **静态校验不留给运行期**：算子的前视 `stage:` 引用（`n > 自身序号`）与带
  `stage:` 基准的保护断言都在 `validate_program` 期拒绝。前者留到执行期会变成
  "命令面收下了、渲染时才失败"；后者在旧实现里声明与求值基准不一致
  （`check_guards` 静默按 base 求值），声明与行为不符比直接拒绝更坏。

## 5. 视觉多模态交互协议（agent/session.mbt）

- **vision 闸**：除 `help`/`session-open`/`list-tools` 外的一切命令都要求已 `session-open full_image`；其他声明（text_only 等）被明确拒绝并附三条出路；
- **双通道闭环**：读元参数（list-layers/query-layer/list-params）→ 拟命令 → 应用（闸 + 零容忍参数校验 + 快照）→ `render`（取景 PNG b64 + sha256，**已含 MVSL 编辑表**）→ 校验（pick/stats/sample/census/probe 给客观数值，模型看图判断）→ commit（save-mpd）；
- **视觉通道给的是最终图**：`render`/`stats`/`sample`/`previews/` 一律渲染
  「底图 + 编辑表」。让模型看底图等于让它基于错图决策；
- **编辑唯一写入通道是元参数层的结构化命令**——保证 canonical、可撤销、可门禁；视觉通道负责 grounding 与验收；
- 归一化坐标协议：viewport 用 `[0,1]` 表述，消除分辨率歧义；
- P0–P2 谓词（lint）：画布限额（P0）、重复 id/幽灵资产引用（P1）、零尺寸/完全越界/opacity 越界（P2）。

## 6. 命令集（56 个；字典 = agent/tools.mbt 单一事实源）

会话：`session-open` `list-tools` `help`；文档：`new` `set-canvas` `list-layers` `query-layer` `lint`；
绘制：`add-rect/ellipse/polygon/line` `add-image`（b64）`set-style` `move` `resize` `rotate` `rename` `tag` `delete` `visible` `reorder` `group` `ungroup`；
元参数：`list-params` `set-param`；视觉：`render` `pick` `stats` `census` `probe`；
修图：`add-paint` `brush` `erase` `crop` `sample` `add-adjust` `add-mask` `set-mask` `remove-mask`；
MVSL：`mvsl-set` `mvsl-show` `mvsl-clear` `select-preview` `mvsl-impact` `mvsl-assert`；
历史/容器：`fingerprint` `inspect` `edits` `undo` `redo` `save-mpd-b64` `open-mpd-b64`；
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
- params 为纯元数据（无 live 绑定）——DESIGN 与 README 双处声明；
- MVSL 编辑表是**文档级的最终一遍**，不是图层：能改整张合成图，但还不能
  "只作用于某几个图层"或参与图层内部的混合序。要那种粒度得先有把图层
  单独栅格化的中间缓冲（`stage:` 基准目前只切到"算子序号"，不切图层）；
- MVSL 的 `probe` 单命令多点批量入口未加（多次 `probe` 可覆盖同一需求）；
- MVSL 的 `recolor` 边界带去污染（`I = αF + (1−α)B`，只改 F）未做：
  当前几何硬边 + 去污染已使选区外泄漏率为 0，但半透明边缘的混色未分离；
- 外部 mask 资产只能引用：引擎不内置分割模型，未登记即报精确错误（不降级）；
- 软 mask 的 12MP < 2s 性能证伪线尚未实测（当前实现是逐像素 + O(N) 盒滤波，
  未做分块/惰性派生，见 PLAN-MVSL §5 风险清单）。

## 附录：与家族的协同

moonviz（PNG 编码器、行协议、会话纪律）、deepOffice（ZIP/DEFLATE/inflate、FFI 模式、容器纪律）、
Compositor（格式纪律与能力参照）。三者出处均在源文件头注明。
