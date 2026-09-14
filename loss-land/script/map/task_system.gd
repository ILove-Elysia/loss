# ============================================================
# 任务系统：地图数据定义
#
# 本脚本是地图生成的"数据中心"，定义了：
#   1. 危险等级（DANGER）
#   2. 地图分层（TIERS）：内圈/中圈/外圈
#   3. 所有任务区域（TASKS）：6 个生物群系
#   4. 任务间的连接关系（TASK_LINKS）
#   5. 地形类型颜色映射（TERRAIN_COLOR_MAP）
#   6. 查询辅助函数
#
# 分层结构（参考饥荒的 concentric layout）：
#   Tier 0 内圈 → 草原区（安全，出生点）
#   Tier 1 中圈 → 丛林/矿区/沙地（中等危险）
#   Tier 2 外圈 → 火山/雪地（高危险）
#
# 地形类型编码：
#   0  = 未开发地表（默认地面色）
#   7  = 海洋（不可通行）
#   8  = 沙滩（岛屿边缘）
#   10 = 草原（Grassland）
#   11 = 丛林（Forest）
#   12 = 岩石（Rocky）
#   13 = 沙地（Savanna）
#   14 = 火山（Marsh）
#   15 = 雪地（Badlands）
#
# 依赖关系：
#   - map_generator.gd / map_generator_3d.gd 通过 task_system 获取数据
#   - layout.gd 使用 TASK_LINKS 进行力导向布局
#   - room_chain.gd 使用 task.rooms 配置生成房间链
# ============================================================
extends RefCounted


# ============================================================
# 危险等级常量
# 用于在 UI 中显示不同危险级别的颜色标识
# SAFE  = 0 → 绿色（安全区域，初始出生点）
# MEDIUM = 2 → 黄色（中等危险，有敌对生物）
# HIGH   = 3 → 红色（高度危险，需要高级装备）
# ============================================================
const DANGER = {
	SAFE = 0,
	MEDIUM = 2,
	HIGH = 3,
}


# ============================================================
# 地图分层（同心圆环布局）
# INNER  = 0 → 内圈（中心区域，安全）
# MIDDLE = 1 → 中圈（过渡区域，中等危险）
# OUTER  = 2 → 外圈（边缘区域，高危险）
#
# 布局逻辑由 layout.gd 实现：
#   - INNER 半径 ≈ 10 瓦片
#   - MIDDLE 半径 ≈ 50 瓦片
#   - OUTER 半径 ≈ 110 瓦片
# ============================================================
const TIERS = {
	INNER = 0,
	MIDDLE = 1,
	OUTER = 2,
}


