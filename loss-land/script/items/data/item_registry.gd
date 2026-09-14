# script/items/data/item_registry.gd
# ============================================
# 物品注册表 - 管理所有物品数据
#
# 什么是注册表模式？
# 注册表是一个集中存储和管理数据的模式
# 所有物品数据都注册到这里，方便查找和使用
#
# 为什么需要注册表？
# 1. 统一管理所有物品数据
# 2. 通过ID快速查找物品
# 3. 避免重复创建物品数据
# ============================================

class_name ItemRegistry
extends Resource

# ============================================
# 导出变量
# ============================================

# 所有物品数据列表
# 在编辑器中添加所有物品的 .tres 文件
@export var items: Array[ItemData] = []

# ============================================
# 私有变量
# ============================================

# 物品缓存字典
# 键: item_id (StringName)
# 值: ItemData
# 用于快速查找物品数据
var _item_cache: Dictionary = {}

# 单例引用
# 全局访问点，避免到处传递注册表
static var _instance: ItemRegistry

# ============================================
# 生命周期函数
# ============================================

func _init() -> void:
	# 构建缓存
	_build_cache()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 获取物品数据函数
# 通过物品ID查找物品数据
#
# 参数：item_id - 物品ID，如 &"grass"
# 返回：ItemData 对象，找不到则返回 null
# ----------------------------------------
func get_item(item_id: StringName) -> ItemData:
	# 如果缓存中有，直接返回
	if _item_cache.has(item_id):
		return _item_cache[item_id]

	# 缓存中没有，尝试在列表中查找
	for item in items:
		if item.item_id == item_id:
			_item_cache[item_id] = item
			return item

	# 找不到
	return null

# ----------------------------------------
# 获取所有物品函数
# 返回所有注册的物品数据
# ----------------------------------------
func get_all_items() -> Array[ItemData]:
	return items.duplicate()

# ----------------------------------------
# 按类型获取物品函数
# 返回指定类型的所有物品
#
# 参数：type - 物品类型
# 返回：该类型的物品数组
# ----------------------------------------
func get_items_by_type(type: ItemData.ItemType) -> Array[ItemData]:
	var result: Array[ItemData] = []
	for item in items:
		if item.item_type == type:
			result.append(item)
	return result

# ----------------------------------------
# 注册物品函数
# 动态添加新物品到注册表
#
# 参数：item - 要添加的物品数据
# ----------------------------------------
func register_item(item: ItemData) -> void:
	if item and not _item_cache.has(item.item_id):
		items.append(item)
		_item_cache[item.item_id] = item

# ----------------------------------------
# 重建缓存函数
# 当物品列表改变时调用
# ----------------------------------------
func rebuild_cache() -> void:
	_item_cache.clear()
	_build_cache()

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 构建缓存函数
# 从物品列表构建缓存字典
# ----------------------------------------
func _build_cache() -> void:
	for item in items:
		if item and item.item_id:
			_item_cache[item.item_id] = item

# ============================================
# 静态方法（全局访问）
# ============================================

# ----------------------------------------
# 获取单例函数
# 返回全局物品注册表实例
#
# 首次访问时自动从磁盘加载注册表资源（懒加载），
# 不依赖 autoload 或场景初始化顺序——headless 测试、
# 掉落物、采集实体在任何时刻取用都能拿到数据。
#
# 使用方法：
#   var registry = ItemRegistry.get_registry()
#   var grass = registry.get_item(&"grass")
# ----------------------------------------
static func get_registry() -> ItemRegistry:
	if _instance == null:
		var registry_resource: Resource = load("res://script/items/data/item_registry.tres")
		if registry_resource is ItemRegistry:
			_instance = registry_resource
			_instance._build_cache()
	return _instance

# ----------------------------------------
# 设置单例函数
# 在游戏初始化时调用
# ----------------------------------------
static func set_registry(registry: ItemRegistry) -> void:
	_instance = registry
	if _instance:
		_instance._build_cache()
