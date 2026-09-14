# ============================================================
# 2D 地图生成器（核心脚本）
#
# 整体架构：7 步流水线生成地图
#   1. init_map_data        → 初始化全海 (terrain=7) 地图
#   2. layout_tasks         → 节点布局（调用 layout.gd 两阶段布局）
#   3. generate_room_chains → 生成房间链（调用 room_chain.gd，防重叠放置）
#   4. stamp_room_terrain   → 把房间地形写入地图数据 + 房间间连通
#   5. create_task_link_roads → 按 TASK_LINKS 铺路 + 额外邻居路（无环）
#   6. build_island_base    → 岛屿底座：沙滩边缘 + 填充内海 + 边缘缓冲
#   7. render_map           → 把 map_data 渲染为 ColorRect 节点
#
# 数据结构：
#   map_data[y][x] = terrain_type (int)
#     0: 道路（泥地路，浅黄色）
#     7: 海洋（不可通行）
#     8: 沙滩（岛屿外圈）
#     10-15: 各地形类型（草原/丛林/矿区等）
#
# 与 map_generator_3d.gd 的关系：
#   本脚本负责 2D 数据层 + 2D 渲染，3D 版本复用相同生成逻辑，
#   但在 render_map 阶段生成 MeshInstance3D 而非 ColorRect。
# ============================================================
extends Node2D

# ------------------------------------------------------------
# 地图常量
# ------------------------------------------------------------

# 每个瓦片的像素尺寸（用于 2D 渲染时 ColorRect 的大小）
const TILE_SIZE = 32

# 地图宽高（瓦片数量）
# 400 × 400 = 160,000 瓦片
const MAP_WIDTH = 400
const MAP_HEIGHT = 400


# ------------------------------------------------------------
# 子系统引用（@onready 保证在 _ready 时加载）
# ------------------------------------------------------------

# 任务系统：定义所有任务、链接、地形颜色映射
@onready var task_system = load("res://scripts/task_system.gd").new()

# 布局系统：两阶段坐标生成（同心布局 + 力导向微调 + 归一化）
@onready var layout = load("res://scripts/layout.gd").new()

# 房间链生成器：生成不规则 blob 房间 + 房间链方向计算
@onready var chain_gen = load("res://scripts/room_chain.gd").new()


# ------------------------------------------------------------
# 运行时数据
# ------------------------------------------------------------

# 地图数据：二维数组 [y][x] = terrain_type
# 初始全为 7（海洋），生成过程中逐步填充陆地
var map_data: Array = []

# 2D 渲染容器：所有 ColorRect 瓦片作为其子节点
var tile_container: Node2D = null

# 随机数生成器：使用 PCG 算法，支持 seed 复现
# 调用 rng.randomize() 每次运行产生不同地图
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# 各任务的中心瓦片坐标 { task_id: Vector2(tile_x, tile_y) }
# 由 layout_tasks() 填充
var task_positions: Dictionary = {}

# 各任务的房间链 { task_id: [room1, room2, ...] }
# 每个 room 包含 center, radius, tiles 数组
# 由 generate_room_chains() 填充
var room_chains: Dictionary = {}


# ============================================================
# 节点就绪时调用：随机化种子 + 生成地图
# ============================================================
func _ready():
	rng.randomize()
	generate_map()


# ============================================================
# 地图生成主入口：7 步流水线
#
# 每步职责：
#   init_map_data:          全海洋背景
#   layout_tasks:           计算各任务中心坐标（防出界）
#   generate_room_chains:    为每个任务生成不规则房间链（防重叠）
#   stamp_room_terrain:     把房间地形写入 map_data + 打通房间
#   create_task_link_roads: 按链接铺路 + 补邻居路（BFS 防环）
#   build_island_base:      沙滩边缘 + 填充内海 + 边缘截断
#   render_map:             渲染为 ColorRect + 绘制标签
# ============================================================
func generate_map():
	init_map_data()
	task_positions = {}
	room_chains = {}

	layout_tasks()
	generate_room_chains()
	stamp_room_terrain()
	create_task_link_roads()
	build_island_base()
	render_map()


