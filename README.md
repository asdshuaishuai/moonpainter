# MoonPainter — Agent 驱动的图层绘制引擎

> 状态：**0.1.0（.mpd 容器 v2 + 参数化绘制 + AI 修图 demo + MVSL 确定性编辑 IR 引擎已落地：
> native 192 项 / wasm-gc 190 项测试全绿；`./verify.sh` 八步验证门全过）**。
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
- **设计稿层**：`assets/sha256/<hash>`（内容寻址 PNG 资产）+ `previews/{flat,thumb}.png`。
  **打包只写当前被层引用的资产**：会话内的登记簿只增（撤销要把字节还回来），
  但删掉图片层后再存，那份孤儿字节不会再进容器
  （保存时自动渲染）+ 拒绝式校验（CRC / 指纹对账 / 前向版本拒绝 / 限额 / 路径安全）。

```
读元参数(list-layers/query-layer) ─► 拟命令 ─► 应用（vision 闸+谓词+undo）
─► render(取景 PNG b64 + sha256) ─► 视觉校验（pick/stats 给客观数值，模型看图判断）─► save-mpd
```

## 能力（0.1.0 实测口径）

| 域 | 内容 |
| :-- | :-- |
| 画布 | `new` / `set-canvas` / `crop`。**容器允许单边 ≤30000、总量 ≤1e8 像素，但渲染器只能画单边 ≤4096**——超过的画布 `new`/`set-canvas` **直接拒绝**（报错说清"只会画左上角 4096×4096、其余图层一个像素都不会出现"，并给可行的下一步），`lint` 以 P0 兜住手改容器、以及**旧引擎（本仓库 81ff759 之前）产出的超限容器**——那时候 `new 5000 200` 是能建能存的，所以这种容器真实存在；`open-mpd` 因此**只知会不拒绝**（拒绝打开就等于用户连"打开自己的文件再 `crop` 到 4096"这条自救路都没有，报错里的 `notice` 字段会说清），`census` 也把两个数分开报（`canvas` = 文档记账尺寸、`render` = 实际渲染尺寸，不等即"能存但画不出来"）。**此前是静默截断**：`new 5000 200` 回 ok、画布尺寸/指纹/容器都按 5000 记账，而渲染只画左上角 4096×200 那块，`lint` 报 0 违规（实测放在 x=4500 的图层整个消失） |
| 绘制 | 矩形（圆角）/椭圆/线段/多边形，纯色+线性渐变填充（颜色支持 `#RRGGBB[AA]`，**AA 真的参与混合**：50% 红压白 = `#FF7F7F`；**端点归一化到本层 bbox 的 0..1**；与同命令的像素参数 x/y/w/h 不同，写错会被入口拒绝并给出换算值），描边，7 种混合（normal/multiply/screen/overlay/darken/lighten/difference，W3C 合成公式），透明度，旋转（Taylor 三角）+ **翻转（flip h/v/both，先翻转后旋转）**，编组（直通；**已有层进出已有组**走 `group-add`/`group-remove`——此前只能 `ungroup`+`group` 整体重组，组的 name/opacity/blend/tags/mask 全丢；新成员追加到组栈顶，移出的层落在**组的下一层**。**两侧都有入口**：AI 侧 `group`/`ungroup`/`group_add`/`group_remove`，人类侧属性面板的「编组」「解组」按钮与「父级」下拉（根级 ⇄ 某个组，只列**根级**组）——从 A 组换到 B 组是 `group-remove` 再 `group-add` 两步，先摘后加，第二步失败层落根级而不是丢失；移走最后一个成员后组**留在原地**（引擎不替你删——那才是静默动作），图层列表会把它标成「空」，因为 `lint` 会报它而人类看不到 lint），PNG 位图导入（8-bit RGB/RGBA/灰非交错；**盒子跟着内容走**：不给 `w=`/`h=` 时盒 = 资产像素尺寸，只给一边时另一边按原比例推——渲染器把资产**拉伸到盒子**，缺省 100×100 会把任意比例的图静默压扁）、**原地换图** `set-image`（只换像素，层序/蒙版/标签/透明度/翻转/旋转都不动——此前只能删了重加，那些全丢且层被推到栈顶） |
| 图层蒙版 | 几何蒙版（矩形/椭圆 + **圆角 `radius`（仅矩形，超过半边长按半边长夹住）** + **边缘羽化 `feather`（按到边界的真实内距线性过渡，`0`=硬边）** + **边缘毛化 `roughen`（按画布坐标的确定性值噪声扰动边界，手绘/撕裂纸边那种不规则轮廓，`0`=光滑边；与 feather 叠加 = 先毛化再羽化）** + `invert` 反选，**蒙版外不渲染**）：人类前端可拖拽创建（工具条 ▭/◯），拖拽前用工具条上的滑块设**圆角**（仅矩形）与**羽化**，另有「蒙版反选 / 去蒙版」按钮，AI 可走 `add_mask` / `set_mask` / `remove_mask` 工具；**`set_mask` 是全参数的部分更新**（只给要改的键，其余原样保留——全量重建会把没重复写的 `radius`/`roughen` 悄悄重置成 0）；`query-layer` / `list-layers` 报告 `mask` 状态（否则加了蒙版看不出来）。用到 `roughen` 的容器在 manifest 里声明 `render_contract:2`，**旧引擎据此拒绝打开**而不是把它画成光滑边 |
| 渲染 | 2×2 子采样 AA、取景渲染（归一化 viewport + 目标宽）、**overlay=1（层 bbox 序号线框 + 3×5 数字标注，像素↔结构对位辅助）**、pick 像素→层 id、直方图/覆盖统计、渲染确定性（golden sha256 锁定） |
| 容器 | pack/unpack 全环、确定性 pack（两次打包字节一致）、原子落盘（tmp+rename）、八类拒绝路径全测试 |
| 会话 | 63 个命令（字典 = agent/tools.mbt）、vision 闸、undo/redo（快照栈 ≤64）、编辑历史、P0–P2 lint、语义标签 `tag`/`untag`（可打可摘；可当**层作用域**用，见下） |
| MVSL 编辑表 | 确定性声明式编辑 IR：**图层级作用域 `layer=<id>` 与标签作用域 `layer=@<标签>`**（前者只作用于指定层，后者作用于带该标签的**全部层**——"只改某几个层"的声明式写法；该层先单独栅格化到透明底，选择子在**这一层自己的像素**上求值，再合成回去；标签是活绑定：打/摘标签即改作用范围，落不到任何层则**拒绝**而不是静默不生效；**这同时是 `recolor` 边界去污染的正确做法**：半透明边缘的颜色是前景与背景的混合，在合成图上变换会连背景一起偏移，在层栅格上则只作用于纯前景色）+ 谓词选择子（OKLCh 色相环/彩度/OKLab 亮度/几何/渐变/种子连通域/外部 mask 资产，全部输出 [0,1] 软权重场，可 Union/And/Diff 组合）+ 有序算子程序（recolor/temperature/relight，`out=lerp(in,op(in),w)` 软权重过渡）+ 选区精修（grow/shrink/feather/fill_holes/keep_largest/guided filter）+ 保护断言；**是渲染的最终一遍**（`最终图 = apply(编辑表, 层合成底图)`，`render`/`previews/`/`mvsl-impact` 三条出口同一张图）；canonical JSON 往返幂等、旧引擎遇未知算子/更高版本一律拒绝、前视 `stage:` 与带 `stage:` 基准的断言在校验期拦下 |
| MVSL 闭环 affordance | `select-preview`（选择子→overlay PNG + 覆盖率/bbox/连通域事实，"AI 选 ID 不报坐标"）、`mvsl-impact`（逐算子 diff 证书：改动像素数/ΔE/选区外泄漏率 + 结果 PNG；泄漏率判据是**选择子支撑集**，软过渡带不算泄漏——`out=lerp(in,op(in),w)` 保证支撑集外逐位不变，所以它是不变量/安全网）、`mvsl-assert`（保护区约束违反则命令信封直接 fail，"别动人物"变成机器可验证约束）、`census`（hue×sat 12×3 桶普查 + OKLab L 与 HSV V 均值对照，`within=` 可收窄到某条选择子）、`probe`（邻域统计 + 边缘置信度 + 当前编辑表每个算子/断言在该点的 membership 与连通域 id；**支持 `points=x1,y1;x2,y2;…` 一次探 64 点**，返回数组且每点字段与单点模式逐字段一致——探九宫格不用往返 9 次）、`sel-schema`（选择子/算子语法自证清单：canonical 示例由写出器产出、由同一解析器验回，附量纲与"数值该取哪个字段"）；**lint 也查编辑表**（空操作/断言被违反/空断言/白装算子）；预览**先全分辨率生成再盒平均降采样**，防发丝级软边界被抹掉误判 |
| wasm SDK | `wasm/` 包：经典 wasm 零 import（默认会话面 `mp_version/mp_reset/mp_exec_in` + in 槽；多会话句柄面 `mp_open/mp_close/mp_exec_h`），Node/浏览器双宿主冒烟 + 合同测试；JS 宿主胶水 `npm/moonpainter-sdk/`（.d.ts 类型化门面） |
| 底座 | 手写 ZIP 读写 / DEFLATE 压缩 / inflate 解压 / PNG 编解码 / SHA-256（NIST 向量验证）——zip/deflate/inflate 复用自 deepOffice（自有 MIT），PNG 编码复用自 moonviz（自有 MIT），余为本仓库新写 |

