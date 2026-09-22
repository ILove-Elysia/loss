# script/player/equipment.gd
# ============================================
# 玩家装备组件
#
# 做什么：
#   管理武器 / 护甲 / 工具 / 核心四个槽位，把装备上的数值
#   （攻击力、防御、采集速度）汇总出来，交给战斗与采集系统消费。
#
#   核心槽是个特例：它不参与数值汇总，而是一个**开关**——
#   装上核心会给玩家多出一块"属于核心自己"的电池（HUD 多一行 🔋 核心电量），
#   并解锁合成界面的「核心」栏目。见 _sync_core_state()。
#
# 为什么单独一个节点：
#   挂载名为 "Equipment" 的子节点后，ResourceInteraction 里
#   早已预留的 get_node("Equipment").get_tool_item() 就能直接生效，
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

## 槽位 → 已装备的 **ItemInstance**（不是 ItemData）
## key 用 ItemData.EquipSlot 的整数值
##
## 为什么存实例而不是物品数据：核心的电量 / 温度值挂在实例上（见 item_instance.gd
## 的 core 字段），只存 ItemData 的话，卸下再装上会造出一个全新的满电核心。
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
	# 四个槽位初始化为空，保证 get_item() 永远有这个键
	for slot in [ItemData.EquipSlot.WEAPON, ItemData.EquipSlot.ARMOR,
			ItemData.EquipSlot.TOOL, ItemData.EquipSlot.CORE]:
		_slots[slot] = null
	# 场景加载时先把"核心带来的状态"清一遍。
	# core_tab_unlocked 是 CraftingSystem 上的静态变量，上一局装过核心的话
	# 它还是 true —— 不在这里重置，新开一局（或读一个没装核心的档）
	# 会凭空多出一个「核心」制作栏。
	# 读了带核心的档也没问题：_apply_player 恢复装备时会把状态再设回来。
	_sync_core_state()

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
	#    先取后放，保证替换下来的旧装备一定有格子可退。
	#    取的是**实例本身**（不是按 id 减数量），核心的电量与温度值才跟着走。
	var instance: ItemInstance = inventory.take_item_instance(item_id)
	if instance == null:
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP, "[装备] 从背包取出 %s 失败", [item_id])
		return false

	# 5. 旧装备退回背包
	var slot: int = instance.data.equip_slot
	var old: ItemInstance = _slots.get(slot, null)
	if old != null:
		if inventory.add_item_instance(old):
			DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 卸下旧装备：%s",
				[old.data.display_name])
		else:
			# 理论上不会发生（刚腾出过一格），保守处理：原样放回，不凭空销毁
			_slots[slot] = old
			inventory.add_item_instance(instance)
			DebugConfig.warn_msg(DebugConfig.CAT_EQUIP,
				"[装备] 背包已满，%s 无法替换", [item_id])
			return false

	# 6. 装上新装备
	_slots[slot] = instance
	DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 已装备：%s（%s）",
		[instance.data.display_name, instance.data.get_equip_slot_name()])
	_sync_core_state()
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

	var instance: ItemInstance = _slots.get(slot, null)
	if instance == null:
		return false

	# 背包放不下就拒绝，绝不让物品消失
	if not _can_return_to_inventory(inventory, instance.data):
		DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 背包已满，无法卸下 %s",
			[instance.data.display_name])
		return false

	# 放回的是**同一个实例**：核心拆下来时电量、温度值原样保留
	if not inventory.add_item_instance(instance):
		return false
	_slots[slot] = null
	DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 已卸下：%s", [instance.data.display_name])
	_sync_core_state()
	equipment_changed.emit()
	return true

## 直接写入装备槽（读档恢复专用，物品数据版）
##
## 只是 set_slot_instance 的便捷包装：造一个全新实例再写进去。
## 新实例的核心是满电的 —— 需要保留存档里的核心状态时，请用
## set_slot_instance 传实例（SaveManager 走的就是那条路）。
##
## 参数：slot - ItemData.EquipSlot 的槽位值；item_data - 要写入的物品数据
func set_slot_item(slot: int, item_data: ItemData) -> void:
	if item_data == null:
		return
	set_slot_instance(slot, ItemInstance.new(item_data, 1))


## 直接写入装备槽（读档恢复专用，实例版）
##
## 为什么不走 equip()：equip 的语义是"从背包取一件穿上"，
## 背包满了会失败（add_item 失败 → 装备凭空消失）。存档里
## 背包 20 格全满 + 身上 4 件装备是很常见的状态，恢复时必须
## 绕过背包。读档是"还原状态"而不是"执行一次装备操作"，直接写槽即可。
##
## 参数：slot - ItemData.EquipSlot 的槽位值；instance - 要写入的物品实例
func set_slot_instance(slot: int, instance: ItemInstance) -> void:
	if instance == null or instance.data == null:
		return
	if not instance.data.is_equippable():
		return
	if not _slots.has(slot):
		return
	# 模板槽位与目标槽位必须一致（防存档损坏 / 模板改过槽位时装错地方）
	if int(instance.data.equip_slot) != slot:
		DebugConfig.warn_msg(DebugConfig.CAT_EQUIP,
			"[装备] 读档恢复：%s 的槽位（%s）与目标槽不符，跳过",
			[instance.data.display_name, instance.data.get_equip_slot_name()])
		return
	_slots[slot] = instance
	DebugConfig.log_msg(DebugConfig.CAT_EQUIP, "[装备] 读档恢复：%s（%s）",
		[instance.data.display_name, instance.data.get_equip_slot_name()])
	_sync_core_state()
	equipment_changed.emit()


