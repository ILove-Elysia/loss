# script/ai/enemy/mob/drone/drone.gd
# ============================================
# 小型无人机敌人（远程弹幕型）
#
# 大纲 3.7.2 设定：
#   生命值 20、攻击力 5/发、移速 1.5
#   攻击范围 5-8 米、攻击间隔 2 秒、弹速 4
#   掉落：电池（20%）
#   出没：矿区、地下遗迹
#
# 行为（悬空单位，不走寻路——直接飞）：
#   idle   悬停漂移，玩家进入 14 米仇恨范围 → engage
#   engage 与玩家保持 3-8 米（太近后撤、太远逼近、缓慢横移）
#          距离 ≤ 8 米且冷却结束 → 发射弹幕
#   hurt   受击闪白 0.15 秒
#   dead   掉落判定 → 缩小消失
#
# 出生态：场景里给的位置只是"期望位置"，
#   _ready 时会锚定到矿区（Rocky）任务入口附近最近的陆地。
#
# 碰撞设定（2026-09-12 用户定）：
#   无人机【没有碰撞体积】——玩家和史莱姆都能从它身上穿过去，
#   它自己飞行时也不被地形/建筑阻挡（高度由 _hover() 直接控制）。
#   但它可以被地面玩家靠近攻击：判定靠 Hitbox 这个 Area3D
#   （Area 不产生物理阻挡，仍能被玩家攻击的形状查询命中），
#   悬停高度也压到了 1.5 米，落在玩家挥砍范围内。
#   受击盒半径 0.35 = 机身最粗处 —— 别调大，用户反馈过"受击范围过大"。
#
# 弹幕（2026-09-14 用户定）：
#   **平行地面平射** —— 枪口压到玩家躯干高度（fire_height）后水平射出，
#   命中玩家 / 撞上地形 / 飞满 projectile_max_distance 米 三种情况就消失。
# ============================================

class_name Drone
extends CharacterBody3D

# ============================================
# 导出变量
# ============================================

## 最大生命值
@export var max_health: int = 20

## 移动速度（米/秒）
@export var move_speed: float = 1.5

## 仇恨范围（米）
@export var hate_range: float = 14.0

## 期望交战距离区间（米）：太近后撤、太远逼近
##
## combat_min 原值 5.0：玩家速度 5、无人机只有 1.5，虽然理论追得上，
## 但它从 5 米就开始退，玩家要一路小跑才能摸到，实际手感是"永远追着打"。
## 降到 3.0（仍大于玩家 2 米的攻击距离）后，冲脸一次就能砍中。
@export var combat_min: float = 3.0
@export var combat_max: float = 8.0

## 攻击间隔（秒）
@export var attack_interval: float = 2.0

## 每发伤害
@export var attack_damage: int = 5

## 弹幕速度
@export var projectile_speed: float = 4.0

## 弹幕最大飞行距离（米）：打空的弹幕飞满这段距离就消失
@export var projectile_max_distance: float = 12.0

## 弹幕平飞高度（米，相对玩家脚下）
##
## 用户要求弹幕**平行地面**射出（不再带下坠打向玩家），而平射的弹道
## 高度就等于枪口高度 —— 所以枪口必须压到玩家身上：
## 玩家的碰撞体只有 1.0 米高（player.tscn 的圆柱），无人机却悬停在 1.5 米，
## 若从机体高度平射，弹幕会正好从玩家头顶平着飞过去。
## 取 0.9：弹幕的碰撞球（半径 0.3）覆盖 y∈[0.6, 1.2]，与玩家躯干
## [0, 1.0] 有 0.4 米的实打实重叠（够稳），同时离机体下沿（1.325）只差
## 0.4 米，看起来不像是从地底下钻出来的。
## 上限：不能再高于 1.2（球底 0.9 与玩家头顶 1.0 只剩 0.1 米，会漏判）。
@export var fire_height: float = 0.9

## 受击盒半径（米）：玩家挥砍的形状查询能打到这个球的范围。
##
## 原值 0.55 是照着旋翼盘半径定的，比实体机身（底部半径 0.35）大一圈，
## 实际手感是"离着老远就被砍中"（用户反馈受击范围过大）。
## 收到 0.35 = 机身最粗处，贴住外观。
@export var hitbox_radius: float = 0.35

