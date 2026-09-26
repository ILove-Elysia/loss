#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 .workbuddy/memory/ 下全部记忆文件合并成一份全量归档 MEMORY-archive.md。

只读源文件、只写目标归档文件，不删除任何东西（删除由调用方另行执行）。
"""
import os
import sys
from datetime import datetime

MEM_DIR = r"E:\GameMake\loss\.workbuddy\memory"
OUT = os.path.join(MEM_DIR, "MEMORY-archive.md")

# (显示标题, 文件名, 分区说明)
PART_A = [("现行入口原文快照", "MEMORY.md")]
PART_B = [("细节详章", "MEMORY-details.md")]
PART_C = [("历史全文备份（2026-09-18 拆分前的 MEMORY.md）", "MEMORY.md.2026-09-18-full.bak")]
DAILY = [
    "2026-09-08.md", "2026-09-09.md", "2026-09-10.md", "2026-09-11.md",
    "2026-09-12.md", "2026-09-13.md", "2026-09-14.md", "2026-09-15.md",
    "2026-09-16.md", "2026-09-18.md", "2026-09-22.md", "2026-09-23.md",
    "2026-09-24.md", "2026-09-25.md", "2026-09-26.md",
]

toc_lines = []
parts = []
n = 0


def add_section(title, fname, tag):
    global n
    path = os.path.join(MEM_DIR, fname)
    if not os.path.isfile(path):
        print("[WARN] missing: %s" % fname)
        return
    with open(path, "r", encoding="utf-8") as fh:
        body = fh.read()
    n += 1
    sec_id = "S%02d" % n
    size = os.path.getsize(path)
    mtime = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M")
    toc_lines.append("- [%s %s](#%s) — `%s`（%d B，改于 %s）" % (sec_id, title, sec_id.lower(), fname, size, mtime))
    parts.append(
        "\n\n---\n\n"
        '<a id="%s"></a>\n'
        "## %s · %s\n\n"
        "> 来源：`%s` ｜ %d B ｜ 最后修改 %s\n\n"
        "<!-- BEGIN SRC:%s -->\n%s\n<!-- END SRC:%s -->\n"
        % (sec_id.lower(), sec_id, title, fname, size, mtime, fname, body.rstrip("\n"), fname)
    )
    print("  + %s %s (%d B)" % (sec_id, fname, size))


add_section_banner = ""

for title, fname in PART_A:
    add_section(title, fname, "A")
for title, fname in PART_B:
    add_section(title, fname, "B")
for title, fname in PART_C:
    add_section(title, fname, "C")
toc_lines.append("")
toc_lines.append("### 每日工作日志（按时间正序）")
toc_lines.append("")
for fname in DAILY:
    add_section(fname.replace(".md", ""), fname, "D")

header = (
    "# loss-land 项目记忆 · 全量归档\n\n"
    "> **本文件是合并后的唯一全量存档，不参与每轮自动注入。**\n"
    "> 入口（每轮注入的高频铁律）＝同目录 `MEMORY.md`；需要查过程细节、历史决策、\n"
    "> 踩坑记录时，在本文件里检索。\n"
    ">\n"
    "> 合并时间：%s ｜ 收录 %d 个源文件 ｜ 源文件已备份于\n"
    "> `.workbuddy/archive/memory_backup_2026-09-26/`\n\n"
    "## 目录\n\n%s\n"
) % (datetime.now().strftime("%Y-%m-%d %H:%M"), n, "\n".join(toc_lines))

with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(header)
    fh.write("".join(parts))

print("")
print("合并完成：%s" % OUT)
print("收录 %d 个源文件，输出 %d B" % (n, os.path.getsize(OUT)))
