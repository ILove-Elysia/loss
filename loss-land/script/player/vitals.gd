# script/player/vitals.gd
# ============================================
# 玩家生命体征：电量 + 体温（大纲 3.1 / 3.2） + 饱食度（本次新增）
#
# 挂载：player.tscn 根节点下（名为 Vitals），与 Physics 平级。
# 独立成组件而不是塞进 physics.gd——物理脚本已经 300 行，
# 状态系统与移动逻辑解耦后各自可测。
#
# 电量（大纲 3.1）—— **两条互相独立的电量线**（用户决策 2026-09-16）：
#
#   【自身电量】= current_power，**内置**电量的载体。
#     只有机器人（power_embedded）有它：电量来自机械身体本身，不是一件物品，
#     所以没有"核心实例"可挂。规则：
#       ≤10 低电量：移速 ×0.7
#       =0  濒危：每秒 -1 生命值
#       >80 且吃饱：+5 生命值/分钟
#       体温越界：每秒 -0.5 电量
#
#   【核心电量】挂在 **PowerCoreInstance** 上（见 script/items/core_instance.gd），
#     不属于玩家。核心是一件独立单位：电量和它自己的温度值都跟着物品走，
#     在装备槽 / 背包 / 地上都独立结算 —— 拆下再装回去电量**不会**回满。
#       核心温度值 <350 过冷 / >650 过热：每秒 -0.5 电量
#       它对人物本体**零影响**（不掉血、不减速、不回血），
#       只决定"耗电的交互还能不能用"。
#
#   冒险家 / 魔女没有自身电量，电量全部来自核心；没装核心时 HUD 显示占位。
#   机器人装了核心就有两块电池，**各自按自己的规则结算**，互不干扰。
#   电池（+10_power）会同时补给自身电量与手上这枚核心，各自夹到上限。
#
# 温度（大纲 3.2）——**两个不同的属性**：
#   【温度值】0~1000，环境给玩家的"热收支总量"。每个区域用一个**带符号的常数**
#             「温度系数」（单位：温度值/秒）持续推动它：
#               正 = 环境在加热，负 = 环境在降温，0 = 中性区（不推动）。
#             玩家温度值 = 原有温度值 + 温度系数 × 时间。
#             ⚠ 温度场数据与规则统一放在 **PowerCoreSystem**（核心与玩家共用同一套场）。
#   【体温】身体的真实温度（-100~100，正常 10~40）。它**不再直接看地形**，
#           而是由**温度值所在的档位**决定往哪边走、走多快：
#             0~100   非常冷  → -2°/s
#             100~350 冷      → -1°/s
#             350~650 正常    →  0
#             650~900 热      → +1°/s
#             900~1000 非常热 → +2°/s
#           体温 = 原有体温 + 体温变化速度 × 时间。
#   - 体温越界（≤10 / ≥40）：每秒 -0.5 生命值。**所有角色一视同仁**。
#     注意：体温越界**只扣血**，不再扣电 —— 电的流失只认核心自己的温度值。
#   - 档位速度**原样生效**，不与环境推力方向做任何对齐（用户决策 2026-09-16）：
#     温度值还在冷档时，哪怕站在火山口体温也照样按 -1°/s 继续掉 ——
#     过冷的人进温暖环境不会立刻变暖，要等温度值被推过 650 才回升。
#   - 中性区（温度系数 = 0）里温度值**回中**（±10/秒 朝常温 500 收），
#     体温改由身体自己调节回 30（10/分钟）。完整规则见 _update_temperature()。
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
#   power_embedded = false（冒险家 / 魔女）：没有自身电量、不自然回血，
#   HUD 电量行显示为"占位"；体温越界**直接扣血**（决策 ③），与机器人的"漏电"对称。
#   开局默认值由 CharacterRegistry.has_embedded_power() 在 _apply_character() 里决定。
#   ⚠ "到底有没有电可用"（has_power）是**运行时**状态 —— 装上一枚核心就有了，
#     所以它是个只读计算属性，不要在别处再缓存一份。
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
## 核心电量变化（装/卸核心、充电、过冷过热漏电都会触发）。
## 与 power_changed（自身电量）是两块不同的电池。
signal core_power_changed(power: float)
signal temperature_changed(temp: float)
## 温度值（环境热负荷，0~1000）变化时发。与 temperature_changed（体温）是两个属性。
signal temperature_value_changed(value: float)
signal hunger_changed(hunger: float)

