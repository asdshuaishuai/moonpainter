# MoonPainter — Agent 驱动的图层绘制引擎

> 状态：**0.1.0（.mpd 容器 v2 + 参数化绘制 + AI 修图 demo + MVSL 确定性编辑 IR 引擎已落地：
> native 148 项 / wasm-gc 146 项测试全绿；`./verify.sh` 七步验证门全过）**。
> 设计书 [DESIGN.md](./DESIGN.md) · 方案与验收 [PLAN.md](./PLAN.md) ·
> MVSL 规划与评审对照 [PLAN-MVSL.md](./PLAN-MVSL.md) · AI 修图 demo 见下节。

一句话：**moonviz 套路在位图绘制领域的进阶复刻** —— 纯 MoonBit、全新模块标准
（`moon.mod`/新 `moon.pkg`）、零第三方依赖、结构化命令 + vision 能力闸 + 不崩谓词；
**只服务具备完整图片视觉的多模态模型**（`session-open full_image` 硬闸，纯文本模型明确拒绝）；
专属容器 **`.mpd`** 双层结构为唯一事实源：

- **元参数层**（纯文本）：`manifest.json` + `meta/{design,params,vision,agent,mvsl}.json`
  —— canonical design.json 的 sha256 即**文档指纹**；编辑表另有
  `program_sha256`（两者不可互相替代：编辑表变了文档指纹不变，宿主缓存渲染
  结果要认 `render_sha256`）；
  `meta/mvsl.json` 是**当前 MVSL 编辑表**（渲染的真值输入），
  manifest 的 `mvsl` 版本块 pin 住 render contract / selector 算法 /
  色彩语义 / 算子语义四个版本号；
- **设计稿层**：`assets/sha256/<hash>`（内容寻址 PNG 资产）+ `previews/{flat,thumb}.png`
  （保存时自动渲染）+ 拒绝式校验（CRC / 指纹对账 / 前向版本拒绝 / 限额 / 路径安全）。

```
读元参数(list-layers/query-layer) ─► 拟命令 ─► 应用（vision 闸+谓词+undo）
─► render(取景 PNG b64 + sha256) ─► 视觉校验（pick/stats 给客观数值，模型看图判断）─► save-mpd
```

## 能力（0.1.0 实测口径）

