# ============================================================
# 布局系统（中心辐射式布局）
#
# 核心架构：两阶段坐标生成
#   第一阶段 generate_concentric_positions()
#     按任务 tier 把节点分布到同心环上，使用【相对半径】(10/50/110)，
#     只生成"相对坐标"，不考虑地图实际尺寸。
#   第二阶段 normalize_to_tile_coords()
#     把相对坐标映射到【绝对瓦片坐标】，使用【绝对半径】(0 / 0.45*rx / 1.0*rx)，
#     确保各层房间不重叠（计算过间距安全）。
#
# 关键设计决策（曾是 bug）：
#   initial_angle 字段：力导向布局后节点位置会"漂移"，
#   导致用 node.position.angle() 算出的角度不稳定。
#   解决方案：在 generate_concentric_positions 时保存 initial_angle，
#   normalize_to_tile_coords 使用 initial_angle 而非运行时计算的角度。
# ============================================================
extends RefCounted

# ------------------------------------------------------------
# 力导向布局物理参数
# ------------------------------------------------------------

# 弹簧力常数：连接节点间的"吸引力"强度
# 公式：force = (distance - SPRING_FORCE) * 0.3
# 距离 > 100 时吸引，< 100 时排斥，使连接节点间距趋于 100
const SPRING_FORCE = 100.0

# 库仑斥力常数：非连接节点间的"排斥力"强度
# 公式：force = -CHARGE_FORCE / distance²
# 平方反比，距离越近斥力越强，防止节点挤在一起
const CHARGE_FORCE = 8000.0

# 阻尼系数：每轮迭代后速度衰减比例（0.85 保留 85% 速度）
# 防止节点永远震荡不收敛
const DAMPING_FORCE = 0.85

# 最大迭代次数：力导向布局的最大循环轮数
# 用于 force_directed_layout 的默认值，layout_tasks 调用时用 30
const MAX_ITERATIONS = 250

# 动能阈值：所有节点的速度平方和低于此值时认为已收敛
# 低于此值时提前结束迭代，不必跑满 MAX_ITERATIONS
const KINETIC_THRESHOLD = 0.008


# ============================================================
# 布局节点类（代表一个任务的逻辑节点）
# ============================================================
class LayoutNode:
	# 节点唯一 ID，对应 task_system 中的 task.id（如 "Grassland"）
	var id: String = ""

	# 节点当前位置（第一阶段的相对坐标，力导向布局后可能漂移）
	var position: Vector2 = Vector2.ZERO

	# 【关键】节点的初始生成角度（力导向布局前保存）
	# 用途：normalize_to_tile_coords 用这个角度做瓦片坐标映射
	# 为什么需要：力导向布局后 position.angle() 会不稳定，
	# 导致外圈节点被错误放到内圈位置（曾是 Marsh 塌陷的 bug）
	var initial_angle: float = 0.0

	# 节点当前速度（力导向布局每轮计算，用于更新位置）
	var velocity: Vector2 = Vector2.ZERO

	# 节点关联的任务数据（完整的 task 字典，包含 tier/terrain_type 等）
	var data: Dictionary = {}

	# 与该节点相连的所有 LayoutEdge 列表
	var edges: Array = []

	# 是否为锚点（不可移动）
	# 草原区（出生点）是锚点，固定在地图中心
	var is_anchored: bool = false

	# 构造函数：创建节点并设置初始属性
	func _init(node_id: String, pos: Vector2, node_data: Dictionary = {}):
		id = node_id
		position = pos
		data = node_data
		edges = []

	# 添加一条连接边到 edges 列表（去重，已存在则跳过）
	func add_edge(edge):
		if not edges.has(edge):
			edges.append(edge)

	# 检查是否与另一个节点有直接连接
	# 遍历所有边，看对方节点是否是 n1 或 n2
	func is_connected_to(other):
		for edge in edges:
			if edge.node1 == other or edge.node2 == other:
				return true
		return false


# ============================================================
# 布局边类（代表两个任务节点的连接关系）
# ============================================================
class LayoutEdge:
	# 边连接的两个节点（顺序无意义，边是无向的）
	var node1: LayoutNode = null
	var node2: LayoutNode = null

	# 构造函数：创建边并自动注册到两个节点的 edges 列表
	func _init(n1: LayoutNode, n2: LayoutNode):
		node1 = n1
		node2 = n2
		# 双向注册：两个节点都持有这条边
		node1.add_edge(self)
		node2.add_edge(self)


