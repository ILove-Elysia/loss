# script/player/vitals.gd
# ============================================
# 玩家生命体征：电量 + 体温（大纲 3.1 / 3.2） + 饱食度（本次新增）
#
# 挂载：player.tscn 根节点下（名为 Vitals），与 Physics 平级。
# 独立成组件而不是塞进 physics.gd——物理脚本已经 300 行，
# 状态系统与移动逻辑解耦后各自可测。
#
# 电量（大纲 3.1）：
#   - 满 100，不自动消耗（只通过特殊交互），电池 +10 / 能量核心 +50（未来）
#   - ≤10 低电量：移动速度 -30%
#   - =0  濒危：每秒 -1 生命值
#   - >80：+5 生命值/分钟
#
# 体温（大纲 3.2）：
#   - 正常 10-40；过冷 -10~10；过热 40~80；极值 -100~100
#   - 过冷/过热：每秒 -0.5 电量
#   - 环境驱动的温度变化见 _zone_temp_target()
#
# 饱食度（大纲未定义，本次补上）：
#   - 满 100，随时间匀速下降（默认一个游戏日 480 秒从全饱到空）
#   - ≤20 饥饿：移速 -10%，且停止自然回血
#   - =0  濒危：每秒 -0.5 生命值（比电量归零的 -1.0 温和，留出找食物的时间）
#   - 只能靠吃东西回补（use_effect = "+N_food"，见 item_effects.gd）
#   为什么必须同时落地食物：没有食物的话饱食度就是个只降不升的死亡计时器，
#   所以配套实装了浆果（berry）资源与物品。
#
# 角色差异（大纲 v0.7 · 2.2）：**电量默认是机器人专属**。
#   has_power = false（冒险家 / 魔女）：不漏电、不自然回血，HUD 电量行显示为"占位"；
#   过冷 / 过热改为**直接扣血**（决策 ③），与机器人的"漏电"对称。
#   开关由 CharacterRegistry.has_power() 在 _apply_character() 里决定。
#
# 两种电量语义（用户决策，2026-09-14）——`power_embedded` 区分：
#   【内置】机器人：电量 = 机械身体的动力，是它的生命线。
#           → 不可关闭（set_has_power(false) 对它无效）、
#             归零**会掉血**、低电**会减速**、>80 且吃饱**会缓慢回血**。
#   【外置】冒险家 / 魔女装上「动力核心」后：电量就是一个外挂电池，
#           **对人物本体零影响** → 不扣血、不减速、**也不回血**；
#           它只决定"耗电的交互还能不能用"。
#   两者唯一共有的部分：过冷 / 过热都要**额外漏电**（环境在消耗电池）。
#   外置 / 无电量角色的回血出口只有一个：**吃食物**（大纲 3.3.2）。
#
# 与其他系统的连接：
#   - HUD：按 "hud" 组找到 HUDUI，值变化时刷新 ⚡/🌡 显示
#   - 移动：physics.gd 每帧调 get_speed_multiplier() 应用低电量减速
#   - 生命：通过 Physics 节点的 take_damage / heal
#
# 测试注意：tick 逻辑在 _tick(delta) 里独立于 _process，
# headless 测试可以直接大步长调用，不必等真实时间流逝。
# ============================================

class_name PlayerVitals
extends Node

signal power_changed(power: float)
signal temperature_changed(temp: float)
signal hunger_changed(hunger: float)

## ---------- 电量参数（大纲 3.1.1 / 3.1.3 / 3.1.4） ----------
@export var max_power: float = 100.0
@export var initial_power: float = 100.0
## 低电量阈值：低于它移动速度乘 low_power_speed_penalty
@export var low_power_threshold: float = 10.0
## 低电量移速惩罚（大纲：-30%）
@export var low_power_speed_multiplier: float = 0.7
## 高电量（>80）生命恢复，HP/秒（大纲：+5 HP/分钟）
## **仅内置电量**（机器人靠机械身体自愈）；外置核心不给回血（见下方两种电量语义）
@export var high_power_regen_rate: float = 5.0 / 60.0
## 高电量回血的电量门槛
@export var high_power_threshold: float = 80.0
## 濒危（=0）每秒掉的生命值
@export var critical_power_damage: float = 1.0

