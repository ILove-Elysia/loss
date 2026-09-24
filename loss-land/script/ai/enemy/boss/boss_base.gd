# script/ai/enemy/boss/boss_base.gd
# ============================================
# Boss 通用状态机骨架（三条 Boss 线共用）
#
# 规格：主线设计规格.md 第 1 章 / 2.2 ~ 2.6。
#
# 为什么另起一层、不沿用史莱姆那套：
#   slime.gd / drone.gd 都是 "String _state + match + _process_<state>()"，
#   各写各的、没有公共基类（41 个函数 / 876 行）。三条 Boss 线照抄就是
#   3 × 900 行，而且表达不了 Boss 真正需要的几件事（前摇可躲、濒死保命、
#   脱战可重复、世界推进）。
#
# 三条钉死的规则（改动前先读 主线设计规格.md 1.2）：
#   1. **没有 dead 状态**。Boss 的终点是 GONE（退场），不是"死亡 + queue_free"。
#      所以本文件里不会有 _die()，也不会有 queue_free()。
#   2. **RETREAT 与 FALLEN 是两件事**。RETREAT = 玩家跑了，可重复、回满血、
#      **不写世界状态**；FALLEN = 打到 1 血，一次性、**写世界状态 + 场地变化**。
#   3. **判距离只走 player_body() / player_distance()**，绝不读 player 根节点
#      （根节点永不位移，读它得到的距离恒等于"出生点→Boss"，2026-09-22
#       已经在采集判定上炸过一次）。
#
# 与现有系统的边界：
#   - **不进 "enemy" 组**，用 "boss" 组：
#       · map_generator_3d._place_enemies() 会把组 "enemy" 的节点全搬到丛林区；
#       · save_manager / world_streamer 对 "enemy" 组用的是"存档里没有＝已击杀"，
#         这个语义对 Boss 是**反的**（Boss 是逃走，不是死）。
#   - 存档走独立的 world.bosses 段（第 2 步做），不碰 _collect_enemies/_apply_enemies。
# ============================================

class_name BossBase
extends CharacterBody3D

# ============================================
# 信号
# 状态迁移、招式开始/命中、退场、血量变化 —— UI/场地/存档都按这几个信号接线，
# 不要反过来去每帧轮询 Boss 的内部变量。
# ============================================
signal state_changed(previous: int, current: int)
signal attack_started(attack_id: StringName)
signal attack_landed(attack_id: StringName, damage: int)
signal health_changed(current: int, maximum: int)
signal boss_gone(boss_id: StringName)

# ============================================
# 配置
# ============================================
@export_group("身份")
## Boss 的稳定标识（**不要**用节点路径当身份：Boss 是运行时生成/移除的）
@export var boss_id: StringName = &"boss_unnamed"
## 中文名，日志与调试面板用
@export var display_name: String = "Boss"
## 退场时要写进 WorldState 的旗标（留空 = 不写）。沙虫用 &"sandworm_nest_state"
@export var nest_flag: StringName = &""

@export_group("数值")
@export var max_health: int = 900
## 追击速度。标尺：玩家 5.0、史莱姆 1.5 ⇒ Boss 落在 3.5 ~ 4.5
@export var chase_speed: float = 4.0
## 回巢/逃走时的移速倍率（逃走过程也要能被玩家看见）
@export var return_speed_scale: float = 1.4

@export_group("触发与脱战")
## 玩家进到多近算"靠近巢穴"
@export var trigger_radius: float = 14.0
## 要在圈里待够多久才登场（中途出圈计时清零）
@export var trigger_dwell: float = 1.5
## 玩家跑出多远算脱战（应显著大于触发半径）
@export var leash_radius: float = 34.0
## 出圈持续多久才真脱战（防止在边界反复横跳刷"回满血"）
@export var leash_time: float = 4.0
## 判定"已经到巢穴了"的半径
@export var arrive_radius: float = 1.2

@export_group("演出")
## 登场时长（占位美术用：钻出沙面）
@export var emerge_time: float = 1.6
## 待机时埋在"地下"多深（占位美术的视觉表达）
@export var buried_depth: float = 3.2
## 沉下去 / 浮上来的速度
@export var rise_speed: float = 6.0

