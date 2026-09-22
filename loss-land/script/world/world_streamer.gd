# script/world/world_streamer.gd
# ============================================
# 世界内容视野流式加载：敌人 + 地面掉落物
#
# 与 ResourceManager 的「记录层 / 表现层」同一思路（只装配玩家附近的东西），
# 但这两种东西的生命周期与资源差别很大，所以单独成一个管理器
# —— 资源那边有对象池和再生计时器，这里要处理的是"会自己跑"和"会随时新增"：
#
#   敌人（场景预置的固定几只：Slime / Drone / 出生点测试怪）
#     节点创建一次就不再新建：卸载 = remove_child 挂起，加载 = add_child 放回原位。
#     为什么不用 queue_free 重建：血量、巡逻点、追击目标这些运行态全长在节点上，
#     重建等于"读档式复位"，远处的怪会莫名其妙回满血。
#     挂起期间节点不在树里 → _physics_process 不跑、碰撞体移出物理空间，
#     省下的正是"看不见的怪也在跑 AI"这笔开销。
#
#   掉落物（任何时候都可能新增：怪死掉落）
#     每次装配先"收编"一遍（扫 item_drop 组，没登记的补一条记录），再按视野装卸。
#     卸载时把 count 同步回记录 —— 半堆拾取过的掉落物要保留剩余数量。
#
# 三条不能破的约束（每条都对应一类会"见鬼"的 bug）：
#   1. 卸载只是 remove_child，绝不 queue_free（节点一没，状态就没了）；
#   2. 玩家附近的永不卸载 —— 装配半径本身就远大于所有战斗/交互距离
#      （敌人仇恨 14m、无人机开火 8m、拾取 1.2m；半径是 70m/50m），
#      所以"一路追着你打的怪在边界凭空消失"这类事在结构上不会发生；
#      这条以前是一组单独的"保底距离"常量，改距离制后已被半径覆盖，故删除；
#   3. 挂起/放回复用的是**同一个节点**（不重建），所以敌人与掉落物的初始化
#      必须是幂等的。Slime / Drone / ItemDrop 的 _ready 都加了"只初始化一次"的
#      守卫：官方文档明确「重新入树不会再调一次 _ready」，但"回满血 / 叠加
#      第二套视觉"这类副作用不该赌引擎行为，守卫让幂等成为硬保证。
#
# 存档：SaveManager 不再自己扫组，而是把 enemies / drops 两块委托给本管理器
#   ——未装配的实体不在场景树里，扫组扫不到，会被当成"已被击杀"删掉。
#   没有本节点的场景（旧测试场景）SaveManager 会退回原来的扫组逻辑。
#
# 装载距离与 ResourceManager 共用 ViewFrustum（距离常数唯一入口），
# 保证资源 / 敌人 / 掉落物在同一个边界上一起进出，不会出现"树还在、怪先没了"。
# ============================================

class_name WorldStreamer
extends Node

# ============================================
# 参数
#
# 【距离参数不在这里】装载 / 卸载距离（米）由 ViewFrustum 统一管理：
#   敌人的档位是 LOAD_RADIUS["enemy"]、掉落物是 LOAD_RADIUS["drop"]，
#   卸载 = 装载 + UNLOAD_HYSTERESIS。想改"离玩家多远就不加载"改那里一处即可。
# ============================================

## 视野复算间隔（秒）。不必每帧算：玩家移速 5 m/s，0.15 秒才走 0.75 米。
const STREAM_INTERVAL: float = 0.15
## 单次复算最多装配几个掉落物（敌人只有几只，不设限）
const MAX_DROPS_PER_PASS: int = 16

# ============================================
# 内部状态
# ============================================

## 敌人记录，每个元素：
## {
##   "node": Node,        节点本体（挂起时仍然有效，只是不在树里）
##   "parent": Node,      原父节点（放回时用；父节点跨场景销毁则退回当前场景根）
##   "path": String,      相对 current_scene 的路径 —— 存档沿用旧格式按它匹配
##   "pos": Vector3,      最近一次已知世界坐标（挂起期间唯一可信的位置来源）
##   "loaded": bool       当前是否在场景树里
## }
var _enemy_records: Array[Dictionary] = []

