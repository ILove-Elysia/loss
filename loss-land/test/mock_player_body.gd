# test/mock_player_body.gd — vitals 测试用的假玩家本体
extends CharacterBody3D

var max_health: int = 100
var current_health: int = 100
var damage_taken: int = 0
var healed: int = 0


func take_damage(d: int) -> void:
	current_health = max(0, current_health - d)
	damage_taken += d


func heal(a: int) -> void:
	current_health = min(max_health, current_health + a)
	healed += a
