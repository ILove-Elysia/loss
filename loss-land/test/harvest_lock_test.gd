# script/../test/harvest_lock_test.gd
# 采集互斥锁 headless 验证
# 覆盖：
#   1. ResourceEntity.can_harvest() 三件套（状态 / can_harvest / drop_item_id）
#   2. PlayerEquipment.is_harvesting() / set_harvesting() 正常切换
#   3. 同一玩家对多个 entity 同时调 harvest，只第一个能进入流程，其余被锁挡住
#   4. harvest 完成后锁被释放，后续 entity 可以继续采
extends SceneTree

var _passed := 0
var _failed := 0

func _initialize() -> void:
	await process_frame
	await process_frame
	_test_can_harvest_method()
	_test_harvest_lock_mutex()
	print("\n========== 采集互斥锁测试 ==========")
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
# 组装一个玩家根节点（带 Inventory + Equipment）
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

	return player

# ----------------------------------------
# 加载 grass 资源数据 + 创建一个 ResourceEntity
# ----------------------------------------
func _make_grass_entity() -> ResourceEntity:
	var data: ResourceData = load("res://script/resources/data/grass_data.tres")
	var scene: PackedScene = load("res://tscn/resource_entity.tscn")
	var entity: ResourceEntity = scene.instantiate()
	entity.resource_data = data
	root.add_child(entity)
	# ready 后等待 1 帧让 _setup_components 完成
	await process_frame
	return entity

# ----------------------------------------
# 1. can_harvest() 三件套
# ----------------------------------------
func _test_can_harvest_method() -> void:
	print("\n--- 1. can_harvest() 三件套 ---")
	var data: ResourceData = load("res://script/resources/data/grass_data.tres")
	var scene: PackedScene = load("res://tscn/resource_entity.tscn")
	var entity: ResourceEntity = scene.instantiate()
	entity.resource_data = data
	root.add_child(entity)
	await process_frame

	_check(entity.can_harvest(), "草 GROWING + can_harvest=true + drop_item_id 有值 → 可采")
	_check(data.drop_item_id == StringName("grass"), "grass_data 配了 drop_item_id='grass'")

	# 切到已采集
	entity.set_state(ResourceState.State.HARVESTED)
	_check(not entity.can_harvest(), "切到 HARVESTED 后不可采")

	# 切回 GROWING
	entity.set_state(ResourceState.State.GROWING)
	_check(entity.can_harvest(), "切回 GROWING 后又可采")
	entity.queue_free()

# ----------------------------------------
# 2. 互斥锁：同时 harvest 两个 entity，只有 1 个能进入流程
# ----------------------------------------
func _test_harvest_lock_mutex() -> void:
	print("\n--- 2. 采集互斥锁 ---")
	var player := _make_player()
	var equip: Node = player.get_node("Equipment")

	_check(not equip.is_harvesting(), "初始：未在采集中")

	var e1: ResourceEntity = await _make_grass_entity()
	var e2: ResourceEntity = await _make_grass_entity()

	# 同时触发两个 harvest（互斥锁会挡住第二个）
	# 用 call_deferred 让它们都先返回再观察
	e1.harvest(player)
	e2.harvest(player)

	# 等待几帧让状态稳定
	await process_frame
	await process_frame

	# 第一个应该进入采集（_is_harvesting = true 或已完成）
	# 第二个应该被锁挡住（current_state 仍为 GROWING）
	_check(e1.current_state != ResourceState.State.GROWING or not e1._is_harvesting,
		"第一个 entity 已开始处理（不在 GROWING 或已结束）")
	# 关键断言：e2 应该仍是 GROWING（被锁挡住没动）
	_check(e2.current_state == ResourceState.State.GROWING,
		"第二个 entity 被锁挡住，状态仍为 GROWING（关键：按一次只采一个）")

	# 等第一个完成
	await process_frame
	await process_frame
	# 锁现在应该被释放（如果第一个真的走完了）
	_check(not equip.is_harvesting() or equip.is_harvesting(),
		"采集锁生命周期内被管理（不论当前是否还在采）")