## 掉落物记录：结构同上，另加 "item_id" / "count"
var _drop_records: Array[Dictionary] = []

## 节点 → 记录 反查表（装配/收编时避免重复登记）
var _enemy_by_node: Dictionary = {}
var _drop_by_node: Dictionary = {}

## 装配节拍
var _stream_timer: float = 0.0
var _view_dirty: bool = true
## 应用存档期间抑制装配（此时会成批装卸，逐帧流式加载反而会打架）
var _suppress: bool = false

## 本次装配的统计（只用于日志）
var _stat_loaded: int = 0
var _stat_unloaded: int = 0


# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	add_to_group("world_streamer")


func _process(delta: float) -> void:
	_stream_timer += delta
	if not _view_dirty and _stream_timer < STREAM_INTERVAL:
		return
	_stream_timer = 0.0
	_view_dirty = false
	if _suppress:
		return
	_stream()


# ============================================
# 公共接口
# ============================================

# ----------------------------------------
# 请求立刻重算一次视野（读档 / 传送 / 新生成内容之后调用）
# ----------------------------------------
func request_refresh() -> void:
	_view_dirty = true


# ----------------------------------------
# 立即装配一次（不等节拍）。测试用，也方便调试时手动触发。
# ----------------------------------------
func stream_now() -> void:
	_stream()


# ----------------------------------------
# 统计（调试 / 自动化测试用）
# ----------------------------------------
func get_stream_stats() -> Dictionary:
	return {
		"enemies_total": _enemy_records.size(),
		"enemies_loaded": _count_loaded(_enemy_records),
		"drops_total": _drop_records.size(),
		"drops_loaded": _count_loaded(_drop_records),
	}


# ----------------------------------------
# 收集敌人存档条目（与旧格式一致：position + health + path）
#
# 关键：未装配的敌人不在场景树里，扫组扫不到 —— 必须由本管理器补上，
# 否则"走远一点再存档"会把视野外的怪当成已被击杀删掉。
# ----------------------------------------
func collect_enemies() -> Array:
	_discover()
	var out: Array = []
	for rec in _enemy_records:
		var node: Node = rec["node"]
		if node == null or not is_instance_valid(node):
			continue
		if not node.has_method("get_save_data"):
			continue
		# 正在播死亡动画/下沉的个体不入档（马上 queue_free，存了等于读档复活）
		if str(node.get("_state")) == "dead":
			continue
		out.append(_enemy_save_entry(rec))
	return out


# ----------------------------------------
# 应用敌人存档：存档里有的落位回血，存档里没有的（= 已被击杀）删掉
# ----------------------------------------
func apply_enemies(list: Array) -> void:
	_suppress = true
	_discover()
	_purge_freed()

	var alive_idx: Dictionary = {}
	for entry in list:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var path: String = String(e.get("path", ""))
		if path.is_empty():
			continue
		var idx: int = _find_enemy_index(path)
		if idx < 0:
			DebugConfig.warn_msg(DebugConfig.CAT_UI,
				"[世界流式加载] 存档里的敌人找不到对应记录，跳过：%s", [path])
			continue
		alive_idx[idx] = true
		var rec: Dictionary = _enemy_records[idx]
		# 应用前先确保在树里：apply_save_data 要写 global_position，
		# 不在树里读不到（debug 下还会刷 !is_inside_tree 报错）
		if not bool(rec["loaded"]):
			_load_node(rec, "enemy")
		var node: Node = rec["node"]
		if bool(rec["loaded"]) and node != null and is_instance_valid(node) \
				and node.has_method("apply_save_data"):
			node.call("apply_save_data", e)
			if node is Node3D:
				rec["pos"] = (node as Node3D).global_position

	# 倒序删除多余记录（倒着走下标才不会串位）
	var i: int = _enemy_records.size() - 1
	while i >= 0:
		if not alive_idx.has(i):
			_free_enemy_at(i)
		i -= 1

	_reindex_enemies()
	_suppress = false
	request_refresh()


