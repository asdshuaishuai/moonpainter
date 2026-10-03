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
    classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
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

// **与浏览器从同一状态出发**：浏览器在 main 里 bootstrap（装载示例场景）。
// 不先做这一步的话，第一个调用 `bootstrap()` 的处理器会把下面的测试文档整个
// 换成示例场景——那时四条断言会一起错，而现象看着像"pick 报错了层"。
globalThis.__headless_boot();
await new Promise((r) => setTimeout(r, 0));
check('初始化：示例场景装进来了（说明驱动器与浏览器同状态）', layers().length === 4, layers().length);

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