# ============================================================
# 步骤 1：初始化地图数据
# 创建 MAP_HEIGHT × MAP_WIDTH 的二维数组，全部填充 terrain=7（海洋）
# 后续步骤会把对应位置改为陆地/沙滩/道路
# ============================================================
func init_map_data():
	map_data = []
	for y in range(MAP_HEIGHT):
		var row = []
		for x in range(MAP_WIDTH):
			row.append(7)
		map_data.append(row)


# ============================================================
# 步骤 2：计算各任务中心坐标
#
# 流程：
#   1. 从 task_system 获取所有任务和链接
#   2. 调用 layout.layout_tasks() 做两阶段布局（相对坐标）
#   3. 调用 normalize_to_tile_coords() 转换为绝对瓦片坐标
#   4. clamp 到安全区 [30, MAP_WIDTH-30] 防止出界
#
# 参数说明：
#   target_rx=60, target_ry=55: 目标椭圆半径（瓦片单位）
#   中圈节点分布在 ~27 瓦片半径，外圈 ~60 瓦片半径
# ============================================================
func layout_tasks():
	var tasks = task_system.get_all_tasks()
	var links = task_system.get_all_links()

	# 第一阶段：力导向布局（相对坐标）
	var result = layout.layout_tasks(tasks, links, rng)
	var nodes = result[0]

	# 第二阶段：归一化到绝对瓦片坐标
	var center = Vector2(MAP_WIDTH / 2, MAP_HEIGHT / 2)
	var target_rx = 60.0
	var target_ry = 55.0
	task_positions = layout.normalize_to_tile_coords(nodes, center, target_rx, target_ry, rng)

	# 防出界：把所有任务位置限制在 [30, MAP_SIZE-30] 范围内
	var MIN_EDGE_DIST = 30.0
	for task_id in task_positions:
		var pos = task_positions[task_id]
		var clamped_x = clamp(pos.x, MIN_EDGE_DIST, MAP_WIDTH - MIN_EDGE_DIST)
		var clamped_y = clamp(pos.y, MIN_EDGE_DIST, MAP_HEIGHT - MIN_EDGE_DIST)
		task_positions[task_id] = Vector2(clamped_x, clamped_y)


# ============================================================
# 步骤 3：为每个任务生成房间链
#
# 流程：
#   1. 构建 tier_lookup 字典（task_id → tier）
#   2. 对每个任务：
#      a. 计算链接方向（指向相邻任务）
#      b. 生成房间链（entrance → middle → ... → exit）
#      c. 逐个房间尝试放置（防重叠，必要时缩小）
#   3. 把成功放置的房间存入 room_chains
#
# 防重叠策略：
#   _place_room_no_overlap 检查：
#     - 完全重叠（_count_overlap）：与其他任务房间不重叠
#     - 邻接冲突（_count_adjacent_conflict）：内圈不与外圈相邻
#     - 若冲突则逐步缩小半径（每次 -2），最小 8
# ============================================================
func generate_room_chains():
	# occupied 字典：{ "x,y": task_id } 记录已占用的瓦片
	var occupied = {}

	# 预构建 tier 查找表
	var tier_lookup = {}
	for task in task_system.get_all_tasks():
		tier_lookup[task.id] = task.get("tier", 1)

	for task in task_system.get_all_tasks():
		var task_id = task.id
		if not task_positions.has(task_id):
			continue

		var task_center = task_positions[task_id]
		var task_tier = tier_lookup.get(task_id, 1)

		# 计算房间链延伸方向（指向连接的任务）
		var direction = chain_gen.compute_chain_direction(
			task_id, task_system.get_all_links(), task_positions)

		# 生成房间链：entrance → middle rooms → exit
		var chain = chain_gen.generate_chain_for_task(
			task, task_center, direction, rng)

		# 逐个尝试放置房间（防重叠，必要时缩小）
		var valid_chain = []
		for room in chain:
			var placed = _place_room_no_overlap(room, occupied, task_id, task_tier, tier_lookup)
			if placed:
				valid_chain.append(room)

		room_chains[task_id] = valid_chain


