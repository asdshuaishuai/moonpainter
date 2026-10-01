# MoonPainter v0.2 规划：MVSL 确定性图像编辑 IR

> 2026-09-30 定稿。基于 8 份外部评审（Gemini / DeepSeek×2 / Claude×2 / ChatGPT×3）
> 的多源比对结论，原文存于 `docs/mvsl-reviews/`，比对结论存于 `docs/mvsl-synthesis.md`。
> 本文档是把评审结论落到 MoonPainter 的执行规划。

## 0. 定位（评审后改口）

**MoonPainter MVSL = 面向 agentic image editing 的确定性声明式编辑 IR**：
不可变内容寻址底图 + 谓词选择子（软权重场 [0,1]）+ 有序算子程序 + AI 感知-行动
affordance，人机同一编辑表、同一撤销栈。

- **成立**：非破坏式编辑程序 IR、调整栈、参数化蒙版系统。
- **不再宣称**：「任意图像的通用视觉源语」——照片的颜色↔语义解耦决定了颜色谓词
  只能做辅助收窄，语义承重墙是空间/外部先验（见 §2 裁决 5）。
- **v1 能力包络**：动漫/图形（分片常数色 + 硬边）优先；照片经「外部 mask 资产」进入。
- **终极证伪线**（ChatGPT）：如果不断新增 hairSel/skySel/skinSel 才能完成任务，
  说明 semantic-free 语言已偷变成语义分类 DSL——立即停。

## 1. 四方共识（评审收敛的硬结论，直接采纳为设计纪律）

1. **真增量**不在图像数学（全是业界成熟件的重组），而在四件事：
   selector=可序列化谓词（可 diff/重放/跨分辨率）、人机同一 IR、
   AI 感知-行动 affordance 闭环、bit-exact 契约。
2. **软权重场**：选择子输出 [0,1] 隶属度而非布尔；所有算子
   `out = lerp(in, op(in), w)`。软边界 ≠ 模糊 mask：smoothstep 软窗
   （色相按环处理，注意 wrap-around）+ guided filter 边缘对齐 + 边界带去污染
   （`I = αF + (1-α)B` 只改 F，否则蓝边变紫边）。
3. **色彩空间**：弃 HSV「保明暗」（V 不是感知亮度：纯绿 Y≈0.72 vs 纯蓝 Y≈0.07）。
   recolor 在 OKLCh 改 h、preserve=OKLab L、chroma 做 gamut compress；
   HSV 降级为 selector/analysis affordance field。算子 IR 必须显式声明
   color_model / transfer_function / luma_definition / gamut_policy / alpha_policy。
4. **选择子求值基准写进 IR**：默认对 immutable base 求值（选区稳定、GUI 可开关
   中间 op、AI 语义不漂移），显式标注才允许 STAGE(n)。
5. **AI 不当色度计、render 不是 verifier**：数值收敛靠确定性指标
   （区域 ΔE、选区外泄漏率、覆盖率、diff report）+ 断言机制；VLM 只做语义判断。
6. **AI 语义必须编译成确定性证据**（种子点/负样本/几何/颜色约束，进 canonical
   JSON），不能引用不透明模型输出，否则 .mpd 退化为模型运行时 artifact。
7. **版本化**：算子语义版本、selector 算法版本（freqSel 的 kernel/window！）、
   色彩语义版本分别管理；旧引擎遇未知 op 拒绝而非静默错渲。
8. **affordance 三件套（census/render/sample）不够**：第一缺口是
   selection overlay + 数值证书（§3 P1）。

## 2. 冲突裁决（6 项）

| # | 冲突 | 裁决 |
| :- | :-- | :-- |
| 1 | 替代架构：Gemini 主张全排除 vs 其余主张保留 | 排除「神经当像素执行器」；**neural proposer → MVSL 确定性执行器**的混合架构合法（宿主侧可微拟合参数→输出编辑表） |
| 2 | 区域级 census 的循环依赖（AI 先要定位区域，而定位是 VLM 最弱项） | **components(selector_mask)**：引擎从实际 selector 推导连通域事实（编号/bbox/质心/面积/均值色）+ 编号叠加图（set-of-marks），AI 选 ID 不报坐标；census 加 `within=` 参数 |
| 3 | probe 形态 | batch probe：多点 + 5×5 邻域统计（均值/方差/边缘置信度）+ 各选择子 membership + 所属连通域 ID |
| 4 | mask 预览的地位 | 分工并存：数值 certificate 给 agent 做闭环，overlay 图给人/VLM 做语义确认；预览与终渲染同管线（先渲染后降采样，防细发丝丢失误判） |
| 5 | 照片场景进不进 v1 | v1 包络明示动漫/图形优先；**外部 mask 作为内容寻址资产**（SAM 类分割结果导入为资产，选择子引用，引擎保持零依赖）是照片入口 |
| 6 | 最小验证设计 | 三阶段融合（见 §4 P3）；mock agent「3 轮证伪」废弃 |

