# script/world/world_state.gd
# ============================================
# 世界状态旗标（场地永久变化）—— 纯静态，不用 autoload
#
# 为什么需要它（规格 1.6）：
#   巢穴坍塌、藤蔓长到第几天、浮空岛有没有坠落 —— 这些**既不属于敌人存档**
#   （world.enemies 存的是敌人本体的位置/血量），**也不属于 v2 的地图快照**
#   （地形快照只存 1600×1600 的瓦片，一格只有地形号）。
#   所以新开一段：world.flags。
#
# 项目约定：核心系统 = class_name + static，不挂 autoload。
# 静态实例在同一进程里跨场景存活 —— 所以**新开局/回主菜单必须 reset()**，
# 否则上一局的旗标会漏进新游戏。
# ============================================

class_name WorldState
extends RefCounted

# ============================================
# 已定义的旗标
# 值一律 int：0 = 未发生 / 1 = 已发生；vine_day 是"第几天"的计数器
# ⚠ 旗标名一旦进存档就不能改（改名 = 老档读不出来）
# ============================================
## 沙虫巢穴：0 完好 / 1 已坍塌（沙虫被打到 1 血逃走时置 1）
const FLAG_SANDWORM_NEST := &"sandworm_nest_state"
## 藤蔓长到第几天（巨鸟线用）
const FLAG_VINE_DAY := &"vine_day"
## 浮空岛：0 悬空 / 1 已坠落
const FLAG_SKY_ISLAND_FALLEN := &"skyisland_fallen"

static var _flags: Dictionary = {}

# ============================================
# 读写
# ============================================

static func set_flag(id: StringName, value: int) -> void:
	_flags[id] = value


static func get_flag(id: StringName, default_value: int = 0) -> int:
	if not _flags.has(id):
		return default_value
	return int(_flags[id])


static func has_flag(id: StringName) -> bool:
	return _flags.has(id)


static func clear_flag(id: StringName) -> void:
	_flags.erase(id)


## 对外一律给**副本**：直接把手里的 Dictionary 递出去，
## 调用方一次 .clear() 就能把世界状态清空（项目里踩过"集合被外部清空"的坑）
static func all_flags() -> Dictionary:
	return _flags.duplicate()

# ============================================
# 存档
# ============================================

## 进存档（挂到 world.flags 段）
static func serialize() -> Dictionary:
	return _flags.duplicate()


## 读档
static func apply(data: Dictionary) -> void:
	_flags = data.duplicate()


## 新开局 / 回主菜单 —— 不清它，上一局的"巢穴已坍塌"会带进新档
static func reset() -> void:
	_flags.clear()
