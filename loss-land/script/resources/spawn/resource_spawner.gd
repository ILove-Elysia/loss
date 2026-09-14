# script/resources/spawn/resource_spawner.gd
# ============================================
# 资源生成器 - 负责在地图上生成资源
#
# 这个组件负责：
# 1. 在地图上生成资源的位置
# 2. 确保资源分布自然（不聚集、避开障碍物）
# 3. 提供批量生成功能
#
# 什么是 AABB？
# AABB = Axis-Aligned Bounding Box（轴对齐包围盒）
# 是一个立方体区域，用起点和终点定义
# 用于定义资源可以生成的范围
#
# 什么是射线检测？
# 从一点向另一点发射"射线"
# 如果射线碰到东西，说明那个方向有障碍物
# ============================================

class_name ResourceSpawner
extends Node3D

# ============================================
# 导出变量
# ============================================

# 生成区域（3D包围盒）
# 资源只会在这个区域内生成（海洋位置会被陆地判断过滤掉）
@export var spawn_area: AABB = AABB(Vector3(-90, 0, -90), Vector3(180, 10, 180))

# 是否让生成区域自动覆盖整张程序化地图
#
# 地图尺寸是运行时由 map_generator_3d 决定的（TILE_SIZE × MAP_WIDTH），
# 硬编码的 spawn_area 会在地图调整后失效——资源只挤在地图中心一小块。
# 开启后，_ready 会按地图世界尺寸重写 spawn_area 的 XZ 范围（Y 保持不变）。
@export var auto_fit_map: bool = true

# 障碍物物理层列表
# 射线检测时使用的层
# 注意：layer2 是"地面"（地图生成器的地板碰撞体），不应视为障碍物，
# 否则资源会因射线命中地板而全部生成失败。
@export var obstacle_layers: Array[int] = [4]

# 水体物理层列表
@export var water_layers: Array[int] = [8]

# ============================================
# 私有变量
# ============================================

# 随机数生成器
# 使用专门的生成器可以获得可预测的随机序列
# （如果需要可重复性）
var _random: RandomNumberGenerator = RandomNumberGenerator.new()

# 地图生成器引用（惰性获取，通过 "map_gen" 组查找）
# 用于判断生成位置是否为可通行陆地
var _map_gen: Node = null

# 是否已经根据地图世界尺寸自适应过生成区
var _fitted: bool = false

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 生成位置函数（核心方法）
# 生成指定数量的随机位置
#
# 参数：
#   data - 资源数据配置
#   count - 要生成的数量
#   existing_positions - 已有位置（避免重叠）
# 返回：生成的位置数组
#
# 算法（两条路径）：
#   1. 首选「按区域地形精确采样」：资源在 task_system.REGION_RESOURCE_MAP
#      里登记了允许区域，直接去这些地形（草原/丛林/矿区/火山/雪地/沙滩）
#      的瓦片池里取点，候选点必然落在目标区域内。
#   2. 回退「全图撒点 + 事后过滤」：地图未就绪或资源未登记区域时使用。
#      这条路径存在一个天然缺陷——地图约八成是海，而资源往往只属于一两个
#      区域，绝大多数候选会被否决；像"煤炭只长在火山区"这种小范围资源，
#      尝试次数耗尽后数量会严重不足（实测配置 2400 个只生成出约 2070 个）。
# ----------------------------------------
func generate_positions(data: ResourceData, count: int, existing_positions: Array[Vector3] = []) -> Array[Vector3]:
	_ensure_fitted()

	# 路径 1：按区域地形精确采样
	var terrains: Array = _allowed_terrain_types(data)
	if not terrains.is_empty():
		var by_terrain: Array[Vector3] = _generate_positions_in_terrains(
			data, count, terrains, existing_positions)
		if not by_terrain.is_empty():
			return by_terrain

	# 路径 2：回退到全图撒点
	return _generate_positions_random(data, count, existing_positions)