| 域 | 内容 |
| :-- | :-- |
| 绘制 | 矩形（圆角）/椭圆/线段/多边形，纯色+线性渐变填充（**端点归一化到本层 bbox 的 0..1**；与同命令的像素参数 x/y/w/h 不同，写错会被入口拒绝并给出换算值），描边，7 种混合（normal/multiply/screen/overlay/darken/lighten/difference，W3C 合成公式），透明度，旋转（Taylor 三角）+ **翻转（flip h/v/both，先翻转后旋转）**，编组（直通），PNG 位图导入（8-bit RGB/RGBA/灰非交错） |
| 渲染 | 2×2 子采样 AA、取景渲染（归一化 viewport + 目标宽）、**overlay=1（层 bbox 序号线框 + 3×5 数字标注，像素↔结构对位辅助）**、pick 像素→层 id、直方图/覆盖统计、渲染确定性（golden sha256 锁定） |
| 容器 | pack/unpack 全环、确定性 pack（两次打包字节一致）、原子落盘（tmp+rename）、八类拒绝路径全测试 |
| 会话 | 57 个命令（字典 = agent/tools.mbt）、vision 闸、undo/redo（快照栈 ≤64）、编辑历史、P0–P2 lint |
| MVSL 编辑表 | 确定性声明式编辑 IR：谓词选择子（OKLCh 色相环/彩度/OKLab 亮度/几何/渐变/种子连通域/外部 mask 资产，全部输出 [0,1] 软权重场，可 Union/And/Diff 组合）+ 有序算子程序（recolor/temperature/relight，`out=lerp(in,op(in),w)` 去污染）+ 选区精修（grow/shrink/feather/fill_holes/keep_largest/guided filter）+ 保护断言；**是渲染的最终一遍**（`最终图 = apply(编辑表, 层合成底图)`，`render`/`previews/`/`mvsl-impact` 三条出口同一张图）；canonical JSON 往返幂等、旧引擎遇未知算子/更高版本一律拒绝、前视 `stage:` 与带 `stage:` 基准的断言在校验期拦下 |
| MVSL 闭环 affordance | `select-preview`（选择子→overlay PNG + 覆盖率/bbox/连通域事实，"AI 选 ID 不报坐标"）、`mvsl-impact`（逐算子 diff 证书：改动像素数/ΔE/选区外泄漏率 + 结果 PNG）、`mvsl-assert`（保护区约束违反则命令信封直接 fail，"别动人物"变成机器可验证约束）、`census`（hue×sat 12×3 桶普查 + OKLab L 与 HSV V 均值对照，`within=` 可收窄到某条选择子）、`probe`（单点邻域统计 + 边缘置信度 + 当前编辑表每个算子/断言在该点的 membership 与连通域 id）、`sel-schema`（选择子/算子语法自证清单：canonical 示例由写出器产出、由同一解析器验回，附量纲与"数值该取哪个字段"）；**lint 也查编辑表**（空操作/断言被违反/空断言/白装算子）；预览**先全分辨率生成再盒平均降采样**，防发丝级软边界被抹掉误判 |
| wasm SDK | `wasm/` 包：经典 wasm 零 import（默认会话面 `mp_version/mp_reset/mp_exec_in` + in 槽；多会话句柄面 `mp_open/mp_close/mp_exec_h`），Node/浏览器双宿主冒烟 + 合同测试；JS 宿主胶水 `npm/moonpainter-sdk/`（.d.ts 类型化门面） |
| 底座 | 手写 ZIP 读写 / DEFLATE 压缩 / inflate 解压 / PNG 编解码 / SHA-256（NIST 向量验证）——zip/deflate/inflate 复用自 deepOffice（自有 MIT），PNG 编码复用自 moonviz（自有 MIT），余为本仓库新写 |

**诚实边界（本轮不做）**：文本层、贝塞尔、蒙版、调整层、图层样式、PSD/AI 等外部格式兼容（远期，见 DESIGN 远期章节）、16/32-bit、CMYK、自由笔刷。线段层占位矩形 w/h 必须为正（水平线请给 h≥描边宽）。

MVSL 侧的诚实边界：编辑表是**文档级的最终一遍**——`最终图 = apply(编辑表,
层合成底图)`，`render` / `previews/` / `mvsl-impact` 三条出口给出同一张图
（`verify.sh` 第 7 步断言 render 与 impact 的 sha256 相同）。它还不能
"只作用于某几个图层"或参与图层内部的混合序（那需要把图层单独栅格化的中间
缓冲；`stage:` 基准目前只切到算子序号，不切图层）。`recolor` 的半透明边缘
混色分离（`I = αF + (1−α)B`，只改 F）未做。外部 mask 资产只能引用、引擎不
内置任何分割模型（未登记即报精确错误，不降级）。`probe` 的单命令多点批量
入口未加（多次 probe 可覆盖）。
HSV 只做 selector/analysis affordance，算子一律走 OKLab/OKLCh（V 不是感知亮度）。

## 快速上手

```bash
cd moonpainter
./verify.sh                     # 一键验证门（见下）
moon run --target native cli << 'EOF'
session-open full_image
new 400 300 uuid=demo
add-rect x=0 y=0 w=400 h=300 fill=#1B2A41FF name=bg tag=background
add-ellipse x=120 y=60 w=160 h=160 lgrad=#FF7A45FF,#2E6FE8FF,0,0,1,1 blend=screen name=orb
render 400
save-mpd demo.mpd
:exit
EOF
```

`.mpd` 就是普通 ZIP——`unzip -l demo.mpd` 可以直接检查元参数层文本。

## AI 修图 demo（wasm SDK + posoco agent，全程 MoonBit）

