extends CharacterBody3D

# ============================================
# 导出变量 - 可在编辑器中修改
# ============================================

## 角色移动速度
@export var speed: float = 5.0
## 重力强度
@export var gravity: float = 20.0
## 攻击冷却时间（秒）
@export var attack_cooldown: float = 0.5
## 攻击范围（米）
@export var attack_range: float = 2.0
## 攻击力
@export var attack_damage: int = 10

# ============================================
# 节点引用
# ============================================

## 角色视觉动画节点
@onready var spr: AnimatedSprite3D = get_parent().get_node("Visual/BaseBody")
## 视觉父节点（用于朝向控制）
@onready var visual_node: Node3D = get_parent().get_node("Visual")

# ============================================
# 状态变量
# ============================================

## 当前是否在攻击中
var is_attacking: bool = false
## 攻击冷却计时器
var _attack_timer: float = 0.0
## 记录左右朝向（true=朝左，false=朝右）
var facing_left: bool = true
## 上一物理帧 / 当前物理帧的世界坐标，供 _process 做渲染插值。
## 必要性：角色在 _physics_process 里按固定 60Hz 跳，相机却按渲染帧率平滑移动，
## 两者不同步 → 持续走动时角色相对画面一跳一跳（看起来就是"糊"/拖影）。
var _vis_prev := Vector3.ZERO
var _vis_curr := Vector3.ZERO
## 最大生命值
var max_health: int = 100
## 当前生命值
var current_health: int = 100
## 是否已死亡（current_health<=0 的持久态标记；复活后才清，避免死亡期间反复触发死亡逻辑）
var dead: bool = false

## 本局角色属性是否已应用（防止重复应用导致倍率叠乘）
var _character_applied: bool = false
## @export 的原始移速 / 攻击力，角色倍率以它们为基准换算
var _base_speed: float = 0.0
var _base_attack_damage: int = 0

## 地图生成器引用（惰性获取，用于查询脚下地形判断是否落水）。
## 复用 vitals.gd / build_placer.gd 同一套方式：地图节点注册在 "map_gen" 组（map_generator_3d.gd:112）。
var _map_gen: Node = null

## 淹死判定：玩家走入海洋（terrain=7）且下沉到该 y 以下即判定溺水死亡。
## 海洋瓦片无碰撞体（见 map_generator_3d 注释），玩家进水即自由落体；
## 海面高度 OCEAN_Y=-0.25，这里取 -0.6 给一个极短的"落水"窗口，避免一碰海岸就秒杀。
const DROWN_Y: float = -0.6

# ============================================
# 点击自动寻路（由 ClickMover 组件调用；手动 WASD 随时打断）
# ============================================

## 到达寻路目标时发出（供将来"到达后执行动作"的系统使用；
## ClickMover 目前用轮询 is_auto_moving() 判断，不依赖本信号）
signal auto_move_arrived(target: Vector3)

## 玩家发起一次攻击（perform_attack 里发射）。
## 伤害判定走攻击动画回调 _on_attack_hitbox_active，这里是留给
## 音效/特效/HUD 之类"想跟着攻击做反应"的系统的监听口。
signal attacked

## 玩家死亡（current_health 归零时发出一次）。供 HUD 弹出复活倒计时 UI。
signal died

## 玩家复活（HUD 点「复活」按钮、回到重生点满状态后发出）。
signal revived

## 自动寻路是否激活
var _auto_active: bool = false
## 寻路目标（世界坐标；取水平面朝它走）
var _auto_target: Vector3 = Vector3.ZERO
## 距目标多近算到达（米）
var _auto_stop_radius: float = 0.35
## 卡死检测：每 0.5 秒采样一次位移
var _auto_stuck_timer: float = 0.0
var _auto_stuck_time: float = 0.0
var _auto_last_pos: Vector3 = Vector3.ZERO

# ============================================
# 生命周期函数
# ============================================