# ============================================================
# 任务（区域）定义列表
# 每个任务代表地图上的一个生物群系（Biome）
#
# 字段说明：
#   id:            唯一标识符（英文，用于 TASK_LINKS 引用）
#   name:          显示名称（中文，用于 UI 标签）
#   color:         地形颜色（用于 TERRAIN_COLOR_MAP 和渲染）
#   terrain_type:  地形类型编号（写入 map_data 的值）
#   tier:          所在分层（0/1/2）
#   danger_level:  危险等级（0/2/3）
#   is_start:      是否为出生点（仅草原区为 true）
#   enemies:       该区域的敌人列表
#   special_points: 该区域的特殊兴趣点
#   rooms:         房间链配置 [{template, role}, ...]
#     - template: 房间模板名（预留扩展，当前未使用）
#     - role:     房间角色（entrance/middle/exit）
# ============================================================
const TASKS: Array = [
	# --------------------------------------------------------
	# 1. 草原区（Grassland）—— 出生点所在
	# Tier 0（内圈），SAFE 危险等级
	# 3 个房间：入口（CLEARING）→ 中间（GRASS）→ 出口（GRASS）
	# --------------------------------------------------------
	{
		id = "Grassland",
		name = "草原区",
		color = Color(0.7, 0.85, 0.5),
		terrain_type = 10,
		tier = TIERS.INNER,
		danger_level = DANGER.SAFE,
		is_start = true,
		enemies = [],
		special_points = ["出生点"],
		rooms = [
			{ template = "CLEARING", role = "entrance" },
			{ template = "GRASS",    role = "middle" },
			{ template = "GRASS",    role = "exit" },
		],
	},

	# --------------------------------------------------------
	# 2. 丛林区（Forest）—— Tier 1（中圈），MEDIUM 危险等级
	# 敌人：史莱姆、绿叶蛞蝓
	# 3 个房间：全部 FOREST 模板
	# --------------------------------------------------------
	{
		id = "Forest",
		name = "丛林区",
		color = Color(0.1, 0.6, 0.1),
		terrain_type = 11,
		tier = TIERS.MIDDLE,
		danger_level = DANGER.MEDIUM,
		is_start = false,
		enemies = ["史莱姆", "绿叶蛞蝓"],
		special_points = ["丛林遗迹", "根须桥"],
		rooms = [
			{ template = "FOREST", role = "entrance" },
			{ template = "FOREST", role = "middle" },
			{ template = "FOREST", role = "exit" },
		],
	},

	# --------------------------------------------------------
	# 3. 矿区（Rocky）—— Tier 1（中圈），MEDIUM 危险等级
	# 敌人：史莱姆、小型无人机
	# 房间序列：ROCKY → MOUNTAIN → ROCKY（岩石与山地混合）
	# --------------------------------------------------------
	{
		id = "Rocky",
		name = "矿区",
		color = Color(0.55, 0.55, 0.55),
		terrain_type = 12,
		tier = TIERS.MIDDLE,
		danger_level = DANGER.MEDIUM,
		is_start = false,
		enemies = ["史莱姆", "小型无人机"],
		special_points = ["矿区地陷"],
		rooms = [
			{ template = "ROCKY",    role = "entrance" },
			{ template = "MOUNTAIN", role = "middle" },
			{ template = "ROCKY",    role = "exit" },
		],
	},

	# --------------------------------------------------------
	# 4. 沙地区（Savanna）—— Tier 1（中圈），MEDIUM 危险等级
	# 敌人：变异鸦群
	# 3 个房间：全部 SAVANNA 模板
	# --------------------------------------------------------
	{
		id = "Savanna",
		name = "沙地区",
		color = Color(0.95, 0.88, 0.45),
		terrain_type = 13,
		tier = TIERS.MIDDLE,
		danger_level = DANGER.MEDIUM,
		is_start = false,
		enemies = ["变异鸦群"],
		special_points = ["破损船只", "沙地地陷"],
		rooms = [
			{ template = "SAVANNA", role = "entrance" },
			{ template = "SAVANNA", role = "middle" },
			{ template = "SAVANNA", role = "exit" },
		],
	},

	# --------------------------------------------------------
	# 5. 火山区（Marsh）—— Tier 2（外圈），HIGH 危险等级
	# 敌人：核污染生物、变异鸦群
	# 房间序列：BADLANDS → ROCKY → BADLANDS（荒地与岩石混合）
	# 注意：terrain_type=14 对应红色火山地形
	# --------------------------------------------------------
	{
		id = "Marsh",
		name = "火山区",
		color = Color(0.85, 0.25, 0.15),
		terrain_type = 14,
		tier = TIERS.OUTER,
		danger_level = DANGER.HIGH,
		is_start = false,
		enemies = ["核污染生物", "变异鸦群"],
		special_points = ["黑曜矿脉"],
		rooms = [
			{ template = "BADLANDS", role = "entrance" },
			{ template = "ROCKY",    role = "middle" },
			{ template = "BADLANDS", role = "exit" },
		],
	},

	# --------------------------------------------------------
	# 6. 雪地区（Badlands）—— Tier 2（外圈），HIGH 危险等级
	# 敌人：机械守卫、核污染生物
	# 房间序列：MARSH → ROCKY → MARSH（沼泽与岩石混合）
	# 注意：terrain_type=15 对应蓝白色雪地地形
	# --------------------------------------------------------
	{
		id = "Badlands",
		name = "雪地区",
		color = Color(0.75, 0.85, 0.95),
		terrain_type = 15,
		tier = TIERS.OUTER,
		danger_level = DANGER.HIGH,
		is_start = false,
		enemies = ["机械守卫", "核污染生物"],
		special_points = ["山顶气象台"],
		rooms = [
			{ template = "MARSH",   role = "entrance" },
			{ template = "ROCKY",   role = "middle" },
			{ template = "MARSH",   role = "exit" },
		],
	},
]


