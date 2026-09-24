# test/storage_transfer_test.gd
# ============================================
# 储物箱 ↔ 背包 搬运逻辑测试（纯数据，headless 秒级完成）
#
# 覆盖 2026-09-23 用户需求的四条路径背后的搬运语义：
#   · 拖拽整堆           → transfer_between(count = -1)
#   · Ctrl 拖拽只拿 1 个  → transfer_between(count = 1)    ← 数量随拖拽数据走
#   · Shift 快速存入箱子  → stash_into（自动并进同类格 + 找空格）
#   · 箱子/背包满时的边界 → 部分搬运、原地不动、**绝不复制物品**
#
# 为什么必须有：这类 bug 静态检查一条都看不出来。
#   "同一个实例挂在两个槽位"能凭空复制物品（核心电量还会跟着分叉）；
#   "合不进去的死循环"会卡死主线程。两者都只发生在数据层，UI 上看不出异常，
#   等玩家发现时存档早就脏了。
#
# 运行：
#   godot --headless --path . --script res://test/storage_transfer_test.gd
# ============================================

extends SceneTree

var _failures: Array[String] = []
var _ran: bool = false

var _wood: ItemData
var _stone: ItemData


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_all()
	quit(0 if _failures.is_empty() else 1)
	return true  # true = 退出主循环


# ============================================
# 辅助
# ============================================

## 造一个临时物品数据（测试不走 ItemRegistry，避免依赖 .tres）
func _make_data(id: String, max_stack: int = 99) -> ItemData:
	var d := ItemData.new()
	d.item_id = StringName(id)
	d.display_name = id
	d.stackable = true
	d.max_stack = max_stack
	return d


## 造背包。注意**不** add_child：SceneTree 脚本里 root 未就绪时进树会静默失败，
## 而实测搬运逻辑不需要 _ready，手动初始化槽位数组即可。
func _make_inv(slots: int = 20) -> Inventory:
	var inv := Inventory.new()
	inv.max_slots = slots
	inv._initialize_slots()
	return inv


