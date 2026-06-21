# script/resources/data/resource_registry.gd
# ============================================
# 资源注册表 - 存储所有资源类型的定义
#
# 什么是注册表模式？
# 注册表就像一个电话簿，通过名字查找信息
# 我们通过 resource_id 来查找对应的资源配置和预制体
#
# 什么是 Dictionary？
# Dictionary 是 Godot 的键值对数据结构
# 类似其他语言的 Map 或 HashMap
# 示例：{ "grass": data1, "tree": data2 }
# ============================================

class_name ResourceRegistry
extends Resource

# ============================================
# 导出变量
# 在编辑器中可以拖拽设置这些引用
# ============================================

# 所有资源数据配置的列表
# 在编辑器中，将 grass_data.tres、tree_data.tres 等拖入此数组
@export var resource_datas: Array[ResourceData] = []

# 资源预制体字典
# 键是资源ID（StringName），值是预制体场景（PackedScene）
# 示例：
#   &"grass" -> grass_entity.tscn
#   &"tree"  -> tree_entity.tscn
@export var resource_scenes: Dictionary[StringName, PackedScene] = {}

# ============================================
# 私有变量
# ============================================

# 数据缓存字典，用于快速查找
# 从 resource_datas 数组构建，提高查询速度
var _data_cache: Dictionary = {}

# ============================================
# 生命周期函数
# ============================================

# _init() 是 Godot 的构造函数
# 当创建这个类的实例时自动调用
func _init() -> void:
	_build_cache()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 获取资源数据函数
# 通过ID查找资源数据配置
#
# 参数：resource_id - 资源ID，如 &"grass"
# 返回：ResourceData 对象，找不到则返回 null
#
# 示例：
#   var grass_config = registry.get_resource_data(&"grass")
# ----------------------------------------
func get_resource_data(resource_id: StringName) -> ResourceData:
	# 如果缓存为空，构建缓存
	if _data_cache.is_empty():
		_build_cache()
	
	# get() 是安全获取字典值的方法
	# 如果键不存在，返回第二个参数（默认值）
	return _data_cache.get(resource_id)

# ----------------------------------------
# 获取资源预制体函数
# 通过ID查找预制体场景
#
# 参数：resource_id - 资源ID，如 &"grass"
# 返回：PackedScene 对象（预制体），找不到则返回 null
# ----------------------------------------
func get_resource_scene(resource_id: StringName) -> PackedScene:
	return resource_scenes.get(resource_id)

# ----------------------------------------
# 获取所有资源数据函数
# 返回资源数据列表的副本
#
# 返回：所有资源数据的数组
# ----------------------------------------
func get_all_resource_data() -> Array[ResourceData]:
	return resource_datas.duplicate()

# ----------------------------------------
# 注册资源函数
# 添加新的资源类型到注册表
#
# 参数：
#   data - 资源数据配置对象
#   scene - 预制体场景（可选）
#
# 示例：
#   registry.register_resource(grass_data, grass_scene)
# ----------------------------------------
func register_resource(data: ResourceData, scene: PackedScene = null) -> void:
	# 添加到数据列表（如果不存在）
	if data not in resource_datas:
		resource_datas.append(data)
	
	# 添加预制体到字典（如果提供了）
	if scene:
		resource_scenes[data.resource_id] = scene
	
	# 更新缓存
	_data_cache[data.resource_id] = data

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 构建缓存函数
# 将列表转换为字典，提高查找速度
#
# 为什么需要缓存？
# 每次调用 get_resource_data 时遍历数组是 O(n) 复杂度
# 用字典查询只需要 O(1) 复杂度
# ----------------------------------------
func _build_cache() -> void:
	_data_cache.clear()
	
	for data in resource_datas:
		# 检查数据是否有效
		# data.resource_id 确保 ID 存在
		if data and data.resource_id:
			# 以 resource_id 为键，存入字典
			_data_cache[data.resource_id] = data
