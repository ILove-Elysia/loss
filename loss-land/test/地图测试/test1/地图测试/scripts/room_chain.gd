# ============================================================
# 房间链生成器
#
# 核心职责：
#   1. 为每个任务生成一串不规则房间（entrance → middle → exit）
#   2. 用多种子 blob 算法生成不规则形状（非圆形/椭圆形）
#   3. 添加树枝状突起（branches），使房间更自然
#   4. 过滤掉不连通的碎片，保证每个房间是单一连通区域
#
# 房间形状生成算法：
#   1. 在基础半径内随机生成 7-12 个"种子"（带噪声的圆形）
#   2. 生成 3-4 个"分支"（椭圆形树枝，有弯曲）
#   3. 对每个瓦片检测是否在任一种子或分支内
#   4. BFS 保留最大连通分量，移除孤立碎片
#
# 与 map_generator.gd 的关系：
#   map_generator.generate_room_chains() 调用本脚本的方法
#   生成的房间链用于 stamp_room_terrain() 写入地图数据
# ============================================================
extends RefCounted


# ============================================================
# 房间实例类
# 代表房间链中的单个房间（入口/中间/出口）
# ============================================================
class RoomInstance:
	# 所属任务 ID（如 "Grassland"、"Forest"）
	var task_id: String

	# 房间角色：entrance（入口）/ middle（中间）/ exit（出口）
	# 房间链按此顺序排列：entrance → middle rooms → exit
	var role: String

	# 房间模板配置（当前为空 dict，预留扩展）
	var template: Dictionary

	# 房间中心坐标（瓦片坐标，浮点）
	var center: Vector2

	# 房间基础半径（瓦片单位，整数）
	# 实际形状不规则，radius 仅作为大致参考
	var radius: int

	# 房间包含的所有瓦片 [{x: int, y: int}, ...]
	# 由 _generate_blob_tiles 填充
	var tiles: Array

	# 构造函数
	func _init(p_task_id: String, p_role: String, p_template: Dictionary, p_center: Vector2, p_radius: int):
		task_id = p_task_id
		role = p_role
		template = p_template
		center = p_center
		radius = p_radius
		tiles = []


# ============================================================
# 为任务生成房间链
#
# 流程：
#   1. 从 task.rooms 获取房间配置列表（如 entrance + middle + exit）
#   2. 按 tier 确定房间半径范围：
#      - Tier 0（内圈/草原）：6-8 瓦片（小房间）
#      - Tier 1（中圈）：9-11 瓦片（中等房间）
#      - Tier 2（外圈/火山）：12-14 瓦片（大房间）
#   3. 沿 direction 方向等距排列房间（间距 = 半径 × 1.2）
#   4. 施加垂直方向的随机偏移（±40% 半径），避免完全对齐
#   5. 为每个房间生成不规则 blob 瓦片
#
# 参数：
#   task:        任务字典（包含 rooms 列表、tier 等）
#   task_center: 任务中心坐标（瓦片坐标）
#   direction:   房间链延伸方向（指向相邻任务的平均方向）
#   rng:         随机数生成器
#
# 返回：Array of RoomInstance — 生成的房间链
# ============================================================
func generate_chain_for_task(task: Dictionary, task_center: Vector2, direction: Vector2, rng: RandomNumberGenerator) -> Array:
	var chain = []
	var rooms = task.get("rooms", [])
	var room_count = rooms.size()
	if room_count == 0:
		return chain

	for i in range(room_count):
		var room_def = rooms[i]
		var role = room_def.get("role", "middle")

		# 按层级确定房间半径
		var tier = task.get("tier", 1)
		var radius_min = 9
		var radius_max = 11
		if tier == 0:
			radius_min = 6
			radius_max = 8
		elif tier == 2:
			radius_min = 12
			radius_max = 14
		var radius = radius_min + rng.randi() % (radius_max - radius_min + 1)

		# 房间间距 = 半径 × 1.2（略大于半径，房间间有小间隙）
		var spacing = radius * 1.2

		# 沿方向偏移：房间围绕 task_center 对称分布
		# i=0（entrance）在最前方，i=room_count-1（exit）在最后方
		var offset = (i - (room_count - 1) / 2.0) * spacing

		# 垂直方向偏移（±40% 半径）
		# 使房间链呈蛇形而非直线，更自然
		var perp_offset = 0.0
		var perp_offset_max = radius * 0.4
		if rng:
			perp_offset = rng.randf_range(-perp_offset_max, perp_offset_max)
		else:
			perp_offset = randf_range(-perp_offset_max, perp_offset_max)

		# 垂直方向 = 旋转 90° 的方向向量
		var perp_dir = Vector2(-direction.y, direction.x)

		# 计算房间中心：任务中心 + 方向偏移 + 垂直偏移
		var room_center = task_center + direction * offset + perp_dir * perp_offset

		# 创建房间实例
		var room = RoomInstance.new(task.id, role, {}, room_center, radius)

		# 生成不规则 blob 瓦片
		# irregularity=0.65: 形状不规则度（0=圆形，1=高度不规则）
		# branch_chance=0.9: 90% 概率生成分支
		# max_branches=5: 最多 5 个分支
		room.tiles = _generate_blob_tiles(room_center.x, room_center.y, radius, rng, 0.65, 0.9, 5)

		chain.append(room)

	return chain


