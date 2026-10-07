// 人类面「点击穿透」：用最小 DOM 壳加载**真的**构建产物 demo.js，直接调页面
// 处理器（`globalThis.__poly_finish()` 这些），再从引擎把状态**读回来**断言。
//
// 为什么需要它：处理器这一层此前只有源码级证据——`demo_test` 查"名字有没有
// 注册"、`panel_html_wbtest` 查"拼出来的 HTML 里有没有这个按钮"。**"点了到底
// 动不动引擎、动的对不对"从没被机器验过**，只有人在浏览器里点。仓库反复写在
// 纪律里（"别把'在浏览器里点一下'当整块——静态那半可机器验"），这就是那半。
//
// 边界要说清：这一层验的是 **处理器 → do_* → 引擎 → 状态** 这条链。
// **DOM 本身的正确性**（元素 id、CSS、画布坐标换算、事件绑定）仍然只有浏览器
// 能验，所以下面的 document 是刻意的哑壳——它只保证处理器跑得下去，
// 不假装自己验证了页面。
//
// 用法（在 dist/ 里）：`node clickthrough.mjs`；全过退出码 0，否则 1。

const els = new Map();
// 页面**追加日志**（`js_log_line` 往 `#ailog` append 一行一行）与
// **下载**（`js_download_file` 建一个 `<a download>` 再 click）是两条人面反馈的
// 主干道。哑壳要能看见它们，就得比"什么都不做"多走半步：
//   - `createElement` 返回**新**元素（原来所有临时元素共用一个 `_tmp`，日志行会互相覆盖）；
//   - `appendChild` 真的累积（否则日志写了也读不回来，"点了没反应"与"写了但壳看不见"分不清）；
//   - 链接的 `click()` 把 `{name, href}` 记进 `__downloads`（浏览器真下载无法测，
//     但"点保存时到底有没有把非空字节交给一个 .mpd 文件名"能测，而且这才是会坏的那半）。
// 仍然**不假装**验证 DOM：没有 CSS、没有布局、没有事件分发。
globalThis.__downloads = [];
// 工具状态（笔宽/笔色）：`do_stroke` 从这里读 `size`/`color`，空串会拼出 `r=` 这种
// 空值参数（引擎拒它）。浏览器里这些由工具栏设置，驱动器给它一组确定值。
// headless 分支**不跑** `setup_tool_state()`（那在浏览器分支里：它把 HTML 控件的
// 初值 bind 进 `MPST`），所以这里的 `MPST` 就是**驱动扮演的"人调好的工具参数"**。
// 新增工具参数（如仿制图章的 `csize`）时，这里必须一起给——否则命令拼出来是
// `r=` 空值，引擎回「`r=` 的值是空的」，而现象看着像"这个工具没做"。
globalThis.MPST = {
  tool: 'rect', size: '6', csize: '8', color: '#3366FF', strength: 0.35, zoom: 1,
};
function mkEl(id) {
  return {
    id,
    value: '',
    textContent: '',
    innerHTML: '',
    src: '',
    href: '',
    download: '',
    className: '',
    style: {},
    dataset: {},
    children: [],
    // classList 用真的集合：`js_toggle_ai` 折面板靠 `classList.toggle('closed')`
    // 与 `contains` —— 假的实现会让"折叠到底动没动"变成不可观测（判据只能靠猜）。
    classList: {
      _s: new Set(),
      toggle(c) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); },
      add(c) { this._s.add(c); },
      remove(c) { this._s.delete(c); },
      contains(c) { return this._s.has(c); },
    },
    addEventListener() {},
    setAttribute() {},
    removeAttribute() {},
    appendChild(c) {
      this.children.push(c);
      return c;
    },
    click() {
      if (this.download) {
        globalThis.__downloads.push({ name: this.download, href: String(this.href || '') });
      }
    },
    querySelector: () => null,
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 1, height: 1 }),
  };
}
function el(id) {
  if (!els.has(id)) els.set(id, mkEl(id));
  return els.get(id);
}
const doc = {
  getElementById: (id) => el(id),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener() {},
  createElement: () => mkEl('_new'),
  createElementNS: () => mkEl('_new'),
  head: el('head'),
  body: el('body'),
};
globalThis.document = doc;
globalThis.localStorage = {
  _m: new Map(),
  getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
  setItem(k, v) { this._m.set(k, String(v)); },
  removeItem(k) { this._m.delete(k); },
};
if (!globalThis.performance) globalThis.performance = { now: () => Date.now() };
globalThis.requestAnimationFrame = (f) => setTimeout(f, 0);

// **构建元数据要在 import 之前设**：浏览器里 `dist/index.html` 的 inline script
// 就排在 `demo.js` 之前（`build_demo.sh` 写的那段）。顺序反了就不算"与浏览器
// 同一状态"——而徽标正是"这一页是哪一版"的唯一可见凭据（人做功能测试的第一件事）。
globalThis.__MP_BUILD__ = {
  time: '2026-10-03T00:00:00Z',
  commit: 'ct1234',
  wasm_sha: 'abcdef0123456789',
  demo_sha: 'fedcba9876543210',
};

// 先 import（此刻还没有 window，`js_is_node()` 为真 → 走 headless 分支：
// 引擎自检 + 注册处理器表 + 暴露引擎入口）。之后再把 window 补上，
// 因为处理器要用 `window.MPST`（工具/颜色/笔宽）与 `window.__polyPreview`。
await import('./demo.js');
globalThis.window = globalThis;
// 页面画预览会调 `window.__polyPreview(点串)`（`js_poly_preview` 的 FFI）。
// 哑壳把它记下来——"处理器 → 引擎采样 → 交给画布"这条链才有可断言的事实。
globalThis.window.__polyPreview = (pts) => {
  globalThis.__MP_lastPolyPreview = pts;
};

const results = [];
function check(name, cond, extra) {
  results.push({ name, ok: !!cond, extra: cond ? '' : String(extra === undefined ? '' : extra) });
}
const exec = (line) => JSON.parse(globalThis.__headless_exec(line));
const layers = () => exec('list-layers').layers || [];
const layer = (id) => (exec('query-layer ' + id).layer || {});
const status = () => el('sbar-text').textContent;
const flush = () => new Promise((r) => setTimeout(r, 0));
// 日志元素里累积的全部文本（`js_log_append` 往它 append 子元素）
const logText = (id) => (el(id).children || []).map((c) => c.textContent || '').join('\n');

check(
  'headless 里注册了页面处理器表（否则下面的"点击"根本没发生）',
  typeof globalThis.__poly_finish === 'function' &&
    typeof globalThis.__tool === 'function' &&
    typeof globalThis.__shape_ready === 'function' &&
    typeof globalThis.__headless_exec === 'function',
  Object.keys(globalThis).filter((k) => k.startsWith('__')).length,
);

// **与浏览器从同一状态出发**：浏览器在 main 里 bootstrap（开照片工作台）。
// 不先做这一步的话，第一个调用 `bootstrap()` 的处理器会把下面的测试文档整个
// 换成工作台——那时四条断言会一起错，而现象看着像"pick 报错了层"。
globalThis.__headless_boot();
await new Promise((r) => setTimeout(r, 0));
// 工作台是**空的**（1 层白底），不是一张预置的矢量海报：这个工具要干的是
// "把照片导进来修"。此前预置 4 层示例，人一打开就以为它是画图/做海报的。
check(
  '初始化：进来就是空照片工作台（1 层白底，没有预置海报）——说明驱动器与浏览器同状态',
  layers().length === 1 && layers()[0].name === '画布底色' && layers()[0].kind === 'rect',
  JSON.stringify(layers().map((l) => l.name)),
);

// 干净起点：确定性画布（引擎的会话在 headless 自检里已经开好）
exec('new 300 200 uuid=ct');
check('起点：0 层', layers().length === 0, JSON.stringify(layers()));

// ① 多边形：逐点点三个点 → 结束 → 引擎里多一个形状正确的 polygon
globalThis.__tool('poly');
globalThis.__poly_click('100,100');
globalThis.__poly_click('160,100');
globalThis.__poly_click('130,160');
check('点第三个点时状态栏在报进度（人得有反馈）', /已点 3 个点/.test(status()), status());
globalThis.__poly_finish();
await flush();
{
  const ls = layers();
  const l = ls[0] || {};
  check('多边形：真的建了 1 层', ls.length === 1, JSON.stringify(ls));
  check('多边形：kind=polygon', l.kind === 'polygon', l.kind);
  check('多边形：盒子=点的包围盒 (100,100,60,60)', l.x === 100 && l.y === 100 && l.w === 60 && l.h === 60, JSON.stringify(l));
  check('多边形：points 是相对盒子的局部坐标', JSON.stringify(l.points) === JSON.stringify([[0, 0], [60, 0], [30, 60]]), JSON.stringify(l.points));
  check('多边形：建完清空待点（再结束一次不该又建一层）', (globalThis.__poly_finish(), await flush(), layers().length === 1), layers().length);
}

// ② 折线：两个点，且是**水平**线（盒高会被抬到 1——引擎的 w/h>0 是硬下界）
globalThis.__tool('line');
globalThis.__poly_click('10,20');
globalThis.__poly_click('40,20');
globalThis.__poly_finish();
await flush();
{
  const ls = layers();
  const l2 = ls.find((x) => x.kind === 'line') || {};
  check('折线：建出 kind=line 的层', !!l2.id, JSON.stringify(ls));
  check('折线：水平线的盒高被抬到 1（不是 0）', l2.x === 10 && l2.y === 20 && l2.w === 30 && l2.h === 1, JSON.stringify(l2));
  check('折线：points 局部坐标', JSON.stringify(l2.points) === JSON.stringify([[0, 0], [30, 0]]), JSON.stringify(l2.points));
}

