# ============================================================
# 3D 地图生成器
#
# 架构说明：
#   本脚本是 map_generator.gd 的 3D 版本，复用其生成逻辑（数据层），
#   但替换渲染层和碰撞层为 3D 实现。
#
#   核心流程：
#     1. 加载 2D 生成器（map_generator.gd）作为数据引擎
#     2. 重写其内部子系统引用（task_system/layout/chain_gen）
#     3. 调用 2D 生成器的 6 步流水线生成地图数据（map_data）
#     4. 把 2D 数据渲染为 3D MultiMesh（高效渲染数万个瓦片）
#     5. 构建合并的 3D 碰撞体（供角色行走）
#     6. 计算出生点的 3D 世界坐标并传送玩家
#
#   性能优化：
#     - MultiMesh：相同地形的瓦片合并为一个 MultiMeshInstance3D
#       400×400=160K 瓦片，但只有 9 个 MultiMesh（按地形类型分）
#     - 碰撞合并：同一行上连续的可通行瓦片合并为一个 BoxShape3D
#       减少碰撞体数量，提高物理性能
#
# 坐标系统：
#   map_data[y * MW + x] 中的 (x, y) 是瓦片坐标
#   3D 世界坐标转换：
#     world_x = (tile_x - MAP_WIDTH/2) * TILE_SIZE   → 左右方向
#     world_z = (tile_y - MAP_HEIGHT/2) * TILE_SIZE  → 前后方向
#     world_y = 0.0                                  → 地面高度
#   中心瓦片 (MAP_WIDTH/2, MAP_HEIGHT/2) 位于世界原点 (0, 0, 0)
# ============================================================
extends Node3D

# ------------------------------------------------------------
# 外部脚本路径常量
# 用于 _ready 中动态加载 2D 生成器及子系统
# ------------------------------------------------------------

# 2D 地图生成器（核心数据引擎）
const GEN_2D_PATH = "res://script/map/map_generator.gd"

# 三个子系统脚本路径（用于重写 2D 生成器内部的引用）
const TASK_SYSTEM_PATH = "res://script/map/task_system.gd"
const LAYOUT_PATH = "res://script/map/layout.gd"
const ROOM_CHAIN_PATH = "res://script/map/room_chain.gd"

# 敌人预制体（出生点测试敌人用）
const SLIME_SCENE_PATH = "res://tscn/prefab/slime.tscn"
const DRONE_SCENE_PATH = "res://tscn/prefab/drone.tscn"


# ------------------------------------------------------------
# 标签样式常量
# 3D 标签（Label3D）的像素大小和字号
# ------------------------------------------------------------

# 普通任务标签：较小
# 主项目为正常人物尺度（玩家高约 1 单位、相机距离约 3 单位），
# 字高约 0.5 世界单位（font_size 32 × pixel_size 0.015）
const LABEL_PIXEL_SIZE = 0.015   # 每个像素的 3D 世界尺寸（米）
const LABEL_FONT_SIZE = 32       # 字体大小

# 出生点标签：更大更醒目（字高约 0.8 世界单位）
const START_LABEL_PIXEL_SIZE = 0.02
const START_LABEL_FONT_SIZE = 40

# 海面高度（陆地瓦片在 y=0，海面略低，形成"岛"的观感）
const OCEAN_Y = -0.25


# ------------------------------------------------------------
# 运行时引用
# ------------------------------------------------------------

# 2D 生成器实例（数据引擎）
# 通过 _gen.map_data 访问地图数据，_gen.task_system 访问地形配置
var _gen = null

# 3D 瓦片容器：所有 MultiMeshInstance3D 作为其子节点
var tile_container: Node3D = null

# 碰撞体容器：FloorStaticBody 作为其子节点
var collision_container: Node3D = null

# 玩家角色的 CharacterBody3D 节点引用
# 用于传送出生点时直接操作其位置和速度
var _player_char: CharacterBody3D = null

# 按地形类型分组的所有瓦片世界坐标（render_map_3d 时顺带收集）
#
# 结构：{ terrain_type: Array[Vector3(world_x, 0, world_z)] }（不含海洋）
#
# 用途：资源系统需要"只在某个区域的地面上"取点。地图只有约两成是陆地，
# 若靠"全图随机 + 事后按区域过滤"，绝大多数候选会白费（尤其煤炭只长在火山区）。
# 有了这张表就能在目标地形内直接均匀采样，数量精确可控。
var _terrain_positions: Dictionary = {}


# ============================================================
# 节点就绪：初始化容器 + 加载生成器 + 执行生成
#
# 步骤：
#   1. 加入 "map_gen" 组（供 player_controller.gd 查找）
#   2. 创建 TileContainer3D（瓦片渲染容器）
#   3. 创建 FloorCollisionContainer（碰撞体容器）
#   4. 加载 2D 生成器并重写其子系统
#   5. 执行生成流水线（仅数据层，不渲染）
#   6. 渲染 3D 瓦片
#   7. 构建碰撞体
#   8. 传送玩家到出生点
# ============================================================
func _ready():
	# 加入 map_gen 组，player_controller.gd 通过此组查找生成器
	add_to_group("map_gen")

	# 创建 3D 瓦片渲染容器
	tile_container = Node3D.new()
	tile_container.name = "TileContainer3D"
	add_child(tile_container)

	# 创建碰撞体容器
	collision_container = Node3D.new()
	collision_container.name = "FloorCollisionContainer"
	add_child(collision_container)

	# 加载 2D 生成器作为数据引擎
	_gen = load(GEN_2D_PATH).new()

	# 重写 2D 生成器内部的子系统引用
	# （原 _ready 中用 @onready 加载，这里直接替换为新实例）
	_gen.task_system = load(TASK_SYSTEM_PATH).new()
	_gen.layout = load(LAYOUT_PATH).new()
	_gen.chain_gen = load(ROOM_CHAIN_PATH).new()
	# 地图种子：读档时必须用存档记录的种子复现同一张地图，否则存档里的
	# 资源与建筑坐标会落到另一张随机地形上（漂到海里或悬在半空）。
	# 新开局（种子 0）则现摇一个并回写，好让第一次保存把它记进存档。
	if SaveManager.pending_map_seed != 0:
		_gen.rng.seed = SaveManager.pending_map_seed
		# 光设 _gen.rng 还不够：layout.gd / room_chain.gd 里有几处裸的
		# randf_range()（走的是 Godot 全局随机，不经过 rng），
		# 不把全局种子一起设成同一个值，同一张存档每次读出来的岛屿
		# 轮廓都会抖一点，存档里的资源/建筑就会歪到海里或半空。
		seed(SaveManager.pending_map_seed)
	else:
		_gen.rng.randomize()
		SaveManager.pending_map_seed = _gen.rng.seed

	# 执行生成流水线 → 填充 _gen.map_data
	_run_generation()

	# 地形快照优先：存档里带了地皮就用它盖掉刚算出来的地形。
	# 读档时"种子 + 当前算法"未必还能算出当年那座岛（算法改过就会变），
	# 而存档里的资源与建筑坐标是当年那座岛的 —— 以快照为准才不会错位。
	_apply_terrain_snapshot()

	# 渲染 3D 瓦片（读取 _gen.map_data）
	render_map_3d()

	# 构建碰撞体（供角色行走）
	_build_floor_collisions()

	# 传送玩家到出生点
	teleport_player_to_start()

	# 出生点旁放置测试材料储物箱（实机验证建造/合成系统用）。
	# 读档时必须跳过：存档里已经记录了这口箱子，再放一个就重复了
	# （而且每读一次档就多一口，箱子会越攒越多）。
	if not SaveManager.has_pending_load():
		_spawn_test_storage_box()

	# 放置敌人到对应区域（如史莱姆 → 丛林区）
	_place_enemies()

	# 出生点旁放置测试敌人（实机验证战斗系统用）。
	# 注意：这里【不做读档跳过】。敌人的恢复机制是"按节点路径匹配"——
	# 存档里有的落位回血、存档里没有的删掉。若读档时不生成这两个节点，
	# 存档里记录着它们的路径却找不到节点，就只能警告跳过，
	# 结果"存过档再读，出生点的测试怪凭空消失"。
	# 无条件生成后，SaveManager._apply_enemies 会按存档把已经被击杀的删掉。
	_spawn_test_enemies()