func _ready():
	# 设置向上方向（用于地板检测）
	up_direction = Vector3.UP
	_vis_curr = global_position
	_vis_prev = _vis_curr
	# 像素画必须关掉精灵的线性过滤与 alpha 边缘抗锯齿，否则放大几倍后糊成一团
	_apply_pixel_art_quality()
	# 应用本局角色（外观 + 属性）。必须在 spr.play("idle") 与
	# _update_hud_health() 之前：先换贴图再播动画，HUD 也才会显示角色正确的血量上限。
	_apply_character()
	# 游戏启动默认播放待机
	spr.play("idle")
	
	# 连接动画信号
	spr.animation_finished.connect(_on_attack_animation_finished)
	spr.frame_changed.connect(_on_attack_animation_frame_changed)
	
	# 初始化HUD血量显示
	_update_hud_health()

func _physics_process(delta):
	# 死亡后禁用所有操作
	if current_health <= 0:
		_auto_active = false
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return

	# ===== 落水判定（仅在玩家存活时检测）=====
	# 玩家走进海洋格会失去地面支撑开始下落，沉到 DROWN_Y 以下即淹死。
	_check_drown()
	if current_health <= 0:
		_auto_active = false
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return
	
	# 更新攻击冷却计时器
	if _attack_timer > 0:
		_attack_timer -= delta
		# 冷却结束，重置攻击状态
		if _attack_timer <= 0:
			is_attacking = false
	
	# ===== 获取移动方向 =====
	# 攻击时不允许移动
	var dir = Vector3.ZERO
	if not is_attacking:
		dir = _get_movement_input()
		# 玩家手动操作优先级最高：一动 WASD 就取消自动寻路
		if dir.length() > 0.0 and _auto_active:
			_auto_active = false
			DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "[寻路] 手动移动，取消寻路", [])
		# 没有手动输入且有寻路目标 → 朝目标自动走（点击移动 / 点击采集）
		elif _auto_active:
			dir = _get_auto_move_direction()
	
	# ===== 应用重力 =====
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	# ===== 应用移动（攻击时保持位置） =====
	# 实际移速 = 基础速度 × 生命体征修正（低电量减速，大纲 3.1.3）
	var move_speed: float = speed * _get_vitals_speed_multiplier()
	if not is_attacking:
		if dir.length() > 0:
			dir = dir.normalized()
			velocity.x = dir.x * move_speed
			velocity.z = dir.z * move_speed
		else:
			# 没有输入时停止水平移动
			velocity.x = move_toward(velocity.x, 0, move_speed)
			velocity.z = move_toward(velocity.z, 0, move_speed)
	else:
		# 攻击时逐渐停止移动
		velocity.x = move_toward(velocity.x, 0, move_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed)
	
	# 执行移动（关键！）
	move_and_slide()

	# 自动寻路卡死检测（目标被挡住时自动放弃，别永远走不到）
	_tick_auto_move_stuck(delta)
	
	# ===== 同步视觉节点位置和朝向 =====
	# 这里先给一个"精确值"兜底（无渲染帧时也对），真正上屏的位置由 _process 插值覆盖
	_vis_prev = _vis_curr
	_vis_curr = global_position
	visual_node.global_position = global_position
	
	# ===== 更新朝向和动画 =====
	_update_visual_rotation()
	_update_animation(dir)

func _input(event: InputEvent) -> void:
	# ===== F键 攻击 =====
	if event.is_action_pressed("player_attack"):
		perform_attack()

# ============================================
# 攻击相关方法
# ============================================

## 执行攻击动作
## 包含：播放动画、设置攻击状态、检测命中
func perform_attack() -> void:
	# 死亡后不能攻击
	if current_health <= 0:
		return
	
	# 如果正在攻击或冷却中，则不能攻击
	if is_attacking or _attack_timer > 0:
		return
	
	# 设置攻击状态
	is_attacking = true
	_attack_timer = attack_cooldown
	
	# 播放攻击动画
	spr.play("attack")
	
	# 发射攻击信号（供其他系统监听，如HUD更新、伤害判定等）
	emit_signal("attacked")

