# ============================================================
# 玩家角色控制器
#
# 基于 CharacterBody3D 的第三人称玩家控制
#
# 核心功能：
#   1. WASD/方向键移动（基于摄像机朝向）
#   2. 重力系统（下落时施加重力）
#   3. 角色朝向平滑跟随移动方向
#   4. 掉出世界检测（y < -10 时自动传送回出生点）
#
# 坐标系说明：
#   输入方向（屏幕坐标）→ 摄像机相对方向 → 世界方向
#   - W/↑: 向摄像机"前方"移动（实际是 -Z 方向投影到水平面）
#   - S/↓: 向摄像机"后方"移动
#   - A/←: 向摄像机"左方"移动
#   - D/→: 向摄像机"右方"移动
#
# 依赖：
#   - camera_controller_3d.gd：提供 Camera3D 引用
#   - map_generator_3d.gd：提供 teleport_player_to_start() 方法
#   - 玩家节点需加入 "player" 组
# ============================================================
extends CharacterBody3D

# ------------------------------------------------------------
# 玩家常量
# ------------------------------------------------------------

# 移动速度（单位：单位/秒）
# 2000 单位/秒 = 快速移动，约 62 瓦片/秒（TILE_SIZE=32）
const MOVE_SPEED: float = 2000.0

# 重力加速度（单位：单位/秒²）
# 1200 单位/秒² = 约 1.2g，快速下落但不会失控
const GRAVITY: float = 1200.0

# 角色旋转平滑系数
# 值越大旋转越快（10 = 约 0.1 秒完成 180° 转向）
const ROTATION_SPEED: float = 10.0


# ------------------------------------------------------------
# 运行时引用和状态
# ------------------------------------------------------------

# 当前场景的 3D 摄像机引用
# @onready 在 _ready 时获取，用于计算移动方向
# 通过 get_viewport().get_camera_3d() 获取当前激活的摄像机
@onready var _camera: Camera3D = get_viewport().get_camera_3d()

# 上一次的移动方向（世界坐标）
# 用于角色朝向计算：即使停止移动，角色仍保持最后朝向
var _last_move_dir: Vector3 = Vector3.FORWARD

# 掉出世界的 Y 阈值
# 当玩家 Y 坐标低于此值时触发重生
# -10.0 说明：地面在 y=0，碰撞体中心在 y=-0.5
# 玩家掉出碰撞体约 10 单位后才传送，避免误触发
const FALL_OUT_Y_THRESHOLD: float = -10.0

# 缓存的地图生成器引用
# 首次重生时查找一次，后续直接使用（避免每帧查找组）
var _cached_map_gen: Node = null


