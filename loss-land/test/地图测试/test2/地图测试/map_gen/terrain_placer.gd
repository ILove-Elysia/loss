class_name TerrainPlacer
extends Node
## 放置 6 个地形生成点（写入 data.points）。
## 约束：
##   · 草原：中心固定
##   · 雪地 / 火山：远离中心（不得与草原生成点相邻），大致分布于两侧
##   · 丛林 / 矿区 / 沙地：到草原距离 < 雪地距 或 < 火山距

@export_group("高危点放置")
@export var snow_min_radius: float = 55.0
@export var snow_max_radius: float = 75.0
@export var opposite_jitter: float = 1.2   # 雪地与火山大致相对的角度抖动


func place(data: MapData, rng: RandomNumberGenerator) -> void:
	var pts: Array = []
	pts.resize(TerrainDefs.T_COUNT)
	# 草原：中心固定
	pts[TerrainDefs.T_GRASS] = Vector2i(TerrainDefs.CX, TerrainDefs.CY)

	# 雪地与火山大致相对
	var snow_ang: float = rng.randf() * TAU
	var volc_ang: float = snow_ang + PI + (rng.randf() - 0.5) * opposite_jitter
	pts[TerrainDefs.T_SNOW] = _place_dir(data, snow_ang, snow_min_radius, snow_max_radius, rng)
	pts[TerrainDefs.T_VOLC] = _place_dir(data, volc_ang, snow_min_radius, snow_max_radius, rng)

	# 雪地 / 火山到草原的距离，用于约束中危点
	var snow_d: float = _dist_to_center(pts[TerrainDefs.T_SNOW])
	var volc_d: float = _dist_to_center(pts[TerrainDefs.T_VOLC])

	# 已占用的源点格（避免中危点与其它源点重叠）
	var occupied: Dictionary = {}
	occupied[Vector2i(TerrainDefs.CX, TerrainDefs.CY)] = true
	occupied[pts[TerrainDefs.T_SNOW]] = true
	occupied[pts[TerrainDefs.T_VOLC]] = true

	# 丛林 / 矿区 / 沙地：随机放置，约束为“到草原距离 < 雪地距 或 < 火山距”
	pts[TerrainDefs.T_JUNGLE] = _place_medium(data, snow_d, volc_d, occupied, rng)
	pts[TerrainDefs.T_MINING] = _place_medium(data, snow_d, volc_d, occupied, rng)
	pts[TerrainDefs.T_SAND] = _place_medium(data, snow_d, volc_d, occupied, rng)
	data.points = pts


# 点到草原中心（CX,CY）的欧氏距离
func _dist_to_center(p: Vector2i) -> float:
	var dx: float = float(p.x - TerrainDefs.CX)
	var dy: float = float(p.y - TerrainDefs.CY)
	return sqrt(dx * dx + dy * dy)


func _is_land(data: MapData, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= TerrainDefs.W or y >= TerrainDefs.H:
		return false
	return data.island[y * TerrainDefs.W + x] == 1


# 在指定方向、距中心 [min_r,max_r] 处寻找陆地点
func _place_dir(data: MapData, angle: float, min_r: float, max_r: float, rng: RandomNumberGenerator) -> Vector2i:
	var CX: int = TerrainDefs.CX
	var CY: int = TerrainDefs.CY
	for _i in range(80):
		var r: float = min_r + rng.randf() * (max_r - min_r)
		var x: int = int(round(CX + r * cos(angle)))
		var y: int = int(round(CY + r * sin(angle)))
		if _is_land(data, x, y):
			return Vector2i(x, y)
	# 兜底：向内逐步收缩
	var r: float = max_r
	while r >= 20.0:
		var x: int = int(round(CX + r * cos(angle)))
		var y: int = int(round(CY + r * sin(angle)))
		if _is_land(data, x, y):
			return Vector2i(x, y)
		r -= 3.0
	return Vector2i(CX, CY)


# 随机放置一个中危地形点：陆地 + 不与已占点重叠 + 到草原距离 < snow_d 或 < volc_d
func _place_medium(data: MapData, snow_d: float, volc_d: float, occupied: Dictionary, rng: RandomNumberGenerator) -> Vector2i:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	for _i in range(300):
		var x: int = rng.randi_range(0, W - 1)
		var y: int = rng.randi_range(0, H - 1)
		var p := Vector2i(x, y)
		if occupied.has(p) or not _is_land(data, x, y):
			continue
		var d: float = _dist_to_center(p)
		if not (d < snow_d or d < volc_d):
			continue
		occupied[p] = true
		return p
	# 兜底：在所有满足约束的陆地中取距中心最近的一格
	var best: Vector2i = Vector2i(TerrainDefs.CX, TerrainDefs.CY)
	var best_d: float = 1e18
	for y in range(H):
		for x in range(W):
			if not _is_land(data, x, y):
				continue
			var p := Vector2i(x, y)
			if occupied.has(p):
				continue
			var d: float = _dist_to_center(p)
			if (d < snow_d or d < volc_d) and d < best_d:
				best_d = d
				best = p
	occupied[best] = true
	return best