**诚实边界**：`params`（命名元参数，`set-param`/`list-params`/`remove-param`）是**纯元数据，
没有 live 绑定**——它会被存进容器、被 `list-params` 报出来、随 `inspect` 一起
显示，但**不影响渲染**，改它不会改任何像素。这是声明过的边界，不是待办埋伏；**语义标签（`tag`/`untag`/`tag=`）**打得上也摘得下、进 canonical JSON 与指纹、被 `query-layer`/`list-layers` 回读，并且**已经有一个消费者**：MVSL 算子的 `layer=@<标签>` 图层级作用域（作用于带该标签的**全部层**，活绑定——打/摘标签即改作用范围）。但**标签仍然不是选择子**：`AtomSel` 的六种原子（色相/亮度/几何/渐变/连通域/外部资产）里没有"按标签"，"这一层里哪些像素"与"哪些层"是两件事——要按标签选像素，选择子必须在层自己的栅格上求值（压平的合成底图里没有层身份），这正是 `layer=@tag` 走的路径（**作用域**由标签决定，"层里哪些像素"仍由选择子决定）；
蒙版只有**几何**的（矩形/椭圆 + 圆角 + 羽化 + 毛边 + 反选）——栅格蒙版（画笔涂抹）、live mask（引用下层 alpha）都未做；蒙版参数化系统只做到**矢量蒙版这一半**（含 `roughen`）；与 MVSL 选择子的软覆盖**在实现层已统一**（`pixel.soft_cover` 是唯一原语，蒙版=「朝内+Linear」、选择子=「朝外+Smooth」，两侧预设逐值复现旧实现、渲染逐位不变），但**语义层刻意不合并**（方向 + 缓动的差异是各自的历史承诺，合并必改一方数值，属产品决定，见 PLAN-MVSL §P2）；调整层是叠加式像素算子（算子与强度**可用 `set-adjust` 原地改、层序不变**；此前只能删了重加，而重加会把它推到栈顶、连作用范围一起变。但它仍是"叠加式"的——不能限定作用范围到单个层，也没有调整层蒙版/剪贴）；文本层只有 ASCII 点阵字形（无 CJK、无字体文件，见 `demo` 的字形表）；其余未做：贝塞尔、图层样式 fx、PSD/AI 等外部格式兼容（远期，见 DESIGN 远期章节）、16/32-bit、CMYK、自由笔刷。线段层占位矩形 w/h 必须为正（水平线请给 h≥描边宽）。

