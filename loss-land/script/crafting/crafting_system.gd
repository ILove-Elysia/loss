# script/crafting/crafting_system.gd
# ============================================
# 合成系统 - 配方的唯一来源 + 合成执行逻辑
#
# 为什么用 class_name + 静态方法，而不是 autoload：
#   和 ItemRegistry / UIManager 同样的理由——`godot --script` 的 headless
#   模式不加载 autoload，全局名在编译期不可见，测试会直接编译失败。
#   静态调用编译期合法，运行期也不需要场景里有节点。
#
# 配方按大纲 3.4.1 ~ 3.4.5 编写，外加：
#   电池 = 史莱姆凝胶 x3 + 石头 x1
#   依据大纲 3.1.2「电池：击败敌人掉落、制作获得」，
#   但大纲没写电池的材料，这里按"凝胶做电解质 + 石头做外壳"设定，可随时调。
#   铁剑 = 铁锭 x3 + 木棍 x2、铁镐 = 铁锭 x3 + 木棍 x2
#   大纲只写到「铁锭」（3.4.5），但没写铁锭用来做什么。为了让矿物链
#   有出口（挖矿 → 冶炼 → 变强），补了这两件铁制装备，可随时调数值。
#
# 关于 requires_station（工作台/熔炉）：
#   建造系统实装后（大纲 3.5），requires_station 才真正生效：
#   空 = 徒手可合成；非空 = 必须已放置对应的制作站。
#   "已放置"是【永久解锁】语义，不要求玩家站在旁边——
#   否则走远后合成界面整片变灰，玩家会以为是 bug。
#   详见 building_system.gd 顶部说明。
#
# 关于装备效果（攻击力+10 / 防御+3 / 采集速度+50%）：
#   这些写在物品描述里，但需要装备系统才能生效，本次未实现（见物品描述）。
# ============================================

class_name CraftingSystem
extends RefCounted

## 已构建的配方表（懒加载）
static var _recipes: Array[CraftingRecipe] = []
static var _built: bool = false

## 「核心」制作栏是否解锁（装上带 unlocks_core_tab 的核心后由 PlayerEquipment 置位）。
##
## 为什么不在这里自己去找玩家装备：CraftingSystem 是纯静态类，没有场景引用；
## 装备状态只有 PlayerEquipment 知道，由它在装备 / 卸下 / 读档恢复时推过来，
## 无头测试里也能直接 set_core_unlocked(true) 验证核心栏，不依赖场景。
static var core_tab_unlocked: bool = false


## 设置核心栏解锁状态（由 PlayerEquipment 调用）
static func set_core_unlocked(unlocked: bool) -> void:
	if core_tab_unlocked == unlocked:
		return
	core_tab_unlocked = unlocked
	DebugConfig.log_msg(DebugConfig.CAT_CRAFTING, "[合成] 核心制作栏 %s",
		["已解锁" if unlocked else "已关闭"])


# ============================================
# 配方查询
# ============================================

# ----------------------------------------
# 获取全部配方函数
#
# 必须返回副本：调用方（合成界面）会拿着这个数组做 clear()，
# 若直接交出内部数组 _recipes，调用方一清空就等于把全局配方表清空了
# ——实测切换一次分类标签，13 条配方会全部消失。
#
# 只返回**当前角色可用**的配方：其他角色的专属栏配方（求生 / 炼药 / 机械）
# 不出现在"全部"里，否则冒险家会看到自己根本做不出来的机器人配方。
# ----------------------------------------
static func get_all_recipes(char_id: String = "") -> Array[CraftingRecipe]:
	_ensure_built()
	var result: Array[CraftingRecipe] = []
	for r in _recipes:
		if _is_recipe_visible(r, char_id):
			result.append(r)
	return result


# ----------------------------------------
# 按分类获取配方函数
# 参数用 int 而不是枚举类型：合成界面用 -1 表示"全部"，
# 枚举做参数时会卡在 -1 的合法性/隐式转换上，用 int 最省心。
#
# 同样按角色过滤：切到别人的专属栏不该有任何配方（正常也切不到，
# 因为标签页不会生成，这里是兜底）。
# ----------------------------------------
static func get_recipes(category: int, char_id: String = "") -> Array[CraftingRecipe]:
	_ensure_built()
	var result: Array[CraftingRecipe] = []
	for r in _recipes:
		if r.category == category and _is_recipe_visible(r, char_id):
			result.append(r)
	return result


