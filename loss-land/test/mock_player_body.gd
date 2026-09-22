# test/mock_player_body.gd — vitals 测试用的假玩家本体
extends CharacterBody3D

var max_health: int = 100
var current_health: int = 100
var damage_taken: int = 0
var healed: int = 0
## 死亡态标记：vitals 用 is_alive() 判定玩家是否活着，以冻结体温（用户需求 2026-09-16）
var dead: bool = false


func take_damage(d: int) -> void:
	current_health = max(0, current_health - d)
	damage_taken += d


func heal(a: int) -> void:
	current_health = min(max_health, current_health + a)
	healed += a


## 玩家是否存活：死亡态或 HP 见底都算死。vitals._tick 据此冻结体温。
func is_alive() -> bool:
	return not dead and current_health > 0
