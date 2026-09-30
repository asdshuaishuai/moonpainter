# MoonPainter v0.1 开发方案（已批准并完成）

> **后续规划**：v0.2（MVSL 确定性编辑 IR）见 [PLAN-MVSL.md](PLAN-MVSL.md)，
> 评审依据见 docs/mvsl-reviews/ 与 docs/mvsl-synthesis.md。

> 2026-09-29 批准稿 + 实施结果。工程名 MoonPainter（用户确认拼写）、
> 全新 MoonBit 标准（moon.mod/新 moon.pkg）、本轮聚焦 .mpd + 绘制、
> 外部格式兼容整体延后。复用策略：只用本工作区自有 MIT 代码并保留出处注释；
> moonviz 的 deflate.mbt（第三方 Apache-2.0 内嵌）明确不用。

## 实施结果（对照 §7 验收口径）

| 项 | 结果 |
| :-- | :-- |
| `moon check` | 0 error / 0 warning |
| `moon test --target native` | **51/51 全绿** |
| CRC32 已知答案 | ✅ `"123456789"` → 0xCBF43926 |
| SHA-256 NIST 向量 | ✅ 空串 / "abc" / 双块 448 位 / 百万 'a' 四向量 |
| deflate/inflate 往返 | ✅ 15 项（ASCII/中文/JSON/随机/空/边界 1/2/3/257/258/259/260/三档级别/确定性） |
| ZIP 往返 + UTF-8 名 + 确定性 | ✅（含小件存储/大件压缩/媒体 stored/CRC 读回校验） |
| PNG 编解码往返 | ✅ 1×1、64×64 渐变+随机 alpha、编码确定性+真压缩断言、坏签名/截断/空拒绝 |
| golden 渲染 | ✅ 固定场景 sha256 `9caa1c1d…e5195` 锁定；重渲染字节一致 |
| 混合公式数值验证 | ✅ multiply→黑、screen→品红、normal→蓝、50% 透明度→127/255 |
| mpd 往返/确定性 | ✅ pack→unpack 保真；两次 pack 字节一致；pack→unpack→pack 字节一致 |
| mpd 拒绝清单 | ✅ 垃圾/截断/篡改 design（指纹对账）/坏 format/前向版本/缺部件/路径穿越/资产哈希对账/源头拒绝（假 hash、幽灵资产、超限画布） |
| e2e（agent 会话） | ✅ vision 闸→new→绘制→render（b64 可解回 PNG）→pick→lint→undo/redo（指纹复原）→save/open-b64（指纹一致）；编组/解组/重排/删除+undo；add-image 资产链 |
| e2e（cli 文件层，native） | ✅ 原子写→读回；save-mpd 落盘→unpack→open-mpd 指纹一致 |

## 原方案存档

### 0. 决策摘要

- 改名 MoonPainter：目录 `deepStudio/moonpainter`，模块名 `moonpainter`（新标准裸名），容器 `.mpd` = MoonPainter Design package。
- 全新 MoonBit 标准：`moon.mod`（TOML）+ 新版 `moon.pkg`（参照 deepOffice/system1 已迁移范例）。
- 本轮范围：① `.mpd` 容器全环；② 参数化绘制引擎；③ 最小人机交互闭环（CLI 行协议 + vision 闸 + undo）。
- 明确不做：PSD/AI/Sketch 等外部格式兼容、文本层、自由笔刷、蒙版/调整层/图层样式、collab、16/32-bit、CMYK。

### 1. 代码复用策略

只复用本工作区自有 MIT 代码（deepOffice/moonviz，文件头核实无第三方内嵌），复制保留出处注释；无现成实现的部分（PNG 解码、SHA-256、IR/canonical JSON、形状光栅、mpd 容器、agent/cli）全部新写。已核实清单：deepOffice/ooxml 的 zip(326)/zip_write(214)/deflate(324)/inflate(484)/deflate_test(276)，moonviz/playground 的 png(332)；FFI 与行协议模式取自 deepOffice cli 与 moonviz cli。

### 2. 包布局（实际落地与方案一致）

base → codec → core → render → mpd → agent → cli，依赖严格无环；文件 FFI 与原子落盘在 cli（native-only），引擎包全部纯字节进出（wasm 可检）。

### 3. .mpd v1 结构

manifest.json + meta/{design,params,vision,agent}.json + assets/sha256/<hash> + previews/{flat,thumb}.png；
canonical 指纹贯穿；pack 确定性；拒绝式 unpack；限额；tmp+rename 原子写；b64 双通道（save-mpd-b64/open-mpd-b64）与路径通道（save-mpd/open-mpd）。

### 4. 绘制能力

含：矩形（圆角）/椭圆/线段/多边形填充与描边；纯色+线性渐变；7 种混合；组（直通）；仿射变换（平移/缩放/旋转/翻转经逆变换内点测试）；PNG 导入（8-bit 非交错，inflate+filter 逆变换）；取景渲染；pick；直方图；2×2 子采样 AA。
不含（诚实边界）：文本、贝塞尔、蒙版、调整层、fx、智能对象、16/32-bit、CMYK、自由笔刷。

### 5. 实施顺序（每步 check 绿再前进）

S1 重命名+新标准迁移 ✅ → S2 codec 基座 ✅ → S3 base+core ✅ → S4 render+golden ✅ → S5 mpd ✅ → S6 agent+cli+e2e ✅ → S7 文档（本文件 + DESIGN v0.2 + README）✅

### 6. 风险与对策（事后复盘）

