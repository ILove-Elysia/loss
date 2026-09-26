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
# 场景内容：一块平地 + 玩家 + 巢穴标记 + 触发圈/领地圈 + 状态调试面板。
# 两个圈的**半径都不是写死的**：运行时按沙虫 @export 的
# trigger_radius / leash_radius 现建环形，改数值圈子跟着变，不会对不上。
# 地面大小同样不写死：半边长 = leash_radius + extra_runway。
#
# ⚠ 两个圈**同心**，圆心都是巢穴：
#     触发圈（trigger_radius）＝ 玩家进圈并停留 trigger_dwell → 沙虫钻出；
#     领地圈（leash_radius）  ＝ 玩家出圈并持续 leash_time → 沙虫回巢回满血。
#   领地判定的基准是「玩家↔巢穴」，**不是「玩家↔沙虫」**（BossSandwormBase._check_leash）。
#   2026-09-25 之前量的是玩家↔沙虫，而脱战要求"拉开 leash_radius 的差距"，
#   速度差却只有 1 m/s（玩家 5.0 vs 沙虫 4.0；低电时沙虫还更快）⇒ 得笔直跑
#   30 秒以上，"逃不掉"就是这么来的。改成量巢穴距离后与速度差无关，跑十来米就脱身。
#   另外沙虫在追击/出招期间会被 `_clamped_move_dir()` 拴在领地圈里（回家路径不受限），
#   它会追到圈边就停住并横向跟随 —— 你站在圈外能直接看到"它守在那儿"。
#
# 运行方式：在编辑器里打开本场景，按 F6（**不要**按 F5，F5 进的是正式地图）。
#
# 按键：
#   T  把玩家挪到触发圈内  → 停留 trigger_dwell 后沙虫钻出
#   H  把玩家挪到领地圈外  → 持续 leash_time 后沙虫回巢回满血
#   K  打死玩家            → 沙虫应**立刻**回巢回满血（不许守尸）
#   G  直接唤起沙虫（跳过"靠近停留"，方便反复测招式）
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
## 领地圈之外还要留多少米跑道（地面半边长 = leash_radius + 本值）。
## 脱战改成量「玩家↔巢穴」之后就不需要长跑道了：出圈 24 m + 十几米余量足够看清
## "沙虫停在圈边"这件事，所以从 150 收到 60（场地 168×168，不再是一望无际）。
@export var extra_runway: float = 60.0

@export_group("调试")
## 让沙虫把自己的状态迁移打进日志（每秒一行 + 每次迁移一行）
@export var boss_log: bool = true

const DEFAULT_BOSS_SCENE := "res://tscn/prefab/boss/sandworm.tscn"
## 地形配色的**唯一来源**（地图也用这张表）—— 场地不另抄一份色号，免得地图改了场地不变
const TERRAIN_TINTS := preload("res://script/map/task_system.gd")
## 地面铺"沙地"(13) 的瓦片色：场地是沙地战场。注意**地形号仍报草原 10**，
## 那是给玩家的体温/湿度系统看的（理由见 test/arena_flat_map_gen.gd），两者不冲突
const GROUND_TERRAIN := 13

var _boss: BossSandwormBase = null
var _label: Label = null
var _nest: Node3D = null
var _leash_ring: MeshInstance3D = null
var _last_message: String = ""


func _ready() -> void:
	_label = get_node_or_null("DebugLayer/DebugPanel/DebugText") as Label
	_nest = get_node_or_null("Nest") as Node3D
	_spawn_boss()
	_fit_ground()
	_ensure_unshaded_materials()
	_build_rings()
	_note("场地就绪：T 靠近巢穴 / H 拖远 / K 自杀 / G 唤起 / 1・2 改血量 / 9 打到 1 血 / R 重置")


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
		KEY_G:
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
	_boss = instance as BossSandwormBase
	if _boss == null:
		_note("错误：沙虫场景的根节点不是 BossSandwormBase")
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

