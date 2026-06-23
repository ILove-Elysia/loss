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
## 最大生命值
var max_health: int = 100
## 当前生命值
var current_health: int = 100

# ============================================
# 生命周期函数
# ============================================

func _ready():
	# 设置向上方向（用于地板检测）
	up_direction = Vector3.UP
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
	
	# ===== 应用重力 =====
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	# ===== 应用移动（攻击时保持位置） =====
	if not is_attacking:
		if dir.length() > 0:
			dir = dir.normalized()
			velocity.x = dir.x * speed
			velocity.z = dir.z * speed
		else:
			# 没有输入时停止水平移动
			velocity.x = move_toward(velocity.x, 0, speed)
			velocity.z = move_toward(velocity.z, 0, speed)
	else:
		# 攻击时逐渐停止移动
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	# 执行移动（关键！）
	move_and_slide()
	
	# ===== 同步视觉节点位置和朝向 =====
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
## @param damage 伤害值
func take_damage(damage: int) -> void:
	current_health = max(0, current_health - damage)
	print("玩家受到", damage, "点伤害！剩余生命:", current_health, "/", max_health)
	
	# 更新HUD血量显示
	_update_hud_health()
	
	if current_health <= 0:
		# 死亡
		print("玩家死亡！")
		is_attacking = false
		spr.play("die")

## 更新HUD血量显示
func _update_hud_health() -> void:
	var hud = get_node_or_null("/root/Node3D/CanvasLayer/HUDUI")
	if hud and hud.has_method("update_health"):
		hud.update_health(current_health, max_health)

## 在攻击动画播放过程中进行伤害检测
## 使用球体检测，检测攻击范围内的所有敌人
func _on_attack_hitbox_active() -> void:
	# 获取攻击方向（角色朝向）
	var attack_dir = -visual_node.basis.z
	
	# 计算检测起点（稍微偏移避免击中自己）
	var query_origin = global_position + Vector3(0, 0.5, 0)
	# 计算检测终点
	var query_target = query_origin + attack_dir * attack_range
	
	# 使用圆柱体/球体检测
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsShapeQueryParameters3D.new()
	
	# 创建球体形状用于检测
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = attack_range * 0.5  # 检测半径
	
	query.shape = sphere_shape
	query.transform = Transform3D(Basis(), query_origin + attack_dir * (attack_range * 0.5))
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
		
		# 尝试获取父节点上的 take_damage 方法（因为碰撞体可能在子节点）
		var target = collider.get_parent()
		if not target.has_method("take_damage"):
			target = collider  # 如果父节点没有，使用碰撞体本身
		
		if target.has_method("take_damage"):
			# 通知目标受到伤害
			target.take_damage(attack_damage)
			print("命中目标: %s，造成 %d 点伤害" % [target.name, attack_damage])

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
		print("玩家死亡动画结束")

## 攻击动画播放到特定帧时的回调（用于激活伤害检测）
func _on_attack_animation_frame_changed() -> void:
	if spr.animation == "attack":
		# 在第2帧时激活伤害检测（攻击动作开始）
		if spr.frame == 1:
			_on_attack_hitbox_active()