## ---------- 体温参数（大纲 3.2.1 / 3.2.2） ----------
## 正常区间（无影响）
@export var temp_normal_min: float = 10.0
@export var temp_normal_max: float = 40.0
## 过冷上限（-10~10 为过冷）与过热下限（40~80 为过热）
@export var temp_cold_max: float = 10.0
@export var temp_hot_min: float = 40.0
## 过冷/过热时每秒流失的电量（大纲：每秒 -0.5）——**只对有电量的角色生效**
@export var extreme_temp_power_drain: float = 0.5
## 过冷/过热时每秒扣的生命值（大纲 3.2.2 决策 ③）——**所有角色一视同仁**。
## 有电量的角色是"扣血 + 漏电"双份惩罚（机器人多一条补给线的代价）。
@export var extreme_temp_damage: float = 0.5
## 体温绝对范围
@export var temp_abs_min: float = -100.0
@export var temp_abs_max: float = 100.0
## 常规区域的回温目标与速率（大纲 3.2.3：趋向 30，变化 10/分钟）
@export var neutral_temp_target: float = 30.0
@export var neutral_temp_rate: float = 10.0 / 60.0
## 火山区升温、雪地区降温（大纲：±15/分钟）
@export var volcano_temp_rate: float = 15.0 / 60.0
@export var snow_temp_rate: float = 15.0 / 60.0

## ---------- 饱食度参数（大纲未定义，数值可自由调） ----------
@export var max_hunger: float = 100.0
@export var initial_hunger: float = 100.0
## 每秒流失的饱食度。100/480 = 一个游戏日（day_night_cycle 默认 480 秒）
## 从全饱掉到空，约等于"一天要吃三四顿"，手感接近饥荒。
## 想更宽松就调小（如 100/960 = 两天才饿一次）。
@export var hunger_drain_rate: float = 100.0 / 480.0
## 低于该值进入"饥饿"：移速小幅下降，并停止自然回血
@export var hungry_threshold: float = 20.0
## 饥饿时的移速乘数（比低电量的 0.7 温和，饥饿不该让人走不动路）
@export var hunger_speed_multiplier: float = 0.9
## 饱食度归零时每秒流失的生命值
@export var starvation_damage: float = 0.5
## 高于该值算"温饱"（HUD 与状态查询用）
@export var well_fed_threshold: float = 80.0

## 本局角色是否**带电量系统**（大纲 2.2.3：机器人开机即 true）。
## false 时：HUD 电量行显示占位、不漏电、不自然回血；过冷过热**只扣血**。
## 冒险家 / 魔女默认 false，装入「动力核心」后由 set_has_power(true) 打开。
## ⚠ 这是**运行时状态**（核心可装可拆），不要再从注册表查询电量状态。
var has_power: bool = false

## 电量是否**内置**（机器人机械身体自带 = true）。
## 这是"电量能否影响人物本体"的总闸门：内置电量归零掉血、低电减速、>80 回血；
## 外置的只是一个设备的电量 → 对人物本体零影响（不掉血 / 不减速 / **不回血**）。
## 本字段来自注册表，运行时不变（动力核心不改它——核心是外挂设备）。
var power_embedded: bool = false

## 当前电量（0 ~ max_power）。**无电量的角色这个值无意义**（HUD 也不显示）。
var current_power: float
## 当前体温（temp_abs_min ~ temp_abs_max）
var current_temperature: float
## 当前饱食度（0 ~ max_hunger）
var current_hunger: float

var _body: CharacterBody3D
var _map_gen: Node
var _hud: Node

# 生命值按秒累积的计数器（伤害/恢复都是整数 HP，累积满 1 才结算）
var _damage_acc: float = 0.0
var _regen_acc: float = 0.0
var _starve_acc: float = 0.0
# 上次推给 HUD 的整数显示值（避免每帧刷 HUD）
var _last_power_shown: int = -1
var _last_temp_shown: int = -9999
var _last_hunger_shown: int = -1
## 上次推给 HUD 的"电量行是否亮起"（-1 = 还没推过，首帧必推一次）。
## 用 int 哨兵值而不是 bool，就是为了让首帧一定能推一次 —— HUD 的 _ready
## 可能早于/晚于本组件的 _ready，靠这一推自纠正，不依赖初始化顺序。
var _last_power_active_shown: int = -1
# 上次的饱食度档位，用于只在切换时打一条调试日志
var _last_hunger_state: String = ""


