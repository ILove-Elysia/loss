# test/fix_import_paths.py
# ============================================
# 同步 .import 里的 source_file 与图片实际位置
#
# 为什么需要它：
#   批量移动美术文件后，.png 和 .png.import 会一起被搬走，但 .import 文件里
#   第 13 行的 source_file="res://旧路径" 还写着老路径。Godot 打开工程时发现
#   source_file 对不上实际位置，会把这张图当成新资源重新导入一遍。
#   一两张无所谓，1244 张就是一次几百 MB 的无效重导入。
#
#   Godot 自己也能修正，但只在编辑器完整扫描后。批量整理目录后先跑一遍这个
#   脚本，可以省掉那次全量重导入。
#
# 用法：python test/fix_import_paths.py
#       python test/fix_import_paths.py --dry-run   # 只报告不修改
# ============================================

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "art")
DRY = "--dry-run" in sys.argv

fixed = []
already_ok = 0
broken = []

for dirpath, _dirnames, filenames in os.walk(ART):
	for fn in filenames:
		if not fn.endswith(".import"):
			continue
		image = os.path.join(dirpath, fn[: -len(".import")])
		import_file = os.path.join(dirpath, fn)
		if not os.path.exists(image):
			broken.append(import_file)
			continue
		with open(import_file, "r", encoding="utf-8", newline="") as f:
			text = f.read()
		m = re.search(r'^source_file="([^"]*)"', text, re.M)
		if not m:
			broken.append(import_file)
			continue
		expect = "res://" + os.path.relpath(image, ROOT).replace("\\", "/")
		if m.group(1) == expect:
			already_ok += 1
			continue
		if not DRY:
			text = text[: m.start(1)] + expect + text[m.end(1):]
			with open(import_file, "w", encoding="utf-8", newline="") as f:
				f.write(text)
		fixed.append((m.group(1), expect))


print("art/ 下 .import 文件统计")
print("  路径已正确: %d" % already_ok)
print("  需要修正:   %d" % len(fixed))
if DRY:
	print("  (--dry-run 模式，未写入)")
if fixed:
	print("\n--- 修正明细（前 10 条）---")
	for old, new in fixed[:10]:
		print("  %s\n    -> %s" % (old, new))
if broken:
	print("\n--- 异常：找不到对应图片或缺少 source_file (%d) ---" % len(broken))
	for b in broken[:20]:
		print("  " + os.path.relpath(b, ROOT).replace("\\", "/"))
	sys.exit(1)
print("\n.import 路径同步完成")