## 受到伤害
## @param damage 伤害值（护甲会先减免，但至少掉 1 点，避免堆防御后完全无敌）
func take_damage(damage: int) -> void:
	var defense := get_defense()
	var actual: int = max(1, damage - defense)
	if defense > 0:
		DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "玩家受到 %d 点伤害（原始 %d，护甲减免 %d）！剩余生命: %d / %d", [actual, damage, defense, current_health - actual, max_health])
	else:
		DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "玩家受到 %d 点伤害！剩余生命: %d / %d", [actual, current_health - actual, max_health])
	current_health = max(0, current_health - actual)
	
	# 更新HUD血量显示（顺带刷新残血滤镜）
	_update_hud_health()
	
	if current_health <= 0:
		_on_death()
	else:
		# 受击：红色暗角瞬时闪一下（叠加在残血/无滤镜之上，结束自动回到 _base）
		FilterSystem.pulse(FilterSystem.FILTER_HIT)

### 回复生命值（供 vitals 高电量回血等系统调用）
func heal(amount: int) -> void:
	if current_health <= 0:
		return  # 死亡状态不回血
	var healed: int = mini(amount, max_health - current_health)
	if healed <= 0:
		return
	current_health += healed
	_update_hud_health()

## 进入死亡态（current_health 归零时由 take_damage 调用）。
## 幂等：死亡期间重复受击不再重复触发、不重复刷日志。
## 这里只标记状态 + 播死亡动画 + 通知复活系统启动 5 秒倒计时，
## 真正的复活（回重生点、满状态）在 revive() 里做。
func _on_death() -> void:
	if dead:
		return
	dead = true
	DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "玩家死亡！")
	is_attacking = false
	_auto_active = false
	spr.play("die")
	RespawnSystem.on_died(global_position)
	emit_signal("died")
	# 死亡滤镜：灰度 + 变暗 + 黑暗角（持续，直到 revive 时 clear）
	FilterSystem.apply(FilterSystem.FILTER_DEATH)

## 落水判定（每物理帧调用，仅在玩家存活时）。
## 查询脚下地形：海洋（terrain=7）无地面支撑，玩家会自由落体；
## 当 global_position.y 跌破 DROWN_Y（沉到海面下），判定为溺水死亡，
## 复用 _on_death 流程（播 die 动画 + 启动复活系统 5 秒倒计时）。
## 陆地地形（y≈0）永远不会触发，玩家在岛上正常走动安全。
func _check_drown() -> void:
	if _map_gen == null or not is_instance_valid(_map_gen):
		_map_gen = get_tree().get_first_node_in_group("map_gen")
		if _map_gen == null or not _map_gen.has_method("get_terrain_world"):
			return
	var terrain: int = int(_map_gen.get_terrain_world(global_position))
	if terrain != 7:  # 7 = 海洋
		return
	if global_position.y < DROWN_Y:
		DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "玩家落水死亡：脚下地形=海洋，y=%.2f", [global_position.y])
		current_health = 0
		_on_death()

## 复活到重生点并恢复满状态。
## 由 HUD 「复活」按钮在 RespawnSystem.can_revive() 为 true 时调用。
## 重生点默认在出生点（map_generator_3d.teleport_player_to_start 注册），
## 未来由床/篝火调用 RespawnSystem.set_respawn_point 覆盖。
func revive() -> void:
	if not dead:
		return
	# 回到重生点（用 Physics 本体的世界坐标；相机追随 Physics）
	global_position = RespawnSystem.respawn_point
	velocity = Vector3.ZERO
	# 传送后同步：相机吸附 + 视觉插值基准重置（否则镜头/精灵会飘回来）
	reset_visual_interp()
	snap_camera()
	# 满血
	current_health = max_health
	dead = false
	RespawnSystem.clear_dead()
	# 复活：清除死亡滤镜（残血滤镜由下方 _update_hud_health 重新评估，不会误清）
	FilterSystem.clear()
	# 体征复位（电量/体温/饱食度），否则复活后立刻又饿死/冷死
	var vitals = get_parent().get_node_or_null("Vitals")
	if vitals != null and vitals.has_method("reset"):
		vitals.call("reset")
	# 动画复位
	spr.stop()
	spr.play("idle")
	# 刷新 HUD + 清死亡态
	_update_hud_health()
	emit_signal("revived")


