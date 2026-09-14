# test/resource_stream_test.gd
# 资源「视野流式加载」headless 验证
#
# 覆盖：
#   1. 全图资源只建"记录"（数据层），不为每个资源创建节点
#   2. 只有玩家一定距离内的资源才被实例化（距离常数在 ViewFrustum.LOAD_RADIUS）
#   3. 离开视野的实体退回对象池，且**状态不丢**（采过的回到视野仍是已采集）
#   4. 未实例化的资源也会继续走再生倒计时（"采完走远"不等于永久消失）
#   5. 存档往返：键名与旧档一致、数量守恒（含视野外资源），读回后能重新装配
#
# 运行：
#   godot --headless --script test/resource_stream_test.gd
extends SceneTree

var _passed: int = 0
var _failed: int = 0
var _mgr: ResourceManager = null
var _player: Node3D = null
var _phys: Node3D = null


func _initialize() -> void:
	await process_frame
	_build_world()
	await _test_stream_scope()
	await _test_state_kept()
	await _test_regen_while_away()
	await _test_save_roundtrip()
	print("\n========== 资源视野流式加载测试 ==========")
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
# 最小世界：资源管理器 + 玩家
# 不建地图、不放相机 —— 装载判定只看"距玩家多少米"（ViewFrustum.LOAD_RADIUS），
# 所以断言可以用具体米数，不受屏幕分辨率与镜头角度影响。
# ----------------------------------------
func _build_world() -> void:
	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	root.add_child(_player)

	# 资源管理器认的是 Physics（玩家根节点只是容器、恒在原点）
	_phys = Node3D.new()
	_phys.name = "Physics"
	_player.add_child(_phys)

	var container := Node3D.new()
	container.name = "ResourceContainer"
	root.add_child(container)

	_mgr = ResourceManager.new()
	_mgr.name = "ResourceManager"
	_mgr.resource_registry = load("res://script/resources/data/resource_registry.tres")
	_mgr.resource_container = container
	# 不设 spawner：_ready 会跳过自动生成，测试自己铺数据
	root.add_child(_mgr)


# ----------------------------------------
# 1. 记录与节点分离 + 只实例化视野内
# ----------------------------------------
func _test_stream_scope() -> void:
	print("\n--- 1. 只实例化视野内的资源 ---")
	var near := _mgr.add_record(&"tree", Vector3(6.0, 0.0, 6.0))
	var far := _mgr.add_record(&"tree", Vector3(220.0, 0.0, 220.0))
	_check(not near.is_empty() and not far.is_empty(), "两条资源记录创建成功")
	_check(_mgr.get_stream_stats()["loaded"] == 0, "建记录本身不产生任何节点")

	await create_timer(0.5).timeout

	var stats: Dictionary = _mgr.get_stream_stats()
	_check(stats["total"] == 2, "全图记录 2 条（视野外的也在数据层里）")
	_check(stats["loaded"] == 1, "只实例化了视野内的 1 个（实际 %d）" % stats["loaded"])
	if stats["loaded"] == 1:
		var ent: ResourceEntity = _mgr._entities[0]
		_check(absf(ent.global_position.x - 6.0) < 0.01, "实例化的正是视野内那一棵（x≈6）")
		_check(ent.is_inside_tree(), "实体确实在场景树里")


# ----------------------------------------
# 2. 卸载不丢状态（对象池复用不能把"已采集"洗成"完好"）
# ----------------------------------------
func _test_state_kept() -> void:
	print("\n--- 2. 离开视野：退回对象池但状态不丢 ---")
	var ent: ResourceEntity = _mgr._entities[0]
	ent.set_state(ResourceState.State.HARVESTED)
	_check(int(_mgr._records[0]["state"]) != int(ResourceState.State.HARVESTED),
		"实体还在场上时，记录层尚未回写")

	# 玩家跑到远处 → 近处那棵卸载，远处那棵加载
	_phys.position = Vector3(220.0, 0.0, 220.0)
	await create_timer(0.5).timeout

	var stats: Dictionary = _mgr.get_stream_stats()
	_check(stats["loaded"] == 1, "视野换地方后仍是 1 个实体在场上")
	_check(int(_mgr._records[0]["state"]) == int(ResourceState.State.HARVESTED),
		"卸载时状态已回写到记录层（没丢）")
	if stats["loaded"] == 1:
		_check(_mgr._entities[0].global_position.x > 200.0, "现在实例化的是远处那棵")
		_check(not _mgr._entities[0].pinned, "普通资源没有被钉住（可以被卸载）")

	# 走回去 → 重新实例化，应该还是"已采集"，不会白白复活
	_phys.position = Vector3.ZERO
	await create_timer(0.5).timeout
	stats = _mgr.get_stream_stats()
	_check(stats["loaded"] == 1, "回到原处后近处那棵被重新实例化")
	if stats["loaded"] == 1:
		var back: ResourceEntity = _mgr._entities[0]
		_check(back.global_position.x < 10.0, "重新实例化的是近处那棵")
		_check(back.current_state == ResourceState.State.HARVESTED, "重新实例化后仍是已采集")


# ----------------------------------------
# 3. 视野外的资源照样长
# ----------------------------------------
func _test_regen_while_away() -> void:
	print("\n--- 3. 视野外的资源继续再生 ---")
	var rec := _mgr.add_record(&"berry", Vector3(600.0, 0.0, 600.0),
		int(ResourceState.State.HARVESTED), 1.2)
	_check(_mgr.get_stream_stats()["regen_watch"] == 1, "它进了再生看护名单")
	_check(int(rec["state"]) == int(ResourceState.State.HARVESTED), "当前是已采集")

	await create_timer(1.8).timeout

	_check(int(rec["state"]) == int(ResourceState.State.GROWING), "倒计时走完自动回到生长态")
	_check(_mgr.get_stream_stats()["regen_watch"] == 0, "看护名单已清空")


# ----------------------------------------
# 4. 存档往返（记录层是权威来源）
# ----------------------------------------
func _test_save_roundtrip() -> void:
	print("\n--- 4. 存档往返 ---")
	var stats: Dictionary = _mgr.get_stream_stats()
	var save: Dictionary = _mgr.save_game()
	var list: Array = save.get("resources", [])
	_check(list.size() == stats["total"],
		"存档 %d 条 = 全图记录 %d 条（视野外的也存了）" % [list.size(), stats["total"]])
	if not list.is_empty():
		var first: Dictionary = list[0]
		_check(first.has("resource_id") and first.has("position") and first.has("state") and first.has("regen_time_remaining"),
			"键名与旧存档一致（resource_id / position / state / regen_time_remaining）")

	_mgr.clear_all_resources()
	_check(_mgr.get_stream_stats()["total"] == 0 and _mgr.get_stream_stats()["loaded"] == 0,
		"清场后记录与实体都为空")

	_mgr.load_game(save)
	_check(_mgr.get_stream_stats()["total"] == list.size(), "读档后记录数一致")
	await create_timer(0.5).timeout
	_check(_mgr.get_stream_stats()["loaded"] >= 1, "读档后视野内的资源被重新装配出来")
