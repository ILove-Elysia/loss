# ============================================================
# 3D 渲染 + 碰撞 基准（不依赖场景，headless --script 运行）
# 复用 map_generator_3d 的数据层与渲染/碰撞逻辑，单独计时：
#   _run_generation      → 数据层（已在 map_bench 测过，此处复核）
#   render_map_3d        → MultiMesh 渲染（2.56M 瓦片扫描 + 实例写入）
#   _build_floor_collisions → 逐行合并碰撞体（2.56M 瓦片扫描）
#
# 运行：
#   godot --headless --path . --script res://test/map_bench3d.gd
# ============================================================
extends SceneTree


func _init() -> void:
	var gen3d = load("res://script/map/map_generator_3d.gd").new()

	# 仅搭建渲染所需容器（不进树、不触发 _ready，避免重复生成）
	gen3d.tile_container = Node3D.new()
	gen3d.tile_container.name = "TileContainer3D"
	gen3d.add_child(gen3d.tile_container)
	gen3d.collision_container = Node3D.new()
	gen3d.collision_container.name = "FloorCollisionContainer"
	gen3d.add_child(gen3d.collision_container)

	gen3d._gen = load("res://script/map/map_generator.gd").new()
	gen3d._gen.task_system = load("res://script/map/task_system.gd").new()
	gen3d._gen.layout = load("res://script/map/layout.gd").new()
	gen3d._gen.chain_gen = load("res://script/map/room_chain.gd").new()
	gen3d._gen.rng.randomize()

	var t0: int = Time.get_ticks_msec()
	gen3d._run_generation()
	var t1: int = Time.get_ticks_msec()
	gen3d.render_map_3d()
	var t2: int = Time.get_ticks_msec()
	gen3d._build_floor_collisions()
	var t3: int = Time.get_ticks_msec()

	# 统计陆地瓦片（用于核对渲染实例数）
	var land: int = 0
	var MW: int = gen3d._gen.MAP_WIDTH
	var MH: int = gen3d._gen.MAP_HEIGHT
	for y in range(MH):
		for x in range(MW):
			if gen3d._gen.task_system.is_terrain_walkable(gen3d._gen.map_data[y * MW + x]):
				land += 1

	# 统计碰撞体节点数
	var col_nodes: int = 0
	for c in gen3d.collision_container.get_children():
		col_nodes += c.get_children().size()

	print("=========== 3D 基准（MAP=1600, TILE=1）===========")
	print("数据生成       : %d ms" % (t1 - t0))
	print("3D 渲染(Multi) : %d ms" % (t2 - t1))
	print("碰撞体构建     : %d ms" % (t3 - t2))
	print("合计(数据+3D)  : %d ms" % (t3 - t0))
	print("陆地瓦片       : %d" % land)
	print("碰撞体(Box)数  : %d" % col_nodes)

	quit()