- PNG zlib 壳与 raw inflate 的接驳：实测踩中并修复（解码端剥 zlib 头 + adler32 校验）；截断在 IEND 尾部时图像仍完整 → 按拒绝式纪律加严为"缺 IEND 即拒绝"。
- 新工具链差异（实测踩中并修复）：插值内不允许二元运算、`String::from_char`/`find_first_of`/`substring`/`Map::new` 弃用或不存在、FFI 指针参数需 `#borrow` 属性行、`?` 传播不可用、`as`/`opaque` 是保留字、Bytes 只读需经 Array 中转。
- 固定 Huffman 压缩率一般：接受（deepOffice 同款）。
- 大画布内存：4096 渲染护栏 + viewport 取景。

---

## 补遗：最小引擎收尾轮（2026-09-29，"继续完成最小引擎实现和可验证"）

对照方案审计发现两处承诺未落地 + 可验证性缺口，本轮补齐：

1. **flip 翻转**（§5 承诺"平移/缩放/旋转/翻转"中的翻转此前缺失）：IR 增 flip_h/flip_v
   （先翻转后旋转），canonical JSON 增 `"flip_h"/"flip_v"`，渲染逆映射支持，新增
   `flip <id> h|v|both|none` 命令；测试：命令往返指纹复原、JSON 往返、渲染镜像像素换边。
2. **render overlay**（§5 承诺"层 bbox + id 标注线框"此前缺失）：
   `render … overlay=1` 为每个可见非组层画 1px 序号色 bbox 线框 + 3×5 数字序号标注
   （8 色循环调色板），供多模态做像素↔结构对位；测试：线框色可检出、回包 overlay 标记
   与 sha256 区分。
3. **verify.sh 一键验证门**（可验证性从"引擎自证"升级为"外部独立验证"）：
   - moon check 零警告 → native 56 项全绿 → wasm-gc 可检 + 54 项全绿
     （少的 2 项是正确门控的 native-only CLI 测试）；
   - CLI 子进程端到端（含 add-image 位图资产，python3 标准库生成最小 PNG）；
   - **独立 unzip 验证**：系统 unzip -t + 条目齐全 + manifest 标识 + 元参数层文本可读，
     不依赖引擎自解压器自证（deepOffice 先例）；
   - **open→save 字节一致**：进程级确定性闭环。
4. **顺手修复**：`load_mpd` 不再向编辑历史追加 "open-mpd" 伪条目——打开容器不应
   篡改历史，这也是 open→save 字节一致的前提。

**最终口径**：`moon check` 0/0；native **56/56**；wasm-gc **54/54**；`./verify.sh` 六步
**ALL VERIFY PASS ✓**。

---

## 补遗 2：AI 修图 demo 轮（2026-09-29，"AI 同步修图 + wasm SDK + 全程 MoonBit"）

1. **引擎 wasm 面**（wasm/ 包）：经典 wasm（WASM MVP、零 import、宿主中立）；
   输入 in 槽（UTF-8 ≤4 字节小端块）+ `mp_exec_in`（与 CLI 同一分发器）+
   字符串指针读出（`[len@ptr-4][UTF-16LE]`，deepDesign engReadStr 同款 ABI）；
   Node/浏览器双宿主冒烟 + 引擎内合同测试。
2. **agent 框架选型**：mooncakes 调研 → `DC-Z-lab/moonllm`（OpenAI 协议库）锁
   `+native` 不适用浏览器弃用；采用 **`colmugx/posoco` 0.20**（六边形端口框架，
   moonbitlang/async 之上，js target 编译 0 错误）。三端口扩展：
   ModelPort（OpenAI wire fetch）/ ToolProvider（19 个修图工具 → 引擎命令行，经
   wasm 实例执行）/ Observer（每个事件转人类可读日志——"全程可见"官方通道）。
3. **LLM 接入**（deepOrca 模式）：`POST {base}/chat/completions` + Bearer +
   function tools + `choices[0].message` 解析 + tool 回放由 posoco 内核承担；
   传输 `moonbitlang/async/http`（js 后端 = fetch）。provider 预设（DeepSeek/
   StepFun/OpenAI/自定义）+ models.dev 式微目录（context/vision/tool_call）。
   Mock 脚本模型离线可完整演示（每轮真实吐 tool_calls）。
4. **视觉闭环**：render 工具 → `ToolOutcome::SuccessWithAttachments` +
   `Content::Image(image/png)`——渲染 PNG 作为附件回传多模态模型，AI 看图确认
   再继续；同时经 Observer 流给页面画布。
5. **e2e 抓出并修复 3 个真问题**：① `set_style` 的 undo 快照在修改之后入栈
   （恢复的是已改状态）——移到修改前，其他命令本就正确；② mock 的图层 id 与
   引擎分配 id 不对齐（`args_to_tail` 键表漏 `id`）——修复，这是 AI 修图
   "id 对齐"问题的真实缩影；③ open→save 的 agent.json 伪条目破坏字节一致性。
6. **验收（实测口径）**：`moon check` 全 target 0 错误（js 0 警告）；
   native 58/58、wasm-gc 56/56、js 57/57；`./build_demo.sh` 四步
   **DEMO BUILD PASS ✓**（含 Node headless：3 工具 3 成功、渲染 PNG 回传、
   .mpd 打包）；`./verify.sh` 六步保持全过。

---

## 补遗 3：六维审计轮（2026-09-29，载入 moonbit-ide / testing-strategy / codebase-design skill）

按 实现 / 可验证性 / 功能完备性 / SDK 完整性 / 工具完整性 / 协议完整性 六维证据驱动审计。

**审计中发现并当场修复**：① PLAN §6 承诺的 `inspect`（元参数层全文）未实现——补齐
（manifest 摘要 + design.json 全文 + params + edits 一次返回；>4MiB 分页属诚实边界）；
② LLM 工具面缺 group/ungroup/tag/undo（undo 对 AI 自我纠正尤其关键）——补齐至 23 个。

