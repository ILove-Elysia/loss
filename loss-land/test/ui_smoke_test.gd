# test/ui_smoke_test.gd
# ============================================
# UI 冒烟测试（headless，不生成地图，秒级完成）
#
# 目的：验证 UI 的"可交互性"基础设施是否真的打通。
# 这类故障静态检查看不出来——脚本能编译、节点也在树上，
# 但玩家点下去毫无反应，所以必须用运行时断言兜底。
#
# 为什么分两帧：
#   extends SceneTree 的 _init() 里 SceneTree.root 尚未就绪，
#   此时 add_child 到 root 会静默失败（节点不在树中，_ready 永不执行）。
#   必须等第一次 _process，root 才可用。
#
# 运行：
#   godot --headless --path . --script res://test/ui_smoke_test.gd
# ============================================

extends SceneTree

var _phase: int = 0
var _failures: Array[String] = []

var _slot: ItemSlotUI
var _hud: HUDUI
var _inv_ui: InventoryUI
var _pressed_index: int = -1
var _click_count: int = 0


func _process(_delta: float) -> bool:
	if _phase == 0:
		_build()
		_phase = 1
		return false  # 继续到下一帧，确保 _ready 已执行
	_run_checks()
	return true  # true = 退出主循环


func _build() -> void:
	_slot = ItemSlotUI.new()
	_slot.name = "TestSlot"
	root.add_child(_slot)

	_hud = HUDUI.new()
	_hud.name = "HUDUI"
	root.add_child(_hud)
	_hud.hotbar_slot_pressed.connect(func(i: int) -> void: _pressed_index = i)

	# --script 模式不加载主场景，UIManager 得自己建（正常游戏里它由 map.tscn 提供）
	var ui_mgr := UIManager.new()
	ui_mgr.name = "UIManager"
	root.add_child(ui_mgr)

	# 背包不再手动建：现由 UIManager 懒加载托管，
	# 自己再 new 一个会同时出现在 inventory_ui 组里，干扰查找。


