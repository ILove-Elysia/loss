extends RefCounted
class_name FilterSystem

##
## 滤镜 / 后处理系统
##
## 在特殊时刻对画面施加调色效果，例如：
##   - 死亡：灰度 + 变暗 + 提高对比度
##   - 受击：对比度/饱和度闪一下
##   - 残血（血量低于阈值）：低饱和 + 变暗呼吸
## 后续要加新效果（暗角 / 灼烧 / 冰冻 / 眩晕 / 自定义 CompositorEffect 等），
## 只需在 Filter 枚举和 _PRESETS 里加一项，调用方用 apply / pulse / clear 即可。
##
## 实现基于 Godot 内置 Environment 的 adjustment（饱和度/亮度/对比度），
## 不依赖自定义 shader，避免编译风险；
## 与昼夜系统（改 background/ambient）共用同一 Environment 资源、互不冲突。
##
## 调用方约定（每帧推进动画）：HUD._process 里调用 FilterSystem.tick(delta)

enum Filter {
	NONE,        # 无滤镜
	DEATH,       # 死亡：灰度 + 变暗 + 黑暗角
	LOW_HEALTH,  # 残血：低饱和 + 红暗角呼吸
	HIT,         # 受击：红暗角闪一下
	BURN,        # 预留：灼烧（火山区 / 熔炉附近）
	FREEZE,      # 预留：冰冻（雪地区）
	CUSTOM,      # 预留：自定义（后续接 CompositorEffect / 自定义 shader）
}

# 对外别名（避免调用方记 enum 路径）
const FILTER_NONE: int = Filter.NONE
const FILTER_DEATH: int = Filter.DEATH
const FILTER_LOW_HEALTH: int = Filter.LOW_HEALTH
const FILTER_HIT: int = Filter.HIT
const FILTER_BURN: int = Filter.BURN
const FILTER_FREEZE: int = Filter.FREEZE
const FILTER_CUSTOM: int = Filter.CUSTOM

## 残血阈值（当前血量 / 最大血量 <= 此值即持续红色滤镜）
const LOW_HEALTH_RATIO: float = 0.3

## 每个滤镜在「强度=1」时的目标后处理参数。强度=0 即无滤镜（与 NONE 一致）。
## 字段直接对应 Environment 属性；tick 时按当前强度在 NONE 与该 preset 之间插值。
const _PRESETS: Dictionary = {
	Filter.NONE:       { "saturation": 1.0, "brightness": 1.0,  "contrast": 1.0  },
	Filter.DEATH:      { "saturation": 0.0, "brightness": 0.55, "contrast": 1.15 },
	Filter.LOW_HEALTH: { "saturation": 0.6, "brightness": 0.85, "contrast": 1.05 },
	Filter.HIT:        { "saturation": 0.8, "brightness": 1.0,  "contrast": 1.15 },
	Filter.BURN:       { "saturation": 1.1, "brightness": 1.05, "contrast": 1.1  },
	Filter.FREEZE:     { "saturation": 0.8, "brightness": 1.1,  "contrast": 1.05 },
	Filter.CUSTOM:     { "saturation": 1.0, "brightness": 1.0,  "contrast": 1.0  },
}

# ---- 运行时状态（静态：全场景共享一个滤镜栈）----
static var _env: Environment = null
static var _env_checked: bool = false
static var _current: int = Filter.NONE
static var _base: int = Filter.NONE
static var _strength: float = 0.0
static var _target_strength: float = 0.0
static var _pulse_time: float = 0.0
static var _pulse_total: float = 0.0
static var _low_health: bool = false


## 持续激活某个滤镜（直到 clear 或被更高优先级的 apply 覆盖）。
## 例：死亡时 apply(FILTER_DEATH)，复活时 clear()。
static func apply(filter: int) -> void:
	if not _PRESETS.has(filter):
		return
	_base = filter
	_current = filter
	_target_strength = 1.0
	_pulse_time = 0.0
	_ensure_env()


