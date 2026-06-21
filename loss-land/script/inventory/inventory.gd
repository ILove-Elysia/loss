# script/inventory/inventory.gd
# ============================================
# 背包系统 - 管理玩家的物品存储
#
# 什么是背包？
# 背包是一个存储物品的容器
# 它管理物品的添加、移除、堆叠和排序
#
# 设计思路：
# 1. 使用槽位（Slot）系统，每个槽位存放一个物品实例
# 2. 支持自动堆叠相同物品
# 3. 支持拖拽移动物品
# 4. 支持存档和读档
# ============================================

class_name Inventory
extends Node

# ============================================
# 信号
# ============================================

# 物品添加信号
signal item_added(item: ItemInstance, slot: int)

# 物品移除信号
signal item_removed(item_id: StringName, count: int, slot: int)

# 物品改变信号（数量变化、移动等）
signal item_changed(slot: int)

# 背包满信号
signal inventory_full()

# 背包清空信号
signal inventory_cleared()

# ============================================
# 导出变量
# ============================================

# 背包最大槽位数
@export var max_slots: int = 20

# ============================================
# 私有变量
# ============================================

# 槽位数组
# 每个元素是一个 ItemInstance 或 null
var _slots: Array = []

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 初始化槽位
	_initialize_slots()

# ============================================
# 公共方法 - 查询
# ============================================

# ----------------------------------------
# 获取槽位数量函数
# 返回背包的总槽位数
# ----------------------------------------
func get_slot_count() -> int:
	return max_slots

# ----------------------------------------
# 获取物品函数
# 获取指定槽位的物品实例
#
# 参数：slot - 槽位索引（从0开始）
# 返回：ItemInstance 或 null
# ----------------------------------------
func get_item(slot: int) -> ItemInstance:
	if not _is_valid_slot(slot):
		return null
	return _slots[slot]

# ----------------------------------------
# 获取所有物品函数
# 返回所有非空的物品实例
# ----------------------------------------
func get_all_items() -> Array[ItemInstance]:
	var items: Array[ItemInstance] = []
	for slot in _slots:
		if slot and not slot.is_empty():
			items.append(slot)
	return items

# ----------------------------------------
# 获取物品数量函数
# 统计背包中某种物品的总数量
#
# 参数：item_id - 物品ID
# 返回：总数量
# ----------------------------------------
func get_item_count(item_id: StringName) -> int:
	var total = 0
	for slot in _slots:
		if slot and slot.data and slot.data.item_id == item_id:
			total += slot.quantity
	return total

# ----------------------------------------
# 查找物品槽位函数
# 找到包含指定物品的槽位
#
# 参数：item_id - 物品ID
# 返回：槽位索引数组
# ----------------------------------------
func find_item_slots(item_id: StringName) -> Array[int]:
	var slots: Array[int] = []
	for i in range(_slots.size()):
		var slot = _slots[i]
		if slot and slot.data and slot.data.item_id == item_id:
			slots.append(i)
	return slots

# ----------------------------------------
# 查找空槽位函数
# 找到第一个空槽位
#
# 返回：槽位索引，没有空槽位返回 -1
# ----------------------------------------
func find_empty_slot() -> int:
	for i in range(_slots.size()):
		if not _slots[i] or _slots[i].is_empty():
			return i
	return -1

# ----------------------------------------
# 查找可堆叠槽位函数
# 找到可以堆叠指定物品的槽位
#
# 参数：item_id - 物品ID
# 返回：槽位索引，没有返回 -1
# ----------------------------------------
func find_stackable_slot(item_id: StringName) -> int:
	for i in range(_slots.size()):
		var slot = _slots[i]
		if slot and slot.data and slot.data.item_id == item_id:
			if not slot.is_full():
				return i
	return -1

# ----------------------------------------
# 是否有物品函数
# 检查背包中是否有指定物品
#
# 参数：
#   item_id - 物品ID
#   count - 需要的数量（默认1）
# 返回：是否有足够数量
# ----------------------------------------
func has_item(item_id: StringName, count: int = 1) -> bool:
	return get_item_count(item_id) >= count

# ----------------------------------------
# 是否已满函数
# 检查背包是否已满
# ----------------------------------------
func is_full() -> bool:
	return find_empty_slot() == -1

# ----------------------------------------
# 是否为空函数
# 检查背包是否为空
# ----------------------------------------
func is_empty() -> bool:
	for slot in _slots:
		if slot and not slot.is_empty():
			return false
	return true

# ============================================
# 公共方法 - 操作
# ============================================

# ----------------------------------------
# 添加物品函数
# 向背包添加物品，自动堆叠
#
# 参数：
#   item_data - 物品数据
#   count - 数量
# 返回：实际添加的数量
# ----------------------------------------
func add_item(item_data: ItemData, count: int = 1) -> int:
	if not item_data or count <= 0:
		return 0

	var remaining = count

	# 如果物品可堆叠，先尝试堆叠到现有槽位
	if item_data.stackable:
		while remaining > 0:
			var slot_idx = find_stackable_slot(item_data.item_id)
			if slot_idx == -1:
				break

			var slot = _slots[slot_idx]
			var added = slot.add(remaining)
			remaining -= added
			item_changed.emit(slot_idx)

	# 如果还有剩余，尝试放入空槽位
	while remaining > 0:
		var slot_idx = find_empty_slot()
		if slot_idx == -1:
			inventory_full.emit()
			break

		# 创建新的物品实例
		var stack_size = mini(remaining, item_data.max_stack)
		var new_item = ItemInstance.new(item_data, stack_size)
		_slots[slot_idx] = new_item
		remaining -= stack_size
		item_added.emit(new_item, slot_idx)
		item_changed.emit(slot_idx)

	return count - remaining

