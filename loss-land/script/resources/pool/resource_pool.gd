# script/resources/pool/resource_pool.gd
# ============================================
# 对象池 - 优化资源实体的创建和销毁
#
# 什么是对象池？
# 对象池是一种设计模式，通过复用已创建的对象来提高性能
#
# 为什么需要对象池？
# 想象你开餐厅：
# - 没有对象池：每来一个顾客，就招聘一个新厨师
#   顾客走了就解雇厨师 → 频繁招聘和解雇很耗时
# - 有对象池：先雇5个厨师，顾客来了用现有的
#   顾客走了不解雇，放回"待命池" → 高效利用
#
# 在游戏中的问题：
# - 草被采集后删除，下次需要时重新创建
# - 频繁创建/销毁对象会造成性能问题（内存碎片、GC延迟）
#
# 使用对象池后：
# - 草被采集 → 放入池中，不销毁
# - 需要新草 → 从池中取，如果有的话
# - 池中没有足够的 → 创建新的
# ============================================

class_name ResourcePool
extends Node

# ============================================
# 导出变量
# ============================================

# 池的最大容量
# 当池中对象超过这个数量，新对象会被直接销毁
@export var max_pool_size: int = 100

# 预加载数量
# 游戏启动时预先创建的对象数量
# 避免游戏运行时突然创建造成卡顿
@export var preload_count: int = 10

# ============================================
# 私有变量
# ============================================

# 空闲对象池
# 字典结构：{ "grass": [entity1, entity2], "tree": [entity3] }
# 键是资源ID，值是可复用对象的数组
var _inactive_pool: Dictionary = {}

# 活跃对象列表
# 正在游戏中使用的对象
var _active_entities: Array[ResourceEntity] = []

# 资源预制体场景
var _entity_scene: PackedScene

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 初始化函数
# 设置预制体并预加载对象
#
# 参数：
#   scene - 资源实体的预制体场景
#   data - 资源数据配置
# ----------------------------------------
func initialize(scene: PackedScene, data: ResourceData) -> void:
	_entity_scene = scene
	# 预加载一些对象
	_preload_entities(data, preload_count)

# ----------------------------------------
# 获取对象函数（核心方法）
# 从池中获取一个可用的资源实体
#
# 参数：
#   data - 资源数据配置
#   position - 放置位置
#   state - 初始状态
#   container - 实体要挂到的父节点（通常是资源容器）
# 返回：资源实体实例
#
# 流程：
# 1. 先尝试从池中获取
# 2. 池中没有，创建新的
# 3. 先挂进场景树，再设置位置和状态
# 4. 添加到活跃列表
#
# 为什么必须先入树再设置：
#   global_position 与 set_state() → 状态机 → 可视化组件都会读节点的
#   全局变换，节点不在树里时 Godot 会报
#   "Condition !is_inside_tree() is true. Returning: Transform3D()"。
#   此前是"先进池、后入树"，于是每生成一个资源就刷两条报错——
#   读档要恢复 2000+ 个资源，一次读档能刷出上千条错误日志。
# ----------------------------------------
func acquire(data: ResourceData, position: Vector3, state: ResourceState.State = ResourceState.State.GROWING, container: Node = null) -> ResourceEntity:
	# 1. 尝试从池中获取
	var entity = _get_from_pool(data)
	
	# 2. 如果池中没有，创建新的
	if not entity:
		entity = _create_new_entity(data)
	
	# 3. 如果成功获取到实体
	if entity:
		# 3.1 先入树（池里的对象在 release 时已 remove_child，没有父节点）
		if container != null and entity.get_parent() == null:
			container.add_child(entity)
		# 3.2 设置位置：强制贴地，避免资源悬浮在半空
		entity.global_position = Vector3(position.x, 0.0, position.z)
		# 3.3 设置状态
		entity.set_state(state)
		# 3.4 添加到活跃列表
		_active_entities.append(entity)
	
	return entity

# ----------------------------------------
# 释放对象函数
# 将对象归还到池中
#
# 参数：entity - 要释放的资源实体
#
# 流程：
# 1. 从活跃列表移除
# 2. 如果池未满，放回池中
# 3. 如果池已满，直接销毁
# ----------------------------------------
func release(entity: ResourceEntity) -> void:
	# 从活跃列表中移除
	if entity in _active_entities:
		_active_entities.erase(entity)

	# 复位（2026-09-12 视野流式加载）：
	# 实体是被反复复用的——卸载一棵树、同一节点可能立刻被拿去表示一块石头。
	# 必须先把上一世的遗留（隐藏的网格、还在跑的再生计时器、钉住标记）清干净。
	if entity.has_method("reset_for_pool"):
		entity.call("reset_for_pool")

	# 获取资源ID
	var resource_id = str(entity.resource_data.resource_id) if entity.resource_data != null else ""
	
	# 确保池中有这个资源类型的列表
	if not _inactive_pool.has(resource_id):
		_inactive_pool[resource_id] = []
	
	var pool = _inactive_pool[resource_id]
	
	# 如果池没满，放回池中复用
	if pool.size() < max_pool_size:
		# 从父节点移除（但不销毁）
		# 没有父节点 = 已经被移除过（重复 release），此时直接入池即可
		var parent := entity.get_parent()
		if parent != null:
			parent.remove_child(entity)
		pool.append(entity)
	else:
		# 池满了，直接销毁
		entity.queue_free()

# ----------------------------------------
# 获取所有活跃对象函数
# 返回活跃列表的副本
# ----------------------------------------
func get_all_active() -> Array[ResourceEntity]:
	return _active_entities.duplicate()

# ----------------------------------------
# 清空所有对象函数
# 清除池中所有对象
# 通常在切换场景或游戏结束时调用
# ----------------------------------------
func clear_all() -> void:
	# 销毁所有活跃对象
	for entity in _active_entities:
		entity.queue_free()
	_active_entities.clear()
	
	# 销毁池中所有空闲对象
	for pool in _inactive_pool.values():
		for entity in pool:
			entity.queue_free()
	_inactive_pool.clear()

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 预加载对象函数
# 提前创建一些对象放入池中
# ----------------------------------------
func _preload_entities(data: ResourceData, count: int) -> void:
	var resource_id = str(data.resource_id)
	
	# 确保池中有这个类型的列表
	if not _inactive_pool.has(resource_id):
		_inactive_pool[resource_id] = []
	
	# 创建指定数量的对象
	for i in count:
		var entity = _create_new_entity(data)
		if entity:
			_inactive_pool[resource_id].append(entity)

# ----------------------------------------
# 从池中获取对象函数
# ----------------------------------------
func _get_from_pool(data: ResourceData) -> ResourceEntity:
	var resource_id = str(data.resource_id)
	
	# 检查池中是否有这个类型的对象
	if _inactive_pool.has(resource_id):
		# 检查列表是否非空
		if not _inactive_pool[resource_id].is_empty():
			# pop_back() 取出并移除最后一个元素
			return _inactive_pool[resource_id].pop_back()
	
	return null

# ----------------------------------------
# 创建新对象函数
# ----------------------------------------
func _create_new_entity(data: ResourceData) -> ResourceEntity:
	# 如果没有预制体场景，返回空
	if not _entity_scene:
		return null
	
	# 实例化预制体
	# instantiate() 从 PackedScene 创建节点实例
	var entity = _entity_scene.instantiate() as ResourceEntity
	
	# 设置资源数据
	if entity:
		entity.resource_data = data
	
	return entity