# ============================================================
# 查找玩家 CharacterBody3D
#
# 主项目（loss-land）的玩家结构为：
#   player (Node3D, groups=["player"])
#     └─ Physics (CharacterBody3D)   ← 实际角色体
#     └─ Camera_controller/Camera_Target/Camera3D（跟随相机）
#
# 与测试项目不同：主项目相机是玩家子节点，会自动跟随玩家移动，
# 因此地图生成器无需再同步摄像机目标，也无需 CameraTarget 节点。
#
# 查找策略：按类型递归查找第一个 CharacterBody3D，
# 避免依赖节点名称（"Physics" 或 "CharacterBody3D" 都能找到）。
# ============================================================
func _find_player_body() -> CharacterBody3D:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return null
	var player_root: Node = players[0]
	# find_children 按类型递归查找第一个 CharacterBody3D
	var bodies: Array = player_root.find_children("*", "CharacterBody3D", true, false)
	if bodies.is_empty():
		return null
	return bodies[0] as CharacterBody3D


# ============================================================
# 执行 2D 生成流水线（数据层）
#
# 复用 map_generator.gd 的 6 步生成逻辑：
#   init_map_data → layout_tasks → generate_room_chains
#   → stamp_room_terrain → create_task_link_roads → build_island_base
#
# 不调用 render_map()（2D 渲染），因为我们需要 3D 渲染
# 执行后 _gen.map_data 填充完整的地图数据
# ============================================================
func _run_generation():
	_gen.init_map_data()
	_gen.task_positions = {}
	_gen.room_chains = {}

	_gen.layout_tasks()
	_gen.generate_room_chains()
	_gen.stamp_room_terrain()
	_gen.fill_region_territories()
	_gen.create_task_link_roads()
	_gen.build_island_base()


# ============================================================
# 用地形快照覆盖生成结果（读档时）
#
# 生成流水线照常跑完（出生点、区域领地、房间链这些派生数据都要它），
# 但地形本身换成存档里的那一份 —— 于是"生成算法改没改过"与老存档无关了。
#
# 快照用完立即清空：否则"读档 → 回主菜单 → 新建游戏"会把上一档的岛带过去。
# 尺寸对不上（存档来自更早的地图尺寸）则丢弃快照，按种子重新生成。
# ============================================================
func _apply_terrain_snapshot():
	var tiles: PackedByteArray = SaveManager.pending_map_tiles
	if tiles.is_empty():
		return
	var map_w: int = int(_gen.MAP_WIDTH)
	var map_h: int = int(_gen.MAP_HEIGHT)
	var stored_size: Vector2i = SaveManager.pending_map_size
	var size_bad: bool = tiles.size() != map_w * map_h
	if stored_size.x > 0 and stored_size != Vector2i(map_w, map_h):
		size_bad = true
	if size_bad:
		DebugConfig.warn_msg(DebugConfig.CAT_TERRAIN,
			"[地图] 存档地形尺寸不符（存档 %d×%d / %d 字节，当前 %d×%d），按种子重新生成地形",
			[stored_size.x, stored_size.y, tiles.size(), map_w, map_h])
		SaveManager.clear_pending_map_tiles()
		return
	# 诊断：比一下"当前算法算出来的地形"与"存档里的地形"。
	# 不一致 = 生成算法在存档之后改过。以前这种改动会静默毁掉所有老存档
	# （建筑落水、资源悬空且不报错），现在它只是日志里的一句话。
	var stored_hash: String = SaveManager.pending_map_hash
	if stored_hash != "":
		var fresh_hash := SaveManager.sha256_hex(get_terrain_bytes())
		if fresh_hash != stored_hash:
			DebugConfig.log_msg(DebugConfig.CAT_TERRAIN,
				"[地图] 生成算法结果与存档地形不一致（算法已变更）→ 按存档快照还原，本档不受影响", [])
	# duplicate：map_data 后续会被渲染/资源系统读取，别和静态变量共用同一份内存
	_gen.map_data = tiles.duplicate()
	SaveManager.clear_pending_map_tiles()
	DebugConfig.log_msg(DebugConfig.CAT_TERRAIN,
		"[地图] 已从存档还原地形（%d × %d），未使用随机生成结果",
		[int(_gen.MAP_WIDTH), int(_gen.MAP_HEIGHT)])


# ============================================================
# 地形导出（存档保存用）
#
# 保存时从"场景里那张真实的地图"取，而不是从缓存 ——
# 将来地形可被玩家改动（挖地 / 铺路）时，存档自动跟着更新。
# ============================================================

## 当前地图的地皮字节（扁平数组，长度 = 宽 × 高，1 字节/格）
func get_terrain_bytes() -> PackedByteArray:
	var src: Variant = _gen.map_data
	if src is PackedByteArray:
		return src
	# 防御：万一哪天 map_data 又被换回普通 Array，也照样能存下来
	if src is Array:
		return PackedByteArray(src)
	# 取不到就返回空 → 存档不写地图段（下次读档按种子重算），不崩
	return PackedByteArray()

func get_map_width() -> int:
	return int(_gen.MAP_WIDTH)

func get_map_height() -> int:
	return int(_gen.MAP_HEIGHT)


