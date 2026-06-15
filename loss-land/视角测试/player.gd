# 让当前脚本继承自 CharacterBody3D（Godot3D专用角色移动节点）
# 这个节点自带移动、碰撞、跳跃、地面检测功能
extends CharacterBody3D

# 导出变量：角色移动速度，编辑器可直接修改
@export var speed: float = 5.0

# 导出变量：角色跳跃力度，数值越高跳得越高
@export var jump_power: float = 4.0

# 物理更新函数：每帧固定执行（专门处理移动、物理），delta是帧间隔时间
func _physics_process(delta):
	# 定义方向变量 dir，初始值为零向量（没有方向）
	var dir = Vector3.ZERO

	# 获取当前场景中激活的主相机（3D相机）
	var cam = get_viewport().get_camera_3d()
	
	# 如果没有找到相机，直接退出函数，不执行后面的移动逻辑
	if not cam:
		return

	# 获取相机的全局空间朝向信息（决定前后左右方向）
	var cam_dir = cam.global_basis
	
	# 相机的正前方方向（Z轴）
	var forward = cam_dir.z
	
	# 相机的右侧方向（X轴）
	var right = cam_dir.x

	# 把前方方向的Y轴设为0（只保留水平方向，不让角色上下飞）
	forward.y = 0
	
	# 把右侧方向的Y轴设为0（只保留水平移动）
	right.y = 0

	# 标准化前方向量（让长度保持为1，防止斜着走更快）
	forward = forward.normalized()
	
	# 标准化右侧向量
	right = right.normalized()

	# ------------------- 按键输入控制方向 -------------------
	# 按下 W 键：角色往【相机前方】移动
	if Input.is_action_pressed("move_forward"):
		dir -= forward  # 减号 = 远离相机方向（向前）
	
	# 按下 S 键：角色往【相机后方】移动
	if Input.is_action_pressed("move_back"):
		dir += forward  # 加号 = 靠近相机方向（向后）
	
	# 按下 D 键：角色往【相机右侧】移动
	if Input.is_action_pressed("move_right"):
		dir += right
	
	# 按下 A 键：角色往【相机左侧】移动
	if Input.is_action_pressed("move_left"):
		dir -= right

	# 如果方向向量长度大于0（说明正在按方向键）
	if dir.length() > 0:
		# 标准化方向，保证斜着走速度不变
		dir = dir.normalized()

	# 给角色水平速度：X轴 = 方向X * 速度
	velocity.x = dir.x * speed
	
	# 给角色水平速度：Z轴 = 方向Z * 速度
	velocity.z = dir.z * speed

	# ------------------- 跳跃逻辑 -------------------
	# 按下跳跃键 并且 角色站在地面上（才能跳）
	if Input.is_action_just_pressed("jump") and is_on_floor():
		# 设置向上的速度 = 跳跃力度
		velocity.y = jump_power

	# ------------------- 重力逻辑 -------------------
	# 如果角色不在地面上（在空中）
	if not is_on_floor():
		# 向下施加重力（9.8是现实重力值）
		velocity.y -= 9.8 * delta

	# 执行移动：根据 velocity 速度移动角色，并自动处理碰撞
	move_and_slide()
