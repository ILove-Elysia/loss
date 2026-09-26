# script/ai/enemy/boss/sandworm/boss_sandworm_base.gd
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
#   4. **受击窗口 = "露出地面"的那一段**（露头之前摇 → 判定 → 后摇；钻回地底就关）。
#      它平时在地下潜行，受击碰撞体也一起关着 ⇒ 玩家**看得见但打不到**。
#      判据只有 _is_surfaced() 一处，碰撞层开关与占位美术的埋深都从它派生 ——
#      三者共用一个判据，就不会出现"看着在地上却打不到"这种自相矛盾。
#
# 与现有系统的边界：
#   - **不进 "enemy" 组**，用 "boss" 组：
#       · map_generator_3d._place_enemies() 会把组 "enemy" 的节点全搬到丛林区；
#       · save_manager / world_streamer 对 "enemy" 组用的是"存档里没有＝已击杀"，
#         这个语义对 Boss 是**反的**（Boss 是逃走，不是死）。
#   - 存档走独立的 world.bosses 段（第 2 步做），不碰 _collect_enemies/_apply_enemies。
# ============================================

class_name BossSandwormBase
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
## 相位分界线：血量比例 > 这个值用表 1，否则用表 2（规格 2.4）。
## ⚠ 早先沙虫脚本里放过一个同名的 `const PHASE_LINE`，但本函数当时把 0.5 写死了
##   ⇒ 改那个 const 根本不生效（已删）。现在它是唯一的真值来源。
@export var phase_line: float = 0.5
## 追击速度。标尺：玩家满速 5.0（饥饿 ×0.9、低电量 ×0.7 ⇒ 最低 3.15）、史莱姆 1.5。
## 2026-09-25 从 4.0 降到 3.4：4.0 只比满速玩家慢 1 m/s，**低电量时还比玩家快**，
## 玩家反馈"逃不掉"。3.4 让满速能明显甩开，虚弱状态仍甩不开（脱身靠领地判定）。
@export var chase_speed: float = 3.4
## 回巢/逃走时的移速倍率（逃走过程也要能被玩家看见）
@export var return_speed_scale: float = 1.4

@export_group("触发与脱战")
## 玩家进到多近算"靠近巢穴"
@export var trigger_radius: float = 14.0
## 要在圈里待够多久才登场（中途出圈计时清零）
@export var trigger_dwell: float = 1.5
## **领地半径**（圆心＝巢穴）：玩家跑出这个圈 = 把 Boss 从它的领地里拉出去了。
## ⚠ 基准是「玩家 ↔ **巢穴**」，不是「玩家 ↔ Boss」——理由见 _check_leash()。
## 24 m：明显大于触发半径 14 m（在圈内正常打不会误触发），从巢穴边再跑 10 m 就能脱身。
@export var leash_radius: float = 24.0
## 离开领地持续多久才真脱战（防止在边界反复横跳刷"回满血"）
@export var leash_time: float = 1.5
## 判定"已经到巢穴了"的半径
@export var arrive_radius: float = 1.2

@export_group("演出")
## 登场时长（占位美术用：钻出沙面）
@export var emerge_time: float = 1.6
## 待机时埋在"地下"多深（占位美术的视觉表达）
@export var buried_depth: float = 3.2
## **潜地移动**时露头的深度（占位美术）。比 buried_depth 浅得多 ⇒ 地面上露出一截背脊。
## 追击/逃走的全过程玩家都看得见它往哪跑，但受击碰撞体是关的 ——
## 这就是"看得见、打不到"的那半边，也是玩家能预判它从哪个方向冒头的前提。
@export var travel_depth: float = 1.9
## 沉下去 / 浮上来的速度（冒头与钻回的手感都由它决定，6.0 ⇒ 约 0.3 s 完成）
@export var rise_speed: float = 6.0

@export_group("占位外观")
## 常态体色。⚠ 占位材质走 UNSHADED ⇒ 这几个色值是**原样输出**的，
## 挑色时按"屏幕上想看到什么"直接定，不用再考虑光照会被打亮多少。
## 刻意选**深沙褐**：地形瓦片色普遍偏亮（草原 0.70,0.85,0.50 / 沙滩 0.98,0.92,0.68
## / 沙地 0.95,0.88,0.45），体色压暗一档才能在**任何**地形上都看得出轮廓。
## 原先的 (0.82,0.70,0.42) 和沙地/沙滩瓦片色几乎一样，就算不打爆也糊在一起。
@export var body_color: Color = Color(0.58, 0.45, 0.26)
## 受击闪光色。刻意用**暖红**而不是近白：原先的 (1.0,0.86,0.86) 是近白色，
## 一旦环境光把体色打爆成白，受击就完全看不出来（2026-09-26）
@export var hurt_color: Color = Color(1.0, 0.66, 0.52)
@export var fallen_color: Color = Color(0.52, 0.50, 0.55)
## 下颚比体色暗多少（0~1）。暗一档才一眼看得出头朝哪边
@export var jaw_darken: float = 0.32
@export var hurt_flash_time: float = 0.12

@export_group("调试")
@export var debug_enabled: bool = false