# ============================================================
# 房间放置：防重叠 + 自动缩小
#
# 策略：
#   1. 尝试原尺寸放置，检查重叠和邻接冲突
#   2. 若有冲突，逐步缩小半径（每次 -2，最小 8）
#   3. 找到不冲突的尺寸则标记占用
#   4. 所有尺寸都冲突则放弃该房间
#
# 参数：
#   room:        待放置的房间（包含 center, radius, tiles）
#   occupied:   已占用瓦片字典
#   task_id:     当前任务 ID（用于区分自身瓦片）
#   task_tier:   当前任务层级（用于邻接冲突检测）
#   tier_lookup: 任务→层级查找表
#
# 返回：bool — 是否成功放置
# ============================================================
func _place_room_no_overlap(room, occupied, task_id: String, task_tier: int, tier_lookup: Dictionary) -> bool:
	var overlap = _count_overlap(room.tiles, occupied, task_id)
	var adjacent = _count_adjacent_conflict(room.tiles, occupied, task_id, task_tier, tier_lookup)
	if overlap == 0 and adjacent == 0:
		_mark_occupied(room.tiles, occupied, task_id)
		return true

	# 逐步缩小半径尝试
	var cur_radius = room.radius - 2
	while cur_radius >= 8:
		var new_tiles = chain_gen.generate_blob_tiles_at(
			room.center.x, room.center.y, cur_radius, rng, 0.4, 0.5, 2)
		var shrink_overlap = _count_overlap(new_tiles, occupied, task_id)
		var shrink_adjacent = _count_adjacent_conflict(new_tiles, occupied, task_id, task_tier, tier_lookup)
		if shrink_overlap == 0 and shrink_adjacent == 0:
			room.tiles = new_tiles
			room.radius = cur_radius
			_mark_occupied(new_tiles, occupied, task_id)
			return true
		cur_radius -= 2

	return false


# ============================================================
# 统计与其他任务房间重叠的瓦片数
# 自身任务的瓦片不算冲突
# 参数：tiles=房间瓦片, occupied=已占用字典, current_task_id=当前任务ID
# 返回：冲突瓦片数量
# ============================================================
func _count_overlap(tiles: Array, occupied: Dictionary, current_task_id: String) -> int:
	var count = 0
	for tile in tiles:
		var key = str(int(tile.x)) + "," + str(int(tile.y))
		if occupied.has(key) and occupied[key] != current_task_id:
			count += 1
	return count


# ============================================================
# 统计邻接冲突瓦片数
# 仅检测 Tier 0（内圈）与 Tier 2（外圈）的直接邻接
# 中间层（Tier 1）可以与任意层相邻
#
# 为什么？
#   内圈安全区不应与外圈高危区直接相邻（游戏逻辑），
#   需要通过中圈或沙滩过渡。
#
# 检测方式：对每个房间瓦片检查 8 邻域（3×3 环绕），
#   若邻居属于不同层级（0↔2），计为冲突
# ============================================================
func _count_adjacent_conflict(tiles: Array, occupied: Dictionary, current_task_id: String, current_tier: int, tier_lookup: Dictionary) -> int:
	if current_tier != 0 and current_tier != 2:
		return 0

	var count = 0
	# 8 邻域偏移（3×3 环绕）
	var offsets = [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1,  0),                 Vector2i(1,  0),
		Vector2i(-1,  1), Vector2i(0,  1), Vector2i(1,  1),
	]

	for tile in tiles:
		for off in offsets:
			var key = str(int(tile.x) + off.x) + "," + str(int(tile.y) + off.y)
			if occupied.has(key):
				var other_task_id = occupied[key]
				if other_task_id == current_task_id:
					continue
				var other_tier = tier_lookup.get(other_task_id, 1)
				# 仅内圈↔外圈视为冲突
				if (current_tier == 0 and other_tier == 2) or (current_tier == 2 and other_tier == 0):
					count += 1
	return count


# ============================================================
# 标记瓦片为已占用
# 把房间所有瓦片写入 occupied 字典，值为 task_id
# ============================================================
func _mark_occupied(tiles: Array, occupied: Dictionary, task_id: String):
	for tile in tiles:
		var key = str(int(tile.x)) + "," + str(int(tile.y))
		occupied[key] = task_id