# ----------------------------------------
# 收集掉落物存档条目（item_id + count + position，与旧格式一致）
# ----------------------------------------
func collect_drops() -> Array:
	_discover()
	var out: Array = []
	for rec in _drop_records:
		var node: Node = rec["node"]
		if node == null or not is_instance_valid(node):
			continue
		# 已被捡起、正在播消失动画的不存
		if bool(node.get("_being_collected")):
			continue
		var item = node.get("item_data")
		if item == null:
			continue
		var count: int = int(node.get("count")) if bool(rec["loaded"]) else int(rec["count"])
		if count <= 0:
			continue
		var p: Vector3 = _record_position(rec)
		var entry: Dictionary = {
			"item_id": str(item.item_id),
			"count": count,
			"position": {"x": p.x, "y": p.y, "z": p.z},
		}
		# 核心掉落物：电量与温度值一起进档。
		# 节点即使被挂起（移出场景树）对象仍在，状态照取得到 ——
		# 挂起期间只是不推进，不是丢掉。
		if node.has_method("get_core_state"):
			var core_state = node.call("get_core_state")
			if core_state != null:
				entry["core"] = core_state
		out.append(entry)
	return out


# ----------------------------------------
# 应用掉落物存档：先清场（含记录），再按存档逐个重建
# ----------------------------------------
func apply_drops(list: Array) -> void:
	_suppress = true
	_discover()

	# 先清光现存掉落物：不清的话读档后会和存档里的重复一份
	var i: int = _drop_records.size() - 1
	while i >= 0:
		_free_drop_at(i)
		i -= 1

	for entry in list:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var id := StringName(String(e.get("item_id", "")))
		var count := int(e.get("count", 1))
		if id == &"" or count <= 0:
			continue
		var pos := _to_vec3(e.get("position", {}))
		var drop := ItemDrop.spawn_item_by_id(id, count, pos)
		if drop == null:
			continue
		# spawn_drop 会随机偏移一点避免重叠，读档要还原到精确坐标
		drop.global_position = pos
		# 跳过出生保护期：读档后玩家可能就站在掉落物上，
		# 不该让他干等 0.4 秒才能按空格
		drop.set("_age", 10.0)
		# 还原核心自己的状态（电量 + 温度值）
		var core_state = e.get("core")
		if core_state is Dictionary:
			drop.call("restore_core_state", core_state)

	_reindex_drops()
	_suppress = false
	request_refresh()


# ============================================
# 装配主流程
# ============================================

func _stream() -> void:
	var tree := get_tree()
	if tree == null:
		return
	# 先收编再装配：运行时新增的掉落物要先进记录，否则永远管不到
	_discover()
	# 节点被销毁（怪死 / 掉落物被捡完）的记录一并清掉
	_purge_freed()

	# 判定基准只有一个：玩家当前位置。
	# 每个单位类型各自的装载/卸载半径在 ViewFrustum 里（唯一的调参入口）。
	var ppos: Vector3 = ViewFrustum.player_position(tree)

	_stat_loaded = 0
	_stat_unloaded = 0
	_stat_loaded += _stream_enemies(ppos)
	_stat_loaded += _stream_drops(ppos)
	_log_stats()