// ③ 点数不够：多边形只点两个点就结束 → **不建层**，而且要说话
globalThis.__tool('poly');
globalThis.__poly_click('200,200');
globalThis.__poly_click('210,210');
const before = layers().length;
globalThis.__poly_finish();
await flush();
check('点数不够：不建层（下界与引擎同一把尺子）', layers().length === before, layers().length);
check('点数不够：状态栏说还差几个', /还差 1 个/.test(status()), status());

// ④ 拖拽形状：椭圆按框建层；太小的框不建层且明说
globalThis.__shape_ready('ellipse', '5,5,40,30');
await flush();
{
  const e = layers().find((x) => x.kind === 'ellipse') || {};
  check('椭圆：按拖拽框建层 (5,5,40,30)', e.x === 5 && e.y === 5 && e.w === 40 && e.h === 30, JSON.stringify(e));
}
const n2 = layers().length;
globalThis.__shape_ready('rect', '5,5,1,1');
await flush();
check('太小的框：不建层', layers().length === n2, layers().length);
check('太小的框：状态栏说"太小了"', /太小了/.test(status()), status());

// ④b 吸管：一下点击**取色 + 选中该点图层**（人类侧唯一一条"点哪儿选哪儿"）
globalThis.__pick_at('105,105');
await flush();
{
  const inside = layers().find((x) => x.kind === 'polygon') || {};
  const props = String(el('pprops').innerHTML);
  check('吸管：点在多边形里 → 属性面板切到那一层', props.includes(inside.id), 'props 里没有 ' + inside.id);
  check('吸管：状态栏说选中了哪一层', /已选中/.test(status()), status());
  check('吸管：命中时不该误报"这一点没有层"', !/没有层/.test(status()), status());
  globalThis.__pick_at('295,195'); // 画布右下角空白
  await flush();
  check('吸管：点在空白处 → 说"这一点没有层"（空集也要说话）', /没有层/.test(status()), status());
  check(
    '吸管：点在空白处不该清掉已有选中态',
    String(el('pprops').innerHTML).includes(inside.id),
    '选中态丢了：props 里没有 ' + inside.id,
  );
}

// ⑤ 属性面板那几个入口（改名/改坐标/标签）走的是"回读另一半再整对发"的路
const pid = (layers().find((x) => x.kind === 'polygon') || {}).id;
globalThis.__rename(pid, '改过的名字');
await flush();
check('改名：引擎里的名字真的变了', layer(pid).name === '改过的名字', layer(pid).name);
const yBefore = layer(pid).y;
globalThis.__setx(pid, '77');
await flush();
check('改 X：x 变了', layer(pid).x === 77, layer(pid).x);
check('改 X：y 没被动过（move 是整对赋值，必须回读另一半）', layer(pid).y === yBefore, layer(pid).y);
const wBefore = layer(pid).w;
globalThis.__seth(pid, '90');
await flush();
check('改 H：h 变了', layer(pid).h === 90, layer(pid).h);
check('改 H：w 没被动过（resize 同理）', layer(pid).w === wBefore, layer(pid).w);
globalThis.__tag_add(pid, 'hero');
await flush();
check('打标签：引擎里真的有这个标签', (layer(pid).tags || []).includes('hero'), JSON.stringify(layer(pid).tags));
globalThis.__tag_del(pid, 'hero');
await flush();
check('摘标签：能打上就必须能摘下', !(layer(pid).tags || []).includes('hero'), JSON.stringify(layer(pid).tags));

// ⑥ 坏输入要**报错原话**，不许静默画到别处（严格解析那一条）
globalThis.__tool('poly');
globalThis.__poly_click('abc,1');
check('坏坐标：状态栏报"没读出来"（不许当成 0,0 画上去）', /没读出来/.test(status()), status());
globalThis.__poly_cancel();

// ⑦ 每一次成功提交都会重渲染：画布 img 拿到新的 data URL
check('渲染：画布拿到 data:image/png;base64 的图', String(el('canvas-img').src).startsWith('data:image/png;base64,'), String(el('canvas-img').src).slice(0, 40));

// ⑧ 失败也要能被看见：给一条引擎会拒的命令（画布超上限），状态栏要带 ⚠
globalThis.__set_canvas = globalThis.__set_canvas || (() => {});
const fp = exec('fingerprint').fingerprint;
globalThis.__rename(pid, '');
check('空名字：入口直接拦（引擎那边空名字会写进指纹而列表上只剩空行）', /不能为空/.test(status()), status());
check('被拦下的时候文档没变（指纹不动）', exec('fingerprint').fingerprint === fp, exec('fingerprint').fingerprint);

// ⑨ 会失败的入口必须**把引擎原话摆出来**（PLAN 五十二：这批处理器原先
//    `let _ = engine_exec_line(…)` 丢掉回包 ⇒ 点了什么都不发生、也没有一句话）
exec('add-rect x=0 y=0 w=40 h=40 fill=#FF0000FF id=gm1');
exec('add-rect x=50 y=0 w=40 h=40 fill=#00FF00FF id=gm2');
exec('group gm gm1 gm2');
// ①组上用蒙版：组不读蒙版（`caps` 里没有 mask）⇒ 引擎拒，理由要看得见
globalThis.__mask_invert('gm');
await flush();
check(
  '组上用蒙版：状态栏报引擎原话（此前丢回包 = 点了没反应）',
  /⚠/.test(status()) && /mask 不生效/.test(status()),
  status(),
);
// ②已经在组里的层再点「编组」：`group` 的成员必须是根级层 ⇒ 被拒且文档不变
const fpGroup = exec('fingerprint').fingerprint;
globalThis.__group_sel('gm1');
await flush();
check(
  '组里的层再编组：状态栏报引擎原话，且文档没变',
  /⚠/.test(status()) && /不是根级层/.test(status()) && exec('fingerprint').fingerprint === fpGroup,
  status(),
);
// ③正控：同一个按钮在**根级**层上是真能编组的（判据两头都咬得住）
exec('group-remove gm gm1');
await flush();
globalThis.__group_sel('gm1');
await flush();
check(
  '正控：根级层点「编组」真的建出组（不是所有点击都报错）',
  !/⚠/.test(status()) && layers().some((l) => l.kind === 'group' && (l.children || []).some((c) => c.id === 'gm1')),
  status(),
);

// ③ 「🩺 自检 · 调试」面板的**每一颗按钮**都必须点得动。
// 这 18 个处理器此前从未被任何驱动器走过（`__selfcheck` 是用户做功能测试的
// **第一件事**）。两层判据：①调用不抛（抛了就是 JS 报错，面板上一个字都不出）；
// ②结果真的落到面板元素上（"点了有反应"）。⚠️ 每次先把目标元素清空——不然后
// 一次的输出会替前一次"作证"，一个永远不写的按钮也能靠上一次的残留通过。
const panel = [
  ['__selfcheck', 'sc-report'],
  ['__dbg_lint', 'dbg-out'],
  ['__dbg_edits', 'dbg-out'],
  ['__dbg_census', 'dbg-out'],
  ['__dbg_probe', 'dbg-out'],
  ['__dbg_help', 'dbg-out'],
  ['__dbg_tools', 'dbg-out'],
  ['__dbg_schema', 'dbg-out'],
  ['__dbg_preview', 'dbg-out'],
  ['__mvsl_show', 'dbg-out'],
  ['__mvsl_impact', 'dbg-out'],
  ['__mvsl_assert', 'dbg-out'],
  ['__mvsl_clear', 'dbg-out'],
  ['__param_list', 'dbg-out'],
  // 三条要输入的：给上合法输入（同一个面板里**有输入才干活**的那半）
  ['__mvsl_set', 'dbg-out'],
  ['__param_set', 'dbg-out'],
  ['__param_del', 'dbg-out'],
  ['__cmd', 'dbg-out'],
];
el('mvsl-json').value = JSON.stringify({ version: 1, ops: [], guards: [] });
el('param-k').value = 'ct_k';
el('param-v').value = 'ct_v';
el('cmd-input').value = 'fingerprint';
const stuck = [];
for (const [fn, target] of panel) {
  el(target).textContent = '';
  el(target).innerHTML = '';
  let threw = '';
  try {
    await globalThis[fn]();
    await flush();
  } catch (e) {
    threw = String((e && e.message) || e);
  }
  const out = (el(target).textContent || '') + (el(target).innerHTML || '');
  if (threw) stuck.push(fn + ' 抛了：' + threw);
  else if (out.length === 0) stuck.push(fn + ' 什么都没写进 #' + target);
}
check(
  '面板 ' + panel.length + ' 颗按钮都点得动，且结果真的落到面板元素上（点了有反应）',
  stuck.length === 0,
  stuck.length === 0 ? '全部有输出' : stuck.join('；'),
);