# ============================================================
# 渲染 3D 瓦片（MultiMesh 优化）
#
# 核心思路：按地形类型分组，每种地形用一个 MultiMesh 渲染
#   1. 遍历所有瓦片，按 terrain_type 分组并计算 3D 世界坐标
#   2. 对每组地形创建一个 MultiMeshInstance3D
#      - 用 PlaneMesh 作为单元网格（尺寸 = TILE_SIZE × TILE_SIZE）
#      - 把所有瓦片位置作为 MultiMesh 实例
#      - 设置地形对应的颜色（shading_mode=UNSHADED 保持纯色）
#
# 性能：
#   160K 瓦片 → 仅 9 个绘制调用（按地形类型分组）
#   相比每瓦片一个 MeshInstance3D，性能提升约 1000 倍
#
# 坐标转换：
#   world_pos = (tile_coord - map_center) * TILE_SIZE
#   瓦片坐标 (0,0) → 世界 (-half_w*TS, 0, -half_h*TS)
#   瓦片坐标 (MAP_WIDTH/2, MAP_HEIGHT/2) → 世界 (0, 0, 0)
# ============================================================
func render_map_3d():
	# 清除旧瓦片
	for child in tile_container.get_children():
		tile_container.remove_child(child)
		child.queue_free()

	var MW: int = _gen.MAP_WIDTH
	var MH: int = _gen.MAP_HEIGHT
	var TS: int = _gen.TILE_SIZE

	# 地图中心偏移量（用于坐标转换）
	var half_w: float = MW / 2.0
	var half_h: float = MH / 2.0

	# 按地形类型分组瓦片位置
	# by_terrain: { terrain_type: [Vector3(world_x, 0, world_z), ...] }
	#
	# 海洋瓦片（terrain=7）不生成网格：
	#   大地图上海洋占九成以上，逐个建实例纯属浪费；
	#   海面改由一整块 PlaneMesh 表示（见 _create_ocean），视觉也更完整。
	var by_terrain: Dictionary = {}
	for y in range(MH):
		for x in range(MW):
			var terrain_type: int = _gen.map_data[y * MW + x]
			if terrain_type == 7:
				continue
			if not by_terrain.has(terrain_type):
				by_terrain[terrain_type] = []
			# 瓦片坐标 → 3D 世界坐标
			var wx: float = (x - half_w) * TS
			var wz: float = (y - half_h) * TS
			by_terrain[terrain_type].append(Vector3(wx, 0.0, wz))

	# 保存"地形 → 瓦片世界坐标"分组，供资源系统按区域精确采样
	# （资源生成由 ResourceManager 稍后执行，此处同步生成完毕即可用）
	_terrain_positions = by_terrain

	# 为每种地形创建一个 MultiMesh
	for terrain_type in by_terrain:
		var positions: Array = by_terrain[terrain_type]
		var color: Color = _gen.task_system.get_terrain_color(terrain_type)
		_create_tile_multimesh(positions, color, TS)

	# 海面（一整块平面，铺在陆地之下）
	_create_ocean(MW * TS, MH * TS)

	# 绘制 3D 标签
	_draw_labels_3d()


# ============================================================
# 创建海面
#
# 用一整块 PlaneMesh 铺满整个世界（略向外延伸，避免走到边缘看到尽头），
# 位于陆地之下 OCEAN_Y 处，使陆地看起来是高出海平面的岛。
#
# 海面不参与碰撞：角色走到海上没有任何地面支撑，会下落并触发溺水。
# ============================================================
func _create_ocean(world_w: float, world_h: float):
	var plane = PlaneMesh.new()
	plane.size = Vector2(world_w * 1.5, world_h * 1.5)

	var mi = MeshInstance3D.new()
	mi.name = "Ocean"
	mi.mesh = plane
	mi.position = Vector3(0.0, OCEAN_Y, 0.0)

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.30, 0.48)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat

	tile_container.add_child(mi)


# ============================================================
# 创建单个地形类型的 MultiMesh
#
# 流程：
#   1. 创建 PlaneMesh（单瓦片的平面网格）
#   2. 创建 MultiMesh 并设置实例数量
#   3. 为每个实例设置变换（位置）
#   4. 创建 MultiMeshInstance3D 并关联 MultiMesh
#   5. 创建材质：UNSHADED（纯色，不受光照影响）+ CULL_DISABLED（双面）
#   6. 添加到 tile_container
#
# 为什么用 UNSHADED？
#   地图瓦片是彩色的，不需要光照计算，UNSHADED 可避免颜色偏差
#   同时性能更好（无需光照计算）
#
# 为什么用 CULL_DISABLED？
#   单面剔除会导致从下方看瓦片消失，禁用后双面可见
# ============================================================
func _create_tile_multimesh(positions: Array, color: Color, TS: int):
	# 单瓦片平面网格
	var plane = PlaneMesh.new()
	plane.size = Vector2(TS, TS)

	# 创建 MultiMesh
	var mm = MultiMesh.new()
	mm.mesh = plane
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = positions.size()

	# 设置每个实例的位置变换
	# 用单位 Basis（无旋转无缩放），仅设置平移
	for i in range(positions.size()):
		mm.set_instance_transform(i, Transform3D(Basis(), positions[i]))

	# 创建实例节点
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm

	# 创建材质：纯色 + 无光照 + 双面
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mmi.material_override = mat

	tile_container.add_child(mmi)


# ============================================================
# 绘制 3D 标签
#
# 与 2D 版本对应：在每个任务入口上方显示任务名
# 3D 标签特点：
#   - Label3D 是空间文本组件
#   - billboard = ENABLED：标签始终面向摄像机（低角度相机也可读）
#   - 尺寸按主项目正常人物尺度设定（字高约 2 个世界单位）
#   - outline_size = 8/10：黑色轮廓线增加可读性
#
# 出生点标签：更大（字号 40）、黄色、位置更高（y=2.5）
# ============================================================
func _draw_labels_3d():
	var TS: int = _gen.TILE_SIZE
	var half_w: float = _gen.MAP_WIDTH / 2.0
	var half_h: float = _gen.MAP_HEIGHT / 2.0

	# 为每个任务创建标签
	for task_id in _gen.room_chains:
		var chain: Array = _gen.room_chains[task_id]
		if chain.is_empty():
			continue
		var entrance = chain[0]
		var task: Dictionary = _gen.task_system.get_task_by_id(task_id)

		# 瓦片坐标 → 3D 世界坐标
		var wx: float = (entrance.center.x - half_w) * TS
		var wz: float = (entrance.center.y - half_h) * TS

		var label = Label3D.new()
		label.text = task.get("name", task_id)
		label.position = Vector3(wx, 1.2, wz)           # 地面上方 1.2 单位
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED  # 始终面向摄像机
		label.pixel_size = LABEL_PIXEL_SIZE
		label.font_size = LABEL_FONT_SIZE
		label.modulate = Color(1, 1, 1)                  # 白色文字
		label.outline_modulate = Color(0, 0, 0, 1)      # 黑色轮廓
		label.outline_size = 8
		tile_container.add_child(label)

	# 出生点特殊标签
	var start_task: Dictionary = _gen.task_system.get_start_task()
	if _gen.room_chains.has(start_task.id):
		var start_chain: Array = _gen.room_chains[start_task.id]
		if not start_chain.is_empty():
			var start_room = start_chain[0]
			var wx: float = (start_room.center.x - half_w) * TS
			var wz: float = (start_room.center.y - half_h) * TS

			var label = Label3D.new()
			label.text = "★ 起点"
			label.position = Vector3(wx, 2.2, wz)          # 比区域名更高，避免重叠
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.pixel_size = START_LABEL_PIXEL_SIZE
			label.font_size = START_LABEL_FONT_SIZE
			label.modulate = Color(1, 1, 0)                 # 黄色
			label.outline_modulate = Color(0, 0, 0, 1)
			label.outline_size = 10
			tile_container.add_child(label)


