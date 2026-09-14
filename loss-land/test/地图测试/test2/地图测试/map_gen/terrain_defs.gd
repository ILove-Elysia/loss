class_name TerrainDefs
extends RefCounted
## 地图与地形的共享常量（几何尺寸 + 地形 id 枚举）。
## 颜色、名称等“可调外观”放在 TerrainPalette 资源里，便于切换预设。

# ---- 地图几何 ----
const W: int = 200          # 地图逻辑宽
const H: int = 200          # 地图逻辑高
const CX: int = 100         # 中心 X（草原固定生成点）
const CY: int = 100         # 中心 Y
const DISP: int = 600       # 显示尺寸（3 倍放大，像素化）

# ---- 地形 id 枚举（同时用作颜色表索引）----
const T_GRASS: int = 0
const T_JUNGLE: int = 1
const T_MINING: int = 2
const T_SAND: int = 3
const T_SNOW: int = 4
const T_VOLC: int = 5
const T_COUNT: int = 6

# 一维索引：x,y → 数组下标
static func idx(x: int, y: int) -> int:
	return y * W + x
