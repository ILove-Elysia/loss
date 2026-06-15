# 让这个脚本继承自 Godot 的 3D 相机节点（Camera3D），拥有相机所有功能
extends Camera3D

# 导出变量：在编辑器里可以拖入要跟随的目标节点（比如角色）
@export var target: Node3D

# 相机相对于目标的固定偏移位置：X=0, Y=5（高度）, Z=-8（身后距离）
var camera_offset: Vector3 = Vector3(0, 5, -8)

# 存储相机当前的水平旋转角度（偏航角），用来控制左右旋转
var current_yaw: float = 0.0

# --------------------- 视野 FOV 相关设置 ---------------------
# 导出变量：相机最小视野（数值越小=越放大、越拉近）
@export var min_fov: float = 30.0

# 导出变量：相机最大视野（数值越大=越广角、越拉远）
@export var max_fov: float = 120.0

# 导出变量：视野调整速度（数值越大，滚轮/按键缩放越快）
@export var fov_speed: float = 60.0

# --------------------- 函数：游戏启动时执行一次 ---------------------
func _ready():
	# 设置相机投影模式为【透视投影】（3D游戏正常视角，近大远小）
	projection = PROJECTION_PERSPECTIVE
	
	# 初始化相机默认视野为 70（人眼正常视角）
	fov = 70.0

# --------------------- 函数：每一帧都执行（delta是帧间隔时间） ---------------------
func _process(delta):
	# 如果没有设置目标（没拖入角色），直接退出，不执行后面代码
	if not target:
		return

	# --------------------- QE 旋转视角 ---------------------
	# 按下【左转】键：只触发一次（不是长按），相机向左转 45 度
	if Input.is_action_just_pressed("rotate_left"):
		current_yaw -= deg_to_rad(45)  # 角度转弧度，Godot 用弧度计算
	
	# 按下【右转】键：只触发一次，相机向右转 45 度
	if Input.is_action_just_pressed("rotate_right"):
		current_yaw += deg_to_rad(45)

	# --------------------- 视野缩放（拉近/拉远） ---------------------
	# 长按【放大视野】键：慢慢增加视野（画面变广、相机拉远）
	if Input.is_action_pressed("zoom_in"):
		fov += fov_speed * delta          # 用 delta 让速度在所有电脑上一致
		fov = clamp(fov, min_fov, max_fov) # 限制视野不超过最小值/最大值
	
	# 长按【缩小视野】键：慢慢减少视野（画面变近、相机拉近）
	if Input.is_action_pressed("zoom_out"):
		fov -= fov_speed * delta
		fov = clamp(fov, min_fov, max_fov)

	# --------------------- 计算相机最终位置 ---------------------
	# 把初始偏移量【绕 Y 轴旋转】，得到旋转后的偏移位置
	var offset = camera_offset.rotated(Vector3.UP, current_yaw)
	
	# 相机世界坐标 = 目标世界坐标 + 旋转后的偏移量（让相机跟在目标身后）
	global_position = target.global_position + offset
	
	# 相机始终看向目标点（保证镜头一直对着角色）
	look_at(target.global_position)