## 悬浮高度（米）
##
## 原值 2.0：玩家攻击的判定球心在腰高（y+0.5）、半径 1 米，
## 2 米高的机体整个在球外面 → 站在下面挥砍永远打空。
## 压到 1.5（起伏后 1.25~1.75）后，攻击判定圆柱（见 physics.gd）能覆盖到。
@export var hover_height: float = 1.5

## 电池掉落概率（0-1）
@export var battery_drop_chance: float = 0.2

## 出生锚定的任务区 ID（找不到时保持场景里的位置）
@export var anchor_task_id: String = "Rocky"

## 是否在 _ready 时锚定到矿区（Rocky）。
## 场景预置的无人机保持 true（出生后飞去矿区出没地）；
## 测试用无人机（出生点旁代码生成的）置 false，停在摆放位置。
@export var anchor_on_ready: bool = true

## 是否输出调试日志（受击/击落/找不到玩家等）
## 默认关闭：正式游玩时控制台会被刷屏。
## 想看所有敌人 → 去「设置 → 调试选项」开「敌人 AI / 战斗」；只想盯这一只 → 勾上本项。
@export var debug_enabled: bool = false

# ============================================
# 状态变量
# ============================================

## 当前状态：idle / engage / hurt / dead
var _state: String = "idle"

## 当前生命值
var _current_health: int = 20

## 攻击冷却计时器
var _attack_timer: float = 0.0

## 动画计时（悬浮起伏）
var _age: float = 0.0

## 受击闪白计时
var _hurt_timer: float = 0.0

## 横移方向（每 2-4 秒随机换向，制造不规则运动）
var _strafe_dir: float = 1.0
var _strafe_timer: float = 0.0

## 视觉部件
var _body_mesh: MeshInstance3D = null
var _eye_mesh: MeshInstance3D = null
var _rotor_mesh: MeshInstance3D = null
var _body_material: StandardMaterial3D = null
var _eye_material: StandardMaterial3D = null

## 地图生成器引用（锚定出生点用）
var _map_gen: Node = null

## 是否已输出过"未找到玩家"日志
var _logged_player_not_found: bool = false

## 初始化是否已完成。
## 视野流式加载（WorldStreamer）会把远处的敌人移出场景树、走近时再放回，
## 复用同一个节点而不是重建 —— 于是 _ready 必须**幂等**。
## 官方文档明确「节点重新入树不会再调一次 _ready」，但这里若重复执行就有副作用
## （_build_visual 会再拼一套机身/眼睛/旋翼叠上去），所以显式加一道守卫，
## 不把正确性寄托在引擎行为上。
var _initialized: bool = false

# ============================================
# 信号
# ============================================

## 死亡时发出
signal died()

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 重新入树（流式加载放回）时不重复初始化：见 _initialized 的说明
	if _initialized:
		return
	_initialized = true

	_current_health = max_health
	add_to_group("enemy")

	# 无碰撞体积：玩家和史莱姆都能从它底下/身上穿过去，它自己飞的时候
	# 也不会被地形和建筑挡住（高度完全由 _hover() 控制，不走地面碰撞）。
	# 想被玩家打到，靠的是下面 Hitbox 那个 Area3D——Area 不产生物理阻挡，
	# 但能被玩家攻击的形状查询（intersect_shape）查到。
	collision_layer = 0
	collision_mask = 0

	_build_visual()
	if anchor_on_ready:
		_anchor_to_region()
	# 悬空单位：velocity.y 恒为 0，不施加重力


func _physics_process(delta: float) -> void:
	_age += delta

	if _state == "dead":
		# 死亡：下坠 + 缩小
		velocity = Vector3(0, -3.0, 0)
		move_and_slide()
		var s := maxf(0.0, scale.x - delta * 2.0)
		scale = Vector3.ONE * s
		if s <= 0.05:
			queue_free()
		return

	# 攻击冷却
	if _attack_timer > 0:
		_attack_timer -= delta

	# 受击闪白
	if _hurt_timer > 0:
		_hurt_timer -= delta
		if _hurt_timer <= 0 and _body_material:
			_body_material.albedo_color = Color(0.35, 0.38, 0.45)

	# 旋翼旋转
	if _rotor_mesh:
		_rotor_mesh.rotation.y += 20.0 * delta

	var player := _get_player()
	var player_pos := _get_player_position(player)

	match _state:
		"idle":
			_process_idle(delta, player, player_pos)
		"engage":
			_process_engage(delta, player, player_pos)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 调试是否开启：全局开关（设置 → 调试选项 → 敌人 AI）或本个体开关
