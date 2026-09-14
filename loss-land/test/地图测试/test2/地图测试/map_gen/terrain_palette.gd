class_name TerrainPalette
extends Resource
## 地形配色 + 名称 + 危险度（可保存为 .tres 预设，在检视面板切换）。
## 渲染器与图例共享同一实例。

@export var ocean_color: Color = Color(0.173, 0.427, 0.620)   # #2c6d9e 海洋蓝
@export var base_color: Color = Color(0.706, 0.659, 0.510)    # 岛屿底色（扩散未到达时）

@export var terrain_colors: Array[Color] = [
	Color(0.486, 0.702, 0.259),  # 草原 绿
	Color(0.180, 0.427, 0.196),  # 丛林 深绿
	Color(0.490, 0.353, 0.275),  # 矿区 棕褐
	Color(0.871, 0.749, 0.455),  # 沙地 沙黄
	Color(0.910, 0.941, 0.957),  # 雪地 近白
	Color(0.769, 0.196, 0.157),  # 火山 红
]
@export var terrain_names: Array[String] = [
	"草原区", "丛林区", "矿区", "沙地区", "雪地区", "火山区",
]
@export var terrain_danger: Array[String] = [
	"安全", "中危", "中危", "中危", "高危", "高危",
]