# ============================================================
# 任务连接关系
# 定义任务之间的邻接关系，用于：
#   1. layout.gd 的力导向布局（确定节点间的吸引力）
#   2. map_generator.gd 的道路生成（create_task_link_roads）
#   3. room_chain.gd 的房间链方向计算
#
# 连接规则（树结构，无环）：
#   内圈 ↔ 中圈：Grassland 连接 Forest/Rocky/Savanna（3 条）
#   中圈 ↔ 中圈：两两互连（形成环形过渡带）
#   中圈 ↔ 外圈：Forest→Marsh, Rocky→Badlands, Savanna→Marsh/Badlands
#   外圈 ↔ 外圈：Marsh↔Badlands
#
# 共 11 条连接，形成 3 个独立的"扇区"路径：
#   路径 A：Grassland → Forest → Marsh
#   路径 B：Grassland → Rocky → Badlands
#   路径 C：Grassland → Savanna → Marsh/Badlands
# ============================================================
const TASK_LINKS: Array = [
	# --- 内圈 → 中圈（3 条主路径）---
	{ from = "Grassland", to = "Forest"   },
	{ from = "Grassland", to = "Rocky"    },
	{ from = "Grassland", to = "Savanna"  },

	# --- 中圈 ↔ 中圈（互连形成环形）---
	{ from = "Forest",  to = "Rocky"    },
	{ from = "Rocky",   to = "Savanna"  },
	{ from = "Savanna", to = "Forest"   },

	# --- 中圈 → 外圈（3 条延伸路径）---
	{ from = "Forest",  to = "Marsh"    },
	{ from = "Rocky",   to = "Badlands" },
	{ from = "Savanna", to = "Marsh"    },
	{ from = "Savanna", to = "Badlands" },

	# --- 外圈 ↔ 外圈（1 条横向连接）---
	{ from = "Marsh",    to = "Badlands" },
]


# ============================================================
# 地形类型 → 颜色映射表
# 用于渲染阶段获取地形颜色
#
# 地形类型编号说明：
#   0  = 未开发地面（灰棕色，默认地表）
#   7  = 海洋（蓝色，不可通行）
#   8  = 沙滩（浅黄色，岛屿边缘过渡）
#   10 = 草原（浅绿色）
#   11 = 丛林（深绿色）
#   12 = 岩石（灰色）
#   13 = 沙地（金黄色）
#   14 = 火山（红色）
#   15 = 雪地（浅蓝色）
#
# 注意：terrain_type=7（海洋）是唯一不可通行的地形
#       其余所有地形均可通行（is_terrain_walkable 检测）
# ============================================================
const TERRAIN_COLOR_MAP: Dictionary = {
	0: Color(0.65, 0.60, 0.55),
	7: Color(0.25, 0.50, 0.75),
	8: Color(0.98, 0.92, 0.68),
	10: Color(0.7, 0.85, 0.5),
	11: Color(0.1, 0.6, 0.1),
	12: Color(0.55, 0.55, 0.55),
	13: Color(0.95, 0.88, 0.45),
	14: Color(0.85, 0.25, 0.15),
	15: Color(0.75, 0.85, 0.95),
}


# ============================================================
# 查询函数组
# 供 map_generator.gd / map_generator_3d.gd / layout.gd 调用
# ============================================================


# 获取所有任务列表（返回 TASKS 常量引用）
func get_all_tasks() -> Array:
	return TASKS


# 获取所有任务连接（返回 TASK_LINKS 常量引用）
func get_all_links() -> Array:
	return TASK_LINKS


# 按 ID 查找任务
# 参数：task_id — 任务 ID 字符串（如 "Grassland"）
# 返回：任务字典（找不到时返回空字典 {}）
# 用途：map_generator.gd 中通过 id 获取任务配置
func get_task_by_id(task_id: String) -> Dictionary:
	for task in TASKS:
		if task.id == task_id:
			return task
	return {}


# 获取出生点任务
# 返回 is_start=true 的任务（即 Grassland 草原区）
# 若没有任何任务标记 is_start，则回退到 TASKS[0]
# 用途：map_generator_3d.gd 的 teleport_player_to_start()
func get_start_task() -> Dictionary:
	for task in TASKS:
		if task.get("is_start", false):
			return task
	return TASKS[0]


