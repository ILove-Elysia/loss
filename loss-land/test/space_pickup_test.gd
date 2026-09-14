# test/space_pickup_test.gd
# ============================================
# 拾取改为"靠近后按空格"回归测试（headless）
#
# 验证：
#   [1] 玩家进入拾取半径 → _nearby_player 被标记 + 显示"空格拾取"提示
#   [2] 在范围内按下 pickup 动作（空格）→ 物品入背包，并解除 nearby
#   [3] 在范围内但不按键 → 不拾取（物品仍在地上、仍等待按键）
#   [4] 远离掉落物（超出半径）→ 不标记 nearby，按空格也不拾取
#
# 注意：模拟输入用 Input.action_press("pickup")（合成动作按下），
# 由 ItemDrop._process 里的 Input.is_action_just_pressed 读取。
# Area 检测需要 ~2 个物理帧才注册，故每次靠近都先等 3 帧再操作。
# ============================================

extends SceneTree

var _failures: int = 0
var _player: Node3D = null
var _inventory: Node = null
var _vitals: Node = null


func _initialize() -> void:
	await process_frame
	await process_frame

	_setup_mock_player()

	print("=================================")
	print("[1] 靠近检测 + 提示")
	await _test_proximity()

	print("[2] 按空格拾取")
	await _test_space_pickup()

	print("[3] 不按键不拾取")
	await _test_no_pickup_without_space()

	print("[4] 远离不拾取")
	await _test_far_no_pickup()

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


## mock 玩家：StaticBody3D（player 组 + 碰撞体，触发 Area 信号）+ Inventory + Vitals
func _setup_mock_player() -> void:
	_player = StaticBody3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	col.shape = sphere
	_player.add_child(col)
	root.add_child(_player)

	_inventory = preload("res://script/inventory/inventory.gd").new()
	_inventory.name = "Inventory"
	_player.add_child(_inventory)

	_vitals = preload("res://script/player/vitals.gd").new()
	_vitals.name = "Vitals"
	_player.add_child(_vitals)
	await process_frame


## 合成"拾取键按下"。is_action_just_pressed 只在一个物理帧为真，
## 与帧边界存在竞态（headless 偶发丢失），故连按若干次保证至少一帧被 _process 捕获。
func _press_pickup() -> void:
	for i in range(6):
		Input.action_press("pickup")
		await physics_frame
		Input.action_release("pickup")
		await physics_frame


## 等足够物理帧让 Area 把玩家标记为 nearby（实测需 ~2 帧）
func _wait_proximity(drop: ItemDrop) -> void:
	for i in range(4):
		await physics_frame
		if drop._nearby_player != null:
			return


func _test_proximity() -> void:
	var drop := ItemDrop.spawn_item_by_id(&"battery", 1, Vector3.ZERO)
	drop._age = 1.0  # 跳过出生保护期
	await _wait_proximity(drop)
	_check(drop._nearby_player == _player, "走近后标记 nearby_player")
	_check(drop._prompt != null and drop._prompt.visible, "显示「空格拾取」提示")
	drop.queue_free()
	await physics_frame


func _test_space_pickup() -> void:
	var drop := ItemDrop.spawn_item_by_id(&"battery", 2, Vector3.ZERO)
	drop._age = 1.0
	await _wait_proximity(drop)
	_check(drop._nearby_player == _player, "proximity 已注册（前置）")
	await _press_pickup()
	_check(_inventory.get_item_count(&"battery") == 2, "按空格后电池入背包（实际 %d）" % _inventory.get_item_count(&"battery"))
	_check(drop._nearby_player == null, "拾取后解除 nearby（等待消失动画）")


func _test_no_pickup_without_space() -> void:
	var before: int = _inventory.get_item_count(&"slime_gel")
	var drop := ItemDrop.spawn_item_by_id(&"slime_gel", 1, Vector3.ZERO)
	drop._age = 1.0
	await _wait_proximity(drop)
	await physics_frame
	await physics_frame  # 故意不按键，等两帧
	_check(_inventory.get_item_count(&"slime_gel") == before, "未按键不拾取（背包凝胶数不变）")
	_check(drop._nearby_player == _player, "仍标记 nearby（等待玩家按键）")
	_check(drop.count == 1, "物品仍留在地上")
	await _press_pickup()  # 收尾清掉


func _test_far_no_pickup() -> void:
	_player.global_position = Vector3(50, 0, 50)  # 移到远处
	await physics_frame
	var drop := ItemDrop.spawn_item_by_id(&"battery", 1, Vector3.ZERO)
	drop._age = 1.0
	await physics_frame
	await physics_frame
	await _press_pickup()
	_check(drop._nearby_player == null, "远离时未标记 nearby")
	_check(drop.count == 1, "远离时按空格也不拾取（仍在地上）")
