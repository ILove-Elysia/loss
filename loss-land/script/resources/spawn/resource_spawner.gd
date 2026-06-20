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
# 资源只会在这个区域内生成
@export var spawn_area: AABB = AABB(Vector3.ZERO, Vector3(100, 10, 100))

# 障碍物物理层列表
# 射线检测时使用的层
@export var obstacle_layers: Array[int] = [2, 4]

# 水体物理层列表
@export var water_layers: Array[int] = [8]

# ============================================
# 私有变量
# ============================================

# 随机数生成器
# 使用专门的生成器可以获得可预测的随机序列
# （如果需要可重复性）
var _random: RandomNumberGenerator = RandomNumberGenerator.new()

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
# 算法：
# 1. 尝试生成随机位置
# 2. 检查位置是否有效
# 3. 重复直到生成足够数量或尝试次数用尽
# ----------------------------------------
func generate_positions(data: ResourceData, count: int, existing_positions: Array[Vector3] = []) -> Array[Vector3]:
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
	# randf_range 生成指定范围内的随机浮点数
	return Vector3(
		_random.randf_range(spawn_area.position.x, spawn_area.end.x),
		_random.randf_range(spawn_area.position.y, spawn_area.end.y),
		_random.randf_range(spawn_area.position.z, spawn_area.end.z)
	)

# ----------------------------------------
# 检查位置有效性函数
# 验证位置是否适合生成资源
#
# 检查项目：
# 1. 与其他资源的距离是否足够
# 2. 是否在障碍物上
# 3. 是否在水中
# ----------------------------------------
func _is_valid_position(pos: Vector3, data: ResourceData, existing: Array[Vector3]) -> bool:
	# 检查1：与其他资源的距离
	# distance_to 计算两点之间的距离
	for other_pos in existing:
		if pos.distance_to(other_pos) < data.min_distance:
			return false  # 距离太近，无效
	
	# 检查2：是否在障碍物上
	if _is_in_obstacle(pos):
		return false
	
	# 检查3：是否在水中
	if _is_in_water(pos):
		return false
	
	# 所有检查通过，位置有效
	return true

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