@export_group("占位外观")
@export var body_color: Color = Color(0.82, 0.70, 0.42)
@export var hurt_color: Color = Color(1.0, 0.86, 0.86)
@export var fallen_color: Color = Color(0.52, 0.50, 0.55)
@export var hurt_flash_time: float = 0.12

@export_group("调试")
@export var debug_enabled: bool = false

# ============================================
# 运行时状态
# ============================================
var _state: int = BossState.State.DORMANT
var _health: int = 0
var _untouchable: bool = false
var _home: Vector3 = Vector3.ZERO
var _gravity: float = 9.8
var _state_time: float = 0.0
var _trigger_timer: float = 0.0
var _leash_timer: float = 0.0
var _move_dir: Vector3 = Vector3.ZERO
var _attack: BossAttack = null
var _attack_index: int = -1
var _strike_done: bool = false
var _cooldowns: Dictionary = {}
var _phase1_attacks: Array[BossAttack] = []
var _phase2_attacks: Array[BossAttack] = []
var _player_cache: Node3D = null
var _died_hooked: bool = false
var _visual: Node3D = null
var _body_material: StandardMaterial3D = null
var _hurt_flash: float = 0.0
var _debug_timer: float = 0.0
var _gone_emitted: bool = false

# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	_home = global_position
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_health = maxi(max_health, 1)
	# 另立 "boss" 组，理由见文件头
	add_to_group("boss")
	_build_attacks()
	_reset_cooldowns()
	_visual = get_node_or_null("Visual") as Node3D
	_setup_placeholder_material()
	_state = BossState.State.DORMANT
	_state_time = 0.0
	_refresh_body_color()
	_connect_player_signals()
	_debug("就绪：巢穴 %s，血量 %d" % [str(_home), _health])


func _physics_process(delta: float) -> void:
	_tick_cooldowns(delta)
	if not _died_hooked:
		_connect_player_signals()
	if _hurt_flash > 0.0:
		_hurt_flash = maxf(_hurt_flash - delta, 0.0)
		if _hurt_flash <= 0.0:
			_refresh_body_color()

	_state_time += delta
	# 各状态只负责给出本帧的"想往哪走"，位移统一在末尾做 ——
	# 免得每个 _process_xxx 都写一遍 move_and_slide
	_move_dir = Vector3.ZERO

	match _state:
		BossState.State.DORMANT:
			_process_dormant(delta)
		BossState.State.EMERGING:
			_process_emerging()
		BossState.State.CHASE:
			_process_chase(delta)
		BossState.State.TELEGRAPH, BossState.State.STRIKE, BossState.State.RECOVER:
			_process_attack(delta)
		BossState.State.RETREAT, BossState.State.FALLEN:
			_process_going_home()
		_:
			_move_dir = Vector3.ZERO

	var speed: float = _movement_speed()
	velocity.x = _move_dir.x * speed
	velocity.z = _move_dir.z * speed
	velocity.y -= _gravity * delta
	move_and_slide()
	if is_on_floor():
		velocity.y = 0.0

	_update_visual(delta)
	_tick_debug(delta)


## 子类覆写：填 _phase1_attacks / _phase2_attacks。
## 基类不定义任何具体招式 —— 招式表是每只 Boss 自己的性格。
func _build_attacks() -> void:
	pass


## 子类可覆写：进入 GONE 时的额外表现（巢穴坍塌动画等）。
## 世界旗标已经在 _enter_gone() 里写好了，这里只做表现。
func _on_gone() -> void:
	pass

# ============================================
# 状态机
# ============================================

func _set_state(new_state: int) -> void:
	var previous: int = _state
	if previous == new_state:
		return
	_state = new_state
	_state_time = 0.0
	_move_dir = Vector3.ZERO
	# 离开招式三段就丢掉当前招 —— 于是"招式播到一半换表"不可能发生
	if not BossState.is_attack_phase(new_state):
		_attack = null
	_refresh_body_color()
	state_changed.emit(previous, new_state)


