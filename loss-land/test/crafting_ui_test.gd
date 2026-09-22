# test/crafting_ui_test.gd
# ============================================
# 合成界面测试（headless）
#
# 验证面板真的能用，而不只是"代码不报错"：
#   [1] 面板能构建，并按 player 组找到背包
#   [2] 配方列表条数正确（全部 13 / 工具 4）
#   [3] 详情区显示选中的配方与材料需求
#   [4] 材料不足时合成按钮禁用，给足材料后启用
#   [5] 点合成按钮真的扣材料、出产物、刷状态
#   [6] 分类标签切换后列表跟着变
#
# 说明：Control 在 headless 下可以正常 new() 和 add_child()，
# 只是没有真实窗口尺寸，所以只验证逻辑与控件状态，不验证像素布局。
# ============================================

extends SceneTree

var _failures: int = 0
var _player: Node3D = null
var _inventory: Node = null
var _ui: CraftingUI = null


func _initialize() -> void:
	await process_frame
	await process_frame
	_setup_mock_player()

	_ui = CraftingUI.new()
	root.add_child(_ui)   # 触发 _ready（构建 UI + 找背包）
	await process_frame
	_ui.open()

	print("=================================")
	print("[1] 面板构建与背包绑定")
	_test_construct()

	print("[2] 配方列表")
	_test_recipe_list()

	print("[3] 详情与材料需求")
	_test_detail()

	print("[4] 合成按钮启用/禁用")
	_test_button_state()

	print("[5] 点击合成")
	_test_craft_click()

	print("[6] 分类标签切换")
	_test_tabs()

	print("=================================")
	if _failures == 0:
		print("===== 全部检查通过 =====")
	else:
		print("!!!!! %d 项失败 !!!!!" % _failures)
	quit(_failures)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  [通过] %s" % msg)
	else:
		_failures += 1
		print("  [失败] %s" % msg)


func _setup_mock_player() -> void:
	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	root.add_child(_player)

	_inventory = preload("res://script/inventory/inventory.gd").new()
	_inventory.name = "Inventory"
	_inventory.max_slots = 20
	_player.add_child(_inventory)
	await process_frame


func _give(item_id: StringName, count: int) -> void:
	var registry := ItemRegistry.get_registry()
	_inventory.add_item(registry.get_item(item_id), count)


func _test_construct() -> void:
	_check(_ui != null, "合成界面实例创建成功")
	_check(_ui.inventory == _inventory, "按 player 组找到玩家背包")
	_check(_ui.is_in_group("crafting_ui"), "已注册 crafting_ui 组")
	_check(_ui.visible, "open() 后面板可见")


func _test_recipe_list() -> void:
	_check(_ui._recipe_buttons.size() == 13, "「全部」列表 13 条（实际 %d）" % _ui._recipe_buttons.size())
	_check(_ui._visible_recipes.size() == 13, "可见配方 13 条")


func _test_detail() -> void:
	var recipe := CraftingSystem.find_recipe(&"wooden_sword")
	_check(recipe != null, "找到木剑配方")
	_ui._select_recipe(recipe)
	_check(_ui._selected == recipe, "选中木剑配方")
	_check(_ui._detail_name.text.contains("木剑"), "详情标题显示「木剑」（实际：%s）" % _ui._detail_name.text)
	_check(_ui._material_list.get_child_count() == 1, "材料清单 1 行（木棍）")
	# 木剑需要木棍 x2，此时背包为空 → 显示 0/2
	var line := _ui._material_list.get_child(0) as Label
	_check(line != null and line.text.contains("0 / 2"), "材料行显示 0 / 2（实际：%s）" % (line.text if line else "<空>"))


func _test_button_state() -> void:
	_check(_ui._craft_button.disabled, "材料不足时合成按钮禁用")
	_give(&"stick", 2)
	_ui.refresh()
	_check(not _ui._craft_button.disabled, "给足 2 根木棍后按钮启用")
	var line := _ui._material_list.get_child(0) as Label
	_check(line.text.contains("2 / 2"), "材料行刷新为 2 / 2（实际：%s）" % line.text)


func _test_craft_click() -> void:
	# 直接触发按钮的 pressed 信号，等价于玩家点了一下
	_ui._craft_button.pressed.emit()
	_check(_inventory.get_item_count(&"stick") == 0, "木棍被扣除（0）")
	_check(_inventory.get_item_count(&"wooden_sword") == 1, "产出木剑 x1")
	_check(_ui._status_label.text.contains("合成成功"), "状态栏提示合成成功（实际：%s）" % _ui._status_label.text)
	_check(_ui._craft_button.disabled, "合成后材料归零，按钮重新禁用")


func _test_tabs() -> void:
	# 切到「工具」分类（CraftingRecipe.Category.TOOL == 1）
	_ui._on_tab_pressed(int(CraftingRecipe.Category.TOOL))
	_check(_ui._recipe_buttons.size() == 7, "工具分类 7 条（实际 %d）" % _ui._recipe_buttons.size())

	# 切到「材料」分类（MATERIAL == 0）：木棍 + 电池 + 铁锭
	_ui._on_tab_pressed(int(CraftingRecipe.Category.MATERIAL))
	_check(_ui._recipe_buttons.size() == 3, "材料分类 3 条（实际 %d）" % _ui._recipe_buttons.size())

	# 在材料分类里合成电池：凝胶 x3 + 石头 x1
	_give(&"slime_gel", 3)
	_give(&"rock", 1)
	_ui.refresh()
	var battery := CraftingSystem.find_recipe(&"battery")
	_ui._select_recipe(battery)
	_check(not _ui._craft_button.disabled, "电池配方材料足够，按钮启用")
	_ui._craft_button.pressed.emit()
	_check(_inventory.get_item_count(&"battery") == 1, "背包里电池 x1")
	_check(_inventory.get_item_count(&"slime_gel") == 0, "凝胶被扣除")