func _ready() -> void:
	# 角色差异（电量上限 / 极端温度漏电 / 饱食度消耗）必须在给 current_* 赋初值前应用，
	# 否则会拿旧的 max_power 去 clamp，开局电量对不上角色。
	_apply_character()
	current_power = initial_power
	current_temperature = neutral_temp_target
	current_hunger = initial_hunger

	# 玩家本体（physics.gd 所在的 CharacterBody3D）
	# 挂载关系：player(Node3D) → Vitals(本脚本) + Physics(CharacterBody3D)
	for c in get_parent().get_children():
		if c is CharacterBody3D:
			_body = c
			break

	_map_gen = get_tree().get_first_node_in_group("map_gen")
	_hud = get_tree().get_first_node_in_group("hud")

	power_changed.emit(current_power)
	temperature_changed.emit(current_temperature)
	hunger_changed.emit(current_hunger)


## 应用本局角色的系统开关（是否有电量 / 电量是否内置）。
## 大纲 v0.7 的设计意图是**三个角色数值完全相同、差异全部来自系统**，
## 所以这里不乘任何数值倍率，只决定电量这条线怎么跑。
## 读档时 SaveManager 会在本函数之后用存档值覆盖 current_*，不冲突。
func _apply_character() -> void:
	var id: String = CharacterRegistry.get_active_id()
	has_power = CharacterRegistry.has_power(id)
	power_embedded = CharacterRegistry.has_embedded_power(id)
	power_changed.emit(current_power)


## 装入 / 拆除「动力核心」（大纲 3.1.3）。
## 内置电量的角色（机器人）**不可关闭**：它的电量来自机械身体本身，不是外挂件。
## 外置电量（冒险家 / 魔女）：
##   装入 → 满电解锁，此后**漏电**照常生效（环境在耗这块电池）；
##   但掉血 / 减速 / 回血这三条"影响人物本体"的规则**只有内置电量才有**，
##   所以外置核心装上后人物本体的手感完全不变。
##   拆除 → 电量清零，相关效果下线（但不影响人物本体的血量与移速）。
## HUD 会通过 _push_hud() 自动在"占位 / 亮起"之间切换，无需额外接线。
func set_has_power(active: bool) -> void:
	if power_embedded and not active:
		DebugConfig.warn_msg(DebugConfig.CAT_PLAYER,
			"[电量] 内置电量不可关闭（角色 %s）", [CharacterRegistry.get_active_id()])
		return
	if has_power == active:
		return
	has_power = active
	# 装上即满电（大纲：装入 → 解锁电量 100/100）；拆下则清零
	current_power = initial_power if active else 0.0
	_damage_acc = 0.0
	_regen_acc = 0.0
	power_changed.emit(current_power)
	DebugConfig.log_msg(DebugConfig.CAT_PLAYER,
		"[电量] %s（当前 %.0f/%.0f，内置=%s）",
		["装入动力核心" if active else "拆除动力核心",
			current_power, max_power, str(power_embedded)])


func _process(delta: float) -> void:
	_tick(delta)


# ============================================
# 主循环（测试可直接调用，传大步长）
# ============================================

func _tick(delta: float) -> void:
	_update_temperature(delta)
	_update_hunger(delta)
	_update_power_effects(delta)
	_push_hud()


# ============================================
# 体温：环境驱动
# ============================================

func _update_temperature(delta: float) -> void:
	if _body == null:
		return

	var terrain: int = _terrain_at_player()
	var before: float = current_temperature

	# 热源优先：站在熔炉旁时体温被拉向 heat_target，压过地形的影响。
	# 大纲 3.2.3 原本写的是"熔炉附近 +5/分钟"，但雪地区降温是 -15/分钟，
	# 只 +5 是净流失，熔炉等于没用。改成"趋向目标温度"后，
	# 雪地里烤火体温能稳定在 ~34 度，熔炉才真的能救命。
	var heater := BuildingSystem.get_heater_at(_body.global_position)
	if heater != null:
		var hdef := BuildingSystem.get_def(StringName(heater.get("building_id")))
		var heat_target := float(hdef.get("heat_target", 35.0))
		var heat_rate := float(hdef.get("heat_rate", 20.0 / 60.0))
		current_temperature = move_toward(
			current_temperature, heat_target, heat_rate * delta)
	else:
		match terrain:
			14:  # 火山区：持续升温
				current_temperature = minf(
					current_temperature + volcano_temp_rate * delta, temp_abs_max)
			15:  # 雪地区：持续降温
				current_temperature = maxf(
					current_temperature - snow_temp_rate * delta, temp_abs_min)
			_:
				# 草原/丛林/矿区/沙地/沙滩/海洋：趋向自然体温。
				# 大纲里的「地下遗迹恒温」仍未实装（Demo 无地下遗迹）。
				current_temperature = move_toward(
					current_temperature, neutral_temp_target, neutral_temp_rate * delta)

	if not is_equal_approx(before, current_temperature):
		temperature_changed.emit(current_temperature)


