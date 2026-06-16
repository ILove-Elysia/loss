extends CharacterBody3D

# 导出变量：角色移动速度，编辑器可直接修改
@export var speed: float = 5.0
# 重力强度
@export var gravity: float = 20.0

@onready var spr: AnimatedSprite3D = get_parent().get_node("Visual/BaseBody")
@onready var visual_node: Node3D = get_parent().get_node("Visual")

func _ready():
	# 设置向上方向（用于地板检测）
	up_direction = Vector3.UP
	# 游戏启动默认播放待机
	spr.play("idle")

func _physics_process(delta):
	# ===== 获取移动方向 =====
	var dir = Vector3.ZERO
	
	# 获取相机方向（用于相对移动）
	var cam = get_viewport().get_camera_3d()
	if cam:
		var cam_dir = cam.global_basis
		# Godot Camera3D 看向 -z 方向，所以向前是 -z
		var forward = -cam_dir.z
		var right = cam_dir.x
		forward.y = 0
		right.y = 0
		forward = forward.normalized()
		right = right.normalized()
		
		# WASD 移动输入（相对于相机方向）
		if Input.is_action_pressed("move_forward"):
			dir += forward
		if Input.is_action_pressed("move_back"):
			dir -= forward
		if Input.is_action_pressed("move_right"):
			dir += right
		if Input.is_action_pressed("move_left"):
			dir -= right
	
	# ===== 应用重力 =====
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	# ===== 应用移动 =====
	if dir.length() > 0:
		dir = dir.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	else:
		# 没有输入时停止水平移动
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	# 执行移动（关键！）
	move_and_slide()
	
	# ===== 同步视觉节点位置 =====
	visual_node.global_position = global_position
	
	# ===== 动画控制 + 朝向翻转 =====
	if dir.length() > 0:
		if spr.animation != "walk":
			spr.play("walk")
		
		# 只在左右移动时翻转，前后移动不改变朝向
		# flip_h = true 表示朝左，flip_h = false 表示朝右
		if abs(dir.x) > 0.1:
			if dir.x > 0:
				# 向右移动，朝右
				spr.flip_h = true
			else:
				# 向左移动，朝左
				spr.flip_h = false
	else:
		if spr.animation != "idle":
			spr.play("idle")
