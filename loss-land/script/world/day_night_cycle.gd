# script/world/day_night_cycle.gd
# ============================================
# 昼夜循环系统
#
# 功能说明：
#   1. 游戏内时间流逝：0-24 小时制，一天 = day_length_seconds 真实秒（默认 480s = 8 分钟）
#   2. 太阳 / 月亮两盏方向光随时间升落（俯仰角 = 正弦曲线，方位角东升西落）
#   3. 天空背景色、环境光颜色/强度按关键帧渐变（深夜→日出→正午→黄昏→深夜）
#   4. 阶段信号：白天 / 夜晚（供将来的夜行敌人、夜间降温等玩法挂钩）
#      白天 = 7:00~18:00，夜晚 = 18:00~次日 7:00（黎明/黄昏只是视觉渐变过渡，不再单独成阶段）
#
# 连接到其他系统：
#   - map.tscn：挂根节点下，自动创建 Sun/Moon 子灯并接管 ../WorldEnvironment
#   - HUD：顶部时钟按 "day_night" 组轮询本节点（本脚本不用 class_name，靠组查找）
#   - 调试：开关 = DebugConfig.CAT_TIME（阶段切换 / 跨天日志）
#
# 修改提示：
#   - 一天时长：改 day_length_seconds；调试加速：time_scale > 1
#   - 光色/强度手感：改 _SUN_* / _AMBIENT_* / _SKY_* 关键帧表
#   - 阶段边界：改 _phase_for()
# ============================================

extends Node3D

# ============================================
# 信号定义
# ============================================

## 每帧时间更新（day 从 1 起，hour 0.0~24.0）
signal time_updated(day: int, hour: float)

## 阶段切换时触发（黎明/白天/黄昏/夜晚）
signal phase_changed(new_phase: int)

# ============================================
# 常量 - 昼夜阶段
# ============================================

## 阶段常量：当前只有 白天/夜晚 两阶段（7~18 点白天，其余夜晚）
## DAWN/DUSK 保留占位，仅供将来细分（黎明/黄昏现在是纯视觉过渡，不再返回）
const PHASE_DAWN := 0
const PHASE_DAY := 1
const PHASE_DUSK := 2
const PHASE_NIGHT := 3

## 阶段中文名（HUD 时钟 / 调试日志用）
const PHASE_NAMES := ["黎明", "白天", "黄昏", "夜晚"]

# ============================================
# 关键帧表：[小时, 数值] / [小时, 颜色]，按小时升序
# 采样时线性插值，端点外取最近值
# ============================================

## 太阳强度系数（乘 sun_max_energy）
const _SUN_ENERGY := [
	[0.0, 0.0],
	[4.5, 0.0],
	[6.5, 0.5],
	[8.0, 0.9],
	[12.0, 1.0],
	[16.0, 0.9],
	[17.5, 0.5],
	[18.5, 0.1],
	[19.5, 0.0],
	[24.0, 0.0],
]

## 太阳颜色：日出橙 → 正午暖白 → 日落红橙
const _SUN_COLOR := [
	[0.0, Color(1.0, 0.6, 0.35)],
	[5.5, Color(1.0, 0.6, 0.35)],
	[7.5, Color(1.0, 0.82, 0.6)],
	[12.0, Color(1.0, 0.97, 0.9)],
	[16.5, Color(1.0, 0.85, 0.6)],
	[18.5, Color(1.0, 0.55, 0.3)],
	[20.0, Color(0.6, 0.3, 0.2)],
	[24.0, Color(1.0, 0.6, 0.35)],
]

## 环境光强度（白天保持主场景原本的 9.0 平光水准，夜晚压到 2.6；18 点入夜，19 点半前过渡完）
const _AMBIENT_ENERGY := [
	[0.0, 2.6],
	[4.5, 2.6],
	[6.5, 5.0],
	[9.0, 9.0],
	[17.0, 9.0],
	[18.5, 5.0],
	[19.5, 2.6],
	[24.0, 2.6],
]

## 环境光颜色：夜晚偏冷蓝（月光感），白天保持原中性灰
const _AMBIENT_COLOR := [
	[0.0, Color(0.5, 0.58, 0.85)],
	[5.0, Color(0.5, 0.58, 0.85)],
	[7.0, Color(0.8, 0.72, 0.68)],
	[10.0, Color(0.83, 0.83, 0.83)],
	[15.0, Color(0.83, 0.83, 0.83)],
	[18.0, Color(0.8, 0.65, 0.55)],
	[19.5, Color(0.5, 0.58, 0.85)],
	[24.0, Color(0.5, 0.58, 0.85)],
]

