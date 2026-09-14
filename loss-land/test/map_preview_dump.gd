extends SceneTree

# 临时脚本：把程序化生成的地图导出为俯视 PNG，用于人工检查地形分布

func _init():
	var gen3 = load("res://script/map/map_generator_3d.gd").new()
	gen3._gen = load("res://script/map/map_generator.gd").new()
	gen3._gen.task_system = load("res://script/map/task_system.gd").new()
	gen3._gen.layout = load("res://script/map/layout.gd").new()
	gen3._gen.chain_gen = load("res://script/map/room_chain.gd").new()
	gen3._gen.rng.randomize()
	gen3._run_generation()

	var MW: int = gen3._gen.MAP_WIDTH
	var MH: int = gen3._gen.MAP_HEIGHT
	var img := Image.create(MW, MH, false, Image.FORMAT_RGB8)

	var land: int = 0
	for y in range(MH):
		for x in range(MW):
			var t: int = gen3._gen.map_data[y * MW + x]
			var c: Color = gen3._gen.task_system.get_terrain_color(t)
			img.set_pixel(x, y, c)
			if gen3._gen.task_system.is_terrain_walkable(t):
				land += 1

	print("地图 ", MW, "x", MH, " 陆地瓦片 ", land, " (", snapped(land * 100.0 / (MW * MH), 0.01), "%)")
	for tid in gen3._gen.room_chains:
		var chain: Array = gen3._gen.room_chains[tid]
		if chain.is_empty():
			continue
		var r = chain[0]
		print("区域 ", tid, " 入口(瓦片) ", r.center, " 半径 ", r.radius)

	# 缩略输出：1600×1600 原图不便人工查看，降采样到 900×900
	img.resize(900, 900, Image.INTERPOLATE_LANCZOS)
	var path := "E:/GameMake/loss/loss-land/map_preview.png"
	var err := img.save_png(path)
	print("预览图已保存: ", path, " err=", err)
	quit()
