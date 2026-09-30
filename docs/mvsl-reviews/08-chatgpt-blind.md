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
