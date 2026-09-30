# MVSL 视觉源语 · 外部评审汇总

> 已收录 8 份（Gemini×1、DeepSeek×2、Claude×2、ChatGPT×3）；等待更多内容，用户说「完毕」后做多源比对

---

## 1. Gemini（匿名直连，Flash-Lite）



Gemini 说

这是一个极具野心且工程审美极高的架构设想。用纯 MoonBit、零依赖在 Wasm 中跑一个声明式的图像编辑引擎，并将「人类 GUI」与「AI Agent」收敛到同一份不可变的编辑表（Edit Table IR）上，这个切入点在当前的 Web 生态中非常硬核。

以下从图像计算专家与软件架构评审的角度，直接给出犀利、无保留的判断：

一、 抽象成立吗？是重新组合还是真增量？

架构抽象本身：完全成立。
「Base Bitmap（不可变内容寻址） + 状态无关算子程序 ＝ 渲染结果」这是现代高性能图形学、不可变数据结构（Immutable Data Structures）与现代云原生编辑器（如 Figma 的 Scene Graph 思想）在像素级计算上的完美落地。“无损靠构造而不是逼近”这个推论在数学上站得住脚，能够彻底根除传统像素软件“多次反复保存导致累积量化误差”的行业病。

关于增量性质：这是精妙的“工程重组”，而非颠覆性数学突破。
你罗列的选择子（色相、亮度、超像素、频率层）和算子（recolor, relight, smooth）在 Photoshop、Lightroom、Halide 或 Nuke 节点图中全部都能找到原型。真正的增量价值在于：

统一控制面（Unified Control Plane）： 把人类的鼠标拖拽和 AI 的 Token/Tool Call 同时编译成完全同构的纯 JSON 编辑表。人类和 AI 拥有平等的编辑特权和同一个 Undo/Redo 栈，这在 AI 原生软件中极为罕见。

纯 Wasm / 零依赖的契约： 放弃重型第三方库，用 MoonBit 的强类型和内存可控性在前端实现极高密度的像素操纵。

二、 主要盲点与失败模式（Failure Modes）

纯“统计普查（Census）”对 AI 来说是严重的信息盲区：

问题： 如果 AI 拿到的只是一个 colorSel x lumSel 的全局统计桶（比如“色相在 30-40 度的像素占 15%”），AI 完全不知道这些像素在哪里。它是衣服、皮肤、还是背景的落叶？

后果： AI 在做 recolor 时极易引发全局误伤。由于缺乏空间上下文，AI 会变成“盲人摸象”，只能靠不断瞎猜参数、反复渲染来试错。

选择子（Selector）边界的“硬切”与边缘瑕疵：

问题： 纯谓词选择（如阈值分割）如果没有空间连续性约束（Spatial Coherence）或边缘羽化（Feathering / Guided Filter），做 recolor 或 relight 时会产生灾难性的边界锯齿（Aliasing）和杂边（Halos）。

AI 闭环的非收敛性（Limit Cycles）：

问题： 图像调整往往是非线性的。如果 AI 仅凭视觉反馈（看渲染图）去迭代，由于视觉大模型对像素级微小差异（如皮肤色相偏移 2 度）的量化感知不稳定，AI 很容易在几轮调整后陷入“过矫正—回调—再矫正”的死循环。

三、 census + render 够不够？还缺什么关键 Affordance？

不够。 只有 Census 和 Render，AI 就像一个蒙着眼睛的调音师。要让 AI 高效、优雅地修图，必须补齐以下关键 Affordance（交互富集度）：

1. 空间与区域热力图指针（Spatial Mask Thumbnails）：
当 AI 激活某个 regionSel 或 colorSel 时，系统必须能返回一个低分辨率的黑白遮罩预览（Mask Preview）或区域中心坐标，让 AI “看见”这个选择子到底圈住了哪里。

2. 语义锚点（Semantic Probes）：
AI 需要能够下发如 probe_point(x, y) 的指令，直接读取特定坐标处的局部色相、饱和度、亮度值，而不是只能面对全局直方图瞎猜。

3. 局部直方图 / 区域采样：
允许 AI 指定对某一个超像素（Superpixel）或几何区域（GeoSel）单独做 Census，而不是整张图的全局 Census。

四、 替代架构的务实评估

在客户端 Web 环境下，其他替代架构的落地阻力远大于你的方案：

可微光栅化（Differentiable Rendering / 类似 PyTorch 架构）：

评估： 理论上最优雅（AI 可以直接通过反向传播梯度一步算出来需要调整多少参数），但在纯 Wasm / 浏览器端落地属于自寻死路。计算整张图的梯度开销极大，且 MoonBit 生态目前不具备成熟的自动微分张量库。

隐式神经表示（INR / NeRF-like MLP）：

评估： 对修图场景是“大炮轰蚊子”。模型训练慢、无法做到像素级确定性控制、对低端设备硬件要求高，违背了“轻量、实时、全可见”的初衷。

程序归纳式编辑器（Program Induction）：

评估： 类似于让 AI 直接写一段完整的像素级滤镜代码。极难调试，且一旦 AI 生成了有 Bug 或死循环的循环体，Wasm 引擎直接崩溃。

结论： 你的「声明式不可变 IR + 算子程序」是目前唯一兼顾工业界传统图形学可靠性与AI Agent 友好性的正确架构。

五、 最小验证实验（MVE）设计

如果要用最短的时间（比如 1-2 周）来证明或证伪这个方向，建议不要一上来就做全套 GUI 和大而全的算子，而是做一个硬核命令行/Web Console 闭环验证：

算子与底层（MoonBit）：

实现一个固定大小的 RGBA 底图加载器、HSVL 色彩空间转换。

实现单一算子：recolor(colorSel(hue_range), target_hue)。

数据契约（IR）：

写死一个 Canonical JSON 的 Edit Table 结构。

AI 闭环代理测试（Mock Agent Loop）：

给定一张图和一个自然语言指令：“把图里偏红的苹果调成绿色，但别动周围的桌子”。

测试点： 编写一个极简的 Agent 脚本（可以接 Claude/GPT 的 Function Calling）：

Agent 调用 get_field_census()。

Agent 根据 Census 确定 colorSel 的阈值。

Agent 写入 Edit Table 并调用 render()。

丢给 VLM（视觉大模型）一张“原图 vs 渲染图”的对比或只看渲染图，让它评估是否达成目标，决定是否输出第二步。

证伪标准：

如果在 3 轮内，AI 无法在没有任何空间信息辅助的情况下，精准定位并只改动目标物体而不污染其他区域，说明 Census 严重信息缺失。此时必须立刻引入上述的 Spatial Mask/Regional Census，否则整个 AI 闭环无法成立。

这个 MVE 能够直接切中你架构中最核心的风险点（AI 与算法的耦合度），用最低的沉没成本跑通最关键的技术路径。

登录即可关联到 Google 应用、制作图片等等
登录




Flash-Lite

Gemini 是一款 AI 工具，其回答未必正确无误。

---

## 2. DeepSeek-A 盲评

总判断：**作为“非破坏性编辑程序 IR”，这个抽象成立；作为“任意图像的可编辑源语”，它不成立，至少被你说大了。**  
MVSL 本质上是把业界已有的调整层、蒙版、hue-vs-hue、亮度蒙版、频率分离、超像素选择，统一成一份确定性 op 列表，再加一套 AI 可调用的 affordance。理论增量很小，工程/交互增量可能很大。真正值钱的是“人机同一 IR + 零依赖 wasm + AI 可见工具调用闭环”，不是“视觉源语”这个新表示。

---

## 1. 抽象成立吗？与业界关系？

**成立的部分：**
- `base + 有序 op 列表` 作为非破坏编辑模型，成立。这就是调整层/节点图/智能滤镜的另一种编码。
- 空编辑表逐位一致，靠构造无损。这个很容易，也很重要，但**不是理论突破**。只要容器保存原始资产，空程序直接返回原字节即可。
- 选择子输出 mask，算子作用于 mask 内，这是标准做法。
- 人机操作编译到同一 IR、同一 undo 栈，产品上很有价值。

**不成立的部分：**
- “任意图像转成可编辑源语言”是过度承诺。像素谓词不是对象，不能恢复遮挡、材质、反照率、光照、透明、运动模糊。你只能做“可参数化重渲染”，不能把照片变成可理解的场景图。
- “选择子正交”不成立。colorSel、lumSel、regionSel、freqSel 高度相关。颜色和亮度相关，频率和区域相关，组合顺序、权重、软边界都影响结果。
- “全部逐像素纯数学”不准确。模糊、锐化、频率分离、磨皮、引导滤波、超像素、连通域都不是逐像素，必须有邻域/全局步骤。
- HSL/HSV 不够。蓝改红保留明暗，在 HSL 里会 gamut clipping，感知亮度会跳。应上 OKLab/OKLCh，色相重映射保持 L，色度按 gamut 压缩。

**与业界关系：**
- hue-vs-hue：PS/LR 已有。
- 亮度蒙版：已有。
- 频率分离：商业修图已有。
- Lab 曲线：已有。
- 超像素/连通域：OpenCV/scikit-image 已有。
- 你的 MVSL 是这些的**重新组合 + canonical IR + AI 工具化**。不是新图像表示，也不是新的计算摄影理论。真增量在“AI agent 能逐步调用、全程可见、同一 IR、零依赖 wasm”。

**结论：** 保留架构，但定位改成“非破坏性程序化调整栈 + AI 可操作蒙版系统”。别叫通用视觉源语。

---

## 2. 主要盲点与失败模式

### 2.1 选择子边界溢色/杂边，零依赖怎么做软边界？

布尔谓词一定锯齿。必须让选择子输出连续权重 `[0,1]`，不是 true/false。零依赖可行路线：

1. **硬 mask → 距离变换羽化**：最简单，但会半透明，背景色会混进来。对头发、树枝、毛发不够。
2. **引导滤波/联合双边**：用原图做 guide，把硬 mask 变成边缘对齐软 mask。零依赖可用积分图实现盒滤波版 guided filter，O(1) 近似，wasm 可行。
3. **拉普拉斯 matting / 随机游走**：在边界带解稀疏线性系统，用共轭梯度。质量好，但大图慢，wasm 内存和性能要测。
4. **颜色去污染**：边界带估计前景 F、背景 B、alpha，解 `I = αF + (1-α)B`。只改 F，不改 B。否则蓝发边缘会留蓝边，改红后变紫边。
5. **限制作用域**：recolor 只在色度通道改，保持亮度/细节。蓝→红时，先转 OKLCh，改 h，c 做 gamut map，L 尽量不动。边界带降低修改强度。

**关键：软边界不是模糊 mask。模糊 mask 会把背景拉进来。必须做 alpha matte + 颜色去污染，至少做引导滤波 + 边界带抑制。**

### 2.2 语义靠 AI 视觉供给的可靠性

不可靠。多模态模型能说“把天空调暖”，但给不出稳定像素级谓词。census 是全局统计，不能区分天空和蓝衣服。sample(x,y) 太稀疏。AI 容易幻觉：以为选了头发，其实选了眼睛/背景。

必须把 AI 限制在：
- 提出候选参数；
- 根据 mask overlay、局部 crop、统计反馈修正；
- 不直接生成像素，不直接写最终 mask。

人类必须能随时接管 mask。否则“AI 逐步修图”会变成“AI 随机试参数”。

### 2.3 AI 看 render 自查迭代的收敛性风险

有风险，而且不小。
- 视觉自评对全局色调还行，对边界溢色、半像素杂边、局部污染不敏感。
- 连续参数空间容易震荡：色相范围调大→误选，调小→漏选。
- 多轮迭代会累积错误，尤其频率分离和磨皮。
- 模型可能迎合提示，说“已自然”，但实际肤色已偏。

缓解：
- 每轮返回 mask overlay、边界带放大、diff 图、区域直方图。
- 限制迭代次数，保存每轮 IR，可选最佳。
- 最终必须人类确认，或至少可一键回退。
- 对关键区域设量化指标：目标区 ΔE、非目标区 ΔE、边界带色相残留。

---

## 3. census + render + sample 够不够？

**不够。缺了 mask 作为一等公民。**  
census 是全局桶，不定位。render 是全图，AI 看不清边界。sample 是单点，不能理解区域。闭环不成立。

分级：

**缺了闭环就不成立：**
1. **mask 预览与编辑**：overlay、透明度、边界带 crop。AI 必须看到“我选了哪里”。
2. **mask 正负样本/涂鸦/框选**：geoSel 不能只是手画范围，还要正负点、笔刷、连通域选择。
3. **区域统计**：选区内的色相/饱和度/亮度直方图、均值、方差、边界像素统计。
4. **局部 crop/zoom**：头发边缘、人物轮廓、天空与建筑交界。
5. **diff 图**：改前改后差异，最好按 ΔE 或色度差异着色。
6. **确定性 mask id / 参数 IR**：AI 说“把刚才那个 mask 收缩 2px”，系统要能引用。

**缺了只是低效：**
- 参数扫描缩略图：一次生成 5 个色相偏移。
- 超像素预计算、连通域缓存。
- 频率分离预览。
- 自动白平衡/曝光建议。
- 矢量示波器/波形图。
- 批量试色。

**一句话：AI 修图不是缺“看全图”，是缺“看蒙版和边界”。**

---

## 4. 替代架构：可微光栅化、INR、程序归纳

在 wasm/浏览器 + 零依赖约束下：

**可微光栅化：值得作为辅助，不值得作为核心。**
- 可用于拟合连续参数，比如白平衡、曲线、局部调整强度。
- 但选择子是离散的，mask 阈值不可微；编辑表是离散 op 序列，梯度帮不上。
- WebGPU/WGSL 在 MoonBit wasm 里绑定成本高，确定性、字节一致、跨浏览器兼容都麻烦。
- 结论：如果有 WebGPU，可做“参数优化器”；没有就排除核心。

**隐式神经表示 INR / NeRF：明确排除。**
- 每图训练，浏览器 wasm 不现实。
- 编辑不直观，无法保证空编辑字节一致。
- 对 2D 修图收益低，成本高。
- 它适合 3D/新视角，不适合你的非破坏 IR。

**程序归纳式编辑：作为 agent 规划可以，作为架构核心排除。**
- 从 before/after 学 op 序列，样本少、泛化差。
- 你的 AI 已经可以用工具调用做规划，不需要再学一个程序归纳器。
- 除非做研究，否则不要碰。

**扩散生成/神经风格：排除。**
- 违反无损、确定性、可回退、字节一致。
- 会重绘内容，不是修图。

---

## 5. 最小验证实验与证伪标准

**实验目标：** 证明或证伪“AI 通过 MVSL 谓词 + 软 mask + 算子，能稳定完成两个场景”。

**最小实现：**
- base 内容寻址，空编辑字节一致。
- OKLab/OKLCh 转换。
- 选择子：colorSel、lumSel、regionSel（连通域）、geoSel（正负点）。
- 软 mask：距离变换羽化 + 引导滤波 + 边界带去污染。
- 算子：recolor（保 L 改 h）、relight（色温/曝光）。
- 工具：census、mask overlay、区域直方图、局部 crop、diff、sample。
- AI agent 或模拟 agent，最多 8 次工具调用。

**数据集：**
- 15 张动漫蓝发角色，背景简单/复杂各半。
- 15 张照片，天空偏冷，含人物/蓝色衣物干扰。