# ============================================
# 专属制作栏（大纲 2.2.5）
# ============================================

# ----------------------------------------
# 该配方对当前角色是否可见函数
# 通用栏恒可见；专属栏只有 craft_category 对得上才可见。
# ----------------------------------------
static func _is_recipe_visible(recipe: CraftingRecipe, char_id: String = "") -> bool:
	if recipe == null:
		return false
	# 核心栏看"装备了什么"，不看角色，必须单独判——
	# 否则它会落进下面的"非专属栏恒可见"分支，核心配方对所有人可见。
	if CraftingRecipe.is_core_tab(int(recipe.category)):
		return core_tab_unlocked
	if not CraftingRecipe.is_exclusive(int(recipe.category)):
		return true
	if char_id.is_empty():
		char_id = CharacterRegistry.get_active_id()
	return CharacterRegistry.has_craft_category(char_id, _exclusive_key(recipe.category))


# ----------------------------------------
# 该分类对当前角色是否可见函数（合成 UI 建标签页时用）
# ----------------------------------------
static func is_category_visible(category: int, char_id: String = "") -> bool:
	if CraftingRecipe.is_core_tab(int(category)):
		return core_tab_unlocked
	if not CraftingRecipe.is_exclusive(int(category)):
		return true
	if char_id.is_empty():
		char_id = CharacterRegistry.get_active_id()
	return CharacterRegistry.has_craft_category(char_id, _exclusive_key(category))


# ----------------------------------------
# 当前角色能看到的全部分类函数（通用栏 + 他自己的专属栏 + 已解锁的核心栏）
# 合成 UI 遍历它建标签页；加新分类不用改 UI。
# ----------------------------------------
static func get_visible_categories(char_id: String = "") -> Array[int]:
	var out: Array[int] = []
	for c in CraftingRecipe.COMMON_CATEGORIES:
		out.append(int(c))
	var C := CraftingRecipe.Category
	for c in [int(C.SURVIVAL), int(C.ALCHEMY), int(C.MACHINE)]:
		if is_category_visible(int(c), char_id):
			out.append(int(c))
	if is_category_visible(int(C.CORE), char_id):
		out.append(int(C.CORE))
	return out


# ----------------------------------------
# 分类枚举 → 专属栏 key（CharacterRegistry.CRAFT_*）函数
# ----------------------------------------
static func _exclusive_key(category: int) -> StringName:
	var C := CraftingRecipe.Category
	var cat: int = int(category)
	# 用 if 而不是 match：match 的分支必须是常量表达式，写 int(C.SURVIVAL) 不合法
	if cat == int(C.SURVIVAL):
		return CharacterRegistry.CRAFT_SURVIVAL
	if cat == int(C.ALCHEMY):
		return CharacterRegistry.CRAFT_ALCHEMY
	if cat == int(C.MACHINE):
		return CharacterRegistry.CRAFT_MACHINE
	return &""


# ----------------------------------------
# 按 ID 查找配方函数
# ----------------------------------------
static func find_recipe(recipe_id: StringName) -> CraftingRecipe:
	_ensure_built()
	for r in _recipes:
		if r.recipe_id == recipe_id:
			return r
	return null


# ----------------------------------------
# 重建配方表函数
# 测试里若改过配方数据，可调用它强制重建
# ----------------------------------------
static func rebuild() -> void:
	_recipes = []
	_built = false
	_ensure_built()


# ============================================
# 合成校验
# ============================================

# ----------------------------------------
# 材料状态函数
# 给 UI 用：每种材料的"需求/拥有/是否足够"
#
# 返回：[{ "item_id": StringName, "need": int, "have": int, "ok": bool }]
# ----------------------------------------
static func get_material_status(recipe: CraftingRecipe, inventory: Node) -> Array[Dictionary]:
	var status: Array[Dictionary] = []
	if recipe == null:
		return status

	for m in recipe.materials:
		var item_id := StringName(m.get("item_id", &""))
		var need := int(m.get("count", 0))
		var have := 0
		if inventory != null and inventory.has_method("get_item_count"):
			have = inventory.get_item_count(item_id)
		status.append({
			"item_id": item_id,
			"need": need,
			"have": have,
			"ok": have >= need
		})
	return status