## 天空背景色（写进 Environment.background_color）
const _SKY_COLOR := [
	[0.0, Color(0.02, 0.03, 0.08)],
	[4.5, Color(0.02, 0.03, 0.08)],
	[6.0, Color(0.55, 0.35, 0.3)],
	[7.5, Color(0.5, 0.72, 0.9)],
	[12.0, Color(0.42, 0.68, 0.95)],
	[17.0, Color(0.85, 0.55, 0.3)],
	[18.5, Color(0.15, 0.1, 0.22)],
	[19.5, Color(0.02, 0.03, 0.08)],
	[24.0, Color(0.02, 0.03, 0.08)],
]

## 月亮强度系数（乘 moon_max_energy，与太阳互补：18 点太阳落月亮升）
const _MOON_ENERGY := [
	[0.0, 1.0],
	[4.5, 1.0],
	[6.5, 0.0],
	[18.0, 0.0],
	[19.5, 1.0],
	[24.0, 1.0],
]

# ============================================
# 导出变量
# ============================================

## 一个游戏日对应的真实秒数（480 = 8 分钟一天）
@export var day_length_seconds: float = 480.0

## 开局时间（小时，0~24）
@export var start_hour: float = 8.0

## 时间流速倍率（调试用：设 10 看快速昼夜）
@export var time_scale: float = 1.0

## 正午太阳强度
@export var sun_max_energy: float = 1.2

## 满月强度（夜里唯一的方向光，太黑看不见路）
@export var moon_max_energy: float = 0.3

## 太阳 / 月亮是否投影
@export var enable_shadows: bool = false

## WorldEnvironment 节点路径（相对本节点）
@export_node_path("WorldEnvironment") var environment_path: NodePath = NodePath("../WorldEnvironment")

# ============================================
# 私有变量
# ============================================

## 当前天数（从 1 起）
var day: int = 1

## 当前小时（0.0~24.0）
var hour: float = 8.0

## 当前阶段（PHASE_* 常量）
var phase: int = PHASE_DAY

var _sun: DirectionalLight3D = null
var _moon: DirectionalLight3D = null
var _environment: Environment = null
var _env_warned: bool = false

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 注册到 "day_night" 组：HUD 时钟和将来的玩法系统都按组找本节点，
	# 不写死节点路径（与 "hud" / "map_gen" 组同一约定）。
	add_to_group("day_night")

	hour = clampf(start_hour, 0.0, 24.0)
	phase = _phase_for(hour)

	_ensure_lights()
	_setup_environment()
	_update_visuals()


func _process(delta: float) -> void:
	var length := maxf(day_length_seconds, 0.1)
	hour += (24.0 / length) * time_scale * delta

	# 跨天：天数 +1，小时回绕
	while hour >= 24.0:
		hour -= 24.0
		day += 1
		DebugConfig.log_msg(DebugConfig.CAT_TIME, "[昼夜] 第 %d 天开始了（当前时刻 %.1f 点）", [day, hour])

	_update_visuals()

	var new_phase := _phase_for(hour)
	if new_phase != phase:
		phase = new_phase
		DebugConfig.log_msg(DebugConfig.CAT_TIME, "[昼夜] 进入%s（%.1f 点）", [PHASE_NAMES[phase], hour])
		phase_changed.emit(phase)

	time_updated.emit(day, hour)

# ============================================
# 公共方法 - 供其他系统查询
# ============================================

## 是否处于夜晚（黄昏结束到黎明开始之间），夜行玩法用这个判断
func is_night() -> bool:
	return phase == PHASE_NIGHT


## 当前阶段中文名（"黎明"/"白天"/"黄昏"/"夜晚"）
func get_phase_name() -> String:
	return PHASE_NAMES[phase]


## 直接设定时间（调试 / 存档恢复用）
func set_time(h: float, d: int = -1) -> void:
	hour = clampf(h, 0.0, 24.0)
	if d >= 1:
		day = d
	phase = _phase_for(hour)
	_update_visuals()

# ============================================
# 私有方法 - 场景搭建
# ============================================

