#!/usr/bin/env python3
"""对抗性参数 fuzz：拿**每一条**引擎命令 × 一张敌意参数表轰一遍，断言"只回错、不崩"。

为什么要它（它的前身差在哪）：
  `verify.sh#catalog` 只用**裸命令名**逐个戳，`verify.sh#arg-lower-bound` 只是
  **静态**扫"读 tokens[N] 之前卡住 N 没有"——两条都照不到"参数形状对、内容恶意"
  这一大片。实测过的现场是 `set-text l1`：它**越界读了 tokens[2]**，于是 CLI 进程
  当场 abort（不是回一句用法错，而是整条进程没了）。命令面越铺越宽之后，
  "某个分支在某个奇怪的参数下把进程干掉"是必然会出现的 bug，而它只在
  真实用户的输入下暴露。

判据（两头都咬）：
  - 正控（平时必须绿）：把 corpus 一次性喂给**一个** CLI 进程，要求
    ① 退出码 0 ② 每行输入都有**恰好一行** JSON 回包（banner 之外 1:1）
    ③ 每一条回包都是合法 JSON ④ stderr 里没有 panic/abort 一类的字眼。
    "没回包"与"回包不是 JSON"都算失败——**静默**和崩溃一样是 bug。
  - 反控（注入后必须红）：把某个命令的参数下界写小（例如照当年 `set-text` 的
    写法读 tokens[2] 而不先卡长度），本步必须非零退出并**指名道姓**报出是哪一行
    把它干掉的（见 PLAN 的注入记录）。

为什么批量跑 + 失败才二分：
  逐行起进程才对得住"隔离"，但 70 条命令 × 上百行 = 上千次启动，门禁会慢到没人跑。
  崩溃是确定性的，所以平时只起**一个**进程（秒级）；一旦红，再按前缀二分定位
  （log2(上万) ≈ 14 次），最后单跑那一行把原文与退出码印出来。

语料是**固定**的（没有随机数）：门禁要可复现，随机 fuzz 只会带来"换个种子就绿"。
"""
import glob
import json
import os
import subprocess
import sys

CLI = ['moon', 'run', '--target', 'native', 'cli']
BATCH_TIMEOUT = 1800      # 整批：超时视为卡死（比崩溃更坏的状态：门禁会挂住）
LINE_TIMEOUT = 60         # 单行（只在定位失败时用）

# 位置参数的敌意取值：**故意不含**小的合法整数（`4096` 一类）——语料不该在
# 顺带把画布改成 4096×4096 之后再去测后面几百行（那会让"这一行很慢"变成
# "整批很慢"，而失败原因指向别处）。
HOSTILE = [
    '-1', '0', 'abc', 'nan', 'inf', '-inf', '1e309', '0x10', '+', '--', '-',
    '=', 'x=', '=1', 'x==1', 'a=b=c', '"', "''", '\\', '../x', '$(id)', '`id`',
    '😀', '１２３', '%s', 'null', 'true', '[]', '{}', '1,2', 'x;y',
    'A' * 4096, 'B' * 64,
]

# 键值对里"值"的敌意取值：空值、非数、NaN/Inf、超长、越界、路径穿越。
VALUES = [
    '', '-1', '0', 'abc', 'nan', 'inf', '-inf', '1e309', '99999999999999999999',
    '0x10', 'A' * 512, '😀', 'null', 'true', '1,2', '../x',
]

# 每个命令至多取这么多个声明键去轰（键多的是载荷类命令，边际收益低）
MAX_KEYS = 8


def banner(msg):
    print(msg, flush=True)


