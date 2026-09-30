# MoonPainter — Agent 驱动的图层绘制引擎

> 状态：**0.1.0（.mpd 容器 v2 + 参数化绘制 + AI 修图 demo + MVSL 确定性编辑 IR 引擎已落地：
> native 118 项 / wasm-gc 116 项测试全绿；`./verify.sh` 七步验证门全过）**。
> 设计书 [DESIGN.md](./DESIGN.md) · 方案与验收 [PLAN.md](./PLAN.md) ·
> MVSL 规划与评审对照 [PLAN-MVSL.md](./PLAN-MVSL.md) · AI 修图 demo 见下节。

一句话：**moonviz 套路在位图绘制领域的进阶复刻** —— 纯 MoonBit、全新模块标准
（`moon.mod`/新 `moon.pkg`）、零第三方依赖、结构化命令 + vision 能力闸 + 不崩谓词；
**只服务具备完整图片视觉的多模态模型**（`session-open full_image` 硬闸，纯文本模型明确拒绝）；
专属容器 **`.mpd`** 双层结构为唯一事实源：

- **元参数层**（纯文本）：`manifest.json` + `meta/{design,params,vision,agent,mvsl}.json`
  —— canonical design.json 的 sha256 即文档指纹，宿主据此判失效；
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
| 绘制 | 矩形（圆角）/椭圆/线段/多边形，纯色+线性渐变填充，描边，7 种混合（normal/multiply/screen/overlay/darken/lighten/difference，W3C 合成公式），透明度，旋转（Taylor 三角）+ **翻转（flip h/v/both，先翻转后旋转）**，编组（直通），PNG 位图导入（8-bit RGB/RGBA/灰非交错） |
| 渲染 | 2×2 子采样 AA、取景渲染（归一化 viewport + 目标宽）、**overlay=1（层 bbox 序号线框 + 3×5 数字标注，像素↔结构对位辅助）**、pick 像素→层 id、直方图/覆盖统计、渲染确定性（golden sha256 锁定） |
| 容器 | pack/unpack 全环、确定性 pack（两次打包字节一致）、原子落盘（tmp+rename）、八类拒绝路径全测试 |
| 会话 | 54 个命令（字典 = agent/tools.mbt）、vision 闸、undo/redo（快照栈 ≤64）、编辑历史、P0–P2 lint |
| MVSL 编辑表 | 确定性声明式编辑 IR：谓词选择子（OKLCh 色相环/OKLab 亮度/几何/渐变/种子连通域/外部 mask 资产，全部输出 [0,1] 软权重场，可 Union/And/Diff 组合）+ 有序算子程序（recolor/temperature/relight，`out=lerp(in,op(in),w)` 去污染）+ 选区精修（grow/shrink/feather/fill_holes/keep_largest/guided filter）+ 保护断言；canonical JSON 往返幂等、旧引擎遇未知算子/更高版本一律拒绝 |
| MVSL 闭环 affordance | `select-preview`（选择子→overlay PNG + 覆盖率/bbox/连通域事实，"AI 选 ID 不报坐标"）、`mvsl-impact`（逐算子 diff 证书：改动像素数/ΔE/选区外泄漏率 + 结果 PNG）、`mvsl-assert`（保护区约束违反则命令信封直接 fail，"别动人物"变成机器可验证约束）；预览**先全分辨率生成再盒平均降采样**，防发丝级软边界被抹掉误判 |
| wasm SDK | `wasm/` 包：经典 wasm 零 import（默认会话面 `mp_version/mp_reset/mp_exec_in` + in 槽；多会话句柄面 `mp_open/mp_close/mp_exec_h`），Node/浏览器双宿主冒烟 + 合同测试；JS 宿主胶水 `npm/moonpainter-sdk/`（.d.ts 类型化门面） |
| 底座 | 手写 ZIP 读写 / DEFLATE 压缩 / inflate 解压 / PNG 编解码 / SHA-256（NIST 向量验证）——zip/deflate/inflate 复用自 deepOffice（自有 MIT），PNG 编码复用自 moonviz（自有 MIT），余为本仓库新写 |

**诚实边界（本轮不做）**：文本层、贝塞尔、蒙版、调整层、图层样式、PSD/AI 等外部格式兼容（远期，见 DESIGN 远期章节）、16/32-bit、CMYK、自由笔刷。线段层占位矩形 w/h 必须为正（水平线请给 h≥描边宽）。

MVSL 侧的诚实边界：**编辑表尚未参与最终渲染**——`render` / `previews/` 仍只画
`design.json` 的层，编辑表目前经 `mvsl-impact` 出图、随容器落盘、可断言，但把
「MVSL 层」接进渲染管线（`pixel ← render`）是下一步。外部 mask 资产只能引用、
引擎不内置任何分割模型（未登记即报精确错误，不降级）。`census` 的
`within=`/hue×sat 桶升级与 `probe` 的 5×5 邻域/component id 升级尚未落地。
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
./build_demo.sh          # 构建 wasm + demo.js + index.html → dist/，并跑 Node headless 自检
cd dist && python3 -m http.server 8080   # 浏览器打开 http://localhost:8080
```

- **Mock 端点**（默认）：离线脚本模型，逐轮真实吐工具调用，无需 API Key 即可完整演示；
- **JS 宿主 SDK**：`npm/moonpainter-sdk/`（加载器 + index.d.ts，多会话句柄
  `open/execOn/close`、`render`/`saveMpd` 门面）——宿主侧唯一 JS 胶水，引擎本体 100% MoonBit；
- **真实端点**：DeepSeek / StepFun / OpenAI / 自定义 OpenAI 兼容端点，Key 仅存本页、
  直连端点（接入形态对齐 deepOrca：OpenAI wire + function calling + models.dev 式模型目录）；
- **视觉闭环**：`render` 工具把渲染 PNG 以附件（`SuccessWithAttachments`）回传给
  多模态模型，AI 真的看图确认效果再继续；
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
7. **MVSL 命令面子进程 e2e**：安装编辑表 → `mvsl-impact`（校验改动像素数与选区外泄漏率 0）→ `mvsl-assert`（合法程序放行、侵犯保护区的程序被拦下并给出条数）→ 编辑表随容器往返且开→存字节一致。

## 包结构（依赖严格无环）

```
base(sha256) ← codec(zip/deflate/inflate/png) ← core(IR + canonical JSON + 指纹 + MVSL 编辑表)
     ← pixel(选择子软场/算子程序/数值证书/覆盖预览)
     ← render(光栅/混合/取景) ← mpd(容器) ← agent(会话/命令/闸) ← cli(native 行协议)
```

`pixel` 与 `render` 目前互不依赖（编辑表还没接进渲染管线），两者都只依赖
core/codec，方向仍然无环。

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
