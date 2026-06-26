# script/enemy/slime.gd
# ============================================
# 史莱姆敌人
#
# 功能：
#   - 待机、移动、追击玩家
#   - 受到玩家攻击时掉血
#   - 死亡时消失
#
# 使用方式：
#   1. 创建场景时自动添加此脚本
#   2. 玩家攻击命中时会调用 take_damage()
# ============================================

class_name Slime
extends CharacterBody3D

# ============================================
# 导出变量 - 可在编辑器中修改
# ============================================

## 最大生命值
@export var max_health: int = 30
## 移动速度（米/秒）
@export var move_speed: float = 1.5
## 仇恨范围（米）- 超过此距离会停止追击
@export var hate_range: float = 8.0
## 停止距离（米）- 到达此距离停止追击并准备攻击
@export var stop_distance: float = 1.0
## 攻击范围（米）- 攻击动画结束时玩家必须在范围内才会受到伤害
@export var attack_range: float = 1.5
## 巡逻范围（米）- 待机时随机移动的范围
@export var patrol_range: float = 3.0
## 受伤后无敌时间（秒）
@export var invincibility_time: float = 0.5
## 攻击伤害
@export var attack_damage: int = 5
## 攻击冷却时间（秒）
@export var attack_cooldown: float = 1.0

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
## 是否面向左侧
var _facing_left: bool = false
## 当前攻击目标（用于动画结束后造成伤害）
var _current_attack_target: Node3D = null
## 是否正在播放攻击动画
var _is_attacking: bool = false
## 待机计时器（用于控制待机时间）
var _idle_timer: float = 0.0

# ============================================
# 信号
# ============================================

## 当史莱姆死亡时发出
signal died()

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 初始化
	_current_health = max_health
	
	# 设置向上方向（CharacterBody3D 需要）
	up_direction = Vector3.UP
	
	# 设置导航代理
	navigation.path_desired_distance = 0.5
	navigation.target_desired_distance = 0.5
	
	# 连接动画信号
	sprite.animation_finished.connect(_on_animation_finished)
	
	# 播放待机动画
	_play_animation("idle")
	
	# 设置随机巡逻目标
	_reset_patrol_target()

func _physics_process(delta: float) -> void:
	# 更新无敌状态
	if _invincibility_timer > 0:
		_invincibility_timer -= delta
		if _invincibility_timer <= 0:
			_is_invincible = false
	
	# 更新攻击冷却
	if _attack_cooldown_timer > 0:
		_attack_cooldown_timer -= delta
	
	# 调试：每0.5秒打印一次距离
	_debug_timer += delta
	if _debug_timer >= 0.5:
		_debug_timer = 0.0
		var player_pos = _get_player_actual_position()
		if player_pos != Vector3.ZERO:
			var to_player = player_pos - global_position
			to_player.y = 0
			print("【调试】状态:", _state, " | 距离:", to_player.length(), " | 仇恨:", hate_range, " | 攻击距离:", stop_distance)
	
	# 状态机处理
	match _state:
		"idle":
			_process_idle(delta)
		"walk":
			_process_walk(delta)
		"chase":
			_process_chase(delta)
		"hurt":
			pass  # 受伤状态由动画结束处理
		"dead":
			pass  # 死亡状态不做处理
	
	# ===== 始终朝向摄像机 =====
	_look_at_camera()

# ============================================
# 公共方法 - 供外部调用
# ============================================

## 受到伤害
## @param damage 伤害值
func take_damage(damage: int) -> void:
	# 如果无敌则不受到伤害
	if _is_invincible:
		return
	
	# 减少生命值
	_current_health -= damage
	print("史莱姆受到 %d 点伤害，剩余 %d/%d" % [damage, _current_health, max_health])
	
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
# 私有方法 - 状态机
# ============================================

## 处理待机状态
func _process_idle(delta: float) -> void:
	# 使用计时器代替 await，避免协程问题
	_idle_timer += delta
	
	if _idle_timer >= 1.5:
		_idle_timer = 0.0
		_state = "walk"
		_reset_patrol_target()
	
	# 检查玩家是否在仇恨范围内
	var player = _get_player()
	if player and _is_player_in_range(hate_range):
		_state = "chase"
		_idle_timer = 0.0

## 处理巡逻状态
func _process_walk(delta: float) -> void:
	# 检查是否到达巡逻目标
	var to_target = _patrol_target - global_position
	to_target.y = 0
	
	if to_target.length() < 0.5:
		# 到达目标，等待后重新巡逻
		_state = "idle"
		_reset_patrol_target()
		return
	
	# 检查玩家是否在仇恨范围内
	var player = _get_player()
	if player and _is_player_in_range(hate_range):
		# 开始追击
		_state = "chase"
		return
	
	# 向巡逻目标移动
	_move_towards(_patrol_target)

