# test/boss_state_test.gd
# ============================================
# Boss 状态机回归（headless，**不生成地图**）
#
#   godot --headless --path . --script res://test/boss_state_test.gd
#
# 对应用例表：主线设计规格.md 1.10（#1~5）+ 2.9（#8~12）。
#
# 关键设计：
#   · 直接实例化 Boss，不加载 map.tscn —— 那边一次地图生成要 12~20 秒；
#   · 假玩家用 test/mock_boss_target.gd，挂在 "player" 组根节点的 **Physics** 子节点上，
#     因为 Boss 的定位入口只认 player/Physics（读 player 根节点会永远得到"出生点"距离）；
#   · 全部断言基于**公开接口**（get_state / get_health / current_attack / debug_*），
#     不去戳私有字段 —— 状态机内部重构时测试不该跟着改。
# ============================================

extends SceneTree

const BOSS_SCENE := "res://tscn/prefab/boss/sandworm.tscn"
const ARENA_SCENE := "res://tscn/sandworm_test.tscn"
const MOCK_TARGET := "res://test/mock_boss_target.gd"

var _failures: int = 0
var _checks: int = 0
var _boss: BossBase = null
var _target: CharacterBody3D = null


func _initialize() -> void:
	await process_frame
	await process_frame
	WorldState.reset()
	_build_world()
	await _run_cases()
	await _case_arena_scene()
	print("============================================")
	if _failures == 0:
		print("===== 全部通过（%d 项断言）=====" % _checks)
	else:
		print("!!!!! %d 项失败（共 %d 项断言）!!!!!" % [_failures, _checks])
	quit(_failures)


# ============================================
# 世界搭建
# ============================================

func _build_world() -> void:
	# 平地把 Boss 接住（Boss 自己吃重力，没有地面会一直往下掉）
	var ground: StaticBody3D = StaticBody3D.new()
	ground.name = "Ground"
	ground.collision_layer = 2
	ground.collision_mask = 0
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)

	# 假玩家：Boss 找的是 "player" 组里的 Physics 子节点
	var player_root: Node3D = Node3D.new()
	player_root.name = "player"
	player_root.add_to_group("player")
	root.add_child(player_root)
	var mock_script: GDScript = load(MOCK_TARGET) as GDScript
	if mock_script == null:
		push_error("找不到假玩家脚本：%s" % MOCK_TARGET)
		quit(1)
		return
	_target = mock_script.new() as CharacterBody3D
	_target.name = "Physics"
	player_root.add_child(_target)

	var packed: PackedScene = load(BOSS_SCENE) as PackedScene
	if packed == null:
		push_error("找不到 Boss 场景：%s" % BOSS_SCENE)
		quit(1)
		return
	_boss = packed.instantiate() as BossBase
	if _boss == null:
		push_error("Boss 场景的根节点不是 BossBase（脚本可能解析失败）")
		quit(1)
		return
	root.add_child(_boss)
	_boss.global_position = Vector3.ZERO
	# _ready 抓的"巢穴坐标"是入树那一刻的坐标，测试里显式再钉一次
	_boss.set_home_position(Vector3.ZERO)
	_boss.debug_enabled = false


# ============================================
# 断言 / 步进工具
# ============================================

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  [通过] %s" % message)
	else:
		_failures += 1
		print("  [失败] %s" % message)


## 把假玩家放到"离 Boss 当前所在位置 distance 米"的地方。
## 以 Boss 当前位置为基准：它一边追一边跑，用固定坐标算距离会越算越偏。
func _place_target_at(distance: float) -> void:
	var base: Vector3 = _boss.global_position
	_target.global_position = Vector3(base.x, 0.0, base.z + distance)


func _boss_distance() -> float:
	return _boss.player_distance()


## 把假玩家放到"离**巢穴** distance 米"的地方。
## 领地（脱战）判定的基准是巢穴、不是 Boss 本人，所以专门留一个以巢穴为基准的摆位函数。
func _place_target_from_home(distance: float) -> void:
	var home: Vector3 = _boss.home_position()
	_target.global_position = Vector3(home.x, 0.0, home.z + distance)


## 玩家到巢穴的距离 —— 领地判定真正量的那一段
func _target_home_distance() -> float:
	return _boss.player_home_distance()


## Boss 到巢穴的距离 —— 领地绳应该把它按在 leash_radius 上
func _boss_home_distance() -> float:
	var home: Vector3 = _boss.home_position()
	var dx: float = _boss.global_position.x - home.x
	var dz: float = _boss.global_position.z - home.z
	return sqrt(dx * dx + dz * dz)


