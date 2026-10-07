# 产品记分卡（由 `scorecard.py` 从 `scorecard/areas.toml` 生成，别手改）

> 口径：**每条目一个状态三档**（已做 / 部分+声明边界 / 未做）+ 一个**唯一命中**的源码锚点（锚点腐烂就红）+ 可选门禁 slug。「未做」不是待办埋伏，是**写下来的能力边界**——它的条数就是roadmap 的长度。生成命令：`python3 scorecard.py`；门禁：`python3 scorecard.py --check`（生成结果必须与提交的这份逐字节相同）。

## 汇总

| 域 | 条目 | 已做 | 部分 | 未做 |
| :-- | --: | --: | --: | --: |
| 画布与文档 | 5 | 4 | 0 | 1 |
| 绘制与图层 | 10 | 8 | 1 | 1 |
| 路径、文本与蒙版 | 8 | 4 | 1 | 3 |
| MVSL 编辑表 | 9 | 6 | 3 | 0 |
| 命令面与工程纪律 | 9 | 9 | 0 | 0 |
| 容器与互操作 | 6 | 4 | 0 | 2 |
| 人类界面（AI 修图 demo） | 9 | 8 | 0 | 1 |
| 性能、确定性与可复现 | 7 | 7 | 0 | 0 |
| **合计** | **63** | **50** | **5** | **8** |

## 现场量的数字（现算，不手写）

| 指标 | 值 | 来源 |
| :-- | --: | :-- |
| 引擎命令面（字典条数） | 71 | floors.toml ← verify.sh#catalog |
| native 测试条数 | 462 | floors.toml ← verify.sh#catalog |
| wasm-gc 测试条数 | 460 | floors.toml ← verify.sh#catalog |
| 变异条数 | 293 | floors.toml ← verify.sh#catalog |
| 被抓住的变异 | 290 | floors.toml ← verify.sh#catalog |
| 人类可达命令 | 71 | floors.toml ← ui_audit.py |
| 人类够不着的命令（目标 0） | 0 | floors.toml ← ui_audit.py |
| AI 工具面条数 | 61 | floors.toml ← build_demo.sh#doc-tools |
| AI 刻意够不着的命令 | 10 | floors.toml ← build_demo.sh#doc-tools |
| （命令, 键）配对 | 204 | floors.toml ← key_effect_audit.py |
| 有读取点的配对 | 204 | floors.toml ← key_effect_audit.py |
| **收了却没人读的键（目标 0）** | 0 | key_effect_audit.py 现场量 |
| 对抗性参数 fuzz 行数 | 5761 | floors.toml ← panic_hunt.py |
| 浏览器自检项 | 30 | floors.toml ← build_demo.sh#selfcheck |
| 点击贯通断言 | 107 | floors.toml ← build_demo.sh#clickthrough |
| 可点处理器 | 85 | floors.toml ← build_demo.sh#clickthrough |

> **别把接线计数当能力**：AI 工具 60 条 / 人类可达 70 条说的是「有没有入口」，一个入口背后可能只是"回一个错误"；行为由`verify.sh` 与 `build_demo.sh` 的各步钉住，而"参数收了没人读"这类空壳由 `key_effect_audit.py` 现场数。

## 分域明细

### 画布与文档

文档记账尺寸与渲染上限是两件事，两个数都要报出来（`canvas` / `render`）。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| 新建 / 改画布 / 裁剪：AI 与人类两侧都有入口 | 已做 | `agent/session.mbt#cmd_crop` · `build_demo.sh#doc-tools` | `new`/`set-canvas`/`crop` 三条命令都有按钮；`crop` 同步平移全部层。 |
| 渲染上限（单边 4096）：入口拒绝 + lint 兜手改容器 | 已做 | `render/scene.mbt#render_limit_error` | 容器允许单边 30000/总量 1e8，渲染器只画 4096；超限 `new`/`set-canvas` 直接拒并说清。 |
| 旧引擎/超限容器：打开只知会、不拒绝（留自救路） | 已做 | `agent/session.mbt#load_mpd` | `open-mpd` 报 `notice` 而不是拒开——拒开等于连「打开自己的文件再 crop」都做不到。 |
| 16/32-bit、CMYK、线性空间 | 未做 | `render/scene.mbt#clamp8` | 整条管线是 8-bit sRGB：`clamp8` 是唯一量化点，没有 16-bit/32-bit 缓冲、没有 CMYK、没有色彩管理。 |
| 资产内容寻址 + 只打包被引用的字节 | 已做 | `core/document.mbt#prune_unreferenced_assets` | assets/sha256/<hash>；删掉图片层后再存，孤儿字节不进容器（会话登记簿只增，撤销要把字节还回来）。 |