// 拒控（**两头都要咬**）：缺输入时必须在状态栏**明说**，不许静默什么都不做——
// "点了没反应"和"点了但输入没填"在用户眼里一模一样，而后者能一句话说清。
const quiet = [];
for (const [fn, key] of [['__param_set', 'param-k'], ['__param_del', 'param-k']]) {
  el(key).value = '';
  el('sbar-text').textContent = '';
  await globalThis[fn]();
  const t = status();
  if (!/先填/.test(t)) quiet.push(fn + ' 缺输入时状态栏是：' + (t || '(空)'));
}
el('cmd-input').value = '';
el('sbar-text').textContent = '';
await globalThis.__cmd();
if (!/先在输入框/.test(status())) quiet.push('__cmd 缺输入时状态栏是：' + (status() || '(空)'));
el('mvsl-json').value = '';
el('sbar-text').textContent = '';
await globalThis.__mvsl_set();
if (!/先.*贴 JSON|先在/.test(status())) quiet.push('__mvsl_set 缺 JSON 时状态栏是：' + (status() || '(空)'));
check(
  '拒控：面板按钮缺输入时状态栏明说怎么办（不许静默无反应）',
  quiet.length === 0,
  quiet.length === 0 ? '四条拒控都有原话' : quiet.join('；'),
);


// ⑤ 保存 / 导出：**用户一定会点**（作品存不存得下来），而这条链此前从没被走过。
// 断言的是"点了之后到底把什么交给了下载"——文件名对不对、字节是不是空的、
// 日志有没有说实话。浏览器真下载测不了，但"点保存交出一个空的 .mpd"能测。
globalThis.__downloads.length = 0;
el('ailog').children.length = 0;
await globalThis.__save();
const dl = globalThis.__downloads[0] || {};
check(
  '正控：点「保存 .mpd」真的把一个非空字节的 .mpd 交给下载，并在日志里说明',
  /painting\.mpd$/.test(dl.name || '') && /blob:/.test(dl.href || '') && /已保存/.test(logText('ailog')),
  JSON.stringify(globalThis.__downloads) + '｜日志：' + logText('ailog').slice(0, 60),
);
globalThis.__downloads.length = 0;
el('ailog').children.length = 0;
await globalThis.__export();
const dl2 = globalThis.__downloads[0] || {};
check(
  '正控：点「导出 PNG」真的把 export.png 交给下载，并在日志里说明',
  /export\.png$/.test(dl2.name || '') && /blob:/.test(dl2.href || '') && /已导出/.test(logText('ailog')),
  JSON.stringify(globalThis.__downloads) + '｜日志：' + logText('ailog').slice(0, 60),
);

// ⑥ AI 修图：**产品的主按钮**。两种"点了不会干活"的状态都必须在**日志里明说**
// （AI 面板的反馈全走日志，静默失败在这里等于"点了没反应"）。
el('ailog').children.length = 0;
el('ai-request').value = '';
await globalThis.__run();
check(
  '拒控：AI 修图没写需求时，日志明说「请输入需求」',
  /请输入需求/.test(logText('ailog')),
  logText('ailog').slice(0, 80) || '(日志空)',
);
el('ailog').children.length = 0;
el('ai-request').value = '把背景改成蓝色';
el('ai-provider').value = 'openai';
el('ai-baseurl').value = '';
el('ai-key').value = '';
await globalThis.__run();
check(
  '拒控：真实端点没填 Base URL / API Key 时，日志明说缺什么（而不是发一个注定失败的请求）',
  /Base URL|API Key/.test(logText('ailog')),
  logText('ailog').slice(0, 80) || '(日志空)',
);
el('ai-request').value = '';
el('ai-provider').value = '';

// ⑦ 图层列表：**点一层选中它 / 点眼睛隐藏它**——最高频的两个动作，而它们是
// `js_reg1` 处理器（与 `js_reg0` 走的是另一条注册路径，异常处理也要走同一条账）。
const listId = layers()[0].id;
el('sbar-text').textContent = '';
// ⚠️ **先清空**：不清的话列表里还留着上一次的内容，一个"根本没重建"的点击
// 也能靠残留通过（第一版就栽在这儿，注入异常后判据照样绿）。
el('llist').innerHTML = '';
await globalThis.__sel(listId);
const selHtml = el('llist').innerHTML || '';
// 高亮写法是 `class="lrow sel"`（`layers_html` 里 `selc = " sel"`）：断言**被高亮
// 的那一行就是点的那个 id**，而不是"列表里有这个 id 出现"（后者任何重建都满足）。
// 真实标记（照 `layers_html` 的行模板）：`<div class='li sel' onclick='globalThis.__sel("ID")'>`
// ——第一版我按 `data-id=` 猜，注入验证时才看见列表里根本没有这个属性。
const selMark = selHtml.match(/class='li sel' onclick='globalThis\.__sel\("([^"]+)"\)'/);
check(
  '点图层列表里的一层：它被标成选中态，且高亮的就是点的那个（不是"列表非空"）',
  selHtml.length > 0 && selMark !== null && selMark[1] === listId,
  (selMark ? '高亮=' + selMark[1] : '没有高亮行') + '｜列表 ' + selHtml.replace(/\s+/g, ' ').slice(0, 100),
);
// 隐藏：**画面必须真的变**（比 sha）+ 引擎随后报 visible=false（两头都咬）
const visId = layers().find((l) => l.visible)?.id;
const shaBefore = exec('render 40').render_sha256;
await globalThis.__vis(visId);
const shaAfter = exec('render 40').render_sha256;
check(
  '点眼睛隐藏一层：引擎报 visible=false，且画面真的变了（不是只改了个字段）',
  layer(visId).visible === false && shaAfter !== shaBefore,
  'visible=' + layer(visId).visible + '｜sha ' + String(shaBefore).slice(0, 8) + ' → ' + String(shaAfter).slice(0, 8),
);
await globalThis.__vis(visId); // 还原（隐藏会影响后面的用例）
check(
  '正控：再点一次眼睛恢复可见（不是"点了就只能隐藏"）',
  layer(visId).visible === true,
  'visible=' + layer(visId).visible,
);

// ④ 顶栏徽标：**这一页是哪一版**（人做功能测试的第一件事）。
// 正控读的是"启动序列真的填了"——不是"显式调了一次"，所以它同时守住
// "启动时有没有调 do_build_badge"（此前 headless 分支从不调它 ⇒ 徽标恒空）
// 与"js_text 的 id 写错没有"（id 错了读回来是空串，而空串不报错）。
const badge = () => el('build-badge').textContent || '';
check(
  '正控：启动后顶栏徽标已填，且说得出这一页的 commit 与 wasm 前 8 位',
  /ct1234/.test(badge()) && /wasm abcdef01/.test(badge()) && /引擎 v/.test(badge()),
  badge(),
);
// 负控：元数据缺失时必须**明说**"不是 ./build_demo.sh 产出的"，而不是显示假版本号
const savedBuild = globalThis.__MP_BUILD__;
delete globalThis.__MP_BUILD__;
await globalThis.__build_badge();
check(
  '负控：没有构建元数据时徽标明说「不是 ./build_demo.sh 产出的」',
  /不是 \.\/build_demo\.sh 产出的/.test(badge()) && /引擎 v/.test(badge()),
  badge(),
);
globalThis.__MP_BUILD__ = savedBuild;

// ⑧ 编辑动作 / 属性面板 / 层序 / 几何 / 透明度 —— 高频写操作，全部"点了之后
// 从引擎读回来验"，而不是看状态栏说了什么。
exec('new 60 40');
exec('add-rect id=e1 x=5 y=6 w=20 h=10 fill=#FF0000FF name=E1');
exec('add-rect id=e2 x=0 y=0 w=8 h=8 fill=#00FF00FF name=E2');
const order0 = layers().map((l) => l.id);
await globalThis.__front('e1');
const orderF = layers().map((l) => l.id);
await globalThis.__back('e1');
const orderB = layers().map((l) => l.id);
check(
  '「置顶」/「置底」把层序挪到**两端**（不是点了没反应）',
  orderF[orderF.length - 1] === 'e1' && orderB[0] === 'e1' && orderF.join() !== order0.join(),
  order0.join('>') + ' → ' + orderF.join('>') + ' → ' + orderB.join('>'),
);

await globalThis.__setx('e1', '12');
await globalThis.__sety('e1', '13');
await globalThis.__setw('e1', '30');
await globalThis.__seth('e1', '11');
const g1 = layer('e1');
check(
  '属性面板四个输入框：引擎报的 x/y/w/h 就是填进去的（不是只改了输入框）',
  g1.x === 12 && g1.y === 13 && g1.w === 30 && g1.h === 11,
  `x=${g1.x} y=${g1.y} w=${g1.w} h=${g1.h}`,
);

await globalThis.__sel('e1'); // 方向键作用于"选中的层"（空选时它报"先选中图层"）
await globalThis.__move_delta('3', '-2');
const g2 = layer('e1');
check(
  '方向键移动：按 (dx,dy) 走，宽高不动',
  g2.x === 15 && g2.y === 11 && g2.w === 30 && g2.h === 11,
  `x=${g2.x} y=${g2.y} w=${g2.w} h=${g2.h}`,
);

await globalThis.__rotate('e1', '90');
await globalThis.__flip('e1', 'h');
const g3 = layer('e1');
check(
  '旋转 90° 与水平翻转：报告面认账（rot=90 / flip_h=true）',
  g3.rot === 90 && g3.flip_h === true,
  `rot=${g3.rot} flip_h=${g3.flip_h}`,
);

await globalThis.__op('e1', '50');
check(
  '透明度滑块（0..100 → 0..1）：报告面是 0.5',
  Math.abs(layer('e1').opacity - 0.5) < 1e-9,
  String(layer('e1').opacity),
);