# ============================================================
# 步骤 4：把房间地形写入地图数据 + 打通房间
#
# 对每个任务：
#   1. 把所有房间的 tiles 写入 map_data（设置 terrain_type）
#   2. 连接相邻房间（_connect_rooms），用粗 Bresenham 线填充
#      使房间链中的房间像素级连通，无断裂
# ============================================================
func stamp_room_terrain():
	for task_id in room_chains:
		var chain = room_chains[task_id]
		var task = task_system.get_task_by_id(task_id)
		var terrain_type = task.get("terrain_type", 2)

		# 写入房间地形
		for room in chain:
			for tile in room.tiles:
				var tx = tile.x
				var ty = tile.y
				if tx >= 0 and tx < MAP_WIDTH and ty >= 0 and ty < MAP_HEIGHT:
					map_data[ty][tx] = terrain_type

		# 连接房间链中相邻的房间
		for i in range(chain.size() - 1):
			var r1 = chain[i]
			var r2 = chain[i + 1]
			_connect_rooms(r1, r2, terrain_type)


# ============================================================
# 连接两个房间：粗 Bresenham 线
# 线宽 = max(4, min(r1.radius, r2.radius) / 2)
# 保证连接路径足够宽，不会断裂
# ============================================================
func _connect_rooms(r1, r2, terrain_type: int):
	var x1 = int(r1.center.x)
	var y1 = int(r1.center.y)
	var x2 = int(r2.center.x)
	var y2 = int(r2.center.y)
	var connect_radius = max(4, min(r1.radius, r2.radius) / 2)

	_bresenham_line_thick(x1, y1, x2, y2, terrain_type, connect_radius)


# ============================================================
# 粗 Bresenham 线算法
# 在标准 Bresenham 线基础上增加厚度：沿线周围画圆形区域
#
# 算法：
#   1. 标准 Bresenham 线从 (x0,y0) 到 (x1,y1)
#   2. 每个点周围画 thickness 半径的圆（dx²+dy² ≤ r²）
#   3. 圆内所有瓦片设为 terrain_type
#
# 用途：房间间连接（较粗），保证通道不断裂
# 对比：_bresenham_line 用于道路（1 像素宽）
# ============================================================
func _bresenham_line_thick(x0: int, y0: int, x1: int, y1: int, terrain_type: int, thickness: int):
	var dx = abs(x1 - x0)
	var dy = abs(y1 - y0)
	var step_x = 1 if x0 < x1 else -1
	var step_y = 1 if y0 < y1 else -1
	var err = dx - dy

	while true:
		# 在当前 Bresenham 点周围画 thickness 半径的圆
		var r2 = thickness * thickness
		for dy2 in range(-thickness, thickness + 1):
			for dx2 in range(-thickness, thickness + 1):
				if dx2 * dx2 + dy2 * dy2 <= r2:
					var nx = x0 + dx2
					var ny = y0 + dy2
					if nx >= 0 and nx < MAP_WIDTH and ny >= 0 and ny < MAP_HEIGHT:
						map_data[ny][nx] = terrain_type
		if x0 == x1 and y0 == y1:
			break
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x0 += step_x
		if e2 < dx:
			err += dx
			y0 += step_y