# ============================================================
# 在指定位置生成 blob 瓦片（公开接口）
#
# 参数与 _generate_blob_tiles 相同
# 供 map_generator._place_room_no_overlap 调用（缩小房间时重新生成）
# ============================================================
func generate_blob_tiles_at(cx: float, cy: float, base_radius: int, rng: RandomNumberGenerator, irregularity: float = 0.5, branch_chance: float = 0.8, max_branches: int = 3) -> Array:
	return _generate_blob_tiles(cx, cy, base_radius, rng, irregularity, branch_chance, max_branches)


# ============================================================
# 核心：生成不规则 blob 瓦片（多种子 + 分支算法）
#
# 算法流程：
#   1. 生成 7-12 个种子（带噪声的圆形区域）
#      - 每个种子有随机位置、半径和相位
#      - 种子叠加形成主体形状
#   2. 生成 3-4 个分支（椭圆形树枝）
#      - 每个分支有起始位置、长度、宽度和弯曲角度
#      - 分支从主体向外延伸，带弯曲
#   3. 计算覆盖范围（max_reach / max_branch_extent）
#      确定需要检测的瓦片区域
#   4. 对每个瓦片检测：
#      - 是否在任一种子的噪声圆内（_is_in_noisy_circle）
#      - 是否在任一分支的椭圆内（_is_in_branch）
#   5. BFS 保留最大连通分量（_keep_largest_connected_component）
#      移除因噪声产生的孤立碎片
#
# 参数：
#   cx, cy:        房间中心坐标（瓦片坐标，浮点）
#   base_radius:   基础半径（瓦片单位）
#   rng:           随机数生成器
#   irregularity:  不规则度（0-1，当前未直接使用，种子噪声固定）
#   branch_chance: 生成分支的概率（0-1）
#   max_branches:  最大分支数量
#
# 返回：Array of {x: int, y: int} — 房间占据的所有瓦片
# ============================================================
func _generate_blob_tiles(cx: float, cy: float, base_radius: int, rng: RandomNumberGenerator, irregularity: float = 0.5, branch_chance: float = 0.8, max_branches: int = 3) -> Array:
	var tiles = []

	# --- 步骤 1：生成种子（7-12 个）---
	# 种子是带噪声的圆形，叠加后形成不规则主体
	var num_seeds = 7 + rng.randi() % 6
	var seeds = []
	for s in range(num_seeds):
		# 种子角度：随机方向
		var angle = rng.randf() * TAU
		# 种子偏移：0.8-1.1 倍基础半径（确保覆盖整个房间）
		var max_offset = base_radius * (0.8 + rng.randf() * 0.3)
		var offset = rng.randf() * max_offset
		var sx = cos(angle) * offset
		var sy = sin(angle) * offset
		# 种子半径：0.3-1.1 倍基础半径（大小不一的种子）
		var sr = base_radius * (0.3 + rng.randf() * 0.8)
		# 种子相位：用于噪声计算（使每个种子形状不同）
		seeds.append({x = sx, y = sy, r = sr, seed = rng.randf() * 1000.0})

	# --- 步骤 2：生成分支（3-4 个，带概率）---
	var branches = []
	var num_branches = 0
	# branch_chance 概率下生成分支（默认 0.9 = 90%）
	if rng.randf() < branch_chance:
		num_branches = 3 + rng.randi() % (max_branches + 1)
	for b in range(num_branches):
		var b_angle = rng.randf() * TAU                    # 分支方向（随机角度）
		var b_start_offset = base_radius * (0.3 + rng.randf() * 0.6)  # 起始偏移（从主体向外）
		var b_len = base_radius * (0.7 + rng.randf() * 0.8)           # 分支长度
		var b_width = base_radius * (0.25 + rng.randf() * 0.45)       # 分支宽度
		var bend_angle = b_angle + deg_to_rad(30.0 + rng.randf() * 60.0)  # 弯曲角度（30-90°偏转）
		var bend_ratio = 0.4 + rng.randf() * 0.4                       # 弯曲点位置（40-80% 长度）
		branches.append({
			angle = b_angle,
			length = b_len,
			width = b_width,
			start_offset = b_start_offset,
			bend_angle = bend_angle,
			bend_ratio = bend_ratio,
		})

	# --- 步骤 3：计算覆盖范围 ---
	# 种子最大延伸距离
	var max_reach = 0.0
	for seed in seeds:
		var reach = sqrt(seed.x * seed.x + seed.y * seed.y) + seed.r * 1.25
		if reach > max_reach:
			max_reach = reach
	# 分支最大延伸距离
	var max_branch_extent = 0.0
	for br in branches:
		var ext = br.start_offset + br.length * (1.0 + br.bend_ratio) + br.width
		if ext > max_branch_extent:
			max_branch_extent = ext
	# 取最大值 + 2 瓦片缓冲
	var max_r = max(max_reach + 2.0, max_branch_extent + 2.0)
	var r_int = int(ceil(max_r))

	# --- 步骤 4：逐瓦片检测 ---
	for dy in range(-r_int, r_int + 1):
		for dx in range(-r_int, r_int + 1):
			var inside = false

			# 检测种子（带噪声的圆形）
			for seed in seeds:
				var sdx = dx - seed.x
				var sdy = dy - seed.y
				var sdist = sqrt(sdx * sdx + sdy * sdy)
				# 快速排除：距离超过 1.4 倍半径的不可能在圆内
				if sdist > seed.r * 1.4:
					continue
				if _is_in_noisy_circle(sdx, sdy, seed.r, seed.seed):
					inside = true
					break

			# 检测分支（椭圆形）
			if not inside:
				for br in branches:
					if _is_in_branch(dx, dy, br):
						inside = true
						break

			if inside:
				tiles.append({x = int(cx) + dx, y = int(cy) + dy})

	# --- 步骤 5：保留最大连通分量 ---
	# 噪声可能产生孤立碎片，BFS 只保留最大连通区域
	tiles = _keep_largest_connected_component(tiles)
	return tiles


