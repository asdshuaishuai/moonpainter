#!/usr/bin/env python3
"""「收了却没人读的键」审计（photocraft 记分卡里那条 settings that do nothing）。

为什么要它：`param_audit.py` 管的是**名字**（字典承诺的 `key=` 解析器认不认），
`field_audit.py` 管的是**改得动吗**（`Layer` 的每个字段有没有命令能改）。两者都
不回答"这个键**真的被读了吗**"——一个键可以被认下、被写进容器、然后**整个引擎
没有任何读点**：画面不变、容器也不变，回包却是 ok。调用方分不出"改了没反应"和
"参数没生效"，而这类键正是"看起来很能干的空壳"。

判据（行为式，不看源码——读代码猜覆盖这件事本仓库栽过）：

  对每个（命令, 字典声明过的键）配对，在**同一个** CLI 进程里跑两遍同一场景
  （`new 40 40` + prep + 命令行），唯一区别是这个键取**基线值**还是**探针值**，
  然后比较四个可观测出口：

    1. 命令自己的回包 JSON（覆盖 uuid/max=/within= 这类只体现在回包里的键）
    2. `fingerprint` 回包（容器变没变）
    3. `list-layers` 回包（层列表变没变）
    4. `render` 的 sha256（画面变没变）

  - 四个出口**全都没变** ⇒ 这个键**收了却没人读**（要报，目标 0）。
  - 命令面**拒绝**了带键的行 ⇒ 分两种：键根本不被接受（字典写错了，`param_audit`
    的地盘）与值不合法（**探针写错了**，要改这里的表，不许改判据）。
  - 没有探针/基线跑不通 ⇒ 记进 `untested` / `baseline_fail` 并**逐条打印**：
    "测不出来"也是一条事实，不许静默算成通过。

固定语料、排序确定、单进程完成（铁律 7：门禁必须可复现；随机 fuzz 只会带来
"换个种子就绿"）。用法：

    python3 key_effect_audit.py            # 人看的报告（红了非零退出）
    python3 key_effect_audit.py --json     # 给 scorecard 读的汇总（一行 JSON）
"""
import base64
import json
import os
import re
import struct
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILT = os.path.join(ROOT, '_build/native/debug/build/cli/cli.exe')
CLI = [BUILT] if os.path.exists(BUILT) else ['moon', 'run', '--target', 'native', 'cli']
CANVAS = '40 40'
POLY = '0,0;20,0;20,20'
LINE = '0,0;20,20'


def png(r, g, b, w=2, h=2):
    """纯色 PNG（自己拼字节：不引第三方库）。"""
    raw = b''.join(b'\x00' + bytes([r, g, b] * w) for _ in range(h))

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))


def b64(raw):
    return base64.b64encode(raw).decode('ascii')


BLUE, RED = b64(png(0, 0, 255)), b64(png(255, 0, 0))  # 已是 base64 文本
SEL = {'basis': 'base',
       'expr': {'t': 'geo', 'shape': 'rect',
                'w': {'x': 0, 'y': 0, 'w': 20, 'h': 20, 'feather': 0}}}
SEL_B64 = b64(json.dumps(SEL, separators=(',', ':'), sort_keys=True).encode())
# 选"红"的选择子：census 的 `components=` 只有在**连通域不止一个**时才看得见
# 效果（全画布 geo 选择子下只有 1 个连通域，`components=1` 与 `components=2`
# 回包逐字节相同——第一版就是这么把 census components 误报成死键的）。
SEL_RED = {'basis': 'base',
           'expr': {'t': 'color',
                    'w': {'h': 29, 'hw': 40, 's': 0.25, 'sh': 0.3,
                          'l': 0.63, 'lh': 0.3, 'feather': 0.1}}}
SEL_RED_B64 = b64(json.dumps(SEL_RED, separators=(',', ':'), sort_keys=True).encode())
PROG = {'version': 1, 'ops': [{'id': 'e1', 'kind': 'recolor',
                              'sel': SEL, 'amount': 1, 'hue_deg': 120,
                              'temp_kelvin': 0, 'relight_gain': 1,
                              'refine': [], 'note': '', 'evidence': None}],
        'guards': []}
PROG_B64 = b64(json.dumps(PROG, separators=(',', ':')).encode())

