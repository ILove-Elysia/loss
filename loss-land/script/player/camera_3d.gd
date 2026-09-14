# script/player/camera_3d.gd
# ============================================
# 相机控制器（饥荒式固定视角）
#
# 饥荒的相机有三个特征，这里逐条还原：
#
#   1. 朝向完全由玩家掌控，绝不自动跟随角色
#      Q/E 转 45° 档位。角色可以朝任意方向走，镜头纹丝不动。
#
#   2. 死区跟随（dead zone）——走路稳的关键
#      角色在死区半径内移动时相机完全不动，走出了才把焦点拖到死区边缘。
#      于是小碎步、微调站位不会让整个画面跟着抖，只有真正"走远了"镜头才跟。
#
#   3. 固定俯角
#      机位 = 焦点 + 固定偏移，视线永远看向焦点，所以视线方向恒定。
#      角色上下起伏（坡地/跳跃）只会让画面上下平移，不会改变俯角——
#      不像每帧 look_at(角色) 那样，角色一跳镜头就上下点头。
#
# 另外两处细节改动：
#   · 移动前瞻：走得越快看得越远，跑动时前方留白更多。
#   · 缩放改用「拉远/推近机位」而不是改 FOV。改 FOV 越大越鱼眼，
#     而饥荒的缩放是整体等比缩放，视角形状不变。
#
# 所有手感参数都是 @export，可以在检查器里实时调，不用改代码。
# ============================================
extends Camera3D

# ---------------- 跟随 ----------------

## 跟随目标：player 下的 Physics（真正移动的那个节点，根节点永远在原点）
@export var target: Node3D

## 死区半径（米）。角色在这个范围内移动，相机完全不动。
## 调大 → 画面更稳但角色更容易偏离中心；调小 → 更"咬手"。
## 0 = 完全关掉死区（镜头紧跟，但走路的每一步都会带动画面）。
@export var follow_deadzone: float = 0.25

## 水平跟随速度（1/秒）。3.0 ≈ 软软缀在身后；8.0 ≈ 几乎硬绑定。
@export var follow_smooth: float = 3.0

## 高度跟随速度。刻意比水平慢：上下坡时画面不会跟着颠。
@export var height_smooth: float = 1.5

## 静止这么久之后，焦点开始缓慢漂回角色正上方（秒）。
## 让站定时角色回到画面中心；设为很大则关闭回中。
@export var idle_recenter_delay: float = 1.5

## 单帧位移超过这个距离就算「传送」，焦点直接吸附而不做平滑。
## 用来处理开局把角色放到出生点、以及日后的传送点——
## 否则镜头会从世界原点一路飞过去，飞好几秒。
@export var teleport_distance: float = 20.0

# ---------------- 移动前瞻 ----------------

## 朝移动方向多看出的距离（米）。0 = 关闭。
@export var look_ahead_distance: float = 1.2

## 达到这个速度时前瞻拉满（米/秒）。应与角色移速同量级。
@export var look_ahead_ref_speed: float = 5.0

## 前瞻自身的平滑速度：起步/刹车时镜头不会猛地弹一下。
@export var look_ahead_smooth: float = 2.0

# ---------------- 机位 ----------------

## 相机相对焦点的偏移（身后上方）。整体按 zoom 等比缩放，方向不变。
@export var base_offset: Vector3 = Vector3(0, 5, -8)

## 固定 FOV。缩放不再动它，避免鱼眼畸变。
@export var base_fov: float = 50.0

# ---------------- 旋转 ----------------

## Q/E 点按一次转过的角度（度）。饥荒是 45° 档位。
@export var rotate_step_degrees: float = 45.0

## 按住 Q/E 超过这个时长后，转为连续旋转（秒）。
## 这样"掉头"不用狂敲四下，按住不放就能一直转。
@export var rotate_hold_delay: float = 0.25

## 连续旋转的角速度（度/秒）。180 = 按住 1 秒转半圈。
@export var rotate_hold_speed: float = 200.0

## 档位之间的过渡速度（1/秒）。越小转得越"飘"。
@export var yaw_smooth: float = 14.0

# ---------------- 缩放 ----------------

@export var min_zoom: float = 0.6
@export var max_zoom: float = 1.8

## 每次滚动滚轮的缩放步长
@export var zoom_step: float = 0.1

## 缩放过渡速度（player.tscn 里覆盖为 4.0）
@export var zoom_speed: float = 4.0

