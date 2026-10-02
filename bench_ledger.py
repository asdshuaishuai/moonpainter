#!/usr/bin/env python3
"""性能数字对账：DESIGN/README 里的**当前**性能数据必须与 `bench/ledger.json` 一致。

为什么要有这个脚本（这一条是实测出来的，不是推演）：
**性能数字进了散文就没人管**。本项目已经给命令数/变异数/步骤数/测试条数/字节预算
都配了机器对账，唯独"墙钟时间"这一类没有——因为 `bench_perf.py` 量的是墙钟时间，
**不许进 verify.sh**（会因机器慢而红）。于是性能数字成了唯一一处"只能靠人自觉"
的承诺：实测同一句边界结论（"12MP <2s 对任何多一点层数都不成立"）在 perf 三轮
之后仍然是错的，而**它连一个数字都没有**，任何对账都抓不住。

办法是**把"测量"与"引用"分开**：数字只能由 `bench_perf.py` 跑出来并写进
`bench/ledger.json`（账本），文档只能引用账本里的数。这个脚本核的就是"引用 ==
账本"，于是：
  * 转录错误（抄成 1.72）→ 红；
  * 手工"改进"数字（没跑过就改）→ 红；
  * 文档里出现一个从没量到过的数 → 红；
  * **重跑标定会让文档立刻变红**，直到你回来改文档——这是**故意的**，它把
    "改了实现要回来改数字"变成机械动作。

⚠️ **它管不了"账本是不是最新的"**：如果改了渲染实现却不重跑标定，文档与账本
会一起停留在旧数字上，这里看不出来。那一半只能靠纪律（改了 perf 相关实现就
跑一次 `python3 bench_perf.py`），或者靠人读 `bench/ledger.json` 的说明。

判据（都只看**当前**数据）：
  1. 标记块 `<!-- bench-table: <实验> -->` … `<!-- bench-table:end -->` 里的
     markdown 表格：每行第一格是**标签**（与账本标签逐字相同），该行**最后一个**
     `X.XX s` 是**当前实现**的值（历史对照列在左边），必须与账本一致（±15%）；
     行里若还有「成立/不成立」，它必须与 `值 < 2.0` 一致。
  2. 派生结论（只在 m2 上）：`每层边际 ≈ X s`、每一处 `约 N 层`（破线点）、
     以及带"软蒙版…边际"的那一行里**最后一个** `X s`（当前值；左边是历史值
     `0.53 s → 0.07 s`）必须与账本重算的一致（±25%；软蒙版边际是两次测量之差，
     绝对值小、噪声大，按 ±0.05 s 绝对容差）——m2 的每层边际是**两次测量之差再除 9**，
     噪声比单个中位大，所以放得宽一些；要抓的是量级腐烂（实测碰到过
     "约 3 层处就破"而真值是 19.6，以及"8.4 ms → 0.8 ms"）。
  3. **覆盖按具名清单核**：`REQUIRED_TABLE_EXPS` 里每个实验都必须有标记块，
     **而且账本里该实验的每个标签都必须在表里出现**（漏掉一行 = 那个数没进
     文档，而"表格对得上"照旧成立——实测就漏过"10 层 + 圆角"这一行），
     `每层边际` 与 `约 N 层` 各必须命中至少一次。**"至少有一个块"是不够的**：
     实测把 `<!-- bench-table: m4 -->` 的名字改坏（或整块删掉）时，"有一个块"
     照样成立，而 m4 那一整块数字已经没人对账了。判据找不到对象必须报错——
     静默跳过等于这块覆盖没了而汇总照旧好看（同 `verify.sh#anchors` 那一课）。

用法：`python3 bench_ledger.py`（供 `verify.sh#catalog` 调用；秒级）。
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_perf import m2_derived  # noqa: E402  （派生公式只有一处实现）

LEDGER = "bench/ledger.json"
DOCS = ["DESIGN.md", "README.md"]
# 单个中位：同机重跑的漂移实测 ~10%，留 15% 给噪声。
TOL_EACH = 0.15
# 派生量（每层边际 = 两次测量之差 / 9）：噪声被放大，留 25%。
TOL_DERIVED = 0.25

TABLE_RE = re.compile(r"<!-- bench-table: (\w+) -->(.*?)<!-- bench-table:end -->", re.S)
TABLE_OPEN_RE = re.compile(r"<!-- bench-table: \w+ -->")
# 哪些实验的**当前**数字必须出现在文档表里。加了新实验就登记在这里——
# 于是"漏写/删掉/改名"都会红，而不是静静少对一块账。
REQUIRED_TABLE_EXPS = ["m2", "m4"]
VALUE_RE = re.compile(r"(\d+\.\d+)\s*s")
MARGINAL_RE = re.compile(r"每层边际\s*[≈=]\s*(\d+\.\d+)\s*s")
# 软蒙版边际：一行里可能出现历史值（`0.53 s → 0.07 s`），取**最后一个**数字。
MASK_LINE_RE = re.compile(r"软蒙版[^\n]*边际|边际[^\n]*软蒙版")
MASK_ABS_TOL = 0.05
# 文档里每一处「约 N 层」都是在说 m2 的破线点（目前只有这一处会这么写）。
BREAK_RE = re.compile(r"约\s*(\d+)\s*层")

FAILS = []
HITS = {"table": 0, "marginal": 0, "break": 0, "mask": 0}
SEEN_EXPS = set()
SEEN_LABELS = {}


def fail(msg):
    FAILS.append(msg)


def close(a, b, tol):
    if b == 0:
        return abs(a) <= tol
    return abs(a - b) / abs(b) <= tol


def read_ledger():
    if not os.path.exists(LEDGER):
        fail(f"没有账本 {LEDGER}：先跑一次 `python3 bench_perf.py`（它才会写出数字）")
        return {}
    with open(LEDGER, encoding="utf-8") as f:
        return json.load(f)


def check_tables(ledger):
    for doc in DOCS:
        text = open(doc, encoding="utf-8").read()
        blocks = TABLE_RE.findall(text)
        opened = len(TABLE_OPEN_RE.findall(text))
        if opened != len(blocks):
            fail(f"{doc}：`<!-- bench-table: … -->` 有 {opened} 个，成对的只有 "
                 f"{len(blocks)} 个——标记块写坏了（少了 end？名字打错？）")
        for exp, block in blocks:
            HITS["table"] += 1
            SEEN_EXPS.add(exp)
            if exp not in ledger:
                fail(f"{doc}：标记块说实验 {exp}，账本里没有这个实验")
                continue
            for line in block.splitlines():
                line = line.strip()
                if not line.startswith("|"):
                    continue
                cells = [c.strip() for c in line.strip("|").split("|")]
                if len(cells) < 2 or set(cells[0]) <= set(":- "):
                    continue
                label = cells[0].replace("**", "").strip()
                if label in ("文档", "画笔层数"):
                    continue  # 表头
                vals = VALUE_RE.findall(line)
                if not vals:
                    fail(f"{doc}：{exp} 表里「{label}」这一行没有任何 `X.XX s`")
                    continue
                got = float(vals[-1])  # 最后一列 = 当前实现（左边是历史对照列）
                SEEN_LABELS.setdefault(exp, set()).add(label)
                if label not in ledger[exp]:
                    fail(f"{doc}：{exp} 表里的标签「{label}」在账本里没有"
                         f"（账本有：{'、'.join(sorted(ledger[exp]))}）——标签变了就要同步账本")
                    continue
                want = float(ledger[exp][label])
                if not close(got, want, TOL_EACH):
                    fail(f"{doc}：{exp}「{label}」写 {got:.2f} s，账本是 {want:.2f} s"
                         f"（差 {abs(got - want) / want * 100:.0f}%）")
                # 「成立/不成立」必须与 `值 < 2.0` 一致（这句曾经的错就在这一格）
                joined = " ".join(cells[1:])
                if "成立" in joined and "不成立" not in joined and not got < 2.0:
                    fail(f"{doc}：{exp}「{label}」写「成立」但 {got:.2f} s ≥ 2 s")
                if "不成立" in joined and got < 2.0:
                    fail(f"{doc}：{exp}「{label}」写「不成立」但 {got:.2f} s < 2 s")


def check_derived(ledger):
    m2 = ledger.get("m2", {})
    if "1 层" not in m2 or "10 层" not in m2:
        fail("账本缺 m2 的「1 层」/「10 层」，推不出每层边际与破线点")
        return
    per, brk = m2_derived(float(m2["1 层"]), float(m2["10 层"]))
    for doc in DOCS:
        text = open(doc, encoding="utf-8").read()
        for got in MARGINAL_RE.findall(text):
            HITS["marginal"] += 1
            if not close(float(got), per, TOL_DERIVED):
                fail(f"{doc}：写「每层边际 ≈ {got} s」，账本重算 {per:.2f} s")
        for m in MASK_LINE_RE.finditer(text):
            # 短语之后、到句号/左括号/换行为止的那一小段里找数字：README 那一行
            # 后面还有一整串别的数字（9.89 s → 5.88 s…），取"整行最后一个"
            # 会抓到它们（实测第一版就报"软蒙版边际 … 1.32 s"）。
            tail = text[m.end() : m.end() + 120]
            for stop in ("。", "\n", "（"):
                i = tail.find(stop)
                if i >= 0:
                    tail = tail[:i]
            vals = re.findall(r"\+?(\d+\.\d+)\s*s", tail)
            if not vals:
                continue
            got = float(vals[-1])
            HITS["mask"] += 1
            want = float(m2["10 层 + 软蒙版"]) - float(m2["10 层"])
            if abs(got - want) > MASK_ABS_TOL:
                fail(f"{doc}：写「软蒙版边际 … {got:.2f} s」，账本重算 {want:+.2f} s"
                     f"（±{MASK_ABS_TOL} s 之外；这一句也是两次测量之差，容易烂）")
        for got in BREAK_RE.findall(text):
            HITS["break"] += 1
            if brk is None:
                fail(f"{doc}：写「约 {got} 层」破线，但账本推不出破线点（边际 ≤ 0）")
            elif not close(float(got), brk, TOL_DERIVED):
                fail(f"{doc}：写「约 {got} 层」破线，账本重算 {brk:.1f} 层")


def main():
    ledger = read_ledger()
    if ledger:
        check_tables(ledger)
        check_derived(ledger)
    for exp in REQUIRED_TABLE_EXPS:
        if exp not in SEEN_EXPS:
            fail(f"文档里没有实验 {exp} 的 `<!-- bench-table: {exp} -->` 标记块"
                 f"——这一整块性能数字没人对账了（删掉或改了名字都会走到这里）")
            continue
        miss = sorted(set(ledger.get(exp, {})) - SEEN_LABELS.get(exp, set()))
        if miss:
            fail(f"{exp} 表里少了账本有的标签：{'、'.join(miss)}"
                 "——量到了却没写进文档（只看现有的行对不对得上，看不出来少了行）")
    for kind, name in (("marginal", "每层边际结论"), ("break", "破线层数结论"),
                       ("mask", "软蒙版边际结论")):
        if HITS[kind] == 0:
            fail(f"{name}一处都没找到——判据找不到对象时必须报错，不许静默通过")
    if FAILS:
        print("FAIL: 文档里的性能数字与账本对不上")
        for m in FAILS:
            print(f"  {m}")
        print("（数字只能由 `python3 bench_perf.py` 产出并写进 bench/ledger.json；"
              "文档只许引用账本里的数）")
        return 1
    print(f"性能数字 OK（{HITS['table']} 个表标记块、"
          f"{HITS['marginal']} 处每层边际、{HITS['break']} 处破线层数、"
          f"{HITS['mask']} 处软蒙版边际，全部对上 bench/ledger.json）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