### 绘制与图层

「有面」的层（矩形/椭圆/多边形/线段/路径/位图）与非面层（文本/笔触/调整/组）走不同的读点矩阵。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| 矩形（圆角）/椭圆/线段/多边形 + 纯色/线性渐变填充 | 已做 | `render/scene.mbt#inside_fill` | AA 真的参与混合；渐变端点归一化 0..1（写像素会被入口拒并给换算值）。 |
| 描边：只实现了矩形/椭圆/线段 | 部分 / 有声明边界 | `render/scene.mbt#inside_stroke` | 多边形/位图/文本/笔触/调整层/组上写 `stroke=`/`stroke_w=` 会被入口拒；`stroke_w ≥ 半短边` 变实心块（lint 报）。 |
| 7 种混合模式 + 透明度 | 已做 | `render/scene.mbt#blend_buffer` | normal/multiply/screen/overlay/darken/lighten/difference（W3C 公式）；属性面板只给有面的层画下拉。 |
| 旋转 / 翻转（含组、文本、笔触三类） | 已做 | `render/scene.mbt#frames_for` | 字形逐点过变换链、dab 过变换链、组的变换作用到整棵子树；象限角取精确值（90°/180°/270°）。 |
| 组 α = 先合成成组画面再打折（SVG `<g opacity>` 语义） | 已做 | `render/scene.mbt#effective_opacity` | 重叠区不再被混合两次；组盒子 = 成员并集且实时派生。 |
| PNG 位图导入 + 原地换图（`set-image`） | 已做 | `agent/session.mbt#cmd_set_image` | 盒子跟着内容走（不给 w/h 时盒 = 资产像素尺寸）；换图不动层序/蒙版/标签/透明度/翻转/旋转。 |
| 布尔运算（并/差/交/异或 → 新路径层，洞用反选蒙版） | 已做 | `agent/bool_cmds.mbt#cmd_bool_op` | 操作数被结果替换（留着会让洞看不见）；共线部分重叠明确拒绝；每个岛最多一个洞。 |
| 调整层：亮度/对比度/饱和度/模糊/锐化/色阶/曲线… + 原地改 | 已做 | `agent/session.mbt#cmd_set_adjust` | 叠加式像素算子，作用于其下全部可见层；蒙版覆盖度 × α 连续生效；不参与变换/混合（入口拒）。 |
| 图层样式 fx：投影 / 描边 / 外发光 / 内阴影 | 已做 | `render/scene.mbt#apply_fx` | 层自己像素的一部分：先整层栅格化到自己的缓冲 → 在覆盖度场（`Field`）上做四件套 → 最后**一步**乘 opacity/blend（先乘会把半透明层的描边算没）。场的工作窗按层**实际范围 + 扩散量**裁（`fx_reach`），与整画布逐位相同；半径上限 64 由 `fx_param_error` 一处判、渲染器显式夹住。边界：不做样式各自的混合模式/渐变描边/多重叠影，`Adjust` 层没有样式（入口拒、lint 报）。 |
| 自由笔刷（笔压、形状动态、笔尖贴图） | 未做 | `agent/session.mbt#cmd_brush` | `brush` 只有圆头、恒定半径与浓度；没有笔压/动态/贴图，也没有画笔预设。 |


### 路径、文本与蒙版

