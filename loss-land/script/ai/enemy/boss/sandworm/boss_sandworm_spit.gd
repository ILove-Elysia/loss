# script/ai/enemy/boss/sandworm/boss_sandworm_spit.gd
# ============================================
# 沙虫②吐沙的**沙弹**（一发平飞出去的沙团）
#
# 为什么要单独写一发、而不是复用无人机的 DroneProjectile：
#   ① DroneProjectile 的伤害结算写死在 `_on_body_entered` 里，而且要求命中体
#      **是 player 节点下有 Physics 子节点**（带 take_damage + current_health）。
#      测试用的假玩家（test/mock_boss_target.gd）**没有 CollisionShape、也没有 Physics 子节点**，
#      复用的话这一发在回归里永远打不中任何东西 —— 等于没测。
#   ② 沙虫的招式统计走 Boss 的 attack_landed 信号（见基类 _on_spit_struck），
#      弹道必须能把"我命中了"回传给 Boss，DroneProjectile 没有这个口子。
#   ③ 无人机那 5 点伤害的弹幕和 Boss 一发 14 点的吐沙，手感标尺完全不同，
#      共用一个脚本迟早要加一堆 if。
#
# 做法（和 Boss 自己的判定判据保持同源）：
#   · **直线平飞**，不下坠（与无人机一致：发射点多高就飞多高）
#   · 命中 = 沙弹**这一帧扫过的线段** ↔ 目标本体的**平面**距离 ≤ hit_radius
#     —— 只看平面距离，不看高度差：平射弹道的高度等于发射高度，
#        用三维距离会变成"从玩家头顶飞过、永远打不中"（drone_projectile.gd 踩过）。
#     —— 用"线段"而不是"当前点"：速度是可调的，逐点判定在低速帧率下可能
#        一步跨过玩家（隧穿）。线段距离让命中判定与帧率、速度都无关。
#   · 目标本体由**发射者传进来**（Boss 已经有唯一权威的 player_body() 入口），
#     本脚本自己不去搜场景 —— 免得又多一处"玩家到底是谁"的答案。
#   · 命中时自己扣血 + 发出 struck，然后销毁；飞满 max_distance / 超时也销毁。
#
# ⚠ 不撞地形：撞墙不会消失（Boss 战场是空旷沙地，暂时够用）。
#   要加的话走 `intersect_ray` + mask 2（障碍物层），别用 Area3D —— 原因见上①。
# ============================================

class_name BossSandwormSpit
extends Node3D

## 命中时发出（**扣血已经做完**）：Boss 接它去转报 attack_landed。
## ⚠ 参数顺序**必须与 Boss._on_spit_struck 完全一致**，而且这里**不许用 Callable.bind()**
##   来补 attack_id：`connect(f.bind(x))` 传进去的参数是"信号参数在前、bind 参数在后"，
##   手写时极易搞反顺序 —— 症状是运行时 `Method expected 2 argument(s), but called with 3`
##   （2026-09-26 就这么炸了一次）。让沙弹自己记住是谁发的，两边签名就能一眼对上。
signal struck(attack_id: StringName, damage: int)

# ============================================
# 导出（由发射它的 Boss 在 _fire_spit 里同步招式的配置）
# ============================================

## 发射它的招式的 id（只用于命中回传与日志，不影响弹道行为）
@export var attack_id: StringName = &""
## 飞行速度（米/秒）。沙虫吐沙 18 ⇒ 约 3.6 倍玩家满速，"快速弹道"
@export var speed: float = 18.0
## 命中伤害
@export var damage: int = 14
## 命中半径（沙弹 ↔ 目标的平面距离 ≤ 它就判命中）
@export var hit_radius: float = 0.9
## 飞满这么多米还没命中就消失
@export var max_distance: float = 16.0
## 最长存活时间（秒）—— **兜底**，不是主要消失规则。
## 正常都该先在 max_distance 处消失；只有 speed 被配成 0 这类异常才轮到它兜底
@export var lifetime: float = 3.0
## 是否输出调试日志（命中）。跟随发射它的 Boss 的 debug_enabled
@export var debug_enabled: bool = false
## 占位色（沙团）。⚠ 必须走 UNSHADED，否则本工程的环境光会把它抬亮成白块
@export var color: Color = Color(0.50, 0.42, 0.26)

# ============================================
# 状态
# ============================================