# ============================================
# 区域（生物群系）→ 可产出资源 ID 映射表
#
# 这是"资源按区域分布"的唯一权威表：
#   is_resource_allowed_in_region() → 判断某区域是否产出某资源
#   get_resource_terrain_types()    → 反查某资源允许出现在哪些地形
# 资源生成器（resource_spawner）据此在**目标地形的瓦片里直接采样**，
# 而不是"全图乱撒再过滤"——后者在资源只属于小区域时（如火山区煤炭）
# 绝大多数候选会被否决，尝试次数耗尽后数量严重不足。
#
# 用户 2026-09-12 指定的配置：
#   草原区 → 木棍 twig / 草 grass / 树 tree / 浆果 berry / 小石块 pebble
#   丛林区 → 木棍 twig / 草 grass / 树 tree / 浆果 berry / 小石块 pebble
#   矿区   → 小石块 pebble / 石头 stone / 铁矿 iron_ore（无植被，须自带工具）
#   火山区 → 煤炭 coal / 铁矿 iron_ore（燃料与金属，无植被）
#   雪山区 → 木棍 twig / 小石块 pebble（寒带荒芜）
#   沙地区 → 木棍 twig / 小石块 pebble
#   沙滩   → 木棍 twig / 小石块 pebble（岛缘沙带，见 BEACH_REGION_ID）
#
# 设计后果（有意为之）：
#   - 石头 stone 只在矿区：想升级到石制 / 铁制工具，必须冒险进入矿区；
#   - 树 / 草 / 浆果集中在草原与丛林，构成"植被带"；
#   - 煤炭只在火山区，是远处的高阶燃料。
#
# 兼容策略：没写进本表的资源 → 视为不限制区域（向后兼容），
#   避免新加资源因漏登记而一个都刷不出来。
# ============================================

# 沙滩的"虚拟区域 ID"
#
# 沙滩（terrain 8）在 TASKS 里没有对应任务区，get_task_by_terrain() 返回空。
# 但它同样要产出零散资源（木棍 / 小石块），因此在映射表里给它一个虚拟区域 ID，
# 由 get_region_terrain_type() 负责与地形号 8 互相对应。
const BEACH_REGION_ID: String = "Beach"

# 地形编号常量（避免各处裸写魔数）
const TERRAIN_OCEAN: int = 7    # 海洋
const TERRAIN_BEACH: int = 8    # 沙滩

const REGION_RESOURCE_MAP: Dictionary = {
	"Grassland": ["twig", "grass", "tree", "berry", "pebble"],  # 草原区（出生安全区）
	"Forest":    ["twig", "grass", "tree", "berry", "pebble"],  # 丛林区（同为植被带）
	"Rocky":     ["pebble", "stone", "iron_ore"],               # 矿区
	"Marsh":     ["coal", "iron_ore"],                          # 火山区
	"Badlands":  ["twig", "pebble"],                            # 雪地区
	"Savanna":   ["twig", "pebble"],                            # 沙地区
	BEACH_REGION_ID: ["twig", "pebble"],                        # 沙滩（岛缘沙带）
}


# 按地形编号反查所属区域任务
# 参数：terrain_type — 地图数据中的地形编号（10 草原 / 11 丛林 / 12 矿区 ……）
# 返回：任务字典；沙滩 8 / 海洋 7 / 道路 0 不属于任何区域，返回空字典 {}
# 用途：资源生成器据此判断"这个坐标脚下是哪个区"
func get_task_by_terrain(terrain_type: int) -> Dictionary:
	for task in TASKS:
		if int(task.get("terrain_type", -1)) == terrain_type:
			return task
	return {}


# 判断某种资源是否允许出现在某个区域
#
# 参数：
#   region_id   — 区域 ID（"Grassland" / "Savanna" / "Marsh" / "Badlands" ……）
#   resource_id — 资源 ID（"grass" / "stone" / "tree" ……）
#
# 返回：bool
#   true  = 允许
#   false = 该区域明确登记了资源列表，但不包含此资源
#
# 兼容策略（重要）：
#   区域未登记、或登记的列表为空时一律放行。
#   这样新加入的资源即使忘记更新 REGION_RESOURCE_MAP，
#   也只会退化成"全图可刷"，而不会一个都刷不出来。
func is_resource_allowed_in_region(region_id: String, resource_id: String) -> bool:
	if not REGION_RESOURCE_MAP.has(region_id):
		return true
	var allow_list: Array = REGION_RESOURCE_MAP[region_id]
	if allow_list.is_empty():
		return true
	return allow_list.has(resource_id)