## 玩家是否存活（供敌人 AI 判定"还要不要以玩家为目标"）。
## 死亡期间返回 false：史莱姆/无人机会放弃追击、退回待机巡逻，也不再开火。
## 复活（revive）后自动恢复 true，敌人重新锁定玩家。
func is_alive() -> bool:
	return not dead and current_health > 0

## 生命体征（电量/体温）组件的移速修正。
## 组件不存在或未就绪时返回 1.0，移动逻辑不感知它。
func _get_vitals_speed_multiplier() -> float:
	var vitals = get_parent().get_node_or_null("Vitals")
	if vitals != null and vitals.has_method("get_speed_multiplier"):
		return float(vitals.call("get_speed_multiplier"))
	return 1.0

## 获取装备组件（player 节点下的 Equipment 子节点）。
## 没挂装备系统时返回 null，战斗数值自动退化为裸装。
func _get_equipment() -> Node:
	return get_parent().get_node_or_null("Equipment")

## 最终攻击力 = 基础攻击力 + 武器加成
func get_total_attack_damage() -> int:
	var equipment := _get_equipment()
	if equipment != null and equipment.has_method("get_attack_bonus"):
		return attack_damage + int(equipment.call("get_attack_bonus"))
	return attack_damage

## 当前防御力（护甲减免值）
func get_defense() -> int:
	var equipment := _get_equipment()
	if equipment != null and equipment.has_method("get_defense_bonus"):
		return int(equipment.call("get_defense_bonus"))
	return 0


# 更新HUD血量显示
func _update_hud_health() -> void:
	# 按组查找，不写死绝对路径（HUDUI 自己会 add_to_group("hud")）
	var hud = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("update_health"):
		hud.update_health(current_health, max_health)

## 在攻击动画播放过程中进行伤害检测
## 用竖直圆柱检测攻击范围内的所有敌人（竖直拉长是为了能打到悬空的无人机）
##
## ⚠ 攻击范围是**以玩家为中心的 360° 圆柱**，不要再拿 visual_node 的朝向去偏移它。
## 原因（2026-09-14 修的"某个方向打不到史莱姆"）：
##   visual_node 每帧被 _update_visual_rotation() 转成 look_at(摄像机)，
##   也就是一块**永远正对镜头的广告牌**。-visual_node.basis.z 恒等于
##   "从玩家指向摄像机"的方向 —— 一个几乎不变的世界方向，跟角色朝哪走、
##   精灵往哪翻（flip_h / facing_left）毫无关系。
##   原先还要沿这个方向把圆柱前推 attack_range*0.5，于是判定体整块挪到了
##   玩家"靠近镜头"的一侧：镜头侧 2 米内打得到，背对镜头那一侧永远在圆柱外，
##   侧面刚好卡在边界上（时中时不中）。看起来就像"只有某个方向打不到"。
##   顶视视角下角色只有左右翻转、没有真正的朝向，判定也就没有方向可言，
##   所以直接以自身为圆心做全向判定。
func _on_attack_hitbox_active() -> void:
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsShapeQueryParameters3D.new()

	var cylinder_shape = CylinderShape3D.new()
	# 全向：圆心就在玩家脚下，半径 = 攻击距离（改以前是半径一半、再前推一半）
	cylinder_shape.radius = attack_range
	# 竖直拉长：原来是半径 1 米的球，球心在腰高 → 竖直只覆盖 y ∈ [-0.5, 1.5]。
	# 地面上的史莱姆没问题，但悬在 1.5 米的无人机整个在球外，
	# 站在它底下挥砍永远打空。改成竖直圆柱后，
	# 从脚下的地面怪到一人多高的悬空单位都在同一次挥砍范围内。
	cylinder_shape.height = 2.6

	query.shape = cylinder_shape
	# 圆柱中心：水平就在玩家脚下，竖直抬到胸高，
	# 这样覆盖范围大致是 玩家脚下 0 米 → 头顶 2.3 米
	var center: Vector3 = global_position
	center.y = global_position.y + 1.0
	query.transform = Transform3D(Basis(), center)
	query.collision_mask = 0xFFFFFFFF  # 所有层
	query.collide_with_bodies = true
	query.collide_with_areas = true
	
	# 执行形状检测
	var results = space_state.intersect_shape(query, 10)  # 最多检测10个
	
	for result in results:
		var collider = result.collider
		# 跳过自己（CharacterBody3D）
		if collider == self:
			continue
		
		# 查找具有 take_damage 方法的节点（向上遍历父节点）
		var target = _find_take_damage_node(collider)
		
		if target:
			# 最终伤害 = 基础攻击力 + 武器加成
			var final_damage := get_total_attack_damage()
			target.take_damage(final_damage)
			DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "命中目标: %s，造成 %d 点伤害（基础 %d + 武器 %d）", [
				target.name, final_damage, attack_damage, final_damage - attack_damage])

