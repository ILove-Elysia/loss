# script/resources/resource_manager.gd
# ============================================
# 资源管理器 - 整个资源系统的核心控制器
#
# 这个脚本负责：
# 1. 初始化所有资源系统组件
# 2. 生成和管理游戏中的所有资源
# 3. 处理存档和读档
# 4. 提供全局访问接口
# 5. 距离流式加载（2026-09-12）：只实例化玩家附近的资源
#
# 为什么需要管理器？
# 就像餐厅需要一个经理来协调：
# - 厨师（生成器）做什么菜
# - 服务员（交互）怎么上菜
# - 仓库（对象池）管理食材
# - 记账（存档）记录收支
#
# ============================================
# 距离流式加载（2026-09-12）
# 用户需求演进：先要"只渲染玩家屏幕内的内容"，后改成"离玩家一定距离外就不加载"
# —— 距离是设出来的常数，比算出来的屏幕范围好定量调（见 script/world/view_frustum.gd）。
# ============================================
#
# 问题：
#   全图资源约 2400 个，每个实体的节点树是
#     ResourceEntity(Node3D) + StateMachine + Visual + Interaction
#              + Regeneration + RegenerationTimer + N 个 MeshInstance3D
#   约 7 个节点 —— 2400 × 7 ≈ 1.7 万个节点常驻场景树。
#   Godot 虽然会自动做视锥剔除（屏幕外的网格不绘制），但这些节点仍然要
#   参与场景树遍历、内存与批处理列表的维护，开销随"资源总量"线性增长，
#   而不是随"看得见的数量"增长。
#
# 做法：把资源拆成两层
#   数据层 _records  —— 每个资源一条记录（位置 / 状态 / 再生剩余时间），
#                       永远存在。约 2400 个 Dictionary，开销可忽略。
#   表现层 _entities —— 只有落在"玩家周围 N 米"内的记录才实例化出实体；
#                       超出范围立刻退回对象池（不是销毁）。
#   于是同一时刻通常只有几十个实体，节点总数从 1.7 万降到几百。
#
# 三条不能破的约束（每条都对应一类会"卡死/丢状态"的 bug）：
#   1. 卸载 = 退回对象池，绝不 queue_free。状态、再生倒计时都靠节点本身活着；
#   2. 采集中的实体（is_busy()）不卸载：harvest() 是 await 出来的长流程，
#      中途被搬走会让 await 回来时对着空壳操作；
#   3. 被点击采集订单钉住的实体（pinned）不卸载：否则对象池会把这个节点
#      复用成另一个位置的资源，ClickMover 的 _pending_resource 变成幽灵。
#   另外：没实例化的记录也要继续走再生倒计时（_regen_watch），
#   否则"采完就走远"等于资源永久消失。
# ============================================

class_name ResourceManager
extends Node

# ============================================
# 导出变量（在编辑器中配置）
# ============================================

# 资源注册表（拖入 resource_registry.tres）
# 注册表包含了所有资源的数据配置和预制体
@export var resource_registry: ResourceRegistry

# 资源生成器（拖入资源生成器节点）
@export var spawner: ResourceSpawner

# 资源容器（场景节点，用于存放所有生成的资源）
# 建议在场景中创建一个空的 Node3D 作为容器
@export var resource_container: Node3D

# ============================================
# 私有变量
# ============================================

# 对象池字典
# { "grass": ResourcePool, "tree": ResourcePool }
var _pools: Dictionary = {}

# 【表现层】当前已实例化的资源实体（只包含视野内的）
var _entities: Array[ResourceEntity] = []

# 【数据层】全部资源的记录，每个元素：
# {
#   "instance_id": int,      唯一 id（用于存档/调试）
#   "resource_id": StringName,
#   "pos": Vector3,          落点（y 恒为 0）
#   "state": int,            ResourceState.State
#   "regen_remaining": float 再生剩余秒数（<=0 表示不可再生或已长好）
#   "entity": ResourceEntity 已实例化时指向实体，否则 null
# }
var _records: Array[Dictionary] = []

# 实体 → 记录 的反查表（卸载时要把状态回写到记录）
var _record_by_entity: Dictionary = {}

# 记录自增 id
var _next_instance_id: int = 0

# 【再生看护名单】未被实例化、但正在倒计时的记录
# 单独维护成一张小表，避免每帧遍历 2400 条记录
var _regen_watch: Array[Dictionary] = []

# 流式加载节拍
var _stream_timer: float = 0.0
var _view_dirty: bool = true
# 批量建记录期间（新开局 / 读档）抑制实例化，避免一次性造出几千个实体
var _suppress_streaming: bool = false

# 存档数据处理
var _save_data: ResourceSaveData = ResourceSaveData.new()

# 生成的位置记录（避免重叠）
var _spawned_positions: Array[Vector3] = []

# 工具门槛提示（底部一行字，见 flash_hint）
var _hint_layer: CanvasLayer = null
var _hint_label: Label = null
var _flash_timer: float = 0.0

# ============================================
# 流式加载参数
#
# 【距离参数不在这里】装载 / 卸载距离（米）是全局统一的，
# 放在 script/world/view_frustum.gd 的 LOAD_RADIUS / UNLOAD_HYSTERESIS，
# 资源、建筑、敌人、掉落物共用同一份 —— 想调"离玩家多远就不加载"改那一处即可。
# 这里只放节拍与单次批量上限这类"与范围无关"的参数。
# ============================================

