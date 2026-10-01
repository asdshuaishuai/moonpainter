#!/usr/bin/env python3
"""字典 ↔ 解析器 的参数对账（verify.sh 第 11 步）。

铁律 6 要求"改命令分发必须同步工具字典"，但那条只覆盖**命令清单**；
**参数**是两张互不校验的表：字典里写 `key=`（LLM 就是照这个发参数的），
解析器里另有 `check_kv_args(tokens, N, [允许的键], "命令")`。两者对不上时：

  - 字典写了、解析器不认 → 照描述发参数**被拒**（还算好的，至少报错）；
  - 解析器认了、字典没写 → 一个只有读源码才知道存在的参数（更糟）。

实测这一条抓到了 `mvsl-set`：描述里用 CLI 参数记法写了 `layer=`，
而它其实是**载荷 JSON 里的字段**，命令行上被 `allowed=[]` 一律拒绝。

判据：解析器"认哪些键"从 check_kv_args/check_kv_names 的第三个实参读出来
（数组字面量直接取；`helper()` 就去 helper 返回的数组里取）。
"""
import re
import sys
import glob

SRC = 'agent'


def read_srcs():
    out = {}
    for f in sorted(glob.glob(SRC + '/*.mbt')):
        if f.endswith('tools.mbt'):
            continue
        out[f] = open(f, encoding='utf-8').read()
    return out


def split_args(text):
    """把 `(a, b, c)` 里的顶层实参切出来（括号/引号感知）。"""
    args, depth, cur, i, in_str = [], 0, '', 0, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == '\\':
                cur += text[i:i + 2]
                i += 2
                continue
            if c == '"':
                in_str = False
            cur += c
        elif c == '"':
            in_str = True
            cur += c
        elif c in '([{':
            depth += 1
            cur += c
        elif c in ')]}':
            depth -= 1
            if depth < 0:
                break
            cur += c
        elif c == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
        else:
            cur += c
        i += 1
    if cur.strip():
        args.append(cur.strip())
    return args


def call_args(text, fname):
    """所有 `fname(...)` 调用的实参列表。"""
    out = []
    for m in re.finditer(r'\b' + re.escape(fname) + r'\s*\(', text):
        i = text.index('(', m.end() - 1)
        depth, j, in_str = 0, i, False
        while j < len(text):
            c = text[j]
            if in_str:
                if c == '\\':
                    j += 2
                    continue
                if c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((split_args(text[i + 1:j]), m.start()))  # 括号内的顶层实参
    return out


def balanced_at(text, start):
    depth, j, in_str = 0, text.index(text[start], start), False
    while j < len(text):
        c = text[j]
        if in_str:
            if c == '\\':
                j += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif text[j] in '([{':
            depth += 1
        elif text[j] in ')]}':
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
        j += 1
    return text[start:]


KEY_RE = r'"([a-z_][a-z_0-9]*)"'


def array_keys(expr, depth=0):
    """从 `["a","b"]` 或 `helper(...)` 里取出键集合；空表返回 set()。

    键表函数**可以是构造出来的**（`let ks = add_shape_keys(…); ks.push("b64"); ks`），
    所以不能只找第一个数组字面量：没有数组字面量时退回"函数体里所有像键的
    字面量 + 它引用的键表函数"，递归下去（深度上限防环）。
    """
    expr = expr.strip()
    if expr.startswith('['):
        return set(re.findall(KEY_RE, balanced_at(expr, 0)))
    if expr in ('[]', ''):
        return set()
    m = re.match(r'([a-z_][a-z_0-9]*)\s*\(', expr)
    if not m or depth > 4:
        return None
    body = body_of(join_srcs, m.group(1))
    if body is None:
        return None
    # 取**所有**方括号里的小写键字面量：不能只取第一个 `[...]`——
    # `let ks : Array[String] = [...]` 里的 `[String]` 会被先匹配到，
    # 于是键集解析成空、审计把"解析器什么都不认"当成事实（实测踩过）。
    keys = set()
    for arr in re.finditer(r'\[[^\]]*\]', body):
        keys |= set(re.findall(KEY_RE, arr.group(0)))
    # 键表也可以是**拼出来的**（`if kind is Polygon { ks.push("points") }`），
    # 所以 `.push("…")` 里的字面量同样算数。这是对 kind 相关键表的一个
    # **过近似**（分不清哪种 kind 走哪个分支），宁可少喊狼——kind 专属的
    # 那一面由 lint 的 kind_only_fields 表 + 测试罩着。
    for pm in re.finditer(r'\.push\(\s*' + KEY_RE + r'\s*\)', body):
        keys.add(pm.group(1))
    if not keys:
        keys = set(re.findall(KEY_RE, body))
    for m2 in re.finditer(r'\b([a-z_][a-z_0-9]*)\s*\(', body):
        if m2.group(1) == m.group(1):
            continue
        sub = array_keys(m2.group(1) + '()', depth + 1)
        if sub:
            keys |= sub
    return keys