## 待机：玩家进圈并**停留**够 trigger_dwell 才登场
func _process_dormant(delta: float) -> void:
	if not player_alive():
		_trigger_timer = 0.0
		return
	var distance: float = player_distance()
	if distance > trigger_radius:
		# 中途出圈 → 计时清零（"靠近并停留一段时间"）
		_trigger_timer = 0.0
		return
	_trigger_timer += delta
	if _trigger_timer >= trigger_dwell:
		_trigger_timer = 0.0
		_debug("玩家在触发圈内停留 %.1fs → 登场" % trigger_dwell)
		_set_state(BossState.State.EMERGING)


func _process_emerging() -> void:
	if _state_time >= emerge_time:
		_debug("登场完毕 → 追击")
		_set_state(BossState.State.CHASE)


## 追击：朝玩家移动，并在每次决策点选招
func _process_chase(delta: float) -> void:
	if _check_leash(delta):
		return
	if not player_alive():
		_start_retreat("玩家死亡")
		return
	var body: Node3D = player_body()
	if body == null:
		return
	var dir: Vector3 = _horizontal_dir(global_position, body.global_position)
	_face(dir)
	_move_dir = dir
	# 决策点：有可用招就出招；一条都没有（全在 CD / 都够不着）
	# 就继续贴身追 —— 这就是原案缺失的兜底，不许原地发呆
	_decide()


## 招式三段：前摇 → 判定 → 后摇。
## 三段走完回到 CHASE，由下一次决策重新选招（**不是** while 跳回上一行）
func _process_attack(delta: float) -> void:
	if _attack == null:
		_set_state(BossState.State.CHASE)
		return
	if _check_leash(delta):
		return

	# 前摇期间按 move_scale 决定能不能动（0 = 定身，给玩家跑的机会）
	if _movement_speed() > 0.0:
		var body: Node3D = player_body()
		if body != null:
			var dir: Vector3 = _horizontal_dir(global_position, body.global_position)
			_face(dir)
			_move_dir = dir

	match _state:
		BossState.State.TELEGRAPH:
			if _state_time >= _attack.telegraph_time:
				_set_state(BossState.State.STRIKE)
		BossState.State.STRIKE:
			# 判定只做一次（不是每帧扣血）
			if not _strike_done:
				_strike_done = true
				_apply_attack_damage()
			if _state_time >= _attack.strike_time:
				_set_state(BossState.State.RECOVER)
		BossState.State.RECOVER:
			if _state_time >= _attack.recover_time:
				_cooldowns[_attack.attack_id] = _attack.cooldown
				_debug("招式 %s 结算，进入冷却 %.1fs" % [_attack.attack_id, _attack.cooldown])
				_set_state(BossState.State.CHASE)
		_:
			pass


## RETREAT / FALLEN 共用：往巢穴走，到了再分道扬镳
func _process_going_home() -> void:
	var distance: float = _horizontal_distance(global_position, _home)
	if distance <= arrive_radius:
		_move_dir = Vector3.ZERO
		if _state == BossState.State.FALLEN:
			_enter_gone()
			return
		# 脱战回巢：**回满血**（不是回一部分），可无限重复
		_health = max_health
		health_changed.emit(_health, max_health)
		_untouchable = false
		_trigger_timer = 0.0
		_leash_timer = 0.0
		_reset_cooldowns()
		_debug("已回巢，血量回满 → 待机")
		_set_state(BossState.State.DORMANT)
		return
	var dir: Vector3 = _horizontal_dir(global_position, _home)
	_face(dir)
	_move_dir = dir


## 移动速度：由状态（以及招式的 move_scale）决定
func _movement_speed() -> float:
	match _state:
		BossState.State.CHASE:
			return chase_speed
		BossState.State.RETREAT, BossState.State.FALLEN:
			return chase_speed * return_speed_scale
		BossState.State.TELEGRAPH, BossState.State.STRIKE, BossState.State.RECOVER:
			if _attack != null:
				return chase_speed * _attack.move_scale
			return 0.0
		_:
			return 0.0


