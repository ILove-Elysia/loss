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
#   3. 俯角随缩放联动（饥荒的 "Pitch Angle Method = Variable"）
#      机位 = 焦点 + 由俯角算出的偏移，视线永远看向焦点，所以视线方向恒定。
#      角色上下起伏（坡地/跳跃）只会让画面上下平移，不会改变俯角——
#      不像每帧 look_at(角色) 那样，角色一跳镜头就上下点头。
#      而俯角自己会随 zoom 变：推近时放平（看得远），拉远时抬高（接近俯视）。
#      这正是"拉远看起来像在看地图"的来源，俯角范围 30° ~ 55°
#      （2026-09-22 从 60° 收窄，原因见下方 pitch_far_degrees 的说明）。
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

## 机位到焦点的距离（米）。实际距离 = base_distance × zoom。
## 方向不在这里给 —— 它由俯角决定，见 _get_offset()。
@export var base_distance: float = 9.434

## 俯角联动范围（度，相对水平面）：
##   · zoom = min_zoom（推近）→ pitch_near_degrees：视角放平，看得远
##   · zoom = max_zoom（拉远）→ pitch_far_degrees：相机抬高，接近俯视
## 两者之间按 zoom 线性插值。
## 拉远时是"后退 + 抬高"同时发生，于是屏幕里**上下方向的地面纵深变化不大**，
## 多出来的视野主要落在左右两侧 —— 想"看远"，该做的是推近而不是拉远。
##
## 远端为什么从 60° 收到 55°（2026-09-22）：
##   60° 时地面被压得很扁，前后物体的投影几乎叠在一起，谁挡谁看不清；
##   贴图侧虽然做了俯角补偿（不再被压扁，见 script/visual/sprite_facing.gd），
##   但地面本身和程序化网格资源仍按透视走，太陡会让"站在一起的东西"糊成一团。
##   55° 保住"拉远像看地图"的感觉，同时前后层次还分得开。
@export var pitch_near_degrees: float = 30.0
@export var pitch_far_degrees: float = 55.0

## 固定 FOV。缩放不再动它，避免鱼眼畸变。
@export var base_fov: float = 50.0

## 注意：Camera3D 挂在 Camera_Target 下，而 Camera_Target 上带着一个 45° 的
## X 轴旋转 —— 那是遗留值，**每帧的 look_at() 会整体覆盖相机朝向**，它不产生
## 任何效果。真实俯角只由 base_distance + 上面的俯角范围决定（曾据此把俯角
## 误判成 45°，做美术资产前务必以这里的参数为准）。

# ---------------- 旋转 ----------------

## Q/E 点按一次转过的角度（度）。饥荒是 45° 档位。
@export var rotate_step_degrees: float = 45.0

## 按住 Q/E 超过这个时长后，转为连续旋转（秒）。
## 这样"掉头"不用狂敲四下，按住不放就能一直转。
@export var rotate_hold_delay: float = 0.25

## 连续旋转的角速度（度/秒）。180 = 按住 1 秒转半圈。
@export var rotate_hold_speed: float = 200.0

## 松开 Q/E 后，是否把镜头归位到最近的 rotate_step_degrees 档位。
## 关掉 = 镜头停在任意角度（代价：大小地图会歪成非 45° 的倍数，
## 因为它们是跟着相机 yaw 转的，见 snap_yaw_to_step()）。
@export var snap_yaw_on_release: bool = true

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
	global_position = _focus + _get_offset(_zoom).rotated(Vector3.UP, _yaw)
	look_at(_focus, Vector3.UP)


# ----------------------------------------
# 档位归位
#
# 点按 Q/E 走的是 45° 整数档，但"按住连续旋转"是按 200°/s 逐帧累加的，
# 松手那一刻 _target_yaw 几乎必然落在两个档位之间（每帧 3° 左右，落点随机）。
# 镜头自己看不出差别，可大小地图是**跟着相机 yaw 转**的
# （map_view._update_map_angle 直接取相机的水平前向），于是地图会歪成一个
# 非 45° 倍数的角度 —— 这就是「大小地图有概率旋转后不是正交角度」的根因。
# 松手时归到最近档位即可；只改 _target_yaw，_yaw 会平滑转过去（最多 22.5°）。
# ----------------------------------------

## 把目标角度归位到最近的档位（rotate_step_degrees 的整数倍）。
## 读档时也会调用：老存档可能是在没有归位的旧版里存的任意角度。
func snap_yaw_to_step() -> void:
	var step := deg_to_rad(rotate_step_degrees)
	if step <= 0.0:
		return
	_target_yaw = roundf(_target_yaw / step) * step
	_wrap_yaw()


## 把 _yaw 与 _target_yaw 一起平移回 [0, 2π)，避免长时间游玩后数值无限增长。
## 两者必须**平移相同的量**，否则镜头会瞬间跳一整圈。
func _wrap_yaw() -> void:
	# floorf / roundf 而不是 floor / round：后者是 float+Variant 双签名重载，
	# 配 `:=` 会把变量推断成 Variant，编辑器直接报错（实测 198 行）。
	var k := floorf(_target_yaw / TAU)
	if k != 0.0:
		_yaw -= k * TAU
		_target_yaw -= k * TAU


# ----------------------------------------
# 机位：俯角与偏移
# ----------------------------------------

## 按 zoom 求俯角（度）。把这段映射收敛在一处 —— 机位、调试显示都读它，
## 免得两处各算一遍、改一半漏一半。
func get_pitch_degrees(zoom: float) -> float:
	var span: float = max_zoom - min_zoom
	if span <= 0.0:
		return pitch_near_degrees
	var t: float = clampf((zoom - min_zoom) / span, 0.0, 1.0)
	# 上限压到 89°：90° 时机位正好在焦点正上方，look_at(_, Vector3.UP) 会退化。
	return clampf(lerpf(pitch_near_degrees, pitch_far_degrees, t), 0.0, 89.0)


## 焦点 → 机位的偏移向量（未经 yaw 旋转）。
## 长度 = base_distance × zoom；方向由俯角定：水平分量 cos、垂直分量 sin，
## 于是机位永远落在焦点的"后方上方"，俯角越大越接近正上方。
## 传入平滑后的 _zoom，俯角就跟着一起平滑，缩放时不会突然跳一个角度。
func _get_offset(zoom: float) -> Vector3:
	var pitch: float = deg_to_rad(get_pitch_degrees(zoom))
	return Vector3(0.0, sin(pitch), -cos(pitch)) * (base_distance * zoom)


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
	# 偏移由俯角算出：zoom 同时决定"退多远"（base_distance × zoom）
	# 和"抬多高"（俯角），于是拉远 = 后退 + 抬高，与饥荒一致。
	var offset := _get_offset(_zoom)
	global_position = _focus + offset.rotated(Vector3.UP, _yaw)

	# 看向焦点（不是角色）。机位 = 焦点 + 偏移，所以视线方向恒定，
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
		# 刚松开 Q/E：走的是"连续旋转"的话，_target_yaw 会停在两个档位之间
		# （每帧加 200°/s × delta，落点随机）。这时必须归位，否则大小地图
		# 会歪成一个非 45° 倍数的角度——它们是跟着相机 yaw 转的。
		if _rotate_dir != 0 and snap_yaw_on_release:
			snap_yaw_to_step()
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