## ---------- 自身电量参数（大纲 3.1.1 / 3.1.3 / 3.1.4） ----------
## 这一组只作用于**内置电量**（机器人）：它是机械身体的动力，是它的生命线。
## 核心里那块电池走自己的规则（PowerCoreSystem.TEMP_DRAIN_RATE），不读这里的值。
@export var max_power: float = 100.0
@export var initial_power: float = 100.0
## 低电量阈值：低于它移动速度乘 low_power_speed_multiplier
@export var low_power_threshold: float = 10.0
## 低电量移速惩罚（大纲：-30%）
@export var low_power_speed_multiplier: float = 0.7
## 高电量（>80）生命恢复，HP/秒（大纲：+5 HP/分钟）
## **仅内置电量**（机器人靠机械身体自愈）；核心不给回血 —— 装核心不是治疗
@export var high_power_regen_rate: float = 5.0 / 60.0
## 高电量回血的电量门槛
@export var high_power_threshold: float = 80.0
## 濒危（=0）每秒掉的生命值
@export var critical_power_damage: float = 1.0

## ---------- 体温参数（第二属性，大纲 3.2.1 / 3.2.2） ----------
## 体温是"身体的真实温度"。**怎么变**由温度值档位决定（见下方 tv_rate_*），
## 这里只管"体温是多少算过冷 / 过热、越界怎么罚"。
## 正常区间（无影响）
@export var temp_normal_min: float = 10.0
@export var temp_normal_max: float = 40.0
## 过冷上限（≤10 为过冷）与过热下限（≥40 为过热）
@export var temp_cold_max: float = 10.0
@export var temp_hot_min: float = 40.0
## 体温越界时每秒流失的**自身电量**（大纲：每秒 -0.5）。
## 只对内置电量（机器人）生效：它的身体冷了 / 热了，电池也跟着掉。
## ⚠ 核心里那块电池**不看体温**，只看核心自己的温度值（见 _update_cores）。
@export var extreme_temp_power_drain: float = 0.5
## 体温越界时每秒扣的生命值（大纲 3.2.2 决策 ③）——**所有角色一视同仁**。
## 有自身电量的角色是"扣血 + 漏电"双份惩罚（机器人多一条补给线的代价）。
@export var extreme_temp_damage: float = 0.5
## 体温绝对范围
@export var temp_abs_min: float = -100.0
@export var temp_abs_max: float = 100.0
## **环境无推力**（温度系数 = 0，即所有中性区）时的**体温**回温目标与速率：
## 身体自己调节回 30，中性区才当得起"家"。
@export var neutral_temp_target: float = 30.0
@export var neutral_temp_rate: float = 10.0 / 60.0

## ---------- 体温档位速度（大纲 3.2.4） ----------
## 玩家的**温度值**落在哪个档位 → 体温以多快变化（度/秒）。
## ⚠ 档位分界（100 / 350 / 650 / 900）与温度值推进规则统一放在
## PowerCoreSystem，那里是核心与玩家共用的温度场，不在这里重复定义。
@export var tv_rate_very_cold: float = -2.0
@export var tv_rate_cold: float = -1.0
@export var tv_rate_normal: float = 0.0
@export var tv_rate_hot: float = 1.0
@export var tv_rate_very_hot: float = 2.0

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

## 本局角色是否**自带（内置）电量**（大纲 2.2.3：机器人开机即 true）。
## 这是"电量能否影响人物本体"的总闸门：归零掉血、低电减速、>80 回血、
## 体温越界漏电 —— 四条都只对内置电量生效。
## 本字段来自角色注册表，运行时不变（核心是外挂设备，不改它）。
var power_embedded: bool = false

## 当前是否**有电可用**：自带内置电量，或者装着带电池的核心。
##
## ⚠ 只读计算属性。核心可装可拆，所以它必须实时反映装备状态 ——
## 不要在别处再缓存一份"有没有电"（HUD 的"占位 ↔ 亮起"就看它）。
var has_power: bool:
	get:
		return power_embedded or _get_core() != null