**指标：**
- 空编辑是否逐位一致。
- 目标区色相改变是否达预期，明暗保留 ΔL。
- 非目标区 ΔE 中位数。
- 边界带蓝/青残留比例。
- AI 工具调用次数、是否收敛。
- 12MP 图单次软 mask + render 耗时。

**证伪标准：**
1. 简单案例 AI 成功率 < 60%，或需要 > 10 次调用仍边界失败。
2. 非目标区 ΔE 中位数 > 3–5，尤其人物肤色/衣服被污染。
3. 边界带色相残留肉眼明显，引导滤波+去污染也压不住。
4. census + sample 不能把候选 mask 缩到 < 20% 图，必须逐像素涂。
5. 12MP 软 mask 单次 > 2s，wasm 零依赖不可接受。
6. AI 看 render 自查无法发现明显边界错误，闭环不成立。

**如果出现 1、2、4 同时成立，架构错了：** 它不是通用可编辑源语，只是高级调整层 + 手动蒙版工具。

---

## 6. 两个目标场景的理想工具调用序列

### 场景 A：动漫角色蓝头发改红，保留明暗

期望序列：

1. `load` + `render` 缩略图。
2. `field_census`：看色相×饱和度桶，确认蓝发色相范围，但知道可能有背景蓝。
3. `colorSel`：蓝青范围，生成候选 mask。
4. `mask_preview`：返回 overlay + 边界带 crop + 统计。
5. 若误选眼睛/背景：`regionSel` 取最大连通域，或 `geoSel` 正负点排除。
6. `soften_mask`：引导滤波 + 距离羽化，返回 alpha matte。
7. `freqSel`：分离基础/细节，只对基础层操作。
8. `recolor`：OKLCh 色相蓝→红，保持 L，色度 gamut map，边界带去污染。
9. `render_crop`：头发局部 + diff + 直方图。
10. 检查高光、蓝边、背景污染。调整色相范围/软度/去污染强度。
11. `commit` 到编辑表。

关键：不是直接 `recolor` 全图，而是先证明 mask 对。

### 场景 B：照片天空偏冷调暖，别动人物

期望序列：

1. `load` + `render` 缩略图。
2. `field_census`：看天空蓝青色相、亮度分布。
3. `colorSel`：蓝青 + `lumSel`：高光/中间调，生成天空候选。
4. `regionSel`：取顶部大连通域，排除人物衣服蓝色。
5. `mask_preview`：overlay + 人物边缘 crop + 统计。
6. 若人物轮廓被选：`geoSel` 负样本人物，或连通域排除。
7. `soften_mask`：边缘对齐软 mask。
8. `freqSel`：只改基础层，保留云细节。
9. `relight`：色温调暖，可能加轻度 `recolor` 去青。
10. `render` 全图 + `diff` + 人物肤色区域直方图。
11. 检查肤色 ΔE、衣服 ΔE、天空过渡。迭代参数。
12. `commit`。

关键：天空和蓝衣服同色，必须靠 regionSel/geoSel 空间排除。没有 mask 反馈，AI 一定会翻车。

---

## 最终建议

- **保留 MVSL 作为 IR**，但改定位：非破坏性程序化调整栈，不是通用视觉源语。
- **优先补 mask 一等公民**：overlay、正负样本、区域统计、边界 crop、diff。
- **色彩空间换 OKLab/OKLCh**，别用 HSL 做保明暗重映射。
- **软边界必须做引导滤波 + 去污染**，不能只羽化。
- **AI 只做参数提议和空间提示**，人类保留最终控制。
- **真增量在 AI 工具闭环 + 零依赖 wasm + 同一 IR**，不在图像处理理论。

如果非要一句话：**这个架构能做成好产品，但不能宣称成新图像表示。它是一套优秀的非破坏编辑 IR 和 AI 工具层，不是“任意图像的视觉源语”。**


---

## 3. DeepSeek-B 对抗审查（针对 Gemini）

Gemini 大方向可用，但有几处是把实现问题当架构必然、把前端问题当运行时问题、把弱工具使用当架构缺陷。

## 1. 我不同意的判断

**"替代架构在 wasm 约束下全部排除"太绝对。**  
可微光栅化、INR、程序归纳不一定要跑在 wasm 运行时里。它们可以作为宿主侧 AI 前端，负责生成 MVSL 编辑表；MVSL 只做可审计 IR、确定性渲染、人机同栈。排除它们作为运行时内核可以，排除它们作为编辑表生成器不行。反例：Python 侧用可微渲染拟合一组 recolor/relight 参数，输出 canonical JSON 编辑表，MoonBit wasm 只负责重放和交互。这仍然是 MVSL，不是替代。

**"选择子硬切边界产生锯齿杂边"不是架构必然。**  
选择子是谓词，但谓词输出不必是布尔。输出 [0,1] 隶属度，recolor 权重用 smoothstep/羽化，边缘就不会硬切。硬切只是二值化实现。反例：色相选择在目标 ±5° 内线性过渡，或对 alpha 边缘做引导滤波。零依赖 wasm 完全可做。把"二值选择子"的缺陷说成 MVSL 缺陷，是偷换。

**"AI 视觉闭环可能不收敛"归因错了。**  
VLM 不该做微小色差控制器。它应该做粗粒度语义定位和验收，数值收敛交给 census 距离、区域 ΔE、覆盖率、编辑表参数搜索。让 VLM 判断"苹果是否绿"通常稳定；让它判断 ΔE=1.5 的差别当然噪声大。反例：生成 4 张候选缩略图让 VLM 排序，比让它直接调参数收敛得多。不收敛往往是反馈信号设计差，不是架构必然。

**census 缺空间信息是正确观察，但不是架构失败。**  
全局色相×饱和 census 当然区分不了红苹果和红椅子。但架构里还有 regionSel/geoSel，问题应该变成"区域级 census 和选择子覆盖率是否强制返回"。如果 AI 只用全局 census，那是工具使用策略差，不是 MVSL 缺空间语义。反例：连通域分桶后每个区域给 bbox、质心、面积、h/s 统计，红苹果和红椅子立刻可分。

**"最小验证只做 recolor+h census+mock agent，证伪 3 轮内无空间辅助做不到精准定位"验证错了对象。**  
mock agent 没有真实视觉，当然证明需要空间辅助，这是稻草人。考题"红苹果调绿别动桌子"如果桌子不是红色，h census 可能就够；如果桌子是红色，才真正测试同色异义。3 轮也太武断，轮数不是稳定指标，误伤像素率、目标区域 ΔE、编辑表长度才是。

**"精妙工程重组而非数学突破"这个定性无关紧要，而且低估了形式化空间。**  
编辑表如果构成带作用域和顺序的偏序幺半群，选择子作为谓词代数，渲染作为 catamorphism，可逆性、交换性、冲突检测都能形式化。是不是"数学突破"不影响产品价值，但说它没有形式化潜力不准确。

## 2. 它漏掉的重要失败模式和设计维度

**多算子次序依赖与交换性。** recolor 保明暗、relight 改明暗、smooth 改边界。recolor→relight 与 relight→recolor 结果不同。canonical JSON 如果对算子排序，会破坏语义。编辑表必须显式有序，并定义哪些算子可交换、哪些作用域冲突、哪些可合并。

**色彩空间极端退化。** HSVL 在低饱和、暗部、高光、色相环绕处极不稳定。recolor 保明暗可能产生色域裁剪、肤色灾难、8bit 量化断层。需要明确 sRGB/线性/OKLab 策略，至少给色域映射和极端区域降权。

**canonical JSON 与浮点确定性。** JSON 数字精度、-0、NaN、键排序、浮点数学函数跨平台差异，都会破坏内容寻址和逐位还原。空编辑表必须短路输出原始字节，不能经过 HSVL 转换再转回。否则"逐位还原"很容易假成立。

**性能上限。** 逐像素多算子、多选择子、高分辨率、AI 多轮渲染，重放成本线性增长。需要预览金字塔、分块、中间缓存、增量重渲染。否则 AI 闭环还没收敛，延迟先爆。

**可解释性与审计。** 用户看到 canonical JSON 不会懂。需要自然语言摘要、编辑 diff、选择子覆盖高亮、为什么选这些像素、参数来源。否则人类不敢用同一撤销栈。

**选择子 DSL 的序列化与版本。** "谓词不是数据"很漂亮，但 AI 生成的谓词必须可序列化、可比较、可版本化。任意闭包不可 canonical。必须限制成受限 DSL，否则编辑表存不下、迁移不了。

**版本兼容和容器演进。** 底图哈希算法、解码器、算子语义、选择子阈值、色彩空间定义都要版本化。旧渲染器遇到新算子应拒绝，不是静默错渲。

**并发、合并、底图替换。** 多人/多 agent 编辑同一底图，编辑表合并冲突；底图替换后选择子语义漂移。撤销栈也需要事务合并，否则 GUI 拖动产生上千条编辑。

**安全与 DoS。** 巨大编辑表、恶意选择子、递归 regionSel、提示注入让 agent 生成无限算子。wasm 沙箱不自动解决资源耗尽。

## 3. 遮罩预览 + 区域 census + probe 是否足够？

不够。这三个只给状态的一部分，没给动作后果。AI 闭环需要知道"我调这个参数，哪些像素会变、变成什么统计"。

**要加：**
- 原图叠加高亮轮廓、区域编号、bbox、质心、面积、邻接图。纯低分辨率遮罩 VLM 经常看不懂。
- 选择子覆盖率和参数敏感性。至少给阈值附近覆盖率变化、有限差分。
- 反事实候选预览：改目标色相/强度后的局部 crop，不只给当前遮罩。
- 编辑表 diff 和验证器：顺序、冲突、作用域、性能预算。
- 确定性收敛指标：区域 ΔE、非目标误伤率、覆盖率变化。VLM 只做语义验收。
- 主动高分辨率 crop 查询，而不是单点 probe。

**要砍或重做：**
- 纯二值低分辨率遮罩，容易误导 VLM。
- 单点 probe_point，会被抗锯齿、噪声、混合像素欺骗。改成 probe_region。
- 让 VLM 判断微小色差。它是语义预言机，不是色度计。

## 4. 如果我来定最小验证

Gemini 的方案验证"没有空间辅助不行"，这几乎显然，且 mock agent 无视觉。我的最小验证要验证 MVSL 核心：编辑表 IR、可逆、人机同栈、AI 闭环收敛。

考题：同色干扰图。红苹果 + 红椅子 + 木桌 + 绿叶。目标：苹果调绿，椅子、桌子、叶子不变。这才能真正区分全局 h census 和区域空间选择。

实现：真实 VLM agent + 受限工具调用 + 软选择子 + 区域连通图 + recolor/relight/smooth。预算 5–8 轮。指标：目标区域色相均值达标；非目标区域 ΔE00 < 2 或误伤像素 < 1%；空编辑逐位还原；canonical 哈希稳定；撤销重做一致；人类 GUI 拖动编译成同一 IR。

证伪：有区域图和参数敏感性反馈，仍在预算内误伤 >1% 或目标不达标，说明 affordance 或选择子代数不够。不是"无空间辅助做不到"这种显然结论。

如果只能做一个实验，我会做"同色干扰 + 真实 VLM + 区域 affordance + 像素指标"。Gemini 那个 mock agent 三轮回合，测不出 MVSL 的真增量。


---

## 4. Claude-A 盲评

# 总评

方向对，但抽象的真实身份要摆正：**MVSL 不是"源语言"，是「无损非破坏式调整栈 + 参数化蒙版」的规范化 IR**。这本身有价值，但"任意图像的可编辑源语"这个说法过强。真正的增量不在数学层，在三处：(a) 选择子作为谓词（可序列化、可重放、分辨率无关）、(b) 人机同 IR、(c) 把 census/render/sample 设计成 AI 的感知-行动闭环。

---

## 1. 抽象成立吗？

**成立的部分：** 无损靠构造（空程序 = 恒等）、谓词式选择子、有序具名 op 列表，这是 Lightroom/Capture One/Darktable 的 history stack + mask 的本质，工程上被验证过。canonical JSON 存容器、open→save 字节一致，很干净。

**"重新组合还是真增量"：** 数学层面几乎全是重新组合。hue-vs-hue、luminosity mask、频率分离（高斯/高反差保留）、Lab 曲线、SLIC 都是成熟东西。真增量只有：
- **谓词而非数据**：Photoshop 的蒙版是位图，你的是可解释的参数化表达式。这使得编辑可 diff、可让 LLM 读写、跨分辨率重放。这是对 AI agent 真正有意义的差异。
- **AI 友好的度量接口**（census）：业界没有把它设计成 LLM 的一等公民工具。

**我不同意的点：**

- **"任意图像，不限于扁平风格"是最危险的过度承诺。** 色相/明度谓词在动漫上工作，是因为动漫是**分片常数色 + 硬边**，颜色≈语义。照片里颜色与语义严重解耦：蓝色衬衫和天空同色相，皮肤高光和白墙同明度，阴影里的一切都趋向同一个低饱和暗色。"天空调暖别动人物"在照片里，纯颜色谓词会**在天际线、树叶缝隙、玻璃反光、蓝色衣物上全部漏选**。这类场景本质上需要**空间/语义先验**（geoSel 手画或分割），颜色谓词只能做辅助收窄。所以对照片，"AI 视觉供给语义"不是可选项，是承重墙，而你的语言里恰恰没有能可靠承接它的原语（见下）。
- **"正交"是假的。** 选择子组合（交/并/差）是布尔代数，可以正交组合；但**算子与选择子不正交**：recolor 会改变色相，导致后续 op 的 colorSel 命中集合变化。编辑表是有序程序，每个选择子在**哪个中间状态上求值**必须是语义的一部分（对 base 求值 vs 对上一步结果求值）。这是 IR 设计里最容易埋雷的地方，见下。
- **"确定性"要落到浮点层面。** wasm 的 f32/f64 是确定的（IEEE 754，除 NaN 位模式），但你如果用 `exp/pow/sin/cbrt` 这类超越函数，MoonBit 的实现依赖底层库/自己实现，**跨 target（native/wasm/js）可能不逐位一致**。零依赖的好处是你可以自己实现并锁定这些函数。这条要在 IR 规范里写死，否则"逐位一致"只在同一 target 内成立。

**必须补的 IR 语义决定：**
1. 选择子求值基准：默认对 base 求值（稳定、可重放、不受前序 op 污染），显式标注才允许对中间态求值。
2. 选择子输出必须是 **[0,1] 的软权重场**，不是布尔。所有 op 都是 `out = lerp(in, op(in), w)`。这一条决定了边界质量。
3. 工作色彩空间必须固定并写入容器（建议线性 sRGB 做光照/模糊，感知空间如 OKLab/OKLCH 做选择和 hue 操作）。HSV 做 recolor 会有明显的感知亮度漂移（黄和蓝同 V 亮度差很大），"保留明暗"在 HSV 里其实保不住。**我建议基础通道用 OKLCh 而不是 HSVL**，除非你有强理由。

---

## 2. 盲点与失败模式

### 2.1 软边界与杂边溢色（零依赖下的做法）

这是动漫改发色的头号视觉失败点：**抗锯齿边缘像素是「头发蓝 × 背景色」的混合**，色相落在两者之间，硬阈值要么漏掉（留下一圈蓝边），要么误选背景。