编辑表的代价护栏只管**时间**、不管**内存**：`算子数 × 像素数 ≤ 2e8`（`edit_cost_error`，按实测 2 µs/(像素·算子) ≈ 400 秒）**隐含**一个 ≈ **2.4–2.9 GB** 的峰值上限，且**与画布尺寸无关**（每条算子留一个整幅中间缓冲 4 B/px + 每个不同选择子留一份整幅浮点场 8 B/px；实测 12–14.4 B/(像素·算子)，`python3 bench_perf.py m3`）。所以「装得进表」不等于「跑得起来」：190 条算子 × 1024×1024 恰好通过时间护栏，却要申请约 2.9 GB。这条**已报出来、但刻意没拦**——拦它等于改被接受的集合，属产品决定（浏览器 tab 里多少内存算可接受）；收紧的旋钮只有 `MAX_EDIT_PIXEL_OPS`（时间内存同降）或给判据加一条内存维，见 DESIGN §8。

（这一行原先写着"文本层、蒙版、调整层不做"——那三项**后来都做了**却没人回来改，属于少报能力；顺手纠正。）

MVSL 侧的诚实边界：编辑表是**文档级的最终一遍**——`最终图 = apply(编辑表,
层合成底图)`；含 `layer=` 算子时走**两段式**（被引用的层各自栅格化到透明底 →
只施加属于它的算子 → 合成回去 → 再施加文档级算子）。`render` / `previews/` /
`mvsl-impact` 三条出口给出同一张图，`verify.sh#mvsl-e2e` 对**文档级与图层级
两种表**都断言 render 与 impact 的 sha256 相同。
**跨作用域的相对顺序不保留**（DESIGN §8 已声明）：一条文档级算子无法插在两条
图层级算子中间。`stage:n` **一律按表序**（段内重编号由引擎一处完成，所以"表里
第 n 条"就是它取到的缓冲；被引用那条必须与引用者**同段**——同为文档级算子，或
同为**同一个层**的算子——且**严格在它之前**，跨段与自指/前视都拒，所以图层级算子
也能用 `stage:n>0`（目标在同层且更早即可）；`stage:0`=本段输入）；`layer=` 的逐算子报告按
**真实执行顺序**给出并带上层 id
（`layer=@<标签>` 展开成几层就是几条）。
`recolor` 的半透明边缘混色分离（`I = αF + (1−α)B`，只改 F）**在合成底图上
无解**（不是"未做"）：反演要同时知道前景覆盖率 α 与背景色 B，而 α 在层合成
那一刻就被乘掉了——"白底 + 50% 红"与"纯粉红"在底图上逐位相同（`render_test`
有判定性测试）；**`layer=` 作用域正是它的答案**（选择子在层栅格上求值，那里
F 与 B 还没乘在一起）。渲染底图**永远不透明**（`render_layers` 先铺满白底再画
图层，`render_test` 有整幅"无半透明像素"断言），所以**文档级**算子根本处理不到
半透明像素。外部 mask 资产只能引用、引擎不内置任何分割模型（未登记即报精确
错误，不降级）。
HSV 只做 selector/analysis affordance，算子一律走 OKLab/OKLCh（V 不是感知亮度）。