## 当前**自身电量**（0 ~ max_power）。
## 只有内置电量的角色（机器人）用它：电量来自机械身体本身，不是一件物品。
## 冒险家 / 魔女没有自身电量，他们的电量全部在核心实例上（见 _get_core）。
var current_power: float
## 当前**温度值**（0 ~ PowerCoreSystem.TV_MAX）—— 环境热负荷，决定体温怎么变。
var current_temperature_value: float
## 当前体温（temp_abs_min ~ temp_abs_max）
var current_temperature: float
## 当前饱食度（0 ~ max_hunger）
var current_hunger: float

var _body: CharacterBody3D
var _map_gen: Node
var _hud: Node
## 装备 / 背包节点缓存：核心电量与"身上所有核心"都要从这里取
var _equipment: Node
var _inventory: Node

# 生命值按秒累积的计数器（伤害/恢复都是整数 HP，累积满 1 才结算）
var _damage_acc: float = 0.0
var _regen_acc: float = 0.0
var _starve_acc: float = 0.0
# 上次推给 HUD 的整数显示值（避免每帧刷 HUD）
var _last_power_shown: int = -1
var _last_core_power_shown: int = -1
var _last_temp_shown: int = -9999
var _last_hunger_shown: int = -1
## 上次的温度值档位，用于只在跨档时打一条日志（不刷屏）
var _last_temp_band: String = ""
## 上次推给 HUD 的"自身电量行是否亮起" / "核心电量行是否显示"
## （-1 = 还没推过，首帧必推一次）。用 int 哨兵值而不是 bool，
## 就是为了让首帧一定能推一次 —— HUD 的 _ready 可能早于/晚于本组件，
## 靠这一推自纠正，不依赖初始化顺序。
var _last_power_active_shown: int = -1
var _last_core_active_shown: int = -1
# 上次的饱食度档位，用于只在切换时打一条调试日志
var _last_hunger_state: String = ""


func _ready() -> void:
	# 角色差异（电量上限 / 极端温度漏电 / 饱食度消耗）必须在给 current_* 赋初值前应用，
	# 否则会拿旧的 max_power 去 clamp，开局电量对不上角色。
	_apply_character()
	current_power = initial_power
	current_temperature_value = PowerCoreSystem.TV_NEUTRAL_TARGET
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
	core_power_changed.emit(get_core_power())
	temperature_changed.emit(current_temperature)
	temperature_value_changed.emit(current_temperature_value)
	hunger_changed.emit(current_hunger)


## 应用本局角色的系统开关（是否有内置电量）。
## 大纲 v0.7 的设计意图是**三个角色数值完全相同、差异全部来自系统**，
## 所以这里不乘任何数值倍率，只决定"自身电量"这条线在不在。
## 读档时 SaveManager 会在本函数之后用存档值覆盖 current_*，不冲突。
func _apply_character() -> void:
	var id: String = CharacterRegistry.get_active_id()
	power_embedded = CharacterRegistry.has_embedded_power(id)
	power_changed.emit(current_power)


## 核心槽发生变化时由 PlayerEquipment 调用（装 / 卸 / 读档恢复）。
##
## 核心是**不参与人物本体结算**的外挂设备：它变化时玩家本人没有任何数值要重算，
## 只需要（1）清掉累积器，避免装卸瞬间的残留伤害跳一下；
## （2）把两条电量行重新推给 HUD（"亮起 / 占位 / 多一行"都靠它自纠正）。
func on_core_changed() -> void:
	_damage_acc = 0.0
	_regen_acc = 0.0
	_push_hud()


func _process(delta: float) -> void:
	_tick(delta)


# ============================================
# 主循环（测试可直接调用，传大步长）
# ============================================