// 删除 → 撤销 → 重做：三步都要"层回得来 + 指纹逐字回得去"
const fpOps = exec('fingerprint').fingerprint;
await globalThis.__del('e1');
const deleted = !layers().some((l) => l.id === 'e1');
const fpDel = exec('fingerprint').fingerprint;
await globalThis.__undo('');
const undone = layers().some((l) => l.id === 'e1') && exec('fingerprint').fingerprint === fpOps;
await globalThis.__redo('');
const redone = !layers().some((l) => l.id === 'e1') && exec('fingerprint').fingerprint === fpDel;
check(
  '删除 → 撤销 → 重做：层回得来、指纹逐字回得去（三步都对得上）',
  deleted && undone && redone,
  `删=${deleted} 撤销=${undone} 重做=${redone}`,
);
// 上面为了验"重做"把 e1 留在删除态——后面的用例要用它，撤销放回来。
// （这条也顺手证明了 undo 栈是按顺序的：redo 之后还能再 undo。）
await globalThis.__undo('');

await globalThis.__rename('e2', '改过的名字');
check('重命名：引擎报的 name 就是新名字', layer('e2').name === '改过的名字', layer('e2').name);
await globalThis.__tag_add('e2', 'hero');
const tagged = JSON.stringify(layer('e2').tags || []);
await globalThis.__tag_del('e2', 'hero');
check(
  '标签：打得上去也摘得下来（"能打上的名字必须能摘下"）',
  /hero/.test(tagged) && !/hero/.test(JSON.stringify(layer('e2').tags || [])),
  tagged + ' → ' + JSON.stringify(layer('e2').tags || []),
);

// 父级：建组 → 把 e2 加进组 → 再解组（层要回根级）
exec('add-rect id=gkeep x=0 y=0 w=4 h=4 fill=#0000FFFF name=GK');
exec('group grp gkeep'); // 位置参数：`group <gid> <id>...`（kv 写法不报错也不建组）
await globalThis.__reparent('e2', 'grp');
const inGroup = JSON.stringify(layers()).includes('grp') &&
  (layers().find((l) => l.id === 'grp')?.children || []).some((c) => c.id === 'e2');
await globalThis.__ungroup_sel('grp');
const rootAgain = layers().some((l) => l.id === 'e2') && !layers().some((l) => l.id === 'grp');
check(
  '「父级」下拉把层放进组，解组后回到根级（两次都从引擎读回来验）',
  inGroup && rootAgain,
  `进组=${inGroup} 回根级=${rootAgain}`,
);

// ⑨ 文字层：点画布定位 → 输入内容建层 → 改内容（盒子跟着内容走）→ 改字号
await globalThis.__text_at('10,12'); // 点画布决定文字落点（写进 MPST.textAt）
el('tinput').value = 'Moon';
await globalThis.__text_add();
const tl = layers().find((l) => l.kind === 'text');
const w0 = tl ? layer(tl.id).w : -1;
if (tl) {
  await globalThis.__text_set(tl.id, 'MoonPainter 很长的一行');
}
const w1 = tl ? layer(tl.id).w : -1;
if (tl) {
  await globalThis.__text_font(tl.id, '28');
}
check(
  '文字：点画布建层（报得出 text），改内容后**盒子跟着内容变**，改字号认账',
  !!tl && layer(tl.id).text === 'MoonPainter 很长的一行' && w1 > w0 && layer(tl.id).font_size === 28,
  tl ? `text=${layer(tl.id).text} w ${w0} → ${w1} font_size=${layer(tl.id).font_size}` : '没建出文字层',
);

// ⑩ 蒙版：加 → 反转 → 摘（三态都要能从报告面读出来）
// 靶子自己新建（根级、不转不翻）：蒙版坐标是**层局部**的，人侧对转过/翻过/
// 在组里的层会明确拒绝——拿别的块留下的层来测，测的就成了"那层恰好合不合格"。
exec('add-rect x=20 y=20 w=30 h=15 fill=#22CC88FF name=蒙版靶');
await globalThis.__refresh();
await flush();
const maskTarget = layers().find((l) => l.name === '蒙版靶');
await globalThis.__sel(maskTarget.id);
// 蒙版只盖这层的**左上四分之一**：盒（画布 20,20,15,15）换算到层局部是 (0,0,15,15)。
// 判据两头咬：①报告面的盒是**层局部**（x=0,y=0）；②盒内保留、盒外被裁
// —— 后半句是矩形层**快速路径**的端到端把手（它曾把局部盒当画布盒用，于是
// "覆盖恒为 1"的那块画到了别处；只有重建 wasm 才照得出来）。
await globalThis.__mask_ready('rect', '20,20,15,15');
await flush();
const mk = layer(maskTarget.id).mask;
const mkIn = exec('probe x=25 y=25').color;
const mkOutRaw = exec('probe x=45 y=25');
const mkOut = mkOutRaw.color;
await globalThis.__mask_invert(maskTarget.id);
const mk2 = layer(maskTarget.id).mask;
await globalThis.__mask_clear(maskTarget.id);
check(
  '蒙版：加得上（盒换算到层局部 + 盒内保留/盒外被裁）→ 反选认账（invert 翻面）→ 摘得掉',
  // ⚠️ 反选**不改 kind**：它在报告里是 `mask.invert: true`（实测；第一版我断言
  // "kind 变了"，红了之后现象指向"反选没生效"，其实是我的判据念错了名字）。
  !!mk && mk.kind === 'rect' && mk.w === 15 && mk.x === 0 && mk.y === 0 &&
    mkIn === '#22CC88FF' && mkOut === '#FFFFFFFF' && !!mk2 && mk2.invert === true &&
    mk.invert !== true && layer(maskTarget.id).mask === undefined,
  `加=${mk && mk.kind}:${mk && mk.w}(x=${mk && mk.x},y=${mk && mk.y}) 盒内=${mkIn} 盒外=${mkOut}(${JSON.stringify(mkOutRaw)}) 画布=${exec('stats').width}x${exec('stats').height} 反转=${mk2 && mk2.kind} 摘=${layer(maskTarget.id).mask === undefined}｜状态栏=${status()}`,
);

// ⑪ 调整层与滤镜：改算子/改数值（原地改，不重建）+ 一键滤镜真的建层
exec('add-adjust id=adj1 op=brightness value=0.1');
await globalThis.__adj_val('adj1', '0.3');
const a1 = layer('adj1').adjust || {};
await globalThis.__adj_op('adj1', 'blur');
const a2 = layer('adj1').adjust || {};
const nBefore = layers().length;
// `__af` 从 MPST.strength 读强度（`js_set_tool` 的默认值是 0.5）——上面已给 0.35
await globalThis.__af('brightness', '+');
const nAfter = layers().length;
// 色阶：换算子时人侧铺一套**中性值**（引擎拒绝"换成 levels 却一个参数都不给"
// 的换算子——那是一个什么都不干的层），随后五格里改一格
await globalThis.__adj_op('adj1', 'levels');
const a3 = layer('adj1').adjust || {};
await globalThis.__adj_key('adj1', 'gamma', '2');
const a4 = layer('adj1').adjust || {};
// 曲线：点表**整表替换** + 预览是引擎采样的 9 点（前端不自己插值）
await globalThis.__adj_op('adj1', 'curves');
const a5 = layer('adj1').adjust || {};
await globalThis.__adj_key('adj1', 'points', '0,0;0.5,0.75;1,1');
const a6 = layer('adj1').adjust || {};
check(
  '色阶/曲线：换算子铺中性值 → 改一格原地生效 → 曲线上整表替换（引擎回读为准）',
  a3.levels && a3.levels.gamma === 1 && a3.levels.in_lo === 0 && a3.levels.out_hi === 1 &&
    a4.levels && a4.levels.gamma === 2 && a4.levels.in_hi === 1 &&
    a5.points === '0,0;1,1' && a6.points === '0,0;0.5,0.75;1,1' &&
    Array.isArray(a6.curve_sample) && a6.curve_sample.length === 9 &&
    a6.curve_sample[4][1] === 0.75,
  `levels=${JSON.stringify(a3.levels)}→gamma ${a4.levels && a4.levels.gamma}｜points=${a5.points}→${a6.points}｜采样=${a6.curve_sample && a6.curve_sample.length} 中点=${a6.curve_sample && a6.curve_sample[4] && a6.curve_sample[4][1]}｜状态栏=${status()}`,
);
// ②B 滤镜：换算子时人侧**问引擎要中性值**（`adjust-spec`），再改一格原地生效；
// 面板要为参数面的每个键画一格（键名来自引擎报出来的 `params`，前端不抄表）
await globalThis.__adj_op('adj1', 'pixelate');
const a7 = layer('adj1').adjust || {};
await globalThis.__adj_key('adj1', 'size', '8');
const a8 = layer('adj1').adjust || {};
await globalThis.__sel('adj1');
const propsF = String(globalThis.document.getElementById('pprops').innerHTML || '');
check(
  '滤镜：换算子铺引擎给的**中性值**（pixelate ⇒ size=2）→ 改一格原地生效 + 面板画出这一格',
  a7.op === 'pixelate' && a7.params && a7.params.size === 2 &&
    a8.op === 'pixelate' && a8.params && a8.params.size === 8 &&
    propsF.includes('__adj_key("adj1","size"'),
  `op=${a7.op} params=${JSON.stringify(a7.params)}→${JSON.stringify(a8.params)}｜面板有格子=${propsF.includes('__adj_key("adj1","size"')}｜状态栏=${status()}`,
);
// 坏参数名在人侧入口就拒（键名是从 HTML 属性拼进命令行的，多一个空格就能塞进
// 第二个参数）——**但不抄引擎的键清单**：只卡形状，语义由引擎拒
await globalThis.__adj_key('adj1', 'si ze', '8');
check(
  '滤镜：不合法的参数名在人侧入口被拒（状态栏说清楚，不拼进命令行）',
  status().includes('不合法的调整参数名') && (layer('adj1').adjust || {}).op === 'pixelate',
  `状态栏=${status()}｜op=${(layer('adj1').adjust || {}).op}`,
);