# ----------------------------------------
# 添加物品实例函数
# 直接添加一个物品实例
#
# 参数：item_instance - 物品实例
# 返回：是否成功添加
# ----------------------------------------
func add_item_instance(item_instance: ItemInstance) -> bool:
	if not item_instance or item_instance.is_empty():
		return false

	# 尝试堆叠
	if item_instance.is_stackable():
		var slot_idx = find_stackable_slot(item_instance.data.item_id)
		if slot_idx != -1:
			var slot = _slots[slot_idx]
			if slot.merge(item_instance):
				item_changed.emit(slot_idx)
				return true

	# 尝试放入空槽位
	var empty_slot = find_empty_slot()
	if empty_slot != -1:
		_slots[empty_slot] = item_instance
		item_added.emit(item_instance, empty_slot)
		item_changed.emit(empty_slot)
		return true

	return false

# ----------------------------------------
# 移除物品函数
# 从背包移除指定数量的物品
#
# 参数：
#   item_id - 物品ID
#   count - 数量
# 返回：实际移除的数量
# ----------------------------------------
func remove_item(item_id: StringName, count: int = 1) -> int:
	if count <= 0:
		return 0

	var remaining = count

	# 从后向前遍历，优先移除后面的槽位
	for i in range(_slots.size() - 1, -1, -1):
		if remaining <= 0:
			break

		var slot = _slots[i]
		if slot and slot.data and slot.data.item_id == item_id:
			var removed = slot.remove(remaining)
			remaining -= removed
			item_changed.emit(i)

			# 如果槽位空了，清空它
			if slot.is_empty():
				_slots[i] = null

	if remaining < count:
		item_removed.emit(item_id, count - remaining, -1)

	return count - remaining

# ----------------------------------------
# 设置槽位函数
# 直接设置指定槽位的物品
#
# 参数：
#   slot - 槽位索引
#   item - 物品实例
# ----------------------------------------
func set_slot(slot: int, item: ItemInstance) -> void:
	if not _is_valid_slot(slot):
		return

	_slots[slot] = item
	item_changed.emit(slot)

# ----------------------------------------
# 清空槽位函数
# 清空指定槽位
#
# 参数：slot - 槽位索引
# 返回：被清空的物品实例
# ----------------------------------------
func clear_slot(slot: int) -> ItemInstance:
	if not _is_valid_slot(slot):
		return null

	var item = _slots[slot]
	_slots[slot] = null
	item_changed.emit(slot)
	return item

# ----------------------------------------
# 移动物品函数
# 在两个槽位之间移动物品
#
# 参数：
#   from_slot - 源槽位
#   to_slot - 目标槽位
# ----------------------------------------
func move_item(from_slot: int, to_slot: int) -> void:
	if not _is_valid_slot(from_slot) or not _is_valid_slot(to_slot):
		return
	if from_slot == to_slot:
		return

	var from_item = _slots[from_slot]
	var to_item = _slots[to_slot]

	# 如果目标槽位为空，直接移动
	if not to_item or to_item.is_empty():
		_slots[to_slot] = from_item
		_slots[from_slot] = null
		item_changed.emit(from_slot)
		item_changed.emit(to_slot)
		return

	# 如果是同一种物品且可堆叠，尝试合并
	if from_item.can_merge_with(to_item):
		if to_item.merge(from_item):
			# 如果完全合并，清空源槽位
			if from_item.is_empty():
				_slots[from_slot] = null
			item_changed.emit(from_slot)
			item_changed.emit(to_slot)
			return

	# 否则，交换两个槽位
	_slots[from_slot] = to_item
	_slots[to_slot] = from_item
	item_changed.emit(from_slot)
	item_changed.emit(to_slot)

# ----------------------------------------
# 清空背包函数
# 移除所有物品
# ----------------------------------------
func clear() -> void:
	_slots.clear()
	_initialize_slots()
	inventory_cleared.emit()

# ============================================
# 公共方法 - 存档
# ============================================

# ----------------------------------------
# 保存数据函数
# 返回背包的存档数据
# ----------------------------------------
func save() -> Dictionary:
	var data = {
		"max_slots": max_slots,
		"items": []
	}

	for i in range(_slots.size()):
		var slot = _slots[i]
		if slot and not slot.is_empty():
			data.items.append({
				"slot": i,
				"item": slot.to_dict()
			})

	return data

# ----------------------------------------
# 加载数据函数
# 从存档数据恢复背包
#
# 参数：data - 存档数据
# ----------------------------------------
func load_data(data: Dictionary) -> void:
	clear()

	if data.has("max_slots"):
		max_slots = data.max_slots
		_initialize_slots()

	if data.has("items"):
		for item_data in data.items:
			var slot = item_data.slot
			var item = ItemInstance.new()
			if item.from_dict(item_data.item):
				_slots[slot] = item

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 初始化槽位函数
# 创建空的槽位数组
# ----------------------------------------
func _initialize_slots() -> void:
	_slots.clear()
	for i in range(max_slots):
		_slots.append(null)

# ----------------------------------------
# 检查槽位有效性函数
# ----------------------------------------
func _is_valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < max_slots
