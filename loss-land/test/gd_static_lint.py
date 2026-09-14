#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GDScript 静态自检（无需 Godot 可执行文件）

用途
----
本机没有 Godot 二进制（游戏是经 Steam 装的，库不在本机），改完 .gd 后
无法跑 `godot --headless` 验证。这个脚本把"最容易踩、又最容易被眼睛漏掉"
的四类语法故障做成自动化检查——尤其是批量替换 print 之后：

  1. 缩进跳变     —— 某行比上一行多缩进 2 级以上。
                     真实事故：批量替换 print 时把 2 个 tab 写成 3 个 tab，
                     整份脚本解析失败 → 它的 class_name 注册不上 →
                     所有引用该类的文件连锁报 "Could not parse global class X"。
  2. 括号不平衡   —— ( ) / [ ] 数量对不上。
  3. 不可见空白   —— NBSP / 全角空格 / 零宽空格做缩进（肉眼完全看不出来）。
  4. 类名缓存不一致 —— 脚本里有 class_name，但 .godot/global_script_class_cache.cfg
                     里没有该条目（说明它解析失败，或被编辑器移除了）。
                     反向也报：缓存里的脚本文件已不存在。
  5. Vector2/Vector3 成员误用 —— 启发式类型追踪。真实事故：`var desired := p2`
                     （p2 是 Vector2）之后写了 `desired.z`，编译期报
                     `Cannot find member "z" in base "Vector2"`。
                     缩进/括号检查都抓不到，只能靠类型追踪。
  6. `:=` 类型推断失败 —— 右侧表达式类型是 Variant 时，Godot 报
                     `Cannot infer the type of "x" variable because the value
                     doesn't have a set type`，**整个脚本解析失败**
                     （不是警告）。真实事故：physics.gd 里
                     `var attack_dir := ...` 整份脚本编译不过 → 所有按钮点了
                     都没反应（黑屏级别的事故，但缩进/括号全是"正常"的）。
                     所以凡是 `:=` 右侧为 Variant 的写法都要显式标类型。

用法
----
    cd <项目根目录>
    python test/gd_static_lint.py

退出码 0 = 全部通过；1 = 发现问题。有问题的行会连同文件:行号一起打印。

