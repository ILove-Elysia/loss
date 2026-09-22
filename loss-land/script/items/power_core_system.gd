# script/items/power_core_system.gd
# ============================================
# 核心系统（静态服务）—— 温度场 + 核心推进
#
# 【职责】
#   1. 提供**温度场**数据：每个区域的温度系数、中性区回中、熔炉热源。
#      玩家自己的温度值（PlayerVitals）与核心的温度值用的是**同一套场**，
#      所以集中放在这里，谁都不必重复抄一份区域表。
#   2. 推进一枚核心：温度值按环境走 → 越界（<350 过冷 / >650 过热）就每秒
#      -0.5 电量。这是核心触电量的**唯一**渠道（玩家体温越界只扣血，不扣电）。
#
# 【为什么是静态类】
#   项目约定：核心系统 = class_name + static，不用 autoload
#   （与 UIManager / ItemRegistry / BuildingSystem 一致）。
#
# 【谁来驱动】
#   - 玩家身上的核心（装备槽 + 背包）：PlayerVitals._process 每帧推进，
#     用的是玩家脚下的地形系数与位置（人的位置就是核心的位置）。
#   - 掉在地上的核心：ItemDrop._process 用**掉落物自己的世界坐标**推进，
#     所以被丢在雪地里的核心会自己冻着掉电，与玩家跑多远无关；
#     所在区块被 WorldStreamer 卸载时节点移出场景树，推进随之暂停。
# ============================================

class_name PowerCoreSystem
extends RefCounted

# ============================================
# 温度场常量（区域系数 / 档位）
# ============================================

## 温度值范围
const TV_MIN := 0.0
const TV_MAX := 1000.0

## 中性区（温度系数 = 0）的**回中**目标与速率（±10 温度值/秒）。
## 系数为 0 时温度值不停表，而是朝 500 靠拢：高于 500 往下降、低于往上升，
## 补到 500 停手。于是从火山 / 雪地带回来的一身余温、一身余寒会在中性区散掉。
const TV_NEUTRAL_TARGET := 500.0
const TV_NEUTRAL_RATE := 10.0

## 温度值档位分界（左闭右开：<100 非常冷，<350 冷，<650 正常，<900 热，其余非常热）。
## 玩家体温的"变化速度"按这套档位取（见 vitals.gd 的 tv_rate_*）。
const BAND_VERY_COLD_MAX := 100.0
const BAND_COLD_MAX := 350.0
const BAND_NORMAL_MAX := 650.0
const BAND_HOT_MAX := 900.0

## 核心自身的舒适区 = **正常档（350 ~ 650 之间）**。
## ⚠ 它不是玩家体温的正常区间（10~40）—— 核心只看温度值：
##   低于 350 过冷 / 高于 650 过热 → 每秒 TEMP_DRAIN_RATE 电量。
const TEMP_DRAIN_RATE := 0.5

## 区域温度系数（温度值/秒，带符号）。
## 正 = 这块地在给角色加热，负 = 在降温，0 = 中性区（走上面的回中规则）。
## 全岛只有**火山**与**雪地**两个极端区，其余全是中性区。
## 键 = 地形编号（7海 8沙滩 10草原 11丛林 12矿区 13沙地 14火山 15雪地）。
const REGION_COEFFICIENT := {
	7: 0.0,     # 海洋：中性（落水会直接淹死，不再叠加温度惩罚）
	8: 0.0,     # 沙滩：中性
	10: 0.0,    # 草原：中性（出生点）
	11: 0.0,    # 丛林：中性
	12: 0.0,    # 矿区：中性
	13: 0.0,    # 沙地：中性
	14: 6.0,    # 火山：极热，唯一的加热区
	15: -6.0,   # 雪地：极寒，唯一的降温区
}

## 落在未登记地形上时用的系数（中性）
const DEFAULT_COEFFICIENT := 0.0


# ============================================
# 温度场查询
# ============================================