// ⑪b 混合模式（人侧下拉）：改成 multiply → 引擎回读；**有面层才有这个控件**，
// 调整层没有面 ⇒ 面板画只读回显（`caps` 里没有 blend），DOM 里不该有下拉
const blendLayer = layers().find((l) => l.kind === 'rect') || layers()[0];
const capsBefore = layer(blendLayer.id).caps || [];
await globalThis.__blend(blendLayer.id, 'multiply');
const blendAfter = layer(blendLayer.id).blend;
await globalThis.__blend(blendLayer.id, 'normal');
const blendBack = layer(blendLayer.id).blend;
// 有面的层选中时**面板里得有这个下拉**；调整层（没有面、caps 里没 blend）
// 选中时**不该有**——正反两头都咬（只查"下拉能改"会漏掉"给不该有的层画控件"）
await globalThis.__sel(blendLayer.id);
const propsRect = String(globalThis.document.getElementById('pprops').innerHTML || '');
await globalThis.__sel('adj1');
const propsAdj = String(globalThis.document.getElementById('pprops').innerHTML || '');
check(
  '混合模式：人侧下拉改得动（引擎回读为准）；有面层有下拉、调整层只有只读回显',
  capsBefore.includes('blend') && blendAfter === 'multiply' && blendBack === 'normal' &&
    !(layer('adj1').caps || []).includes('blend') &&
    propsRect.includes("__blend(\"") && propsRect.includes("<select") &&
    !propsAdj.includes("__blend(\"") && propsAdj.includes('不参与合成模式'),
  `caps=${capsBefore.join(',')} → ${blendAfter} → ${blendBack}｜adjust caps=${(layer('adj1').caps || []).join(',')}｜rect 有下拉=${propsRect.includes('__blend(')} adjust 有下拉=${propsAdj.includes('__blend(')}`,
);
check(
  '调整层：value 改得动、op 改得动（原地改而不是删了重加）；一键滤镜真的建出层',
  a1.value === 0.3 && a2.op === 'blur' && nAfter === nBefore + 1 &&
    layers().some((l) => l.kind === 'adjust'),
  `value=${a1.value} op=${a2.op} 层数 ${nBefore} → ${nAfter}`,
);

// ⑪c 自由变换（PS 的 Ctrl+T）：一个手势 = **一条** `transform` = **一步历史**；
// 框能不能挪/能不能缩放由引擎 `caps` 决定（前端只按位画手柄），
// 数值收口（非数/夹紧）在人侧一处做
exec('add-rect id=tfr x=10 y=10 w=20 h=10');
await globalThis.__sel('tfr');
const tfFrame = globalThis.window.__MP_TF || null;
const tfEdit0 = exec('edits').count;
await globalThis.__tf_ready('30,25,40,20,15');
const tfGot = layer('tfr');
const tfEdit1 = exec('edits').count;
await globalThis.__undo();
const tfBack = layer('tfr');
// 夹紧：框退化成 0×0 时发的是 1×1（不是让引擎拒一条 w=0）
await globalThis.__tf_ready('5,5,0,0,0');
const tfMin = layer('tfr');
// 非数：状态栏说清且**不发命令**（edits 不动）
const tfEdit2 = exec('edits').count;
await globalThis.__tf_ready('abc');
const tfEdit3 = exec('edits').count;
// 没选中层时（先取消选中）不发命令
await globalThis.__sel('');
await globalThis.__tf_ready('1,1,2,2,0');
const tfEdit4 = exec('edits').count;
await globalThis.__tf_hint('');
const tfHint = status();
await globalThis.__sel('tfr');
check(
  '自由变换：一个手势 = 一条命令 = 一步历史（撤销一次回到原样）；框的能力位来自 caps',
  tfFrame && tfFrame.id === 'tfr' && tfFrame.move === true && tfFrame.resize === true &&
    tfEdit1 === tfEdit0 + 1 && tfGot.x === 30 && tfGot.y === 25 && tfGot.w === 40 &&
    tfGot.h === 20 && tfGot.rot === 15 &&
    tfBack.x === 10 && tfBack.y === 10 && tfBack.w === 20 && tfBack.h === 10 && tfBack.rot === 0 &&
    tfMin.w === 1 && tfMin.h === 1 &&
    tfEdit3 === tfEdit2 && tfEdit4 === tfEdit2 && tfHint.includes('自由变换'),
  `框=${tfFrame && JSON.stringify(tfFrame)}｜一步历史 ${tfEdit0}→${tfEdit1}｜落定 x${tfGot.x} y${tfGot.y} w${tfGot.w} h${tfGot.h} rot${tfGot.rot}｜撤销后 ${tfBack.x},${tfBack.y},${tfBack.w},${tfBack.h},rot${tfBack.rot}｜夹紧 ${tfMin.w}×${tfMin.h}｜坏输入 edits ${tfEdit2}→${tfEdit3}｜没选中 ${tfEdit4}｜状态栏=${tfHint}`,
);
// 调整层没有 move/resize 能力 ⇒ 框画出来也拖不动（能力位为假，前端据此不画手柄）
await globalThis.__sel('adj1');
const tfAdj = globalThis.window.__MP_TF || null;
check(
  '自由变换：调整层的位置/盒子不参与渲染 ⇒ 能力位为假（画出来也拖不动，不发空命令）',
  tfAdj && tfAdj.id === 'adj1' && tfAdj.move === false && tfAdj.resize === false,
  `调整层的框=${tfAdj && JSON.stringify(tfAdj)}`,
);
await globalThis.__sel('tfr');

// ⑪d 图层样式（fx，人侧面板）：四件套开关 → 参数原地改 → 摘掉；影**真的**
// 落在画布上（取一个层外、只有影能盖到的点，三态各取一次色）。
// 这里先开一张干净画布（后面 ⑫ 本来也会重开），免得靶子落在别的层上。
exec('new 60 40 uuid=ctfx');
exec('add-rect id=fxb x=10 y=10 w=30 h=20 fill=#3366FFFF');
await globalThis.__refresh();
await flush();
// 影往右下偏 12、不模糊 ⇒ 层右下那一条带子被影**整块**盖住（覆盖度恒 1），
// 于是"改颜色"能断言**精确值**，不是"看起来变了"
const FXP = { x: 46, y: 36 };
const fxPlain = exec(`probe x=${FXP.x} y=${FXP.y}`).color;
await globalThis.__sel('fxb');
await globalThis.__fx_sw('fxb', 'shadow', '1');
const fx1 = layer('fxb').fx;
await globalThis.__fx_key('fxb', 'shadow_dx', '12');
await globalThis.__fx_key('fxb', 'shadow_dy', '12');
await globalThis.__fx_key('fxb', 'shadow_blur', '0');
const fx2 = layer('fxb').fx;
const fxShadow = exec(`probe x=${FXP.x} y=${FXP.y}`).color;
await globalThis.__fx_key('fxb', 'shadow_color', '#FF0000FF');
const fx3 = layer('fxb').fx;
const fxRed = exec(`probe x=${FXP.x} y=${FXP.y}`).color;
// 面板：开着的那一件要给出参数框与"点一下关"的开关，另有「清除全部」
const propsFx = String(globalThis.document.getElementById('pprops').innerHTML || '');
if (!propsFx.includes('__fx_key')) {
  console.log('FXPROPS-FULL>>>' + propsFx.replace(/\s+/g, ' ') + '<<<');
}
await globalThis.__fx_clear('fxb');
const fx4 = layer('fxb').fx;
const fxCleared = exec(`probe x=${FXP.x} y=${FXP.y}`).color;
// 负控：调整层没有自己的像素 ⇒ 引擎的 caps 里没有 fx、面板一个样式控件都不画
exec('add-adjust id=adjx op=brightness value=0.2');
await globalThis.__sel('adjx');
const propsAdjFx = String(globalThis.document.getElementById('pprops').innerHTML || '');
check(
  '图层样式（fx）：人侧开关装得上 → 参数原地改 → 影真的落到画布上 → 摘得掉回到原样',
  fx1 === 'shadow(4,4,4,#00000080)' && fx2 === 'shadow(12,12,0,#00000080)' &&
    fx3 === 'shadow(12,12,0,#FF0000FF)' && fx4 === 'none' &&
    fxPlain === '#FFFFFFFF' && fxShadow !== fxPlain && fxRed === '#FF0000FF' &&
    fxCleared === fxPlain &&
    propsFx.includes('__fx_sw(\"fxb\",\"shadow\",\"0\")') &&
    propsFx.includes('__fx_key(\"fxb\",\"shadow_dx\",this.value)') &&
    propsFx.includes('__fx_clear(\"fxb\")') &&
    !(layer('adjx').caps || []).includes('fx') && !propsAdjFx.includes('__fx_sw'),
  `装=${fx1} 偏=${fx2} 色=${fx3} 摘=${fx4}｜点(${FXP.x},${FXP.y}) ${fxPlain} → 有影 ${fxShadow} → 改色 ${fxRed} → 摘后 ${fxCleared}｜rect 面板开关=${propsFx.includes('__fx_sw')} 参数框=${propsFx.includes('__fx_key')}｜adjust caps=${(layer('adjx').caps || []).join(',')} 面板开关=${propsAdjFx.includes('__fx_sw')}`,
);

