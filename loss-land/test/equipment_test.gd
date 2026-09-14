# script/../test/equipment_test.gd
# 装备系统 headless 验证
# 覆盖：
#   1. PlayerEquipment 装备/卸下流转（与背包交换）
#   2. 属性汇总：攻击 / 防御 / 采集速度倍率（工具类型匹配才生效）
#   3. Physics 最终攻击力含武器加成、受伤按护甲减伤
#   4. ResourceEntity 采集耗时：匹配工具明显缩短
#   5. 集成：装备木斧后砍树更快
extends SceneTree

var _passed := 0
var _failed := 0

func _initialize() -> void:
	await process_frame
	await process_frame
	_test_equip_unequip()
	_test_bonus_methods()
	_test_physics_attack_defense()
	_test_harvest_duration()
	_test_harvest_integration()
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
	_check(equip.get_harvest_speed_multiplier(int(ResourceData.HarvestTool.AXE)) == 1.0, "空装采集倍率=1.0")

	_add(player, &"wooden_axe", 1)
	equip.equip(&"wooden_axe")
	_check(equip.get_attack_bonus() == 0, "斧头不提供攻击加成")
	_check(_equip_harvest(equip, ResourceData.HarvestTool.AXE) == 1.5, "斧头对木材(匹配)倍率=1.5")
	# 不匹配：斧头挖矿不加速
	_check(_equip_harvest(equip, ResourceData.HarvestTool.PICKAXE) == 1.0, "斧头对矿物(不匹配)倍率=1.0")

	_add(player, &"stone_sword", 1)
	equip.equip(&"stone_sword")
	_check(equip.get_attack_bonus() == 18, "石剑攻击加成=18")
	_check(equip.get_defense_bonus() == 0, "武器不提供防御")

	_add(player, &"wood_armor", 1)
	equip.equip(&"wood_armor")
	_check(equip.get_defense_bonus() == 6, "木甲防御=6")

	player.queue_free()
	await process_frame

func _equip_harvest(equip: PlayerEquipment, t: int) -> float:
	return equip.get_harvest_speed_multiplier(t)

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
# 4. ResourceEntity 采集耗时
# ----------------------------------------
func _test_harvest_duration() -> void:
	var tree = ResourceEntity.new()
	var data: ResourceData = load("res://script/resources/data/tree_data.tres")
	tree.resource_data = data
	_check(is_instance_valid(data), "树资源数据加载成功")

	# 无装备采集者
	var p1 := Node3D.new()
	p1.add_to_group("player")
	var e1 := Node.new(); e1.name = "Equipment"; p1.add_child(e1)
	root.add_child(p1)

	var t_no_tool := tree.get_harvest_duration(p1)
	_check(absf(t_no_tool - 0.8) < 0.001, "无工具砍树耗时=基础0.8s (实际 %.2f)" % t_no_tool)

	# 装备木斧（匹配）
	var p2 := Node3D.new()
	p2.add_to_group("player")
	var e2 = preload("res://script/player/equipment.gd").new(); e2.name = "Equipment"; p2.add_child(e2)
	var inv2 = preload("res://script/inventory/inventory.gd").new(); inv2.name = "Inventory"; p2.add_child(inv2)
	root.add_child(p2)
	inv2.add_item(ItemRegistry.get_registry().get_item(&"wooden_axe"), 1)
	e2.equip(&"wooden_axe")
	var t_axe := tree.get_harvest_duration(p2)
	_check(absf(t_axe - (0.8/1.5)) < 0.001, "木斧砍树耗时=0.53s (实际 %.2f)" % t_axe)
	_check(t_axe < t_no_tool, "木斧比徒手更快")

	p1.queue_free(); p2.queue_free()
	await process_frame

# ----------------------------------------
# 5. 集成：装备木斧后砍树确实更快（端到端）
# ----------------------------------------
func _test_harvest_integration() -> void:
	# 用直接数值对比即可（harvest 是 await 协程，耗时对比在 _4 已覆盖）
	var tree = ResourceEntity.new()
	var data := load("res://script/resources/data/tree_data.tres") as ResourceData
	tree.resource_data = data
	root.add_child(tree)

	var player := Node3D.new()
	player.add_to_group("player")
	var e = preload("res://script/player/equipment.gd").new(); e.name = "Equipment"; player.add_child(e)
	var inv = preload("res://script/inventory/inventory.gd").new(); inv.name = "Inventory"; player.add_child(inv)
	root.add_child(player)
	inv.add_item(ItemRegistry.get_registry().get_item(&"wooden_axe"), 1)
	e.equip(&"wooden_axe")

	var dur := tree.get_harvest_duration(player)
	_check(dur < 0.8, "集成：木斧装备后砍树耗时<0.8s (实际 %.2f)" % dur)
	_check(tree._get_harvester_speed_multiplier(player) == 1.5, "集成：采集倍率取到1.5")

	player.queue_free(); tree.queue_free()
	await process_frame
