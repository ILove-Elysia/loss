# ============================================================
# 2D 地图生成器（核心脚本）
#
# 整体架构：8 步流水线生成地图
#   1. init_map_data        → 初始化全海 (terrain=7) 地图
#   2. layout_tasks         → 节点布局（调用 layout.gd 两阶段布局）
#   3. generate_room_chains → 生成房间链（调用 room_chain.gd，防重叠放置）
#   4. stamp_room_terrain   → 把房间地形写入地图数据 + 房间间连通
#   5. fill_region_territories → 用 Voronoi 把六个群系连成一块完整孤岛
#   6. create_task_link_roads → 按 TASK_LINKS 铺路 + 额外邻居路（无环）
#   7. build_island_base    → 岛屿底座：沙滩边缘 + 填充内海 + 边缘缓冲
#   8. render_map           → 把 map_data 渲染为 ColorRect 节点
#
# 数据结构：
#   map_data[y * MAP_WIDTH + x] = terrain_type (int)
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

# 每个瓦片的尺寸（世界单位）
# 用户要求“用更多格子数放大地图，而不是放大格子”，因此瓦片保持细粒度 1 单位
# （角色高约 1 单位，一格≈一个身位，碰撞边缘精细、地图更细腻）。
# 世界尺度完全由格子数量决定：MAP × TILE_SIZE。
const TILE_SIZE = 1

# 地图宽高（瓦片数量）
# 1600 × 1600 = 2,560,000 瓦片 → 世界 1600 × 1600 单位
# （饥荒标准图约 1700 × 1700 单位，同量级；横穿岛屿约 3 分钟）
# 注意：与“放大瓦片”的方案相比，本方案的渲染/碰撞/寻路都按格子数缩放，
# 生成耗时随格子数上升，但地图精细度更高。
const MAP_WIDTH = 1600
const MAP_HEIGHT = 1600

# 瓦片整数键：把 (x, y) 打包成一个 int，替代 str(x)+","+str(y)。
# 房间占用检测（overlap / adjacent）要对每个房间瓦片做多次键查找，
# 大地图下房间瓦片数以万计，字符串拼接与哈希是生成耗时的热点。
# 偏移 512 是为了容纳房间瓦片落在地图外的负坐标，避免键冲突。
const TILE_KEY_OFFSET = 512
const TILE_KEY_STRIDE = 2048

# ------------------------------------------------------------
# 岛屿轮廓常量（供 fill_region_territories 使用）
# ------------------------------------------------------------

# 岛屿本体椭圆的半轴（瓦片单位），以地图中心为心。
# 取值依据：Tier 2 任务中心的布局半径约 310，房间链最远可再向外延伸约 100，
# 取 430 可完整包住全部房间，并留出约 100 的"无主荒地"作为各区缓冲。
# 严格遵照 target_rx : target_ry = 310 : 280 的比例换算纵向半轴（≈388）。
const ISLAND_RX = 430.0
const ISLAND_RY = 388.0

# 海岸线噪声：让岛屿轮廓从完美椭圆变成有半岛与海湾的有机形状。
# 幅度是相对归一化半径的，0.13 ≈ 边缘在 ±13% 之间起伏（约 ±56 瓦片）。
const COAST_NOISE_AMPLITUDE = 0.13

# 区域分界线扭曲强度（瓦片）：对 Voronoi 的输入坐标做 domain warp，
# 使各群系的边界不再是直线多边形，而是弯曲的有机曲线。
const REGION_WARP = 70.0

# 出生区保护半径（瓦片）：先把距离出生点这么近的空格直接划给草原。
#
# 起因：布局存在两处随机（初始角度抖动 ±25%、力导向 30 次迭代漂移），
# 某些种子下三个中圈区会挤到距地图中心很近的位置，
# 把正中心的草原压成一小块（实测最小仅 3 万格，半径不足 100）。
# 出生即进入的区域需要稳定的保底规模，否则"第一个基地"无处安放。
# 注意取值必须小于中圈布局半径（约 160），否则会把中圈房间整个包进草原。
const MIN_START_REGION_RADIUS = 110.0