# ============================================
# 运行时状态
# ============================================
var _state: int = BossSandwormState.State.DORMANT
var _health: int = 0
var _untouchable: bool = false
var _home: Vector3 = Vector3.ZERO
var _gravity: float = 9.8
var _state_time: float = 0.0
var _trigger_timer: float = 0.0
var _leash_timer: float = 0.0
var _move_dir: Vector3 = Vector3.ZERO
var _attack: BossSandwormAttack = null
var _attack_index: int = -1
var _strike_done: bool = false
## 本招的判定圆心。aims_at_player 的招在**施放那一刻**取一次玩家位置并记住
## （每帧重算的话圈会跟着玩家跑，变成必中）；其余招只在判定时读当前位置。
var _strike_origin: Vector3 = Vector3.ZERO
## 顺序轮转的"下一招"指针（表 1：①②③；表 2：④①②③）
var _rotation_index: int = 0
## 上一帧的表号（1/2）。换表要把轮转指针归零，否则表 2 的顺序读不出"4123"
var _phase_cache: int = 1
## "露头时可被打"的碰撞层。**从场景读**（sandworm.tscn 写 8 = layer 4），
## 不硬编码 —— 免得场景和脚本各写一份、改漏一处。
var _hit_layer: int = 0
var _cooldowns: Dictionary = {}
var _phase1_attacks: Array[BossSandwormAttack] = []
var _phase2_attacks: Array[BossSandwormAttack] = []
var _player_cache: Node3D = null
var _died_hooked: bool = false
var _visual: Node3D = null
var _body_material: StandardMaterial3D = null
var _jaw_material: StandardMaterial3D = null
var _hurt_flash: float = 0.0
var _debug_timer: float = 0.0
var _gone_emitted: bool = false
## 地面预警圈（流沙 / 吐沙落点）。**top_level = true** 挂在世界坐标上，
## 不跟着沙虫走 —— 否则圈会追着玩家跑，等于取消了"跑出去就能躲"。
var _zone_fx: Node3D = null
var _zone_mesh: CylinderMesh = null
var _zone_mat: StandardMaterial3D = null

# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	_home = global_position
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_health = maxi(max_health, 1)
	# 场景里配的层 = "露头时可被打"的层，记下来；埋起来时置 0，露头时还原
	_hit_layer = collision_layer
	if _hit_layer == 0:
		push_warning("[%s] 场景的 collision_layer 是 0 ⇒ 它永远打不到也打不着。"
			% display_name)
	# 另立 "boss" 组，理由见文件头
	add_to_group("boss")
	_build_attacks()
	_reset_cooldowns()
	_phase_cache = current_phase()
	_visual = get_node_or_null("Visual") as Node3D
	_setup_placeholder_material()
	_state = BossSandwormState.State.DORMANT
	_state_time = 0.0
	_refresh_body_color()
	_refresh_hitbox()
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
		BossSandwormState.State.DORMANT:
			_process_dormant(delta)
		BossSandwormState.State.EMERGING:
			_process_emerging()
		BossSandwormState.State.CHASE:
			_process_chase(delta)
		BossSandwormState.State.TELEGRAPH, BossSandwormState.State.STRIKE, BossSandwormState.State.RECOVER:
			_process_attack(delta)
		BossSandwormState.State.RETREAT, BossSandwormState.State.FALLEN:
			_process_going_home()
		_:
			_move_dir = Vector3.ZERO

	var speed: float = _movement_speed()
	# 领地绳：追击/出招期间不许迈出领地（回家路径不受限，否则它永远回不了巢）
	_move_dir = _clamped_move_dir(_move_dir, speed, delta)
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
	if not BossSandwormState.is_attack_phase(new_state):
		_attack = null
		_hide_zone()
	_refresh_body_color()
	# 受击碰撞体跟着状态走：露头才开（唯一入口，见 _refresh_hitbox）
	_refresh_hitbox()
	state_changed.emit(previous, new_state)


## 此刻是否"露出地面" —— 受击窗口、碰撞层开关、占位美术的埋深都从这一个判据派生。
##   · 冒头前摇（surfaces_in_telegraph = true 的招）→ 是
##   · 判定 / 后摇 → 是（"钻回地底"发生在退出 RECOVER 的那一帧）
##   · 潜地移动 / 待机 / 登场 / 逃走 / ③④的地下调度 → 否
##
## ⚠ ③流沙陷落 与 ④潜行突袭 的 state 也是 TELEGRAPH，但它们**在地下动作**
##   （布置流沙 / 高速突进），所以前摇期间玩家打不到它 ——
##   这两招的解法是走位躲，不是"在它冒头前先打它一顿"。
func _is_surfaced() -> bool:
	match _state:
		BossSandwormState.State.TELEGRAPH:
			return _attack != null and _attack.surfaces_in_telegraph
		BossSandwormState.State.STRIKE, BossSandwormState.State.RECOVER:
			return true
		_:
			return false


## 受击碰撞体的开关。切的是 **collision_layer**、不是 collision_mask：
##   · collision_mask = 2 不动 ⇒ 它照样站在地面上，不会掉进地底；
##   · layer 置 0 ⇒ 玩家挥砍的 intersect_shape（mask = 全部层）查不到它，
##     于是"打不到"是字面意义上打不到，而不只是靠 take_damage 里提前 return；
##   · 顺带没有"看不见的墙"：埋着的时候它不占碰撞层，玩家能从它上面直接走过去。
## 工程内同款做法见 resources/resource_manager.gd 隐藏建筑那段（layer 2 ↔ 0）。
## 只在状态切换时调用一次，不必每帧刷。
func _refresh_hitbox() -> void:
	collision_layer = _hit_layer if _is_surfaced() else 0


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
		_set_state(BossSandwormState.State.EMERGING)