# 查询某个资源允许出现在哪些区域
# 参数：resource_id — 资源 ID（如 &"grass"、&"tree"）
# 返回：区域 ID 数组（["Grassland"] 等）；返回空数组表示该资源未登记 → 不限制区域
func get_resource_regions(resource_id: StringName) -> Array:
	var regions: Array = []
	var rid: String = str(resource_id)
	for region_id in REGION_RESOURCE_MAP:
		var allow_list: Array = REGION_RESOURCE_MAP[region_id]
		if allow_list.has(rid):
			regions.append(region_id)
	return regions


# 区域 ID → 地形编号
#
# 用途：资源生成器要把"区域"换算成"地图上的地形号"，才能去对应的瓦片池里采样。
#   "Grassland" → 10、"Forest" → 11 …… 由 TASKS 表提供；
#   沙滩是虚拟区域（不在 TASKS 里），单独映射到 TERRAIN_BEACH。
#
# 参数：region_id — 区域 ID（"Grassland" / "Beach" ……）
# 返回：地形编号；未知区域返回 -1
func get_region_terrain_type(region_id: String) -> int:
	if region_id == BEACH_REGION_ID:
		return TERRAIN_BEACH
	for task in TASKS:
		if str(task.get("id", "")) == region_id:
			return int(task.get("terrain_type", -1))
	return -1


# 不属于任何任务区、但仍有资源配置的特殊地形 → 虚拟区域 ID
#
# 目前只有沙滩（terrain 8）。海洋（7）与道路（0）返回空字符串，表示不产资源。
# 供 map_generator_3d.is_resource_allowed_at() 判断"这块地属于哪个区域"。
func get_special_region_id(terrain_type: int) -> String:
	if terrain_type == TERRAIN_BEACH:
		return BEACH_REGION_ID
	return ""


# 反查某个资源允许出现在哪些地形上（资源生成器的采样依据）
#
# 与 get_resource_regions() 的区别：这里把区域 ID 进一步换算成地形编号，
# 生成器拿到地形号后即可直接去 map_generator_3d 的地形瓦片池里采样。
#
# 参数：resource_id — 资源 ID（"grass" / "coal" ……）
# 返回：地形编号数组（如 "tree" → [10, 11]）；空数组 = 该资源未登记 → 不限制区域
func get_resource_terrain_types(resource_id: String) -> Array[int]:
	var out: Array[int] = []
	for region_id in REGION_RESOURCE_MAP:
		var allow_list: Array = REGION_RESOURCE_MAP[region_id]
		if not allow_list.has(resource_id):
			continue
		var terrain: int = get_region_terrain_type(str(region_id))
		if terrain >= 0 and not out.has(terrain):
			out.append(terrain)
	return out



# 获取指定地形类型的颜色
# 参数：terrain_type — 地形类型编号（0-15）
# 返回：对应 Color（未知类型返回灰色 0.5,0.5,0.5）
# 用途：render_map_3d() 中按 terrain_type 分组渲染
func get_terrain_color(terrain_type: int) -> Color:
	if TERRAIN_COLOR_MAP.has(terrain_type):
		return TERRAIN_COLOR_MAP[terrain_type]
	return Color(0.5, 0.5, 0.5)


# 判断地形是否可通行
# 规则：terrain_type != 7（海洋）即可通行
# 其他所有地形（包括沙滩 8 和所有生物群系 10-15）均可通行
# 用途：_build_floor_collisions() 中过滤可通行瓦片
func is_terrain_walkable(terrain_type: int) -> bool:
	return terrain_type != 7


# 获取危险等级对应的 UI 显示颜色
# SAFE   → 绿色 (0.2, 0.8, 0.2) — 安全
# MEDIUM → 黄色 (1.0, 0.8, 0.0) — 中等
# HIGH   → 红色 (1.0, 0.3, 0.2) — 高危
# 未知   → 灰色 (0.5, 0.5, 0.5) — 未分类
# 用途：UI 界面显示危险区域标识
func get_danger_color(danger_level: int) -> Color:
	match danger_level:
		DANGER.SAFE:
			return Color(0.2, 0.8, 0.2)
		DANGER.MEDIUM:
			return Color(1.0, 0.8, 0.0)
		DANGER.HIGH:
			return Color(1.0, 0.3, 0.2)
		_:
			return Color(0.5, 0.5, 0.5)
