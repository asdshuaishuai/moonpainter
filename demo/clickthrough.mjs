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
function el(id) {
  if (!els.has(id)) {
    els.set(id, {
      id,
      value: '',
      textContent: '',
      innerHTML: '',
      src: '',
      className: '',
      style: {},
      dataset: {},
      classList: { toggle() {}, add() {}, remove() {}, contains: () => false },
      addEventListener() {},
      appendChild() {},
      setAttribute() {},
      querySelector: () => null,
      querySelectorAll: () => [],
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 1, height: 1 }),
    });
  }
  return els.get(id);
}
const doc = {
  getElementById: (id) => el(id),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener() {},
  createElement: () => el('_tmp'),
  createElementNS: () => el('_tmp'),
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
