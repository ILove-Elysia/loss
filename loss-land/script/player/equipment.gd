# script/player/equipment.gd
# ============================================
# 玩家装备组件
#
# 做什么：
#   管理武器 / 护甲 / 工具三个槽位，把装备上的数值
#   （攻击力、防御、采集速度）汇总出来，交给战斗与采集系统消费。
#
# 为什么单独一个节点：
#   挂载名为 "Equipment" 的子节点后，ResourceInteraction 里
#   早已预留的 get_node("Equipment").get_current_tool() 就能直接生效，
#   不必给玩家根节点加脚本。
#
# 装备流转：
#   装备 = 从背包取出 1 件 → 放进槽位 → 旧装备退回背包
#   卸下 = 从槽位取出 → 放回背包（背包满则拒绝，避免物品凭空消失）
#
# 挂载方式：
#   作为 player 节点的子节点，节点名必须是 "Equipment"
# ============================================

class_name PlayerEquipment
extends Node

# ============================================
# 信号
# ============================================

## 装备发生变化（装上/卸下/替换）后发出
## UI 与战斗系统监听它来刷新显示和数值
signal equipment_changed()

# ============================================
# 成员变量
# ============================================

## 槽位 → 已装备的 ItemData
## key 用 ItemData.EquipSlot 的整数值
var _slots: Dictionary = {}

## 采集互斥锁：玩家当前是否正在采集某个资源
## ResourceEntity.harvest 入口抢占、退出释放，避免一次交互采掉周围全部资源
var _harvesting: bool = false

## 采集锁的失效时间点（毫秒时间戳）
## 兜底：万一某次采集被中断没走到释放逻辑，超时后 is_harvesting() 自动返回 false，
## 避免"锁卡死 → 之后永远采不了任何资源"。
var _harvest_lock_deadline_ms: int = 0

# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	name = "Equipment"
	# 三个槽位初始化为空，保证 get_item() 永远有这个 key
	for slot in [ItemData.EquipSlot.WEAPON, ItemData.EquipSlot.ARMOR, ItemData.EquipSlot.TOOL]:
		_slots[slot] = null

# ============================================
# 装备 / 卸下
# ============================================

# ----------------------------------------
# 装备函数
# 从背包取出一件物品装到对应槽位
#
# 参数：item_id - 要装备的物品ID
# 返回：true 装备成功，false 失败（不存在/不可装备/背包没有）
# ----------------------------------------
func equip(item_id: StringName) -> bool:
	var inventory := _get_inventory()
	if inventory == null:
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP, "[装备] 找不到 Inventory 节点，无法装备")
		return false

	# 1. 查物品数据
	var item_data := _get_item_data(item_id)
	if item_data == null:
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP, "[装备] 物品不存在: %s", [item_id])
		return false

	# 2. 必须可装备
	if not item_data.is_equippable():
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP, "[装备] %s 不可装备", [item_id])
		return false

	# 3. 背包里得真有这件物品
	if not inventory.has_item(item_id):
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP, "[装备] 背包中没有 %s", [item_id])
		return false

	# 4. 从背包取出 1 件
	#    先取后放，保证替换下来的旧装备一定有格子可退
	if not inventory.remove_item(item_id, 1):
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP, "[装备] 从背包取出 %s 失败", [item_id])
		return false

	# 5. 旧装备退回背包
	var slot: int = item_data.equip_slot
	var old: ItemData = _slots.get(slot, null)
	if old != null:
		inventory.add_item(old, 1)
		DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 卸下旧装备：%s", [old.display_name])

	# 6. 装上新装备
	_slots[slot] = item_data
	DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 已装备：%s（%s）", [item_data.display_name, item_data.get_equip_slot_name()])
	equipment_changed.emit()
	return true

# ----------------------------------------
# 卸下函数
# 把指定槽位的装备放回背包
#
# 参数：slot - ItemData.EquipSlot 的槽位值
# 返回：true 卸下成功，false 失败（槽位空/背包满）
# ----------------------------------------
func unequip(slot: int) -> bool:
	var inventory := _get_inventory()
	if inventory == null:
		return false

	var item_data: ItemData = _slots.get(slot, null)
	if item_data == null:
		return false

	# 背包放不下就拒绝，绝不让物品消失
	if not _can_return_to_inventory(inventory, item_data):
		DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 背包已满，无法卸下 %s", [item_data.display_name])
		return false

	inventory.add_item(item_data, 1)
	_slots[slot] = null
	DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 已卸下：%s", [item_data.display_name])
	equipment_changed.emit()
	return true

## 直接写入装备槽（读档恢复专用）
##
## 为什么不走 equip()：equip 的语义是"从背包取一件穿上"，
## 背包满了会失败（add_item 失败 → 装备凭空消失）。存档里
## 背包 20 格全满 + 身上 3 件装备是很常见的状态，恢复时必须
## 绕过背包。读档是"还原状态"而不是"执行一次装备操作"，直接写槽即可。
##
## 参数：slot - ItemData.EquipSlot 的槽位值；item_data - 要写入的物品数据
func set_slot_item(slot: int, item_data: ItemData) -> void:
	if item_data == null or not item_data.is_equippable():
		return
	if not _slots.has(slot):
		return
	_slots[slot] = item_data
	DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 读档恢复：%s（%s）",
		[item_data.display_name, item_data.get_equip_slot_name()])
	equipment_changed.emit()