# ----------------------------------------
# 能否合成函数
# 只看材料是否够（背包是否有空位留给产物，在 craft 里兜底回滚）
# ----------------------------------------
static func can_craft(recipe: CraftingRecipe, inventory: Node) -> bool:
	if recipe == null or inventory == null:
		return false
	# 制作站不满足时直接否掉：材料再全也不让做
	if not has_required_station(recipe):
		return false
	if not inventory.has_method("has_item"):
		return false

	for m in recipe.materials:
		var item_id := StringName(m.get("item_id", &""))
		var need := int(m.get("count", 0))
		if need <= 0:
			continue
		if not inventory.has_item(item_id, need):
			return false

	return true


# ============================================
# 执行合成
# ============================================

# ----------------------------------------
# 合成函数
# 先扣材料再放产物；若产物放不进背包（背包满）则原样退回材料。
#
# 参数：
#   recipe    - 要合成的配方
#   inventory - 玩家背包（Inventory 节点）
# 返回：实际产出数量（0 = 失败）
# ----------------------------------------
static func craft(recipe: CraftingRecipe, inventory: Node) -> int:
	if recipe == null or inventory == null:
		return 0
	if not can_craft(recipe, inventory):
		return 0

	var registry := ItemRegistry.get_registry()
	if registry == null:
		return 0
	var output: ItemData = registry.get_item(recipe.output_item_id)
	if output == null:
		DebugConfig.warn_msg(DebugConfig.CAT_CRAFTING, "CraftingSystem: 配方 %s 的产物 %s 不存在", [recipe.recipe_id, recipe.output_item_id])
		return 0

	# 1) 扣除材料（记录实际扣了多少，便于失败回滚）
	var consumed: Array[Dictionary] = []
	for m in recipe.materials:
		var item_id := StringName(m.get("item_id", &""))
		var need := int(m.get("count", 0))
		if need <= 0:
			continue
		var got: int = inventory.remove_item(item_id, need)
		consumed.append({"item_id": item_id, "count": got})
		if got < need:
			# 理论上不会走到这里（can_craft 已校验），保守回滚
			_rollback(inventory, consumed)
			return 0

	# 2) 放入产物
	var added: int = inventory.add_item(output, recipe.output_count)
	if added <= 0:
		# 背包塞不下产物——退回材料，不让玩家白白损失
		_rollback(inventory, consumed)
		return 0

	return added


# ----------------------------------------
# 按 ID 合成函数（UI/快捷键用）
# ----------------------------------------
static func craft_by_id(recipe_id: StringName, inventory: Node) -> int:
	return craft(find_recipe(recipe_id), inventory)


# ----------------------------------------
# 回滚函数：把已扣的材料加回背包
# ----------------------------------------
static func _rollback(inventory: Node, consumed: Array[Dictionary]) -> void:
	var registry := ItemRegistry.get_registry()
	if registry == null:
		return
	for c in consumed:
		var item_id := StringName(c.get("item_id", &""))
		var count := int(c.get("count", 0))
		if count <= 0:
			continue
		var data: ItemData = registry.get_item(item_id)
		if data != null:
			inventory.add_item(data, count)


# ============================================
# 配方表构建（大纲 3.4）
# ============================================

static func _ensure_built() -> void:
	if _built:
		return
	_build_recipes()
	_built = true


static func _add(recipe_id: StringName, output_id: StringName, output_count: int,
		category: CraftingRecipe.Category, materials: Array, notes: String = "",
		station: StringName = &"") -> void:
	var r := CraftingRecipe.new()
	r.recipe_id = recipe_id
	r.output_item_id = output_id
	r.output_count = output_count
	r.category = category
	r.notes = notes
	r.requires_station = station
	# materials 声明成 Array[Dictionary]，而 [_mat(...)] 推断出来的是无类型 Array，
	# 直接赋值会被 GDScript 拒绝（"Invalid assignment ... of type 'Array'"）。
	# 这里逐项拷进类型化数组再赋值。
	var typed: Array[Dictionary] = []
	for m in materials:
		typed.append(m)
	r.materials = typed
	_recipes.append(r)