func _check(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		print("  [通过] ", name)
	else:
		print("  [失败] ", name, "  ", detail)
		_failures.append(name)


func _qty(inv: Inventory, slot: int) -> int:
	var item: ItemInstance = inv.get_item(slot)
	return item.quantity if item != null else 0


# ============================================
# 用例
# ============================================

func _run_all() -> void:
	print("========== 储物箱搬运逻辑测试 ==========")

	_wood = _make_data("wood")
	_stone = _make_data("stone")

	_case_whole_move()
	_case_ctrl_single()
	_case_merge_whole()
	_case_merge_partial()
	_case_ctrl_merge_into_full()
	_case_other_item_with_count()
	_case_swap_whole()
	_case_same_inv_split()
	_case_self_drop()
	_case_stash_autostack()
	_case_stash_full_target()
	_case_stash_finds_next_slot()
	_case_no_instance_duplication()

	print("=================================")
	if _failures.is_empty():
		print("===== 全部通过 =====")
	else:
		print("===== 失败 %d 项 =====" % _failures.size())
		for f in _failures:
			print("  - ", f)
	print("=================================")


# ---- 1. 整堆搬到空格 ----
func _case_whole_move() -> void:
	print("\n[1] 整堆搬进空格（普通拖拽）")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	var moved: int = Inventory.transfer_between(a, 0, b, 0, -1)
	_check(moved == 10, "搬运数量 = 10", "实际 %d" % moved)
	_check(a.get_item(0) == null, "源槽已清空")
	_check(_qty(b, 0) == 10, "目标槽拿到 10")


# ---- 2. Ctrl 拖拽只拿 1 个 ----
func _case_ctrl_single() -> void:
	print("\n[2] Ctrl 拖拽只拿 1 个")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	var moved: int = Inventory.transfer_between(a, 0, b, 0, 1)
	_check(moved == 1, "只搬走 1 个", "实际 %d" % moved)
	_check(_qty(a, 0) == 9, "源槽剩 9", "实际 %d" % _qty(a, 0))
	_check(_qty(b, 0) == 1, "目标槽拿到 1", "实际 %d" % _qty(b, 0))


# ---- 3. 同类整堆合并 ----
func _case_merge_whole() -> void:
	print("\n[3] 同类整堆合并")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	b.set_slot(0, ItemInstance.new(_wood, 5))
	var moved: int = Inventory.transfer_between(a, 0, b, 0, -1)
	_check(moved == 10, "搬运数量 = 10", "实际 %d" % moved)
	_check(a.get_item(0) == null, "源槽已清空")
	_check(_qty(b, 0) == 15, "合并成 15", "实际 %d" % _qty(b, 0))


# ---- 4. 目标堆叠快满：合不下的留在源槽 ----
func _case_merge_partial() -> void:
	print("\n[4] 目标堆叠只剩 2 个空位")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	b.set_slot(0, ItemInstance.new(_wood, 97))
	var moved: int = Inventory.transfer_between(a, 0, b, 0, -1)
	_check(moved == 2, "只搬走 2 个", "实际 %d" % moved)
	_check(_qty(b, 0) == 99, "目标堆满 99", "实际 %d" % _qty(b, 0))
	_check(_qty(a, 0) == 8, "源槽剩 8（没被吞）", "实际 %d" % _qty(a, 0))


# ---- 5. Ctrl 指定数量合并到快满的堆 ----
func _case_ctrl_merge_into_full() -> void:
	print("\n[5] Ctrl 拿 5 个去合只剩 2 空位的堆")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	b.set_slot(0, ItemInstance.new(_wood, 97))
	var moved: int = Inventory.transfer_between(a, 0, b, 0, 5)
	_check(moved == 2, "实际只合进 2 个", "实际 %d" % moved)
	_check(_qty(b, 0) == 99, "目标堆满 99", "实际 %d" % _qty(b, 0))
	_check(_qty(a, 0) == 8, "剩下的 8 个还在源槽", "实际 %d" % _qty(a, 0))


# ---- 6. 不同类 + Ctrl 指定数量 → 原地不动 ----
func _case_other_item_with_count() -> void:
	print("\n[6] Ctrl 拿 1 个去撞别的物品 → 不动")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	b.set_slot(0, ItemInstance.new(_stone, 5))
	var moved: int = Inventory.transfer_between(a, 0, b, 0, 1)
	_check(moved == 0, "没有搬任何东西", "实际 %d" % moved)
	_check(_qty(a, 0) == 10 and _qty(b, 0) == 5, "两边都没变",
		"a=%d b=%d" % [_qty(a, 0), _qty(b, 0)])


# ---- 7. 不同类 + 整堆 → 交换 ----
func _case_swap_whole() -> void:
	print("\n[7] 整堆拖到别的物品上 → 交换")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	b.set_slot(0, ItemInstance.new(_stone, 5))
	Inventory.transfer_between(a, 0, b, 0, -1)
	_check(_qty(a, 0) == 5 and _qty(b, 0) == 10, "两格互换",
		"a=%d b=%d" % [_qty(a, 0), _qty(b, 0)])


# ---- 8. 同背包内拆堆（背包内部 Ctrl 拖拽） ----
func _case_same_inv_split() -> void:
	print("\n[8] 同一个背包内部拆 4 个到空格")
	var a := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	var moved: int = Inventory.transfer_between(a, 0, a, 3, 4)
	_check(moved == 4, "搬走 4 个", "实际 %d" % moved)
	_check(_qty(a, 0) == 6 and _qty(a, 3) == 4, "拆成 6 + 4",
		"源=%d 目标=%d" % [_qty(a, 0), _qty(a, 3)])


# ---- 9. 拖到自己身上 → 不动 ----
func _case_self_drop() -> void:
	print("\n[9] 拖回同一格 → 不动")
	var a := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	var moved: int = Inventory.transfer_between(a, 0, a, 0, -1)
	_check(moved == 0 and _qty(a, 0) == 10, "数量没变（不会先清后写导致丢件）",
		"moved=%d qty=%d" % [moved, _qty(a, 0)])


# ---- 10. stash_into：自动并进同类格 ----
func _case_stash_autostack() -> void:
	print("\n[10] Shift 快速存入：自动并进同类格")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 10))
	b.set_slot(2, ItemInstance.new(_wood, 5))
	var moved: int = Inventory.stash_into(a, 0, b)
	_check(moved == 10, "搬走 10 个", "实际 %d" % moved)
	_check(a.get_item(0) == null, "源槽已清空")
	_check(_qty(b, 2) == 15, "并进第 2 格的同类堆 → 15", "实际 %d" % _qty(b, 2))
	_check(b.find_empty_slot() == 0, "没有多余新格子被占用（第 0 格仍空）")