def body_of(sources, fname):
    for t in sources.values():
        m = re.search(r'\bfn\s+' + re.escape(fname) + r'\s*[(<]', t)
        if not m:
            continue
        i = t.index('{', m.end() - 1)
        depth = 0
        for j in range(i, len(t)):
            if t[j] == '{':
                depth += 1
            elif t[j] == '}':
                depth -= 1
                if depth == 0:
                    return t[i:j + 1]
    return None




def enclosing_fn(text, pos):
    """包含 pos 的函数名。"""
    name = None
    for m in re.finditer(r'\bfn\s+([a-z_][a-z_0-9]*)\s*[(<]', text):
        if m.start() < pos:
            name = m.group(1)
        else:
            break
    return name


def fn_param_index(fname, pname):
    """形参名在 `fn fname(...)` 里的位置（0 基）；找不到返回 None。"""
    for t in srcs.values():
        m = re.search(r'\bfn\s+' + re.escape(fname) + r'\s*[(<]', t)
        if not m:
            continue
        i = t.index('(', m.end() - 1)
        depth, j = 0, i
        while j < len(t):
            if t[j] == '(':
                depth += 1
            elif t[j] == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        for k, prm in enumerate(split_args(t[i + 1:j])):
            if prm.split(':')[0].strip() == pname:
                return k
        return None
    return None


def arg_literals(fname, idx):
    """分发表里调用 fname 时第 idx 个实参的**字面量命令名**集合。

    命令名可以做成参数从分发表传进来（`cmd_add_shape(…, "add-rect")`），
    这是刻意的：分发表本来就知道名字。这里顺着把它找回来，
    免得门禁因为"看不见"而放行。任一调用点的实参不是字面量 → 不能判定。
    """
    out = set()
    for t in srcs.values():
        for args, _ in call_args(t, fname):
            if len(args) <= idx:
                return None
            a = args[idx].strip()
            if ':' in a:
                continue  # 函数**定义**处（形参表）不是调用点
            if re.match(r'^"[a-z0-9\-]+"$', a):
                out.add(a.strip('"'))
            else:
                return None
    return out



srcs = read_srcs()
join_srcs = srcs

tools = open(SRC + '/tools.mbt', encoding='utf-8').read()


def doc_keys(expr):
    """描述表达式里承诺的全部 `key=`。

    描述**可以是生成的**（`"…" + set_style_keys().map(…)`），所以不能只看
    字符串字面量：字面量照收，另外把引用的键表函数的返回数组也算进来。
    否则 `set-style`（描述一直是从键表生成的）会被误报成"字典没写"。
    """
    keys = set(re.findall(r'([a-z_][a-z_0-9]*)=', expr))
    for m in re.finditer(r'\b([a-z_][a-z_0-9]*)\s*\(', expr):
        ks = array_keys(m.group(1) + '()')
        if ks:
            keys |= ks
    return keys


# 字典：命令 → 描述表达式（用实参切分，别用正则——描述里有逗号）
descs = {}
for args, _ in call_args(tools, 'add'):
    if len(args) < 3:
        continue
    cmd = args[0].strip().strip('"')
    descs[cmd] = args[1]

# 解析器：命令 → 认下的键集合
parsed = {}
unreadable = []
dynamic = []
sites = set()
for f, t in srcs.items():
    for args, pos in call_args(t, 'check_kv_args') + call_args(t, 'check_kv_names'):
        if len(args) < 4:
            continue  # 函数定义处（参数表）不是调用点
        name_arg = args[3].strip()
        if ':' in name_arg:
            continue  # `fn check_kv_args(tokens, from, allowed, ctx : String)` 定义
        keys = array_keys(args[2])
        if re.match(r'^"[a-z0-9\-]+"$', name_arg):
            cmds = [name_arg.strip('"')]
        else:
            # 命令名是形参 → 顺分发表把字面量找回来；找不回来就**报错**，
            # 不许静默跳过（否则这个命令从门禁里消失、汇总照旧"通过"）。
            fn = enclosing_fn(t, pos)
            idx = fn_param_index(fn, name_arg) if fn else None
            cmds = arg_literals(fn, idx) if fn is not None and idx is not None else None
            if not cmds:
                dynamic.append('%s：%s 里的第 4 个实参是 %s，顺分发表也找不回字面量'
                               % (f, fn, name_arg))
                continue
        if keys is None:
            # **读不出来 ≠ 不用审**：静默跳过会让这个命令从门禁里消失
            # （正是"锚点失效"那一类：汇总照旧好看，覆盖已经没了）。
            for cmd in cmds:
                unreadable.append('%s：%s 的键表读不出来：%s' % (f, cmd, args[2]))
            continue
        for cmd in cmds:
            sites.add(cmd)
            parsed.setdefault(cmd, set()).update(keys)