人类提需求 → AI（posoco agent 循环）思考并**真实逐个调用引擎工具** → 每一步
（思考文本/工具名/参数/引擎回包/渲染预览）实时上屏——不是一键滤镜，是全过程可见的
工具操作。引擎交互全部经 **wasm SDK 实例**（经典 wasm 零 import；in 槽写入 +
`mp_exec_in` 执行 + 字符串指针读出，与 deepDesign 胶水同款 ABI）。

```bash
./build_demo.sh          # 构建 wasm + demo.js + index.html → dist/ + Node headless 自检
                         # + npm SDK 冒烟 + demo 测试（工具面与 MVSL 闭环可达）
cd dist && python3 -m http.server 8080   # 浏览器打开 http://localhost:8080
```

- **Mock 端点**（默认）：离线脚本模型，逐轮真实吐工具调用，无需 API Key 即可完整演示；
- **JS 宿主 SDK**：`npm/moonpainter-sdk/`（加载器 + index.d.ts，多会话句柄
  `open/execOn/close`、`render`/`saveMpd` 门面）——宿主侧唯一 JS 胶水，引擎本体 100% MoonBit；
- **真实端点**：DeepSeek / StepFun / OpenAI / 自定义 OpenAI 兼容端点，Key 仅存本页、
  直连端点（接入形态对齐 deepOrca：OpenAI wire + function calling + models.dev 式模型目录）；
- **视觉闭环**：`render` / `select_preview` / `mvsl_impact` 三个图像类工具把 PNG 以附件
  （`SuccessWithAttachments`）回传给多模态模型，AI 真的看图确认效果再继续
  （试选不看图 = 闭眼改色；影响证书不看图 = 发现不了选区跑偏）；
- **39 个工具，MVSL 闭环可达**：`sel_schema`（先看语法：字段名/量纲/示例自证）/
  `census`（先普查再选色）/`probe`（这个点选中没有）/
  `select_preview`（试选 + 连通域事实）/`mvsl_set`（装编辑表）/`mvsl_impact`
  （影响证书）/`mvsl_assert`（保护断言）/`mvsl_show`/`mvsl_clear`。模型只写 **JSON**
  选择子与编辑表，base64 由 SDK 做——不该让 LLM 手搓 base64；
- **两套颜色坐标系分家**：`probe`/`census` 报 `sel_h`/`sel_c`/`sel_l`
  （= OKLCh 色相 / OKLCh 彩度 / OKLab 亮度，**直接喂选择子的那三个数**）
  与 `hsv_h`/`hsv_s`/`hsv_v`（仅分析对照）。纯红 #C81E1E 的
  `sel_h≈28, sel_c≈0.20` 而 `hsv_h=0, hsv_s=0.85`——拿错一套的表现是
  「命令成功但一个像素都没选中」；彩度窗整条高于 sRGB 可达上限 0.3225
  会在装表前被**拒绝**（而不是静默返回空选）；
- **`lint` 会检查编辑表**（编辑表有一整类「每个命令都返回 ok」的失败）：
  P0 装了表却整张图逐位未变（选择子没命中）、P0 保护断言被违反、
  P1 某条算子白装、P1 构造性空算子（`hue_deg=0` / `temp_kelvin=0` /
  `relight_gain=1` / `amount=0`）、P1 **空断言**（保护断言的选择子零命中——
  它恒真，给的是虚假的安心：用户以为「别动背景」被机器守着，其实什么都没守）、
  P0 编辑表执行失败（如 mask 资产未登记）。
  只报 `changed_total=0` 是不够的——那需要调用方先知道 0 意味着"我什么都没改"；
- agent 层用 mooncakes 的 **colmugx/posoco**（六边形端口框架：ModelPort /
  ToolProvider / Observer 三端口扩展；Observer 即"全程可见"的官方通道）。
  评估记录：moonllm（DC-Z-lab）锁 `+native` 不适用浏览器，弃用。

## 一键验证门（`./verify.sh` 七步，任何一步失败即非零退出）

