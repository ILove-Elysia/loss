# script/debug/terrain_probe.gd
# ============================================
# 地形探针：实时输出玩家脚下踩的是什么地形
#
# 挂在 player 根节点下（与 Vitals / Inventory 同级），每 interval 秒采样一次
# 玩家真实世界坐标 → 查地图数据 → 打印「地形名 / 编号 / 所属群系 / 瓦片坐标」。
#
# 为什么是独立节点而不是塞进 vitals.gd：
#   vitals 只关心「是不是火山/雪地」两个分支，而排查地图（群系边界画歪、
#   出生点落在海里、走路掉进内海）需要瓦片坐标和区域 ID。两者关注点不同，
#   混在一起会让体温逻辑被调试代码淹没；独立节点还能直接整块删掉。
#
# 默认只在「地形或区域发生变化」时打印：站着不动不会刷屏，
# 走过群系边界时才会打一行——这正好是排查地图最需要的那一行。
# 想要心跳式输出（每 interval 秒必打一行）把 only_on_change 设成 false。
#
# 输出开关：设置 → 调试选项 →「地形（脚下地形 / 所属群系）」
# ============================================
extends Node

# ---------------- 可调参数 ----------------

## 采样间隔（秒）。0.25 = 一秒四次，足够跟上 5/s 的移速且不漏格。
@export var interval: float = 0.25

## true  = 只在地形/区域变化时打印（推荐，站着不动不刷屏）
## false = 每个 interval 都打印一行（心跳式，用于确认探针本身还活着）
@export var only_on_change: bool = true

# 地形编号 -> 中文名
# 与 task_system.gd 的 TERRAIN_COLOR_MAP 同源：
#   0 未开发地面 / 7 海洋 / 8 沙滩 / 10 草原 / 11 丛林 / 12 岩石 / 13 沙地 / 14 火山 / 15 雪地
const TERRAIN_NAMES: Dictionary = {
	0: "未开发地面",
	7: "海洋",
	8: "沙滩",
	10: "草原",
	11: "丛林",
	12: "岩石",
	13: "沙地",
	14: "火山",
	15: "雪地",
}

# ---------------- 内部状态 ----------------

var _timer: float = 0.0
var _map_gen: Node = null
var _physics: Node3D = null

# 上一次打印的内容，用于 only_on_change 去重
# _printed_once 保证开启后第一次一定打印（否则首次地形恰好也是 -1 就永远哑了）
var _last_terrain: int = -1
var _last_region: String = ""
var _printed_once: bool = false

# 地图还没生成时会连续报「找不到地图」，只报一次避免刷屏
var _warned_no_map: bool = false


func _process(delta: float) -> void:
	# 开关关闭时直接返回：连下面取节点、算坐标都不做，正式游玩零开销
	if not DebugConfig.is_enabled(DebugConfig.CAT_TERRAIN):
		# 关掉再打开时，让「上次打印值」失效，重新打开能立刻看到当前地形
		_last_terrain = -1
		_last_region = ""
		_printed_once = false
		return

	_timer += delta
	if _timer < interval:
		return
	_timer = 0.0

	_sample()


# ---------------- 采样与输出 ----------------

func _sample() -> void:
	var body := _get_physics()
	if body == null:
		return

	var gen := _get_map_gen()
	if gen == null or not is_instance_valid(gen):
		if not _warned_no_map:
			_warned_no_map = true
			DebugConfig.warn_msg(
				DebugConfig.CAT_TERRAIN, "TerrainProbe：找不到 map_gen 组的地图节点")
		return
	_warned_no_map = false

	var pos: Vector3 = body.global_position
	var terrain: int = int(gen.get_terrain_world(pos)) if gen.has_method("get_terrain_world") else -1
	var region: String = str(gen.get_region_id_world(pos)) if gen.has_method("get_region_id_world") else ""

	# 站在原地不动 + 只在变化时打印 → 什么都不做
	if only_on_change and _printed_once and terrain == _last_terrain and region == _last_region:
		return

	_last_terrain = terrain
	_last_region = region
	_printed_once = true

	var name_: String = str(TERRAIN_NAMES.get(terrain, "未知(%d)" % terrain))
	var tile: Vector2i = gen.world_to_tile(pos) if gen.has_method("world_to_tile") else Vector2i.ZERO

	DebugConfig.log_msg(
		DebugConfig.CAT_TERRAIN,
		"[地形] %s(%d) | 群系=%s | 瓦片=(%d, %d) | 世界=(%.1f, %.1f, %.1f)",
		[
			name_, terrain,
			("无" if region.is_empty() else region),
			tile.x, tile.y,
			pos.x, pos.y, pos.z,
		])


# ---------------- 节点查找 ----------------

## 真实移动的玩家碰撞体。
## 注意：player 根节点永远停在原点，只有 Physics 子节点在动（见项目约定）。
func _get_physics() -> Node3D:
	if _physics != null and is_instance_valid(_physics):
		return _physics
	var root := get_parent()
	if root == null:
		return null
	_physics = root.get_node_or_null("Physics") as Node3D
	return _physics


func _get_map_gen() -> Node:
	if _map_gen != null and is_instance_valid(_map_gen):
		return _map_gen
	if get_tree() == null:
		return null
	_map_gen = get_tree().get_first_node_in_group("map_gen")
	return _map_gen
