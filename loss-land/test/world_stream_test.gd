# test/world_stream_test.gd
# 敌人与地面掉落物「视野流式加载」headless 验证
#
# 覆盖：
#   1. 只有玩家附近的敌人才在场景树里，超过卸载距离的被"挂起"（remove_child，不销毁）
#   2. 挂起不丢状态：血量、掉落物剩余数量、巡逻/追击等运行态都跟着节点活着
#   3. 重新入树不会重复初始化（Godot 重新入树会再发一次 ready 通知）
#   4. 远距离外的敌人/掉落物照样进存档（别处扫组扫不到它们）
#   5. 存档里没有的敌人 = 已被击杀 → 读档后连记录一起删掉
#   6. 节点被销毁（怪死 / 掉落物被捡光）后，记录跟着清掉
#
# 装载/卸载距离是常数（ViewFrustum.LOAD_RADIUS），不经相机，
# 所以断言可以用具体米数，不受分辨率与镜头角度影响。
#
# 运行：
#   godot --headless --script test/world_stream_test.gd
extends SceneTree

var _passed: int = 0
var _failed: int = 0

var _scene: Node3D = null
var _player: Node3D = null
var _phys: Node3D = null
var _ws: WorldStreamer = null
var _enemy_near: FakeEnemy = null
var _enemy_far: FakeEnemy = null
var _drop_near: ItemDrop = null
var _drop_far: ItemDrop = null

const NEAR := Vector3(6.0, 0.0, 6.0)
const FAR := Vector3(220.0, 0.0, 220.0)


# ----------------------------------------
# 假敌人：只需要存档接口 + _state + _current_health，
# 就能覆盖 WorldStreamer 用到的全部敌人侧契约。
# ready_runs 是"重新入树是否重复初始化"的探针。
# ----------------------------------------
class FakeEnemy extends Node3D:
	var _state: String = "idle"
	var _current_health: int = 20
	var max_health: int = 20
	var ready_runs: int = 0
	var _initialized: bool = false

	func _ready() -> void:
		if _initialized:
			return
		_initialized = true
		ready_runs += 1
		add_to_group("enemy")

	func get_save_data() -> Dictionary:
		return {
			"position": {"x": global_position.x, "y": global_position.y, "z": global_position.z},
			"health": _current_health,
		}

	func apply_save_data(data: Dictionary) -> void:
		var p: Dictionary = data.get("position", {})
		if not p.is_empty():
			global_position = Vector3(
				float(p.get("x", global_position.x)),
				float(p.get("y", global_position.y)),
				float(p.get("z", global_position.z)))
		_current_health = clampi(int(data.get("health", max_health)), 1, max_health)


func _initialize() -> void:
	await process_frame
	_build_world()
	await _test_stream_radius()
	await _test_stream_scope()
	await _test_state_kept()
	await _test_save_roundtrip()
	await _test_killed_enemy_removed()
	await _test_freed_records_purged()
	print("\n========== 敌人 / 掉落物视野流式加载测试 ==========")
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
# 最小世界：自己当 current_scene 的容器 + 玩家 + 两只敌人 + 两个掉落物
#
# 不需要相机 —— 装载判定只看"距玩家多少米"，
# 判定完全确定，不受屏幕分辨率与镜头角度影响（300 米外的必然在半径外）。
# ----------------------------------------
func _build_world() -> void:
	_scene = Node3D.new()
	_scene.name = "TestScene"
	root.add_child(_scene)
	# 敌人存档按"相对 current_scene 的路径"匹配，headless 下必须显式指定
	current_scene = _scene

	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	_scene.add_child(_player)
	_phys = Node3D.new()
	_phys.name = "Physics"
	_player.add_child(_phys)

	_enemy_near = FakeEnemy.new()
	_enemy_near.name = "SlimeNear"
	_enemy_near.position = NEAR
	_scene.add_child(_enemy_near)

	_enemy_far = FakeEnemy.new()
	_enemy_far.name = "SlimeFar"
	_enemy_far.position = FAR
	_scene.add_child(_enemy_far)

	_drop_near = ItemDrop.spawn_item_by_id(&"battery", 3, NEAR)
	_drop_far = ItemDrop.spawn_item_by_id(&"battery", 5, FAR)

	_ws = WorldStreamer.new()
	_ws.name = "WorldStreamer"
	_scene.add_child(_ws)


