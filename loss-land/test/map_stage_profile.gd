# ============================================================
# 生成流水线分阶段耗时剖析（headless --script 运行）
#
# 用途：定位"数据生成"这一步内部的热点。
# generate_map 是 8 步流水线，整体计时无法看出是哪一步慢，
# 本脚本对每一步单独计时，用于回归时快速定位性能退化点。
#
# 运行：
#   godot --headless --path . --script res://test/map_stage_profile.gd
# ============================================================
extends SceneTree


func _init() -> void:
	var gen = load("res://script/map/map_generator.gd").new()
	gen.task_system = load("res://script/map/task_system.gd").new()
	gen.layout = load("res://script/map/layout.gd").new()
	gen.chain_gen = load("res://script/map/room_chain.gd").new()
	gen.rng.randomize()

	var marks: Array = []
	var t: int = Time.get_ticks_msec()

	gen.init_map_data()
	marks.append(["init_map_data", Time.get_ticks_msec() - t])

	t = Time.get_ticks_msec()
	gen.layout_tasks()
	marks.append(["layout_tasks", Time.get_ticks_msec() - t])

	t = Time.get_ticks_msec()
	gen.generate_room_chains()
	marks.append(["generate_room_chains", Time.get_ticks_msec() - t])

	t = Time.get_ticks_msec()
	gen.stamp_room_terrain()
	marks.append(["stamp_room_terrain", Time.get_ticks_msec() - t])

	t = Time.get_ticks_msec()
	gen.fill_region_territories()
	marks.append(["fill_region_territories", Time.get_ticks_msec() - t])

	t = Time.get_ticks_msec()
	gen.create_task_link_roads()
	marks.append(["create_task_link_roads", Time.get_ticks_msec() - t])

	t = Time.get_ticks_msec()
	gen.build_island_base()
	marks.append(["build_island_base", Time.get_ticks_msec() - t])

	var total: int = 0
	for m in marks:
		total += m[1]

	print("=========== 流水线分阶段耗时 ===========")
	print("阶段                        ms      占比")
	for m in marks:
		var pct: float = float(m[1]) / float(max(total, 1)) * 100.0
		print("  %-24s %-7d %.1f%%" % [m[0], m[1], pct])
	print("  %-24s %-7d" % ["合计", total])

	quit()