可行做法，按性价比排序：

1. **软阈值 + 羽化的色相区间**：用平滑的窗函数（smoothstep 或余弦窗）而非矩形，区间内=1，区间外过渡带宽度是参数。色相是环，注意 wrap-around。加权重 `w = hueWin(h) * satWin(s) * lumWin(l)`。
2. **饱和度加权 recolor**：混合像素饱和度低，权重自然低，这本身抑制杂边，但也会留下"半蓝"边。
3. **边缘去污染（decontamination）**：对选区边缘的部分覆盖像素，估计前景纯色 F 与背景 B，使 `pixel = αF + (1-α)B`，只对 F 做 recolor 再合回。零依赖下可以用 **guided filter**（He et al.）把粗糙权重场对齐到图像边缘。guided filter 是 O(N) 的盒式滤波，纯数学，几十行代码，**强烈推荐作为引擎内置的"选择子精修"原语**，比超像素靠谱。
4. **形态学 + 连通域过滤**：去掉孤立噪点、填小孔。廉价，有用。
5. **regionSel(超像素)**：SLIC 在零依赖下可行但代价高，且超像素边界与语义边界并不一致，在有细发丝的动漫里会切碎。我认为它**优先级低于 guided filter**，且更适合作为 AI 的辅助（"选这个块"）而不是核心。

**实话：** 动漫线稿/描边压在头发边缘，线稿是深色，颜色谓词不选，但线稿抗锯齿像素含头发色，会留下淡色杂边。这在实际中通常可接受。真正麻烦的是**渐变发丝、高光、半透明发梢**，这些区域色相会偏移（高光偏白/偏黄），单一色相区间抓不全。这就是"保留明暗"的 recolor 需要按明度分段扩展色相窗的原因。

### 2.2 语义靠 AI 视觉供给的可靠性

这是最大的系统性风险，我说具体点：

- **多模态模型的空间定位是弱项。** 它能可靠说"这张图里有蓝头发"，但让它从一张 census 表反推"哪个色相桶是头发"，需要它把**视觉印象映射到数值桶**，这一步非常容易错（头发、衣服、背景、眼睛同为蓝系时）。census 表本身没有空间信息，AI 只能靠均值色和占比猜。
- **渲染回看的分辨率问题：** 送回给 AI 的图会被缩放/压缩，几像素宽的杂边**在 AI 视野里不存在**。所以"AI 看 render 自查"对**全局色调正确性**有效，对**边缘质量**基本无效。边缘质量必须由确定性工具（数值指标）而非视觉判断来把关。
- **色彩数字的无感：** 模型对"色相 218° vs 231°"这种差异没有可靠感知，对肉眼不敏感的偏色也不敏感。

**结论：** 语义→谓词的映射不能只走"AI 读表猜桶"。需要**空间化的感知工具**（见第3节）：把候选选区叠加成半透明高亮图给 AI 看，AI 回答"是否选对"，这比让 AI 读数字可靠得多。

### 2.3 render 自查迭代的收敛性

会出的问题：

- **无客观目标函数。** 迭代是"模型觉得看起来对了"就停，没有可量化的收敛判据，会出现振荡（调过头→调回→再过头）、漂移（每轮微调累积成大偏差）、过早满意。
- **参数空间的非单调性：** 色相窗宽度 ↔ 漏选/溢选是尖锐权衡，模型靠视觉难以做梯度式调整。
- **副作用不可见：** 改发色时同时改了衣服上同色相区域，模型看整图缩略图可能没注意到。

缓解手段：**每个 op 提交前强制产出「变更报告」**（见第3节的 diff 工具），把"改了哪里"变成数值 + 可视化，闭环靠这个而不是靠主观观感。并且要有硬性的**迭代上限和回退**（你的 undo 栈正好用上）。

---

## 3. Affordance 够不够？

census + render + sample **不够**。它们都是「读」型工具，且都是**全局/点状**的。缺的是空间维度和验证维度。

### 缺了它闭环就不成立

1. **选区预览/可视化（selection overlay）**：给定一个选择子表达式，返回它的权重场渲染成半透明高亮图（或黑白蒙版图）+ 覆盖率统计（占全图%、bbox、连通域数量）。没有这个，AI 是**盲选**——只能提交谓词然后看 render 后果，出错成本高一轮。这是最关键的缺失。
2. **变更 diff 度量（edit diff）**：对任意 op 或 op 序列，返回「被改动像素的占比、改动的空间分布（热力图）、改动的平均/最大 ΔE（OKLab）、改动区域的 bbox」。这是防止"改了不该改的地方"的唯一客观手段，是 **不变量校验**的基础。
3. **空间化 census / 区域查询**：census 需要能**限定在一个选择子或 bbox 内**重算（"在这个选区内色相分布如何"），并且能反查——**给一个桶，返回它的空间分布**（bbox + 缩略高亮图 + 连通域列表）。否则 AI 无法把"桶"和"图上的东西"对应起来。census 现在是「桶→统计」，必须补「桶→空间」。
4. **约束/断言机制**：允许 AI 声明"此区域（人物 mask）在本 op 前后 ΔE < 阈值"，引擎自动校验。"别动人物"这种需求，如果只能靠 AI 眼看，就没有闭环。要变成可机器验证的断言。

### 缺了它只是低效

5. **局部放大 render（crop + zoom render）**：看边缘质量必须放大到 1:1 或 2:1 看局部。整图缩略图看不到杂边。**这个我倾向放进第一档**，因为边缘质量是你主场景（动漫改发色）的核心验收标准，没有它 AI 不可能发现杂边。
6. **connected components / 区域列表工具**：返回连通域及其属性（面积、bbox、均值色、质心），让 AI 用"第2大的蓝色块"这种方式指代。
7. **A/B 并排与 before/after 切换渲染**。
8. **直方图/通道统计（选区内）**：用于校准明度保持是否成立（recolor 前后选区内亮度直方图应基本重合）。
9. **参数扫描（sweep）**：一次渲染多个参数取值的小图拼图，让 AI 用一轮选参数，减少串行迭代次数。这对收敛性有明显帮助。
10. **自动候选生成**：census 之上给出「候选谓词建议」（如"这个桶+这个连通域构成一个内聚对象"），降低 AI 出错率。属于锦上添花。

另外一个基础设施问题：所有 AI 工具的**返回体积和成本**。图像要压缩和降采样，census 表要限制行数。工具设计要把 token 成本算进去。

---

## 4. 替代架构

| 方案 | 结论 | 理由 |
|---|---|---|
| **可微光栅化** | **有条件，不作为主线** | 优点是能做"给定目标反推参数"的优化（如自动拟合矢量化）。但它解决的是「表示」问题，你的问题是「编辑」。浏览器 wasm 中做反向传播需要自己写 autodiff，性能和开发量都高。仅对"图像→矢量层"的**一次性矢量化**有意义，可以离线。**不排除但优先级低。** |
| **隐式神经表示 (INR/NeRF-like)** | **明确排除** | 与你的核心约束直接冲突：无法保证 open→save 字节一致和"空程序=原图逐位一致"；需要训练/推理，权重体积大；零依赖 wasm 里跑不动；编辑不可解释、不可 diff。这与"无损靠构造"的理念是对立的。 |
| **程序归纳式编辑**（让 AI/搜索合成 op 序列） | **值得认真对待，且已经是你的架构** | 你的"AI 用工具调用逐步构造编辑表"本质就是程序合成，只是搜索者是 LLM。值得做的扩展是**在引擎内提供廉价的确定性搜索**：比如给定目标色，自动求解 recolor 的映射参数；给定选区，自动优化 guided filter 半径。让 LLM 决定「做什么」，让确定性代码决定「参数多少」。 |
| **分割模型（SAM 类）在浏览器端** | **值得考虑，但作为外部可选供给，不进核心** | 它能解决照片场景语义选区的承重墙问题。但零依赖原则与之冲突。折中：分割结果作为**内容寻址的 mask 资产**导入（就像位图资产一样），选择子引用它，引擎本身仍零依赖。这样语义由外部供给，语言保持纯净。**这其实是我对你"语义不内置"原则的最重要补充**：需要一个「外部 mask 作为资产」的原语。 |

---

## 5. 最小验证实验

**目标：** 证伪「MVSL + census/render/sample 能让 AI 在无人工干预下完成语义正确的局部编辑」。

**设计：**

- **数据集：** 60 张图，分三组各 20：(A) 干净动漫立绘（单色相目标：发/衣/眼）；(B) 复杂动漫（渐变、高光、多同色物体）；(C) 照片（天空、植物、单件衣物）。每张预标注**目标区域真值 mask**和**保护区域真值 mask**（人工标或用 SAM 生成后人工修正）。
- **任务：** 每张一个自然语言指令（如"蓝头发改红""天空调暖别动人物"）。
- **对照组（关键，防止自欺）：**
  - 基线1：人类专家用 Photoshop 30 分钟内完成同任务（给出质量上限）。
  - 基线2：**同一个 AI，仅用 hue-vs-hue + 全局调整层，不用 MVSL 选择子**（验证增量）。
  - 基线3：**同一个 AI + MVSL，但去掉 selection overlay 与 diff 工具**（验证 affordance 补全的价值）。
- **度量（全部自动、客观）：**
  - 目标区域内：色相位移到目标附近的比例；明度保持（L 通道 ΔL 的 P95）。
  - 保护区域内：ΔE(OKLab) 均值与 P99，越接近 0 越好。
  - 边缘杂边：目标 mask 边界 3px 带内的残留原色相像素比例。
  - 迭代数与工具调用数、失败/回退次数。
  - 无损性检查：空程序输出与原图逐位一致（回归测试，应 100%）。

**证伪标准（明确）：**

1. **A 组成功率 < 80%**（成功=目标区 recolor 达标且保护区 ΔE P99 < 2 且边缘残留 < 5%）→ 架构在它最有利的场景都不成立，直接判死。
2. **C 组（照片）纯颜色选择子的成功率 < 30%，且加了外部 mask 资产后也没有显著提升** → "颜色谓词作为通用源语"被证伪，只能退回动漫/图形专用。预期 C 组不加 mask 会很差，这不算证伪，是**验证我上面的判断**。
3. **基线2 与 MVSL 的成功率差 < 10 个百分点** → MVSL 相对于现有调色工具没有增量，重新组合的判断成立，不值得建立新语言。
4. **AI 迭代不收敛**：超过 30% 的任务在 8 轮迭代内不满足自身停止条件，或出现明显振荡（同一参数来回变号 ≥3 次）→ render 自查闭环不成立。
5. **基线3 与完整版差距大（>20 个百分点）** → 说明 affordance 缺口是主要瓶颈，这是好消息（可补），不算架构错，但必须正视 census+render+sample 不够这一结论。
6. **空程序逐位一致性有任何一例失败** → 工程基础不成立，先修。

---

## 6. 我作为修图 agent 的理想调用序列

### 场景一：动漫蓝发 → 红发，保明暗

```
1. render(full, downscale)                      # 整体理解，识别发型位置、是否多处蓝色
2. census(scope=full)                           # 看色相×饱和度分布
3. hue_bucket_locate(bucket=蓝色候选1..n)        # 【缺口工具】每个候选桶的空间高亮 + bbox
   → 对照 render，确认哪个桶对应头发（排除衣服/眼睛/背景）
4. sample(x,y) × 5~8                            # 在发根/发中/发梢/高光/暗部/边缘各采点，
                                                #   确定色相窗和明度范围（高光会偏色）
5. define_selection(colorSel(hue窗, sat窗, lum窗, soft=…)
                    ∩ geoSel或regionSel(限定头部区域))
6. preview_selection(overlay)                   # 【缺口工具】看权重场；
                                                #   crop_zoom 看发际线、发梢、线稿边
7. refine_selection(guided_filter(r, eps))      # 对齐边缘，去杂边
8. preview_selection → 确认
9. apply recolor(hue→目标红, preserve_lightness=true, sel=…)
10. render + crop_zoom(边缘, 高光, 发梢)         # 查杂边残留与高光偏色
11. edit_diff(op=recolor)                       # 【缺口工具】确认只改了头发区：
                                                #   改动占比、bbox、区域外ΔE≈0
12. lum_histogram(sel, before/after)            # 确认明度分布保持
13. 若有蓝边：扩窗/加 refine，undo 回退重试（≤3轮）
14. 提交并给出变更摘要
```

### 场景二：照片天空调暖，别动人物

```
1. render(full)
2. census(scope=full)                           # 天空通常是一个大的蓝色低-中饱和高亮度桶
3. hue_bucket_locate(...)                       # 看天空桶的空间分布；
                                                #   发现漏进衣服/水面反射 → 颜色谓词不够
4. 【关键分歧点】请求外部语义 mask（sky）或 geoSel：
   若引擎支持 import_mask_asset(sky_mask)，用它；否则用 geoSel 粗画天空
   ∩ colorSel 收窄 → 得到权重场
5. refine_selection(guided_filter)              # 天际线、树梢、发丝：照片里边缘是难点
6. preview_selection + crop_zoom(天际线/人物头发边缘)
7. 定义保护：protect = geo/mask(人物)；selection = sky − protect
8. apply 色温/tint 类算子(调暖, sel=…)           # 不是 recolor 色相重映射：
                                                #   天空调暖是色温偏移，用 hue 重映射会把蓝天变成脏灰橙
9. edit_diff + assert(protect区ΔE < 阈值)        # 用断言机制把"别动人物"机器化
10. render + 全图检查自然度（渐变是否断层、天空到地平线过渡）
11. 迭代 ≤3 轮，超出则回退并上报"需要人工选区"
```

**注意场景二的两点：** (a) 要用「色温/白平衡偏移」而不是「色相重映射」，语义完全不同，这说明算子库里需要区分**色相重映射**（离散物体换色）与**连续色调迁移**（光照/色温）；(b) 照片里"天空"的渐变（近地平线偏暖偏亮）意味着**恒定强度调整会不自然**，需要沿渐变方向的权重衰减（一个线性/径向的 geoSel 渐变蒙版乘进去），这也是你的选择子集里需要**渐变形状的 geoSel**的原因。

---

## 最后的判断

- **值得做**，但定位要收敛：先把它做成「动漫/图形的高质量语义换色引擎 + 照片的辅助调色栈」，而不是宣称任意图像通用。照片必须引入外部 mask 资产这个口子，否则第二个目标场景做不成。
- **先补三件事再谈其他：** guided filter 精修、选区预览/diff/断言工具、色彩空间与选择子求值基准的 IR 规范。
- **最该警惕的自欺：** 用一两张漂亮的动漫 demo 图证明"通用"。跑第5节的实验，看 C 组的数字。


---

## 5. Claude-B 对抗审查（针对 Gemini）

## 1. 我不同意 Gemini 的地方

**"真增量是统一控制面"：只对一半。**
- 非破坏性编辑表 + 参数化遮罩早有先例：Darktable 的 history stack + 参数遮罩（HSL/亮度带）本质就是你的 colorSel/lumSel，Lightroom/ACR 的 XMP、RawTherapee 的 PP3 同理。
- 人机共用一个 IR 只要一开始就这么设计，成本很低，不构成护城河。
- 真增量是 **AI 侧 affordance 的设计**（让 VLM 能低成本、可验证地操作这套 IR）和**解码到渲染全链路 bit-exact**。Gemini 提了后者，却没让最小验证去测它。