## 视野复算间隔（秒）。不必每帧算：玩家移速 5 m/s，0.15 秒才走 0.75 米。
const STREAM_INTERVAL: float = 0.15
## 单次复算最多实例化多少个（防止传送/瞬移时一帧内造几百个实体卡顿）
const MAX_LOAD_PER_PASS: int = 16

# ============================================
# 信号（通知其他节点）
# ============================================

# 资源生成完成信号
signal resources_spawned(count: int)

# 资源被采集信号
signal resource_harvested(entity: ResourceEntity, harvester: Node)

# ============================================
# 生命周期函数
# ============================================

# ----------------------------------------
# _ready() - 节点就绪时调用
# 相当于初始化函数
# ----------------------------------------
func _ready() -> void:
	# 注册组，供 ClickMover（点击移动/点击采集）按组查找本管理器，不写死节点路径
	add_to_group("resource_manager")

	# 初始化对象池
	_initialize_pools()
	
	# 有待应用的存档时跳过随机生成（存档里已带全部资源位置/状态），
	# 延迟一拍等整棵场景树（player/equipment/day_night）都 _ready 完再重建，
	# 否则读档中途会去设置还没就绪的节点。
	#
	# 注意：pending 的消费要放在注册表判断之外。注册表为空时若直接跳过，
	# pending_load_slot 会一直残留，之后点"新建游戏"会被它劫持成载入旧档。
	if SaveManager.has_pending_load():
		_apply_pending_save.call_deferred()
	elif resource_registry:
		spawn_initial_resources()


## 延迟应用主菜单请求的读档（SaveManager 总入口）
func _apply_pending_save() -> void:
	SaveManager.apply_pending_load(self)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 生成初始资源函数
# 在游戏开始时建立所有资源的"记录"
#
# 注意：这里**不再**为每个资源创建实体节点（2400 个实体 = 1.7 万节点，
# 开局会明显卡顿）。只建数据层记录，随后由 _update_streaming 实例化
# 玩家附近的那几十个。
# ----------------------------------------
func spawn_initial_resources() -> void:
	# 检查生成器是否有效
	if not spawner:
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "错误：ResourceSpawner 未配置！")
		return
	
	# 清空已有位置记录
	_spawned_positions.clear()
	
	# 遍历注册表中的所有资源数据
	var spawned_total: int = 0
	_suppress_streaming = true
	for data in resource_registry.get_all_resource_data():
		# 生成该资源的位置
		var positions = spawner.generate_positions(
			data,
			data.initial_count,
			_spawned_positions
		)
		
		# 在每个位置建立资源记录
		for pos in positions:
			if not add_record(data.resource_id, pos).is_empty():
				spawned_total += 1

		# 实际落位少于配置数量 = 该资源允许的区域装不下这么多
		# （区域面积太小，或 min_distance 太密导致互相排斥）。
		# 最常见于只属于单一区域的资源：石头（仅矿区）、煤炭（仅火山区）。
		if positions.size() < data.initial_count:
			DebugConfig.warn_msg(DebugConfig.CAT_RESOURCE,
				"[资源系统] %s 只放下 %d/%d 个（区域面积或间距限制）",
				[data.resource_id, positions.size(), data.initial_count])
	
	# 地图世界尺寸为 1600×1600，纯随机撒点会让玩家出生点附近大概率一个资源都没有，
	# 按空格采集会一直"附近没有资源可用"。这里保证出生点周围有一小簇起步资源。
	_spawn_starter_cluster()
	_suppress_streaming = false
	
	# 先把出生点附近这一屏装配出来，避免开局第一帧是个空世界
	_update_streaming()

	DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[资源系统] 初始生成完成：共 %d 个资源", [_records.size()])
	resources_spawned.emit(_records.size())

# ----------------------------------------
# 建立一条资源记录（数据层，不产生节点）
#
# 参数：
#   resource_id     - 资源ID（如 "grass", "tree"）
#   position        - 落点（y 会被压到 0）
#   state           - 初始状态（默认生长中）
#   regen_remaining - 再生剩余秒数（读档用，<=0 = 从头开始）
# 返回：记录字典；资源 id 未登记时返回空字典
# ----------------------------------------
func add_record(resource_id: StringName, position: Vector3, state: int = int(ResourceState.State.GROWING), regen_remaining: float = 0.0) -> Dictionary:
	if resource_registry == null:
		return {}
	if resource_registry.get_resource_data(resource_id) == null:
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "错误：找不到资源数据 %s", [resource_id])
		return {}

	var rec: Dictionary = {
		"instance_id": _next_instance_id,
		"resource_id": resource_id,
		"pos": Vector3(position.x, 0.0, position.z),
		"state": state,
		"regen_remaining": regen_remaining,
		"entity": null,
	}
	_next_instance_id += 1
	_records.append(rec)

	# 采完还没长好的资源要进看护名单（它可能一直不被实例化，
	# 光靠实体自己的 Timer 是走不动的——实体一旦退回对象池，Timer 就停了）
	if state == int(ResourceState.State.HARVESTED) and regen_remaining > 0.0:
		_regen_watch.append(rec)
	return rec

