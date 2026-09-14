# script/ai/enemy/mob/drone/drone_projectile.gd
# ============================================
# 无人机弹幕 - 远程攻击投射物
#
# 大纲 3.7.2「小型无人机」：
#   攻击力 5（每发）、弹幕速度 4 米/秒
#
# 行为（2026-09-14 用户要求改为"平射"）：
#   - **平行地面直线飞行**：弹道只有水平分量，不下坠也不抬升 ——
#     发射点的高度就是整条弹道的飞行高度（见 launch）
#   - 命中玩家 → 对 Physics 节点造成 5 点伤害
#   - 飞行满 max_distance 米仍未命中 → 直接消失
#   - 撞上静态地形（墙壁 / 岩石）→ 消失
# ============================================

class_name DroneProjectile
extends Node3D

# ============================================
# 导出变量
# ============================================

## 飞行速度（米/秒）
@export var speed: float = 4.0

## 命中伤害
@export var damage: int = 5

## 最大飞行距离（米）：打空的弹幕飞满这段距离就直接消失。
## 由发射它的无人机在 _fire() 里同步（drone.projectile_max_distance）。
@export var max_distance: float = 12.0

## 最长存活时间（秒）—— **兜底**，不是主要的消失规则。
## 正常弹幕都该先在 max_distance 处消失；只有把 speed 配成 0
## 这类异常情况才轮到它兜底，免得弹幕永远挂在场上。
@export var lifetime: float = 6.0

## 是否输出调试日志（命中等）。默认关闭，避免战斗中刷屏。
## 由发射它的无人机在 _fire() 里同步自身的 debug_enabled。
## 全局开关在「设置 → 调试选项 → 敌人 AI / 战斗」，个体开关跟随发射它的无人机。
@export var debug_enabled: bool = false

# ============================================
# 状态变量
# ============================================

## 飞行方向（单位向量）
var _direction: Vector3 = Vector3.ZERO

## 已存活时间
var _age: float = 0.0

## 已飞行距离（米）：累计到 max_distance 就消失
var _traveled: float = 0.0

## 命中检测区域
var _area: Area3D = null

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	_build_visual()
	_build_area()


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= lifetime:          # 兜底，见 lifetime 的说明
		queue_free()
		return

	# 平行地面直线飞行（方向已在 launch() 里抹掉竖直分量）
	var step := speed * delta
	global_position += _direction * step
	_traveled += step
	if _traveled >= max_distance:
		queue_free()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 发射函数
# 由无人机调用，设定飞行方向（自动归一化）
#
# ★ 弹道平行地面（2026-09-14 用户要求）：**抹掉竖直分量**，
#   弹幕只在水平面上直线前进、不下坠。
#   代价是"发射点多高，弹道就飞多高" —— 所以枪口必须压到玩家躯干高度，
#   否则弹幕会平着从玩家头顶飞过去。这一步由无人机在 _fire() 里做
#   （见 drone.fire_height 的说明），本函数只负责方向。
#   发射瞬间锁定方向，玩家横向走位仍然躲得开。
#
# 参数：target_pos - 目标位置，只取水平方向（y 不参与计算）
# ----------------------------------------
func launch(from_pos: Vector3, target_pos: Vector3) -> void:
	global_position = from_pos
	var to_target := target_pos - from_pos
	to_target.y = 0.0                     # ★ 平行地面：弹道不带竖直分量
	if to_target.length() < 0.01:
		_direction = Vector3.FORWARD
	else:
		_direction = to_target.normalized()
	look_at(global_position + _direction, Vector3.UP)

# ============================================
# 私有方法
# ============================================

# 视觉：发光小球 + 短尾迹（拉长的盒子）
func _build_visual() -> void:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	mesh.mesh = sphere

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.15)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.45, 0.15)
	mat.emission_energy_multiplier = 2.0
	mesh.material_override = mat
	add_child(mesh)


# 命中检测：Area3D 监听身体进入
func _build_area() -> void:
	_area = Area3D.new()
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.3
	shape.shape = sphere
	_area.add_child(shape)
	add_child(_area)

	_area.body_entered.connect(_on_body_entered)


## 调试是否开启：全局开关（设置 → 调试选项 → 敌人 AI）或本个体开关
func _debug_on() -> bool:
	return debug_enabled or DebugConfig.is_enabled(DebugConfig.CAT_ENEMY)


## 调试日志：受 _debug_on() 控制，关闭时直接返回
func _log(text: String, args: Array = []) -> void:
	if not _debug_on():
		return
	DebugConfig.log_msg(DebugConfig.CAT_ENEMY, text, args)


func _on_body_entered(body: Node3D) -> void:
	# 向上找 player 组成员
	var node: Node = body
	while node:
		if node.is_in_group("player"):
			var physics := node.get_node_or_null("Physics")
			if physics and physics.has_method("take_damage") \
					and "current_health" in physics and physics.current_health > 0:
				physics.take_damage(damage)
				_log("[无人机] 弹幕命中玩家，造成 %d 点伤害", [damage])
			queue_free()
			return
		node = node.get_parent()

	# 撞到的是别的身体（岩石、地面等）→ 弹幕消失
	# 注意：命中自己的发射者（无人机本体）不会进这个分支，
	# 因为弹幕生成在无人机体外、且无人机不是 player 组
	if body is StaticBody3D or body is CharacterBody3D:
		queue_free()