# ============================================================
# 第一阶段：生成同心环初始位置（相对坐标）
#
# 按任务 tier 分层布局：
#   Tier 0（内圈/安全）: 草原区 → 半径 10（中心锚点不受此值影响）
#   Tier 1（中圈/中危）: 丛林/矿区/沙地 → 半径 50
#   Tier 2（外圈/高危）: 火山/雪地 → 半径 110
#
# 每层用极坐标分布（角度均匀 + 抖动），形成同心结构
# 同时保存 initial_angle 供后续归一化使用
#
# 参数：
#   tier_nodes:   { tier_id: [node, ...] } 各层的节点数组
#   tier_radii:   { tier_id: radius } 各层的目标半径（相对值）
#   rng:          随机数生成器（可选，不提供时用全局随机）
#   tier_offsets: { tier_id: angle_offset } 各层的角度偏移（防止径向对齐）
# ============================================================
func generate_concentric_positions(
	tier_nodes: Dictionary,
	tier_radii: Dictionary,
	rng: RandomNumberGenerator = null,
	tier_offsets: Dictionary = {}
) -> void:
	# 遍历每个层级
	for tier_id in tier_nodes.keys():
		var nodes = tier_nodes[tier_id]
		var base_radius = tier_radii.get(tier_id, 0.0)
		var node_count = nodes.size()

		if node_count == 0:
			continue

		# 计算该层节点的角度间隔（360° / 节点数）
		var angle_step = TAU / float(max(node_count, 1))

		# 获取该层的角度偏移（默认 0）
		# 设计：Tier 2 偏移 30° (TAU/12)，
		# 使外圈节点位于中圈节点的间隙方向，避免径向重叠
		var tier_offset = tier_offsets.get(tier_id, 0.0)

		for i in range(node_count):
			var node = nodes[i]

			# 基础角度：均匀分布 + 层级偏移
			var base_angle = angle_step * float(i) + tier_offset

			# 角度抖动（±25% 间隔）：使分布不完全对称
			var angle_jitter = 0.0
			if rng:
				angle_jitter = rng.randf_range(-angle_step * 0.25, angle_step * 0.25)
			else:
				angle_jitter = randf_range(-angle_step * 0.25, angle_step * 0.25)

			var final_angle = base_angle + angle_jitter

			# 半径抖动（±10%）：使环不完全规整，更自然
			var radius_jitter = 0.0
			if rng:
				radius_jitter = rng.randf_range(-base_radius * 0.1, base_radius * 0.1)
			else:
				radius_jitter = randf_range(-base_radius * 0.1, base_radius * 0.1)

			# 最小半径 5.0，防止抖动后出现负值或过小
			var final_radius = max(base_radius + radius_jitter, 5.0)

			# 极坐标 → 笛卡尔坐标
			# cos(angle)*radius = X, sin(angle)*radius = Y
			node.position = Vector2(
				cos(final_angle) * final_radius,
				sin(final_angle) * final_radius
			)

			# 【关键】保存初始角度，供 normalize_to_tile_coords 使用
			# 此时角度稳定（还没受力导向影响），后续不会变
			node.initial_angle = final_angle