# ── 每个命令的场景骨架 ───────────────────────────────────────────────────
# pos：位置参数；skel：**必需键**的基线取值（探针命中 skel 里的键时替换它，
# 否则追加）；prep：跑命令行之前要先做的准备；skel_over/prep_over/pos_over：
# 某个键需要另一套上下文时用（例：`points=` 只在 polygon/path 上有意义）。
SPEC = {
    'new': dict(pos=CANVAS, skel={}),
    'add-rect': dict(pos='', skel={}),
    'add-ellipse': dict(pos='', skel={}),
    'add-polygon': dict(pos='', skel={'points': POLY}),
    'add-line': dict(pos='', skel={'points': LINE}),
    'add-path': dict(pos='', skel={'points': POLY}),
    'path-preview': dict(pos='', skel={'points': POLY}),
    'add-text': dict(pos='', skel={'text': '"Base"'}),
    'add-image': dict(pos='', skel={'b64': BLUE}),
    # ⚠️ prep 里放一张**渐变**椭圆（不是纯色矩形）：调整层作用在它下面，
    # 纯色底图会让 pixelate/posterize/contrast 这类算子的"改了参数"在画面上
    # 看不出来，探针就只剩指纹在动——"收了却没人读"这条判据会被削弱一半。
    'add-adjust': dict(pos='', skel={'op': 'blur', 'value': '0.2'},
                       prep=['add-ellipse x=4 y=4 w=32 h=32 lgrad=#FF0000FF,#0000FFFF,0,0,1,1'],
                       skel_over={'in_lo': {'op': 'levels', 'in_lo': '0.1'},
                                  'in_hi': {'op': 'levels', 'in_hi': '0.9'},
                                  'gamma': {'op': 'levels', 'gamma': '1.0'},
                                  'out_lo': {'op': 'levels', 'out_lo': '0.0'},
                                  'out_hi': {'op': 'levels', 'out_hi': '1.0'},
                                  'points': {'op': 'curves', 'points': '0,0;1,1'},
                                  'angle': {'op': 'motion-blur', 'angle': '10', 'radius': '8'},
                                  'radius': {'op': 'motion-blur', 'angle': '10', 'radius': '8'},
                                  'center_x': {'op': 'radial-blur', 'center_x': '0.4', 'center_y': '0.4', 'radius': '16'},
                                  'center_y': {'op': 'radial-blur', 'center_x': '0.4', 'center_y': '0.4', 'radius': '16'},
                                  'radius': {'op': 'radial-blur', 'center_x': '0.4', 'center_y': '0.4', 'radius': '16'},
                                  'amount': {'op': 'noise', 'amount': '0.2', 'mono': '0'},
                                  'mono': {'op': 'noise', 'amount': '0.2', 'mono': '0'},
                                  'size': {'op': 'pixelate', 'size': '4'},
                                  'levels': {'op': 'posterize', 'levels': '4'},
                                  'channel': {'op': 'threshold', 'channel': '3', 'level': '0.4'},
                                  'level': {'op': 'threshold', 'channel': '3', 'level': '0.4'},
                                  'hue': {'op': 'hue-sat', 'hue': '40', 'light': '0.2', 'sat': '0.4'},
                                  'light': {'op': 'hue-sat', 'hue': '40', 'light': '0.2', 'sat': '0.4'},
                                  'sat': {'op': 'hue-sat', 'hue': '40', 'light': '0.2', 'sat': '0.4'},
                                  'cb': {'op': 'color-balance', 'cb': '0.2', 'cg': '0.2', 'cr': '0.2'},
                                  'cg': {'op': 'color-balance', 'cb': '0.2', 'cg': '0.2', 'cr': '0.2'},
                                  'cr': {'op': 'color-balance', 'cb': '0.2', 'cg': '0.2', 'cr': '0.2'},}),
    'add-paint': dict(pos='', skel={}),
    'add-mask': dict(pos='l1', skel={'kind': 'rect', 'x': '0', 'y': '0', 'w': '10', 'h': '10'},
                     prep=['add-rect w=20 h=20'],
                     skel_over={'points': {'kind': 'polygon', 'x': '0', 'y': '0',
                                           'w': '20', 'h': '20', 'points': POLY}}),
    'set-image': dict(pos='l1', skel={'b64': BLUE},
                      prep=['add-image b64=' + BLUE + ' w=20 h=20']),
    'set-style': dict(pos='l1', skel={'visible': 'true'},
                      prep=['add-rect w=20 h=20'],
                      prep_over={'points': ['add-path points=' + POLY + ' fill=#FF0000FF'],
                                 'handles': ['add-path points=' + POLY + ' fill=#FF0000FF']}),
    'transform': dict(pos='l1', skel={'rot': '0'}, prep=['add-rect w=20 h=20']),
    'set-text': dict(pos='l1 "Base"', skel={}, prep=['add-text text="Base"']),
    'set-adjust': dict(pos='l2', skel={'op': 'blur', 'value': '0.2'},
                       prep=['add-ellipse x=4 y=4 w=32 h=32 lgrad=#FF0000FF,#0000FFFF,0,0,1,1', 'add-adjust op=blur value=0.2'],
                       skel_over={'in_lo': {'op': 'levels', 'in_lo': '0.1'},
                                  'in_hi': {'op': 'levels', 'in_hi': '0.9'},
                                  'gamma': {'op': 'levels', 'gamma': '1.0'},
                                  'out_lo': {'op': 'levels', 'out_lo': '0.0'},
                                  'out_hi': {'op': 'levels', 'out_hi': '1.0'},
                                  'points': {'op': 'curves', 'points': '0,0;1,1'},
                                  'angle': {'op': 'motion-blur', 'angle': '10', 'radius': '8'},
                                  'radius': {'op': 'motion-blur', 'angle': '10', 'radius': '8'},
                                  'center_x': {'op': 'radial-blur', 'center_x': '0.4', 'center_y': '0.4', 'radius': '16'},
                                  'center_y': {'op': 'radial-blur', 'center_x': '0.4', 'center_y': '0.4', 'radius': '16'},
                                  'radius': {'op': 'radial-blur', 'center_x': '0.4', 'center_y': '0.4', 'radius': '16'},
                                  'amount': {'op': 'noise', 'amount': '0.2', 'mono': '0'},
                                  'mono': {'op': 'noise', 'amount': '0.2', 'mono': '0'},
                                  'size': {'op': 'pixelate', 'size': '4'},
                                  'levels': {'op': 'posterize', 'levels': '4'},
                                  'channel': {'op': 'threshold', 'channel': '3', 'level': '0.4'},
                                  'level': {'op': 'threshold', 'channel': '3', 'level': '0.4'},
                                  'hue': {'op': 'hue-sat', 'hue': '40', 'light': '0.2', 'sat': '0.4'},
                                  'light': {'op': 'hue-sat', 'hue': '40', 'light': '0.2', 'sat': '0.4'},
                                  'sat': {'op': 'hue-sat', 'hue': '40', 'light': '0.2', 'sat': '0.4'},
                                  'cb': {'op': 'color-balance', 'cb': '0.2', 'cg': '0.2', 'cr': '0.2'},
                                  'cg': {'op': 'color-balance', 'cb': '0.2', 'cg': '0.2', 'cr': '0.2'},
                                  'cr': {'op': 'color-balance', 'cb': '0.2', 'cg': '0.2', 'cr': '0.2'},}),
    # 图层样式（fx）：**四件全开**当骨架，于是每一个参数键的探针都真的改画面
    # （只开一件的话，另外三件的参数改了只动指纹不动像素——"收了却没人读"
    # 这条判据会漏掉一半）。
    # `clear` 得单独给一套上下文：`clear=1` 与别的键**不能同时给**（摘掉 vs 改），
    # 所以它的基线是 `clear=0`（合法且什么都不摘），而 prep 里先把样式装上。
    'set-fx': dict(pos='l1',
                   skel={'shadow': 'true', 'shadow_dx': '6',
                         'outline': 'true', 'glow': 'true', 'inner': 'true'},
                   prep=['add-rect w=20 h=20'],
                   prep_over={'clear': ['add-rect w=20 h=20', 'set-fx l1 shadow=true']},
                   skel_over={'clear': {'clear': '0'}}),
    'set-mask': dict(pos='l1', skel={'x': '0', 'y': '0', 'w': '10', 'h': '10'},
                     prep=['add-rect w=20 h=20',
                           'add-mask l1 kind=rect x=0 y=0 w=10 h=10'],
                     skel_over={'points': {'x': '0', 'y': '0', 'w': '20', 'h': '20',
                                           'kind': 'polygon', 'points': POLY}}),
    'brush': dict(pos='', skel={'layer': 'l1', 'pts': '0,0;20,20', 'r': '3'},
                  prep=['add-paint', 'add-paint']),
    'erase': dict(pos='', skel={'layer': 'l1', 'pts': '5,5;15,15', 'r': '3'},
                  prep=['add-paint', 'add-paint', 'brush layer=l1 pts=0,0;20,20 r=5']),
    'clone': dict(pos='', skel={'layer': 'l1', 'pts': '5,5;15,15', 'r': '3', 'src': '0,0'},
                  prep=['add-paint', 'add-paint', 'brush layer=l1 pts=0,0;20,20 r=5']),
    'bool-op': dict(pos='', skel={'op': 'union', 'a': 'l1', 'b': 'l2'},
                    prep=['add-rect w=10 h=10',
                          'add-ellipse x=10 y=10 w=10 h=10',
                          'add-rect x=20 y=20 w=10 h=10']),
    'probe': dict(pos='', skel={'x': '5', 'y': '5'}),
    'render': dict(pos='', skel={}),
    'census': dict(pos='', skel={'within': SEL_RED_B64},
                   prep=['add-rect x=2 y=2 w=8 h=8 fill=#FF0000FF',
                         'add-rect x=22 y=22 w=8 h=8 fill=#FF0000FF']),
    'select-preview': dict(pos=SEL_B64, skel={}),
    'mvsl-impact': dict(pos='', skel={}, prep=['mvsl-set ' + PROG_B64]),
}