# ----------------------------------------
# 从存档条目建立记录
# 键名与旧存档完全一致（instance_id / resource_id / position / state /
# regen_time_remaining），所以老档可以直接读。
# ----------------------------------------
func add_record_from_save(data: Dictionary) -> void:
	var rid := StringName(data.get("resource_id", ""))
	if rid == StringName(""):
		return
	var pd: Dictionary = data.get("position", {})
	var pos := Vector3(float(pd.get("x", 0.0)), 0.0, float(pd.get("z", 0.0)))

	# TRANSITIONING / REGENERATING 是"过程态"，记录层没有计时器接手，
	# 原样存进去会永久卡死。统一按"已采集"恢复，再生倒计时由这条记录接着走。
	# （与 SaveManager._normalize_resource_states 同一套规则，双保险）
	var st := int(data.get("state", int(ResourceState.State.GROWING)))
	if st != int(ResourceState.State.GROWING) and st != int(ResourceState.State.HARVESTED):
		st = int(ResourceState.State.HARVESTED)

	var rec := add_record(rid, pos, st, float(data.get("regen_time_remaining", 0.0)))
	if rec.is_empty():
		return
	rec["instance_id"] = int(data.get("instance_id", rec["instance_id"]))

	# "采集中途存档"这一种档：state 被归一化成 HARVESTED，但那时还没开始计时，
	# regen_time_remaining = 0。记录层没有"实体创建后再启动"的时机，
	# 这里直接按完整再生时长补一次倒计时——否则这条资源会永远停在已采集，
	# 玩家再也不去那个地方的话就等于永久消失（旧实现是实例化时 start_regeneration）。
	if st == int(ResourceState.State.HARVESTED) and float(rec["regen_remaining"]) <= 0.0:
		var rdata := get_record_data(rec)
		if rdata != null and rdata.can_regenerate and rdata.regeneration_time > 0.0:
			rec["regen_remaining"] = rdata.regeneration_time
			if not _regen_watch.has(rec):
				_regen_watch.append(rec)

# ----------------------------------------
# 生成单个资源函数（记录 + 立刻实例化）
#
# 兼容旧签名：调用方拿到的还是实体。种树、调试、以及将来"在玩家眼前生成
# 一个东西"这类需求都走它——反正目标一定在玩家附近，实例化是正确行为。
#
# 参数：
#   resource_id - 资源ID（如 "grass", "tree"）
#   position    - 生成位置（Vector3）
#   state       - 初始状态（可选，默认生长中）
# 返回：生成的资源实体（被抑制实例化时可能为 null）
# ----------------------------------------
func spawn_resource(resource_id: StringName, position: Vector3, state: ResourceState.State = ResourceState.State.GROWING) -> ResourceEntity:
	var rec := add_record(resource_id, position, int(state), 0.0)
	if rec.is_empty():
		return null
	if _suppress_streaming:
		return null
	return _materialize(rec)

# ----------------------------------------
# 采集资源函数
# 触发资源的采集行为
#
# 参数：
#   entity - 要采集的资源实体
#   harvester - 采集者（通常是玩家）
# ----------------------------------------
func harvest_resource(entity: ResourceEntity, harvester: Node) -> void:
	# 检查实体是否有效且可以采集
	if is_instance_valid(entity) and entity.can_harvest():
		entity.harvest(harvester)

# ----------------------------------------
# 挖掘资源函数
# 使用铲子挖掘资源
# ----------------------------------------
func dig_resource(entity: ResourceEntity, digger: Node) -> void:
	if is_instance_valid(entity) and entity.can_dig():
		entity.dig(digger)

# ----------------------------------------
# 种植资源函数
# 在指定位置种植资源
#
# 参数：
#   resource_id - 要种植的资源ID
#   position - 种植位置
#   planter - 种植者
# 返回：是否种植成功
# ----------------------------------------
func plant_resource(resource_id: StringName, position: Vector3, planter: Node) -> bool:
	# 获取资源数据
	var data = resource_registry.get_resource_data(resource_id)
	if not data:
		return false
	
	# 检查是否可以种植
	if not data.can_plant:
		return false
	
	# 检查位置是否有效
	if not spawner._is_valid_position(position, data, _spawned_positions):
		return false
	
	# 生成资源
	var entity = spawn_resource(resource_id, position)
	
	# 如果生成成功，从种植者背包扣除种子
	if entity:
		# 通知种植成功（需要背包系统配合）
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "%s 种植了 %s", [planter.name, data.display_name])
		return true
	
	return false

# ----------------------------------------
# 保存游戏函数
# 将全部资源（记录层）状态存进存档
#
# 注意：数据源是 _records 而不是 _entities —— 视野外的资源也必须存，
# 而且它们的状态本来就完整地躺在记录里。
# ----------------------------------------
func save_game() -> Dictionary:
	return _save_data.save_records(_records)

# ----------------------------------------
# 加载游戏函数
# 从存档恢复所有资源记录，再按玩家位置装配视野内的实体
# ----------------------------------------
func load_game(data: Dictionary) -> void:
	# 清除当前所有资源
	clear_all_resources()
	
	# 加载存档数据（只建记录，不建节点）
	_suppress_streaming = true
	_save_data.load_all(data, self)
	_suppress_streaming = false

	# 不在这里立刻装配：读档时玩家位置往往还没恢复（SaveManager 先应用
	# 世界再应用玩家），此刻装配会装错一片区域。交给下一帧的 _process。
	_view_dirty = true