### D1 实现（codebase-design 词汇）
- 依赖图实测严格无环：base→∅；codec→∅；core→{base,codec}；render→+core；
  mpd→+render；agent→+mpd；wasm→{agent,core}；cli→{agent,core,mpd}；demo→{core,agent,posoco,async}。
- 深模块判定：`agent.exec`（1 行命令 → JSON 信封，隐藏闸/undo/谓词/指纹）✓深；
  `mpd.pack/unpack`（2 函数藏 ZIP/CRC/sha256 对账/限额）✓深；`render.render_view`
  （文档+取景 → 像素，隐藏 AA/混合/变换）✓深；codec 广而浅是编解码层本性（40 pub fn
  皆为格式原语），可接受。
- 接缝真实性："两个适配器=真实接缝"——`agent.exec` 这一个接缝上有 CLI、wasm、
  demo-ToolProvider **三个适配器**，接缝真实 ✓。
- TODO/FIXME 全仓 0（唯一 grep 命中是 \uXXXX 注释误报）。

### D2 可验证性
- 12 个测试文件覆盖全部 9 个引擎/宿主包；三 target 矩阵（native 59 / js 58 / wasm-gc 57）；
  已知答案（NIST SHA-256、CRC32）、golden 渲染 sha256、pack/open→save 双确定性、
  八类拒绝矩阵、独立 unzip、headless e2e、双验证门。
- 未测路径（登记）：PNG 灰度/RGB/灰-alpha 解码（仅 RGBA 往返）、多 IDAT、ZIP64 读取
  （继承 deepOffice，无合成样本）、Windows 原子写退化分支（POSIX 实测）。

### D3 功能完备性（承诺 vs 交付）
交付：容器全环/确定性/拒绝式 ✓、绘制（矩形圆角/椭圆/线段/多边形、双色线性渐变、
描边、7 混合、透明度、旋转+翻转、编组、PNG 位图）✓、渲染（AA/取景/overlay/pick/
直方图/golden）✓、会话（vision 闸/undo/35→36 命令）✓、wasm SDK ✓、AI 修图 demo ✓。
文档化未做（诚实边界）：文本/贝塞尔/蒙版/调整层/fx/16bit/CMYK/自由笔刷/PSD 家族
兼容/params live 绑定/vision 锚点/MCP/SKILL/collab。

### D4 SDK 完整性
6 导出（mp_version/mp_reset/in_reset/in_push/in_len/mp_exec_in）双 target（wasm+wasm-gc）
同面；双宿主（浏览器 fetch / Node fs）加载 + 冒烟；合同测试在引擎内。
缺口（登记）：单全局会话（无句柄多路复用）；无 wasm 侧原始 meta 层读取
（经 exec 的 list-layers/inspect 可覆盖绝大部分需求）；无 .d.ts/npm 包装。

### D5 工具完整性
CLI 31 命令 → LLM 23 工具。本轮补 group/ungroup/tag/undo 后，LLM 面缺口仅剩：
set-param/list-params/fingerprint/edits（刻意不暴露——纯元数据与记账，对修图无用）
与 add-image/open-mpd（页面职责）。判定：**修图语义面已闭合**。

### D6 协议完整性
.mpd v1：前向版本拒绝（容器级+文档级双层）✓、指纹链（manifest↔design 对账）✓、
逐条目 CRC ✓、路径安全 ✓、限额 ✓、确定性 pack + open→save 字节一致 ✓、原子落盘 ✓；
vision.json 为注册表存根（anchors 空）、params 纯元数据、source/ 层保留未用——三者
均已在 DESIGN/README 声明。CLI 行协议与 wasm ABI 信封同构（{ok}/{error}+指纹）。

### 审计后口径
native **59/59**、js **58/58**、wasm-gc **57/57**；`./verify.sh` 六步 ✓、
`./build_demo.sh` 四步 ✓；LLM 工具 **23**、CLI 命令 **36**。

---

## 补遗 4：审计缺口修复轮（2026-09-29，"那就修复"）

补遗 3 登记的缺口全部修复，验证门全绿后收口：

1. **wasm SDK 多会话（结构欠账之首）**：新增 `mp_open()`（句柄）/`mp_close(handle)`/
   `mp_exec_h(handle)`——宿主可同时开多文档，会话表在实例内 Map 隔离。
   旧默认会话面（mp_reset/mp_exec_in）原样保留，demo/dist 零改动兼容。
   合同测试：双句柄状态隔离（h1 开门+h2 未开门各自正确）、关闭后未知句柄、
   h1 不受 close 干扰。
2. **PNG 解码补测（D2 登记未测路径）**：新增 wbtest 用包内私有 png_chunk/zlib_wrap
   手工造帧，覆盖色彩类型 0（灰度展开 R=G=B、alpha 补满）/2（RGB alpha 补满）/
   4（灰+alpha）、多 IDAT 拼接、filter 1（Sub 逆滤波）——共 5 新测试。
   过程中抓出测试自身两处期望值算错（多 IDAT 字节序、Sub 差分还原），解码器正确。
3. **ZIP64 读取合成样本（D2 登记）**：手工构造 ZIP64 EOCD + 定位器容器
   （0xFFFF/0xFFFFFFFF 触发分支），断言偏移改道后条目解出 + 普通路径不受扰。