# ----------------------------------------
# 0. 距离判定：装载 / 卸载半径就是两个可改的常数
# ----------------------------------------
func _test_stream_radius() -> void:
	print("\n--- 0. 距离判定 ---")
	var enemy_load: float = ViewFrustum.load_radius("enemy")
	var enemy_keep: float = ViewFrustum.unload_radius("enemy")
	_check(enemy_keep > enemy_load,
		"卸载半径 > 装载半径（有滞回带，实际 %.0f / %.0f 米）" % [enemy_load, enemy_keep])
	_check(absf(enemy_load - float(ViewFrustum.LOAD_RADIUS["enemy"])) < 0.01,
		"半径取自常量表，可直接定量修改（enemy=%.0f 米）" % enemy_load)
	_check(ViewFrustum.distance_to_player(self, NEAR) <= enemy_load,
		"近处单位约 %.1f 米，在装载半径内" % ViewFrustum.distance_to_player(self, NEAR))
	_check(ViewFrustum.distance_to_player(self, FAR) > enemy_keep,
		"远处单位约 %.1f 米，在卸载半径外" % ViewFrustum.distance_to_player(self, FAR))


# ----------------------------------------
# 1. 只装配视野内的
# ----------------------------------------
func _test_stream_scope() -> void:
	print("\n--- 1. 只装配视野内的敌人与掉落物 ---")
	_ws.stream_now()
	var stats: Dictionary = _ws.get_stream_stats()
	_check(int(stats["enemies_total"]) == 2, "两只敌人都进了记录（全图 2）")
	_check(int(stats["enemies_loaded"]) == 1, "只装配了视野内那只（实际 %d）" % stats["enemies_loaded"])
	_check(_enemy_near.get_parent() != null, "近处敌人在场景树里")
	_check(_enemy_far.get_parent() == null, "远处敌人已挂起（移出场景树，节点没销毁）")
	_check(is_instance_valid(_enemy_far), "挂起的敌节点仍然有效（不是 queue_free）")
	_check(int(stats["drops_total"]) == 2, "两个掉落物都进了记录")
	_check(int(stats["drops_loaded"]) == 1, "只装配了视野内那个（实际 %d）" % stats["drops_loaded"])
	_check(_drop_far.get_parent() == null, "远处掉落物已挂起")


# ----------------------------------------
# 2. 挂起不丢状态 + 重新入树不重复初始化
# ----------------------------------------
func _test_state_kept() -> void:
	print("\n--- 2. 挂起不丢状态、放回不重复初始化 ---")
	_enemy_near._current_health = 7
	_drop_near.count = 2

	# 玩家跑到远处 → 近处挂起、远处放回
	_phys.position = FAR
	_ws.stream_now()

	_check(_enemy_near.get_parent() == null, "近处敌人被挂起")
	_check(_enemy_near._current_health == 7, "挂起后血量仍是 7（没有被重置成满血）")
	_check(_enemy_far.get_parent() != null, "远处敌人被放回场景树")
	_check(_enemy_far.ready_runs == 1, "初始化只跑了一次（幂等；ready_runs=%d）" % _enemy_far.ready_runs)
	_check(_enemy_far.is_in_group("enemy"), "放回后仍在 enemy 组（扫组的老逻辑找得到）")
	var fp: Vector3 = _enemy_far.global_position
	_check(absf(fp.x - FAR.x) < 0.01 and absf(fp.z - FAR.z) < 0.01, "放回后落在原位置")

	_check(_drop_near.count == 2, "挂起的掉落物保留剩余数量（2）")
	_check(_drop_far.get_parent() != null, "远处掉落物被放回")
	_check(_drop_far.find_children("*", "MeshInstance3D", true, false).size() == 1,
		"放回后视觉只有一份（没有重复拼装第二套）")


