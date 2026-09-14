# ============================================================
# 3D 地图摄像机脚本（仿第三人称追踪相机）
#
# 整体思路：
#   场景中放一个空节点 CameraTarget 作为追踪目标（由
#   map_generator_3d.gd 的 _process 每帧同步到玩家位置），
#   摄像机以 base_offset 偏移跟随目标：
#     - 滚轮：调整 FOV 实现拉近/拉远（平滑过渡）
#     - Q/E：绕目标旋转视角（每次 45°）
#     - _process：平滑插值摄像机位置 + look_at 始终看向目标
#
# 与正俯视正交相机不同，这里用透视投影 + 斜视角度，可环绕地图查看。
# ============================================================
extends Camera3D

# ------------------------------------------------------------
# 编辑器可配置参数（@export：可在 Inspector 面板直接修改）
# ------------------------------------------------------------

# 追踪目标：地图中心的空节点 CameraTarget
# 留空时 _ready 会自动查找同级名为 "CameraTarget" 的节点
@export var target: Node3D

# 相机基础偏移（相对于目标的后上方位置），按地图尺度放大
# 默认 (0, 8000, -5600)：高位略前倾，能看全 400x400 地图上约 240 瓦片的岛屿
#   X=0   → 正对目标 X 轴中心
#   Y=8000 → 高空俯视（Y 是上帝方向）
#   Z=-5600 → 向 -Z 方向后撤，形成斜视角度（不是纯正俯视）
@export var base_offset: Vector3 = Vector3(0, 8000, -5600)

# 位置平滑跟随系数：越大跟随越快（1 = 瞬间到位，0 = 永远不动）
# 默认 4.0：温和跟随，玩家移动时摄像机会有轻微滞后感
@export var smooth_factor: float = 4.0

# ------------------------------------------------------------
# 旋转视角参数（Q/E 环绕目标）
# ------------------------------------------------------------

# 当前水平旋转角度（弧度），初始 0 = base_offset 原始方向
# Q 减小、E 增大，每按一次变化 rotate_step
var yaw_rad: float = 0.0

# Q/E 单次旋转步长：45°（按一次转 45°，按住不重复触发）
# 用弧度表示，deg_to_rad(45) ≈ 0.785
const rotate_step: float = deg_to_rad(45)

# ------------------------------------------------------------
# FOV 缩放参数（滚轮控制视野大小实现拉近拉远）
# ------------------------------------------------------------

# FOV 最小值（滚轮上拉到极限）→ 视野最窄 = 拉得最近
@export var min_fov: float = 10.0

# FOV 最大值（滚轮下拉到极限）→ 视野最宽 = 拉得最远
@export var max_fov: float = 80.0

# 每次滚轮滚动调整的 FOV 单位（越大滚动越快）
@export var zoom_speed: float = 2.0

# FOV 目标值：_input 中修改此值，_process 中平滑过渡到实际 fov
# 这样滚轮滚动不会突变，而是缓动到目标视野
var current_fov: float = 50.0


# ============================================================
# 节点就绪时调用
# 配置透视投影参数 + 自动查找追踪目标
# ============================================================
func _ready():
	# 透视投影（有近大远小效果，斜视看地图有立体感）
	# 默认就是 PERSPECTIVE，这里显式设置以防被外部修改
	projection = Camera3D.PROJECTION_PERSPECTIVE
	fov = 50.0
	current_fov = 50.0

	# 关键：摄像机距地图中心约 6100 单位，默认 far=4000 会把整个地图裁掉！
	# 必须增大远裁剪面；near 设 1.0 提升深度缓冲精度（避免平面瓦片 z-fighting）
	near = 1.0
	far = 50000.0

	# 若 Inspector 未指定 target，自动查找同级 CameraTarget 节点
	# 摄像机与 CameraTarget 都是 Map3D 的子节点，按名查找无需手动拖拽
	if not target:
		target = get_parent().get_node_or_null("CameraTarget")


# ============================================================
# 输入事件处理（仅处理单次按下，不处理按住）
# 滚轮：调整 FOV 目标值 current_fov（实际 fov 在 _process 中平滑过渡）
# Q/E：调整 yaw_rad 旋转角度（实际位置在 _process 中插值更新）
# ============================================================
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# 滚轮上 → FOV 变小 → 拉近（视野收窄看远处更大）
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			current_fov = clamp(current_fov - zoom_speed, min_fov, max_fov)
		# 滚轮下 → FOV 变大 → 拉远（视野扩大看更多但变小）
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			current_fov = clamp(current_fov + zoom_speed, min_fov, max_fov)
	elif event is InputEventKey and event.pressed and not event.echo:
		# event.pressed 且 not event.echo：只在按下瞬间触发，按住不重复
		# 用 physical_keycode 按物理键位检测（不受键盘布局影响）
		if event.physical_keycode == KEY_Q:
			yaw_rad -= rotate_step  # 逆时针环绕目标
		elif event.physical_keycode == KEY_E:
			yaw_rad += rotate_step  # 顺时针环绕目标


# ============================================================
# 每帧处理
# 根据目标位置 + 旋转角度计算摄像机理想位置，平滑插值更新
# 摄像机位置和 FOV 都用插值实现缓动，避免突变
# ============================================================
func _process(delta: float) -> void:
	# 没有目标节点时不更新（避免报错）
	if not target:
		return

	# 把 base_offset 绕世界 Y 轴旋转 yaw_rad → 实现 Q/E 环绕目标
	# Vector3.UP = (0,1,0)，绕 Y 轴旋转保持高度不变，只改水平方向
	var rotated_offset = base_offset.rotated(Vector3.UP, yaw_rad)
	# 摄像机理想位置 = 目标位置 + 旋转后的偏移
	var target_cam_global_pos = target.global_position + rotated_offset

	# 帧率无关的平滑因子：
	# 公式 t = 1 - 0.001^(smooth_factor * delta)
	#   delta 大（帧率低）→ t 大 → 跟随更快（补偿帧率）
	#   delta 小（帧率高）→ t 小 → 跟随更缓
	# 0.001 是个经验常数，控制整体跟随速度
	var t = 1.0 - pow(0.001, smooth_factor * delta)
	# 摄像机当前位置 → 理想位置的线性插值
	global_position = global_position.lerp(target_cam_global_pos, t)

	# FOV 同样用 t 做插值，实现滚轮缩放的缓动效果
	fov = lerp(fov, current_fov, t)

	# 摄像机始终看向目标（让目标保持在屏幕中心）
	# Vector3.UP 指定"上"方向为 Y 轴，避免摄像机侧翻
	look_at(target.global_position, Vector3.UP)