func _tick(delta: float) -> void:
	# 玩家是否活着：用本体 is_alive() 判定。死亡期间（HP=0 且 dead 标记），
	# 体温与身上核心的温度值都**冻结**——尸体不再有热收支（用户需求 2026-09-16）。
	# 饱食度 / 电量被动效果照常跑（无害，且复活时体征会被 reset() 统一重设）。
	var alive: bool = (_body == null) or (not _body.has_method("is_alive") or _body.is_alive())

	# 温度与核心都需要玩家世界坐标；没绑定本体时（极端情况）只跑不依赖位置的部分
	if _body == null:
		_update_hunger(delta)
		_update_power_effects(delta)
		_push_hud()
		return

	# 本帧生效的**温度系数**（温度值/秒，带符号）：热源优先，否则取脚下地形。
	# 算一次就够 —— 玩家自己的温度值与身上的核心用**同一个环境**。
	var terrain: int = _terrain_at_player()
	var coefficient: float = PowerCoreSystem.coefficient_at(
		_body.global_position, terrain)

	if alive:
		_update_temperature(delta, coefficient)
		_update_cores(delta, coefficient)
	_update_hunger(delta)
	_update_power_effects(delta)
	_push_hud()


# ============================================
# 温度：温度值（环境驱动）→ 体温（档位驱动）
# ============================================

func _update_temperature(delta: float, coefficient: float) -> void:
	var before: float = current_temperature
	var before_value: float = current_temperature_value

	# 体温变化速度用**本帧开始时**的温度值定档。若先改温度值再定档，
	# 大步长下结果会随步长漂移（测试里一次 tick 就是几十秒）。
	var rate: float = get_temp_band_rate()

	# ---- 1. 温度值：玩家温度值 = 原有温度值 + 温度系数 × 时间 ----
	# 系数为 0（中性区）时改走"回中"：以 ±10/秒 朝 500 靠拢，补到 500 停手 ——
	# 从火山 / 雪地带回来的一身余温、一身余寒都会在这里被慢慢抹平。
	# 规则与核心共用同一份实现（PowerCoreSystem.advance_temperature_value）。
	current_temperature_value = PowerCoreSystem.advance_temperature_value(
		current_temperature_value, delta, coefficient)

	# ---- 2. 体温：变化速度由温度值档位给出 ----
	# 体温 = 原有体温 + 体温变化速度 × 时间
	if is_zero_approx(coefficient):
		# 环境对温度值**没有任何推力**（中性区）：
		# 身体自己调节，体温按 neutral_temp_rate 回温到 neutral_temp_target。
		current_temperature = move_toward(
			current_temperature, neutral_temp_target, neutral_temp_rate * delta)
	else:
		# 档位速度**原样生效**，不与环境推力方向做任何对齐（用户决策 2026-09-16）：
		# 现实中过冷的人进入温暖环境也不会**立刻**变暖。所以带着一身寒气冲进火山，
		# 只要温度值还在冷档，体温就照旧按 -1°/s 往下掉，要等温度值被推过 650
		# 才转为回升；反过来从火山冲进雪地，也会先把热气散完再开始变冷。
		current_temperature = clampf(
			current_temperature + rate * delta, temp_abs_min, temp_abs_max)

	if not is_equal_approx(before, current_temperature):
		temperature_changed.emit(current_temperature)
	if not is_equal_approx(before_value, current_temperature_value):
		temperature_value_changed.emit(current_temperature_value)

	# 跨档时打一条日志（调试面板「玩家」分类），只在切换时打，不刷屏
	var band: String = get_temp_band()
	if band != _last_temp_band:
		if _last_temp_band != "":
			DebugConfig.log_msg(DebugConfig.CAT_PLAYER,
				"[温度] 档位 → %s（温度值 %.0f，体温变化 %.1f°/s，环境系数 %.1f/s）",
				[get_temp_band_name(band), current_temperature_value, rate, coefficient])
		_last_temp_band = band


# ============================================
# 核心：玩家身上（装备槽 + 背包）的每一枚核心都独立走温度值
# ============================================