## 查玩家脚下地形的编号（7海洋 8沙滩 10草原 11丛林 12矿区 13沙地 14火山 15雪地）
func _terrain_at_player() -> int:
	if _map_gen == null or not is_instance_valid(_map_gen):
		_map_gen = get_tree().get_first_node_in_group("map_gen")
		if _map_gen == null:
			return 10  # 地图未就绪时按草原处理（趋向回温，最温和）
	if not _map_gen.has_method("get_terrain_world"):
		return 10
	return int(_map_gen.get_terrain_world(_body.global_position))


# ============================================
# 饱食度：随时间下降，归零后饿到掉血
# ============================================

func _update_hunger(delta: float) -> void:
	var before: float = current_hunger
	current_hunger = clampf(current_hunger - hunger_drain_rate * delta, 0.0, max_hunger)
	_tick_starvation(delta)
	# 只在真的变了才发信号：每帧发会把 HUD 拖进无意义的刷新
	if not is_equal_approx(before, current_hunger):
		hunger_changed.emit(current_hunger)

	# 档位切换时打一条日志（调试面板「玩家」分类），只在变化时打，不刷屏
	var state := get_hunger_state()
	if state != _last_hunger_state:
		if _last_hunger_state != "":
			if state == "starving":
				DebugConfig.warn_msg(DebugConfig.CAT_PLAYER,
					"[饱食度] 饿到 0，开始每秒 -%.1f 生命", [starvation_damage])
			else:
				DebugConfig.log_msg(DebugConfig.CAT_PLAYER,
					"[饱食度] 档位 → %s（当前 %.0f）", [state, current_hunger])
		_last_hunger_state = state


## 饿到 0 就持续掉血。用累积器结算，保证扣的是整数 HP。
func _tick_starvation(delta: float) -> void:
	if _body == null or current_hunger > 0.0:
		return
	_starve_acc += starvation_damage * delta
	while _starve_acc >= 1.0:
		_starve_acc -= 1.0
		if _body.has_method("take_damage"):
			_body.call("take_damage", 1)


# ============================================
# 电量：被动效果
# ============================================

func _update_power_effects(delta: float) -> void:
	# ---- 1. 过冷 / 过热（大纲 3.2.2 · 决策 ③）----
	# 统一规则：**先扣血**（三个角色一视同仁），**再额外漏电**（仅 has_power 的角色）。
	# 这样火山 / 雪地对谁都有压力；机器人双份承担，是它多一条补给线的代价。
	var in_normal_temp: bool = (
		current_temperature > temp_cold_max and current_temperature < temp_hot_min)
	if not in_normal_temp:
		_damage_acc += extreme_temp_damage * delta
		if has_power:
			var drained: float = extreme_temp_power_drain * delta
			if drained >= current_power:
				set_power(0.0)
			else:
				set_power(current_power - drained)

	# ---- 2. 电量归零掉血 / 高电量自然回血：**都只对内置电量（机器人）生效** ----
	# 这两条都是"电量影响人物本体"的效果。电量就是机器人的命，所以
	#   归零 → 掉血、>80 且吃饱 → 缓慢自愈。
	# 而外置核心（冒险家 / 魔女装的动力核心）只是一个身外电池：
	#   它**不给人物本体任何增益，也不给任何惩罚**（用户决策 2026-09-14），
	#   只决定"耗电的交互还能不能用"。
	# 无电量 / 外置电量角色的回血出口是**吃食物**，不是这里（大纲 3.3.2）。
	# 门禁统一挂在 power_embedded 上：has_power 只表示"电量这条线在不在跑"。
	if has_power and power_embedded:
		if current_power <= 0.0:
			_damage_acc += critical_power_damage * delta
		elif (current_power > high_power_threshold
				and current_hunger > hungry_threshold
				and _body != null
				and int(_body.get("current_health")) < int(_body.get("max_health"))):
			_regen_acc += high_power_regen_rate * delta

	# ---- 3. 结算：累积满 1 点才动整数 HP（先扣后加，避免同帧互相抵消）----
	if _body == null:
		return
	while _damage_acc >= 1.0:
		_damage_acc -= 1.0
		if _body.has_method("take_damage"):
			_body.call("take_damage", 1)
	while _regen_acc >= 1.0:
		_regen_acc -= 1.0
		if _body.has_method("heal"):
			_body.call("heal", 1)