共同规则：**盒子跟着内容走**（路径按采样包围盒、文本按字形占位盒、笔触按落笔范围）。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| 钢笔/贝塞尔路径（锚点 + 控制柄，原地改 handles） | 已做 | `core/path.mbt#path_samples` | 采样规则只有一处：预览（`path-preview`）与落定不可能不一致；闭合 = `fill_closed` 一处判定。 |
| 路径二次编辑（加/删锚点）、形状转路径、路径文字、SVG/AI 导入 | 未做 | `agent/session.mbt#cmd_set_style` | `set-style points=` 只能整表替换顶点；不能在路径上加/删锚点、不能把已有形状转成路径。 |
| 文本：ASCII 点阵字形（无 CJK、无字体文件） | 部分 / 有声明边界 | `render/scene.mbt#glyph_columns` | 字形表在 demo 侧；`rot`/`flip` 已生效，`query-layer` 报盒子而墨是字形（`text_ink` 与渲染共用一处）。 |
| 文本盒子跟着内容走 + `set-text` 原地改字号 | 已做 | `agent/session.mbt#text_box` | `add-text` 与 `set-text` 共用 `text_box`；显式 `w=`/`h=` 才固定；`lint` 兜「盒子装不下自己的文字」。 |
| 文本排版：对齐、行距、字距、自动换行 | 未做 | `render/scene.mbt#text_glyphs` | 一行直排、无对齐/字距/行距参数、无换行；多行文本只能拆成多个层。 |
| 几何蒙版：矩形/椭圆/多边形 + 圆角/羽化/毛化/反选 | 已做 | `core/document.mbt#mask_param_error` | 参数判据一处（入口与 lint 共用）；`set-mask` 是全参数的部分更新；软边与选择子共用 `pixel.soft_cover`。 |
| 栅格蒙版（画笔涂抹）、live mask（引用下层 alpha） | 未做 | `render/scene.mbt#mask_cover_at` | 蒙版只有几何的：`mask_cover_at` 只认 rect/ellipse/polygon + invert。 |
| 语义标签：可打可摘，并作为 MVSL 的层作用域（`layer=@tag`） | 已做 | `core/mvsl.mbt#expand_layer_scopes` | 展开只有一处（渲染/impact/assert/lint 共用）；活绑定在**执行时**展开，落不到任何层则拒绝。 |


### MVSL 编辑表

确定性声明式编辑 IR：`最终图 = apply(编辑表, 层合成底图)`，三条出口同一张图。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| canonical IR：往返幂等 + 前向版本拒绝 | 已做 | `core/mvsl.mbt#validate_program` | 旧引擎遇未知算子/更高版本一律拒绝；`program_sha256` 单一实现。 |
| 选择子：色彩/几何/渐变/连通域/外部资产 + Union/And/Diff 组合 | 已做 | `core/mvsl.mbt#validate_sel` | 全部输出 [0,1] 软权重场；颜色走 OKLCh/OKLab（HSV 只做分析对照）。 |
| 算子 recolor/temperature/relight：`out = lerp(in, op(in), w)` | 已做 | `pixel/edit.mbt#apply_op` | 软权重混合、量化与羽化都有测试守着；分析出口与渲染共用 `render.impact_stages`。 |
| 选区精修：grow/shrink/feather/fill_holes/keep_largest/guided | 已做 | `pixel/edit.mbt#apply_refines` | 精修在软权重场上做，`guided_refine` 用引导滤波（不引第三方库）。 |
| 保护断言：`mvsl-assert` 违约即命令信封 fail | 已做 | `agent/mvsl_cmds.mbt#cmd_mvsl_assert` | 「别动人物」变成机器可验证约束；判定与渲染走同一段执行代码。 |
| `stage:n` 按表序、被引用者必须同段且严格在前 | 已做 | `core/mvsl.mbt#segment_ops` | 段内重编号由引擎一处完成；判据在 `layer=@tag` 展开之后的表上跑。 |
| 跨作用域的**相对顺序不保留** | 部分 / 有声明边界 | `core/mvsl.mbt#program_for_layer` | 声明的边界：一条文档级算子无法插在两条图层级算子中间（两段式执行的必然结果）。 |
| 编辑表内存代价：**只报不拦**（产品决定） | 部分 / 有声明边界 | `core/mvsl.mbt#edit_peak_bytes` | 时间护栏隐含 ≈2.4–2.9 GB 峰值；`est_peak_bytes` 报出来但刻意不拦（收紧旋钮见 DESIGN §性能）。 |
| 外部 mask 资产：只引用，引擎不内置任何分割模型 | 部分 / 有声明边界 | `core/mvsl.mbt#validate_atom` | 未登记的资产报精确错误、不降级；没有任何内置模型或启发式「自动抠图」。 |


### 命令面与工程纪律