## 脱战判定：出圈持续 leash_time 才生效（返回值 = 本帧是否已经转入 RETREAT）
func _check_leash(delta: float) -> bool:
	if BossState.is_terminal(_state):
		return true
	if leash_time <= 0.0:
		return false
	var distance: float = player_distance()
	if distance <= leash_radius:
		_leash_timer = 0.0
		return false
	_leash_timer += delta
	if _leash_timer < leash_time:
		return false
	_start_retreat("玩家拖太远 %.1f m（>%.1f m 持续 %.1fs）" % [distance, leash_radius, leash_time])
	return true

# ============================================
# 决策：选表 → 选招
# ============================================

## 决策点执行一次：选到招就出招（返回 true），没招就交回 CHASE（返回 false）
func _decide() -> bool:
	var next: BossAttack = _pick_next_attack()
	if next == null:
		return false
	_start_attack(next)
	return true


## 从上往下取第一条**同时**满足「不在 CD」且「玩家在射程内」的招。
## 扫不到 → null（调用方回 CHASE）。注意这是**固定优先级轮转**、不是随机：
## 第 1 招永远优先，第 3 招只在 1、2 都在 CD 时才出场。
func _pick_next_attack() -> BossAttack:
	var table: Array[BossAttack] = _current_table()
	var distance: float = player_distance()
	for i in range(table.size()):
		var candidate: BossAttack = table[i]
		if candidate == null:
			continue
		if cooldown_left(candidate.attack_id) > 0.0:
			continue
		if not candidate.in_range(distance):
			continue
		_attack_index = i
		return candidate
	_attack_index = -1
	return null


## 按血量选表。**相位切换只发生在决策点** —— 招式播到一半绝不换表
func _current_table() -> Array[BossAttack]:
	if max_health > 0 and float(_health) / float(max_health) > 0.5:
		return _phase1_attacks
	return _phase2_attacks


func _start_attack(attack: BossAttack) -> void:
	_attack = attack
	_strike_done = false
	attack_started.emit(attack.attack_id)
	_debug("选招 %s（%s）" % [attack.attack_id, attack.describe()])
	_set_state(BossState.State.TELEGRAPH)


## 判定生效：玩家在判定半径内才扣血。用玩家**本体**（player/Physics）算距离
func _apply_attack_damage() -> void:
	if _attack == null:
		return
	var body: Node3D = player_body()
	if body == null or not player_alive():
		_debug("招式 %s 落空（玩家不在场）" % _attack.attack_id)
		return
	var distance: float = _horizontal_distance(global_position, body.global_position)
	if distance > _attack.radius:
		_debug("招式 %s 落空（玩家 %.1f m 在 %.1f m 判定外）"
			% [_attack.attack_id, distance, _attack.radius])
		return
	if not body.has_method("take_damage"):
		return
	body.call("take_damage", _attack.damage)
	attack_landed.emit(_attack.attack_id, _attack.damage)
	_debug("招式 %s 命中玩家，扣 %d" % [_attack.attack_id, _attack.damage])

# ============================================
# 受伤与濒死
# ============================================

## 受伤入口。签名必须与 Slime / Drone / 玩家 Physics 一致
## （玩家攻击是**沿父链按方法名找 take_damage**，改名就找不到承伤体了）。
func take_damage(damage: int) -> void:
	# ⚠ 第一行就拦。玩家一次挥砍用 intersect_shape(..., 10) 查最多 10 个碰撞体，
	#   进入 FALLEN 的**同一帧**完全可能再来第二段伤害把保底的 1 点打光。
	if _untouchable:
		return
	if not BossState.can_be_hurt(_state):
		return
	if damage <= 0:
		return
	_health -= damage
	if _health <= 0:
		# 保留最后 1 点生命 —— 注意这一步发生在 take_damage **内部**，
		# 不是"等主循环回头查到血量等于 1"（一次扣 10、血量剩 5 → -5，
		# 那时" >50% / 1<x<50% / ==1 " 三个分支一个都不命中，状态机会卡死）
		_health = 1
		health_changed.emit(_health, max_health)
		_enter_fallen()
		return
	health_changed.emit(_health, max_health)
	_on_hurt(damage)


func _on_hurt(_damage: int) -> void:
	_hurt_flash = hurt_flash_time
	_refresh_body_color()