# ----------------------------------------
func _debug_on() -> bool:
	return debug_enabled or DebugConfig.is_enabled(DebugConfig.CAT_ENEMY)


# ----------------------------------------
# 调试日志：受 _debug_on() 控制，关闭时直接返回
# ----------------------------------------
func _log(text: String, args: Array = []) -> void:
	if not _debug_on():
		return
	DebugConfig.log_msg(DebugConfig.CAT_ENEMY, text, args)

# ----------------------------------------
# 受到伤害函数
# ----------------------------------------
func take_damage(damage: int) -> void:
	if _state == "dead":
		return

	_current_health -= damage
	_log("[无人机] 受到 %d 点伤害，剩余 %d/%d", [damage, _current_health, max_health])

	# 受击反馈：机身闪白
	if _body_material:
		_body_material.albedo_color = Color(1.0, 1.0, 1.0)
		_hurt_timer = 0.15

	if _current_health <= 0:
		_die()
	else:
		# 被打立即进入交战状态
		_state = "engage"


func get_health() -> int:
	return _current_health


func get_max_health() -> int:
	return max_health


# ============================================
# 存档接口（由 SaveManager 调用）
# ============================================

## 存：世界坐标 + 当前血量（死亡的个体不入档，见 SaveManager._collect_enemies）
func get_save_data() -> Dictionary:
	return {
		"position": {"x": global_position.x, "y": global_position.y, "z": global_position.z},
		"health": _current_health,
	}


## 读：落位并复位运行态。
## 注意 y：_ready 里 _anchor_to_region() 会按矿区重新锚定，读档必须晚于它
## （SaveManager 在整棵树 _ready 完之后才应用存档，顺序上安全）。
func apply_save_data(data: Dictionary) -> void:
	var p: Dictionary = data.get("position", {})
	if not p.is_empty():
		global_position = Vector3(
			float(p.get("x", global_position.x)),
			float(p.get("y", global_position.y)),
			float(p.get("z", global_position.z)))

	_current_health = clampi(int(data.get("health", max_health)), 1, max_health)

	_state = "idle"
	_attack_timer = 0.0
	_hurt_timer = 0.0
	velocity = Vector3.ZERO
	scale = Vector3.ONE
	if _body_material:
		_body_material.albedo_color = Color(0.35, 0.38, 0.45)

# ============================================
# 状态处理
# ============================================

## 待机：原地悬浮，等待玩家进入仇恨范围
func _process_idle(delta: float, player: Node3D, player_pos: Vector3) -> void:
	_hover(delta)
	velocity = Vector3.ZERO
	move_and_slide()

	# 玩家存活且在仇恨范围内才进入交战（玩家死亡后不再锁定）
	if _is_player_alive() and player and player_pos != Vector3.ZERO:
		var dist := _flat_distance_to(player_pos)
		if dist <= hate_range:
			_state = "engage"


## 交战：保持 5-8 米距离 + 定时开火
func _process_engage(delta: float, player: Node3D, player_pos: Vector3) -> void:
	_hover(delta)

	if player == null or player_pos == Vector3.ZERO:
		_state = "idle"
		return

	# 玩家已死亡：不再以玩家为目标，停止走位与开火，回到悬停待机
	# （复活后 Physics.is_alive() 恢复 true，会自动重新锁定并交战）
	if not _is_player_alive():
		_state = "idle"
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var dist := _flat_distance_to(player_pos)

	# 玩家逃出仇恨范围 → 回待机
	if dist > hate_range + 2.0:
		_state = "idle"
		return

	# 朝向玩家（水平面）
	var to_player := player_pos - global_position
	to_player.y = 0
	to_player = to_player.normalized()
	look_at(global_position + to_player, Vector3.UP)

	# 距离控制
	var move := Vector3.ZERO
	if dist > combat_max:
		move = to_player * move_speed          # 太远 → 逼近
	elif dist < combat_min:
		move = -to_player * move_speed         # 太近 → 后撤

	# 横移（换向计时）
	_strafe_timer -= delta
	if _strafe_timer <= 0:
		_strafe_timer = randf_range(2.0, 4.0)
		_strafe_dir = 1.0 if randf() > 0.5 else -1.0
	var strafe_vec := Vector3(-to_player.z, 0, to_player.x) * _strafe_dir
	move += strafe_vec * move_speed * 0.5

	velocity = move
	move_and_slide()

	# 开火判定：距离 ≤ 8 米 且 冷却结束
	if dist <= combat_max and _attack_timer <= 0:
		_fire(player_pos)


