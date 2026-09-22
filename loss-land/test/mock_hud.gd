# test/mock_hud.gd — vitals 测试用的假 HUD（记录刷新调用）
extends Node

var last_power: int = -1
var last_temp: int = -9999
## 电量行是否亮起（-1 = 从未收到过推送）。对应真 HUD 的 set_power_active()。
var last_power_active: int = -1
## 核心电量行：数值 / 是否显示（-1 = 从未收到过推送）。
## 两块电池是分开的两行 —— 自身电量（⚡，仅内置）与核心电量（🔋，有核心才出现）。
var last_core_power: int = -1
var last_core_active: int = -1
var power_calls: int = 0
var temp_calls: int = 0


func update_power(p: int) -> void:
	last_power = p
	power_calls += 1


func set_power_active(active: bool) -> void:
	last_power_active = 1 if active else 0


func update_core_power(p: int) -> void:
	last_core_power = p


func set_core_active(active: bool) -> void:
	last_core_active = 1 if active else 0


func update_temperature(t: int) -> void:
	last_temp = t
	temp_calls += 1
