# script/items/core_instance.gd
# ============================================
# 动力核心实例 —— 「核心」作为独立单位携带的运行时状态
#
# 【为什么需要它】
#   电量不再是"玩家身上的一个数字"，而是**核心这件特殊物品自己的属性**。
#   否则玩家把耗尽电量的核心拆下来、再装回去，电量就白白回满了 ——
#   因为装备槽当初只记了"装的是哪件物品"，没记这件物品自己的状态。
#
# 【一个核心实例携带两样东西】
#   power             —— 电量（0 ~ MAX_POWER）。它是所有耗电交互的能量来源。
#   temperature_value —— 核心**自身**的温度值（0 ~ 1000）。
#                        它和玩家自己的温度值是两套独立数据：
#                        核心按**它所在位置**的环境系数独立推进，
#                          < 350 过冷 / > 650 过热 → 每秒 -0.5 电量。
#                        在装备槽里、在背包里、掉在地上都照算，
#                        所在区块被流式卸载时随节点一起暂停。
#
# 【真值只有一份】
#   实例跟着 ItemInstance 走（见 item_instance.gd 的 core 字段），
#   在背包 ↔ 装备槽 ↔ 掉落物之间流转时**引用不变**，
#   所以电量与温度值天然连续，不需要任何"搬运状态"的代码。
#
# 【内置核心】
#   机器人（内置电量角色）开机自带一枚 is_builtin = true 的核心，
#   它不占背包格、不可拆不可丢，是机械身体的一部分。
# ============================================

class_name PowerCoreInstance
extends RefCounted

## 核心的电量上限
const MAX_POWER := 100.0

## 温度值上限（与玩家温度值同量纲）
const MAX_TEMPERATURE_VALUE := 1000.0

## 出厂温度值（500 = 正常档正中，不冷不热）
const INITIAL_TEMPERATURE_VALUE := 500.0

## 模板 id（power_core；将来的 mechanical_core 也复用本类）
var core_id: StringName = &"power_core"

## 是否是角色**自带**的内置核心（机器人机械身体的一部分）：
## 不可拆卸、不可丢弃、不占背包格。玩家身上的核心都是 false。
var is_builtin: bool = false

## 当前电量（0 ~ MAX_POWER）
var power: float = MAX_POWER

## 当前**温度值**（0 ~ 1000）—— 核心自身的环境热负荷，不是玩家的体温。
var temperature_value: float = INITIAL_TEMPERATURE_VALUE


# ----------------------------------------
# 电量比例（供 UI 画进度条用）
# ----------------------------------------
func get_power_ratio() -> float:
	if MAX_POWER <= 0.0:
		return 0.0
	return clampf(power / MAX_POWER, 0.0, 1.0)


# ----------------------------------------
# 是否彻底没电
# ----------------------------------------
func is_depleted() -> bool:
	return power <= 0.0


# ----------------------------------------
# 序列化（背包里的核心走 ItemInstance.to_dict 的 "core" 子字典）
#
# 只存"会变的状态"，模板 id 与是否内置也一起存 ——
# 机器人那枚内置核心同样要进档，读档才能对上电量。
# ----------------------------------------
func to_dict() -> Dictionary:
	return {
		"core_id": str(core_id),
		"builtin": is_builtin,
		"power": power,
		"temperature_value": temperature_value,
	}


# ----------------------------------------
# 反序列化。老存档没有字段时保持当前值（不把出厂值冲掉）。
# ----------------------------------------
func from_dict(dict: Dictionary) -> bool:
	if dict.is_empty():
		return false
	if dict.has("core_id"):
		core_id = StringName(String(dict.get("core_id", "power_core")))
	if dict.has("builtin"):
		is_builtin = bool(dict.get("builtin"))
	if dict.has("power"):
		power = clampf(float(dict.get("power")), 0.0, MAX_POWER)
	if dict.has("temperature_value"):
		temperature_value = clampf(
			float(dict.get("temperature_value")), 0.0, MAX_TEMPERATURE_VALUE)
	return true


# ----------------------------------------
# 深拷贝（duplicate / split 时用，避免两个物品共享同一条电量）
# ----------------------------------------
func duplicate_core() -> PowerCoreInstance:
	var c := PowerCoreInstance.new()
	c.core_id = core_id
	c.is_builtin = is_builtin
	c.power = power
	c.temperature_value = temperature_value
	return c