## 向上遍历查找具有 take_damage 方法的节点
## @param node 起始节点
## @return 具有 take_damage 方法的节点，未找到返回 null
func _find_take_damage_node(node: Node) -> Node:
	var current = node
	while current:
		if current.has_method("take_damage"):
			return current
		current = current.get_parent()
	return null

# ============================================
# 点击自动寻路 - 公共接口（ClickMover 调用）
# ============================================

## 设置寻路目标并开始自动移动（新目标覆盖旧目标）
func start_auto_move(target: Vector3) -> void:
	_auto_target = target
	_auto_active = true
	_auto_stuck_time = 0.0
	_auto_stuck_timer = 0.0
	_auto_last_pos = global_position
	DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "[寻路] 目标 (%.1f, %.1f)", [target.x, target.z])


## 静默更新寻路目标（长按鼠标实时拖动用：不刷日志、不重置卡死计时）
## 与 start_auto_move 的区别：每帧都会被调，打日志会把控制台刷爆
func update_auto_move_target(target: Vector3) -> void:
	_auto_target = target
	_auto_active = true


## 取消自动寻路
func cancel_auto_move() -> void:
	_auto_active = false


## 是否正在自动寻路
func is_auto_moving() -> bool:
	return _auto_active


## 朝目标的水平方向；进入停止半径时判定到达并恢复待机
func _get_auto_move_direction() -> Vector3:
	var to := _auto_target - global_position
	to.y = 0.0
	if to.length() <= _auto_stop_radius:
		_auto_active = false
		DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "[寻路] 已到达 (%.1f, %.1f)", [_auto_target.x, _auto_target.z])
		auto_move_arrived.emit(_auto_target)
		return Vector3.ZERO
	# 朝向翻转与 WASD 一致：以相机右方向为"右"，角色朝移动方向看
	var cam := get_viewport().get_camera_3d()
	if cam:
		var right := cam.global_basis.x
		right.y = 0.0
		facing_left = to.dot(right) < 0.0
	return to.normalized()


## 卡死检测：每 0.5 秒采样一次位移，连续 2 秒几乎没动就放弃目标
## （点到了被资源/建筑围住的位置、或被碰撞体卡住时避免原地推挤到天荒地老）
func _tick_auto_move_stuck(delta: float) -> void:
	if not _auto_active:
		return
	_auto_stuck_timer += delta
	if _auto_stuck_timer < 0.5:
		return
	_auto_stuck_timer = 0.0
	if global_position.distance_to(_auto_last_pos) < 0.05:
		_auto_stuck_time += 0.5
		if _auto_stuck_time >= 2.0:
			_auto_active = false
			DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "[寻路] 被挡住 2 秒，放弃目标 (%.1f, %.1f)",
				[_auto_target.x, _auto_target.z])
			auto_move_arrived.emit(_auto_target)
	else:
		_auto_stuck_time = 0.0
	_auto_last_pos = global_position