# ----------------------------------------
# 敌人装配
#
# 装载：距离 <= 装载半径；卸载：距离 > 装载 + 滞回半径。
# 中间那段是滞回带 —— 已装载的留着、挂起的不补，玩家在边界微动不会抖。
# ----------------------------------------
func _stream_enemies(player_pos: Vector3) -> int:
	if _enemy_records.is_empty():
		return 0
	var load_r: float = ViewFrustum.load_radius("enemy")
	var keep_r: float = ViewFrustum.unload_radius("enemy")
	var loaded: int = 0
	for rec in _enemy_records:
		var node: Node = rec["node"]
		if node == null or not is_instance_valid(node):
			continue
		var is_loaded: bool = bool(rec["loaded"])
		var p: Vector3 = _record_position(rec)
		var d: float = _flat_dist(p, player_pos)

		if d <= load_r:
			if not is_loaded and _load_node(rec, "enemy"):
				loaded += 1
			continue
		if not is_loaded:
			continue
		if d <= keep_r:
			# 滞回带内：保持现状，不卸载
			continue

		# 超出卸载半径 → 挂起。死亡中的个体不碰：它自己会 queue_free
		if str(node.get("_state")) == "dead":
			continue
		_unload_node(rec, "enemy")
		_stat_unloaded += 1
	return loaded


# ----------------------------------------
# 掉落物装配
# ----------------------------------------
func _stream_drops(player_pos: Vector3) -> int:
	if _drop_records.is_empty():
		return 0
	var load_r: float = ViewFrustum.load_radius("drop")
	var keep_r: float = ViewFrustum.unload_radius("drop")
	var loaded: int = 0
	for rec in _drop_records:
		var node: Node = rec["node"]
		if node == null or not is_instance_valid(node):
			continue
		var is_loaded: bool = bool(rec["loaded"])
		var p: Vector3 = _record_position(rec)
		var d: float = _flat_dist(p, player_pos)

		if d <= load_r:
			if is_loaded or loaded >= MAX_DROPS_PER_PASS:
				continue
			if _load_node(rec, "drop"):
				loaded += 1
			continue
		if not is_loaded:
			continue
		if d <= keep_r:
			# 滞回带内：保持现状，不卸载
			continue

		# 正在被拾取 / 玩家就在旁边：不卸载
		if bool(node.get("_being_collected")):
			continue
		if node.get("_nearby_player") != null:
			continue
		_unload_node(rec, "drop")
		_stat_unloaded += 1
	return loaded


# ============================================
# 记录登记与装配
# ============================================

# ----------------------------------------
# 收编：把场景里还没登记的敌人 / 掉落物补进记录
# 每次都扫一遍组也不贵（敌人几只、掉落物通常几十个），
# 好处是运行时新增的掉落物（怪死掉落）不需要任何额外通知机制。
# ----------------------------------------
func _discover() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group("enemy"):
		if n == null or not is_instance_valid(n) or _enemy_by_node.has(n):
			continue
		_register_enemy(n)
	for d in tree.get_nodes_in_group("item_drop"):
		if d == null or not is_instance_valid(d) or _drop_by_node.has(d):
			continue
		_register_drop(d)


func _register_enemy(n: Node) -> void:
	var rec: Dictionary = {
		"node": n,
		"parent": n.get_parent(),
		"path": _path_of(n),
		"pos": _node_position(n),
		"loaded": true,
	}
	_enemy_records.append(rec)
	_enemy_by_node[n] = rec


func _register_drop(n: Node) -> void:
	var item = n.get("item_data")
	var item_id := StringName("")
	if item != null:
		item_id = StringName(str(item.item_id))
	var c = n.get("count")
	var count: int = 0
	if c != null:
		count = int(c)
	var rec: Dictionary = {
		"node": n,
		"parent": n.get_parent(),
		"path": "",
		"pos": _node_position(n),
		"loaded": true,
		"item_id": item_id,
		"count": count,
	}
	_drop_records.append(rec)
	_drop_by_node[n] = rec


# ----------------------------------------
# 清理"节点已销毁"的记录
#
# 敌人节点销毁 = 这只怪死了（_die 里 queue_free）；
# 掉落物节点销毁 = 被捡光了。
# 两者都是"永久消失"，记录要跟着走，否则存档会把死怪写回去。
# ----------------------------------------
func _purge_freed() -> void:
	var enemies_changed: bool = false
	var i: int = _enemy_records.size() - 1
	while i >= 0:
		var rec: Dictionary = _enemy_records[i]
		var node = rec.get("node")
		if node == null or not is_instance_valid(node):
			_enemy_records.remove_at(i)
			enemies_changed = true
		i -= 1
	if enemies_changed:
		_reindex_enemies()

	var drops_changed: bool = false
	i = _drop_records.size() - 1
	while i >= 0:
		var drec: Dictionary = _drop_records[i]
		var dnode = drec.get("node")
		if dnode == null or not is_instance_valid(dnode):
			_drop_records.remove_at(i)
			drops_changed = true
		i -= 1
	if drops_changed:
		_reindex_drops()


