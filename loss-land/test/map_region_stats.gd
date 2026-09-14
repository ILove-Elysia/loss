# ============================================================
# 区域（生物群系）统计脚本（headless --script 运行）
#
# 用途：回答"地图上到底生成了哪些区域、各占多少格"。
# 统计维度：
#   1. 各任务配色 areas：房间数（成功放置 / 配置）与瓦片数
#   2. 全图 terrain_type 直方图（含海洋 7 / 沙滩 8 / 道路 0 / 未开发地表）
#   3. 每个区域的实际中心与半径（用于核对同心环布局是否符合预期）
#
# 运行：
#   godot --headless --path . --script res://test/map_region_stats.gd
# ============================================================
extends SceneTree


func _init() -> void:
	var gen = load("res://script/map/map_generator.gd").new()
	gen.task_system = load("res://script/map/task_system.gd").new()
	gen.layout = load("res://script/map/layout.gd").new()
	gen.chain_gen = load("res://script/map/room_chain.gd").new()
	gen.rng.randomize()

	# 只跑数据层（不渲染），与 generate_map 前 6 步等价
	gen.init_map_data()
	gen.layout_tasks()
	gen.generate_room_chains()
	gen.stamp_room_terrain()
	gen.fill_region_territories()
	gen.create_task_link_roads()
	gen.build_island_base()

	var MW: int = gen.MAP_WIDTH
	var MH: int = gen.MAP_HEIGHT

	# --- 1. 全图 terrain_type 直方图 ---
	var hist: Dictionary = {}
	for y in range(MH):
		var row: int = y * MW
		for x in range(MW):
			var t: int = gen.map_data[row + x]
			hist[t] = hist.get(t, 0) + 1

	var total: int = MW * MH

	print("=========== 全图地形直方图（MAP=%d x %d）===========" % [MW, MH])
	print("terrain  名称              格子数      占比")
	var names: Dictionary = {
		0: "道路/泥地", 7: "海洋", 8: "沙滩",
		10: "草原区", 11: "丛林区", 12: "矿区",
		13: "沙地区", 14: "火山区", 15: "雪地区",
	}
	var keys: Array = hist.keys()
	keys.sort()
	for k in keys:
		var pct: float = float(hist[k]) / float(total) * 100.0
		print("  %-4d   %-16s %-10d  %.2f%%" % [k, names.get(k, "未知"), hist[k], pct])

	# 陆地总量
	var land: int = 0
	for k in hist:
		if k != 7:
			land += hist[k]
	print("---------------------------------------------")
	print("陆地合计: %d（%.2f%%），海洋: %d" % [land, float(land) / float(total) * 100.0, total - land])

	# --- 2. 各任务的房间放置情况 ---
	print("")
	print("=========== 各区域房间与占地 ===========")
	print("区域          配置房间  成功放置  瓦片数     占陆地%")
	for task in gen.task_system.get_all_tasks():
		var tid: String = task.id
		var configured: int = task.get("rooms", []).size()
		var chain: Array = gen.room_chains.get(tid, [])
		var tiles: int = 0
		for room in chain:
			tiles += room.tiles.size()
		var land_pct: float = 0.0
		if land > 0:
			land_pct = float(tiles) / float(land) * 100.0
		print("%-12s  %-8d  %-8d  %-9d  %.2f%%" % [tid, configured, chain.size(), tiles, land_pct])

	# --- 3. 各区域中心到地图中心的半径（核对同心环）---
	print("")
	print("=========== 各区域布局位置（同心环核对）===========")
	var center: Vector2 = Vector2(MW / 2.0, MH / 2.0)
	print("区域          tier  danger  中心坐标            距中心半径")
	for task in gen.task_system.get_all_tasks():
		var tid: String = task.id
		if not gen.task_positions.has(tid):
			print("%-12s  —— 未布局 ——" % tid)
			continue
		var pos: Vector2 = gen.task_positions[tid]
		print("%-12s  %-4d  %-6d  (%6.0f,%6.0f)  %6.0f" % [
			tid,
			task.get("tier", -1),
			task.get("danger_level", -1),
			pos.x, pos.y,
			pos.distance_to(center),
		])

	# --- 3.5 地形交界自然度（边界格占比）---
	#
	# "边界格" = 4 邻域内存在异种地形的格子。
	# 若区界是刀切硬线，边界格只等于各区的周长（占比很低）；
	# 开启过渡带后两侧地形互相渗透，接触面大幅增加，
	# 边界格占比会明显上升 —— 这就是"交界是否自然"的量化指标。
	var area_count: Dictionary = {}
	var edge_count: Dictionary = {}
	for y in range(MH):
		var row: int = y * MW
		for x in range(MW):
			var t: int = gen.map_data[row + x]
			if t == 7:
				continue  # 海洋不计
			area_count[t] = area_count.get(t, 0) + 1
			var is_edge: bool = false
			if x > 0 and gen.map_data[row + x - 1] != t:
				is_edge = true
			elif x < MW - 1 and gen.map_data[row + x + 1] != t:
				is_edge = true
			elif y > 0 and gen.map_data[row - MW + x] != t:
				is_edge = true
			elif y < MH - 1 and gen.map_data[row + MW + x] != t:
				is_edge = true
			if is_edge:
				edge_count[t] = edge_count.get(t, 0) + 1

	print("")
	print("=========== 地形交界自然度 ===========")
	print("地形               面积       边界格     边界占比")
	for k in area_count:
		var a: int = area_count[k]
		var e: int = edge_count.get(k, 0)
		print("  %-4d %-12s %-10d %-10d %.1f%%" % [k, names.get(k, "未知"), a, e, float(e) / float(a) * 100.0])
	var sum_a: int = 0
	var sum_e: int = 0
	for k in area_count:
		sum_a += area_count[k]
		sum_e += edge_count.get(k, 0)
	print("  %-17s %-10d %-10d %.1f%%" % ["陆地合计", sum_a, sum_e, float(sum_e) / float(sum_a) * 100.0])
	print("（边界占比越高 = 交界越破碎自然；硬切硬线通常在 1-2%%）")

	# --- 4. 资源可用性矩阵 ---
	#
	# resource_spawner 现在是"全图随机撒点 → 校验"，
	# 而 _is_resource_allowed_in_biome 会否决不匹配群系的点，
	# 且尝试上限只有 count * 10 次。所以必须确认：
	# 每种资源在全图随机采样的命中率是否够高到能凑够数量。
	# 命中率过低 → 资源刷不出来，或挤在少数几个区。
	var ts = gen.task_system
	var tasks: Array = ts.get_all_tasks()
	var terrain_to_task: Dictionary = {}
	for tk in tasks:
		terrain_to_task[int(tk.get("terrain_type", -1))] = tk

	var res_ids: Array = ["grass", "tree", "stone"]
	var combos: Dictionary = {}
	for y in range(MH):
		var row: int = y * MW
		for x in range(MW):
			var tk = terrain_to_task.get(gen.map_data[row + x], null)
			if tk == null:
				continue  # 海洋 / 沙滩 / 道路：不放资源
			var region: String = str(tk.get("id", ""))
			for rid in res_ids:
				if ts.is_resource_allowed_in_region(region, rid):
					var key: String = rid + "|" + region
					combos[key] = combos.get(key, 0) + 1

	print("")
	print("=========== 资源 × 区域 可用格子 ===========")
	var head: String = "资源       "
	for tk in tasks:
		head += "%-11s" % tk.id
	print(head + "合计      占陆地%")
	for rid in res_ids:
		var line: String = "%-9s  " % rid
		var row_total: int = 0
		for tk in tasks:
			var c: int = combos.get(rid + "|" + str(tk.get("id", "")), 0)
			row_total += c
			line += "%-11d" % c
		var pct: float = 0.0
		if land > 0:
			pct = float(row_total) / float(land) * 100.0
		print(line + "%-10d %.1f%%" % [row_total, pct])
	print("（占陆地% = 全图随机撒点的命中率；经验上低于 10% 就要改成分区定向采样）")

	quit()
