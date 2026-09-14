# test/pickup_verify_test.gd
# 验证：凝胶掉落物的 body_entered → try_pickup 全链路能否把物品送进背包。
# 用 await physics_frame 保证真实物理步；显式把 _age 跳到保护期之后，只测"走近触发拾取"这一段。
extends SceneTree

var _player: Node3D
var _inv: Inventory
var _drop: ItemDrop

func _initialize() -> void:
	await physics_frame
	await physics_frame

	_player = Node3D.new()
	_player.name = "player"
	_player.add_to_group("player")
	root.add_child(_player)

	var physics := CharacterBody3D.new()
	physics.name = "Physics"
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.height = 1.0
	cyl.radius = 0.33
	col.shape = cyl
	col.position = Vector3(0, 0.5, 0)
	physics.add_child(col)
	_player.add_child(physics)

	_inv = Inventory.new()
	_inv.name = "Inventory"
	_player.add_child(_inv)
	await physics_frame

	# 在玩家 3 米外生成凝胶掉落
	_drop = ItemDrop.spawn_item_by_id(&"slime_gel", 1, Vector3(3.0, 0.0, 0.0))
	_drop._age = 1.0  # 跳过 0.4s 拾取保护，专注测触发段
	print("[测试] 生成凝胶掉落: %s" % (_drop != null))

	# 让 Area3D 完成首帧检测（此时玩家未重叠，不应拾取）
	for i in range(5):
		await physics_frame
	var before := _inv.get_item_count(&"slime_gel")
	print("走近前背包凝胶: %d" % before)

	# 玩家"走"到掉落点上方 → 触发 body_entered
	_player.global_position = _drop.global_position

	# 等 body_entered 触发并调用 try_pickup
	for i in range(15):
		await physics_frame

	var cnt := _inv.get_item_count(&"slime_gel")
	var still_there := (_drop != null and is_instance_valid(_drop))
	print("===== 拾取测试结果 =====")
	print("背包中凝胶数量: %d" % cnt)
	print("掉落物是否仍在世界: %s" % still_there)
	if cnt >= 1:
		print("RESULT: PASS - 凝胶被自动拾取进背包")
	else:
		print("RESULT: FAIL - 凝胶未被拾取（body_entered 未触发或 try_pickup 失败）")
	quit()