# ============================================================
# 保留最大连通分量
#
# 算法：多源 BFS
#   1. 构建瓦片哈希表（O(1) 查找）
#   2. 对每个未访问的瓦片执行 BFS，找到其连通分量
#   3. 记录最大的连通分量
#   4. 返回最大连通分量的所有瓦片
#
# 为什么需要此步骤？
#   噪声圆形算法会随机产生远离主体的孤立瓦片群，
#   这些碎片会导致房间断开，影响地图质量。
#   只保留最大连通分量可确保房间是单一连通区域。
#
# 时间复杂度：O(T)，T = 瓦片数量
# ============================================================
func _keep_largest_connected_component(tiles: Array) -> Array:
	if tiles.size() < 2:
		return tiles

	# 构建哈希表
	var tile_map = {}
	for tile in tiles:
		var key = str(tile.x) + "," + str(tile.y)
		tile_map[key] = tile

	var visited = {}
	var largest_component = []

	# 4 邻域方向（上下左右）
	var dirs = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	# 对每个未访问的瓦片执行 BFS
	for start_key in tile_map.keys():
		if visited.has(start_key):
			continue

		var queue = [start_key]
		visited[start_key] = true
		var component = []

		# BFS 遍历整个连通分量
		while !queue.is_empty():
			var current_key = queue.pop_back()
			component.append(tile_map[current_key])

			var parts = current_key.split(",")
			var cx_val = int(parts[0])
			var cy_val = int(parts[1])

			# 检查 4 个邻居
			for d in dirs:
				var nx = cx_val + d.x
				var ny = cy_val + d.y
				var nkey = str(nx) + "," + str(ny)
				if tile_map.has(nkey) and not visited.has(nkey):
					visited[nkey] = true
					queue.push_back(nkey)

		# 保留最大的连通分量
		if component.size() > largest_component.size():
			largest_component = component

	return largest_component


