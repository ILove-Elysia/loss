extends SceneTree

# 临时验证脚本：检查史莱姆 AI 的寻路绕障与落水死亡行为
#
#   godot --headless --path . --script res://test/slime_ai_test.gd
#
# 检查项：
#   1. A* 能在两个相隔较远的区域之间给出全程落在陆地上的路径
#   2. 史莱姆自由活动数秒后仍存活且始终站在陆地上
#   3. 把史莱姆丢进海里后它会下沉并被销毁（死亡）
#
# 注意：海面坐标不再硬编码（地图尺度变化后死坐标会落在岛上），
# 改由 _find_sea_point() 运行时查询真实海域。

var _scene: Node = null
var _slime: CharacterBody3D = null
var _gen: Node = null

var _time: float = 0.0
var _phase: int = 0
var _phase_timer: float = 0.0
var _fail_count: int = 0

var _off_land_violations: int = 0
var _max_distance_moved: float = 0.0
var _last_slime_pos: Vector3 = Vector3.ZERO
var _seen_slime: bool = false


func _initialize() -> void:
	_scene = load("res://tscn/map.tscn").instantiate()
	root.add_child(_scene)


func _process(delta: float) -> bool:
	_time += delta
	_phase_timer += delta
	match _phase:
		0:
			if _phase_timer > 1.0:
				_start_phase1()
		1:
			_run_phase1()
		2:
			_run_phase2()
		3:
			_run_phase3()
	return false


# ---------------- 阶段1：A* 寻路检查 ----------------
func _start_phase1() -> void:
	_gen = get_first_node_in_group("map_gen")
	if _gen == null:
		print("[失败] 找不到地图生成器（map_gen 组）")
		_fail_count += 1
		quit()
		return

	var players: Array = get_nodes_in_group("player")
	if players.is_empty():
		print("[失败] 找不到玩家")
		_fail_count += 1
		quit()
		return

	var enemies: Array = get_nodes_in_group("enemy")
	if enemies.is_empty():
		print("[失败] 找不到史莱姆（enemy 组）")
		_fail_count += 1
		quit()
		return
	_slime = enemies[0]
	_last_slime_pos = _slime.global_position
	_seen_slime = true

	# 专门的绕行测试：找一对"直线会穿海"的陆地点对，验证 A* 能绕开
	var found_pair: bool = false
	for attempt in range(400):
		var a: Vector3 = _random_land_point()
		var b: Vector3 = _random_land_point()
		if a == Vector3.ZERO or b == Vector3.ZERO:
			continue
		var dist: float = Vector2(a.x - b.x, a.z - b.z).length()
		if dist < 12.0 or dist > 60.0:
			continue
		if not _segment_crosses_water(a, b):
			continue  # 直线本就可走，换一对

		found_pair = true
		var detour: Array = _gen.find_world_path(a, b)
		var walked: float = 0.0
		var prev: Vector3 = a
		for p in detour:
			walked += Vector2(prev.x - p.x, prev.z - p.z).length()
			prev = p
		print("[绕行] 点对 #%d 直线=%.1f 路径=%.1f 航点=%d" % [attempt, dist, walked, detour.size()])
		if detour.is_empty():
			print("[失败] 明明存在绕行路线，却返回空路径")
			_fail_count += 1
		elif _path_crosses_water(a, detour):
			print("[失败] A* 路径仍然穿过海面")
			_fail_count += 1
		elif walked <= dist:
			print("[失败] 路径长度未大于直线距离（没有真的绕行）")
			_fail_count += 1
		else:
			print("[绕行] 通过：所有航点均在陆地上，且绕路长度大于直线")
		break
	if not found_pair:
		print("[注意] 400 次抽样未找到需要绕行的点对（地图较连通），跳过该项")

	# 绕开墙体等物理碰撞体的能力
	_test_obstacle_avoidance()

	# 目标点在海中央时应判定不可达（或自动落到最近陆地）
	var from: Vector3 = _gen.get_task_world_position("Grassland", 0.0)
	var sea_target: Vector3 = _find_sea_point()
	if sea_target == Vector3.ZERO or _gen.is_land_world(sea_target):
		print("[注意] 未找到合适的远海点，跳过不可达检查")
	else:
		var path2: Array = _gen.find_world_path(from, sea_target)
		if path2.is_empty():
			print("[寻路] 目标在远海 → 正确返回空路径")
		else:
			var last_point: Vector3 = path2[-1]
			if _gen.is_land_world(last_point):
				print("[寻路] 目标在远海 → 已自动重定向到最近陆地末点")
			else:
				print("[失败] 路径末点仍落在海上")
				_fail_count += 1

	_phase = 1
	_phase_timer = 0.0


# 绕障单元测试：在史莱姆正前方立一堵墙，要求它选出一个不会被挡的方向
func _test_obstacle_avoidance() -> void:
	var wall := StaticBody3D.new()
	wall.name = "TestWall"
	wall.collision_layer = 1  # 史莱姆 collision_mask=3，能检测到这一层
	wall.position = _slime.global_position + Vector3(0.8, 0.5, 0.0)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 2.0, 8.0)  # 横向长墙，堵住 +X 方向
	col.shape = box
	wall.add_child(col)
	_scene.add_child(wall)

	# StaticBody3D 加入场景后不是立刻进入物理空间，先等一帧再探测
	# （SceneTree 脚本里没有 get_tree()，直接用 SceneTree 自己的 physics_frame 信号）
	await physics_frame

	if not is_instance_valid(_slime):
		return

	var toward_wall := Vector3(1.0, 0.0, 0.0)
	var straight_blocked: bool = _slime.test_move(_slime.global_transform, toward_wall * _slime.obstacle_probe)
	var chosen: Vector3 = _slime._avoid_obstacles(toward_wall)
	var chosen_blocked: bool = chosen != Vector3.ZERO and _slime.test_move(
		_slime.global_transform, chosen * _slime.obstacle_probe)

	print("[绕障] 直行为被挡=%s，选出的朝向=%s，该朝向是否被挡=%s"
		% [straight_blocked, str(chosen), chosen_blocked])

	if not straight_blocked:
		print("[注意] test_move 未检测到墙，绕障检查无效")
	elif chosen == Vector3.ZERO:
		print("[失败] 所有候选方向都被判定为受阻，史莱姆会卡死")
		_fail_count += 1
	elif chosen_blocked:
		print("[失败] 选出的方向依然会撞墙")
		_fail_count += 1
	elif chosen.dot(toward_wall) > 0.9:
		print("[失败] 仍直冲墙面，没有绕行")
		_fail_count += 1
	else:
		print("[绕障] 通过：成功选出一个绕开墙面的可行方向")

	wall.queue_free()


