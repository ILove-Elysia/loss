# script/ai/enemy/mob/slime.gd
# ============================================
# 史莱姆敌人
#
# 功能：
#   - 待机、巡逻、追击玩家、攻击、受伤、死亡、溺水
#   - 使用地图瓦片 A* 寻路绕开海洋等不可通行区域，并对前方碰撞体做绕行
#   - 掉入海中会持续下沉，低于死亡深度立即死亡
#   - 受到玩家攻击时受伤、死亡
#   - 攻击动画结束后检查玩家是否在攻击范围内
#
# 状态说明：
#   idle  待机（计时结束后转巡逻）
#   walk  巡逻（在陆地上随机游走）
#   chase 追击玩家（沿寻路路径靠近）
#   hurt  受伤（短暂无敌）
#   drown 落水下沉
#   dead  死亡（等待销毁）
#
# 属性说明：
#   - hate_range: 仇恨范围，玩家超出此范围停止追击
#   - stop_distance: 停止距离，怪物靠近到此距离后停止移动
#   - attack_range: 攻击范围，攻击动画结束时玩家必须在范围内才会受到伤害
#   - patrol_range: 巡逻半径（会过滤掉落在海里的目标点）
#   - path_update_interval: 重新寻路的间隔（秒）
#   - drown_depth: 下沉到该高度（y）即判定淹死
#
# 使用方式：
#   1. 创建场景时自动添加此脚本
#   2. 玩家攻击命中时会调用 take_damage()
# ============================================

class_name Slime
extends CharacterBody3D

# 用 preload 而不用全局类名 SpriteFacing：全局类名依赖 .godot 的类缓存，
# 新建脚本若还没被编辑器扫描登记，运行时就会报"找不到类"。
# preload 是编译期常量，不走那份缓存。详见 script/visual/sprite_facing.gd
const Facing := preload("res://script/visual/sprite_facing.gd")

# ============================================
# 导出变量 - 可在编辑器中修改
# ============================================

## 贴图朝向相机的俯角补偿比例。
## 1.0 = 完全正对镜头（拉远拉近时史莱姆在屏幕上的高度不变）；
## 0.0 = 不补偿，只跟相机的水平方向（拉远时会被透视压扁）。
@export_range(0.0, 1.0, 0.05) var billboard_tilt: float = 1.0

## 最大生命值
@export var max_health: int = 30

## 移动速度（米/秒）
@export var move_speed: float = 1.5

## 仇恨范围（米）- 超过此距离会停止追击
@export var hate_range: float = 8.0

## 停止距离（米）- 到达此距离停止移动并准备攻击
@export var stop_distance: float = 1.0

## 攻击范围（米）- 攻击动画结束时玩家必须在范围内才会受到伤害
@export var attack_range: float = 2.0

## 巡逻范围（米）- 待机时随机移动的范围
@export var patrol_range: float = 3.0

## 受伤后无敌时间（秒）
@export var invincibility_time: float = 0.5

## 攻击伤害
@export var attack_damage: int = 5

## 攻击冷却时间（秒）
@export var attack_cooldown: float = 1.0

## 重力加速度（米/秒²）- 空中时向下加速，用于踩空落水
@export var gravity: float = 20.0

## 溺水深度（y 坐标低于此值立即死亡）
@export var drown_depth: float = -1.0

## 重新寻路间隔（秒）
@export var path_update_interval: float = 0.4

## 判定"已到达某个路径点"的距离阈值（米）
@export var waypoint_distance: float = 0.6

## 前方障碍物探测距离（米）- 用于绕开树木、岩石等碰撞体
@export var obstacle_probe: float = 0.9

## 是否输出调试日志（状态/距离/伤害/掉血等）
## 默认关闭：正式游玩时每只史莱姆每 0.5 秒刷一行【调试】，控制台会被冲爆。
## 想看所有敌人 → 去「设置 → 调试选项」开「敌人 AI / 战斗」，不用动这里；
## 只想盯这一只 → 把本项勾上（或在 .tscn 里设为 true）。
@export var debug_enabled: bool = false

# ============================================
# 节点引用
# ============================================

## 视觉节点（包含动画精灵）
@onready var visual: Node3D = $Visual

## 动画精灵
@onready var sprite: AnimatedSprite3D = $Visual/Sprite