## 推进**玩家身上所有核心**一帧。
##
## 装备槽里的那枚与背包里的每一枚都算 —— 核心是独立单位，
## 只要在玩家身上，环境（脚下地形 / 熔炉）就同时在影响它的温度值；
## 掉了电它就自己掉，玩家把它背回火边它也会自己回暖。
##
## 位置参数用的是玩家脚下 —— 装在身上的东西，位置就是人的位置。
## 掉在地上的核心不归这里管：它们由 ItemDrop 用自己的坐标推进。
func _update_cores(delta: float, coefficient: float) -> void:
	var cores: Array[PowerCoreInstance] = _collect_carried_cores()
	if cores.is_empty():
		return
	for c in cores:
		PowerCoreSystem.tick_core(c, delta, coefficient)


## 收集玩家身上的所有核心状态（装备槽 1 枚 + 背包里的每一枚）。
##
## 每帧重新收集而不是缓存列表：核心会随拾取 / 丢弃 / 装拆进进出出，
## 背包 20 格的遍历成本可以忽略，缓存反而要处理一堆失效情况。
func _collect_carried_cores() -> Array[PowerCoreInstance]:
	var out: Array[PowerCoreInstance] = []

	var equip := _get_equipment()
	if equip != null and equip.has_method("get_core_instance"):
		var equipped = equip.call("get_core_instance")
		if equipped != null:
			out.append(equipped)

	var inv := _get_inventory()
	if inv != null and inv.has_method("get_all_items"):
		for it in inv.call("get_all_items"):
			var inst: ItemInstance = it
			if inst != null and inst.core != null:
				out.append(inst.core)

	return out


## 装备槽里的核心状态（没有则 null）。玩家的"外置电量"就是它。
func _get_core() -> PowerCoreInstance:
	var equip := _get_equipment()
	if equip == null or not equip.has_method("get_core_instance"):
		return null
	var c = equip.call("get_core_instance")
	if c == null:
		return null
	return c


func _get_equipment() -> Node:
	if _equipment == null or not is_instance_valid(_equipment):
		var parent := get_parent()
		_equipment = parent.get_node_or_null("Equipment") if parent != null else null
	return _equipment


func _get_inventory() -> Node:
	if _inventory == null or not is_instance_valid(_inventory):
		var parent := get_parent()
		_inventory = parent.get_node_or_null("Inventory") if parent != null else null
	return _inventory


## 温度值 → 档位 id（very_cold / cold / normal / hot / very_hot）
## 档位分界来自 PowerCoreSystem（核心与玩家共用的温度场），不在这里重复定义。
func get_temp_band() -> String:
	if current_temperature_value < PowerCoreSystem.BAND_VERY_COLD_MAX:
		return "very_cold"
	if current_temperature_value < PowerCoreSystem.BAND_COLD_MAX:
		return "cold"
	if current_temperature_value < PowerCoreSystem.BAND_NORMAL_MAX:
		return "normal"
	if current_temperature_value < PowerCoreSystem.BAND_HOT_MAX:
		return "hot"
	return "very_hot"


## 档位 id → 中文名（日志 / 调试面板 / 未来的 HUD）
static func get_temp_band_name(band: String) -> String:
	match band:
		"very_cold":
			return "非常冷"
		"cold":
			return "冷"
		"hot":
			return "热"
		"very_hot":
			return "非常热"
		_:
			return "正常"


## 当前温度值档位对应的**体温变化速度**（度/秒）
func get_temp_band_rate() -> float:
	match get_temp_band():
		"very_cold":
			return tv_rate_very_cold
		"cold":
			return tv_rate_cold
		"hot":
			return tv_rate_hot
		"very_hot":
			return tv_rate_very_hot
		_:
			return tv_rate_normal