# ----------------------------------------
# 获取指定槽位的装备函数
# 参数：slot - 槽位值
# 返回：ItemData，空槽返回 null
# ----------------------------------------
func get_item(slot: int) -> ItemData:
	return _slots.get(slot, null)

# ----------------------------------------
# 获取指定槽位装备的物品ID函数
# 空槽返回空 StringName
# ----------------------------------------
func get_item_id(slot: int) -> StringName:
	var item_data: ItemData = _slots.get(slot, null)
	if item_data == null:
		return &""
	return item_data.item_id

# ============================================
# 数值汇总
# 战斗与采集系统只读这几个方法，不直接碰槽位
# ============================================

# ----------------------------------------
# 攻击力加成函数
# 返回：武器槽提供的攻击力加成（没武器为 0）
# ----------------------------------------
func get_attack_bonus() -> int:
	var weapon: ItemData = _slots.get(ItemData.EquipSlot.WEAPON, null)
	if weapon == null:
		return 0
	return weapon.attack_bonus

# ----------------------------------------
# 防御力加成函数
# 返回：护甲槽提供的防御（没护甲为 0）
# ----------------------------------------
func get_defense_bonus() -> int:
	var armor: ItemData = _slots.get(ItemData.EquipSlot.ARMOR, null)
	if armor == null:
		return 0
	return armor.defense_bonus

# ----------------------------------------
# 采集速度倍率函数
#
# 参数：required_tool - 该资源需要的工具类型（ResourceData.HarvestTool 的整数值）
# 返回：耗时的除数。1.0 = 原速，1.5 = 快 50%，2.0 = 快一倍
#
# 说明：工具类型必须与资源匹配才生效。
#       拿斧头挖石头不会加速，这样四种工具各有用途。
# ----------------------------------------
func get_harvest_speed_multiplier(required_tool: int) -> float:
	var tool_item: ItemData = _slots.get(ItemData.EquipSlot.TOOL, null)
	if tool_item == null:
		return 1.0
	# 资源不要求工具（如草）时，任何工具都不加成，避免无意义加速
	if required_tool == int(ResourceData.HarvestTool.NONE):
		return 1.0
	if int(tool_item.tool_type) != required_tool:
		return 1.0
	return 1.0 + tool_item.harvest_speed_bonus

# ----------------------------------------
# 当前工具类型函数
# 供 ResourceInteraction 查询（它按 "Equipment".get_current_tool() 查找）
# 返回：ResourceData.HarvestTool 对应的整数值
# ----------------------------------------
func get_current_tool() -> int:
	var tool_item: ItemData = _slots.get(ItemData.EquipSlot.TOOL, null)
	if tool_item == null:
		return int(ResourceData.HarvestTool.NONE)
	return int(tool_item.tool_type)

# ----------------------------------------
# 是否装备了某件物品函数
# 参数：item_id - 物品ID
# ----------------------------------------
func has_equipped(item_id: StringName) -> bool:
	for slot in _slots:
		var item_data: ItemData = _slots[slot]
		if item_data != null and item_data.item_id == item_id:
			return true
	return false

# ============================================
# 采集互斥锁
# ResourceEntity.harvest 会调用，避免玩家同时采集多个相邻资源
# ============================================

## 玩家是否正在采集某个资源
## 自带超时兜底：超过预定时长仍未释放，视为锁已失效并自动清除
func is_harvesting() -> bool:
	if _harvesting and Time.get_ticks_msec() >= _harvest_lock_deadline_ms:
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 采集锁超时自动清除（说明之前有一次采集没有正常释放）")
		_harvesting = false
		_harvest_lock_deadline_ms = 0
	return _harvesting

## 设置采集状态（true=开始采集，false=采集结束）
## 由 ResourceEntity.harvest 调用；外部不直接用
## timeout_ms：true 时锁的最长存活时间，超时自动失效（防止卡死）
func set_harvesting(value: bool, timeout_ms: int = 8000) -> void:
	_harvesting = value
	_harvest_lock_deadline_ms = (Time.get_ticks_msec() + timeout_ms) if value else 0

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 获取背包节点函数
# Equipment 与 Inventory 同为 player 的子节点
# ----------------------------------------
func _get_inventory() -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null("Inventory")

# ----------------------------------------
# 获取物品数据函数
# 从物品注册表查询
# ----------------------------------------
func _get_item_data(item_id: StringName) -> ItemData:
	var registry = ItemRegistry.get_registry()
	if registry == null:
		return null
	return registry.get_item(item_id)

# ----------------------------------------
# 判断背包能否放回这件装备函数
#
# Inventory 没有 can_add_item，这里用现有接口自己判断：
#   可堆叠 → 有可堆叠槽或有空槽即可
#   不可堆叠（装备都是） → 必须有空槽
#
# 返回：true 放得下
# ----------------------------------------
func _can_return_to_inventory(inventory: Node, item_data: ItemData) -> bool:
	# 以后 Inventory 补了 can_add_item 就优先用它
	if inventory.has_method("can_add_item"):
		return bool(inventory.call("can_add_item", item_data, 1))

	if item_data.stackable:
		return inventory.find_stackable_slot(item_data.item_id) != -1 \
			or inventory.find_empty_slot() != -1
	return inventory.find_empty_slot() != -1
