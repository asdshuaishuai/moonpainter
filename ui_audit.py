#!/usr/bin/env python3
"""人类前端 ↔ 引擎命令：**第二条边界**的对账（`build_demo.sh#doc-tools` 调它）。

已有的那条边界是 AI 工具面：`build_demo.sh#doc-tools` 断言
「引擎命令 − 工具面覆盖 == README 的 unreachable 名单」。人类前端是**另一条**，
此前完全没人管——实测 63 条命令里只有 35 条人类走得到，而 README 的「绘制」
一行读起来像"产品支持画多边形/线段"，实际前端连一个入口都没有。
（这就是仓库那条纪律的下半句：名单/数字有门禁，**名单旁边的理由没有**。）

三条判据：
① `reachable` 必须**恰好**等于源码里真实出现的命令（按字符串**首词**判定，
   与 `paint_tools_wbtest` 判 `tool_line` 首词的口径一致）——名单不能"编"：
   写上去而前端够不着的会被抓；
② `reachable ∪ 声明够不着 == 引擎命令`：不重、不漏、名单里不许有引擎里
   不存在的命令；
③ 每条"声明够不着"必须写理由（形如「- 命令 — 理由」），**空理由判失败**——
   没理由的名单就是没做过的决定。
④ 散文里的数字（"人类前端直接可达 **N** 条命令"）也要对得上：数字是承诺。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

# 命令表的**单一事实源**在 `field_audit.read_commands()`（它也是从
# `agent/tools.mbt` 读的）——这里不再写第二份正则，免得两处各窄一点。
import field_audit  # noqa: E402

BLOCK_A = "<!-- human-face:begin -->"
BLOCK_B = "<!-- human-face:end -->"


def read_human_reachable(cmds):
    """`demo/main.mbt` 里作为**字符串首词**出现的命令 = 人类前端可达的命令。

    为什么用"首词"而不是 `eng("cmd`：命令行的拼法有三种（`eng("add-rect x=…")`、
    `engine_exec_line(cmd + …)`、经参数传给拼串辅助函数），只认一种写法就会
    漏——实测第一版按 `eng("` 前缀统计，把 `add-mask` 这种"先算再发"的
    漏掉了两成。首词判定对三种写法都成立，而且与 `tool_line` 的首词判据同口径。
    """
    src = re.sub(r"//[^\n]*", "", (ROOT / "demo" / "main.mbt").read_text(encoding="utf-8"))
    lits = re.findall(r'"((?:[^"\\]|\\.)*)"', src)
    reach = set()
    for lit in lits:
        head = lit.split(" ")[0]
        if head in cmds:
            reach.add(head)
    return reach


def read_declared():
    """README 里那份"人类前端刻意不给入口"的名单（命令 + 理由）。"""
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    i = text.find(BLOCK_A)
    j = text.find(BLOCK_B)
    if i < 0 or j < 0 or j < i:
        return None, None, "README 里找不到 `%s` / `%s` 标记块" % (BLOCK_A, BLOCK_B)
    block = text[i:j]
    declared = {}
    nopr = []
    for line in block.splitlines():
        m = re.match(r"^- `([a-z0-9-]+)`\s*—\s*(.*)$", line.strip())
        if m:
            if not m.group(2).strip():
                nopr.append(m.group(1))
            declared[m.group(1)] = m.group(2).strip()
        elif re.match(r"^- `[a-z0-9-]+`", line.strip()):
            nopr.append(line.strip())
    num = re.search(r"人类前端[^\n]*?直接可达\s*\*\*(\d+)\*\*\s*条命令", block)
    return declared, (nopr, int(num.group(1)) if num else None), None


def main():
    cmds, err = field_audit.read_commands()
    if err:
        print("FAIL:", err)
        return 1
    reach = read_human_reachable(cmds)
    declared, extra, err = read_declared()
    if err:
        print("FAIL:", err)
        return 1
    nopr, stated = extra
    bad = []

    # ② 名单与引擎命令集合的关系（不重不漏、不许有幽灵命令）
    gap = cmds - reach
    unknown = sorted(set(declared) - cmds)
    if unknown:
        bad.append("名单里有引擎里不存在的命令：%s" % "、".join(unknown))
    not_declared = sorted(gap - set(declared))
    if not_declared:
        bad.append(
            "这些命令人类前端够不着、也没在名单里声明（是漏了还是没决定？）：%s"
            % "、".join(not_declared)
        )
    reachable_but_declared = sorted(set(declared) & reach)
    if reachable_but_declared:
        bad.append(
            "这些命令人类前端**明明够得着**却被声明成够不着（名单腐烂）：%s"
            % "、".join(reachable_but_declared)
        )
    # ③ 理由不许空
    if nopr:
        bad.append("名单里有没写理由的条目：%s" % "、".join(sorted(nopr)))
    # ④ 散文里的数字
    if stated is None:
        bad.append("标记块里没写「人类前端直接可达 **N** 条命令」")
    elif stated != len(reach):
        bad.append("标记块写「可达 %d 条」，实际 %d 条" % (stated, len(reach)))

    if bad:
        for b in bad:
            print("FAIL:", b)
        return 1
    print(
        "人类面边界 OK（引擎 %d 条 − 人类可达 %d 条 = 声明够不着 %d 条，全部有理由）"
        % (len(cmds), len(reach), len(declared))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