# ----------------------------------------
# 清除所有资源函数
# 移除场景中所有资源实体与记录
# ----------------------------------------
func clear_all_resources() -> void:
	# 释放所有活跃实体到对象池
	for entity in _entities:
		if is_instance_valid(entity):
			var rid := ""
			if entity.resource_data != null:
				rid = str(entity.resource_data.resource_id)
			if _pools.has(rid):
				_pools[rid].release(entity)
			else:
				entity.queue_free()
	
	# 清空列表
	_entities.clear()
	_record_by_entity.clear()
	_records.clear()
	_regen_watch.clear()
	_spawned_positions.clear()
	_next_instance_id = 0
	_view_dirty = true

# ----------------------------------------
# 流式加载统计（调试 / 自动化测试用）
# ----------------------------------------
func get_stream_stats() -> Dictionary:
	return {
		"total": _records.size(),
		"loaded": _entities.size(),
		"regen_watch": _regen_watch.size(),
		"pools": _pools.size(),
	}

# ----------------------------------------
# 某条记录当前是否可采集（不改动任何状态）
# ----------------------------------------
func is_record_harvestable(rec: Dictionary) -> bool:
	if int(rec.get("state", 0)) != int(ResourceState.State.GROWING):
		return false
	var data := get_record_data(rec)
	if data == null:
		return false
	if not data.can_harvest:
		return false
	return data.drop_item_id != StringName("")

# ----------------------------------------
# 取记录对应的资源数据
# ----------------------------------------
func get_record_data(rec: Dictionary) -> ResourceData:
	if resource_registry == null:
		return null
	return resource_registry.get_resource_data(StringName(rec.get("resource_id", "")))

# ============================================
# 起步资源簇
# ============================================

# 出生点周围保证出现的资源数量（资源ID → 个数）
# 地图为 1600×1600，若只靠随机撒点，玩家出生后很久都碰不到资源，
# 因此额外在出生点周围环形撒一小簇，确保"一开局就能采集、能拿到木头"。
#
# 注意：采集工具强制后（树要斧、大石要镐），起步簇必须保证空手
# 有产出 —— 草 + 小石块（都 required_tool=NONE），捡出来的石头
# 够合成"粗制石斧"（石3+草3），再砍树进入正常链路。
const STARTER_CLUSTER: Dictionary = {
	"grass": 6,
	"pebble": 6,
	"twig": 4,
	"berry": 3,
	"tree": 2,
}

# ----------------------------------------
# 生成出生点起步资源簇
# 以世界原点（玩家出生点）为中心，5~12 米环形分布，
# 落到非陆地（海洋/沙滩）的位置自动跳过。
# ----------------------------------------
func _spawn_starter_cluster() -> void:
	var center := Vector3.ZERO
	var entries: Array[ResourceData] = []
	for rid in STARTER_CLUSTER.keys():
		var data = resource_registry.get_resource_data(StringName(rid))
		if data == null:
			continue
		for i in int(STARTER_CLUSTER[rid]):
			entries.append(data)
	if entries.is_empty():
		return

	var total: int = entries.size()
	for i in total:
		var data: ResourceData = entries[i]
		var angle: float = TAU * float(i) / float(total)
		var radius: float = randf_range(5.0, 12.0)
		var pos := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		if not _is_land_at(pos):
			continue
		add_record(data.resource_id, pos)

# ----------------------------------------
# 陆地判定（复用地图生成器）
# ----------------------------------------
func _is_land_at(pos: Vector3) -> bool:
	var gens := get_tree().get_nodes_in_group("map_gen")
	if gens.is_empty():
		return true
	var mg = gens[0]
	if mg != null and mg.has_method("is_land_world"):
		return bool(mg.is_land_world(pos))
	return true

# ============================================
# 采集交互（唯一权威入口）
# ============================================
#
# 为什么采集不放在每个资源自己的 Area3D 里？
# 历史上每个 ResourceEntity 都挂一个 Area3D 检测玩家，问题不断：
#   - Area 根本没检测到玩家（body_entered 从不触发）→ 完全采不了；
#   - 一旦能检测，附近多个 Area 又会同时响应同一次按键 → "一次采一片"。
# 现在改为唯一权威：按下交互键时，由本管理器找出"玩家附近最近的
# 一个可采集资源"并采集它。逻辑确定、不依赖物理检测、天然只采一个。
#
# 2026-09-12 起判定对象从"实体"换成"记录"：视野外的资源没有实体，
# 但玩家可能正好站在它的记录旁边（例如刚走近）。命中后即时实例化即可。
#
# 交互范围（米）：与资源侧 ResourceInteraction.interaction_range 保持一致。
const INTERACT_RANGE: float = 3.0

func _process(delta: float) -> void:
	# 一次性提示的倒计时放在按键处理之前，保证到点一定收起
	_tick_flash(delta)

	# 视野外的资源也在流逝：先把"看护名单"里的再生倒计时走掉
	_tick_record_regeneration(delta)

	# 视野装配：按节拍复算，或收到 _view_dirty 时立刻算一次
	_stream_timer += delta
	if _view_dirty or _stream_timer >= STREAM_INTERVAL:
		_stream_timer = 0.0
		_view_dirty = false
		if not _suppress_streaming:
			_update_streaming()

	if Input.is_action_just_pressed("player_interact"):
		_try_harvest_nearest()