已知误报
--------
用 `\\` 换行的多行条件（如 `if a and \\` 换行）会被当作缩进跳变——脚本已
针对行尾 `\\` 做了豁免；若仍有报告，先人工看一眼再判断。
"""

import io
import os
import re
import sys

STR_RE = re.compile(r'"(\\.|[^"\\])*"')


def strip_code(line: str) -> str:
    """去掉字符串与注释，返回纯代码部分。

    顺序很重要：必须**先摘字符串再切注释**。反过来的话，字符串里的颜色码
    （"#9aa0a6"）会被当成注释起点，把行尾切掉，导致括号计数错乱。
    """
    if line.lstrip().startswith("#"):
        return ""
    return STR_RE.sub('""', line).split("#", 1)[0]


def collect_scripts(root: str = "script"):
    out = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for f in filenames:
            if f.endswith(".gd"):
                out.append(os.path.join(dirpath, f).replace("\\", "/"))
    return sorted(out)


def check_indent(lines):
    """返回 [(行号, 说明)]：缩进层级跳跃（多缩进 2 级以上）。

    两类"缩进随意"的情况要豁免，否则全是误报：
      - 括号（或方括号/花括号）尚未闭合时的续行；
      - 上一行以 `\\` 结尾的显式续行。
    """
    bad = []
    depth = 0
    prev_indent = 0
    in_continuation = False
    for i, raw in enumerate(lines, 1):
        code = strip_code(raw)
        is_code = bool(raw.strip()) and not raw.lstrip().startswith("#")
        if depth == 0 and is_code and not in_continuation:
            indent = len(raw) - len(raw.lstrip("\t"))
            if indent > prev_indent + 1:
                bad.append((i, "缩进跳跃 +%d：%s" % (indent - prev_indent, raw.strip()[:60])))
            prev_indent = indent
        # 行尾反斜杠 = 显式续行，只豁免紧接的下一行
        in_continuation = code.rstrip().endswith("\\")
        depth += code.count("(") + code.count("[") + code.count("{")
        depth -= code.count(")") + code.count("]") + code.count("}")
        depth = max(depth, 0)
    return bad


def check_balance(text):
    """括号平衡。注释必须一起摘掉——注释里常出现单个括号（"返回：(true …"），
    只摘字符串的话会把它们算进去，报出一堆假的不平衡。"""
    s = STR_RE.sub('""', text)
    s = "\n".join(line.split("#", 1)[0] for line in s.split("\n"))
    return s.count("(") - s.count(")"), s.count("[") - s.count("]")


SUSPECT_SPACE = {
    0x00A0: "NBSP", 0x3000: "全角空格", 0x200B: "零宽空格", 0xFEFF: "BOM",
    0x2002: "EN SPACE", 0x2003: "EM SPACE", 0x2007: "FIGURE SPACE",
    0x2009: "THIN SPACE", 0x200A: "HAIR SPACE", 0x202F: "NARROW NBSP",
    0x205F: "MMSP",
}


def check_invisible(text):
    bad = []
    for i, line in enumerate(text.split("\n"), 1):
        for ch in line:
            if ord(ch) in SUSPECT_SPACE:
                bad.append((i, "%s (U+%04X)" % (SUSPECT_SPACE[ord(ch)], ord(ch))))
                break
    return bad


def check_class_cache(scripts, cache_path=".godot/global_script_class_cache.cfg"):
    """脚本声明的 class_name 必须都在缓存里；缓存里的路径必须真实存在。"""
    declared = {}
    for p in scripts:
        text = io.open(p, encoding="utf-8").read()
        m = re.search(r"^class_name\s+([A-Za-z_0-9]+)", text, re.M)
        if m:
            declared[m.group(1)] = p

    if not os.path.exists(cache_path):
        return ["缓存文件不存在：%s（用编辑器打开一次项目即可生成）" % cache_path], []

    cache = io.open(cache_path, encoding="utf-8", newline="").read()
    # 逐行扫描而不是跨行正则：30KB 的文件上用 .*? + DOTALL 会来回回溯到卡死。
    cached = {}
    cur = None
    for line in cache.split("\n"):
        m = re.match(r'\s*"class": &"([^"]+)"', line)
        if m:
            cur = m.group(1)
            continue
        m = re.match(r'\s*"path": "([^"]+)"', line)
        if m and cur:
            cached[cur] = m.group(1)
            cur = None

    missing = []
    for name, path in sorted(declared.items()):
        if name not in cached:
            missing.append("%s（%s）未登记 —— 该脚本可能解析失败" % (name, path))

    stale = []
    for name, path in sorted(cached.items()):
        rel = path.replace("res://", "")
        if rel.startswith("script/") and not os.path.exists(rel):
            stale.append("%s 指向已不存在的文件 %s" % (name, path))
    return missing, stale


IDENT_MEMBER_RE = re.compile(r"\b([A-Za-z_]\w*)\.(z|w)\b")
ATTR_PREFIX_RE = re.compile(r"^@\w+(\([^)]*\))?\s+")


def _literal_vec_type(expr: str):
    """表达式是不是 Vector2/Vector3 字面量。注意先判 Vector3——Vector2 的正则
    不会误吞 Vector3，但顺序写反容易看不清。Vector2i 也归入 Vector2（同样没有 .z）。"""
    e = expr.strip()
    if re.match(r"Vector3\b", e):
        return "Vector3"
    if re.match(r"Vector2i?\b", e):
        return "Vector2"
    return None


def _simple_ident(expr: str):
    """表达式是不是单个标识符（用于 var a := b 的类型传播）。"""
    e = expr.strip()
    return e if re.fullmatch(r"[A-Za-z_]\w*", e) else None


def _scan_vector_members(code: str, known: dict):
    """找 `标识符.z`（Vector2 没有 z）与 `标识符.w`（Vector3 没有 w）。"""
    hits = []
    for m in IDENT_MEMBER_RE.finditer(code):
        name, member = m.group(1), m.group(2)
        t = known.get(name)
        if t == "Vector2" and member == "z":
            hits.append(name)
        elif t == "Vector3" and member == "w":
            hits.append(name)
    return hits


def check_vector_members(text: str):
    """启发式 Vector2/Vector3 成员误用检查。

    真实事故：`var desired := p2`（p2 是 Vector2）之后写了 `desired.z`，
    编译期报 `Cannot find member "z" in base "Vector2"`。这类错误
    缩进/括号检查完全抓不到，只能靠类型追踪。

    做法很保守，只报「确凿」的：
      · 显式标注 `var v: Vector2`
      · 字面量 `var v := Vector2(...)` / `Vector3.ZERO`
      · 传播 `var a := b`（b 已知）
      · 函数参数 `func f(v: Vector2)`
    类型未知的标识符一律不报，所以基本没有误报。
    """
    bad = []
    file_types = {}
    local_types = {}
    for i, raw in enumerate(text.split("\n"), 1):
        code = strip_code(raw).strip()
        if not code:
            continue
        code_norm = ATTR_PREFIX_RE.sub("", code)
        is_top = (len(raw) - len(raw.lstrip("\t"))) == 0

        known = dict(file_types)
        known.update(local_types)

        # 1. 先用「当前已知类型」检查本行的成员访问
        for name in _scan_vector_members(code_norm, known):
            bad.append((i, "Vector2 没有 .z：%s（本行：%s）" % (name, code_norm[:60])))

        # 2. 再更新类型表
        fm = re.match(r"(?:static\s+)?func\s+[A-Za-z_]\w*\s*\((.*?)\)", code_norm)
        if fm:
            if is_top:
                local_types = {}
            for part in fm.group(1).split(","):
                pm = re.match(r"\s*([A-Za-z_]\w*)\s*:\s*(Vector2i?|Vector3)\b", part)
                if pm:
                    t = "Vector2" if pm.group(2).startswith("Vector2") else "Vector3"
                    local_types[pm.group(1)] = t
            continue

        dm = re.match(r"(?:static\s+)?var\s+([A-Za-z_]\w*)\s*:\s*(Vector2i?|Vector3)\b", code_norm)
        if dm:
            t = "Vector2" if dm.group(2).startswith("Vector2") else "Vector3"
            (file_types if is_top else local_types)[dm.group(1)] = t
            continue

        im = re.match(r"(?:static\s+)?var\s+([A-Za-z_]\w*)\s*:=\s*(.+)$", code_norm)
        if im:
            name, expr = im.group(1), im.group(2)
            t = _literal_vec_type(expr)
            if t is None:
                ident = _simple_ident(expr)
                if ident:
                    t = known.get(ident)
            if t:
                (file_types if is_top else local_types)[name] = t
    return bad


FUNC_DEF_RE = re.compile(
    r"^(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\((.*?)\)\s*(->[^:\n]*)?\s*:")
VAR_INFER_RE = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)?var\s+([A-Za-z_]\w*)\s*:=\s*(.+?)\s*$")
## 返回 Variant 的内置 API（`:=` 直接接它们必然推断失败）
## 只列**确认返回 Variant** 的；FileAccess.open() 之类有明确返回类型的不要放进来，
## 否则是误报——误报会让人开始无视这个检查。
VARIANT_BUILTINS = re.compile(
    r"^(?:ProjectSettings\.get_setting\w*"
    r"|JSON\.parse\w*"
    r"|ConfigFile\.get_value"
    r"|FileAccess\.get_var"
    r"|Object\.(?:get|call))")


def _collect_func_returns(scripts):
    """扫全项目函数定义，分出「有返回类型标注」与「没有的」。

    为什么必须跨文件收集：`:=` 右侧调用别处的 `func foo():`（无 `-> 类型`）
    同样推断失败，只看本文件会漏。
    """
    typed, untyped = set(), {}
    for p in scripts:
        for i, raw in enumerate(io.open(p, encoding="utf-8").read().split("\n"), 1):
            m = FUNC_DEF_RE.match(strip_code(raw).strip())
            if not m:
                continue
            name, ret = m.group(1), m.group(3)
            if ret:
                typed.add(name)
            else:
                untyped.setdefault(name, (p, i))
    return typed, untyped


def _outermost_callee(expr: str):
    """整个表达式是不是一层调用 `a.b(...)`；是则返回被调用者字面量。

    只认"最外层"：`Time.get_ticks_msec()` -> "Time.get_ticks_msec"；
    `int(x.get(0))` -> "int"（外层构造函数有类型，不算问题）；
    非调用式（字面量/标识符/二元运算）-> None。
    """
    e = expr.strip()
    if not e.endswith(")"):
        return None
    depth = 0
    for i in range(len(e) - 1, -1, -1):
        ch = e[i]
        if ch == ")":
            depth += 1
        elif ch == "(":
            depth -= 1
            if depth == 0:
                head = e[:i].strip()
                return head or None
    return None


def check_type_inference(scripts):
    """找 `var x := <Variant 表达式>`。

    只报三类确凿的（宁可漏，不可误报——误报会让人开始无视这个检查）：
      · 右侧最外层是 `.get(...)` / `.call(...)`（Dictionary/Object 取成员，返回 Variant）
      · 右侧最外层是已知返回 Variant 的内置 API（ProjectSettings.get_setting 等）
      · 右侧最外层调用的是**项目内没有返回类型标注**的函数
    显式标了类型（`var x: Vector3 = ...`）的不算问题——那是运行时转换，能编译。
    """
    typed, untyped = _collect_func_returns(scripts)
    bad = []
    for p in scripts:
        for i, raw in enumerate(io.open(p, encoding="utf-8").read().split("\n"), 1):
            code = strip_code(raw).strip()
            m = VAR_INFER_RE.match(code)
            if not m:
                continue
            name, expr = m.group(1), m.group(2)
            callee = _outermost_callee(expr)
            if callee is None:
                continue
            where = ""
            if callee.endswith(".get") or callee.endswith(".call"):
                where = "%s 返回 Variant（Dictionary/Object 取成员）" % callee
            elif VARIANT_BUILTINS.match(callee):
                where = "%s 返回 Variant" % callee
            else:
                tail = callee.split(".")[-1]
                if tail in untyped and tail not in typed:
                    defp, defl = untyped[tail]
                    where = "项目内函数 %s() 没写返回类型（定义于 %s:%d）" % (tail, defp, defl)
            if where:
                bad.append((p, i, "var %s := %s  —— %s，改成 `var %s: <类型> = ...`"
                            % (name, expr[:56], where, name)))
    return bad


def main():
    cwd = os.getcwd()
    if not os.path.isdir(os.path.join(cwd, "script")):
        print("请在项目根目录（含 script/ 的那一层）运行。当前目录：%s" % cwd)
        return 2

    scripts = collect_scripts()
    problems = 0

    print("扫描 %d 个脚本……" % len(scripts))

    print("\n[1/6] 缩进跳变")
    before = problems
    for p in scripts:
        text = io.open(p, encoding="utf-8").read()
        bad = check_indent(text.split("\n"))
        for lineno, msg in bad:
            print("  %s:%d  %s" % (p, lineno, msg))
            problems += 1
    if problems == before:
        print("  OK")

    before = problems
    print("\n[2/6] 括号平衡")
    for p in scripts:
        text = io.open(p, encoding="utf-8").read()
        d1, d2 = check_balance(text)
        if d1 or d2:
            print("  %s  () 差 %d，[] 差 %d" % (p, d1, d2))
            problems += 1
    if problems == before:
        print("  OK")

    before = problems
    print("\n[3/6] 不可见空白字符")
    for p in scripts:
        text = io.open(p, encoding="utf-8").read()
        for lineno, what in check_invisible(text):
            print("  %s:%d  %s" % (p, lineno, what))
            problems += 1
    if problems == before:
        print("  OK")

    before = problems
    print("\n[4/6] class_name 缓存一致性")
    missing, stale = check_class_cache(scripts)
    for m in missing:
        print("  缺失：%s" % m)
        problems += 1
    for s in stale:
        print("  过期：%s" % s)
        problems += 1
    if problems == before:
        print("  OK")

    before = problems
    print("\n[5/6] Vector2/Vector3 成员误用")
    for p in scripts:
        text = io.open(p, encoding="utf-8").read()
        for lineno, msg in check_vector_members(text):
            print("  %s:%d  %s" % (p, lineno, msg))
            problems += 1
    if problems == before:
        print("  OK")

    before = problems
    print("\n[6/6] := 类型推断（右侧为 Variant 会让整个脚本解析失败）")
    for p, lineno, msg in check_type_inference(scripts):
        print("  %s:%d  %s" % (p, lineno, msg))
        problems += 1
    if problems == before:
        print("  OK")

    print("\n" + ("全部通过。" if problems == 0 else "发现 %d 个问题。" % problems))
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