# ============================================================
# 构建地板碰撞体（供 CharacterBody3D 行走）
#
# 优化策略：行内连续可通行瓦片合并为一个 BoxShape3D
#   对每一行，扫描连续的可通行区域：
#     - 遇到可通行瓦片：开始记录（x_start = x）
#     - 遇到不可通行瓦片（如海洋）且已有起点：
#       合并 [x_start, x-1] 为一个碰撞体
#     - 行末尾：若有未结束的区域，合并到行尾
#
# 性能对比：
#   不合并：160K 瓦片 → 最多 160K 个 BoxShape3D（爆炸）
#   合并后：约数百到数千个 BoxShape3D（取决于海洋分布）
#
# 碰撞体形状：
#   BoxShape3D，size = (长 × 厚 × 宽)
#   厚度 = 1.0（y 方向），放在 y = -0.5 位置
#   这样角色脚底在 y=0，碰撞体中心在 y=-0.5
# ============================================================
func _build_floor_collisions():
	# 清除旧碰撞体
	for child in collision_container.get_children():
		collision_container.remove_child(child)
		child.queue_free()

	var MW: int = _gen.MAP_WIDTH
	var MH: int = _gen.MAP_HEIGHT
	var TS: int = _gen.TILE_SIZE
	var half_w: float = MW / 2.0
	var half_h: float = MH / 2.0

	# 创建统一的 StaticBody3D，所有碰撞体挂在其上
	var floor_body = StaticBody3D.new()
	floor_body.name = "FloorStaticBody"
	# 主项目物理层：layer_2 = 地面（玩家 collision_mask=3 含 layer2，可站立）
	floor_body.collision_layer = 2
	collision_container.add_child(floor_body)

	# 逐行扫描，合并连续可通行瓦片
	for y in range(MH):
		var x_start: int = -1  # 当前连续区域的起点
		for x in range(MW):
			# 内联可通行判定：只有 terrain=7（海洋）不可走。
			# 64 万格地图上省下这么多次函数调用，能明显减少生成耗时。
			var walkable: bool = _gen.map_data[y * MW + x] != 7
			if walkable:
				if x_start == -1:
					x_start = x  # 开始新的连续区域
			else:
				if x_start != -1:
					# 连续区域结束，创建碰撞体
					_add_floor_segment(floor_body, x_start, x - 1, y, TS, half_w, half_h)
					x_start = -1
		# 行末尾：处理可能未结束的区域
		if x_start != -1:
			_add_floor_segment(floor_body, x_start, MW - 1, y, TS, half_w, half_h)


# ============================================================
# 添加一段连续地板碰撞体
#
# 计算逻辑：
#   count = 瓦片数量
#   length_x = count × TILE_SIZE（碰撞体 X 方向长度）
#   tile_center_x = 起点 + (count-1)/2（瓦片中心坐标）
#   world_x = (tile_center_x - half_w) × TILE_SIZE（3D 世界坐标）
#   world_z = (y - half_h) × TILE_SIZE（3D 世界坐标）
#   world_y = -0.5（碰撞体中心，角色脚底在 y=0）
#
# 形状：BoxShape3D
#   size.x = length_x（覆盖所有瓦片的宽度）
#   size.y = 1.0（薄片状厚度）
#   size.z = TILE_SIZE（单个瓦片深度）
# ============================================================
func _add_floor_segment(parent: StaticBody3D, x_start: int, x_end: int, y: int, TS: int, half_w: float, half_h: float):
	var count: int = x_end - x_start + 1
	var length_x: float = count * TS
	var tile_center_x: float = x_start + (count - 1) / 2.0
	var wx: float = (tile_center_x - half_w) * TS
	var wz: float = (y - half_h) * TS
	var shape_half_y: float = 0.5
	var wy: float = -shape_half_y

	var col = CollisionShape3D.new()
	col.position = Vector3(wx, wy, wz)

	var box = BoxShape3D.new()
	box.size = Vector3(length_x, shape_half_y * 2.0, TS)
	col.shape = box

	parent.add_child(col)


# ============================================================
# 获取出生点的 3D 世界坐标
#
# 流程：
#   1. 从 task_system 获取 start_task（草原区）
#   2. 从 room_chains 获取其第一个房间（entrance）
#   3. 把瓦片坐标转换为 3D 世界坐标
#   4. 返回 Vector3(world_x, 2.0, world_z)
#      （y=2.0 让角色站在地面上方，避免穿模）
#
# 返回：Vector3 出生点世界坐标（若未找到则返回 Vector3.ZERO）
# ============================================================
func get_task_world_position(task_id: String, height: float = 1.0) -> Vector3:
	if _gen == null or _gen.task_system == null:
		return Vector3.ZERO
	if not _gen.room_chains.has(task_id):
		return Vector3.ZERO
	var chain: Array = _gen.room_chains[task_id]
	if chain.is_empty():
		return Vector3.ZERO
	var entrance_room = chain[0]
	var TS: int = _gen.TILE_SIZE
	var half_w: float = _gen.MAP_WIDTH / 2.0
	var half_h: float = _gen.MAP_HEIGHT / 2.0
	var wx: float = (entrance_room.center.x - half_w) * TS
	var wz: float = (entrance_room.center.y - half_h) * TS
	return Vector3(wx, height, wz)


# 获取出生点世界坐标（草原区入口房间中心）
# 高度设 1.0：主项目玩家碰撞体中心在 y=0.5、脚底在 y=0，略高于地面以便落地
func get_start_world_position() -> Vector3:
	if _gen == null or _gen.task_system == null:
		return Vector3.ZERO
	var start_task: Dictionary = _gen.task_system.get_start_task()
	return get_task_world_position(start_task.id, 1.0)


# ============================================================
# 返回地图世界尺寸（世界单位 = MAP × TILE_SIZE）
#
# 用途：资源生成器等需要按地图实际世界范围决定生成区域，
# 地图运行时生成、尺寸由 TILE_SIZE × MAP_WIDTH 决定，不能硬编码。
# 返回 Vector2(world_width, world_height)
# ============================================================
func get_world_size() -> Vector2:
	if _gen == null:
		return Vector2.ZERO
	return Vector2(_gen.MAP_WIDTH * _gen.TILE_SIZE, _gen.MAP_HEIGHT * _gen.TILE_SIZE)


# ============================================================
# 生成地图缩略图（一次性版本）
#
# 按 target_size 对 map_data 等比采样，返回一张 RGB8 俯视图。
# 采样而非全量遍历：1600x1600 缩到 200x200 只取 4 万次色，开销可忽略。
#
# 注意：接口虽是一次性的，但如果 target_size 开大（1600 = 256 万次取色），
# 同步跑会明显卡顿。游戏里的地图（小地图/大地图）走下面的分帧版本：
#   build_minimap_pixels + fill_minimap_bands
# 本函数保留给测试脚本（test/minimap_live_test.gd）与需要整图的场合。
#
# 参数：target_size — 缩略图边长（像素）
# 返回：Image；地图尚未生成时返回 null
# ============================================================
func build_minimap_image(target_size: int) -> Image:
	var data := build_minimap_pixels(target_size)
	if data.is_empty():
		return null
	fill_minimap_bands(data, target_size, 0, target_size)
	return Image.create_from_data(target_size, target_size, false, Image.FORMAT_RGB8, data)