## 碰撞体（用于被攻击检测）
@onready var hitbox: CollisionShape3D = $Hitbox/CollisionShape3D

## 导航引用（用于路径导航）
@onready var navigation: NavigationAgent3D = $NavigationAgent

# ============================================
# 状态变量
# ============================================

## 当前状态：idle(待机)、walk(巡逻)、chase(追击)、hurt(受伤)、dead(死亡)
var _state: String = "idle"

## 当前生命值
var _current_health: int = 30

## 是否无敌
var _is_invincible: bool = false

## 无敌计时器
var _invincibility_timer: float = 0.0

## 巡逻目标点
var _patrol_target: Vector3

## 是否已经输出过"未找到玩家"日志（避免重复输出）
var _logged_player_not_found: bool = false

## 攻击冷却计时器
var _attack_cooldown_timer: float = 0.0

## 调试计时器（每0.5秒打印一次距离）
var _debug_timer: float = 0.0

## 是否正往**屏幕左边**走（不是 world X 的负方向，判据见 _update_facing）
## ⚠ 与 sprite.flip_h 同值，这个脚本里两者一致；玩家脚本里两者相反。
var _facing_left: bool = false

## 当前攻击目标（用于动画结束后造成伤害）
var _current_attack_target: Node3D = null

## 是否正在播放攻击动画
var _is_attacking: bool = false

## 待机计时器（用于控制待机时间）
var _idle_timer: float = 0.0

## 地图生成器引用（提供寻路与陆地查询）
var _map_gen: Node = null

## 当前寻路结果（世界坐标航点列表）
var _path: Array = []

## 当前正在走向的路径点索引
var _path_index: int = 0

## 距离上次重新寻路的时间
var _path_timer: float = 0.0

## 当前正在寻路的目标点（用于判断目标是否发生较大变化）
var _last_path_target: Vector3 = Vector3.ZERO

## 是否正在落水下沉
var _is_drowning: bool = false

## 初始化是否已完成。
## 视野流式加载（WorldStreamer）会把远处的敌人移出场景树、走近时再放回，
## 复用同一个节点而不是重建 —— 于是 _ready 必须**幂等**。
## 官方文档明确「节点重新入树不会再调一次 _ready」，但这里若重复执行就有副作用
## （回满血 / 重复连动画信号而报"信号已连接"），所以显式加一道守卫，
## 不把正确性寄托在引擎行为上。
var _initialized: bool = false

# ============================================
# 信号
# ============================================

## 当史莱姆死亡时发出
signal died()

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 重新入树（流式加载放回）时不重复初始化：见 _initialized 的说明
	if _initialized:
		return
	_initialized = true

	# 初始化生命值
	_current_health = max_health
	
	# 设置向上方向（CharacterBody3D 需要）
	up_direction = Vector3.UP
	
	# 连接动画信号
	sprite.animation_finished.connect(_on_animation_finished)
	
	# 播放待机动画
	_play_animation("idle")
	
	# 获取地图生成器（提供寻路与陆地查询）
	_get_map_gen()
	
	# 设置随机巡逻目标（会过滤掉海面上的点）
	_reset_patrol_target()


func _physics_process(delta: float) -> void:
	# ===== 死亡/溺水：不再执行 AI，只保留下沉物理 =====
	if _state == "dead" or _is_drowning:
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y -= gravity * delta
		move_and_slide()
		# 下沉到死亡深度立即判定淹死
		if _is_drowning and global_position.y <= drown_depth:
			_drown()
		return
	
	# ===== 更新计时器 =====
	_update_timers(delta)
	
	# ===== 状态机处理（只负责设定水平速度） =====
	_process_state_machine(delta)
	
	# ===== 应用重力并统一执行一次移动 =====
	# 必须每帧都调用 move_and_slide()：is_on_floor() 是它的结果缓存，
	# 若某些状态（如待机）不调用 mova_and_slide，缓存会长期停留在旧值，
	# 导致踩空后既不下落也检测不到落水。
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()
	
	# ===== 落水检测（此时 is_on_floor 已是本帧最新结果）=====
	if not is_on_floor() and not _is_position_on_land(global_position):
		_start_drowning()
		return
	
	# ===== 始终朝向摄像机 =====
	_look_at_camera()


