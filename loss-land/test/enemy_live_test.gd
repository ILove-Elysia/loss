# test/enemy_live_test.gd
# ============================================
# 敌人掉落实弹测试（真实地图数据，headless）
#
# 验证链路：
#   [1] 无人机出生锚定：出现在矿区附近、且落在陆地上方
#   [2] 击杀无人机 → 必掉电池（测试强制 chance=1.0）
#   [3] 击杀史莱姆 → 必掉凝胶 x1
#   [4] 掉落物可被拾取（try_pickup 模拟玩家走近）
#
# 地图生成约 12~20 秒，本脚本整体运行较慢属正常。
# ============================================

extends SceneTree

var _failures: int = 0
var _gen3d: Node = null
var _player: Node3D = null
var _inventory: Node = null


func _initialize() -> void:
	await process_frame
	await process_frame

	# ---- 搭建地图生成器（bench 同款做法：不进树）----
	_gen3d = load("res://script/map/map_generator_3d.gd").new()
	_gen3d.tile_container = Node3D.new()
	_gen3d.tile_container.name = "TileContainer3D"
	_gen3d.add_child(_gen3d.tile_container)
	_gen3d.collision_container = Node3D.new()
	_gen3d.collision_container.name = "FloorCollisionContainer"
	_gen3d.add_child(_gen3d.collision_container)

	_gen3d._gen = load("res://script/map/map_generator.gd").new()
	_gen3d._gen.task_system = load("res://script/map/task_system.gd").new()
	_gen3d._gen.layout = load("res://script/map/layout.gd").new()
	_gen3d._gen.chain_gen = load("res://script/map/room_chain.gd").new()
	_gen3d._gen.rng.randomize()

	print("生成地图中（约 15 秒）...")
	_gen3d._run_generation()

	# map_gen 组是无人机锚定查询的入口，必须注册
	root.add_child(_gen3d)

	# ---- mock 玩家 ----
	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	root.add_child(_player)
	_inventory = load("res://script/inventory/inventory.gd").new()
	_inventory.name = "Inventory"
	_player.add_child(_inventory)
	await process_frame

	print("=================================")
	print("[1] 无人机出生锚定")
	await _test_drone_anchor()

	print("[2] 无人机死亡掉电池")
	await _test_drone_drop()

	print("[3] 史莱姆死亡掉凝胶")
	await _test_slime_drop()

	print("[4] 掉落物拾取")
	await _test_pickup_live()

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


func _test_drone_anchor() -> void:
	var drone: Drone = load("res://script/ai/enemy/mob/drone/drone.gd").new()
	root.add_child(drone)
	await process_frame  # 让 _ready（锚定）执行

	var rocky: Vector3 = _gen3d.get_task_world_position("Rocky", 1.0)
	var dist: float = drone.global_position.distance_to(rocky)
	_check(dist < 80.0, "无人机出生在矿区入口 %.0f 米内（实际 %.0f）" % [80.0, dist])
	_check(_gen3d.is_land_world(drone.global_position), "无人机出生点在陆地上")
	_check(drone.global_position.y > 0.5, "无人机悬浮在空中（y=%.1f）" % drone.global_position.y)
	drone.queue_free()


func _test_drone_drop() -> void:
	var drone: Drone = load("res://script/ai/enemy/mob/drone/drone.gd").new()
	drone.battery_drop_chance = 1.0  # 测试强制必掉
	root.add_child(drone)
	await process_frame

	drone.take_damage(999)
	await process_frame

	var drops: Array = get_nodes_in_group_safe()
	var battery_drop: Node = null
	for d in drops:
		if d.item_data != null and d.item_data.item_id == &"battery":
			battery_drop = d
	_check(battery_drop != null, "击杀无人机后地上出现电池")


func _test_slime_drop() -> void:
	var slime: Node = load("res://tscn/prefab/slime.tscn").instantiate()
	root.add_child(slime)
	await process_frame

	slime.take_damage(999)
	await process_frame

	var drops: Array = get_nodes_in_group_safe()
	var gel_drop: Node = null
	for d in drops:
		if d.item_data != null and d.item_data.item_id == &"slime_gel":
			gel_drop = d
	_check(gel_drop != null, "击杀史莱姆后地上出现凝胶 x%d" % (gel_drop.count if gel_drop else 0))


func _test_pickup_live() -> void:
	var drops: Array = get_nodes_in_group_safe()
	_check(not drops.is_empty(), "场上有掉落物")
	var picked: int = 0
	for d in drops:
		d._age = 1.0  # 跳过拾取保护
		picked += d.try_pickup(_player)
	_check(picked >= 2, "掉落物全部被拾取（%d 件）" % picked)
	_check(_inventory.get_item_count(&"battery") >= 1, "背包有电池")
	_check(_inventory.get_item_count(&"slime_gel") >= 1, "背包有凝胶")


## 收集 item_drop 组（root.get_tree() 在 SceneTree 脚本里不可用，走 root）
func get_nodes_in_group_safe() -> Array:
	var result: Array = []
	_collect_group(root, result)
	return result


func _collect_group(node: Node, out: Array) -> void:
	if node.is_in_group("item_drop"):
		out.append(node)
	for c in node.get_children():
		_collect_group(c, out)