func _process_emerging() -> void:
	if _state_time >= emerge_time:
		_debug("登场完毕 → 追击")
		_set_state(BossSandwormState.State.CHASE)


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
		_set_state(BossSandwormState.State.CHASE)
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

	# 上面几行（尤其 _check_leash）可能已经把状态推走 ⇒ 只有确实还在招式三段里，
	# 下面读 _attack.xxx 才是安全的。这是"招式播到一半绝不换表/丢招"的守门员。
	if not BossSandwormState.is_attack_phase(_state):
		return

	match _state:
		BossSandwormState.State.TELEGRAPH:
			# 区域招（流沙陷落）：前摇这几秒**持续**把圈内单位拖向圆心，
			# 同时把地面圈画出来。玩家要在这段时间里逆着拉力走出去才能躲开。
			if _attack.has_zone():
				_pull_into_zone(delta, _attack)
			if _attack.aims_at_player or _attack.has_zone():
				_update_zone_fx(_attack)
			if _state_time >= _attack.telegraph_time:
				_enter_strike()
		BossSandwormState.State.STRIKE:
			# 判定只做一次（不是每帧扣血）
			if not _strike_done:
				_strike_done = true
				_apply_attack_damage()
				# ⚠ 上面这一行**可能同步把状态机推走**（详见 _apply_attack_damage 的说明：
				#   那一击把玩家打死 ⇒ RETREAT ⇒ _attack 被置 null）。回头确认再往下读，
				#   否则下一行的 _attack.strike_time 又是空引用。
				if _attack == null:
					return
			if _state_time >= _attack.strike_time:
				_set_state(BossSandwormState.State.RECOVER)
		BossSandwormState.State.RECOVER:
			if _state_time >= _attack.recover_time:
				_cooldowns[_attack.attack_id] = _attack.cooldown
				_debug("招式 %s 结算，进入冷却 %.1fs" % [_attack.attack_id, _attack.cooldown])
				_set_state(BossSandwormState.State.CHASE)
		_:
			pass


## RETREAT / FALLEN 共用：往巢穴走，到了再分道扬镳
func _process_going_home() -> void:
	var distance: float = _horizontal_distance(global_position, _home)
	if distance <= arrive_radius:
		_move_dir = Vector3.ZERO
		if _state == BossSandwormState.State.FALLEN:
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
		_set_state(BossSandwormState.State.DORMANT)
		return
	var dir: Vector3 = _horizontal_dir(global_position, _home)
	_face(dir)
	_move_dir = dir


## 移动速度：由状态（以及招式的 move_scale）决定
func _movement_speed() -> float:
	match _state:
		BossSandwormState.State.CHASE:
			return chase_speed
		BossSandwormState.State.RETREAT, BossSandwormState.State.FALLEN:
			return chase_speed * return_speed_scale
		BossSandwormState.State.TELEGRAPH, BossSandwormState.State.STRIKE, BossSandwormState.State.RECOVER:
			if _attack != null:
				return chase_speed * _attack.move_scale
			return 0.0
		_:
			return 0.0


## 领地绳：追击与出招期间，把"朝领地外"的那一维分量削掉。
## 三个目的：① 它不会一路把你追出几十米远；② 「它守在领地边缘」这件事**看得见**，
## 玩家不用靠猜；③ 回家路径（RETREAT / FALLEN）不受限，否则它永远回不了巢。
## 做法＝削掉朝外分量再归一化 ⇒ 它会贴着领地边缘横向滑动，而不越走越远。
func _clamped_move_dir(dir: Vector3, speed: float, delta: float) -> Vector3:
	if dir == Vector3.ZERO or speed <= 0.0:
		return dir
	if _state != BossSandwormState.State.CHASE and not BossSandwormState.is_attack_phase(_state):
		return dir
	var next_position: Vector3 = global_position + dir * speed * delta
	if _horizontal_distance(next_position, _home) <= leash_radius:
		return dir
	var outward: Vector3 = _horizontal_dir(_home, global_position)
	var along: float = dir.x * outward.x + dir.z * outward.z
	if along <= 0.0:
		return dir
	var slid: Vector3 = Vector3(dir.x - outward.x * along, 0.0, dir.z - outward.z * along)
	if slid.length() < 0.0001:
		return Vector3.ZERO
	return slid.normalized()


