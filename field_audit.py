#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""字段面门禁（铁律 6「改得动吗」那条的机器版）：`Layer` 的每个字段，命令面改得动吗？

为什么需要它：这一面此前是**靠手走**的。AGENTS 里写着「"改得动吗"这一面到此
走完」——而那句话是走过 `add-adjust`→`set-adjust`、`add-text`→`set-text`、
`points`→`set-style points=` 三处之后下的结论。**手走的清单一定漏**（同
`kind_only_fields` 那课：这张表从 3 格补到 8 格，后 5 格此前谁都没查）。
实测这次它漏了两处：

  - `asset_hash`：换一张图只能 `delete` 再 `add-image`，层序/蒙版/标签/
    透明度/翻转/旋转全丢，而且层被推到栈顶；
  - 位图层的**盒子**：`add-image` 不给 `w=`/`h=` 时盒恒为 100×100，而渲染器把
    资产**拉伸到盒子**——400×300 的图被静默压成正方形（回包里 `asset_size`
    还写着 400x300，同一个信封里两个字段描述的不是同一件事）。

判据：`core/document.mbt` 的 `Layer` 每个字段，必须至少被一条**建层之后**能改它的
命令覆盖；覆盖不到的要显式声明（`id`/`kind`：层身份，改身份 = 换一个层，不属于
"改得动"这一面）。"哪些命令改哪个字段"从源码静态读出来——**读不出来判失败**，
别静默跳过（静默跳过 = 这块覆盖没了而汇总照旧好看，同 `verify.sh#anchors` 那课）。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
AGENT = ROOT / "agent"

# kv 键 → `Layer` 字段。键清单本身从源码读（见 `read_kv_keys`），这里只说
# "这个键改的是哪个字段"——**一份映射**，别在两边各写一份。
KEY_FIELD = {
    "name": "name",
    "x": "x",
    "y": "y",
    "w": "w",
    "h": "h",
    "fill": "fill",
    "lgrad": "fill",  # 渐变是 fill 的一种（Gradient 变体）
    "stroke": "stroke",
    "stroke_w": "stroke",
    "opacity": "opacity",
    "blend": "blend",
    "radius": "corner_radius",
    "rot": "rotation_deg",
    "visible": "visible",
    "tag": "tags",
    "points": "points",
    "handles": "handles",
    "text": "text",
    "font_size": "font_size",
    "b64": "asset_hash",  # add-image / set-image 的像素载荷
    "op": "adjust",  # add-adjust / set-adjust 的算子
    "value": "adjust",
    # 色阶/曲线参数（levels/curve 都是 `adjust` 这个字段的内容：
    # `points` 在调整层上写的是 `adjust.curve`，在图形层上是 `points` 字段）
    "in_lo": "adjust",
    "in_hi": "adjust",
    "gamma": "adjust",
    "out_lo": "adjust",
    "out_hi": "adjust",
    # 蒙版参数（mask_keys）：改的是 `mask` 这个字段本身
    "kind": "mask",
    "feather": "mask",
    "roughen": "mask",
    "invert": "mask",
    # 图层样式（fx，set-fx）：16 个参数 + clear 改的都是 `fx` 这一个字段
    # （它是 `LayerFx` 整份样式；`clear=1` = 把整份摘掉，仍改这个字段）
    "clear": "fx",
    "shadow": "fx",
    "shadow_dx": "fx",
    "shadow_dy": "fx",
    "shadow_blur": "fx",
    "shadow_color": "fx",
    "outline": "fx",
    "outline_w": "fx",
    "outline_color": "fx",
    "glow": "fx",
    "glow_radius": "fx",
    "glow_color": "fx",
    "inner": "fx",
    "inner_dx": "fx",
    "inner_dy": "fx",
    "inner_blur": "fx",
    "inner_color": "fx",
    # brush / erase（位置参数是层 id + 一串点，其余走键）
    "pts": "dabs",
    "r": "dabs",
    "color": "dabs",
}

# 这些键**不是** `Layer` 字段，而且这是刻意的——必须写明理由（否则门禁只会
# 对着一堆分析/查询参数喊冤，而人就开始随手往 KEY_FIELD 里塞假映射）。
NON_FIELD_KEYS = {
    "id": "建层时给**新层**的 id（身份在出生那一刻定；改显示名用 `rename`）——不是「改得动」这一面",
    "layer": '指"改哪一个层"（brush/erase 的目标选择器），不是层自己的字段',
    # bool-op：操作数是**两个不同的层**，`a`/`b` 是"选哪一个操作数"，
    # 不是任何一层的字段；`op` 是算法名（并/差/交/异或），也不是字段。
    "a": 'bool-op 的操作数选择器（"第一个形状是哪个层"），不是层自己的字段',
    "b": 'bool-op 的操作数选择器（"第二个形状是哪个层"），不是层自己的字段',
    "op": 'bool-op 的算法名（union/subtract/intersect/xor）——它决定**读哪些字段**，自己不是字段',
}