**"选择子是谓词不是数据"：Gemini 没戳穿这个自洽性问题。**
- 苹果和红桌布同色相时，colorSel 无解，必须引入 regionSel/geoSel，也就是 VLM 给的 bbox/多边形/点，这本身就是数据。
- 纯度承诺在真实场景下必然泄漏。要么承认"谓词 + 少量锚点数据"的混合，要么明确能力包络（不支持同色相相邻物体）。

**"census 缺空间信息 → 加区域级 census"：这个修法循环依赖。**
- 要做区域 census，AI 得先定位区域，而定位恰恰是 VLM 最弱的环节（像素坐标 grounding 误差大）。
- 正确方向是让引擎做定位：返回选择子的**连通域标注**（编号、bbox、质心、面积、均值 HSV）加带编号的叠加图（set-of-marks）。AI 选 ID，不报坐标。

**"AI 闭环不收敛源于 VLM 对小色差不敏感"：诊断错了层。**
- 收敛需要**可测的目标函数**，不该让 VLM 当色差计。引擎能直接给数值：选区内均值色相、选区外 ΔE 泄漏量。
- VLM 只负责语义判断（选中的是不是苹果）。让 VLM 看图判色差，本来就是错误的设计。

**"硬切边界产生锯齿杂边"：只说对了表面。**
- 抗锯齿边缘像素是红与棕的混合，色相落在橙色，本身就是 fringe，光羽化解决不了。JPEG 4:2:0 色度块也会让色相选区带 8/16px 块状伪影。
- 需要 soft membership（smoothstep 带宽）、按饱和度和明度加权的色相置信度，必要时加 guided filter 做边缘细化。

**"替代架构全部排除"：过于武断。**
- wasm 约束只限制引擎，感知在远端 VLM/分割模型。
- "AI 输出 SAM 类掩膜再入编辑表"的混合路线并没有被排除，只是违反了你的纯度，这是取舍，不是不可行。

**最小验证方案本身有缺陷：**
- n=1 的苹果题是最简单的情形。
- "无空间辅助 3 轮做不到"是在证实显然的事，不检验你的方案有效。
- mock agent 去掉了 VLM 噪声，而 VLM 正是最大风险。

## 2. 遗漏的失败模式与设计维度

**次序与交换性**
- 关键决策：选择子求值在 base 上还是在中间结果上？
- 在 base 上：选区稳定，可以自由开关或重排某条 op（GUI 需要），但 AI 看到的是当前图，语义会错位（红→绿后"选红"选不到任何东西）。
- 在中间结果上：意义依赖整个前缀，撤销中间一步会让后续选区漂移。
- 建议选择"base 求值 + 有序管线"，并把这条写进规范。

**HSV 的 V 不保感知明度**
- 红→绿保持 V，视觉亮度会跳变（sRGB 纯绿 Y≈0.72，纯蓝 Y≈0.07）。"保明暗"必须在感知空间（OKLab/OKLCH 的 L）里做。
- 换色相后 chroma 可能出 sRGB 域，需要 gamut mapping，否则裁切造成色阶断层。
- 近灰轴和近黑处色相无定义，噪声会造成选区散斑。
- 还要规定 smooth/relight 在线性光还是伽马空间做。

**确定性的真正风险**
- 用浏览器解码 JPEG/PNG，各家 IDCT 和色度上采样不同，"内容寻址底图"的解码后像素跨浏览器不一致，"空表逐位还原"直接破功。**解码必须在 wasm 内自己实现**（JPEG 解码器是相当大的工作量，含渐进式、EXIF 方向、ICC）。
- 数学函数（pow/exp/sin）不能走宿主 Math；relaxed SIMD 不确定。
- canonical JSON 里的浮点序列化（-0、NaN、最短表示）会破坏哈希，编辑表参数应改用定点整数。
- 每步量化 8-bit 会累积误差。管线内部保持浮点，末端一次量化，且分块渲染结果必须与整图渲染逐位一致。

**算子版本冻结**
- bit-exact 意味着 `recolor@1` 永远不能修 bug。要么二进制内保留所有历史实现，要么在容器里存渲染哈希和缓存来检测漂移，并提供显式迁移。
- schema 版本和算子语义版本要分开管理。

**可解释性**
- AI 写出来的 hue∈[0.97,0.03] 和阈值 0.07，人类无法理解为什么是这个数。
- 每条 op 应带 intent、依据的 census/probe 证据、AI 的 rationale，并能在 GUI 里渲染成可拖动的句柄和遮罩叠加。

**人机并发与撤销粒度**
- AI 的一轮多步应是一个原子撤销组。
- 人在 AI 循环中途手动改，会产生合并冲突。需要锁或分支，否则"同一撤销栈"是假象。

**性能**
- HSVL 浮点场 24MP × 4 × 4B ≈ 384MB，手机浏览器扛不住，应惰性派生或量化存储。
- freqSel 需要金字塔，smooth 要用可分离或积分图。
- census 若用全局统计做自动归一化，会破坏分块局部性。
- 无 COOP/COEP 就没有多线程。
- wasm-gc 与线性内存后端在数组访问和互操作拷贝上的性能特征差异要提前测。

**预览与终渲染不一致**
- 低分辨率遮罩预览会丢掉茎、发丝这类细结构。AI 在预览上验证通过，终渲染却不同。预览必须走同一管线（渲染后再降采样，不能先降采样）。

**能力包络未声明**
- 不支持同色相相邻物体、多色物体（条纹衬衫）、需要生成的编辑（去物体、苹果变梨）。
- 高光、阴影、环境色溢出都是偏离主色相的，"红苹果"的选区一定有洞。

**色彩管理**
- 广色域（P3/AdobeRGB）输入、16-bit、alpha 预乘、HDR。"immutable base"若默认按 sRGB 处理，会悄悄出错。

## 3. 三个 affordance 够吗？

**不够，且结构不对。**

保留并加强：
- **遮罩预览**：输出软 alpha 叠加图，附覆盖率、bbox、连通域数。这是最有价值的一个。
- **probe_point**：返回邻域统计（5×5 的 HSVL）、各选择子在该点的 membership、所属连通域 ID，而不是单点色值。

砍掉或合并：
- **独立的区域 census**：并入 census 的参数 `within=selector|component_id`，不做"先框区域再统计"。
- 同时给 census 每个 bin 附带空间分布指标（连通域数、质心、离散度），这一项就补上了"盲人摸象"。

新增（按重要性排序）：
1. **种子连通域选择子**：`component_of(colorSel, seed=probe点, tolerance=ΔE)`。用一个粗略的点加颜色连通性就能分开苹果和红桌布，不需要像素精确坐标。
2. **diff_report**：编辑前后的 ΔE 统计，选区内 vs 选区外的变化量、泄漏比例、最大 ΔE、变化热力图。它是收敛信号，替代 VLM 看色差。
3. **后置条件断言**：AI 提交 op 时声明"选区内均值色相 ≈120°±5°，选区外 ΔE<1"，引擎自动校验。这样闭环由数值判定，VLM 只做语义确认。
4. **选区精修原语**：grow/shrink/feather/fill_holes/keep_largest。
5. **收敛控制**：步数预算、单步幅度上限、"回滚到最优检查点"，防止震荡。

## 4. 我会怎么设计最小验证

**第 0 步（不用 AI）：选择子表达力上限。**
- 对每张测试图，用暴力/优化搜索找 colorSel+lumSel 组合，使其与真值掩膜 IoU 最大。
- 若苹果集上的上限就低于 0.9，任何 AI 都救不了，问题出在算子代数，不是 affordance。这一步成本极低，却能先砍掉一半不确定性。

**第 1 步（真实闭环）：**
- **真 VLM，不用 mock**。mock 只用于引擎单测。
- **30–50 张带真值掩膜的图**，分层：易（红苹果/绿桌）、中（桌子偏红棕）、难（两个红物体、多色物体、低饱和、高光、JPEG 压缩），加负例（目标不存在、指令歧义）。
- **消融**：A0 只有 census；A1 +遮罩预览；A2 +probe；A3 +连通域/种子选择；A4 +diff_report/后置条件。每组 k=5 次取方差。
- **指标**：变化像素与真值的 IoU、选区外泄漏率、目标色相误差、收敛轮数、token 成本，并对失败做分类。
- **事先写死的证伪标准**（示例）：A4 在易+中难度上成功率 ≥80%、泄漏 <1%、中位数 ≤4 轮，且显著优于 A0。若 A3 相对 A0 提升不明显，说明瓶颈不在空间信息，而在 VLM 定位或选择子表达力，要转向。

**第 2 步（顺手验证 Gemini 认定的真增量）：**
- 同一份编辑表在 Chrome/Safari/Firefox/wasmtime 上渲染，输出哈希必须完全一致。
- 人 GUI 与 AI 各产生若干 op，撤销/重做往返后仍逐位相等。

**与 Gemini 方案的核心区别**：它测的是"不加辅助会不会失败"，是一个必然成立的负面结论；我测的是"加了哪些辅助有效、有效到什么程度、上限在哪"，并把确定性契约放进验证范围。


---

## 6. ChatGPT-B1 对抗审查（第一份）

先给结论：Gemini 的方向基本对，但它把几个“工具可用性问题”说得太重，把几个真正决定 MVSL 能不能成为**可维护的图像编程 IR**的问题说得太轻。尤其是它对 **选择语义、算子代数、确定性、颜色语义、版本化、性能** 的讨论明显不够。

更尖锐一点：它现在是在评审“AI 能不能把苹果染绿”，而你真正需要验证的是——**MVSL 是否形成了一个稳定、可组合、可解释、可重放的图像编辑语言。**

---

# 1. 我不同意 Gemini 的几个判断

## 1.1 “census 没空间信息 → AI 全局误伤”这个因果关系说得过头了

这是真问题，但不是 census 的缺陷。

全局 census 本来就应该回答：

> “这张图里有哪些颜色/材质分布？”

它不应该承担：

> “左上角那个红色东西是谁？”

这两个查询是不同的 affordance。

反例很简单：

一张图里只有一个明显的红色簇，census 得到：

```text
red-orange / high saturation / medium luminance : 8.7%
```

AI 再通过 `regionSel` 或 `probe_point` 定位，完全没问题。

所以更准确的架构是：

```text
global census
    ↓
候选语义假设
    ↓
spatial census / probe / region selection
    ↓
predicate
    ↓
preview
    ↓
edit
```

而不是把“空间定位失败”归咎于 census。

Gemini 的真正漏洞是：它默认 AI 的观察接口应该是**线性追加工具**。实际上你可以把它设计成一个层级检索系统：先便宜的全局统计，再空间缩小，再精确 probe。这样成本和精度都更合理。

---

## 1.2 “选择子硬切边界会产生锯齿杂边”是正确警告，但不应该把它描述成 MVSL 的必然失败模式

因为你的 selector 完全可以是：

```text
hard predicate
```

和：

```text
soft predicate
```

两种不同语义。

例如：

```text
h ∈ [350°, 10°]
s > 0.35
```

可以得到 bool mask。

也可以定义：

```text
w = smoothstep(...)
```

得到连续权重。

甚至：

```text
mask = colorSel(...) ⊗ regionSel(...)
mask = feather(mask, radius)
```

这里真正困难的不是“predicate 是不是硬边界”，而是：

> **选择语义和边缘处理语义有没有分层。**

如果 selector 自己负责 feather，会污染 selector 的纯谓词语义；如果 operator 自己负责 edge handling，又可能不同算子产生不一致。

所以我会把：

```text
selector
operator
boundary policy
```

明确拆开。

否则以后一定出现：

```text
recolor 的边缘很好看
relight 的边缘一圈发灰
smooth 的边缘又不一样
```

这不是小 bug，而是 IR 语义不一致。

---

## 1.3 “AI 视觉闭环可能不收敛”是真的，但根因不只是 VLM

Gemini 把问题归因给：

> VLM 对微小色差不稳定。

这个判断没错，但不完整。

真正的控制理论问题是：

```text
agent
  → action
  → render
  → observation
  → agent
```

是不是一个**可观测、可单调推进**的系统。

一个极其容易出现的失败：

```text
AI：红色区域太宽
→ 缩小 hue range

render：
→ 苹果主体变好了，但阴影漏掉

AI：扩大 saturation range

render：
→ 桌子边缘又被染进去

AI：再缩小 region
...
```

这不是“VLM 看不准”这么简单。

这是一个没有显式目标函数、没有进度度量、没有动作回退策略的控制器。

所以你真正需要的是：

```text
target hypothesis
+
observable metrics
+
monotonic refinement
+
no-op detection
+
rollback
```

否则即使换一个非常强的 VLM，一样能振荡。

---

## 1.4 Gemini 的“3 轮内无空间辅助就做不到精准定位”这个证伪标准不够科学

我反而比较反对这个。

因为它把三个变量混在一起了：

1. engine 能不能表达目标；
2. affordance 能不能暴露足够信息；
3. agent 能不能正确使用信息。

三者没有分离。

而“3 轮”本身几乎是任意阈值。

一个 agent 可能 4 轮成功，但这不证明架构错误；另一个 agent 可能 2 轮碰巧成功，也不证明接口设计正确。

更好的指标应该是：

```text
selection precision
selection recall
changed-pixel IoU
unintended-change rate
action count
rollback count
render cost
```

尤其是：

> **目标区域 precision / 非目标区域污染率**

比“几轮成功”有信息量得多。

---

## 1.5 “这只是精妙的工程重组”这个判断，我认为低估了架构层的价值

如果所谓“数学突破”是指新的图像处理理论，那确实不是。

但它也不只是简单重组。

你实际上定义了一个东西：

> **面向视觉编辑的声明式、可重放 IR。**

其中最重要的一刀是：

```text
selector = predicate
```

而不是：

```text
selection = bitmap
```

这一点非常重要。

因为 bitmap selection 是：

```text
一次性的空间事实
```

predicate selection 是：

```text
可重算的语义程序
```

这会直接带来：

```text
replay
canonicalization
provenance
parameter editing
human/AI convergence
undo/redo
portable serialization
```

所以我会把它称为：

> **image-editing DSL / IR architecture**

而不是简单“工程重组”。

当然，它是否足够新，是另一个问题；但从系统设计角度，它的核心抽象是很实质的。

---

# 2. Gemini 漏掉的真正大坑

这里反而是我最担心的部分。

---

## 2.1 最大的问题：算子组合的代数没有定义

这个我会放第一优先级。

例如：

```text
A = recolor(red → green)
B = relight(region, +20%)
```

通常：

```text
A ∘ B ≠ B ∘ A
```

再比如：

```text
A = recolor(red → green)
B = smooth(red region)
```

如果 B 的 selector 是基于当前图像：

```text
A → B
```

第二步可能已经找不到原来的 red。

于是马上产生一个关键问题：

> selector 是对 base HSVL 求值，还是对当前 render 求值？

这是 MVSL 的核心语义之一。

### 方案一

所有 selector 都绑定 immutable base：

```text
sel(e, base)
```

那么：

```text
recolor red→green
```

之后再执行：

```text
colorSel(red)
```

仍然选中原始红色区域。

优点是稳定、可重放。

缺点是有时候用户其实想选择“当前已经变成绿色的东西”。

### 方案二