## 处理追击状态
func _process_chase(delta: float) -> void:
	var player = _get_player()
	var player_pos = _get_player_actual_position()
	
	# 如果玩家不存在或位置无效，停止追击
	if not player or player_pos == Vector3.ZERO:
		print("史莱姆：玩家不存在或位置无效")
		_state = "idle"
		_reset_patrol_target()
		return
	
	# 检查玩家是否超出仇恨范围
	var to_player = player_pos - global_position
	to_player.y = 0
	var distance = to_player.length()
	
	# 调试：显示状态变化
	if distance > hate_range:
		print("史莱姆：玩家逃离！距离=", distance, "（仇恨范围=", hate_range, "）")
		_state = "idle"
		_reset_patrol_target()
		return
	
	# 面向玩家
	_look_at_direction(to_player.normalized())
	
	# 如果正在播放攻击动画，忽略其他逻辑（让动画完整播放）
	if sprite.animation == "attack":
		velocity = Vector3.ZERO
		return
	
	# 在攻击范围内且冷却结束时攻击（不受停止距离限制）
	if distance <= attack_range and _attack_cooldown_timer <= 0:
		_attack_player(player)
	
	# 在停止距离内停止移动，否则继续靠近
	if distance <= stop_distance:
		velocity = Vector3.ZERO
		print("追击状态：距离=", distance, "，在停止距离内，停止移动")
	else:
		_move_towards(player_pos)
		print("追击状态：距离=", distance, "，停止距离=", stop_distance, "，正在向玩家移动")

# ============================================
# 私有方法 - 朝向控制
# ============================================

## 让史莱姆始终面向摄像机
func _look_at_camera() -> void:
	var cam = get_viewport().get_camera_3d()
	if cam:
		# 计算朝向摄像机的方向
		var look_dir = cam.global_position - global_position
		look_dir.y = 0  # 只在水平面旋转
		if look_dir.length() > 0.001:
			_look_at_direction(look_dir.normalized())

## 让史莱姆朝向指定方向
## @param direction 目标方向（水平面，已归一化）
func _look_at_direction(direction: Vector3) -> void:
	if direction.length() > 0.001:
		look_at(global_position + direction, Vector3.UP)
		# 根据方向翻转精灵
		sprite.flip_h = direction.x > 0

# ============================================
# 私有方法 - 移动与导航
# ============================================

## 攻击玩家
func _attack_player(player: Node3D) -> void:
	if _attack_cooldown_timer > 0:
		return
	
	# 检查玩家是否已死亡 - 直接访问属性
	var physics = player.get_node_or_null("Physics")
	if physics == null:
		return
	
	# 如果玩家已死亡，不攻击
	if physics.current_health <= 0:
		return
	
	# 使用统一的距离计算方法
	var player_pos = _get_player_actual_position()
	var to_player = player_pos - global_position
	to_player.y = 0
	var distance = to_player.length()
	
	print("史莱姆准备攻击！距离=", distance, "，停止距离=", stop_distance, "，攻击范围=", attack_range)
	
	_attack_cooldown_timer = attack_cooldown
	
	# 保存攻击目标（保存Player节点引用）
	_current_attack_target = player
	
	# 设置攻击状态
	_is_attacking = true
	
	# 播放攻击动画
	_play_animation("attack")
	print("史莱姆开始攻击！等待动画结束后检查玩家是否在攻击范围内")

## 向目标点移动
func _move_towards(target: Vector3) -> void:
	# 直接计算方向（不依赖导航系统）
	var direction = target - global_position
	direction.y = 0
	
	if direction.length() > 0.1:
		direction = direction.normalized()
		
		# 设置速度（保持在地上）
		velocity = direction * move_speed
		velocity.y = 0
		
		# 执行移动
		move_and_slide()
		
		# 更新朝向
		_update_facing(direction)
		
		# 播放走路动画
		if sprite.animation != "walk":
			_play_animation("walk")

## 更新面向方向
func _update_facing(direction: Vector3) -> void:
	# 根据移动方向设置翻转
	_facing_left = direction.x < 0
	sprite.flip_h = _facing_left

## 重置巡逻目标
func _reset_patrol_target() -> void:
	# 在当前位置周围随机选择一个新的巡逻点
	var random_offset = Vector3(
		randf_range(-patrol_range, patrol_range),
		0,
		randf_range(-patrol_range, patrol_range)
	)
	_patrol_target = global_position + random_offset

# ============================================
# 私有方法 - 玩家检测
# ============================================