# ----------------------------------------
# 核心槽查询
#
# 核心槽只放"开关"类装备（动力核心 / 机械核心），不做数值汇总。
# 需要读核心本体的地方（如 UI 显示核心栏归属）走 get_core_item()。
# ----------------------------------------

## 核心槽是否装着东西
func has_core() -> bool:
	return get_instance(ItemData.EquipSlot.CORE) != null

## 取核心槽里的物品数据，空槽返回 null
func get_core_item() -> ItemData:
	var inst: ItemInstance = get_instance(ItemData.EquipSlot.CORE)
	if inst == null:
		return null
	return inst.data

## 取核心槽里的**核心状态**（电量 + 自身温度值），空槽 / 非电量核心返回 null。
## 这是玩家"外置电量"的唯一来源：HUD 的核心电量行、耗电交互都读它。
func get_core_instance() -> PowerCoreInstance:
	var inst: ItemInstance = get_instance(ItemData.EquipSlot.CORE)
	if inst == null:
		return null
	return inst.core


# ----------------------------------------
# 让外部强制重算一次核心槽状态
#
# 读档专用：装备恢复循环只会处理"槽里真有东西"的情况，
# 存档里核心槽为空时那个循环直接跳过，于是谁也不会去关掉
# 上一档留下的「核心」制作栏。读档收尾时无条件调一次这个方法即可。
# ----------------------------------------
func resync_core_state() -> void:
	_sync_core_state()


# ----------------------------------------
# 同步核心槽带来的状态（装 / 卸 / 读档恢复后都要调）
#
# 核心槽是**状态开关**而不是数值装备，所以它的效果不由 get_*_bonus() 提供，
# 而是"一旦装上就成立、拆下就失效"的两件事：
#   1. 电量：核心接入后，玩家多出一块**属于核心自己的**电池（外置电量）。
#      对已经自带内置电量的机器人无影响 —— 它有两块电池，各自结算
#      （见 vitals.gd 的 _update_power_effects / get_speed_multiplier）。
#   2. 核心制作栏：只有带 unlocks_core_tab 的核心会让合成界面多出「核心」栏。
#
# 放在装备组件里而不是 vitals 里监听信号：装备槽是唯一知道"核心何时变化"的地方，
# equip / unequip / set_slot_instance 三个入口都能覆盖到，读档恢复也天然走同一条路。
# ----------------------------------------
func _sync_core_state() -> void:
	var core_item: ItemData = get_core_item()

	var vitals := _get_vitals()
	if vitals != null and vitals.has_method("on_core_changed"):
		vitals.call("on_core_changed")

	CraftingSystem.set_core_unlocked(core_item != null and core_item.unlocks_core_tab)


# ----------------------------------------
# 获取指定槽位的装备数据函数
# 参数：slot - 槽位值
# 返回：ItemData，空槽返回 null
# （只读物品模板；需要带电量的核心状态请用 get_core_instance）
# ----------------------------------------
func get_item(slot: int) -> ItemData:
	var inst: ItemInstance = _slots.get(slot, null)
	if inst == null:
		return null
	return inst.data

# ----------------------------------------
# 获取指定槽位的**物品实例**函数
# 参数：slot - 槽位值
# 返回：ItemInstance，空槽返回 null
# （数值汇总用 get_item 就够；这里给需要物品实例的调用方用）
# ----------------------------------------
func get_instance(slot: int) -> ItemInstance:
	return _slots.get(slot, null)

# ----------------------------------------
# 获取指定槽位装备的物品ID函数
# 空槽返回空 StringName
# ----------------------------------------
func get_item_id(slot: int) -> StringName:
	var inst: ItemInstance = _slots.get(slot, null)
	if inst == null or inst.data == null:
		return &""
	return inst.data.item_id

# ============================================
# 数值汇总
# 战斗与采集系统只读这几个方法，不直接碰槽位
# ============================================

# ----------------------------------------
# 攻击力加成函数
# 返回：武器槽提供的攻击力加成（没武器为 0）
# ----------------------------------------
func get_attack_bonus() -> int:
	var weapon: ItemData = get_item(ItemData.EquipSlot.WEAPON)
	if weapon == null:
		return 0
	return weapon.attack_bonus

# ----------------------------------------
# 防御力加成函数
# 返回：护甲槽提供的防御（没护甲为 0）
# ----------------------------------------
func get_defense_bonus() -> int:
	var armor: ItemData = get_item(ItemData.EquipSlot.ARMOR)
	if armor == null:
		return 0
	return armor.defense_bonus

# ----------------------------------------
# 工具槽上那件物品的数据（没装工具返回 null）
#
# 采集侧靠它读两样东西：
#   tags         → 资源侧的"工具标签白名单"判定（树认斧、石头认镐）
#   harvest_work → 每次作业完成的工作量（石斧 4 / 铁斧 6）
# ----------------------------------------
func get_tool_item() -> ItemData:
	return get_item(ItemData.EquipSlot.TOOL)

# ----------------------------------------
# 是否装备了某件物品函数
# 参数：item_id - 物品ID
# ----------------------------------------
func has_equipped(item_id: StringName) -> bool:
	for slot in _slots:
		var inst: ItemInstance = _slots[slot]
		if inst != null and inst.data != null and inst.data.item_id == item_id:
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
# 获取生命体征节点函数
# Equipment 与 Vitals 同为 player 的子节点
# （核心槽要靠它开关电量，见 _sync_core_state）
# ----------------------------------------
func _get_vitals() -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null("Vitals")

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
