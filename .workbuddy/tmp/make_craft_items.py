"""一次性脚本：为三个角色的专属制作栏生成 6 件占位物品，并注册进 item_registry.tres。

用法：python .workbuddy/tmp/make_craft_items.py   （cwd = loss-land）
幂等：物品文件已存在则跳过；注册表已含该 ext_resource 则跳过。
"""
import os
import re

ROOT = os.getcwd()
DATA = os.path.join(ROOT, "script", "items", "data")

ITEMS = [
    dict(
        file="herb_bandage_item.tres", item_id="herb_bandage", name="草药绷带",
        icon="grass", item_type=5, max_stack=20, effect="+25_health",
        desc="嚼碎的草药与草茎缠成的简陋绷带。右键使用：立即回复 25 点生命。来源：冒险家专属「求生」制作栏。",
        buy=8, sell=3,
    ),
    dict(
        file="trail_ration_item.tres", item_id="trail_ration", name="干粮",
        icon="berry", item_type=2, max_stack=20, effect="+40_food +15_health",
        desc="浆果与草茎压成的应急干粮。右键使用：回复 40 点饱食度与 15 点生命（饱食度已满时吃不下）。来源：冒险家专属「求生」制作栏。",
        buy=10, sell=4,
    ),
    dict(
        file="healing_potion_item.tres", item_id="healing_potion", name="治疗药剂",
        icon="berry", item_type=5, max_stack=10, effect="+50_health",
        desc="黏稠的红色药水，入口是铁锈与浆果的味道。右键使用：立即回复 50 点生命。来源：魔女专属「炼药」制作栏。",
        buy=18, sell=7,
    ),
    dict(
        file="vigor_draught_item.tres", item_id="vigor_draught", name="活力药剂",
        icon="slime_gel", item_type=2, max_stack=10, effect="+60_food +20_health",
        desc="喝下去浑身发热的绿色浊液。右键使用：回复 60 点饱食度与 20 点生命（饱食度已满时吃不下）。来源：魔女专属「炼药」制作栏。",
        buy=16, sell=6,
    ),
    dict(
        file="power_cell_item.tres", item_id="power_cell", name="高容量电芯",
        icon="battery", item_type=3, max_stack=20, effect="+60_power",
        desc="两块电池并联、再用铁壳箍紧的能量包。右键使用：立即回复 60 点电量（只有带电量系统的角色用得上）。来源：机器人专属「机械」制作栏。",
        buy=25, sell=10,
    ),
    dict(
        file="repair_kit_item.tres", item_id="repair_kit", name="维修包",
        icon="workbench", item_type=5, max_stack=10, effect="+40_health",
        desc="铁片、木楔与一整套自检工具。右键使用：修补外壳与关节，回复 40 点生命。来源：机器人专属「机械」制作栏。",
        buy=20, sell=8,
    ),
]

SCRIPT_UID = "uid://cg1a0jbuu3lyo"

TEMPLATE = """[gd_resource type="Resource" script_class="ItemData" format=3]

[ext_resource type="Script" uid="{uid}" path="res://script/items/data/item_data.gd" id="1_br"]
[ext_resource type="Texture2D" path="res://art/icons/{icon}.png" id="2_icon"]

[resource]
script = ExtResource("1_br")
item_id = &"{item_id}"
display_name = "{name}"
description = "{desc}"
item_type = {item_type}
stackable = true
max_stack = {max_stack}
usable = true
use_effect = "{effect}"
consume_on_use = true
buy_price = {buy}
sell_price = {sell}
icon = ExtResource("2_icon")
metadata/_custom_type_script = "{uid}"
"""

created = []
for it in ITEMS:
    path = os.path.join(DATA, it["file"])
    if os.path.exists(path):
        print("skip (exists):", it["file"])
        continue
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(TEMPLATE.format(uid=SCRIPT_UID, **it))
    created.append(it)
    print("created:", it["file"])

# ---- 注册表：补 ext_resource + items 数组 ----
reg_path = os.path.join(DATA, "item_registry.tres")
with open(reg_path, "r", encoding="utf-8") as f:
    reg = f.read()

added_ids = []
for it in ITEMS:
    rid = "20_" + it["item_id"]
    if ('id="%s"' % rid) in reg:
        print("registry skip:", rid)
        continue
    line = '[ext_resource type="Resource" path="res://script/items/data/%s" id="%s"]\n' % (it["file"], rid)
    # 插到最后一条 ext_resource 之后
    last = reg.rfind('[ext_resource ')
    end = reg.index("\n", last) + 1
    reg = reg[:end] + line + reg[end:]
    added_ids.append(rid)
    print("registry + ext_resource:", rid)

if added_ids:
    m = re.search(r"items = Array\[ExtResource\(\"1_bkhi0\"\)\]\(\[(.*?)\]\)", reg, re.S)
    if not m:
        raise SystemExit("找不到 items 数组，手动补")
    inner = m.group(1)
    for rid in added_ids:
        if ('ExtResource("%s")' % rid) not in inner:
            inner = inner.rstrip() + ', ExtResource("%s")' % rid
    reg = reg[:m.start(1)] + inner + reg[m.end(1):]
    with open(reg_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(reg)
    print("registry items array updated, +%d" % len(added_ids))
else:
    print("registry 无需改动")
