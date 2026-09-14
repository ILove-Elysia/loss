# ============================================================
# 小地图底图实测（headless --script，需跑一次完整地图生成）
#
# 冒烟测试只能验证面板开合，验证不了底图——那里没有真实地图数据。
# 这里用 map_bench3d 相同的方式手工搭出生成器并跑完流水线，
# 再真正调一次 build_minimap_image，确认：
#   1. 能产出 200×200 的图像
#   2. 采样结果不是纯色（说明取到了不同地形，配色链路是通的）
#
# 运行：
#   godot --headless --path . --script res://test/minimap_live_test.gd
# ============================================================
extends SceneTree


func _init() -> void:
	var gen3d = load("res://script/map/map_generator_3d.gd").new()

	# 不进树、不触发 _ready，避免重复生成
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

	gen3d._run_generation()

	var size := 200
	var t0: int = Time.get_ticks_msec()
	var img: Image = gen3d.build_minimap_image(size)
	var t1: int = Time.get_ticks_msec()

	print("=========== 小地图底图实测 ===========")
	if img == null:
		print("[失败] build_minimap_image 返回 null")
		quit()
		return

	print("尺寸           : %d x %d" % [img.get_width(), img.get_height()])
	print("生成耗时       : %d ms" % (t1 - t0))

	# 统计不同颜色的数量：只有 1 种说明采样或取色链路断了
	var colors := {}
	for y in range(0, size, 2):
		for x in range(0, size, 2):
			colors[img.get_pixel(x, y).to_html()] = true
	print("不同地形颜色数 : %d" % colors.size())

	var ok_size: bool = img.get_width() == size and img.get_height() == size
	var ok_colors: bool = colors.size() > 1
	print("尺寸正确       : %s" % ("通过" if ok_size else "失败"))
	print("配色链路通     : %s" % ("通过" if ok_colors else "失败（全图同色）"))
	print("=====================================")
	print("===== %s =====" % ("全部通过" if ok_size and ok_colors else "存在失败项"))

	quit()