# ============================================================
# 检测点是否在噪声圆内
#
# 原理：用三组不同频率的正弦/余弦噪声调制有效半径
#   effective_r = radius × (1 + n1 + n2 + n3)
#   n1: 3 倍角频率，幅度 0.11（大尺度起伏）
#   n2: 5 倍角频率，幅度 0.07（中尺度细节）
#   n3: 7 倍角频率，幅度 0.04（小尺度纹理）
#
# 效果：圆形边界变得不规则，呈有机Blob形状
#       不同 seed 值产生不同形状（相位不同）
#
# 参数：
#   dx, dy: 相对于种子中心的坐标（浮点）
#   radius: 种子基础半径
#   seed:   相位种子（0-1000），决定噪声相位
#
# 返回：bool — 点是否在噪声圆内
# ============================================================
func _is_in_noisy_circle(dx: float, dy: float, radius: float, seed: float) -> bool:
	var dist = sqrt(dx * dx + dy * dy)
	# 快速排除/包含
	if dist > radius * 1.3 or dist < 0.001:
		return dist < radius * 1.3

	# 计算角度和噪声调制
	var angle = atan2(dy, dx)
	var n1 = sin(angle * 3.0 + seed) * 0.11
	var n2 = cos(angle * 5.0 + seed * 1.7) * 0.07
	var n3 = sin(angle * 7.0 + seed * 2.3) * 0.04
	var effective_r = radius * (1.0 + n1 + n2 + n3)
	return dist <= effective_r


# ============================================================
# 检测点是否在分支内
#
# 分支由两个椭圆段组成（模拟弯曲的树枝）：
#   1. 第一段：从起点沿 angle 方向，长度 bend_ratio × b_len
#      位于 (cos(b_angle)*b_start, sin(b_angle)*b_start)
#   2. 第二段：继续沿 bend_angle 方向，长度 (1-bend_ratio) × b_len
#      弯曲点位于 (cos(b_angle)*(b_start+b_len), sin(b_angle)*(b_start+b_len))
#
# 每段都是椭圆形（长轴 = length，短轴 = width）
#
# 参数：
#   dx, dy: 相对于房间中心的坐标
#   br:     分支配置字典
#
# 返回：bool — 点是否在分支内
# ============================================================
func _is_in_branch(dx: float, dy: float, br: Dictionary) -> bool:
	var b_angle = br.angle
	var b_len = br.length
	var b_width = br.width
	var b_start = br.start_offset
	var bend_angle = br.bend_angle
	var bend_ratio = br.bend_ratio

	# 第一段起点：分支从主体边缘向外延伸
	var sx1 = cos(b_angle) * b_start
	var sy1 = sin(b_angle) * b_start
	# 第二段起点（弯曲点）：沿原方向走 b_start + b_len
	var mid_x = cos(b_angle) * (b_start + b_len)
	var mid_y = sin(b_angle) * (b_start + b_len)

	# 检测第一段
	if _is_point_in_ellipse(dx, dy, sx1, sy1, b_angle, b_len, b_width):
		return true

	# 检测第二段（弯曲部分）
	var b_len2 = b_len * bend_ratio
	if b_len2 < 0.5:
		return false
	return _is_point_in_ellipse(dx, dy, mid_x, mid_y, bend_angle, b_len2, b_width)