func _check(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		print("  [通过] ", name)
	else:
		print("  [失败] ", name, "  ", detail)
		_failures.append(name)


func _run_checks() -> void:
	print("========== UI 冒烟测试 ==========")

	# ---------- 1. 输入映射 ----------
	print("[1] 输入映射")
	var need: Array[String] = ["ui_cancel", "ui_tab", "toggle_bigmap", "player_interact", "player_attack"]
	for i in range(1, 10):
		need.append("hotbar_%d" % i)
	var missing: Array[String] = []
	for a in need:
		if not InputMap.has_action(a):
			missing.append(a)
	_check(missing.is_empty(), "按键映射齐全（Esc / 1-9 / E / Tab / M / F）", "缺失: " + ", ".join(missing))

	# ---------- 2. 槽位鼠标过滤 ----------
	print("[2] 物品槽交互")
	_check(_slot.mouse_filter != Control.MOUSE_FILTER_IGNORE,
		"槽位 mouse_filter 已开启",
		"仍为 IGNORE，点击与悬停不会触发")

	# 用成员变量记录，不用 lambda 改写局部变量——GDScript lambda
	# 对外部局部变量的赋值不保证回写，会让断言假阴性。
	_slot.clicked.connect(func(_i: int, _b: int) -> void: _click_count += 1)
	var ev := InputEventMouseButton.new()
	ev.pressed = true
	ev.button_index = MOUSE_BUTTON_LEFT
	_slot._gui_input(ev)
	_check(_click_count > 0, "投递鼠标事件能触发 clicked", "计数 %d" % _click_count)

	# ---------- 3. HUD 结构与定位 ----------
	print("[3] HUD 结构与定位")
	_check(_hud.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"HUD 根节点不吞鼠标（3D 世界仍可点击）")

	var hotbar = _hud.find_child("HotbarContainer", true, false)
	_check(hotbar != null and is_equal_approx(hotbar.anchor_left, 0.5) and is_equal_approx(hotbar.anchor_top, 1.0),
		"快捷栏锚定底部居中")

	var panel = _hud.find_child("StatusPanel", true, false)
	_check(panel != null and is_equal_approx(panel.anchor_top, 1.0),
		"状态栏锚定左下（原为左上）")

	var hints = _hud.find_child("ControlHints", true, false)
	_check(hints != null and is_equal_approx(hints.anchor_top, 1.0) and hints.offset_top == -140,
		"按键提示在底部、快捷栏上方（原为顶部）")

	# ---------- 4. 快捷栏选中 ----------
	print("[4] 快捷栏选中")
	_hud._select_hotbar(3)
	_check(_pressed_index == 3, "选择槽位会发出 hotbar_slot_pressed")

	var slot3 = _hud.get_hotbar_slot(3)
	var slot0 = _hud.get_hotbar_slot(0)
	_check(slot3 != null and slot3._is_selected, "被选中的槽位有高亮状态")
	_check(slot0 != null and not slot0._is_selected, "旧选中槽位已取消高亮")

	# ---------- 5. 背包由 UIManager 托管 ----------
	print("[5] 背包（UIManager 托管）")
	_hud._toggle_inventory()
	_check(UIManager.is_open(UIManager.INVENTORY_PANEL), "Tab 经 UIManager 能打开背包")
	var inv_panel := UIManager.get_panel(UIManager.INVENTORY_PANEL)
	_check(inv_panel != null and inv_panel.visible, "背包实例已创建且可见")
	_check(inv_panel != null and inv_panel.mouse_filter == Control.MOUSE_FILTER_STOP,
		"背包根节点吃掉鼠标（不穿透到 3D）")
	_check(not paused, "背包非模态：不暂停游戏")
	_hud._toggle_inventory()
	_check(not UIManager.is_open(UIManager.INVENTORY_PANEL), "再次触发可关闭背包")

	# ---------- 5b. 窗口类面板互斥 ----------
	# 用户 2026-09-12 反馈：开着一个面板再按另一个的快捷键，会同时冒出多个面板。
	# 规则：背包/合成/装备/储物箱同一时刻只允许开一个；全屏覆盖类（大地图等）
	# 打开时收掉所有窗口类面板。
	print("[5b] 窗口类面板互斥")
	UIManager.close_all()
	_hud._toggle_inventory()
	_hud._toggle_crafting()
	_check(UIManager.is_open(UIManager.CRAFTING_PANEL) and not UIManager.is_open(UIManager.INVENTORY_PANEL),
		"开合成会自动收起背包（不同时显示）")
	_hud._toggle_equipment()
	_check(UIManager.is_open(UIManager.EQUIPMENT_PANEL) and not UIManager.is_open(UIManager.CRAFTING_PANEL),
		"开装备会自动收起合成")
	var inv_hidden := UIManager.get_panel(UIManager.INVENTORY_PANEL)
	_check(inv_hidden != null and not inv_hidden.visible,
		"被收起的面板确实隐藏了（不只是从栈里摘掉）")
	_hud._toggle_equipment()
	_check(not UIManager.is_open(UIManager.EQUIPMENT_PANEL), "再按一次关掉当前面板")
	# 全屏覆盖类：打开大地图会收掉窗口类面板（否则关掉地图会"凭空冒出背包"）
	_hud._toggle_inventory()
	_hud._toggle_big_map()
	_check(UIManager.is_open(UIManager.BIGMAP_PANEL) and not UIManager.is_open(UIManager.INVENTORY_PANEL),
		"打开大地图会收起背包")
	_check(paused, "大地图仍是模态：暂停游戏")
	UIManager.close_all()
	_check(not paused, "全部关闭后游戏恢复运行")

	# ---------- 6. 玩家 → HUD 通路 ----------
	print("[6] 玩家 → HUD 通路")
	_check(get_first_node_in_group("hud") == _hud, "physics.gd 按 hud 组能取到 HUDUI")
	_hud.update_health(42, 100)
	_check(_hud._health_label.text.contains("42"), "update_health 能刷新显示", _hud._health_label.text)

	# ---------- 7. UIManager 面板栈与暂停 ----------
	print("[7] 暂停菜单与面板栈")
	UIManager.close_all()
	UIManager.open_panel(UIManager.PAUSE_PANEL)
	_check(paused, "打开暂停菜单会暂停游戏")
	UIManager.open_panel(UIManager.SETTINGS_PANEL)
	_check(UIManager.is_open(UIManager.PAUSE_PANEL) and UIManager.is_open(UIManager.SETTINGS_PANEL),
		"设置压栈在暂停菜单之上")
	UIManager.close_top()
	_check(not UIManager.is_open(UIManager.SETTINGS_PANEL) and UIManager.is_open(UIManager.PAUSE_PANEL),
		"Esc 只关栈顶（设置），暂停菜单仍在")
	UIManager.close_top()
	_check(not paused, "关闭全部模态面板后游戏恢复运行")

	# ---------- 8. 地图 ----------
	# 小地图：HUD 常驻组件，只有按钮开关（无快捷键），滚轮缩放/拖动在 MapView
	# 大地图：UIManager 托管的全屏面板（modal：打开即暂停），M 键或按钮开关
	print("[8] 地图")
	_hud._toggle_big_map()
	_check(UIManager.is_open(UIManager.BIGMAP_PANEL), "HUD 按钮能打开大地图")
	var bigmap := UIManager.get_panel(UIManager.BIGMAP_PANEL)
	_check(bigmap != null and bigmap.visible, "大地图实例已创建且可见")
	_check(bigmap != null and bigmap.mouse_filter == Control.MOUSE_FILTER_STOP,
		"大地图吃掉鼠标（滚轮缩放/拖动平移要收得到事件）")
	# 回归：运行时 new 的全屏面板若靠 set_anchors_preset 铺全屏，会停在 0×0——
	# 那样不只是画不满屏幕，控件矩形为 0 也**永远不是鼠标悬停控件**，
	# _gui_input 收不到滚轮/拖动（地图不能缩放），鼠标还会穿过去点世界。
	var vp_size: Vector2 = root.get_visible_rect().size
	_check(bigmap != null and bigmap.size.x >= vp_size.x - 1.0 and bigmap.size.y >= vp_size.y - 1.0,
		"大地图铺满整个视口（不能是 0×0）",
		("size=%s vp=%s" % [str(bigmap.size), str(vp_size)]) if bigmap != null else "面板为空")
	_check(paused, "大地图是模态：打开就暂停游戏")
	_hud._toggle_big_map()
	_check(not UIManager.is_open(UIManager.BIGMAP_PANEL), "再触发关闭大地图")
	_check(not paused, "关掉大地图后游戏恢复运行")

	_check(_hud._minimap != null and _hud._minimap.visible, "小地图默认常驻显示")
	_check(_hud._minimap != null and _hud._minimap.mouse_filter == Control.MOUSE_FILTER_STOP,
		"小地图吃掉自己那块区域的鼠标（滚轮缩放/拖动平移）")
	_hud._toggle_minimap()
	_check(_hud._minimap != null and not _hud._minimap.visible, "小地图按钮能关闭它")
	_hud._toggle_minimap()
	_check(_hud._minimap != null and _hud._minimap.visible, "再点一次恢复显示")
	UIManager.close_all()

	# ---------- 汇总 ----------
	print("=================================")
	if _failures.is_empty():
		print("===== UI 冒烟测试全部通过 =====")
	else:
		print("===== 失败 %d 项 =====" % _failures.size())
		for f in _failures:
			print("  - ", f)
	print("=================================")