**分析出口不许是"另一套实现"**：`mvsl-impact` 的逐算子 diff、`mvsl-assert` 的
断言判定、`lint` 的白装/违约判定、`probe` 的逐算子 membership 全部取自
`render.impact_stages`（渲染与分析**共用同一段执行代码**，`render_doc_with`
就是它的最终图那一半），每个算子量的是**它自己真正执行的那一步**（层算子 =
层栅格、文档级 = 合成底图）。此前它们各自在合成底图上跑整张表（`run_program`
根本不看 `layer`）：`layer=l1` 的表被报成"整幅 2048 个像素都改了"、与文档级
给出**同一个 sha**；`mvsl-assert` 在**错的图**上判定保护断言（安全网变成假安心）；
`probe` 报的是另一张图上的 membership。现在这类分叉**在构造上不可能**，
变异 U7–U12 守着这条不变量。

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
  `open/execOn/close`、`render`/`saveMpd`/`openMpd` 门面）——宿主侧唯一 JS 胶水，
  引擎本体 100% MoonBit；
- **容器存取对称**：页面「📂 打开 .mpd」可把存过的容器装回来（按容器自己的
  画布尺寸重渲染），SDK 侧是 `openMpd(b64)`。在此之前引擎有 `open-mpd`、verify.sh
  也测着"open→save 字节一致"，但**SDK 只有 `saveMpd`、页面只有保存按钮**——
  `.mpd` 号称唯一事实源，却能存不能开，等于存了个死文件；
- **真实端点**：DeepSeek / StepFun / OpenAI / 自定义 OpenAI 兼容端点，Key 仅存本页、
  直连端点（接入形态对齐 deepOrca：OpenAI wire + function calling + models.dev 式模型目录）；
- **视觉闭环**：`render` / `select_preview` / `mvsl_impact` 三个图像类工具把 PNG 以附件
  （`SuccessWithAttachments`）回传给多模态模型，AI 真的看图确认效果再继续
  （试选不看图 = 闭眼改色；影响证书不看图 = 发现不了选区跑偏）；
- **55 个工具，MVSL 闭环可达**：`sel_schema`（先看语法：字段名/量纲/示例自证）/
  `census`（先普查再选色）/`probe`（这个点选中没有）/
  `select_preview`（试选 + 连通域事实）/`mvsl_set`（装编辑表）/`mvsl_impact`
  （影响证书）/`mvsl_assert`（保护断言）/`mvsl_show`/`mvsl_clear`。模型只写 **JSON**
  选择子与编辑表，base64 由 SDK 做——不该让 LLM 手搓 base64；
- **引擎侧能力与 AI 可达范围的边界**（诚实边界；`undispatched_tools()` 锁的是
  「工具面 → 引擎」这个方向，反方向是**刻意的子集**——但这份名单不是散文，
  `build_demo.sh#doc-tools` 会机械核对下面这块，同时保证**工具面不许指向一条
  引擎里不存在的命令**。要新增可达能力时改这里，而不是默默改数：
  <!-- unreachable:begin -->
  引擎 63 条命令里，demo 的 AI 够不着 8 条：`session-open` `open-mpd-b64`
  `help` `list-tools` `fingerprint` `add-image` `set-image` `inspect`
  <!-- unreachable:end -->
  各自原因——`session-open`/`open-mpd-b64`：会话与开门由前端管，不该让模型
  自己开门；`help`/`list-tools`：工具清单本来就在 system prompt 里；
  `fingerprint`：完整性自检，前端与门禁用；**`add-image` / `set-image`：要吃图片字节，
  模型无法产出、也无处接收图片字节——插图与换图是人类的动作：前端上传后成为图片层，
  AI 可以在它之上移动/缩放/改样式（`move`/`resize`/`set-style`/`set-mask`），
  但不能凭空造出或替换掉图片像素**；`inspect`：
  文档概览，AI 用 list_layers + edits + stats 已能拼出。**分组不在名单里**：
  `group`/`ungroup`/`group-add`/`group-remove` 四条现在**两侧都有入口**——
  AI 侧是 `group`/`ungroup`/`group_add`/`group_remove` 四个工具，人类侧是
  属性面板的「编组」「解组」按钮与「父级」下拉（根级 ⇄ 某个组）。
- **元参数通道**：`list_params` / `set_param` / `remove_param` 读写命名元参数
  （品牌主色、网点密度这类设计系统元数据）。**纯元数据、不影响渲染**——改画面
  仍要走 MVSL 或图形命令；它的用途是让 AI 在开场先读既有规范（而不是凭空配色）、
  把用户说的设计约定写进容器。删条目用 `remove_param`，**`set_param x ""` 只把值
  改成空串、条目还在**（前者是对偶，后者是改名不改存在）；
- **两套颜色坐标系分家**：`probe`/`census` 报 `sel_h`/`sel_c`/`sel_l`
  （= OKLCh 色相 / OKLCh 彩度 / OKLab 亮度，**直接喂选择子的那三个数**）
  与 `hsv_h`/`hsv_s`/`hsv_v`（仅分析对照）。纯红 #C81E1E 的
  `sel_h≈28, sel_c≈0.20` 而 `hsv_h=0, hsv_s=0.85`——拿错一套的表现是
  「命令成功但一个像素都没选中」；彩度窗整条高于 sRGB 可达上限 0.3225
  会在装表前被**拒绝**（而不是静默返回空选）；