# ============================================================
# 力导向布局微调
# 在同心布局基础上做少量力导向微调（30 次迭代），使节点分布更自然
#
# 算法：弹簧力（吸引）+ 库仑力（排斥）+ 阻尼（稳定）
#   - 连接节点：弹簧力，距离趋于 SPRING_FORCE (100)
#   - 非连接节点：库仑斥力，距离越近斥力越强
#   - 每轮后阻尼 0.85，防止震荡
#
# 为什么只用 30 次？
#   默认 MAX_ITERATIONS=250 次会完全破坏同心结构，
#   30 次是微调节：只做小幅度调整，保留同心分层特征
#
# 参数：
#   nodes:       所有节点数组
#   anchored_ids: 锚点 ID 列表（当前未使用，锚点由 is_anchored 控制）
#   max_iter:    最大迭代次数（-1 用默认 MAX_ITERATIONS）
# ============================================================
func force_directed_layout(nodes: Array, anchored_ids: Array = [], max_iter: int = -1) -> Array:
	var total_kinetic_energy = 1000.0  # 初始动能，保证至少执行一轮
	var iteration = 0
	var effective_max_iter = max_iter if max_iter > 0 else MAX_ITERATIONS

	# 主循环：直到动能低于阈值 或 达到最大迭代次数
	while total_kinetic_energy > KINETIC_THRESHOLD and iteration < effective_max_iter:
		total_kinetic_energy = 0.0

		# 第一阶段：计算每个节点受到的合力
		for node in nodes:
			node.velocity = Vector2.ZERO
			if node.is_anchored:
				continue  # 锚点不动

			for other_node in nodes:
				if node == other_node:
					continue

				var delta = other_node.position - node.position
				var distance = delta.length()

				# 距离下限 10.0，防止除零或力过大
				if distance < 10.0:
					distance = 10.0

				var force = 0.0

				# 弹簧力：连接节点间的吸引力
				if node.is_connected_to(other_node):
					force = (distance - SPRING_FORCE) * 0.3
				# 库仑力：非连接节点间的排斥力
				else:
					force = -(CHARGE_FORCE / (distance * distance))

				# 沿力方向更新速度
				node.velocity += delta.normalized() * force

		# 第二阶段：应用阻尼 + 限速 + 更新位置
		for node in nodes:
			if node.is_anchored:
				continue

			# 阻尼衰减速度
			node.velocity *= DAMPING_FORCE

			# 限速：速度超过 25 时截断，防止节点飞出去
			if node.velocity.length() > 25.0:
				node.velocity = node.velocity.normalized() * 25.0

			# 位置更新
			node.position += node.velocity
			# 累加动能（用于判断收敛）
			total_kinetic_energy += node.velocity.length_squared()

		iteration += 1

	return nodes


# ============================================================
# 根据任务链接拓扑创建边
# 遍历 task_links，用 node_map 查找对应的 LayoutNode，创建 LayoutEdge
#
# 参数：
#   nodes:       所有节点数组
#   task_links:  TASK_LINKS 数组（来自 task_system）
#   node_map:    { task_id: LayoutNode } 快速查找表
#
# 返回：创建的 LayoutEdge 数组
# ============================================================
func connect_nodes_by_links(nodes: Array, task_links: Array, node_map: Dictionary) -> Array:
	var edges = []
	for link in task_links:
		if not node_map.has(link.from):
			continue  # 源任务节点不存在，跳过
		if not node_map.has(link.to):
			continue  # 目标任务节点不存在，跳过
		var n1 = node_map[link.from]
		var n2 = node_map[link.to]
		var edge = LayoutEdge.new(n1, n2)
		edges.append(edge)
	return edges


# ============================================================
# 任务节点布局主入口
#
# 核心流程：
# 1. 创建节点（标记锚点：草原区为锚点）
# 2. 按 tier 字段分组节点（0/1/2 三层）
# 3. 为每层计算目标半径和角度偏移
#    - 相对半径：Tier 0=10, Tier 1=50, Tier 2=110
#    - 角度偏移：Tier 2 偏移 30° 避免径向对齐
# 4. generate_concentric_positions 生成同心布局（相对坐标）
# 5. connect_nodes_by_links 按 TASK_LINKS 建边
# 6. force_directed_layout 微调 30 次（保留同心结构）
#
# 返回：[nodes, edges] — 节点数组和边数组
# 注意：返回的节点位置是相对坐标，需要 normalize_to_tile_coords 转换
# ============================================================
func layout_tasks(tasks: Array, task_links: Array, rng: RandomNumberGenerator = null) -> Array:
	var nodes = []
	var node_map = {}

	# 步骤 1：创建节点
	for i in range(tasks.size()):
		var task = tasks[i]
		var is_start = task.get("is_start", false)
		var initial_pos = Vector2.ZERO
		var node = LayoutNode.new(task.id, initial_pos, task)
		node.is_anchored = is_start  # 草原区（is_start=true）为锚点
		nodes.append(node)
		node_map[task.id] = node

	# 步骤 2：按 tier 分组
	var tier_nodes: Dictionary = {}
	for node in nodes:
		var task_data = node.data
		var tier = task_data.get("tier", 1)
		if not tier_nodes.has(tier):
			tier_nodes[tier] = []
		tier_nodes[tier].append(node)

	# 步骤 3：各层相对半径（第一阶段使用，不是瓦片坐标）
	# 设计比例：内圈≈0、中圈≈50、外圈≈110
	# 保证各层房间不重叠：外圈半径 110 >> 中圈 50 >> 内圈 10
	var tier_radii: Dictionary = {
		0: 10.0,    # 内圈：草原区（锚点位置不受此值影响）
		1: 50.0,    # 中圈：丛林/矿区/沙地
		2: 110.0,   # 外圈：火山/雪地
	}

	# 角度偏移：防止不同层级节点径向对齐
	# Tier 0/1 不偏移（0°），Tier 2 偏移 30°（TAU/12）
	# 效果：外圈节点位于中圈节点的间隙方向，避免径向重叠
	var tier_offsets = {
		0: 0.0,
		1: 0.0,
		2: TAU / 12.0,  # 30° 偏移
	}

	# 步骤 4：生成同心布局（相对坐标）
	generate_concentric_positions(tier_nodes, tier_radii, rng, tier_offsets)

	# 步骤 5：按 TASK_LINKS 建边
	var edges = connect_nodes_by_links(nodes, task_links, node_map)

	# 步骤 6：力导向微调（仅 30 次迭代，保留同心结构）
	force_directed_layout(nodes, [], 30)

	return [nodes, edges]