## 确保太阳/月亮灯存在（场景里没配就在代码里建，避免 tscn 手写出错）
func _ensure_lights() -> void:
	_sun = get_node_or_null("Sun") as DirectionalLight3D
	if _sun == null:
		_sun = DirectionalLight3D.new()
		_sun.name = "Sun"
		add_child(_sun)
	_sun.shadow_enabled = enable_shadows

	_moon = get_node_or_null("Moon") as DirectionalLight3D
	if _moon == null:
		_moon = DirectionalLight3D.new()
		_moon.name = "Moon"
		add_child(_moon)
	_moon.shadow_enabled = enable_shadows
	_moon.light_color = Color(0.6, 0.7, 1.0)  # 冷色月光


## 拿 Environment 引用并切到纯色背景（原场景没有天空盒）
func _setup_environment() -> void:
	var we := get_node_or_null(environment_path) as WorldEnvironment
	if we == null or we.environment == null:
		# 只警告一次：没有 Environment 也能跑，只是没有天色变化
		if not _env_warned:
			_env_warned = true
			DebugConfig.warn_msg(DebugConfig.CAT_TIME, "[昼夜] 未找到 WorldEnvironment，天色渐变不生效", [])
		return
	_environment = we.environment
	# 原场景没设背景（默认 clearColor），改成纯色模式才能整片天空跟着时间变色
	_environment.background_mode = Environment.BG_COLOR

# ============================================
# 私有方法 - 每帧视觉更新
# ============================================

## 根据当前小时更新灯角度 / 强度 / 颜色 / 天空
func _update_visuals() -> void:
	# 太阳俯仰角：6 点升到地平线、12 点到头顶（+90°）、18 点落回地平线、0 点在正下方
	var elevation := 90.0 * sin(TAU * (hour - 6.0) / 24.0)
	# 方位角：东升西落，一整天转一圈
	var azimuth := (hour - 6.0) / 24.0 * 360.0

	if _sun:
		# 俯仰角取负：Godot 方向光默认朝 -Z，rotation.x = -90 时垂直向下照
		_sun.rotation_degrees = Vector3(-elevation, azimuth, 0.0)
		_sun.light_energy = _sample_float(_SUN_ENERGY, hour) * sun_max_energy
		_sun.light_color = _sample_color(_SUN_COLOR, hour)

	if _moon:
		# 月亮与太阳对称：位置差半天（方位 +180°），太阳落月亮升
		_moon.rotation_degrees = Vector3(elevation, azimuth + 180.0, 0.0)
		_moon.light_energy = _sample_float(_MOON_ENERGY, hour) * moon_max_energy

	if _environment:
		_environment.background_color = _sample_color(_SKY_COLOR, hour)
		_environment.ambient_light_color = _sample_color(_AMBIENT_COLOR, hour)
		_environment.ambient_light_energy = _sample_float(_AMBIENT_ENERGY, hour)

# ============================================
# 私有方法 - 关键帧采样
# ============================================

## 在 [小时, 数值] 关键帧表间线性插值（表须按小时升序）
func _sample_float(stops: Array, h: float) -> float:
	for i in range(stops.size() - 1):
		var h0 := float(stops[i][0])
		var h1 := float(stops[i + 1][0])
		if h >= h0 and h <= h1:
			var t := (h - h0) / maxf(h1 - h0, 0.0001)
			return lerpf(float(stops[i][1]), float(stops[i + 1][1]), t)
	return float(stops[stops.size() - 1][1])


## 在 [小时, 颜色] 关键帧表间线性插值
func _sample_color(stops: Array, h: float) -> Color:
	for i in range(stops.size() - 1):
		var h0 := float(stops[i][0])
		var h1 := float(stops[i + 1][0])
		if h >= h0 and h <= h1:
			var t := (h - h0) / maxf(h1 - h0, 0.0001)
			var c0: Color = stops[i][1]
			var c1: Color = stops[i + 1][1]
			return c0.lerp(c1, t)
	return stops[stops.size() - 1][1]


## 按小时划分昼夜阶段（用户约定：白天 7~18 点，夜晚 18 点~次日 7 点）
## 黎明/黄昏只保留为视觉渐变过渡，不再单独返回阶段
func _phase_for(h: float) -> int:
	if h >= 7.0 and h < 18.0:
		return PHASE_DAY
	return PHASE_NIGHT
