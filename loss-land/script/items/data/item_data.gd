# script/items/data/item_data.gd
# ============================================
# 物品数据类 - 定义物品的所有属性
#
# 什么是物品数据？
# 物品数据是物品的"模板"，定义了物品的基本属性
# 例如：草、木头、石头等都是不同的物品数据
#
# 什么是 Resource？
# Resource 是 Godot 的资源基类
# 继承它的类可以保存为 .tres 文件，在编辑器中可视化配置
#
# 运行时物品实例使用 ItemInstance 类
# ============================================

class_name ItemData
extends Resource

# ============================================
# 枚举定义
# ============================================

# ----------------------------------------
# 物品类型枚举
# 定义物品的大类，用于背包分类和UI显示
# ----------------------------------------
# 注意：只能往末尾追加新类型，禁止在中间插入——
# .tres 里保存的是数字（item_type = 3），重排会让已有物品类型错乱。
enum ItemType {
	RESOURCE,    # 资源类（草、木头、石头等）
	TOOL,        # 工具类（斧头、镐、铲子等）
	FOOD,        # 食物类（浆果、肉等）
	MATERIAL,    # 材料类（木棍、布料、金属等）
	QUEST,       # 任务物品
	MISC,        # 杂项
	WEAPON,      # 武器类（木剑、石剑等）
	ARMOR,       # 护甲类（草甲、木甲等）
	BUILDING     # 建筑类（工作台、熔炉、储物箱等）
}

# ----------------------------------------
# 物品稀有度枚举
# 影响物品名称的颜色和掉落概率
# ----------------------------------------
enum Rarity {
	COMMON,      # 普通（白色）
	UNCOMMON,    # 罕见（绿色）
	RARE,        # 稀有（蓝色）
	EPIC,        # 史诗（紫色）
	LEGENDARY    # 传说（橙色）
}

# ----------------------------------------
# 装备槽位枚举
# 决定这件物品能装到哪个槽位；NONE 表示不可装备
#
# 注意：只能往末尾追加，禁止在中间插入——
# .tres 里存的是数字，重排会让已有装备错位。
# ----------------------------------------
enum EquipSlot {
	NONE,        # 不可装备（草、木材、电池等）
	WEAPON,      # 武器槽（剑）——加攻击力
	ARMOR,       # 护甲槽（衣服）——加防御
	TOOL,        # 工具槽（斧、镐）——每一下做掉多少工作量
	CORE         # 核心槽（动力核心 / 机械核心）——开启电量或制作栏
}

# 工具类型：只影响物品说明里"这是哪一类工具"那句话，不参与采集门槛判定
# （门槛看资源侧的标签白名单）
# 0=NONE 1=AXE 2=PICKAXE 3=SHOVEL 4=KNIFE
enum ToolType {
	NONE = 0,
	AXE = 1,
	PICKAXE = 2,
	SHOVEL = 3,
	KNIFE = 4
}

# ----------------------------------------
# 专属物品的使用权限策略（大纲 v0.7 · 2.2.4-④ 决策 ⑦）
#
# 为什么需要它：专属物品**可能生成在宝箱里被别的角色捡到**。
# 如果什么都不做，玩家会"捡到一件好东西却用不了"；如果全放开，"专属"就没意义了。
# 所以权限只卡在**能不能用**这一层，拾取 / 携带一律放开（大纲的取舍理由）。
#
# 三档策略，覆盖"黑名单"（OWNER_ONLY）与"白名单加成"（OWNER_BONUS）两种诉求。
# 注意：只能往末尾追加，禁止在中间插入——.tres 里存的是数字。
# ----------------------------------------
enum AccessPolicy {
	ANYONE,        # 谁都能用（通用物品；不填 exclusive_owner 时也是这一档）
	OWNER_BONUS,   # 谁都能用，但**只有归属角色享受专属加成**（白名单）
	OWNER_ONLY,    # **只有归属角色能用**，其他角色被拒（黑名单）
}

# ============================================
# 基本信息配置
# ============================================
@export_group("基本信息", "")

# 物品的唯一标识符
# 用于代码中查找物品，如 &"grass"、&"wood"
@export var item_id: StringName

# 物品的显示名称
# 用于UI显示，如 "草"、"木头"
@export var display_name: String

# 物品的描述文本
# 鼠标悬停时显示的说明文字
@export_multiline var description: String = ""

# 物品类型
@export var item_type: ItemType = ItemType.RESOURCE

# 物品稀有度
@export var rarity: Rarity = Rarity.COMMON

# ============================================
# 视觉配置
# ============================================
@export_group("视觉", "")

# 物品图标
# 在背包和快捷栏中显示的图片
@export var icon: Texture2D

# 世界模型
# 掉落在地上时显示的3D模型或精灵
@export var world_scene: PackedScene

# ============================================
# 堆叠配置
# ============================================
@export_group("堆叠", "")

# 是否可以堆叠
# 资源类物品通常可以堆叠，工具类通常不能
@export var stackable: bool = true

# 最大堆叠数量
# 一个格子最多能放多少个该物品
@export var max_stack: int = 99