# ── 探针：非默认、合法、且"能看出来" ──────────────────────────────────────
PROBE = {
    'uuid': 'probeuuid',
    'x': '7', 'y': '7', 'w': '24', 'h': '18',
    'id': 'probeid', 'name': '"Probe Name"',
    'fill': '#123456FF', 'lgrad': '#FF0000FF,#0000FFFF,0,0,1,1',
    'stroke': '#00FF00FF', 'stroke_w': '3',
    'opacity': '0.5', 'blend': 'multiply', 'radius': '4', 'rot': '30',
    'visible': 'false', 'tag': 'probe-tag',
    'points': POLY, 'handles': '2,2;2,2;2,2;2,2;2,2;2,2', 'closed': 'true',
    'op': 'contrast', 'value': '0.5', 'a': 'l2', 'b': 'l1',
    'text': '"Probe"', 'font_size': '24',
    'kind': 'ellipse', 'feather': '3', 'roughen': '2', 'invert': 'true',
    'layer': 'l2', 'pts': '2,2;18,18', 'r': '5', 'color': '#FF0000FF', 'src': '8,8',
    'overlay': '1', 'within': SEL_B64, 'components': '1', 'max': '8',
    'in_lo': '0.9', 'in_hi': '0.2', 'gamma': '2.0', 'out_lo': '0.3', 'out_hi': '0.7',
    # ②B 滤镜参数（16 个键；`radius` 复用上面那个——调整层上它是拖影/缩放半径，
    # 骨架里给的是 8，与这里的 4 不同，仍然是"两遍不一样"）
    'angle': '90', 'center_x': '0.2', 'center_y': '0.2', 'amount': '0.6',
    'mono': '1', 'size': '10', 'levels': '10', 'channel': '0', 'level': '0.8',
    'hue': '120', 'sat': '-0.8', 'light': '-0.4',
    'cr': '-0.4', 'cg': '-0.4', 'cb': '-0.4',
    'b64': RED,
    # 图层样式（fx，`set-fx`）：每个参数键都给一个"四件全开"骨架下**真的改像素**
    # 的探针（-9 与 9 之类是为了让偏移/宽度在 20×20 的层上看得见）。
    'clear': '1',
    'shadow': 'false',
    'shadow_dx': '9',
    'shadow_dy': '-9',
    'shadow_blur': '0',
    'shadow_color': '#FF0000FF',
    'outline': 'false',
    'outline_w': '9',
    'outline_color': '#00FF00FF',
    'glow': 'false',
    'glow_radius': '14',
    'glow_color': '#0000FFFF',
    'inner': 'false',
    'inner_dx': '-9',
    'inner_dy': '-9',
    'inner_blur': '0',
    'inner_color': '#FFFFFF80',
}
# 同一个键在不同命令上需要不同探针（形状不同、上下文不同）
PROBE_OVERRIDE = {
    ('add-line', 'points'): '1,1;19,19',
    ('add-polygon', 'points'): '1,1;19,1;19,19',
    ('add-path', 'points'): '1,1;19,1;19,19',
    ('path-preview', 'points'): '1,1;19,1;19,19',
    ('set-style', 'points'): '1,1;19,1;19,19',
    ('add-mask', 'points'): '1,1;9,1;9,9',
    ('set-mask', 'points'): '1,1;9,1;9,9',
    ('add-adjust', 'op'): 'contrast',
    ('set-adjust', 'op'): 'contrast',
    ('bool-op', 'a'): 'l3',
    ('bool-op', 'b'): 'l3',
    ('bool-op', 'op'): 'subtract',
    ('add-adjust', 'points'): '0,0;0.5,0.6;1,1',
    ('set-adjust', 'points'): '0,0;0.5,0.6;1,1',
    ('census', 'within'): SEL_B64,
}


