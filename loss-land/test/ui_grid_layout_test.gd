# test/ui_grid_layout_test.gd
# ============================================
# 九宫格布局回归测试（2026-09-24 新增）
#
# 背景：用户要求把界面改成"九宫格"——
#   左列 背包 / 箱子 / 制作栏；右上角 小地图+时钟（左）与 三按钮+状态栏（右）；
#   右列下半 装备栏；中列只剩吐司；底部 快捷栏。
#   而且**四块信息面板要能同时打开、互不遮挡**。
#   2026-09-24 二次改版：小地图从"中列居中"搬到"贴着按钮列左侧、整体靠右上角"，
#   右下角的操作提示被删除，那条带子让给了装备栏（装备栏 264→284 起、到 710 止）。
#
# 为什么必须有这个测试：
#   这类布局 bug 静态检查一条都看不出来，而实机肉眼也难查——
#   面板究竟落在哪几个像素上，只有把控件建出来量一次才知道。
#   之前踩过的坑（set_anchors_preset 在 _ready 里算成 0×0）就是这样漏出去的。
#
# 断言四条：
#   1. 每块面板的实际矩形 == 设计矩形（±2px）
#   2. 四块面板两两不重叠
#   3. 全部落在 1280×720 视口内
#   4. 左列三块（背包/箱子/制作栏）都不越过 y=626（快捷栏带的上沿）
#      ——否则会压住快捷栏。**装备栏例外**：它在右列（x≥794）一路用到 y=710，
#      而快捷栏横向只占 x 148..648（9 格 ×52 + 8×4 = 500 宽、中心 398），
#      两者根本不相交（下面单独核这条）。
#   另加 HUD 侧：快捷栏/状态栏/小地图/按钮组也在各自区域里。
#
# 运行：
#   godot --headless --path . --script res://test/ui_grid_layout_test.gd
# ============================================

extends SceneTree

var _fail: int = 0
var _checked: int = 0

## 信息面板下边界（与 hud_ui.gd 的 CONTENT_BOTTOM 保持一致）
const CONTENT_BOTTOM := 626.0
## 矩形比对容差
const EPS := 2.0


func _initialize() -> void:
	# 下面所有断言都基于 **1280×720 设计视口**。界面缩放
	# （GraphicsConfig.ui_scale → window.content_scale_factor）>1 时，
	# canvas_items + expand 会把**逻辑视口**缩小（1.05 ⇒ 1219×686），
	# 断言会全部失真 —— 先显式归零。
	root.content_scale_factor = 1.0
	await process_frame
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame

	var vp := Vector2(root.size)
	print("视口: ", vp)
	print("---------------------------------------")

	var mgr := UIManager.new()
	mgr.name = "UIManager"
	root.add_child(mgr)
	await process_frame

	# ---- 四块面板一起打开（这正是新规则要保证的）----
	var rects := {
		UIManager.INVENTORY_PANEL: InventoryUI.RECT_INVENTORY,
		UIManager.STORAGE_PANEL: StorageUI.RECT_STORAGE,
		UIManager.CRAFTING_PANEL: CraftingUI.RECT_CRAFTING,
		UIManager.EQUIPMENT_PANEL: EquipmentUI.RECT_EQUIPMENT,
	}

	var actual: Dictionary = {}
	for panel_name in rects.keys():
		var p := UIManager.open_panel(panel_name)
		await process_frame
		await process_frame
		if p == null:
			print("[%s] 面板没建出来" % panel_name)
			_fail += 1
			continue
		actual[panel_name] = Rect2(p.position, p.size)
		_check_rect(panel_name, p, rects[panel_name])

	# ---- 两两不重叠 ----
	var names: Array = actual.keys()
	for i in range(names.size()):
		for j in range(i + 1, names.size()):
			var a: Rect2 = actual[names[i]]
			var b: Rect2 = actual[names[j]]
			if a.intersects(b):
				var ov := a.intersection(b)
				print("[重叠] %s 与 %s 相交 %s" % [names[i], names[j], ov])
				_fail += 1
	_checked += 1
	if _fail == 0:
		print("[不重叠] 四块面板两两不相交")

	# ---- 左列三块不许越过快捷栏带上沿；装备栏例外（右列与快捷栏不相交）----
	for panel_name in actual.keys():
		var r: Rect2 = actual[panel_name]
		var limit: float = CONTENT_BOTTOM
		if panel_name == UIManager.EQUIPMENT_PANEL:
			limit = 720.0
		if r.end.y > limit + EPS:
			print("[压快捷栏] %s 下边 %.1f > %.1f" % [panel_name, r.end.y, limit])
			_fail += 1
	_checked += 1

	# ---- 装备栏应当吃满到 y=710，且横向不与快捷栏（x 148..648）相交 ----
	var eq: Rect2 = actual.get(UIManager.EQUIPMENT_PANEL, Rect2())
	if eq.size != Vector2.ZERO:
		_checked += 1
		if absf(eq.end.y - 710.0) > EPS:
			print("[装备栏] 下边 %.1f != 710（右下角操作提示已删，装备栏应一路到底）" % eq.end.y)
			_fail += 1
		else:
			print("[装备栏] 吃到 y=710，右列高度用满")
		_checked += 1
		# 快捷栏右边缘 = 中心 398 + 500/2 = 648（物品格 64→52 前是 702）
		if eq.position.x < 648.0 + EPS:
			print("[装备栏] 左边缘 %.1f 会与快捷栏（x≤648）横向相交" % eq.position.x)
			_fail += 1

	# ---- HUD 侧 ----
	await _check_hud(vp)

	print("---------------------------------------")
	if _fail == 0:
		print("===== 九宫格布局全部通过（%d 项）=====" % _checked)
	else:
		print("===== 有 %d 项不通过 =====" % _fail)
	quit(0 if _fail == 0 else 1)


