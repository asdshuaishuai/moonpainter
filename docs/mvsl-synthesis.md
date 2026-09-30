# MVSL 多源评审比对结论（Gemini / DeepSeek / Claude / ChatGPT，共 8 份）

## 一、四方共识（无需再议，直接采纳）

1. **定位重写**：全部一致——MVSL 作为「非破坏式编辑程序 IR / 调整栈 + 参数化蒙版」成立；作为「任意图像的通用视觉源语」过度承诺。真增量不是图像数学，而是：selector=可序列化谓词、人机同一 IR、AI 感知-行动 affordance 闭环、bit-exact 契约。建议定名「agentic deterministic image-editing IR」。
2. **census/render/sample 三件套不够**：四方全判「不成立」。公认第一缺口 = selection overlay + 数值证书（覆盖率/bbox/连通域/ΔE）。
3. **软边界是第一视觉失败点**：smoothstep 软权重场 [0,1]、guided filter 边缘对齐（O(N) 盒滤波、几十行）、边界带去污染（否则蓝边变紫边）。共识公式：所有 op = out = lerp(in, op(in), w)，w∈[0,1]。
4. **HSV 不胜任「保明暗」**：三方独立指向 OKLab/OKLCh（V 不是感知亮度：纯绿 Y≈0.72 vs 纯蓝 Y≈0.07）。HSV 降级为 selector affordance field；recolor 必须显式声明 luma_definition + gamut_policy（clip/compress）。
5. **选择子求值基准必须写进 IR**：默认对 immutable base 求值（可重放、GUI 可开关中间 op），显式标注才允许 STAGE(n)。Claude 与 ChatGPT 互相独立列为第一优先级。
6. **AI 不当色度计、render 不是 verifier**：数值收敛靠确定性指标（区域 ΔE、泄漏率、覆盖率、diff report）+ 断言机制；VLM 只做语义判断（「选中的是不是头发」）。Gemini 的「VLM 对小色差敏感」归因被三方一致驳回。
7. **AI 语义必须编译成确定性证据**（种子点/负样本/几何/颜色约束，可进 canonical JSON），不能引用不透明模型输出；算子语义、selector 算法（freqSel 的 kernel/window！）、色彩语义分别版本化。
8. **最小验证方法论**：mock agent「3 轮」被三方否决（混淆了表达力/affordance/agent 能力三者，且去掉了 VLM 噪声这个最大风险源）；改为真实 VLM + affordance 消融 + 客观指标（IoU/泄漏率/ΔE/交互成本/回滚数）。

## 二、冲突点与裁决

| 冲突 | 各方立场 | 裁决 |
|---|---|---|
| 替代架构 | Gemini：wasm 下全排除 / 其余三家：太绝对 | 排除「神经当像素执行器」；「neural proposer → MVSL 确定性执行器」混合架构合法（宿主侧可微拟合参数→输出编辑表） |
| 区域级 census | Gemini 提议 / DeepSeek-B 要求强制 / Claude-B 指出循环依赖（AI 得先定位区域，而定位正是 VLM 最弱项） | 采纳 components(selector_mask)：引擎从实际 selector 推导连通域事实（编号/bbox/质心/面积/均值色）+ 编号叠加图（set-of-marks），AI 选 ID 不报坐标；census 加 within= 参数 |
| probe 形态 | 单点被批（DeepSeek-B/Claude-B：抗锯齿/噪声欺骗）vs ChatGPT 升级方案 | batch probe：多点 + 5×5 邻域统计（均值/方差/边缘置信度）+ 各选择子 membership + 所属连通域 ID |
| mask 预览的地位 | Gemini：控制信号 / ChatGPT：降级为人/VLM inspection，certificate 才是 agent 的控制信号 | 并存分工：数值 certificate 给 agent 做闭环，overlay 图给人/VLM 做语义确认；预览必须与终渲染同管线（先渲染后降采样，防细发丝丢失误判） |
| 照片场景进不进 v1 | DeepSeek-A：数据集一半照片 / Claude-A：照片需外部 mask 资产、纯颜色谓词必漏 / ChatGPT-A：50/50 但设「加语义 selector 即证伪」线 | v1 能力包络明示「动漫/图形优先」；照片走「外部 mask 作为内容寻址资产」口子（SAM 类分割结果导入为资产，选择子引用，引擎保持零依赖）——Claude 方案四方无异议 |
| 最小验证设计 | mock 3 轮（Gemini）/ 同色干扰真 VLM 5-8 轮（DeepSeek-B）/ 三组基线+消融（Claude）/ Phase A 引擎不变量 + Phase B 消融（ChatGPT） | 三阶段融合，见修订路线 P3 |

## 三、单源独有、被他家忽略的高价值点