# ============================================================
# 步骤 5：创建任务间道路
#
# 两阶段策略：
#   1. 按 TASK_LINKS 铺路（预定义链接）
#      - BFS 检测环，禁止形成闭合三角形
#      - 从 exit 房间画到 entrance 房间
#   2. 额外邻居路（补充链接不足）
#      - 遍历所有任务对，距离 < 110 且无环的作为候选
#      - 按距离排序，最多添加 12 条
#
# 道路使用 draw_road() 绘制贝塞尔曲线（更自然）
# ============================================================
func create_task_link_roads():
	var links = task_system.get_all_links()

	# 已绘制的链接（双向存储）
	var drawn_links = {}
	# 邻接图（用于环检测 BFS）
	var adj_graph = {}

	# --- 第一阶段：按 TASK_LINKS 铺路 ---
	for link in links:
		var from_id = link.from
		var to_id = link.to

		if not room_chains.has(from_id) or not room_chains.has(to_id):
			continue

		# 环检测：若添加此边会形成环则跳过
		if _creates_cycle(from_id, to_id, adj_graph):
			continue

		var from_chain = room_chains[from_id]
		var to_chain = room_chains[to_id]

		# 获取出口/入口房间（房间链的首尾房间）
		var exit_room = chain_gen.get_exit(from_chain)
		var entrance_room = chain_gen.get_entrance(to_chain)

		if exit_room == null or entrance_room == null:
			continue

		# 标记为已绘制
		var link_key = from_id + "_" + to_id
		drawn_links[link_key] = true
		drawn_links[to_id + "_" + from_id] = true

		# 更新邻接图
		if not adj_graph.has(from_id):
			adj_graph[from_id] = []
		adj_graph[from_id].append(to_id)
		if not adj_graph.has(to_id):
			adj_graph[to_id] = []
		adj_graph[to_id].append(from_id)

		# 绘制道路
		draw_road(int(exit_room.center.x), int(exit_room.center.y),
				  int(entrance_room.center.x), int(entrance_room.center.y))

	# --- 第二阶段：添加额外邻居路 ---
	var task_ids = []
	for task_id in task_positions:
		task_ids.append(task_id)

	var max_neighbor_dist = 110.0  # 邻居距离阈值
	var extra_links = []

	# 收集候选链接（距离近且不形成环）
	for i in range(task_ids.size()):
		for j in range(i + 1, task_ids.size()):
			var id_a = task_ids[i]
			var id_b = task_ids[j]
			var key_ab = id_a + "_" + id_b

			if drawn_links.has(key_ab):
				continue

			if _creates_cycle(id_a, id_b, adj_graph):
				continue

			var dist = task_positions[id_a].distance_to(task_positions[id_b])
			if dist < max_neighbor_dist:
				extra_links.append({
					from = id_a,
					to = id_b,
					dist = dist,
				})
				drawn_links[key_ab] = true
				drawn_links[id_b + "_" + id_a] = true

	# 按距离排序（最近的优先），最多添加 12 条
	extra_links.sort_custom(func(a, b): return a.dist < b.dist)

	var max_extra = min(extra_links.size(), 12)
	for idx in range(max_extra):
		var link = extra_links[idx]
		var from_id = link.from
		var to_id = link.to

		if not room_chains.has(from_id) or not room_chains.has(to_id):
			continue

		var from_chain = room_chains[from_id]
		var to_chain = room_chains[to_id]

		var exit_room = chain_gen.get_exit(from_chain)
		var entrance_room = chain_gen.get_entrance(to_chain)

		if exit_room == null or entrance_room == null:
			continue

		if not adj_graph.has(from_id):
			adj_graph[from_id] = []
		adj_graph[from_id].append(to_id)
		if not adj_graph.has(to_id):
			adj_graph[to_id] = []
		adj_graph[to_id].append(from_id)

		# 额外路标记为粗线（is_thin=true，当前未区分渲染）
		draw_road(int(exit_room.center.x), int(exit_room.center.y),
				  int(entrance_room.center.x), int(entrance_room.center.y), true)


# ============================================================
# 环检测：BFS 判断 from→to 是否已有路径
#
# 原理：维护无向邻接图，添加新边前做 BFS 检查。
#   若从 from 能通过已有路径到达 to，则添加此边会形成环。
#   禁止环的原因：饥荒类游戏地图应为树形结构（无闭合回路），
#   保证玩家不会绕圈而迷路。
#
# 时间复杂度：O(V + E)，其中 V=任务数，E=已有边数
# ============================================================
func _creates_cycle(from: String, to: String, adj_graph: Dictionary) -> bool:
	if not adj_graph.has(from):
		return false

	var visited = {}
	var queue = [from]
	visited[from] = true

	while not queue.is_empty():
		var current = queue.pop_front()
		if current == to:
			return true

		if not adj_graph.has(current):
			continue

		for neighbor in adj_graph[current]:
			if not visited.has(neighbor):
				visited[neighbor] = true
				queue.append(neighbor)

	return false