selector 对当前结果求值：

```text
sel(e, render(program_before_e))
```

语义灵活，但产生大量序依赖。

所以你必须明确：

```text
selection domain:
BASE | PREVIOUS_RENDER | EXPLICIT_STAGE
```

否则编辑表一旦有 3～5 个 operator，行为会开始“魔法化”。

---

## 2.2 交换性、幂等性、融合规则要成为 IR 的一等公民

至少应该定义：

### 幂等

```text
A ∘ A = A ?
```

很多操作不是。

### 交换

```text
A ∘ B = B ∘ A ?
```

大多数不是。

### 可合并

例如：

```text
recolor red→green
recolor green→blue
```

能不能 canonicalize 成：

```text
recolor red→blue
```

但这里有一个致命问题：

如果第二个 selector 看的是第一步的输出，当然不能随便合并。

所以你实际上需要一个 operator algebra：

```text
depends_on
commutes_with
idempotent
fusable
```

这件事甚至比 census 更重要。

否则你的所谓 canonical JSON 只是：

> canonical serialization

而不是：

> canonical program semantics。

这两者差很多。

---

# 2.3 色彩空间问题会比 Gemini 想得严重得多

HSV 是人类直觉友好，但数学上并不干净。

尤其：

### S ≈ 0 时 H 没意义

```text
gray pixel:
H = ?
```

你必须规定。

否则：

```text
colorSel(h=30°)
```

对 near-gray 会出现数值上的奇怪行为。

### H 是环

```text
350° → 10°
```

不能做普通区间。

### RGB → HSV 本身依赖 gamma / transfer function 的解释

如果输入是：

```text
sRGB
```

你如果直接在编码域计算 luminance，然后做：

```text
recolor 保明暗
```

和在线性光空间计算，视觉结果会不同。

### Wide gamut

当以后碰到：

```text
Display-P3
Rec.2020
HDR
```

你的：

```text
HSV
```

语义会开始变得不舒服。

### gamut clipping

“把红变成蓝”不是永远存在一个合法 RGB 表示的。

如果目标：

```text
H = 250°
S = 1.0
V = 1.0
```

超出目标色域怎么办？

要定义：

```text
clip
compress
desaturate
preserve-luminance
```

哪一种。

否则 `recolor` 看起来是一个很简单的 operator，实际是一个隐藏了很多 policy 的 operator。

---

# 2.4 “recolor 保明暗”本身并没有一个唯一数学定义

这是个非常容易埋雷的地方。

你说：

```text
recolor 保明暗
```

那到底保持：

```text
HSV V
```

还是：

```text
HSL L
```

还是：

```text
relative luminance Y
```

还是：

```text
perceptual lightness Jz / Lab / OKLab
```

？

它们不是同一个东西。

甚至：

```text
RGB(255,0,0)
```

换成：

```text
RGB(0,255,0)
```

如果简单保持某个通道量不变，人的视觉明度完全可能发生巨大变化。

因此 operator 名字不能替代 operator semantics。

我会要求 IR 明确记录：

```text
color_model
transfer_function
luma_definition
gamut_policy
alpha_policy
```

否则多年后你会发现：

> 同一个 edit table 在不同版本里渲染结果变了。

---

# 2.5 “空编辑表逐位恢复原图”其实比看上去困难

这个要求很好，但需要重新定义“原图”。

如果：

```text
JPEG bytes
→ decode
→ base pixels
```

那么你能保证的是：

```text
empty_program(render(base_pixels))
==
base_pixels
```

不一定是：

```text
encode(render(base_pixels)) == original JPEG bytes
```

后者基本不是同一个问题。

更麻烦的是：

```text
premultiplied alpha
vs
straight alpha
```

以及：

```text
8-bit
16-bit
float
```

只要中间发生格式转换，就可能出现：

```text
1 LSB drift
```

而你要求的是“逐位还原”。

所以我会明确规定：

> MVSL 的 base 身份是 canonical decoded pixel buffer，而不是用户上传文件的二进制字节。

如果要保留原始文件，则：

```text
source_blob
+
canonical_base
```

双轨存储。

---

# 2.6 确定性是隐藏的大雷

“MoonBit + wasm + 零依赖 + deterministic”听起来非常漂亮。

但：

> **不要默认 wasm = bitwise deterministic。**

尤其一旦你用了：

```text
浮点
SIMD
并行
trigonometric
sqrt
颜色转换
滤波
frequency domain
```

就需要非常明确地定义数值行为。

你真正应该要求的是：

```text
same engine version
+
same canonical input
+
same canonical edit table
→ same pixel buffer hash
```

而不是泛泛的“算法 deterministic”。

甚至可以直接把：

```text
render_hash
```

作为核心 invariant。

---

# 2.7 性能上限可能比算法正确性更早成为瓶颈

现在的模型看起来很漂亮：

```text
render = base ⊕ edits
```

但假设：

```text
4K image
+
30 edit ops
+
每个 op 全图 scan
```

就是：

```text
30 × 8.3M pixels
```

还没算：

```text
HSV conversion
region test
frequency field
relight
smooth
```

然后 AI 每试一个参数都重新 render。

如果 agent 10 次调整：

```text
300 次全图 pass
```

你的“全程可见”可能会变成：

> agent 思考 1 秒，wasm 算 4 秒。

因此我会非常早引入：

```text
tile cache
selector cache
field cache
incremental invalidation
operator fusion
preview resolution
```

而且这恰好和内容寻址结构非常契合。

例如：

```text
(base_hash, field_spec) → field_hash
```

然后：

```text
(field_hash, selector_params) → selection cache
```

再：

```text
(selection_hash, operator_params) → tile delta
```

这会让你的“不可变内容寻址”从存储设计真正变成计算缓存架构。

---

# 2.8 `canonical JSON` 也不是天然解决版本兼容

JSON canonicalization 只能解决：

> 同一语义是否得到同一字节序列。

解决不了：

> 未来程序是否仍然理解这份语义。

例如：

```json
{
  "op": "recolor",
  "luma": "preserve"
}
```

三年后 `luma=preserve` 的实现改了。

JSON 仍然 canonical。

render 却不同。

因此编辑表至少需要：

```text
schema_version
engine_semantics_version
color_semantics_version
operator_version
```

甚至：

```text
capability declaration
```

例如：

```text
requires:
  color_model = srgb-linear+oklab
  recolor_v2
```

否则跨版本 replay 会非常危险。

---

# 2.9 AI 可解释性不等于 JSON 可读性

这是 Gemini 完全没提够的。

人类看到：

```text
colorSel(
  h=[350,20],
  s>0.42,
  v=[0.15,0.92]
)
→ recolor(H=118)
```

不一定觉得“可解释”。

用户真正想知道的是：

> “你刚才把哪些东西改了？”

所以应该存在**语义 provenance**：

```text
Edit #7
reason: "apple body"
selector:
  affected_pixels: 81,204
  bbox: ...
  components: 1
operator:
  red → green
effect:
  mean ΔE = ...
  unintended-region estimate = ...
```

也就是说：

```text
IR explainability
≠
serialized syntax readability
```

你需要两层。

---

# 2.10 还有一个很隐蔽的问题：编辑表会不会膨胀成“操作录像带”

AI agent 非常可能产生：

```text
recolor #1
recolor #2
adjust #3
rollback
recolor #4
slight correction
recolor #5
...
```

最后 JSON 可能 500 个 operation。

理论上仍然没问题。

工程上会变得非常难：

```text
render latency
undo memory
explainability
conflict analysis
schema migrations
```

因此最好区分：

```text
history log
```

和：

```text
current canonical program
```

否则“编辑表 = 撤销栈”最后很可能成为设计耦合。

---

# 2.11 GeoSel / FreqSel 的语义稳定性也值得单独审

`freqSel` 尤其危险。

频域选择天然依赖：

```text
kernel
window
padding
scale
boundary condition
image size
tile size
```

稍微改一个实现，selector 的结果就变。

`regionSel` 也有：

```text
connected-component
segmentation
distance transform
morphology
```

这些定义必须 version pin。

换句话说：

> **不是只有 operator 要版本化，selector algorithm 也必须版本化。**

---

# 3. “遮罩预览 + 区域 census + probe”够不够？

**不够。**

但 Gemini 这三个方向是对的。

我会把它们重新组织成四层，而不是三个平行工具。

---

## 第一层：便宜的候选发现

### `census()`

全局：

```text
h × s × l
```

但最好不是只有一个 global histogram。

我更倾向于：

```text
spatial_pyramid_census
```

例如：

```text
global
2×2
4×4
```

每个 cell 给：

```text
dominant hue
sat
luma
pixel count
```

这比单独的：

```text
global census
+
region census
```

更强。

因为 AI 会天然得到：

> 哪里有这种颜色？

而不是先猜一个 region 再调用 census。

---

# 第二层：精确定位

### `probe_point(x, y)`

我会保留，但我不会叫“semantic anchor”。

因为它首先应该是**确定性像素诊断接口**：

```text
base_rgb
current_rgb
hsvl
region_id
selector_score
nearby statistics
```

尤其关键的是：

```text
selector_score
```

而不只是：

```text
this pixel is red
```

例如：

```text
colorSel score = 0.83
regionSel score = 1
lumSel score = 0.92
final selection = 0.76
```

这样 agent 能真正理解：

> 为什么这个点被选中了？

---

# 第三层：选择器验真

这里我觉得 Gemini 少了一层。

### `selection_certificate(sel)`

不是仅仅显示 mask。

应该直接返回：

```text
pixel_count
coverage
bbox
connected_components
largest_component
centroid
edge_ratio
score histogram
sample points
```

再附加：

```text
low-res mask preview
```

这才是真正有价值的。

因为：

> mask 是给人/VLM看的；certificate 是给 agent 算的。

两种信息应该同时存在。

---

# 第四层：修改结果验真

### `impact(edit)`

这个比 Gemini 的三个 affordance 都重要。

执行前/执行后告诉 AI：

```text
changed_pixels
ΔE mean/max/p95
bbox
affected_components
luma_delta
alpha_delta
gamut_clip_count
```

还可以：

```text
changed_area / selected_area
```

这能直接检测：

> “我只想改苹果，为什么桌子也发生了变化？”

这时候 AI 不需要凭视觉主观判断。

---

## 我会砍掉什么？

我不会砍 `mask preview`，但我会把它降级为：

> **human/VLM inspection tool，而不是控制闭环的主要信号。**

我甚至会把 Gemini 的三个东西合并成：

```text
inspect_selection(selector)
```

返回：

```text
certificate
+
spatial stats
+
sample points
+
preview mask
```

然后增加：

```text
inspect_edit(edit)
```

这样 API 更干净。

---

# 4. 我会怎么做最小验证实验

这里我和 Gemini 的方案差别比较大。

Gemini 的：

> `recolor + hue census + mock agent + 红苹果变绿`

我认为**太像 demo，不像证伪实验。**

因为它只能证明：

> “这个 happy path 可以走通。”

不能证明 MVSL 的核心假设成立。

---

# 我的最小实验会分成两个极小阶段

## Phase A：先证明 IR 本身成立

只实现：

```text
colorSel
recolor
render
canonical JSON
```

再做四个 invariant。

### Invariant 1：identity

```text
render(base, [])
== base
```

逐像素 hash 完全一致。

### Invariant 2：replay

```text
parse(canonicalize(program))
→ render
```

结果 hash 不变。

### Invariant 3：undo

```text
P = [A,B,C]
undo C
undo B
undo A
```

最终必须逐位回到：

```text
base
```

### Invariant 4：序依赖显式存在

构造：

```text
A = recolor(red→green)
B = relight(red,+20%)
```

验证：

```text
A∘B != B∘A
```

然后明确把这种序依赖写进 IR 语义，而不是把它当 bug。

这一阶段几乎不需要 AI。

---

# Phase B：再证明 AI affordance 真能解决定位问题

测试图不要只放一只苹果。

至少造一个极小的 adversarial corpus：

```text
图 1：
红苹果 + 红桌布

图 2：
红苹果 + 红杯子

图 3：
两个相同红苹果，位置不同

图 4：
苹果主体红，阴影偏棕，高光接近白

图 5：
苹果边缘有红色反射光

图 6：
背景也存在相似 hue/saturation
```

然后比较三种 agent observation：

### A

```text
global census only
```

### B

```text
global census + probe
```

### C

```text
global census + spatial census + probe + selection certificate
```

每个 agent 都执行同一任务：

```text
把苹果变绿，桌子不变
```

但是**不要用“3 轮成功/失败”作为唯一指标。**

测：

```text
target precision
target recall
unintended changed-pixel ratio
selection IoU
number of actions
number of rollbacks
render time
```

然后真正问：

> **每加一种 affordance，误选率下降了多少？**

这才是在验证你的工具面设计，而不是测 VLM 的运气。

---

# 还有一个我会专门加入的测试：故意制造“诱导错误”

这是我认为 Gemini 没抓到的关键。

例如：

```text
苹果主体：
h = 2°
s = 80%

桌布：
h = 4°
s = 78%
```

视觉上它们颜色高度相似。

但：

```text
苹果 region = compact component
桌布 = huge background region
```

此时：

```text
colorSel
```

天然不够。

测试 AI 能否通过：

```text
spatial census
+
probe
+
regionSel
```

逐步收敛到：

```text
small compact component
```

这才真正检验你的核心哲学：

> **语义来自 AI，确定性执行来自 predicate + deterministic operator。**

---

# 最后，我会给 MVSL 一个比 Gemini 更严格的判断标准

我不会问：

> “AI 能不能把苹果变绿？”

我会问五件事。

### ① 语义稳定性

同一：

```text
base + edit table + engine version
```

是否永远得到同一像素 hash。

### ② 组合性

多个 selector/operator 是否有明确的：

```text
ordering
dependency
commutativity
fusion
idempotence
```

语义。

### ③ 可解释性

系统能否回答：

```text
为什么选到这个像素？
为什么没选到那个像素？
这一条 edit 到底改了多少？
```

### ④ 可诊断性

AI 是否可以在真正修改前，获得足够低成本的：

```text
selection certificate
```

并在修改后得到：

```text
impact certificate
```

### ⑤ 可扩展性

当你从：

```text
1 op
```

增长到：

```text
50 ops
```

以及：

```text
2K → 4K → 8K
```

时，系统是否仍然可交互。

---

## 我认为 MVSL 当前最值得优先补的，不是更多 selector

反而是这四个“元语义”：

```text
Selection domain
    BASE / STAGE_N / CURRENT

Operator algebra
    order / dependency / commutativity / fusion

Render semantics version
    color / numeric / selector / operator version

Inspection protocol
    census / probe / selection-certificate / impact-certificate
```

这四块如果定义扎实，`colorSel / lumSel / regionSel / geoSel / freqSel` 反而只是后面的扩展。

否则你会得到一个很漂亮的 selector 集合，但它实际上只是一个**高级 Photoshop macro recorder**。

而如果这四块成立，MVSL 才真正像一个：

> **面向人类 + AI 共同编辑的确定性图像程序 IR。**