## 悬浮起伏（视觉 y 微动）
func _hover(delta: float) -> void:
	var target_y: float = hover_height + sin(_age * 2.0) * 0.25
	global_position.y = lerpf(global_position.y, target_y, delta * 3.0)

# ============================================
# 攻击
# ============================================

## 发射一发弹幕
func _fire(target_pos: Vector3) -> void:
	_attack_timer = attack_interval

	var projectile := DroneProjectile.new()
	# 弹幕伤害 / 速度 / 射程同步本体的导出配置
	projectile.damage = attack_damage
	projectile.speed = projectile_speed
	projectile.max_distance = projectile_max_distance
	# 调试开关跟随本体：勾上无人机的 debug_enabled，它打出的弹幕日志也一起打开
	projectile.debug_enabled = debug_enabled

	var parent_node := get_parent()
	if parent_node == null:
		return
	parent_node.add_child(projectile)

	# 枪口：机体前方 0.6 米（沿"眼睛"朝向出去，避免打到自己），
	# 但**高度压到玩家躯干**（fire_height）—— 平射的弹道高度 = 枪口高度，
	# 直接取机体高度会从玩家头顶平着飞过去，原因见 fire_height 的说明。
	var muzzle: Vector3 = global_position + (-global_transform.basis.z) * 0.6
	muzzle.y = target_pos.y + fire_height
	projectile.launch(muzzle, target_pos)

	# 开火反馈：眼部闪一下
	if _eye_material:
		_eye_material.emission_energy_multiplier = 4.0
		var timer := get_tree().create_timer(0.15)
		timer.timeout.connect(func() -> void:
			if is_instance_valid(self) and _eye_material:
				_eye_material.emission_energy_multiplier = 1.5)

# ============================================
# 死亡与掉落
# ============================================

func _die() -> void:
	_state = "dead"
	_log("[无人机] 被击落")
	emit_signal("died")

	# 电池掉落（大纲 3.3.2：20%）
	if randf() <= battery_drop_chance:
		ItemDrop.spawn_item_by_id(&"battery", 1, global_position)

# ============================================
# 出生锚定
# ============================================

# ----------------------------------------
# 锚定到区域函数
# 尝试移动到锚定任务区（矿区）入口附近；
# 找不到任务时保持场景中摆放的位置。
# ----------------------------------------
func _anchor_to_region() -> void:
	var gen := _get_map_gen()
	if gen == null or not gen.has_method("get_task_world_position"):
		return

	var anchor: Vector3 = gen.get_task_world_position(anchor_task_id, 1.0)
	if anchor == Vector3.ZERO:
		return  # 找不到该任务 → 用场景摆放位置

	# 在任务中心附近随机偏移，然后吸附到最近陆地（螺旋搜索）
	var angle := randf() * TAU
	var dist := randf_range(10.0, 40.0)
	var candidate: Vector3 = anchor + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
	global_position = _snap_to_land(candidate)


# 螺旋向外搜索最近的陆地点
func _snap_to_land(from: Vector3) -> Vector3:
	var gen := _get_map_gen()
	if gen == null or not gen.has_method("is_land_world"):
		return from
	if gen.is_land_world(from):
		return from
	for ring in range(1, 30):
		var r: float = ring * 5.0
		for i in range(8):
			var a: float = TAU * i / 8.0 + ring
			var p: Vector3 = from + Vector3(cos(a) * r, 0, sin(a) * r)
			if gen.is_land_world(p):
				return p
	return from  # 整片都是海（理论上不会）：保持原位

# ============================================
# 工具方法
# ============================================

func _get_map_gen() -> Node:
	if _map_gen != null and is_instance_valid(_map_gen):
		return _map_gen
	_map_gen = get_tree().get_first_node_in_group("map_gen")
	return _map_gen