# ============================================================
# 分配底图字节缓冲（分帧生成第 1 步）
#
# 返回长度 = target_size² × 3 的全零 RGB8 缓冲，配合 fill_minimap_bands
# 逐帧填充，最后 Image.create_from_data 一次转成纹理。
#
# 为什么要分帧：1600×1600 底图是 256 万次逐像素取色，
# 在 GDScript 里同步跑要一两秒，直接卡住主线程；
# 拆开后调用方每帧只填若干行，百余帧内无感填满。
#
# 返回：PackedByteArray；地图尚未生成时返回空数组（调用方据此重试）
# ============================================================
func build_minimap_pixels(target_size: int) -> PackedByteArray:
	var data := PackedByteArray()
	if _gen == null or _gen.map_data.is_empty() or target_size <= 0:
		return data
	data.resize(target_size * target_size * 3)
	return data


# ============================================================
# 填充底图字节缓冲的 [y0, y1) 行（分帧生成第 2 步）
#
# 采样方式与 build_minimap_image 完全一致（等比取样最近格），
# 保证分帧版和一次性版画出来的是同一张图。
#
# 参数：
#   data        — build_minimap_pixels 分配的缓冲（原地写入）
#   target_size — 底图边长，必须与分配时一致
#   y0 / y1     — 本次填充的行区间（左闭右开）
# ============================================================
func fill_minimap_bands(data: PackedByteArray, target_size: int, y0: int, y1: int) -> void:
	if _gen == null or _gen.map_data.is_empty() or target_size <= 0:
		return
	if data.size() < target_size * target_size * 3:
		return

	var mw: int = _gen.MAP_WIDTH
	var mh: int = _gen.MAP_HEIGHT
	var step_x: float = float(mw) / float(target_size)
	var step_y: float = float(mh) / float(target_size)
	# 地形→颜色只在第一次遇到时查一次表（字典查找比函数调用便宜）
	var color_cache: Dictionary = {}

	for y in range(maxi(y0, 0), mini(y1, target_size)):
		var sy: int = mini(int(float(y) * step_y), mh - 1)
		var row: int = sy * mw
		var base: int = y * target_size * 3
		for x in range(target_size):
			var sx: int = mini(int(float(x) * step_x), mw - 1)
			var terrain_type: int = int(_gen.map_data[row + sx])
			if not color_cache.has(terrain_type):
				color_cache[terrain_type] = _gen.task_system.get_terrain_color(terrain_type)
			var c: Color = color_cache[terrain_type]
			var i: int = base + x * 3
			data[i] = roundi(c.r * 255.0)
			data[i + 1] = roundi(c.g * 255.0)
			data[i + 2] = roundi(c.b * 255.0)


# ============================================================
# 地图图例（大地图底部用）
#
# 组装顺序：海洋 → 沙滩 → 各个任务区（TASKS 的顺序 = 内圈到外圈）。
# 名称与配色都取自 task_system，改配色不会出现"图例和地图两张皮"。
#
# 返回：Array[{ name: String, color: Color }]，地图未就绪时返回空数组
# ============================================================
func get_terrain_legend() -> Array:
	var out: Array = []
	if _gen == null or _gen.task_system == null:
		return out
	out.append({"name": "海洋", "color": _gen.task_system.get_terrain_color(7)})
	out.append({"name": "沙滩", "color": _gen.task_system.get_terrain_color(8)})
	for task in _gen.task_system.TASKS:
		out.append({
			"name": str(task.get("name", task.get("id", ""))),
			"color": task.get("color", Color(0.5, 0.5, 0.5)),
		})
	return out


# ============================================================
# 查询某个世界坐标所属的地形编号
#
# 每个瓦片的 terrain_type 本身就是它的生物群系：
#   8 沙滩 / 10 草原 / 11 丛林 / 12 矿区 / 13 沙地 / 14 火山 / 15 雪地
# 资源生成器、敌人 AI 等据此判断"脚下属于哪个区"。
# 返回：terrain_type；地图未就绪或越界时返回 7（海洋）
# ============================================
func get_terrain_world(world_pos: Vector3) -> int:
	if _gen == null or _gen.map_data.is_empty():
		return 7
	var t: Vector2i = world_to_tile(world_pos)
	if t.x < 0 or t.y < 0 or t.x >= _gen.MAP_WIDTH or t.y >= _gen.MAP_HEIGHT:
		return 7
	return int(_gen.map_data[t.y * _gen.MAP_WIDTH + t.x])


# ============================================
# 查询某个世界坐标所属的区域（任务）ID
#
# 返回：区域 ID 字符串（"Grassland" / "Forest" / "Rocky" ……）
#       沙滩、海洋、道路等不属于任何任务区时返回 ""（空字符串）
# ============================================
func get_region_id_world(world_pos: Vector3) -> String:
	if _gen == null or _gen.task_system == null:
		return ""
	var task: Dictionary = _gen.task_system.get_task_by_terrain(get_terrain_world(world_pos))
	if task.is_empty():
		return ""
	return str(task.get("id", ""))


# ============================================
# 判断世界坐标是否位于可通行陆地（非海洋）
#
# 用途：供资源系统（resource_spawner）和敌人 AI 查询，避免走到海上。
# 世界坐标 → 瓦片坐标的逆变换，与 render_map_3d 中的正向变换一致：
#   tile_x = world_x / TILE_SIZE + MAP_WIDTH / 2
#   tile_y = world_z / TILE_SIZE + MAP_HEIGHT / 2
#
# 参数：world_pos — 3D 世界坐标（y 分量忽略）
# 返回：bool — true 表示可通行陆地，false 表示海洋或地图外
# ============================================================
func is_land_world(world_pos: Vector3) -> bool:
	return is_walkable_tile(world_to_tile(world_pos))


# ============================================================
# 判断某种资源是否允许生成在某个世界坐标
#
# 用途：resource_spawner 借此实现"资源按生物群系分布"——
#       草原长草、丛林长树、矿区出矿，而不是全图均匀撒。
#
# 判定链：
#   世界坐标 → terrain_type → 所属区域 → REGION_RESOURCE_MAP → 是否含该资源
#   沙滩（terrain 8）不在 TASKS 里，但映射表为它保留了一个虚拟区域 "Beach"，
#   因此沙滩同样能长木棍 / 小石块。
#
# 参数：
#   world_pos   — 3D 世界坐标
#   resource_id — 资源 ID（&"grass" / &"stone" / &"tree" ……）
#
# 返回：bool
#   true  = 允许生成
#   false = 该坐标不产此资源（海洋 / 道路，或该区域未登记此资源）
# ============================================
func is_resource_allowed_at(world_pos: Vector3, resource_id: StringName) -> bool:
	if _gen == null or _gen.task_system == null:
		return true  # 地图未就绪：不做限制（保持向后兼容）
	var terrain: int = get_terrain_world(world_pos)
	var task: Dictionary = _gen.task_system.get_task_by_terrain(terrain)
	var region_id: String = ""
	if task.is_empty():
		# 沙滩（terrain 8）不属于任何任务区，但映射表为它保留了虚拟区域
		region_id = _gen.task_system.get_special_region_id(terrain)
		if region_id.is_empty():
			return false  # 海洋 / 道路不放资源
	else:
		region_id = str(task.get("id", ""))
	return _gen.task_system.is_resource_allowed_in_region(region_id, str(resource_id))