var _direction: Vector3 = Vector3.FORWARD
var _target: Node3D = null
var _traveled: float = 0.0
var _age: float = 0.0
var _done: bool = false

# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	_build_visual()


func _physics_process(delta: float) -> void:
	if _done:
		return
	_age += delta
	var previous: Vector3 = global_position
	var step: float = speed * delta
	global_position += _direction * step
	_traveled += step
	# 命中判定排在消失判定前面：最后一步正好够到目标时，算命中、不算打空
	if _hit_target(previous):
		return
	if _traveled >= max_distance or _age >= lifetime:
		_done = true
		queue_free()

# ============================================
# 公共方法
# ============================================

## 发射。**必须先把本节点 add_child 进场景树**（look_at 需要全局变换）。
## from_position 是沙虫的嘴（Boss 负责算好、并把高度压在玩家躯干上）；
## aim_at 是**发射这一刻**玩家的位置 —— 之后玩家走位就躲得掉了，这是"可躲"的来源。
## target 是玩家本体（Boss 的 player_body()），命中判定只认它
func launch(from_position: Vector3, aim_at: Vector3, target: Node3D) -> void:
	global_position = from_position
	_target = target
	var to_target: Vector3 = aim_at - from_position
	to_target.y = 0.0
	if to_target.length() < 0.01:
		_direction = Vector3.FORWARD
	else:
		_direction = to_target.normalized()
	look_at(global_position + _direction, Vector3.UP)

# ============================================
# 私有
# ============================================

## 本帧扫过的那一段有没有碰到目标。返回 true 表示已经结算完毕（节点即将销毁）
func _hit_target(previous: Vector3) -> bool:
	if _target == null or not is_instance_valid(_target):
		_target = null
		return false
	if _segment_distance_xz(previous, global_position, _target.global_position) > hit_radius:
		return false
	_strike()
	return true


## 命中结算：先扣血、再上报、最后销毁。
## ⚠ 扣血可能**同步**把玩家打死（玩家会发 died ⇒ Boss 立刻脱战）——
##   本脚本在那条链路里只是个旁观者，所以后面不许再碰 _target / 场景状态。
##   Boss 那边接 struck 时同样只许转报、不许读 _attack（见 _on_spit_struck）。
func _strike() -> void:
	_done = true
	var dealt: int = damage
	if _target.has_method("take_damage"):
		_target.call("take_damage", damage)
	_log("招式 %s 的沙弹命中，造成 %d 点伤害", [attack_id, dealt])
	struck.emit(attack_id, dealt)
	queue_free()


## 点到线段的**平面**距离（沙弹这一帧扫过的线段 ↔ 目标）。
## 用它而不是"当前点距离"，是为了让判定跟帧率、跟 speed 都无关：
## 速度配到 60 m/s、帧率掉到 30 时，一步就跨 2 m —— 逐点判定会直接从玩家身上穿过去。
static func _segment_distance_xz(a: Vector3, b: Vector3, p: Vector3) -> float:
	var abx: float = b.x - a.x
	var abz: float = b.z - a.z
	var length_sq: float = abx * abx + abz * abz
	if length_sq < 0.000001:
		var dx0: float = p.x - a.x
		var dz0: float = p.z - a.z
		return sqrt(dx0 * dx0 + dz0 * dz0)
	var t: float = clampf(((p.x - a.x) * abx + (p.z - a.z) * abz) / length_sq, 0.0, 1.0)
	var closest_x: float = a.x + abx * t
	var closest_z: float = a.z + abz * t
	var dx: float = p.x - closest_x
	var dz: float = p.z - closest_z
	return sqrt(dx * dx + dz * dz)


## 占位表现：一颗沙团。正式美术接入后由特效取代。
func _build_visual() -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	sphere.radial_segments = 12
	sphere.rings = 6
	mesh.mesh = sphere
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	# ⚠ 全工程 3D 网格一律 UNSHADED：受光材质在本工程的环境光下会被抬亮约 2.2 倍，
	#   沙团会变成白球（详见 boss_sandworm_base.gd 里同一段说明）
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)


## 调试开关：跟随发射它的 Boss（全局开关在「设置 → 调试选项 → 敌人 AI」）
func _debug_on() -> bool:
	return debug_enabled or DebugConfig.is_enabled(DebugConfig.CAT_ENEMY)


func _log(text: String, args: Array = []) -> void:
	if not _debug_on():
		return
	DebugConfig.log_msg(DebugConfig.CAT_ENEMY, text, args)
