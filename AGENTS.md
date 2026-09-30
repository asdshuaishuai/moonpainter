# AGENTS.md — MoonPainter 工程纪律

给后续在本仓库工作的 Agent（人类同样适用）。核心一句话：
**事实源在容器里、纪律在测试里、边界在文档里。**

## 铁律

1. **测试口径是唯一口径**：任何改动后 `moon check`（0 error / 0 warning）+
   `moon test --target native`（全绿）才算完成。golden sha256 变化必须是有意为之并同步更新。
   **但全绿不等于被守护**：核心语义（编辑表的软权重混合/羽化/量化、三个指纹、
   保护断言）必须有**能抓住注入 bug** 的测试。`python3 mutation_scan.py` 是这件事的
   度量——往实现注入语义 bug，看测试能否抓住。实测这条纪律值多少：把 MVSL 的
   `lerp(in, op(in), w)` 的 w 换成常量 1.0（核心语义硬边化）时，**当时全部
   150 条测试统统通过**（因为断言全是契约/结构，而 render 的 golden 走空编辑表、
   根本不经过 `lerp_argb`）。
   新增核心语义时同步往 `MUTS` 加一条变异。
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
   **lint 必须覆盖编辑表的"自我否定"状态**：装了表却什么都没改、保护断言被
   违反、某条算子白装、构造性空算子。这类状态 `mvsl-set`/`impact`/`assert`/
   `render` **全都返回 ok**，只有 lint 会报——新增编辑表能力时同步把它接进
   `lint_mvsl`，否则引擎知道自己没干活而没人告诉调用方。
7. **确定性**：pack/canonical 序列化/渲染 sha256 必须可复现；禁止把时间戳、
   随机数、哈希表迭代序混进任何落盘字节。
   **三个指纹别混**：`fingerprint`（design.json，编辑表变了它不变）/
   `program_sha256`（编辑表，`@core.program_sha256` 单一实现）/
   `render_sha256`（渲染产物，缓存失效判断认这个）。
   **两套颜色坐标系别混**：选择子吃 **OKLCh/OKLab**（`color` 的 `h`/`s` 是
   OKLCh 色相/彩度）；HSV 只做分析辅助。凡向调用方报颜色数值，一律走
   `pixel.ColorStats`（`sel_*` 喂选择子、`hsv_*` 仅对照）——三处报告点
   各自算一遍就是把 HSV 的 h 写进选择子字段的温床。
8. **坐标单位别混**：`add-*` / `set-style` 里 `x/y/w/h/stroke_w` 是**像素**，
   而 `lgrad` 端点是**归一化到本层 bbox 的 0..1**（见 `core.grad_endpoint_error`）。
   写错的表现是"一切正常但渐变几乎看不出过渡"——静默失败最难查，所以入口
   直接拒绝并给换算建议，`lint` 兜底手改容器的情形。新增任何带坐标的参数，
   必须在**工具字典里写明单位**，不能只在类型注释里写。
9. **字符串插值**：`\{...}` 内只放标识符/字段/调用，不放二元运算（先 let）；
   `as`/`opaque`/`guard` 等是保留字；FFI 指针参数需要 `#borrow` 属性行。
10. **测试文件命名**：`*_test.mbt` 是 **blackbox**（必须写 `@pkg.x`，否则
   `test_unqualified_package` 警告，且在文件内定义同名 fn 会变成无限自递归）；
   需要直接访问包内私有符号时用 `*_wbtest.mbt`。两类测试都在 `moon check` 口径内。

11. **数值断言必须精确解析，禁止子串匹配**：`contains("\"leak_ratio\":0")`
    会被 `"leak_ratio":0.0279` **骗过**——泄漏率在 `[0,1)` 的任何值都能通过，
    断言看起来在守护「选区外零泄漏」，实际只拒绝 ≥ 1 的泄漏率。本仓库曾有
    5 处栽在这里（含 `verify.sh` 的 e2e 门），所以一个真实的判据 bug 藏了
    好几轮没人发现。取值一律走 `@core.parse_json` + `as_num`
    （辅助见 `agent/mvsl_test.mbt` 的 `per_op_num` / `near`）；shell 里用
    `grep -E '"k":0[,}]'` 锚住字段值结尾。整数计数字段（`violations`/`count`）
    碰巧不受影响，但一视同仁更省心。