4. **npm/.d.ts 包装（D4 登记缺口）**：`npm/moonpainter-sdk/`——package.json(type:module)
   + index.js（wasm 加载器：浏览器 fetch/Node fs 双通道、模块目录优先路径解析、
   字符串槽编解码、类型化门面 exec/render/saveMpd/open/close/execOn）+
   index.d.ts（信封/渲染/容器类型）。Node 冒烟全绿：默认会话修图回合 +
   多会话隔离 + 关闭句柄拒绝。
   顺手抓出 loader 路径解析 bug（解析到过期 dist 副本）——改为模块目录优先。
5. **build_demo.sh 升 5 步**：npm SDK 冒烟并入（多会话+渲染+容器）。

### 修复后口径
native **67/67**、js **66/66**、wasm-gc **65/65**；`moon check` 0 错误
（native 0 警告，js 1 条 main 包黑盒测试形态提示——工具链迁移预告，非代码问题）；
`./verify.sh` 六步 ✓、`./build_demo.sh` 五步 ✓。

## 补遗 5：MVSL 确定性编辑 IR 轮（2026-09-30，"按当前进度继续完成任务"）

### 做了什么

1. **MVSL 编辑引擎入库并修复**（`core/mvsl.mbt` + `pixel/`）：
   工作区里的这份 WIP 此前 `moon check` 62 条 warning、4 个测试失败、
   2 个测试无限自递归。修掉六处真实的数值/几何缺陷（sRGB 传递函数指数
   写成 3 而非 2.4、`mexp` 归约用 ln2 放缩却乘 e、gamut compress 在
   线性 RGB 上等比缩放导致纯红被压成黑、`rect_dist` 算的是到中心的距离、
   `evidence:null` 反解成空证据破坏 canonical 幂等、`msin` 归约区间过大
   带来 3e-8 截断误差），并为每一条补了回归测试。
2. **测试口径修正**：`*_test.mbt` 是 blackbox，包内符号必须写 `@pkg.x`；
   需要直接访问私有符号的用 `*_wbtest.mbt`。pixel 与 cli 的测试文件按此
   归位，`moon check` 与 `moon test` 双双 0 警告。
3. **affordance 命令面**（PLAN-MVSL §P1）：`select-preview`（overlay PNG +
   覆盖率/bbox/连通域事实）、`mvsl-impact`（逐算子 diff 证书 + 结果 PNG）、
   `mvsl-assert`（保护断言违反即信封 fail）、`mvsl-set/show/clear`；
   覆盖预览遵守「先全分辨率生成再降采样」。
4. **编辑表随容器持久化**：新增权威条目 `meta/mvsl.json` + manifest `mvsl`
   版本块（render_contract / selector_algo / color_semantics / op_semantics
   + program_sha256）；容器 **v1 → v2 升版**（不认识编辑表的旧引擎必须在
   入口拒绝，而不是少渲染一批编辑）；非 canonical 编辑表、指纹对账失败、
   半截状态一律拒绝。
5. **验证门升 7 步**：新增 MVSL 子进程 e2e（安装 → impact 校验改动像素数与
   泄漏率 → 合法程序放行/侵权程序被断言拦下 → 编辑表随容器往返且
   开→存字节一致）。

### 验收口径

`moon check` 0 error / 0 warning；`moon test --target native` **158/158**、
`--target wasm-gc` **156/156**；`./verify.sh` **七步全过**。
（对比补遗 4：native 67 → 158。）

### 补遗 5 追加：区域级 affordance（census / probe）

`census`：hue×sat 12×3 桶普查 + OKLab L 与 HSV V 均值**对照**（把「V 不是
感知亮度」从文档论断变成可读数值），`within=<sel>` 收窄区域并附覆盖率/bbox/
连通域事实。`probe`：单点 `r≤32` 邻域统计（OKLab 均值/方差、环平均色相、
边缘置信度 = 中心差分梯度 / 0.25 L·px⁻¹）+ 当前编辑表每个算子与断言在该点的
membership 与所属连通域 id。连通域 id 由新加的标签场给出，与既有的组件事实
共用同一趟栅格序扫描（编号严格一致）——用 bbox 做包含判断在 bbox 重叠时
会指错，这是 probe 必须拿到标签场而不是组件列表的原因。

两个命令共同破的是同一个循环依赖：AI 得先知道「画面里有什么」才能提选择子，
而定位恰是 VLM 最弱的一环。现在引擎把区域事实算成数值，模型只做语义判断。

### 补遗 5 追加二：编辑表接进渲染管线（`pixel ← render`）

这是上一轮自己写下的最大诚实缺口。语义钉死为
**`最终图 = apply(编辑表, 层合成底图)`**：

- `render` 新增 `render_layers`（层合成底图 = 编辑表求值与渲染的唯一基准）、
  `render_doc_with` / `render_view_with` / `render_view_overlay_with`；
  `render/doc`/`render_view` 保持原签名（= 空编辑表路径），调用方零改动；
- **先全画布求编辑表，再裁剪缩放**：选择子定义在画布坐标里，先裁剪会让同一条
  选择子在不同取景下命中不同的东西。`render_view_impl` 本就是"先全画布渲染
  再最近邻缩放"，插入点是天然的；
- **空编辑表逐位等价**：`run_program` 在 `ops` 为空时直接返回 base，所以
  既有 golden 与 open→save 字节一致断言全部不受影响（实测 129 → 136 全绿，
  没有一条 golden 需要改）；
- `previews/`、`render`、`stats`、`sample` 全部改用最终图——视觉通道给模型看
  底图，等于让它基于错图决策；
- **三条出口同一张图**：`render` 的 sha256 ≡ `mvsl-impact` 的 `result_sha256`
  ≡ 容器里 `previews/flat.png` 的 sha256。`verify.sh` 第 7 步把这条做成硬断言，
  它把"编辑表只是一份被存下来的数据"和"编辑表真的改变了渲染结果"区分开。

