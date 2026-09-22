# test/vitals_test.gd
# ============================================
# 电量与体温系统测试（大纲 3.1 / 3.2 验收）
#
# 全部用 mock：假 map_gen（固定地形）、假 HUD（记录调用）、假玩家本体，
# 外加真实的 Equipment + Inventory（核心状态挂在物品实例上，必须真流转）。
# 不生成地图，秒级完成。
#
# 覆盖：
#   [1]~[2c] 体温 / 温度值：区域系数、档位→体温速度、中性区回中
#   [3]~[8]  自身电量：过冷过热漏电、供电耗电、低电减速、濒危掉血、高电回血、HUD
#   [9]      核心（外置电量）对人物本体零影响
#   [10]     核心是独立单位：拆下重装电量不恢复（本次改造的核心目的）
#   [10b]    核心自身温度值越界 → 每秒 -0.5 核心电量
#   [10c]    掉在地上的核心按自己的坐标独立推进
#   [11]     熔炉热源
#   [12]     死亡冻结体温 + 复活半属性 + 携带核心复活清零（用户需求 2026-09-16）
# ============================================

extends SceneTree

var _fail: int = 0
var _vitals: Node
var _mock_body: CharacterBody3D
var _mock_map: Node
var _mock_hud: Node
var _equipment: PlayerEquipment
var _inventory: Inventory
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

	# 装备槽 + 背包：核心的电量 / 温度值挂在**物品实例**上（ItemInstance.core），
	# 要验证"核心是独立单位"就必须有真实的槽位与背包（[9] / [10] 用）。
	_equipment = preload("res://script/player/equipment.gd").new()
	_equipment.name = "Equipment"
	player_root.add_child(_equipment)

	_inventory = preload("res://script/inventory/inventory.gd").new()
	_inventory.name = "Inventory"
	player_root.add_child(_inventory)
	await process_frame

	_vitals = PlayerVitals.new()
	_vitals.name = "Vitals"
	player_root.add_child(_vitals)
	await process_frame

	# ⚠ 基础用例（3~7）按**机器人语义**跑：内置电量（power_embedded）。
	# 默认角色是冒险家（无内置电量），直接跑会让"漏电 / 低电减速 / 归零掉血 / 高电回血"
	# 全部卡在门禁上不生效。这里直接赋字段模拟 robot，不依赖选角流程。
	# ⚠ has_power 现在是**只读计算属性**（= power_embedded 或装了核心），
	#   不能再直接赋值 —— 只能通过 power_embedded / 装备核心来改变它。
	# 内置与外置两种语义的差别由 [9] 专门覆盖。
	_vitals.power_embedded = true
	_vitals.set_power(100.0)

	# ---- 1. 初始状态 ----
	print("[1] 初始状态")
	_check(is_equal_approx(_vitals.current_power, 100.0), "初始电量 100")
	_check(is_equal_approx(_vitals.current_temperature, 30.0), "初始体温 30")

	# ---- 2. 温度值：区域温度系数驱动（大纲 3.2.3） ----
	# 温度值是**独立于体温的另一个属性**（0~1000），本身不伤人，
	# 由区域的「温度系数」（带符号，温度值/秒）持续推动：正 = 加热，负 = 降温，0 = 中性区。
	print("[2] 温度值：区域系数驱动")
	_check(is_equal_approx(_vitals.current_temperature_value, 500.0),
		"初始温度值 500（正常档正中）")

	_vitals.current_temperature_value = 500.0
	_set_terrain(14)  # 火山 +6/s
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 560.0),
		"火山 10 秒：温度值 500→560（+6/s）")

	_vitals.current_temperature_value = 500.0
	_set_terrain(15)  # 雪地 -6/s
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 440.0),
		"雪地 10 秒：温度值 500→440（-6/s）")

	# 中性区（草原 / 丛林 / 矿区 / 沙滩 / 沙地 / 海洋，系数 0）：
	# 温度值**不停表**，而是以 ±10/秒 朝常温 500 收 —— 从火山 / 雪地
	# 带回来的余温余寒会在这类地形上被慢慢抹平。只有火山(14) 与雪地(15) 是极端区。
	for t: int in [7, 8, 10, 11, 12, 13]:
		_vitals.current_temperature_value = 0.0
		_set_terrain(t)
		_vitals._tick(10.0)
		_check(is_equal_approx(_vitals.current_temperature_value, 100.0),
			"地形 %d 10 秒：温度值 0→100（中性区 +10/s 回中）" % t)

	_vitals.current_temperature_value = 800.0
	_set_terrain(10)
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 700.0),
		"草原 10 秒：温度值 800→700（中性区 -10/s 回中，高低两个方向都收）")

	_vitals.current_temperature_value = 490.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 500.0),
		"回中封顶在常温 500，不会冲过头")

	# 边界：温度值被压在 0 ~ 1000 之内
	_vitals.current_temperature_value = 300.0
	_set_terrain(15)
	_vitals._tick(60.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 0.0),
		"雪地久留：温度值触底 0，不越界")

	# ---- 2b. 温度值档位 → 体温变化速度（大纲 3.2.4） ----
	print("[2b] 温度值档位 → 体温变化速度")
	_vitals.current_temperature_value = 99.0
	_check(_vitals.get_temp_band() == "very_cold", "温度值 99 → 非常冷")
	_vitals.current_temperature_value = 100.0
	_check(_vitals.get_temp_band() == "cold", "温度值 100 → 冷")
	_vitals.current_temperature_value = 349.0
	_check(_vitals.get_temp_band() == "cold", "温度值 349 → 冷")
	_vitals.current_temperature_value = 350.0
	_check(_vitals.get_temp_band() == "normal", "温度值 350 → 正常")
	_vitals.current_temperature_value = 649.0
	_check(_vitals.get_temp_band() == "normal", "温度值 649 → 正常")
	_vitals.current_temperature_value = 650.0
	_check(_vitals.get_temp_band() == "hot", "温度值 650 → 热")
	_vitals.current_temperature_value = 899.0
	_check(_vitals.get_temp_band() == "hot", "温度值 899 → 热")
	_vitals.current_temperature_value = 900.0
	_check(_vitals.get_temp_band() == "very_hot", "温度值 900 → 非常热")

	# 升温侧（火山正在加热，正速度生效）
	_set_terrain(14)
	_vitals.current_temperature_value = 950.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 50.0),
		"非常热 10 秒：体温 30→50（+2°/s）")

	_vitals.current_temperature_value = 700.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 40.0),
		"热 10 秒：体温 30→40（+1°/s）")

	_vitals.current_temperature_value = 500.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 30.0),
		"正常 10 秒：体温不变（0°/s）")

	# 降温侧（雪地正在降温，负速度生效）
	_set_terrain(15)
	_vitals.current_temperature_value = 200.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 20.0),
		"冷 10 秒：体温 30→20（-1°/s）")

	_vitals.current_temperature_value = 50.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 10.0),
		"非常冷 10 秒：体温 30→10（-2°/s）")

	# ---- 2c. 档位速度原样生效：环境在加热 ≠ 体温立刻回升 ----
	print("[2c] 环境推力不改变档位速度")
	# 带着一身寒气冲进火山：温度值才 50（非常冷档），体温仍按 -2°/s 继续掉，
	# 要等温度值被推过 650 才会回升 —— 过冷的人进温暖环境不会立刻变暖。
	_set_terrain(14)
	_vitals.current_temperature_value = 50.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 10.0),
		"火山 + 非常冷档：体温继续掉 30→10（-2°/s，环境在加热也不管用）")
	_check(is_equal_approx(_vitals.current_temperature_value, 110.0),
		"同一帧里温度值照常被顶高 50→110（+6/s）")

	# 反向：带着一身热气进雪地，温度值还高（非常热档）→ 体温继续升。
	_set_terrain(15)
	_vitals.current_temperature_value = 950.0
	_vitals.current_temperature = 30.0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 50.0),
		"雪地 + 非常热档：体温继续升 30→50（+2°/s，环境在降温也不管用）")

	# 中性区：体温由身体自己回温到 30（10/分钟），温度值同时以 +10/s 回中
	_set_terrain(10)
	_vitals.current_temperature_value = 200.0
	_vitals.current_temperature = 0.0
	_vitals._tick(60.0)
	_check(is_equal_approx(_vitals.current_temperature, 10.0),
		"草原 1 分钟：体温 0→10（自然回温 10/分钟）")
	_check(is_equal_approx(_vitals.current_temperature_value, 500.0),
		"草原 1 分钟：温度值 200→500（回中 +10/s，60 秒足够补满）")

	# 上面这些用例一共流过约 240 秒游戏时间，饱食度已被消耗近半、体温也在
	# 过冷/过热区间待过，伤害与回血的**累积器**里可能留着小尾巴。
	# 后面的用例（[6] 濒危掉血要数到整数 5、[7] 高电量回血要刚好 +5）都按
	# "刚开局"结算，这里一次性归零，免得温度用例的副作用串过去。
	_vitals.set_hunger(100.0)
	_vitals.set_power(100.0)
	_vitals._damage_acc = 0.0
	_vitals._regen_acc = 0.0
	_vitals._starve_acc = 0.0
	_mock_body.damage_taken = 0
	_mock_body.healed = 0
	_mock_body.current_health = 100

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
	# 用户决策：核心这块电池**对人物本体零影响** —— 归零不掉血、低电不减速、
	# **高电也不回血**；它只决定"耗电交互还能不能用"，以及它自己的温度值越界时掉自己的电。
	# 2026-09-16 改造后，"外置电量"不再长在玩家身上，而在核心实例上，
	# 所以要装一枚真核心才算这条用例的真实形态。
	print("[9] 外置电量：不影响人物本体")
	_vitals.power_embedded = false          # 冒险家：没有自身电量
	_inventory.add_item(ItemRegistry.get_registry().get_item(&"power_core"), 1)
	_check(_equipment.equip(&"power_core"), "装入动力核心（外置电池）")
	_check(_vitals.has_power, "装核心 → has_power 变 true（运行时计算属性）")

	_vitals.current_temperature = 30.0
	_vitals.set_hunger(100.0)  # 隔离饥饿掉血，免得混进 damage_taken
	_vitals.set_power(0.0)
	_mock_body.damage_taken = 0
	_vitals._tick(5.0)
	_check(_mock_body.damage_taken == 0, "自身电量 0 持续 5 秒：**不掉血**（核心不伤本体）")
	_check(is_equal_approx(_vitals.get_speed_multiplier(), 1.0), "自身电量 0：**不减速**")

	_vitals.current_temperature = 30.0
	_vitals.set_power(100.0)
	_mock_body.current_health = 60
	_mock_body.damage_taken = 0
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

	# ---- 10. 核心是独立单位：拆下重装，电量不恢复 ----
	# 这是本次改造的**直接目的**：改造前装备槽只记"装的是哪件物品"，
	# 拆下再装上会造一枚全新满电核心 —— 电量凭空回满。
	# 现在电量挂在 ItemInstance.core 上，随实例在 背包 ↔ 装备槽 之间流转，引用不变。
	print("[10] 核心是独立单位（拆下重装电不满）")
	var core: PowerCoreInstance = _equipment.get_core_instance()
	_check(core != null, "核心槽里有核心状态（不是空壳）")
	_check(is_equal_approx(core.power, 100.0), "核心出厂满电 100")
	_check(is_equal_approx(_vitals.get_core_power(), 100.0), "vitals 读到核心电量 100")

	_vitals.set_core_power(40.0)
	_check(is_equal_approx(core.power, 40.0), "核心电量设为 40")

	_check(_equipment.unequip(ItemData.EquipSlot.CORE), "拆下核心")
	_check(not _vitals.has_power, "拆下核心 → has_power 变 false")
	# 内置电量角色不靠核心也有电（此刻核心槽确实是空的）
	_vitals.power_embedded = true
	_check(_vitals.has_power, "内置电量角色：没装核心也算「有电可用」")
	_vitals.power_embedded = false
	var core_slots: Array[int] = _inventory.find_item_slots(&"power_core")
	_check(core_slots.size() == 1, "核心回到背包（1 件）")
	var back: ItemInstance = _inventory.get_item(core_slots[0])
	_check(back != null and back.core == core, "背包里就是同一个核心实例（引用不变）")
	_check(back != null and back.core != null and is_equal_approx(back.core.power, 40.0),
		"背包里的它仍是 40 电")

	_check(_equipment.equip(&"power_core"), "重新装上核心")
	_check(is_equal_approx(_equipment.get_core_instance().power, 40.0),
		"**重装后仍是 40 —— 不再回满**（本次改造的核心目的）")

	# ---- 10b. 核心自身的温度值：过冷 / 过热 → 每秒 -0.5 电量 ----
	# 核心温度值按**它所在位置**（这里 = 玩家脚下）的环境系数独立推进，
	# 与玩家体温无关。舒适区 = 350 ~ 650，越界才漏电。
	print("[10b] 核心温度值越界漏电")
	var core2: PowerCoreInstance = _equipment.get_core_instance()
	core2.temperature_value = 500.0
	core2.power = 100.0
	_set_terrain(15)  # 雪地：温度系数 -6/s
	_vitals._tick(10.0)
	_check(is_equal_approx(core2.temperature_value, 440.0),
		"雪地 10 秒：核心温度值 500→440")
	_check(is_equal_approx(core2.power, 100.0), "440 仍在舒适区（350~650）：不掉电")

	_vitals._tick(10.0)
	_check(is_equal_approx(core2.temperature_value, 380.0), "再 10 秒：380")
	_check(is_equal_approx(core2.power, 100.0), "380 仍舒适：不掉电")

	_vitals._tick(10.0)
	_check(is_equal_approx(core2.temperature_value, 320.0), "跌破 350 → 过冷")
	_check(is_equal_approx(core2.power, 95.0), "过冷这一帧就漏 5（0.5/s × 10s）")

	_vitals._tick(10.0)
	_check(is_equal_approx(core2.temperature_value, 260.0), "继续冻：260")
	_check(is_equal_approx(core2.power, 90.0), "再过冷 10 秒：再 -5")
	# 两块电池是两行：核心行由 set_core_active() 亮起，数值走 update_core_power()
	_check(_mock_hud.last_core_active == 1, "HUD 收到「核心电量行显示」推送")
	_check(_mock_hud.last_core_power == 90, "HUD 收到核心电量 90")
	_set_terrain(10)  # 复位中性区

	# ---- 10c. 地上核心：按自己的坐标独立推进 ----
	# 掉在地上的核心不归 vitals 管，由 ItemDrop._process 用自己的世界坐标推进。
	print("[10c] 地上核心独立计算")
	var drop := ItemDrop.spawn_item_by_id(&"power_core", 1, Vector3(3, 0, 3))
	_check(drop != null and drop.instance != null, "核心掉落物携带物品实例")
	_check(drop.instance.core != null, "掉落物携带核心状态")
	drop.instance.core.temperature_value = 500.0
	drop.instance.core.power = 100.0
	drop._age = 1.0

	# 身上那枚的核心电量保持不动，作为对照
	var carried_before: float = _equipment.get_core_instance().power
	_set_terrain(15)  # 雪地
	for i in range(4):
		drop._process(10.0)
	_check(is_equal_approx(drop.instance.core.temperature_value, 260.0),
		"地上核心 40 秒：温度值 500→260（按自己坐标的雪地 -6/s）")
	_check(is_equal_approx(drop.instance.core.power, 90.0),
		"地上核心过冷漏电 100→90（独立结算）")
	_check(is_equal_approx(_equipment.get_core_instance().power, carried_before),
		"身上那枚核心的电量不受地上这枚影响（各算各的）")
	_set_terrain(10)
	drop.queue_free()

	# ---- 11. 熔炉热源：持续 +20/秒 加热（不封顶在常温） ----
	# 雪地(-6/s) 里往火边一站，热源**压过地形**：温度值以 +20/s 一路走高，
	# 越过常温 500 也照样加热，最高顶到温度值上限 1000。
	# 补温途中体温**不会立刻回升**：温度值还在冷档时照旧按档位往下掉，
	# 要等温度值越过 650（热档）才转为升温 —— 于是在火边待久了会过热，得自己挪开。
	print("[11] 熔炉热源")
	_set_terrain(15)
	_vitals.current_temperature_value = 200.0
	_vitals.current_temperature = 5.0
	var heater := MockHeater.new()
	root.add_child(heater)
	BuildingSystem.register(heater)
	await process_frame

	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 400.0),
		"熔炉旁 10 秒：温度值 200→400（+20/s 压过雪地的 -6/s）")
	_check(is_equal_approx(_vitals.current_temperature, -5.0),
		"补温途中体温照旧失温 5→-5（温度值还在冷档）")

	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 600.0),
		"再 10 秒：温度值 400→600（**越过 500 仍然 +20/s**，不在常温停手）")
	_check(is_equal_approx(_vitals.current_temperature, -5.0),
		"体温停在 -5：本帧档位是正常档（0°/s）")

	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 800.0),
		"再 10 秒：温度值 600→800（进入热档）")

	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 1000.0),
		"再 10 秒：温度值 800→1000（顶到上限）")
	_check(is_equal_approx(_vitals.current_temperature, 5.0),
		"热档开始回温：体温 -5→5（+1°/s，火边待久了会过热）")

	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature_value, 1000.0),
		"温度值封顶在 1000，不再上涨")
	_check(is_equal_approx(_vitals.current_temperature, 25.0),
		"非常热档：体温 5→25（+2°/s）—— 一直烤下去一定会过热")

	BuildingSystem.unregister(heater)
	heater.queue_free()

	# ---- 12. 死亡冻结体温 + 复活半属性 + 携带核心复活清零（用户需求 2026-09-16） ----
	print("[12] 死亡冻结 / 复活半属性 / 核心清零")
	# 准备：内置电量角色 + 装一枚核心，体温放在极端档（过冷），各处电量各有值
	_vitals.power_embedded = true
	_vitals.set_power(100.0)
	_vitals.set_hunger(100.0)
	_vitals.current_temperature = 5.0
	_vitals.current_temperature_value = 200.0
	var c12: PowerCoreInstance = _equipment.get_core_instance()
	_check(c12 != null, "复活用例：装备槽有核心")
	# 给核心一个非满、非 0 的值，验证"复活清零"而不是"回半 / 回满"
	c12.power = 80.0
	c12.temperature_value = 800.0
	_set_terrain(15)  # 雪地：本应快速降温

	# (a) 死亡期间：玩家体温 + 温度值 + 身上核心温度值**全部冻结**
	_mock_body.dead = true
	_mock_body.current_health = 0
	_vitals._tick(10.0)
	_check(is_equal_approx(_vitals.current_temperature, 5.0),
		"死亡 10 秒：玩家体温不变（5.0 冻结）")
	_check(is_equal_approx(_vitals.current_temperature_value, 200.0),
		"死亡 10 秒：玩家温度值不变（200 冻结）")
	_check(is_equal_approx(c12.temperature_value, 800.0),
		"死亡 10 秒：身上核心温度值不变（800 冻结）")

	# (b) 复活：体征回到上限一半；携带核心电量清零
	# 实际复活由 physics.revive() 设半血并调用本 reset()；这里直接调 reset() 验体征。
	_mock_body.dead = false
	_vitals.reset()
	_check(is_equal_approx(_vitals.current_power, 50.0),
		"复活：自身电量 = 上限一半（100→50）")
	_check(is_equal_approx(_vitals.current_hunger, 50.0),
		"复活：饱食度 = 上限一半（100→50）")
	_check(is_equal_approx(_vitals.current_temperature, 30.0),
		"复活：体温回到常温 30")
	_check(is_equal_approx(_vitals.current_temperature_value, 500.0),
		"复活：温度值回到中性 500")
	_check(is_equal_approx(_equipment.get_core_instance().power, 0.0),
		"复活：携带核心电量清零（不是一半，是 0）")
	_set_terrain(10)
	_vitals.power_embedded = false

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


## 假熔炉：BuildingSystem.get_heater_at() 只看两样东西 ——
## 节点的 building_id 和它的 global_position（半径从真实定义表里取）。
## 所以摆一个带 building_id 的空 Node3D 就足够了，不必真造一栋建筑。
class MockHeater:
	extends Node3D

	var building_id: StringName = &"furnace"
