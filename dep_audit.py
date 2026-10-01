#!/usr/bin/env python3
"""依赖方向门禁（verify.sh 第 12 步）。

铁律 5 说了三件事，此前**一件都没有门禁**：

    base ← codec ← core ← pixel ← render ← mpd ← agent ← cli
    禁止反向/环；FFI 只许出现在 cli（native-only），引擎包保持纯字节进出；
    引擎包零第三方依赖。

靠人眼守这条的实测代价：`demo/moon.pkg` 里那句 `moonpainter/core` 只为
`@core.ENGINE_VERSION` 一个常量而存在，于是"引擎交互必须经 wasm SDK"这条
纪律被开了个口子（同一个事实有两条路：demo 编译进去的常量 vs 已加载 wasm
的 `mp_version`）。这类"只为一个小东西而 import"的旁路不会有人报警——
moon 编译器只管有没有环，**反向依赖照样编得过**。

判据（每条都要能两头咬住，注入反例会红）：

1. 每个包都在 ORDER 里——**新加包必须来这里登记**，不许静默不审；
2. 每条 moonpainter/ 内部的边都朝前走（反向 → 红）；
3. `pixel` 绝不依赖 `render`（铁律 5 点名的反向边）；
4. 引擎包（base…wasm）零第三方依赖；第三方只许出现在 demo；
5. demo 不 import 任何 `moonpainter/` 包（引擎交互只走 wasm ABI）；
6. `extern "…"` FFI 只许出现在 cli/demo，引擎包内出现 → 红。

用法：python3 dep_audit.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# 依赖顺序：索引小的在底层。与 AGENTS 铁律 5 / DESIGN §2 的链一致。
# wasm 与 demo 不在链上，但也要有位置（wasm 驱动 agent，demo 只走 wasm ABI）。
ORDER = ["base", "codec", "core", "pixel", "render", "mpd", "agent", "cli", "wasm", "demo"]
ENGINE = ["base", "codec", "core", "pixel", "render", "mpd", "agent", "cli", "wasm"]
FFI_OK = ["cli", "demo"]
THIRD_PARTY_ONLY = ["demo"]

PACKAGE_RE = re.compile(r"^\s*\"([^\"]+)\"", re.M)


def parse_pkg(path):
    """返回 (内部依赖, 第三方依赖, 是否 test-only 之外的 import 块)。

    moon.pkg 里 import 块可以带 `for "test"`——测试期依赖不参与运行时依赖图，
    但**方向仍然是方向**，所以照样审，只是单独标出来。
    """
    text = path.read_text(encoding="utf-8")
    internal, third = set(), set()
    for block in re.finditer(r"import\s*\{(.*?)\}", text, re.S):
        for dep in PACKAGE_RE.findall(block.group(1)):
            if dep.startswith("moonpainter/"):
                internal.add(dep.split("/", 1)[1])
            elif dep.startswith("moonbitlang/core/"):
                pass  # 标准库，哪都能用
            else:
                third.add(dep)
    return internal, third


def main():
    pkgs = {}
    for d in ORDER:
        p = ROOT / d / "moon.pkg"
        if not p.exists():
            print("FAIL: %s/moon.pkg 不存在（ORDER 里的包名写错了？）" % d)
            return 1
        pkgs[d] = parse_pkg(p)

    fails = []

    # 1. 反向依赖 / 未知包
    for name in ORDER:
        for dep in sorted(pkgs[name][0]):
            if dep not in ORDER:
                fails.append("%s 依赖 %s，而 %s 不在 ORDER 里（新包要登记进来再审）"
                             % (name, dep, dep))
            elif ORDER.index(dep) >= ORDER.index(name):
                fails.append("反向依赖：%s（第 %d 位）依赖 %s（第 %d 位）"
                             % (name, ORDER.index(name), dep, ORDER.index(dep)))

    # 3. 铁律 5 点名的反向边
    if "render" in pkgs["pixel"][0]:
        fails.append("pixel 依赖了 render（铁律 5 点名的反向边）")

    # 4. 引擎包零第三方依赖
    for name in ENGINE:
        for dep in sorted(pkgs[name][1]):
            fails.append("引擎包 %s 依赖第三方 %s（引擎包必须零第三方依赖）" % (name, dep))

    # 5. demo 不 import 引擎包
    for dep in sorted(pkgs["demo"][0]):
        fails.append("demo 依赖了引擎包 %s：引擎交互只许经 wasm ABI（铁律 5 / "
                     "AGENTS demo 层纪律），这条旁路正是 @core.ENGINE_VERSION 那种" % dep)

    # 6. FFI 只许在 cli/demo
    for name in ENGINE:
        if name in FFI_OK:
            continue
        for f in sorted((ROOT / name).glob("*.mbt")):
            text = f.read_text(encoding="utf-8")
            # 剥注释：注释里写 `extern "C"` 不算（判据要分得清代码与散文）
            code = re.sub(r"//[^\n]*", "", text)
            if re.search(r'\bextern\s+"', code):
                fails.append("引擎包 %s 里出现 FFI（%s）：铁律 5 只许 cli 有 FFI"
                             % (name, f.name))

    # 目录里有 moon.pkg 却没进 ORDER → **不许静默跳过**
    for d in sorted(p.name for p in ROOT.iterdir() if p.is_dir()):
        if (ROOT / d / "moon.pkg").exists() and d not in ORDER:
            fails.append("包 %s 有 moon.pkg 却没登记进 ORDER（静默不审 = 这块覆盖没了）" % d)

    if fails:
        print("依赖方向门禁失败 %d 条：" % len(fails))
        for f in fails:
            print("  " + f)
        return 1
    print("依赖方向 OK（%d 个包：内部边全部朝前、引擎包零第三方、FFI 只在 %s）"
          % (len(ORDER), "/".join(FFI_OK)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
