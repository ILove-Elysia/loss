# -*- coding: utf-8 -*-
"""
查找工程内"未被引用"的文件（孤岛）。

判定逻辑：
  1. 收集全工程的 res:// 字面量引用（.tscn/.tres/.res/.gd/.godot/.cfg 等）
  2. 收集 uid:// 引用，经 .import / .uid / 资源头部的 uid 映射回文件路径
  3. .gd 若声明了 class_name，且该名字在别处被使用，视为被引用（核心系统走 class_name + static）
  4. .import / .uid 属于源文件的附属文件，随源文件判定
  5. 不含 res:// 的文件（.md 文档、.py 测试脚本等）不参与孤岛判定

不扫描：.godot / .git / .vscode，以及任何自带 project.godot 的嵌套独立工程。
不把 .md 文档里的路径当作"引用"——文档提到不等于代码在用。

用法：
    python test/find_orphans.py            # 汇总
    python test/find_orphans.py --list     # 附上孤岛明细
"""

import io
import os
import re
import sys
import unicodedata
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SKIP_DIRS = {".godot", ".git", ".vscode", ".workbuddy", "node_modules"}

# 参与"引用提取"的扩展名（文档类刻意排除：文档提到路径 ≠ 代码在用）
REF_EXTS = {".tscn", ".tres", ".res", ".gd", ".godot", ".cfg", ".import_cfg"}
# 资源本身可被引用的扩展名（孤岛判定的候选池）
ASSET_EXTS = {
    ".png", ".jpg", ".jpeg", ".svg", ".webp", ".bmp", ".tga", ".exr", ".hdr",
    ".res", ".tres", ".tscn", ".gd", ".gdshader", ".shader", ".ttf", ".otf",
    ".wav", ".ogg", ".mp3", ".glb", ".gltf", ".obj", ".fbx", ".aseprite",
    ".csv", ".json", ".tres2",
}
# 附属文件：不独立判定，随其源文件
SIDECAR_SUFFIXES = (".import", ".uid")