这也是我对 Gemini 评审最核心的反驳：**它已经发现了“AI 看不清”的问题，但还没有充分审到“程序语义本身会不会随着组合而崩掉”。**后者才是我认为更值得现在就钉死的东西。
```


---

## 7. ChatGPT-B2 对抗审查（第二份）

我会把 Gemini 的结论改写成一句更准确的话：

> **它抓到了"观测不足"这个核心问题，但把它说成了三个 affordance 就能补齐，而且把"工程重组"说得过于轻描淡写。真正危险的地方，其实在选择语义的稳定性、算子组合语义、确定性边界和 agent 的可验证性。**

## 1. 我不同意 Gemini 的几个判断

### ① "精妙工程重组，而非数学突破"——前半句对，后半句有点低估

我不会把 MVSL 叫"数学突破"，但也不会把它简单归类成"把已有东西重新拼起来"。

真正有价值的不是 `HSV + mask + operator + JSON` 这些组件本身，而是你把它们绑成了一个**可重演的图像程序契约**：

`immutable base + canonical edit program -> deterministic render`

这会带来一组很硬的性质：

* 同一个 `base_hash + edit_program_hash` 可以重现同一图像；
* 人工操作和 agent 操作可以落到同一个程序语义；
* undo 不需要做逆运算，只需要回滚 program state；
* diff 的对象从"像素"变成"程序"；
* 编辑可以缓存、复制、审计、迁移、合并。

这不是新的图像数学，但它已经不只是 UI/工程拼装，而是在定义一种**图像编辑的中间表示与执行语义**。

真正值得警惕的是：这些性质**不是靠"canonical JSON"自动获得的**。

例如：

```text
recolor(red -> green)
relight(...)
```

和：

```text
relight(...)
recolor(red -> green)
```

通常不同。

如果你为了 canonicalization 把 operator 排序，反而会毁掉语义。

所以真正需要定义的不是"JSON 是 canonical 的"，而是：

> **什么叫两个编辑程序在语义上相同，以及什么时候两个 operator 可以重排、融合、消去。**

这其实是一个小型的 **image-edit algebra / IR semantics** 问题。

---

### ② "census 没空间信息，所以 3 轮内无空间辅助做不到精准定位"——论断太绝对

"census 对空间定位能力不足"我同意。

"所以 3 轮内必然做不到"我不同意。

反例很简单：

一张图只有一个红色物体，桌子完全是棕灰色；
`hue census + luminance census` 已经可能足够。

甚至只要工具输出里同时有：

```text
red pixels: 18342
bounding-box-like spatial statistic: absent
```

agent 仍可能通过视觉回图直接大致定位。

所以 Gemini 真正应该说的是：

> **census-only 的接口没有提供足够的、机器可验证的空间观测，因此在"多个语义候选共享相似颜色统计"的 adversarial scene 上会失效。**

这比"3 轮做不到"严谨得多。

而且"3 轮"本身没有太强的科学意义。
三轮到底是：

* select → inspect → edit？
* 还是一个 tool call 算一轮？
* render 是否算一轮？
* 参数修正是否算一轮？

更合理的是定义**interaction budget + success criterion**，而不是把 3 当作神奇数字。

---

### ③ "硬切边界产生锯齿杂边"——问题不在 predicate，而在 predicate 的语义

这个批评基本方向对，但说法不够精确。

`selector is a predicate` 并不等于：

```text
P(x) ∈ {true,false}
```

完全可以是：

```text
P(x) ∈ [0,1]
```

也就是一个 deterministic membership weight。

甚至可以有：

```text
colorSel
  -> soft membership
  -> morphology
  -> feather
  -> operator
```

问题真正是：

> **你的 selector contract 有没有定义边界、抗锯齿、软选择、邻域扩张/收缩，以及最终如何映射到像素。**

如果 predicate 严格二值，那么 Gemini 的担忧成立。

如果 predicate 可以是可确定计算的权重，那么这个并不是架构级缺陷。

---

### ④ "alternative architectures 在 wasm 约束下全部排除"——说得太满

"可微光栅化 / INR / program induction 不适合作为这个 MVP 的主执行模型"，我基本同意。

但"全部排除"是逻辑上过强的。

例如完全可以做：

```text
AI / neural model
    ↓
只负责提出 selector / 参数
    ↓
MVSL deterministic executor
```

甚至未来：

```text
neural proposer
    ↓
MVSL IR
    ↓
wasm verifier / executor
```

这已经是一个**混合架构**。

所以应该排除的是：

> "让神经网络直接成为像素执行器"

而不是排除所有 neural components。

---

# 2. Gemini 漏掉的东西，远比"三个 affordance"重要

这里我认为有几个是架构级问题。

## A. 最大的坑：selector 到底在什么阶段求值？

这是我认为你现在最应该钉死的一条。

假设：

```text
colorSel(hue=red)
recolor(red -> green)
```

那么下一次 render 时，`colorSel` 是对：

1. 原始 base 的 HSV？
2. 当前前序 operator 的结果？
3. 每个 operator 自己定义的输入场？

求值？

这三个语义完全不同。

如果 selector 看 current state：

```text
red -> green
```

第一次执行之后，那些像素已经不是 red 了。

于是 selector 的意义会发生漂移。

这对 AI 闭环尤其危险：

```text
round 1:
  select red
  recolor -> green

round 2:
  inspect
  recolor more green
```

如果 round 2 的 selector 重新在当前图像上求值，目标集合可能已经变了。

### 我会强制加一个概念：

```text
selector_source = BASE
```

默认所有 semantic selector 都在 immutable base-derived fields 上求值。

然后高级情况下才允许：

```text
selector_source = STAGE(n)
```

否则你的"selector 是谓词"最后会变成"**一个随 program 演化而漂移的谓词**"。

这个比 census 缺空间严重得多。

---

## B. 多 operator 的次序依赖与非交换性

这是 Gemini 没提，但对"编辑表 IR"非常核心。

例如：

```text
A = relight(+20%)
B = recolor(red -> green)
```

通常：

```text
A ∘ B != B ∘ A
```

还有：

```text
smooth ∘ recolor
```

与：

```text
recolor ∘ smooth
```

也不一样。

所以你至少要明确区分：

* **顺序敏感 operator**
* **可交换 operator**
* **可合并 operator**
* **可消除 operator**

这直接决定：

* canonicalization 能做什么；
* optimizer 能做什么；
* GUI/AI compiler 能不能生成等价 IR；
* undo / redo 是否可压缩；
* 两个 agent 的 edit table 能不能 merge。

### 更狠一点说

如果你现在的 canonical JSON 只是：

```json
{
  "ops": [...]
}
```

那它只是"确定序列化"，还不是"确定语义"。

你需要的是一个真正的：

```text
semantic IR
```

---

## C. "重复编辑"是否是 append，还是 mutate？

这是 AI agent 场景特有的大坑。

人类操作：

```text
把苹果调绿一点
```

agent 第一次：

```text
hue += 20°
```

看到结果后：

```text
再绿一点
```

如果你永远 append：

```text
op1: +20
op2: +20
```

那么 agent 每一轮实际上是在堆叠变换。

这会导致两个问题：

1. correction 不稳定；
2. 重试同一个 tool call 可能产生不同结果。

你需要区分：

```text
append_op()
```

和：

```text
update_op(op_id, params)
```

或者干脆让 AI 的"意图层"具有稳定 operation identity：

```text
edit_id = "apple_recolor"
```

后续 agent 在修改它，而不是不断追加。

这对"闭环收敛"比 probe 更重要。

---

## D. HSV 不是一个足够稳的语义坐标系

这是一个潜在的大雷。

特别是：

### 低饱和区

Hue 接近没有定义。

```text
S ≈ 0
```

一丁点数值噪声就可以让 H 大幅跳动。

所以：

```text
colorSel(hue=red)
```

对近灰像素可能产生很怪的行为。

### 高饱和 / 色域边界

"保明暗"的定义也不明确。

HSV 的：

```text
V
```

并不是：

```text
perceived lightness
```

也不是物理意义上的 luminance。

所以：

> `recolor 保明暗`

这个表述必须定义成**数值契约**，否则只是人类语言。

例如到底保：

```text
sRGB V
```

还是：

```text
linear-light Y
```

还是 perceptual `L`？

这会直接影响黑暗区域、高光、霓虹色、接近 clipping 的颜色。

### 我的建议

HSV 可以继续存在，但把它降级成：

> **一种 selector affordance field，而不是所有颜色语义的真理。**

执行层至少要明确：

```text
encoded RGB
linear RGB
perceptual L/chroma
alpha
```

各自是什么。

---

## E. Alpha 是一个被严重低估的问题

这是图像引擎很容易踩的坑。

例如一个透明像素：

```text
RGBA = (255, 0, 0, 0)
```

视觉上它"不是红色"。

但如果你的 `colorSel(red)` 直接看 RGB，它会被选中。

更糟的是半透明边缘。

如果：

```text
straight alpha
```

和：

```text
premultiplied alpha
```

处理不一致，recolor / relight / smoothing 都可能产生 halo。

所以必须明确：

* selector 是否忽略 `alpha≈0`；
* HSVL 是在 straight 还是 premultiplied domain 上计算；
* operator 是对 RGB 还是 unpremultiplied RGB 操作；
* 输出重新 premultiply 的时机。

这不是实现细节，是语义。

---

## F. "逐像素确定性"并没有覆盖非局部算子

你列出的：

```text
smooth
freqSel
regionSel
```

本质上都可能不是纯点函数。

例如：

```text
smooth(x,y)
```

依赖邻域。

`freqSel` 更麻烦，频域特征需要定义：

* window；
* kernel；
* boundary condition；
* tile；
* normalization；
* DC 分量；
* 尺寸不整除时怎么办。

所以：

> "逐像素 deterministic"

不足以成为统一执行模型。

更准确应该是：

> **给定固定输入场、固定参数、固定版本的 deterministic field transform。**

这样 pointwise 和 neighborhood operator 才能统一。

---

## G. AI 的 semantic anchoring 到底存在哪里？

这是我认为你的"selector 不是数据"原则最值得自我攻击的一点。

agent 说：

> "那个苹果"

这个语义最终必须落成某种东西：

```text
region id
mask
polygon
seed point
connected component
bbox
embedding reference
```

否则 replay 时根本没有"那个苹果"这个东西。

也就是说：

> **选择标准可以是 predicate，但语义锚点本身仍然需要某种不可变证据。**

否则：

```text
same base + same edit JSON
```

并不能重现。

一个比较干净的办法是：

```text
regionSel(
    semantic_anchor_hash,
    predicate
)
```

其中 semantic anchor 是 AI 已经确定下来的、不可变的外部事实。

这样可以保持：

> selector 是程序；semantic evidence 是它引用的 immutable input。

否则"零依赖 + 确定性 + AI 语义"三者之间会出现裂缝。

---

## H. 性能天花板会比 Gemini 想得更早撞到

第一次 MVP：

```text
一张图
几个 op
全图 render
```

完全没问题。

但 agent 很自然会变成：

```text
inspect
→ edit
→ render
→ inspect
→ edit
→ render
→ ...
```

4K 图 × 30 op × 每轮重新构建 HSVL / mask / frequency field，很快会把交互体验打爆。

真正需要考虑的是：

```text
field cache
selector cache
tile cache
dirty region
op fusion
memoized derived fields
```

尤其是：

```text
HSV(L) field
```

如果每次都从 base 全量重算，架构很快失去 agent affordance 的优势。

而 frequency selector / smooth 一旦引入，多级缓存和 locality 会更加重要。

---

## I. canonical JSON 的版本演进是个大雷

假设今天：

```text
recolor(h=120)
```

和一年后的：

```text
recolor(h=120)
```

执行公式有一处 rounding 改了。

那：

```text
same base hash
same JSON
```

也可能得到不同像素。

所以真正需要 hash 的不是：

```text
base + edit_table
```

而应该至少语义上等价于：

```text
base
+ edit program
+ color/number semantics version
+ engine semantic version
```

或者把后两者固定进：

```text
render contract version
```

否则你所谓的 reproducible render 其实只是：

> reproducible under today's implementation。

容器也需要明确：

```text
schema version
migration strategy
unknown-op behavior
forward compatibility
backward compatibility
```

---

## J. "编辑表可解释"不等于"JSON 可读"

这是 Gemini 完全没碰的一个产品层问题。

人看到：

```json
{
  "selector": {
    "h": [350, 20],
    "s": [0.42, 1.0],
    "l": [0.18, 0.83]
  }
}
```

并不会因此理解：

> "这是苹果，而不是桌子。"

真正需要的是**语义解释投影**：

```text
Why was pixel (812,431) changed?

✓ matched colorSel
✓ matched regionSel #17
✓ excluded by lumSel guard: false
→ recolor
→ relight
```

所以我会增加：

```text
explain_pixel(x,y)
```

它甚至可能比 `probe_point()` 更有价值。

`probe` 告诉 agent "这个点是什么"。

`explain` 告诉 agent：

> **为什么这个点被这个 program 改了。**

这对于 human GUI 也很重要。

---

# 3. mask preview + region census + probe，够不够？

**不够。远远不够。**

这三个解决的是：

> **"我看到了什么？"**

但闭环收敛还需要：

> **"我做了什么？"**
>
> **"它造成了什么？"**
>
> **"我现在是否比上一轮更接近目标？"**

这才是 control loop。

---

## 我会这样处理这三个 affordance

### `mask preview`：保留，而且是核心

但不要只返回一张小图。

最好同时返回：

```text
mask preview
bbox
area %
component count
centroid
```

因为视觉上"差不多"不等于机器知道选择范围。

---

### `probe_point`：保留，但升级

不要只返回：

```text
HSV(L)
```

应该至少返回：

```text
base pixel
current pixel
selector match
region/component id
alpha
operator trace
```

最好支持 batch：

```text
probe_points([(x1,y1), (x2,y2), ...])
```

因为单点 probe 很容易刚好落在：

* 边界；
* 阴影；
* anti-alias；
* 高光。

一个点不足以证伪选择器。

---

### `region census`：我不会砍掉，但会改定义

不要让它成为一个依赖外部"语义区域"的 primitive。

更好的定义是：

```text
components(selector_mask)
```

然后每个 component 给：

```text
area
bbox
centroid
mean HSVL
variance
```

这会把空间信息从"AI 自己脑补"变成**由 engine 从实际 selector 推导出来的事实**。

---

## 我一定要额外加两个 affordance

### ① `impact_report / dry_run`

这是最重要的新增接口。

AI 在真正 commit 前可以拿到：

```text
selected_pixels: 18342
changed_pixels: 17984

target:
  mean ΔL = +0.01
  mean Δh = +107°

outside selection:
  changed_pixels = 0

max ΔE outside target = 0
```

也就是：

> **不用再靠 VLM "看起来是不是对了"。**

这会极大提升闭环稳定性。

---

### ② `explain_pixel(x,y)`

这个是为可解释性和 debug 准备的：

```text
selector:
  colorSel = true
  lumSel = true
  regionSel = component#3

ops:
  recolor + relight

final contribution:
  hue: +103°
  luminance: +0.04
```

---

## 所以我最终的最小 affordance 集合是

```text
1. selector_preview()
2. components()/mask_stats()
3. probe_points()
4. dry_run()/impact_report()
5. explain_pixel()
```

如果必须砍到极限：

> **砍掉"独立的 region census API"，把它并入 selector mask 的 component stats。**

绝对不能砍：

> **mask preview + impact report。**

因为前者解决 spatial observability，后者解决 action observability。

---

## 更关键的是：闭环需要"单调性"

三件 affordance 本身不会让 AI 收敛。

要收敛，你最好让每次 mutation 都能报告：

```text
before error
after error
```

或者至少报告一组硬 invariant：

```text
outside(target):
    max_delta = 0

