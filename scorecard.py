#!/usr/bin/env python3
"""产品记分卡：把「做到了多少」从散落的散文里收进一张可对账的表。

photocraft 的可搬经验之一：**"接线计数"不是行为**。它的 README 曾按菜单接线
率自报 100%，而真实能力对等"远低于 50%"——数字好看而没人问"这个数在数什么"。
本仓库的对应风险是 README 那张能力表：它写得诚实，但**是散文**——加一条能力
没人回来改（实测：文本层/蒙版/调整层三项做完后，边界节还写着"不做"），
而"没做"的那半散在十几个"未做："里，谁也不数它有几个。

所以记分卡由**清单**（`scorecard/areas.toml`）生成，每个条目带：

  status  = done | partial | missing（only 这三档，不许"基本完成"）
  anchor  = `<文件>#<符号名>` 或 `<文件>#L<行号>` —— **唯一命中 1 处**才算数
  gate    = 可选：`<脚本>#<slug>`（步骤 slug，不许写步号——步号会腐烂）
  note    = 一句人话，说清"它现在到底能做什么 / 缺什么"

判据（`--check` 会让它成为门禁）：

  - 每条都要有 anchor，且 anchor 解析失败/命中 0 或 >1 处 → 红；
  - anchor 指向的那一行必须含 `must_contain`（给了的话）——**锚点会腐烂**，
    所以它得像别处的锚点一样会喊；
  - `gate` 必须在对应脚本的 `step-slugs:` 表里存在 → 绿；写不存在的 slug → 红；
  - **`missing` 的条目不许挂 gate**（没有任何门禁在守一个没做的东西）；
  - `status` 只有三档；`note` 不许空；
  - 汇总里的三个数（done/partial/missing）由清单现算，散文只许引用
    `docs/scorecard.md` 的数字（`verify.sh#catalog` 对账）。

`--check` 重新生成并与提交的 `docs/scorecard.md` **逐字节**比较：文档过期的
唯一修法是重新生成（跑一次不带参数），不许手改。

用法：
    python3 scorecard.py            # 重新生成 docs/scorecard.md
    python3 scorecard.py --check    # 门禁口径：生成 → 逐字节比对
"""
import io
import json
import os
import re
import subprocess
import sys
import tomllib

ROOT = os.path.dirname(os.path.abspath(__file__))
TOML = os.path.join(ROOT, 'scorecard/areas.toml')
OUT = os.path.join(ROOT, 'docs/scorecard.md')
STATUS = ('done', 'partial', 'missing')
STATUS_ZH = {'done': '已做', 'partial': '部分 / 有声明边界', 'missing': '未做'}


def fail(msg):
    print('FAIL: %s' % msg)
    return 1


def load():
    with open(TOML, 'rb') as f:
        return tomllib.load(f)


def slug_table(script):
    """从脚本头部注释里的 `step-slugs:` 行读 slug → 步号。"""
    path = os.path.join(ROOT, script)
    if not os.path.exists(path):
        return None
    text = io.open(path, encoding='utf-8').read()
    m = re.search(r'^#\s*step-slugs:\s*(.+)$', text, re.M)
    if not m:
        return None
    out = {}
    for part in m.group(1).split():
        if '=' in part:
            num, slug = part.split('=', 1)
            out[slug] = num
    return out


def resolve_anchor(anchor):
    """`path#symbol` / `path#L123` → (行号, 那一行文本)；失败回 (None, 原因)。"""
    if '#' not in anchor:
        return None, '锚点得写成 <文件>#<符号> 或 <文件>#L<行号>'
    rel, what = anchor.split('#', 1)
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        return None, '文件不存在：%s' % rel
    lines = io.open(path, encoding='utf-8').read().split('\n')
    if re.fullmatch(r'L\d+', what):
        n = int(what[1:])
        if n < 1 or n > len(lines):
            return None, '%s 只有 %d 行，L%d 越界' % (rel, len(lines), n)
        return n, lines[n - 1]
    # .mbt 用 `fn name(`；脚本（.py/.mjs/.js）用 `def name(` / `function name(`。
    # **锚点必须唯一命中**：命中 0 处 = 覆盖被拿掉，>1 处 = 锚点不知道自己在说谁。
    pat = (r'\bfn\s+' if rel.endswith('.mbt')
           else r'\b(?:async\s+)?(?:def|function)\s+')
    hits = [i + 1 for i, l in enumerate(lines)
            if re.search(pat + re.escape(what) + r'\s*[(<]', l)]
    if len(hits) == 0:
        return None, '%s 里找不到 `fn %s`' % (rel, what)
    if len(hits) > 1:
        return None, '%s 里 `fn %s` 命中 %d 处（锚点必须唯一）' % (rel, what, len(hits))
    return hits[0], lines[hits[0] - 1]


def key_effect_numbers():
    """「收了却没人读的键」现场量（审计脚本自己就是它的判据）。"""
    try:
        out = subprocess.run([sys.executable, 'key_effect_audit.py', '--json'],
                             cwd=ROOT, capture_output=True, text=True, timeout=600)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout.strip().split('\n')[-1])
    except Exception:
        return None