RES_RE = re.compile(r"res://[A-Za-z0-9_/.\-\u4e00-\u9fff\u3000-\u303f\uff00-\uffef ]+")
UID_RE = re.compile(r"uid://[a-z0-9]+")
CLASSNAME_RE = re.compile(r"^class_name\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


def read_text(path):
    try:
        with io.open(path, "rb") as f:
            return f.read().decode("latin-1")
    except OSError:
        return ""


def to_rel(abs_path):
    return os.path.relpath(abs_path, ROOT).replace("\\", "/")


def res_to_abs(ref):
    return os.path.normpath(os.path.join(ROOT, ref[len("res://"):].replace("/", os.sep)))


def walk_project():
    """产出 (绝对路径) —— 跳过隐藏/缓存目录与嵌套独立工程。"""
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for fn in filenames:
            yield os.path.join(dirpath, fn)
        # os.walk 是先 yield 文件再进子目录，嵌套工程判定放在进入前
        if dirpath != ROOT and "project.godot" in filenames:
            dirnames[:] = []
            continue
        # 避免进入嵌套工程：提前检查子目录
        keep = []
        for d in dirnames:
            child = os.path.join(dirpath, d)
            if os.path.exists(os.path.join(child, "project.godot")):
                continue
            keep.append(d)
        dirnames[:] = keep


def display_width(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)


def pad(s, w):
    return s + " " * max(0, w - display_width(s))


def main():
    show_list = "--list" in sys.argv

    all_files = list(walk_project())
    disk_paths = set(all_files)

    # ---------- 1. 建 uid -> 路径 映射 ----------
    uid_map = {}
    for p in all_files:
        rel = to_rel(p)
        ext = os.path.splitext(p)[1].lower()
        if ext == ".import":
            txt = read_text(p)
            m = re.search(r'uid="(uid://[a-z0-9]+)"', txt)
            src = re.search(r'source_file="(res://[^"]+)"', txt)
            if m and src:
                uid_map[m.group(1)] = res_to_abs(src.group(1))
        elif ext == ".uid":
            uid = read_text(p).strip()
            if uid.startswith("uid://"):
                uid_map[uid] = p[: -len(".uid")]
        elif ext in (".tres", ".tscn"):
            head = read_text(p)[:400]
            m = re.search(r'uid="(uid://[a-z0-9]+)"', head)
            if m:
                uid_map[m.group(1)] = p

    # ---------- 2. 提取引用 ----------
    refs = set()          # 被引用的绝对路径
    unresolved = set()    # 解析不到的 res:// / uid://
    ref_files = 0

    for p in all_files:
        ext = os.path.splitext(p)[1].lower()
        if ext in SIDECAR_SUFFIXES or ext not in REF_EXTS:
            continue
        ref_files += 1
        txt = read_text(p)

        for raw in RES_RE.findall(txt):
            ref = raw.rstrip(" .")
            ap = res_to_abs(ref)
            if os.path.exists(ap):
                refs.add(ap)
            elif not ref.startswith("res://.godot/"):
                unresolved.add(ref)

        for uid in UID_RE.findall(txt):
            tgt = uid_map.get(uid)
            if tgt is None:
                unresolved.add(uid)
            elif tgt != p:
                # 排除"自引用"：.tres/.tscn 会在文件头声明自己的 uid，
                # 若把这条也算引用，则任何场景/资源都永远不是孤岛 —— 会漏报。
                refs.add(tgt)

    # ---------- 3. class_name 视为被引用 ----------
    class_owner = {}   # class_name -> 路径
    for p in all_files:
        if p.endswith(".gd"):
            m = CLASSNAME_RE.search(read_text(p))
            if m:
                class_owner[m.group(1)] = p

    # 汇总全工程文本，用于判断 class_name 是否被别处使用
    corpus_by_path = {}
    for p in all_files:
        ext = os.path.splitext(p)[1].lower()
        if ext in (".gd", ".tscn", ".tres"):
            corpus_by_path[p] = read_text(p)

    for cname, owner in class_owner.items():
        for p, txt in corpus_by_path.items():
            if p == owner:
                continue
            if re.search(r"\b" + re.escape(cname) + r"\b", txt):
                refs.add(owner)
                break

    # ---------- 4. 附属文件随源文件 ----------
    for p in all_files:
        if p.endswith(".import"):
            src = p[: -len(".import")]
            if src in refs:
                refs.add(p)
        elif p.endswith(".uid"):
            src = p[: -len(".uid")]
            if src in refs:
                refs.add(p)

    # ---------- 5. 求孤岛 ----------
    orphans = [p for p in all_files if p not in refs]

    def bucket(rel):
        seg = rel.split("/")
        top = seg[0]
        if rel.startswith("art/_source/"):
            return "A  第三方原始素材包  art/_source/"
        if rel.startswith("art/_deprecated/"):
            return "B  废弃资产  art/_deprecated/"
        if top == "addons":
            return "C  插件  addons/"
        if top == "godot_state_charts_examples":
            return "D  插件示例工程  godot_state_charts_examples/"
        if top in ("Godot", "NVIDIA Corporation"):
            return "E  运行时残留  Godot/ NVIDIA Corporation/"
        if top == "test":
            return "F  测试工程  test/"
        if top == "记忆":
            return "G  文档 记忆/"
        if rel.startswith("art/"):
            return "H  生产资产  art/（非 _source）"
        if top == "script":
            return "I  脚本  script/"
        if top == "tscn":
            return "J  场景  tscn/"
        if rel.endswith(".md"):
            return "K  文档  *.md"
        return "Z  其他"

    groups = defaultdict(list)
    for p in orphans:
        groups[bucket(to_rel(p))].append(p)

    def size_of(paths):
        return sum(os.path.getsize(p) for p in paths if os.path.exists(p))

    print("=" * 78)
    print("孤岛扫描：扫描 %d 个文件，其中 %d 个参与引用提取" % (len(all_files), ref_files))
    print("解析成功引用 %d 条" % len(refs))
    if unresolved:
        print("未解析引用 %d 条（下面单独列出，多为 .godot 缓存或历史遗留）" % len(unresolved))
    print("=" * 78)
    print()
    print(pad("分类", 40) + pad("文件数", 9) + "体积")
    print("-" * 78)
    total_n = total_s = 0
    for k in sorted(groups):
        n = len(groups[k])
        s = size_of(groups[k])
        total_n += n
        total_s += s
        print(pad(k, 40) + pad(str(n), 9) + ("%.1f MB" % (s / 1048576.0)))
    print("-" * 78)
    print(pad("合计", 40) + pad(str(total_n), 9) + ("%.1f MB" % (total_s / 1048576.0)))
    print()

    if unresolved:
        print("--- 未解析的引用（需人工确认）---")
        for r in sorted(unresolved)[:30]:
            print("  " + r)
        if len(unresolved) > 30:
            print("  ... 另有 %d 条" % (len(unresolved) - 30))
        print()

    if show_list:
        for k in sorted(groups):
            print("### " + k + "  (%d)" % len(groups[k]))
            for p in sorted(groups[k]):
                print("  " + to_rel(p))
            print()


if __name__ == "__main__":
    main()
