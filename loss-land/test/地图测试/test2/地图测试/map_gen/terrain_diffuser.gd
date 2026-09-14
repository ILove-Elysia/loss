class_name TerrainDiffuser
extends Node
## 多源 BFS 地形扩散器。
## ------------------------------------------------------------
## 6 个生成点同时入队，FIFO 公平扩展；遇到已归属格子该方向停止。
## 每个陆地块最终归属“最近的生成点”，形成 Voronoi 式分布。
## 8 邻接使区域更圆润自然。
##
## 草原面积上限规则：
##   草原区扩散到占岛屿总面积的 grass_ratio（默认 1/7）后停止扩展，
##   剩余区域由其他 5 种地形继续扩散填充。
##   这样草原不会过度扩张，保证其他地形有足够空间。
##
## 输入：data.island（岛屿掩膜）、data.points（6 个生成点）
## 输出：data.grid（每格地形 id，255=未填充/海洋）
##       data.dist（每格到自身生成点的 BFS 步数）
##       data.max_dist（最大扩散步数，用作动画总进度）

## 草原区面积上限比例（占岛屿陆地总面积）。
## 默认 1/7 ≈ 0.1429；设为 1.0 则不限制草原扩张。
## 可在检视面板直接调整。
@export var grass_ratio: float = 1.0 / 7.0

# 8 邻接方向（成对 x,y）：右/左/下/上 + 四个对角
# 对角步进会使区域更圆润，避免十字形扩散痕迹
const _DIRS: Array[int] = [
	1, 0,  -1, 0,  0, 1,  0, -1,
	1, 1,  1, -1,  -1, 1,  -1, -1,
]


# ------------------------------------------------------------
# 执行扩散。原地修改 data.grid / data.dist / data.max_dist。
# ------------------------------------------------------------
func diffuse(data: MapData) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var T_COUNT: int = TerrainDefs.T_COUNT
	var T_GRASS: int = TerrainDefs.T_GRASS

	# 复位：所有格未填充
	# 注意：grid / dist 已在 MapData 构造或上层 resize 过；这里只填充默认值
	data.grid.fill(255)
	data.dist.fill(-1)

	# —— 统计岛屿陆地总面积，计算草原面积上限 ——
	# grass_cap = land_count × grass_ratio（向下取整）
	# 草原占据格数达到该值后即停止扩展
	var land_count: int = 0
	for i in range(W * H):
		if data.island[i] == 1:
			land_count += 1
	var grass_cap: int = int(float(land_count) * grass_ratio)
	# 草原当前已占据格数（含源点本身）
	var grass_count: int = 0

	# BFS 队列：紧凑存放 (x, y, terrain_id, dist) 四元组
	# 用 PackedInt32Array 而非 Array，避免装箱开销，提升 200×200 规模下的性能
	var q: PackedInt32Array = PackedInt32Array()

	# —— 初始化源点 ——
	# 每个生成点若落在陆地上，则归为该地形、步数=0，并入队
	for t in range(T_COUNT):
		var p: Vector2i = data.points[t]
		# 越界保护：极端情况下生成点可能落在地图外
		if p.x < 0 or p.y < 0 or p.x >= W or p.y >= H:
			continue
		var i: int = p.y * W + p.x
		if data.island[i] == 0:   # 源点落海则跳过（理论上不会发生）
			continue
		data.grid[i] = t
		data.dist[i] = 0
		# 草原源点计入面积（源点格也算草原占地）
		if t == T_GRASS:
			grass_count += 1
		q.append(p.x)
		q.append(p.y)
		q.append(t)
		q.append(0)

	data.max_dist = 0
	var head: int = 0   # 读指针（避免 pop_front 的 O(n) 开销）

	# —— 主循环：FIFO 公平扩展 ——
	# 每次从队首取一个格，向 8 邻接尝试扩展；
	# 只把“未归属的陆地格”收编为本地形，并按步数入队。
	while head < q.size():
		var x: int = q[head]; head += 1
		var y: int = q[head]; head += 1
		var t: int = q[head]; head += 1
		var d: int = q[head]; head += 1

		# 草原面积上限检查（优化层）：
		# 草原已达上限后，其格子不再向邻居扩展，直接跳过 8 方向遍历
		if t == T_GRASS and grass_count >= grass_cap:
			continue

		# 尝试 8 个方向
		for k in range(8):
			var nx: int = x + _DIRS[k * 2]
			var ny: int = y + _DIRS[k * 2 + 1]
			# 越界跳过
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var ni: int = ny * W + nx
			# 非陆地（海洋）跳过：地形只在岛上扩散
			if data.island[ni] == 0:
				continue
			# 已被其它源点占先归属：该方向停止（“相遇即停”）
			if data.grid[ni] != 255:
				continue
			# 草原收编前再次检查上限（精确截断）
			# 防止多个草原分支在同一轮并行收编导致面积超出上限
			if t == T_GRASS and grass_count >= grass_cap:
				continue
			# 收编为本地形，步数 +1
			data.grid[ni] = t
			data.dist[ni] = d + 1
			if t == T_GRASS:
				grass_count += 1
			if d + 1 > data.max_dist:
				data.max_dist = d + 1
			# 入队继续扩展
			q.append(nx)
			q.append(ny)
			q.append(t)
			q.append(d + 1)