## 3. 单源独有、必须吸收的点

- **Claude**：外部 mask 资产原语；guided filter 作引擎内置精修原语（O(N) 盒滤波）；
  **色温偏移与色相重映射是两个算子**（天空调暖用 hue remap 会变脏灰橙）；
  渐变 geoSel（地平线渐变需权重衰减）。
- **ChatGPT**：**append vs mutate**——AI 反复修正会堆叠 `hue+=20`，需要稳定
  edit_id + update_op（对闭环收敛比 probe 更重要）；alpha 语义（透明红像素会被
  colorSel(red) 选中，spec 必须定义 alpha≈0 的处理）；explain_pixel(x,y)；
  性能=把内容寻址从存储设计升级为计算缓存架构
  （(base_hash, field_spec)→field_hash→selection cache→tile delta）；
  history log 与 current canonical program 分离；selector 算法版本 pin。
- **DeepSeek**：去污染 decontamination；12MP 软 mask <2s 的性能证伪线；
  同色异义干扰（红苹果 h=2°/s=80% vs 红桌布 h=4°/s=78%）是唯一真考题。
- **Claude-B**：**第 0 步选择子表达力上限测试**（无 AI 暴力搜索 colorSel+lumSel
  对真值 mask 的 IoU，<0.9 则先改算子代数）；解码必须 wasm 内自实现
  （本引擎 PNG 已满足；算子版本冻结悖论：bit-exact 意味着算子实现永不能改，
  需存渲染哈希 + 显式迁移）；编辑表参数定点整数化；预览与终渲染不一致风险。
- **ChatGPT-A**：终极证伪线（见 §0）；MVSL 应成为 program induction 的
  目标语言而非竞争者；「render 是最后的视觉审查，不应是第一次发现 selector
  错的地方」；edge-aware geodesic feather（发丝/树枝级边缘）。
- **明确不做**（四方共识）：INR、生成式扩散进 renderer、VLM 当色度计、
  语言层绑 GPU（wasm SIMD 优先，GPU 只是可选后端）、mock agent 当验证主体。

## 4. 执行路线（对照引擎现状）

现状可用地基：canonical JSON + SHA-256 指纹、undo 快照栈、line 协议命令面
（= 编辑表雏形）、自研 PNG 编解码、sample/stats 命令、wasm SDK、
人机同一协议（GUI 操作与 AI 工具调用同走 agent.exec）。

### P0 钉语义（纯规范，几乎不写新代码）

1. IR 语义三决定写入容器 manifest：
   - 选择子求值基准 = base（显式标注才允许 STAGE(n)）；
   - 算子显式有序，canonical 化不得重排（canonical JSON = 序列化契约，
     不是语义规范化）；
   - render contract version（色彩/数值/算子语义版本），旧引擎遇新版本拒绝。
2. 空编辑表逐位还原短路：无调整层时 render 直接返回 base 原像素。
   （导入路径已天然满足 canonical decoded buffer 定义：canvas→PNG 在导入时
   固化像素并内容寻址，base 身份即导入时像素而非原 JPEG 字节。）
3. 编辑表参数定点化或固定格式化数值（沿用 fmt_num 纪律，禁 -0/NaN 入容器）。

### P1 闭环 affordance（映射到现有命令面）

1. `select-preview`：选择子 → overlay PNG + 覆盖率/bbox/连通域计数
   （数值证书 + 图一并返回）。
2. `census` 升级：hue×sat 桶 + `within=` 选择子参数 + `components()`
   （union-find 连通域：id/bbox/质心/面积/均值色，纯数学）。
3. `probe` 升级：batch + 5×5 邻域统计 + membership + component id。
4. `dry-run/impact`：执行前后 diff（改动像素数、目标区 ΔE、选区外泄漏率、
   变化热力图）——undo 栈里现成有 before 状态。
5. `assert` 机制：保护区域 ΔE 阈值断言，命令信封直接 fail
   （「别动人物」从自然语言愿望变成机器可验证约束）。

### P2 算子与选择子

1. `recolor` v1：OKLCh 色相重映射 + preserve=OKLab L + gamut compress +
   色相环 smoothstep 软窗 + 饱和度/明度加权 + 边界带去污染。
2. guided filter 精修原语（盒滤波积分图实现）。
3. `component_of(colorSel, seed, ΔEtol)` 种子连通域选择子。
4. 选区精修原语：grow/shrink/feather/fill_holes/keep_largest。
5. `temperature`/`relight`（与 recolor 明确分家）。

### P3 最小验证（三阶段融合）

