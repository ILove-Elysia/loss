# test/crafting_test.gd
# ============================================
# 合成系统测试（headless，不生成地图）
#
# 验证：
#   [1] 配方表能加载，且所有配方引用的物品/材料在注册表里都存在
#       —— 专防"配方写了 log，注册表里叫 wood"这类 ID 不一致
#   [2] 按分类查询数量正确（材料2 / 工具4 / 武器2 / 护甲2 / 建筑3）
#   [3] 材料不足时 can_craft=false、craft 返回 0 且材料不被扣
#   [4] 合成木棍：木材 x1 → 木棍 x1
#   [5] 合成电池：凝胶 x3 + 石头 x1 → 电池 x1（大纲 3.1.2「制作获得」）
#   [6] 背包满时：扣除的材料原样退回，不让玩家白白损失
# ============================================

extends SceneTree

var _failures: int = 0
var _player: Node3D = null
var _inventory: Node = null


func _initialize() -> void:
	await process_frame
	await process_frame
	_setup_mock_player()

	print("=================================")
	print("[1] 配方表与物品引用")
	_test_recipes_exist()

	print("[2] 分类查询")
	_test_categories()

	print("[2b] 专属制作栏按角色过滤")
	_test_exclusive_categories()

	print("[3] 材料不足不可合成")
	_test_insufficient()

	print("[4] 合成木棍（木材 x1）")
	_test_craft_stick()

	print("[5] 合成电池（凝胶 x3 + 石头 x1）")
	_test_craft_battery()

	print("[6] 背包满时回滚")
	_test_rollback()

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


## mock 玩家：Node3D（player 组）+ Inventory（3 格，方便测背包满）
func _setup_mock_player() -> void:
	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	root.add_child(_player)

	_inventory = preload("res://script/inventory/inventory.gd").new()
	_inventory.name = "Inventory"
	_inventory.max_slots = 3
	_player.add_child(_inventory)
	await process_frame


## 往背包塞物品（按 ID 从注册表取数据）
func _give(item_id: StringName, count: int) -> void:
	var registry := ItemRegistry.get_registry()
	_inventory.add_item(registry.get_item(item_id), count)


func _test_recipes_exist() -> void:
	var recipes := CraftingSystem.get_all_recipes()
	# 只统计**当前角色可见**的配方（默认角色 = 冒险家）：
	# 通用 18 条 + 冒险家专属「求生」2 条；魔女/机器人的专属配方不计入。
	_check(recipes.size() == 20, "冒险家可见配方 20 条（实际 %d）" % recipes.size())

	var registry := ItemRegistry.get_registry()
	var bad_output: Array[String] = []
	var bad_material: Array[String] = []
	for r in recipes:
		if registry.get_item(r.output_item_id) == null:
			bad_output.append(str(r.output_item_id))
		for m in r.materials:
			var mid := StringName(m.get("item_id", &""))
			if registry.get_item(mid) == null:
				bad_material.append(str(mid))

	_check(bad_output.is_empty(), "所有配方的产物都能在注册表找到%s" %
		("" if bad_output.is_empty() else "（缺失：%s）" % ", ".join(bad_output)))
	_check(bad_material.is_empty(), "所有配方的材料都能在注册表找到%s" %
		("" if bad_material.is_empty() else "（缺失：%s）" % ", ".join(bad_material)))

	# 顺带确认采集侧引用的 log / rock 已注册（否则砍树挖矿仍然是空手而归）
	_check(registry.get_item(&"log") != null, "log（木材）已注册——砍树不再空手而归")
	_check(registry.get_item(&"rock") != null, "rock（石头）已注册——挖矿不再空手而归")


func _test_categories() -> void:
	var C := CraftingRecipe.Category
	_check(CraftingSystem.get_recipes(C.MATERIAL).size() == 3, "材料配方 3 条（木棍、电池、铁锭）")
	_check(CraftingSystem.get_recipes(C.TOOL).size() == 7, "工具配方 7 条（粗斧/木斧/木镐/石斧/石镐/铁镐/铁斧）")
	_check(CraftingSystem.get_recipes(C.WEAPON).size() == 3, "武器配方 3 条（木剑、石剑、铁剑）")
	_check(CraftingSystem.get_recipes(C.ARMOR).size() == 2, "护甲配方 2 条（草甲、木甲）")
	_check(CraftingSystem.get_recipes(C.BUILDING).size() == 3, "建筑配方 3 条（工作台/熔炉/储物箱）")