## 濒死逃走：1 点生命 + **永久**无敌（不是 mob 那种 0.5 秒计时器）
func _enter_fallen() -> void:
	if _state == BossState.State.FALLEN or BossState.is_terminal(_state):
		return
	_untouchable = true
	_trigger_timer = 0.0
	_leash_timer = 0.0
	_refresh_body_color()
	_debug("血量见底 → 保留 1 点生命、永久无敌，开始逃走")
	_set_state(BossState.State.FALLEN)


## 退场：一次性，且是**唯一**写世界状态的地方
func _enter_gone() -> void:
	if _state == BossState.State.GONE:
		return
	_set_state(BossState.State.GONE)
	if nest_flag != &"":
		# 场地永久变化（巢穴坍塌 / 藤蔓天数 / 浮空岛是否坠落）的唯一落点：
		# v2 的地图地形快照只存 1600×1600 的瓦片，装不下这些
		WorldState.set_flag(nest_flag, 1)
	_on_gone()
	if not _gone_emitted:
		_gone_emitted = true
		boss_gone.emit(boss_id)
	_debug("已退场（%s）" % boss_id)

# ============================================
# 离场：两个触发源、同一条路径
# ============================================

## 脱战。
## 触发源有两个：① 玩家拖太远（_check_leash）② 玩家死亡（_on_player_died）。
## **两者共用这一条路径、同一个结果**，只区分触发源写日志。
func _start_retreat(reason: String) -> void:
	if BossState.is_terminal(_state) or _state == BossState.State.FALLEN:
		return
	if _state == BossState.State.RETREAT:
		return
	# 这里**不写任何世界状态**、可以无限重复 ⇒ 反复消耗磨不死它
	_trigger_timer = 0.0
	_leash_timer = 0.0
	_debug("脱战（%s）→ 回巢回满血" % reason)
	_set_state(BossState.State.RETREAT)


## 玩家死亡 → 同一条脱战路径。
## 必须接：RespawnSystem 完全不碰敌人，不接就会"守尸"
## （复活点若在仇恨圈内，玩家 5 秒后必再死）。
func _on_player_died() -> void:
	if BossState.is_terminal(_state):
		return
	if _state == BossState.State.DORMANT:
		return
	_start_retreat("玩家死亡")


## 挂上玩家的 died 信号。用**动态** connect：玩家本体是"CharacterBody3D + 脚本"，
## 静态类型上访问不到 .died（和现役敌人查 is_alive() 一样走 has_signal/has_method）。
## 玩家可能比 Boss 晚入树，所以 _physics_process 每帧重试，成功一次就置 _died_hooked。
func _connect_player_signals() -> void:
	var body: Node3D = player_body()
	if body == null:
		return
	# 玩家本体没有 died 信号时（例如没有生命系统的假玩家）不挂，
	# 这种情况靠每帧的 player_alive() 兜底，照样不会守尸
	if body.has_signal("died"):
		var callback: Callable = Callable(self, "_on_player_died")
		if not body.is_connected("died", callback):
			body.connect("died", callback)
	_died_hooked = true

# ============================================
# 玩家定位（**唯一入口**，谁都不许绕过）
# ============================================

## 玩家本体 = player 节点的 Physics 子节点（CharacterBody3D）。
## 找不到就退回玩家根节点 —— 那只是最后兜底，正常情况永远走 Physics。
func player_body() -> Node3D:
	if _player_cache != null and is_instance_valid(_player_cache):
		return _player_cache
	var root: Node = get_tree().get_first_node_in_group("player")
	if root == null:
		return null
	var body: Node = root.get_node_or_null("Physics")
	if body is Node3D:
		_player_cache = body as Node3D
	else:
		_player_cache = root as Node3D
	return _player_cache


## 玩家本体位置。玩家不在场时返回巢穴位置 —— 想判"有没有人"请用 player_distance()
func player_position() -> Vector3:
	var body: Node3D = player_body()
	if body == null:
		return _home
	return body.global_position