def measure():
    """记分卡里的数字一律现算/现读——**不许手写**（手写的数没人管）。"""
    nums = {}
    try:
        with open(os.path.join(ROOT, 'floors.toml'), 'rb') as f:
            nums.update(tomllib.load(f).get('floors', {}))
    except Exception:
        pass
    nums['dead_keys'] = (key_effect_numbers() or {}).get('dead')
    return nums


def check(areas, nums):
    errs = []
    gates = {'verify.sh': slug_table('verify.sh'),
             'build_demo.sh': slug_table('build_demo.sh')}
    for script, table in gates.items():
        if not table:
            errs.append('%s 里读不出 step-slugs 表' % script)
    ids = {}
    for area in areas.get('area', []):
        aname = area.get('id', '')
        if not aname:
            errs.append('有个 area 没写 id')
        if not area.get('title'):
            errs.append('%s 没写 title' % aname)
        items = area.get('item', [])
        if not items:
            errs.append('%s 一条 item 都没有' % aname)
        for it in items:
            iid = it.get('id', '')
            full = '%s/%s' % (aname, iid)
            if not iid:
                errs.append('%s 里有个 item 没写 id' % aname)
            if full in ids:
                errs.append('item id 重复：%s' % full)
            ids[full] = 1
            if not it.get('title'):
                errs.append('%s 没写 title' % full)
            st = it.get('status', '')
            if st not in STATUS:
                errs.append('%s 的 status=%r 不在 %s 里' % (full, st, '/'.join(STATUS)))
            if not (it.get('note') or '').strip():
                errs.append('%s 的 note 是空的（说清"现在能做什么/缺什么"）' % full)
            anchor = it.get('anchor', '')
            if not anchor:
                errs.append('%s 没写 anchor' % full)
            else:
                n, text = resolve_anchor(anchor)
                if n is None:
                    errs.append('%s 的 anchor 解析失败：%s' % (full, text))
                else:
                    want = it.get('must_contain')
                    if want and want not in text:
                        errs.append('%s 的 anchor 指到 %s:%d，但那一行里没有 %r'
                                    % (full, anchor.split('#')[0], n, want))
            g = it.get('gate')
            if g:
                if '#' not in g:
                    errs.append('%s 的 gate=%r 得写成 <脚本>#<slug>' % (full, g))
                else:
                    script, slug = g.split('#', 1)
                    table = gates.get(script)
                    if table is None:
                        errs.append('%s 的 gate 指向未知脚本 %s' % (full, script))
                    elif slug not in table:
                        errs.append('%s 的 gate=%s 不在 %s 的 step-slugs 表里'
                                    % (full, g, script))
            if st == 'missing' and g:
                errs.append('%s 是 missing 却挂着 gate=%s（没做的东西没有门禁在守）'
                            % (full, g))
    if nums.get('dead_keys') != 0:
        errs.append('「收了却没人读的键」= %r，目标 0（审计本身也会红）' % nums.get('dead_keys'))
    if errs:
        print('记分卡清单不合法（%d 条）：' % len(errs))
        for e in errs:
            print('  - ' + e)
        return 1
    return 0