# ============================================================
# 第二阶段：归一化到瓦片坐标（绝对坐标）
#
# 把第一阶段的相对坐标映射到地图瓦片坐标
# 关键改进：按 tier 绝对半径定位，而非全局最大距离归一化
#
# 各层绝对半径（瓦片单位）：
#   Tier 0: 0           （中心锚点，直接用地图中心）
#   Tier 1: target_rx * 0.45 ≈ 27 瓦片（中圈）
#   Tier 2: target_rx * 1.0  ≈ 60 瓦片（外圈）
#
# 间距验证（确保不重叠）：
#   中圈 27 + 房间12 ≤ 外圈 60 - 房间14 → 39 ≤ 46 ✓
#   外圈 60 + 房间14 + 沙滩10 + 缓冲4 = 88 < 岛屿半径限制
#
# 使用 initial_angle（而非运行时计算的角度）：
#   这是修复 Marsh 塌陷 bug 的关键，确保外圈节点始终在外圈
#
# 参数：
#   nodes:     第一阶段输出的节点数组
#   center:    地图中心瓦片坐标（如 Vector2(200, 200)）
#   target_rx: X 方向目标半径（瓦片单位，如 60）
#   target_ry: Y 方向目标半径（瓦片单位，如 55）
#   rng:       随机数生成器（用于添加 ±5% 随机拉伸）
#
# 返回：{ task_id: Vector2(tile_x, tile_y) } 各任务的瓦片坐标
# ============================================================
func normalize_to_tile_coords(nodes: Array, center: Vector2, target_rx: float, target_ry: float, rng: RandomNumberGenerator = null) -> Dictionary:
	var result = {}

	# 各层绝对半径（瓦片单位），与 tier_radii（相对半径）不同
	var tier_target_radius = {
		0: 0.0,                       # 内圈：锚点，直接用中心
		1: target_rx * 0.45,          # 中圈：~27 瓦片
		2: target_rx * 1.0,           # 外圈：~60 瓦片
	}

	# 全局随机拉伸因子（±5%），增加地图间的差异
	var stretch = 1.0
	if rng:
		stretch = rng.randf_range(0.95, 1.05)
	else:
		stretch = randf_range(0.95, 1.05)

	for node in nodes:
		# 锚点直接放在地图中心
		if node.is_anchored:
			result[node.id] = center
			continue

		var tier = node.data.get("tier", 1)
		# 获取该层的目标半径 × 拉伸因子
		var target_r = tier_target_radius.get(tier, target_rx * 0.5) * stretch

		# 使用 initial_angle（力导向布局前保存的稳定角度）
		# 而非 node.position.angle()（力导向后可能不稳定）
		var angle = node.initial_angle

		# X/Y 方向使用不同半径，形成椭圆形分布
		# 保持 target_rx : target_ry 的比例
		var rx = target_r
		var ry = target_r * (target_ry / target_rx)

		# 极坐标 → 瓦片坐标
		var tile_x = center.x + cos(angle) * rx
		var tile_y = center.y + sin(angle) * ry
		result[node.id] = Vector2(tile_x, tile_y)

	return result