## 大纲 2.2.5：专属制作栏只对本角色可见
func _test_exclusive_categories() -> void:
	var C := CraftingRecipe.Category
	var backup := CharacterRegistry.get_active_id()

	# 冒险家：只有「求生」
	CharacterRegistry.set_active("adventurer")
	_check(CraftingSystem.get_recipes(C.SURVIVAL).size() == 2, "冒险家看得见求生配方 2 条")
	_check(CraftingSystem.get_recipes(C.ALCHEMY).size() == 0, "冒险家看不见炼药配方")
	_check(CraftingSystem.get_recipes(C.MACHINE).size() == 0, "冒险家看不见机械配方")

	# 魔女：只有「炼药」
	CharacterRegistry.set_active("witch")
	_check(CraftingSystem.get_recipes(C.ALCHEMY).size() == 2, "魔女看得见炼药配方 2 条")
	_check(CraftingSystem.get_recipes(C.SURVIVAL).size() == 0, "魔女看不见求生配方")

	# 机器人：只有「机械」
	CharacterRegistry.set_active("robot")
	_check(CraftingSystem.get_recipes(C.MACHINE).size() == 2, "机器人看得见机械配方 2 条")
	_check(CraftingSystem.get_recipes(C.ALCHEMY).size() == 0, "机器人看不见炼药配方")

	# 通用栏不受角色影响
	_check(CraftingSystem.get_recipes(C.TOOL).size() == 7, "工具栏对任何角色都是 7 条")

	# 标签页列表：通用 5 个 + 各自专属 1 个
	CharacterRegistry.set_active("robot")
	var tabs := CraftingSystem.get_visible_categories()
	_check(tabs.size() == 6 and tabs.has(int(C.MACHINE)), "机器人有 6 个标签页且含「机械」")
	CharacterRegistry.set_active("knight")
	_check(CraftingSystem.get_visible_categories().size() == 5, "测试角色没有专属栏（5 个标签页）")

	CharacterRegistry.set_active(backup)


func _test_insufficient() -> void:
	_inventory.clear()
	_give(&"log", 1)  # 木斧需要 3 根，只给 1 根
	var recipe := CraftingSystem.find_recipe(&"wooden_axe")
	_check(recipe != null, "找到木斧配方")
	_check(not CraftingSystem.can_craft(recipe, _inventory), "木材不足时 can_craft=false")
	var made: int = CraftingSystem.craft(recipe, _inventory)
	_check(made == 0, "木材不足时 craft 返回 0（实际 %d）" % made)
	_check(_inventory.get_item_count(&"log") == 1, "材料未被扣除（仍为 1 根木材）")
	_check(_inventory.get_item_count(&"wooden_axe") == 0, "没有产出木斧")


func _test_craft_stick() -> void:
	_inventory.clear()
	_give(&"log", 1)
	var recipe := CraftingSystem.find_recipe(&"stick")
	_check(CraftingSystem.can_craft(recipe, _inventory), "木材 x1 足够合成木棍")
	var made: int = CraftingSystem.craft(recipe, _inventory)
	_check(made == 1, "合成产出 1 根木棍（实际 %d）" % made)
	_check(_inventory.get_item_count(&"log") == 0, "木材被扣除（0）")
	_check(_inventory.get_item_count(&"stick") == 1, "背包里木棍 x1")


func _test_craft_battery() -> void:
	_inventory.clear()
	_give(&"slime_gel", 3)
	_give(&"rock", 1)
	var recipe := CraftingSystem.find_recipe(&"battery")
	_check(recipe != null, "找到电池配方")
	_check(CraftingSystem.can_craft(recipe, _inventory), "凝胶 x3 + 石头 x1 足够合成电池")
	var made: int = CraftingSystem.craft(recipe, _inventory)
	_check(made == 1, "合成产出 1 个电池（实际 %d）" % made)
	_check(_inventory.get_item_count(&"slime_gel") == 0, "凝胶被扣除")
	_check(_inventory.get_item_count(&"rock") == 0, "石头被扣除")
	_check(_inventory.get_item_count(&"battery") == 1, "背包里电池 x1")


func _test_rollback() -> void:
	_inventory.clear()
	# 3 格全塞满（草/石头/木材各 99），此时没有空位放产物
	_give(&"grass", 99)
	_give(&"rock", 99)
	_give(&"log", 99)
	_check(_inventory.is_full(), "背包已塞满 3 格")

	var recipe := CraftingSystem.find_recipe(&"stick")
	_check(CraftingSystem.can_craft(recipe, _inventory), "材料足够（can_craft 只看材料）")
	var made: int = CraftingSystem.craft(recipe, _inventory)
	_check(made == 0, "背包无空位时合成失败返回 0（实际 %d）" % made)
	_check(_inventory.get_item_count(&"log") == 99, "木材原样退回（99，未白扣）")
	_check(_inventory.get_item_count(&"stick") == 0, "没有凭空产出木棍")