# ----------------------------------------
# 查询某资源允许生成在哪些地形（空数组 = 不限区域）
# 数据来源：task_system.REGION_RESOURCE_MAP（地图生成器转发）
# 返回 untyped Array：跨对象动态调用返回 Variant，标注 Array[int]
# 会多一道类型转换检查，这里以稳健为先。
# ----------------------------------------
func _allowed_terrain_types(data: ResourceData) -> Array:
	var map_gen: Node = _get_map_gen()
	if map_gen == null or not map_gen.has_method("get_resource_terrain_types"):
		return []
	return map_gen.get_resource_terrain_types(data.resource_id)


# ----------------------------------------
# 在指定地形的瓦片池里均匀采样（路径 1）
#
# 与 _generate_positions_random 的区别：候选点一定落在目标区域内，
# 不需要"海洋判定"和"区域判定"两道过滤，命中率极高。
# 仍然保留两项必要检查：
#   - 障碍物射线检测（避免资源生在岩石/建筑里）
#   - 与已有资源的间距（data.min_distance）
#
# 抽取方式按各区域瓦片数量加权：面积大的区域自然分到更多资源，
# 跨区域资源（如小石块同时属于 5 个区域）因此分布均匀。
# ----------------------------------------
func _generate_positions_in_terrains(data: ResourceData, count: int, terrains: Array, existing: Array[Vector3]) -> Array[Vector3]:
	var map_gen: Node = _get_map_gen()
	if map_gen == null or not map_gen.has_method("get_terrain_tile_count"):
		return []

	# 先统计各区域瓦片数（同时作为加权抽样的权重）
	var pool_sizes: Array[int] = []
	var total_tiles: int = 0
	for terrain in terrains:
		var n: int = int(map_gen.get_terrain_tile_count(terrain))
		pool_sizes.append(n)
		total_tiles += n
	if total_tiles <= 0:
		return []   # 地图未就绪或这些地形不存在

	var positions: Array[Vector3] = []
	var attempts: int = 0
	# 只需查障碍与间距（不再过滤地形），命中率高，尝试上限不必给太大：
	# count × 20 足以应对间距冲突较密的大资源（如树的 min_distance = 5 米）。
	var max_attempts: int = count * 20

	while positions.size() < count and attempts < max_attempts:
		attempts += 1

		# 按瓦片数量加权挑选地形
		var pick: int = _random.randi_range(0, total_tiles - 1)
		var terrain: int = terrains[0]
		for i in pool_sizes.size():
			if pick < pool_sizes[i]:
				terrain = terrains[i]
				break
			pick -= pool_sizes[i]

		var n2: int = int(map_gen.get_terrain_tile_count(terrain))
		if n2 <= 0:
			continue

		# 在该地形的瓦片池里随机取一格
		var pos: Vector3 = map_gen.get_terrain_tile_position(
			terrain, _random.randi_range(0, n2 - 1))

		# 障碍物检查（射线）
		if _is_in_obstacle(pos):
			continue

		# 间距检查（最贵，放最后）
		var too_close: bool = false
		for other in existing:
			if pos.distance_to(other) < data.min_distance:
				too_close = true
				break
		if too_close:
			continue

		positions.append(pos)
		existing.append(pos)

	return positions


# ----------------------------------------
# 全图撒点（路径 2，回退用）
# 在生成区域内随机撒点，靠 _is_valid_position 逐项过滤
# ----------------------------------------
func _generate_positions_random(data: ResourceData, count: int, existing_positions: Array[Vector3]) -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var attempts = 0
	# 最大尝试次数（防止无限循环）
	var max_attempts = count * 10

	# 循环直到生成足够数量或尝试次数用尽
	while positions.size() < count and attempts < max_attempts:
		attempts += 1

		# 生成随机位置
		var pos = _generate_random_position()

		# 检查位置是否有效
		if _is_valid_position(pos, data, existing_positions):
			positions.append(pos)
			existing_positions.append(pos)

	return positions

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 生成随机位置函数
# 在生成区域内生成一个随机点
# ----------------------------------------
func _generate_random_position() -> Vector3:
	# spawn_area.position 是包围盒起点
	# spawn_area.end 是包围盒终点
	# X/Z 在平面内随机；Y 固定为包围盒底部（地面 y=0），避免资源浮空
	return Vector3(
		_random.randf_range(spawn_area.position.x, spawn_area.end.x),
		spawn_area.position.y,
		_random.randf_range(spawn_area.position.z, spawn_area.end.z)
	)