## 清除所有滤镜（恢复无滤镜）。复活 / 脱离残血时调用。
static func clear() -> void:
	_base = Filter.NONE
	_current = Filter.NONE
	_target_strength = 0.0
	_pulse_time = 0.0
	_low_health = false
	if _env != null and is_instance_valid(_env):
		_apply_to_env(0.0)


## 触发一次瞬时滤镜（如受击红闪），duration 秒后自动衰减回 _base。
## 与持续滤镜（死亡/残血）叠加：脉冲期间显示本滤镜，结束回到 _base。
static func pulse(filter: int, duration: float = 0.35) -> void:
	if not _PRESETS.has(filter):
		return
	_current = filter
	_strength = 1.0
	_target_strength = 1.0
	_pulse_time = maxf(duration, 0.0)
	_pulse_total = _pulse_time
	_ensure_env()


## 设置残血持续滤镜开/关。内部据 active 调 apply(FILTER_LOW_HEALTH) / clear。
## 由血量变化时调用；与死亡（apply DEATH）共存时，死亡的 _base 优先级更高。
static func set_low_health(active: bool) -> void:
	_low_health = active
	if active:
		apply(Filter.LOW_HEALTH)
	elif _current == Filter.LOW_HEALTH and _pulse_time <= 0.0:
		clear()


## 每帧推进滤镜过渡 / 脉冲动画。由 HUD._process 调用。
static func tick(delta: float) -> void:
	if _env == null or not is_instance_valid(_env):
		if not _ensure_env():
			return

	if _pulse_time > 0.0:
		_pulse_time -= delta
		var k := 0.0
		if _pulse_total > 0.0:
			k = clampf(_pulse_time / _pulse_total, 0.0, 1.0)
		_strength = k * k  # 受击红快速淡出
		if _pulse_time <= 0.0:
			_current = _base
			_target_strength = 1.0 if _base != Filter.NONE else 0.0
			_strength = _target_strength
	else:
		_strength = move_toward(_strength, _target_strength, delta * 3.0)

	# 残血呼吸：LOW_HEALTH 持续态时，暗角强度按正弦轻微起伏
	var s := _strength
	if _low_health and _current == Filter.LOW_HEALTH and _pulse_time <= 0.0:
		s = _target_strength * (0.7 + 0.3 * sin(Time.get_ticks_msec() / 220.0))

	_apply_to_env(s)


## 把当前强度映射到 Environment 后处理属性（在 NONE 与 _current preset 之间插值）。
## 只使用 Godot 4 确认存在的 adjustment 属性：adjustment_enabled + saturation/brightness/contrast。
## 不碰 vignette（Godot 4.7 标准 Environment 没有 vignette 相关属性/枚举），也不碰 adjustment_color/adjustment_color_correction。
static func _apply_to_env(strength: float) -> void:
	var p: Dictionary = _PRESETS.get(_current, _PRESETS[Filter.NONE])
	var base: Dictionary = _PRESETS[Filter.NONE]

	var sat := lerpf(float(base["saturation"]), float(p["saturation"]), strength)
	var bri := lerpf(float(base["brightness"]), float(p["brightness"]), strength)
	var con := lerpf(float(base["contrast"]), float(p["contrast"]), strength)

	_env.adjustment_enabled = strength > 0.001
	_env.adjustment_saturation = sat
	_env.adjustment_brightness = bri
	_env.adjustment_contrast = con


## 惰性获取场景里的 WorldEnvironment 资源（与昼夜系统共用同一 Environment）。
static func _ensure_env() -> bool:
	if _env != null and is_instance_valid(_env):
		return true
	if _env_checked:
		return false
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root := (loop as SceneTree).root
		if root != null:
			_env = _find_world_environment(root)
	_env_checked = true
	return _env != null and is_instance_valid(_env)


static func _find_world_environment(node: Node) -> Environment:
	if node is WorldEnvironment:
		var we: WorldEnvironment = node as WorldEnvironment
		if we.environment != null:
			return we.environment
	for child in node.get_children():
		var found: Environment = _find_world_environment(child)
		if found != null:
			return found
	return null