def render(areas, nums):
    rows, totals = [], {k: 0 for k in STATUS}
    detail = []
    for area in areas.get('area', []):
        items = area.get('item', [])
        cnt = {k: sum(1 for it in items if it.get('status') == k) for k in STATUS}
        for k in STATUS:
            totals[k] += cnt[k]
        rows.append('| %s | %d | %d | %d | %d |'
                    % (area.get('title', area.get('id')), len(items),
                       cnt['done'], cnt['partial'], cnt['missing']))
        detail.append('\n### %s\n' % area.get('title', area.get('id')))
        if area.get('note'):
            detail.append('%s\n' % area['note'])
        detail.append('| 条目 | 状态 | 依据（锚点 / 门禁） | 说明 |')
        detail.append('| :-- | :-- | :-- | :-- |')
        for it in items:
            ev = '`%s`' % it['anchor']
            if it.get('gate'):
                ev += ' · `%s`' % it['gate']
            detail.append('| %s | %s | %s | %s |'
                          % (it['title'], STATUS_ZH[it['status']], ev,
                             (it.get('note') or '').replace('\n', ' ')))
        detail.append('')
    total = sum(totals.values())
    out = []
    out.append('# 产品记分卡（由 `scorecard.py` 从 `scorecard/areas.toml` 生成，别手改）')
    out.append('')
    out.append('> 口径：**每条目一个状态三档**（已做 / 部分+声明边界 / 未做）+ 一个'
               '**唯一命中**的源码锚点（锚点腐烂就红）+ 可选门禁 slug。'
               '「未做」不是待办埋伏，是**写下来的能力边界**——它的条数就是'
               'roadmap 的长度。生成命令：`python3 scorecard.py`；'
               '门禁：`python3 scorecard.py --check`（生成结果必须与提交的这份'
               '逐字节相同）。')
    out.append('')
    out.append('## 汇总')
    out.append('')
    out.append('| 域 | 条目 | 已做 | 部分 | 未做 |')
    out.append('| :-- | --: | --: | --: | --: |')
    out.extend(rows)
    out.append('| **合计** | **%d** | **%d** | **%d** | **%d** |'
               % (total, totals['done'], totals['partial'], totals['missing']))
    out.append('')
    out.append('## 现场量的数字（现算，不手写）')
    out.append('')
    out.append('| 指标 | 值 | 来源 |')
    out.append('| :-- | --: | :-- |')
    pairs = [
        ('engine_commands', '引擎命令面（字典条数）', 'floors.toml ← verify.sh#catalog'),
        ('tests_native', 'native 测试条数', 'floors.toml ← verify.sh#catalog'),
        ('tests_wasm', 'wasm-gc 测试条数', 'floors.toml ← verify.sh#catalog'),
        ('mutations', '变异条数', 'floors.toml ← verify.sh#catalog'),
        ('mutations_killed', '被抓住的变异', 'floors.toml ← verify.sh#catalog'),
        ('human_reachable', '人类可达命令', 'floors.toml ← ui_audit.py'),
        ('unreachable_human', '人类够不着的命令（目标 0）', 'floors.toml ← ui_audit.py'),
        ('ai_tools', 'AI 工具面条数', 'floors.toml ← build_demo.sh#doc-tools'),
        ('unreachable_ai', 'AI 刻意够不着的命令', 'floors.toml ← build_demo.sh#doc-tools'),
        ('key_effect_pairs', '（命令, 键）配对', 'floors.toml ← key_effect_audit.py'),
        ('key_effect_read', '有读取点的配对', 'floors.toml ← key_effect_audit.py'),
        ('dead_keys', '**收了却没人读的键（目标 0）**', 'key_effect_audit.py 现场量'),
        ('panic_lines', '对抗性参数 fuzz 行数', 'floors.toml ← panic_hunt.py'),
        ('selfcheck_items', '浏览器自检项', 'floors.toml ← build_demo.sh#selfcheck'),
        ('clickthrough_assertions', '点击贯通断言', 'floors.toml ← build_demo.sh#clickthrough'),
        ('clickable_handlers', '可点处理器', 'floors.toml ← build_demo.sh#clickthrough'),
    ]
    for key, label, src in pairs:
        val = nums.get(key)
        out.append('| %s | %s | %s |' % (label, '—' if val is None else val, src))
    out.append('')
    out.append('> **别把接线计数当能力**：AI 工具 60 条 / 人类可达 70 条说的是'
               '「有没有入口」，一个入口背后可能只是"回一个错误"；行为由'
               '`verify.sh` 与 `build_demo.sh` 的各步钉住，'
               '而"参数收了没人读"这类空壳由 `key_effect_audit.py` 现场数。')
    out.append('')
    out.append('## 分域明细')
    out.extend(detail)
    return '\n'.join(out).rstrip('\n') + '\n'


def main():
    areas = load()
    nums = measure()
    bad = check(areas, nums)
    items = [it for a in areas.get('area', []) for it in a.get('item', [])]
    try:
        import floors
        floors.check('scorecard_items', len(items))
        floors.check('scorecard_done', sum(1 for it in items if it.get('status') == 'done'))
    except Exception as e:
        print('FAIL: 单调地板检查没跑起来：%s' % e)
        return 1
    md = render(areas, nums)
    if '--check' in sys.argv:
        cur = io.open(OUT, encoding='utf-8').read() if os.path.exists(OUT) else ''
        if bad:
            print('FAIL: 清单不合法，记分卡不生成（先修清单）')
            return 1
        if cur != md:
            print('FAIL: docs/scorecard.md 与清单/现场数字不一致——'
                  '跑 `python3 scorecard.py` 重新生成（别手改）')
            import difflib
            for line in list(difflib.unified_diff(cur.split('\n'), md.split('\n'),
                                                  'committed', 'generated', lineterm=''))[:40]:
                print('  ' + line)
            return 1
        print('记分卡 OK（%d 个域 / %d 条：已做 %d、部分 %d、未做 %d；'
              '收了却没人读的键 %s）'
              % (len(areas.get('area', [])),
                 sum(len(a.get('item', [])) for a in areas.get('area', [])),
                 sum(1 for a in areas.get('area', []) for i in a.get('item', [])
                     if i.get('status') == 'done'),
                 sum(1 for a in areas.get('area', []) for i in a.get('item', [])
                     if i.get('status') == 'partial'),
                 sum(1 for a in areas.get('area', []) for i in a.get('item', [])
                     if i.get('status') == 'missing'),
                 nums.get('dead_keys')))
        return 0
    if bad:
        print('FAIL: 清单不合法，不写文档')
        return 1
    io.open(OUT, 'w', encoding='utf-8').write(md)
    print('记分卡已生成：%s（%d 字节）' % (os.path.relpath(OUT, ROOT), len(md.encode())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