func _check_rect(panel_name: String, p: Control, want: Rect2) -> void:
	_checked += 1
	var got := Rect2(p.position, p.size)
	if got.position.distance_to(want.position) > EPS or got.size.distance_to(want.size) > EPS:
		print("[%s] 矩形不符: 实际 pos=%s size=%s / 期望 pos=%s size=%s"
			% [panel_name, got.position, got.size, want.position, want.size])
		_fail += 1
		return
	# 顺带核视口内
	if got.position.x < -EPS or got.position.y < -EPS \
			or got.end.x > 1280.0 + EPS or got.end.y > 720.0 + EPS:
		print("[%s] 超出视口: %s" % [panel_name, got])
		_fail += 1
		return
	print("[%s] 就位 pos=%s size=%s" % [panel_name, got.position, got.size])


func _check_hud(vp: Vector2) -> void:
	var hud := HUDUI.new()
	hud.name = "HUD"
	root.add_child(hud)
	await process_frame
	await process_frame

	var hotbar := hud.get_node_or_null("HotbarContainer") as Control
	if hotbar == null:
		print("[HUD] 找不到 HotbarContainer")
		_fail += 1
	else:
		_checked += 1
		var r := Rect2(hotbar.position, hotbar.size)
		# 快捷栏必须整条落在底部带子里，且不越过信息面板下边界
		if r.position.y < CONTENT_BOTTOM - EPS:
			print("[HUD] 快捷栏顶端 %.1f 越过了信息面板下边界 %.1f" % [r.position.y, CONTENT_BOTTOM])
			_fail += 1
		elif r.end.y > vp.y + EPS:
			print("[HUD] 快捷栏超出视口底: %s" % r)
			_fail += 1
		else:
			print("[HUD] 快捷栏就位 pos=%s size=%s" % [r.position, r.size])

	var status := hud.get_node_or_null("StatusPanel") as Control
	if status == null:
		print("[HUD] 找不到 StatusPanel")
		_fail += 1
	else:
		_checked += 1
		var r := Rect2(status.position, status.size)
		# 状态栏：贴屏幕右边缘（x 1110..1270），且正好在按钮列下方（y 126 起）
		if absf(r.position.x - 1110.0) > EPS or absf(r.end.x - 1270.0) > EPS:
			print("[HUD] 状态栏没贴住屏幕右边缘: pos=%s size=%s" % [r.position, r.size])
			_fail += 1
		elif absf(r.position.y - 126.0) > EPS:
			print("[HUD] 状态栏不在按钮列正下方: y=%.1f（应为 126）" % r.position.y)
			_fail += 1
		elif r.end.y > EquipmentUI.RECT_EQUIPMENT.position.y + EPS:
			# 这里是**实测**高度，能抓到"字号/行距改大了把装备栏顶穿"这类问题
			print("[HUD] 状态栏压到装备栏: 底 %.1f > 装备栏顶 %.1f（实际高 %.1f）"
				% [r.end.y, EquipmentUI.RECT_EQUIPMENT.position.y, r.size.y])
			_fail += 1
		else:
			print("[HUD] 状态栏就位 pos=%s size=%s" % [r.position, r.size])

	var map_col := hud.get_node_or_null("TopRightMap")
	if map_col == null:
		print("[HUD] 找不到 TopRightMap")
		_fail += 1
	else:
		_checked += 1
		var c := map_col as Control
		# 小地图列：紧贴按钮列左侧、顶格右上角（x 890..1102、y 10..274）
		if absf(c.position.x - 890.0) > EPS or absf(c.position.x + c.size.x - 1102.0) > EPS:
			print("[HUD] 小地图列没贴在按钮列左侧: pos=%s size=%s" % [c.position, c.size])
			_fail += 1
		elif absf(c.position.y - 10.0) > EPS:
			print("[HUD] 小地图列没顶到上沿: y=%.1f" % c.position.y)
			_fail += 1
		elif c.position.y + c.size.y > EquipmentUI.RECT_EQUIPMENT.position.y + EPS:
			print("[HUD] 小地图列压到装备栏: 底 %.1f > 装备栏顶 %.1f"
				% [c.position.y + c.size.y, EquipmentUI.RECT_EQUIPMENT.position.y])
			_fail += 1
		else:
			print("[HUD] 小地图列就位 pos=%s size=%s" % [c.position, c.size])

	var btns := hud.get_node_or_null("TopRightButtons")
	if btns == null:
		print("[HUD] 找不到 TopRightButtons")
		_fail += 1
	else:
		_checked += 1
		var c := btns as Control
		# 按钮列：贴屏幕右边缘，高 = 3×32 + 2×6 = 108
		if absf(c.position.x - 1110.0) > EPS or absf(c.position.x + c.size.x - 1270.0) > EPS:
			print("[HUD] 按钮列没贴住屏幕右边缘: pos=%s size=%s" % [c.position, c.size])
			_fail += 1
		elif absf(c.size.y - 108.0) > EPS:
			print("[HUD] 按钮列高度 %.1f != 108（3 个 32 高按钮 + 2×6 间距）" % c.size.y)
			_fail += 1
		else:
			print("[HUD] 按钮列就位 pos=%s size=%s" % [c.position, c.size])

	# ---- 界面缩放把视口缩小后，贴边控件不许被裁（2026-09-24 用户反馈的回归）----
	# ui_scale >1 ⇒ content_scale_factor >1 ⇒ 逻辑视口变小（1.05 ⇒ 1280/1.05 ≈ 1219 宽）。
	# 右列/底部这些"贴视口边缘"的控件必须跟着往里收；以前写死绝对坐标时，
	# 视口一小就被裁到屏幕外（玩家看到的"装备栏 UI 超出屏幕"）。
	root.content_scale_factor = 1.05
	await process_frame
	await process_frame
	var shrunk_vp := Vector2(root.get_visible_rect().size)
	print("[缩放 105] 逻辑视口 = ", shrunk_vp)
	var edge_nodes: Array = [
		["StatusPanel", hud.get_node_or_null("StatusPanel")],
		["TopRightButtons", hud.get_node_or_null("TopRightButtons")],
		["TopRightMap", hud.get_node_or_null("TopRightMap")],
		["装备栏", UIManager.get_panel(UIManager.EQUIPMENT_PANEL)],
	]
	for entry in edge_nodes:
		var label: String = entry[0]
		var c: Control = entry[1]
		if c == null:
			continue
		_checked += 1
		var r := Rect2(c.position, c.size)
		if r.end.x > shrunk_vp.x + EPS or r.end.y > shrunk_vp.y + EPS:
			print("[缩放越界] %s %s 超出逻辑视口 %s" % [label, r, shrunk_vp])
			_fail += 1
		else:
			print("[缩放] %s 仍贴边落在视口内 %s" % [label, r])
	root.content_scale_factor = 1.0
	await process_frame
	await process_frame
