class_name MapRenderer3D
extends Node
## 3D 地图渲染器。
## ------------------------------------------------------------
## 把 200×200 地图数据渲染到 y=0 平面上：
## - 海面：大 PlaneMesh，位于 y=-0.01，海洋色
## - 陆地：6 个 MultiMeshInstance3D（每地形一个），
##   用 1×1×block_height 的方块，顶面恰好对齐 y=0
## ------------------------------------------------------------

## 每格方块高度（y 方向厚度）。值越小越像贴在 y=0 的地形瓦片。
@export var block_height: float = 0.15

## 是否显示海面大平面
@export var show_sea_plane: bool = true

## 海面 y 位置（略低于 0，避免 z-fighting）
@export var sea_y: float = -0.01

@export var palette: TerrainPalette = preload("res://map_gen/default_palette.tres")

# 每地形一个 MultiMeshInstance3D
var _terrain_meshes: Array = []
# 海面 MeshInstance3D
var _sea: MeshInstance3D


func setup() -> void:
	_clear_children()

	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H

	# —— 海面 ——
	# Godot PlaneMesh 默认 FACE_Y：水平躺在 x-z 平面上，法线向上 +Y
	# 这正是我们需要的“地板”朝向。
	if show_sea_plane:
		_sea = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(W, H)   # 覆盖整个 200×200 地图区域
		_sea.mesh = pm
		# MeshInstance3D 默认 position=(0,0,0)，
		# PlaneMesh 以自身中心为 pivot，所以把它平移到 (W/2, sea_y, H/2)
		# 使得平面覆盖 x∈[0,W], z∈[0,H]，高度 y=sea_y（略低于 0）
		_sea.position = Vector3(W * 0.5, sea_y, H * 0.5)
		var sm := StandardMaterial3D.new()
		sm.albedo_color = palette.ocean_color
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		_sea.material_override = sm
		add_child(_sea)

	# —— 方块共享网格：1 × block_height × 1 ——
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(1.0, block_height, 1.0)

	_terrain_meshes.clear()
	_terrain_meshes.resize(TerrainDefs.T_COUNT)
	for t in range(TerrainDefs.T_COUNT):
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.mesh = cube_mesh
		mm.transform_format = MultiMesh.TRANSFORM_3D
		# instance_count 稍后在 apply() 里按实际数量设置
		mm.instance_count = 0
		mmi.multimesh = mm
		var smt := StandardMaterial3D.new()
		smt.albedo_color = palette.terrain_colors[t]
		smt.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		mmi.material_override = smt
		add_child(mmi)
		_terrain_meshes[t] = mmi


func apply(data: MapData) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var T: int = TerrainDefs.T_COUNT
	var cube_center_y: float = -block_height * 0.5   # 顶面恰好在 y=0

	# —— 第一遍：统计每地形的陆地格数 ——
	var counts: PackedInt32Array = PackedInt32Array()
	counts.resize(T)
	counts.fill(0)
	for i in range(W * H):
		if data.island[i] == 1:
			var t: int = data.grid[i]
			if t >= 0 and t < T:
				counts[t] += 1

	# 每地形分配 instance_count
	for t in range(T):
		var mmi: MultiMeshInstance3D = _terrain_meshes[t]
		mmi.multimesh.instance_count = counts[t]

	# —— 第二遍：逐个写入 transform ——
	var cursors: PackedInt32Array = PackedInt32Array()
	cursors.resize(T)
	cursors.fill(0)
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if data.island[i] == 0:
				continue
			var t: int = data.grid[i]
			if t < 0 or t >= T:
				continue
			var k: int = cursors[t]
			var xf: Transform3D = Transform3D.IDENTITY
			# 1×1 方块中心位于格中心 (x+0.5, cube_center_y, y+0.5)
			xf.origin = Vector3(float(x) + 0.5, cube_center_y, float(y) + 0.5)
			var mmi: MultiMeshInstance3D = _terrain_meshes[t]
			mmi.multimesh.set_instance_transform(k, xf)
			cursors[t] += 1

	# 同步海面颜色
	if show_sea_plane and _sea != null:
		var sm: StandardMaterial3D = _sea.material_override as StandardMaterial3D
		if sm != null:
			sm.albedo_color = palette.ocean_color


func _clear_children() -> void:
	for c in get_children(true):
		c.queue_free()
	_terrain_meshes.clear()
	_sea = null