# 完整性：凡是**自己解析 kv 参数**的命令，都必须有键表校验。
# 手写 `has_prefix("max=")` / `kv_args` 的命令会静默收下认不出的键
# （"拼错的参数名返回 ok 而一个像素没改"），这正是历轮在堵的"静默接受"。
disp = {}
for f, t in srcs.items():
    for name, fn in re.findall(r'"([a-z0-9\-]+)"\s*=>\s*(cmd_[a-z_0-9]+)', t):
        disp.setdefault(name, fn)
hand = []
for cmd in sorted(descs):
    fn = disp.get(cmd)
    body = body_of(srcs, fn) if fn else None
    if body is None:
        continue
    parses = ('kv_args(' in body or re.search(r'has_prefix\("[a-z_]+="\)', body)
              or re.search(r'\.get\("[a-z_]+"\)', body))
    if parses and cmd not in sites:
        hand.append('%s：解析 kv 参数却没有键表校验（认不出的键会被静默收下）' % cmd)

fails = list(unreadable) + list(dynamic) + hand
# 每个真实的 kv 调用点都必须被审到（否则这门外禁有洞）
for cmd in sorted(sites - set(parsed)):
    fails.append('%s：有 check_kv_* 调用点却没能被审（键表读不出来？）' % cmd)
for cmd, desc in sorted(descs.items()):
    dk = doc_keys(desc)
    if cmd not in parsed:
        continue  # 手写扫描参数的命令（render/census/... ）另有一套，见 AGENTS
    got = parsed[cmd]
    for k in sorted(dk - got):
        fails.append('%s：字典承诺 `%s=`，解析器不认（照描述发参数会被拒）' % (cmd, k))
    for k in sorted(got - dk):
        fails.append('%s：解析器收下 `%s=`，字典没写（只有读源码才知道有它）' % (cmd, k))

# ---- 第四面：数值解析不许**静默退默认** ----
# `match to_d(m.get("k")) { Some(v) => v, None => 默认 }` 这种写法看着像防守，
# 实际是把"给了但根本不是数"变成默认值：回包 ok、画面照默认渲染，调用方分不出
# "我给的数生效了"与"我给的数没被看懂"。实测 `add-text font_size=abc` 静默按 16、
# `font_size=-3` 建出 -5.14x-3 的负尺寸层（同一个函数里 `w`/`h`/`x`/`y` 四兄弟
# 一模一样）。要么报错（`arg_d` 就是干这个的），要么这条判据会红。
def code_only(line):
    """剥掉行尾注释（字符串字面量里的 `//` 不算）。

    判据必须分得清**代码与散文**：这一版第一跑就抓到了我自己刚写的那段注释
    （`match to_d(...) { Some(v) => v, None => 默认 }`）——注释里描述的坏写法
    被当成了真代码。同一课在第 9 步（参数下界扫描）已经上过一次。
    """
    out, in_str, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == '"':
            in_str = not in_str
        elif (
            c == '/'
            and not in_str
            and i + 1 < len(line)
            and line[i + 1] == '/'
        ):
            break
        out.append(c)
        i += 1
    return ''.join(out)


srcs = read_srcs()
silent = []
for name, text in srcs.items():
    if not name.startswith('agent/') or '_test' in name:
        continue
    lines = [code_only(l) for l in text.split('\n')]
    for i, line in enumerate(lines):
        if 'to_d(' not in line or 'fn to_d' in line:
            continue
        win = '\n'.join(lines[i:i + 5])
        m = re.search(r'None\s*=>\s*(.{0,80})', win, re.S)
        if m and not re.search(r'return|err\(|Err\(|abort', m.group(1)):
            tail = m.group(1).strip().split('\n')[0][:40]
            silent.append('%s:%d 数值解析静默退默认（%s）' % (name, i + 1, tail))
fails.extend(silent)

if fails:
    print('字典与解析器参数对账失败 %d 条：' % len(fails))
    for x in fails:
        print('  ' + x)
    sys.exit(1)
print('字典与解析器参数对账通过（审计 %d 条命令 / %d 个 kv 调用点，%d 条带参数）'
      % (len(parsed), len(sites), sum(1 for c in parsed if parsed[c])))
