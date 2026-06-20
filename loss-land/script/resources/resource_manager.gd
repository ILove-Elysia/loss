# script/resources/resource_manager.gd
# ============================================
# 资源管理器 - 整个资源系统的核心控制器
#
# 这个脚本负责：
# 1. 初始化所有资源系统组件
# 2. 生成和管理游戏中的所有资源
# 3. 处理存档和读档
# 4. 提供全局访问接口
#
# 为什么需要管理器？
# 就像餐厅需要一个经理来协调：
# - 厨师（生成器）做什么菜
# - 服务员（交互）怎么上菜
# - 仓库（对象池）管理食材
# - 记账（存档）记录收支
# ============================================

class_name ResourceManager
extends Node

# ============================================
# 导出变量（在编辑器中配置）
# ============================================

# 资源注册表（拖入 resource_registry.tres）
# 注册表包含了所有资源的数据配置和预制体
@export var resource_registry: ResourceRegistry

# 资源生成器（拖入资源生成器节点）
@export var spawner: ResourceSpawner

# 资源容器（场景节点，用于存放所有生成的资源）
# 建议在场景中创建一个空的 Node3D 作为容器
@export var resource_container: Node3D

# ============================================
# 私有变量
# ============================================

# 对象池字典
# { "grass": ResourcePool, "tree": ResourcePool }
var _pools: Dictionary = {}

# 所有活跃资源实体列表
var _entities: Array[ResourceEntity] = []

# 存档数据处理
var _save_data: ResourceSaveData = ResourceSaveData.new()

# 生成的位置记录（避免重叠）
var _spawned_positions: Array[Vector3] = []

# ============================================
# 信号（通知其他节点）
# ============================================

# 资源生成完成信号
signal resources_spawned(count: int)

# 资源被采集信号
signal resource_harvested(entity: ResourceEntity, harvester: Node)

# ============================================
# 生命周期函数
# ============================================

# ----------------------------------------
# _ready() - 节点就绪时调用
# 相当于初始化函数
# ----------------------------------------
func _ready() -> void:
	# 初始化对象池
	_initialize_pools()
	
	# 如果注册表中有资源数据，生成初始资源
	if resource_registry:
		spawn_initial_resources()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 生成初始资源函数
# 在游戏开始时生成所有资源
# ----------------------------------------
func spawn_initial_resources() -> void:
	# 检查生成器是否有效
	if not spawner:
		print("错误：ResourceSpawner 未配置！")
		return
	
	# 清空已有位置记录
	_spawned_positions.clear()
	
	# 遍历注册表中的所有资源数据
	for data in resource_registry.get_all_resource_data():
		# 生成该资源的位置
		var positions = spawner.generate_positions(
			data,
			data.initial_count,
			_spawned_positions
		)
		
		# 在每个位置生成资源实体
		for pos in positions:
			spawn_resource(data.resource_id, pos)

# ----------------------------------------
# 生成单个资源函数
# 在指定位置生成指定类型的资源
#
# 参数：
#   resource_id - 资源ID（如 "grass", "tree"）
#   position - 生成位置（Vector3）
#   state - 初始状态（可选，默认生长中）
# 返回：生成的资源实体
# ----------------------------------------
func spawn_resource(resource_id: StringName, position: Vector3, state: ResourceState.State = ResourceState.State.GROWING) -> ResourceEntity:
	# 获取资源数据
	var data = resource_registry.get_resource_data(resource_id)
	if not data:
		print("错误：找不到资源数据 ", resource_id)
		return null
	
	# 获取或创建对象池
	var pool = _get_or_create_pool(resource_id, data)
	
	# 检查对象池是否有效
	if not pool:
		print("错误：找不到资源预制体 ", resource_id, "，请在 resource_registry.tres 中配置")
		return null
	
	# 从池中获取对象
	var entity = pool.acquire(data, position, state)
	
	# 如果成功获取到实体
	if entity:
		# 添加到场景中
		resource_container.add_child(entity)
		
		# 添加到活跃列表
		_entities.append(entity)
		
		# 连接信号
		_connect_entity_signals(entity)
	
	return entity

# ----------------------------------------
# 采集资源函数
# 触发资源的采集行为
#
# 参数：
#   entity - 要采集的资源实体
#   harvester - 采集者（通常是玩家）
# ----------------------------------------
func harvest_resource(entity: ResourceEntity, harvester: Node) -> void:
	# 检查实体是否有效且可以采集
	if is_instance_valid(entity) and entity.can_harvest():
		entity.harvest(harvester)