# ============================================================
# 步骤 6：构建岛屿底座（最复杂的步骤）
#
# 四阶段流程：
#   1. 标记可达海洋（DFS 从地图边缘开始），把不可达的内海填为沙滩
#   2. 生成噪声地图，基于噪声从岸边向外扩展沙滩（最多 10 瓦片）
#   3. 二次 DFS 确认沙滩间无残留内海
#   4. 边缘缓冲：地图最外圈 4 瓦片强制设为海洋（保证四面环海）
#
# 关键概念：
#   海洋=7（不可通行），沙滩=8（可通行，岛屿边缘）
#   可达海洋：从地图边缘通过 4 方向 DFS 能到达的海洋瓦片
#   不可达海洋：被陆地完全包围的内海，应填为沙滩
#
# 沙滩扩展算法：
#   用 4 次迭代从岸边向外扩展沙滩：
#     step 0-1: 直接把邻接陆地的海洋设为沙滩
#     step 2+: 仅噪声 > 阈值的瓦片设为沙滩（形成起伏边缘）
#   最多扩展 MAX_BEACH_WIDTH=10 瓦片宽
# ============================================================
func build_island_base():
	var dirs = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]

	# --- 阶段 1：标记可达海洋，填充内海为沙滩 ---
	var reachable = []
	for y in range(MAP_HEIGHT):
		var row = []
		for x in range(MAP_WIDTH):
			row.append(false)
		reachable.append(row)

	# 从地图边缘的海洋瓦片开始 DFS
	var stack = []
	for x in range(MAP_WIDTH):
		if map_data[0][x] == 7:
			stack.append(Vector2(x, 0))
		if map_data[MAP_HEIGHT - 1][x] == 7:
			stack.append(Vector2(x, MAP_HEIGHT - 1))
	for y in range(1, MAP_HEIGHT - 1):
		if map_data[y][0] == 7:
			stack.append(Vector2(0, y))
		if map_data[y][MAP_WIDTH - 1] == 7:
			stack.append(Vector2(MAP_WIDTH - 1, y))

	# DFS 遍历所有从边缘可达的海洋
	while not stack.is_empty():
		var p = stack.pop_back()
		var px = int(p.x)
		var py = int(p.y)
		if px < 0 or px >= MAP_WIDTH or py < 0 or py >= MAP_HEIGHT:
			continue
		if reachable[py][px]:
			continue
		if map_data[py][px] != 7:
			continue
		reachable[py][px] = true
		for d in dirs:
			stack.append(p + d)

		# 不可达的内海 → 沙滩
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if map_data[y][x] == 7 and not reachable[y][x]:
				map_data[y][x] = 8

	# --- 阶段 2：生成噪声地图，用于沙滩边缘起伏 ---
	var NUM_LEVELS = 4
	var noise_map = []
	for y in range(MAP_HEIGHT):
		var nrow = []
		for x in range(MAP_WIDTH):
			# 三层正弦噪声叠加（不同频率和相位）
			# t1: 低频 + 随机相位 → 大尺度起伏
			# t2: 中频 + 随机相位 → 中尺度细节
			# t3: 高频余弦 → 小尺度纹理
			var t1 = asin(sin(x * 0.06 + y * 0.04 + rng.randf_range(-1, 1))) * 2.0 / PI
			var t2 = asin(sin(x * 0.12 - y * 0.08 + rng.randf_range(-0.5, 0.5))) * 2.0 / PI
			var t3 = asin(cos(x * 0.03 + y * 0.09)) * 2.0 / PI
			var combined = (t1 * 0.5 + t2 * 0.3 + t3 * 0.2) * 0.5 + 0.5
			combined = clamp(combined, 0.0, 1.0)
			var level = int(combined * NUM_LEVELS)
			if level >= NUM_LEVELS:
				level = NUM_LEVELS - 1
			combined = (level + 0.5) / float(NUM_LEVELS)
			nrow.append(combined)
		noise_map.append(nrow)

	# --- 阶段 3：从岸边向外扩展沙滩（最多 10 瓦片） ---
	var MAX_BEACH_WIDTH = 10
	for step in range(MAX_BEACH_WIDTH):
		# step 0-1: 直接填充（无噪声限制）
		# step 2+: 仅噪声 > 阈值的瓦片填充（形成起伏）
		var fill_threshold = 0.0
		if step >= 2:
			fill_threshold = 1.0 - (step - 1) / float(MAX_BEACH_WIDTH - 2)

		var to_fill = []

		for y in range(MAP_HEIGHT):
			for x in range(MAP_WIDTH):
				if map_data[y][x] == 7 and reachable[y][x]:
					# 检查是否邻接陆地（非海洋）
					var has_land_neighbor = false
					for d in dirs:
						var nx = x + int(d.x)
						var ny = y + int(d.y)
						if nx >= 0 and nx < MAP_WIDTH and ny >= 0 and ny < MAP_HEIGHT:
							var nt = map_data[ny][nx]
							if nt != 7:
								has_land_neighbor = true
								break
					if has_land_neighbor:
						if step < 2 or noise_map[y][x] > fill_threshold:
							to_fill.append(Vector2(x, y))

		for p in to_fill:
			map_data[int(p.y)][int(p.x)] = 8

	# --- 阶段 4：二次 DFS 确认（可能产生新的内海） ---
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			reachable[y][x] = false

	stack.clear()
	for x in range(MAP_WIDTH):
		if map_data[0][x] == 7:
			stack.append(Vector2(x, 0))
		if map_data[MAP_HEIGHT - 1][x] == 7:
			stack.append(Vector2(x, MAP_HEIGHT - 1))
	for y in range(1, MAP_HEIGHT - 1):
		if map_data[y][0] == 7:
			stack.append(Vector2(0, y))
		if map_data[y][MAP_WIDTH - 1] == 7:
			stack.append(Vector2(MAP_WIDTH - 1, y))

	while not stack.is_empty():
		var p = stack.pop_back()
		var px = int(p.x)
		var py = int(p.y)
		if px < 0 or px >= MAP_WIDTH or py < 0 or py >= MAP_HEIGHT:
			continue
		if reachable[py][px]:
			continue
		if map_data[py][px] != 7:
			continue
		reachable[py][px] = true
		for d in dirs:
			stack.append(p + d)

	# 二次填充：新产生的内海也填为沙滩
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if map_data[y][x] == 7 and not reachable[y][x]:
				map_data[y][x] = 8

	# --- 阶段 5：边缘缓冲（最外圈 4 瓦片强制为海洋） ---
	# 保证岛屿四面环海，不会生成到地图边缘
	var EDGE_BUFFER = 4
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if x < EDGE_BUFFER or x >= MAP_WIDTH - EDGE_BUFFER:
				if map_data[y][x] != 7:
					map_data[y][x] = 7
			if y < EDGE_BUFFER or y >= MAP_HEIGHT - EDGE_BUFFER:
				if map_data[y][x] != 7:
					map_data[y][x] = 7