func _step(seconds: float) -> void:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < seconds:
		await physics_frame
		elapsed += per_frame


func _wait_for_state(target_state: int, timeout: float) -> bool:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < timeout:
		if _boss.get_state() == target_state:
			return true
		await physics_frame
		elapsed += per_frame
	return _boss.get_state() == target_state


## 等进入"战斗中"：追击，或招式三段之一
func _wait_for_battle(timeout: float) -> bool:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < timeout:
		var state: int = _boss.get_state()
		if state == BossState.State.CHASE or BossState.is_attack_phase(state):
			return true
		await physics_frame
		elapsed += per_frame
	return false


## 等进入招式三段（前摇/判定/后摇）
func _wait_for_attack_phase(timeout: float) -> bool:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < timeout:
		if BossState.is_attack_phase(_boss.get_state()):
			return true
		await physics_frame
		elapsed += per_frame
	return false


# ============================================
# 用例
# ============================================

func _run_cases() -> void:
	print("============================================")
	print("[用例 1] 触发：靠近 + 停留够时长才登场")

	_place_target_at(60.0)
	await _step(0.4)
	_check(_boss.get_state() == BossState.State.DORMANT, "玩家在圈外时保持待机")

	_place_target_at(10.0)
	await _step(_boss.trigger_dwell * 0.5)
	_check(_boss.get_state() == BossState.State.DORMANT,
		"进圈不满 %.1fs 仍是待机" % _boss.trigger_dwell)

	_place_target_at(20.0)
	await _step(_boss.trigger_dwell + 0.4)
	_check(_boss.get_state() == BossState.State.DORMANT, "中途出圈 → 计时清零、不出场")

	_place_target_at(10.0)
	await _step(_boss.trigger_dwell + 0.15)
	_check(_boss.get_state() == BossState.State.EMERGING, "停留够时长 → 登场")
	_check(not BossState.can_be_hurt(_boss.get_state()), "登场期间不可受伤")

	# 挪到所有招式射程外（免得一出场就出招），但**别出领地**：
	# 领地判定量的是「玩家↔巢穴」，站到 leash_radius 外会直接把脱战计时打开。
	_place_target_at(20.0)
	await _step(_boss.emerge_time + 0.2)
	_check(_boss.get_state() == BossState.State.CHASE, "登场结束 → 追击")

	print("[用例 8] 追击与脱战")
	# 先把所有招式按在 CD 上：这一段要测的是**纯追击位移**与**领地判定**。
	# 一旦让它出招，①前摇/后摇的 move_scale 会把位移吃掉（bite/sweep 近乎定身），
	# 位移断言必假失败；②假玩家要是被咬死，走的就是"玩家死亡"那条分支，
	# 领地判定根本没被执行。
	# ⚠ 必须在这里（还没有招式在播的时候）就按：等招式播起来再按，
	#   它结束时 reco 分支会把自己的 cooldown（如 sand_spit 的 9 s）写回去，
	#   于是这一招提前解禁、又开始出招（2026-09-25 踩过：spit CD 9 → 0，
	#   而同时按下的 bite 仍有 19 s）。
	_boss.debug_set_all_cooldowns(30.0)

	var distance_before: float = _boss_distance()
	await _step(1.0)
	var distance_after: float = _boss_distance()
	_check(distance_after < distance_before - 1.5,
		"玩家在仇恨圈内 → 朝玩家位移（%.1f m → %.1f m）" % [distance_before, distance_after])

	_boss.take_damage(200)
	_check(_boss.get_health() < _boss.get_max_health(),
		"追击状态下可被扣血（%d / %d）" % [_boss.get_health(), _boss.get_max_health()])

	# ① 领地内站多久都不脱战
	_place_target_from_home(_boss.leash_radius * 0.9)
	await _step(_boss.leash_time * 3.0)
	_check(_boss.get_state() == BossState.State.CHASE,
		"还在领地内（%.1f m < %.1f m）→ 追多久都不脱战"
			% [_target_home_distance(), _boss.leash_radius])

	# ② 领地绳：追到领地边缘就停住，不许越界。
	#    临时把 leash_time 拉到 10 s —— 否则脱战计时会先跑完，看不到"它停在边上"。
	var saved_leash_time: float = _boss.leash_time
	_boss.leash_time = 10.0
	_place_target_from_home(_boss.leash_radius + 20.0)
	await _step(6.0)
	_check(_boss_home_distance() <= _boss.leash_radius + 0.5,
		"领地绳：沙虫被按在领地边缘（离巢穴 %.1f m ≤ %.1f m）"
			% [_boss_home_distance(), _boss.leash_radius])
	_check(_boss.get_state() == BossState.State.CHASE,
		"领地绳生效期间仍在追击态（没卡死）")

	# ③ 回领地内 → 计时清零（顺带验证"回圈就重置"，否则下一步会秒脱战）
	_place_target_from_home(_boss.leash_radius * 0.5)
	await _step(0.5)
	_boss.leash_time = saved_leash_time

	# ④ 出领地：立刻计时，不满 leash_time 不走
	_place_target_from_home(_boss.leash_radius + 12.0)
	await _step(_boss.leash_time * 0.5)
	_check(_boss.get_state() == BossState.State.CHASE,
		"刚出领地不满 %.1fs 还不脱战" % _boss.leash_time)
	await _step(_boss.leash_time * 0.5 + 0.3)
	_check(_boss.get_state() == BossState.State.RETREAT, "出领地持续够久 → 脱战逃走")

	print("[用例 2] 脱战回巢：回满血 + 回待机（不推进世界）")
	var got_home: bool = await _wait_for_state(BossState.State.DORMANT, 30.0)
	_check(got_home, "走回巢穴后回到待机")
	_check(_boss.get_health() == _boss.get_max_health(),
		"回巢后**回满**血（%d / %d）" % [_boss.get_health(), _boss.get_max_health()])
	_check(WorldState.get_flag(Sandworm.NEST_FLAG, 0) == 0,
		"脱战**不写**世界状态（巢穴仍完好）")

	print("[用例 9] 玩家死亡 → 走同一条脱战路径")
	_place_target_at(3.0)
	_boss.debug_wake()
	var engaged: bool = await _wait_for_battle(10.0)
	_check(engaged, "被唤起后进入战斗")
	_boss.debug_damage_to(int(_boss.get_max_health() * 0.5))
	var health_before_death: int = _boss.get_health()
	_target.kill()
	await _step(0.2)
	var state_after_death: int = _boss.get_state()
	_check(state_after_death == BossState.State.RETREAT
			or state_after_death == BossState.State.DORMANT,
		"玩家一死，Boss 立刻撤离（当前 %s）" % BossState.label_of(state_after_death))
	var home_again: bool = await _wait_for_state(BossState.State.DORMANT, 30.0)
	_check(home_again, "回巢后回到待机")
	_check(_boss.get_health() == _boss.get_max_health(),
		"玩家死亡这条路径同样**回满**血（%d → %d）" % [health_before_death, _boss.get_health()])
	_target.revive()

	print("[用例 10] 招式表兜底：全表在 CD 时不空放、不卡死")
	_place_target_at(3.0)
	_boss.debug_wake()
	_boss.debug_set_all_cooldowns(30.0)
	var engaged_again: bool = await _wait_for_battle(10.0)
	_check(engaged_again, "再次进入战斗")
	var saw_attack: bool = BossState.is_attack_phase(_boss.get_state())
	var saw_chase: bool = _boss.get_state() == BossState.State.CHASE
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var waited: float = 0.0
	while waited < 1.5:
		await physics_frame
		waited += per_frame
		var state_now: int = _boss.get_state()
		if BossState.is_attack_phase(state_now):
			saw_attack = true
		if state_now == BossState.State.CHASE:
			saw_chase = true
	_check(not saw_attack, "全部招式在 CD 时一帧都不出招（不空放）")
	_check(saw_chase, "没有可用招时留在追击态继续贴身（不卡死）")

	print("[用例 11] 相位切换只发生在决策点")
	_boss.debug_set_all_cooldowns(0.0)
	var phase_at_full: int = _boss.current_phase()
	_check(phase_at_full == 1,
		"血量 %d / %d → 用表 1" % [_boss.get_health(), _boss.get_max_health()])
	var got_attack: bool = await _wait_for_attack_phase(10.0)
	_check(got_attack, "进入招式三段")
	var in_flight: StringName = _boss.current_attack_id()
	_check(in_flight != &"", "当前招式 = %s" % in_flight)
	# 前摇途中把血量打过 50%：招式播到一半**绝对不换表**
	_boss.debug_damage_to(int(_boss.get_max_health() * 0.4))
	_check(_boss.current_attack_id() == in_flight,
		"招式播到一半不换招（仍是 %s）" % in_flight)
	_check(_boss.current_phase() == 2, "血量低于 50% → 下一次决策起用表 2")
	# 换表后必须继续正常出招（不是停在某一招上）
	var damage_before_flip: int = _target.damage_taken
	await _step(3.0)
	_check(_target.damage_taken > damage_before_flip,
		"换表后继续出招（3 秒内又打中 %d 点）" % (_target.damage_taken - damage_before_flip))

	print("[用例 12] 招式三段时序：伤害只发生在判定段，且每招只扣一次")
	_place_target_at(3.0)
	# 逐帧观察一串招式，记录"伤害增长的那一刻，状态是哪一段"。
	# ⚠ 不要写成"检测到招式三段 → 等 telegraph_time 再断言没扣血"：
	#   检测到的那一招可能已经播了一半（上一轮遗留），窗口算不准。
	#   真正要守的不变式是"扣血那一刻的状态"，逐帧看才是准的。
	var hits_in_telegraph: int = 0
	var hits_in_strike: int = 0
	var hits_in_recover: int = 0
	var frame_time: float = 1.0 / float(Engine.physics_ticks_per_second)
	var watched: float = 0.0
	while watched < 5.0:
		var before_frame: int = _target.damage_taken
		await physics_frame
		watched += frame_time
		var gained: int = _target.damage_taken - before_frame
		if gained <= 0:
			continue
		var state_now: int = _boss.get_state()
		if state_now == BossState.State.TELEGRAPH:
			hits_in_telegraph += 1
		elif state_now == BossState.State.STRIKE:
			hits_in_strike += 1
		elif state_now == BossState.State.RECOVER:
			hits_in_recover += 1
	_check(hits_in_telegraph == 0, "前摇期间一次都没扣血（「可躲」成立的前提）")
	_check(hits_in_strike >= 1, "判定段确实扣了血（观测到 %d 次）" % hits_in_strike)
	_check(hits_in_recover == 0, "后摇期间不重复扣血")

	print("[用例 3] 濒死：保底 1 点生命 + 永久无敌")
	_boss.take_damage(999999)
	_check(_boss.get_health() == 1, "血量停在 1（实际 %d）" % _boss.get_health())
	_check(_boss.get_state() == BossState.State.FALLEN, "进入濒死逃走")
	_check(not BossState.can_be_hurt(_boss.get_state()), "濒死期间不可受伤")

	print("[用例 4] 同帧多段伤害（玩家一次挥砍最多查 10 个碰撞体）")
	_boss.take_damage(999999)
	_boss.take_damage(999999)
	_check(_boss.get_health() == 1, "第二、三段伤害被拦下（血量仍为 1）")
	_check(_boss.get_state() == BossState.State.FALLEN, "状态没有被后续伤害改写")

	print("[用例 5] 退场推进世界")
	var gone: bool = await _wait_for_state(BossState.State.GONE, 30.0)
	_check(gone, "走完逃走路径 → 已退场")
	_check(_boss.get_health() == 1, "退场后血量仍是 1（不是死）")
	_check(WorldState.get_flag(Sandworm.NEST_FLAG, 0) == 1, "巢穴坍塌旗标已置 1")
	_check(_boss.is_defeated(), "is_defeated() 为真（存档 defeated 用）")

	print("[回归] Boss 的分组（进了 enemy 组会被 _place_enemies 搬到丛林区）")
	_check(_boss.is_in_group("boss"), "沙虫在 boss 组")
	_check(not _boss.is_in_group("enemy"), "沙虫**不在** enemy 组")

	# 世界旗标是静态的、跨场景存活，测完清掉，免得污染后续测试
	WorldState.reset()


