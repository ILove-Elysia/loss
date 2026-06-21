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
enum ItemType {
	RESOURCE,    # 资源类（草、木头、石头等）
	TOOL,        # 工具类（斧头、镐、铲子等）
	FOOD,        # 食物类（浆果、肉等）
	MATERIAL,    # 材料类（布料、金属等）
	QUEST,       # 任务物品
	MISC         # 杂项
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
		_:                  return "未知"

# ----------------------------------------
# 获取完整描述函数
# 返回包含名称、类型、描述的格式化文本
# ----------------------------------------
func get_full_description() -> String:
	var text = "[color=%s]%s[/color]\n" % [get_rarity_color().to_html(), display_name]
	text += "[i]类型: %s[/i]\n" % get_type_name()
	if not description.is_empty():
		text += "\n" + description
	return text