# ============================================================
# 资源采样：按地形取瓦片
#
# 供 resource_spawner 使用。生成器先用 get_resource_terrain_types()
# 拿到"该资源允许出现在哪些地形"，再到这里的地形瓦片池里均匀取点——
# 而不是"全图乱撒再按区域过滤"（后者在资源只属于小区域时，如火山区的煤炭，
# 绝大多数候选会被否决，尝试次数耗尽后数量严重不足）。
#
# 刻意不直接暴露 _terrain_positions 数组（避免外部误改），
# 只提供"池子大小 + 按下标取点"两个接口。
# ============================================================

# 某地形的可用瓦片数量（0 表示该地形在此地图上不存在）
func get_terrain_tile_count(terrain_type: int) -> int:
	var arr: Array = _terrain_positions.get(terrain_type, [])
	return arr.size()


# 取某地形第 index 个瓦片的世界坐标（越界返回原点）
func get_terrain_tile_position(terrain_type: int, index: int) -> Vector3:
	var arr: Array = _terrain_positions.get(terrain_type, [])
	if index < 0 or index >= arr.size():
		return Vector3.ZERO
	return arr[index]


# 某资源允许生成在哪些地形（转发到 task_system 的区域映射表）
# 返回空数组 = 该资源未登记 → 不限区域（生成器会回退到全图撒点）
# 返回 untyped Array：跨对象动态调用的返回值走 Variant，用 Array[int]
# 标注会触发额外的类型转换检查，这里以稳健为先。
func get_resource_terrain_types(resource_id: StringName) -> Array:
	if _gen == null or _gen.task_system == null:
		return []
	return _gen.task_system.get_resource_terrain_types(str(resource_id))


# ============================================
# 寻路子系统（网格 A*）
#
# 为什么不用 NavigationAgent3D？
#   本项目的地图是运行时程序化生成的，没有预先烘焙的导航网格；
#   而 map_data 本身就是一张现成的通行图（terrain != 7 即可走），
#   直接在瓦片网格上跑 A* 既精确又零烘焙成本。
#
# 对外的核心接口：
#   find_world_path(from, to) -> Array[Vector3]
#     返回一串世界坐标航点（已做视线拉直），敌人依次走过即可绕开海与障碍。
# ============================================================

# A* 最大扩展节点数（防止在超大空旷地图上无限搜索）
# TILE_SIZE=1 后瓦片距离翻倍（同样的世界距离现在对应两倍瓦片数），
# 长程追击需要的扩展节点数随之翻倍，故从 20000 提到 40000。
const PATH_MAX_EXPANSIONS = 40000

# 8 邻接方向：前 4 个为正交，后 4 个为对角（用于禁止贴角穿越）
const _PATH_DIRS: Array = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]


# 世界坐标 → 瓦片坐标
func world_to_tile(world_pos: Vector3) -> Vector2i:
	var TS: int = _gen.TILE_SIZE
	var tx: int = int(round(world_pos.x / TS + _gen.MAP_WIDTH / 2.0))
	var ty: int = int(round(world_pos.z / TS + _gen.MAP_HEIGHT / 2.0))
	return Vector2i(tx, ty)


# 瓦片坐标 → 世界坐标（瓦片中心）
func tile_to_world(tile: Vector2i, height: float = 0.0) -> Vector3:
	var TS: int = _gen.TILE_SIZE
	return Vector3(
		(tile.x - _gen.MAP_WIDTH / 2.0) * TS,
		height,
		(tile.y - _gen.MAP_HEIGHT / 2.0) * TS
	)


# 判断某个瓦片是否可通行（越界与海洋均为不可通行）
func is_walkable_tile(tile: Vector2i) -> bool:
	if _gen == null or _gen.map_data.is_empty():
		return true  # 地图未就绪时默认放行，避免阻塞调用方
	if tile.x < 0 or tile.y < 0 or tile.x >= _gen.MAP_WIDTH or tile.y >= _gen.MAP_HEIGHT:
		return false
	return _gen.task_system.is_terrain_walkable(_gen.map_data[tile.y * _gen.MAP_WIDTH + tile.x])


# ============================================================
# 在世界坐标之间寻路
#
# 返回：Array[Vector3] 航点列表（不含起点，末点为实际目标点）
#       两点间已有直线通路时 → 直接返回 [to]
#       目标不可达/在海里 → 返回空数组
# ============================================================
func find_world_path(from: Vector3, to: Vector3) -> Array:
	var start: Vector2i = world_to_tile(from)
	var goal: Vector2i = world_to_tile(to)

	# 目标点落在海里：向外螺旋搜索最近的可通行瓦片作为替代目标
	if not is_walkable_tile(goal):
		goal = _find_nearest_walkable_tile(goal)
		if goal == Vector2i(-1, -1):
			return []
	if start == goal:
		return [to]

	# 直线可达（视线内全是陆地）时无需绕路
	if _tile_line_walkable(start, goal):
		return [to]

	return _astar_tiles(start, goal, to)


# 在目标瓦片附近螺旋搜索最近的可通行瓦片（找不到返回 (-1,-1)）
func _find_nearest_walkable_tile(origin: Vector2i, max_radius: int = 8) -> Vector2i:
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if max(abs(dx), abs(dy)) != r:
					continue
				var cand: Vector2i = origin + Vector2i(dx, dy)
				if is_walkable_tile(cand):
					return cand
	return Vector2i(-1, -1)


#  检查两瓦片中心之间的直线是否全程可通行（用于视线判断与路径拉直）
#
#  实现：DDA 体素遍历（Amanatides & Woo），精确枚举直线经过的每一个瓦片。
#  相比"按固定步长采样"或 Bresenham 阶梯，它不会漏掉被斜穿的格子；
#  且在直线正好穿过格点（角落）时会同时推进两轴，采用最严格的 supercover 判定。
func _tile_line_walkable(a: Vector2i, b: Vector2i) -> bool:
	# 瓦片 (tx,ty) 占据 [tx-0.5, tx+0.5] 的方形，因此整体 +0.5 后
	# 即变成标准的单位网格：格子 (tx,ty) 覆盖 [tx, tx+1)
	var x0: float = a.x + 0.5
	var y0: float = a.y + 0.5
	var x1: float = b.x + 0.5
	var y1: float = b.y + 0.5
	var dx: float = x1 - x0
	var dy: float = y1 - y0

	var cx: int = int(floor(x0))
	var cy: int = int(floor(y0))
	if not is_walkable_tile(Vector2i(cx, cy)):
		return false

	var goal_cell: Vector2i = Vector2i(int(floor(x1)), int(floor(y1)))

	# 单轴方向为 0 时，对应 t_max 设为无穷大，永远不会在那一轴推进
	var step_x: int = 0
	var step_y: int = 0
	var t_max_x: float = INF
	var t_max_y: float = INF
	var t_delta_x: float = INF
	var t_delta_y: float = INF

	if dx > 0.0:
		step_x = 1
		t_delta_x = 1.0 / dx
		t_max_x = (float(cx) + 1.0 - x0) / dx
	elif dx < 0.0:
		step_x = -1
		t_delta_x = 1.0 / (-dx)
		t_max_x = (x0 - float(cx)) / (-dx)

	if dy > 0.0:
		step_y = 1
		t_delta_y = 1.0 / dy
		t_max_y = (float(cy) + 1.0 - y0) / dy
	elif dy < 0.0:
		step_y = -1
		t_delta_y = 1.0 / (-dy)
		t_max_y = (y0 - float(cy)) / (-dy)

	var guard: int = _gen.MAP_WIDTH + _gen.MAP_HEIGHT + 4
	while guard > 0:
		if cx == goal_cell.x and cy == goal_cell.y:
			return true
		if absf(t_max_x - t_max_y) < 1e-9:
			# 正好穿过格点：两轴同时推进（严格判定，不抄近路）
			t_max_x += t_delta_x
			t_max_y += t_delta_y
			cx += step_x
			cy += step_y
		elif t_max_x < t_max_y:
			t_max_x += t_delta_x
			cx += step_x
		else:
			t_max_y += t_delta_y
			cy += step_y
		if not is_walkable_tile(Vector2i(cx, cy)):
			return false
		guard -= 1
	return false


