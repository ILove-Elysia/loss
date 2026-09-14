# test/check_data_refs.py
# ============================================
# 数据引用校验 - 抓"引用了不存在的东西"这类跨文件错误
#
# 为什么需要它：
#   gd_static_lint.py 只看 .gd 的语法层面，看不出
#   "配方要合成 iron_sword，但 item_registry.tres 里根本没登记这件物品"
#   或者"资源掉落 drop_item_id = coal，但物品表里没有 coal"。
#   这类错误在 Godot 里要到运行时点开合成界面才会爆，本机又没有 Godot 二进制，
#   所以在新增 .tres / 配方后必须跑一遍这个脚本。
#
# 检查项：
#   1. 所有 .tres 里 ext_resource 指向的文件是否存在
#   2. item_registry.tres 登记的每个物品 .tres 是否存在、item_id 是否与文件名一致
#   3. 每个 item .tres 的 icon 文件是否存在
#   4. crafting_system.gd 里 _add 的产物、_mat 的材料是否都在物品表里
#   5. resource_registry.tres 里的资源是否都有 resource_id 且掉落物在物品表里
#   6. task_system.gd 的 REGION_RESOURCE_MAP 里出现的资源 id 是否都已注册
#
# 用法：python test/check_data_refs.py
# ============================================

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

errors = []
warnings = []


def rel(path: str) -> str:
	return os.path.relpath(path, ROOT).replace("\\", "/")


def read(path: str) -> str:
	with open(path, "r", encoding="utf-8") as f:
		return f.read()


def res_to_abs(res_path: str) -> str:
	# res://xxx -> 项目根下的实际路径
	return os.path.join(ROOT, res_path[len("res://"):].replace("/", os.sep))


def find_tres(*dirs: str):
	out = []
	for d in dirs:
		base = os.path.join(ROOT, d)
		for dirpath, _dirnames, filenames in os.walk(base):
			if ".godot" in dirpath:
				continue
			for fn in filenames:
				if fn.endswith(".tres"):
					out.append(os.path.join(dirpath, fn))
	return out


# ---- 1. 所有 tres 的 ext_resource 是否存在 ----
tres_files = find_tres("script", "tscn")
for path in tres_files:
	text = read(path)
	for m in re.finditer(r'\[ext_resource[^\]]*path="(res://[^"]+)"', text):
		target = res_to_abs(m.group(1))
		if not os.path.exists(target):
			errors.append("%s: ext_resource 指向的文件不存在 -> %s" % (rel(path), m.group(1)))


# ---- 2/3. 物品表 ----
registry_path = os.path.join(ROOT, "script", "items", "data", "item_registry.tres")
registry_text = read(registry_path)
item_files = re.findall(r'path="(res://script/items/data/[^"]+_item\.tres)"', registry_text)
registered_items = {}
for res_path in item_files:
	abs_path = res_to_abs(res_path)
	if not os.path.exists(abs_path):
		errors.append("item_registry.tres: 登记了不存在的物品 %s" % res_path)
		continue
	text = read(abs_path)
	m = re.search(r'item_id\s*=\s*&"([^"]+)"', text)
	if not m:
		errors.append("%s: 缺少 item_id" % rel(abs_path))
		continue
	item_id = m.group(1)
	registered_items[item_id] = abs_path
	# item_id 与文件名一致（约定）
	fname = os.path.basename(abs_path).replace("_item.tres", "")
	if item_id != fname:
		warnings.append("%s: item_id(%s) 与文件名(%s) 不一致" % (rel(abs_path), item_id, fname))
	# icon 必须存在
	im = re.search(r'\[ext_resource type="Texture2D"[^\]]*path="(res://[^"]+)"', text)
	if im:
		if not os.path.exists(res_to_abs(im.group(1))):
			errors.append("%s: 图标不存在 -> %s" % (rel(abs_path), im.group(1)))
	else:
		warnings.append("%s: 没有配置 icon" % rel(abs_path))

# item_registry 数组里引用的 ExtResource id 是否都声明过
declared_ids = set(re.findall(r'\[ext_resource[^\]]*id="([^"]+)"', registry_text))
used_ids = re.findall(r'ExtResource\("([^"]+)"\)', registry_text)
for uid in used_ids:
	if uid not in declared_ids:
		errors.append("item_registry.tres: 引用了未声明的 ExtResource(\"%s\")" % uid)


# ---- 4. 配方引用的物品 ----
craft_path = os.path.join(ROOT, "script", "crafting", "crafting_system.gd")
craft_text = read(craft_path)
for m in re.finditer(r'_add\(&"([^"]+)"\s*,\s*&"([^"]+)"', craft_text):
	output = m.group(2)
	if output not in registered_items:
		errors.append("crafting_system.gd: 配方产物 %s 未登记在物品表" % output)
for m in re.finditer(r'_mat\(&"([^"]+)"', craft_text):
	material = m.group(1)
	if material not in registered_items:
		errors.append("crafting_system.gd: 配方材料 %s 未登记在物品表" % material)