顺带补上两处**静态可判却漏在运行期**的校验（本轮发现的真问题）：
算子**前视 `stage:` 引用**（`n > 自身序号`）永远不可能满足，留到执行期会变成
"命令面收下了、渲染时才失败"；**带 `stage:` 基准的保护断言**在旧实现里声明与
实际求值基准不一致（`check_guards` 静默按 base 求值），这比直接拒绝更坏。
两者现在都在 `validate_program` 期拒绝——声明与行为必须一致。

### 补遗 5 追加三：MVSL 闭环在产品里可达（demo 工具面）

前两轮把引擎做完了，但 **demo 的 AI 用不到它**：demo 的工具面是手写的 30 个工具，
一个 MVSL 命令都没有——引擎再完备，产品里的模型也够不着。这轮补上：

- 新增 8 个工具：`census` / `probe` / `select_preview` / `mvsl_set` / `mvsl_show` /
  `mvsl_clear` / `mvsl_impact` / `mvsl_assert`（工具面 30 → 38）；
- **模型只写 JSON，base64 由 SDK 做**：命令面收的是 base64（行协议空白分词，
  内联 JSON 的引号空格会在分词阶段被切碎），但让 LLM 手搓 base64 是荒唐的——
  SDK 侧 `b64_text` 转换是它的本职；
- **图像类工具统一走附件**：`render` / `select_preview` / `mvsl_impact` 的 PNG 都以
  `SuccessWithAttachments` 回传。试选不看图 = 闭眼改色；影响证书不看图 =
  发现不了选区跑偏；
- mock 模型新增一条 MVSL 脚本路由，`demo_test` 增加第 3 个回合：普查 → 试选 →
  装编辑表 → 影响 + 断言 + 渲染，断言 5 次 MVSL 工具调用、3 张图像附件、
  编辑表 ops=1 且进了渲染管线（`leak_ratio:0`）、清表后 ops=0。

这一轮的意义是**把"引擎有能力"变成"产品里的 AI 用得上"**——否则前两轮的
闭环只是实验室里的闭环。

### 补遗 5 追加四：三个身份字段各司其职

接进渲染管线后暴露的一个宿主级陷阱：`fingerprint` 覆盖的是 design.json，
**编辑表变了它不会变**。宿主若只按文档指纹判缓存失效，编辑表改动后会继续
用旧图。修法不是改指纹语义（那会破坏容器的指纹对账），而是把三个身份字段
在 `render` 信封里并列给出，别让宿主猜：

- `fingerprint` = design.json 的 sha256（**编辑表不变它**）；
- `program_sha256` = 编辑表的 sha256，提为 `@core.program_sha256` 单一实现
  （容器 manifest 的同名字段改为复用它，杜绝两份实现漂移）；
- `render_sha256` = 渲染产物 PNG 的 sha256，**缓存失效判断认这个**。

配套测试断言这三者的变化关系（装编辑表 → 文档指纹不变、program 与 render
指纹都变；清空 → 三者都回到原值），把陷阱钉在测试里而不只是文档里。

### 补遗 5 追加六：把「必然空选」从静默行为变成明确错误

坐标系分家之后还留着一个同类入口：彩度窗的**数值范围**没有约束到物理可达
区间。`s_center` 允许 0..1，而 sRGB 全色域下 OKLCh 彩度的上确界只有 0.3225
（洋红 #FF00FF 处取得；纯红 0.258 / 纯绿 0.295 / 纯蓝 0.313）。于是
`s_center=0.85` 这种**必然一个像素都选不中**的选择子会被接受，命令返回
`ok:true`，调用方看到一张没变的图。

现在装表即拒，并说明真实上限。判据刻意取**窗的下沿**而非中心：
`center=0.4, half=0.2` 覆盖 0.2..0.6，与可达区间相交，是合法宽窗——
限制中心会误伤这类正当用法。

这条护栏立刻抓到了我自己写的 schema 示例（`s=0.85`）——它此前"通过"只是
因为 schema 的示例不参与求值。示例现已改用真实量级，并在注释里写明：
**"文档合法、语义为空"的示例比没有示例更坏**。

补遗 5 追加五：两套颜色坐标系分家（一个静默失败的闭环）

给 demo 接 `sel_schema` 时想验证「模型能不能照文档拼出可用的选择子」，于是
写了条闭环测试：probe 报数值 → 拼 `color` 选择子 → 看命中面积。**结果是
coverage 0**——一个像素都没选中，而且命令返回 `ok:true`。

根因：`color` 选择子的三个维度是 **OKLCh 色相 / OKLCh 彩度 / OKLab 亮度**，
而 `probe`/`census` 报的 `mean_h`/`mean_s` 是 **HSV** 色相与饱和度。同一个
像素：纯红 #C81E1E 的选择子坐标是 `h≈28, c≈0.20`，HSV 坐标是 `h=0, s=0.85`。
把后者填进前者，彩度维度距离 0.65 > 窗宽 → 全场权重 0。

这是整个系统最要命的一类 bug：**引擎把数字告诉模型，数字却不能用**——
引擎在"帮"模型避免当色度计，同时又在另一处让它必然填错；而失败是静默的
（选择子是软权重，填错了不报错，只是什么都不选）。

修法不是改文档措辞，而是**让坐标系无法混淆**：

- 新增 `pixel.ColorStats`：一组像素的颜色摘要，`sel_*` 与 `hsv_*` 并列；
- `ColorStats` + `ColorAcc` 是**单一实现**，probe 邻域 / census 区域 /
  连通域事实三处共用（此前三处各算一遍，正是漂移的温床），并由
  `stats_json` 统一序列化；