# 群系交界过渡带宽度（加权距离差，约等于实际宽度的 2 倍）
#
# 纯净 Voronoi 的分界是一条刀切的硬线：这一格是草原、下一格是丛林，颜色突变。
# 打开过渡带后，越靠近区界就越倾向于采信"次近"的群系，
# 于是两侧地形以斑块/指状互相渗透——真实世界的森林-草原过渡带正是这个形态。
# 取值 55 意味着区界两侧各约 27 瓦片内会出现交错，
# 再往外迅速纯化为各自的本色，不会让群系失去辨识度。
const REGION_BLEND_WIDTH = 55.0

# 领地权重（按 tier）：Voronoi 比较前先把距离乘以该权重。
# 权重 < 1 = 该区影响力更强 = 领地更大。
# 用途：校正同心环的天然不公——外圈是环形，面积随半径增长，
#   纯 Voronoi 会把大片土地判给外圈，而正中心的草原区被四邻挤成一小块。
#   给内圈降权，才能换来一个规模合理的出生安全区（足以安放第一个基地）。
const REGION_TIER_WEIGHT = {
	0: 0.78,   # 内圈草原：适度放大，保证出生安全区有足够建基空间
	1: 0.85,   # 中圈三区：略放大
	2: 1.00,   # 外圈高危区：保持原权重
}


# ------------------------------------------------------------
# 子系统引用（@onready 保证在 _ready 时加载）
# ------------------------------------------------------------

# 任务系统：定义所有任务、链接、地形颜色映射
@onready var task_system = load("res://script/map/task_system.gd").new()

# 布局系统：两阶段坐标生成（同心布局 + 力导向微调 + 归一化）
@onready var layout = load("res://script/map/layout.gd").new()

# 房间链生成器：生成不规则 blob 房间 + 房间链方向计算
@onready var chain_gen = load("res://script/map/room_chain.gd").new()


# ------------------------------------------------------------
# 运行时数据
# ------------------------------------------------------------

# 地图数据：扁平的一维数组，索引 = y * MAP_WIDTH + x，值 = terrain_type
# 初始全为 7（海洋），生成过程中逐步填充陆地
# （声明成 PackedByteArray 而不是 Array：每次访问只是一次字节读写，
#   几十万格下省掉变体装箱开销；此外存档也直接存它的字节快照）
var map_data: PackedByteArray = PackedByteArray()

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
#   fill_region_territories: 领域扭曲 Voronoi 分配各区领地（连片成岛）
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
	fill_region_territories()
	create_task_link_roads()
	build_island_base()
	render_map()


