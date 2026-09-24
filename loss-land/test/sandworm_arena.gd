# test/sandworm_arena.gd
# ============================================
# 沙虫测试场地（调试用，不进正式游戏）
#
# 为什么单开一个场景，而不是把沙虫塞进 map.tscn 测：
#   1. map.tscn 每次要跑 12~20 秒的地图生成，改一次数值等一次生成太慢；
#   2. map_generator_3d._place_enemies() 会把组 "enemy" 的节点**全搬到丛林区**，
#      Boss 混在正式地图里会被到处掉包，测不准（这也是 Boss 另立 "boss" 组的理由）；
#   3. 正式地图上的巢穴位置/沙地战场还没做（规格第 4 步）。
#
# 场景内容：一块平地 + 玩家 + 巢穴标记 + 触发圈/脱战圈 + 状态调试面板。
# 触发圈/脱战圈的**半径不是写死的**：运行时按沙虫 @export 的
# trigger_radius / leash_radius 现建环形，改数值圈子跟着变，不会对不上。
#
# 运行方式：在编辑器里打开本场景，按 F6（**不要**按 F5，F5 进的是正式地图）。
#
# 按键：
#   T  把玩家挪到触发圈内  → 停留 trigger_dwell 后沙虫钻出
#   H  把玩家挪到脱战圈外  → 持续 leash_time 后沙虫回巢回满血
#   K  打死玩家            → 沙虫应**立刻**回巢回满血（不许守尸）
#   W  直接唤起沙虫（跳过"靠近停留"，方便反复测招式）
#   1  沙虫血量降到 60%    → 下一决策点仍用表 1
#   2  沙虫血量降到 40%    → **下一决策点**才切表 2（招式播到一半不切）
#   9  把沙虫打到 1 血     → 濒死逃走 → 巢穴坍塌（世界旗标置 1）
#   R  重置：清世界旗标 + 重生成沙虫
# ============================================

extends Node3D

## 用哪个场景当沙虫（留空则加载 res://tscn/prefab/boss/sandworm.tscn）
@export var boss_scene: PackedScene

@export_group("场地")
@export var trigger_ring_color: Color = Color(1.0, 0.85, 0.2)
@export var leash_ring_color: Color = Color(1.0, 0.32, 0.18)
## 玩家被挪动时统一落到这个高度（让重力把他放回地面）
@export var drop_height: float = 1.5

@export_group("调试")
## 让沙虫把自己的状态迁移打进日志（每秒一行 + 每次迁移一行）
@export var boss_log: bool = true

const DEFAULT_BOSS_SCENE := "res://tscn/prefab/boss/sandworm.tscn"

var _boss: BossBase = null
var _label: Label = null
var _nest: Node3D = null
var _last_message: String = ""


func _ready() -> void:
	_label = get_node_or_null("DebugLayer/DebugPanel/DebugText") as Label
	_nest = get_node_or_null("Nest") as Node3D
	_spawn_boss()
	_build_rings()
	_note("场地就绪：T 靠近巢穴 / H 拖远 / K 自杀 / W 唤起 / 1・2 改血量 / 9 打到 1 血 / R 重置")


func _process(_delta: float) -> void:
	if _label == null:
		return
	_label.text = "\n".join(_panel_lines())


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key: InputEventKey = event as InputEventKey
	if not key.pressed or key.echo:
		return
	var code: int = key.physical_keycode
	if code == 0:
		code = key.keycode
	match code:
		KEY_T:
			_move_player_near(true)
		KEY_H:
			_move_player_near(false)
		KEY_K:
			_kill_player()
		KEY_W:
			_wake_boss()
		KEY_1:
			_damage_boss_to_ratio(0.6)
		KEY_2:
			_damage_boss_to_ratio(0.4)
		KEY_9:
			_damage_boss_to_blood_1()
		KEY_R:
			_reset_all()
		_:
			pass

# ============================================
# 沙虫
# ============================================

func _spawn_boss() -> void:
	if _boss != null and is_instance_valid(_boss):
		_boss.queue_free()
		_boss = null

	var packed: PackedScene = boss_scene
	if packed == null:
		packed = load(DEFAULT_BOSS_SCENE) as PackedScene
	if packed == null:
		_note("错误：找不到沙虫场景")
		return

	var instance: Node = packed.instantiate()
	_boss = instance as BossBase
	if _boss == null:
		_note("错误：沙虫场景的根节点不是 BossBase")
		if instance != null:
			instance.free()
		return

	add_child(_boss)
	var spawn: Node3D = get_node_or_null("Nest/Spawn") as Node3D
	if spawn != null:
		_boss.global_position = spawn.global_position
	# ⚠ _ready 抓的"巢穴坐标"是**入树那一刻**的坐标（此时还在原点），
	#   所以落位后必须重新告诉它 —— 否则脱战后它会往原点跑
	_boss.set_home_position(_boss.global_position)
	_boss.debug_enabled = boss_log


func _wake_boss() -> void:
	if _boss == null or not is_instance_valid(_boss):
		_note("还没有沙虫，按 R 重置")
		return
	_boss.debug_wake()
	_note("已唤起沙虫（跳过靠近停留）")


func _damage_boss_to_ratio(ratio: float) -> void:
	if _boss == null or not is_instance_valid(_boss):
		_note("还没有沙虫")
		return
	var target: int = int(float(_boss.get_max_health()) * ratio)
	_boss.debug_damage_to(target)
	_note("沙虫血量 → %d / %d（%.0f%%）" % [_boss.get_health(), _boss.get_max_health(), ratio * 100.0])


