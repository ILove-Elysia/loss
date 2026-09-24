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
	# 防死循环：slot.add 返回 0（slot 满）时必须 break，否则 while 永不退出
	if item_data.stackable:
		while remaining > 0:
			var slot_idx = find_stackable_slot(item_data.item_id)
			if slot_idx == -1:
				break

			# _slots 是无类型 Array，取出的元素是 Variant，
			# 对 Variant 取 .quantity 无法用 := 推断类型，必须显式声明 int
			var slot = _slots[slot_idx]
			var before: int = slot.quantity
			var added: int = slot.add(remaining)
			# slot.add 在 slot 满时返回 0，避免再次回到同一个满 slot
			if added <= 0 or slot.quantity == before:
				break
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
# 取出一件物品实例函数（装备 / 丢弃时用）
#
# 为什么不用 remove_item：
#   remove_item 是"按 id 减数量"，只返回减掉了几个 —— **物品实例本身被丢掉**，
#   之后再 add_item 只会造一个全新的实例。核心的电量、温度值都挂在实例上，
#   于是"拆下核心 → 电量凭空回满"。
#   本方法把同一个实例交出去，状态天然连续。
#
# 参数：item_id - 物品ID
# 返回：取出的实例（背包里没有则 null）
# ----------------------------------------
func take_item_instance(item_id: StringName) -> ItemInstance:
	var slots := find_item_slots(item_id)
	if slots.is_empty():
		return null

	var idx: int = slots[0]
	var slot: ItemInstance = _slots[idx]
	if slot == null or slot.is_empty():
		return null

	if slot.quantity <= 1:
		# 整件取走：槽位清空，交出的就是原实例
		_slots[idx] = null
		item_changed.emit(idx)
		item_removed.emit(item_id, 1, idx)
		return slot

	# 堆叠物品：拆出 1 件（split 会连核心状态一起克隆），原槽数量 -1
	var taken: ItemInstance = slot.split(1)
	if taken == null:
		return null
	item_changed.emit(idx)
	item_removed.emit(item_id, 1, idx)
	return taken

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
# 跨背包移动物品函数（静态）
# 箱子 ↔ 玩家背包 拖拽共用：目标空=整堆搬过去；同类可堆叠=合并（放不下的留在源槽）；
# 否则=交换两个槽位。只改数据，各自通过 item_changed 信号回刷 UI。
# 注意 Inventory._slots 是私有数组，这里全部走 get_item/set_slot/clear_slot 公共接口。
#
# 保留这个旧入口只为兼容：实现已经统一到 transfer_between（count = -1 就是整堆），
# 新代码请直接用 transfer_between。
# ----------------------------------------
static func move_between(from_inv: Inventory, from_slot: int, to_inv: Inventory, to_slot: int) -> void:
	transfer_between(from_inv, from_slot, to_inv, to_slot, -1)