- **参数零容忍（拼错的键不再静默通过）**：**所有** kv 参数命令
  （`set-style`、`add-{rect,ellipse,polygon,line,text,paint,image,adjust,mask}`、
  `set-adjust`、`brush`/`erase`、`new`、`census`、`probe`、`render`、
  `select-preview`、`mvsl-impact`、`mvsl-set`）都会逐个检查参数——**不认识的键、
  漏了 `=` 的裸词、空值一律拒绝**，并给出合法键清单；键归别的命令管时直接指路
  （`points` → add-polygon、`x/y` → move、`w/h` → resize、`text` → set-text）。
  此前 `kv_args` 是**静默**的：`set-style l1 fil=#FF0000`（拼错）、
  `set-style l1 fill`（漏 `=`）、`set-style l1 fill=`（空值）**全都返回 ok 而一个
  像素没改**。实锤还牵出一个真 bug：`apply_style_kv` 的注释写着它会应用 `tag`，
  但实现里没有那条分支 —— `add-rect … tag=background` 一直**被静默忽略**
  （不报错、`tags` 为空），而两条既有测试都用着它、谁也没断言它真的落上。
  现在 `tag=` 可用（与 `tag` 命令共用 `@core.layer_with_tag`，追加去重）。
- **字典承诺的参数必须真的认**：铁律 6 只覆盖**命令清单**，**参数**一直是两张
  互不校验的表——工具字典里写 `key=`（LLM 就是照这个发参数的），解析器里另有
  `check_kv_args` 的允许键表。新增 `param_audit.py`（`verify.sh#params`）双向对账，
  一上来就抓到四处：`add-rect` 的手写键清单漏了 `visible=`、`add-image` 收下整套
  形状键而字典只写了 `x/y/w/h/b64`、`add-text`/`add-adjust` 的 `id=`/`name=`、
  以及 **`erase` 静默收下 `color=`**（橡皮擦恒全强度，渲染器连笔色 alpha 都不读
  —— 那是个收了也不生效的参数）。现在四条 `add-*` 与 `add-text`/`add-adjust`/
  `add-paint`/`add-image` 的键清单都从**与解析器同一个函数**生成；`erase` 拆成
  独立函数并拒收 `color=`。门禁本身还要求"命令名是字面量、键表读得出来"，
  否则判失败——静默跳过就等于这块覆盖没了。
- **`pick`/`sample` 的层 id 必须真的是「在那里画了东西」的层**：`pick` 此前走
  压平的层列表且只查 `visible`，于是三类层被报成"在那里"而实际一个像素都没画
  ——**隐藏组的子层**、**opacity=0 的层**（含祖先组透明度乘下来为 0）、
  **被自己蒙版盖掉的点**；反过来，**画笔层根本拾不到**（它的 `inside_fill`
  恒假）。现在 `pick` 是递归遍历、按 `paint_layer` 的守卫逐条对齐
  （可见性/继承透明度/蒙版/组无面/raster 笔触含 erase），并因此修好了
  `sample` 的自相矛盾：实测它曾同时回 `color=#FFFFFFFF`（白纸，什么都没画）
  与 `layer=l1`（全透明层）。
- **信封里的 sha 必须是回吐那张 PNG 的 sha**：`mvsl-impact` 的 `result_png_b64`
  是 `max=` 降采样**之后**编码的，而 `result_sha256` 曾哈希**全分辨率**结果
  ——画布 64×64、`max=16` 时宿主拿到 16×16 的图，却配着一个算不到它头上的
  sha（**同一个信封里两个字段描述的不是同一张图**）。现在
  `result_sha256` = 回吐那张 PNG 的 sha（与 `render` 的 `render_sha256`
  同一份契约），全分辨率结果另给 `full_sha256`。
  顺带把两处**名字与内容不符**的字段说准：`select-preview` 的
  `base_sha256` → `source_sha256`（它哈希的是底图，回吐的却是 overlay 图），
  `mvsl-assert` 的 `result_sha256` → `result_full_sha256`（这条命令**不回吐
  任何 PNG**，却和"回吐 PNG 的 sha"撞了名）。
