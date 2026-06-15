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
		var forward = cam_dir.z
		var right = cam_dir.x
		forward.y = 0
		right.y = 0
		forward = forward.normalized()
		right = right.normalized()
		
		# WASD 移动输入
		if Input.is_action_pressed("move_forward"):
			dir -= forward
		if Input.is_action_pressed("move_back"):
			dir += forward
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
	
	# ===== 动画 + 左右转向 =====
	if dir.length() > 0:
		# 播放跑步动画
		if spr.animation != "walk":
			spr.play("walk")
		
		# 按左键 → 朝左 / 按右键 → 朝右
		if Input.is_action_pressed("move_left"):
			spr.flip_h = false
		elif Input.is_action_pressed("move_right"):
			spr.flip_h = true
	else:
		# 松开按键 → 立刻待机
		if spr.animation != "idle":
			spr.play("idle")