## 鼠标悬停在 UI 上时滚轮不缩放：打开背包滚列表不会误拉镜头
@export var ignore_zoom_over_ui: bool = true

# ---------------- 内部状态 ----------------

## 相机实际盯住的点（平滑后）。角色可以在它周围自由活动。
var _focus := Vector3.ZERO
## 焦点是否已经对准过目标。false = 还没吸附过，第一帧直接落位。
## 开局把角色放到出生点、读档还原坐标、复活传送都会瞬移角色，
## 而相机 _ready 早于这些操作，若不吸附镜头就会从旧坐标一路平滑飞过去。
var _focus_ready: bool = false
## 前瞻偏移（平滑后）
var _ahead := Vector2.ZERO

var _prev_target_pos := Vector3.ZERO
var _idle_time: float = 0.0

var _yaw: float = 0.0
var _target_yaw: float = 0.0
## 上一次的旋转方向（-1/0/+1）。方向从 0 变为非 0 = 刚按下，走一档；
## 之后按住不动则转为连续旋转。
var _rotate_dir: int = 0
var _hold_time: float = 0.0

var _zoom: float = 1.0
var _target_zoom: float = 1.0


func _ready() -> void:
	# ALWAYS：暂停态（大地图/暂停菜单）下 _process 照跑，Q/E 仍能转相机——
	# 大地图开着时游戏是暂停的，若不这样，地图的 Q/E 旋转就失灵。
	# 暂停时玩家不动，跟随/回中等逻辑无副作用。
	process_mode = Node.PROCESS_MODE_ALWAYS
	projection = PROJECTION_PERSPECTIVE
	fov = base_fov
	# 供传送/读档处按组找回相机并调用 snap_to_target()（不依赖节点路径）
	add_to_group("player_camera")
	if target == null:
		target = get_parent().get_parent().get_parent() as Node3D
	if target != null:
		_focus = target.global_position
		_prev_target_pos = _focus
	# 注意：这里只是先填个初值，_focus_ready 仍为 false。
	# 地图生成（teleport_player_to_start）和读档（SaveManager._apply_player）
	# 都在这之后才把角色挪到真实位置，真正的落位留给第一帧的 snap_to_target()。


## 把焦点瞬间对准目标（不做平滑），并把机位同步到位。
##
## 为什么需要：角色会被瞬移——
##   · 开局：map_generator_3d.teleport_player_to_start 把角色放到出生点
##   · 读档：SaveManager._apply_player 把角色还原到存档坐标
##   · 复活：Physics.revive 把角色拉回重生点
## 而相机的 _ready 早于这些操作，_focus 还停在旧坐标。
## 若只靠死区平滑跟随，镜头就会"从旧位置飞到玩家身上"（1~2 秒的漂移），
## 表现为「进入存档后镜头从出生点飘过去」。
## 正确行为是：玩家看到第一帧画面时，镜头已经在玩家身上。
func snap_to_target() -> void:
	if target == null or not is_instance_valid(target):
		return
	_focus = target.global_position
	_prev_target_pos = _focus
	_ahead = Vector2.ZERO
	_idle_time = 0.0
	_focus_ready = true
	# 调用点通常不在 _process 里，所以这里直接把机位落好，
	# 不等下一帧——否则读档那一帧仍会画出"旧机位"的画面。
	global_position = _focus + (base_offset * _zoom).rotated(Vector3.UP, _yaw)
	look_at(_focus, Vector3.UP)


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_WHEEL_UP and event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	if ignore_zoom_over_ui and get_viewport().gui_get_hovered_control() != null:
		return
	# zoom 是「机位距离倍率」：越大 = 相机退得越远 = 画面越小。
	# 所以滚轮上滚（约定俗成的放大/推近）要**减小** zoom。
	var step: float = -zoom_step if event.button_index == MOUSE_BUTTON_WHEEL_UP else zoom_step
	_target_zoom = clampf(_target_zoom + step, min_zoom, max_zoom)


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target) or delta <= 0.0:
		return

	# 首帧吸附：角色可能已经被地图生成 / 读档瞬移过（都发生在相机的 _ready 之后），
	# 此时必须直接落位，否则镜头会从旧坐标平滑飞过来。
	if not _focus_ready:
		snap_to_target()

	# ---- 输入：点按走一档，按住转连续 ----
	_update_rotation(delta)

	# 旋转与缩放都走平滑：Q/E 转档时是"转过去"而不是"跳过去"
	_yaw = _damp(_yaw, _target_yaw, yaw_smooth, delta)
	_zoom = _damp(_zoom, _target_zoom, zoom_speed, delta)

	_update_focus(delta)

	# ---- 机位 ----
	var offset := base_offset * _zoom
	global_position = _focus + offset.rotated(Vector3.UP, _yaw)

	# 看向焦点（不是角色）。机位 = 焦点 + 固定偏移，所以视线方向恒定，
	# 角色上下起伏只平移画面、不改俯角——饥荒的固定视角。
	look_at(_focus, Vector3.UP)