func _case_arena_scene() -> void:
	print("[场景] 沙虫测试场地可加载（顺带校验两个 .tscn 的写法）")
	var packed: PackedScene = load(ARENA_SCENE) as PackedScene
	if packed == null:
		_check(false, "沙虫测试场地加载失败")
		return
	var bosses_before: int = get_nodes_in_group("boss").size()
	var arena: Node = packed.instantiate()
	root.add_child(arena)
	await process_frame
	await process_frame
	var bosses_after: int = get_nodes_in_group("boss").size()
	_check(bosses_after > bosses_before,
		"场地里生成了沙虫（boss 组 %d → %d）" % [bosses_before, bosses_after])
	_check(get_nodes_in_group("player").size() >= 1, "场地里有玩家（player 组）")
	_check(arena.get_node_or_null("Ground") != null, "场地有地面")
	_check(arena.get_node_or_null("Nest/Spawn") != null, "场地有巢穴出生点")
	# rotation_degrees 是 Node3D 的真实属性，写错的话这里会露出来
	var sun: Node3D = arena.get_node_or_null("Sun") as Node3D
	_check(sun != null, "场地有方向光")
	if sun != null:
		_check(absf(sun.rotation.x) > 0.01, "方向光的俯角已生效（rotation_degrees 可用）")
	arena.queue_free()
	await process_frame