# ============================================
# 工具门槛（空手 / 工具类型不符时拒绝采集）
# ============================================
#
# 规则（2026-09-12 用户约定）：
#   树必须装备斧头、大石头/矿必须装备镐子；
#   草和小石块空手可采（required_tool = NONE）。
#   死锁的解法：小石块空手可捡 → 掉石头 → 粗制石斧（石3+草3，徒手配方）
#   → 砍树 → 原木 → 木镐 → 大石头。
#
# 提示走本文件的 flash_hint（底部一行字，1.6 秒收起），
# 与 BuildPlacer 的提示层同名不同节点，互不干扰。

## 玩家当前装备的工具是否满足该资源的采集要求（记录版，不需要实体）
func is_tool_sufficient_for_data(data: ResourceData) -> bool:
	if data == null:
		return false
	var required := int(data.required_tool)
	if required == int(ResourceData.HarvestTool.NONE):
		return true
	return _current_tool() == required

## 玩家当前装备的工具是否满足该资源的采集要求
## 无 Equipment 节点时按"空手"处理（只有 NONE 资源可通过）
func is_tool_sufficient(entity: ResourceEntity) -> bool:
	if entity == null or not is_instance_valid(entity) or entity.resource_data == null:
		return false
	return is_tool_sufficient_for_data(entity.resource_data)

## 玩家当前工具类型（无 Equipment 时 = NONE）
func _current_tool() -> int:
	var root := _get_player_root()
	if root == null:
		return int(ResourceData.HarvestTool.NONE)
	var equipment = root.get_node_or_null("Equipment")
	if equipment == null or not equipment.has_method("get_current_tool"):
		return int(ResourceData.HarvestTool.NONE)
	return int(equipment.call("get_current_tool"))

## 该资源缺工具时的提示文案
func get_tool_missing_hint(entity: ResourceEntity) -> String:
	if entity == null or not is_instance_valid(entity):
		return ""
	return get_tool_missing_hint_for_data(entity.resource_data)

## 该资源缺工具时的提示文案（记录版）
func get_tool_missing_hint_for_data(data: ResourceData) -> String:
	if data == null:
		return ""
	var verb := ResourceData.get_harvest_verb(int(data.required_tool))
	var tool_name := ResourceData.get_required_tool_name(int(data.required_tool))
	return "%s「%s」需要装备%s" % [verb, data.display_name, tool_name]


## 底部一行字提示，1.6 秒自动收起（与 BuildPlacer 的提示同款交互，层号错开）
func flash_hint(text: String) -> void:
	_ensure_hint()
	if _hint_label == null or _hint_layer == null:
		return
	_hint_label.text = text
	_hint_layer.visible = true
	_flash_timer = 1.6

func _ensure_hint() -> void:
	if _hint_layer != null and is_instance_valid(_hint_layer):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	_hint_layer = CanvasLayer.new()
	_hint_layer.name = "ResourceHintLayer"
	# 与 BuildPlacer 的提示层(150)错开，避免同时显示时互相遮挡
	_hint_layer.layer = 151
	scene.add_child(_hint_layer)

	_hint_label = Label.new()
	# 显式 anchor + 对称 offset（运行时 new 出来的控件不能用 set_anchors_preset）
	_hint_label.anchor_left = 0.5
	_hint_label.anchor_right = 0.5
	_hint_label.anchor_top = 1.0
	_hint_label.anchor_bottom = 1.0
	_hint_label.offset_left = -220
	_hint_label.offset_right = 220
	_hint_label.offset_top = -110
	_hint_label.offset_bottom = -86
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_layer.add_child(_hint_label)

func _tick_flash(delta: float) -> void:
	if _flash_timer <= 0.0:
		return
	_flash_timer -= delta
	if _flash_timer <= 0.0 and _hint_layer != null and is_instance_valid(_hint_layer):
		_hint_layer.visible = false

# ----------------------------------------
# 找世界坐标附近最近的资源（水平距离判定，与采集判定同口径）
# ClickMover 点击采集用：鼠标落点 click_radius 内的资源才算"被点中"。
#
# 命中视野外的资源时会即时实例化它（返回实体，调用方要读 global_position）。
#
# @param world_pos 世界坐标（鼠标射线与地面的交点）
# @param radius 搜索半径（米）
# @param harvestable_only 是否只考虑当前可采集的资源
# ----------------------------------------
func find_nearest_resource(world_pos: Vector3, radius: float, harvestable_only: bool = true) -> ResourceEntity:
	var rec := _nearest_record(world_pos, radius, harvestable_only)
	if rec.is_empty():
		return null
	return _ensure_materialized(rec)

# ----------------------------------------
# 找离某点最近、且在半径内的资源记录（空字典 = 没找到）
# ----------------------------------------
func _nearest_record(world_pos: Vector3, radius: float, harvestable_only: bool) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: float = radius
	for rec in _records:
		var p: Vector3 = rec["pos"]
		var dx: float = p.x - world_pos.x
		var dz: float = p.z - world_pos.z
		var d: float = sqrt(dx * dx + dz * dz)
		# 先比距离（便宜），再查状态/数据（贵）——绝大多数记录在第一关就被否决
		if d >= best_dist:
			continue
		if harvestable_only and not is_record_harvestable(rec):
			continue
		best_dist = d
		best = rec
	return best

