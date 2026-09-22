# script/building/building_system.gd
# ============================================
# 建造系统 - 建筑定义的唯一来源 + 已放置建筑的查询入口
#
# 为什么用 class_name + 静态方法（而不是 autoload）：
#   和 CraftingSystem / ItemRegistry / UIManager 同样的理由——
#   `godot --script` 的 headless 模式不加载 autoload，全局名在编译期不可见。
#
# 建筑定义为什么用 Dictionary 而不是 Resource（.tres）：
#   照抄 CraftingSystem 配方的做法——Demo 阶段代码里注册就够用，
#   省去为三个建筑各建一个 .tres 与 uid。将来要可视化调参时再迁。
#
# 定义表为什么是懒加载的 static var 而不是 const：
#   GDScript 的 const 只允许常量表达式，Color(...) / Vector2(...) 这类
#   构造函数调用会报 "non-constant value in constant expression"。
#   所以颜色/尺寸先存成普通数组 [r,g,b] / [w,h]，运行时再取用。
#
# 三个建筑的实际效果（大纲 3.5.2）：
#   工作台   - 放置后【永久】解锁需要工作台的高级配方
#   熔炉     - 放置后【永久】解锁铁锭 / 铁剑 / 铁镐配方（station = furnace），
#              同时在半径内提供热源（heat_value_rate，见下）
#   储物箱   - 放置后在其半径内可打开，提供 storage 格额外存储
#
# 注意「永久解锁」是有意的选择：若要求玩家必须站在工作台旁才能合成，
# 走远后合成界面会整片变灰，玩家会以为是 bug。饥饿/饥荒的 science machine
# 也是首次靠近即永久解锁。熔炉的热源与储物箱的存取则必须靠近——
# 那是物理属性，符合直觉，也让"放在哪"这件事有意义。
# （制作站与热源是两套判定：has_station 看"放没放过"，get_heater_at 看"人在不在附近"。）
# ============================================

class_name BuildingSystem
extends RefCounted

## 建筑类型标记：物品 id 出现在 DEFS 里即为"可放置建筑"
## 取不到定义时返回空字典，调用方用 is_empty() 判断。

static var _defs: Dictionary = {}
static var _built: bool = false

## 已放置的建筑实体（Building 节点）
static var _placed: Array = []


# ============================================
# 建筑定义
# ============================================

static func _ensure_built() -> void:
	if _built:
		return

	_defs[&"workbench"] = {
		"name": "工作台",
		"station": &"workbench",
		"storage": 0,
		"heat_value_rate": 0.0,
		"heat_radius": 0.0,
		"color": [0.62, 0.45, 0.24],
		"size": [1.6, 1.0],
		"tip": "放置后解锁高级合成配方（石制工具、石剑、木甲）",
	}

	_defs[&"furnace"] = {
		"name": "熔炉",
		"station": &"furnace",
		"storage": 0,
		# 热源规则（大纲 3.2.3）：熔炉把**温度值**往上顶，速率 heat_value_rate
		# （温度值/秒）。**只要人在 5 米内就持续加热，不封顶在常温**（用户决策
		# 2026-09-16）—— 温度值最高涨到 1000，所以火边能救命、待久了也会过热，
		# 得自己挪开（与饥荒的火堆一致）。
		"heat_value_rate": 20.0,
		"heat_radius": 5.0,
		"color": [0.38, 0.36, 0.34],
		"size": [1.2, 1.4],
		"tip": "放置后解锁铁锭与铁制装备，并在周围 5 米内提供热源",
	}

	_defs[&"storage_box"] = {
		"name": "储物箱",
		"station": &"",
		"storage": 20,
		"heat_value_rate": 0.0,
		"heat_radius": 0.0,
		"color": [0.55, 0.40, 0.22],
		"size": [1.1, 0.9],
		"tip": "放置后在附近点击可打开，提供 20 格额外存储",
	}

	_built = true


## 取建筑定义（未定义返回空字典）
static func get_def(building_id: StringName) -> Dictionary:
	_ensure_built()
	return _defs.get(building_id, {})


## 该物品 id 是否是可放置建筑
static func is_building(item_id: StringName) -> bool:
	_ensure_built()
	return _defs.has(item_id)


## 建筑中文名
static func get_display_name(building_id: StringName) -> String:
	return String(get_def(building_id).get("name", building_id))


## 全部可放置建筑的 id
static func get_all_ids() -> Array[StringName]:
	_ensure_built()
	var ids: Array[StringName] = []
	for k in _defs:
		ids.append(StringName(k))
	return ids


# ============================================
# 已放置建筑的登记
# ============================================

static func register(building: Node) -> void:
	if building == null or _placed.has(building):
		return
	_placed.append(building)


static func unregister(building: Node) -> void:
	_placed.erase(building)


## 清空登记表（切场景 / 重开游戏时调用，否则会残留已释放的节点）
static func clear() -> void:
	_placed.clear()


## 全部已放置建筑（返回副本，避免外部清掉内部数组）
static func get_placed() -> Array:
	_prune_invalid()
	return _placed.duplicate()


## 移除已 queue_free 的残留条目
static func _prune_invalid() -> void:
	var alive: Array = []
	for b in _placed:
		if is_instance_valid(b) and not (b as Node).is_queued_for_deletion():
			alive.append(b)
	_placed = alive


# ============================================
# 制作站：工作台 / 熔炉
# ============================================

## 是否已经放置了提供该制作站的建筑
## station 为空 = 徒手可合成，恒为 true
static func has_station(station_id: StringName) -> bool:
	if station_id == &"" or station_id == null:
		return true
	_prune_invalid()
	for b in _placed:
		var bid := StringName(b.get("building_id"))
		if StringName(get_def(bid).get("station", &"")) == station_id:
			return true
	return false


## 已放置的全部制作站 id（给 UI 显示用）
static func get_unlocked_stations() -> Array[StringName]:
	_prune_invalid()
	var out: Array[StringName] = []
	for b in _placed:
		var bid := StringName(b.get("building_id"))
		var st := StringName(get_def(bid).get("station", &""))
		if st != &"" and not out.has(st):
			out.append(st)
	return out


# ============================================
# 热源：熔炉
# ============================================

## 返回覆盖该世界坐标的热源建筑；没有则 null
static func get_heater_at(world_pos: Vector3) -> Node:
	_prune_invalid()
	var best: Node = null
	var best_dist := 1e9
	for b in _placed:
		var bid := StringName(b.get("building_id"))
		var radius := float(get_def(bid).get("heat_radius", 0.0))
		if radius <= 0.0:
			continue
		var d := _horizontal_distance(b.global_position, world_pos)
		if d <= radius and d < best_dist:
			best_dist = d
			best = b as Node
	return best


# ============================================
# 就近查找（交互 / 拆除）
# ============================================

## 找离该点最近、且在 radius 内的建筑（不限类型）
static func find_nearest(world_pos: Vector3, radius: float) -> Node:
	_prune_invalid()
	var best: Node = null
	var best_dist := radius
	for b in _placed:
		var d := _horizontal_distance(b.global_position, world_pos)
		if d <= best_dist:
			best_dist = d
			best = b as Node
	return best


## 水平距离（忽略 y）：世界是平面无海拔，建筑落位判定只看 x/z
static func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)
