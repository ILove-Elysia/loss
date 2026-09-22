# script/../test/equipment_ui_test.gd
# 装备界面 headless 验证
# 覆盖：
#   1. 面板构造无报错，能找到玩家 Inventory / Equipment
#   2. 打开后属性总览显示攻击/防御
#   3. 空装时三槽位显示「（空）」
#   4. 点击背包装备按钮 → 槽位更新为已装备物品
#   5. 点击槽位卸下 → 回到空
extends SceneTree

var _passed := 0
var _failed := 0

func _initialize() -> void:
	await process_frame
	await process_frame
	await _test_panel()
	print("\n========== 装备界面测试 ==========")
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

func _test_panel() -> void:
	# 组装玩家
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

	# 装入一些可装备物品
	var reg = ItemRegistry.get_registry()
	inv.add_item(reg.get_item(&"wooden_sword"), 1)
	inv.add_item(reg.get_item(&"wood_armor"), 1)
	inv.add_item(reg.get_item(&"stone_axe"), 1)

	# 构造界面
	var ui := preload("res://script/ui/equipment_ui.gd").new()
	root.add_child(ui)
	await process_frame

	_check(ui.inventory != null, "界面找到 Inventory")
	_check(ui.equipment != null, "界面找到 Equipment")

	ui.open()
	await process_frame

	_check(ui._stat_label != null, "属性总览标签已创建")
	_check("攻击力" in ui._stat_label.text, "总览显示攻击力")
	_check("防御力" in ui._stat_label.text, "总览显示防御力")

	# 空装时四槽位应显示（空）
	var weapon_name: Label = ui._slot_name.get(ItemData.EquipSlot.WEAPON, null)
	_check(weapon_name != null and weapon_name.text == "（空）", "空装武器槽显示（空）")

	# 核心槽：动力核心的装入 / 拆除入口就靠它，必须出现在面板上，
	# 否则玩家能装不能拆。
	var core_name: Label = ui._slot_name.get(ItemData.EquipSlot.CORE, null)
	_check(core_name != null and core_name.text == "（空）", "核心槽存在且初始为空")

	# 点击列表里的木剑按钮 → 装备
	# 找到文本含「木剑」的按钮并按下
	var equipped := false
	for child in ui._equip_list.get_children():
		if child is Button and "木剑" in child.text:
			child.pressed.emit()
			equipped = true
			break
	await process_frame
	_check(equipped, "在列表中找到木剑按钮并触发")
	_check(equip.get_item(ItemData.EquipSlot.WEAPON) != null, "点击后武器槽已装备")
	_check(weapon_name.text == "木剑", "界面武器槽显示「木剑」")

	# 点击武器槽卸下
	var slot_btn: Button = null
	for child in ui._slot_boxes[ItemData.EquipSlot.WEAPON].get_children():
		if child is Button:
			slot_btn = child
			break
	if slot_btn != null:
		slot_btn.pressed.emit()
	await process_frame
	_check(equip.get_item(ItemData.EquipSlot.WEAPON) == null, "点击槽位后卸下武器")
	_check(weapon_name.text == "（空）", "卸下后界面武器槽回到（空）")

	player.queue_free()
	await process_frame