func _damage_boss_to_blood_1() -> void:
	if _boss == null or not is_instance_valid(_boss):
		_note("还没有沙虫")
		return
	# 打到 0 → take_damage 内部夹到 1 → 进 FALLEN（走的就是正式那条路）
	_boss.debug_damage_to(0)
	_note("沙虫血量 → %d（应进入濒死逃走）" % _boss.get_health())

# ============================================
# 玩家
# ============================================

## near = true 挪到触发圈内；false 挪到脱战圈外
func _move_player_near(near: bool) -> void:
	if _boss == null or not is_instance_valid(_boss):
		_note("还没有沙虫")
		return
	var body: Node3D = _find_player_body()
	if body == null:
		_note("找不到玩家")
		return
	var radius: float = _boss.trigger_radius * 0.5
	if not near:
		radius = _boss.leash_radius + 8.0
	var nest_position: Vector3 = _boss.home_position()
	body.global_position = Vector3(nest_position.x + radius, drop_height, nest_position.z)
	if near:
		_note("玩家 → 距巢穴 %.1f m（触发圈 %.1f m 内，等 %.1f s 沙虫登场）"
			% [radius, _boss.trigger_radius, _boss.trigger_dwell])
	else:
		_note("玩家 → 距巢穴 %.1f m（脱战圈 %.1f m 外，等 %.1f s 沙虫回巢）"
			% [radius, _boss.leash_radius, _boss.leash_time])


func _kill_player() -> void:
	var body: Node3D = _find_player_body()
	if body == null or not body.has_method("take_damage"):
		_note("找不到玩家本体")
		return
	body.call("take_damage", 999999)
	_note("玩家已死亡 → 沙虫应**立刻**回巢回满血（这条不接就是守尸）")


func _find_player_body() -> Node3D:
	var root: Node = get_tree().get_first_node_in_group("player")
	if root == null:
		return null
	# 真正会移动的是 player 的 Physics 子节点，根节点永不位移
	var body: Node = root.get_node_or_null("Physics")
	if body is Node3D:
		return body as Node3D
	return root as Node3D

# ============================================
# 场地
# ============================================

func _reset_all() -> void:
	# 静态旗标跨场景存活，不主动清会把"上一局巢穴已坍塌"带进来
	WorldState.reset()
	_spawn_boss()
	_build_rings()
	_note("已重置：世界旗标清空、沙虫重生")


## 触发圈 / 脱战圈：半径**从沙虫的 @export 现取**，改数值圈子立刻跟着变
func _build_rings() -> void:
	if _nest == null or _boss == null:
		return
	for child in _nest.get_children():
		if child is MeshInstance3D and (child.name == "TriggerRing" or child.name == "LeashRing"):
			child.queue_free()
	_make_ring(_boss.trigger_radius, trigger_ring_color, "TriggerRing")
	_make_ring(_boss.leash_radius, leash_ring_color, "LeashRing")


func _make_ring(radius: float, color: Color, ring_name: String) -> void:
	# TorusMesh 的环心半径 = (inner + outer) / 2，管粗 = (outer - inner) / 2
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = maxf(radius - 0.15, 0.05)
	torus.outer_radius = radius + 0.15
	var ring: MeshInstance3D = MeshInstance3D.new()
	ring.name = ring_name
	ring.mesh = torus
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	# 不参与光照，纯标记线
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = material
	ring.position = Vector3(0.0, 0.06, 0.0)
	_nest.add_child(ring)

# ============================================
# 调试面板
# ============================================

func _panel_lines() -> Array[String]:
	var lines: Array[String] = []
	lines.append("=== 沙虫测试场地 ===")

	if _boss == null or not is_instance_valid(_boss):
		lines.append("沙虫：未生成（按 R 重置）")
	else:
		lines.append("沙虫 " + _boss.debug_line())
		lines.append("触发 %.1f m / 停留 %.1f s      脱战 %.1f m / %.1f s" % [
			_boss.trigger_radius, _boss.trigger_dwell,
			_boss.leash_radius, _boss.leash_time,
		])
		var table_label: String = "表1（血厚）"
		if _boss.get_health() * 2 <= _boss.get_max_health():
			table_label = "表2（血少）"
		var nest_label: String = "完好"
		if WorldState.get_flag(Sandworm.NEST_FLAG, 0) == 1:
			nest_label = "已坍塌"
		lines.append("当前相位 %s      巢穴 %s" % [table_label, nest_label])

	lines.append("玩家 " + _player_line())
	lines.append("T 靠近巢穴 / H 拖远 / K 自杀 / W 唤起 / 1・2 改血量 / 9 打到 1 血 / R 重置")
	lines.append(_last_message)
	return lines


func _player_line() -> String:
	var body: Node3D = _find_player_body()
	if body == null:
		return "未找到（player 组）"
	var raw: Variant = body.get("current_health")
	var maximum: Variant = body.get("max_health")
	if raw == null or maximum == null:
		return "位置 (%.1f, %.1f)" % [body.global_position.x, body.global_position.z]
	var alive: String = "存活"
	if body.has_method("is_alive") and not bool(body.call("is_alive")):
		alive = "死亡"
	return "HP %d / %d（%s）  距巢穴 %.1f m" % [
		int(raw), int(maximum), alive,
		_flat_distance(body.global_position, _boss.home_position()) if _boss != null else 0.0,
	]


func _flat_distance(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


func _note(message: String) -> void:
	_last_message = message
	print("[沙虫测试场地] " + message)