def key_names(desc):
    """描述里声明的**参数键**（字典是 LLM 唯一的说明书）。

    不能整段抓 `key=`：说明文字里也会出现形如 `brightness=[-1..1]` 的东西
    （那是 `op=` 的取值清单，不是键），第一版把它们当成了 28 个"没有探针"的键。
    口径 = 用法行（第一个全角冒号之前）里的 `key=` ∪ 任意 `[...]` 里的 `key=`
    （可选键写成 `[id=][name=]`，出现在冒号之后）。
    """
    usage = desc.split('：', 1)[0]
    cand = re.findall(r'([a-z_][a-z0-9_]*)\s*=', usage)
    for seg in re.findall(r'\[([^\]]*)\]', desc):
        cand += re.findall(r'([a-z_][a-z0-9_]*)\s*=', seg)
    seen, out = set(), []
    for k in cand:
        if k not in seen:
            seen.add(k)
            out.append(k)
    return out


def kv(pairs):
    return ' '.join('%s=%s' % (k, v) for k, v in pairs.items())


def line_of(cmd, pos, skel, key=None, value=None):
    pairs = dict(skel)
    if key is not None:
        pairs[key] = value
    parts = [cmd]
    if pos:
        parts.append(pos)
    if pairs:
        parts.append(kv(pairs))
    return ' '.join(parts)


