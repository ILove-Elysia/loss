# test/vitals_test.gd
# ============================================
# 电量与体温系统测试（大纲 3.1 / 3.2 验收）
#
# 全部用 mock：假 map_gen（固定地形）、假 HUD（记录调用）、假玩家本体。
# 不生成地图，秒级完成。
# ============================================

extends SceneTree

var _fail: int = 0
var _vitals: Node
var _mock_body: CharacterBody3D
var _mock_map: Node
var _mock_hud: Node
var _terrain: int = 10


const MOCK_BODY := preload("res://test/mock_player_body.gd")
const MOCK_MAP := preload("res://test/mock_map_gen.gd")
const MOCK_HUD := preload("res://test/mock_hud.gd")


func _initialize() -> void:
	await process_frame
	await process_frame

	# ---- 搭 mock 环境 ----
	var player_root := Node3D.new()
	player_root.name = "player"
	root.add_child(player_root)
	await process_frame

	_mock_body = MOCK_BODY.new()
	player_root.add_child(_mock_body)
	await process_frame

	_mock_map = MOCK_MAP.new()
	_mock_map.add_to_group("map_gen")
	root.add_child(_mock_map)
	await process_frame

	_mock_hud = MOCK_HUD.new()
	_mock_hud.add_to_group("hud")
	root.add_child(_mock_hud)
	await process_frame

	_vitals = PlayerVitals.new()
	_vitals.name = "Vitals"
	player_root.add_child(_vitals)
	await process_frame

	# ⚠ 基础用例（3~7）按**机器人语义**跑：内置电量（has_power + power_embedded）。
	# 默认角色是冒险家（无电量），直接跑会让"漏电 / 低电减速 / 归零掉血 / 高电回血"
	# 全部卡在门禁上不生效。这里直接赋字段模拟 robot，不依赖选角流程。
	# 内置与外置两种语义的差别由 [9] 专门覆盖。
	_vitals.has_power = true
	_vitals.power_embedded = true
	_vitals.set_power(100.0)

	# ---- 1. 初始状态 ----
	print("[1] 初始状态")
	_check(is_equal_approx(_vitals.current_power, 100.0), "初始电量 100")
	_check(is_equal_approx(_vitals.current_temperature, 30.0), "初始体温 30")

	# ---- 2. 体温：区域驱动（大纲 3.2.3） ----
	print("[2] 体温区域变化")
	_set_terrain(15)  # 雪地区 -15/分钟
	_vitals._tick(60.0)
	_check(is_equal_approx(_vitals.current_temperature, 15.0), "雪地 1 分钟：30→15")

	_set_terrain(14)  # 火山区 +15/分钟
	_vitals._tick(60.0)
	_check(is_equal_approx(_vitals.current_temperature, 30.0), "火山 1 分钟：15→30")

	_set_terrain(10)  # 草原 趋向30
	_vitals.current_temperature = 0.0
	_vitals._tick(60.0)
	_check(is_equal_approx(_vitals.current_temperature, 10.0), "草原 1 分钟：0→10（趋向30速率10）")

	# ---- 3. 过冷漏电（大纲 3.2.2：每秒 -0.5） ----
	print("[3] 过冷漏电")
	# 注意：上一段「草原回温」从 0 度升温，全程过冷区间，已经漏了不少电——
	# 这里重置回 100，隔离各用例的初始条件。
	_vitals.set_power(100.0)
	_vitals.current_temperature = 5.0  # 过冷区间
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_power, 95.0), "过冷 10 秒：100→95")

	_vitals.current_temperature = 45.0  # 过热区间
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_power, 90.0), "过热 10 秒：95→90")

	_vitals.current_temperature = 30.0  # 恢复正常，不再漏电
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_power, 90.0), "体温正常后不再漏电")

	# ---- 4. 电量接口（大纲 3.1.2） ----
	print("[4] 供电与耗电")
	_check(_vitals.add_power(10.0) > 0.0, "电池供电 +10")
	_check(is_equal_approx(_vitals.current_power, 100.0), "供电不超过上限 100")
	_check(_vitals.consume_power(30.0), "耗电 30 成功")
	_check(is_equal_approx(_vitals.current_power, 70.0), "电量 70")
	_vitals.set_power(5.0)
	_check(not _vitals.consume_power(30.0), "电量不足时耗电失败")
	_check(is_equal_approx(_vitals.current_power, 5.0), "失败不扣电")

	# ---- 5. 低电量减速（大纲 3.1.3） ----
	print("[5] 低电量减速")
	_check(_vitals.get_speed_multiplier() < 0.75, "电量 5：移速惩罚 0.7")
	_vitals.set_power(50.0)
	_check(is_equal_approx(_vitals.get_speed_multiplier(), 1.0), "电量 50：正常移速")

	# ---- 6. 濒危掉血（大纲 3.1.3：每秒 -1 HP） ----
	print("[6] 濒危掉血")
	_vitals.current_temperature = 30.0  # 保持正常体温，排除漏电干扰
	# 前几段在过冷 / 过热区间待过，而"极端温度扣血"是**所有角色**都吃的惩罚
	#（大纲 3.2.2 决策 ③），累积值已经记在 damage_taken 上 —— 先清零再测本条，
	# 否则这里会数到 5 + 前面几段的温度伤害。
	_mock_body.damage_taken = 0
	_vitals.set_power(0.0)
	_vitals._tick(5.0)
	_check(_mock_body.damage_taken == 5, "电量 0 持续 5 秒：掉 5 HP（实际 %d）" % _mock_body.damage_taken)

	# ---- 7. 高电量回血（大纲 3.1.4：+5 HP/分钟） ----
	print("[7] 高电量回血")
	_mock_body.current_health = 50
	_mock_body.damage_taken = 0
	_vitals.set_power(100.0)
	_vitals._tick(60.0)
	_check(_mock_body.current_health == 55, "电量>80 持续 1 分钟：+5 HP（实际 %d）" % _mock_body.current_health)
	_check(_mock_body.damage_taken == 0, "高电量时不掉血")

	# ---- 8. HUD 同步 ----
	print("[8] HUD 同步")
	_check(_mock_hud.last_power == roundi(_vitals.current_power), "HUD 收到电量刷新")
	_check(_mock_hud.last_temp == roundi(_vitals.current_temperature), "HUD 收到体温刷新")
	_check(_mock_hud.last_power_active == 1, "HUD 收到「电量行亮起」推送")

	# ---- 9. 外置电量的语义（冒险家 / 魔女装入动力核心） ----
	# 用户决策：外置电池**对人物本体零影响** —— 归零不掉血、低电不减速、
	# **高电也不回血**；唯一保留的是漏电（环境在耗这块电池）。
	print("[9] 外置电量：不影响人物本体")
	_vitals.power_embedded = false
	_vitals.has_power = true
	_vitals.current_temperature = 30.0
	_vitals.set_hunger(100.0)  # 隔离饥饿掉血，免得混进 damage_taken
	_vitals.set_power(0.0)
	_mock_body.damage_taken = 0
	_vitals._tick(5.0)
	_check(_mock_body.damage_taken == 0, "电量 0 持续 5 秒：**不掉血**（外置电池）")
	_check(is_equal_approx(_vitals.get_speed_multiplier(), 1.0), "电量 0：**不减速**（外置电池）")

	_vitals.set_power(100.0)
	_vitals.current_temperature = 5.0  # 过冷
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_power, 95.0), "过冷 10 秒：外置电量同样漏 5")

	_vitals.current_temperature = 30.0
	_vitals.set_power(100.0)
	_mock_body.current_health = 60
	_vitals.set_hunger(100.0)
	_vitals._tick(60.0)
	_check(_mock_body.current_health == 60,
		"电量>80 1 分钟：外置电量**不回血**（回血仅内置，实际 %d）" % _mock_body.current_health)

	# 对照组：同样条件切回内置电量，回血应恢复 —— 证明门禁挂在 power_embedded 上，
	# 而不是被 hunger / health 之类的旁路挡住（防止改错地方还全绿）。
	_vitals.power_embedded = true
	_vitals.set_power(100.0)
	_vitals.set_hunger(100.0)
	_vitals._tick(60.0)
	_check(_mock_body.current_health == 65,
		"内置电量：同样条件下 +5 HP（对照组，实际 %d）" % _mock_body.current_health)
	_vitals.power_embedded = false

	# ---- 10. 动力核心装拆（set_has_power） ----
	print("[10] 动力核心装拆")
	_vitals.has_power = false
	_vitals.set_has_power(true)
	_check(_vitals.has_power and is_equal_approx(_vitals.current_power, 100.0),
		"装入核心：解锁电量并满电")
	_vitals.set_has_power(false)
	_check(not _vitals.has_power and is_equal_approx(_vitals.current_power, 0.0),
		"拆除核心：关闭电量并清零")

	# 内置电量（机器人）不可关闭
	_vitals.power_embedded = true
	_vitals.set_has_power(true)
	_vitals.set_has_power(false)
	_check(_vitals.has_power, "内置电量：set_has_power(false) 被拒，仍为 true")

	print("=================================")
	if _fail == 0:
		print("===== 全部检查通过 =====")
	else:
		print("===== 有 %d 项不通过 =====" % _fail)
	quit()


func _set_terrain(t: int) -> void:
	_terrain = t
	_mock_map.set("terrain", t)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  [通过] ", label)
	else:
		print("  [失败] ", label)
		_fail += 1