## near = true 挪到触发圈内；false 挪到领地圈外。
## 两个圈的圆心**都是巢穴**，所以只需要换半径、不用换锚点。
func _move_player_near(near: bool) -> void:
	if _boss == null or not is_instance_valid(_boss):
		_note("还没有沙虫")
		return
	var body: Node3D = _find_player_body()
	if body == null:
		_note("找不到玩家")
		return
	var anchor: Vector3 = _boss.home_position()
	var radius: float = _boss.trigger_radius * 0.5
	if not near:
		# 领地判定量的就是「玩家↔巢穴」，所以出圈以**巢穴**为基准。
		# 余量 12 m：稳稳出圈，又不会一按就贴到墙上（地面半边长 = 领地 + 60）。
		radius = _boss.leash_radius + 12.0
	body.global_position = Vector3(anchor.x + radius, drop_height, anchor.z)
	if near:
		_note("玩家 → 距巢穴 %.1f m（触发圈 %.1f m 内，等 %.1f s 沙虫登场）"
			% [radius, _boss.trigger_radius, _boss.trigger_dwell])
	else:
		_note("玩家 → 距巢穴 %.1f m（领地圈 %.1f m 外，站住别动，等 %.1f s 沙虫回巢）"
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
	_fit_ground()
	_ensure_unshaded_materials()
	_build_rings()
	_note("已重置：世界旗标清空、沙虫重生、场地按当前数值重铺")


## 地面半边长 = 领地圈 + 跑道（有下限 45 m，免得数值调小了场地变成一块豆腐干）
func _ground_half_extent() -> float:
	var leash: float = 24.0
	if _boss != null and is_instance_valid(_boss):
		leash = _boss.leash_radius
	return maxf(leash + extra_runway, 45.0)


## 按当前数值把地面（Mesh + 碰撞盒）铺开，顶面仍保持 y=0。
## 只改尺寸不动逻辑：碰撞层还是 layer2 / mask0，点击寻路也不受影响。
func _fit_ground() -> void:
	var ground: Node3D = get_node_or_null("Ground") as Node3D
	if ground == null:
		return
	var side: float = _ground_half_extent() * 2.0
	var dims: Vector3 = Vector3(side, 1.0, side)
	var offset: Vector3 = Vector3(0.0, -0.5, 0.0)
	var mesh_node: MeshInstance3D = ground.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_node != null:
		var box: BoxMesh = mesh_node.mesh as BoxMesh
		if box != null:
			# 复制一份再改：.tscn 里的 SubResource 是场景共享的，直接改会污染编辑器里的值
			var box_copy: BoxMesh = box.duplicate() as BoxMesh
			box_copy.size = dims
			mesh_node.mesh = box_copy
		mesh_node.position = offset
	var shape_node: CollisionShape3D = ground.get_node_or_null("Shape") as CollisionShape3D
	if shape_node != null:
		var box_shape: BoxShape3D = shape_node.shape as BoxShape3D
		if box_shape != null:
			var shape_copy: BoxShape3D = box_shape.duplicate() as BoxShape3D
			shape_copy.size = dims
			shape_node.shape = shape_copy
		shape_node.position = offset


## 场地外观归一化。两件事：
##
## ① 地面 / 巢穴土堆的材质改成 UNSHADED —— 本工程的环境光是 ambient_light_color(0.83)
##    × energy(9.0)（map.tscn），受光面被整体抬亮约 2.2 倍 ⇒ **albedo 亮过 0.45 的
##    直接打爆成纯白**。原先的沙色地面 (0.78,0.68,0.46) 和沙虫体色都在这个区间：
##    地面和沙虫一起变白糊成一片，连"前摇变红 / 濒死变灰"这些状态信号也一起白掉
##    （2026-09-26 用户反馈"沙虫经常会变成白色看不清"；渲染取证实测两处像素都是 #ffffff）。
##    真地图里地形 / 海面一律 UNSHADED（map_generator_3d.gd）—— 场地必须跟它一致，
##    否则在场地里看到的画面跟实机不是一回事，测了个寂寞。
##
## ② 地面换成地图"沙地"瓦片色：色号**与 task_system.TERRAIN_COLOR_MAP 同源**，
##    不另抄一份。场地的地形号仍报草原(10)，那是给玩家的体温/湿度系统看的
##    （理由见 test/arena_flat_map_gen.gd），两者不冲突。
##
## ⚠ 为什么写在脚本里而不是只写进 .tscn：本场景的标签页在编辑器里开着，外部改 .tscn
##   会被编辑器用内存里的版本重新落盘覆盖（本工程已踩过 3 次）。运行时强制就绕开了，
##   .tscn 里那两个材质只是"在编辑器里看着对"。
func _ensure_unshaded_materials() -> void:
	_paint_material("Ground/Mesh", TERRAIN_TINTS.TERRAIN_COLOR_MAP[GROUND_TERRAIN])
	_paint_material("Nest/NestMound", null)


## color 传 null = 保留 .tscn 里配的固有色，只改着色方式
func _paint_material(path: String, color: Variant) -> void:
	var mesh_node: MeshInstance3D = get_node_or_null(path) as MeshInstance3D
	if mesh_node == null:
		return
	var mat: BaseMaterial3D = null
	var src: BaseMaterial3D = mesh_node.material_override as BaseMaterial3D
	if src != null:
		# 复制再改：与 _fit_ground() 同理，.tscn 里的 SubResource 是场景共享的
		mat = src.duplicate() as BaseMaterial3D
	else:
		mat = StandardMaterial3D.new()
	if color is Color:
		mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_node.material_override = mat


## 玩家（Physics 子节点）到巢穴的平面距离 —— **这就是领地（脱战）判据**
func _player_distance_to_nest() -> float:
	if _boss == null:
		return 0.0
	var body: Node3D = _find_player_body()
	if body == null:
		return 0.0
	return _flat_distance(body.global_position, _boss.home_position())


## 玩家↔沙虫的平面距离（判断招式够不够得着用，**不是**脱战判据）
func _player_distance_to_boss() -> float:
	if _boss == null or not is_instance_valid(_boss):
		return 0.0
	var body: Node3D = _find_player_body()
	if body == null:
		return 0.0
	return _flat_distance(body.global_position, _boss.global_position)


## 触发圈 / 领地圈：半径**从沙虫的 @export 现取**，改数值圈子立刻跟着变。
## 两个圈的圆心**都是巢穴**：触发是"靠近巢穴"，脱战是"离开领地"，基准同一个点，
## 于是场上一对同心圆 —— 玩家站在哪一层，一眼就看得出。
func _build_rings() -> void:
	if _nest == null or _boss == null:
		return
	for child in _nest.get_children():
		if child is MeshInstance3D and (child.name == "TriggerRing" or child.name == "LeashRing"):
			child.queue_free()
	var trigger_ring: MeshInstance3D = _make_ring(_boss.trigger_radius, trigger_ring_color, "TriggerRing")
	_nest.add_child(trigger_ring)
	_leash_ring = _make_ring(_boss.leash_radius, leash_ring_color, "LeashRing")
	_nest.add_child(_leash_ring)


## 造环但**不入树**：由调用方决定挂给谁（当前两个圈都挂巢穴，见 _build_rings）
func _make_ring(radius: float, color: Color, ring_name: String) -> MeshInstance3D:
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
	return ring

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
		lines.append("触发 %.1f m / 停留 %.1f s      领地 %.1f m / 停留 %.1f s" % [
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
		var to_home: float = _player_distance_to_nest()
		lines.append("★玩家↔巢穴 %.1f m（领地 %.1f m，%s）—— 脱战判定量的是这一段" % [
			to_home,
			_boss.leash_radius,
			"已出领地" if to_home > _boss.leash_radius else "领地内",
		])
		lines.append("场地半边长 %.0f m      玩家↔沙虫 %.1f m（仅供参考）" % [
			_ground_half_extent(),
			_player_distance_to_boss(),
		])

	lines.append("玩家 " + _player_line())
	lines.append("T 靠近巢穴 / H 拖远 / K 自杀 / G 唤起 / 1・2 改血量 / 9 打到 1 血 / R 重置")
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
		_player_distance_to_nest(),
	]


func _flat_distance(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


func _note(message: String) -> void:
	_last_message = message
	print("[沙虫测试场地] " + message)