def load_tools():
    out = subprocess.run(CLI, input='list-tools\n', capture_output=True, text=True)
    lines = [l for l in out.stdout.split('\n') if l.strip()]
    if len(lines) < 2:
        print('FAIL: CLI 没有回 list-tools（stderr 尾部：%s）' % out.stderr[-300:])
        sys.exit(1)
    return json.loads(lines[-1])['tools']


def run_batch(lines):
    out = subprocess.run(CLI, input='\n'.join(lines) + '\n',
                         capture_output=True, text=True)
    if out.returncode != 0:
        print('FAIL: CLI 退出码 %s（stderr 尾部：%s）' % (out.returncode, out.stderr[-400:]))
        sys.exit(1)
    replies = out.stdout.split('\n')[1:]
    if len(replies) < len(lines):
        print('FAIL: 只回了 %d 行（给了 %d 行）——静默回包和崩溃一样是 bug'
              % (len(replies), len(lines)))
        sys.exit(1)
    return replies[:len(lines)]


def main():
    tools = {t['name']: t for t in load_tools()}
    pairs = []
    for cmd in sorted(SPEC):
        if cmd not in tools:
            continue
        for k in sorted(key_names(tools[cmd]['desc'])):
            pairs.append((cmd, k))
    pairs = sorted(set(pairs))

    # 一个进程跑完：每对两遍（基线/探针），中间用 `new` 复位（确定性）。
    plan, index = [], {}
    for cmd, k in pairs:
        spec = SPEC[cmd]
        # skel_over 是**整体替换**而不是合并：默认骨架里的 `value=0.2` 跟
        # `op=levels`/`op=curves` 打架（后者不吃 value=，入口会拒）。
        skel = dict(spec.get('skel_over', {}).get(k, spec.get('skel', {})))
        prep = spec.get('prep_over', {}).get(k, spec.get('prep', []))
        pos = spec.get('pos_over', {}).get(k, spec.get('pos', ''))
        probe = PROBE_OVERRIDE.get((cmd, k), PROBE.get(k))
        if probe is None:
            index[(cmd, k)] = ('no_probe', None, None)
            continue
        base_val = skel.get(k)
        if base_val is not None and base_val == probe:
            index[(cmd, k)] = ('probe_eq_base', None, None)
            continue
        a = line_of(cmd, pos, skel)
        v = line_of(cmd, pos, skel, k, probe)
        block = ['new ' + CANVAS] + prep + [None] + ['fingerprint', 'list-layers', 'render']
        base_plan = [x for x in block]
        var_plan = [x for x in block]
        base_plan[base_plan.index(None)] = a
        var_plan[var_plan.index(None)] = v
        index[(cmd, k)] = ('run', len(plan), len(plan) + len(base_plan))
        plan += base_plan + var_plan

    replies = run_batch(['session-open full_image'] + plan)
    OFF = 1        # replies[0] 是 session-open 的回包，plan 从 replies[1] 起

    dead, rejected, untested, base_fail, ok = [], [], [], [], []
    for (cmd, k) in pairs:
        state = index.get((cmd, k))
        if state[0] == 'no_probe':
            untested.append('%s %s（没有探针）' % (cmd, k))
            continue
        if state[0] == 'probe_eq_base':
            untested.append('%s %s（探针值 == 基线值：这是审计自己的 bug）' % (cmd, k))
            continue
        _, i, j = state
        block = len(plan[i:j])
        a_rep = replies[OFF + j - 4]
        v_rep = replies[OFF + j + block - 4]
        a_obs = [a_rep] + replies[OFF + j - 3:OFF + j]
        v_obs = [v_rep] + replies[OFF + j + block - 3:OFF + j + block]
        try:
            ja, jv = json.loads(a_rep), json.loads(v_rep)
        except Exception:
            base_fail.append('%s %s（回包不是 JSON）' % (cmd, k))
            continue
        if not ja.get('ok'):
            base_fail.append('%s %s（基线失败：%s）' % (cmd, k, (ja.get('error') or '')[:70]))
            continue
        if not jv.get('ok'):
            err = (jv.get('error') or '')[:90]
            if re.search(r'不认识的?参数|未知参数|认不出|不支持的键', err):
                rejected.append('%s %s（键不被接受：%s）' % (cmd, k, err))
            else:
                rejected.append('%s %s（值被拒：%s）' % (cmd, k, err))
            continue
        def sha(obs):
            try:
                return json.loads(obs[3]).get('sha256')
            except Exception:
                return None
        if a_obs == v_obs:
            dead.append('%s %s（四个出口全都没变）' % (cmd, k))
        else:
            ok.append('%s %s' % (cmd, k))

    summary = {
        'pairs': len(pairs),
        'read': len(ok),
        'dead': len(dead),
        'rejected': len(rejected),
        'untested': len(untested),
        'baseline_fail': len(base_fail),
    }
    try:
        import floors
        floors.check('key_effect_pairs', len(pairs))
        floors.check('key_effect_read', len(ok))
    except Exception as e:                      # 地板文件缺失也别静默通过
        print('FAIL: 单调地板检查没跑起来：%s' % e)
        return 1
    if '--json' in sys.argv:
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0 if not (dead or untested or base_fail) else 1

    print('审计 %d 个（命令, 键）配对：有读取点 %d，死键 %d，被拒 %d，未测 %d，基线失败 %d'
          % (len(pairs), summary['read'], summary['dead'], summary['rejected'],
             summary['untested'], summary['baseline_fail']))
    for label, items in (('收了却没人读（要修）', dead), ('被命令面拒（要么探针错、要么字典错）', rejected),
                         ('测不出来', untested), ('基线跑不通', base_fail)):
        if items:
            print('%s：%d 条' % (label, len(items)))
            for x in items:
                print('  -', x)
    bad = bool(dead or untested or base_fail)
    if bad:
        print('FAIL: 死键/未测/基线失败都必须清零（"测不出来"不等于"通过"）')
        return 1
    print('收了却没人读的键：0 个（目标口径，photocraft 的 settings that do nothing）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
