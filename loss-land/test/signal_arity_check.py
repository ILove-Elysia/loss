# test/signal_arity_check.py
# ============================================
# 信号参数个数校验 —— 抓"改了 signal 声明、忘了同步回调"这类错误
#
# 为什么需要它：
#   GDScript 的信号是**运行时**检查的。`signal item_dropped(a, b)` 改成
#   `signal item_dropped(a, b, c)` 之后，如果某处 `.connect(_on_dropped)` 的
#   回调还写着 `func _on_dropped(a, b)`，脚本照样能编译、静态检查也全绿，
#   直到玩家真的拖了一下物品才在控制台刷一行 "Too few arguments for call"。
#   2026-09-23 给拖拽加"数量"参数时正好踩在这个形状上（item_dropped /
#   cross_dropped 都要加 count），所以把这类检查固化下来。
#
# 检查项：
#   1. 每个 `xxx.emit(a, b, c)` 的参数个数 == 该信号的声明参数个数
#   2. 每个 `.connect(具名方法)` 的目标方法参数个数 == 信号声明参数个数
#   3. 每个 `.connect(func(...) ...)` 的 lambda 参数个数 == 信号声明参数个数
#
# 只检查**项目自定义信号**：内置信号（pressed / timeout / body_entered / …）
# 没有 `signal` 声明，自然落在"未知信号"里被跳过，不会误报。
#
# 用法：python test/signal_arity_check.py
# ============================================

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.join(ROOT, "script")

# 内置信号白名单（用到了但项目里没有 signal 声明的，直接跳过）
BUILTIN_SIGNALS = {
    "pressed", "toggled", "timeout", "body_entered", "body_exited",
    "area_entered", "area_exited", "animation_finished", "frame_changed",
    "visibility_changed", "item_selected", "text_changed", "text_submitted",
    "value_changed", "gui_input", "mouse_entered", "mouse_exited",
    "ready", "tree_entered", "tree_exiting", "renamed", "child_entered_tree",
    "child_exiting_tree", "size_changed", "resized", "focus_entered",
    "focus_exited", "draw", "hide", "show", "confirmed", "canceled",
    "custom_action", "close_requested", "files_selected", "dir_selected",
    "sort_children", "pre_sort_children", "id_pressed", "id_focused",
    "menu_changed",
}

problems = []


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def split_args(inner):
    """按顶层逗号切分参数列表（跳过括号内的逗号）。"""
    parts = []
    depth = 0
    cur = ""
    for ch in inner:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts if p.strip()]


def arg_count(inner):
    if not inner.strip():
        return 0
    return len(split_args(inner))


def balanced(text, start):
    """从 text[start] == '(' 开始，返回 (括号内内容, 结束下标)。"""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i
    return text[start + 1:], len(text)


def collect_signals():
    """全局收集 信号名 -> {文件: 参数个数}"""
    table = {}
    for dirpath, _dirs, files in os.walk(SCRIPT_DIR):
        for fn in files:
            if not fn.endswith(".gd"):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT).replace("\\", "/")
            for m in re.finditer(r"^signal\s+([A-Za-z_]\w*)\s*\(", read(path), re.M):
                name = m.group(1)
                inner, _ = balanced(read(path), m.end() - 1)
                table.setdefault(name, {})[rel] = arg_count(inner)
    return table


def collect_funcs(text):
    """本文件里的 func 名 -> (参数总数, 必填参数数)

    必填 = 没有写默认值的那些。GDScript 允许回调"多收几个参数"，
    但多出来的必须都有默认值（如 `func _on_x(_a = null, _b = null)` 可以挂到
    0/1/2 个参数的信号上）。少收参数则一定报错（emit 时 too few arguments）。
    """
    out = {}
    for m in re.finditer(r"^func\s+([A-Za-z_]\w*)\s*\(", text, re.M):
        inner, _ = balanced(text, m.end() - 1)
        args = split_args(inner)
        required = sum(1 for a in args if "=" not in a)
        out[m.group(1)] = (len(args), required)
    return out