# ============================================================
# 网格 A* 主实现
#
# 代价：正交 1.0，对角 1.4142
# 启发式：octile 距离（允许对角移动时的一致性启发）
# 对角约束：禁止"贴角"穿越——两侧正交邻居都必须可通行才能斜走
# ============================================================
func _astar_tiles(start: Vector2i, goal: Vector2i, real_target: Vector3) -> Array:
	var open_heap: Array = []
	_heap_push(open_heap, {"tile": start, "f": _octile(start, goal)})

	var came_from: Dictionary = {}
	var g_score: Dictionary = {start: 0.0}
	var closed: Dictionary = {}
	var expansions: int = 0

	while not open_heap.is_empty() and expansions < PATH_MAX_EXPANSIONS:
		var current: Vector2i = _heap_pop(open_heap)["tile"]
		if current == goal:
			return _reconstruct_path(came_from, start, current, real_target)
		if closed.has(current):
			continue
		closed[current] = true
		expansions += 1

		for i in range(_PATH_DIRS.size()):
			var dir: Vector2i = _PATH_DIRS[i]
			var next: Vector2i = current + dir
			if not is_walkable_tile(next):
				continue
			# 对角移动：两侧正交格必须都能走，防止穿透海角的缝隙
			if i >= 4:
				if not is_walkable_tile(current + Vector2i(dir.x, 0)):
					continue
				if not is_walkable_tile(current + Vector2i(0, dir.y)):
					continue

			var step_cost: float = 1.4142 if i >= 4 else 1.0
			var tentative_g: float = g_score[current] + step_cost
			if g_score.has(next) and tentative_g >= g_score[next]:
				continue
			g_score[next] = tentative_g
			came_from[next] = current
			_heap_push(open_heap, {"tile": next, "f": tentative_g + _octile(next, goal)})

	return []  # 不可达


# 回溯路径 → 拉直 → 转世界坐标
#
# 注意：必须从起点瓦片开始拉直，否则"当前位置 → 第一个航点"这一段
# 没有经过可通行校验，角色仍可能斜着踩进海里。
func _reconstruct_path(came_from: Dictionary, start: Vector2i, goal: Vector2i, real_target: Vector3) -> Array:
	# 回溯出完整瓦片序列：[start, ..., goal]
	var tiles: Array = [goal]
	var node: Vector2i = goal
	while came_from.has(node):
		node = came_from[node]
		tiles.push_front(node)

	# 串拉（string pulling）：从起点开始，发现直线不通就保留前一个点作为转折点
	var simplified: Array = []
	var anchor: int = 0
	for i in range(1, tiles.size()):
		if not _tile_line_walkable(tiles[anchor], tiles[i]):
			simplified.append(tiles[i - 1])
			anchor = i - 1
	simplified.append(tiles[tiles.size() - 1])

	# 起点只是锚点，不作为航点输出
	if simplified.size() > 1 and simplified[0] == start:
		simplified.remove_at(0)

	# 转世界坐标，末点替换为调用方传入的真实目标
	var world_path: Array = []
	for i in range(simplified.size()):
		if i == simplified.size() - 1:
			world_path.append(real_target)
		else:
			world_path.append(tile_to_world(simplified[i]))
	return world_path


# octile 启发式距离
func _octile(a: Vector2i, b: Vector2i) -> float:
	var dx: int = absi(a.x - b.x)
	var dy: int = absi(a.y - b.y)
	return (dx + dy) + (1.4142 - 2.0) * mini(dx, dy)


# ---- 二叉小顶堆（Godot 无内置优先队列）----
func _heap_push(heap: Array, item: Dictionary) -> void:
	heap.append(item)
	var i: int = heap.size() - 1
	while i > 0:
		var p: int = (i - 1) / 2
		if heap[p]["f"] <= heap[i]["f"]:
			break
		var tmp = heap[p]
		heap[p] = heap[i]
		heap[i] = tmp
		i = p


func _heap_pop(heap: Array) -> Dictionary:
	var top: Dictionary = heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.size() > 0:
		heap[0] = last
		var i: int = 0
		while true:
			var l: int = i * 2 + 1
			var r: int = i * 2 + 2
			var s: int = i
			if l < heap.size() and heap[l]["f"] < heap[s]["f"]:
				s = l
			if r < heap.size() and heap[r]["f"] < heap[s]["f"]:
				s = r
			if s == i:
				break
			var tmp = heap[s]
			heap[s] = heap[i]
			heap[i] = tmp
			i = s
	return top


# ============================================================
# 传送玩家到出生点
#
# 流程：
#   1. 调用 get_start_world_position() 获取出生点坐标
#   2. 在 "player" 组中查找玩家节点
#   3. 查找玩家下的 CharacterBody3D 子节点
#   4. 清零速度 + 设置位置
#   5. 同步摄像机目标位置
#
# 为什么要同步摄像机目标？
#   camera_controller_3d.gd 让摄像机追踪 CameraTarget，
#   若只移动玩家不同步目标，摄像机会有明显的跟随延迟。
# ============================================================
func teleport_player_to_start():
	var start_pos: Vector3 = get_start_world_position()

	# 注册默认重生点（出生点）；只在还没设过时写，避免覆盖玩家自定义的床位（未来功能）。
	RespawnSystem.register_spawn(start_pos)

	var char_body: CharacterBody3D = _find_player_body()
	if char_body == null:
		return
	char_body.velocity = Vector3.ZERO
	char_body.global_position = start_pos
	_player_char = char_body
	# 传送后立刻把相机吸附到新坐标：否则镜头会从世界原点/旧位置
	# 一路平滑飞过去（首帧画面不在玩家身上）。
	if char_body.has_method("reset_visual_interp"):
		char_body.call("reset_visual_interp")
	var cam: Node = get_tree().get_first_node_in_group("player_camera")
	if cam != null and cam.has_method("snap_to_target"):
		cam.call("snap_to_target")


# ============================================================
# 放置敌人到对应区域
#
# 把场景中加入了 "enemy" 组的敌人放置到各自区域。
# 当前 Demo：史莱姆 → 丛林区（Forest，对应大纲中史莱姆的出没区域）。
# 多个敌人沿 X 轴略微分散，避免堆叠在同一点。
# ============================================================
func _place_enemies():
	var forest_pos: Vector3 = get_task_world_position("Forest", 0.0)
	if forest_pos == Vector3.ZERO:
		return
	var enemies: Array = get_tree().get_nodes_in_group("enemy")
	var i: int = 0
	for enemy in enemies:
		if enemy is Node3D:
			enemy.global_position = forest_pos + Vector3(i * 2.0, 0.0, 0.0)
			i += 1