# ---------------- 阶段2：自由活动，检查是否掉出海里 ----------------
func _run_phase1() -> void:
	if not is_instance_valid(_slime):
		print("[失败] 史莱姆在自由活动阶段就被销毁了")
		_fail_count += 1
		_next_phase()
		return

	_max_distance_moved += _last_slime_pos.distance_to(_slime.global_position)
	_last_slime_pos = _slime.global_position

	if not _gen.is_land_world(_slime.global_position):
		_off_land_violations += 1

	if _phase_timer > 8.0:
		print("[活动] 8 秒内移动了 %.2f 米，脱离陆地帧数=%d，最终位置=%s"
			% [_max_distance_moved, _off_land_violations, str(_slime.global_position)])
		if _off_land_violations > 0:
			print("[失败] 史莱姆离开了陆地")
			_fail_count += 1
		if _max_distance_moved < 0.5:
			print("[失败] 史莱姆几乎没有移动（AI 可能卡死）")
			_fail_count += 1
		_next_phase()


func _next_phase() -> void:
	_phase += 1
	_phase_timer = 0.0


# ---------------- 阶段3：丢进海里，应下沉并死亡 ----------------
func _run_phase2() -> void:
	if not is_instance_valid(_slime):
		print("[失败] 进入落水测试前史莱姆已消失")
		_fail_count += 1
		_phase = 3
		_phase_timer = 0.0
		return

	# 传送到真实远海（动态查询海面坐标，避免地图尺度变化后死坐标落在岛上）
	var sea_pos: Vector3 = _find_sea_point()
	if sea_pos == Vector3.ZERO:
		print("[失败] 找不到海面坐标，无法验证落水")
		_fail_count += 1
		_phase = 3
		_phase_timer = 0.0
		return
	_slime.global_position = sea_pos + Vector3(0.0, 0.2, 0.0)
	_slime.velocity = Vector3.ZERO
	print("[落水] 已把史莱姆放到 %s，当前是否海面=%s"
		% [str(sea_pos), str(not _gen.is_land_world(_slime.global_position))])
	_phase = 3
	_phase_timer = 0.0


func _run_phase3() -> void:
	if not is_instance_valid(_slime):
		_finish()
		return
	if _phase_timer > 0.05 and _phase_timer < 0.1:
		print("[落水] %.2f 秒后 y=%.2f" % [_phase_timer, _slime.global_position.y])
	if _phase_timer > 5.0:
		print("[失败] 史莱姆落水 5 秒后仍未死亡")
		_fail_count += 1
		_finish()


func _random_land_point() -> Vector3:
	for attempt in range(60):
		var x: float = randf_range(-180.0, 180.0)
		var z: float = randf_range(-180.0, 180.0)
		var p := Vector3(x, 0.0, z)
		if _gen.is_land_world(p):
			# 吸附到瓦片中心：与寻路内部的"起点按瓦片计算"保持一致
			return _gen.tile_to_world(_gen.world_to_tile(p))
	return Vector3.ZERO


# 动态查询一个真实海面坐标：从地图外圈向中心螺旋收缩，找到第一个海洋瓦片
# 地图岛屿居中、四周环海，因此越靠近边缘越可能是海
func _find_sea_point() -> Vector3:
	if _gen == null or not _gen.has_method("get_world_size"):
		return Vector3.ZERO
	var world_size: Vector2 = _gen.get_world_size()
	var half: float = world_size.x / 2.0
	# 由外向内扫描：地图岛屿居中、四周环海，越靠近边缘越可能是海
	var radii: Array = [0.97, 0.9, 0.8]
	for r in radii:
		for ang_deg in range(0, 360, 10):
			var rad: float = deg_to_rad(float(ang_deg))
			var p := Vector3(cos(rad) * half * r, 0.0, sin(rad) * half * r)
			if not _gen.is_land_world(p):
				return p
	return Vector3.ZERO


# 直线采样：判断两点之间的直线是否经过海面
func _segment_crosses_water(a: Vector3, b: Vector3) -> bool:
	var steps: int = int(a.distance_to(b) * 2.0)
	if steps <= 0:
		return false
	for i in range(steps + 1):
		var p: Vector3 = a.lerp(b, float(i) / float(steps))
		if not _gen.is_land_world(p):
			return true
	return false


# 逐段检查路径（含起点）是否全程落在陆地上
func _path_crosses_water(from: Vector3, path: Array) -> bool:
	var prev: Vector3 = from
	for p in path:
		if _segment_crosses_water(prev, p):
			return true
		prev = p
	return false


func _finish() -> void:
	print("")
	if _fail_count == 0:
		print("===== 全部检查通过 =====")
	else:
		print("===== 存在 %d 项失败 =====" % _fail_count)
	quit()
