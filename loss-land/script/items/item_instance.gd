# script/items/item_instance.gd
# ============================================
# 物品实例类 - 运行时的物品对象
#
# 什么是物品实例？
# 物品实例是物品在游戏运行时的具体表现
# 它包含物品数据引用和当前数量
#
# 为什么需要物品实例？
# ItemData 是"模板"，定义物品的属性
# ItemInstance 是"实例"，表示玩家拥有的具体物品
#
# 例如：
# - ItemData: 草（定义了草的图标、名称、最大堆叠数等）
# - ItemInstance: 50个草（玩家背包中实际拥有的草）
# ============================================

class_name ItemInstance
extends RefCounted

# ============================================
# 信号
# ============================================

# 数量改变信号
signal quantity_changed(new_quantity: int)

# ============================================
# 属性
# ============================================

# 物品数据引用
# 指向物品的模板数据
var data: ItemData:
	set(value):
		data = value
		# 数据改变时，检查数量是否超过最大堆叠
		_clamp_quantity()
		# 携带电量的核心物品（动力核心等）在这里挂上它自己的核心状态实例。
		# 放在 setter 里而不是各个调用点，是为了让**所有**入口（制作产出、
		# 掉落、测试箱、拾取、读档）都自动带上 —— 不再可能出现"空壳核心"。
		_sync_core()

# 核心物品的独立状态：电量 + 自身温度值。
#
# 只有 data.carries_power == true 的物品才有它，其余物品恒为 null。
# 它跟着本实例在 背包 ↔ 装备槽 ↔ 掉落物 之间流转，**引用不变**，
# 所以电量与温度值天然连续 —— 拆下重装不会回满（这是引入它的直接原因）。
var core: PowerCoreInstance = null

# 数量后备字段
# 重要：quantity 的 setter 内部绝不能再对 quantity 赋值，
# 否则 setter → _clamp → setter 无限递归（栈溢出）。
# _clamp_quantity 只写 _quantity，绕开 setter。
var _quantity: int = 1

# 物品数量
# 当前这个实例中有多少个该物品
var quantity: int = 1:
	set(value):
		var old_quantity = _quantity
		_quantity = _clamped(value)
		# 如果数量真的改变了，发出信号
		if _quantity != old_quantity:
			quantity_changed.emit(_quantity)
	get:
		return _quantity

# ============================================
# 构造函数
# ============================================

# ----------------------------------------
# 初始化函数
# 创建物品实例
#
# 参数：
#   item_data - 物品数据
#   count - 数量（默认1）
# ----------------------------------------
func _init(item_data: ItemData = null, count: int = 1) -> void:
	data = item_data
	quantity = count

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 是否可以堆叠函数
# 检查这个物品是否可以堆叠
# ----------------------------------------
func is_stackable() -> bool:
	return data and data.stackable

# ----------------------------------------
# 是否已满函数
# 检查是否已达到最大堆叠数量
# ----------------------------------------
func is_full() -> bool:
	if not data:
		return true
	return quantity >= data.max_stack

# ----------------------------------------
# 获取剩余空间函数
# 返回还能堆叠多少个
# ----------------------------------------
func get_remaining_space() -> int:
	if not data:
		return 0
	return data.max_stack - quantity

# ----------------------------------------
# 添加数量函数
# 向实例中添加物品
#
# 参数：count - 要添加的数量
# 返回：实际添加的数量
# ----------------------------------------
func add(count: int) -> int:
	if not data or count <= 0:
		return 0

	# 计算能添加多少
	var can_add = mini(count, get_remaining_space())
	quantity += can_add
	return can_add

# ----------------------------------------
# 移除数量函数
# 从实例中移除物品
#
# 参数：count - 要移除的数量
# 返回：实际移除的数量
# ----------------------------------------
func remove(count: int) -> int:
	if not data or count <= 0:
		return 0

	# 计算能移除多少
	var can_remove = mini(count, quantity)
	quantity -= can_remove
	return can_remove

