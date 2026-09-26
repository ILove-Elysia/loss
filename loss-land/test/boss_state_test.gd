# test/boss_state_test.gd
# ============================================
# Boss 状态机回归（headless，**不生成地图**）
#
#   godot --headless --path . --script res://test/boss_state_test.gd
#
# 对应用例表：主线设计规格.md 1.10（#1~5）+ 2.9（#8~18）。
# #13 是线上缺陷回归（2026-09-26「被沙虫打死后会报错」）：招式判定把玩家打死时，
#     玩家 died 信号会**同步**把状态机推去 RETREAT、连带丢掉当前招，
#     扣血函数回来后再读 _attack 就是空引用。规格里没有这一条，是修 bug 补的。
# #14 / #15 是 2026-09-26 招式重做（①撕咬 ②吐沙 ③流沙陷落 ④潜行突袭、顺序轮转）补的：
#     #14 受击窗口 = "露出地面"的那几段（③④在地下筹备/突进 ⇒ 前摇打不到）
#     #15 顺序轮转：表 1 = ①②③，表 2 从 ④ 起手（读作 4123）
# #16 / #17 是 2026-09-26 判定形状重做补的（同日又按用户反馈改过一版）：
#     #16 ①撕咬 = **面前扇形**（朝向锁定 ⇒ 绕到背后咬空）；
#         顺带钉死前摇的**可见信号**：地面上画出同形状、同朝向的预警片 ——
#         用户反馈"撕咬释放时不够明显、难以察觉"，预警片就是那次的落地
#     #17 ②吐沙 = **连吐 4 发的弹道**（判定段真的射出 4 颗；假玩家连碰撞体都没有
#         也能被打中 ⇒ 顺带证明命中判定走的是"组名 + 距离"而不是物理查询。
#         站定不动 ⇒ 4 发全中；判定段里持续横移 ⇒ 4 发全空）
#     #18 ④潜行突袭 = **面前长条矩形**（用户要求"快速靠近玩家然后对长条矩形范围的
#         玩家造成伤害，快速靠近不会造成伤害，长条矩形才会造成伤害"）：
#         站在它的扑击直线上 ⇒ 命中；前摇里**侧移**出走廊 ⇒ 咬空 ——
#         同一个位置若按老的圆形判定（半径 4.0）本该命中，所以这条断言
#         同时钉死了"形状真的是长条"，以及"朝向在起手就定格"（facing_locked）
# #19 是 2026-09-26 按用户反馈"受击范围过大 / 离很远就空放技能"补的：
#     受击体半径 ≤ 0.85（玩家最远够得着的距离 3.3 m → 2.8 m）；
#     玩家在 22 m 外（**超出最远的 ③ 的 20 m**）整段时间一招都不放，走近 1 m 内又立刻出招
#     （2026-09-27 射程改版后 ②③ 变远，原来的 12 m 已不够"远"，所以抬到 22 m）
# #20 是 2026-09-27 按用户要求"完善潜行突袭的快速靠近 + 高速难躲"补的：
#     轮转落到 ④ 时它的**逼近速度**必须 > 玩家满速 5.0（approach_speed = 7.0）⇒
#     玩家全速逃跑也照样被贴上；④ 一放完就自动回到 chase_speed 3.4。
#     判据是"同样 2 s 内它的位移 vs 满速玩家的位移"，两次测量的位置与玩家行为完全相同
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


## 当前招式是不是"弹道招"——它的伤害本来就落在三段之外（见基类 _on_spit_struck），
## 所以"后摇期间扣血"对它是正常的，对别的招才是违规。
## （连吐 4 发之后，"同一个 attack_id 扣了多次"也属于这类 —— 用例 12 靠它排除误报。）
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


