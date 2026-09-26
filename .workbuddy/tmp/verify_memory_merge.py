#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 MEMORY-archive.md：逐个 section 解包后与源文件逐字节比对。"""
import os

MEM_DIR = r"E:\GameMake\loss\.workbuddy\memory"
ARCHIVE = os.path.join(MEM_DIR, "MEMORY-archive.md")

SOURCES = [
    "MEMORY.md", "MEMORY-details.md", "MEMORY.md.2026-09-18-full.bak",
    "2026-09-08.md", "2026-09-09.md", "2026-09-10.md", "2026-09-11.md",
    "2026-09-12.md", "2026-09-13.md", "2026-09-14.md", "2026-09-15.md",
    "2026-09-16.md", "2026-09-18.md", "2026-09-22.md", "2026-09-23.md",
    "2026-09-24.md", "2026-09-25.md", "2026-09-26.md",
]

with open(ARCHIVE, "r", encoding="utf-8") as fh:
    text = fh.read()

ok = 0
bad = []
for name in SOURCES:
    with open(os.path.join(MEM_DIR, name), "r", encoding="utf-8") as fh:
        src = fh.read().rstrip("\n")
    begin = "<!-- BEGIN SRC:%s -->\n" % name
    end = "\n<!-- END SRC:%s -->" % name
    start = text.find(begin)
    if start < 0:
        bad.append((name, "找不到起始哨兵"))
        continue
    stop = text.find(end, start)
    if stop < 0:
        bad.append((name, "找不到结束哨兵"))
        continue
    body = text[start + len(begin):stop]
    if body == src:
        ok += 1
    else:
        bad.append((name, "内容不一致：源 %d 字符 / 归档 %d 字符" % (len(src), len(body))))

print("逐字节一致：%d / %d" % (ok, len(SOURCES)))
if bad:
    print("!!! 不一致清单：")
    for n_, why in bad:
        print("   - %s: %s" % (n_, why))
else:
    print("全部 18 份原文完整无损。")