# ============================================
# 使用配置
# ============================================
@export_group("使用", "")

# 是否可以使用
@export var usable: bool = false

# 使用后的效果
# 可以是恢复生命、增加饱食度等
@export var use_effect: String = ""

# 使用后是否消耗
# 食物使用后会消耗，工具不会
@export var consume_on_use: bool = true

# ============================================
# 专属权限（大纲 v0.7 · 2.2.4-④ 决策 ⑦）
#
# 三档策略见 AccessPolicy 枚举的注释。归属角色填 CharacterRegistry 的 id
# （如 &"adventurer" / &"witch" / &"robot"）。
# 判定统一走本类的 is_usable_by() / has_owner_bonus_for()，
# 由 ItemEffects.access_denied_reason() 与 apply() 执行，
# UI 侧（背包 / 快捷栏 / 悬停说明）只负责把拒绝原因展示出来。
# ============================================
@export_group("专属权限", "")

# 归属角色 id。**空 = 通用物品**，此时三档策略里只有 ANYONE 有意义。
@export var exclusive_owner: StringName = &""

# 使用权限策略（黑名单 / 白名单加成 / 通用）
@export var access_policy: AccessPolicy = AccessPolicy.ANYONE

# 归属角色使用时的**效果倍率**（仅 OWNER_BONUS 生效；1.0 = 无加成）。
# 用倍率而不是"第二套数值"，是为了让 .tres 里只维护一份 use_effect。
@export var owner_bonus_mult: float = 1.0

# ============================================
# 装备配置
#
# 只有 equip_slot != NONE 的物品才能装到玩家身上。
# 数值由 PlayerEquipment 汇总后，交给战斗/采集系统消费：
#   attack_bonus   → Physics 的最终攻击力
#   defense_bonus  → Physics.take_damage 的减伤
#   harvest_work   → 采集时每一次作业做掉多少工作量
# ============================================
@export_group("装备", "")

# 可装备的槽位，NONE 表示这件物品不能装备
@export var equip_slot: EquipSlot = EquipSlot.NONE

# 攻击力加成（武器槽生效，直接加到玩家基础攻击力上）
@export var attack_bonus: int = 0

# 防御力加成（护甲槽生效，每次受伤减少的伤害值，至少仍会掉 1 点）
@export var defense_bonus: int = 0

# 工具类型（斧 / 镐 / 铲 / 刀）：只用来在物品说明里写"这是哪一类工具"。
# 能不能采某个资源不看它，看下面的标签白名单。
@export var tool_type: ToolType = ToolType.NONE

# 工具标签：资源侧"白名单"的唯一判据
#
# 资源填了 allowed_tool_tags 后，装备的工具只要带其中任意一个标签就能作业。
# 目前斧头类统一挂 &"axe"、镐类统一挂 &"pickaxe"，
# 将来某个资源想只认「铁器」、或者同时接受斧和刀，直接配标签就行，不用改代码。
@export var tags: Array[StringName] = []

# 每次采集完成的工作量（配合 ResourceData.work_amount 使用）
#
# 资源的 work_amount 相当于"血量"，本值相当于"每次攻击的伤害"：
#   树 24 点 / 石斧 4 点 = 砍 6 次；铁斧 6 点 = 砍 4 次。
# 0 = 这件工具不按工作量计（作业时直接一次采完，旧行为）。
# 只有装备在工具槽、且通过资源的标签白名单时才被读取。
@export var harvest_work: int = 0

# 核心栏开关：装到「核心」槽后，是否让合成界面多出一个「核心」栏目。
#
# 为什么做成物品字段而不是写死"动力核心"这个 id：
# 大纲里还有一件「机械核心」（击败机械沙虫掉落），同样是"装上就多一栏"。
# 两者共用一个机制，将来加第三件核心也不用改代码。
@export var unlocks_core_tab: bool = false

# 是否**携带电量**：这件核心自带一块电池 + 一个独立温度值（PowerCoreInstance）。
#
# 为什么和 unlocks_core_tab 分开写：
#   "解锁核心栏"是功能开关，"携带电量"是实体属性。将来若出一枚只负责解锁、
#   不带电池的核心（或反过来），两者可以自由组合，不必改代码。
#
# 携带电量的物品一旦进入游戏（制作产出 / 掉落 / 测试箱 / 拾取 / 读档），
# 都会自动挂上一枚满电的核心实例，见 ItemInstance 的 core 字段。
@export var carries_power: bool = false

# ============================================
# 价值配置
# ============================================
@export_group("价值", "")

# 购买价格
@export var buy_price: int = 0

# 出售价格
@export var sell_price: int = 0

# ============================================
# 方法
# ============================================

# ----------------------------------------
# 获取稀有度颜色函数
# 返回对应稀有度的颜色，用于UI显示
# ----------------------------------------
func get_rarity_color() -> Color:
	match rarity:
		Rarity.COMMON:    return Color.WHITE
		Rarity.UNCOMMON:  return Color.GREEN
		Rarity.RARE:      return Color.BLUE
		Rarity.EPIC:      return Color.PURPLE
		Rarity.LEGENDARY: return Color.ORANGE
		_:                return Color.WHITE