- **「某 kind 才有意义」的字段有了完整矩阵**：`text`/`font_size`（只 text 层读）、
  `radius`（只 rect）、`points`（只 polygon/line）、`adjust`（只 adjust 层）、
  `asset`（只 image）、`dabs`（只 raster）、`children`（只 group）——**8 个**。
  在错的 kind 上带着它们 = 死数据：写进 canonical JSON、**改变指纹**，渲染器
  根本不读，于是"改成功了吗"三个信号自相矛盾。此前 lint 只查了 3 个（另 5 个
  谁都没查），而且写成三条手写 `if`；现在是**一行一个字段**的表
  （`kind_only_fields`），漏没漏能一眼数出来。实测这三条通路都有人守：
  入口有 kind 守卫（`set-adjust l1`（rect）报「不是调整层」、`brush layer=l1`
  报「不是画笔层」），容器侧 open 会做**指纹对账**（手改 design.json 直接
  「指纹对账失败」开不了），lint 是第三道。
  第二批挂上时又抓到：`add-mask radus=5` 静默给出硬边直角蒙版、
  `add-adjust value` 拼成 `vlaue` 静默按 0 建一个"没效果"的调整层、
  `brush rr=4` 静默用默认半径。`session-open` 不接受 kv 校验（它认位置参数
  `full_image`；`render`/`select-preview` 同理有位置参数，走放行裸词的
  `check_kv_names`），但把**收到的参数回显**进拒绝文案——拼错 `vison=` 时原来的
  文案会把人误导成"模型不是多模态"。
  第三批是视觉/分析类命令，它们**手写 `has_prefix` 扫 kv**（不走 `kv_args`），
  所以"认不出来也不报错"在这里另有一份：`census bogus=1`、`probe bogus=1`、
  `render 16 bogus=1`、`mvsl-impact bogus=1` **全都返回 ok**。同一批还抓到
  **"值越界就静默退回默认"**：`census components=0` 静默给 16 个连通域、
  `mvsl-impact max=0` 静默按 1024 渲染、`render overlay=yes` 静默不叠加——
  调用方要的和拿到的不是一回事。`render width=16`（把位置参数写成 kv）此前
  报的是一句自己咬自己的 `width=width=16 不是整数`，现在会指路回位置参数。
- **调整层读得回来、改得动**：`query-layer`/`list-layers` 报
  `adjust:{op,value}`（此前调整层整个层就由 op+value 定义，两者却都不报，
  两个不同的调整层长得一模一样）；`set-adjust <id> [op=] [value=]` 原地改，
  **只给一个时另一个沿用原值**。层序不变是关键——删了重加会推到栈顶，
  而调整层作用于其下全部可见层，于是"只改数值"变成"连作用范围也变了"。
  算子名走 `@core.adjust_op_name`（canonical JSON 与命令面**单一实现**）；
- **几何样式读得回来**：`query-layer`/`list-layers` 报 `radius`（仅矩形）与
  `flip_h`/`flip_v`。此前这两个**只写不读**——设了圆角/翻转后画面与指纹都变了，
  却没有命令能把值读回来（fill/stroke 还有 sample/census/probe 这条视觉回读
  路径，几何样式没有：看渲染只能看出"有圆角"，量不出多少像素）。`radius` 在
  **非矩形层**上被入口直接拒绝（渲染器只在 Rect 分支读它，收了就是"指纹变了、
  画面没变"的死数据）；
- **`lint` 会检查编辑表与几何侧的「空操作」**（一整类「每个命令都返回 ok、
  渲染也成功、只是什么都没干」的失败）：空组（没有任何成员，直通合成里什么都
  不做）、空文本层（渲染不出任何字形）、**非文本层上带 `text` 字段**、
  **非矩形层上带 `radius`**（渲染器
  只对 Text 层读它，它却会写进 canonical JSON、**改变指纹**——于是"改成功了
  吗"的信号自相矛盾：指纹说变了、画面逐位没变。入口 `set-text` 已直接拒绝，
  lint 兜住手改容器）；
- **`lint` 还会检查编辑表的失败**：
  P0 装了表却整张图逐位未变（选择子没命中）、P0 保护断言被违反、
  P1 某条算子白装、P1 构造性空算子（`hue_deg=0` / `temp_kelvin=0` /
  `relight_gain=1` / `amount=0`）、P1 **空断言**（保护断言的选择子零命中——
  它恒真，给的是虚假的安心：用户以为「别动背景」被机器守着，其实什么都没守）、
  P0 编辑表执行失败（如 mask 资产未登记）。
  只报 `changed_total=0` 是不够的——那需要调用方先知道 0 意味着"我什么都没改"；
- agent 层用 mooncakes 的 **colmugx/posoco**（六边形端口框架：ModelPort /
  ToolProvider / Observer 三端口扩展；Observer 即"全程可见"的官方通道）。
  评估记录：moonllm（DC-Z-lab）锁 `+native` 不适用浏览器，弃用。

## 一键验证门（`./verify.sh` 13 步，任何一步失败即非零退出）

> 散文里引用步骤**一律写 slug**（`verify.sh#anchors`），**不写编号**：
> 编号会随插入步骤错位——实测这里曾把锚点自检写成过一个当时的步号，插入
> 一步之后就指向了**别的**步骤，而没有任何东西会红（具体经过见 PLAN.md
> 六之三十五）。现在 `verify.sh` / `build_demo.sh` 各带一张机器可读的
> `step-slugs:` 映射，文档里的 slug 引用由验证门逐条核对存在性；再冒出编号
> 引用（`第 N 步` / `N/12` / `N/8`）也直接红。