## 脱战判定：玩家跑出**领地**（圆心＝巢穴、半径 leash_radius）并持续 leash_time 才生效。
## 返回值 = 本帧是否已经转入 RETREAT。
##
## ⚠ 基准是「玩家 ↔ 巢穴」，**不是「玩家 ↔ Boss」**（2026-09-25 改）：
##   ① 案设就是"在一定距离内追击"—— 绳子拴在巢穴上，被拉出领地就回巢；
##      语义是"你离开了它的地盘"，而不是"你离它本人多远"；
##   ② 量 Boss↔玩家 时，脱战要求**拉开 leash_radius 的差距**，而这个差距只能靠速度差
##      一点点攒（玩家 5.0 vs Boss 3.4；饥饿 ×0.9、低电 ×0.7，最低 3.15 ⇒ 低电时
##      **Boss 比玩家还快**）。原值 34 m ÷ 1 m/s ⇒ 得笔直跑 30 秒以上，实战等于
##      "永远逃不掉"（2026-09-25 用户反馈）；
##   ③ 量「玩家↔巢穴」则**与速度差无关**：跑出去多少就是多少，跑十来米就能脱身。
func _check_leash(delta: float) -> bool:
	if BossSandwormState.is_terminal(_state):
		return true
	if leash_time <= 0.0:
		return false
	var distance: float = player_home_distance()
	if distance <= leash_radius:
		_leash_timer = 0.0
		return false
	_leash_timer += delta
	if _leash_timer < leash_time:
		return false
	_start_retreat("玩家离开领地 %.1f m（>%.1f m 持续 %.1fs）" % [distance, leash_radius, leash_time])
	return true

# ============================================
# 决策：选表 → 选招
# ============================================

## 决策点执行一次：选到招就出招（返回 true），没招就交回 CHASE（返回 false）
func _decide() -> bool:
	_sync_rotation_with_phase()
	var next: BossSandwormAttack = _pick_next_attack()
	if next == null:
		return false
	_start_attack(next)
	return true


## 换表就把轮转指针归零。表 2 的顺序是 ④①②③，必须**从 ④ 起手**才对得上"4123"；
## 不归零的话血线一破就从表 2 的中间某招续下去，顺序读不出来。
## 只在这里（决策点）判，招式播到一半不换表 —— 与 _current_table() 的规则一致。
func _sync_rotation_with_phase() -> void:
	var phase: int = current_phase()
	if phase == _phase_cache:
		return
	_phase_cache = phase
	_rotation_index = 0


## 按**固定顺序轮转**取招（表 1：①②③；表 2：④①②③）。
##
## 与旧版"从上往下取第一条可用"的区别：旧版第 1 招永远优先，玩家只要把距离拉开
## 就只会见到远程招；新版是背板式轮转 —— 打完①才轮到②，顺序是可预期的。
##
## 三条规则：
##   · 轮到的招**够不着**（> max_range）⇒ 返回 null 且**不推进指针**。
##     调用方还在 CHASE ⇒ 它会继续潜行逼近，追进射程再放（＝"潜近再放"）。
##   · 轮到的招**在 CD / 太近不该放**（< min_range）⇒ 顺延到下一条，不卡住。
##   · 一圈都轮不到 ⇒ 返回 null，继续贴身追（原案的兜底，不许原地发呆）。
##
## ⚠ min_range 的陷阱：严格顺序 + 够不着就等 ⇒ 一旦给某招设 min_range > 0，
##   玩家贴脸时它会"永远够不着"，于是站着不动。本表所有招的 min_range 都是 0，
##   靠这一条避开；将来真要给某招加 min_range，请同时补"太近就顺延"的分支。
func _pick_next_attack() -> BossSandwormAttack:
	var table: Array[BossSandwormAttack] = _current_table()
	var count: int = table.size()
	if count == 0:
		_attack_index = -1
		return null
	var distance: float = player_distance()
	for step in range(count):
		var index: int = (_rotation_index + step) % count
		var candidate: BossSandwormAttack = table[index]
		if candidate == null:
			continue
		if cooldown_left(candidate.attack_id) > 0.0:
			continue
		if distance > candidate.max_range:
			_attack_index = -1
			return null
		if distance < candidate.min_range:
			continue
		_rotation_index = (index + 1) % count
		_attack_index = index
		return candidate
	_attack_index = -1
	return null


## 按血量选表。**相位切换只发生在决策点** —— 招式播到一半绝不换表
func _current_table() -> Array[BossSandwormAttack]:
	if max_health > 0 and float(_health) / float(max_health) > phase_line:
		return _phase1_attacks
	return _phase2_attacks


func _start_attack(attack: BossSandwormAttack) -> void:
	_attack = attack
	_strike_done = false
	# 落点必须在**施放这一刻**算一次然后钉住（见 _strike_origin 的说明）
	_strike_origin = attack.strike_origin_from(global_position, player_position())
	attack_started.emit(attack.attack_id)
	_debug("选招 %s（%s）" % [attack.attack_id, attack.describe()])
	if attack.aims_at_player or attack.has_zone():
		_show_zone(attack, _strike_origin)
	_set_state(BossSandwormState.State.TELEGRAPH)


## 进入判定段。区域招在这里**破土而出**：沙虫瞬移到圆心 ——
##   ① "从圆心冒出吞噬"的表现就是它本人出现在圈心；
##   ② 于是判定半径天然就是"离圆心多远"，不用额外记一个判定原点；
##   ③ 露头 → _set_state 里顺带把受击碰撞体打开（玩家终于能打了）。
func _enter_strike() -> void:
	var attack: BossSandwormAttack = _attack
	if attack != null and attack.has_zone():
		global_position = Vector3(_strike_origin.x, global_position.y, _strike_origin.z)
		_move_dir = Vector3.ZERO
		velocity.x = 0.0
		velocity.z = 0.0
	_hide_zone()
	_set_state(BossSandwormState.State.STRIKE)