# ----------------------------------------
# 采集玩家附近最近的可采集资源
# 水平距离判定（忽略高度差，更符合"靠近"的直觉）。
# 一次按键只采一个；采集期间互斥锁保证不会同时采多个。
# ----------------------------------------
func _try_harvest_nearest() -> void:
	var player_root := _get_player_root()
	if player_root == null:
		return
	var ppos := _get_player_world_position()

	# best_any = 范围内最近的可采集资源（不管工具）
	# best_fit = 其中"当前工具采得动"的最近者
	# 有 best_fit 就采它；只有 best_any 时说明玩家站错了地方/没带对工具 → 提示
	var best_any: Dictionary = {}
	var best_fit: Dictionary = {}
	var best_any_dist: float = INTERACT_RANGE
	var best_fit_dist: float = INTERACT_RANGE
	var nearest_any: float = INF
	for rec in _records:
		var p: Vector3 = rec["pos"]
		var dx: float = p.x - ppos.x
		var dz: float = p.z - ppos.z
		var d: float = sqrt(dx * dx + dz * dz)
		if d < nearest_any:
			nearest_any = d
		# 只考虑"范围内且可采集（GROWING、有掉落物）"的最近者
		if d > INTERACT_RANGE or not is_record_harvestable(rec):
			continue
		if d < best_any_dist:
			best_any_dist = d
			best_any = rec
		if d < best_fit_dist and is_tool_sufficient_for_data(get_record_data(rec)):
			best_fit_dist = d
			best_fit = rec

	if not best_fit.is_empty():
		# 命中：先实例化（它可能刚好在视野外一步），再走原来的采集流程
		var entity := _ensure_materialized(best_fit)
		if entity != null:
			DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集] 采集最近资源：%s 距离=%.2f",
				[entity.resource_data.resource_id, best_fit_dist])
			harvest_resource(entity, player_root)
		return

	if not best_any.is_empty():
		# 范围内有资源但工具不对：不采，闪提示告诉玩家缺什么。
		# 这里**不**实例化——为了显示一行字把一个资源节点搬进场景不值当。
		var hint := get_tool_missing_hint_for_data(get_record_data(best_any))
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集] 工具不足被拒：%s（距离=%.2f）",
			[best_any.get("resource_id", ""), best_any_dist])
		flash_hint(hint)
		return

	var nd: float = nearest_any if nearest_any < INF else -1.0
	DebugConfig.log_msg(DebugConfig.CAT_RESOURCE,
		"[采集] 附近没有可采集资源（最近距离=%.2f，交互范围=%s）", [nd, INTERACT_RANGE])

# ----------------------------------------
# 取玩家根节点（player 组成员；其下挂 Inventory / Equipment）
# ----------------------------------------
func _get_player_root() -> Node:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if not players.is_empty() else null

# ----------------------------------------
# 取玩家真实世界坐标
# 注意：玩家根节点只是容器、恒在原点，真正移动的是其子节点 Physics。
# 具体取法在 ViewFrustum（与敌人/掉落物的流式加载共用）。
# ----------------------------------------
func _get_player_world_position() -> Vector3:
	return ViewFrustum.player_position(get_tree())

# ============================================
# 视野流式加载（核心）
# ============================================

# ----------------------------------------
# 一次装配：卸载远处的实体 + 实例化玩家附近的记录
#
# 判定全部按"距玩家的水平距离"：
#   距离 <= 装载半径       → 装载
#   距离 >  装载 + 滞回    → 卸载
#   中间那段               → 维持现状（滞回带）
# 距离常数统一在 ViewFrustum，改一处全局生效。
# ----------------------------------------
func _update_streaming() -> void:
	var ppos: Vector3 = _get_player_world_position()
	var unloaded: int = _unload_outside(ppos)
	var loaded: int = _load_inside(ppos)

	_update_building_streaming(ppos)
	_log_stream_stats(loaded, unloaded)

# ----------------------------------------
# 卸载：把超出卸载半径的实体退回对象池
# 倒序索引遍历：_dematerialize 会从 _entities 里 erase 当前元素
# ----------------------------------------
func _unload_outside(player_pos: Vector3) -> int:
	var unloaded: int = 0
	var keep_r: float = ViewFrustum.unload_radius("resource")
	var i: int = _entities.size() - 1
	while i >= 0:
		var entity: ResourceEntity = _entities[i]
		i -= 1
		if entity == null or not is_instance_valid(entity):
			# 实体被别处销毁了（如 dig() 里的 queue_free）：清掉引用即可
			_entities.remove_at(i + 1)
			continue
		var rec = _record_by_entity.get(entity)
		var p: Vector3 = entity.global_position
		if rec is Dictionary:
			var rp: Vector3 = rec["pos"]
			p = Vector3(rp.x, 0.0, rp.z)
		if ViewFrustum.flat_distance(p, player_pos) <= keep_r:
			continue
		if not can_unload(entity, player_pos):
			continue
		_dematerialize(entity)
		unloaded += 1
	return unloaded