命令面是产品的唯一操作面：AI 与人类都走它，散文里的数字由门禁对账。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| 命令字典（`agent/tools.mbt`）与分发同步，`list-tools` 每条真实可调 | 已做 | `agent/session.mbt#tools_json` · `verify.sh#catalog` | 字典是 LLM 唯一的说明书；`help`/`list-tools`/README 名单全部从它出。 |
| 字典 ↔ 解析器参数对账（承诺的 `key=` 必须真的认） | 已做 | `agent/ops.mbt#check_kv_args` · `verify.sh#params` | 键清单只有一个事实源；读不出键表/命令名不是字面量 → 判失败而不是静默跳过。 |
| 「收了却没人读的键」审计（行为式：配对四个出口） | 已做 | `key_effect_audit.py#main` · `verify.sh#scorecard` | 每个（命令, 键）配对跑两遍比回包/指纹/层表/render sha；全都没变 = 空壳。现测 187 对，死键 0。 |
| 参数零容忍：认不出的键 / 越界的值 / 用不上的值都在入口拒 | 已做 | `agent/ops.mbt#check_kv_names` · `verify.sh#params` | 「用不上的参数」也在入口拒（例：`census components=` 没有 `within=` 时、`erase color=`）。 |
| 对抗性参数 fuzz：全部命令 × 敌意语料只回错、不崩 | 已做 | `panic_hunt.py#main` · `verify.sh#panic-hunt` | 断言退出码 0 + 每行恰好一条 JSON 回包 + stderr 无 panic；红了二分指名那一行。 |
| 变异门 + 锚点自检（「测试全绿」不等于「行为被守护」） | 已做 | `mutation_scan.py#main` · `verify.sh#anchors` | 287 条变异、284 条被抓住、3 条已确认等价；INVALID/UNKNOWN 都判失败（不是「通过」）。 |
| 字段可改性门禁：每个 `Layer` 字段都有「建层之后改得动」的命令 | 已做 | `field_audit.py#main` · `verify.sh#fields` | 改不动的只能声明为身份字段（id/kind）；「暂时没做」不算理由，那是能力边界。 |
| 能力表 `caps`：某命令对这个 kind 的画面有没有效果，引擎一处算 | 已做 | `agent/ops.mbt#layer_caps` | 界面只按它画控件；对照测试要求「说有 ⇒ 画面变，说没有 ⇒ 逐位相同」。 |
| lint（P0–P3）+ 编辑表 lint：装了却什么都不干的状态必须报 | 已做 | `agent/session.mbt#cmd_lint` | 空组/空文本/非文本层带 text 字段/白装算子/违约断言；kind 专属字段是一张表，不加手写 if。 |


### 容器与互操作

`.mpd` 双层结构（元参数 JSON + 内容寻址资产）是唯一事实源。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| .mpd pack/unpack 全环 + 确定性 pack（两次打包字节一致） | 已做 | `mpd/mpd.mbt#pack` · `verify.sh#roundtrip` | 手写 ZIP/DEFLATE/PNG/SHA-256 底座（自有 MIT）；open→save 字节一致有断言。 |
| 原子落盘（tmp + rename）+ 八类拒绝路径全测试 | 已做 | `agent/session.mbt#pack_current` | CRC / 指纹对账 / 前向版本拒绝 / 限额 / 路径安全；`unpack` 拒绝式校验。 |
| 前向版本拒开：`render_contract` 按用到的新字段升档 | 已做 | `core/document.mbt#required_render_contract` | 旧引擎静默错渲比拒绝更坏；负控：只带亮度层的容器仍是第 1 档。 |
| previews/{flat,thumb}.png：保存时自动渲染（含编辑表） | 已做 | `mpd/mpd.mbt#preview_png` | 预览与 `render` 同一张图（编辑表是渲染的最终一遍）。 |
| PSD 读写（真实 .psd：图层/蒙版/混合/文本/样式） | 未做 | `agent/session.mbt#cmd_save_b64` | 落盘格式只有 `.mpd`；没有 PSD 解析/写出，也没有语料级往返对账（③ 的目标）。 |
| SVG / AI / 其他位图格式的导入导出 | 未做 | `agent/session.mbt#cmd_open_b64` | 导入只有 PNG（8-bit RGB/RGBA/灰非交错）与 `.mpd`；导出只有 `.mpd` 与 PNG。 |


### 人类界面（AI 修图 demo）