# ============================================
# 私有方法 - 获取输入
# ============================================

## 获取WASD移动输入
## @return 移动方向向量（已归一化）
func _get_movement_input() -> Vector3:
	var dir = Vector3.ZERO
	
	# 获取相机方向（用于相对移动）
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return dir
	
	var cam_dir = cam.global_basis
	# Godot Camera3D 看向 -z 方向，所以向前是 -z
	var forward = -cam_dir.z
	var right = cam_dir.x
	forward.y = 0
	right.y = 0
	forward = forward.normalized()
	right = right.normalized()
	
	# WASD 移动输入（相对于相机方向）
	if Input.is_action_pressed("move_forward"):
		dir += forward
	if Input.is_action_pressed("move_back"):
		dir -= forward
	if Input.is_action_pressed("move_right"):
		dir += right
		facing_left = false  # 向右移动，朝右
	if Input.is_action_pressed("move_left"):
		dir -= right
		facing_left = true   # 向左移动，朝左
	
	return dir

# ============================================
# 私有方法 - 视觉更新
# ============================================

## 每渲染帧把视觉节点放到「两个物理帧之间的插值位置」。
## 这样角色和相机（相机在 _process 里平滑移动）同频，持续走动时不再一格一格地跳。
func _process(_delta: float) -> void:
	if visual_node == null or not is_instance_valid(visual_node):
		return
	var f := 1.0
	if Engine.has_method("get_physics_interpolation_fraction"):
		f = Engine.get_physics_interpolation_fraction()
	visual_node.global_position = _vis_prev.lerp(_vis_curr, f)


## 瞬移后重置视觉插值基准（读档 / 出生点传送 / 复活都要调）。
## 不重置的话 _vis_prev 还停在旧坐标，精灵会被插值出一条横穿地图的残影。
func reset_visual_interp() -> void:
	_vis_prev = global_position
	_vis_curr = global_position
	if visual_node != null and is_instance_valid(visual_node):
		visual_node.global_position = global_position


## 让跟随相机立刻对准自己（按组查找，不依赖节点路径）。
## 用于复活传送：镜头不该从死亡地点一路飘回重生点。
func snap_camera() -> void:
	var cam: Node = get_tree().get_first_node_in_group("player_camera")
	if cam != null and cam.has_method("snap_to_target"):
		cam.call("snap_to_target")


## 应用本局角色（外观 + 属性）。角色 id 由 CharacterRegistry.active_id 决定：
##   · 新建游戏：主菜单「选择角色」面板选定后 SaveManager.create_slot 写进存档并设为激活
##   · 读档：SaveManager.request_load 从存档 meta 回填
##   · 直接运行 map.tscn 调试：没设过 → 落默认角色
func _apply_character() -> void:
	if _character_applied:
		return
	_character_applied = true
	var def: Dictionary = CharacterRegistry.get_active()
	if def.is_empty():
		return

	# 属性：以 @export 的值为基准乘/取，只应用一次
	_base_speed = speed
	_base_attack_damage = attack_damage
	var speed_mult: float = float(def.get("speed_mult", 1.0))
	var attack_mult: float = float(def.get("attack_mult", 1.0))
	speed = _base_speed * speed_mult
	attack_damage = int(round(float(_base_attack_damage) * attack_mult))
	max_health = int(def.get("base_health", max_health))
	current_health = max_health

	# 外观：换精灵表底层贴图（三套表布局一致，帧区一个都不动）
	var sprite_path: String = String(def.get("sprite", ""))
	var tex: Texture2D = CharacterRegistry.get_sprite(CharacterRegistry.get_active_id())
	if tex == null:
		# 配错路径、或新加的美术文件还没被引擎导入（编辑器扫描后会自动导入）
		DebugConfig.warn_msg(DebugConfig.CAT_PLAYER,
			"[角色] 贴图不可用，沿用基础外观：%s", [sprite_path])
	else:
		_swap_sprite_atlas(tex)

	DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "[角色] %s（速度×%.2f，生命 %d，攻击 %d）",
		[String(def.get("name", "?")), speed_mult, max_health, attack_damage])