## 更新所有计时器
func _update_timers(delta: float) -> void:
	# 更新无敌状态
	if _invincibility_timer > 0:
		_invincibility_timer -= delta
		if _invincibility_timer <= 0:
			_is_invincible = false
	
	# 更新攻击冷却
	if _attack_cooldown_timer > 0:
		_attack_cooldown_timer -= delta
	
	# 更新调试计时器
	_debug_timer += delta
	
	# 更新寻路计时器
	_path_timer += delta


## 处理状态机
func _process_state_machine(delta: float) -> void:
	# 调试输出（每0.5秒）——开关关闭时整段跳过，连距离计算都不做
	if _debug_on() and _debug_timer >= 0.5:
		_debug_timer = 0.0
		_print_debug_info()
	
	# 状态机
	match _state:
		"idle":
			_process_idle(delta)
		"walk":
			_process_walk(delta)
		"chase":
			_process_chase(delta)
		"hurt":
			# 受伤状态由动画结束处理
			pass
		"drown":
			# 落水下沉由 _physics_process 统一处理
			pass
		"dead":
			# 死亡状态不做处理
			pass


## 调试是否开启：全局开关 或 本个体开关，满足其一即输出。
##   全局 —— 设置 → 调试选项 →「敌人 AI / 战斗」，对所有敌人生效；
##   个体 —— 检查器里的 debug_enabled，用于"只想盯住这一只"。
func _debug_on() -> bool:
	return debug_enabled or DebugConfig.is_enabled(DebugConfig.CAT_ENEMY)


## 调试日志：受 _debug_on() 控制，关闭时直接返回（连字符串格式化都省掉）
## @param text 模板，可含 %s / %d / %.2f 等占位符
## @param args 占位符参数；不需要参数时留空，按纯文本输出
func _log(text: String, args: Array = []) -> void:
	if not _debug_on():
		return
	DebugConfig.log_msg(DebugConfig.CAT_ENEMY, text, args)

## 打印调试信息
func _print_debug_info() -> void:
	var player_pos = _get_player_actual_position()
	if player_pos != Vector3.ZERO:
		var to_player = player_pos - global_position
		to_player.y = 0
		_log("【调试】状态:%s | 距离:%.2f | 仇恨:%.1f | 停止:%.1f | 攻击:%.1f", [
			_state, to_player.length(), hate_range, stop_distance, attack_range
		])

# ============================================
# 公共方法 - 供外部调用
# ============================================

## 受到伤害
## @param damage 伤害值
func take_damage(damage: int) -> void:
	# 已死亡或正在溺水不再受伤
	if _state == "dead" or _is_drowning:
		return
	
	# 如果无敌则不受到伤害
	if _is_invincible:
		return
	
	# 减少生命值
	_current_health -= damage
	_log("史莱姆受到 %d 点伤害，剩余 %d/%d", [damage, _current_health, max_health])
	
	# 如果生命值 <= 0，触发死亡
	if _current_health <= 0:
		_current_health = 0
		_die()
	else:
		# 进入受伤状态
		_hurt()


## 获取当前生命值
func get_health() -> int:
	return _current_health


## 获取最大生命值
func get_max_health() -> int:
	return max_health


# ============================================
# 存档接口（由 SaveManager 调用）
# ============================================

## 存：世界坐标 + 当前血量。
## 死亡/溺水的个体不会被存——它们走 queue_free，读档时"存档里没有"就等于"已被击杀"。
func get_save_data() -> Dictionary:
	return {
		"position": {"x": global_position.x, "y": global_position.y, "z": global_position.z},
		"health": _current_health,
	}


## 读：落到存档位置，并把所有运行态复位成"刚出生"的样子。
##
## 为什么必须复位：存档可能停在 chase（追击）/ hurt（受伤无敌）/ drown（下沉中）
## 这类瞬时状态上，它们全靠每帧的计时器或动画回调推进。读档后玩家位置已变，
## 若沿用旧状态会出现"史莱姆对着空气挥拳"或"无敌状态永久不解除"。
func apply_save_data(data: Dictionary) -> void:
	var p: Dictionary = data.get("position", {})
	if not p.is_empty():
		global_position = Vector3(
			float(p.get("x", global_position.x)),
			float(p.get("y", global_position.y)),
			float(p.get("z", global_position.z)))

	# 血量至少留 1 点：存 0 的个体说明当时正在播死亡动画，不该当作活口恢复
	_current_health = clampi(int(data.get("health", max_health)), 1, max_health)

	_state = "idle"
	_is_drowning = false
	_is_attacking = false
	_is_invincible = false
	_invincibility_timer = 0.0
	_attack_cooldown_timer = 0.0
	_idle_timer = 0.0
	_current_attack_target = null
	_path.clear()
	_path_index = 0
	_path_timer = 0.0
	velocity = Vector3.ZERO
	_play_animation("idle")
	_reset_patrol_target()

