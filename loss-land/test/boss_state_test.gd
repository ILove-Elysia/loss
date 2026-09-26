# test/boss_state_test.gd
# ============================================
# Boss 状态机回归（headless，**不生成地图**）
#
#   godot --headless --path . --script res://test/boss_state_test.gd
#
# 对应用例表：主线设计规格.md 1.10（#1~5）+ 2.9（#8~17）。
# #13 是线上缺陷回归（2026-09-26「被沙虫打死后会报错」）：招式判定把玩家打死时，
#     玩家 died 信号会**同步**把状态机推去 RETREAT、连带丢掉当前招，
#     扣血函数回来后再读 _attack 就是空引用。规格里没有这一条，是修 bug 补的。
# #14 / #15 是 2026-09-26 招式重做（①撕咬 ②吐沙 ③流沙陷落 ④潜行突袭、顺序轮转）补的：
#     #14 受击窗口 = "露出地面"的那几段（③④在地下筹备/突进 ⇒ 前摇打不到）
#     #15 顺序轮转：表 1 = ①②③，表 2 从 ④ 起手（读作 4123）
# #16 / #17 是 2026-09-26 判定形状重做补的：
#     #16 ①撕咬 = **面前扇形**（朝向锁定 ⇒ 绕到背后咬空）
#     #17 ②吐沙 = **弹道**（真的射一发出去；假玩家连碰撞体都没有也能被打中
#         ⇒ 顺带证明命中判定走的是"组名 + 距离"而不是物理查询）
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
var _boss: BossSandwormBase = null
var _target: CharacterBody3D = null
## 用例 13 用：数 attack_landed 发了几次。
## 这一条是**功能性判据**，不是只看"有没有报错"——旧代码在重入处直接中断，
## attack_landed 根本发不出来，所以这个计数能真正把回归钉死。
var _landed_hits: int = 0
## 用例 17 用：其中**沙弹**命中了几次（②吐沙的伤害落在三段之外，靠这条观察它）
var _spit_hits: int = 0


func _on_attack_landed(attack_id: StringName, _damage: int) -> void:
	_landed_hits += 1
	if attack_id == &"sand_spit":
		_spit_hits += 1


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
	_boss = packed.instantiate() as BossSandwormBase
	if _boss == null:
		push_error("Boss 场景的根节点不是 BossSandwormBase（脚本可能解析失败）")
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
		if state == BossSandwormState.State.CHASE or BossSandwormState.is_attack_phase(state):
			return true
		await physics_frame
		elapsed += per_frame
	return false


## 等进入招式三段（前摇/判定/后摇）
func _wait_for_attack_phase(timeout: float) -> bool:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < timeout:
		if BossSandwormState.is_attack_phase(_boss.get_state()):
			return true
		await physics_frame
		elapsed += per_frame
	return false


## 场景里现有的一发沙弹（没有就返回 null）。
## 沙弹是 Boss 在判定段挂到**自己的父节点**下面的（和无人机弹幕同一个落点惯例）。
## ⚠ 它只活零点几秒（3 m / 18 m·s⁻¹ ≈ 0.17 s），所以判断"有没有射出去"必须**每帧扫**，
##   不能等一秒钟再看一眼。
func _find_spit() -> BossSandwormSpit:
	var parent_node: Node = _boss.get_parent()
	if parent_node == null:
		return null
	for child in parent_node.get_children():
		if child is BossSandwormSpit:
			return child as BossSandwormSpit
	return null


## 当前招式是不是"弹道招"——它的伤害本来就落在三段之外（见基类 _on_spit_struck），
## 所以"后摇期间扣血"对它是正常的，对别的招才是违规。
func _current_attack_is_projectile() -> bool:
	var attack: BossSandwormAttack = _boss.current_attack()
	return attack != null and attack.has_projectile()