# ----------------------------------------
# 检查位置有效性函数
# 验证位置是否适合生成资源
#
# 检查项目（按执行顺序，全部满足才有效）：
# 1. 是否在陆地（海洋没有碰撞体，故查地图数据而非射线）
# 2. 所在生物群系是否产出该资源（实现资源按区域分布）
# 3. 是否在障碍物上（射线检测）
# 4. 与其他资源的距离是否足够
#
# 顺序刻意从"最便宜且否决最多"排到"最贵"，理由见函数内注释。
# ----------------------------------------
func _is_valid_position(pos: Vector3, data: ResourceData, existing: Array[Vector3]) -> bool:
	# 判定顺序按「否决率 × 开销」排列：
	# 先用最便宜且否决最多的地形/群系检查砍掉绝大多数候选（地图约 78% 是海洋），
	# 最后才做 O(n) 的间距检查——否则高数量资源（500 个 × 5000 次尝试）
	# 会退化到上千万次距离计算，导致启动明显卡顿。
	# 这些条件都是"必须全部满足"的必要条件，调换顺序不影响结果。

	# 检查1：是否位于可通行陆地（通过地图生成器查询，非海洋）
	# 地图的海洋（terrain=7）没有碰撞体，无法用射线检测，
	# 因此改用地形数据查询，保证资源不会生成到海洋上。
	if not _is_on_land(pos):
		return false

	# 检查2：所在生物群系（区域）是否产出该资源
	# 实现资源按区域分布：草原长草、丛林长树、矿区/火山出石。
	# 海洋 / 沙滩 / 道路不属于任何群系，也会在这里被否决。
	if not _is_resource_allowed_in_biome(pos, data):
		return false

	# 检查3：是否在障碍物上（射线检测真正的遮挡物）
	if _is_in_obstacle(pos):
		return false

	# 检查4：与其他资源的距离（最贵，放最后）
	# distance_to 计算两点之间的距离
	for other_pos in existing:
		if pos.distance_to(other_pos) < data.min_distance:
			return false  # 距离太近，无效

	# 所有检查通过，位置有效
	return true

# ----------------------------------------
# 判断位置是否位于可通行陆地
# 通过 "map_gen" 组查找地图生成器并调用 is_land_world()
# 无地图生成器时默认放行（保持向后兼容）
# ----------------------------------------
func _is_on_land(pos: Vector3) -> bool:
	var map_gen = _get_map_gen()
	if map_gen and map_gen.has_method("is_land_world"):
		return map_gen.is_land_world(pos)
	return true

# ----------------------------------------
# 判断该位置的生物群系是否产出指定资源
#
# 依据 task_system.REGION_RESOURCE_MAP 的"区域 → 资源"映射表，
# 实现资源按区域分布：草原长草、丛林长树、矿区/火山出石、雪地出树。
# 代价是随机撒点需要更多次尝试才能凑够数量
# （generate_positions 的 attempts 上限为 count * 10）。
# 地图生成器不可用时放行，保持向后兼容。
# ----------------------------------------
func _is_resource_allowed_in_biome(pos: Vector3, data: ResourceData) -> bool:
	var map_gen = _get_map_gen()
	if map_gen and map_gen.has_method("is_resource_allowed_at"):
		return map_gen.is_resource_allowed_at(pos, data.resource_id)
	return true

