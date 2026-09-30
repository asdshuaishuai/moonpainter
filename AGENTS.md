# AGENTS.md — MoonPainter 工程纪律

给后续在本仓库工作的 Agent（人类同样适用）。核心一句话：
**事实源在容器里、纪律在测试里、边界在文档里。**

## 铁律

1. **测试口径是唯一口径**：任何改动后 `moon check`（0 error / 0 warning）+
   `moon test --target native`（全绿）才算完成。golden sha256 变化必须是有意为之并同步更新。
2. **`.mpd` 是唯一事实源**：不要发明旁路状态；一切变更走 agent 命令面
   （canonical design.json + 指纹），像素资产只增不改（内容寻址）。
3. **诚实边界**：新能力做多少写多少（README 能力表 + DESIGN 边界节同步）；
   不支持就报明确错误，不降级、不糊弄。vision 闸永远不许放宽。
4. **复用规则**：只用本工作区自有 MIT 代码，复制时保留出处注释；
   任何带第三方内嵌标注的文件（如 moonviz 的 deflate.mbt）不得引入。
5. **依赖方向**：base ← codec ← core ← pixel ← render ← mpd ← agent ← cli，禁止反向/环；
   FFI 只许出现在 cli（native-only），引擎包保持纯字节进出。
   `render` 依赖 `pixel`（编辑表是渲染的**最终一遍**：层合成底图 → 施加编辑表 →
   再裁剪缩放）；`pixel` 绝不反向依赖 `render`。改这里必须同步 DESIGN §2 依赖图。
   重采样路径不许分叉：空编辑表必须走与"没有编辑表"逐位相同的代码路径。
6. **工具字典同步**：改 agent/session.mbt 的命令分发必须同步 agent/tools.mbt
   （反之亦然）——它是 help/list-tools/文档的单一事实源。
7. **确定性**：pack/canonical 序列化/渲染 sha256 必须可复现；禁止把时间戳、
   随机数、哈希表迭代序混进任何落盘字节。
   **三个指纹别混**：`fingerprint`（design.json，编辑表变了它不变）/
   `program_sha256`（编辑表，`@core.program_sha256` 单一实现）/
   `render_sha256`（渲染产物，缓存失效判断认这个）。
8. **字符串插值**：`\{...}` 内只放标识符/字段/调用，不放二元运算（先 let）；
   `as`/`opaque`/`guard` 等是保留字；FFI 指针参数需要 `#borrow` 属性行。
9. **测试文件命名**：`*_test.mbt` 是 **blackbox**（必须写 `@pkg.x`，否则
   `test_unqualified_package` 警告，且在文件内定义同名 fn 会变成无限自递归）；
   需要直接访问包内私有符号时用 `*_wbtest.mbt`。两类测试都在 `moon check` 口径内。

## 快速命令

```bash
./verify.sh                     # 一键验证门：check / native 测试 / wasm-gc 测试 /
                                # CLI 子进程 e2e / 独立 unzip 验证 / open→save 字节一致 /
                                # MVSL 编辑表命令面 + 渲染管线闭环
                                #（安装→render≡impact 同一张图→断言→容器往返→预览走编辑表）
./build_demo.sh                 # AI 修图 demo 构建 + Node headless 自检 + npm SDK 冒烟
                                # + demo 测试（工具面与 MVSL 闭环可达，需 Node）
moon run --target native cli    # stdin 行协议；help 查看全部 56 个命令
```

## demo/agent 层附加纪律（demo 包不适用"零第三方依赖"铁律）

- demo 包允许 mooncakes 依赖（当前 colmugx/posoco + moonbitlang/async）；
  **引擎包（base/codec/core/pixel/render/mpd/agent/wasm/cli）仍零第三方依赖**；
- 引擎交互必须经 wasm SDK 实例（wasm 包 ABI），不得在 demo 里旁路直调引擎包；
- mooncakes 依赖进模块前必须查 `supported_targets`（例：moonllm 锁 +native，
  浏览器 demo 不可用）；
- 工具回包给 LLM 一律截断（shorten），render 的 PNG 走 attachments 不走文本
  （`render` / `select_preview` / `mvsl_impact` 三个图像类工具同规）；
- demo 工具面是 agent 命令面的**手写子集**（当前 38 个）：引擎新增命令后，
  要用到就该同步加进 `paint_tools.mbt` 的 `paint_tool_defs` + `execute` +
  `catalog.mbt` 的 system prompt，否则"引擎有能力"不等于"产品里的 AI 用得上"。
  模型侧只写 JSON，base64 由 SDK 的 `b64_text` 转。

改动 canonical JSON 字段序、渲染管线或 pack 条目顺序时，golden sha256 与
open→save 字节一致断言会变化——这必须是有意为之，并同步更新对应测试与文档。

## 结构速览

见 README「包结构」与 DESIGN §2；实施历史与验收对照见 PLAN.md。

<!-- deepgit:begin progress -->
## 当前进度（deepGit 维护）

> 浅更新 · 2026-09-30 17:43 · 追踪 2 个分支

### 工程脉搏

- 提交构成：`feat` ×4 · `fix` ×5 · `other` ×1

- **`dev`**（当前）：活跃 · head `4b72a1f3`（16 小时前） —— 最近 10 个提交：修复×5、新增×4、更新×1
- **`main`**（默认）：活跃 · head `bc27a023`（22 小时前） —— 最近 1 个提交：更新×1

**最近提交**
- `4b72a1f3` feat(retouch): 画笔/橡皮擦/裁剪/吸管/像素滤镜 —— 真实修图操作引擎+UI（2026-09-30）
- `c3f9611d` fix: 图片导入 canvas 统一转 PNG + 文件选择器 value 清空（支持重复选同一文件）（2026-09-29）
- `7bcfa1f0` fix: index.html 根节点 id mp-root → app（与 MoonBit 代码一致）（2026-09-29）
<!-- deepgit:end progress -->
