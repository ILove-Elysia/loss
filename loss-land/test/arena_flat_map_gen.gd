# test/arena_flat_map_gen.gd
# ============================================
# 测试场地用的"平坦地图"替身（挂 "map_gen" 组）
#
# 为什么需要它：玩家的 Physics / Vitals / BuildPlacer / ClickMover 都会
# `get_first_node_in_group("map_gen")` 去问地形（走上去烫不烫、这格能不能站）。
# 真地图生成器一次要 12~20 秒，测试场地不需要。
#
# 好消息是**它们本来就容错**：Vitals 在 map_gen 缺席时直接按草原（10）处理
# （vitals.gd 第 453~459 行）。所以这个替身只是把"草原"这件事**显式写出来**，
# 顺带保证 get_terrain_world() 有真实返回、不走 null 分支。
#
# 地形号对照（项目约定）：7 海 / 8 沙滩 / 10 草原 / 11 丛林 / 12 矿区 /
#                          13 沙地 / 14 火山 / 15 雪地
# ============================================

extends Node

## 整套地形都报这一号：10 = 草原（中性区，温度/湿度都不触发极端效果）
const TERRAIN := 10

## 沙虫测试场地是沙地战场，但**故意报草原**：
## 沙地（13）会牵动体温/湿度那一套，测 Boss 时不该混进这些变量。
## 想让场地真的按沙地算，把这个值改成 13。
const USE_SAND_TERRAIN := false


func _ready() -> void:
	# 玩家的地形查询按组找人，所以必须入组
	add_to_group("map_gen")


## 玩家相关系统唯一会调的地形接口
func get_terrain_world(_world_position: Vector3) -> int:
	if USE_SAND_TERRAIN:
		return 13
	return TERRAIN


## 平坦场地：怎么问都是陆地（死亡后复活判定、落水判定都会问这个）
func is_land_world(_world_position: Vector3) -> bool:
	return true


## 地图尺寸（有些系统会拿它做越界判断；给一个够大的方场）
func get_world_size() -> Vector2:
	return Vector2(80.0, 80.0)