# ============================================
# 状态处理方法
# ============================================

## 处理待机状态
func _process_idle(delta: float) -> void:
	# 使用计时器控制待机时间
	_idle_timer += delta
	
	# 待机1.5秒后开始巡逻
	if _idle_timer >= 1.5:
		_idle_timer = 0.0
		_state = "walk"
		_reset_patrol_target()
		return
	
	# 检查玩家是否在仇恨范围内（玩家已死亡则不再锁定）
	if _is_player_alive() and _is_player_in_range(hate_range):
		_state = "chase"
		_idle_timer = 0.0


## 处理巡逻状态
func _process_walk(delta: float) -> void:
	# 检查是否到达巡逻目标
	var to_target = _patrol_target - global_position
	to_target.y = 0
	
	if to_target.length() < 0.5:
		# 到达目标，切换到待机状态
		_state = "idle"
		_reset_patrol_target()
		return
	
	# 检查玩家是否在仇恨范围内（玩家已死亡则不再锁定）
	if _is_player_alive() and _is_player_in_range(hate_range):
		# 开始追击
		_state = "chase"
		return
	
	# 沿可通行路径向巡逻目标移动（自动绕开海洋与碰撞体）
	_move_towards(_patrol_target)


## 处理追击状态
func _process_chase(delta: float) -> void:
	var player = _get_player()
	var player_pos = _get_player_actual_position()
	
	# 如果玩家不存在或位置无效，停止追击
	if not player or player_pos == Vector3.ZERO:
		_state = "idle"
		_reset_patrol_target()
		return

	# 玩家已死亡：不再以玩家为目标，退回待机巡逻（复活后会自动重新锁定）
	if not _is_player_alive():
		_state = "idle"
		_reset_patrol_target()
		velocity.x = 0.0
		velocity.z = 0.0
		_play_animation("idle")
		return
	
	# 计算到玩家的距离
	var to_player = player_pos - global_position
	to_player.y = 0
	var distance = to_player.length()
	
	# 检查玩家是否超出仇恨范围
	if distance > hate_range:
		_log("史莱姆：玩家逃离仇恨范围")
		_state = "idle"
		_reset_patrol_target()
		return
	
	# 面向玩家
	_look_at_direction(to_player.normalized())
	
	# 如果正在播放攻击动画，忽略其他逻辑
	if sprite.animation == "attack":
		velocity = Vector3.ZERO
		return
	
	# 在攻击范围内且冷却结束时攻击
	if distance <= attack_range and _attack_cooldown_timer <= 0:
		_attack_player(player)
	
	# 在停止距离内停止移动，否则沿可通行路径靠近玩家
	if distance <= stop_distance:
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		_move_towards(player_pos)

# ============================================
# 朝向控制
# ============================================

## 让史莱姆贴图始终正对摄像机（含俯角补偿）
##
## 只转 Visual 子节点，不转史莱姆本体：
##   Visual 里只有贴图，转它没有副作用；而本体上挂着碰撞体、受击 Hitbox、
##   NavigationAgent3D，转本体会把它们一起转掉（眼下都是圆柱 / 全局坐标，
##   没坏，但没有任何好处，还容易被后续改动踩到）。
##
## 为什么不用 look_at(摄像机方向)：那样只跟相机的水平方向（yaw），
## 不跟俯角（pitch）。相机拉到 60° 俯角时，竖直的贴图被透视压缩到只剩一半高，
## 推近拉远时史莱姆会忽大忽小。改用 SpriteFacing 后屏幕高度恒定。
func _look_at_camera() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or visual == null or not is_instance_valid(visual):
		return
	var t := visual.global_transform
	t.basis = Facing.facing_basis(cam, billboard_tilt)
	visual.global_transform = t


