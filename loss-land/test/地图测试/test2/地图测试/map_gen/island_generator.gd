class_name IslandGenerator
extends Node
## 生成不规则椭圆岛屿掩膜（写入 data.island）。
## 形状参数来自 IslandShape 资源，可在检视面板调整或切换预设。

@export var shape: IslandShape = preload("res://map_gen/default_shape.tres")

var _phaseA: float = 0.0
var _phaseB: float = 0.0
var _phaseC: float = 0.0


func generate(data: MapData, rng: RandomNumberGenerator) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var CX: int = TerrainDefs.CX
	var CY: int = TerrainDefs.CY

	_phaseA = rng.randf() * TAU
	_phaseB = rng.randf() * TAU
	_phaseC = rng.randf() * TAU
	var sy: float = 1.0 + (rng.randf() - 0.5) * shape.ellipse_jitter
	# 注：缓冲由 MapData.init() 预先分配，这里只负责写入掩膜值
	for y in range(H):
		for x in range(W):
			var dx: float = float(x - CX)
			var dy: float = float(y - CY) / sy
			var ang: float = atan2(dy, dx)
			# 基础半径 + 多频率正弦扰动 → 不规则海岸线
			var r: float = shape.base_radius
			r += shape.amp1 * sin(ang * shape.freq1 + _phaseA)
			r += shape.amp2 * sin(ang * shape.freq2 + _phaseB)
			r += shape.amp3 * sin(ang * shape.freq3 + _phaseC)
			data.island[y * W + x] = 1 if (dx * dx + dy * dy) <= r * r else 0