- 报告字段名带前缀，不再有裸的 `mean_h`：想喂选择子就得写 `sel_h`；
- `sel-schema` 命令（第 57 个命令）把语法、量纲、取值范围与"数值该取哪个
  字段"一并自证给出——示例由 canonical 写出器产出、由同一解析器验回，
  语法非法就 abort（宁可报引擎 bug 也不发一段照着写必然失败的示例）；
- 闭环测试反向钉住：用 `sel_h`/`sel_c`/`sel_l` 拼选择子必须命中 0.5
  （左半幅），并断言 `sel_*` 与 `hsv_*` 不雷同。

顺带把 `sel-schema` 的 `verified` 说准：它保证**语法**自证（写出器 → 解析器
→ 往返稳定），**能否在具体画布上求值**另有 `precondition`——`comp` 的种子
必须落在色窗内、`assetmask` 的资产必须已登记。「语法合法」与「在此画布上
有效」是两件事，含糊过去就是骗调用方。

### 补遗 5 追加七：lint 接上编辑表（让「引擎知道自己没干活」说出来）

坐标系与空选窗修完之后，我顺着同一条思路找还有哪些"静默成功"。答案是
**编辑表的"自我否定"状态**：装了非空编辑表，但整张图逐位未变。实测一路
命令全都返回 ok：

    select-preview → coverage 0（只是数字，不是告警）
    mvsl-set       → ok, ops 1
    mvsl-impact    → ok, changed_total=0
    mvsl-assert    → ok, 0 违规
    render         → ok（图没变）
    lint           → **0 违规**

只有 `changed_total=0` 这一个数字在暗示出了事，而它需要调用方先知道
"0 意味着我的编辑什么都没做"。模型装完表、渲染、看图，只会觉得"怎么没变化"，
然后在错误的假设下继续。

修法：`lint` 接上编辑表（`agent/mvsl_lint.mbt`），五类条目——

- **P0** 装了非空表却整张图逐位未变（归因到选择子：用 census/probe 重取
  `sel_*`，或先 select-preview 确认选区）；
- **P0** 保护断言被违反（用户的「别动 XX」被破坏——`render` 本身不查断言，
  没有 lint 就永远没人查）；
- **P0** 编辑表执行失败（静态校验过得了、求值才失败，例如 mask 资产未登记）；
- **P1** 某条算子未改动任何像素（其余算子正常时点名是哪一条，而不是只报整表）；
- **P1** 构造性空算子（`hue_deg=0` / `temp_kelvin=0` / `relight_gain=1` /
  `amount=0`）——与画布无关，一眼可判。

同一轮里补上的第六条：**空断言**（保护断言的选择子零命中）。它比"断言被违反"
更坏——被违反至少会响，空断言恒真，给出的是**虚假的安心**：用户以为
「别动背景」被机器守着，实际上那条断言什么都没守。实测 `mvsl-assert` 对它是
`violations: 0`，正是"通过"让人不再怀疑。

两处刻意的分寸：**空编辑表不报**（= 未编辑是合法状态，lint 不该对我还没改
任何东西报警）；**归因要准**——全是构造性空算子时说"选择子没命中"是误导，
所以分开报。

`verify.sh` 第 7 步加入硬断言：必然空选的编辑表必须被 lint 报出
「整张图逐位未变」，被违反的保护断言必须被 lint 报出——e2e 门从此也守住
"静默成功"这条线。demo 的收工检查里也加了 lint 调用并断言它被调到。

### 补遗 5 追加八：坐标单位别混（渐变端点是归一化 0..1）

前七条修的都是"引擎知道自己没干活却没人说"。这一条是我**照着自己文档里的
示例去画一张渐变**时踩出来的，属于另一类静默失败：参数合法、命令成功、
渲染成功，只是结果不是你要的。

`add-rect` 的 `x/y/w/h/stroke_w` 全是像素，而 `lgrad` 端点是**归一化到本层
bbox 的 0..1**。我顺手把端点也写成了像素：

    lgrad=#E8B23CFF,#B4361EFF,0,0,60,40      ← 本想写像素 (60,40)

结果：层建好了、`query-layer` 正常、`render` 成功、颜色确实是渐变——只是在
160×180 的层上 t 最大只到 60/5200≈0.012，整块几乎是纯 c0。**与纯色无异，
且没有任何提示。** 我原本是拿它当"照片"素材用的，采样六个点全是同一个色，
才回头看是渐变没生效。

这类错误的可恨之处在于它不报错：调用方只会觉得"渐变怎么不明显"，然后
去调颜色、调方向，而真正错的是单位。

修法分三层：
1. **入口拒绝**（`core.grad_endpoint_error`，`add-*`/`set-style` 共用）：
   端点越出 0..1 直接报错，错误文本带上换算后的归一化值——
   实测输出"本层 160×180 应写作 (0,0)→(0.375,0.2222222222222222)"，
   一步就能改对；
2. **lint 兜底**（P0）：手改 design.json 或外部构造的容器不经过入口，
   由 `lint_doc` 报出；
3. **工具字典写明单位**：字典是 help/list-tools 与 demo 工具描述的单一事实源。
   原先只在类型注释里写了"局部 0..1 端点"——**注释不是接口**，调用方看不到。
   新增纪律 8「坐标单位别混：带坐标的参数必须在工具字典里写明单位」。

`verify.sh` 第 4 步加入硬断言：像素坐标写进端点必须被拒绝，且拒绝信息必须
给出换算值。

### 补遗 5 追加九：leak_ratio 的判据错了，而且守着它的断言是假的

这一条是本轮最值得记的：**一个真实的产品 bug，被 5 处形同虚设的断言藏了好几轮。**

