# script/resources/data/resource_data.gd
# ============================================
# 资源数据类 - 存储所有资源的配置信息
#
# 什么是 Resource？
# Resource 是 Godot 的资源基类
# 继承它的类可以保存为 .tres 文件，在编辑器中可视化配置
#
# 什么是 @export？
# @export 装饰器让变量在编辑器检查器中可见可编辑
# 用户可以在不修改代码的情况下调整游戏参数
#
# 什么是 StringName？
# StringName 是 Godot 的字符串优化类型
# 用 & 前缀创建，如 &"grass"
# 比普通 String 更高效，适合作为键使用
# ============================================

class_name ResourceData
extends Resource

# ============================================
# 枚举定义
# ============================================

# ----------------------------------------
# 资源类型枚举
# 定义游戏中所有可能的资源类型
# 你可以在这里添加更多类型来扩展游戏
# ----------------------------------------
enum ResourceType {
	GRASS,      # 草
	TWIG,       # 树枝
	TREE,       # 树
	STONE,      # 石头
	BUSH,       # 灌木
	FLOWER,     # 花
	CUSTOM,     # 自定义（用于特殊资源）
	IRON_ORE,   # 铁矿（矿区/火山/雪地，需镐）
	COAL,       # 煤矿（矿区/火山，需镐）
	PEBBLE      # 小石块（空手可捡的碎石，掉落石头；大石头才需要镐）
}

# ============================================
# 基本信息配置
# ============================================
@export_group("基本信息", "")

# 资源的唯一标识符，用于代码中查找资源
# 例如：&"grass"、&"tree"、&"stone"
@export var resource_id: StringName

# 资源的显示名称，用于UI显示
# 例如："草"、"树"、"石头"
@export var display_name: String

# 资源类型，用于分类和特殊逻辑处理
@export var resource_type: ResourceType = ResourceType.GRASS

# ============================================
# 视觉配置
# ============================================
@export_group("视觉", "")

# 生长状态的贴图（完好状态的图片）
# 在编辑器中拖拽图片文件到此处
@export var growing_texture: Texture2D

# 已采集状态的贴图（被采集后的枯萎图片）
@export var harvested_texture: Texture2D

# 生长状态的动画名称
# 需要在 AnimatedSprite3D 的 SpriteFrames 中创建同名动画
@export var growing_animation: String = "grow"

# 已采集状态的动画名称
@export var harvested_animation: String = "harvested"

# 被采集（砍伐/挖掘）时播放的动画名称
# 同样取自 AnimatedSprite3D 的 SpriteFrames，播完停在最后一帧。
# 要与实际作业节奏对齐才有意义：树每挥一下 1 秒（work_interval），chop 是 25 帧 @30fps ≈ 0.83s。
# SpriteFrames 里没有这个动画名时，退回 AnimationPlayer 的 "harvest"。
@export var harvest_animation: String = "chop"

# 状态切换的过渡动画时长（秒）
# 采集后从生长状态切换到已采集状态需要的时间
@export var transition_duration: float = 0.3

# ============================================
# 生成配置
# ============================================
@export_group("生成", "")

# 同类资源之间的最小距离
# 防止资源生成得太密集，看起来更自然
@export var min_distance: float = 2.0

# 初始生成数量
# 游戏开始时在地图上生成的资源数量
@export var initial_count: int = 10

# 每个区块的最大生成数量
# 控制地图上该资源的密度
@export var max_count_per_chunk: int = 10

# 生成权重，数值越大越容易生成
# 用于混合生成多种资源时的概率计算
# 例如：草权重2，石头权重1，则草生成概率是石头的2倍
@export var spawn_weight: float = 1.0

# 禁止生成的层级名称列表
# ["water", "obstacle"] 表示不能在水上和障碍物上生成
@export var prohibited_layers: Array[StringName] = ["water", "obstacle"]

# ============================================
# 采集配置
# ============================================
@export_group("采集", "")

# 是否可以采集
@export var can_harvest: bool = true

# ----------------------------------------
# 工作量：采集就是"把这条血条打空"
#
#   work_amount    资源的工作量总量（相当于血量），累计做满才采得下来。
#                  每次作业扣掉「当前工具的 harvest_work」，扣完才掉落。
#   work_interval  每一"次"作业的耗时（秒）。
#
# 工具的强弱只改"每次做掉多少"（harvest_work），不改挥舞速度——
# 好工具是"每次做得更多"，不是"挥得更快"。
#
# 空手（没装工具 / 工具没配 harvest_work）每次做 1 点，
# 所以空手可采的资源（草、木棍、浆果、小石块）把 work_amount 配成 1 即可，
# 实际手感 = 挥一下 + 等一个 work_interval。
# ----------------------------------------
@export var work_amount: int = 0

# 每一次作业的耗时（秒）
@export var work_interval: float = 1.0

