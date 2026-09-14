# test/mock_map_gen.gd — vitals 测试用的假地图生成器（固定地形）
extends Node

var terrain: int = 10


func get_terrain_world(_pos: Vector3) -> int:
	return terrain