# ============================================================
# 步骤 1：初始化地图数据
# 创建 MAP_HEIGHT × MAP_WIDTH 的二维数组，全部填充 terrain=7（海洋）
# 后续步骤会把对应位置改为陆地/沙滩/道路
# ============================================================
func init_map_data():
	# 扁平化的 PackedByteArray 而非"数组的数组"：
	# 大地图下（数十万格）两次索引 + 变体装箱的开销相当可观，
	# 扁平化后每次访问只是一次字节读写。
	# 索引用 y * MAP_WIDTH + x。
	map_data = PackedByteArray()
	map_data.resize(MAP_WIDTH * MAP_HEIGHT)
	map_data.fill(7)


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
#   target_rx=310, target_ry=280: 目标椭圆半径（瓦片单位，TILE_SIZE=1）
#   中圈节点分布在 ~140 瓦片半径，外圈 ~310 瓦片半径
#   （世界单位：外圈中心距原点 ~310，加上房间半径与沙滩后岛屿半径 ~510）
# ============================================================
func layout_tasks():
	var tasks = task_system.get_all_tasks()
	var links = task_system.get_all_links()

	# 第一阶段：力导向布局（相对坐标）
	var result = layout.layout_tasks(tasks, links, rng)
	var nodes = result[0]

	# 第二阶段：归一化到绝对瓦片坐标
	# TILE_SIZE=1 后，为保持岛屿“绝对尺寸”与放大方案一致（外圈半径≈310 世界单位），
	# 瓦片单位的布局半径随 TILE_SIZE 同步放大（155→310，140→280）。
	var center = Vector2(MAP_WIDTH / 2, MAP_HEIGHT / 2)
	var target_rx = 310.0
	var target_ry = 280.0
	task_positions = layout.normalize_to_tile_coords(nodes, center, target_rx, target_ry, rng)

	# 防出界：把所有任务位置限制在 [MIN_EDGE, MAP_SIZE-MIN_EDGE] 范围内
	# 边距按地图尺寸同比放大（60→120），保持约 7.5% 的安全留白。
	var MIN_EDGE_DIST = 120.0
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

	# 逐步缩小半径尝试（瓦片更细，步长与下限同步放大：步长 6、下限 24）
	var cur_radius = room.radius - 6
	while cur_radius >= 24:
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
		var key: int = (int(tile.y) + TILE_KEY_OFFSET) * TILE_KEY_STRIDE + int(tile.x) + TILE_KEY_OFFSET
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
		Vector2i(-1, 1), Vector2i(0,  1), Vector2i(1,  1),
	]

	for tile in tiles:
		for off in offsets:
			var key: int = (int(tile.y) + off.y + TILE_KEY_OFFSET) * TILE_KEY_STRIDE + int(tile.x) + off.x + TILE_KEY_OFFSET
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
		var key: int = (int(tile.y) + TILE_KEY_OFFSET) * TILE_KEY_STRIDE + int(tile.x) + TILE_KEY_OFFSET
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
					map_data[ty * MAP_WIDTH + tx] = terrain_type

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
						map_data[ny * MAP_WIDTH + nx] = terrain_type
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
# 步骤 4.5：填充区域领地（把六个群系连成一块完整孤岛）
#
# 为什么要这一步（本地图与饥荒布局的最大差距就在这里）：
#   stamp_room_terrain() 只把"房间 blob"写进地图，房间之外仍是海洋，
#   结果六个区变成漂浮在大海里的六块孤岛斑块，彼此只靠 1 像素细路相连。
#   饥荒的地图恰好相反：群系彼此邻接、铺满整块陆地，海洋只在外圈包边。
#   本步骤就是把这个差别补上——玩家在陆地上走，永远脚下有归属。
#
# 算法：岛屿椭圆 + 领域扭曲的 Voronoi
#   1. 岛屿轮廓：以地图中心为心、(ISLAND_RX, ISLAND_RY) 为半轴的椭圆，
#      边界用低频噪声扰动，海岸线因此是有机曲线而非完美椭圆。
#   2. 领地划分：椭圆内所有"仍是海洋"的格子（未被房间/道路占用），
#      分配给最近的任务中心，写入该区的 terrain_type（10-15）。
#      分配前对输入坐标做 domain warp（每格整格共享一次扭曲），
#      使群系边界扭曲成自然曲线，而不是 Voronoi 的直线多边形。
#
# 与 build_island_base 的分工：
#   本步骤只造"陆地"，不造海岸。椭圆之外依然是海洋，
#   build_island_base 会从新的陆地边缘向外扩展沙滩环 + 边缘缓冲，
#   因此这里不用处理沙滩，也不用担心越界。
#
# 性能：按行求椭圆横截面，跳过岛屿之外的行；
#   实际进入 Voronoi 的只有椭圆内未占用的格子（约 30 万 × 6 次距离）。
# ============================================================
func fill_region_territories():
	# --- 收集任务中心与其地形类型 ---
	# 平行数组而非字典数组：内层 Voronoi 循环每格要遍历全部中心，
	# 避免 Variant 装箱与字典查找是值得的。
	var centers_x := PackedFloat32Array()
	var centers_y := PackedFloat32Array()
	var centers_t := PackedInt32Array()
	var centers_w2 := PackedFloat32Array()
	for task in task_system.get_all_tasks():
		var tid: String = task.id
		if not task_positions.has(tid):
			continue
		var pos: Vector2 = task_positions[tid]
		centers_x.append(pos.x)
		centers_y.append(pos.y)
		centers_t.append(int(task.get("terrain_type", 10)))
		# 权重作用于"距离"，而 Voronoi 比较的是平方距离，故先取平方备用
		var w: float = float(REGION_TIER_WEIGHT.get(task.get("tier", 1), 1.0))
		centers_w2.append(w * w)

	# --- 出生区保护圈：为草原区锁死一块保底安全面积 ---
	# 后续 Voronoi 会跳过所有非海洋格，因此这里抢先铺好底，
	# 草原的最终面积 = 保护圈 ∪ Voronoi 分得的领地。
	var start_task: Dictionary = task_system.get_start_task()
	if not start_task.is_empty() and task_positions.has(start_task.id):
		var sp: Vector2 = task_positions[start_task.id]
		var start_terrain: int = int(start_task.get("terrain_type", 10))
		var sr: int = int(MIN_START_REGION_RADIUS)
		var sr2: int = sr * sr
		var cix: int = int(sp.x)
		var ciy: int = int(sp.y)
		var sy0: int = maxi(ciy - sr, 0)
		var sy1: int = mini(ciy + sr, MAP_HEIGHT - 1)
		var sx0: int = maxi(cix - sr, 0)
		var sx1: int = mini(cix + sr, MAP_WIDTH - 1)
		for yy2 in range(sy0, sy1 + 1):
			var dy2: int = yy2 - ciy
			var row: int = yy2 * MAP_WIDTH
			for xx2 in range(sx0, sx1 + 1):
				var dx2: int = xx2 - cix
				if dx2 * dx2 + dy2 * dy2 > sr2:
					continue
				if map_data[row + xx2] == 7:
					map_data[row + xx2] = start_terrain

	var n_centers: int = centers_x.size()
	if n_centers == 0:
		return

	# --- 噪声准备 ---
	# 海岸噪声（低频 → 大尺度半岛与海湾）
	var coast_noise := FastNoiseLite.new()
	coast_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	coast_noise.frequency = 0.004
	coast_noise.seed = rng.randi()

	# Domain warp 噪声（中频 → 群系边界的有机扭曲）
	var warp_noise := FastNoiseLite.new()
	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp_noise.frequency = 0.010
	warp_noise.seed = rng.randi()

	# 过渡带噪声（中频 → 大块斑状交错，而非细碎噪点）
	# 频率 0.022 约对应 45 瓦片的斑块尺度，与过渡带宽度匹配，
	# 形成"指状互相渗透"的过渡，而不是沙沙响的噪点。
	var blend_noise := FastNoiseLite.new()
	blend_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	blend_noise.frequency = 0.022
	blend_noise.seed = rng.randi()

	var cx: float = MAP_WIDTH / 2.0
	var cy: float = MAP_HEIGHT / 2.0
	# 噪声扰动的极值：用于按行求椭圆横截面时留出安全余量，避免切掉半岛
	var max_coast: float = 1.0 + COAST_NOISE_AMPLITUDE

	for y in range(MAP_HEIGHT):
		var ndy: float = (float(y) - cy) / ISLAND_RY
		if abs(ndy) > max_coast:
			continue  # 整行都在岛屿之外

		# 本行的椭圆横截面半径（按最大扰动计算，宁宽勿窄）
		var half_span: float = sqrt(max(max_coast * max_coast - ndy * ndy, 0.0)) * ISLAND_RX
		var x0: int = maxi(int(ceil(cx - half_span)), 0)
		var x1: int = mini(int(floor(cx + half_span)), MAP_WIDTH - 1)
		var row_base: int = y * MAP_WIDTH

		for x in range(x0, x1 + 1):
			var idx: int = row_base + x
			if map_data[idx] != 7:
				continue  # 房间 / 道路已占用，保留原地形

			var fx: float = float(x)
			var fy: float = float(y)
			var ndx: float = (fx - cx) / ISLAND_RX

			# 海岸判定：归一化椭圆半径 + 噪声扰动
			var dist_norm: float = sqrt(ndx * ndx + ndy * ndy)
			if dist_norm > 1.0 + coast_noise.get_noise_2d(fx, fy) * COAST_NOISE_AMPLITUDE:
				continue  # 岛外的海：留给 build_island_base 变沙滩或保持海洋

			# Domain warp：扭曲坐标后再做 Voronoi，使区界有机化
			var wx: float = fx + warp_noise.get_noise_2d(fx, fy) * REGION_WARP
			var wy: float = fy + warp_noise.get_noise_2d(fx + 537.0, fy - 311.0) * REGION_WARP

			var best_t: int = -1
			var best_d: float = 1e18
			# 次近群系：过渡带用它做交错，避免区界成为一条刀切硬线
			var second_t: int = -1
			var second_d: float = 1e18
			for c in range(n_centers):
				var ddx: float = wx - centers_x[c]
				var ddy: float = wy - centers_y[c]
				var d: float = (ddx * ddx + ddy * ddy) * centers_w2[c]
				if d < best_d:
					second_d = best_d
					second_t = best_t
					best_d = d
					best_t = centers_t[c]
				elif d < second_d:
					second_d = d
					second_t = centers_t[c]

			if best_t >= 0:
				# --- 群系交界过渡带 ---
				# edge 表示"到区界有多远"（加权距离差）：0 = 正落在两区平分线上，
				# 越大 = 越深入本区腹地。
				# 越贴近区界，改采次近群系的概率越高，于是两侧地形呈指状互相渗透；
				# 走出过渡带后概率归零，各区迅速恢复本色、不丢辨识度。
				if second_t >= 0 and REGION_BLEND_WIDTH > 0.0:
					var edge: float = sqrt(second_d) - sqrt(best_d)
					if edge < REGION_BLEND_WIDTH:
						var bn: float = blend_noise.get_noise_2d(fx, fy) * 0.5 + 0.5
						var switch_chance: float = 1.0 - edge / REGION_BLEND_WIDTH
						if bn < switch_chance:
							best_t = second_t
				map_data[idx] = best_t


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

	var max_neighbor_dist = 500.0  # 邻居距离阈值（TILE_SIZE=1、MAP=1600，原 250）
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
#   2. 生成噪声地图，基于噪声从岸边向外扩展沙滩（最多 22 瓦片）
#   3. 二次 DFS 确认沙滩间无残留内海
#   4. 边缘缓冲：地图最外圈 8 瓦片强制设为海洋（保证四面环海）
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
#   最多扩展 MAX_BEACH_WIDTH=30 轮（外缘随轮次变稀疏，实际宽度小于此值）
# ============================================================
func build_island_base():
	var dirs = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]

	# --- 阶段 1：标记可达海洋，填充内海为沙滩 ---
	# 扁平 PackedByteArray（0 = 未访问），与 map_data 同样的索引方式
	var reachable := PackedByteArray()
	reachable.resize(MAP_WIDTH * MAP_HEIGHT)

	# 从地图边缘的海洋瓦片开始 DFS
	# 栈里存整数索引（y * MAP_WIDTH + x）而不是 Vector2，
	# 大地图下 DFS 会压入数十万个元素，避免这些对象分配是值得的。
	var stack: Array = []
	for x in range(MAP_WIDTH):
		if map_data[x] == 7:
			stack.append(x)
		if map_data[(MAP_HEIGHT - 1) * MAP_WIDTH + x] == 7:
			stack.append((MAP_HEIGHT - 1) * MAP_WIDTH + x)
	for y in range(1, MAP_HEIGHT - 1):
		if map_data[y * MAP_WIDTH] == 7:
			stack.append(y * MAP_WIDTH)
		if map_data[y * MAP_WIDTH + MAP_WIDTH - 1] == 7:
			stack.append(y * MAP_WIDTH + MAP_WIDTH - 1)

	# DFS 遍历所有从边缘可达的海洋
	while not stack.is_empty():
		var idx: int = stack.pop_back()
		if reachable[idx]:
			continue
		if map_data[idx] != 7:
			continue
		reachable[idx] = 1
		var py: int = idx / MAP_WIDTH
		var px: int = idx - py * MAP_WIDTH
		# 4 邻域。用显式边界判断代替"入栈后越界检查"，
		# 少一次出栈后的无效迭代。
		if py > 0:
			stack.append(idx - MAP_WIDTH)
		if py < MAP_HEIGHT - 1:
			stack.append(idx + MAP_WIDTH)
		if px > 0:
			stack.append(idx - 1)
		if px < MAP_WIDTH - 1:
			stack.append(idx + 1)

		# 不可达的内海 → 沙滩
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if map_data[y * MAP_WIDTH + x] == 7 and not reachable[y * MAP_WIDTH + x]:
				map_data[y * MAP_WIDTH + x] = 8

	# --- 阶段 2：生成噪声地图，用于沙滩边缘起伏 ---
	# 改用 FastNoiseLite（原生实现）替代手写三层正弦叠加，原因有二：
	#   1) 快一个数量级。64 万格地图上原写法是主要瓶颈（占生成耗时大头）。
	#   2) 原写法每格都叠加随机相位，实际是白噪声，沙滩边缘是碎点；
	#      FastNoiseLite 是空间连贯噪声，边缘会形成自然的团块起伏。
	var NUM_LEVELS = 4
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.02
	noise.seed = rng.randi()
	var noise_map := PackedFloat32Array()
	noise_map.resize(MAP_WIDTH * MAP_HEIGHT)
	# 性能优化：把“噪声图生成”和“初始岸边候选收集”合并到同一次全图遍历，
	# 省掉一遍 256 万次的扫描（MAP=1600 下约 1-2 秒）。
	# 沙滩最大扩展轮数。注意它不等于实际沙滩宽度：阈值逐轮升高，
	# 越往外填充率越低，外缘自然碎成沙洲，因此实际平均宽度远小于此值。
	# 取 30 而非 44 是性能与观感的折衷：最后若干轮填充率极低（<10%），
	# 对画面几乎无贡献，却要为每轮遍历整条前沿（实测 44 轮要多花约 10 秒）。
	var MAX_BEACH_WIDTH = 30

	# 前沿改用整数索引（y * MAP_WIDTH + x）而非 Vector2i 字典键。
	# 沙滩真正跑满 44 轮后，每轮要处理数万个候选格，
	# Vector2i 的构造与哈希开销会主导整张地图的生成耗时（实测多出约 30 秒）。
	# 换成"索引数组 + PackedByteArray 去重标记"后，查重退化成一次字节读写。
	var frontier: Array = []
	var queued := PackedByteArray()
	queued.resize(MAP_WIDTH * MAP_HEIGHT)

	for y in range(MAP_HEIGHT):
		var nrow_base: int = y * MAP_WIDTH
		for x in range(MAP_WIDTH):
			# 噪声图（用于沙滩边缘起伏）
			var n: float = clamp(noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5, 0.0, 1.0)
			var level: int = int(n * NUM_LEVELS)
			if level >= NUM_LEVELS:
				level = NUM_LEVELS - 1
			noise_map[nrow_base + x] = (level + 0.5) / float(NUM_LEVELS)

			# 初始岸边候选：可达海洋且邻接陆地
			var idx0: int = nrow_base + x
			if map_data[idx0] == 7 and reachable[idx0]:
				var px0: int = x
				var py0: int = y
				var has_land_neighbor := false
				if px0 > 0 and map_data[idx0 - 1] != 7:
					has_land_neighbor = true
				elif px0 < MAP_WIDTH - 1 and map_data[idx0 + 1] != 7:
					has_land_neighbor = true
				elif py0 > 0 and map_data[idx0 - MAP_WIDTH] != 7:
					has_land_neighbor = true
				elif py0 < MAP_HEIGHT - 1 and map_data[idx0 + MAP_WIDTH] != 7:
					has_land_neighbor = true
				if has_land_neighbor:
					frontier.append(idx0)
					queued[idx0] = 1

	for step in range(MAX_BEACH_WIDTH):
		# step 0-1: 直接填充（无噪声限制），保证沙滩紧贴陆地、不会断裂
		# step 2+: 仅噪声 > 阈值的瓦片填充。
		#   阈值随轮次【递增】：越远离陆地越挑剔，只有噪声高的团块才填得上，
		#   于是沙滩外缘由密实渐变为破碎沙洲，而不是一刀切的直线。
		#   注意方向不能写反——阈值递减会让越远填得越多，沙滩将失控铺满整片海。
		#   阈值还必须落在 noise_map 的实际取值区间内：噪声被量化为 4 档，
		#   取值只可能是 0.125/0.375/0.625/0.875。若阈值高过 0.875，
		#   就会出现"整轮填不出任何格子 → 立刻 break"，沙滩退化成 2 格宽的细线。
		var fill_threshold: float = 0.0
		if step >= 2:
			var t: float = float(step - 2) / float(MAX_BEACH_WIDTH - 2)
			fill_threshold = 0.125 + t * 0.75

		var next_frontier: Array = []
		var filled_count: int = 0

		for i in range(frontier.size()):
			var idx: int = frontier[i]
			queued[idx] = 0  # 释放标记，允许该格将来在更外层重新入队
			if map_data[idx] != 7:
				continue  # 更早的轮次已填成沙滩
			if step >= 2 and noise_map[idx] <= fill_threshold:
				# 本轮不填。由于阈值逐轮【升高】，后续轮次只会更严格，
				# 留着重试毫无意义，却会让候选集逐轮累积成 O(n²)（曾导致生成卡死）。
				# 直接丢弃：破碎的沙洲由"已填格子的外圈邻居"继续向外生长形成。
				continue

			# 填成沙滩，并立刻把海洋邻居收进下一轮前沿。
			# 边填边扩与"先收集后统一填"等价：邻居若在本轮已被填，就不再是海洋。
			map_data[idx] = 8
			filled_count += 1

			var px: int = idx % MAP_WIDTH
			var py: int = idx / MAP_WIDTH
			var nidx: int
			if px > 0:
				nidx = idx - 1
				if map_data[nidx] == 7 and reachable[nidx] and queued[nidx] == 0:
					queued[nidx] = 1
					next_frontier.append(nidx)
			if px < MAP_WIDTH - 1:
				nidx = idx + 1
				if map_data[nidx] == 7 and reachable[nidx] and queued[nidx] == 0:
					queued[nidx] = 1
					next_frontier.append(nidx)
			if py > 0:
				nidx = idx - MAP_WIDTH
				if map_data[nidx] == 7 and reachable[nidx] and queued[nidx] == 0:
					queued[nidx] = 1
					next_frontier.append(nidx)
			if py < MAP_HEIGHT - 1:
				nidx = idx + MAP_WIDTH
				if map_data[nidx] == 7 and reachable[nidx] and queued[nidx] == 0:
					queued[nidx] = 1
					next_frontier.append(nidx)

		if filled_count == 0:
			break  # 本轮没有任何扩展，再循环也不会有变化

		frontier = next_frontier

	# --- 阶段 4：二次 DFS 确认（可能产生新的内海） ---
	reachable.fill(0)

	stack.clear()
	for x in range(MAP_WIDTH):
		if map_data[x] == 7:
			stack.append(x)
		if map_data[(MAP_HEIGHT - 1) * MAP_WIDTH + x] == 7:
			stack.append((MAP_HEIGHT - 1) * MAP_WIDTH + x)
	for y in range(1, MAP_HEIGHT - 1):
		if map_data[y * MAP_WIDTH] == 7:
			stack.append(y * MAP_WIDTH)
		if map_data[y * MAP_WIDTH + MAP_WIDTH - 1] == 7:
			stack.append(y * MAP_WIDTH + MAP_WIDTH - 1)

	while not stack.is_empty():
		var idx: int = stack.pop_back()
		if reachable[idx]:
			continue
		if map_data[idx] != 7:
			continue
		reachable[idx] = 1
		var py: int = idx / MAP_WIDTH
		var px: int = idx - py * MAP_WIDTH
		if py > 0:
			stack.append(idx - MAP_WIDTH)
		if py < MAP_HEIGHT - 1:
			stack.append(idx + MAP_WIDTH)
		if px > 0:
			stack.append(idx - 1)
		if px < MAP_WIDTH - 1:
			stack.append(idx + 1)

	# 二次填充：新产生的内海也填为沙滩
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if map_data[y * MAP_WIDTH + x] == 7 and not reachable[y * MAP_WIDTH + x]:
				map_data[y * MAP_WIDTH + x] = 8

	# --- 阶段 5：边缘缓冲（最外圈 16 瓦片强制为海洋） ---
	# 保证岛屿四面环海，不会生成到地图边缘
	var EDGE_BUFFER = 16
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			if x < EDGE_BUFFER or x >= MAP_WIDTH - EDGE_BUFFER:
				if map_data[y * MAP_WIDTH + x] != 7:
					map_data[y * MAP_WIDTH + x] = 7
			if y < EDGE_BUFFER or y >= MAP_HEIGHT - EDGE_BUFFER:
				if map_data[y * MAP_WIDTH + x] != 7:
					map_data[y * MAP_WIDTH + x] = 7


# ============================================================
# 绘制贝塞尔曲线道路
#
# 算法：
#   1. 在起终点间添加 1-3 个随机控制节点（法向偏移 ±36）
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
		var jitter = rng.randf_range(-36.0, 36.0)
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
			map_data[y0 * MAP_WIDTH + x0] = 0
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
			var terrain_type = map_data[y * MAP_WIDTH + x]
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