## 玩家到 Boss 的**平面**距离。玩家不在场返回 INF
## ⇒ 于是"没有任何招够得着"，决策自然回落到 CHASE 而不是空放
func player_distance() -> float:
	var body: Node3D = player_body()
	if body == null:
		return INF
	return _horizontal_distance(global_position, body.global_position)


## 权威判定走玩家的 Physics.is_alive()（死亡期间敌人应放弃锁定）
func player_alive() -> bool:
	var body: Node3D = player_body()
	if body == null:
		return false
	if body.has_method("is_alive"):
		return bool(body.call("is_alive"))
	return true

# ============================================
# 招式冷却
# ============================================

func cooldown_left(attack_id: StringName) -> float:
	if not _cooldowns.has(attack_id):
		return 0.0
	return float(_cooldowns[attack_id])


func _tick_cooldowns(delta: float) -> void:
	# 每招一个计时器（不是全局一个）；.keys() 返回的是副本，可安全边遍历边改
	for key in _cooldowns.keys():
		var left: float = float(_cooldowns[key])
		if left > 0.0:
			_cooldowns[key] = maxf(left - delta, 0.0)


func _reset_cooldowns() -> void:
	_cooldowns.clear()
	_seed_cooldown_table(_phase1_attacks)
	_seed_cooldown_table(_phase2_attacks)


func _seed_cooldown_table(table: Array[BossAttack]) -> void:
	for attack in table:
		if attack == null:
			continue
		if not _cooldowns.has(attack.attack_id):
			_cooldowns[attack.attack_id] = 0.0

# ============================================
# 表现（占位）
# ============================================

func _setup_placeholder_material() -> void:
	if _visual == null:
		return
	var body_mesh: MeshInstance3D = _visual.get_node_or_null("Body") as MeshInstance3D
	if body_mesh == null:
		return
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = body_color
	material.roughness = 0.9
	body_mesh.material_override = material
	_body_material = material


func _refresh_body_color() -> void:
	if _body_material == null:
		return
	var color: Color = body_color
	if _hurt_flash > 0.0:
		color = hurt_color
	elif _state == BossState.State.FALLEN or _state == BossState.State.GONE:
		color = fallen_color
	elif _state == BossState.State.TELEGRAPH and _attack != null:
		# 前摇的视觉信号：体色变红 = "要打了，快跑"
		# 正式美术接入后这一段由动画承担（BossAttack.telegraph_color 只是占位）
		color = _attack.telegraph_color
	_body_material.albedo_color = color


## 占位美术的"钻出沙面"：待机埋在 -buried_depth，登场期间抬到 0
func _update_visual(delta: float) -> void:
	if _visual == null:
		return
	var position: Vector3 = _visual.position
	match _state:
		BossState.State.EMERGING:
			var t: float = 1.0
			if emerge_time > 0.0:
				t = clampf(_state_time / emerge_time, 0.0, 1.0)
			position.y = lerpf(-buried_depth, 0.0, t)
		BossState.State.DORMANT, BossState.State.GONE:
			position.y = move_toward(position.y, -buried_depth, rise_speed * delta)
		_:
			position.y = move_toward(position.y, 0.0, rise_speed * delta)
	_visual.position = position
	_visual.visible = position.y > -buried_depth + 0.05


## 占位朝向：只转 Visual 的 yaw（正式美术接入后改走
## script/visual/sprite_facing.gd 的 facing_basis —— 那时要**删掉**这里，
## 否则会和 SpriteFacing 抢 Visual 的 basis）
func _face(dir: Vector3) -> void:
	if _visual == null:
		return
	if absf(dir.x) < 0.001 and absf(dir.z) < 0.001:
		return
	# 本脚本把"面向"表达为 Visual 的局部 +Z 指向目标（占位模型的"下颚"挂在 +Z）
	var rotation: Vector3 = _visual.rotation
	rotation.y = atan2(dir.x, dir.z)
	_visual.rotation = rotation

# ============================================
# 工具
# ============================================

func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


func _horizontal_dir(from: Vector3, to: Vector3) -> Vector3:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var length: float = sqrt(dx * dx + dz * dz)
	if length < 0.0001:
		return Vector3.ZERO
	return Vector3(dx / length, 0.0, dz / length)