- **Phase 0 引擎不变量（无 AI）**：identity（空程序逐位还原）/
  parse→canonicalize→render 重放 / undo 逐位回底 / A∘B≠B∘A 显式入规范并有测试。
- **Phase 1 表达力上限（无 AI）**：colorSel+lumSel 暴力搜索 vs 真值 mask
  IoU ≥ 0.9，否则先改算子代数，不怪 AI。
- **Phase 2 真 VLM 消融**：合成对抗集（红苹果+红桌布 h 差 2°、双苹果、
  阴影偏棕、高光偏白）+ 30–50 张带真值图；arms
  A0 census → A1 +preview → A2 +probe → A3 +components/种子 → A4 +diff/assert；
  指标：IoU、选区外泄漏率 <1%、目标色相误差、交互轮数、token 成本；
  门槛：A4 易/中难度成功率 ≥80% 且显著优于 A0，中位 ≤4 轮。

## 4.5 实施进度（每轮更新；未勾选 = 尚未落地）

### P0 钉语义 —— 已完成（含渲染管线闭环）

- [x] 编辑表 IR（core/mvsl.mbt）：选择子/算子/断言 + canonical JSON 双向；
      求值基准默认 `base`、显式 `stage:n` 且**拒绝前视引用**；
      算子顺序即语义、canonical 化不重排；`MVSL_IR_VERSION` /
      `RENDER_CONTRACT_VERSION` / `SELECTOR_ALGO_VERSION` /
      `COLOR_SEMANTICS_VERSION` / `OP_SEMANTICS_VERSION` 五个版本 pin。
- [x] 空编辑表逐位还原短路（`run_program` 在 ops 为空时直接返回 base 本身）。
- [x] 参数定点格式化：复用 `@core.fmt_num`（禁 -0/NaN 入容器），
      并做范围校验（amount/hue/temp/gain/refine 半径与 eps）。
- [x] **编辑表接进渲染管线**：`render/depends-on/pixel`（`pixel ← render`，
      AGENTS 铁律 5 / DESIGN §2 已同步）。语义钉死为
      `最终图 = apply(program, 层合成底图)`：
      · 新增 `render_layers`（层合成底图，编辑表求值与渲染的唯一基准）、
        `render_doc_with` / `render_view_with` / `render_view_overlay_with`；
      · **先全画布求编辑表，再裁剪缩放**——取景只是观看方式，不该改变
        选择子语义；`render_view_impl` 本就"先全画布渲染再缩放"，插入点天然；
      · 空编辑表走与"没有编辑表"逐位相同的代码路径（`ops` 为空时
        `run_program` 直接返回 base）→ 既有 golden 与 open→save 字节一致
        断言不受影响；
      · `previews/`、`render`、`stats`、`sample` 全部改用最终图
        （视觉通道不能给模型看底图）；
      · 静态校验补齐：算子**前视 `stage:` 引用**（`n > 自身序号`）与
        **带 `stage:` 基准的保护断言**都在 `validate_program` 期拒绝——
        前者留到执行期会变成"命令面收下了、渲染时才失败"，后者在旧实现里
        声明与实际求值基准不一致（静默按 base 求值），比直接拒绝更坏。
      · 不变量测试：`render/mvsl_render_test.mbt`（空程序逐位等价 / 只在
        命中区改变 / 取景不改语义 / 坏程序报错 / 重复渲染幂等）+
        `agent` 端「render ≡ impact ≡ 容器预览 三条出口同一张图」。

### P1 闭环 affordance —— 部分完成

- [x] `select-preview`：选择子 → overlay PNG（洋红软覆盖）+ 覆盖率/bbox/
      连通域事实（id/bbox/质心/面积/均值色/环平均色相）。**先全分辨率生成
      overlay 再盒平均降采样**（防发丝级软边界被抹掉误判）。
- [x] `mvsl-impact`：逐算子 diff 证书（改动像素数 / 平均与最大 ΔE /
      目标区 ΔE / 选区外泄漏率）+ 结果 PNG。
- [x] `mvsl-assert`：保护断言违反 → 命令信封直接 fail 并带全部明细。
- [x] 编辑表随容器持久化（`meta/mvsl.json` + manifest `mvsl` 版本块，
      容器升版 v2，篡改/半截状态/更高 render contract 一律拒绝）。
- [x] `census` 升级：hue×sat 桶（12×3）+ `within=` 选择子参数 +
      `components()` 事实；附 OKLab L 与 HSV V 均值**对照**（V 不是感知亮度）。