# ----------------------------------------
# 实例化：玩家附近、还没实例化的记录，按"离玩家越近越先补"的顺序装配
# 每次最多 MAX_LOAD_PER_PASS 个，避免瞬移时一帧造几百个实体
# ----------------------------------------
func _load_inside(player_pos: Vector3) -> int:
	var load_r: float = ViewFrustum.load_radius("resource")
	var pending: Array[Dictionary] = []
	for rec in _records:
		var ent = rec["entity"]
		if ent != null and is_instance_valid(ent):
			continue
		var p: Vector3 = rec["pos"]
		if ViewFrustum.flat_distance(p, player_pos) > load_r:
			continue
		pending.append(rec)

	var loaded: int = 0
	var center := Vector2(player_pos.x, player_pos.z)
	while loaded < MAX_LOAD_PER_PASS and not pending.is_empty():
		var best_i: int = 0
		var best_d: float = INF
		for k in pending.size():
			var pk: Vector3 = pending[k]["pos"]
			var d: float = (Vector2(pk.x, pk.z) - center).length_squared()
			if d < best_d:
				best_d = d
				best_i = k
		var rec: Dictionary = pending[best_i]
		pending.remove_at(best_i)
		if _materialize(rec) != null:
			loaded += 1
	return loaded

# ----------------------------------------
# 是否可以卸载
#
# 三种情况必须留在场上：
#   1. 被点击采集订单钉住（pinned）——否则对象池复用后订单指向幽灵节点；
#   2. 正在采集（is_busy）——harvest() 的 await 还没走完；
#   3. 玩家就在旁边（3 米内）——宁可多留一个节点，也不要"眼前的东西突然消失"。
#
# player_pos 由调用方算好传进来（一次装配只取一次玩家坐标）
# ----------------------------------------
func can_unload(entity: ResourceEntity, player_pos: Vector3) -> bool:
	if entity.pinned:
		return false
	if entity.is_busy():
		return false
	var ep: Vector3 = entity.global_position
	var d: float = Vector2(ep.x - player_pos.x, ep.z - player_pos.z).length()
	if d <= INTERACT_RANGE:
		return false
	return true

# ----------------------------------------
# 实例化一条记录
# ----------------------------------------
func _materialize(rec: Dictionary) -> ResourceEntity:
	var rid: StringName = rec["resource_id"]
	var data = resource_registry.get_resource_data(rid)
	if data == null:
		return null
	var pool = _get_or_create_pool(rid, data)
	if pool == null:
		return null

	# 容器缺省时挂到自己身上（headless 测试里没有场景容器）
	# —— 必须先入树，pool.acquire 才能安全地设 global_position 与状态
	var container: Node = resource_container if resource_container != null else self
	var pos: Vector3 = rec["pos"]
	# 显式标注枚举类型：从 Variant 取出后直接传 int 会触发
	# "int as enum without cast" 警告，标注成枚举即可原样使用
	var state: ResourceState.State = rec["state"]
	var entity: ResourceEntity = pool.acquire(data, pos, state, container)
	if entity == null:
		return null

	entity.instance_id = int(rec["instance_id"])
	# 把记录层的状态/倒计时原样套回实体（对象池的 acquire 只设了大状态）
	entity.apply_record_state(state, float(rec["regen_remaining"]))

	_wire_entity_signals(entity)
	rec["entity"] = entity
	_record_by_entity[entity] = rec
	_entities.append(entity)

	# 实体自己的 Timer 接管倒计时，把它从"看护名单"摘掉，避免双份计时
	_regen_watch.erase(rec)
	return entity

# ----------------------------------------
# 卸载一个实体：状态回写记录 → 退回对象池
# ----------------------------------------
func _dematerialize(entity: ResourceEntity) -> void:
	var rec = _record_by_entity.get(entity)
	_record_by_entity.erase(entity)
	_entities.erase(entity)

	if rec is Dictionary:
		if is_instance_valid(entity):
			_sync_record_from_entity(rec, entity)
		rec["entity"] = null
		# 采完还在倒计时的资源进看护名单，交给 _tick_record_regeneration
		if int(rec["state"]) == int(ResourceState.State.HARVESTED) and float(rec["regen_remaining"]) > 0.0:
			if not _regen_watch.has(rec):
				_regen_watch.append(rec)

	if not is_instance_valid(entity):
		return
	var rid := ""
	if entity.resource_data != null:
		rid = str(entity.resource_data.resource_id)
	if _pools.has(rid):
		_pools[rid].release(entity)
	else:
		entity.queue_free()

# ----------------------------------------
# 把实体当前状态写回记录
#
# 用 get_save_data() 取（它就是"实体 → 可存数据"的权威转换），
# 再把过程态归一化成 HARVESTED —— 记录层没有计时器接手 TRANSITIONING，
# 存进去会永久卡死。
# ----------------------------------------
func _sync_record_from_entity(rec: Dictionary, entity: ResourceEntity) -> void:
	var d: Dictionary = entity.get_save_data()
	var st := int(d.get("state", int(ResourceState.State.GROWING)))
	if st != int(ResourceState.State.GROWING) and st != int(ResourceState.State.HARVESTED):
		st = int(ResourceState.State.HARVESTED)
	rec["state"] = st
	rec["regen_remaining"] = float(d.get("regen_time_remaining", 0.0))

# ----------------------------------------
# 已实例化的记录直接复用，否则即时实例化
# ----------------------------------------
func _ensure_materialized(rec: Dictionary) -> ResourceEntity:
	var ent = rec.get("entity")
	if ent != null and is_instance_valid(ent):
		return ent as ResourceEntity
	return _materialize(rec)