界面是命令面的**手写子集**：有按钮 = 真的发得出那条命令，失败要把引擎的拒绝原话摆出来。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| 人类可达命令 = 引擎命令（名单有门禁、每条写理由） | 已做 | `ui_audit.py#main` · `build_demo.sh#doc-tools` | 命令名不许插值拼（对账看不见 = 等于没有入口）；`引擎 − 人类可达 = 0`。 |
| 点击贯通：用哑 DOM 壳加载真的 demo.js 调处理器，再从引擎读回状态 | 已做 | `demo/clickthrough.mjs#check` · `build_demo.sh#clickthrough` | DOM 本身仍需浏览器（边界写清）；壳只保证「跑得下去 + 状态真的变了」。 |
| 人类侧入口一律回显引擎的拒绝原话（不静默失败） | 已做 | `demo/main.mbt#do_ui_cmd` | 蒙版/编组/父级/层序/删除/可见统一走一个入口；静默失败的入口比没有入口更坏。 |
| 属性面板只按引擎 `caps` 画控件（不抄 kind 名单） | 已做 | `demo/main.mbt#caps_of` | 没有的能力画成带理由的只读回显；`caps` 缺失时一个能力控件都不画并明说。 |
| 步骤历史面板（点一行 `goto` 跳回，未来步骤画成灰行可重做） | 已做 | `agent/session.mbt#cmd_goto` | 跳回复用 undo/redo 原语；跳回后再操作会丢掉后面的步骤（PS 语义）。 |
| 画布上的自由变换（Ctrl+T：一个手势 = 一条 `transform` = 一步历史） | 已做 | `agent/session.mbt#cmd_transform` | 手柄画不画由 `caps` 说了算（文本/笔触/调整层只画框、不画缩放手柄）。 |
| 图层样式 fx 的属性面板（投影/描边/发光/内阴影） | 已做 | `demo/main.mbt#props_html` | 四件套的开关与参数都由 `props_html` 按 `query-layer` 报出的样式面画控件，点击走 `do_ui_cmd`（同一条 `set-fx` 命令，没有旁路）；`panel_html_wbtest` 直接调纯函数断言控件存在，`clickthrough` 用哑 DOM 调处理器再从引擎读回。 |
| 文本排版面板（对齐/行距/字距/换行） | 未做 | `demo/main.mbt#refresh_props` | 现在面板只给文本层画内容与字号两个控件。 |
| 浏览器内自检（30 项）：工具面 + MVSL 闭环真的可达 | 已做 | `demo/selfcheck.mbt#selfcheck_cases` · `build_demo.sh#node-headless` | 自检项是浏览器里真跑一遍引擎的清单（工具面/MVSL 闭环/分析出口），不是接线计数。 |


### 性能、确定性与可复现

「能跑起来」与「跑得对」之外，还有「换个时间跑还是这个数」。

| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |
| :-- | :-- | :-- | :-- |
| 三个指纹各指一件事：design.json / 编辑表 / 渲染产物 | 已做 | `core/json.mbt#fingerprint` | `fingerprint`（编辑表变了它不变）/ `program_sha256` / `render_sha256`（缓存失效认它）。 |
| 渲染确定性：golden sha256 锁定 + 无时间戳/随机数/哈希序 | 已做 | `render/scene.mbt#render_doc_with` · `verify.sh#roundtrip` | 空编辑表必须走与「没有编辑表」逐位相同的代码路径（不许分叉）。 |
| 性能数字只许脚本写账本、文档只许引用 | 已做 | `bench_ledger.py#main` · `verify.sh#catalog` | `bench/ledger.json` 是唯一来源；重跑标定会让文档变红，直到回来改数字。 |
| 性能标定**不进任何门禁**（量的是墙钟时间，换机器就变） | 已做 | `bench_perf.py#selfcheck` | 标定脚本自带对照组与前提自检；会因机器慢而红的门禁只会被人 `|| true` 掉。 |
| 编辑表时间护栏：判乘积（算子数 × 像素数）并回显两个量 | 已做 | `core/mvsl.mbt#edit_cost_error` | ≈2 µs/(像素·算子) ≈ 400 秒；只有一个限额常量，时间内存同降。 |
| 代价拒绝对渲染路径也生效（不是只在 `mvsl-set` 拦） | 已做 | `render/scene.mbt#edit_cost_refusal` | 同一句判据的执行点在渲染侧也有一份调用——判据本身只有一处实现。 |
| 单调地板：命令/测试/变异/入口/配对数只许抬不许降 | 已做 | `floors.py#main` · `verify.sh#catalog` | 下调必须配**本次新增**的 `[[retired]]` 并写理由——等号门禁管不住「改文档追平退化」。 |
