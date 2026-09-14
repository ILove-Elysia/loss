# script/ui/debug_ui.gd
# ============================================
# 调试选项面板（由 UIManager 懒加载，modal）
#
# 从「设置 → 调试选项」压栈打开，返回后回到设置面板。
# 每项对应 DebugConfig 里的一个分类，勾选即允许该类信息打到控制台。
#
# 布局与暂停菜单/设置面板同构（全屏 dimmer + 居中面板），同样的坑：
#   _ready 里 set_anchors_preset 会得到 0x0，必须显式给 size 赋值；
#   窗口变化由 UIManager 调 on_viewport_resized() 同步。
#
# 面板是懒创建的，且关闭只是 visible=false（UIManager 不会销毁它），
# 所以每次显示都要 on_shown() 重新同步勾选状态——否则在别处改了开关
# （或存档里读出来的值）界面上还是旧的。
# ============================================

class_name DebugUI
extends Control

var _dimmer: ColorRect
var _panel: PanelContainer
## 分类 -> CheckBox
var _checks: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	on_viewport_resized()


func _build() -> void:
	_dimmer = ColorRect.new()
	_dimmer.name = "Dimmer"
	_dimmer.color = Color(0, 0, 0, 0.55)
	_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dimmer)

	_panel = PanelContainer.new()
	_panel.name = "DebugPanel"
	_panel.custom_minimum_size = Vector2(340, 0)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "调试选项"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "勾选后，该类别的调试信息会打印到控制台。设置会自动保存。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(320, 0)
	hint.add_theme_color_override("font_color", Color(0.72, 0.74, 0.78))
	hint.add_theme_font_size_override("font_size", 13)
	vbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	# ---- 全开 / 全关 ----
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var all_on := Button.new()
	all_on.text = "全部开启"
	all_on.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all_on.pressed.connect(_on_all_on)
	btn_row.add_child(all_on)

	var all_off := Button.new()
	all_off.text = "全部关闭"
	all_off.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all_off.pressed.connect(_on_all_off)
	btn_row.add_child(all_off)

	vbox.add_child(HSeparator.new())

	# ---- 分类勾选框 ----
	for cat in DebugConfig.ALL_CATEGORIES:
		var key := String(cat)
		var check := CheckBox.new()
		check.text = String(DebugConfig.CATEGORY_LABELS.get(key, key))
		check.toggled.connect(_on_category_toggled.bind(key))
		vbox.add_child(check)
		_checks[key] = check

	vbox.add_child(HSeparator.new())

	var note := Label.new()
	note.text = "注：真正的程序错误（push_error）不受此开关影响，始终会输出。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(320, 0)
	note.add_theme_color_override("font_color", Color(0.66, 0.68, 0.72))
	note.add_theme_font_size_override("font_size", 12)
	vbox.add_child(note)

	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(0, 40)
	back.pressed.connect(_on_back)
	vbox.add_child(back)

	_sync_checks()


# ============================================
# 布局（_ready 时与窗口尺寸变化时调用，后者由 UIManager 驱动）
# ============================================

func on_viewport_resized() -> void:
	var vp := get_viewport_rect().size
	size = vp
	position = Vector2.ZERO

	_dimmer.size = vp
	_dimmer.position = Vector2.ZERO

	# 居中面板：锚点全在中心 + 对称 offset。
	# 不用 set_anchors_preset(CENTER, MINSIZE)：它以控件「当前」位置为基准，
	# 首次调用时控件尚未布局（position=0），会把面板居中到 (0,0)。
	var ms: Vector2 = _panel.get_combined_minimum_size()
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -ms.x / 2.0
	_panel.offset_right = ms.x / 2.0
	_panel.offset_top = -ms.y / 2.0
	_panel.offset_bottom = ms.y / 2.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# ============================================
# 每次显示时同步（UIManager.open_panel_impl 会调 on_shown）
# ============================================

func on_shown() -> void:
	_sync_checks()


# ============================================
# 回调
# ============================================

func _on_category_toggled(pressed: bool, category: String) -> void:
	DebugConfig.set_enabled(category, pressed)


func _on_all_on() -> void:
	DebugConfig.set_all(true)
	_sync_checks()


func _on_all_off() -> void:
	DebugConfig.set_all(false)
	_sync_checks()


func _on_back() -> void:
	UIManager.close_panel(UIManager.DEBUG_PANEL)


# ============================================
# 私有
# ============================================

## 从 DebugConfig 读值写回勾选框。
## 用 set_pressed_no_signal 而不是 button_pressed =，否则会反过来触发
## toggled → 再存一次盘（虽无害，但会在"全开"时产生 N 次无谓写盘）。
func _sync_checks() -> void:
	for cat in _checks:
		var check := _checks[cat] as CheckBox
		if check == null:
			continue
		check.set_pressed_no_signal(DebugConfig.is_enabled(String(cat)))
