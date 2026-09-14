# script/items/item_effects.gd
# ============================================
# 物品使用效果服务 - 解析 use_effect 并施加到玩家
#
# 为什么独立成静态服务？
#   - 背包 UI 只管"用了哪个槽"，不该知道效果细节
#   - headless 测试不需要 UI 就能验证效果闭环
#   - 以后加食物（回血）、药水等效果都在这里扩展
#
# use_effect 格式（ItemData.use_effect 字符串）：
#   "+10_power"                → 电量 +10（电池）
#   "+25_food"                 → 饱食度 +25（浆果）
#   "+15_health"               → 生命 +15
#   **一条效果可以带多个值**（大纲 3.3.2：吃食物 = 补饱食度 且 回血）：
#   "+25_food +10_health"      → 饱食度 +25 且 生命 +10（浆果）
#   连写也可以："+25_food+10_health"
#   无 / 空                     → 无效果（不可用）
#
# ⚠ 防滥用（大纲 3.3.2）：饱食度已满时**不允许进食**（见 apply 的 food 分支）。
#   否则"背包塞满浆果"会让战斗与过冷过热的惩罚全部失效。
#
# 专属权限（大纲 v0.7 · 2.2.4-④ 决策 ⑦）：见 access_denied_reason()。
#   不满足权限时 apply() 直接返回 false 且**不消耗物品**；
#   UI 侧应先用 access_denied_reason() 拿原因，给玩家提示后再决定是否调用。
#
# 返回 true 表示效果已生效（调用方消耗物品）。
# ============================================

class_name ItemEffects
extends RefCounted

# ============================================
# 静态方法
# ============================================

# ----------------------------------------
# 判断物品是否"真的能直接用"
#
# 为什么要独立于 item.usable：
#   usable 是策划在 .tres 里标的一个开关，历史上出现过"usable=true 但 use_effect
#   为空"的数据（例如 grass），此时右键会"看起来能用、实际什么都没发生"。
#   统一用本函数判断，UI 提示与实际行为就不会打架。
#
# 返回 true 表示 apply() 有成功生效的可能（usable 且填了非空 use_effect）
# ----------------------------------------
static func can_use(item: ItemData) -> bool:
	if item == null or not item.usable:
		return false
	return not item.use_effect.strip_edges().is_empty()


# ----------------------------------------
# 专属物品的使用权限检查（大纲 v0.7 · 2.2.4-④ 决策 ⑦）
#
# 返回空串 = 当前角色可以使用；非空 = 给玩家看的拒绝原因。
# 单独抽成方法，是为了让 UI（背包 / 快捷栏 / 悬停说明）与真正的结算逻辑
# 走**同一个**判定 —— 否则会出现"提示说不能用、实际又能用"的错位。
# ----------------------------------------
static func access_denied_reason(item: ItemData) -> String:
	if item == null:
		return ""
	if item.is_usable_by(""):
		return ""
	var hint: String = item.get_access_hint()
	if hint.is_empty():
		return "此物品无法使用"
	return hint


