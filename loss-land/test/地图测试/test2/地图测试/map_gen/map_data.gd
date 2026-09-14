class_name MapData
extends RefCounted
## 生成管线的共享数据容器，沿阶段传递：
##   岛屿掩膜(island) → 生成点(points) → 扩散结果(grid/dist/max_dist)。

var island: PackedByteArray        # 1=陆地, 0=海洋
var points: Array = []             # 6 个生成点（Vector2i），按地形 id 索引
var grid: PackedByteArray          # 每格地形 id（255=未填充）
var dist: PackedInt32Array         # 每格到自身生成点的 BFS 步数
var max_dist: int = 0              # 最大扩散步数（动画总进度）


# 一次性分配所有定长缓冲。在管线开始前调用一次。
func init() -> void:
	var n: int = TerrainDefs.W * TerrainDefs.H
	island.resize(n)
	grid.resize(n)
	dist.resize(n)
