# test/bullet_hit_test.gd
# 验证：无人机弹幕（平行地面平射）能否命中玩家。
#
# 平射的弹道高度 = 枪口高度，所以枪口必须压到玩家躯干（见 drone.fire_height）：
# 玩家碰撞体只有 1.0 米高，若从机体高度（1.5 米）平射，弹幕会从玩家头顶掠过。
# 用 await physics_frame 保证真实物理步，给足飞行时间（6m / 4m/s ≈ 1.5s）。
extends SceneTree

var _proj: DroneProjectile
var _player: Node3D

func _initialize() -> void:
	await physics_frame
	await physics_frame

	# 玩家在原点，身体圆柱 y∈[0,1]
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
	await physics_frame

	# 无人机悬在 (0,2.0,6)，按 drone._fire 的平射逻辑发射：
	# 枪口高度 = 玩家脚下 + fire_height(0.9)，方向只有水平分量
	var drone := Node3D.new()
	root.add_child(drone)
	drone.global_position = Vector3(0, 2.0, 6.0)

	_proj = DroneProjectile.new()
	_proj.damage = 5
	_proj.speed = 4.0
	drone.add_child(_proj)
	await physics_frame

	var target: Vector3 = _player.get_node("Physics").global_position
	var muzzle: Vector3 = drone.global_position
	muzzle.y = target.y + 0.9            # = drone.fire_height
	_proj.launch(muzzle, target)

	# 等弹幕飞到玩家（给足 ~3s，远超 1.5s 飞行时间）
	for i in range(180):
		await physics_frame

	# 命中玩家组后弹幕会 queue_free，实例随之失效
	var hit := (_proj == null or not is_instance_valid(_proj))
	print("===== 弹幕命中测试结果 =====")
	print("弹幕是否已被销毁(命中玩家): %s" % hit)
	print("弹幕末位置: %s" % (_proj.global_position if is_instance_valid(_proj) else "已销毁"))
	if hit:
		print("RESULT: PASS - 弹幕命中玩家")
	else:
		print("RESULT: FAIL - 弹幕越过玩家未命中（检查枪口高度与 launch 的水平弹道）")
	quit()