# ----------------------------------------
# 应用使用效果函数
#
# 参数：
#   item - 物品数据（读 use_effect）
#   player_root - 玩家根节点（player 组成员）
# 返回：是否成功生效
# ----------------------------------------
static func apply(item: ItemData, player_root: Node) -> bool:
	if not can_use(item):
		return false
	if player_root == null:
		return false

	# 专属权限（决策 ⑦）：不满足就整个作废，且**不消耗物品**。
	# 这里再判一次而不只依赖 UI 判断 —— 效果服务是权威，
	# 将来任何新调用方（宝箱、快捷键、脚本）都不会绕过限制。
	var denied: String = access_denied_reason(item)
	if not denied.is_empty():
		DebugConfig.warn_msg(DebugConfig.CAT_ITEM,
			"[使用] %s 被拒：%s", [item.display_name, denied])
		return false

	# 归属角色的专属加成（白名单）：本次使用把每个效果数值乘上倍率
	var bonus_active: bool = item.has_owner_bonus_for("")
	if bonus_active:
		DebugConfig.log_msg(DebugConfig.CAT_ITEM,
			"[使用] %s：专属加成 ×%.2f 生效", [item.display_name, item.owner_bonus_mult])

	var effect: String = item.use_effect.strip_edges()
	if effect.is_empty():
		return false

	# 一条 use_effect 可以带**多个**效果（大纲 3.3.2：吃食物 = 补饱食度 且 回血）。
	# 用正则把所有 "+N_xxx" 片段抓出来逐个结算，空格分隔与连写都支持。
	# 旧实现是"按后缀 ends_with 命中一个就 return"，所以一条效果只能表达一个值，
	# 浆果想同时补饱食度和回血就做不到 —— 这是本次改动的原因。
	var re := RegEx.new()
	if re.compile("\\+([0-9.]+)_(power|food|health)") != OK:
		DebugConfig.warn_msg(DebugConfig.CAT_ITEM, "[使用] 效果正则编译失败：%s", [effect])
		return false

	# 防滥用（大纲 3.3.2 ⚠）：**饱食度已满时不可进食**，且整次使用作废
	#（连回血一起废掉）—— 否则"满着肚子啃浆果回血"会绕过这道门槛，
	# 让战斗与过冷过热的惩罚全部失效。判断放在结算之前，避免先回了血再作废。
	var vitals: Node = player_root.get_node_or_null("Vitals")
	if vitals != null and effect.find("_food") >= 0:
		var hunger: float = float(vitals.get("current_hunger"))
		var hunger_max: float = float(vitals.get("max_hunger"))
		if hunger >= hunger_max:
			DebugConfig.log_msg(DebugConfig.CAT_ITEM, "[使用] %s：饱食度已满，吃不下",
				[item.display_name])
			return false

	var applied: bool = false
	var matches: Array = re.search_all(effect)
	for m in matches:
		var rm: RegExMatch = m as RegExMatch
		if rm == null:
			continue
		var amount: float = float(rm.get_string(1))
		var kind: String = rm.get_string(2)
		# 专属加成乘在"每条效果"上，所以 "+40_food +15_health" 会同时被放大
		if bonus_active:
			amount *= item.owner_bonus_mult
		if amount <= 0.0:
			continue

		if kind == "power":
			var vitals_p := player_root.get_node_or_null("Vitals")
			if vitals_p == null or not vitals_p.has_method("add_power"):
				continue
			var gained: float = vitals_p.add_power(amount)
			DebugConfig.log_msg(DebugConfig.CAT_ITEM, "[使用] %s：电量 +%.0f",
				[item.display_name, gained])
			if gained > 0.0:
				applied = true

		elif kind == "food":
			var vitals_f := player_root.get_node_or_null("Vitals")
			if vitals_f == null or not vitals_f.has_method("add_hunger"):
				continue
			# （饱食度已满的门槛已在结算前统一拦掉，这里不再重复判断）
			var fed: float = vitals_f.add_hunger(amount)
			DebugConfig.log_msg(DebugConfig.CAT_ITEM, "[使用] %s：饱食度 +%.0f",
				[item.display_name, fed])
			if fed > 0.0:
				applied = true

		elif kind == "health":
			var physics := player_root.get_node_or_null("Physics")
			if physics == null or not physics.has_method("heal"):
				continue
			# 满血时不浪费：heal 内部会夹到上限，这里只判断"有没有真的回上血"
			var before: int = int(physics.get("current_health"))
			physics.heal(int(amount))
			var healed: int = int(physics.get("current_health")) - before
			DebugConfig.log_msg(DebugConfig.CAT_ITEM, "[使用] %s：生命 +%d",
				[item.display_name, healed])
			if healed > 0:
				applied = true

	if not applied:
		DebugConfig.warn_msg(DebugConfig.CAT_ITEM,
			"[使用] %s：效果未生效（%s）", [item.display_name, effect])
	return applied


# ----------------------------------------
# 解析效果数值函数
# 形如 "+10_power" 的字符串 → 10.0；不匹配返回 -1
# ----------------------------------------
static func _parse_amount(effect: String, suffix: String) -> float:
	if not effect.ends_with(suffix):
		return -1.0
	var head := effect.substr(0, effect.length() - suffix.length())
	if head.begins_with("+"):
		head = head.substr(1)
	return head.to_float()