# ----------------------------------------
# 分割函数
# 将一部分物品分割成新实例
#
# 参数：count - 要分割的数量
# 返回：新的物品实例
# ----------------------------------------
func split(count: int) -> ItemInstance:
	if count <= 0 or count >= quantity:
		return null

	# 创建新实例
	var new_instance = ItemInstance.new(data, count)
	if core != null:
		new_instance.core = core.duplicate_core()
	# 从当前实例移除
	quantity -= count
	return new_instance

# ----------------------------------------
# 合并函数
# 尝试将另一个实例合并到这个实例
#
# 参数：other - 要合并的物品实例
# 返回：是否完全合并成功
# ----------------------------------------
func merge(other: ItemInstance) -> bool:
	# 检查是否可以合并
	if not can_merge_with(other):
		return false

	# 计算能合并多少
	var can_add = mini(other.quantity, get_remaining_space())
	quantity += can_add
	other.quantity -= can_add

	# 如果完全合并，返回 true
	return other.quantity == 0

# ----------------------------------------
# 是否可以合并函数
# 检查两个实例是否可以合并
#
# 参数：other - 另一个物品实例
# 返回：是否可以合并
# ----------------------------------------
func can_merge_with(other: ItemInstance) -> bool:
	# 检查是否是同一种物品
	if not data or not other.data:
		return false
	if data.item_id != other.data.item_id:
		return false
	# 检查是否可以堆叠
	if not data.stackable:
		return false
	# 检查是否已满
	if is_full():
		return false
	return true

# ----------------------------------------
# 克隆函数
# 创建一个完全相同的副本
#
# 返回：新的物品实例
# ----------------------------------------
func duplicate() -> ItemInstance:
	return ItemInstance.new(data, quantity)

# ----------------------------------------
# 是否为空函数
# 检查实例是否为空（数量为0或没有数据）
# ----------------------------------------
func is_empty() -> bool:
	return not data or quantity <= 0

# ----------------------------------------
# 转换为字典函数
# 用于存档
# ----------------------------------------
func to_dict() -> Dictionary:
	if not data:
		return {}
	return {
		"item_id": str(data.item_id),
		"quantity": quantity
	}

# ----------------------------------------
# 从字典加载函数
# 用于读档
#
# 参数：dict - 存档数据
# 返回：是否成功
# ----------------------------------------
func from_dict(dict: Dictionary) -> bool:
	if not dict.has("item_id"):
		return false

	var registry = ItemRegistry.get_registry()
	if not registry:
		return false

	data = registry.get_item(StringName(dict.item_id))
	quantity = dict.get("quantity", 1)
	if data == null:
		return false
	# 核心状态：setter 已经挂了一枚出厂满电的核心，这里用存档值覆盖它。
	# 老存档没有 core 字段 → 保持出厂状态（当时的核心确实没存过状态）。
	if dict.has("core") and core != null:
		var cd = dict.get("core")
		if cd is Dictionary:
			core.from_dict(cd)
	return true

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 同步核心状态函数
#
# data 变化后调用：
#   携带电量的物品 → 没有核心就补一枚出厂满电的（有则原样保留，
#                     所以更换 data 不会把已消耗的电量冲掉）
#   不携带电量的物品 → 清掉可能残留的核心引用
# ----------------------------------------
func _sync_core() -> void:
	if data != null and data.carries_power:
		if core == null:
			core = PowerCoreSystem.create_core(data.item_id)
	elif core != null:
		core = null


# ----------------------------------------
# 限制数量函数
# 确保数量在有效范围内（只写后备字段，不触发 setter）
# ----------------------------------------
func _clamp_quantity() -> void:
	_quantity = _clamped(_quantity)


# 计算合法数量（纯函数，无副作用）
func _clamped(value: int) -> int:
	if not data:
		return 0
	# 数量不能小于0
	var v: int = maxi(value, 0)
	# 数量不能超过最大堆叠
	if data.stackable:
		v = mini(v, data.max_stack)
	return v