# ----------------------------------------
# 挖掘资源函数
# 使用铲子挖掘资源
# ----------------------------------------
func dig_resource(entity: ResourceEntity, digger: Node) -> void:
	if is_instance_valid(entity) and entity.can_dig():
		entity.dig(digger)

# ----------------------------------------
# 种植资源函数
# 在指定位置种植资源
#
# 参数：
#   resource_id - 要种植的资源ID
#   position - 种植位置
#   planter - 种植者
# 返回：是否种植成功
# ----------------------------------------
func plant_resource(resource_id: StringName, position: Vector3, planter: Node) -> bool:
	# 获取资源数据
	var data = resource_registry.get_resource_data(resource_id)
	if not data:
		return false
	
	# 检查是否可以种植
	if not data.can_plant:
		return false
	
	# 检查位置是否有效
	if not spawner._is_valid_position(position, data, _spawned_positions):
		return false
	
	# 生成资源
	var entity = spawn_resource(resource_id, position)
	
	# 如果生成成功，从种植者背包扣除种子
	if entity:
		# 通知种植成功（需要背包系统配合）
		print(planter.name, " 种植了 ", data.display_name)
		return true
	
	return false

# ----------------------------------------
# 保存游戏函数
# 将所有资源状态保存到存档
# ----------------------------------------
func save_game() -> Dictionary:
	return _save_data.save_all(_entities)

# ----------------------------------------
# 加载游戏函数
# 从存档恢复所有资源状态
# ----------------------------------------
func load_game(data: Dictionary) -> void:
	# 清除当前所有资源
	clear_all_resources()
	
	# 加载存档数据
	_save_data.load_all(data, self)

# ----------------------------------------
# 清除所有资源函数
# 移除场景中所有资源实体
# ----------------------------------------
func clear_all_resources() -> void:
	# 释放所有活跃实体到对象池
	for entity in _entities:
		if is_instance_valid(entity):
			var resource_id = str(entity.resource_data.resource_id)
			if _pools.has(resource_id):
				_pools[resource_id].release(entity)
	
	# 清空列表
	_entities.clear()
	_spawned_positions.clear()

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 初始化对象池函数
# 为每种资源类型创建一个对象池
# ----------------------------------------
func _initialize_pools() -> void:
	if not resource_registry:
		return
	
	# 遍历所有资源数据
	for data in resource_registry.get_all_resource_data():
		# 获取预制体场景
		var scene = resource_registry.get_resource_scene(data.resource_id)
		if scene:
			# 创建对象池
			var pool = ResourcePool.new()
			pool.initialize(scene, data)
			_pools[str(data.resource_id)] = pool

# ----------------------------------------
# 获取或创建对象池函数
# 如果池不存在则创建新池
# ----------------------------------------
func _get_or_create_pool(resource_id: StringName, data: ResourceData) -> ResourcePool:
	var key = str(resource_id)
	
	# 如果池已存在，直接返回
	if _pools.has(key):
		return _pools[key]
	
	# 如果池不存在，创建新池
	var scene = resource_registry.get_resource_scene(resource_id)
	if scene:
		var pool = ResourcePool.new()
		pool.initialize(scene, data)
		_pools[key] = pool
		return pool
	
	return null

# ----------------------------------------
# 连接实体信号函数
# 将实体的信号连接到管理器
# ----------------------------------------
func _connect_entity_signals(entity: ResourceEntity) -> void:
	# 连接采集完成信号
	entity.harvested.connect(func(harvester):
		_on_entity_harvested(entity, harvester)
	)
	
	# 连接状态改变信号
	entity.state_changed.connect(func(new_state):
		_on_entity_state_changed(entity, new_state)
	)

# ----------------------------------------
# 实体采集完成处理函数
# ----------------------------------------
func _on_entity_harvested(entity: ResourceEntity, harvester: Node) -> void:
	# 发射信号通知其他节点
	resource_harvested.emit(entity, harvester)
	
	print(entity.resource_data.display_name, " 被采集了")

# ----------------------------------------
# 实体状态改变处理函数
# ----------------------------------------
func _on_entity_state_changed(entity: ResourceEntity, new_state: ResourceState.State) -> void:
	# 可以在这里添加状态改变的额外逻辑
	# 例如：记录统计数据、触发事件等
	pass