# ============================================================
# 检测点是否在椭圆内
#
# 算法：坐标旋转 + 归一化
#   1. 把点平移到椭圆中心坐标系
#   2. 旋转到椭圆主轴方向
#   3. 计算归一化坐标 (along/a)² + (perp/b)² ≤ 1
#      其中 a = 长半轴 = len/2, b = 短半轴 = width/2
#
# 参数：
#   dx, dy: 待测点坐标（相对于房间中心）
#   cx, cy: 椭圆中心坐标
#   angle:  椭圆长轴方向角度（弧度）
#   len:    椭圆长轴长度
#   width:  椭圆短轴长度
#
# 返回：bool — 点是否在椭圆内
# ============================================================
func _is_point_in_ellipse(dx: float, dy: float, cx: float, cy: float, angle: float, len: float, width: float) -> bool:
	# 平移到椭圆中心
	var rel_x = dx - cx
	var rel_y = dy - cy
	# 旋转到椭圆主轴方向
	# along: 沿长轴方向的投影
	# perp: 沿短轴方向的投影
	var along = rel_x * cos(angle) + rel_y * sin(angle)
	var perp = -rel_x * sin(angle) + rel_y * cos(angle)
	# 半轴长度
	var a = len / 2.0
	var b = width / 2.0
	if a < 0.5 or b < 0.5:
		return false
	# 归一化检测：(along/a)² + (perp/b)² ≤ 1
	var ndx = along / a
	var ndy = perp / b
	return ndx * ndx + ndy * ndy <= 1.0


# ============================================================
# 计算房间链延伸方向
#
# 原理：计算指向所有相邻任务的平均方向
#   1. 遍历 TASK_LINKS 中与当前任务相连的链接
#   2. 计算每个邻居相对于当前任务的方向向量
#   3. 求平均方向并归一化
#   4. 若平均方向与径向方向（远离地图中心）相反，则翻转
#      这样房间链总是向外延伸，不会朝地图中心
#
# 参数：
#   task_id:        当前任务 ID
#   task_links:     TASK_LINKS 数组
#   task_positions: 各任务的瓦片坐标
#
# 返回：Vector2 — 单位方向向量
# ============================================================
func compute_chain_direction(task_id: String, task_links: Array, task_positions: Dictionary) -> Vector2:
	if not task_positions.has(task_id):
		return Vector2(1, 0)

	var my_pos = task_positions[task_id]

	# 累加所有邻居方向
	var sum_dir = Vector2.ZERO
	var neighbor_count = 0
	for link in task_links:
		var neighbor_id = ""
		if link.from == task_id:
			neighbor_id = link.to
		elif link.to == task_id:
			neighbor_id = link.from
		else:
			continue

		if not task_positions.has(neighbor_id):
			continue

		var neighbor_pos = task_positions[neighbor_id]
		var dir_to_neighbor = neighbor_pos - my_pos
		sum_dir += dir_to_neighbor
		neighbor_count += 1

	# 无邻居时默认向右
	if neighbor_count == 0 or sum_dir.length() < 0.001:
		return Vector2(1, 0)

	var avg_dir = sum_dir / neighbor_count
	if avg_dir.length() < 0.001:
		return Vector2(1, 0)

	# 径向方向（远离地图中心）
	var radial_dir = my_pos.normalized()
	# 若平均方向指向地图中心（与径向相反），翻转
	# 这是因为有时布局可能导致邻居在中心方向
	if avg_dir.dot(radial_dir) < 0:
		avg_dir = -avg_dir

	return avg_dir.normalized()


# ============================================================
# 获取房间链的入口房间
# 房间链第一个元素是 entrance（入口）
# ============================================================
func get_entrance(chain: Array) -> RoomInstance:
	if chain.is_empty():
		return null
	return chain[0]


# ============================================================
# 获取房间链的出口房间
# 房间链最后一个元素是 exit（出口）
# ============================================================
func get_exit(chain: Array) -> RoomInstance:
	if chain.is_empty():
		return null
	return chain[chain.size() - 1]