1. `moon check` 零错误零警告；
2. `moon test --target native` 全绿（NIST/CRC 已知答案、deflate/ZIP/PNG 往返、golden 渲染、容器确定性、八类拒绝路径、会话 e2e）；
3. `moon check --target wasm-gc` + wasm-gc 测试全绿（引擎包纯字节进出的硬背书）；
4. CLI 子进程端到端：管道喂命令（含 add-image 位图资产）→ 落盘 `.mpd`；
5. **独立外部验证**：系统 `unzip -t` 校验容器 + 条目齐全性 + manifest 格式标识 + 元参数层可直接文本阅读——不依赖引擎自证；
6. **open→save 字节一致**：载入容器后原样重打包，与原文件逐字节相同（确定性 pack 的进程级闭环）；
7. **MVSL 命令面 + 渲染管线闭环（子进程 e2e）**：安装编辑表 → `render` 与 `mvsl-impact` 的 sha256 必须**相同**（编辑表真的进了渲染管线，不只是被存下来）→ 校验改动像素数与选区外泄漏率 0 → `mvsl-assert`（合法程序放行、侵犯保护区的程序被拦下并给出条数）→ **`lint` 必须报出必然空选的编辑表与违约的保护断言**（这类失败其它命令全返回 ok）→ 编辑表随容器往返且开→存字节一致 → 带/不带编辑表的 `previews/flat.png` 必须不同（预览不撒谎）。
8. **命令字典与分发一致**（铁律 6）：`list-tools` 吐出的每个命令都逐个真实调用，必须不报"未知命令"；同一步做**文档数字对账**——README/DESIGN/AGENTS 里的命令条数、变异条数、`verify.sh` 步数，以及步骤 slug 引用的存在性；
9. **命令参数下界自检**：每个 `cmd_*` 读 `tokens[N]` 之前必须先卡住 `N`（下界写小了不报用法错、而是越界 panic——实测 `set-text l1` 把 CLI 干掉了，而 `verify.sh#catalog` 只用裸命令名逐个戳，照不到带参数才越界的那批）；
10. **变异锚点自检**：每个变异锚点必须唯一命中 1 处（秒级）。锚点失效 = 那块覆盖被悄悄拿掉，而汇总里的「N 个变异全部通过」照旧好看；
11. **字典 ↔ 解析器参数对账**：字典承诺的 `key=` 必须真的认（双向）；读不出键表/命令名不是字面量 → 判失败，别静默跳过；
12. **依赖方向门禁**（铁律 5）：内部边全部朝前、`pixel` 不依赖 `render`、引擎包零第三方、FFI 只在 cli/demo、demo 不 import 引擎包；外加 DESIGN §3 ↔ `core/document.mbt` 逐字对账（层类型/层属性/填充/混合，双向）；
13. **字段面门禁**（`field_audit.py`）：`Layer` 的每个字段都必须有"建层之后改得动"的归属，改不动的要显式声明为身份字段——「改得动吗」这一面**不许靠手走**（手走三处就下了"到此走完"的结论，实测漏掉位图换图与位图盒子两处）。

## 变异测试门（`python3 mutation_scan.py`，本机约 42 分钟）

**「测试全绿」不等于「行为被守护」。** 这个脚本往产品代码注入语义 bug，跑测试看能否抓住；
有「应当被抓住却存活」的变异即非零退出。它存在的理由是本仓库两次真实教训：

- **M1 把 MVSL 的软权重硬边化**（`lerp(in, op(in), w)` 的 w 换成 1.0）—— 编辑表最核心的
  那句话，当时 150 条测试全部通过。原因：已有断言全是契约/结构（覆盖率、连通域、泄漏率、
  canonical 往返），而 render 的 golden 走 `render_doc`（空编辑表）**根本不经过 `lerp_argb`**；
- **`leak_ratio` 的判据用错了阈值**（软过渡带被误报成「选区外泄漏」），而守着它的 5 处断言
  是子串匹配（`"leak_ratio":0` 会被 `0.0279` 骗过），真 bug 因此藏了好几轮；
- **N3 半透明合成不去预乘**：已有的混合测试全用**不透明**层（ao=1 时预乘即直通），
  把去预乘那一步换成"直接返回预乘值"全部测试通过——半透明合成整片偏暗而无人察觉；
- **N7 几何选择子丢掉羽化**：色彩窗的羽化有测试，几何窗（rect/ellipse）的 feather
  是另一个入口，写成硬边照样全绿。

- **P3 manifest 的 `counts` 无人校验**：把 `layers` 和 `assets` 计数互换全部测试通过——
  而 `counts` 正是工具/审阅者据以判断"容器里有什么"的对外事实。