# 配方产物 / 材料与 stations 的一致性
for m in re.finditer(r'_add\(&"[^"]+"\s*,\s*&"[^"]+"[^)]*?,\s*&"([a-z_]+)"\)', craft_text, re.S):
	station = m.group(1)
	if station not in ("workbench", "furnace"):
		warnings.append("crafting_system.gd: 未知制作站 %s" % station)


# ---- 5. 资源表 ----
res_reg_path = os.path.join(ROOT, "script", "resources", "data", "resource_registry.tres")
res_reg_text = read(res_reg_path)
data_files = re.findall(r'path="(res://script/resources/data/[^"]+_data\.tres)"', res_reg_text)
resource_ids = set()
for res_path in data_files:
	abs_path = res_to_abs(res_path)
	if not os.path.exists(abs_path):
		errors.append("resource_registry.tres: 登记了不存在的资源数据 %s" % res_path)
		continue
	text = read(abs_path)
	m = re.search(r'resource_id\s*=\s*"([^"]+)"', text)
	if not m:
		errors.append("%s: 缺少 resource_id" % rel(abs_path))
		continue
	resource_ids.add(m.group(1))
	dm = re.search(r'drop_item_id\s*=\s*"([^"]+)"', text)
	if dm and dm.group(1) not in registered_items:
		errors.append("%s: drop_item_id(%s) 未登记在物品表" % (rel(abs_path), dm.group(1)))

# resource_scenes 字典的键要和 resource_ids 对得上
# 键有两种写法：Godot 自己保存的 StringName 键是 &"coal"，手写的是 "coal"
scene_keys = set(re.findall(r'^&?"([a-z_]+)":\s*ExtResource', res_reg_text, re.M))
if not scene_keys:
	errors.append("resource_registry.tres: 没解析到 resource_scenes 的键（格式变了？）")
for rid in resource_ids:
	if rid not in scene_keys:
		errors.append("resource_registry.tres: 资源 %s 没有配置预制体" % rid)
for key in scene_keys:
	if key not in resource_ids:
		warnings.append("resource_registry.tres: 预制体键 %s 没有对应的资源数据" % key)


# ---- 6. 区域资源映射 ----
# 大纲里规划、但尚未实装成 ResourceData 的资源。放在这里避免误报：
# 它们出现在 REGION_RESOURCE_MAP 里不会导致运行时错误（该映射只是"允许名单"，
# 没有实体去请求就不会被查到）。
PLANNED_UNIMPLEMENTED = {"flower"}

task_path = os.path.join(ROOT, "script", "map", "task_system.gd")
task_text = read(task_path)
m = re.search(r'REGION_RESOURCE_MAP\s*:?\s*Dictionary\s*=\s*\{(.*?)\n\}', task_text, re.S)
if not m:
	warnings.append("task_system.gd: 没解析到 REGION_RESOURCE_MAP")
else:
	seen_regions = set()
	for rm in re.finditer(r'"([a-z_]+)"', m.group(1)):
		rid = rm.group(1)
		if not rid.islower() or rid in seen_regions:
			continue
		seen_regions.add(rid)
		if rid in resource_ids:
			continue
		if rid in PLANNED_UNIMPLEMENTED:
			warnings.append("task_system.gd: 资源 %s 在映射表里但尚未实装（规划中）" % rid)
		else:
			errors.append("task_system.gd: REGION_RESOURCE_MAP 里的资源 %s 未在 resource_registry 注册" % rid)


# ---- 7. 出生点测试箱的物品清单 ----
# map_generator_3d.gd 的 _TEST_BOX_CONTENTS 是手写字典，
# id 写错不会报错，只会"箱子里少一件东西"，很难发现。
box_path = os.path.join(ROOT, "script", "map", "map_generator_3d.gd")
box_text = read(box_path)
m = re.search(r'_TEST_BOX_CONTENTS\s*:?=\s*\{(.*?)\n\}', box_text, re.S)
if not m:
	warnings.append("map_generator_3d.gd: 没解析到 _TEST_BOX_CONTENTS")
else:
	for bm in re.finditer(r'&"([a-z_]+)"\s*:\s*(\d+)', m.group(1)):
		iid, count = bm.group(1), int(bm.group(2))
		if iid not in registered_items:
			errors.append("map_generator_3d.gd: 测试箱物品 %s 未登记在物品表" % iid)
		elif count <= 0:
			errors.append("map_generator_3d.gd: 测试箱物品 %s 数量非法(%d)" % (iid, count))


# ---- 输出 ----
print("检查了 %d 个 .tres 文件" % len(tres_files))
print("物品 %d 件、资源 %d 种" % (len(registered_items), len(resource_ids)))
if warnings:
	print("\n--- 警告 (%d) ---" % len(warnings))
	for w in warnings:
		print("  [warn] " + w)
if errors:
	print("\n--- 错误 (%d) ---" % len(errors))
	for e in errors:
		print("  [ERROR] " + e)
	sys.exit(1)
print("\n数据引用检查通过")