- **Claude**：外部 mask 资产原语（照片场景承重墙）；guided filter 作引擎内置精修原语；**色温偏移与色相重映射是两个算子**（天空调暖用 hue remap 会变脏灰橙）；渐变 geoSel（地平线渐变需权重衰减）
- **ChatGPT-B2**：**append vs mutate**（AI 反复修正会堆叠 hue+=20，需 update_op(op_id)/稳定 edit_id——对闭环收敛比 probe 更重要）；alpha 语义（透明红像素会被 colorSel(red) 选中）；explain_pixel(x,y)
- **ChatGPT-B1**：性能=把内容寻址从存储设计升级为计算缓存架构（(base_hash,field_spec)→field_hash→selection cache→tile delta）；history log 与 current canonical program 分离；selector 算法也要版本 pin
- **DeepSeek-A**：颜色去污染 decontamination（I=αF+(1-α)B，只改 F）；「软边界不是模糊 mask」；12MP 软 mask <2s 的性能证伪线
- **ChatGPT-A**：终极证伪线——**如果不断新增 hairSel/skySel/skinSel 才能完成任务，说明 semantic-free 语言已偷变成语义分类 DSL，立即停**；MVSL 应成为 program induction 的目标语言而非竞争者；「render 是最后的视觉审查，不应是第一次发现 selector 错的地方」；edge-aware geodesic feather
- **DeepSeek-B**：set-of-marks + 参数敏感性（覆盖率有限差分）；同色异义干扰（红苹果 h=2° s=80% vs 红桌布 h=4° s=78%）是唯一真考题
- **Claude-B**：解码必须 wasm 内自实现（浏览器 JPEG IDCT/色度上采样不一致会破坏内容寻址）——本引擎 PNG 已自研解码满足；算子版本冻结悖论（bit-exact 意味 recolor@1 永不能修 bug→存渲染哈希+显式迁移）；编辑表参数定点整数化；**第 0 步选择子表达力上限测试**（无 AI 暴力搜索 colorSel+lumSel 对真值 mask 的 IoU，<0.9 则任何 AI 都救不了）
- **Gemini**（虽被批最多但地基是它的）：空间化观测三件套方向本身

## 四、对 MoonPainter 的可执行修订路线

对照引擎现状（canonical JSON+指纹、undo 快照栈、line 协议命令面=编辑表雏形、自研 PNG 编解码、sample/stats 命令、wasm SDK、人机同一协议）：

**P0 钉语义（纯规范，几乎不写新代码）**
1. IR 语义三决定写入容器 manifest：选择子求值基准=base；算子显式有序且 canonical 不重排；render contract version（色彩/数值/算子语义版本）。
2. 空编辑表逐位还原短路：无调整层时 render 直接返回 base 原像素（不经任何色彩变换）。导入路径已天然满足「canonical decoded buffer」定义——canvas 转 PNG 在导入时固化像素并内容寻址，base 身份即导入时像素而非原 JPEG 字节。

**P1 闭环 affordance（映射到现有命令面）**
1. select-preview：选择子 → overlay PNG + 覆盖率/bbox/连通域计数
2. census 升级：hue×sat 桶 + within= 选择子参数 + components()（union-find 连通域：id/bbox/质心/面积/均值色，纯数学）
3. probe 升级：batch + 5×5 邻域统计 + membership
4. dry-run/impact：执行前后 diff（改动像素数、目标区 ΔE、选区外泄漏率、热力图）——undo 栈里现成有 before 状态
5. assert 机制：保护区域 ΔE 阈值断言，信封直接 fail

**P2 算子与选择子**
1. recolor v1：OKLCh 色相重映射 + preserve=OKLab L + gamut compress + 色相环 smoothstep 软窗 + 饱和度/明度加权
2. guided filter 精修原语
3. component_of(colorSel, seed, ΔEtol) 种子连通域选择子
4. 选区精修 grow/shrink/feather/keep_largest
5. temperature/relight（与 recolor 明确分家）

**P3 最小验证（三阶段融合）**
- Phase 0 引擎不变量（无 AI）：identity / parse→canonicalize→render 重放 / undo 逐位回底 / A∘B≠B∘A 显式入规范
- Phase 1 表达力上限（无 AI）：colorSel+lumSel 暴力搜索 vs 真值 mask IoU ≥ 0.9，否则先改算子代数
- Phase 2 真 VLM 消融：合成对抗集（红苹果+红桌布 h 差 2°、双苹果、阴影偏棕、高光偏白）+ 30-50 张真值图；arms A0 census→A1 +preview→A2 +probe→A3 +components/种子→A4 +diff/assert；指标：IoU、泄漏率<1%、目标色相误差、轮数、token 成本；A4 易中难度 ≥80% 且显著优于 A0

**明确不做（四方共识）**：INR、生成式扩散进 renderer、VLM 当色度计、语言层绑 GPU（wasm SIMD 优先）、mock agent 当验证主体。

## 五、一句话定位

> MoonPainter MVSL = 面向 agentic image editing 的确定性声明式编辑 IR：不可变内容寻址底图 + 谓词选择子（软权重场）+ 有序算子程序 + AI 感知-行动 affordance，人机同一编辑表。v1 能力包络：动漫/图形语义换色优先；照片经外部 mask 资产进入。若发现自己在加 hairSel/skySel——停，抽象已走偏。
