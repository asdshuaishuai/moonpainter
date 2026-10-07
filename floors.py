#!/usr/bin/env python3
"""单调地板：这些数字**只许往上抬**，往下调必须在同一次提交里写明理由。

为什么要它（为什么"等号门禁"不够）：
  `verify.sh#catalog` 现在核的是**等号**——文档写 70 条命令，实际就必须 70 条。
  它能抓住"数字写错"，但抓不住**退化**：把一条命令、一个入口、一条变异删掉，
  再把文档里的数字改成新的，门禁照旧全绿。**数字是承诺**（铁律 3）这句话里
  缺的那一半，就是"承诺不许倒退"。

它跟 photocraft 的 `FLOOR` 常量是同一条纪律（"parity 涨了就抬高 FLOOR，
永不下调"），只是这里把地板做成了**数据**（`floors.toml`）+ 一个读它的模块：

  - 谁**测量**，谁调用 `check()`（`verify.sh#catalog` 测命令/测试/变异条数，
    `ui_audit.py` 测人类可达条数，`build_demo.sh#doc-tools` 测工具面与点击穿透，
    `panic_hunt.py` 测语料行数）——**不在别处重算一遍**（同一个判断两处实现，
    就必然有一处先烂）。
  - 下调的唯一合法姿势：改 `floors.toml` 的值，**并在同一次提交里**加一条
    `[[retired]]`（metric + amount + reason）。`--check-history` 拿工作树与
    `HEAD` 比，任何"悄悄调低"当场红——"暂时降一点，回头补"正是要堵的。

用法：
  python3 floors.py                      # 列出所有地板
  python3 floors.py --check-history      # 只查"有没有悄然下调"（秒级，进门禁）
  from floors import check; check('mutations', 285)
"""
import os
import subprocess
import sys
import tomllib

# 数据文件按**本文件所在目录**解析，不按 cwd：`build_demo.sh` 的点击穿透那一步
# 在 `dist/` 里跑（`cd dist`），按 cwd 找会 FileNotFoundError——实测踩过。
PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'floors.toml')


def load(path=PATH):
    with open(path, 'rb') as f:
        return tomllib.load(f)


def load_head(path='floors.toml'):
    """HEAD 里的同一份文件（相对仓库根）；文件不存在（第一次加它）时返回空表。"""
    try:
        raw = subprocess.run(['git', 'show', 'HEAD:%s' % path],
                             capture_output=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}
    return tomllib.loads(raw.decode('utf-8'))


def check(metric, value, path=PATH):
    """值不得低于地板。**读不出地板 = 判失败**：静默跳过就等于这块覆盖没了。"""
    data = load(path)
    floors = data.get('floors', {})
    if metric not in floors:
        print('FAIL: floors.toml 里没有指标 %r（新指标要在同一次提交里登记地板）' % metric)
        sys.exit(1)
    floor = floors[metric]
    if value < floor:
        print('FAIL: %s = %s，低于地板 %s。'
              '要么修回能力，要么在 floors.toml 里下调**并**加一条 [[retired]] 写明理由'
              % (metric, value, floor))
        sys.exit(1)
    print('地板 OK（%s = %s ≥ %s）' % (metric, value, floor))
    return value


def check_history(path=PATH):
    """工作树 vs HEAD：任何下调都必须有一条**本次新增**的退休记录来抵。"""
    now, head = load(path), load_head()
    new_retired = []
    for r in now.get('retired', []):
        if r not in head.get('retired', []):
            new_retired.append(r)
    bad, ok = [], 0
    for metric, floor in sorted(now.get('floors', {}).items()):
        old = head.get('floors', {}).get(metric)
        if old is None:
            continue                      # 新指标：没有"下调"可言
        if floor < old:
            drop = old - floor
            cover = sum(r.get('amount', 0) for r in new_retired
                        if r.get('metric') == metric and r.get('reason', '').strip())
            if cover < drop:
                bad.append('%s：%s → %s（降了 %d），本次只申报了 %d'
                           % (metric, old, floor, drop, cover))
            else:
                ok += 1
        elif floor > old:
            ok += 1
        if floor == old:
            continue
        for r in new_retired:
            if r.get('metric') == metric and not r.get('reason', '').strip():
                bad.append('%s 的退休记录没写理由（空理由 = 没做过的决定）' % metric)
    for r in now.get('retired', []):
        if not r.get('metric') or 'amount' not in r or not str(r.get('reason', '')).strip():
            bad.append('退休记录不完整（metric/amount/reason 都要有）：%r' % r)
    if bad:
        print('FAIL: 地板只许抬不许降：')
        for b in bad:
            print('   ', b)
        return 1
    n = len(now.get('floors', {}))
    print('单调地板 OK（%d 项，本提交里 %d 项有变化且都有据可查）' % (n, ok))
    return 0


def main():
    if '--check-history' in sys.argv:
        return check_history()
    data = load()
    floors = data.get('floors', {})
    retired = data.get('retired', [])
    print('地板（%d 项）：' % len(floors))
    for k, v in sorted(floors.items()):
        print('  %-26s %s' % (k, v))
    if retired:
        print('退休记录（%d 条）：' % len(retired))
        for r in retired:
            print('  %-26s -%s %s' % (r['metric'], r['amount'], r['reason']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
