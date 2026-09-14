# ============================================================
# 地图生成基准测试（不依赖场景，headless --script 运行）
#
# 用途：调整地图尺度参数后验证
#   1. 生成耗时是否可接受（加载卡顿）
#   2. 岛屿实际世界尺寸（判断"够不够大"）
#   3. 陆地占比、瓦片总数
#
# 运行：
#   godot --headless --path . --script res://test/map_bench.gd
# ============================================================
extends SceneTree


func _init() -> void:
	var gen = load("res://script/map/map_generator.gd").new()
	gen.task_system = load("res://script/map/task_system.gd").new()
	gen.layout = load("res://script/map/layout.gd").new()
	gen.chain_gen = load("res://script/map/room_chain.gd").new()
	gen.rng.randomize()

	# 微基准：单个房间的 blob 生成耗时（房间生成是瓶颈时用它定位量级）
	for r in [14, 23, 36]:
		var tb: int = Time.get_ticks_msec()
		var tt: Array = gen.chain_gen.generate_blob_tiles_at(400.0, 400.0, r, gen.rng, 0.65, 0.9, 5)
		print("  单房间 半径%2d : %5d ms, %6d 瓦片" % [r, Time.get_ticks_msec() - tb, tt.size()])

	# 只跑数据层（跳过 render_map，2D 渲染与 3D 无关且极慢）
	# 分段计时，便于定位大地图下的性能瓶颈
	var t0: int = Time.get_ticks_msec()
	gen.init_map_data()
	var t1: int = Time.get_ticks_msec()
	gen.task_positions = {}
	gen.room_chains = {}
	gen.layout_tasks()
	var t2: int = Time.get_ticks_msec()
	gen.generate_room_chains()
	var t3: int = Time.get_ticks_msec()
	gen.stamp_room_terrain()
	var t4: int = Time.get_ticks_msec()
	gen.create_task_link_roads()
	var t5: int = Time.get_ticks_msec()
	gen.build_island_base()
	var t6: int = Time.get_ticks_msec()
	var cost: int = t6 - t0

	print("---- 分段耗时 ----")
	print("  init_map_data         : %d ms" % (t1 - t0))
	print("  layout_tasks          : %d ms" % (t2 - t1))
	print("  generate_room_chains  : %d ms" % (t3 - t2))
	print("  stamp_room_terrain    : %d ms" % (t4 - t3))
	print("  create_task_link_roads: %d ms" % (t5 - t4))
	print("  build_island_base     : %d ms" % (t6 - t5))

	var TS: int = gen.TILE_SIZE
	var MW: int = gen.MAP_WIDTH
	var MH: int = gen.MAP_HEIGHT

	# 统计陆地
	var land: int = 0
	var min_x: int = MW
	var max_x: int = 0
	var min_y: int = MH
	var max_y: int = 0
	for y in range(MH):
		for x in range(MW):
			if gen.task_system.is_terrain_walkable(gen.map_data[y * MW + x]):
				land += 1
				if x < min_x: min_x = x
				if x > max_x: max_x = x
				if y < min_y: min_y = y
				if y > max_y: max_y = y

	var total: int = MW * MH
	var world_size: float = MW * TS
	var island_w: float = (max_x - min_x + 1) * TS
	var island_h: float = (max_y - min_y + 1) * TS

	print("=========== 地图基准 ===========")
	print("瓦片数        : %d × %d = %d" % [MW, MH, total])
	print("瓦片尺寸      : %d 世界单位" % TS)
	print("世界尺寸      : %.0f × %.0f 世界单位" % [world_size, world_size])
	print("生成耗时      : %d ms" % cost)
	print("陆地瓦片      : %d (%.1f%%)" % [land, land * 100.0 / total])
	print("陆地面积      : %.0f 平方世界单位" % (land * TS * TS))
	print("岛屿包围盒    : %.0f × %.0f 世界单位" % [island_w, island_h])
	print("岛屿直径(估)  : %.0f 世界单位" % ((island_w + island_h) / 2.0))
	print("横穿耗时(估)  : %.0f 秒（按玩家速度 5）" % (((island_w + island_h) / 2.0) / 5.0))

	# 各区域世界坐标（用于核对分布是否撑开）
	print("---- 各区域入口世界坐标 ----")
	for task_id in gen.room_chains:
		var chain: Array = gen.room_chains[task_id]
		if chain.is_empty():
			continue
		var c = chain[0].center
		var wx: float = (c.x - MW / 2.0) * TS
		var wz: float = (c.y - MH / 2.0) * TS
		print("  %-12s (%7.0f, %7.0f)" % [task_id, wx, wz])

	quit()