# ----------------------------------------
# 焦点更新：死区 + 前瞻 + 静止回中
# ----------------------------------------
func _update_focus(delta: float) -> void:
	var p := target.global_position

	# 用位置差分求速度：不依赖 CharacterBody3D，以后换移动实现也不会坏
	var moved := Vector2(p.x - _prev_target_pos.x, p.z - _prev_target_pos.z)
	_prev_target_pos = p
	var speed: float = moved.length() / delta

	# 传送/开局落位：直接吸附，别让镜头横穿整张地图
	if moved.length() > teleport_distance:
		_focus = p
		_ahead = Vector2.ZERO
		return

	# ---- 前瞻：走得越快看得越远 ----
	var want_ahead := Vector2.ZERO
	if look_ahead_distance > 0.0 and moved.length() > 0.0001:
		var ratio: float = clampf(speed / maxf(look_ahead_ref_speed, 0.001), 0.0, 1.0)
		want_ahead = moved.normalized() * look_ahead_distance * ratio
	_ahead = _ahead.lerp(want_ahead, _damp_factor(look_ahead_smooth, delta))

	# ---- 水平死区 ----
	# 以下用 Vector2 做水平面运算：x → 世界 x，y → 世界 z。
	# 注意 Vector2 没有 .z，下面写回 _focus 时取的是 desired.y。
	var f2 := Vector2(_focus.x, _focus.z)
	var p2 := Vector2(p.x, p.z)
	var to_p := p2 - f2
	var dist := to_p.length()

	var desired := p2
	if dist > follow_deadzone and dist > 0.0001:
		# 只把焦点拖到死区边缘：死区内的小幅移动完全不带动镜头
		desired = f2 + to_p.normalized() * (dist - follow_deadzone)
	desired += _ahead

	# ---- 静止回中：站定后角色慢慢回到画面中心 ----
	if speed < 0.05:
		_idle_time += delta
	else:
		_idle_time = 0.0
	if _idle_time >= idle_recenter_delay:
		desired = p2  # 忽略死区，缓缓漂回

	_focus.x = _damp(_focus.x, desired.x, follow_smooth, delta)
	_focus.z = _damp(_focus.z, desired.y, follow_smooth, delta)
	_focus.y = _damp(_focus.y, p.y, height_smooth, delta)


# ----------------------------------------
# 旋转输入
#
# 点按一下 = 走一档（默认 45°，饥荒的档位感）；
# 按住超过 rotate_hold_delay = 转为连续旋转，不用狂敲也能掉头。
# ----------------------------------------
func _update_rotation(delta: float) -> void:
	var dir := 0
	if Input.is_action_pressed("rotate_left"):
		dir -= 1
	if Input.is_action_pressed("rotate_right"):
		dir += 1
	# 同时按住左右：互相抵消
	if Input.is_action_pressed("rotate_left") and Input.is_action_pressed("rotate_right"):
		dir = 0

	if dir == 0:
		_rotate_dir = 0
		_hold_time = 0.0
		return

	if dir != _rotate_dir:
		# 刚按下（或换了个方向）：先走一档
		_rotate_dir = dir
		_hold_time = 0.0
		_target_yaw += dir * deg_to_rad(rotate_step_degrees)
		return

	_hold_time += delta
	if _hold_time >= rotate_hold_delay:
		_target_yaw += dir * deg_to_rad(rotate_hold_speed) * delta


# ----------------------------------------
# 帧率无关的指数阻尼
# rate 的语义：每秒把剩余差距收敛掉 e^-rate
# ----------------------------------------
static func _damp_factor(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)


static func _damp(current: float, target_: float, rate: float, delta: float) -> float:
	return lerpf(current, target_, _damp_factor(rate, delta))