# ============================================================
# 出生点旁放置一个装满测试材料的储物箱
#
# 用途：实机验证建造/合成系统——不用先徒手攒材料，
#   开局直接左键开箱拿材料去合成石制工具/护甲/建筑。
#
# 内容物（够反复合成的量级）：
#   原木×50 / 石头×50 / 草×50 / 木棍×50 / 史莱姆凝胶×20
#   铁矿×30 / 煤矿×30 / 铁锭×15           ← 矿物链测试用
#   浆果×15                                ← 试饱食度：右键吃掉回 25
#
# 说明：
#   - 只在 _ready 调用一次；重新生成地图时箱子挂在生成器节点下不消失。
#   - 建筑已有碰撞体（见 building.gd），出生点旁 1.5m 大于"箱半宽 + 玩家半径"，
#     不会把玩家卡住。
#   - 矿石本要从矿区/火山区挖，这里先给一份方便直接试熔炉冶炼；
#     想验证完整流程可把铁锭那行去掉，逼自己走一遍"挖矿→炼铁"。
#   - 材料清单要改就改 _TEST_BOX_CONTENTS。
# ============================================================
const _TEST_BOX_CONTENTS := {
	&"wood": 50,
	&"rock": 50,
	&"grass": 50,
	&"stick": 50,
	&"slime_gel": 20,
	&"iron_ore": 20,
	&"coal": 20,
	&"iron_ingot": 10,
	&"berry": 15,
	# 动力核心：正式来源是击败机械沙虫（规划中），先放在测试箱里，
	# 好让"装入核心 → 电量栏亮起 → 解锁核心制作栏"整条链路一开始就能验证。
	&"power_core": 1,
}

func _spawn_test_storage_box() -> void:
	var start_pos: Vector3 = get_start_world_position()
	if start_pos == Vector3.ZERO:
		return

	# get_start_world_position 的 y=1.0 是给角色落地的；箱子直接贴地 y=0
	var box_pos := Vector3(start_pos.x + 1.5, 0.0, start_pos.z)
	var box: Building = Building.spawn(&"storage_box", box_pos, self)
	if box == null or not box.has_storage():
		push_error("出生点测试储物箱创建失败")
		return

	var registry := ItemRegistry.get_registry()
	if registry == null:
		push_error("出生点测试储物箱: 物品注册表为空")
		return

	for item_id in _TEST_BOX_CONTENTS:
		var data: ItemData = registry.get_item(item_id)
		if data == null:
			DebugConfig.warn_msg(DebugConfig.CAT_ITEM, "测试储物箱: 注册表中找不到物品 %s", [item_id])
			continue
		box.storage.add_item(data, int(_TEST_BOX_CONTENTS[item_id]))
	DebugConfig.log_msg(DebugConfig.CAT_ITEM, "出生点测试储物箱已放置 (%.1f, %.1f)，材料已装填",
		[box_pos.x, box_pos.z])


# ============================================================
# 出生点旁放置测试敌人（实机验证战斗系统用）
#
# 用途：不用跑遍全岛找怪——开局出生点旁边就有一只
#   史莱姆和一架无人机，直接验证：
#   - 近战攻击（圆柱判定、受击掉血、死亡掉落）
#   - 无人机设定（无碰撞体积可穿身、Area3D 命中盒
#     能被打到、1.5m 悬停高度在挥砍范围内、弹幕反击）
#
# 说明：
#   - 新开局和读档都会生成（与场景预置的 Slime/Drone 一致）：
#     谁活着由 SaveManager._apply_enemies 按存档判定——
#     存档里有的落位回血，存档里没有的（已被击杀）删掉。
#     若只在非读档时生成，存档里记录的路径会找不到节点，
#     测试怪每次读档都会凭空消失。
#   - 无人机 anchor_on_ready=false：出生后不去矿区，停在摆放位置。
#   - 距出生点约 9 米：够近方便测试，又不至于一出生就被围攻
#     （无人机仇恨范围 14m，主动靠近它才会被盯上）。
#   - 挂在 MapGenerator3D 节点下，名字固定 TestSlime / TestDrone，
#     保证存档路径匹配跨会话稳定。
# ============================================================
func _spawn_test_enemies() -> void:
	var start_pos: Vector3 = get_start_world_position()
	if start_pos == Vector3.ZERO:
		return

	# ---- 史莱姆（出生点东侧约 9 米，地面单位）----
	var slime_scene: PackedScene = load(SLIME_SCENE_PATH)
	if slime_scene != null:
		var slime: Node3D = slime_scene.instantiate()
		slime.name = "TestSlime"
		var s_pos: Vector3 = _find_test_land_near(start_pos + Vector3(9.0, 0.0, 0.0))
		# 生成器在原点 → 本地坐标即世界坐标；y 抬一点让重力自然落地
		slime.position = Vector3(s_pos.x, 0.5, s_pos.z)
		add_child(slime)
		DebugConfig.log_msg(DebugConfig.CAT_ENEMY, "测试史莱姆已放置 (%.1f, %.1f)", [s_pos.x, s_pos.z])

	# ---- 无人机（出生点西侧约 9 米，悬空单位）----
	var drone_scene: PackedScene = load(DRONE_SCENE_PATH)
	if drone_scene != null:
		var drone: Drone = drone_scene.instantiate() as Drone
		if drone == null:
			DebugConfig.warn_msg(DebugConfig.CAT_ENEMY, "测试无人机实例化失败（脚本类型不符）", [])
			return
		drone.name = "TestDrone"
		# 必须在 add_child 之前关锚定：_ready 在 add_child 时就会跑
		drone.anchor_on_ready = false
		var d_pos: Vector3 = _find_test_land_near(start_pos + Vector3(-9.0, 0.0, 0.0))
		# _hover() 会把 y 平滑拉到悬停高度，起始 y 给 1.5 减少进场下坠感
		drone.position = Vector3(d_pos.x, 1.5, d_pos.z)
		add_child(drone)
		DebugConfig.log_msg(DebugConfig.CAT_ENEMY, "测试无人机已放置 (%.1f, %.1f)", [d_pos.x, d_pos.z])


## 从 from 开始沿 +X 每 2 米找一格陆地，找不到就原样返回
## （出生点在草原房中心，正常第一步就命中；这是海岛边界等极端情况的兜底）
func _find_test_land_near(from: Vector3) -> Vector3:
	var pos: Vector3 = from
	for _i in 16:
		if is_land_world(pos):
			return pos
		pos += Vector3(2.0, 0.0, 0.0)
	return from


# ============================================================
# 兼容方法：供 player_controller.gd 调用
# player_controller.gd 调用 teleport_player_to_start()
# 这里提供一个内部转发版本（_teleport → 直接调 teleport）
# ============================================================
func _teleport_player_to_start():
	teleport_player_to_start()


# ============================================================
# 重新生成按钮回调
# 重新随机化种子 → 重新生成数据 → 重新渲染 → 重建碰撞 → 传送玩家
# ============================================================
func _on_regenerate_pressed():
	_gen.rng.randomize()
	_run_generation()
	render_map_3d()
	_build_floor_collisions()
	teleport_player_to_start()
