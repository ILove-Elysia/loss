class_name BeachPostProcessor
extends Node
## 海岸沙滩后处理器。
## ------------------------------------------------------------
## 在地形扩散完成后运行：把岛屿边缘（与海洋相邻的陆地格）
## 改成沙滩地形（T_SAND），形成一圈海岸沙滩。
##
## 算法：多源 BFS 从所有海洋格出发，计算每个陆地格到最近
## 海洋格的步数；步数 ≤ beach_width 的陆地格标记为沙滩。
## 用 8 邻接使沙滩圈连续（填补对角缺口）。
##
## 输入/输出：原地修改 data.grid（边缘格 → T_SAND）

## 沙滩宽度（格）。1 = 仅紧贴海岸的一圈，2 = 两圈，以此类推。
@export var beach_width: int = 1

# 8 邻接方向（成对 x,y）
const _DIRS: Array[int] = [
	1, 0,  -1, 0,  0, 1,  0, -1,
	1, 1,  1, -1,  -1, 1,  -1, -1,
]


func apply(data: MapData) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var n: int = W * H

	# —— 阶段 1：多源 BFS 从所有海洋格出发，计算陆地格到最近海洋的距离 ——
	# dist_to_sea[i] = 该陆地格到最近海洋格的步数（海洋格自身 = 0）
	var dist_to_sea: PackedInt32Array = PackedInt32Array()
	dist_to_sea.resize(n)
	dist_to_sea.fill(-1)

	var q: PackedInt32Array = PackedInt32Array()
	# 所有海洋格入队，距离 = 0
	for i in range(n):
		if data.island[i] == 0:
			dist_to_sea[i] = 0
			q.append(i % W)   # x
			q.append(i / W)   # y

	var head: int = 0
	while head < q.size():
		var x: int = q[head]; head += 1
		var y: int = q[head]; head += 1
		var d: int = dist_to_sea[y * W + x]
		for k in range(8):
			var nx: int = x + _DIRS[k * 2]
			var ny: int = y + _DIRS[k * 2 + 1]
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var ni: int = ny * W + nx
			if dist_to_sea[ni] != -1:
				continue   # 已访问
			dist_to_sea[ni] = d + 1
			q.append(nx)
			q.append(ny)

	# —— 阶段 2：距离 ≤ beach_width 的陆地格改成沙滩 ——
	for i in range(n):
		if data.island[i] == 1 and dist_to_sea[i] >= 1 and dist_to_sea[i] <= beach_width:
			data.grid[i] = TerrainDefs.T_SAND