## 判定生效：玩家在判定半径内才扣血。用玩家**本体**（player/Physics）算距离
##
## ⚠⚠ 本函数**会在执行途中被同步重入**，这是本文件最危险的一处：
##      body.take_damage() 可能把玩家打死 ⇒ 玩家同步发 died 信号
##      ⇒ _on_player_died() ⇒ _start_retreat() ⇒ _set_state(RETREAT)
##      ⇒ 依 _set_state 的规则「离开招式三段就丢掉当前招」把 _attack 置 null。
##      而此刻本函数**还没执行完**，后面还要用这一招的 id / damage。
##    ⇒ 所以：**开头取一个局部引用 attack，全程只用它**，扣血之后绝不回头读 _attack。
##      （2026-09-26 玩家反馈"被沙虫打死后会报错"就是这里：
##       Invalid access to property or key 'attack_id' on a base object of type 'Nil'）
##    ⚠ 同理，调用方（_process_attack）在调用本函数之后也必须重新确认 _attack 还在。
func _apply_attack_damage() -> void:
	var attack: BossSandwormAttack = _attack
	if attack == null:
		return
	# 区域招（流沙吞噬）判的是"圈里还有谁"，不是"玩家在不在嘴边上"
	if attack.has_zone():
		_apply_zone_devour(attack)
		return
	var body: Node3D = player_body()
	if body == null or not player_alive():
		_debug("招式 %s 落空（玩家不在场）" % attack.attack_id)
		return
	var origin: Vector3 = _damage_origin(attack)
	var distance: float = _horizontal_distance(origin, body.global_position)
	if distance > attack.radius:
		_debug("招式 %s 落空（玩家 %.1f m 在 %.1f m 判定外）"
			% [attack.attack_id, distance, attack.radius])
		return
	if not body.has_method("take_damage"):
		return
	# ↓↓↓ 这一行可能就是上面说的"重入点"（打死玩家 → 状态被改 → _attack 变 null）
	body.call("take_damage", attack.damage)
	# 继续用局部 attack：命中确实发生了，即使状态机已经被推去 RETREAT，也该照实上报
	attack_landed.emit(attack.attack_id, attack.damage)
	_debug("招式 %s 命中玩家，扣 %d" % [attack.attack_id, attack.damage])


## 判定圆心：钉死的落点（aims_at_player）还是"此刻沙虫自己站的地方"。
## ⚠ 后者不能用施放时的快照 —— ④潜行突袭在前摇里一路高速突进，
##   判定要落在它**咬下去那一刻**的位置上，否则它会咬到身后的空气。
func _damage_origin(attack: BossSandwormAttack) -> Vector3:
	if attack.aims_at_player:
		return _strike_origin
	return global_position


## 流沙吞噬：圈内**所有**单位各挨一次（玩家 + 其他生物），没躲出去就吃满。
## 判定圆心就是落点 —— 破土时沙虫已经瞬移到圆心（见 _enter_strike），
## 所以"离圆心多远"和"离沙虫多远"是同一个数，直接复用 radius。
##
## ⚠ 同 _apply_attack_damage：body.call 可能同步把玩家打死 ⇒ 状态机被推走 ⇒
##    _attack 变 null。这里靠两件事顶住：① 全程只用局部 attack；
##    ② _pullable_bodies() 返回的是**新数组**（快照），遍历不会被中途改坏。
func _apply_zone_devour(attack: BossSandwormAttack) -> void:
	var origin: Vector3 = _damage_origin(attack)
	var caught: int = 0
	for body in _pullable_bodies():
		if not is_instance_valid(body):
			continue
		if _horizontal_distance(origin, body.global_position) > attack.radius:
			continue
		if not body.has_method("take_damage"):
			continue
		body.call("take_damage", attack.damage)
		caught += 1
	if caught > 0:
		attack_landed.emit(attack.attack_id, attack.damage)
		_debug("招式 %s 吞噬了 %d 个目标，各扣 %d"
			% [attack.attack_id, caught, attack.damage])
	else:
		_debug("招式 %s 落空（圈里一个单位都没有）" % attack.attack_id)

# ============================================
# 受伤与濒死
# ============================================

## 受伤入口。签名必须与 Slime / Drone / 玩家 Physics 一致
## （玩家攻击是**沿父链按方法名找 take_damage**，改名就找不到承伤体了）。
##
## 三道门：① 这场架已经输掉（濒死保命 / 已退场）；② 状态本身不该收（待机 / 登场 / 脱战）；
## ③ **此刻没露头**（埋在地下潜行）—— 这一条是运行时状态，静态谓词表达不了。
func take_damage(damage: int) -> void:
	# ⚠ 第一行就拦。玩家一次挥砍用 intersect_shape(..., 10) 查最多 10 个碰撞体，
	#   进入 FALLEN 的**同一帧**完全可能再来第二段伤害把保底的 1 点打光。
	if _untouchable:
		return
	if not BossSandwormState.can_be_hurt(_state):
		return
	if not _is_surfaced():
		return
	_apply_damage(damage)