# ----------------------------------------
# 3. 存档往返（挂起的也在档里）
# ----------------------------------------
func _test_save_roundtrip() -> void:
	print("\n--- 3. 存档往返：视野外的也存得住 ---")
	_phys.position = Vector3.ZERO
	_ws.stream_now()

	var enemies: Array = _ws.collect_enemies()
	var drops: Array = _ws.collect_drops()
	_check(enemies.size() == 2, "敌人存了 2 条（含视野外被挂起那只）：%d" % enemies.size())
	_check(drops.size() == 2, "掉落物存了 2 条（含视野外被挂起那个）：%d" % drops.size())

	var by_path: Dictionary = {}
	for e in enemies:
		by_path[String(e.get("path", ""))] = e
	_check(by_path.has("SlimeNear") and by_path.has("SlimeFar"),
		"键名与旧存档一致（path 指向场景节点）")

	if by_path.has("SlimeNear"):
		_check(int(by_path["SlimeNear"].get("health", 0)) == 7, "已装配敌人的血量 = 7")
	if by_path.has("SlimeFar"):
		var pd: Dictionary = by_path["SlimeFar"].get("position", {})
		_check(absf(float(pd.get("x", 0.0)) - FAR.x) < 0.01,
			"挂起敌人的坐标取自记录（x=%.1f）" % float(pd.get("x", 0.0)))
		_check(int(by_path["SlimeFar"].get("health", 0)) == 20, "挂起敌人的血量取自节点变量（20）")

	var counts: Array = []
	for d in drops:
		counts.append(int(d.get("count", 0)))
	counts.sort()
	_check(str(counts) == "[2, 5]", "掉落物数量正确（2 与 5）：%s" % str(counts))

	# 模拟读档：应用回来，视野内仍然只装配 1 个
	_ws.apply_enemies(enemies)
	_ws.apply_drops(drops)
	_ws.stream_now()
	var stats: Dictionary = _ws.get_stream_stats()
	_check(int(stats["enemies_total"]) == 2 and int(stats["enemies_loaded"]) == 1,
		"读档后敌人 记录 2 / 装配 1")
	_check(int(stats["drops_total"]) == 2 and int(stats["drops_loaded"]) == 1,
		"读档后掉落物 记录 2 / 装配 1")


# ----------------------------------------
# 4. 存档里没有的敌人 = 已被击杀
# ----------------------------------------
func _test_killed_enemy_removed() -> void:
	print("\n--- 4. 存档里没有的敌人 = 已被击杀 ---")
	var only_near: Array = []
	for e in _ws.collect_enemies():
		if String(e.get("path", "")) == "SlimeNear":
			only_near.append(e)
	_check(only_near.size() == 1, "构造了一个只含 SlimeNear 的存档")

	_ws.apply_enemies(only_near)
	await process_frame
	_ws.stream_now()

	var stats: Dictionary = _ws.get_stream_stats()
	_check(int(stats["enemies_total"]) == 1, "记录里只剩 1 只（实际 %d）" % stats["enemies_total"])
	_check(not is_instance_valid(_enemy_far), "被击杀的敌节点已销毁")
	_check(is_instance_valid(_enemy_near), "存档里有的敌节点还在")


# ----------------------------------------
# 5. 节点被销毁 → 记录跟着清掉
# ----------------------------------------
func _test_freed_records_purged() -> void:
	print("\n--- 5. 被捡光的掉落物记录会被清掉 ---")
	var before: int = int(_ws.get_stream_stats()["drops_total"])
	var node = _loaded_drop_node()
	_check(node != null, "取到一个已装配的掉落物")
	if node != null:
		node.free()  # 等价于"被捡光后 queue_free"
		await process_frame
		_ws.stream_now()
		var after: int = int(_ws.get_stream_stats()["drops_total"])
		_check(after == before - 1, "记录数 %d → %d（节点没了记录也跟着走）" % [before, after])


# ----------------------------------------
# 取一个当前已装配的掉落物节点（供断言/构造场景用）
# ----------------------------------------
func _loaded_drop_node() -> ItemDrop:
	for rec in _ws._drop_records:
		if bool(rec["loaded"]):
			var n = rec["node"]
			if n is ItemDrop:
				return n
	return null
