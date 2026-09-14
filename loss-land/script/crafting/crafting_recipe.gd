# script/crafting/crafting_recipe.gd
# ============================================
# 合成配方资源 - 描述"用什么材料、做出什么"
#
# 为什么做成 Resource：
#   和 ItemData 一样，配方是纯数据。虽然现在配方在 crafting_system.gd 里
#   用代码构建（Demo 阶段够用），但保留 Resource 形式后，
#   将来可以把每个配方另存成 .tres，在编辑器里可视化调整，不用改代码。
#
# materials 的结构：
#   [{ "item_id": &"wood", "count": 3 }, ...]
#   用 Dictionary 而不是两个平行数组，是为了将来存 .tres 时读写直观。
# ============================================

class_name CraftingRecipe
extends Resource

# ============================================
# 枚举定义
# ============================================

## 配方分类，对应合成界面左侧的标签页
##
## ⚠ 只能往**末尾追加**，禁止插入或重排：分类值会被存档 / .tres 以数字形式记下，
##   重排会让已有配方串到别的分类去。
##
## 前 5 项是**通用栏**（所有角色都能看到）；
## 后 3 项是**专属栏**：只有 craft_category 匹配的角色才会看到该标签页，
## 且配方只在本人游戏里出现（见 CraftingSystem.is_category_visible）。
enum Category {
	MATERIAL,   # 材料（木棍、电池等中间/消耗品）
	TOOL,       # 工具（斧、镐）
	WEAPON,     # 武器（剑）
	ARMOR,      # 护甲
	BUILDING,   # 建筑（工作台、熔炉、储物箱）
	SURVIVAL,   # 专属：求生制作（冒险家）
	ALCHEMY,    # 专属：炼药 / 魔法（魔女）
	MACHINE     # 专属：机械制作（机器人）
}

## 专属栏的第一个值 —— 大于等于它的都是"按角色过滤"的专属栏
const FIRST_EXCLUSIVE: int = 5

## 通用栏（不含专属栏）：合成 UI 建标签页时直接遍历这个数组，
## 加通用分类只改这里 + 上面的 enum 末尾。
const COMMON_CATEGORIES: Array[int] = [
	Category.MATERIAL, Category.TOOL, Category.WEAPON,
	Category.ARMOR, Category.BUILDING,
]

# ============================================
# 配置
# ============================================

## 配方唯一标识
@export var recipe_id: StringName

## 产物物品 ID
@export var output_item_id: StringName

## 产物数量
@export var output_count: int = 1

## 所属分类（决定出现在哪个标签页）
@export var category: Category = Category.TOOL

## 所需材料：[{ "item_id": StringName, "count": int }]
@export var materials: Array[Dictionary] = []

## 需要的制作站（空 = 徒手可合成）
## 例如 &"workbench" / &"furnace"。建造系统实装后才会真正校验。
@export var requires_station: StringName = &""

## 备注（UI 上显示的补充说明）
@export var notes: String = ""

# ============================================
# 方法
# ============================================

# ----------------------------------------
# 获取分类名称函数
# ----------------------------------------
static func category_name(cat: Category) -> String:
	match cat:
		Category.MATERIAL: return "材料"
		Category.TOOL:     return "工具"
		Category.WEAPON:   return "武器"
		Category.ARMOR:    return "护甲"
		Category.BUILDING: return "建筑"
		Category.SURVIVAL: return "求生"
		Category.ALCHEMY:  return "炼药"
		Category.MACHINE:  return "机械"
		_:                 return "其他"


# ----------------------------------------
# 是否专属栏函数
# 专属栏（SURVIVAL / ALCHEMY / MACHINE）只对对应角色显示
# ----------------------------------------
static func is_exclusive(cat: int) -> bool:
	return cat >= FIRST_EXCLUSIVE


# ----------------------------------------
# 获取某个材料的需求数量函数
# 不是该配方的材料时返回 0
# ----------------------------------------
func material_count(item_id: StringName) -> int:
	for m in materials:
		if StringName(m.get("item_id", &"")) == item_id:
			return int(m.get("count", 0))
	return 0


# ----------------------------------------
# 获取全部材料 ID 函数
# ----------------------------------------
func get_material_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for m in materials:
		ids.append(StringName(m.get("item_id", &"")))
	return ids