## 真正扣血的那一段（take_damage 与 debug_damage_to 共用）。
##
## ⚠ "保留最后 1 点生命"这一步必须发生在**扣血函数内部**，不是"等主循环回头查到
##   血量等于 1"：一次扣 10、血量剩 5 → -5，那时"用表 1 / 用表 2 / 濒死"
##   三个分支一个都不命中，状态机会卡死。
func _apply_damage(damage: int) -> void:
	if damage <= 0:
		return
	_health -= damage
	if _health <= 0:
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
	if _state == BossSandwormState.State.FALLEN or BossSandwormState.is_terminal(_state):
		return
	_untouchable = true
	_trigger_timer = 0.0
	_leash_timer = 0.0
	_refresh_body_color()
	_debug("血量见底 → 保留 1 点生命、永久无敌，开始逃走")
	_set_state(BossSandwormState.State.FALLEN)


## 退场：一次性，且是**唯一**写世界状态的地方
func _enter_gone() -> void:
	if _state == BossSandwormState.State.GONE:
		return
	_set_state(BossSandwormState.State.GONE)
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
	if BossSandwormState.is_terminal(_state) or _state == BossSandwormState.State.FALLEN:
		return
	if _state == BossSandwormState.State.RETREAT:
		return
	# 这里**不写任何世界状态**、可以无限重复 ⇒ 反复消耗磨不死它
	_trigger_timer = 0.0
	_leash_timer = 0.0
	_debug("脱战（%s）→ 回巢回满血" % reason)
	_set_state(BossSandwormState.State.RETREAT)


## 玩家死亡 → 同一条脱战路径。
## 必须接：RespawnSystem 完全不碰敌人，不接就会"守尸"
## （复活点若在仇恨圈内，玩家 5 秒后必再死）。
func _on_player_died() -> void:
	if BossSandwormState.is_terminal(_state):
		return
	if _state == BossSandwormState.State.DORMANT:
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


## 玩家到**巢穴**的平面距离 —— 这是**领地（脱战）判定的基准**，调试面板也显示它。
## 玩家不在场返回 INF（而不是 0）：找不到人不该被判成"乖乖待在领地里"。
func player_home_distance() -> float:
	var body: Node3D = player_body()
	if body == null:
		return INF
	return _horizontal_distance(_home, body.global_position)


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
	# 每次"开一场新架"（就绪 / 回巢后再登场）都从①重新起手，顺序才可背板
	_rotation_index = 0


func _seed_cooldown_table(table: Array[BossSandwormAttack]) -> void:
	for attack in table:
		if attack == null:
			continue
		if not _cooldowns.has(attack.attack_id):
			_cooldowns[attack.attack_id] = 0.0

# ============================================
# 地面区域（流沙陷落 / 吐沙的落点）
#
# 只用在"落点在玩家身上"的招上（aims_at_player / zone_radius）。两件事必须钉死：
#   ① 圆心在**施放那一刻**取一次就固定（存进 _strike_origin）——
#      每帧重算会变成"圈跟着玩家跑"，那就完全没有躲的余地了；
#   ② 圈是 top_level 的世界节点，不能挂在 Visual 底下 —— 否则它跟着沙虫一起走。
# ============================================

## 会被拉向圆心的单位。用**组名**遍历，而不是物理形状查询：
##   · 玩家的本体是 player 节点的 Physics 子节点，不是根节点
##     （物理查询拿到根节点，位置恒等于出生点 —— 2026-09-22 在采集判定上炸过同款）；
##   · 测试用的假玩家根本没有 CollisionShape，物理查询根本扫不到它。
## "其他生物"就是 enemy 组，两边一起收。
func _pullable_bodies() -> Array[Node3D]:
	var bodies: Array[Node3D] = []
	_collect_pullable(get_tree().get_nodes_in_group(&"player"), bodies)
	_collect_pullable(get_tree().get_nodes_in_group(&"enemy"), bodies)
	return bodies


func _collect_pullable(nodes: Array, out: Array[Node3D]) -> void:
	for node in nodes:
		var body: Node3D = _resolve_body_of(node)
		if body != null and body != self:
			out.append(body)


## 从"组里的那个节点"找到真正该被拖动的 3D 本体
func _resolve_body_of(node: Node) -> Node3D:
	if node is CharacterBody3D:
		return node as Node3D
	var physics: Node = node.get_node_or_null("Physics")
	if physics is Node3D:
		return physics as Node3D
	return null


## 前摇期间把圈内单位拖向圆心。**直接改 global_position**、不走 velocity ——
## 玩家的控制器每帧自己重算 velocity，塞进去的初速立刻会被覆盖掉。
## 拉力 2.6 对玩家满速 5.0 ⇒ 逆着走能出来、站着不动被拖进中心，
## 这就是流沙"逃得掉、但很吃力"的手感来源。
func _pull_into_zone(delta: float, attack: BossSandwormAttack) -> void:
	if attack.zone_pull_speed <= 0.0:
		return
	var center: Vector3 = _strike_origin
	var step: float = attack.zone_pull_speed * delta
	for body in _pullable_bodies():
		if not is_instance_valid(body):
			continue
		var position: Vector3 = body.global_position
		var dx: float = center.x - position.x
		var dz: float = center.z - position.z
		var distance: float = sqrt(dx * dx + dz * dz)
		if distance > attack.zone_radius:
			continue
		if distance < 0.0001 or distance <= step:
			body.global_position = Vector3(center.x, position.y, center.z)
			continue
		body.global_position = Vector3(
			position.x + dx / distance * step,
			position.y,
			position.z + dz / distance * step)