## 记录朝向
## @param direction 目标方向（水平面，已归一化）
func _look_at_direction(direction: Vector3) -> void:
	if direction.length() <= 0.001:
		return
	# 不再旋转本体：贴图朝向由 _look_at_camera() 统一接管（始终正对镜头），
	# 这里若再 look_at(玩家) 就会和它打架 —— 追击时贴图转向玩家、
	# 脱离追击又转回相机，玩家看到的是史莱姆在左右乱扭。
	# 史莱姆只有一张正面贴图，左右朝向只能靠 flip_h 表达。
	# 翻转的唯一实现在 _update_facing()，这里只负责把方向交给它 ——
	# 以前这里和 _update_facing() 各写一套、判据还正好相反
	# （这里 direction.x > 0，那里 direction.x < 0），追击时一套、
	# 停下来时另一套，表现就是"走近玩家的一瞬间左右翻一下"。
	_update_facing(direction)

# ============================================
# 移动与攻击
# ============================================

## 沿寻路结果走向目标点
## @param target 最终目标位置
func _move_towards(target: Vector3) -> void:
	_update_path(target)
	
	if _path.is_empty():
		# 目标不可达（例如隔着整片海），原地不动
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
		return
	
	# 推进到下一个尚未到达的路径点
	while _path_index < _path.size() - 1 and _is_waypoint_reached(_path[_path_index]):
		_path_index += 1
	
	var next_point: Vector3 = _path[_path_index]
	var direction: Vector3 = next_point - global_position
	direction.y = 0
	
	if direction.length() < 0.1:
		return
	direction = direction.normalized()
	
	# 前方有树木/岩石等碰撞体时，尝试偏转绕行
	direction = _avoid_obstacles(direction)
	if direction == Vector3.ZERO:
		# 四面都被挡住：停住并强制下一帧重新寻路
		velocity = Vector3.ZERO
		_path_timer = path_update_interval
		return
	
	# 设置水平速度（y 方向重力由 _physics_process 统一处理）
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	
	# 更新朝向
	_update_facing(direction)
	
	# 播放走路动画
	if sprite.animation != "walk":
		_play_animation("walk")


## 按需重新寻路：路径走完、超时、或目标明显移动时刷新
func _update_path(target: Vector3) -> void:
	var needs_refresh: bool = (
		_path.is_empty()
		or _path_timer >= path_update_interval
		or target.distance_to(_last_path_target) > 1.0
	)
	if needs_refresh:
		_request_path(target)


## 向地图生成器请求路径；没有生成器时退回直线移动
func _request_path(target: Vector3) -> void:
	_path_timer = 0.0
	_last_path_target = target
	
	var gen: Node = _get_map_gen()
	if gen == null or not gen.has_method("find_world_path"):
		_path = [target]
		_path_index = 0
		return
	
	var result: Array = gen.find_world_path(global_position, target)
	_path = result
	_path_index = 0


## 判断某个路径点是否已到达
func _is_waypoint_reached(point: Vector3) -> bool:
	var to_point: Vector3 = point - global_position
	to_point.y = 0
	return to_point.length() <= waypoint_distance


## 前方有碰撞体时依次尝试偏转绕行，全部被挡则返回零向量
func _avoid_obstacles(direction: Vector3) -> Vector3:
	var angles: Array = [0.0, 45.0, -45.0, 90.0, -90.0, 135.0, -135.0]
	for angle in angles:
		var candidate: Vector3 = direction.rotated(Vector3.UP, deg_to_rad(angle))
		if not test_move(global_transform, candidate * obstacle_probe):
			return candidate
	return Vector3.ZERO


## 获取地图生成器（惰性查找，避免节点初始化顺序问题）
func _get_map_gen() -> Node:
	if _map_gen != null and is_instance_valid(_map_gen):
		return _map_gen
	_map_gen = get_tree().get_first_node_in_group("map_gen")
	return _map_gen


## 判断某个世界坐标是否在陆地上（地图不可用时一律视为可走）
func _is_position_on_land(world_pos: Vector3) -> bool:
	var gen: Node = _get_map_gen()
	if gen == null or not gen.has_method("is_land_world"):
		return true
	return gen.is_land_world(world_pos)