当前 169 个变异中 168 个被抓住，唯一存活的 M2 是**已确认的等价变异**。
变异门自己也有一个静默失效模式：锚点文本被重构改掉或变得不唯一，那个变异就
**再也没跑过**，而汇总里的「N 个变异全部通过」照旧好看（实测踩过：两个变异
静静失效了一轮）。所以 `verify.sh#anchors` 用 `--check-anchors` 秒级校验
"每个锚点唯一命中 1 处"，锚点失效直接让门禁红（去掉空表短路后行为逐位相同）。
覆盖路径：编辑表数值语义 / 三个指纹 / 保护断言 / lint / W3C alpha 合成与 blend 模式 /
几何选择子 / 覆盖预览与盒降采样 / SHA-256 / PNG / ZIP-CRC / 容器 manifest /
命令行分词（自由文本的引号与转义）/ 字典与实现的一致性（set-mask 不许静默无效）/ 批量入口与单点入口的字段一致性（probe 的两条路不许走样）/ 蒙版参数真的被消费（radius 圆角、feather 羽化与它的内距、roughen 毛边且噪声必须可复现）/ 蒙版部分更新不许退化成全量替换 / 蒙版解析与取值判据不许静默（未知 kind、负 roughen）/ 容器契约档位按实际能力声明 / `stage:n` 一律按表序且不许前视（两段式下段内重编号必须与判据成对，图层级只能用 `stage:0`）/ 两种 `feather` 的软覆盖方向（geo 朝窗外、蒙版朝窗内）/ 共享软覆盖原语的两个预设逐值复现旧实现（Linear 蒙版与 Smooth 选择子都不许被改）/ `feather<=0` 走硬边且**不许出 NaN**（实测 NaN 会让整包测试挂死）/ 编辑表规模护栏（算子数 256、断言数 64、像素·算子 2e8 三条限额，且**入口与渲染各判一次**——装表后 `set-canvas` 放大的路只有渲染侧拦得住）。
新增核心语义（新的算子/选择子判据/指纹/断言）时，同步往 `MUTS` 加一条变异。

## 性能标定（`python3 bench_perf.py`，**不进任何门禁**）

它量的是**墙钟时间**：换机器、换构建模式数字就变，所以**不是判据**，也不进
`verify.sh`。它存在的意义只有一个——让文档里写的性能数字**能指回一次可重复的
测量**（本仓库为这条纪律付过代价：一次"优化"改动差一点被写成"提速 43 倍"，
重复测量后收益在噪声内，见 PLAN 补遗十七）。

```bash
python3 bench_perf.py            # 自检 + 两个实验全跑（约 4 分钟）
python3 bench_perf.py selfcheck  # 只验测量前提：尺寸对不对、蒙版有没有生效
python3 bench_perf.py m1         # 编辑表代价模型
python3 bench_perf.py m2         # 12MP 渲染证伪线
```

`selfcheck` 是必须的先决条件：它直接读 **PNG 头**核对 `render 4000` 真的吐出
4000×3000（**别信信封里的 `width`**——信封可能描述的是另一张图），并确认软蒙版
**确实改变了渲染**（sha 不同），而完全同位的硬边蒙版**逐位不变**才是对的。

两个实验的结论（详细读数见 DESIGN 边界节）：

| 实验 | 结论 |
| :-- | :-- |
| m1 编辑表代价 | ≈ **1.9 µs/(像素·算子)**；线性于 `画布像素数 × 算子数`；瓶颈是**逐像素色彩变换**（≈1.5）而非选择子求值（≈0.4）。据此设了编辑表三道限额 |
| m2 12MP 证伪线 | 端到端 **1 层 1.22 s（成立）/ 4 层 3.63 s / 10 层 8.78 s**——**每层边际 ≈ 0.84 s，线在约 2 层处就破了**；**软蒙版不是瓶颈**（10 层下边际 ≈ 0），逐层合成才是 |

⚠️ 写这类脚本时最容易踩的三个坑（脚本首部注释里逐条写着）：**全链必须查
`"error"`**（有一次整轮标定跑在空画布上，因为 `add-rect l1 …` 少写了 `id=`）、
**`render` 默认是 1024 预览**（量 12MP 必须写 `render 4000`）、
**`add-mask` 是位置参数命令**。

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

> 本区域由 **deepGit** 自动维护（浅更新）· 更新于 2026-10-01 00:05
> 追踪 2 个分支 · 3 处未提交改动

### 工程脉搏

- 提交构成：`feat` ×10 · `fix` ×12 · `docs` ×3 · `other` ×1
- 注意：1 个未跟踪文件；`dev` 可直接 fast-forward 到 `main`

### `dev`（当前）

- **状态**：活跃 · 最近提交 9 分钟前（`adc33d9c` docs: 说准数字 —— 5 处子串断言是 4 处 leak + 1 …）
- **摘要**：新增 16 个提交（修复×7、新增×6、文档×3），涉及 agent（12 文件）、docs（10 文件）、pixel（10 文件）
- **近期进展**
  - 文档：“说准数字 —— 5 处子串断言是 4 处 leak + 1 处 coverage”
  - 修复：“leak_ratio 判据用错阈值 —— 软过渡带被误报成「选区外…
  - 修复：“渐变端点是归一化 0..1 —— 写成像素不再静默变成纯色”
  - 文档：“校准文档口径 —— 命令数 56→57，测试数去掉陈旧快照”
  - 新增：“空断言检测 —— 恒真的保护断言是虚假的安心”
- **下一步**
  - 本次改动较大，建议补充测试与文档
- 本次记录 16 个提交

### `main`（默认分支）

- **状态**：活跃 · 最近提交 1 天前（`bc27a023` MoonPainter 0.1.0：.mpd 双层容器 + 参数化绘制引…）
- **摘要**：最近 1 个提交：更新×1
- **近期进展**
  - 更新：“MoonPainter 0.1.0：.mpd 双层容器 + 参数化绘制引擎 + …
- 本次记录 1 个提交
<!-- deepgit:end progress -->