inside(target):
    hue_shift >= threshold

selection:
    changed_area <= expected_area * k
```

甚至可以直接把它变成程序契约：

```text
assert unchanged(exclusion)
assert affected_area < 25%
assert hue_delta(target) > 60°
```

这时 agent 就不再完全依赖自己的视觉判断。

**闭环从"VLM 看图"升级成"VLM + deterministic verifier"。**

这个变化比加一个 probe 强得多。

---

# 4. 如果让我定最小验证，我不会照 Gemini 那么测

Gemini 的实验：

> recolor + hue census + mock agent → "红苹果变绿，不动桌子"

作为**证明 census 的空间观测不足**，可以。

作为验证 MVSL，我认为太弱，而且有两个问题。

### 第一，它把"引擎 correctness"和"agent capability"混在了一起

如果失败，你不知道：

* selector 不行；
* affordance 不行；
* agent reasoning 不行；
* render 不行；
* color semantics 不行。

### 第二，"3 轮"没有解释力

你真正应该测的是：

> **在相同 scene、相同 agent、逐项增加 affordance 时，空间误选率和 interaction cost 如何变化。**

---

# 我会做一个极小但杀伤力更强的实验

## Scene

不要用真实照片。

做一张完全合成的图，故意制造歧义：

```text
256×256

左边：红苹果
右边：另一个红色物体
背景：棕色桌子
两个红物体具有重叠 hue histogram
苹果有高光、阴影、抗锯齿边缘
桌子存在接近红色的局部区域
```

目标：

> **只把左苹果变绿；右侧红物体、桌子、高光关系都保持。**

这样 ground truth 是精确已知的。

---

## 四个 API arm

### A

```text
census
render
```

### B

```text
A + probe_points
```

### C

```text
B + mask_preview + components
```

### D

```text
C + dry_run/impact_report
```

这比单纯"有没有三个 affordance"更有信息量，因为你能做 ablation。

---

## 每一轮测五个指标

### 1. Target IoU

最终 selector 与 ground truth 苹果 mask 的重合。

### 2. False-positive area

右侧物体和桌子被波及多少。

### 3. Outside-target ΔE

目标之外颜色到底变了多少。

### 4. Interaction cost

多少次 mutation / probe / render 才成功。

### 5. Engine cost

单次 render：

```text
ms
memory
cache hit rate
```

这样你能知道问题究竟是：

```text
semantic localization
vs
editor semantics
vs
performance
```

而不是把全部失败都归因给"agent 看不懂"。

---

# 但我还会再塞两个 engine-level test

这两个测试比真实 agent 更基础，也更重要。

## Test 1：selector 稳定性

同一个 base：

```text
P = colorSel(red)
E = recolor(red -> green)
```

验证：

```text
selection(P, base)
==
selection(P, render(base,E))
```

如果你规定 selector 是 base-space，这个必须成立。

否则整个 AI iterative editing 的语义容易漂。

---

## Test 2：组合语义

构造：

```text
A = recolor
B = relight
```

验证：

```text
render(A+B) != render(B+A)
```

然后明确规定：

```text
edit table order is semantic
```

并测试：

```text
serialize
→ parse
→ canonicalize
→ render
```

前后 bitwise identical。

这才是真正验证你的 IR 是不是"语言"，而不仅仅是"JSON 里的操作数组"。

---

# 我最终会把 MVSL 的核心风险排序成这样

| 风险                                 | 我认为的重要度 |
| ---------------------------------- | ------: |
| selector 求值阶段是否稳定                  |      极高 |
| operator 次序/组合语义                   |      极高 |
| semantic anchor 如何可重演              |      极高 |
| deterministic color/alpha 数值契约     |      极高 |
| dry-run / impact verification      |      极高 |
| AI 反复修正是否会 append 漂移               |       高 |
| 性能 / cache / 全图重渲染                 |       高 |
| canonical JSON 的 schema/version 演进 |       高 |
| mask 空间可观测性                        |       高 |
| HSV 在低 S / 高 gamut 情况下退化           |       高 |
| explainability / provenance             |      中高 |
| 三轮交互预算                             |       低 |

---

## 最狠的一句话

Gemini 抓到的是：

> **"AI 看不见选择范围。"**

但我认为真正更危险的问题是：

> **"AI 就算看见了选择范围，也未必知道这个选择范围在下一次 render 后还是不是同一个选择。"**

如果 `selector` 的语义空间、operator 的组合规则、semantic anchor 的可重演性、以及 mutation 的替换/追加语义没有先钉死，**mask preview 只能把一个不稳定的编辑语言变成一个更好看的不稳定编辑语言。**

反过来，如果这四件事先定义清楚，再加上：

```text
mask preview
+ component stats
+ multi-point probe
+ dry-run impact report
+ pixel explanation
```

你的"AI agent 全程可见地修图"才开始真正像一个**可验证的 program synthesis / execution loop**，而不只是"VLM 不停看图再猜下一刀"。
```


---

## 8. ChatGPT-A 盲评

先给结论：

**MVSL 作为“非破坏式图像编辑 IR / DSL”是成立的；作为“任意图像的通用可编辑源语言”目前还差一个关键维度：稳定、可验证、可组合的影响域（mask/field）系统。**

更直白一点：

> **你真正发明得有价值的，不是 `recolor / lumSel / freqSel` 这些图像处理算子；而是把“选择＝可计算谓词、编辑＝程序、原图＝不可变资产、AI＝程序生成与验证器”统一进一个确定性 IR。**

这有明显价值。但如果现在就宣称“5 个正交 selector + 若干算子足以把任意照片变成可编辑源语言”，我会反对这个表述。

---

# 1. 这个抽象到底成立到什么程度？

## 1.1 数学上成立，而且是一个很好的抽象

可以把你的东西写成：

$$
I_0 = \text{immutable base asset}
$$

$$
F = \Phi(I_0)
$$

其中 \(F\) 是 HSVL、边缘、频率、区域等派生场。

每个操作：

$$
I_{k+1}(x)
=
(1-w_k(x))I_k(x)
+
w_k(x)f_k(I_k(x), F(x), \theta_k)
$$

最后：

$$
I_n = P_n \circ P_{n-1} \circ \cdots \circ P_1(I_0)
$$

这就是一个非常正常、非常强的 **programmatic image editing** 模型。

而且你的一个设计非常正确：

> **selector 语义上是 predicate，不是结果 mask。**

这比“每次选择都生成一张巨大的 bitmap mask 并把 mask 当真相”干净得多。

但是工程上我要加一句：

> **“不是数据”不能等于“永远不物化”。**

应当是：

**semantic source = predicate；runtime representation = 可缓存的 materialized field/mask。**

否则每次 `colorSel ∩ lumSel ∩ regionSel` 都重新扫描整张图，复杂 selector、反复 render、AI 自查都会把性能打穿。

所以我建议：

```text
Selector AST
    ↓
canonical predicate
    ↓
cached evaluation field [0..1]
    ↓
operator
```

缓存是实现细节，不进入语义真相。

---

## 1.2 它与业界实践的关系：**底层大多是重新组合，上层确实有增量**

你列的这些东西几乎都不是从零发明出来的。

例如 Photoshop 现在的 Hue/Saturation 本身就是非破坏式 adjustment layer；Color Range 用模糊度控制选择范围，Adobe 也明确使用“fall-off / feathered adjustment”的方式避免硬边。([Adobe帮助中心][1])

亮度选择、mask、局部调整也是几十年的成熟范式；Adobe 当前文档仍然把“白/黑显示隐藏、灰色提供部分透明”作为 layer mask 的基础模型。([Adobe帮助中心][2])

超像素也不是新概念。SLIC / SNIC 一类方法本来就在做“把图像分成空间连续、颜色/特征相近的区域”；SNIC 还专门强调了 connectivity 和边界保持。([开放获取会议视觉基金会][3])

所以：

| MVSL 元件                                            | 新颖程度          |
| -------------------------------------------------- | ------------- |
| hue/color selection                                | 很低            |
| luminosity selection                               | 很低            |
| frequency separation                               | 很低            |
| superpixel / connected region                      | 很低            |
| parameterized adjustment                           | 很低            |
| non-destructive ordered program                    | 中低            |
| immutable base + program-as-state                  | 工程上很合理        |
| selector 作为一等 predicate                            | **有价值**       |
| 人类 GUI 与 AI 共用同一 IR                                | **明显有价值**     |
| field census → render → inspect 的 agent affordance | **真正值得押注的部分** |

因此如果你准备写论文/技术文章，我不会把贡献写成：

> “我们发明了一种新的照片编辑数学。”

我会写成：

> **“一种面向 agentic image editing 的 deterministic declarative editing language / intermediate representation。”**

这个定位准确得多。

---

# 2. 最大盲点是什么？

我认为有 **六个**，前三个是架构级问题。

---

## 2.1 第一大盲点：selector 的“空间边界”比 operator 难得多

这是整个系统最大的坑。

比如：

> 把蓝头发改成红色。

最简单：

```text
colorSel(hue=blue)
→ recolor(red)
```

马上就会出现：

```text
蓝头发
蓝眼睛
蓝衣服
蓝背景
蓝色反光
蓝色阴影
头发边缘的抗锯齿像素
```

所以真正需要表达的是：

$$
M =
colorSel(blue)
\cap
regionSel(hair)
\setminus
regionSel(eyes, clothes, background)
$$

而且不是 hard mask，而是：

$$
M(x)\in[0,1]
$$

这才是专业修图实际在干的事情。

### 零依赖情况下怎么解决软边界？

我不建议简单：

```text
hard mask → Gaussian blur
```

这是最容易做、也是最容易出 halo 的方案。

更好的零依赖基础设施是：

### A. 所有 selector 最终产生 soft weight

例如 hue：

$$
d_h(h,h_0)=\min(|h-h_0|,360-|h-h_0|)
$$

然后：

$$
w_h = smoothstep(r_{outer},r_{inner},d_h)
$$

sat/luma 同理。

这样：

```text
colorSel
lumSel
regionSel
geoSel
```

都统一为 `[0,1]` field。

然后：

```text
AND = a * b
OR  = 1 - (1-a)(1-b)
NOT = 1-a
```

这比到处写 if/else 干净很多。

### B. geoSel 要有 signed distance

手画区域得到 hard interior/exterior 后，不要直接二值化。

计算：

$$
d(x)=signedDistance(x,\partial M)
$$

再：

$$
w(x)=smoothstep(-f,+f,d(x))
$$

这样 feather 是数学定义的一部分。

### C. 发丝/物体边缘不要靠普通 blur

真正容易翻车的是：

```text
天空 | 发丝
树枝 | 天空
玻璃反光
人物边缘
物体半透明边缘
```

这里需要 **edge-aware feather / geodesic propagation**。

一个零依赖实现完全可以自己写：

```text
Sobel / gradient
      ↓
edge cost
      ↓
narrow-band propagation
      ↓
soft mask
```

也就是：**跨强边缘的距离比沿着同一物体内部的距离“贵”。**

这会比单纯 Gaussian mask 好很多。

---

## 2.2 第二大盲点：HSV 是很好的工程坐标，不是很好的“视觉真理”

这是我会主动要求你改 spec 的地方。

如果你的 `recolor` 是：

> Hue 替换 + 保持 Value

那么对于“蓝头发 → 红头发”这样的扁平视觉内容很好。

但对照片并不稳。

原因之一是 HSV 的 V 并不是人类感知的 lightness。

比如：

```text
RGB 0,0,255
RGB 255,0,0
```

两者 V 都是 1，但视觉明度不是同一概念。

而且：

* 低饱和像素的 hue 不稳定
* 灰色/白色几乎没有可靠 hue
* 高饱和区域换 hue 后很容易 gamut clipping
* 在 gamma-encoded RGB 上直接算 luminance 会产生语义错误

Oklab 这种感知空间就是为“lightness / chroma / hue”的处理设计的，而且计算形式并不复杂。([Björn Ottosson][4])

所以我不会删掉 HSVL，但我会把它定义成：

> **一个 selector/analysis field，不是唯一的视觉坐标系。**

至少应该有：

```text
RGB encoded
RGB linear
Luma
HSV/HSL-like
Lab/Oklab
```

然后 operator 明确写：

```text
recolor {
    hue_space: ...
    preserve: oklab.L
    gamut: compress
}
```

否则“保明暗”最终会变成一个非常含糊的 promise。

---

# 2.3 第三大盲点：AI 负责语义，意味着“可重复性”突然变得困难

这一点特别重要。

你说：

> 语义不内置在语言里，由多模态 AI 的视觉供给。

我认为**这个方向本身是对的。**

因为：

```text
“角色头发”
“天空”
“人的皮肤”
“墙”
```

这些不是底层图像语言应该知道的东西。

但是会出现一个问题：

### AI 看到“头发”，最终产生了什么？

如果是：

```text
geoSel([
  polygon...
])
```

很好。

因为文件里保存的是确定性的几何参数。

但如果是：

```text
regionSel(hair)
```

然后 regionSel 依赖某个外部视觉模型：

那么：

```text
打开项目
→ 模型 A
```

和

```text
第二年打开项目
→ 模型 B
```

可能根本不是同一块头发。

这直接破坏了你最看重的：

> deterministic / reproducible editing program。

所以我会规定：

### AI 的“语义”必须编译成 deterministic evidence

比如：

```text
AI: hair
↓
seed points
+
negative points
+
color constraints
+
region parameters
↓
deterministic regionSel
```

或者：

```text
AI: sky
↓
geoSel(boundary points)
+
colorSel(cold)
```

而不是：

```text
AI: sky
↓
opaque neural mask reference
```

后者会让你的 `.mpd` 变成“模型运行时 artifact”，不是一个真正稳定的编辑程序。

---

# 2.4 render → AI 看图 → 再改，存在一个很明显的收敛性风险

你现在的 loop：

```text
tool call
→ render
→ AI 看 render
→ tool call
→ render
...
```

很自然，但它不是保证收敛的算法。

可能出现：

```text
蓝头发太红
↓
AI 减少 hue shift
↓
又觉得不够红
↓
重新加大
↓
又觉得边缘不自然
↓
扩大 mask
↓
发现衣服变色
↓
缩回来
```

这不是“bug”，而是视觉 agent 常见的局部振荡。

### 所以 render 不能是唯一 verifier。

你需要一个：

> **objective diff / invariant verifier**

例如每个 edit 在 IR 中可以带：

```json
{
  "goal": {
    "targetCoverage": 0.22,
    "protectedRegions": [...],
    "maxProtectedDelta": 2.0,
    "preserveLuma": true
  }
}
```

render 之后，不只是给 AI 看：

```text
render()
```

而是：

```text
evaluate(edit)
```

返回：

```text
target coverage
protected coverage
mean color delta
mean luminance delta
boundary error
gamut clipping
changed-pixel %
```

这非常关键。

**视觉模型应该负责“理解有没有达到意图”，数学 verifier 负责“有没有违反硬约束”。**

否则 agent 很容易“看起来差不多”就自我确认。

---

# 3. census + render + sample 够不够？

**不够。**

但不是缺很多 operator，而是缺几个“闭环工具”。