## 更新面向方向（**翻转的唯一实现**，追击和移动两条路都走它）
##
## 判据是"**屏幕**左还是右"，不是世界 X：
##   贴图是一块永远正对镜头的广告牌，玩家看到的左右就是屏幕的左右。
##   以前用 direction.x（世界 X），玩家拿 Q/E 把镜头转 90° 之后左右就反了 ——
##   镜头转一次、史莱姆的左右跟着错一次。
##
## ⚠ 符号与玩家相反，别照抄 physics.gd：
##   player.tscn 里的 BaseBody 烘了"180° 旋转 + flip_v = true"，
##   两者抵消后净剩**一次水平镜像**，所以玩家那边是 flip_h = not facing_left；
##   而史莱姆的 Sprite 是干净的单位变换，没有那次镜像，
##   所以这里是 flip_h = facing_left。
##   （2026-09-22 朝向由 look_at(相机方向) 换成 SpriteFacing 时，
##     视觉那一层从"从背面看（多一次镜像）"变成"从正面看"，
##     两个脚本的符号都必须跟着取反，玩家那边漏了 → 人物左右反了。）
func _update_facing(direction: Vector3) -> void:
	var d := Vector3(direction.x, 0.0, direction.z)
	if d.length_squared() <= 0.000001:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_right := cam.global_basis.x
	cam_right.y = 0.0
	if cam_right.length_squared() <= 0.000001:
		return
	# 点积 < 0 ⇒ 目标方向落在镜头右方向的背面 ⇒ 正在往屏幕左边走
	_facing_left = d.dot(cam_right) < 0.0
	sprite.flip_h = _facing_left


## 攻击玩家
func _attack_player(player: Node3D) -> void:
	# 检查冷却
	if _attack_cooldown_timer > 0:
		return
	
	# 检查玩家是否已死亡
	var physics = player.get_node_or_null("Physics")
	if physics == null or physics.current_health <= 0:
		return
	
	# 计算距离
	var player_pos = _get_player_actual_position()
	var to_player = player_pos - global_position
	to_player.y = 0
	var distance = to_player.length()
	
	_log("史莱姆攻击！距离:%.2f", [distance])
	
	# 设置冷却和攻击状态
	_attack_cooldown_timer = attack_cooldown
	_current_attack_target = player
	_is_attacking = true
	
	# 播放攻击动画
	_play_animation("attack")

# ============================================
# 玩家检测
# ============================================

## 获取玩家节点
func _get_player() -> Node3D:
	var player = get_node_or_null("/root/Node3D/player")
	if not player:
		player = get_node_or_null("../player")
	if not player:
		player = get_tree().get_first_node_in_group("player")
	if not player and not _logged_player_not_found:
		_log("史莱姆：未找到玩家节点")
		_logged_player_not_found = true
	return player


## 玩家是否存活（死亡/溺水期间为 false）。
## 玩家死亡后史莱姆不再以玩家为目标：不会进入追击，已在追击的会退回待机巡逻。
## 权威判定走 Physics.is_alive()；没有该方法的老存档/场景退回血量判定。
func _is_player_alive() -> bool:
	var player = _get_player()
	if not player:
		return false
	var physics = player.get_node_or_null("Physics")
	if physics == null:
		return false
	if physics.has_method("is_alive"):
		return bool(physics.call("is_alive"))
	if "current_health" in physics:
		return int(physics.current_health) > 0
	return true


## 获取玩家Physics节点的实际位置
func _get_player_actual_position() -> Vector3:
	var player = _get_player()
	if player:
		var physics = player.get_node_or_null("Physics")
		if physics:
			return physics.global_position
	return Vector3.ZERO


## 检查玩家是否在范围内
func _is_player_in_range(range_dist: float) -> bool:
	var player_pos = _get_player_actual_position()
	if player_pos == Vector3.ZERO:
		return false
	
	var to_player = player_pos - global_position
	to_player.y = 0
	return to_player.length() <= range_dist

# ============================================
# 动画与状态变化
# ============================================

## 播放动画
func _play_animation(anim_name: String) -> void:
	if sprite.sprite_frames and sprite.sprite_frames.has_animation(anim_name):
		sprite.play(anim_name)
	elif _debug_on():
		# 动画缺失是内容问题，但正式游玩时要静默；排查时打开调试开关才会报
		push_warning("史莱姆动画不存在: %s" % anim_name)


## 进入受伤状态
func _hurt() -> void:
	_state = "hurt"
	_is_invincible = true
	_invincibility_timer = invincibility_time
	
	# 打断当前攻击
	_attack_cooldown_timer = 0
	_current_attack_target = null
	_is_attacking = false
	velocity = Vector3.ZERO
	
	# 播放受伤动画
	_play_animation("hurt")
	_log("史莱姆受伤，无敌 %.1f 秒", [invincibility_time])