# ----------------------------------------
# 获取类型名称函数
# 返回物品类型的中文名称
# ----------------------------------------
func get_type_name() -> String:
	match item_type:
		ItemType.RESOURCE:  return "资源"
		ItemType.TOOL:      return "工具"
		ItemType.FOOD:      return "食物"
		ItemType.MATERIAL:  return "材料"
		ItemType.QUEST:     return "任务物品"
		ItemType.MISC:      return "杂项"
		ItemType.WEAPON:    return "武器"
		ItemType.ARMOR:     return "护甲"
		ItemType.BUILDING:  return "建筑"
		_:                  return "未知"

# ----------------------------------------
# 获取装备槽位名称函数
# ----------------------------------------
func get_equip_slot_name() -> String:
	match equip_slot:
		EquipSlot.WEAPON: return "武器槽"
		EquipSlot.ARMOR:  return "护甲槽"
		EquipSlot.TOOL:   return "工具槽"
		EquipSlot.CORE:   return "核心槽"
		_:                return "不可装备"

# ----------------------------------------
# 获取工具类型名称函数
# 用于物品说明里描述"这件工具是干哪一行的"
# ----------------------------------------
func get_tool_type_name() -> String:
	match tool_type:
		ToolType.AXE:     return "木材"
		ToolType.PICKAXE: return "矿物"
		ToolType.SHOVEL:  return "挖掘"
		ToolType.KNIFE:   return "切割"
		_:                return ""

# ----------------------------------------
# 是否可装备函数
# ----------------------------------------
func is_equippable() -> bool:
	return equip_slot != EquipSlot.NONE

# ----------------------------------------
# 专属权限判定（决策 ⑦）
#
# owner_id 留空 = 用"当前正在游玩的角色"（CharacterRegistry.get_active_id()）。
# 这样调用方（UI / 效果服务）不必自己到处取角色 id。
# ----------------------------------------

# 是否设了归属角色（空 = 通用物品）
func has_exclusive_owner() -> bool:
	return not str(exclusive_owner).is_empty()

# 某角色能否使用本物品。
# OWNER_ONLY = 黑名单（只有归属者能用）；其余两档一律放行。
func is_usable_by(owner_id: String = "") -> bool:
	if access_policy != AccessPolicy.OWNER_ONLY:
		return true
	if not has_exclusive_owner():
		return true
	return _matches_owner(owner_id)

# 某角色使用本物品时是否享受专属加成（OWNER_BONUS = 白名单加成）
func has_owner_bonus_for(owner_id: String = "") -> bool:
	if access_policy != AccessPolicy.OWNER_BONUS:
		return false
	if owner_bonus_mult <= 0.0:
		return false
	return _matches_owner(owner_id)

# 归属角色的显示名（拼提示文案用）；没有归属时返回空串
func get_owner_display_name() -> String:
	if not has_exclusive_owner():
		return ""
	var defn := CharacterRegistry.get_character(str(exclusive_owner))
	return String(defn.get("name", ""))

# 给玩家看的一句话说明；"能用且无加成"的情况返回空串（不需要提示）
func get_access_hint() -> String:
	var owner_name := get_owner_display_name()
	if is_usable_by(""):
		if has_owner_bonus_for(""):
			return "专属加成生效（%s）" % owner_name
		return ""
	if owner_name.is_empty():
		return "此物品无法使用"
	return "只有「%s」能使用" % owner_name

# 内部：某角色是否就是归属角色
func _matches_owner(owner_id: String) -> bool:
	var id: String = owner_id
	if id.is_empty():
		id = CharacterRegistry.get_active_id()
	return id == str(exclusive_owner)

# ----------------------------------------
# 获取完整描述函数
# 返回包含名称、类型、描述的格式化文本
# ----------------------------------------
func get_full_description() -> String:
	var text = "[color=%s]%s[/color]\n" % [get_rarity_color().to_html(), display_name]
	text += "[i]类型: %s[/i]\n" % get_type_name()

	# 可装备物品：把生效的数值列出来，玩家不用猜
	if equip_slot != EquipSlot.NONE:
		text += "\n[b]装备效果[/b]（%s）\n" % get_equip_slot_name()
		if attack_bonus != 0:
			text += "  攻击力 +%d\n" % attack_bonus
		if defense_bonus != 0:
			text += "  防御 +%d\n" % defense_bonus
		# 核心槽不带数值，它的效果是"开关"，单独说清楚——
		# 否则说明里只有一行"装备效果（核心槽）"后面空着，玩家看不出装它图什么。
		if unlocks_core_tab:
			text += "  解锁「核心」制作栏\n"

	# 专属权限说明（决策 ⑦）：被拒 → 红字；能用且有专属加成 → 绿字；
	# 普通物品（能用、无加成）不加任何行，避免说明里全是废话。
	var access_hint := get_access_hint()
	if not access_hint.is_empty():
		var col: String = "#8fd18f" if is_usable_by("") else "#ff8a80"
		text += "\n[color=%s]%s[/color]" % [col, access_hint]

	if not description.is_empty():
		text += "\n" + description
	return text