# ----------------------------------------
# 惰性获取地图生成器引用
# 地图生成器（map_generator_3d.gd）加入 "map_gen" 组
# 首次调用时查找一次并缓存，后续直接复用
# ----------------------------------------
func _get_map_gen() -> Node:
	if _map_gen == null or not is_instance_valid(_map_gen):
		var gens: Array = get_tree().get_nodes_in_group("map_gen")
		if not gens.is_empty():
			_map_gen = gens[0]
	return _map_gen

# ----------------------------------------
# 应用自适应生成区（按地图世界尺寸重写 spawn_area 的 XZ 范围）
# 地图运行时生成、尺寸由 TILE_SIZE × MAP_WIDTH 决定，硬编码范围会在地图
# 调整后失效（资源挤在中心一小块）。开启 auto_fit_map 时调用。
# Y 范围（高度）保持不变，仅水平方向铺满整张地图（留 5% 余量）。
# ----------------------------------------
func _ensure_fitted() -> void:
	if not auto_fit_map or _fitted:
		return
	# 地图生成器尚未就绪时不要锁死，留到下次调用再试；
	# 否则会误把"未适配"当成"已适配"，资源永远挤在默认的 ±90 小方块里。
	var map_gen: Node = _get_map_gen()
	if map_gen == null or not map_gen.has_method("get_world_size"):
		return
	_auto_fit_spawn_area()
	_fitted = true

func _auto_fit_spawn_area() -> void:
	var map_gen: Node = _get_map_gen()
	if map_gen == null or not map_gen.has_method("get_world_size"):
		return
	var world_size: Vector2 = map_gen.get_world_size()
	var half_x: float = world_size.x / 2.0
	var half_z: float = world_size.y / 2.0
	var margin: float = 0.95   # 留 5% 余量，避免资源贴到地图最边缘
	var hx: float = half_x * margin
	var hz: float = half_z * margin
	spawn_area = AABB(
		Vector3(-hx, spawn_area.position.y, -hz),
		Vector3(hx * 2.0, spawn_area.size.y, hz * 2.0)
	)

# ----------------------------------------
# 检查是否在障碍物中函数
# 使用射线检测
# ----------------------------------------
func _is_in_obstacle(pos: Vector3) -> bool:
	# 获取物理空间状态
	# direct_space_state 允许直接查询物理世界
	var space_state = get_world_3d().direct_space_state
	
	# 创建射线查询参数
	var query = PhysicsRayQueryParameters3D.create(
		pos + Vector3.UP,   # 起点（位置上方）
		pos + Vector3.DOWN   # 终点（位置下方）
	)
	
	# 设置检测的碰撞层
	query.collision_mask = _layers_to_mask(obstacle_layers)
	
	# 执行射线检测
	# 如果有碰撞，result 会有数据
	# 如果没有碰撞，result 是空的
	var result = space_state.intersect_ray(query)
	
	# is_empty() 检查字典是否为空
	return not result.is_empty()

# ----------------------------------------
# 检查是否在水中函数
# ----------------------------------------
func _is_in_water(pos: Vector3) -> bool:
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		pos + Vector3.UP,
		pos + Vector3.DOWN
	)
	query.collision_mask = _layers_to_mask(water_layers)
	var result = space_state.intersect_ray(query)
	return not result.is_empty()

# ----------------------------------------
# 层数转掩码函数
#
# 什么是位掩码？
# 物理层使用位运算来表示多层
# 第1层 = 1 << 0 = 1
# 第2层 = 1 << 1 = 2
# 第3层 = 1 << 2 = 4
# 第4层 = 1 << 3 = 8
# ...以此类推
#
# 例如：
#   层 [2, 4] 的掩码 = 2 | 8 = 10
#   二进制：1010
#   表示第2层和第4层
# ----------------------------------------
func _layers_to_mask(layers: Array[int]) -> int:
	var mask = 0
	for layer in layers:
		# |= 是位或赋值
		# 1 << (layer - 1) 将1左移 layer-1 位
		mask |= (1 << (layer - 1))
	return mask