## 把 SpriteFrames 里所有帧的 atlas 换成新贴图，动画名与帧区完全沿用。
## 前提：各角色表与基础表同布局（448×392，8 列 × 7 行，单帧 56×56）。
func _swap_sprite_atlas(tex: Texture2D) -> void:
	if spr == null or not is_instance_valid(spr) or tex == null:
		return
	var src: SpriteFrames = spr.sprite_frames
	if src == null:
		return
	# 深拷贝：SpriteFrames 和内部的 AtlasTexture 都是 .tscn 里的共享子资源，
	# 直接改会连带污染同场景的其它实例（以后做"多角色同屏"就会串色）。
	var sf: SpriteFrames = src.duplicate(true) as SpriteFrames
	if sf == null:
		return
	for anim in sf.get_animation_names():
		var count: int = sf.get_frame_count(anim)
		for i in count:
			var frame_tex: Texture2D = sf.get_frame_texture(anim, i)
			if frame_tex is AtlasTexture:
				(frame_tex as AtlasTexture).atlas = tex
	spr.sprite_frames = sf


## 像素画的画质设置：关掉会把硬边缘抹软的两项。
## 用字符串 set + in 检测，避免个别 Godot 版本没有这些属性时报错。
func _apply_pixel_art_quality() -> void:
	if spr == null or not is_instance_valid(spr):
		return
	# 0 = BaseMaterial3D.TEXTURE_FILTER_NEAREST：不做双线性插值，像素边缘才硬
	if "texture_filter" in spr:
		spr.set("texture_filter", 0)
	# 0 = ALPHA_ANTIALIASING_DISABLED：默认是 EDGE，会按 alpha 梯度做边缘羽化，
	# 放大后的像素画边缘会被抹成一圈灰边，看起来就是"糊"
	if "alpha_antialiasing" in spr:
		spr.set("alpha_antialiasing", 0)


## 更新视觉节点的朝向（始终朝向摄像机）
func _update_visual_rotation() -> void:
	var cam = get_viewport().get_camera_3d()
	if cam:
		var look_dir = cam.global_position - global_position
		look_dir.y = 0
		if look_dir.length() > 0.001:
			look_dir = look_dir.normalized()
			visual_node.look_at(global_position + look_dir, Vector3.UP)

## 更新角色动画
## @param dir 移动方向向量
func _update_animation(dir: Vector3) -> void:
	# 攻击状态不更新动画（保持attack动画播放完毕）
	if is_attacking:
		return
	
	# 根据移动状态播放对应动画
	if dir.length() > 0:
		if spr.animation != "walk":
			spr.play("walk")
		# 根据记录的朝向翻转动画
		spr.flip_h = facing_left
	else:
		if spr.animation != "idle":
			spr.play("idle")
		spr.flip_h = facing_left

# ============================================
# 动画信号回调
# ============================================

## 攻击动画播放完毕时的回调
func _on_attack_animation_finished() -> void:
	if spr.animation == "attack":
		# 攻击动画播放完毕，恢复idle状态
		is_attacking = false
		spr.play("idle")
	elif spr.animation == "die":
		# 死亡动画播放完毕
		DebugConfig.log_msg(DebugConfig.CAT_PLAYER, "玩家死亡动画结束")

## 攻击动画播放到特定帧时的回调（用于激活伤害检测）
func _on_attack_animation_frame_changed() -> void:
	if spr.animation == "attack":
		# 在第2帧时激活伤害检测（攻击动作开始）
		if spr.frame == 1:
			_on_attack_hitbox_active()