// ⑫ 画笔：`__stroke` 落笔（人画的那条链），画面与文档都要变
const fpPaint0 = exec('fingerprint').fingerprint;
await globalThis.__stroke('draw', '10,10 14,12 18,16');
const fpPaint1 = exec('fingerprint').fingerprint;
check(
  '画笔落笔：文档指纹变了，且多出一个笔触层（人画画那条链）',
  fpPaint1 !== fpPaint0 && layers().some((l) => l.kind === 'raster'),
  '指纹 ' + String(fpPaint0).slice(0, 8) + ' → ' + String(fpPaint1).slice(0, 8),
);

// ⑫b 仿制图章（去污点）：人侧那条链 = 选 🩹 工具 → Alt 点一下定源 → 拖动涂抹。
// 判据要**两头咬**：源点与目标点的颜色本来不同（判别力自证），克隆之后目标点
// 必须变成**源点的颜色**——不是笔刷色、也不是"什么都没发生"。
el('cw').value = '120';
el('ch').value = '120';
await globalThis.__new('');
exec('add-rect x=10 y=10 w=40 h=40 fill=#22CC88FF');
globalThis.__tool('clone');
check(
  '🩹 工具：状态栏说清"Alt 定源再拖"，且画布光标切到十字',
  /仿制图章/.test(status()) && String(el('canvas-img').className || '').includes('tool-clone'),
  `status="${status()}" class="${el('canvas-img').className}"`,
);
const cloneSrc = exec('sample 30 30').color; // 源区（干净的绿块）
const cloneDst0 = exec('sample 90 80').color; // 目标点（原本是白纸）
check(
  '克隆前：源点与目标点颜色**本就不同**（不然下面那条断言是空的）',
  cloneSrc !== cloneDst0,
  `源 ${cloneSrc} vs 目标 ${cloneDst0}`,
);
await globalThis.__clone_src('30,30');
await globalThis.__stroke('clone', '80,80;100,80');
const cloneDst1 = exec('sample 90 80').color;
const cloneLayer = layers().filter((l) => l.kind === 'raster').slice(-1)[0];
const cloneQ = cloneLayer ? exec(`query-layer ${cloneLayer.id}`) : null;
check(
  '克隆真的落笔：目标点变成**源点的颜色**（不是笔刷色、也不是没反应）',
  cloneDst1 === cloneSrc && cloneDst1 !== cloneDst0,
  `目标 ${cloneDst0} → ${cloneDst1}；源 ${cloneSrc}`,
);
// 报告面：**读解析后的数值**（别拿字符串 `contains` 判——`exec` 回的是对象，
// 而且子串匹配会被 `clone_off:[-50.5,-50]` 这类值骗过）。
const cloneL = cloneQ && cloneQ.layer ? cloneQ.layer : {};
check(
  '克隆笔触记在文档里：报告面报出克隆笔数与**源偏移**（画布向量 −50,−50）',
  cloneL.clone_dabs > 0 && JSON.stringify(cloneL.clone_off) === '[-50,-50]',
  JSON.stringify({ clone_dabs: cloneL.clone_dabs, clone_off: cloneL.clone_off }),
);
// 拒控：没定源就画 ⇒ 人侧入口把**引擎原话**摆出来（不是静默不画）
await globalThis.__clone_src('');
el('sbar-text').textContent = '';
await globalThis.__stroke('clone', '20,100;40,100');
// 没定源时前端把 `src=` 原样发下去（**前端不判**这条前置条件——同一个判断
// 只许引擎那一处实现），引擎按"空值参数一律拒绝"回原话，入口把它摆到状态栏。
check(
  '拒控：没 Alt 定源就涂抹 ⇒ 状态栏报引擎原话（不是静默不画）',
  /clone/.test(status()) && /src=/.test(status()),
  status() || '(空)',
);

// ⑫b2 钢笔/路径（④ 人侧）：点=锚点、拖=控制柄（曲线）、点回首锚=闭合收口、
// 回车=落定为开放路径。判据落在**引擎里那一层真的是 path、控制柄真的落进容器、
// 画面真的变了**——不是"按钮点了不报错"。
{
  await globalThis.__tool('pen');
  await globalThis.__poly_cancel(); // 上一轮的工具切换可能留下未闭合的点
  const before = exec('list-layers').count;
  const findPath = () => (exec('list-layers').layers || []).filter((l) => l.kind === 'path');
  // 三个锚点：第二个点拖出控制柄（曲线那段就是它）
  await globalThis.__poly_click('20,20');
  globalThis.__MP_lastPolyPreview = '';
  await globalThis.__poly_click('60,20');
  await globalThis.__pen_handle('0,25'); // 拖动：给刚落的锚点拉控制柄（曲线）
  check(
    '钢笔：拖出控制柄后预览由**引擎采样**（采样点数远多于锚点数，预览与落定同一条采样规则）',
    String(globalThis.__MP_lastPolyPreview || '').split(';').filter((x) => x).length > 3,
    String(globalThis.__MP_lastPolyPreview || '(无预览)').slice(0, 90),
  );
  await globalThis.__poly_click('60,60');
  await globalThis.__poly_finish(); // 回车/双击 = 开放路径
  const after = exec('list-layers');
  const paths = findPath();
  check(
    '钢笔：回车落定建出一层，且引擎认它是 path（不是矩形/多边形）',
    after.count === before + 1 && paths.length === 1,
    `层数 ${before} → ${after.count}，path 层 ${JSON.stringify(paths.map((p) => p.id))}`,
  );
  const q = layer(paths[0].id);
  check(
    '钢笔：控制柄真的落进容器（handles 回读得到，且不是全 0）',
    Array.isArray(q.handles) && q.handles.some((h) => h[0] !== 0 || h[1] !== 0),
    JSON.stringify(q.handles || null),
  );
  check(
    '钢笔：开放路径 = 只描边（引擎报 closed=false：闭合与否由 fill 派生，命令面如实回报）',
    q.closed === false,
    `closed=${JSON.stringify(q.closed)}`,
  );
  // 闭合：点回第一个锚点 ⇒ 填色收口（同一个动作两条语义，判据分开咬）
  await globalThis.__poly_click('120,120');
  await globalThis.__poly_click('160,120');
  await globalThis.__poly_click('160,160');
  await globalThis.__poly_click('120,120'); // 点回首锚 = 闭合
  const closed = findPath().filter((l) => l.id !== paths[0].id);
  check(
    '钢笔：点回第一个锚点 = 闭合收口（多出一层，且它 kind 仍是 path）',
    closed.length === 1 && closed[0].kind === 'path',
    JSON.stringify(closed.map((l) => [l.id, l.kind])),
  );
  const closedQ = layer(closed[0].id);
  check(
    '钢笔：闭合那层报 closed=true（收口 = 有面，判据与开放路径同一条）',
    closedQ.closed === true,
    `closed=${JSON.stringify(closedQ.closed)}`,
  );
  await globalThis.__tool('rect');
}


// ⑫b3 布尔运算（④ Stage B，人侧）：面板四个按钮走的是引擎 `bool-op`。
// 判据落在**引擎里的层真的被结果替换、画面真的是那个集合**——不是"按钮点了不报错"。
// 这个块自己开一张新画布：坐标要能算准（并集的盒子、洞的位置都是具体数字），
// 而共享画布上别处的图层会让"这里应该是白纸"变成一句假话。
{
  el('cw').value = '300';
  el('ch').value = '300';
  await globalThis.__new('');
  const mk = (id, x, y, color) => {
    globalThis.__headless_exec(`add-rect id=${id} x=${x} y=${y} w=60 h=60 fill=${color}`);
    return id;
  };
  const col = (x, y) => exec(`probe x=${x} y=${y}`).color;
  const ids = () => layers().map((l) => l.id);
  const A = mk('ba', 20, 20, '#FF0000FF');
  const B = mk('bb', 60, 60, '#0000FFFF');
  // 人侧的动作序列：先点 B（它成为"上一个选中的层"），再点 A（当前层 = A）
  await globalThis.__sel(B);
  await globalThis.__sel(A);
  const before = ids();
  await globalThis.__bool_op('union', A, B);
  const after = ids();
  const fresh = after.filter((i) => !before.includes(i));
  check(
    '布尔：两个操作数被结果替换（a/b 两层消失，多出恰好一个新层）',
    !after.includes(A) && !after.includes(B) && fresh.length === 1,
    `${JSON.stringify(before)} → ${JSON.stringify(after)}`,
  );
  const res = fresh.length === 1 ? layer(fresh[0]) : {};
  check('布尔：结果层是 path（引擎认它是路径，不是矩形）', res.kind === 'path', JSON.stringify(res.kind));
  check(
    '布尔：结果盒子 = 两个形状的并集（并集是 20,20..120,120 ⇒ 100×100）',
    res.w === 100 && res.h === 100 && res.x === 20 && res.y === 20,
    `x=${res.x} y=${res.y} w=${res.w} h=${res.h}`,
  );
  check('布尔：并集里 A 独有的那角有墨（颜色继承 A）', col(30, 30) === '#FF0000FF', col(30, 30));
  check(
    '布尔：并集里 B 独有的那角也有墨（轮廓真的走过了两条边界）',
    col(110, 110) === '#FF0000FF',
    col(110, 110),
  );
  check('布尔：并集之外还是白纸', col(200, 200) === '#FFFFFFFF', col(200, 200));
  // 差集挖洞：**洞里真的没墨**（反选蒙版在干活；操作数已被替换，下面没有残留层）
  const C = mk('bc', 200, 20, '#FF0000FF');
  const D = mk('bd', 220, 40, '#0000FFFF');
  await globalThis.__sel(D);
  await globalThis.__sel(C);
  const before2 = ids();
  await globalThis.__bool_op('subtract', C, D);
  const after2 = ids();
  check(
    '布尔：差集同样替换操作数（b 层不留在洞里）',
    !after2.includes(C) && !after2.includes(D) && after2.length === before2.length - 1,
    `${JSON.stringify(before2)} → ${JSON.stringify(after2)}`,
  );
  check('布尔：差集挖出的洞里没有墨（反选蒙版）', col(250, 70) === '#FFFFFFFF', col(250, 70));
  check('布尔：差集的环上仍有墨', col(210, 70) === '#FF0000FF', col(210, 70));
  await globalThis.__sel('');
}