## 等"某一招的**判定段**"（前摇已经走完、判定刚开始的那一刻）。
##
## ⚠ 为什么不能只等"进入这一招"：招式三段里 TELEGRAPH 最长（①②都是 0.75~0.9 s），
##   而弹道只活零点几秒 —— 在前摇里扫场景必然扫不到"有没有射出去"。
##   （2026-09-26 用例 17 第一版就栽在这：判定段写成 is_attack_phase，
##     扫描窗口整个落在前摇里，弹还没出膛。）
func _wait_for_strike_of(attack_id: StringName, timeout: float) -> bool:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < timeout:
		await physics_frame
		elapsed += per_frame
		if _boss.current_attack_id() == attack_id \
				and _boss.get_state() == BossSandwormState.State.STRIKE:
			return true
	return false


# ============================================
# 用例
# ============================================

func _run_cases() -> void:
	print("============================================")
	print("[用例 1] 触发：靠近 + 停留够时长才登场")

	_place_target_at(60.0)
	await _step(0.4)
	_check(_boss.get_state() == BossSandwormState.State.DORMANT, "玩家在圈外时保持待机")

	_place_target_at(10.0)
	await _step(_boss.trigger_dwell * 0.5)
	_check(_boss.get_state() == BossSandwormState.State.DORMANT,
		"进圈不满 %.1fs 仍是待机" % _boss.trigger_dwell)

	_place_target_at(20.0)
	await _step(_boss.trigger_dwell + 0.4)
	_check(_boss.get_state() == BossSandwormState.State.DORMANT, "中途出圈 → 计时清零、不出场")

	_place_target_at(10.0)
	await _step(_boss.trigger_dwell + 0.15)
	_check(_boss.get_state() == BossSandwormState.State.EMERGING, "停留够时长 → 登场")
	_check(not BossSandwormState.can_be_hurt(_boss.get_state()), "登场期间不可受伤")

	# 挪到所有招式射程外（免得一出场就出招），但**别出领地**：
	# 领地判定量的是「玩家↔巢穴」，站到 leash_radius 外会直接把脱战计时打开。
	_place_target_at(20.0)
	await _step(_boss.emerge_time + 0.2)
	_check(_boss.get_state() == BossSandwormState.State.CHASE, "登场结束 → 追击")

	print("[用例 8] 追击与脱战")
	# 先把所有招式按在 CD 上：这一段要测的是**纯追击位移**与**领地判定**。
	# 一旦让它出招，三段期间的移速按 move_scale 算（①②③ 都是 0 = 完全定身，
	# 只有 ④潜行突袭 会高速突进），位移断言必假失败；
	# ②假玩家要是被咬死，走的就是"玩家死亡"那条分支，
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

	# 2026-09-26 起**潜地追击期间打不到它** —— 受击碰撞体也一起关着。
	# 玩家的输出窗口只剩"露头出招"那几段，见用例 14。
	var health_before_poke: int = _boss.get_health()
	_boss.take_damage(200)
	_check(_boss.get_health() == health_before_poke,
		"潜地追击时打不到它（血量仍 %d / %d）"
			% [_boss.get_health(), _boss.get_max_health()])
	_check(_boss.collision_layer == 0,
		"潜地时受击碰撞体是关的（collision_layer=%d）" % _boss.collision_layer)

	# ① 领地内站多久都不脱战
	_place_target_from_home(_boss.leash_radius * 0.9)
	await _step(_boss.leash_time * 3.0)
	_check(_boss.get_state() == BossSandwormState.State.CHASE,
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
	_check(_boss.get_state() == BossSandwormState.State.CHASE,
		"领地绳生效期间仍在追击态（没卡死）")

	# ③ 回领地内 → 计时清零（顺带验证"回圈就重置"，否则下一步会秒脱战）
	_place_target_from_home(_boss.leash_radius * 0.5)
	await _step(0.5)
	_boss.leash_time = saved_leash_time

	# ④ 出领地：立刻计时，不满 leash_time 不走
	_place_target_from_home(_boss.leash_radius + 12.0)
	await _step(_boss.leash_time * 0.5)
	_check(_boss.get_state() == BossSandwormState.State.CHASE,
		"刚出领地不满 %.1fs 还不脱战" % _boss.leash_time)
	await _step(_boss.leash_time * 0.5 + 0.3)
	_check(_boss.get_state() == BossSandwormState.State.RETREAT, "出领地持续够久 → 脱战逃走")

	print("[用例 2] 脱战回巢：回满血 + 回待机（不推进世界）")
	var got_home: bool = await _wait_for_state(BossSandwormState.State.DORMANT, 30.0)
	_check(got_home, "走回巢穴后回到待机")
	_check(_boss.get_health() == _boss.get_max_health(),
		"回巢后**回满**血（%d / %d）" % [_boss.get_health(), _boss.get_max_health()])
	_check(WorldState.get_flag(Sandworm.NEST_FLAG, 0) == 0,
		"脱战**不写**世界状态（巢穴仍完好）")

	print("[用例 14] 受击窗口：只有露出地面的那几段能被打")
	# 两道判据、两道都断言：
	#   ① take_damage 直接拦（静态谓词 can_be_hurt + 运行时的 _is_surfaced）
	#   ② **受击碰撞体本身关着**（collision_layer = 0）—— 玩家挥砍走的是
	#      intersect_shape，真正让玩家"打不到"的其实是②这一层，不是①。
	_place_target_at(3.0)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	_boss.debug_wake()
	var got_open_telegraph: bool = await _wait_for_state(
		BossSandwormState.State.TELEGRAPH, 15.0)
	_check(got_open_telegraph, "进入第一招的前摇")
	_check(_boss.current_attack_id() == &"bite",
		"表 1 第一招是①撕咬（实际 %s）" % _boss.current_attack_id())
	var open_layer: int = _boss.collision_layer
	_check(open_layer != 0, "①前摇已露头 ⇒ 受击碰撞体打开（layer=%d）" % open_layer)
	var health_before_open: int = _boss.get_health()
	_boss.take_damage(50)
	_check(_boss.get_health() < health_before_open,
		"露头期间可以被打（%d → %d）" % [health_before_open, _boss.get_health()])

	# 按 ①②③ 的轮转次序等到 ③流沙陷落 —— 它的前摇在**地底下**筹备，窗口必须关着
	var reached_quicksand: bool = false
	var waited_buried: float = 0.0
	while waited_buried < 45.0:
		await physics_frame
		waited_buried += 1.0 / float(Engine.physics_ticks_per_second)
		if _boss.current_attack_id() == &"quicksand" and _boss.get_state() == BossSandwormState.State.TELEGRAPH:
			reached_quicksand = true
			break
	_check(reached_quicksand, "按 ①②③ 的顺序轮到了③流沙陷落")
	if reached_quicksand:
		_check(_boss.collision_layer == 0, "③在地下筹备 ⇒ 受击碰撞体关着")
		var health_before_buried: int = _boss.get_health()
		_boss.take_damage(50)
		_check(_boss.get_health() == health_before_buried,
			"③的前摇打不到它（血量仍 %d）" % _boss.get_health())

	print("[用例 15] 顺序轮转：表 1 = ①②③，表 2 从 ④ 起手（4123）")
	# ⚠ 此刻正卡在③的前摇里，所以不能直接抓 current_attack_id()（抓到的是③自己）。
	#   先把血打过 50%（顺带验"招式播到一半不换表"），再等一个**不是③**的招起手。
	_boss.debug_damage_to(int(_boss.get_max_health() * 0.4))
	_check(_boss.current_phase() == 2, "血量跌破 50% → 表 2")
	_check(_boss.current_attack_id() == &"quicksand", "换表不打断正在播的③")
	# 表 2 的顺序写作"④①②③"，而换表时轮转指针会归零 ⇒ 下一招必定是 ④。
	# 这一条断言就把"4123"钉死了。
	var first_of_phase2: StringName = &""
	var waited_next: float = 0.0
	while waited_next < 25.0:
		await physics_frame
		waited_next += 1.0 / float(Engine.physics_ticks_per_second)
		var now_attack: StringName = _boss.current_attack_id()
		if now_attack != &"" and now_attack != &"quicksand":
			first_of_phase2 = now_attack
			break
	_check(first_of_phase2 == &"dash_bite",
		"表 2 第一招是④潜行突袭（实际 %s）" % first_of_phase2)

	# 收尾：让玩家死一次，把 Boss 送回待机（后面的用例都从 DORMANT 起手）
	_target.kill()
	await _step(0.2)
	var home_before_next: bool = await _wait_for_state(BossSandwormState.State.DORMANT, 30.0)
	_check(home_before_next, "收尾：回巢回到待机")
	_target.revive()

	print("[用例 16] ①撕咬是**面前扇形**：朝向锁住后绕到背后就咬不到")
	# 扇形的实现依据是"前摇期间朝向**锁住**"（定身招不前摇转向，见基类 _facing 的说明）：
	# 追击时它朝你，一旦决定咬就定住 —— 于是"贴脸绕背"成了圆圈时代不存在的那条活路。
	# 这一条就是把那条活路钉死：同一招、同样 3 m，从背后发起 ⇒ 必须咬空。
	_place_target_at(3.0)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	_boss.debug_wake()
	var reached_bite: bool = await _wait_for_state(
		BossSandwormState.State.TELEGRAPH, 15.0)
	_check(reached_bite and _boss.current_attack_id() == &"bite",
		"等到①撕咬的前摇（实际 %s）" % _boss.current_attack_id())
	if _boss.current_attack_id() == &"bite":
		# 沿**逻辑朝向的反方向**摆到同样 3 m 处 —— 正好在嘴的反面
		var facing: Vector3 = _boss.facing_direction()
		var behind: Vector3 = _boss.global_position - facing * 3.0
		_target.global_position = Vector3(behind.x, 0.0, behind.z)
		_check(absf(_boss.facing_direction().dot(facing) - 1.0) < 0.001,
			"前摇期间朝向锁住（扇形基准不会中途跟着玩家转）")
		var damage_before_arc: int = _target.damage_taken
		# 前摇剩余 ≤0.9 s + 判定 0.2 s + 后摇 1.0 s ⇒ 1.4 s 内一定还在这一招里，
		# 不会混进下一招的伤害（这是"咬空"能作为断言的前提）
		await _step(1.4)
		_check(_target.damage_taken == damage_before_arc,
			"绕到正背后 ⇒ 这一口咬空（伤害停在 %d）" % damage_before_arc)
	# 把假玩家挪回正面，免得影响后面的用例
	_place_target_at(3.0)
	# 收尾：让玩家死一次，把 Boss 送回待机（用例 17 要从 DORMANT 起手才数得清轮转指针）
	_target.kill()
	await _step(0.2)
	var home_after_arc_test: bool = await _wait_for_state(
		BossSandwormState.State.DORMANT, 30.0)
	_check(home_after_arc_test, "收尾：回巢回到待机")
	_target.revive()

	print("[用例 17] ②吐沙是**弹道**：判定段真射一发出去，且走位能躲")
	_place_target_at(3.0)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	_boss.attack_landed.connect(_on_attack_landed)
	_spit_hits = 0
	_boss.debug_wake()
	# ⚠ 名字不能用 frame_time：用例 12 在同一个函数作用域里已经用了（GDScript 不许重名）
	var spit_frame: float = 1.0 / float(Engine.physics_ticks_per_second)

	# ---- (a) 判定段射出一发**真实弹道** ----
	# 表 1 顺序 ①②③ ⇒ 先等 ①咬完。
	# ⚠ 必须等**判定段**而不是"进入②"：前摇那 0.75 s 里它还什么都没吐出来
	var reached_spit_strike: bool = await _wait_for_strike_of(&"sand_spit", 20.0)
	_check(reached_spit_strike, "轮到②吐沙并走到判定段（表 1 的第二招）")
	# 弹道只活零点几秒 ⇒ 每帧扫场景
	var saw_projectile: bool = false
	var scanned: float = 0.0
	while scanned < 0.6:
		if _find_spit() != null:
			saw_projectile = true
			break
		await physics_frame
		scanned += spit_frame
	_check(saw_projectile, "判定段真的射出了一发弹道（不是就地结算）")
	# 假玩家**连 CollisionShape 都没有**：能被它打中 ⇒ 命中判定走的是"组名 + 平面距离"，
	# 不是物理查询（物理查询在测试里永远扫不到假玩家，这条断言才有意义）
	var spit_hits_at_launch: int = _spit_hits
	await _step(0.5)
	_check(_spit_hits > spit_hits_at_launch,
		"沙弹命中了假玩家（%d → %d 次；假玩家没有碰撞体）"
			% [spit_hits_at_launch, _spit_hits])

	# ---- (b) 走位躲得掉：**出膛之后**横移 ----
	# 沙弹瞄的是**发射那一刻**玩家的位置 ⇒ 之后横移出命中半径（0.9 m）就打空了。
	# 这才是"弹道"相对"落点钉死在地面"的价值所在。
	# ⚠⚠ 必须等它**真的出膛**再动：在出膛前挪位置只是换了个靶子（沙弹会瞄新位置），
	#     2026-09-26 第一版就是这么写错的 —— 断言把正确实现判成了失败。
	var reached_telegraph: bool = false
	var waited_telegraph: float = 0.0
	while waited_telegraph < 25.0:
		await physics_frame
		waited_telegraph += spit_frame
		# 顺手补血：这一轮要等一整圈（②→③→①→② ≈ 9 s），玩家中途血尽会打断序列
		_target.revive()
		if _boss.current_attack_id() == &"sand_spit" \
				and _boss.get_state() == BossSandwormState.State.TELEGRAPH:
			reached_telegraph = true
			break
	_check(reached_telegraph, "等到下一次②的前摇")
	# 判定段那一帧（此刻弹还没出膛）→ 再放一帧（Boss 就在这一帧里发射）→ 然后才动
	var reached_strike: bool = await _wait_for_strike_of(&"sand_spit", 3.0)
	_check(reached_strike, "进入②的判定段")
	await physics_frame
	var spit_hits_before_dodge: int = _spit_hits
	var dodge_anchor: Vector3 = _target.global_position
	_target.global_position = Vector3(dodge_anchor.x + 6.0, 0.0, dodge_anchor.z)
	await _step(0.6)
	_check(_spit_hits == spit_hits_before_dodge,
		"沙弹出膛后横移 6 m ⇒ 这一发打空（命中仍是 %d 次）" % _spit_hits)
	_boss.attack_landed.disconnect(_on_attack_landed)
	# 收尾：把假玩家送回巢穴附近，让 Boss 自己回待机
	_target.revive()
	_target.kill()
	await _step(0.2)
	var home_after_arc: bool = await _wait_for_state(BossSandwormState.State.DORMANT, 30.0)
	_check(home_after_arc, "收尾：回巢回到待机")
	_target.revive()

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
	_check(state_after_death == BossSandwormState.State.RETREAT
			or state_after_death == BossSandwormState.State.DORMANT,
		"玩家一死，Boss 立刻撤离（当前 %s）" % BossSandwormState.label_of(state_after_death))
	var home_again: bool = await _wait_for_state(BossSandwormState.State.DORMANT, 30.0)
	_check(home_again, "回巢后回到待机")
	_check(_boss.get_health() == _boss.get_max_health(),
		"玩家死亡这条路径同样**回满**血（%d → %d）" % [health_before_death, _boss.get_health()])
	_target.revive()

	print("[用例 13] 招式判定把玩家打死：状态机被同步重入也不报错")
	# 复现 2026-09-26 线上报错（用户反馈「被沙虫打死后会报错」）：
	#   SCRIPT ERROR: Invalid access to property or key 'attack_id' on a base
	#   object of type 'Nil'.  at Sandworm._apply_attack_damage
	# 链路：_apply_attack_damage 调 body.take_damage() ⇒ 玩家**同步**发 died 信号
	#   ⇒ Boss._on_player_died ⇒ _start_retreat ⇒ _set_state(RETREAT)
	#   ⇒ 按「离开招式三段就丢掉当前招」把 _attack 置 null，
	#   而 _apply_attack_damage 还没执行完、后面仍要读 _attack.attack_id / .damage。
	# ⚠ 用例 9 用的是**外部** _target.kill()：那条路径不经过招式判定，
	#   所以它一直测不到这个重入。要复现必须让玩家**死在招式判定里**——
	#   把血量压到 1，然后等沙虫的招自己打过来。
	_place_target_at(3.0)
	_boss.debug_wake()
	_boss.debug_set_all_cooldowns(0.0)
	var engaged_reentry: bool = await _wait_for_battle(10.0)
	_check(engaged_reentry, "重新进入战斗")
	_target.revive()
	_target.current_health = 1
	# 挂上信号计数：**被打死的那一击也必须照实上报 attack_landed**。
	# 旧代码在 attack_landed.emit 之前就空引用中断了 ⇒ 这一击永远上报不了，
	# 计数会停在 0 ⇒ 本用例变红（这比"日志里有没有 ERROR"更可靠）。
	_boss.attack_landed.connect(_on_attack_landed)
	_landed_hits = 0
	var damage_before_hit: int = _target.damage_taken
	var hit_landed: bool = false
	var watch_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var watched_hit: float = 0.0
	while watched_hit < 12.0:
		await physics_frame
		watched_hit += watch_frame
		if _target.damage_taken > damage_before_hit:
			hit_landed = true
			break
	_check(hit_landed, "招式判定命中玩家（累计伤害 %d → %d）"
		% [damage_before_hit, _target.damage_taken])
	_check(not _target.is_alive(), "玩家死在这一击里（take_damage 内同步发了 died）")
	_check(_landed_hits >= 1,
		"打死玩家的那一击同样上报了 attack_landed（%d 次）" % _landed_hits)
	# 命中那一刻状态就被重入改走了 —— 这一行要是崩溃，就是本轮修的 bug 复发
	var state_after_hit: int = _boss.get_state()
	_check(state_after_hit == BossSandwormState.State.RETREAT
			or state_after_hit == BossSandwormState.State.DORMANT,
		"被同步重入后落在合法状态（当前 %s）" % BossSandwormState.label_of(state_after_hit))
	_check(_boss.current_attack() == null,
		"被打断的招式已丢弃（current_attack_id = '%s'）" % _boss.current_attack_id())
	await _step(0.3)
	var home_after_hit: bool = await _wait_for_state(BossSandwormState.State.DORMANT, 30.0)
	_check(home_after_hit, "这一击之后照样回巢回待机（没有卡死在招式里）")
	_check(_boss.get_health() == _boss.get_max_health(), "回巢回满血")
	_boss.attack_landed.disconnect(_on_attack_landed)
	_target.revive()

	print("[用例 10] 招式表兜底：全表在 CD 时不空放、不卡死")
	_place_target_at(3.0)
	_boss.debug_wake()
	_boss.debug_set_all_cooldowns(30.0)
	var engaged_again: bool = await _wait_for_battle(10.0)
	_check(engaged_again, "再次进入战斗")
	var saw_attack: bool = BossSandwormState.is_attack_phase(_boss.get_state())
	var saw_chase: bool = _boss.get_state() == BossSandwormState.State.CHASE
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var waited: float = 0.0
	while waited < 1.5:
		await physics_frame
		waited += per_frame
		var state_now: int = _boss.get_state()
		if BossSandwormState.is_attack_phase(state_now):
			saw_attack = true
		if state_now == BossSandwormState.State.CHASE:
			saw_chase = true
	_check(not saw_attack, "全部招式在 CD 时一帧都不出招（不空放）")
	_check(saw_chase, "没有可用招时留在追击态继续贴身（不卡死）")

	print("[用例 11] 相位切换只发生在决策点")
	# 顺带把假玩家补满：血量见底会让 Boss 走脱战分支，后面的断言就没得测了
	_target.revive()
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
	# 同样先补满：这一条要连续观察 5 秒的出手，玩家中途死掉会打断序列
	_target.revive()
	# 逐帧观察一串招式，记录"伤害增长的那一刻，状态是哪一段"。
	# ⚠ 不要写成"检测到招式三段 → 等 telegraph_time 再断言没扣血"：
	#   检测到的那一招可能已经播了一半（上一轮遗留），窗口算不准。
	#   真正要守的不变式是"扣血那一刻的状态"，逐帧看才是准的。
	#
	# ⚠ 2026-09-26 起 ②吐沙改成一发**真弹道**（boss_sandworm_spit.gd）：它的伤害在
	#   三段之外结算（判定段只负责"射出去"）⇒ "后摇期间扣血"对**弹道招是正常的**，
	#   对别的招才是违规。所以这一条拆成两条更准的不变式：
	#     ① 非弹道招绝不在后摇重复扣血；
	#     ② 每一个 attack_id 最多扣一次血（这才是"一次出招只扣一次"的真身）。
	var hits_in_telegraph: int = 0
	var hits_in_strike: int = 0
	var hits_in_recover_from_melee: int = 0
	var repeated_hits: int = 0
	var unhooked_hits: int = 0
	var hit_ids: Dictionary = {}
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
		if state_now == BossSandwormState.State.TELEGRAPH:
			hits_in_telegraph += 1
		elif state_now == BossSandwormState.State.STRIKE:
			hits_in_strike += 1
		elif state_now == BossSandwormState.State.RECOVER:
			if not _current_attack_is_projectile():
				hits_in_recover_from_melee += 1
		var id_now: StringName = _boss.current_attack_id()
		if id_now == &"":
			# 沙弹可能在 Boss 已经回 CHASE 之后才落地 ⇒ 这一击无法归属到某一招，
			# 单独计数（不参与"每招只扣一次"的判定，否则会误报重复）
			unhooked_hits += 1
		else:
			if hit_ids.has(id_now):
				repeated_hits += 1
			hit_ids[id_now] = true
	_check(hits_in_telegraph == 0, "前摇期间一次都没扣血（「可躲」成立的前提）")
	_check(hits_in_strike >= 1, "判定段确实扣了血（观测到 %d 次）" % hits_in_strike)
	_check(hits_in_recover_from_melee == 0,
		"后摇期间**非弹道招**没有重复扣血（弹道招不在此列）")
	_check(repeated_hits == 0,
		"每一招最多扣一次血（重复 %d 次；另有 %d 次落在招式之外、无法归属）"
			% [repeated_hits, unhooked_hits])

	print("[用例 3] 濒死：保底 1 点生命 + 永久无敌")
	# ⚠ 必须等它**露头**再打：潜地期间的 take_damage 会被受击窗口挡掉（见用例 14），
	#   而这一条要走的正是"真刀真枪打上去"的那条路（不是 debug_damage_to）。
	#   判据直接读 collision_layer —— 它和受击窗口是同一个开关，不必另开测试接口。
	var exposed: bool = false
	var waited_exposed: float = 0.0
	while waited_exposed < 25.0:
		await physics_frame
		waited_exposed += 1.0 / float(Engine.physics_ticks_per_second)
		if _boss.collision_layer != 0:
			exposed = true
			break
	_check(exposed, "等到它露头（受击碰撞体打开）")
	_boss.take_damage(999999)
	_check(_boss.get_health() == 1, "血量停在 1（实际 %d）" % _boss.get_health())
	_check(_boss.get_state() == BossSandwormState.State.FALLEN, "进入濒死逃走")
	_check(not BossSandwormState.can_be_hurt(_boss.get_state()), "濒死期间不可受伤")

	print("[用例 4] 同帧多段伤害（玩家一次挥砍最多查 10 个碰撞体）")
	_boss.take_damage(999999)
	_boss.take_damage(999999)
	_check(_boss.get_health() == 1, "第二、三段伤害被拦下（血量仍为 1）")
	_check(_boss.get_state() == BossSandwormState.State.FALLEN, "状态没有被后续伤害改写")

	print("[用例 5] 退场推进世界")
	var gone: bool = await _wait_for_state(BossSandwormState.State.GONE, 30.0)
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
