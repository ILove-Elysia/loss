# script/../test/equipment_test.gd
# 装备系统 headless 验证
# 覆盖：
#   1. PlayerEquipment 装备/卸下流转（与背包交换）
#   2. 属性汇总：攻击 / 防御 / 工具槽的每击工作量
#   3. Physics 最终攻击力含武器加成、受伤按护甲减伤
#   4. ResourceEntity 采集：工具标签白名单门槛 + 每击工作量（24 点 / 4 点 = 6 次）
#   5. 集成：装备石斧后确实能砍树，且次数对得上
#   6. 核心槽：装入 / 拆除动力核心 → 开启 / 关闭「外置电量」与「核心」制作栏
extends SceneTree

var _passed := 0
var _failed := 0

func _initialize() -> void:
	await process_frame
	await process_frame
	_test_equip_unequip()
	_test_bonus_methods()
	_test_physics_attack_defense()
	_test_harvest_work()
	_test_harvest_integration()
	await _test_core_slot()
	print("\n========== 装备系统测试 ==========")
	print("通过: %d   失败: %d" % [_passed, _failed])
	print("RESULT: %s" % ("PASS" if _failed == 0 else "FAIL"))
	quit()

func _check(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("[通过] %s" % msg)
	else:
		_failed += 1
		print("[失败] %s" % msg)

# ----------------------------------------
# 组装一个玩家根节点（带 Inventory + Equipment + Physics）
# ----------------------------------------
func _make_player() -> Node3D:
	var player := Node3D.new()
	player.name = "player"
	player.add_to_group("player")
	root.add_child(player)

	var inv = preload("res://script/inventory/inventory.gd").new()
	inv.name = "Inventory"
	player.add_child(inv)

	var equip = preload("res://script/player/equipment.gd").new()
	equip.name = "Equipment"
	player.add_child(equip)

	var phys = preload("res://script/player/physics.gd").new()
	phys.name = "Physics"
	player.add_child(phys)
	# Physics 的 @onready 会去找 Visual 等，headless 下为 null 不影响数值测试
	return player

func _add(player: Node3D, item_id: StringName, count: int) -> void:
	var inv = player.get_node("Inventory")
	var registry = ItemRegistry.get_registry()
	inv.add_item(registry.get_item(item_id), count)


# ----------------------------------------
# 6. 核心槽：装入 / 拆除动力核心 → 开关「核心电量行」与「核心」制作栏
#
# 这条链路的坑在于它是**跨系统的副作用**：核心槽本身不带任何数值，
# 装上去以后真正变化的是 Vitals 的 has_power（只读计算属性）与
# CraftingSystem 的静态开关。只测"槽位里有东西"是测不出来的。
#
# 2026-09-16 起电量是**核心自己的属性**（PowerCoreInstance），
# 装入的是"一枚电量 100 的核心"，拆下时它连同电量原样回到背包。
# ----------------------------------------
func _test_core_slot() -> void:
	# 先切到冒险家（默认无内置电量），必须在 Vitals._ready 之前设好
	CharacterRegistry.set_active("adventurer")
	CraftingSystem.set_core_unlocked(false)

	var player := Node3D.new()
	player.name = "player"
	root.add_child(player)

	var inv = preload("res://script/inventory/inventory.gd").new()
	inv.name = "Inventory"
	player.add_child(inv)

	var vitals = preload("res://script/player/vitals.gd").new()
	vitals.name = "Vitals"
	player.add_child(vitals)

	var equip: PlayerEquipment = preload("res://script/player/equipment.gd").new()
	equip.name = "Equipment"
	player.add_child(equip)

	await process_frame

	_check(not vitals.has_power, "冒险家开局没有电量")
	_check(not equip.has_core(), "核心槽初始为空")

	_add(player, &"power_core", 1)
	_check(equip.equip(&"power_core"), "动力核心装入核心槽")
	await process_frame
	_check(equip.has_core(), "核心槽已占用")
	_check(equip.get_item(ItemData.EquipSlot.CORE).item_id == &"power_core",
		"槽里就是动力核心")
	_check(vitals.has_power, "装入核心 → has_power 开启（运行时计算）")
	_check(is_equal_approx(equip.get_core_instance().power, 100.0), "核心出厂满电 100")
	_check(is_equal_approx(vitals.get_core_power(), 100.0), "vitals 读到核心电量 100")
	_check(CraftingSystem.core_tab_unlocked, "装入核心 → 「核心」制作栏解锁")

	# 拆下：核心（连同自己的电量）回到背包，has_power 立刻回落
	_check(equip.unequip(ItemData.EquipSlot.CORE), "动力核心拆下核心槽")
	await process_frame
	_check(not equip.has_core(), "核心槽已清空")
	_check(not vitals.has_power, "拆下核心 → has_power 关闭")
	_check(is_equal_approx(vitals.get_core_power(), 0.0), "没装核心时 vitals 读不到核心电量")
	_check(not CraftingSystem.core_tab_unlocked, "拆下核心 → 「核心」制作栏关闭")

	player.queue_free()


# ----------------------------------------
# 1. 装备 / 卸下流转
# ----------------------------------------
func _test_equip_unequip() -> void:
	var player := _make_player()
	var equip: PlayerEquipment = player.get_node("Equipment")
	var inv = player.get_node("Inventory")

	_add(player, &"wooden_sword", 1)

	_check(equip.equip(&"wooden_sword"), "装备木剑成功")
	_check(equip.get_item(ItemData.EquipSlot.WEAPON) != null, "武器槽已占用")
	_check(inv.get_item_count(&"wooden_sword") == 0, "背包木剑减为 0")

	# 换石剑，旧木剑应退回背包
	_add(player, &"stone_sword", 1)
	_check(equip.equip(&"stone_sword"), "装备石剑成功（替换木剑）")
	_check(inv.get_item_count(&"wooden_sword") == 1, "被替换的木剑退回背包")
	_check(equip.get_item(ItemData.EquipSlot.WEAPON).item_id == &"stone_sword", "武器槽现为石剑")

	# 卸下
	_check(equip.unequip(ItemData.EquipSlot.WEAPON), "卸下武器成功")
	_check(equip.get_item(ItemData.EquipSlot.WEAPON) == null, "武器槽清空")
	_check(inv.get_item_count(&"stone_sword") == 1, "卸下的石剑回背包")

	# 不可装备物品装备应失败
	_add(player, &"log", 3)
	_check(not equip.equip(&"log"), "木材不可装备（返回 false）")

	player.queue_free()
	await process_frame

# ----------------------------------------
# 2. 属性汇总
# ----------------------------------------
func _test_bonus_methods() -> void:
	var player := _make_player()
	var equip: PlayerEquipment = player.get_node("Equipment")

	_check(equip.get_attack_bonus() == 0, "空装攻击加成=0")
	_check(equip.get_defense_bonus() == 0, "空装防御=0")
	_check(equip.get_item(ItemData.EquipSlot.TOOL) == null, "空装工具槽为空")

	_add(player, &"stone_axe", 1)
	equip.equip(&"stone_axe")
	_check(equip.get_attack_bonus() == 0, "斧头不提供攻击加成")
	_check(equip.get_tool_item().harvest_work == 4, "石斧每击工作量=4")
	_check(equip.get_tool_item().tags.has(&"axe"), "石斧带 &\"axe\" 标签")

	_add(player, &"stone_sword", 1)
	equip.equip(&"stone_sword")
	_check(equip.get_attack_bonus() == 18, "石剑攻击加成=18")
	_check(equip.get_defense_bonus() == 0, "武器不提供防御")

	_add(player, &"wood_armor", 1)
	equip.equip(&"wood_armor")
	_check(equip.get_defense_bonus() == 6, "木甲防御=6")

	player.queue_free()
	await process_frame

# ----------------------------------------
# 3. Physics 攻击 / 防御
# ----------------------------------------
func _test_physics_attack_defense() -> void:
	var player := _make_player()
	var equip: PlayerEquipment = player.get_node("Equipment")
	var phys = player.get_node("Physics")

	_check(phys.get_total_attack_damage() == 10, "裸装攻击力=基础10")
	_check(phys.get_defense() == 0, "裸装防御=0")

	# 受伤不减
	phys.current_health = 100
	phys.take_damage(10)
	_check(phys.current_health == 90, "裸装受10伤掉10血")

	# 装备石剑后攻击力提升
	_add(player, &"stone_sword", 1)
	equip.equip(&"stone_sword")
	_check(phys.get_total_attack_damage() == 28, "石剑后攻击力=28(基础10+18)")
	# 直接验证 take_damage 数值路径
	phys.current_health = 100
	# 装备木甲减伤
	_add(player, &"wood_armor", 1)
	equip.equip(&"wood_armor")
	_check(phys.get_defense() == 6, "装备木甲后防御=6")
	phys.current_health = 100
	phys.take_damage(10)
	_check(phys.current_health == 96, "木甲6：受10伤实际掉4血")
	# 高防御不致死（至少掉1）
	phys.current_health = 100
	phys.take_damage(3)
	_check(phys.current_health == 99, "防御>=伤害时至少掉1血（100-3+6保底1）")

	player.queue_free()
	await process_frame

# ----------------------------------------
# 4. ResourceEntity 采集门槛与工作量
#
# 采集只有一套数值：资源 work_amount（血量）÷ 工具 harvest_work（每击伤害）= 要采几下。
# 门槛只看工具标签白名单：树认 &"axe"，空手一概拒绝。
# ----------------------------------------
func _test_harvest_work() -> void:
	var tree = ResourceEntity.new()
	var data: ResourceData = load("res://script/resources/data/tree_data.tres")
	tree.resource_data = data
	_check(is_instance_valid(data), "树资源数据加载成功")
	_check(data.work_amount == 24, "树工作量=24")

	# 空手：门槛不通过（不允许开工），所以"每击 1 点"也无从谈起
	var p1 := Node3D.new()
	p1.add_to_group("player")
	var e1 := Node.new(); e1.name = "Equipment"; p1.add_child(e1)
	root.add_child(p1)
	_check(not tree._is_tool_allowed(p1), "空手砍树被拒（树要 &\"axe\"）")

	# 装备石斧（命中白名单）
	var p2 := Node3D.new()
	p2.add_to_group("player")
	var e2 = preload("res://script/player/equipment.gd").new(); e2.name = "Equipment"; p2.add_child(e2)
	var inv2 = preload("res://script/inventory/inventory.gd").new(); inv2.name = "Inventory"; p2.add_child(inv2)
	root.add_child(p2)
	inv2.add_item(ItemRegistry.get_registry().get_item(&"stone_axe"), 1)
	e2.equip(&"stone_axe")
	_check(tree._is_tool_allowed(p2), "装备石斧后允许砍树")
	var per_hit := tree.get_work_per_hit(p2)
	_check(per_hit == 4, "石斧每击 4 点（实际 %d）" % per_hit)
	_check(ceili(float(data.work_amount) / float(per_hit)) == 6, "24 / 4 = 砍 6 次")

	p1.queue_free(); p2.queue_free()
	await process_frame

# ----------------------------------------
# 5. 集成：铁矿 / 煤矿与大石头同一套数值（石镐 6 次、铁镐 4 次）
# ----------------------------------------
func _test_harvest_integration() -> void:
	var player := Node3D.new()
	player.add_to_group("player")
	var e = preload("res://script/player/equipment.gd").new(); e.name = "Equipment"; player.add_child(e)
	var inv = preload("res://script/inventory/inventory.gd").new(); inv.name = "Inventory"; player.add_child(inv)
	root.add_child(player)

	for res_path in [
		"res://script/resources/data/stone_data.tres",
		"res://script/resources/data/iron_ore_data.tres",
		"res://script/resources/data/coal_data.tres",
	]:
		var entity = ResourceEntity.new()
		var data := load(res_path) as ResourceData
		entity.resource_data = data
		root.add_child(entity)
		_check(data.work_amount == 24, "%s 工作量沿用大石头=24" % data.resource_id)
		_check(data.allowed_tool_tags.has(&"pickaxe"), "%s 认 &\"pickaxe\"" % data.resource_id)
		_check(not entity._is_tool_allowed(player), "%s 空手被拒" % data.resource_id)

		inv.add_item(ItemRegistry.get_registry().get_item(&"stone_pickaxe"), 1)
		e.equip(&"stone_pickaxe")
		_check(entity._is_tool_allowed(player), "%s 石镐可挖" % data.resource_id)
		_check(ceili(24.0 / float(entity.get_work_per_hit(player))) == 6, "%s 石镐 6 次" % data.resource_id)

		e.unequip(ItemData.EquipSlot.TOOL)
		inv.add_item(ItemRegistry.get_registry().get_item(&"iron_pickaxe"), 1)
		e.equip(&"iron_pickaxe")
		_check(ceili(24.0 / float(entity.get_work_per_hit(player))) == 4, "%s 铁镐 4 次" % data.resource_id)

		e.unequip(ItemData.EquipSlot.TOOL)
		entity.queue_free()

	player.queue_free()
	await process_frame