## 获取玩家节点
func _get_player() -> Node3D:
	var player = get_node_or_null("/root/Node3D/player")
	if not player:
		player = get_node_or_null("../player")
	if not player:
		player = get_tree().get_first_node_in_group("player")
	if not player and not _logged_player_not_found:
		print("史莱姆：未找到玩家节点！")
		_logged_player_not_found = true
	return player

## 获取玩家Physics节点的实际位置
func _get_player_actual_position() -> Vector3:
	var player = _get_player()
	if player:
		var physics = player.get_node_or_null("Physics")
		if physics:
			return physics.global_position
	return Vector3.ZERO

## 检查玩家是否在范围内（使用Physics的实际位置）
func _is_player_in_range(range_dist: float) -> bool:
	var player_pos = _get_player_actual_position()
	if player_pos == Vector3.ZERO:
		return false
	
	var to_player = player_pos - global_position
	to_player.y = 0
	return to_player.length() <= range_dist

# ============================================
# 私有方法 - 动画与状态变化
# ============================================

## 播放动画
func _play_animation(anim_name: String) -> void:
	if sprite.sprite_frames:
		if sprite.sprite_frames.has_animation(anim_name):
			sprite.play(anim_name)
			print("_play_animation: 播放 ", anim_name)
		else:
			print("_play_animation: 动画 ", anim_name, " 不存在！可用动画:", sprite.sprite_frames.get_animation_names())
	else:
		print("_play_animation: sprite_frames 为空！")

## 进入受伤状态
func _hurt() -> void:
	_state = "hurt"
	_is_invincible = true
	_invincibility_timer = invincibility_time
	
	# 打断当前攻击
	_attack_cooldown_timer = 0
	_current_attack_target = null
	velocity = Vector3.ZERO
	
	# 播放受伤动画
	if sprite.sprite_frames and sprite.sprite_frames.has_animation("hurt"):
		sprite.play("hurt")
		print("史莱姆：播放受伤动画")
	else:
		print("史莱姆：受伤动画不存在！可用动画:", sprite.sprite_frames.get_animation_names())
	
	# 受伤后无敌
	print("史莱姆进入受伤状态，无敌时间: %.1f秒" % invincibility_time)

## 死亡处理
func _die() -> void:
	_state = "dead"
	_play_animation("die")
	print("史莱姆死亡！")
	
	# 发射死亡信号
	emit_signal("died")
	
	# 延迟删除节点
	await get_tree().create_timer(1.0).timeout
	queue_free()

# ============================================
# 动画信号回调
# ============================================

## 动画播放完毕回调
func _on_animation_finished() -> void:
	match sprite.animation:
		"hurt":
			# 受伤动画结束，恢复追击或待机
			_state = "idle" if not _is_player_in_range(hate_range) else "chase"
		"die":
			# 死亡动画结束，节点已在 _die() 中删除
			pass
		"walk":
			# 走路动画自然循环，不需要特殊处理
			pass
		"attack":
			# 重置攻击状态
			_is_attacking = false
			
			# 攻击动画结束，检查玩家是否仍在攻击范围内
			if _current_attack_target:
				# 使用统一的距离计算方法
				var player_pos = _get_player_actual_position()
				var to_player = player_pos - global_position
				to_player.y = 0
				var distance = to_player.length()
				
				if distance <= attack_range:
					var physics = _current_attack_target.get_node_or_null("Physics")
					if physics and physics.has_method("take_damage") and physics.current_health > 0:
						physics.take_damage(attack_damage)
						print("史莱姆攻击动画结束！玩家在攻击范围内（距离=", distance, "），造成", attack_damage, "点伤害")
					else:
						print("史莱姆攻击动画结束！玩家已死亡")
				else:
					print("史莱姆攻击动画结束！玩家已逃离攻击范围（距离=", distance, "，攻击范围=", attack_range, "）")
				
				_current_attack_target = null
			
			# 攻击动画结束，重新评估状态
			if _is_player_in_range(hate_range):
				_state = "chase"
				_idle_timer = 0.0
				print("攻击动画结束！玩家在仇恨范围内，切换到追击状态")
				
				# 根据距离决定播放什么动画
				var player_pos = _get_player_actual_position()
				var to_player = player_pos - global_position
				to_player.y = 0
				var distance = to_player.length()
				
				if distance <= stop_distance:
					_play_animation("idle")
					print("播放 idle 动画（在停止距离内）")
				else:
					_play_animation("walk")
					print("播放 walk 动画（正在追击）")
			else:
				_state = "idle"
				_idle_timer = 0.0
				_reset_patrol_target()
				print("攻击动画结束！玩家超出仇恨范围，切换到待机状态")
				_play_animation("idle")
				print("播放 idle 动画")