## 查玩家脚下地形的编号（7海洋 8沙滩 10草原 11丛林 12矿区 13沙地 14火山 15雪地）
func _terrain_at_player() -> int:
	if _map_gen == null or not is_instance_valid(_map_gen):
		_map_gen = get_tree().get_first_node_in_group("map_gen")
		if _map_gen == null:
			return 10  # 地图未就绪时按草原处理（中性区，最温和）
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
	# ---- 1. 体温越界（大纲 3.2.2 · 决策 ③）----
	# 统一规则：**先扣血**（所有角色一视同仁），**再额外漏自身电量**（仅内置电量）。
	# 这样火山 / 雪地对谁都有压力；机器人双份承担，是它多一条补给线的代价。
	# ⚠ 核心里那块电池**不走这里**：它只看核心自己的温度值（见 _update_cores），
	#   所以"体温越界"与"核心温度值越界"是两条互不相干的漏电渠道。
	var in_normal_temp: bool = (
		current_temperature > temp_cold_max and current_temperature < temp_hot_min)
	if not in_normal_temp:
		_damage_acc += extreme_temp_damage * delta
		if power_embedded:
			var drained: float = extreme_temp_power_drain * delta
			if drained >= current_power:
				set_power(0.0)
			else:
				set_power(current_power - drained)

	# ---- 2. 自身电量归零掉血 / 高电量自然回血：**只对内置电量（机器人）生效** ----
	# 这两条都是"电量影响人物本体"的效果。电量就是机器人的命，所以
	#   归零 → 掉血、>80 且吃饱 → 缓慢自愈。
	# 而核心（冒险家 / 魔女装的动力核心）只是一个身外电池：
	#   它**不给人物本体任何增益，也不给任何惩罚**（用户决策 2026-09-14），
	#   只决定"耗电的交互还能不能用"。
	# 只有核心 / 没有电量的角色的回血出口是**吃食物**，不是这里（大纲 3.3.2）。
	if power_embedded:
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

