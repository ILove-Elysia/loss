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
