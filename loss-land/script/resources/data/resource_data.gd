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
    CUSTOM      # 自定义（用于特殊资源）
}

# ----------------------------------------
# 工具类型枚举
# 定义采集该资源需要的工具类型
# NONE 表示不需要任何工具，空手就能采集
# ----------------------------------------
enum HarvestTool {
    NONE,       # 无需工具（如草、树枝）
    AXE,        # 斧头（如树）
    PICKAXE,    # 镐（如石头）
    SHOVEL,     # 铲子（用于挖掘）
    KNIFE       # 小刀
}

# ============================================
# 基本信息配置
# ============================================

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

# 状态切换的过渡动画时长（秒）
# 采集后从生长状态切换到已采集状态需要的时间
@export var transition_duration: float = 0.3

# ============================================
# 生成配置
# ============================================

# 同类资源之间的最小距离
# 防止资源生成得太密集，看起来更自然
@export var min_distance: float = 2.0

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

# 采集所需时间（秒）
# 玩家需要站在原地多久才能完成采集
@export var harvest_time: float = 1.0

# 采集所需的工具类型
# NONE 表示不需要工具
# AXE/PICKAXE 等表示需要对应工具才能采集
@export var required_tool: HarvestTool = HarvestTool.NONE

# 采集后掉落的物品ID
# 这个ID需要与你的物品系统中的物品ID对应
@export var drop_item_id: StringName

# 掉落数量最小值
@export var drop_count_min: int = 1

# 掉落数量最大值
# 实际掉落数量会在 min 和 max 之间随机
@export var drop_count_max: int = 1

# ============================================
# 挖掘配置（铲子功能）
# ============================================

# 是否可以被铲子挖掘
# 如果为 true，用铲子交互会：
# 1. 移除资源实体
# 2. 掉落"草丛"等特殊物品（不是普通采集的物品）
@export var can_dig: bool = false

# 挖掘后掉落的物品ID（如"草丛"物品）
# 玩家可以用这个物品来种植新的草
@export var dig_drop_item_id: StringName

# 挖掘掉落数量
@export var dig_drop_count: int = 1

# ============================================
# 再生配置
# ============================================

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

# 是否可以被种植
# 如果为 true，玩家可以把挖掘获得的草丛物品放到地上
@export var can_be_planted: bool = false

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