- [x] `probe` 升级：5×5（`r≤32`）邻域统计 + 环平均色相 + 边缘置信度 +
      当前编辑表每个算子/断言在该点的 membership 与 component id。
      **批量入口也已落地**：`points=x1,y1;x2,y2;…`（上限 64 点）返回数组，
      每点字段与单点模式逐字段一致。~~单命令多点的批量入口尚未加~~——这句
      在这里挂了很久，而代码与测试（`agent/affordance_test.mbt` 的
      `probe points=5,5 r=3`）早就在了：**进度表也会烂，且没有任何门禁看着它**。

### P2 算子与选择子 —— 部分完成

- [x] `recolor`（OKLCh 改 h、preserve OKLab L、gamut 在 chroma 上收、
      softstep 软窗、环距）、`temperature`（蓝↔黄轴，与 recolor 分家）、
      `relight`（L 增益）。
- [x] guided filter 精修原语（盒滤波积分近似，O(N)）。
- [x] `component_of(colorSel, seed, ΔEtol)` 种子连通域选择子。
- [x] 选区精修：grow/shrink/feather/fill_holes/keep_largest。
- [x] `recolor` 的边界带去污染（`I = αF + (1−α)B` 只改 F）——**已解决**：
      用 `layer=<id>` 作用域把该层单独栅格化到透明底再变换（α 在那里重新
      出现），见 `render/mvsl_render_test.mbt` 的「边界去污染」测试与
      PLAN.md 补遗九。~~未做~~ 是这句话过期了，不是能力过期。
- [ ] 参数化蒙版系统（矢量蒙版 roughen/feather 与 MVSL 选择子的统一）。
- [x] **层集合作用域 `layer=@<标签>`**（标签当活选层器）：`expand_layer_scopes`
      在执行时把 `@标签` 展开成"带该标签的每层各一份算子"（层序即顺序）；
      渲染/`mvsl-impact`/`mvsl-assert`/`lint` 共用这一处判断；落不到任何层
      一律拒绝（入口 + 渲染 + lint 三道闸），事后摘掉标签由 `mvsl_resolved`
      先拒后展开、`lint` 报 P4。**这一条同时补上了标签缺失的消费者**，并覆盖
      了本文件「下一步」原先的第 1 条里"只作用于某几个图层"那半边。

### P3 最小验证 —— 部分完成

- [x] **Phase 0 引擎不变量**（无 AI）：identity（空程序逐位还原）/
      parse→canonicalize→render 重放逐位一致 / undo 逐位回底 /
      A∘B≠B∘A 显式入规范并有测试 / 色相环 wrap-around / 软窗单调性。
- [x] **Phase 1 表达力上限**（无 AI）：colorSel 暴力搜索 vs 真值 mask，
      IoU ≥ 0.9 门槛（pixel/mvsl_wbtest.mbt）。
- [ ] **Phase 2 真 VLM 消融**：合成对抗集（红苹果+红桌布 h 差 2°、双苹果、
      阴影偏棕、高光偏白）+ 30–50 张带真值图；arms A0→A4；门槛
      A4 易/中难度成功率 ≥80% 且显著优于 A0，中位 ≤4 轮。

### 下一步（按价值排序；每次对照代码与测试，别信这张表本身）

1. **`stage:n` 的图层粒度与跨作用域顺序**：`stage:n` 现在只切到"算子序号"
   （第 n 个算子之后的全画布中间缓冲），而"只作用于某几个图层"已由
   `layer=@<标签>` 覆盖（**层集合**粒度，见 P2）——仍未解决的是：
   ①`stage:n` 取"某一层的中间缓冲"；②跨作用域的**相对顺序**（一条文档级算子
   无法插在两条图层级算子中间，两段式渲染的代价，DESIGN §8 已声明）。
2. **参数化蒙版系统**：矢量蒙版 roughen/feather 与 MVSL 选择子统一（P2 唯一
   未勾选的那条；`layer=@标签` 与它是两件事——前者选**层**，这里选**像素**）。
3. Phase 2 的对抗集与消融实验（需要真实 VLM）。
4. ~~`recolor` 边界带去污染~~ / ~~`probe` 单命令多点批量入口~~：**都已落地**
   （见上方勾选表），留在这里是为了记住"清单本身也会烂"。

## 5. 风险清单（评审原话摘要，实现时对照自查）

- 预览与终渲染不一致（低分辨率预览丢发丝 → 同管线渲染后再降采样）。
- 8-bit 逐步量化累积误差 → 管线内浮点、末端一次量化、分块=整图逐位一致。
- HSVL 浮点场内存（24MP ≈ 384MB）→ 惰性派生/量化存储。
- 编辑表膨胀成「操作录像带」→ history log 与 canonical program 分离。
- 人机并发：AI 一轮多步 = 原子撤销组；中途人工编辑需锁或分支。
- 巨大编辑表/恶意谓词 DoS → 限额护栏（沿用 mpd 拒绝式校验纪律）。
