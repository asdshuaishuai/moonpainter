# MoonPainter — Agent 驱动的图层绘制引擎

> 状态：**0.1.0（.mpd 容器 + 参数化绘制 + AI 修图 demo 已落地：native 58 项 / wasm-gc 56 项 / js 57 项测试全绿；`./verify.sh` 与 `./build_demo.sh` 双验证门全过）**。
> 设计书 [DESIGN.md](./DESIGN.md) · 方案与验收 [PLAN.md](./PLAN.md) · AI 修图 demo 见下节。

一句话：**moonviz 套路在位图绘制领域的进阶复刻** —— 纯 MoonBit、全新模块标准
（`moon.mod`/新 `moon.pkg`）、零第三方依赖、结构化命令 + vision 能力闸 + 不崩谓词；
**只服务具备完整图片视觉的多模态模型**（`session-open full_image` 硬闸，纯文本模型明确拒绝）；
专属容器 **`.mpd`** 双层结构为唯一事实源：

- **元参数层**（纯文本）：`manifest.json` + `meta/{design,params,vision,agent}.json`
  —— canonical design.json 的 sha256 即文档指纹，宿主据此判失效；
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
| 会话 | 35 个命令、vision 闸、undo/redo（快照栈 ≤64）、编辑历史、P0–P2 lint |
| wasm SDK | `wasm/` 包：经典 wasm 零 import（默认会话面 `mp_version/mp_reset/mp_exec_in` + in 槽；多会话句柄面 `mp_open/mp_close/mp_exec_h`），Node/浏览器双宿主冒烟 + 合同测试；JS 宿主胶水 `npm/moonpainter-sdk/`（.d.ts 类型化门面） |
| 底座 | 手写 ZIP 读写 / DEFLATE 压缩 / inflate 解压 / PNG 编解码 / SHA-256（NIST 向量验证）——zip/deflate/inflate 复用自 deepOffice（自有 MIT），PNG 编码复用自 moonviz（自有 MIT），余为本仓库新写 |

**诚实边界（本轮不做）**：文本层、贝塞尔、蒙版、调整层、图层样式、PSD/AI 等外部格式兼容（远期，见 DESIGN 远期章节）、16/32-bit、CMYK、自由笔刷。线段层占位矩形 w/h 必须为正（水平线请给 h≥描边宽）。

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

## 一键验证门（`./verify.sh` 六步，任何一步失败即非零退出）

1. `moon check` 零错误零警告；
2. `moon test --target native` 全绿（NIST/CRC 已知答案、deflate/ZIP/PNG 往返、golden 渲染、容器确定性、八类拒绝路径、会话 e2e）；
3. `moon check --target wasm-gc` + wasm-gc 测试全绿（引擎包纯字节进出的硬背书）；
4. CLI 子进程端到端：管道喂命令（含 add-image 位图资产）→ 落盘 `.mpd`；
5. **独立外部验证**：系统 `unzip -t` 校验容器 + 条目齐全性 + manifest 格式标识 + 元参数层可直接文本阅读——不依赖引擎自证；
6. **open→save 字节一致**：载入容器后原样重打包，与原文件逐字节相同（确定性 pack 的进程级闭环）。

## 包结构（依赖严格无环）

```
base(sha256) ← codec(zip/deflate/inflate/png) ← core(IR+canonical JSON+指纹)
     ← render(光栅/混合/取景) ← mpd(容器) ← agent(会话/命令/闸) ← cli(native 行协议)
```

## 复用说明

zip/deflate/inflate 移植自 `deepOffice/ooxml`（自有 MIT，手写实现，文件头已注明出处）；
PNG 编码移植自 `moonviz/playground/png.mbt`（自有 MIT）；moonviz 的 deflate.mbt
是第三方内嵌代码（mizchi/zlib, Apache-2.0），**未使用**。其余为本仓库新写。
