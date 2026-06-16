extends Camera3D

# 跟随目标：直接指向顶层player
@export var target: Node3D
# 相机基础偏移（相对于玩家身后上方）
@export var base_offset: Vector3 = Vector3(0, 5, -8)
# 平滑跟随系数
@export var smooth_factor: float = 4.0

# 水平旋转总角度（弧度）
var yaw_rad: float = 0.0
# 单次Q/E旋转45°
const rotate_step: float = deg_to_rad(45)

# FOV缩放参数
@export var min_fov: float = 30.0
@export var max_fov: float = 80.0
@export var zoom_speed: float = 2.0

# FOV平滑过渡
var current_fov: float = 50.0

func _ready():
	projection = PROJECTION_PERSPECTIVE
	fov = 50.0
	current_fov = 50.0
	# 自动赋值目标，不用手动拖拽（适配你的节点树）
	if not target:
		target = get_parent().get_parent().get_parent()

func _input(event: InputEvent) -> void:
	# 滚轮缩放 FOV 目标值（不是即时改变）
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			current_fov = clamp(current_fov - zoom_speed, min_fov, max_fov)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			current_fov = clamp(current_fov + zoom_speed, min_fov, max_fov)

func _process(delta: float) -> void:
	if not target:
		return

	# Q/E单次旋转45°，按一次转一次
	if Input.is_action_just_pressed("rotate_left"):
		yaw_rad -= rotate_step
	if Input.is_action_just_pressed("rotate_right"):
		yaw_rad += rotate_step

	# 计算旋转后的偏移（绕世界Y轴旋转，环绕玩家）
	var rotated_offset = base_offset.rotated(Vector3.UP, yaw_rad)
	var target_cam_global_pos = target.global_position + rotated_offset

	# 平滑插值更新相机全局坐标
	var t = 1.0 - pow(0.001, smooth_factor * delta)
	global_position = global_position.lerp(target_cam_global_pos, t)
	
	# 平滑插值更新 FOV
	fov = lerp(fov, current_fov, t)
	
	# 镜头始终看向玩家
	look_at(target.global_position, Vector3.UP)