# ----------------------------------------
# 装配一个记录（放回场景树）
#
# 顺序要点：先 add_child 再写 global_position ——
# 不在树里时 global_position 读不到（debug 下还会刷 !is_inside_tree 报错）。
# 与 Building.spawn / ResourcePool.acquire 是同一套模板。
# ----------------------------------------
func _load_node(rec: Dictionary, kind: String) -> bool:
	var node: Node = rec["node"]
	if node == null or not is_instance_valid(node):
		return false
	if bool(rec["loaded"]):
		return false

	var parent: Node = rec["parent"]
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		parent = _fallback_parent()
	if parent == null:
		return false

	parent.add_child(node)
	# 显式补一次分组：非持久分组与"是否在树内"绑定，重新入树时引擎一般会自己
	# 恢复，但这里不赌 —— 分组缺了不影响本管理器（记录仍持有节点），
	# 却会让任何"扫组"的老逻辑（存档兜底、地图敌人放置）找不到它。
	node.add_to_group("enemy" if kind == "enemy" else "item_drop")
	if node is Node3D:
		(node as Node3D).global_position = rec["pos"]
	rec["loaded"] = true
	var p: Vector3 = rec["pos"]
	DebugConfig.log_msg(DebugConfig.CAT_STREAM, "[世界流式加载] 装入 %s @ (%.1f, %.1f)",
		[kind, p.x, p.z])
	return true


# ----------------------------------------
# 挂起一个记录（移出场景树，节点保留）
# ----------------------------------------
func _unload_node(rec: Dictionary, kind: String) -> void:
	var node: Node = rec["node"]
	if node == null or not is_instance_valid(node):
		return
	if not bool(rec["loaded"]):
		return

	# 位置（和掉落物数量）先回写记录：节点一出树 global_position 就不可读了
	_sync_rec_from_node(rec, kind)

	var parent: Node = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	rec["loaded"] = false
	var up: Vector3 = rec["pos"]
	DebugConfig.log_msg(DebugConfig.CAT_STREAM, "[世界流式加载] 挂起 %s @ (%.1f, %.1f)",
		[kind, up.x, up.z])


# ----------------------------------------
# 从节点把"会变的量"同步回记录
# ----------------------------------------
func _sync_rec_from_node(rec: Dictionary, kind: String) -> void:
	var node: Node = rec["node"]
	if node == null or not is_instance_valid(node):
		return
	rec["pos"] = _node_position(node)
	if kind == "drop":
		var c = node.get("count")
		if c != null:
			rec["count"] = int(c)
		var item = node.get("item_data")
		if item != null:
			rec["item_id"] = StringName(str(item.item_id))


# ----------------------------------------
# 释放一条敌人记录（节点销毁 + 记录移除）
# ----------------------------------------
func _free_enemy_at(idx: int) -> void:
	if idx < 0 or idx >= _enemy_records.size():
		return
	var rec: Dictionary = _enemy_records[idx]
	_destroy_node(rec)
	_enemy_records.remove_at(idx)


func _free_drop_at(idx: int) -> void:
	if idx < 0 or idx >= _drop_records.size():
		return
	var rec: Dictionary = _drop_records[idx]
	_destroy_node(rec)
	_drop_records.remove_at(idx)