我会分两档。

## A. 缺它闭环就不成立

### ① `selectPreview(selector)`

这是第一优先级。

AI 不能只调用：

```text
recolor(colorSel(...))
```

然后看最终图。

它应该先问：

```text
这个 selector 到底选中了什么？
```

所以需要：

```text
selectPreview(...)
```

返回：

```text
coverage
bbox
connected-components
edge-touch %
mean color
```

最好还能直接显示 mask overlay。

这是比 `render()` 更重要的工具。

---

### ② `diff(before, after, selector?)`

必须有。

例如：

```text
diff(protected=person)
```

得到：

```text
person:
  changed pixels: 0.3%
  mean ΔL: 0.4
  max ΔL: 3.2
```

否则“别动人物”只是自然语言愿望，没有可验证性。

---

### ③ `samplePatch(x,y,r)`

你现在的：

```text
sample(x,y)
```

我认为太弱。

单个 pixel 对照片来说经常没有意义。

比如坐标刚好落在：

```text
JPEG block artifact
specular highlight
anti-aliased boundary
noise pixel
```

最好变成：

```text
sample(x, y, radius)
```

返回：

```text
center RGB
mean
median
variance
HSV/Lab/Oklab
local gradient
local edge confidence
```

这样 agent 才能知道：

> “我点到的是蓝头发主体，还是头发边缘。”

---

### ④ `inspectImage()`

AI 修图第一步必须知道：

```text
width / height
color space
transfer function
alpha
bit depth
orientation
```

否则后面所有“保明暗 / gamut / color temp”都有隐含假设。

---

### ⑤ `renderPreview()` 与 `renderExact()`

不要只有一种 render。

AI 迭代应该：

```text
low-res preview
↓
verify
↓
exact render
```

否则大图 + 10 个 operator + segmentation 每轮都全分辨率跑，很快成为 agent latency 瓶颈。

---

## B. 缺它只是低效

这些可以后补：

```text
fieldCacheStats()
```

```text
regionList()
```

```text
editTable()
```

```text
reorderOp()
```

```text
simplifyProgram()
```

```text
compareVersions()
```

```text
renderRegion(bbox)
```

以及：

```text
explainSelector()
```

让 agent 能读取：

```text
“该 selector 覆盖了 18.2% 像素，
其中 94% 位于右上象限，
主要颜色簇为青蓝。”
```

---

# 4. 我会认真考虑哪些替代路线？

## 4.1 可微光栅化：**基本排除作为核心架构**

可微 rasterizer 很适合：

```text
几何参数
↓
renderer
↓
image loss
↓
gradient
↓
优化几何
```

Soft Rasterizer 这类工作就是让 rasterization 可以反向传播，用图像损失去优化几何/mesh。([arXiv][5])

但你的问题是：

```text
一个照片里的蓝头发
↓
我要把它改成红色
```

你根本没有需要优化的 mesh。

把它引进来会得到：

* gradient machinery
* non-convex optimization
* 更多数值不稳定性
* 更大的 runtime
* 更难保证确定性

**收益与问题完全不匹配。**

---

# 4.2 隐式神经表示 INR：**明确排除为底层**

INR 的思想是：

$$
(x,y)\rightarrow RGB
$$

或者：

$$
(x,y,z)\rightarrow feature
$$

很漂亮。

但你最重要的 invariant 是：

> **原始像素永远不被重新逼近。**

而 INR 天然是“用函数逼近图像”。

这和你的核心哲学冲突。

如果：

```text
pixel image
→ neural representation
→ render
```

那么哪怕视觉上几乎一样，也不能满足：

```text
empty program => original bit exact
```

除非你重新变成：

```text
immutable original + neural residual
```

那最后又回到了你的架构。

所以 INR 我会直接放弃。

---

# 4.3 程序归纳 / program synthesis：**值得认真对待，但应该在 MVSL 上面**

这个反而非常值得做。

架构应该是：

```text
vision model
      ↓
intent
      ↓
program synthesis / planning
      ↓
MVSL IR
      ↓
deterministic renderer
```

而不是：

```text
vision model
      ↓
image generation
```

换句话说：

> **MVSL 不应该与 program induction 竞争；MVSL 应该成为 program induction 的目标语言。**

这恰好和你的 agent 产品形态高度一致。

---

# 4.4 Diffusion / semantic editor：作为“外部视觉供应商”，不要放进核心 renderer

现在的 semantic image editing 经常依赖 mask / segmentation；例如 DiffEdit、InstructEdit 等路线都明确遇到“准确找到需要编辑的区域”和“保持未编辑区域”的问题。([arXiv][6])

这一类模型可以非常适合：

```text
AI：这是天空
```

或者：

```text
AI：这是头发
```

但不应该成为你的：

```text
render()
```

否则你的三个核心承诺：

```text
deterministic
pixel-preserving
zero-dependency runtime
```

全部变得模糊。

---

# 4.5 浏览器架构上，我反而不建议你急着 GPU 化

WebAssembly 2.0 已经正式包含 128-bit SIMD 等能力，这对于逐像素图像处理已经相当有用。([WebAssembly][7])

WebGPU 当前确实有 compute pipeline，可以直接执行 compute shaders，而且 WGSL 也已经在 W3C 标准轨道上推进。([W3C][8])

但是到 2026 年 9 月，MDN 仍把 WebGPU 标为 **Limited availability / 非 Baseline**。([MDN Web Docs][9])

所以我会做：

```text
MVSL semantics
    ↓
pure MoonBit CPU/WASM reference renderer
    ↓
WASM SIMD accelerator
    ↓
optional WebGPU backend
```

而不是：

```text
MVSL = GPU shader language
```

**语言层绝对不要绑定 GPU。**

---

# 5. 如果只做一个实验，我会怎么证伪？

不要做 demo。

做一个 **小型 adversarial benchmark**。

## 数据集

大约：

**100 张图**

分成：

### A. 动漫/插画

50 张：

```text
蓝头发 → 红头发
红衣服 → 绿衣服
黄色物件 → 紫色
保留明暗
```

专门考：

```text
colorSel
lumSel
regionSel
```

### B. 真实照片

50 张：

```text
冷天空 → 暖天空
不动人物
不动建筑
保持云的纹理
```

专门考：

```text
region
spatial boundary
color temperature
frequency/detail
```

---

## 每张图建立 ground truth

不是让人主观打分。

每张图都有：

```text
target mask
protected mask
target color intent
```

然后自动计算：

### 目标区

```text
color error
luma error
coverage
```

### 保护区

```text
changed-pixel %
mean delta
max delta
```

### 边界

单独取：

```text
mask boundary ± 3 px
```

计算 halo / spill。

---

## 同时跑四个系统

### Baseline 1

```text
global hue adjustment
```

### Baseline 2

```text
hue + luminance selection
```

### Baseline 3

```text
hue + spatial region
```

### MVSL

```text
colorSel
lumSel
regionSel
geoSel
freqSel
+
agent planning
```

这样你能知道：

> 到底是 MVSL 真有价值，还是只是“多写了几个参数”。

---

## 我会设置这些“架构失败线”

注意：这些不是行业标准，而是我会在实验里人为规定的**证伪门槛**。

### 失败线 1：表达力失败

如果超过 **30%** 的简单目标，需要：

```text
新增 selector 类型
```

才能表达，而不是现有 selector 可以组合出来，

那么“正交 selector 已接近通用源语言”的假设基本失败。

---

### 失败线 2：mask 复杂度失败

如果超过 **30%** 的真实照片案例需要：

```text
任意像素级 mask
```

才能把边缘修好，而 `colorSel + regionSel + geoSel` 始终无法稳定表达，

那说明你实际上缺的是：

> **first-class soft mask algebra**

而不只是继续增加 selector。

---

### 失败线 3：agent 闭环失败

在简单任务上：

```text
> 80% successful tasks
≤ 3 iterations
```

我认为是一个合理目标。

如果 agent 在非常简单的：

```text
蓝头发 → 红头发
```

上平均要：

```text
6～10 次 render
```

那不是一个好的 agent editing IR。

---

### 失败线 4：保护区域失败

例如“天空变暖，人物不变”。

我会设：

```text
protected region changed pixels < 1%
```

以及：

```text
mean perceptual color change
```

必须非常小。

如果 MVSL 经常出现：

```text
天空改好了
但脸也偷偷偏暖
```

那么你的 spatial semantics 没有闭合。

---

### 失败线 5：边缘失败

如果目标 mask 边界 ±3px 是大量错误的来源，

而且 soft feather 不解决，只能让 AI 不断扩大/缩小 mask，

那么：

> 不是 operator 不够，而是你的 field model 不够。

---

### 最重要的一个证伪标准

如果最终你发现自己不断往语言里添加：

```text
hairSel
skySel
skinSel
clothSel
faceSel
objectSel
reflectionSel
shadowSel
glassSel
...
```

**停。**

这证明你的“semantic-free language”开始偷偷变成：

> semantic object taxonomy DSL。

那就说明抽象走偏了。

---

# 6. 两个目标场景，我理想中的 agent 调用序列

这里我会稍微改一下你现在的 affordance。

---

## 场景 A：蓝头发 → 红色，明暗保持

理想：

```text
inspectImage()
```

得到：

```text
2048×2048
RGBA
source color space
bit depth
```

然后：

```text
fieldCensus(
    fields=[hue,saturation,luma]
)
```

找到：

```text
blue cluster
coverage = 8.7%
```

然后 AI 视觉定位头发，取几个正样本：

```text
samplePatch(x1,y1,5)
samplePatch(x2,y2,5)
samplePatch(x3,y3,5)
```

再取几个负样本：

```text
samplePatch(eye)
samplePatch(clothes)
```

然后：

```text
selectPreview(
    colorSel(
        hue=blue,
        saturation=...
    )
    ∩
    regionSel(seeds=[...])
)
```

查看：

```text
coverage
bbox
connected components
edge contamination
```

确认之后：

```text
apply(
    recolor(
        hue=red,
        preserve=perceptualLightness
    )
)
```

然后：

```text
renderPreview()
```

再：

```text
diff(
    protected=[eyes,clothes],
    boundary=3px
)
```

如果：

```text
eyes unchanged
clothes unchanged
boundary clean
```

最后：

```text
renderExact()
save()
```

关键点是：

> **render 是最后的视觉审查，不应该是第一次发现 selector 错了的地方。**

---

# 场景 B：照片天空变暖，不动人物

这里我绝对不会：

```text
colorSel(cold) → warm
```

直接干。

理想序列：

```text
inspectImage()
```

↓

```text
fieldCensus(hue,sat,luma)
```

↓

AI 根据视觉理解找到天空：

```text
samplePatch(sky1)
samplePatch(sky2)
```

人物作为 protected samples：

```text
samplePatch(face)
samplePatch(clothes)
```

↓

```text
selectPreview(
    geoSel(sky-seed/boundary)
    ∩
    colorSel(cool-range)
    ∩
    lumSel(...)
)
```

↓

检查：

```text
coverage
person contamination
cloud inclusion
boundary strength
```

↓

```text
apply(
    recolor / chromaticAdapt / temperatureShift,
    preserveTexture=true
)
```

↓

```text
renderPreview()
```

↓

```text
diff(
    protected=person,
    boundary=3px
)
```

如果人物出现暖偏：

```text
tighten selector
```

如果云层纹理被压掉：

```text
freqSel(detail)
→ preserve
```

最后：

```text
renderExact()
save()
```

---

# 我最终会怎么改你的 MVSL

我不会推翻它，反而会把它**收敛成更严格的东西**：

```text
Immutable Base Asset
        │
        ├── Analysis Fields
        │     ├── RGB-linear
        │     ├── Luma
        │     ├── HSV/HSL
        │     ├── Oklab
        │     ├── Gradient
        │     ├── Frequency
        │     └── Region
        │
        ▼
Selector Algebra
        │
        ├── color
        ├── luminance
        ├── region
        ├── geometry
        ├── frequency
        ├── AND / OR / NOT
        ├── distance
        └── edge-aware feather
        │
        ▼
Soft Influence Field [0,1]
        │
        ▼
Deterministic Operators
        │
        ├── recolor
        ├── relight
        ├── smooth
        ├── sharpen
        └── ...
        │
        ▼
Canonical Edit Program
        │
        ├── human GUI compiler
        └── AI agent compiler
```

最重要的三条原则，我会钉死：

### 第一

**selector 是程序，不是 mask；但 mask/field 可以被 cache。**

### 第二

**所有 AI 语义必须最终落成 deterministic evidence。**

例如：

```text
points
geometry
color constraints
region parameters
algorithm version
```

不要让 `.mpd` 隐含依赖某个未来 AI 模型。

### 第三

**render 不是 verifier。**

真正完整的 agent 闭环应该是：

```text
inspect
→ hypothesize
→ selectPreview
→ apply
→ renderPreview
→ objective diff
→ visual inspect
→ commit
```

而不是：

```text
apply
→ render
→ “嗯，好像不错”
```

---

## 最后一句判断

**我认为这个方向值得继续，但值得押注的是“Agent-oriented deterministic image-editing IR”，不是“MVSL 发现了新的图像处理原语”。**

底层 `HSV / luminosity / superpixel / frequency separation / masks` 基本都是成熟技术的正交化组合；真正有潜力的增量是：

> **把这些成熟 primitives 变成可组合、可审计、可重放、可由人和 AI 共同生成的程序。**

而目前最大的技术缺口只有一个词：

> **mask algebra。**

你现在的 selector 集合已经够做 demo；**还不够做“任意照片的源语言”。**
一旦把 soft field、selector composition、edge-aware boundary、deterministic semantic evidence、objective verifier 补上，这个架构才真正开始像一个完整的“图像编辑语言”，而不只是一个漂亮的 adjustment engine。

[1]: https://helpx.adobe.com/photoshop/desktop/adjust-color/color-corrections/apply-a-hue-or-saturation-adjustment.html?utm_source=chatgpt.com "Adjust hue and saturation in Photoshop | Photoshop"
[2]: https://helpx.adobe.com/photoshop/desktop/create-manage-layers/color-adjustment-fill-layers/use-layer-masks-to-target-adjustment-or-fill-layers.html?utm_source=chatgpt.com "Use layer masks for targeted adjustments in Photoshop | Photoshop"
[3]: https://openaccess.thecvf.com/content_cvpr_2017/html/Achanta_Superpixels_and_Polygons_CVPR_2017_paper.html?utm_source=chatgpt.com "CVPR 2017 Open Access Repository"
[4]: https://bottosson.github.io/posts/oklab/?utm_source=chatgpt.com "A perceptual color space for image processing"
[5]: https://arxiv.org/abs/1901.05567?utm_source=chatgpt.com "Soft Rasterizer: Differentiable Rendering for Unsupervised Single-View Mesh Reconstruction"
[6]: https://arxiv.org/abs/2210.11427?utm_source=chatgpt.com "DiffEdit: Diffusion-based semantic image editing with mask guidance"
[7]: https://webassembly.org/news/2025-03-20-wasm-2.0/?utm_source=chatgpt.com "Wasm 2.0 Completed - WebAssembly"
[8]: https://www.w3.org/TR/WGSL/?utm_source=chatgpt.com "WebGPU Shading Language"
[9]: https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API?utm_source=chatgpt.com "WebGPU API - Web APIs | MDN"