## 供电（电池 +10 等）。返回**两块电池加起来**的实际增加量。
##
## 电池补的是"身上的电"：自身电量（内置，如果有）与装备中的核心各充 amount，
## 各自夹到上限。只充一块会让另一块永远补不回来 ——
## 机器人装了核心之后，如果电池只认核心，它的命（自身电量）就再也回不去了。
func add_power(amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var gained: float = 0.0
	if power_embedded:
		var before_self: float = current_power
		set_power(current_power + amount)
		gained += current_power - before_self
	var core := _get_core()
	if core != null:
		gained += PowerCoreSystem.charge_core(core, amount)
		core_power_changed.emit(core.power)
	return gained


## 耗电（特殊交互）。返回是否成功（电量不足则不执行）。
##
## 优先级：装备中的核心 → 自身电量。核心本来就是给耗电设备供电的那块电池，
## 机器人只有在没装核心时才动用自己的内置电量。
func consume_power(amount: float) -> bool:
	if amount <= 0.0:
		return false
	var core := _get_core()
	if core != null and core.power >= amount:
		return PowerCoreSystem.drain_core(core, amount)
	if power_embedded and current_power >= amount:
		set_power(current_power - amount)
		return true
	return false


## 直接设定**自身电量**（读档 / 调试用）。
## 核心电量不在这里 —— 它是核心自己的属性，见 set_core_power。
func set_power(value: float) -> void:
	current_power = clampf(value, 0.0, max_power)
	power_changed.emit(current_power)


# ============================================
# 公共接口 —— 核心电量（属于核心这件物品，不是玩家）
# ============================================

## 装备槽里那枚核心的电量（0 ~ 100）。没装核心 / 核心不带电池时返回 0。
func get_core_power() -> float:
	var core := _get_core()
	if core == null:
		return 0.0
	return core.power


## 直接设定核心电量（读档 / 调试用）
func set_core_power(value: float) -> void:
	var core := _get_core()
	if core == null:
		return
	core.power = clampf(value, 0.0, PowerCoreInstance.MAX_POWER)
	core_power_changed.emit(core.power)


## 给核心充电。返回实际增加量。
func add_core_power(amount: float) -> float:
	var core := _get_core()
	if core == null:
		return 0.0
	var gained: float = PowerCoreSystem.charge_core(core, amount)
	if gained > 0.0:
		core_power_changed.emit(core.power)
	return gained


## 从核心扣电。返回是否成功（电量不足则不执行）。
func consume_core_power(amount: float) -> bool:
	var core := _get_core()
	if core == null:
		return false
	return PowerCoreSystem.drain_core(core, amount)


## 进食（"+N_food" 效果走这里）。返回实际增加量。
func add_hunger(amount: float) -> float:
	var before: float = current_hunger
	set_hunger(current_hunger + amount)
	return current_hunger - before


func set_hunger(value: float) -> void:
	current_hunger = clampf(value, 0.0, max_hunger)
	hunger_changed.emit(current_hunger)


## 直接设定**温度值**（读档 / 调试用）。走 setter 而不是裸赋值，
## 是为了让外部拿到 temperature_value_changed 去刷新自己的缓存。
func set_temperature_value(value: float) -> void:
	current_temperature_value = clampf(value, 0.0, PowerCoreSystem.TV_MAX)
	temperature_value_changed.emit(current_temperature_value)


## 直接设定**体温**（读档 / 调试用），同上。
func set_temperature(value: float) -> void:
	current_temperature = clampf(value, temp_abs_min, temp_abs_max)
	temperature_changed.emit(current_temperature)


## 复活时复位体征（用户需求 2026-09-16）：
##   所有属性回到上限的一半 —— 自身电量 = max_power/2（仅内置电量的角色）、
##   饱食度 = max_hunger/2、HP 由 physics.revive() 设半血。
##   体温与温度值回到常温档（**不是减半**：体温上半 = 50 会落入过热区，是 Bug）。
##   携带的核心：复活后电量清零（不是一半，也不是满）。
##   —— 死亡期间温度已冻结（见 _tick），复活作为惩罚把核心充能抹掉，
##      没电了该由玩家拿电池充，而不是复活白送。
##   ⚠ 核心清零范围：装备槽里的那枚 + 背包里每一枚（"携带"= 身上任何一枚）。
func reset() -> void:
	# 自身电量 / 饱食度各回到上限一半
	current_power = (max_power * 0.5) if power_embedded else 0.0
	current_hunger = max_hunger * 0.5
	# 体温 / 温度值回到常温档（半血之外的"软重置"，避免复活即冷热死）
	current_temperature_value = PowerCoreSystem.TV_NEUTRAL_TARGET
	current_temperature = neutral_temp_target
	# 携带的核心复活清零（用户需求 2026-09-16）
	for c in _collect_carried_cores():
		c.power = 0.0
	# 清掉累积器
	_damage_acc = 0.0
	_regen_acc = 0.0
	_starve_acc = 0.0
	power_changed.emit(current_power)
	core_power_changed.emit(get_core_power())
	temperature_changed.emit(current_temperature)
	temperature_value_changed.emit(current_temperature_value)
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

	# 先推"哪几行亮起"，再推数值 —— 顺序反了的话第一帧会出现
	# "占位态却显示了数字"的闪烁。
	#
	# 两条电量行（用户决策 2026-09-16）：
	#   自身电量行 → 只有内置电量的角色（机器人）才亮起
	#   核心电量行 → 装着带电池的核心时出现
	# 两者都没有时，HUD 会把自身行退回"⚡ --"占位（由 HUD 自己决定）。
	var p_active: int = 1 if power_embedded else 0
	if p_active != _last_power_active_shown and _hud.has_method("set_power_active"):
		_last_power_active_shown = p_active
		_hud.call("set_power_active", power_embedded)

	var core := _get_core()
	var c_active: int = 1 if core != null else 0
	if c_active != _last_core_active_shown and _hud.has_method("set_core_active"):
		_last_core_active_shown = c_active
		_hud.call("set_core_active", core != null)

	# 只在整数显示值变化时刷新，避免每帧改 Label
	var p_i := roundi(current_power)
	if p_i != _last_power_shown and _hud.has_method("update_power"):
		_last_power_shown = p_i
		_hud.call("update_power", p_i)

	if core != null:
		var cp_i := roundi(core.power)
		if cp_i != _last_core_power_shown and _hud.has_method("update_core_power"):
			_last_core_power_shown = cp_i
			_hud.call("update_core_power", cp_i)
	else:
		# 核心没了：重置哨兵，下一次装上时才会重新推一次数值
		_last_core_power_shown = -1

	var t_i := roundi(current_temperature)
	if t_i != _last_temp_shown and _hud.has_method("update_temperature"):
		_last_temp_shown = t_i
		_hud.call("update_temperature", t_i)

	var h_i := roundi(current_hunger)
	if h_i != _last_hunger_shown and _hud.has_method("update_hunger"):
		_last_hunger_shown = h_i
		_hud.call("update_hunger", h_i)