def arity_ok(total, required, want):
    """回调能不能挂到 want 个参数的信号上。"""
    return required <= want <= total


def check_file(path, signals, rel):
    text = read(path)
    funcs = collect_funcs(text)
    lines = text.split("\n")

    def line_of(idx):
        return text.count("\n", 0, idx) + 1

    # ---- .emit(...) ----
    for m in re.finditer(r"([A-Za-z_]\w*)\.emit\s*\(", text):
        name = m.group(1)
        inner, _ = balanced(text, m.end() - 1)
        if name not in signals:
            continue
        declared = sorted(set(signals[name].values()))
        got = arg_count(inner)
        if len(declared) != 1:
            continue  # 同名信号参数不一致，信息不足，跳过
        if got != declared[0]:
            problems.append("%s:%d  %s.emit(...) 传了 %d 个参数，信号声明是 %d 个"
                            % (rel, line_of(m.start()), name, got, declared[0]))

    # ---- .connect(handler) ----
    for m in re.finditer(r"([A-Za-z_]\w*)\.connect\s*\(", text):
        name = m.group(1)
        if name in BUILTIN_SIGNALS or name not in signals:
            continue
        declared = sorted(set(signals[name].values()))
        if len(declared) != 1:
            continue
        want = declared[0]
        inner, _ = balanced(text, m.end() - 1)
        inner = inner.strip()
        if not inner:
            continue
        # 跳过 bind() 等链式调用（参数个数会被 bind 改变）
        if "bind(" in inner or ".bind" in inner:
            continue

        head = inner.split(",")[0].strip() if inner.startswith("func") else inner
        # 具名方法
        if re.fullmatch(r"[A-Za-z_]\w*", inner):
            if inner not in funcs:
                continue  # 可能是别处定义的回调（Callable 变量等），跳过
            total, required = funcs[inner]
            if not arity_ok(total, required, want):
                problems.append(
                    "%s:%d  %s.connect(%s) —— 回调必填 %d / 共 %d 个参数，信号声明是 %d 个"
                    % (rel, line_of(m.start()), name, inner, required, total, want))
        # lambda
        elif inner.startswith("func"):
            lm = re.match(r"func\s*\(", inner)
            if not lm:
                continue
            lam_inner, _ = balanced(inner, lm.end() - 1)
            args = split_args(lam_inner)
            total = len(args)
            required = sum(1 for a in args if "=" not in a)
            if not arity_ok(total, required, want):
                problems.append(
                    "%s:%d  %s.connect(func(...)) —— lambda 必填 %d / 共 %d 个参数，信号声明是 %d 个"
                    % (rel, line_of(m.start()), name, required, total, want))


def main():
    signals = collect_signals()
    # 同名信号参数个数不一致 → 提示（可能是两个不同信号共名）
    for name, table in sorted(signals.items()):
        counts = sorted(set(table.values()))
        if len(counts) > 1:
            where = "、".join("%s(%d)" % (f, c) for f, c in sorted(table.items()))
            print("提示：信号名 %s 在不同文件里参数个数不同：%s（两个不相干的信号重名了？）"
                  % (name, where))

    files = []
    for dirpath, _dirs, fns in os.walk(SCRIPT_DIR):
        for fn in fns:
            if fn.endswith(".gd"):
                files.append(os.path.join(dirpath, fn))
    # 测试目录也扫
    test_dir = os.path.join(ROOT, "test")
    for fn in os.listdir(test_dir):
        if fn.endswith(".gd"):
            files.append(os.path.join(test_dir, fn))

    for path in sorted(files):
        check_file(path, signals, os.path.relpath(path, ROOT).replace("\\", "/"))

    print("扫描 %d 个脚本，收集到 %d 个自定义信号" % (len(files), len(signals)))
    if problems:
        print("\n发现 %d 个参数不匹配：" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    print("信号参数个数全部匹配。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
