# test/crafting_core_tab_test.gd
# ============================================
# 「核心」制作栏的可见性回归测试
#
# 为什么需要它：
#   核心栏是**第二套**"有条件可见"的栏目 —— 角色专属栏看"你是谁"，
#   核心栏看"你装备了什么"。两套机制挤在同一个 Category 枚举里，
#   最容易犯的错是"枚举末尾追加了新分类，但上界常量没跟着改"：
#   那样核心栏会掉进角色过滤分支，而角色注册表里根本没有对应 key，
#   结果是【这一栏永远不出现】，而且不报任何错 —— 只看代码看不出来。
#   所以把这几条不变量钉住。
#
# 运行：
#   godot --headless --path . --script res://test/crafting_core_tab_test.gd
# ============================================

extends SceneTree

var _fail: int = 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS  ", msg)
	else:
		_fail += 1
		print("  FAIL  ", msg)


func _initialize() -> void:
	await process_frame

	var C := CraftingRecipe.Category
	CraftingSystem.set_core_unlocked(false)

	print("--- [1] 未解锁：核心栏与它的配方都不可见 ---")
	_check(not CraftingSystem.is_category_visible(int(C.CORE)),
		"未装核心时核心栏不可见")
	_check(not CraftingSystem.get_visible_categories().has(int(C.CORE)),
		"未装核心时标签列表里没有「核心」")
	_check(CraftingSystem.get_recipes(int(C.CORE)).is_empty(),
		"未装核心时核心栏查不到配方")

	print("--- [2] 核心栏不是角色专属栏（枚举上界没改就会踩的坑）---")
	_check(not CraftingRecipe.is_exclusive(int(C.CORE)),
		"核心栏不算角色专属栏，否则会掉进角色过滤而永远不可见")
	_check(CraftingRecipe.is_exclusive(int(C.MACHINE)),
		"机器人的机械栏仍然是角色专属栏")
	_check(CraftingRecipe.category_name(int(C.CORE)) == "核心",
		"分类显示名为「核心」")

	print("--- [3] 解锁后：核心栏出现，配方可查 ---")
	CraftingSystem.set_core_unlocked(true)
	_check(CraftingSystem.is_category_visible(int(C.CORE)),
		"装上核心后核心栏可见")
	_check(CraftingSystem.get_visible_categories().has(int(C.CORE)),
		"标签列表里出现「核心」")
	var recipes := CraftingSystem.get_recipes(int(C.CORE))
	_check(not recipes.is_empty(), "核心栏有配方（%d 条）" % recipes.size())
	if not recipes.is_empty():
		_check(recipes[0].output_item_id == &"thermal_underwear",
			"占位配方产物 = 保暖内衣")

	print("--- [4] 与角色专属栏互不干扰 ---")
	var adv := CraftingSystem.get_visible_categories("adventurer")
	_check(adv.has(int(C.SURVIVAL)), "冒险家看得到「求生」")
	_check(not adv.has(int(C.MACHINE)), "冒险家看不到「机械」")
	_check(adv.has(int(C.CORE)), "冒险家装了核心也能看到「核心」")
	var bot := CraftingSystem.get_visible_categories("robot")
	_check(bot.has(int(C.MACHINE)), "机器人看得到「机械」")
	_check(not bot.has(int(C.SURVIVAL)), "机器人看不到「求生」")
	_check(bot.has(int(C.CORE)), "机器人装了核心也能看到「核心」")

	print("--- [5] 拆掉核心后栏目消失 ---")
	CraftingSystem.set_core_unlocked(false)
	_check(not CraftingSystem.get_visible_categories().has(int(C.CORE)),
		"拆掉核心后「核心」栏消失")
	_check(CraftingSystem.get_recipes(int(C.CORE)).is_empty(),
		"拆掉核心后核心栏配方为空")

	print("")
	if _fail == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fail)
	quit(_fail)