func _get_player() -> Node3D:
	var player := get_tree().get_first_node_in_group("player")
	if player == null and not _logged_player_not_found:
		_log("[无人机] 未找到玩家节点")
		_logged_player_not_found = true
	return player


## 玩家是否存活（死亡/溺水期间为 false）。
## 玩家死亡后无人机不再以玩家为目标：不会进入交战，已交战的退回悬停待机并停止开火。
## 权威判定走 Physics.is_alive()；没有该方法的场景退回血量判定。
func _is_player_alive() -> bool:
	var player := _get_player()
	if player == null:
		return false
	var physics := player.get_node_or_null("Physics")
	if physics == null:
		return false
	if physics.has_method("is_alive"):
		return bool(physics.call("is_alive"))
	if "current_health" in physics:
		return int(physics.current_health) > 0
	return true


func _get_player_position(player: Node3D) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var physics := player.get_node_or_null("Physics")
	if physics:
		return physics.global_position
	return Vector3.ZERO


func _flat_distance_to(pos: Vector3) -> float:
	var diff := pos - global_position
	diff.y = 0
	return diff.length()

# ============================================
# 视觉构建
# ============================================

# 视觉：几何体拼装的小型无人机
#   圆柱机身 + 红色发光"眼睛" + 高速旋转的旋翼盘
#   （远古机器风格，不需要贴图）
func _build_visual() -> void:
	var visual := Node3D.new()
	visual.name = "Visual"
	add_child(visual)

	# 机身（圆柱）
	_body_mesh = MeshInstance3D.new()
	var body := CylinderMesh.new()
	body.top_radius = 0.25
	body.bottom_radius = 0.35
	body.height = 0.35
	_body_mesh.mesh = body
	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = Color(0.35, 0.38, 0.45)
	_body_material.metallic = 0.7
	_body_mesh.material_override = _body_material
	visual.add_child(_body_mesh)

	# 眼睛（朝 -Z，与 look_at 方向一致）
	_eye_mesh = MeshInstance3D.new()
	var eye := SphereMesh.new()
	eye.radius = 0.09
	eye.height = 0.18
	_eye_mesh.mesh = eye
	_eye_mesh.position = Vector3(0, 0.05, -0.36)
	_eye_material = StandardMaterial3D.new()
	_eye_material.albedo_color = Color(1.0, 0.15, 0.1)
	_eye_material.emission_enabled = true
	_eye_material.emission = Color(1.0, 0.15, 0.1)
	_eye_material.emission_energy_multiplier = 1.5
	_eye_mesh.material_override = _eye_material
	visual.add_child(_eye_mesh)

	# 旋翼盘（扁圆柱，高速旋转模拟螺旋桨）
	_rotor_mesh = MeshInstance3D.new()
	var rotor := CylinderMesh.new()
	rotor.top_radius = 0.55
	rotor.bottom_radius = 0.55
	rotor.height = 0.03
	_rotor_mesh.mesh = rotor
	_rotor_mesh.position = Vector3(0, 0.28, 0)
	var rotor_mat := StandardMaterial3D.new()
	rotor_mat.albedo_color = Color(0.2, 0.2, 0.22, 0.8)
	rotor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rotor_mesh.material_override = rotor_mat
	visual.add_child(_rotor_mesh)

	# 命中盒：包在 Area3D 里，只用于"被玩家的攻击形状查询命中"。
	#
	# 之前这块 CollisionShape3D 是直接挂在 CharacterBody3D 上的，结果两头不讨好：
	#   1. 作为物理体它真的挡路（玩家的 collision_mask 含 layer 1，会被挡住）；
	#   2. 玩家照样打不到——机体悬在 2 米，超出攻击判定的高度范围。
	# Area3D 不参与碰撞解算（不会挡住任何人），但仍能被 intersect_shape 查到，
	# 命中后由 physics.gd 沿父链找到本节点的 take_damage()。
	var hitbox_area := Area3D.new()
	hitbox_area.name = "Hitbox"
	var hitbox := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = hitbox_radius        # 贴住机身，别比外观胖一圈（见 hitbox_radius）
	hitbox.shape = sphere
	hitbox_area.add_child(hitbox)
	add_child(hitbox_area)