# ============================================================
# 物理帧更新：每帧处理移动、重力、朝向、掉出检测
#
# 流程：
#   1. 施加重力（仅在不在地面时）
#   2. 读取输入 → 计算屏幕移动方向
#   3. 转换为摄像机相对的世界移动方向
#   4. 设置水平速度（x/z 分量）
#   5. move_and_slide() 执行物理移动
#   6. 平滑旋转角色朝向（面向移动方向）
#   7. 检测是否掉出世界
#
# 为什么用 _physics_process 而非 _process？
#   CharacterBody3D.move_and_slide() 必须在物理帧中调用，
#   以保证物理碰撞的确定性和一致性。
# ============================================================
func _physics_process(delta: float):
	# --- 重力：不在地面时施加向下的加速度 ---
	# is_on_floor() 由 move_and_slide() 上一帧的碰撞结果决定
	# 地面 = 有碰撞体支撑的状态（角色脚底接触地板）
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	# --- 输入读取 ---
	var input_x: float = 0.0
	var input_y: float = 0.0
	# D/→: 向右（屏幕坐标 +X）
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_x += 1.0
	# A/←: 向左（屏幕坐标 -X）
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_x -= 1.0
	# W/↑: 向上（屏幕坐标 -Y，因为屏幕 Y 轴向下）
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_y -= 1.0
	# S/↓: 向下（屏幕坐标 +Y）
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_y += 1.0

	# 归一化输入向量
	# 对角线输入长度为 √2，归一化后保证移动速度一致
	var input_dir: Vector2 = Vector2(input_x, input_y)
	if input_dir.length() > 1.0:
		input_dir = input_dir.normalized()

	# --- 屏幕坐标 → 世界坐标转换 ---
	var move_dir: Vector3 = Vector3.ZERO
	if _camera and input_dir != Vector2.ZERO:
		# 获取摄像机的朝向基向量
		var cam_basis: Basis = _camera.global_transform.basis
		# 摄像机"前方"= -Z 轴（Godot 约定：摄像机朝 +Z 看）
		# 但 camera_controller_3d 的摄像机朝 -Z 方向看，所以用 -cam_basis.z
		var forward: Vector3 = (-cam_basis.z)
		# 去除垂直分量（y=0），只保留水平朝向
		# 这样无论摄像机俯视还是斜视，移动都在水平面上
		forward.y = 0.0
		forward = forward.normalized()
		# 摄像机"右方"= +X 轴
		var right: Vector3 = cam_basis.x
		right.y = 0.0
		right = right.normalized()

		# 合成移动方向：
		#   W/↑ (input_y=-1): forward * 1.0 → 向摄像机前方
		#   S/↓ (input_y=+1): forward * (-1) → 向摄像机后方
		#   A/← (input_x=-1): right * (-1) → 向摄像机左方
		#   D/→ (input_x=+1): right * 1.0 → 向摄像机右方
		move_dir = forward * (-input_dir.y) + right * input_dir.x
		if move_dir.length() > 0.0:
			move_dir = move_dir.normalized()
			# 保存最后移动方向（用于角色朝向，即使停止也保持朝向）
			_last_move_dir = move_dir

	# --- 设置水平速度 ---
	# 仅设置 x/z 分量，y 分量由重力控制
	# 这样跳跃/下落时不会被水平移动覆盖
	velocity.x = move_dir.x * MOVE_SPEED
	velocity.z = move_dir.z * MOVE_SPEED

	# --- 执行物理移动 ---
	# move_and_slide() 是 CharacterBody3D 的核心方法：
	#   1. 按 velocity 移动
	#   2. 检测碰撞（与 StaticBody3D/FloorCollisionContainer）
	#   3. 处理滑动（沿碰撞面滑动）
	#   4. 更新 is_on_floor() 状态
	move_and_slide()

	# --- 角色朝向平滑跟随 ---
	# 仅在有输入时旋转（停止时保持当前朝向）
	if input_dir != Vector2.ZERO:
		# 用 atan2 计算目标朝向角度
		# atan2(x, z) 返回从 +Z 轴正方向顺时针到 (x,0,z) 的角度
		# 这正好是角色应该面向的 Y 轴旋转
		var target_y_rot: float = atan2(_last_move_dir.x, _last_move_dir.z)
		var current_y: float = rotation.y
		# lerp_angle 保证角度插值正确（避免 179° → -179° 的跳变）
		rotation.y = lerp_angle(current_y, target_y_rot, ROTATION_SPEED * delta)

	# --- 掉出世界检测 ---
	# 当玩家 Y 低于阈值时（掉入海洋或地图外）
	# 自动传送回出生点，防止卡死
	if global_position.y < FALL_OUT_Y_THRESHOLD:
		_respawn_to_start()


# ============================================================
# 重生：传送回出生点
#
# 查找策略（两级回退）：
#   1. 优先查找 "map_gen" 组的第一个节点（map_generator_3d.gd）
#      - 若有 teleport_player_to_start() 方法 → 调用它
#      - 若只有 get_start_world_position() → 获取坐标并直接设置
#   2. 回退：直接传送到 (0, 10, 0)（地图中心上方 10 单位）
#
# 为什么两级回退？
#   防止生成器未就绪时玩家无法重生，保证总能回到安全位置
#
# 为什么缓存 _cached_map_gen？
#   get_nodes_in_group() 每帧调用开销较大，缓存后只查找一次
# ============================================================
func _respawn_to_start():
	# 优先使用缓存的生成器引用
	var map_gen = _cached_map_gen
	if map_gen == null or not is_instance_valid(map_gen):
		# 从 "map_gen" 组查找（map_generator_3d.gd 加入了此组）
		var gens: Array = get_tree().get_nodes_in_group("map_gen")
		if gens.is_empty():
			# 无生成器 → 回退到默认位置
			velocity = Vector3.ZERO
			global_position = Vector3(0, 10, 0)
			return
		map_gen = gens[0]
		_cached_map_gen = map_gen

	# 一级：调用 teleport_player_to_start()
	# 此方法会同时同步摄像机目标位置（更流畅）
	if map_gen.has_method("teleport_player_to_start"):
		map_gen.teleport_player_to_start()
	# 二级：仅获取出生点坐标并直接设置
	elif map_gen.has_method("get_start_world_position"):
		var pos: Vector3 = map_gen.get_start_world_position()
		velocity = Vector3.ZERO
		global_position = pos
	else:
		# 回退：默认位置
		velocity = Vector3.ZERO
		global_position = Vector3(0, 10, 0)