# ============================================
# 对外的只读查询（场地 / 调试面板 / 存档）
# ============================================

func get_state() -> int:
	return _state


func get_health() -> int:
	return _health


func get_max_health() -> int:
	return max_health


func home_position() -> Vector3:
	return _home


## 场地/世界流式应在落位后调用它（_ready 抓的是入树那一刻的坐标）
func set_home_position(position: Vector3) -> void:
	_home = position


# ---- 测试场地专用（沙虫测试场地 sandworm_arena.gd 会调）----
# 正式游戏逻辑**不要**依赖这两个：正式流程永远是"玩家的接近行为"触发登场。

## 跳过"靠近 + 停留"，直接唤起（方便反复测招式/三段时序）
func debug_wake() -> void:
	if _state != BossState.State.DORMANT:
		return
	_debug("调试唤起")
	_set_state(BossState.State.EMERGING)


## 把血量打到指定值。**走正常受伤路径**，所以"保底 1 点 + 濒死"的规则照样生效：
## debug_damage_to(0) → 血量打光 → 夹到 1 → 进 FALLEN（正是要测的那条路）
func debug_damage_to(target_health: int) -> void:
	var delta: int = _health - target_health
	if delta <= 0:
		return
	take_damage(delta)


## 把所有招式的冷却拉满（测"全表在 CD 时的兜底"：应当继续追击、不空放、不卡死）
func debug_set_all_cooldowns(seconds: float) -> void:
	for key in _cooldowns.keys():
		_cooldowns[key] = maxf(seconds, 0.0)


## 当前相位：1 = 血厚表，2 = 血少表。
## 注意它**只反映此刻按血量该用哪张表**；招式播到一半不会真的换表（见 _current_table 注释）
func current_phase() -> int:
	if max_health > 0 and float(_health) / float(max_health) > 0.5:
		return 1
	return 2


## 此刻正在执行的那条招式（不在招式三段里时为 null）
func current_attack() -> BossAttack:
	return _attack


## 是否已经"输掉这场架"（濒死逃走 or 已退场）—— 存档用它判 defeated
func is_defeated() -> bool:
	return _state == BossState.State.FALLEN or BossState.State.GONE == _state


func current_attack_id() -> StringName:
	if _attack == null:
		return &""
	return _attack.attack_id


## 调试面板用的一行描述（测试场地每帧刷这个）
func debug_line() -> String:
	return "状态 %s   HP %d/%d   距离 %.1f m   用招 %s" % [
		BossState.label_of(_state),
		_health,
		max_health,
		player_distance(),
		_describe_cooldowns(),
	]


func _describe_cooldowns() -> String:
	var parts: Array[String] = []
	var table: Array[BossAttack] = _current_table()
	for attack in table:
		if attack == null:
			continue
		var cd: float = cooldown_left(attack.attack_id)
		if cd > 0.0:
			parts.append("%s(CD %.1f)" % [attack.attack_id, cd])
		else:
			parts.append("%s(就绪)" % attack.attack_id)
	if parts.is_empty():
		return "（无招式表）"
	return " ".join(parts)

# ============================================
# 日志（默认关闭：DebugConfig 的 enemy 分类打开时才输出）
# ============================================

func _debug_on() -> bool:
	return debug_enabled or DebugConfig.is_enabled(DebugConfig.CAT_ENEMY)


func _debug(text: String) -> void:
	if not _debug_on():
		return
	# 自己把前缀拼好再传：log_msg(cat, text, args) 只在 args 非空时才做 text % args，
	# 所以这里 args 留空 —— 日志文本里出现 % 也不会被二次解析
	DebugConfig.log_msg(DebugConfig.CAT_ENEMY, "[%s] %s" % [display_name, text], [])


func _tick_debug(delta: float) -> void:
	if not _debug_on() or BossState.is_terminal(_state):
		return
	_debug_timer += delta
	if _debug_timer < 1.0:
		return
	_debug_timer = 0.0
	_debug("状态=%s HP=%d/%d 距离=%.1f" % [
		BossState.label_of(_state), _health, max_health, player_distance()])
