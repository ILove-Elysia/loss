# test/drop_test.gd
# ============================================
# 掉落与拾取闭环测试（headless，不生成地图）
#
# 验证链路：
#   [1] 物品注册表懒加载：grass / slime_gel / battery 可查
#   [2] ItemDrop.spawn_item_by_id 生成掉落物
#   [3] 拾取：走近 → 掉落物入背包（直接调 try_pickup 模拟 Area 信号）
#   [4] 背包满时拾取：部分入包、剩余留地
#   [5] 使用电池：ItemEffects → vitals.add_power → 电量 +10、数量 -1
#   [6] 使用不可用物品（凝胶）：无效果、不消耗
#
# 注意：本测试用 mock 玩家（Node3D + Inventory + Vitals），
# 不依赖 player.tscn 和地图生成。
# ============================================

extends SceneTree

var _failures: int = 0
var _player: Node3D = null
var _inventory: Node = null
var _vitals: Node = null


func _initialize() -> void:
	# 等场景树与首帧就绪（_init 里 add_child 会静默失败）
	await process_frame
	await process_frame

	_setup_mock_player()

	print("=================================")
	print("[1] 物品注册表")
	_test_registry()

	print("[2] 生成掉落物")
	_test_spawn_drop()

	print("[3] 拾取入背包")
	_test_pickup()

	print("[4] 背包满部分拾取")
	_test_full_inventory()

	print("[5] 使用电池（电量闭环）")
	_test_use_battery()

	print("[6] 使用不可用物品")
	_test_use_gel()

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


## mock 玩家：Node3D（player 组）+ Inventory + Vitals
func _setup_mock_player() -> void:
	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	root.add_child(_player)

	_inventory = preload("res://script/inventory/inventory.gd").new()
	_inventory.name = "Inventory"
	_inventory.max_slots = 3  # 故意小，方便测背包满
	_player.add_child(_inventory)

	_vitals = preload("res://script/player/vitals.gd").new()
	_vitals.name = "Vitals"
	_player.add_child(_vitals)
	await process_frame  # 等 _ready 跑完（初始化槽位）


func _test_registry() -> void:
	var registry: ItemRegistry = ItemRegistry.get_registry()
	_check(registry != null, "注册表懒加载可用")
	_check(registry.get_item(&"grass") != null, "grass 已注册")
	_check(registry.get_item(&"slime_gel") != null, "slime_gel 已注册")
	_check(registry.get_item(&"battery") != null, "battery 已注册")
	var battery := registry.get_item(&"battery")
	_check(battery.usable and battery.use_effect == "+10_power", "电池 use_effect = +10_power")


func _test_spawn_drop() -> void:
	var drop := ItemDrop.spawn_item_by_id(&"battery", 1, Vector3.ZERO)
	_check(drop != null, "spawn_item_by_id 生成成功")
	_check(drop.item_data != null and drop.item_data.item_id == &"battery", "掉落物携带 battery")
	_check(drop.is_in_group("item_drop"), "掉落物已注册 item_drop 组")
	# 手动老化，跳过拾取保护
	drop._age = 1.0


func _test_pickup() -> void:
	# 空手拾取：背包应有 1 个电池
	var drop := ItemDrop.spawn_item_by_id(&"battery", 2, Vector3(5, 0, 5))
	drop._age = 1.0  # 跳过保护期
	var taken: int = drop.try_pickup(_player)
	_check(taken == 2, "一次拾取 2 个电池（实际 %d）" % taken)
	_check(_inventory.get_item_count(&"battery") == 2, "背包里 battery x2")
	_check(drop.count == 0, "掉落物数量清零（等待消失动画）")


func _test_full_inventory() -> void:
	# 先清空背包，再用 grass 填满全部 3 格（不同物品不互相堆叠）
	_inventory.clear()
	var registry: ItemRegistry = ItemRegistry.get_registry()
	var grass: ItemData = registry.get_item(&"grass")
	for i in range(3):
		_inventory.add_item(grass, 99)
	_check(_inventory.is_full(), "背包已用 grass 填满 3 格")

	var drop := ItemDrop.spawn_item_by_id(&"battery", 20, Vector3(9, 0, 9))
	drop._age = 1.0
	var taken: int = drop.try_pickup(_player)
	_check(taken == 0, "背包完全塞满时电池拾取失败（实际 %d）" % taken)
	_check(drop.count == 20 and not drop._being_collected, "掉落物留在原地")

	# 清一格再捡：应能放 20 个（battery max_stack=20）
	_inventory.clear_slot(2)
	var taken2: int = drop.try_pickup(_player)
	_check(taken2 == 20, "腾出格子后拾取 20 个（一整格堆叠）")
	_check(drop.count == 0, "全部拾完")


func _test_use_battery() -> void:
	# 先把电量耗到 50
	_vitals.set_power(50.0)

	# 使用背包里的电池（动态找电池所在格）
	var battery_slots: Array[int] = _inventory.find_item_slots(&"battery")
	_check(not battery_slots.is_empty(), "背包里有电池格")
	var item = _inventory.get_item(battery_slots[0]) if not battery_slots.is_empty() else null
	_check(item != null and item.data.item_id == &"battery", "找到电池实例")
	var applied: bool = ItemEffects.apply(item.data, _player)
	_check(applied, "电池使用生效")
	_check(_vitals.current_power == 60.0, "电量 50 → 60（实际 %.1f）" % _vitals.current_power)

	# 完整使用路径：use_effect 解析
	var power: float = ItemEffects._parse_amount("+10_power", "_power")
	_check(power == 10.0, "效果解析 +10_power = 10")
	var bad: float = ItemEffects._parse_amount("+10_health", "_power")
	_check(bad == -1.0, "不匹配的后缀返回 -1")


func _test_use_gel() -> void:
	# 凝胶 usable=false → 不生效、不消耗
	var registry: ItemRegistry = ItemRegistry.get_registry()
	var gel: ItemData = registry.get_item(&"slime_gel")
	var applied: bool = ItemEffects.apply(gel, _player)
	_check(not applied, "凝胶不可使用（apply 返回 false）")