## 开始落水下沉（脚下没有地面且不处于陆地）
func _start_drowning() -> void:
	if _is_drowning:
		return
	_is_drowning = true
	_state = "drown"
	_is_attacking = false
	_current_attack_target = null
	_path.clear()
	velocity = Vector3.ZERO
	_play_animation("die")
	_log("史莱姆落水！开始下沉")


## 淹死：低于死亡深度时立即执行死亡流程
func _drown() -> void:
	if _state == "dead":
		return
	_state = "dead"
	_is_drowning = false
	_log("史莱姆淹死于 y=%.2f", [global_position.y])
	
	emit_signal("died")
	
	await get_tree().create_timer(0.3).timeout
	queue_free()


## 死亡处理
func _die() -> void:
	_state = "dead"
	_play_animation("die")
	_log("史莱姆死亡")
	
	# 掉落史莱姆凝胶 x1（大纲 3.3.2：100% 掉落）
	# 溺死（_drown）不掉——尸体沉海里了
	ItemDrop.spawn_item_by_id(&"slime_gel", 1, global_position)
	
	emit_signal("died")
	
	await get_tree().create_timer(1.0).timeout
	queue_free()


## 重置巡逻目标：随机取点并确保落在陆地上（避免自己走进海里）
func _reset_patrol_target() -> void:
	for _attempt in range(12):
		var random_offset = Vector3(
			randf_range(-patrol_range, patrol_range),
			0,
			randf_range(-patrol_range, patrol_range)
		)
		var candidate: Vector3 = global_position + random_offset
		if _is_position_on_land(candidate):
			_patrol_target = candidate
			return
	# 周围取不到陆地点（例如在狭长海角上），原地待命
	_patrol_target = global_position

# ============================================
# 动画信号回调
# ============================================

## 动画播放完毕回调
func _on_animation_finished() -> void:
	match sprite.animation:
		"hurt":
			# 受伤动画结束，恢复追击或待机（玩家已死亡则回到待机）
			_state = "idle" if (not _is_player_alive() or not _is_player_in_range(hate_range)) else "chase"
		
		"die":
			# 死亡动画结束，节点已在 _die() 中删除
			pass
		
		"walk":
			# 走路动画自然循环
			pass
		
		"attack":
			# 攻击动画结束
			_on_attack_animation_finished()


## 攻击动画结束处理
func _on_attack_animation_finished() -> void:
	# 重置攻击状态
	_is_attacking = false
	
	# 检查玩家是否在攻击范围内并造成伤害
	if _current_attack_target:
		_apply_attack_damage()
		_current_attack_target = null
	
	# 重新评估状态
	_evaluate_state_after_attack()


## 攻击动画结束时检查并造成伤害
func _apply_attack_damage() -> void:
	var player_pos = _get_player_actual_position()
	var to_player = player_pos - global_position
	to_player.y = 0
	var distance = to_player.length()
	
	if distance <= attack_range:
		var physics = _current_attack_target.get_node_or_null("Physics")
		if physics and physics.has_method("take_damage") and physics.current_health > 0:
			physics.take_damage(attack_damage)
			_log("攻击命中！造成 %d 点伤害", [attack_damage])
		else:
			_log("攻击未命中：玩家已死亡")
	else:
		_log("攻击未命中：玩家已逃离（距离 %.2f > 攻击范围 %.1f）", [distance, attack_range])


## 攻击动画结束后重新评估状态
func _evaluate_state_after_attack() -> void:
	if _is_player_alive() and _is_player_in_range(hate_range):
		# 玩家存活且在仇恨范围内，继续追击
		_state = "chase"
		_idle_timer = 0.0
		
		# 根据距离决定播放什么动画
		var distance = _get_distance_to_player()
		if distance <= stop_distance:
			_play_animation("idle")
		else:
			_play_animation("walk")
	else:
		# 玩家超出仇恨范围，切换到待机
		_state = "idle"
		_idle_timer = 0.0
		_reset_patrol_target()
		_play_animation("idle")


## 获取到玩家的距离
func _get_distance_to_player() -> float:
	var player_pos = _get_player_actual_position()
	var to_player = player_pos - global_position
	to_player.y = 0
	return to_player.length()