# ----------------------------------------
# 跨背包搬运指定数量（静态）
#
# 参数：
#   from_inv / from_slot - 来源
#   to_inv / to_slot     - 落点（**具体某一格**，不是"随便找个位置"）
#   count                - < 0 = 整堆（默认）；> 0 = 只搬这么多个
# 返回：实际搬过去的数量
#
# 三种落点行为：
#   ① 目标格为空     → 搬过去（整堆，或从源堆里拆 count 个出来）
#   ② 同类可堆叠     → 合并，**最多合 count 个**；合不下的留在源槽
#   ③ 是别的物品     → 整堆时交换两格；**指定数量时什么都不做**
#      （Ctrl 拿 1 个去撞别人的格子，如果交换整堆，玩家会莫名其妙——
#        那时他要的是"这一格放不下我这 1 个"，不是"把我的东西换走"）
#
# 允许 from_inv == to_inv（背包内部拆堆）：只要两格不同就行。
# ----------------------------------------
static func transfer_between(from_inv: Inventory, from_slot: int, to_inv: Inventory,
		to_slot: int, count: int = -1) -> int:
	if from_inv == null or to_inv == null:
		return 0
	if from_inv == to_inv and from_slot == to_slot:
		return 0

	var from_item: ItemInstance = from_inv.get_item(from_slot)
	if from_item == null or from_item.is_empty():
		return 0
	var to_item: ItemInstance = to_inv.get_item(to_slot)
	var whole: bool = count < 0 or count >= from_item.quantity

	# ---- ① 目标格为空 ----
	if to_item == null or to_item.is_empty():
		if whole:
			to_inv.set_slot(to_slot, from_item)
			from_inv.clear_slot(from_slot)
			return from_item.quantity
		var piece: ItemInstance = from_item.split(count)
		if piece == null:
			return 0
		to_inv.set_slot(to_slot, piece)
		from_inv.set_slot(from_slot, from_item)
		return piece.quantity

	# ---- ② 同类可堆叠：能合多少合多少 ----
	if from_item.can_merge_with(to_item):
		var give: ItemInstance = from_item
		if not whole:
			give = from_item.split(count)
			if give == null:
				return 0
		var before: int = give.quantity
		to_item.merge(give)
		var moved: int = before - give.quantity
		# merge 是就地改 to_item，这里重新 set 一次只为触发 item_changed 回刷 UI
		to_inv.set_slot(to_slot, to_item)
		# 没合进去的还回源槽
		if not whole:
			from_item.merge(give)
		if from_item.is_empty():
			from_inv.clear_slot(from_slot)
		else:
			from_inv.set_slot(from_slot, from_item)
		return moved

	# ---- ③ 别的物品：只有整堆才交换 ----
	if whole:
		to_inv.set_slot(to_slot, from_item)
		from_inv.set_slot(from_slot, to_item)
		return from_item.quantity
	return 0

# ----------------------------------------
# 把源槽里的一整堆"塞进"目标背包（静态）
#
# 与 transfer_between 的区别：**不指定落点**。先并进已有的同类槽，再往空格里塞。
# 这就是 Shift+左键「快速存入箱子 / 快速取回背包」要的行为——
# 玩家不想为"背包 20 个空格里到底放哪一格"操心。
#
# 搬的是**实例本身**（不是新建），核心电量、温度这些挂在实例上的状态不会丢。
# 返回实际搬走的数量。
# ----------------------------------------
static func stash_into(src: Inventory, from_slot: int, dst: Inventory) -> int:
	if src == null or dst == null or src == dst:
		return 0
	var item: ItemInstance = src.get_item(from_slot)
	if item == null or item.is_empty():
		return 0
	var start: int = item.quantity

	# ---- ① 先并进已有的同类槽 ----
	while item != null and not item.is_empty():
		var stack_idx: int = dst.find_stackable_slot(item.data.item_id)
		if stack_idx == -1:
			break
		var slot: ItemInstance = dst.get_item(stack_idx)
		if slot == null:
			break
		var before: int = item.quantity
		slot.merge(item)
		if item.quantity >= before:
			# 一格都没合进去（那格已经满了）→ 必须跳出，否则 find_stackable_slot
			# 还会返回同一格，while 永不退出
			break
		dst.set_slot(stack_idx, slot)

	# ---- ② 剩下的塞空格 ----
	while item != null and not item.is_empty():
		var empty_idx: int = dst.find_empty_slot()
		if empty_idx == -1:
			dst.inventory_full.emit()
			break
		if item.quantity <= item.data.max_stack:
			# 整堆塞得下 → 直接把实例放进空格，**并置 item = null**：
			# 否则下面收尾时还会把它当"没搬走的余量"写回源槽，
			# 同一个实例挂在两个槽位上（复制物品级别的 bug）。
			dst.set_slot(empty_idx, item)
			item = null
			break
		var chunk: ItemInstance = item.split(item.data.max_stack)
		if chunk == null:
			break
		dst.set_slot(empty_idx, chunk)

	# ---- ③ 源槽收尾 ----
	var left: int = item.quantity if item != null else 0
	if item == null or item.is_empty():
		src.clear_slot(from_slot)
	else:
		src.set_slot(from_slot, item)
	return start - left

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

# ----------------------------------------
# 通知所有槽位刷新函数
# 读档专用：load_data 是直接写内部数组、不发 item_changed 的，
# 于是 HUD 快捷栏与背包界面会一直停留在读档前的旧内容。
# 读档完成后调一次，把所有槽位通知出去。
# ----------------------------------------
func notify_all_slots() -> void:
	for i in range(_slots.size()):
		item_changed.emit(i)

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