起因是我照文档例子画渐变时把归一化端点写成了像素（见追加八），修完顺手用
**真实渐变 + 柔边色彩窗**跑了一遍 MVSL 闭环——结果 `leak_ratio` 报 **8.52%**。

而 `out = lerp(in, op(in), w)` 在 `w=0` 处逐位取原像素，**"支撑集外被改动"
结构上只能是 0**。这个数字不可能非零——除非判据本身错了。

判据确实错了。`diff_report` 里：

    let inside = w.v[i] >= CERT_THRESHOLD     // 0.5，连通域证书阈值
    ... if inside { sel_de } else { leak += 1 }

`CERT_THRESHOLD` 是"哪些像素属于同一个连通域"的判据，被拿来判"哪些像素算
选区内"。后果：**软选择子的过渡带（0 < w < 0.5）被算成"选区外"**，于是每个
带柔边的选择子都报出非零"泄漏率"。

危害不是数字难看，而是**它把模型引向反方向**：`demo/catalog.mbt` 里给模型的
指导写着"leak_ratio 必须为 0（否则说明改到了选区外）"，模型看到 8.5% 会去
收缩选择子、加 shrink——而过渡带本来就是要改的区域。而且编辑器里所有柔边
选择子都会触发这个误导。

修法：把两个判据分开，各服务一件事——
- `w >= CERT_THRESHOLD` → `sel_de`（核心区平均 ΔE，"要改的地方"）
- `w > 0` → `leak_ratio`（支撑集，"算子有没有越界写"的安全网，恒为 0）

顺带修掉整表证书的一个相关错误：`cmd_mvsl_impact` 给 total 传的是**零场**，
零场里每个像素都在支撑集外，`leak_ratio` 退化成 `changed/total`、语义全错
（只是恰好没被序列化出来）。现在传**各算子权重场的逐点并集**
（新增 `pixel.field_union`）。

**然后是更难看的部分：为什么这个 bug 能活这么久。**

因为守着它的断言全是子串匹配：

    assert_true(imp.contains("\"leak_ratio\":0"), ...)
    grep -q '"leak_ratio":0' "$OUT/mvsl.log"

`"leak_ratio":0.0279` **以 `"leak_ratio":0` 开头**。所以泄漏率在 `[0,1)` 的
任何值都能通过——断言只拒绝 ≥ 1 的泄漏率。

同类子串断言全仓库共 5 处：4 处 `leak_ratio`（`verify.sh` 的 e2e 门、
`agent/schema_test.mbt`、`agent/mvsl_test.mbt`、`demo/demo_test.mbt`）
+ 1 处 `coverage`（`agent/mvsl_lint_test.mbt` 断言"该选择子一个像素都不命中"，
而 `coverage:0.348` 同样以 `coverage:0` 开头）。更糟的是 e2e 门那条用的是
**几何硬边**选择子（权重非 0 即 1），旧判据下泄漏本来就是 0——
它**永远测不到软边界**。

修法：
1. 数值断言一律精确解析（`@core.parse_json` + `as_num`，辅助
   `per_op_num`/`near`）；shell 里 `grep -E '"k":0[,}]'` 锚住字段值结尾；
2. `verify.sh` 第 7 步**补一个真实渐变 + 柔边色彩窗的场景**，并断言
   `changed_total > 0`（避免拿空操作"通过"）；
3. 写成纪律 11，并加两条反证测试（白盒软场 + 端到端渐变）。

反证过：把判据改回 0.5，白盒与端到端两条测试立刻失败
（`leak_ratio=0.3478` / `0.0279`），`verify.sh` 也在第 7 步失败——
修好的断言是真能抓住它的。

### 补遗 5 追加十：变异测试——「测试全绿」不等于「行为被守护」

前九条都是"用产品时踩出来的"。这一条换了个问法：**如果我把实现改坏，测试会说话吗？**

于是我写了 `mutation_scan.py`：往产品代码注入语义 bug，跑测试看能否抓住。第一轮结果
（10 个变异，8 个有效）就很尴尬——**5 个存活**：

    M1  lerp 忽略软权重（out=op(in)，硬边化）   SURVIVED
    M3  color 窗用色相 half 判彩度              SURVIVED
    M7  quant8d 四舍五入改截断                  SURVIVED
    M8  color 窗色相项漏掉 feather              SURVIVED

**M1 最刺眼：MVSL 最核心的那句话 `out = lerp(in, op(in), w)` 没有测试。**

把 w 换成常量 1.0（软权重对输出完全无效、所有柔边变硬边）——150 条测试全部通过。
原因是结构性的：已有断言全是**契约/结构**（覆盖率、连通域、bbox、泄漏率、
canonical 往返、容器字节一致），而唯一涉及像素数值的 render golden 走
`render_doc`（**空编辑表**），根本不经过 `lerp_argb`。整个"编辑表逐像素混合"
这条数值路径是测试盲区：

- M7 说明量化舍入（`+0.5`）没人管——`quant8d` 只被 `lerp_argb` 用，
  而 `lerp_argb` 只走编辑表/overlay 两条路；
- M3 说明彩度半宽没被守护（拿色相半宽顶替都行）；
- M8 说明**色相项**的羽化没被守护——我第一版补的羽化测试只覆盖亮度项，
  重跑才发现 M8 还活着。这直接促成了 `pixel.window3` 重构：三项（色相/彩度/亮度）
  判据同构却手写三遍，就是"三处各自算一遍"的温床（同铁律 7 的 `ColorStats`）。
  抽成单一实现点后，M8/M8b（单独漏掉某一项的羽化）都被抓住；