## 材料的简写，避免每写一条配方都敲一遍 Dictionary
static func _mat(item_id: StringName, count: int) -> Dictionary:
	return {"item_id": item_id, "count": count}


## 该配方需要的制作站是否已经放置（不需要制作站时恒为 true）
static func has_required_station(recipe: CraftingRecipe) -> bool:
	if recipe == null:
		return true
	return BuildingSystem.has_station(recipe.requires_station)


## 该配方缺少的制作站 id；不缺（或不需要）时返回 &""
## 合成界面用它显示"需要工作台"这类提示
static func get_missing_station(recipe: CraftingRecipe) -> StringName:
	if recipe == null or recipe.requires_station == &"":
		return &""
	if BuildingSystem.has_station(recipe.requires_station):
		return &""
	return recipe.requires_station


static func _build_recipes() -> void:
	var MAT := CraftingRecipe.Category.MATERIAL
	var TOOL := CraftingRecipe.Category.TOOL
	var WEAPON := CraftingRecipe.Category.WEAPON
	var ARMOR := CraftingRecipe.Category.ARMOR
	var BUILD := CraftingRecipe.Category.BUILDING
	# 专属栏（只有 craft_category 对得上的角色看得到，见 _is_recipe_visible）
	var SURV := CraftingRecipe.Category.SURVIVAL
	var ALCH := CraftingRecipe.Category.ALCHEMY
	var MACH := CraftingRecipe.Category.MACHINE
	var CORE := CraftingRecipe.Category.CORE

	# ---- 3.4.5 材料配方 ----
	# 木棍：木材 x1 → 木棍 x1（大纲 3.4.2 也把木棍列在武器里，同一条配方）
	_add(&"stick", &"stick", 1, MAT, [_mat(&"wood", 1)])

	# 电池：凝胶 x3 + 石头 x1（大纲 3.1.2 说电池可"制作获得"，材料为本次设定）
	_add(&"battery", &"battery", 1, MAT, [_mat(&"slime_gel", 3), _mat(&"rock", 1)],
		"凝胶做电解质、石块做外壳，是最稳妥的续命手段。")

	# 铁锭：铁矿 x1 + 煤矿 x1，需要熔炉（大纲 3.4.5）
	# 这是矿物链的最后一环：镐挖出铁矿/煤矿 → 熔炉冶炼 → 铁制装备。
	# 没有熔炉时这条配方在界面上显示"需要熔炉"，材料齐了也做不出来。
	_add(&"iron_ingot", &"iron_ingot", 1, MAT, [_mat(&"iron_ore", 1), _mat(&"coal", 1)],
		"铁矿与煤矿投入熔炉，炼成坚硬的铁锭。", &"furnace")

	# ---- 3.4.1 工具配方 ----
	# 石斧 / 石镐：石头 x3 + 木棍 x2，徒手可做 —— 采集工具强制后的开局入口。
	# 空手撬小石块得石头、地上捡树枝得木棍 → 石斧砍树 → 木材 → 石镐挖大石与矿。
	# （粗制石斧 / 木斧 / 木镐三档过渡工具已删除，石制工具直接顶替开局位。）
	_add(&"stone_axe", &"stone_axe", 1, TOOL, [_mat(&"rock", 3), _mat(&"stick", 2)],
		"砍树每次完成 4 点工作量")
	_add(&"stone_pickaxe", &"stone_pickaxe", 1, TOOL, [_mat(&"rock", 3), _mat(&"stick", 2)],
		"挖矿每次完成 4 点工作量")
	# 铁制工具：铁锭 x3 + 木棍 x2，需要熔炉（铁线的终点产物）
	_add(&"iron_pickaxe", &"iron_pickaxe", 1, TOOL, [_mat(&"iron_ingot", 3), _mat(&"stick", 2)],
		"挖矿每次完成 6 点工作量", &"furnace")
	_add(&"iron_axe", &"iron_axe", 1, TOOL, [_mat(&"iron_ingot", 3), _mat(&"stick", 2)],
		"砍树每次完成 6 点工作量", &"furnace")

	# ---- 3.4.2 武器配方 ----
	_add(&"wooden_sword", &"wooden_sword", 1, WEAPON, [_mat(&"stick", 2)], "攻击力+10")
	_add(&"stone_sword", &"stone_sword", 1, WEAPON, [_mat(&"rock", 3), _mat(&"stick", 2)],
		"攻击力+18", &"workbench")
	# 铁剑：铁锭 x3 + 木棍 x2，需要熔炉（当前攻击力最高的武器）
	_add(&"iron_sword", &"iron_sword", 1, WEAPON, [_mat(&"iron_ingot", 3), _mat(&"stick", 2)],
		"攻击力+28", &"furnace")

	# ---- 3.4.3 护甲配方 ----
	_add(&"grass_armor", &"grass_armor", 1, ARMOR, [_mat(&"grass", 10)], "防御+3")
	_add(&"wood_armor", &"wood_armor", 1, ARMOR, [_mat(&"wood", 5), _mat(&"stick", 3)],
		"防御+6", &"workbench")

	# ---- 3.4.4 建筑配方 ----
	# 合成出来是物品，在背包/快捷栏里右键它才进入放置模式（见 build_placer.gd）。
	_add(&"workbench", &"workbench", 1, BUILD, [_mat(&"wood", 10)],
		"放置后解锁高级配方：石斧 / 石镐 / 石剑 / 木甲")
	_add(&"furnace", &"furnace", 1, BUILD, [_mat(&"rock", 20)],
		"放置后解锁铁锭与铁制装备的配方，并在周围 5 米内提供热源")
	_add(&"storage_box", &"storage_box", 1, BUILD, [_mat(&"wood", 8)],
		"放置后点击可打开，额外 20 格存储")

	# ---- 专属制作栏（大纲 2.2.5）----
	# 这 6 条只在对应角色的存档里出现：冒险家看到「求生」，魔女看到「炼药」，
	# 机器人看到「机械」。产物都是占位物品（决策 ②⑤ 未定稿），
	# 等能力设定敲定后替换成正式配方——机制（分类 + 过滤）不受影响。

	# 冒险家 · 求生：没有自然回血，靠自制的补给品续命
	_add(&"herb_bandage", &"herb_bandage", 1, SURV, [_mat(&"grass", 5), _mat(&"stick", 1)],
		"嚼碎的草药糊在伤口上，立刻回复 25 点生命。")
	_add(&"trail_ration", &"trail_ration", 1, SURV, [_mat(&"berry", 3), _mat(&"grass", 2)],
		"浆果与草茎压成的一坨干粮，回复 40 点饱食度与 15 点生命。")

	# 魔女 · 炼药：把采集物熬成更强效的药剂（深度待定，决策 ⑤）
	_add(&"healing_potion", &"healing_potion", 1, ALCH,
		[_mat(&"berry", 5), _mat(&"slime_gel", 2)],
		"黏稠的红色药水，回复 50 点生命。")
	_add(&"vigor_draught", &"vigor_draught", 1, ALCH,
		[_mat(&"berry", 3), _mat(&"slime_gel", 3), _mat(&"grass", 2)],
		"喝下去浑身发热，回复 60 点饱食度与 20 点生命。")

	# 机器人 · 机械：唯一有电量的角色，专属栏全是能量与自检维修
	_add(&"power_cell", &"power_cell", 1, MACH,
		[_mat(&"battery", 2), _mat(&"iron_ingot", 1)],
		"两块电池并联成的高容量电芯，回复 60 点电量。")
	_add(&"repair_kit", &"repair_kit", 1, MACH,
		[_mat(&"iron_ingot", 2), _mat(&"stick", 2)],
		"现场修补外壳与关节，回复 40 点生命。")

	# ---- 核心制作栏（大纲 3.6.7）----
	# 与上面三个角色专属栏是**两套独立机制**：专属栏看"你是谁"，这栏看"你装备了什么"。
	# 只有核心槽里装着带 unlocks_core_tab 的核心（动力核心 / 机械核心）才出现，
	# 与当前玩的是哪个角色无关。
	# 目前只有一条占位配方——核心的真正用途是给日后的耗电设备供能（规划中），
	# 内容定稿后往这里加即可，机制不用动。
	_add(&"thermal_underwear", &"thermal_underwear", 1, CORE,
		[_mat(&"grass", 8), _mat(&"stick", 2)],
		"粗织的贴身衣物，防御+2。保暖效果规划中。")