## 地形编号 → 温度系数（不带热源，纯区域）
static func region_coefficient(terrain: int) -> float:
	return float(REGION_COEFFICIENT.get(terrain, DEFAULT_COEFFICIENT))


## 世界坐标 → 本帧生效的温度系数（**热源优先于地形**）。
## 熔炉半径内就持续加热，不封顶 —— 温度值会一路涨到 1000（温度值上限），
## 所以在火边待久了会过热，得自己挪开（用户决策 2026-09-16）。
static func coefficient_at(world_pos: Vector3, terrain: int) -> float:
	var heater := BuildingSystem.get_heater_at(world_pos)
	if heater != null:
		var hdef := BuildingSystem.get_def(StringName(heater.get("building_id")))
		var heat_rate := float(hdef.get("heat_value_rate", 0.0))
		if heat_rate > 0.0:
			return heat_rate
	return region_coefficient(terrain)


# ============================================
# 温度值推进（玩家与核心共用同一条规则）
# ============================================

## 推进**温度值**一步。
## 玩家温度值 = 原有温度值 + 温度系数 × 时间；系数为 0 时改走回中。
static func advance_temperature_value(
		tv: float, delta: float, coefficient: float) -> float:
	if is_zero_approx(coefficient):
		return move_toward(tv, TV_NEUTRAL_TARGET, TV_NEUTRAL_RATE * delta)
	return clampf(tv + coefficient * delta, TV_MIN, TV_MAX)


# ============================================
# 核心推进
# ============================================

## 核心是否处在舒适（不掉电）的温度值区间。
## 注意用的是**核心自己的温度值**，与玩家体温无关。
static func is_comfortable(temperature_value: float) -> bool:
	return temperature_value >= BAND_COLD_MAX and temperature_value <= BAND_NORMAL_MAX


## 核心此刻的温度档位（"cold" / "normal" / "hot"），供日志与 UI 用。
static func get_band(temperature_value: float) -> String:
	if temperature_value < BAND_COLD_MAX:
		return "cold"
	if temperature_value > BAND_NORMAL_MAX:
		return "hot"
	return "normal"


## 推进一枚核心一帧：先走温度值，再结算"过冷 / 过热掉电"。
## 电量归零后不再往下扣（clamp 到 0，不会变成负数）。
static func tick_core(
		core: PowerCoreInstance, delta: float, coefficient: float) -> void:
	if core == null:
		return
	core.temperature_value = advance_temperature_value(
		core.temperature_value, delta, coefficient)
	if not is_comfortable(core.temperature_value):
		core.power = maxf(0.0, core.power - TEMP_DRAIN_RATE * delta)


# ============================================
# 工厂
# ============================================

## 造一枚核心：出厂满电 + 常温温度值。
##
## 所有产生核心的入口（制作台产出、掉落、测试箱、读档兜底）都必须走这里，
## 否则会出现"空壳核心"——有物品、没电量状态。
static func create_core(
		core_id: StringName = &"power_core", builtin: bool = false) -> PowerCoreInstance:
	var core := PowerCoreInstance.new()
	core.core_id = core_id
	core.is_builtin = builtin
	core.power = PowerCoreInstance.MAX_POWER
	core.temperature_value = PowerCoreInstance.INITIAL_TEMPERATURE_VALUE
	return core


## 给一枚核心充电（电池）。返回实际增加量。
static func charge_core(core: PowerCoreInstance, amount: float) -> float:
	if core == null or amount <= 0.0:
		return 0.0
	var before: float = core.power
	core.power = clampf(core.power + amount, 0.0, PowerCoreInstance.MAX_POWER)
	return core.power - before


## 从一枚核心扣电（耗电交互）。返回是否成功（电量不足则不执行）。
static func drain_core(core: PowerCoreInstance, amount: float) -> bool:
	if core == null or amount <= 0.0:
		return false
	if core.power < amount:
		return false
	core.power = clampf(core.power - amount, 0.0, PowerCoreInstance.MAX_POWER)
	return true
