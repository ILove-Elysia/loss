# test/mock_boss_target.gd
# ============================================
# Boss 测试用的"假玩家本体"
#
# 只实现 Boss 真正会用到的那几个接口（因为 Boss 一律按方法名调用，不做静态类型依赖）：
#   take_damage(damage: int)   被招式命中时扣血
#   is_alive() -> bool         权威存活判定（Boss 据此放弃锁定）
#   died 信号                  玩家死亡 → Boss 走脱战路径
#
# 为什么不复用 test/mock_player_body.gd：那个夹具的 take_damage 不改 dead 标记
# （vitals 测试依赖"挨打但不死"的语义），而这里恰恰需要"打死了要发信号"。
# 共享夹具里改语义会波及别的测试，所以另起一个，别动老的那个。
# ============================================

extends CharacterBody3D

signal died

var max_health: int = 100
var current_health: int = 100
var damage_taken: int = 0
var dead: bool = false


func take_damage(damage: int) -> void:
	if dead:
		return
	var before: int = current_health
	current_health = maxi(current_health - damage, 0)
	damage_taken += damage
	if before > 0 and current_health <= 0:
		dead = true
		died.emit()


func is_alive() -> bool:
	return not dead and current_health > 0


## 测试用：直接判死（模拟玩家在 Boss 战里被打死）
func kill() -> void:
	if dead:
		return
	dead = true
	current_health = 0
	died.emit()


## 测试用：复活（Boss 那边靠 is_alive 自愈，不需要额外的"玩家复活"通知）
func revive() -> void:
	dead = false
	current_health = max_health