# ============================================
# 公共接口
# ============================================

## 供电（电池 +10 等）。返回实际增加量。
func add_power(amount: float) -> float:
	var before: float = current_power
	set_power(current_power + amount)
	return current_power - before


## 耗电（特殊交互）。返回是否成功（电量不足则不执行）。
func consume_power(amount: float) -> bool:
	if current_power < amount:
		return false
	set_power(current_power - amount)
	return true


func set_power(value: float) -> void:
	current_power = clampf(value, 0.0, max_power)
	power_changed.emit(current_power)


## 进食（"+N_food" 效果走这里）。返回实际增加量。
func add_hunger(amount: float) -> float:
	var before: float = current_hunger
	set_hunger(current_hunger + amount)
	return current_hunger - before


func set_hunger(value: float) -> void:
	current_hunger = clampf(value, 0.0, max_hunger)
	hunger_changed.emit(current_hunger)


## 复活时复位体征：电量回满（**仅在有电量系统的角色身上**，否则清零）、
## 体温回常温、饱食度满，并清掉累积器。
## 由 physics.gd.revive() 调用，避免复活后立刻又饿死/冷死。
func reset() -> void:
	# 没装动力核心的角色不该因为复活而凭空满电（那会让 HUD 占位行显示成有电）
	current_power = initial_power if has_power else 0.0
	current_temperature = neutral_temp_target
	current_hunger = initial_hunger
	_damage_acc = 0.0
	_regen_acc = 0.0
	_starve_acc = 0.0
	power_changed.emit(current_power)
	temperature_changed.emit(current_temperature)
	hunger_changed.emit(current_hunger)


## 低电量 / 饥饿的减速系数，供 physics.gd 每帧取用。
## 两个惩罚取更狠的那个，而不是相乘——相乘会让残血玩家几乎走不动。
func get_speed_multiplier() -> float:
	var m: float = 1.0
	# 低电量减速只惩罚**内置电量**（机器人）：动力不足 = 走不动。
	# 外置电池（冒险家 / 魔女装的核心）没电了不该拖慢腿脚——那是身外设备，
	# 和人物的行动能力无关（用户决策：外置电池不影响人物本身）。
	if power_embedded and current_power <= low_power_threshold:
		m = minf(m, low_power_speed_multiplier)
	if current_hunger <= hungry_threshold:
		m = minf(m, hunger_speed_multiplier)
	return m


## 饱食度档位：starving / hungry / normal / full
func get_hunger_state() -> String:
	if current_hunger <= 0.0:
		return "starving"
	if current_hunger <= hungry_threshold:
		return "hungry"
	if current_hunger >= well_fed_threshold:
		return "full"
	return "normal"


## 当前体温状态，便于其他系统（未来的体温 UI 配色/预警）查询
func get_temp_state() -> String:
	if current_temperature <= temp_cold_max:
		return "cold"
	if current_temperature >= temp_hot_min:
		return "hot"
	return "normal"


# ============================================
# HUD 同步
# ============================================

func _push_hud() -> void:
	if _hud == null or not is_instance_valid(_hud):
		_hud = get_tree().get_first_node_in_group("hud")
		if _hud == null:
			return

	# 先推"电量行是否亮起"，再推数值 —— 顺序反了的话第一帧会出现
	# "占位态却显示了数字"的闪烁。
	var p_active: int = 1 if has_power else 0
	if p_active != _last_power_active_shown and _hud.has_method("set_power_active"):
		_last_power_active_shown = p_active
		_hud.call("set_power_active", has_power)

	# 只在整数显示值变化时刷新，避免每帧改 Label
	var p_i := roundi(current_power)
	if p_i != _last_power_shown and _hud.has_method("update_power"):
		_last_power_shown = p_i
		_hud.call("update_power", p_i)

	var t_i := roundi(current_temperature)
	if t_i != _last_temp_shown and _hud.has_method("update_temperature"):
		_last_temp_shown = t_i
		_hud.call("update_temperature", t_i)

	var h_i := roundi(current_hunger)
	if h_i != _last_hunger_shown and _hud.has_method("update_hunger"):
		_last_hunger_shown = h_i
		_hud.call("update_hunger", h_i)
