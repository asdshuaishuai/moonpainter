#!/usr/bin/env python3
"""人类前端 ↔ 引擎命令：**第二条边界**的对账（`build_demo.sh#doc-tools` 调它）。

已有的那条边界是 AI 工具面：`build_demo.sh#doc-tools` 断言
「引擎命令 − 工具面覆盖 == README 的 unreachable 名单」。人类前端是**另一条**，
此前完全没人管——实测 63 条命令里只有 35 条人类走得到，而 README 的「绘制」
一行读起来像"产品支持画多边形/线段"，实际前端连一个入口都没有。
（这就是仓库那条纪律的下半句：名单/数字有门禁，**名单旁边的理由没有**。）

判据（写成第一版时**自己就栽了一次**，见下）：
① `reachable` = 前端**真的发得出**的命令：剥掉注释与 `#|` 注入的 JS/HTML 块
   （那不是命令行，是页面骨架），排除声明为"场景装载"的函数，然后取
   "作为字符串首词出现、且**长得像命令行**"（`cmd ` 开头）或"与引擎调用同一条
   语句"（`eng("undo")` 这种单词命令）的字面量。
   ⚠️ **"名字在源码里出现过"不算可达**：第一版就是按这个判的，于是
   `data-tool='move'`、`class='group'`、注入 JS 里的 `new`、还有 `bootstrap`
   发的示例场景（`add-rect`/`add-ellipse`）全被算成"人类可达"——名册虚高，
   而它正是为了防"名册是编的"才写的。**判据写窄和写宽都会骗人。**
② `reachable` 必须与源码实际发出的集合一致——名单不能"编"：写上去而前端
   够不着的会被抓；
③ `reachable ∪ 声明够不着 == 引擎命令`：不重、不漏、名单里不许有引擎里
   不存在的命令；
④ 每条"声明够不着"必须写理由（形如「- 命令 — 理由」），**空理由判失败**——
   没理由的名单就是没做过的决定；散文里的条数（"人类前端直接可达 **N** 条命令"）
   也要对得上：数字是承诺；
⑤ 声明为"场景装载"的函数必须真的还在（名单腐烂的另一个方向）。
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


# 声明为"场景装载/初始化"的函数：它们发出的命令**不是人类的动作**，而是
# 起始状态（示例场景 + 开会话）。判据必须能证明这些函数真的还在（⑤）。
SCENE_FUNCS = ("bootstrap",)

# 引擎入口（前端只有这几条路能把命令发出去）。行拼装类字面量（`"move " + …`）
# 自带空格，走"像命令行"那条；单词命令（`eng("undo")`）走"同语句"那条。
ENGINE_CALLS = ("eng(", "engine_exec_line(", "do_ui_cmd(", "import_line(")


def _strip_noise(src):
    """剥注释与 `#|` 注入块。注入的 JS/HTML 里全是 `data-tool='move'` 这种
    和命令名撞车的词——把它们算进来，名册就虚高（第一版的实测就是这样）。"""
    src = re.sub(r"//[^\n]*", "", src)
    return "\n".join(
        l for l in src.split("\n") if not l.lstrip().startswith("#|")
    )


def _cut_func(src, name):
    """切掉一个顶层函数的函数体（含签名行），返回 (新源码, 是否找到)。"""
    m = re.search(r"^fn %s\([^)]*\)[^\n]*\{" % re.escape(name), src, re.M)
    if not m:
        return src, False
    nxt = re.search(r"^(?:async )?(?:pub )?fn ", src[m.end():], re.M)
    end = m.end() + (nxt.start() if nxt else 0)
    return src[:m.start()] + src[end:], True


def read_human_reachable(cmds):
    """`demo/main.mbt` 里**真的发得出去**的命令 = 人类前端可达的命令。"""
    src = _strip_noise((ROOT / "demo" / "main.mbt").read_text(encoding="utf-8"))
    for fn in SCENE_FUNCS:
        src, found = _cut_func(src, fn)
        if not found:
            return None, "声明为场景装载的函数 `%s` 已经不在源码里了（名册腐烂）" % fn
    reach = set()
    for stmt in re.split(r"[;\n]", src):
        engine_here = any(c in stmt for c in ENGINE_CALLS)
        for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', stmt):
            head = lit.split(" ")[0]
            if head in cmds and (" " in lit or engine_here):
                reach.add(head)
    return reach, None


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
    reach, err = read_human_reachable(cmds)
    if err:
        print("FAIL:", err)
        return 1
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
    # 单调地板：人类可达条数只许涨（删掉人侧入口、把 README 数字改成新的，
    # 等号门禁照样绿——"能力倒退没人红"正是地板要堵的那半边）
    import floors
    floors.check("human_reachable", len(reach))
    floors.check("unreachable_human", len(declared))
    return 0


if __name__ == "__main__":
    sys.exit(main())