def run_cli(lines, timeout):
    """把 lines 喂给一个 CLI 进程；返回 (exit_code, stdout_lines, stderr)。"""
    payload = '\n'.join(lines) + '\n'
    try:
        p = subprocess.run(CLI, input=payload, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout.splitlines(), p.stderr
    except subprocess.TimeoutExpired:
        return None, [], 'TIMEOUT'


def help_tools():
    """取工具字典（含每条命令的描述——键表就从描述里的 `key=` 抠）。"""
    code, out, err = run_cli(['session-open full_image', 'list-tools'], 600)
    if code != 0:
        banner('FAIL: 取 list-tools 失败（exit=%s）\n%s' % (code, err[-2000:]))
        sys.exit(1)
    for line in out:
        if '"tools"' not in line:
            continue
        return json.loads(line)['tools']
    banner('FAIL: list-tools 没吐出命令表')
    sys.exit(1)


def keys_of(desc):
    """从字典描述里抠出 `key=` 的键名（**唯一事实源就是字典**：LLM 照它发参数）。"""
    out, i = [], 0
    while True:
        j = desc.find('=', i)
        if j < 0:
            break
        k = j - 1
        while k >= 0 and (desc[k].isalnum() or desc[k] == '_'):
            k -= 1
        name = desc[k + 1:j]
        if name and not name[0].isdigit():
            out.append(name)
        i = j + 1
    seen, uniq = set(), []
    for k in out:
        if k not in seen:
            seen.add(k)
            uniq.append(k)
    return uniq[:MAX_KEYS]


def corpus(tools):
    """固定语料：登录 + 每条命令 × {裸名, 位置参数, 声明键 × 敌意值, 混合}。"""
    lines = ['session-open full_image', 'new 16 16']
    plan = []            # (命令名, [该命令的行])
    for t in tools:
        name = t['name']
        if name in ('session-open', 'list-tools', 'help'):
            continue          # 会话/字典类命令单独测过，且它们会重置会话
        ks = keys_of(t.get('desc', ''))
        body = [name]
        for tok in HOSTILE:
            body.append('%s %s' % (name, tok))
        for tok in HOSTILE[:10]:
            body.append('%s %s %s' % (name, tok, tok))
        for i in range(min(3, len(HOSTILE))):
            body.append('%s %s %s %s' % (name, HOSTILE[i], HOSTILE[-1 - i], HOSTILE[i + 5]))
        for k in ks:
            body.append('%s %s' % (name, k))               # 漏了 `=` 的裸词
            for v in VALUES:
                body.append('%s %s=%s' % (name, k, v))
        if ks:
            body.append('%s %s' % (name, ' '.join('%s=%s' % (k, VALUES[0]) for k in ks)))
        plan.append((name, body))
        lines.extend(body)
    return lines, plan


def check_batch(lines):
    """整批跑一次，返回 (ok, 说明, 坏行下标 or None)。"""
    code, out, err = run_cli(lines, BATCH_TIMEOUT)
    if code is None:
        return False, '整批超时（%ds）：疑似某条命令在敌意参数下卡死' % BATCH_TIMEOUT, None
    # 第一行是 CLI 的 banner（不含 JSON）
    replies = out[1:] if out else []
    if code != 0:
        return False, 'CLI 退出码 %s（崩溃/abort）' % code, first_bad(lines, replies, err)
    if len(replies) != len(lines):
        return False, ('回包行数 %d ≠ 输入行数 %d（有命令**没回包**：静默也是 bug）'
                       % (len(replies), len(lines))), first_bad(lines, replies, err)
    for i, r in enumerate(replies):
        if not r.startswith('{'):
            return False, '第 %d 行回包不是 JSON：%r' % (i + 1, r[:200]), i
        try:
            json.loads(r)
        except ValueError:
            return False, '第 %d 行回包不是合法 JSON：%r' % (i + 1, r[:200]), i
    for marker in ('panicked', 'abort', 'unreachable', 'Unreachable', 'panicked at'):
        if marker in err:
            return False, 'stderr 里出现 %r' % marker, first_bad(lines, replies, err)
    if err.strip():
        return False, 'stderr 非空（疑似警告/崩溃痕迹）：%r' % err.strip()[:300], None
    return True, '整批 %d 行全部回包、全是 JSON、退出码 0' % len(lines), None


def first_bad(lines, replies, err):
    """回包数不对时定位第一处对不上的下标（用它当二分起点）。"""
    n = min(len(lines), len(replies))
    for i in range(n):
        if not replies[i].startswith('{'):
            return i
    return n if n < len(lines) else None


def bisect(lines):
    """按前缀二分找出第一行让 CLI 变红的输入。崩溃是确定性的，所以可行。"""
    lo, hi = 0, len(lines)
    while lo < hi:
        mid = (lo + hi) // 2
        code, out, err = run_cli(lines[:mid], LINE_TIMEOUT * 4)
        ok = code == 0 and len(out) - 1 == mid
        if ok:
            lo = mid + 1
        else:
            hi = mid
    if lo == 0:
        return None, None
    return lo - 1, lines[lo - 1]


def main():
    tools = help_tools()
    lines, plan = corpus(tools)
    banner('语料：%d 条命令 × 敌意参数 → %d 行（固定、可复现）'
           % (len(plan), len(lines)))
    # 单调地板：语料行数只许涨（新命令必须被轰到；缩语料 = 悄悄少测一片）
    import floors
    floors.check('panic_lines', len(lines))
    ok, msg, bad = check_batch(lines)
    if ok:
        banner('对抗性参数 OK（%s）' % msg)
        return 0
    banner('FAIL: %s' % msg)
    if bad is None:
        idx, line = bisect(lines)
    else:
        idx, line = bad, lines[bad] if bad < len(lines) else None
    if line is None:
        banner('（定位不到具体行——请手工跑 `python3 panic_hunt.py --dump` 看语料）')
        return 1
    code, out, err = run_cli(lines[:idx] + [line], LINE_TIMEOUT * 4)
    banner('最小复现：第 %d 行\n    %s\n  退出码 %s' % (idx + 1, line[:400], code))
    if err.strip():
        banner('  stderr:\n    %s' % err.strip()[-1500:].replace('\n', '\n    '))
    # 崩溃时这一行**没有回包**，别把上一行的回包印出来当它的（"证据错位"比没有证据更坏）
    if len(out) - 1 >= idx + 1:
        banner('  该行回包：%s' % out[idx + 1][:400])
    else:
        banner('  该行**没有回包**（进程在它上面就死了）')
    return 1


def dump():
    tools = help_tools()
    lines, _ = corpus(tools)
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--dump':
        sys.exit(dump())
    sys.exit(main())
