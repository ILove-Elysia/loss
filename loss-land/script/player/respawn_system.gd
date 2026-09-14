# script/player/respawn_system.gd
# ============================================
# 玩家复活 / 重生点管理（静态类，无 autoload，headless 测试友好）
#
# 流程：死亡 → 5 秒倒计时 → 5 秒后「复活」按钮可点。
# 重生点默认在出生点（map_generator_3d.teleport_player_to_start 调
# register_spawn 注册）。后续「床 / 篝火改重生点」之类只要调
# set_respawn_point 覆盖即可，无需改别处。
#
# 为什么是静态类而不是挂在节点上：
#   - 复活是全局唯一状态，不需要每局多个实例；
#   - 不依赖场景树，headless 测试直接调，不会被 autoload 缺失拖垮。
# ============================================

class_name RespawnSystem
extends RefCounted

## 死亡后到按钮可点的倒计时（秒）
const RESPAWN_DELAY := 5.0

## 重生点世界坐标（默认出生点；未来由床/篝火调用 set_respawn_point 覆盖）
static var respawn_point: Vector3 = Vector3.ZERO
## 玩家是否处于死亡待复活状态
static var dead: bool = false
## 剩余倒计时（秒）
static var countdown: float = 0.0

## 注册出生点：仅在还没设过时写入，避免读档/再次传送覆盖掉玩家自定义的床位。
static func register_spawn(pos: Vector3) -> void:
	if respawn_point == Vector3.ZERO:
		respawn_point = pos

## 显式设置重生点（未来「床 / 篝火」等功能用）。
static func set_respawn_point(pos: Vector3) -> void:
	respawn_point = pos

## 玩家死亡：进入死亡态 + 启动倒计时；重生点还没设过时用当前位置兜底。
static func on_died(pos: Vector3) -> void:
	dead = true
	countdown = RESPAWN_DELAY
	if respawn_point == Vector3.ZERO:
		respawn_point = pos

## 每帧推进倒计时（由 HUD._process 驱动）。
static func tick(delta: float) -> void:
	if dead and countdown > 0.0:
		countdown = maxf(0.0, countdown - delta)

## 倒计时是否结束、可以复活。
static func can_revive() -> bool:
	return dead and countdown <= 0.0

## 实际复活：清死亡态（玩家 reset 满状态在 physics.gd.revive 里做）。
static func clear_dead() -> void:
	dead = false
	countdown = 0.0