- 补 smoothstep 测试时又发现 **M12（羽化曲线退化成线性）也存活**——
  线性退化下中间权重仍严格在 (0,1)、核心区/窗外/覆盖率/泄漏率全部照旧，
  结构断言天生看不见曲线形状。

补了 5 条**数值语义**测试（逐像素 `out == lerp(in,op(in),w)`、量化 .5 进位、
三项羽化各自生效、s_half 参与判据、smoothstep 曲线），并把扫描器整理成
仓库工具。终态：**13 个变异，12 个被抓住**，唯一存活的 M2（去掉空表短路）
经分析是**等价变异**——ops 为空时循环体不执行、`cur` 仍是 base、`stages` 仍是 []，
与短路返回逐位相同，短路只是省掉 `SelCtx`/`FieldCache` 的构造。脚本里把它显式
标注为 `equivalent`，而不是让它冒充"覆盖漏洞"。

这条补遗和第九条是同一枚硬币的两面：第九条是**断言写错了**（子串匹配），
第十条是**断言根本不存在**（数值路径无人看）。两者都让"全绿"说谎。

### 补遗 5 追加十一：把变异扫描推到别的路径——同一个模式又出现两次

第十条把扫描对准了编辑表的数值语义。这一条换个方向：**别的路径上，
"全绿"是不是也在说谎？** 第二批 11 个变异覆盖图层合成（W3C alpha 公式 +
7 种 blend 模式）、几何选择子、SHA-256、PNG 扫描线、ZIP CRC。结果
9 个被抓住、**2 个存活**——而这两个又是同一个模式："某一步在某类输入下
恰好不起作用，于是没人测它"。

**N3：合成后不去预乘。** 正确公式是 premultiplied 合成后再除以 ao
（`o_r/ao`）。把它改成"直接返回预乘值"——全部测试通过。

为什么？因为仓库里已有的混合测试**全用不透明层**（alpha=255）。此时
`ao = 1`，预乘值就是直通值，`unpremul` 除以 1 等于没除——**那一步对不透明
输入毫无影响**。所以只要测试里没有"双方都半透明"的用例，这一步就永远
测不到。裸奔的是整条半透明合成路径：颜色会整片偏暗（实测 170 → 128）。
补了一条直接锁 W3C 公式数值的测试（`0x80000000` over `0x80FFFFFF`
→ `0xC0AAAAAA`，不去预乘会得 `0xC0808080`），外加一条"不透明时两种
算法必须一致"的对照，免得我把差异归错原因。

**N7：几何选择子丢掉羽化。** 上一批我刚给**色彩窗**的三项羽化补了测试，
甚至为它重构出 `window3` 单一实现点。但 `geo_field` 的 `window_membership
(d, g.feather, 1.0)` 是**另一个入口**——把 feather 写成 0（硬边）时全部测试
通过。测试跟着"我上次改过的地方"走，而不是跟着"承诺的语义"走，这就是
漏掉的机制。补了一条：矩形 + feather=4 必须产生中间权重，且内部为 1、
远处为 0。

顺带一提，N8（几何采样丢掉半像素中心偏移）被 **8 条测试**抓住——说明
"精确到像素中心"这件事本身有人守着，不是所有数值细节都裸奔。

终态：**23 个变异，22 个被抓住**，唯一存活的 M2 是已确认的等价变异。
覆盖路径已从"编辑表数值"扩到合成/blend/几何/哈希/编解码。

这两批的结论是一样的：**盲区不是随机的，它长在"某个条件分支恰好不生效"
的地方**（软权重在硬边选择子下、去预乘在不透明输入下、几何羽化在色彩
羽化的影子里）。变异扫描的价值就在于它不按人的记忆去找，而是按实际
执行路径去找。

第三批转向最"外围"的模块：覆盖预览、盒平均降采样、容器 manifest。
**P3 又中了一个**：manifest 的 `counts` 里把 `layers` 和 `assets` 互换，
全部测试通过。

这个位置值得单独说一句：`counts` 是**对外可见的事实**——工具和审阅者
据此判断"容器里到底有什么"。而 `verify.sh` 第 5 步的独立验证只检查
`format` 标识与条目齐全性，`mpd_test` 只断言 MVSL 版本块，**没有一处
读 `counts` 的数值**。于是 manifest 可以对着一个 3 图层 1 资产 1 参数的
容器说"1 层 3 资产"，从引擎到端到端门禁全部放行。补了一条精确取值的
测试（`@core.parse_json` + 逐字段 `JNum`，不用子串——纪律 11）。

顺带记一个方法论上的自我修正：P2 我第一版写成 `round_div(sa, n)` →
`sa / k / k`，看似"不做平均"，其实 `sa` 是 k×k 像素之和、除以 k² 就是
平均值——只在取整方式和边界（`n < k²`）上不同，属于**近似等价的坏变异**。
换成"直接输出左上角像素"后立刻被 2 条测试抓住。**变异本身选不好会谎报
盲区**，这和第 11 条是同一类错误：验证手段自己不可信，结论就不可信。

终态：**26 个变异，25 个被抓住**，唯一存活的 M2 是已确认的等价变异。

### 仍未落地（诚实边界，详见 README 与 DESIGN §8）

- **MVSL 编辑表是文档级的最终一遍**，不是图层：能改整张合成图，但还不能
  "只作用于某几个图层"或参与图层内部的混合序（`stage:n` 只切到算子序号）。
  要那种粒度得先有把图层单独栅格化的中间缓冲。
- `probe` 的单命令多点批量入口未加（多次 probe 可覆盖同一需求）。
- `recolor` 的边界带去污染（`I = αF + (1−α)B` 只改前景）未做。
- PLAN-MVSL §P3 Phase 2 的真 VLM 消融实验未做（需要真实多模态模型）。