## 快速命令

```bash
./verify.sh                     # 一键验证门：check / native 测试 / wasm-gc 测试 /
                                # **两个 target 的 check 都断言无 Warning**（铁律 1
                                # 的 0-warning 不分 target；warning 会让 moon check
                                # 返回非零，set -e 直接停在第 1 步） /
                                # CLI 子进程 e2e / 独立 unzip 验证 / open→save 字节一致 /
                                # MVSL 编辑表命令面 + 渲染管线闭环（安装→
                                # render≡impact 同一张图→断言→软过渡带不
                                # 算泄漏→lint 空操作/违约→容器往返→预览
                                # 走编辑表）；渐变端点单位等静默失败也在此拦
                                # 8/9 命令字典与分发一致：list-tools 吐出的每个
                                # 命令都逐个真实调用，必须不报"未知命令"（铁律 6）
                                # 9/10 命令参数下界自检：每个 cmd_* 读 tokens[N]
                                # 之前必须先卡住 N。下界写小了**不报用法错、
                                # 而是越界 panic**（实测 `set-text l1` 把 CLI
                                # 干掉了），而第 8 步只用裸命令名逐个戳、
                                # 照不到带参数才越界的那批
                                # 10/10 变异锚点自检：每个变异锚点必须唯一命中 1 处
                                # （秒级）。锚点失效 = 那块覆盖被悄悄拿掉，
                                # 而汇总里的「N 个变异全部通过」照旧好看——实测
                                # 踩过，两个变异静静失效了一轮
./build_demo.sh                 # AI 修图 demo 构建 + Node headless 自检 + npm SDK 冒烟
                                # （含 save→open 往返）+ 页面接线源码核对 + demo 测试
                                # （工具面与 MVSL 闭环可达，需 Node；
                                # 含 undispatched_tools 工具面自检、HTML 接线自检）
                                # **页面接线的两层**：demo_test 拿真的拼出来的
                                # HTML 查 globalThis 处理器与 id；build_demo.sh
                                # 第 6 步额外罩住动态拼出来的图层列表/属性面板。
                                # 别把"在浏览器里点一下"当整块——静态那半可机器验

# 门禁脚本别写 `cmd | tail -1`：管道的退出码是 tail 的，set -e 抓不到失败。
# 两个脚本都用 run_quiet 包裹长输出命令。
python3 mutation_scan.py        # 变异门：注入语义 bug 看测试能否抓住（约 5 分钟；
                                # 「测试全绿」不等于「行为被守护」）
python3 mutation_scan.py --check-anchors   # 只校验锚点唯一命中（秒级，已进 verify.sh）
python3 mutation_scan.py R3 R4  # 按 id 只跑指定的变异（改完测试想快速复验）
# 锚点失效 → INVALID → **退出码 1**（不再被静默排除在统计之外）
moon run --target native cli    # stdin 行协议；help 查看全部 58 个命令
```

## demo/agent 层附加纪律（demo 包不适用"零第三方依赖"铁律）

- demo 包允许 mooncakes 依赖（当前 colmugx/posoco + moonbitlang/async）；
  **引擎包（base/codec/core/pixel/render/mpd/agent/wasm/cli）仍零第三方依赖**；
- 引擎交互必须经 wasm SDK 实例（wasm 包 ABI），不得在 demo 里旁路直调引擎包；
- mooncakes 依赖进模块前必须查 `supported_targets`（例：moonllm 锁 +native，
  浏览器 demo 不可用）；
- 工具回包给 LLM 一律截断（shorten），render 的 PNG 走 attachments 不走文本
  （`render` / `select_preview` / `mvsl_impact` 三个图像类工具同规）；