# ============================================================
# 绘制贝塞尔曲线道路
#
# 算法：
#   1. 在起终点间添加 1-3 个随机控制节点（法向偏移 ±8）
#   2. 用折线近似贝塞尔曲线（控制点越多越平滑）
#   3. 对每段折线调用 _bresenham_line（1 像素宽道路）
#
# is_thin: 预留参数（当前所有道路都是 1 像素宽）
#   未来可用于区分主干道/小路
# ============================================================
func draw_road(x1: int, y1: int, x2: int, y2: int, is_thin: bool = false):
	var points = []
	points.append(Vector2i(x1, y1))

	# 随机生成 1-3 个控制节点
	var num_ctrl = 1 + rng.randi() % 3
	for c in range(num_ctrl):
		# 控制节点位置：沿路径参数 t ∈ [0.2, 0.8] 插值
		var t = 0.2 + 0.6 * (c + 1.0) / (num_ctrl + 1.0)
		var mx = x1 + (x2 - x1) * t
		var my = y1 + (y2 - y1) * t
		# 法向偏移：垂直于路径方向的随机偏移
		var perp_x = -(y2 - y1)
		var perp_y = (x2 - x1)
		var perp_len = sqrt(perp_x * perp_x + perp_y * perp_y)
		if perp_len > 0.001:
			perp_x /= perp_len
			perp_y /= perp_len
		var jitter = rng.randf_range(-8.0, 8.0)
		points.append(Vector2i(int(mx + perp_x * jitter), int(my + perp_y * jitter)))

	points.append(Vector2i(x2, y2))

	# 逐段画线
	for seg_idx in range(points.size() - 1):
		var sx = points[seg_idx].x
		var sy = points[seg_idx].y
		var ex = points[seg_idx + 1].x
		var ey = points[seg_idx + 1].y
		_bresenham_line(sx, sy, ex, ey)


