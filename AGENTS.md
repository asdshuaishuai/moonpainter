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
5. **依赖方向**：base ← codec ← core ← render ← mpd ← agent ← cli，禁止反向/环；
   FFI 只许出现在 cli（native-only），引擎包保持纯字节进出。
6. **工具字典同步**：改 agent/session.mbt 的命令分发必须同步 agent/tools.mbt
   （反之亦然）——它是 help/list-tools/文档的单一事实源。
7. **确定性**：pack/canonical 序列化/渲染 sha256 必须可复现；禁止把时间戳、
   随机数、哈希表迭代序混进任何落盘字节。
8. **字符串插值**：`\{...}` 内只放标识符/字段/调用，不放二元运算（先 let）；
   `as`/`opaque` 等是保留字；FFI 指针参数需要 `#borrow` 属性行。

## 快速命令

```bash
./verify.sh                     # 一键验证门：check / native 测试 / wasm-gc 测试 /
                                # CLI 子进程 e2e / 独立 unzip 验证 / open→save 字节一致
./build_demo.sh                 # AI 修图 demo 构建 + Node headless 自检
moon run --target native cli    # stdin 行协议；help 查看全部 35 个命令
```

## demo/agent 层附加纪律（demo 包不适用"零第三方依赖"铁律）

- demo 包允许 mooncakes 依赖（当前 colmugx/posoco + moonbitlang/async）；
  **引擎包（base/codec/core/render/mpd/agent/wasm/cli）仍零第三方依赖**；
- 引擎交互必须经 wasm SDK 实例（wasm 包 ABI），不得在 demo 里旁路直调引擎包；
- mooncakes 依赖进模块前必须查 `supported_targets`（例：moonllm 锁 +native，
  浏览器 demo 不可用）；
- 工具回包给 LLM 一律截断（shorten），render 的 PNG 走 attachments 不走文本。

改动 canonical JSON 字段序、渲染管线或 pack 条目顺序时，golden sha256 与
open→save 字节一致断言会变化——这必须是有意为之，并同步更新对应测试与文档。

## 结构速览

见 README「包结构」与 DESIGN §2；实施历史与验收对照见 PLAN.md。