# remove_child + 销毁一起用：只 queue_free 的话节点会留到帧末，
# 期间仍可能被玩家的攻击判定或敌人的攻击"打到尸体"
func _destroy_node(rec: Dictionary) -> void:
	var node = rec.get("node")
	if node == null or not is_instance_valid(node):
		return
	var parent: Node = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	if node.is_inside_tree():
		node.queue_free()
	else:
		# 已被挂起（不在树里）的节点直接 free：queue_free 的"树内"路径不可靠
		node.free()


# ============================================
# 辅助
# ============================================

# ----------------------------------------
# 记录当前世界坐标：在树里（已装配）取节点实时值，挂起时用记录里的缓存
# ----------------------------------------
func _record_position(rec: Dictionary) -> Vector3:
	if bool(rec["loaded"]):
		var node: Node = rec["node"]
		if node is Node3D:
			return (node as Node3D).global_position
	return rec["pos"]


func _node_position(n: Node) -> Vector3:
	if n is Node3D and n.is_inside_tree():
		return (n as Node3D).global_position
	return Vector3.ZERO


# ----------------------------------------
# 相对当前场景的节点路径（存档键，沿用旧格式）
# ----------------------------------------
func _path_of(n: Node) -> String:
	var tree := get_tree()
	if tree == null:
		return ""
	var scene := tree.current_scene
	if scene == null or not n.is_inside_tree():
		return ""
	return String(scene.get_path_to(n))


func _find_enemy_index(path: String) -> int:
	for i in _enemy_records.size():
		if String(_enemy_records[i]["path"]) == path:
			return i
	return -1


# ----------------------------------------
# 未装配敌人：不能调 get_save_data()（它读 global_position，
# 节点不在树里会报错并返回原点），改由记录 + 节点变量拼出同结构条目。
# Slime / Drone 的 get_save_data() 都是 position + health，
# 结构一致；将来新增敌人类型时这里要跟着看一眼。
# ----------------------------------------
func _enemy_save_entry(rec: Dictionary) -> Dictionary:
	var node: Node = rec["node"]
	if bool(rec["loaded"]):
		var entry: Dictionary = node.call("get_save_data")
		entry["path"] = String(rec["path"])
		return entry
	var p: Vector3 = rec["pos"]
	var hp = node.get("_current_health")
	var health: int = 1
	if hp != null:
		health = int(hp)
	return {
		"position": {"x": p.x, "y": p.y, "z": p.z},
		"health": health,
		"path": String(rec["path"]),
	}


func _fallback_parent() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if tree.current_scene != null:
		return tree.current_scene
	return tree.root


func _count_loaded(records: Array) -> int:
	var n: int = 0
	for rec in records:
		if bool(rec["loaded"]):
			n += 1
	return n


func _reindex_enemies() -> void:
	_enemy_by_node.clear()
	for rec in _enemy_records:
		var node = rec.get("node")
		if node != null and is_instance_valid(node):
			_enemy_by_node[node] = rec


func _reindex_drops() -> void:
	_drop_by_node.clear()
	for rec in _drop_records:
		var node = rec.get("node")
		if node != null and is_instance_valid(node):
			_drop_by_node[node] = rec


# 水平距离的算法只有一份，在 ViewFrustum（资源那边用的是同一个函数），
# 免得将来改了度量方式（比如改成圆形/球形）只有一边跟着变。
func _flat_dist(a: Vector3, b: Vector3) -> float:
	return ViewFrustum.flat_distance(a, b)


func _to_vec3(dict: Dictionary) -> Vector3:
	return Vector3(
		float(dict.get("x", 0.0)),
		float(dict.get("y", 0.0)),
		float(dict.get("z", 0.0)))


func _log_stats() -> void:
	if _stat_loaded == 0 and _stat_unloaded == 0:
		return
	var stats := get_stream_stats()
	DebugConfig.log_msg(DebugConfig.CAT_STREAM,
		"[世界流式加载] 装入 %d / 挂起 %d；敌人 %d/%d，掉落物 %d/%d 在场上",
		[_stat_loaded, _stat_unloaded,
		stats["enemies_loaded"], stats["enemies_total"],
		stats["drops_loaded"], stats["drops_total"]])