# 不走 kv 的专用命令 → 它改的字段（`move`/`flip`/`tag` 这类是位置参数）。
CMD_FIELD = {
    "move": ["x", "y"],
    "resize": ["w", "h"],
    "rotate": ["rotation_deg"],
    "flip": ["flip_h", "flip_v"],
    "rename": ["name"],
    "visible": ["visible"],
    "tag": ["tags"],
    "untag": ["tags"],
    "group": ["children"],
    "ungroup": ["children"],
    "add-mask": ["mask"],
    "set-mask": ["mask"],
    "remove-mask": ["mask"],
    "add-adjust": ["adjust"],
    "set-adjust": ["adjust"],
    "set-fx": ["fx"],
    "set-text": ["text", "font_size", "w", "h"],
    "set-style": [
        "fill",
        "stroke",
        "opacity",
        "blend",
        "corner_radius",
        "points",
        "rotation_deg",
        "visible",
        "name",
        "tags",
    ],
    "add-image": ["asset_hash"],
    "set-image": ["asset_hash", "w", "h"],
    "add-text": ["text", "font_size"],
    "add-rect": ["fill", "stroke", "opacity", "blend", "corner_radius", "visible", "tags"],
    "add-ellipse": ["fill", "stroke", "opacity", "blend", "visible", "tags"],
    "add-polygon": ["fill", "stroke", "opacity", "blend", "points", "visible", "tags"],
    "add-line": ["stroke", "points", "visible", "tags"],
    "brush": ["dabs"],
    "erase": ["dabs"],
}

# 建层之后**任何命令都改不动**的字段：必须在这里显式声明，别让它静默通过。
# 声明要经得起追问——"身份字段"是理由，"暂时没做"不是（那种要写进
# README 的能力边界 + PLAN 的下一步，而不是塞进这张表当设计取舍）。
DECLARED = {
    "id": "层身份：容器内的一切引用（编辑表的 layer=、断言、undo 栈）都按 id 定位，改 id 等于换一个层；改显示名用 `rename`",
    "kind": "层身份：改种类 = 换一个层（`delete` + 对应 `add-*`）——渲染器/命令面/校验全按 kind 分派，原地改种类没有定义",
}


def read_layer_fields():
    """从 `core/document.mbt` 的 `pub(all) struct Layer { … }` 读字段名。"""
    src = (ROOT / "core" / "document.mbt").read_text(encoding="utf-8")
    m = re.search(r"pub\(all\) struct Layer \{(.*?)\n\}", src, re.S)
    if not m:
        return None, "core/document.mbt 里找不到 `pub(all) struct Layer { … }`"
    fields = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        mm = re.match(r"([a-z_][a-z0-9_]*)\s*:", line)
        if mm:
            fields.append(mm.group(1))
    if not fields:
        return None, "`Layer` 的字段一个都没读出来（解析写窄了？）"
    return fields, None


def read_kv_keys():
    """读 agent 侧**全部** kv 键清单：`*_keys()` 函数体 + `check_kv_args` 的内联字面量表。

    两个来源都要读：键清单在本仓库是 `*_keys()` 函数（单一事实源），但
    `set-adjust` 这类是内联字面量表——只读一处就会漏。
    """
    keys = set()
    for path in sorted(AGENT.glob("*.mbt")):
        src = path.read_text(encoding="utf-8")
        # 剥注释（同 param_audit：判据要能分清代码与散文）
        src = re.sub(r"//[^\n]*", "", src)
        for fm in re.finditer(r"fn\s+[a-z_]*keys\s*\([^)]*\)\s*->\s*Array\[String\]\s*\{", src):
            i = fm.end()
            depth = 1
            while i < len(src) and depth > 0:
                if src[i] == "{":
                    depth += 1
                elif src[i] == "}":
                    depth -= 1
                i += 1
            body = src[fm.end() : i]
            keys.update(re.findall(r'"([a-z_][a-z0-9_]*)"', body))
        # check_kv_args(tokens, N, ["k1", "k2"], "cmd") —— 内联键表。
        # ⚠️ 只取**第 3 个实参**：末尾那个实参是命令名（"brush"），第一版把它
        # 也当成键读进来了（"源码里的 kv 键 brush 没有登记"）——**判据要能分清
        # 参数与它的兄弟**，否则门禁会对着命令名喊冤。
        for cm in re.finditer(r"check_kv_args\(", src):
            i = cm.end()
            depth = 1
            args = []
            cur = ""
            while i < len(src) and depth > 0:
                c = src[i]
                if c in "([{":
                    depth += 1
                elif c in ")]}":
                    depth -= 1
                    if depth == 0:
                        break
                if c == "," and depth == 1:
                    args.append(cur)
                    cur = ""
                else:
                    cur += c
                i += 1
            args.append(cur)
            if len(args) < 3 or "[" not in args[2]:
                continue
            # 只审**会改字段的**命令：`check_kv_args` 也被分析/渲染类命令用
            # （`probe max=`、`render width=`、`census within=`），那些键不落在
            # `Layer` 上，混进来只会逼着人往 KEY_FIELD 里塞假映射。
            cmd = re.search(r'"([a-z-]+)"', args[3]) if len(args) >= 4 else None
            if cmd is None or cmd.group(1) not in CMD_FIELD:
                continue
            keys.update(re.findall(r'"([a-z_][a-z0-9_]*)"', args[2]))
    if not keys:
        return None, "agent 侧的 kv 键清单一个都没读出来（解析写窄了？）"
    return keys, None