# ----------------------------------------
# 未实例化资源的再生倒计时
# 只遍历"看护名单"，与全图资源总量无关
# ----------------------------------------
func _tick_record_regeneration(delta: float) -> void:
	if delta <= 0.0 or _regen_watch.is_empty():
		return
	var i: int = _regen_watch.size() - 1
	while i >= 0:
		var rec: Dictionary = _regen_watch[i]
		var rem: float = float(rec["regen_remaining"]) - delta
		if rem > 0.0:
			rec["regen_remaining"] = rem
			i -= 1
			continue
		# 长好了：记录回到生长态，等下次进视野时以正常形态出现
		rec["state"] = int(ResourceState.State.GROWING)
		rec["regen_remaining"] = 0.0
		_regen_watch.remove_at(i)
		i -= 1

# ----------------------------------------
# 建筑的可见性剔除（顺带做，不做对象池）
#
# 建筑数量本来就少（玩家自己放的），价值不如资源大；但它同样"远处不需要渲染"。
# 判定与资源共用同一个半径（ViewFrustum 的 "building" 档），
# 所以"树在、建筑没了"这种错位不会出现。
#
# 注意两件事：
#   · 不能只 node.visible = false —— 那样会留下"看不见的墙"，
#     所以隐藏时把 StaticBody3D 的 collision_layer 也置 0，恢复时还原成 2。
#   · 只切换可见性、不动 BuildingSystem 的登记表，
#     所以工作台/熔炉的"永久解锁配方"与储物箱内容都不受影响。
# ----------------------------------------
func _update_building_streaming(player_pos: Vector3) -> void:
	var keep_r: float = ViewFrustum.unload_radius("building")
	for b in BuildingSystem.get_placed():
		if b == null or not is_instance_valid(b):
			continue
		var node := b as Node3D
		if node == null:
			continue
		# 不在树里的节点读 global_position 会报 !is_inside_tree()，直接跳过
		if not node.is_inside_tree():
			continue
		var p: Vector3 = node.global_position
		var inside: bool = ViewFrustum.flat_distance(p, player_pos) <= keep_r
		if node.visible == inside:
			continue
		node.visible = inside
		var body := node.get_node_or_null("CollisionBody")
		if body is StaticBody3D:
			# layer 2 = 地面/障碍（与 Building._build_collision 保持一致）
			(body as StaticBody3D).collision_layer = 2 if inside else 0

# ----------------------------------------
# 装配日志：只在真的发生加载/卸载时打印（避免每 0.15 秒刷一行）
# ----------------------------------------
func _log_stream_stats(loaded: int, unloaded: int) -> void:
	if loaded == 0 and unloaded == 0:
		return
	DebugConfig.log_msg(DebugConfig.CAT_STREAM,
		"[资源流式加载] 实例化 %d / 退回对象池 %d，当前场上 %d / 全图 %d",
		[loaded, unloaded, _entities.size(), _records.size()])

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 初始化对象池函数
# 为每种资源类型创建一个对象池
# ----------------------------------------
func _initialize_pools() -> void:
	if not resource_registry:
		return
	
	# 遍历所有资源数据
	for data in resource_registry.get_all_resource_data():
		# 获取预制体场景
		var scene = resource_registry.get_resource_scene(data.resource_id)
		if scene:
			# 创建对象池
			var pool = ResourcePool.new()
			pool.initialize(scene, data)
			_pools[str(data.resource_id)] = pool

# ----------------------------------------
# 获取或创建对象池函数
# ----------------------------------------
func _get_or_create_pool(resource_id: StringName, data: ResourceData) -> ResourcePool:
	var key = str(resource_id)
	
	# 如果池已存在，直接返回
	if _pools.has(key):
		return _pools[key]
	
	# 如果池不存在，创建新的池
	var scene = resource_registry.get_resource_scene(resource_id)
	if scene:
		var pool = ResourcePool.new()
		pool.initialize(scene, data)
		_pools[key] = pool
		return pool
	
	return null

# ----------------------------------------
# 连接实体信号函数
# 将实体的信号连接到管理器
#
# 流式加载后同一个实体节点会被反复复用（卸载→池→再取出），
# 而 spawn 路径会重复经过这里。用 meta 标记保证只连一次，
# 否则采集一次会触发 N 次回调（历史坑）。
# ----------------------------------------
func _wire_entity_signals(entity: ResourceEntity) -> void:
	if entity.has_meta("rm_signals_wired"):
		return
	entity.set_meta("rm_signals_wired", true)
	# 连接采集完成信号
	entity.harvested.connect(func(harvester):
		_on_entity_harvested(entity, harvester)
	)
	# 连接状态改变信号
	entity.state_changed.connect(func(new_state):
		_on_entity_state_changed(entity, new_state)
	)

# ----------------------------------------
# 实体采集完成处理函数
# ----------------------------------------
func _on_entity_harvested(entity: ResourceEntity, harvester: Node) -> void:
	# 发射信号通知其他节点
	resource_harvested.emit(entity, harvester)
	
	DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "%s 被采集了", [entity.resource_data.display_name])

# ----------------------------------------
# 实体状态改变处理函数
# ----------------------------------------
func _on_entity_state_changed(entity: ResourceEntity, new_state: ResourceState.State) -> void:
	# 可以在这里添加状态改变的额外逻辑
	# 例如：记录统计数据、触发事件等
	pass