## 懒创建预警圈：只建一次、靠 visible 开关复用，
## 免得每次出招都新建一个网格 + 新建一份材质。
func _ensure_zone_fx() -> void:
	if _zone_fx != null and is_instance_valid(_zone_fx):
		return
	_zone_mesh = CylinderMesh.new()
	_zone_mesh.height = 0.06
	_zone_mesh.radial_segments = 48
	_zone_mat = StandardMaterial3D.new()
	# 与其它占位网格一致走 UNSHADED：受光材质在本工程的环境光下会被抬亮约 2.2 倍
	_zone_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zone_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var disc: MeshInstance3D = MeshInstance3D.new()
	disc.name = "Disc"
	disc.mesh = _zone_mesh
	disc.material_override = _zone_mat
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var root: Node3D = Node3D.new()
	root.name = "ZoneFx"
	# top_level ⇒ 它钉在世界坐标上，沙虫一边追一边走时圈不跟着跑
	root.top_level = true
	root.visible = false
	root.add_child(disc)
	add_child(root)
	_zone_fx = root


func _show_zone(attack: BossSandwormAttack, center: Vector3) -> void:
	var radius: float = attack.marker_radius()
	if radius <= 0.0:
		return
	_ensure_zone_fx()
	if _zone_fx == null:
		return
	_zone_mesh.top_radius = radius
	_zone_mesh.bottom_radius = radius
	_zone_mat.albedo_color = attack.zone_color
	# top_level ⇒ position 就是世界坐标
	_zone_fx.position = Vector3(center.x, center.y + 0.06, center.z)
	_zone_fx.visible = true


## 越接近爆发越暗、越不透明 —— 给玩家一个"还剩多久"的读数
func _update_zone_fx(attack: BossSandwormAttack) -> void:
	if _zone_fx == null or not _zone_fx.visible:
		return
	var progress: float = 0.0
	if attack.telegraph_time > 0.0:
		progress = clampf(_state_time / attack.telegraph_time, 0.0, 1.0)
	var base: Color = attack.zone_color
	var dim: float = 1.0 - 0.45 * progress
	_zone_mat.albedo_color = Color(
		base.r * dim, base.g * dim, base.b * dim,
		clampf(base.a + 0.35 * progress, 0.0, 1.0))


func _hide_zone() -> void:
	if _zone_fx != null and is_instance_valid(_zone_fx):
		_zone_fx.visible = false


# ============================================
# 表现（占位）
# ============================================

## 占位材质。**必须 UNSHADED**，理由（2026-09-26 用户反馈"沙虫经常会变成白色看不清"）：
##   本工程 map.tscn 的环境光是 ambient_light_color(0.83) × ambient_light_energy(9.0)，
##   受光材质（默认 SHADING_MODE_PER_PIXEL）会被整体抬亮约 2.2 倍 ⇒ **albedo 亮过
##   0.45 的直接打爆成纯白**。体色 (0.82,0.70,0.42)、亮黄的地面沙色 (0.78~0.95)、
##   濒死灰 (0.52,0.50,0.55) 全都在这个区间里 —— 沙虫、地面一起变白糊成一片；
##   连"前摇变红 / 濒死变灰"这些**状态信号**也一起白掉，等于没有信号。
##   渲染取证实测：体色态/地面像素都是 #ffffff，前摇橙只到 #ffff90。
##   全工程的地形与海面同样走 UNSHADED（map_generator_3d.gd）—— 保持一致，
##   而且往后加任何 3D 网格都请照这个来，否则会遇到同一个坑。
func _setup_placeholder_material() -> void:
	if _visual == null:
		return
	var body_mat: StandardMaterial3D = _make_placeholder_material(body_color)
	var jaw_mat: StandardMaterial3D = _make_placeholder_material(body_color.darkened(jaw_darken))
	# Visual 下**所有** MeshInstance3D 都要吃到材质：漏一个就会退回引擎默认的
	# 白色**受光**材质，又变成一块白（Jaw 原先就是这么漏的）
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(_visual, meshes)
	for mesh in meshes:
		var is_jaw: bool = String(mesh.name).findn("Jaw") >= 0
		mesh.material_override = jaw_mat if is_jaw else body_mat
	_body_material = body_mat
	_jaw_material = jaw_mat


func _make_placeholder_material(base: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = base
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child as MeshInstance3D)
		_collect_meshes(child, out)


func _refresh_body_color() -> void:
	if _body_material == null:
		return
	var color: Color = body_color
	if _hurt_flash > 0.0:
		color = hurt_color
	elif _state == BossSandwormState.State.FALLEN or _state == BossSandwormState.State.GONE:
		color = fallen_color
	elif _state == BossSandwormState.State.TELEGRAPH and _attack != null:
		# 前摇的视觉信号：体色变红 = "要打了，快跑"
		# 正式美术接入后这一段由动画承担（BossSandwormAttack.telegraph_color 只是占位）
		color = _attack.telegraph_color
	_body_material.albedo_color = color
	if _jaw_material != null:
		# 下颚跟着一起变，但保持"比体色暗一档"的关系
		_jaw_material.albedo_color = color.darkened(jaw_darken)