# 工具标签白名单：装备的工具**带有其中任意一个标签**才允许作业。
#
#   填了标签  = 必须带对应工具才能采（树填 [&"axe"]，大石头/矿填 [&"pickaxe"]），
#                空手一律拒绝；
#   留空      = 不设门槛，空手也能采（草、木棍、浆果、小石块）。
#
# 这就是唯一的工具门槛判定，没有任何"工具类型相等"的旧规则做兜底。
@export var allowed_tool_tags: Array[StringName] = []

# 采集后掉落的物品ID
# 这个ID需要与你的物品系统中的物品ID对应
@export var drop_item_id: StringName

# 掉落数量范围
# 实际掉落数量会在范围内随机
@export var drop_count_min: int = 1
@export var drop_count_max: int = 1

# ============================================
# 挖掘配置（铲子功能）
# ============================================
@export_group("挖掘", "")

# 是否可以被铲子挖掘
# 如果为 true，用铲子交互会：
# 1. 移除资源实体
# 2. 掉落"草丛"等特殊物品（不是普通采集的物品）
@export var can_dig: bool = false

# 挖掘后掉落的物品ID（如"草丛"物品）
# 玩家可以用这个物品来种植新的草
@export var dig_drop_item_id: StringName

# 挖掘掉落数量范围
@export var dig_drop_count_min: int = 1
@export var dig_drop_count_max: int = 1

# ============================================
# 再生配置
# ============================================
@export_group("再生", "")

# 是否可以再生
# 石头、树等不可再生资源设为 false
@export var can_regenerate: bool = true

# 再生所需时间（秒）
# 300秒 = 5分钟
# 玩家等待这么久后，草会自动恢复到生长状态
@export var regeneration_time: float = 300.0

# 再生过程的视觉阶段数
# 用于渐进式视觉变化效果
# 例如设为4，再生过程会有4个不同的视觉阶段
@export var regeneration_stages: int = 4

# ============================================
# 种植配置
# ============================================
@export_group("种植", "")

# 是否可以被种植
# 如果为 true，玩家可以把挖掘获得的草丛物品放到地上
@export var can_plant: bool = false

# 用于种植的物品ID
# 玩家背包中有这个物品时，可以在地上种植
@export var plant_item_id: StringName

# ============================================
# 音效配置
# ============================================

# 采集音效
# 玩家成功采集资源时播放
@export var harvest_sound: AudioStream

# 挖掘音效
# 玩家用铲子挖掘时播放
@export var dig_sound: AudioStream

# 再生完成音效
# 资源再生完成时播放
@export var regen_sound: AudioStream

# ============================================
# 工具函数
# ============================================

# ----------------------------------------
# 获取掉落数量函数
# 返回一个随机值，范围在 drop_count_min 到 drop_count_max 之间
#
# 什么是 randi_range？
# randi_range 是 Godot 的随机数函数
# 返回一个在指定范围内的随机整数
#
# 示例：
#   drop_count_min = 1, drop_count_max = 3
#   可能返回 1, 2, 或 3
# ----------------------------------------
func get_drop_count() -> int:
	return randi_range(drop_count_min, drop_count_max)

# ----------------------------------------
# 获取挖掘掉落数量函数
# 返回一个随机值，范围在 dig_drop_count_min 到 dig_drop_count_max 之间
# ----------------------------------------
func get_dig_drop_count() -> int:
	return randi_range(dig_drop_count_min, dig_drop_count_max)


# ----------------------------------------
# 工具标签的中文名（静态）：采集被拒时给玩家看的提示要用
# 按标签取名，不再按已删除的"工具类型枚举"取名
# ----------------------------------------
static func get_tool_tag_name(tag: StringName) -> String:
	match String(tag):
		"axe":
			return "斧头"
		"pickaxe":
			return "镐子"
		"shovel":
			return "铲子"
		"knife":
			return "小刀"
	return "工具"


# ----------------------------------------
# 采集动词（静态）：斧头="砍伐"、镐子="挖掘"，其余笼统说"采集"
# ----------------------------------------
static func get_harvest_verb(tag: StringName) -> String:
	match String(tag):
		"axe":
			return "砍伐"
		"pickaxe":
			return "挖掘"
	return "采集"


# ----------------------------------------
# 主工具标签：白名单里的第一个，用来生成"需要装备X"这类提示
# 没设门槛（白名单为空）时返回空标签
# ----------------------------------------
func primary_tool_tag() -> StringName:
	if allowed_tool_tags.is_empty():
		return &""
	return allowed_tool_tags[0]

# ----------------------------------------
# 工具标签白名单判定
#
# 参数：tool_tags - 当前装备工具身上的标签列表
# 返回：true = 允许作业
#
# 白名单为空时不参与判定（由调用方按"空手可采"处理）。
# ----------------------------------------
func is_tool_tag_allowed(tool_tags: Array[StringName]) -> bool:
	if allowed_tool_tags.is_empty():
		return false
	for t in tool_tags:
		if allowed_tool_tags.has(t):
			return true
	return false