# ============================================================
# 标准 Bresenham 线算法（1 像素宽）
# 把路径上每个瓦片设为 terrain=0（道路/泥地）
#
# 与 _bresenham_line_thick 的区别：
#   - 仅画 1 像素宽线（道路通道）
#   - 用于任务间道路绘制（细通道）
#   - _bresenham_line_thick 用于房间间连接（粗通道）
# ============================================================
func _bresenham_line(x0: int, y0: int, x1: int, y1: int) -> void:
	var dx = abs(x1 - x0)
	var dy = abs(y1 - y0)
	var step_x = 1 if x0 < x1 else -1
	var step_y = 1 if y0 < y1 else -1
	var err = dx - dy

	while true:
		if x0 >= 0 and x0 < MAP_WIDTH and y0 >= 0 and y0 < MAP_HEIGHT:
			map_data[y0][x0] = 0
		if x0 == x1 and y0 == y1:
			break
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x0 += step_x
		if e2 < dx:
			err += dx
			y0 += step_y


# ============================================================
# 步骤 7：渲染地图
# 把 map_data 二维数组渲染为 ColorRect 节点
#
# 流程：
#   1. 创建/清空 TileContainer 容器
#   2. 遍历所有瓦片，根据 terrain_type 获取颜色
#   3. 为每个瓦片创建 ColorRect（TILE_SIZE × TILE_SIZE）
#   4. 调用 draw_labels() 绘制任务名标签
#
# 性能提示：400×400 = 160,000 个 ColorRect 节点
#   2D 场景下可接受，但 3D 版本用合并网格优化
# ============================================================
func render_map():
	if not tile_container:
		tile_container = Node2D.new()
		tile_container.name = "TileContainer"
		add_child(tile_container)

	# 清除旧瓦片
	for child in tile_container.get_children():
		tile_container.remove_child(child)
		child.queue_free()

	# 创建新瓦片
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			var terrain_type = map_data[y][x]
			var color = task_system.get_terrain_color(terrain_type)

			var rect = ColorRect.new()
			rect.color = color
			rect.size = Vector2(TILE_SIZE, TILE_SIZE)
			rect.position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
			tile_container.add_child(rect)

	draw_labels()


# ============================================================
# 绘制任务名称标签
#
# 在每个任务的入口房间上方显示任务名
# 标签颜色对应危险等级（绿=安全，黄=中危，红=高危）
# 出生点额外标注"★ 出生点"（黄色大字）
# ============================================================
func draw_labels():
	for task_id in room_chains:
		var chain = room_chains[task_id]
		if chain.is_empty():
			continue

		# 入口房间（房间链第一个）
		var entrance = chain[0]
		var task = task_system.get_task_by_id(task_id)

		var danger_level = task.get("danger_level", 0)
		var label_color = task_system.get_danger_color(danger_level)

		var label = Label.new()
		var task_name = task.get("name", task_id)
		label.text = task_name
		# 标签位置：入口房间中心上方
		label.position = Vector2(entrance.center.x * TILE_SIZE - 30,
								 entrance.center.y * TILE_SIZE - 35)
		# 样式：危险等级颜色 + 黑色阴影
		label.add_theme_color_override("font_color", label_color)
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		tile_container.add_child(label)

	# 出生点特殊标注
	var start_task = task_system.get_start_task()
	if room_chains.has(start_task.id):
		var start_chain = room_chains[start_task.id]
		if not start_chain.is_empty():
			var start_room = start_chain[0]
			var start_label = Label.new()
			start_label.text = "★ 出生点"
			start_label.position = Vector2(start_room.center.x * TILE_SIZE - 35,
										   start_room.center.y * TILE_SIZE - 40)
			start_label.add_theme_color_override("font_color", Color(1, 1, 0))
			start_label.add_theme_font_size_override("font_size", 16)
			start_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
			start_label.add_theme_constant_override("shadow_offset_x", 2)
			start_label.add_theme_constant_override("shadow_offset_y", 2)
			tile_container.add_child(start_label)


# ============================================================
# 重新生成按钮回调
# 重新随机化种子并执行完整生成流水线
# 连接到 UI 按钮的 "pressed" 信号
# ============================================================
func _on_regenerate_pressed():
	rng.randomize()
	generate_map()