## 占位美术的"钻地"深度目标：
##   · 待机 / 退场 / 地下筹备 → 整只埋掉（看不见）
##   · 潜地移动（追击 / 逃走）→ 只露一截背脊（travel_depth）：
##     "玩家看得见但打不到"就靠这一档 —— 看不见它往哪跑就没法预判它从哪冒头
##   · 冒头前摇 / 判定 / 后摇 → 抬到 0（完全露出）
## 口径与 _is_surfaced() 一致：露头的那几段才开受击碰撞体。
func _visual_target_depth() -> float:
	match _state:
		BossSandwormState.State.TELEGRAPH:
			if _attack != null and _attack.surfaces_in_telegraph:
				return 0.0
			return -buried_depth
		BossSandwormState.State.STRIKE, BossSandwormState.State.RECOVER:
			return 0.0
		BossSandwormState.State.CHASE, BossSandwormState.State.RETREAT, BossSandwormState.State.FALLEN:
			return -travel_depth
		_:
			return -buried_depth


## 占位美术的浮沉：登场走插值（钻出沙面），其余朝目标深度匀速挪（rise_speed）。
func _update_visual(delta: float) -> void:
	if _visual == null:
		return
	var position: Vector3 = _visual.position
	if _state == BossSandwormState.State.EMERGING:
		var t: float = 1.0
		if emerge_time > 0.0:
			t = clampf(_state_time / emerge_time, 0.0, 1.0)
		position.y = lerpf(-buried_depth, 0.0, t)
	else:
		position.y = move_toward(position.y, _visual_target_depth(), rise_speed * delta)
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
	if _state != BossSandwormState.State.DORMANT:
		return
	_debug("调试唤起")
	_set_state(BossSandwormState.State.EMERGING)


## 把血量打到指定值（调试 / 测试用）。走同一条扣血路径 ⇒ "保底 1 点 + 濒死"
## 的规则照样生效：debug_damage_to(0) → 血量打光 → 夹到 1 → 进 FALLEN（正是要测的那条路）。
##
## ⚠ 它**故意绕过"受击窗口"**：埋伏在地下时调试者也必须能把血打下去，
##   否则"摆状态"就变成要看沙虫脸色的运气活（2026-09-26 加受击窗口时踩到）。
##   濒死/退场（_untouchable）那条仍然拦 —— 那是"这场架已经结束"，不是窗口问题。
func debug_damage_to(target_health: int) -> void:
	if _untouchable:
		return
	var delta: int = _health - target_health
	if delta <= 0:
		return
	_apply_damage(delta)


## 把所有招式的冷却拉满（测"全表在 CD 时的兜底"：应当继续追击、不空放、不卡死）。
##
## ⚠ **必须在这一帧没有招式正在三段里的时候调用**：正在播的那一招走到 RECOVER
##   结束时会把自己的 cooldown 写回去（`_cooldowns[id] = attack.cooldown`，
##   例如 sand_spit 的 9 s），把这里设的 30 s 覆盖掉 ⇒ 该招提前解禁。
##   2026-09-25 踩过：先跑了一段位移、让 sand_spit 进了前摇，才调本函数，
##   结果 bite 还有 19 s、sand_spit 已经归零，测试里 Boss 又开始出招。
##   若确实需要在招式播到一半时叫停，请等它结算后再调一次。
func debug_set_all_cooldowns(seconds: float) -> void:
	for key in _cooldowns.keys():
		_cooldowns[key] = maxf(seconds, 0.0)


## 当前相位：1 = 血厚表，2 = 血少表。
## 注意它**只反映此刻按血量该用哪张表**；招式播到一半不会真的换表（见 _current_table 注释）
func current_phase() -> int:
	if max_health > 0 and float(_health) / float(max_health) > phase_line:
		return 1
	return 2


## 此刻正在执行的那条招式（不在招式三段里时为 null）
func current_attack() -> BossSandwormAttack:
	return _attack


## 是否已经"输掉这场架"（濒死逃走 or 已退场）—— 存档用它判 defeated
func is_defeated() -> bool:
	return _state == BossSandwormState.State.FALLEN or BossSandwormState.State.GONE == _state


func current_attack_id() -> StringName:
	if _attack == null:
		return &""
	return _attack.attack_id


## 调试面板用的一行描述（测试场地每帧刷这个）
func debug_line() -> String:
	return "状态 %s   HP %d/%d   距离 %.1f m   用招 %s" % [
		BossSandwormState.label_of(_state),
		_health,
		max_health,
		player_distance(),
		_describe_cooldowns(),
	]


func _describe_cooldowns() -> String:
	var parts: Array[String] = []
	var table: Array[BossSandwormAttack] = _current_table()
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
	if not _debug_on() or BossSandwormState.is_terminal(_state):
		return
	_debug_timer += delta
	if _debug_timer < 1.0:
		return
	_debug_timer = 0.0
	_debug("状态=%s HP=%d/%d 距离=%.1f" % [
		BossSandwormState.label_of(_state), _health, max_health, player_distance()])
