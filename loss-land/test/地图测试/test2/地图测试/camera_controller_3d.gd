extends Camera3D
## ============================================================
##  3D 摄像机控制器（仿照第三人称追踪相机）
## ------------------------------------------------------------
##  在地图中心放置一个空物体 CameraTarget，本相机追踪它。
##  - 滚轮上/下 → FOV 缩小/放大（拉近/拉远），带平滑过渡
##  - Q/E → 绕地图中心（Y 轴）45° 步进旋转
##  - 相机始终 look_at 目标，平滑 lerp 跟随
## ============================================================

# 追踪目标：指向地图中心的空物体 CameraTarget
@export var target: Node3D

# 相机基础偏移（相对于目标）
# 200×200 地图尺度，需要高位略前倾才能看全：
# y=220 提供俯视角，z=180 让相机在目标前方（look_at 会朝向目标）
@export var base_offset: Vector3 = Vector3(0, 220, 180)

# 平滑跟随系数（值越大跟得越紧）
@export var smooth_factor: float = 4.0

# FOV 缩放范围与速度
@export var min_fov: float = 30.0
@export var max_fov: float = 80.0
@export var zoom_speed: float = 2.0

# 水平旋转总角度（弧度），Q/E 累加
var yaw_rad: float = 0.0
# 单次 Q/E 旋转 45°
const rotate_step: float = deg_to_rad(45)

# FOV 平滑过渡的当前目标值
var current_fov: float = 50.0


func _ready() -> void:
	# 透视投影
	projection = PROJECTION_PERSPECTIVE
	fov = 50.0
	current_fov = 50.0

	# 关键：远裁剪面必须 > 相机到地图最远点距离
	# 相机距中心约 284，地图边缘最远点约 425，所以 far=2000 足够
	# 增大 near 提升深度精度，避免平面瓦片 z-fighting
	near = 0.5
	far = 2000.0

	# 自动赋值目标：查找同级 CameraTarget 空物体，无需手动拖拽
	if target == null:
		var p = get_parent()
		if p != null:
			target = p.get_node_or_null("CameraTarget")

	# 若找到目标，立即就位（避免启动时从原点滑过来的动画）
	if target != null:
		var rot_offset = base_offset.rotated(Vector3.UP, yaw_rad)
		global_position = target.global_position + rot_offset
		look_at(target.global_position, Vector3.UP)


func _input(event: InputEvent) -> void:
	# —— 滚轮缩放 FOV 目标值（不是即时改变，_process 里平滑过渡）——
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			current_fov = clamp(current_fov - zoom_speed, min_fov, max_fov)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			current_fov = clamp(current_fov + zoom_speed, min_fov, max_fov)

	# —— Q/E 单次旋转 45°（用物理键直接检测，避免依赖 project.godot 输入映射）——
	if event is InputEventKey and event.pressed:
		if event.physical_keycode == KEY_Q:
			yaw_rad -= rotate_step
		elif event.physical_keycode == KEY_E:
			yaw_rad += rotate_step


func _process(delta: float) -> void:
	if target == null:
		return

	# 计算旋转后的偏移（绕世界 Y 轴旋转，环绕目标）
	var rotated_offset = base_offset.rotated(Vector3.UP, yaw_rad)
	var target_cam_pos = target.global_position + rotated_offset

	# 平滑插值更新相机全局位置
	# t 用指数衰减公式，帧率无关且平滑
	var t = 1.0 - pow(0.001, smooth_factor * delta)
	global_position = global_position.lerp(target_cam_pos, t)

	# 平滑插值更新 FOV
	fov = lerp(fov, current_fov, t)

	# 镜头始终看向目标
	look_at(target.global_position, Vector3.UP)