- **自由文本参数必须用双引号包裹**：`text="Hello World"`、`name="My Layer"`。
  命令行协议按空白分词，`tokenize_line` 支持双引号（引号内的空格不参与切分，
  `\"` 表示字面引号）。原先协议里只有"下划线代替空格"一说——它写在
  `add-text` 的错误提示里、前端 `do_text_add` 也真的把空格换成了下划线，
  **但引擎从未实现还原**，于是用户输入 "Hello World"，存进去和渲染出来的
  都是 `Hello_World`。现在 `_` 保持**字面下划线**（历史行为完全不变），
  含空格靠引号。新增自由文本参数时，走 `quote_arg`（demo/main.mbt）拼串。
- demo 工具面是 agent 命令面的**手写子集**（当前 49 个）：引擎新增命令后，
  要用到就该同步加进 `paint_tools.mbt` 的 `paint_tool_defs` + `tool_cmd` +
  `catalog.mbt` 的 system prompt，否则"引擎有能力"不等于"产品里的 AI 用得上"。
  模型侧只写 JSON，base64 由 SDK 的 `b64_text` 转。
  **"注册了工具"与"接得上引擎命令行"是两件事，必须由测试锁住**：
  `paint_tools.mbt` 里曾有**两张手写表**（`tool_cmd` 的命令名、`line` 的参数
  拼接），`cmd` 求值在前且不认识就报"未知工具"，于是 `line` match 里写了、
  `cmd` 表里漏了的工具**在工具面上根本调不通**。实测漏了 10 个（`undo` 与
  B4.5 起的画笔/橡皮/调整层/分组/标签/裁剪/采样）。现在 `undispatched_tools()`
  把它变成一条断言，`demo_test.mbt` 断言为空——新增工具时忘了接线会**立刻红**。
  人类前端有按钮、测试又直接调 `engine_exec_line`，这两条都会掩盖这类漏洞。
  **第二张表现在是 `pub fn tool_line(name, args)`**：原先它藏在 `execute`
  内部，`undispatched_tools()` 只查第一张表、`engine_exec_line` 又直接调引擎
  绕过它，两条测试路径都照不到它。提取成接受 `Json` 的纯函数后，
  `demo_test.mbt` 可以直接喂参数断言拼出的命令行（含自由文本的引号）。

改动 canonical JSON 字段序、渲染管线或 pack 条目顺序时，golden sha256 与
open→save 字节一致断言会变化——这必须是有意为之，并同步更新对应测试与文档。

## 结构速览

见 README「包结构」与 DESIGN §2；实施历史与验收对照见 PLAN.md。

<!-- deepgit:begin progress -->
## 当前进度（deepGit 维护）

> 浅更新 · 2026-10-01 00:05 · 追踪 2 个分支 · 3 处未提交改动

### 工程脉搏

- 提交构成：`feat` ×10 · `fix` ×12 · `docs` ×3 · `other` ×1
- 注意：1 个未跟踪文件；`dev` 可直接 fast-forward 到 `main`

- **`dev`**（当前）：活跃 · head `adc33d9c`（9 分钟前） —— 新增 16 个提交（修复×7、新增×6、文档×3），涉及 agent（12 文件）、docs（10 文件）、pixel（10 文件）
- **`main`**（默认）：活跃 · head `bc27a023`（1 天前） —— 最近 1 个提交：更新×1

**需要注意**
- 工作区有 3 处未提交改动

**最近提交**
- `adc33d9c` docs: 说准数字 —— 5 处子串断言是 4 处 leak + 1 处 coverage（2026-09-30）
- `81525b69` fix(pixel): leak_ratio 判据用错阈值 —— 软过渡带被误报成「选区外泄漏」（2026-09-30）
- `a6a33505` fix(core): 渐变端点是归一化 0..1 —— 写成像素不再静默变成纯色（2026-09-30）
<!-- deepgit:end progress -->