# ---- 11. stash_into：目标全满 → 一个都搬不动，源槽不丢 ----
func _case_stash_full_target() -> void:
	print("\n[11] 箱子塞满不同类型的物品")
	var a := _make_inv()
	var b := _make_inv(3)
	# 塞满 3 格，每格一个不同物品（既不能堆叠也没空格）
	for i in range(3):
		b.set_slot(i, ItemInstance.new(_make_data("filler_%d" % i), 1))
	a.set_slot(0, ItemInstance.new(_wood, 10))
	var moved: int = Inventory.stash_into(a, 0, b)
	_check(moved == 0, "一个都没搬走", "实际 %d" % moved)
	_check(_qty(a, 0) == 10, "源槽原样保留（没被吞）", "实际 %d" % _qty(a, 0))


# ---- 12. stash_into：堆满后会自动找下一个格子（不会卡在满堆上死循环） ----
func _case_stash_finds_next_slot() -> void:
	print("\n[12] 三格木料依次快速存入：满堆要让位给下一格")
	var a := _make_inv()
	var b := _make_inv()
	a.set_slot(0, ItemInstance.new(_wood, 99))
	a.set_slot(1, ItemInstance.new(_wood, 99))
	a.set_slot(2, ItemInstance.new(_wood, 52))

	for i in range(3):
		Inventory.stash_into(a, i, b)

	var total: int = 0
	for i in range(b.max_slots):
		total += _qty(b, i)
	_check(total == 250, "目标总计 250（一个不多一个不少）", "实际 %d" % total)
	_check(_qty(b, 0) == 99 and _qty(b, 1) == 99 and _qty(b, 2) == 52,
		"依次落在第 0/1/2 格（没堆在某格上死循环）",
		"%d / %d / %d" % [_qty(b, 0), _qty(b, 1), _qty(b, 2)])
	_check(_qty(a, 0) == 0 and _qty(a, 1) == 0 and _qty(a, 2) == 0,
		"源背包已清空")


# ---- 13. 绝不出现"同一个实例挂在两个槽位" ----
func _case_no_instance_duplication() -> void:
	print("\n[13] 搬完后不存在跨槽重复引用（复制物品级别的 bug）")
	var a := _make_inv(4)
	var b := _make_inv(4)
	a.set_slot(0, ItemInstance.new(_wood, 99))
	b.set_slot(3, ItemInstance.new(_wood, 50))
	# 先合进 b 第 3 格（进 49），剩下的 50 再找空格放进 b 第 0 格
	Inventory.stash_into(a, 0, b)

	var seen: Dictionary = {}
	var dup: String = ""
	for ctx in [["a", a], ["b", b]]:
		var tag: String = ctx[0]
		var inv: Inventory = ctx[1]
		for i in range(inv.max_slots):
			var item: ItemInstance = inv.get_item(i)
			if item == null:
				continue
			var key: int = item.get_instance_id()
			if seen.has(key):
				dup += "%s 第 %d 格 = 已出现在 %s；" % [tag, i, seen[key]]
			else:
				seen[key] = "%s 第 %d 格" % [tag, i]
	_check(dup == "", "没有重复引用的实例", dup)

	# 顺带核对总量守恒
	var total: int = 0
	for i in range(a.max_slots):
		total += _qty(a, i)
	for i in range(b.max_slots):
		total += _qty(b, i)
	_check(total == 149, "总数量守恒（99 + 50 = 149）", "实际 %d" % total)
	_check(_qty(b, 3) == 99 and _qty(b, 0) == 50 and a.get_item(0) == null,
		"合进第 3 格 49 个，余 50 落到第 0 格，源槽清空",
		"b3=%d b0=%d a0=%s" % [_qty(b, 3), _qty(b, 0), str(a.get_item(0))])