## 等"某一招的**前摇**"（判定还没发生、局面还改得动）。
##
## ⚠ 用例 18 必须在**前摇里**摆位：伤害只在判定段的**第一帧**结算一次，
##   等检测到 STRIKE 时已经打完了。
## ⚠ ④的前摇只有 0.35 s（≈21 个物理帧），别在这个函数里加多余的等待。
func _wait_for_telegraph_of(attack_id: StringName, timeout: float) -> bool:
	var per_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	var elapsed: float = 0.0
	while elapsed < timeout:
		await physics_frame
		elapsed += per_frame
		if _boss.current_attack_id() == attack_id \
				and _boss.get_state() == BossSandwormState.State.TELEGRAPH:
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
	# ⚠ 刻意摆在**偏斜方位**（Boss 的 (+X,+Z) 方向 ≈3.1 m）而不是正 +Z：
	#   下面"预警片朝向 = 逻辑朝向"若摆在正 +Z，就会退化成 0.000 vs 0.000 的
	#   **无效断言**（预警片根本不跟着转也照样能过）。
	var skew: Vector3 = _boss.global_position + Vector3(2.2, 0.0, 2.2)
	_target.global_position = Vector3(skew.x, 0.0, skew.z)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	_boss.debug_wake()
	var reached_bite: bool = await _wait_for_state(
		BossSandwormState.State.TELEGRAPH, 15.0)
	_check(reached_bite and _boss.current_attack_id() == &"bite",
		"等到①撕咬的前摇（实际 %s）" % _boss.current_attack_id())
	if _boss.current_attack_id() == &"bite":
		# ---- 前摇的**可见信号**（2026-09-26 用户反馈"撕咬释放时不够明显、难以察觉"）----
		# 地面上必须画出**扇形预警片**，而且它的朝向要和判定**同源**（都是 _facing）——
		# 否则会出现"预警片朝东、判定朝西"这种玩家永远学不会的怪事。
		var facing: Vector3 = _boss.facing_direction()
		var marker: Node3D = _boss.get_node_or_null("ZoneFx") as Node3D
		_check(marker != null and marker.visible,
			"①前摇期间地面上画出了扇形预警片（ZoneFx）")
		if marker != null:
			var expected_yaw: float = atan2(facing.x, facing.z)
			_check(absf(marker.rotation.y - expected_yaw) < 0.01,
				"预警片朝向 = 逻辑朝向（%.3f vs %.3f）" % [marker.rotation.y, expected_yaw])
		# 沿**逻辑朝向的反方向**摆到同样 3 m 处 —— 正好在嘴的反面
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
		_check(marker == null or not marker.visible,
			"判定段一开始预警片就收起（不残留到出完招）")
	# 把假玩家挪回正面，免得影响后面的用例
	_place_target_at(3.0)
	# 收尾：让玩家死一次，把 Boss 送回待机（用例 17 要从 DORMANT 起手才数得清轮转指针）
	_target.kill()
	await _step(0.2)
	var home_after_arc_test: bool = await _wait_for_state(
		BossSandwormState.State.DORMANT, 30.0)
	_check(home_after_arc_test, "收尾：回巢回到待机")
	_target.revive()

	print("[用例 17] ②吐沙是**连吐 4 发的弹道**：真的射出 4 颗，且走位能躲")
	_place_target_at(3.0)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	_boss.attack_landed.connect(_on_attack_landed)
	_spit_hits = 0
	_boss.debug_wake()
	# ⚠ 名字不能用 frame_time：用例 12 在同一个函数作用域里已经用了（GDScript 不许重名）
	var spit_frame: float = 1.0 / float(Engine.physics_ticks_per_second)

	# ---- (a) 判定段**连吐 4 发**，且每一发都能命中 ----
	# 表 1 顺序 ①②③ ⇒ 先等 ①咬完。
	# ⚠ 必须等**判定段**而不是"进入②"：前摇那 0.75 s 里它还什么都没吐出来
	var reached_spit_strike: bool = await _wait_for_strike_of(&"sand_spit", 20.0)
	_check(reached_spit_strike, "轮到②吐沙并走到判定段（表 1 的第二招）")
	# 一边数"场上出现过几个沙弹实例"、一边让假玩家**站定不动**（这样才能 4 发全吃）。
	# 沙弹只活零点几秒 ⇒ 必须每帧扫，并用 instance_id 去重。
	var seen_shots: Dictionary = {}
	var hits_at_launch: int = _spit_hits
	var scanned: float = 0.0
	while scanned < 1.8:
		for child in _boss.get_parent().get_children():
			if child is BossSandwormSpit:
				seen_shots[child.get_instance_id()] = true
		await physics_frame
		scanned += spit_frame
	_check(seen_shots.size() == 4,
		"判定段真的**连吐了 4 发**沙弹（不是就地结算、也不是只吐一发）—— 观测到 %d 个"
			% seen_shots.size())
	# 假玩家**连 CollisionShape 都没有**：能被它打中 ⇒ 命中判定走的是"组名 + 平面距离"，
	# 不是物理查询（物理查询在测试里永远扫不到假玩家，这条断言才有意义）
	_check(_spit_hits - hits_at_launch == 4,
		"站定不动 ⇒ 4 发**全中**（命中 %d → %d 次；假玩家没有碰撞体）"
			% [hits_at_launch, _spit_hits])

	# ---- (b) 走位躲得掉：判定段期间**持续横移** ----
	# 沙弹瞄的是**发射那一刻**玩家的位置 ⇒ 之后横移出命中半径（0.9 m）就打空了。
	# 这才是"弹道"相对"落点钉死在地面"的价值所在。
	# ⚠⚠ 连发招要**连着躲**：站着不动挡不住第 2~4 发（每一发都重新瞄你当时的位置）。
	#   3 m 处飞行只要 0.17 s、横移 0.85 m < 0.9 ⇒ 贴脸必吃满；所以先在前摇里
	#   把假玩家退到 10 m 外（飞行 0.56 s，够挪出 2.8 m ≫ 0.9）。
	var reached_telegraph: bool = false
	var waited_telegraph: float = 0.0
	while waited_telegraph < 30.0:
		await physics_frame
		waited_telegraph += spit_frame
		# 顺手补血：这一轮要等一整圈（②→③→①→② ≈ 9 s），玩家中途血尽会打断序列
		_target.revive()
		if _boss.current_attack_id() == &"sand_spit" \
				and _boss.get_state() == BossSandwormState.State.TELEGRAPH:
			reached_telegraph = true
			break
	_check(reached_telegraph, "等到下一次②的前摇")
	# 吐沙是**定身招**（move_scale = 0）⇒ 前摇里它不会追过来，趁这段时间把假玩家退到 10 m 外
	var stand: Vector3 = _boss.global_position
	var away: Vector3 = stand - _target.global_position
	away.y = 0.0
	if away.length() < 0.01:
		away = Vector3.FORWARD
	away = away.normalized()
	_target.global_position = stand + away * 10.0
	# 横移方向取"垂直于它↔你的连线"（沙弹是沿着这条连线飞过来的）
	var lateral: Vector3 = Vector3(-away.z, 0.0, away.x)
	var reached_strike: bool = await _wait_for_strike_of(&"sand_spit", 3.0)
	_check(reached_strike, "进入②的判定段（沙弹开始出膛）")
	var hits_before_dodge: int = _spit_hits
	var dodged: float = 0.0
	while dodged < 1.4:
		var p: Vector3 = _target.global_position
		_target.global_position = Vector3(
			p.x + lateral.x * 5.0 * spit_frame, 0.0,
			p.z + lateral.z * 5.0 * spit_frame)
		await physics_frame
		dodged += spit_frame
	_check(_spit_hits == hits_before_dodge,
		"判定段里**持续横移**（满速 5 m/s）⇒ 4 发全部打空（命中仍是 %d 次）" % _spit_hits)
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
	var repeat_melee: int = 0
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
			# ⚠ 2026-09-26 起 ②吐沙是**连吐 4 发**的弹道招 ⇒ 同一个 attack_id 会命中多次，
			#   那是它的机制、不是"重复扣血"。所以"每招只扣一次"这条不变式只对
			#   **就地判定**的招成立（区域招的扣血次数由圈内还有几个单位决定，同样不在此列）。
			if hit_ids.has(id_now) and not _current_attack_is_projectile():
				repeat_melee += 1
			hit_ids[id_now] = true
	_check(hits_in_telegraph == 0, "前摇期间一次都没扣血（「可躲」成立的前提）")
	_check(hits_in_strike >= 1, "判定段确实扣了血（观测到 %d 次）" % hits_in_strike)
	_check(hits_in_recover_from_melee == 0,
		"后摇期间**非弹道招**没有重复扣血（弹道招不在此列）")
	_check(repeat_melee == 0,
		"**就地判定**的招每次出招只扣一次血（重复 %d 次；另有 %d 次落在招式之外、无法归属）"
			% [repeat_melee, unhooked_hits])

	print("[用例 18] ④潜行突袭是**长条矩形**：站在扑击直线上才咬得到，侧移就落空")
	# 血量已经低于 50%（用例 11 打的）⇒ 表 2 ⇒ 轮转读作 ④①②③
	_place_target_at(5.0)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	# ⚠ 名字不能撞同作用域已有的：frame_time（用例 12）/ spit_frame（用例 17）/
	#   watch_frame（用例 13）。GDScript 重名会让**整个脚本解析失败**。
	var dash_frame: float = 1.0 / float(Engine.physics_ticks_per_second)

	# ---- (a) 站在它的扑击直线上 ⇒ 破土那一口咬中 ----
	var reached_dash: bool = await _wait_for_telegraph_of(&"dash_bite", 25.0)
	_check(reached_dash, "轮到④潜行突袭并进入前摇（表 2 首招）")
	var damage_before_dash: int = _target.damage_taken
	# 0.35 前摇 + 0.2 判定 ⇒ 1.0 s 足够看到那一口结算
	await _step(1.0)
	_check(_target.damage_taken > damage_before_dash,
		"站在它的扑击直线上 ⇒ 破土那一口咬中（累计伤害 %d → %d）"
			% [damage_before_dash, _target.damage_taken])

	# ---- (b) 前摇里**侧移**让出走廊 ⇒ 这一口咬空 ----
	# 摆位刻意选在"老圆形判定会命中、长条不会"的临界点上：
	#   沿向 3.0 m（≤ rect_length 6.0）＋ 侧向 2.5 m（> 半宽 1.3）
	#   ⇒ 到它的距离 ≈ 3.9 m < 老的判定半径 4.0 —— 若判定还是圆形，这一口必然中。
	# 所以这条断言同时钉死了两件事：形状**真的是长条**、且朝向**真的定格了**
	#   （facing_locked 若失效，它会扭头对准新位置 ⇒ 侧移等于没躲 ⇒ 红灯）。
	# ⚠ 摆位必须在前摇里做完：判定段第一帧就结算，那时再动已经晚了。
	_place_target_at(5.0)
	var found_dash_telegraph: bool = false
	var waited_dash: float = 0.0
	while waited_dash < 30.0:
		await physics_frame
		waited_dash += dash_frame
		# 顺手补血：这一轮要等一整圈（④→①→②→③ ≈ 9.6 s）
		_target.revive()
		if _boss.current_attack_id() == &"dash_bite" \
				and _boss.get_state() == BossSandwormState.State.TELEGRAPH:
			found_dash_telegraph = true
			break
	_check(found_dash_telegraph, "等到下一轮④的前摇")
	var lock_dir: Vector3 = _boss.facing_direction()
	var stand_pos: Vector3 = _boss.global_position
	var lateral_axis: Vector3 = Vector3(-lock_dir.z, 0.0, lock_dir.x)
	_target.global_position = Vector3(
		stand_pos.x + lock_dir.x * 3.0 + lateral_axis.x * 2.5, 0.0,
		stand_pos.z + lock_dir.z * 3.0 + lateral_axis.z * 2.5)
	# 摆完位要**再过一帧**才断言朝向：_physics_process 在这一帧里才有机会扭头，
	# 摆位当帧就断言等于在测"摆位之前"的朝向，永远绿灯（同用例 16 踩过的退化成常量）
	await physics_frame
	_check(absf(_boss.facing_direction().dot(lock_dir) - 1.0) < 0.001,
		"前摇期间朝向锁住（facing_locked ⇒ 它不会扭头对准新位置）")
	var damage_before_dash_dodge: int = _target.damage_taken
	await _step(1.0)
	_check(_target.damage_taken == damage_before_dash_dodge,
		"侧移 2.5 m 让出长条 ⇒ 这一口咬空（伤害停在 %d；按圆形半径 4.0 本该命中）"
			% damage_before_dash_dodge)
	print("[用例 19] 受击体尺寸 + 出手距离（2026-09-26 用户反馈）")
	# 反馈原文：「1.boss受击范围过大，玩家离很远就能打到不合理
	#           2.boss应该靠近玩家后才开始放技能而不是离很远就开始空放技能」
	#
	# ---- ① 受击体尺寸 ----
	# 玩家挥砍是"以自己为圆心、半径 attack_range(2.0) 的圆柱"（physics.gd），
	# 所以"玩家能打到它"的圆心距 = 2.0 + 沙虫受击体半径。原值 r1.3 ⇒ 算出来 3.3 m，
	# 比史莱姆（2.0 + 0.335 = 2.34 m）多出整整 1 m —— 这就是"离很远就能打到"。
	# ⚠ 这条断言**故意钉死具体数值**：它是用户点名的需求，不是随手调的平衡值。
	#   半径再收小不会出问题；放大就会亮红灯（那时是需求变了，就该来改这一行）。
	var body_shape: CollisionShape3D = _boss.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var body_cyl: CylinderShape3D = null
	if body_shape != null:
		body_cyl = body_shape.shape as CylinderShape3D
	_check(body_cyl != null, "沙虫的受击体是一个圆柱（CollisionShape3D）")
	if body_cyl != null:
		_check(body_cyl.radius <= 0.85,
			"受击体半径 %.2f ≤ 0.85 ⇒ 玩家最远 ≈ %.1f m 才够得着（原 r1.3 ⇒ 3.3 m）"
				% [body_cyl.radius, 2.0 + body_cyl.radius])

	# ---- ② 出手距离：玩家在**射程外**时只潜行逼近、不放技能 ----
	# ⚠ 2026-09-27 用户把射程改成 ①1.0 / ②15.0 / ③20.0 / ④0.5 之后，"远处"必须取到
	#   **超过最长射程（③ 的 20 m）**才成立 —— 所以这里的 12 m 换成了 22 m：
	#   · 22 > 20 ⇒ 无论轮转指针停在哪一招，它都够不着（轮转第一条规则：够不着就
	#     返回 null 且不推进指针）⇒ 只能继续潜行过来；
	#   · 22 < leash_radius(24) ⇒ 不会先触发领地判定的 RETREAT。
	#   （老版本敢用 12 m 是因为当时四招都 ≤ 10；现在 ②③ 变远，12 m 已落在 ② 的射程里。）
	#
	# ⚠ 这一段的观测量是"有没有进过招式三段"，所以必须**同时把两边都钉住**：
	#   · 假玩家每帧摆回离巢穴 out_of_range 米 —— 否则它一逼近就进了射程；
	#   · 沙虫每帧按回巢穴 —— 否则它一路追着"永远在前方"的玩家跑，
	#     跑出 leash_radius(24 m) 之后**领地判定会先触发 RETREAT**，测的就不是出手距离了。
	#   两边都钉住 ⇒ 距离恒定，决策规则被单独拎出来测，没有位移的干扰。
	var park: Vector3 = _boss.home_position()
	# 22 m：**超过全表最长的 ③（20 m）**，又小于 leash_radius(24) —— 两头都留了余量
	var out_of_range: float = 22.0
	var far_frame: float = 1.0 / float(Engine.physics_ticks_per_second)
	_target.revive()
	_boss.debug_set_all_cooldowns(0.0)
	# 起手先把上一轮残留的招式播完（用例 18 结束时它可能还在三段里），
	# 否则"整段不许出招"会被那半招误报。
	var settled: bool = false
	var waited_settle: float = 0.0
	while waited_settle < 8.0:
		_boss.global_position = Vector3(park.x, _boss.global_position.y, park.z)
		_target.global_position = Vector3(park.x, 0.0, park.z + out_of_range)
		await physics_frame
		waited_settle += far_frame
		_target.revive()
		if _boss.get_state() == BossSandwormState.State.CHASE \
				and _boss.current_attack() == null:
			settled = true
			break
	_check(settled, "玩家退到 %.0f m 外（射程外）→ 它收招回到追击态" % out_of_range)
	var saw_attack_far: bool = false
	var saw_chase_far: bool = false
	var held_far: float = 0.0
	while held_far < 2.0:
		_boss.global_position = Vector3(park.x, _boss.global_position.y, park.z)
		_target.global_position = Vector3(park.x, 0.0, park.z + out_of_range)
		await physics_frame
		held_far += far_frame
		_target.revive()
		var state_far: int = _boss.get_state()
		if BossSandwormState.is_attack_phase(state_far):
			saw_attack_far = true
		if state_far == BossSandwormState.State.CHASE:
			saw_chase_far = true
	_check(saw_chase_far, "玩家在 %.0f m 外 ⇒ 它保持追击态（不是原地发呆）" % out_of_range)
	_check(not saw_attack_far,
		"玩家在 %.0f m 外 ⇒ 整整 2 s 一次招都不放（最远的 ③ 是 20 m，四招全部够不着）"
			% out_of_range)
	# 反向对照：走进射程**必须**能出招 —— 否则上面那两条可能只是"它整体哑了"。
	# 表 1 的表头 ① 现在要 1.0 m ⇒ 这里直接摆进 1 m 内，免得断言里混进
	# "它还要先追过来"那段与本需求无关的时间。
	_place_target_at(0.9)
	var fired_when_close: bool = await _wait_for_attack_phase(6.0)
	_check(fired_when_close, "贴近到 1 m 内 ⇒ 立刻恢复出招（出手距离是上界，不是把招式关掉）")
	_place_target_at(3.0)
	_target.revive()

	print("[用例 20] ④潜行突袭的**逼近加速**：要放它时比满速玩家还快，放完自动恢复")
	# 需求原文（2026-09-27）：「完善"潜行突袭"的快速靠近 + 高速难躲。
	#   如果要释放潜行突袭，则沙虫的速度大幅增加（一定要大于玩家的默认速度），
	#   直到释放出"潜行突袭"后才恢复原来的速度」。
	#
	# ⚠ 这一条**不靠读内部字段**判"有没有加速"，而是直接量位移再除以时间：
	#   标尺借玩家满速（5.0 m/s），语义就是那句话本身 ——
	#     · 要放 ④ 时：同样 2 s，它跑得比"全速逃跑的玩家"还远 ⇒ 追得上（跑不掉）；
	#     · ④ 放完之后：同样 2 s，它跑得比玩家满速还短 ⇒ 恢复成原来那个追不上的速度。
	#   两次测量的**位置与玩家行为完全相同**，唯一差别只有"轮转轮到哪一招"⇒
	#   位移差只可能来自 approach_speed（比"读一下配置字段"硬得多）。
	#
	# ⚠ 玩家必须**真的在跑**（每帧沿 +Z 推 5.0 × dt）：站着不动的玩家区分不出 7.0 与 3.4，
	#   那样断言就退化成"测它会不会动"了（用例 16 踩过同款"退化成常量"）。
	# ⚠ 起始间距 10 m：跑满 2 s 玩家到 20 m，仍 < leash_radius(24) ⇒ 不会被领地判定
	#   半路打断成 RETREAT（那会让位移变成"回巢"，量到的就不是逼近速度了）。
	var nest: Vector3 = _boss.home_position()
	var run_speed: float = 5.0  # 玩家默认满速（physics.gd）
	var sample: float = 2.0
	var chase_frame: float = 1.0 / float(Engine.physics_ticks_per_second)

	# ---- 先把局面重置成"轮转指针必定停在 ④"----
	# ⚠ 为什么必须重置：指针只在**相位切换**时归零，而用例 18/19 已经把它推到了 ②③ 那一段
	#   ⇒ 直接量会量到别的招（第一版就栽在这：读到的 upcoming 是 ③，它 10 m 处够得着、
	#   于是当场起手定身招，位移 0）。
	# 做法走**真实流程**、不戳内部字段，和用例 15 钉"4123"用的是同一条规则：
	#   ① 让玩家死一次 ⇒ 它脱战回巢（血回满 ⇒ 相位回到表 1）；
	#   ② 重新触发登场、以**满血**在 CHASE 里过一帧 ⇒ _sync_rotation_with_phase 把指针归零
	#      （这一步不能省：_phase_cache 只在决策点更新，跳过它就一直是 2、根本不触发归零）；
	#   ③ 再把血打过 50% ⇒ 相位 1 → 2 ⇒ **再次**归零 ⇒ 下一招必定是 ④。
	_target.kill()
	await _step(0.2)
	var reset_home: bool = await _wait_for_state(BossSandwormState.State.DORMANT, 30.0)
	_check(reset_home, "重置：玩家死亡 → 它回巢回到待机（血回满 ⇒ 相位回表 1）")
	_target.revive()
	_target.global_position = Vector3(nest.x, 0.0, nest.z + 10.0)
	# 10 m 在 trigger_radius(14) 内 ⇒ 停留够时长就会重新登场
	var reengaged: bool = await _wait_for_state(BossSandwormState.State.CHASE, 30.0)
	_check(reengaged, "重置：重新登场（满血 ⇒ 表 1、轮转指针归零）")
	_boss.debug_damage_to(int(_boss.get_max_health() * 0.4))
	_check(_boss.current_phase() == 2,
		"重置：血量跌破 50% ⇒ 表 2（换表时指针归零 ⇒ 指向 ④）")

	# ---- (a) 轮到 ④ ⇒ 逼近加速，追得上满速逃跑的玩家 ----
	_boss.global_position = Vector3(nest.x, _boss.global_position.y, nest.z)
	_target.global_position = Vector3(nest.x, 0.0, nest.z + 10.0)
	await physics_frame
	var upcoming: BossSandwormAttack = _boss.upcoming_attack()
	var upcoming_id: StringName = &"<无>"
	if upcoming != null:
		upcoming_id = upcoming.attack_id
	_check(upcoming_id == &"dash_bite",
		"轮转接下来要放的是 ④潜行突袭（表 2 表头；此刻是 %s）" % upcoming_id)
	if upcoming != null:
		_check(upcoming.approach_speed > run_speed,
			"④ 的逼近速度 %.1f > 玩家满速 %.1f（用户要求：一定要大于玩家的默认速度）"
				% [upcoming.approach_speed, run_speed])
	var charge_start: Vector3 = _boss.global_position
	var gap_start: float = _boss_distance()
	var ran_charge: float = 0.0
	while ran_charge < sample:
		_target.global_position += Vector3(0.0, 0.0, run_speed * chase_frame)
		await physics_frame
		ran_charge += chase_frame
	var charge_delta: Vector3 = _boss.global_position - charge_start
	var charge_moved: float = sqrt(charge_delta.x * charge_delta.x
		+ charge_delta.z * charge_delta.z)
	var gap_end: float = _boss_distance()
	_check(charge_moved > run_speed * sample,
		"轮到 ④ 时 %.0f s 内它位移 %.1f m > 满速玩家的 %.1f m ⇒ 追得上"
			% [sample, charge_moved, run_speed * sample])
	_check(gap_end < gap_start,
		"玩家全速逃跑时距离仍在缩小（%.1f m → %.1f m）" % [gap_start, gap_end])

	# ---- 让它把 ④ 放出来（轮转随之推进到 ①）----
	_place_target_at(3.0)
	var fired: bool = false
	var waited_fire: float = 0.0
	while waited_fire < 20.0:
		await physics_frame
		waited_fire += chase_frame
		_target.revive()
		if _boss.current_attack_id() == &"dash_bite" \
				and _boss.get_state() == BossSandwormState.State.STRIKE:
			fired = true
			break
	_check(fired, "加速之后它追上来、把 ④ 放了出来（进入判定段）")
	var dash_finished: bool = false
	var waited_finish: float = 0.0
	while waited_finish < 10.0:
		await physics_frame
		waited_finish += chase_frame
		_target.revive()
		if _boss.current_attack_id() != &"dash_bite":
			dash_finished = true
			break
	_check(dash_finished, "④ 走完三段 ⇒ 轮转推进到下一招")

	# ---- (b) ④ 已放完 ⇒ 逼近速度恢复 ----
	# 摆位与 (a) **一模一样**（Boss 回巢穴、玩家 10 m 外），玩家行为也一样，
	# 唯一的差别是轮转指针已经走到 ① ⇒ 这正是"释放之后恢复原来的速度"的对照实验。
	_boss.global_position = Vector3(nest.x, _boss.global_position.y, nest.z)
	_target.global_position = Vector3(nest.x, 0.0, nest.z + 10.0)
	var plain_chase: bool = false
	var waited_plain: float = 0.0
	while waited_plain < 15.0:
		await physics_frame
		waited_plain += chase_frame
		_target.revive()
		if _boss.get_state() == BossSandwormState.State.CHASE \
				and _boss.current_attack() == null:
			plain_chase = true
			break
	_check(plain_chase, "④ 之后回到纯追击态（10 m 外没有招够得着 ⇒ 不会立刻又起手）")
	var upcoming_after: BossSandwormAttack = _boss.upcoming_attack()
	var after_id: StringName = &"<无>"
	if upcoming_after != null:
		after_id = upcoming_after.attack_id
	_check(after_id != &"dash_bite",
		"放完 ④ 之后轮转已经走到下一招（此刻是 %s）⇒ 不该再加速" % after_id)
	var plain_start: Vector3 = _boss.global_position
	var ran_plain: float = 0.0
	while ran_plain < sample:
		_target.global_position += Vector3(0.0, 0.0, run_speed * chase_frame)
		await physics_frame
		ran_plain += chase_frame
	var plain_delta: Vector3 = _boss.global_position - plain_start
	var plain_moved: float = sqrt(plain_delta.x * plain_delta.x
		+ plain_delta.z * plain_delta.z)
	_check(plain_moved < run_speed * sample,
		"放完 ④ 之后同样 %.0f s 只位移 %.1f m < 满速玩家的 %.1f m ⇒ 恢复原来的速度"
			% [sample, plain_moved, run_speed * sample])
	_check(plain_moved < charge_moved - 3.0,
		"放完 ④ 之后确实慢下来（%.1f m vs 轮到 ④ 时的 %.1f m）"
			% [plain_moved, charge_moved])
	# 收尾摆位：贴着 0.9 m ⇒ ① 够得着（它的 max_range 是 1.0）⇒ 会起手 ⇒ 顺带把
	# "露头才开受击碰撞体"交给下一个用例（用例 3 要等它露头才能真刀真枪地打）。
	# ⚠ 摆 3 m 不行：指针这时停在 ①，而"够不着就 return null 且**不推进指针**"
	#   ⇒ 它会一步都不出招，用例 3 干等 25 s。
	_place_target_at(0.9)
	_target.revive()

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