// ⑫c 步骤历史面板（③ 每步可见、可跳回）：面板 HTML 是**纯函数**算出来的，
// 这里既查"面板列出来的步骤与引擎的 history 一致"，也查"点一行真的跳回去"。
{
  // 面板判据要跑在**有多步**的画布上（此前那条链只留下 1 步，"跳回"就无从谈起）。
  // 这本身是一条自查：先把步骤做够，再断言行数与游标。
  exec('add-rect x=4 y=4 w=5 h=5 fill=#FFAA00FF');
  exec('add-rect x=12 y=4 w=5 h=5 fill=#00AAFFFF');
  exec('add-rect x=20 y=4 w=5 h=5 fill=#AA00FFFF');
  // ⚠️ 断言顺序有讲究：`exec`（`__headless_exec`）只跑引擎、**不刷界面**，
  // 而面板是"上次人侧交互"那一帧。所以先做完所有引擎侧准备，**再触发一次
  // 人侧动作**（`__goto` → `refresh_ui`）让面板对齐，然后才断言行数。
  // 不这么做，"行数 vs 步数"比的其实是两个不同时刻的事实——实测就是这么差了 2。
  const hBefore = exec('history');
  const rows = (h) => (h.steps || []);
  check(
    '步骤面板的前提：此刻确实有多步历史（单步时"跳回"这条断言是空的）',
    rows(hBefore).length >= 3,
    `步数 ${rows(hBefore).length}`,
  );
  await globalThis.__goto(String(hBefore.cursor)); // 人侧动作：面板随之对齐
  const html0 = el('hlist').innerHTML || '';
  check(
    '步骤面板：每一行对应引擎 history 里的一步（行数 = 步数 + 初始行）',
    (html0.match(/class='hstep/g) || []).length === rows(hBefore).length + 1,
    `行 ${(html0.match(/class='hstep/g) || []).length} vs 步 ${rows(hBefore).length}`,
  );
  check(
    '步骤面板：当前步高亮（.cur 恰好一个），未来步骤没有（此刻在末尾）',
    (html0.match(/hstep cur/g) || []).length === 1 && !/undone/.test(html0),
    html0.slice(0, 160),
  );
  // 当前步号（面板上说"哪一步"必须与引擎一致）
  const cur = hBefore.cursor;
  const target = Math.max(0, cur - 1);
  const fpBefore = exec('fingerprint').fingerprint;
  // 跳回上一步：指纹要变；面板 .cur 要跟着挪
  await globalThis.__goto(String(target));
  const hAfter = exec('history');
  const html1 = el('hlist').innerHTML || '';
  check(
    '步骤面板：点一行跳回去 ⇒ 引擎游标跟着走（面板与引擎同一条事实）',
    hAfter.cursor === target && hAfter.can_redo === true,
    `游标 ${cur} → ${hAfter.cursor}，can_redo=${hAfter.can_redo}`,
  );
  check(
    '步骤面板：跳回去后后面的步骤标成"未来"（.undone 与 .cur 各就各位）',
    /undone/.test(html1) && (html1.match(/hstep cur/g) || []).length === 1,
    html1.slice(0, 200),
  );
  check(
    '步骤面板：跳回真的改了画布状态（不是只挪了游标）',
    exec('fingerprint').fingerprint !== fpBefore,
    `${fpBefore.slice(0, 8)} → ${exec('fingerprint').fingerprint.slice(0, 8)}`,
  );
  // 点"未来"那一行 = 重做回去（面板上灰行**仍然可点**，这是 PS 的口径）。
  // 判据咬住"跳回再往前"这个来回，而不是"灰行存在"——后者任何重建都满足。
  const future = rows(hAfter).filter((st) => !st.done).map((st) => st.i);
  check(
    '步骤面板：跳回后确实还有"未来步骤"（不然下面那条断言是空的）',
    future.length > 0,
    `未来步骤 ${JSON.stringify(future)}`,
  );
  const back = future[future.length - 1];
  await globalThis.__goto(String(back));
  check(
    '步骤面板：点"未来"那行 = 重做回去（游标回到那一步，未来步骤变少）',
    exec('history').cursor === back && rows(exec('history')).filter((st) => !st.done).length === 0,
    `游标 ${exec('history').cursor}，期望 ${back}`,
  );
  el('sbar-text').textContent = '';
  await globalThis.__goto('9999');
  check(
    '拒控：面板点到不存在的步号 ⇒ 状态栏报引擎原话（不是静默不跳）',
    /第 9999 步还不存在/.test(status()),
    status() || '(空)',
  );
}

// ⑬ 画布：新建（顶栏尺寸 → 画布 + 白底）、改尺寸、以及**越界必须报原话**
el('cw').value = '44';
el('ch').value = '33';
await globalThis.__new('');
const nc = exec('census').canvas; // 画布尺寸从 `census` 读（没有 canvas-size 这条命令）
check(
  '「新建」按顶栏尺寸开画布并铺白底',
  JSON.stringify(nc).includes('44') && JSON.stringify(nc).includes('33') &&
    layers().some((l) => l.kind === 'rect'),
  JSON.stringify(nc).slice(0, 80),
);
el('cw').value = '99999';
el('sbar-text').textContent = '';
await globalThis.__set_canvas('');
check(
  '拒控：画布尺寸越界时状态栏报引擎原话（不是静默不改）',
  /非法|1\.\.30000|30000/.test(status()),
  status() || '(空)',
);
el('cw').value = '50';
el('ch').value = '40';
await globalThis.__set_canvas('');
check(
  '正控：合法尺寸改得动（50×40）',
  JSON.stringify(exec('census').canvas).includes('50'),
  JSON.stringify(exec('census').canvas).slice(0, 60),
);

// ⑭ 裁剪：准备 → 取消（不生效）→ 准备 → 应用（画布真的变小）
globalThis.__crop_ready('5,5,20,12');
await globalThis.__crop_cancel('');
el('ailog').children.length = 0;
globalThis.__crop_ready('5,5,20,12');
await globalThis.__crop_apply();
check(
  '裁剪：取消不生效；应用之后画布真的变成选区尺寸并写明',
  exec('census').canvas[0] === 20 && exec('census').canvas[1] === 12 && /裁剪/.test(logText('ailog')),
  JSON.stringify(exec('census').canvas) + '｜日志 ' + logText('ailog').slice(0, 40),
);

// ⑮ 纯 UI：缩放 / 重刷 / 统计 / 不透明度气泡 / AI 面板折叠
el('canvas-img').naturalWidth = 600;
globalThis.MPST.zoom = 1;
await globalThis.__zoom('2');
const zw = el('canvas-img').style.width;
await globalThis.__zoom('');
el('llist').innerHTML = '';
await globalThis.__refresh();
const statsBefore = logText('ailog').length;
await globalThis.__stats('');
await globalThis.__optip('', '150');
const aiClosed0 = el('ai-panel').classList.contains('closed');
await globalThis.__toggle_ai('');
const aiClosed1 = el('ai-panel').classList.contains('closed');
check(
  '缩放写出画布宽度；重刷重建图层列表；统计写日志；不透明度气泡 150→1.5；AI 面板折叠可切换',
  /px$/.test(zw || '') && (el('llist').innerHTML || '').length > 0 &&
    logText('ailog').length > statsBefore && el('opv').textContent === '1.5' &&
    aiClosed0 !== aiClosed1,
  `宽=${zw} 列表=${(el('llist').innerHTML || '').length} 字符 气泡=${el('opv').textContent} 折叠 ${aiClosed0}→${aiClosed1}`,
);

// ⚠️ 前面每条"点击"里的 `try/catch` 都**靠不住**：`js_reg0`/`js_reg1` 的包装层
// 把处理器的异常 `catch` 掉了（页面不会被一个坏处理器打断，这是对的），异常不会
// 冒到调用方。它们现在同时记进 `globalThis.__handler_errors` 并把原话写进状态栏与
// 日志——这条断言读的账才是"有没有处理器在页面背后炸掉"。
// **必须放在所有点击之后**：第一版把它紧跟在面板探针后面，于是后面那些点击
// （图层列表、保存、AI）里炸掉的处理器它一条都看不到。
const hErr = globalThis.__handler_errors || [];
check(
  '上面所有点击都没有处理器在背后抛异常（包装层会吞掉，所以读它记的账）',
  hErr.length === 0,
  hErr.map((e) => e.name + ': ' + e.msg).join('；') || '0 条',
);

// ⑰ 导入照片的两条入口：**拒绝路径必须说人话**（成功路径要真的 File/Image，
// 只有浏览器能给——所以这里验的是"没选文件/没拿到字节时它明说"）。
el('ailog').children.length = 0;
await globalThis.__file_sel();
const noFile = logText('ailog');
el('ailog').children.length = 0;
await globalThis.__drop('', 'x.png', '');
const noBytes = logText('ailog');
check(
  '导入照片的两条入口（选文件 / 拖进来）：没选文件、没拿到字节时都说清原因（不静默）',
  /没有选到文件|文件读取失败/.test(noFile) && /导入失败/.test(noBytes),
  `选文件="${noFile.trim().slice(0, 60)}" 拖入="${noBytes.trim().slice(0, 60)}"`,
);


// ⑱ 导入一张**正经照片**：不再被拉伸、画布跟着照片走。
// 驱动器能跑到这里已经很接近浏览器了：`__drop` 就是拖拽入口，直通同一条
// `do_import`（引擎 add-image → 读 asset_size → 算落点 → 必要时放大画布）。
// 只有"浏览器把 File 解成 PNG"那一步是壳给不了的（那一层由 TESTING.md 手工验）。
const PNG_300x100 = 'iVBORw0KGgoAAAANSUhEUgAAASwAAABkCAIAAACzY5qXAAAA50lEQVR42u3TAQkAAAjAMDWI/aMYyxgibBEOz+kO4E5JACYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBOCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE8JnC2rGAcw33RhRAAAAAElFTkSuQmCC';
const PNG_1200x300 = 'iVBORw0KGgoAAAANSUhEUgAABLAAAAEsCAIAAABc390HAAAF1ElEQVR42u3XMQEAMAjAsDEh6EQishDBSSKhXyOrHwAAAPd8CQAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAADAEAIAAGAIAQAAMIQAAAAYQgAAAAwhAAAAhhAAAABDCAAAgCEEAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAGEIJAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAABhCAAAADCEAAACGEAAAAEMIAACAIQQAAMAQAgAAYAgBAAAwhAAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAAAAQwgAAIAhBAAAwBACAABgCAEAADCEAAAAGEIAAAAMIQAAAIYQAACArQGSoQO2yT9YzgAAAABJRU5ErkJggg==';
exec('new 800 600 uuid=ct2');
await globalThis.__drop(PNG_300x100, 'photo.png', '');
const small = layers()[layers().length - 1];
const smallBox = { x: small.x, y: small.y, w: small.w, h: small.h };
check(
  '导入 300×100 的照片：**按原生尺寸落进来**（不拉伸），画布不动、照片居中',
  small.kind === 'image' && smallBox.w === 300 && smallBox.h === 100 &&
    smallBox.x === 250 && smallBox.y === 250,
  JSON.stringify(smallBox),
);
await globalThis.__drop(PNG_1200x300, 'wide.png', '');
const wide = layers()[layers().length - 1];
const canvas = exec('census').canvas;
check(
  '导入 1200×300 的照片：装不下就把画布放大到装得下（画布 1200×600），照片仍 1:1 居中',
  canvas[0] === 1200 && canvas[1] === 600 && wide.w === 1200 && wide.h === 300 && wide.y === 150,
  `画布=${canvas.join('x')} 层=${wide.w}x${wide.h}@${wide.x},${wide.y}`,
);

// ⑲ 「选区 → 只改这一块」这条 PS 核心动线的人侧走法：加调整层 → 它必须**被选中**
// → 拖 ▭ 蒙版必须落在**调整层**上（而不是把照片挖掉一块）。判据两头咬：调整层有蒙版，
// 且刚才那张照片层**没有**被动过。
{
  const before = new Set(layers().map((l) => l.id));
  globalThis.__sel(wide.id);
  await globalThis.__af('brightness', '+');
  await flush();
  const adj = layers().find((l) => !before.has(l.id));
  const propsSel = !!adj && String(el('pprops').innerHTML).includes(adj.id);
  await globalThis.__mask_ready('rect', '10,10,200,80');
  await flush();
  const adjMask = adj && layer(adj.id).mask;
  const photoMask = layer(wide.id).mask;
  check(
    '局部调整动线：加调整层后它被选中（属性面板切到它），拖 ▭ 蒙版落在**调整层**上、照片层不被动',
    !!adj && adj.kind === 'adjust' && propsSel && !!adjMask && adjMask.w === 200 && photoMask === undefined,
    `选中=${propsSel} 调整层mask=${adjMask && adjMask.w} 照片层mask=${photoMask}｜状态栏=${status()}`,
  );
}

// ⑳ 任意形状选区（套索 🪢）：逐点圈定 → 该层拿到 **kind=polygon** 的蒙版（不是矩形）。
// 判据两头咬：①`query-layer` 报 polygon 且盒 = 点列紧包围盒、顶点是盒内局部坐标；
// ②**盒内、三角形外**那块必须被裁掉——只判①的话"套索退化成矩形"照样绿。
{
  // `__cmd` 不收参数（它读控制台输入框），建层走 headless 执行 + 刷新界面
  exec('add-rect x=20 y=20 w=60 h=50 fill=#FF0000FF name=套索靶');
  await globalThis.__refresh();
  await flush();
  const target = layers().find((l) => l.name === '套索靶');
  globalThis.__sel(target.id);
  globalThis.__tool('lasso');
  await globalThis.__poly_click('20,20');
  await globalThis.__poly_click('80,20');
  await globalThis.__poly_click('50,70');
  await flush();
  const midHint = status();
  await globalThis.__poly_finish();
  await flush();
  const m = layer(target.id).mask || {};
  const nPts = (m.points || []).length;
  const inTri = exec('probe x=50 y=36').color;
  const inBoxOut = exec('probe x=76 y=66').color;
  check(
    // ⚠️ 盒是**层局部**坐标：这一层在画布 (20,20)，所以画布上拖的 (20,20)~(80,70)
    // 换算过来是局部 (0,0,60,50)。修前这里直接把画布坐标当局部 ⇒ 盒报 (20,20)
    // 而画面整体偏一层的位置（同一条断言当时是红的，现象指向"三角形跑到别处"）。
    '套索：逐点圈定 → 该层拿到 kind=polygon 蒙版（盒=紧包围盒**换算到层局部** 0,0,60,50 + 3 个盒内顶点）',
    m.kind === 'polygon' && m.x === 0 && m.y === 0 && m.w === 60 && m.h === 50 && nPts === 3,
    `${JSON.stringify(m)}｜点中途提示=${midHint}`,
  );
  check(
    '套索：形状内保留、**盒内形状外**被裁（退化成矩形就会红；层不在原点也算对）',
    inTri === '#FF0000FF' && inBoxOut === '#FFFFFFFF',
    `内=${inTri} 盒内外=${inBoxOut}｜状态栏=${status()}`,
  );
  // 负控：转过角度的层，人侧换算不了（局部盒不再是轴对齐矩形）⇒ 必须**说清并
  // 不加蒙版**，而不是猜一个位置。判据两头咬：状态栏说了原因、且蒙版没被改。
  await globalThis.__rotate(target.id, '30');
  await flush();
  const maskBefore = JSON.stringify(layer(target.id).mask);
  globalThis.__tool('lasso');
  await globalThis.__poly_click('20,20');
  await globalThis.__poly_click('80,20');
  await globalThis.__poly_click('50,70');
  await flush();
  await globalThis.__poly_finish();
  await flush();
  const refusal = status();
  await globalThis.__poly_cancel();
  check(
    '套索：转过的层明确拒绝（说清原因 + 蒙版逐字未动），不猜位置',
    refusal.includes('转过角度') && JSON.stringify(layer(target.id).mask) === maskBefore,
    `状态栏=${refusal}｜rot=${layer(target.id).rot}｜蒙版 ${maskBefore} → ${JSON.stringify(layer(target.id).mask)}`,
  );
}

// ⑯ 覆盖清单（机器对账用，格式由 `build_demo.sh#html-wiring` 解析）：
// driver 走不到的处理器必须在这儿**写明原因**，否则"没覆盖"会静默变成"覆盖了"。
/* coverage:begin
driven: __selfcheck __dbg_lint __dbg_edits __dbg_census __dbg_probe __dbg_help __dbg_tools __dbg_schema __dbg_preview __mvsl_set __mvsl_show __mvsl_impact __mvsl_assert __mvsl_clear __param_list __param_set __param_del __cmd __build_badge __save __export __run __sel __vis __front __back __setx __sety __setw __seth __move_delta __rotate __flip __op __del __undo __redo __rename __tag_add __tag_del __reparent __ungroup_sel __text_at __text_add __text_set __text_font __mask_ready __mask_invert __mask_clear __adj_op __adj_val __adj_key __blend __fx_sw __fx_key __fx_clear __tf_ready __tf_hint __af __stroke __new __set_canvas __crop_ready __crop_apply __crop_cancel __zoom __refresh __stats __optip __toggle_ai __tool __poly_click __poly_finish __poly_cancel __shape_ready __group_sel __pick_at __clone_src __goto __pen_handle __bool_op
browser-only: __drop=拒绝路径已被 driver 走过（没字节时明说）；成功路径要真的 File+Image 解码，壳里造一个等于把"读文件"假装测了; __file_sel=同上（driver 走的是"没选到文件"那条）; __mpd_sel=要真的 .mpd 文件字节，壳里没有 FileReader; __img_swap=换图必须先有一张真图进来
coverage:end */

const bad = results.filter((r) => !r.ok);
console.log(
  JSON.stringify({
    clickthrough: bad.length === 0,
    total: results.length,
    failed: bad.length,
    checks: results,
  }),
);
process.exit(bad.length === 0 ? 0 : 1);
