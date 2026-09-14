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
#   map_data[y][x] 中的 (x, y) 是瓦片坐标
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
const GEN_2D_PATH = "res://scripts/map_generator.gd"

# 三个子系统脚本路径（用于重写 2D 生成器内部的引用）
const TASK_SYSTEM_PATH = "res://scripts/task_system.gd"
const LAYOUT_PATH = "res://scripts/layout.gd"
const ROOM_CHAIN_PATH = "res://scripts/room_chain.gd"


# ------------------------------------------------------------
# 标签样式常量
# 3D 标签（Label3D）的像素大小和字号
# ------------------------------------------------------------

# 普通任务标签：较小
const LABEL_PIXEL_SIZE = 2.0     # 每个像素的 3D 世界尺寸（米）
const LABEL_FONT_SIZE = 32       # 字体大小

# 出生点标签：较大更醒目
const START_LABEL_PIXEL_SIZE = 3.0
const START_LABEL_FONT_SIZE = 40


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

# 摄像机追踪目标（空节点，每帧同步到玩家位置）
# camera_controller_3d.gd 的 _process 会让摄像机看向此节点
var _cam_target: Node3D = null

# 玩家角色的 CharacterBody3D 节点引用
# 用于传送出生点时直接操作其位置和速度
var _player_char: CharacterBody3D = null


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
	_gen.rng.randomize()

	# 执行生成流水线 → 填充 _gen.map_data
	_run_generation()

	# 渲染 3D 瓦片（读取 _gen.map_data）
	render_map_3d()

	# 构建碰撞体（供角色行走）
	_build_floor_collisions()

	# 传送玩家到出生点
	teleport_player_to_start()


# ============================================================
# 每帧更新：同步摄像机目标到玩家位置
#
# 查找策略（惰性初始化）：
#   - _cam_target: 查找同级名为 "CameraTarget" 的节点
#   - _player_char: 在 "player" 组中查找 CharacterBody3D
#   - 找到后每帧同步 x/z 坐标（y 由摄像机脚本控制）
#
# 为什么不在 _ready 中查找？
#   因为玩家节点可能在本脚本 _ready 之后才实例化，
#   用惰性查找可避免初始化顺序问题。
# ============================================================
func _process(_delta: float):
	# 惰性查找摄像机目标
	if _cam_target == null:
		_cam_target = get_parent().get_node_or_null("CameraTarget")

	# 惰性查找玩家角色
	if _player_char == null or not is_instance_valid(_player_char):
		var players: Array = get_tree().get_nodes_in_group("player")
		if not players.is_empty():
			_player_char = players[0].get_node_or_null("CharacterBody3D")

	# 同步摄像机目标位置到玩家（仅 x/z，y 由摄像机脚本管理）
	if _cam_target != null and _player_char != null and is_instance_valid(_player_char):
		_cam_target.global_position.x = _player_char.global_position.x
		_cam_target.global_position.z = _player_char.global_position.z


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
	_gen.create_task_link_roads()
	_gen.build_island_base()


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
	var by_terrain: Dictionary = {}
	for y in range(MH):
		for x in range(MW):
			var terrain_type: int = _gen.map_data[y][x]
			if not by_terrain.has(terrain_type):
				by_terrain[terrain_type] = []
			# 瓦片坐标 → 3D 世界坐标
			var wx: float = (x - half_w) * TS
			var wz: float = (y - half_h) * TS
			by_terrain[terrain_type].append(Vector3(wx, 0.0, wz))

	# 为每种地形创建一个 MultiMesh
	for terrain_type in by_terrain:
		var positions: Array = by_terrain[terrain_type]
		var color: Color = _gen.task_system.get_terrain_color(terrain_type)
		_create_tile_multimesh(positions, color, TS)

	# 绘制 3D 标签
	_draw_labels_3d()


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
#   - Label3D 是空间文本组件，面向摄像机（默认 billboard 模式）
#   - rotation_degrees.x = -90：让文本平铺在地面上（水平朝向摄像机）
#   - no_depth_test = true：标签不受深度测试影响，始终可见
#   - outline_size = 8/10：黑色轮廓线增加可读性
#
# 出生点标签：更大（字号 40）、黄色、位置更高（y=2.0）
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
		label.position = Vector3(wx, 1.0, wz)           # 地面上方 1 单位
		label.rotation_degrees.x = -90                   # 平铺在地面
		label.pixel_size = LABEL_PIXEL_SIZE
		label.font_size = LABEL_FONT_SIZE
		label.modulate = Color(1, 1, 1)                  # 白色文字
		label.outline_modulate = Color(0, 0, 0, 1)      # 黑色轮廓
		label.outline_size = 8
		label.no_depth_test = true                       # 始终可见
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
			label.position = Vector3(wx, 2.0, wz)          # 更高位置
			label.rotation_degrees.x = -90
			label.pixel_size = START_LABEL_PIXEL_SIZE
			label.font_size = START_LABEL_FONT_SIZE
			label.modulate = Color(1, 1, 0)                 # 黄色
			label.outline_modulate = Color(0, 0, 0, 1)
			label.outline_size = 10
			label.no_depth_test = true
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
	collision_container.add_child(floor_body)

	# 逐行扫描，合并连续可通行瓦片
	for y in range(MH):
		var x_start: int = -1  # 当前连续区域的起点
		for x in range(MW):
			var tt: int = _gen.map_data[y][x]
			var walkable: bool = _gen.task_system.is_terrain_walkable(tt)
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
func get_start_world_position() -> Vector3:
	if _gen == null or _gen.task_system == null:
		return Vector3.ZERO
	var start_task: Dictionary = _gen.task_system.get_start_task()
	var start_id: String = start_task.id
	if not _gen.room_chains.has(start_id):
		return Vector3.ZERO
	var chain: Array = _gen.room_chains[start_id]
	if chain.is_empty():
		return Vector3.ZERO
	var entrance_room = chain[0]
	var TS: int = _gen.TILE_SIZE
	var half_w: float = _gen.MAP_WIDTH / 2.0
	var half_h: float = _gen.MAP_HEIGHT / 2.0
	var wx: float = (entrance_room.center.x - half_w) * TS
	var wz: float = (entrance_room.center.y - half_h) * TS
	var wy: float = 2.0
	return Vector3(wx, wy, wz)


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

	var players: Array = get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var player_root: Node3D = players[0]
	var char_body: CharacterBody3D = player_root.get_node_or_null("CharacterBody3D")
	if char_body == null:
		return
	char_body.velocity = Vector3.ZERO
	char_body.global_position = start_pos

	# 同步摄像机目标
	_cam_target = get_parent().get_node_or_null("CameraTarget")
	if _cam_target != null:
		_cam_target.global_position = Vector3(start_pos.x, 0.0, start_pos.z)
	_player_char = char_body


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