1. `moon check` 零错误零警告；
2. `moon test --target native` 全绿（NIST/CRC 已知答案、deflate/ZIP/PNG 往返、golden 渲染、容器确定性、八类拒绝路径、会话 e2e）；
3. `moon check --target wasm-gc` + wasm-gc 测试全绿（引擎包纯字节进出的硬背书）；
4. CLI 子进程端到端：管道喂命令（含 add-image 位图资产）→ 落盘 `.mpd`；
5. **独立外部验证**：系统 `unzip -t` 校验容器 + 条目齐全性 + manifest 格式标识 + 元参数层可直接文本阅读——不依赖引擎自证；
6. **open→save 字节一致**：载入容器后原样重打包，与原文件逐字节相同（确定性 pack 的进程级闭环）；
7. **MVSL 命令面 + 渲染管线闭环（子进程 e2e）**：安装编辑表 → `render` 与 `mvsl-impact` 的 sha256 必须**相同**（编辑表真的进了渲染管线，不只是被存下来）→ 校验改动像素数与选区外泄漏率 0 → `mvsl-assert`（合法程序放行、侵犯保护区的程序被拦下并给出条数）→ **`lint` 必须报出必然空选的编辑表与违约的保护断言**（这类失败其它命令全返回 ok）→ 编辑表随容器往返且开→存字节一致 → 带/不带编辑表的 `previews/flat.png` 必须不同（预览不撒谎）。

## 包结构（依赖严格无环）

```
base(sha256) ← codec(zip/deflate/inflate/png) ← core(IR + canonical JSON + 指纹 + MVSL 编辑表)
     ← pixel(选择子软场/算子程序/数值证书/覆盖预览)
     ← render(光栅/混合/取景) ← mpd(容器) ← agent(会话/命令/闸) ← cli(native 行协议)
```

`render` 依赖 `pixel`：MVSL 编辑表是渲染的最终一遍（层合成底图 → 施加编辑表
→ 再裁剪缩放）。`pixel` 绝不反向依赖 `render`，方向仍然无环。

## 复用说明

zip/deflate/inflate 移植自 `deepOffice/ooxml`（自有 MIT，手写实现，文件头已注明出处）；
PNG 编码移植自 `moonviz/playground/png.mbt`（自有 MIT）；moonviz 的 deflate.mbt
是第三方内嵌代码（mizchi/zlib, Apache-2.0），**未使用**。其余为本仓库新写。

<!-- deepgit:begin progress -->
## 项目进度

> 本区域由 **deepGit** 自动维护（浅更新）· 更新于 2026-09-30 17:43
> 追踪 2 个分支

### 工程脉搏

- 提交构成：`feat` ×4 · `fix` ×5 · `other` ×1

### `dev`（当前）

- **状态**：活跃 · 最近提交 16 小时前（`4b72a1f3` feat(retouch): 画笔/橡皮擦/裁剪/吸管/像素滤镜 —…）
- **摘要**：最近 10 个提交：修复×5、新增×4、更新×1
- **近期进展**
  - 新增：“画笔/橡皮擦/裁剪/吸管/像素滤镜 —— 真实修图操作引擎+U…
  - 修复：“图片导入 canvas 统一转 PNG + 文件选择器 value 清空（…
  - 修复：“index.html 根节点 id mp-root → app（与 MoonBit 代码…
  - 修复：“浏览器黑屏修复（sync wasm 加载 + 同步初始化 + JSON …
  - 修复：“js_load_wasm_node 多路径回退 + 同步 wasm 加载（修复…
- 本次记录 10 个提交

### `main`（默认分支）

- **状态**：活跃 · 最近提交 22 小时前（`bc27a023` MoonPainter 0.1.0：.mpd 双层容器 + 参数化绘制引…）
- **摘要**：最近 1 个提交：更新×1
- **近期进展**
  - 更新：“MoonPainter 0.1.0：.mpd 双层容器 + 参数化绘制引擎 + …
- 本次记录 1 个提交
<!-- deepgit:end progress -->