def read_commands():
    """从 `agent/tools.mbt` 读命令名（字典是单一事实源）。

    ⚠️ 名字里的字符集**不许写窄**：这里原先写的是 `[a-z-]+`，于是
    `open-mpd-b64` / `save-mpd-b64` 两条**带数字**的命令**从来没被读进来**
    （61 ≠ 63），而脚本照旧打印"对账通过"。窄的两个后果都要命：
    ①`CMD_FIELD` 里给这两条命令登记归属会被判成"不存在的命令"（**误报**）；
    ②将来任何带数字的新命令都**静默**落在覆盖面之外（**漏报**）。
    所以现在先读**全部** `add("…")` 的第一个参数，再检查每个名字都在允许字符集里
    ——读不出来就**判失败**，不静默跳过（同 `verify.sh#params` 那课）。
    """
    src = (ROOT / "agent" / "tools.mbt").read_text(encoding="utf-8")
    src = re.sub(r"//[^\n]*", "", src)
    names = re.findall(r'add\(\s*"([^"]+)"', src)
    if not names:
        return None, "agent/tools.mbt 里的命令名一个都没读出来"
    # **读不出来就判失败**：`add(` 的调用次数与读到的名字数必须相等。少了就说明
    # 正则的字符集写窄了——修复前正是这个状态（63 次调用只读到 61 个名字），
    # 而门禁照样全绿。判据要能自己发现"我少读了"，不能等外部对账来喊。
    calls = len(re.findall(r'add\(\s*"', src))
    if len(names) != calls:
        return None, "有 %d 个 add(…) 的名字没读进来（字符集写窄了？）" % (calls - len(names))
    bad = sorted(n for n in names if not re.fullmatch(r"[a-z0-9-]+", n))
    if bad:
        return None, "这些命令名读不出来（含允许字符集外的字符）：%s" % bad
    if len(set(names)) != len(names):
        dup = sorted(n for n in set(names) if names.count(n) > 1)
        return None, "命令表里有重名：%s" % dup
    return set(names), None


def main():
    fields, err = read_layer_fields()
    if err:
        print("FAIL:", err)
        return 1
    keys, err = read_kv_keys()
    if err:
        print("FAIL:", err)
        return 1
    cmds, err = read_commands()
    if err:
        print("FAIL:", err)
        return 1

    # 覆盖表：字段 → 谁改得动（命令名）
    cover = {f: [] for f in fields}
    key_owner = {}
    for k in sorted(keys):
        if k in NON_FIELD_KEYS:
            continue
        f = KEY_FIELD.get(k)
        if f is None:
            print('FAIL: 源码里的 kv 键 "{}" 没有登记它改的是哪个字段——'.format(k))
            print("      请在 field_audit.py 的 KEY_FIELD 里补一行（新参数面必须登记）。")
            return 1
        key_owner.setdefault(f, []).append(k)
    for f, ks in sorted(key_owner.items()):
        if f in cover:
            cover[f].append("键 " + "/".join(ks))
    for cmd, fs in sorted(CMD_FIELD.items()):
        if cmd not in cmds:
            print('FAIL: CMD_FIELD 里的命令 "{}" 不在字典里（改过名？）'.format(cmd))
            return 1
        for f in fs:
            if f not in cover:
                print('FAIL: CMD_FIELD 把命令 "{}" 记到字段 "{}"，但 Layer 里没有这个字段'.format(cmd, f))
                return 1
            cover[f].append(cmd)

    print("== Layer 字段面：建层之后改得动吗 ==")
    gaps = []
    for f in fields:
        who = cover[f]
        if who:
            print("  {:<14} ✓ {}".format(f, " / ".join(sorted(set(who)))))
        elif f in DECLARED:
            print("  {:<14} — 声明不可改：{}".format(f, DECLARED[f]))
        else:
            print("  {:<14} ✗ 没有任何命令改得动它".format(f))
            gaps.append(f)

    if gaps:
        print("")
        print("FAIL: 以下 Layer 字段建层之后改不动，且没有声明：{}".format("、".join(gaps)))
        print("      —— 「改得动吗」这一面不许靠手走（手走的清单一定漏）。")
        print("      补一条 set-* 命令（对偶于对应的 add-*），或在 DECLARED 里写明")
        print("      为什么它是身份而不是能力缺口。")
        return 1

    print("")
    for k, why in sorted(NON_FIELD_KEYS.items()):
        print("  非字段键 {:<8} — {}".format(k, why))
    print("")
    print(
        "字段面 OK：{} 个字段全部有归属（{} 个改得动，{} 个声明为身份字段）".format(
            len(fields), len(fields) - len(DECLARED), len(DECLARED)
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
