# test/ui_layout_diag.gd
# ============================================
# 弹出面板定位回归：面板必须铺满视口，内部居中控件必须真的居中
#
# 背景（已修复的 bug）：
#   运行时 new() 的面板在 _ready 回调里调用 set_anchors_preset 会得到 0x0
#   （锚点重算发生在布局阶段而非回调内）。修复为显式给 size 赋值。
#   此测试用真实分辨率逐面板校验，防止回归。
# ============================================

extends SceneTree

var _fail: int = 0


func _initialize() -> void:
	await process_frame
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame

	var vp: Vector2 = Vector2(root.size)
	print("视口: ", vp)
	print("---------------------------------------")

	var mgr := UIManager.new()
	mgr.name = "UIManager"
	root.add_child(mgr)
	await process_frame

	for panel_name in [UIManager.PAUSE_PANEL, UIManager.SETTINGS_PANEL]:
		var p := UIManager.open_panel(panel_name)
		await process_frame
		await process_frame
		_check_centered(p, panel_name, vp)
		UIManager.close_panel(panel_name)

	# 窗口变化后再次校验（触发 viewport size_changed → on_viewport_resized）
	root.size = Vector2i(1600, 900)
	await process_frame
	await process_frame
	var vp2: Vector2 = Vector2(root.size)
	var p2 := UIManager.open_panel(UIManager.SETTINGS_PANEL)
	await process_frame
	await process_frame
	_check_centered(p2, "settings(窗口变化后)", vp2)
	UIManager.close_panel(UIManager.SETTINGS_PANEL)

	print("---------------------------------------")
	if _fail == 0:
		print("===== 定位检查全部通过 =====")
	else:
		print("===== 有 %d 项不通过 =====" % _fail)
	quit()


func _check_centered(p: Control, panel_name: String, vp: Vector2) -> void:
	if p == null:
		print("[%s] 面板未创建" % panel_name)
		_fail += 1
		return

	var ok := true
	if p.size.distance_to(vp) > 2.0:
		print("[%s] 面板根未铺满: size=%s 期望=%s" % [panel_name, p.size, vp])
		ok = false

	var dimmer := p.get_node_or_null("Dimmer") as Control
	if dimmer != null and dimmer.size.distance_to(vp) > 2.0:
		print("[%s] 遮罩未铺满: size=%s" % [panel_name, dimmer.size])
		ok = false

	var inner := _find_centered_child(p)
	if inner != null:
		var center: Vector2 = inner.global_position + inner.size / 2.0
		var want: Vector2 = vp / 2.0
		if center.distance_to(want) > 4.0:
			print("[%s] 内部面板未居中: 中心=%s 期望=%s (size=%s pos=%s)"
				% [panel_name, center, want, inner.size, inner.position])
			ok = false
		else:
			print("[%s] 内部面板居中正确: 中心=%s size=%s" % [panel_name, center, inner.size])

	if not ok:
		_fail += 1


func _find_centered_child(root_node: Node) -> Control:
	for c in root_node.get_children():
		if c is Control:
			var cc := c as Control
			if is_equal_approx(cc.anchor_left, 0.5) and is_equal_approx(cc.anchor_top, 0.5):
				return cc
			var deeper := _find_centered_child(cc)
			if deeper != null:
				return deeper
	return null
