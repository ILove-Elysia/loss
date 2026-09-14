# script/ui/settings_ui.gd
# ============================================
# 设置面板（由 UIManager 懒加载，modal）
#
# 由暂停菜单压栈打开：关闭后回到暂停菜单，不会直接跳回游戏。
# 目前提供：主音量、全屏开关、图像设置（再压一层 GraphicsUI）、调试选项（再压一层 DebugUI）。
#
# 音量直接写 AudioServer 的 Master 总线，存储用线性值（0-100）以便滑块直观，
# 写入前转成分贝 —— 滑块直接用分贝做范围会导致手感极不均匀。
#
# 「全屏」勾选框与图像设置里的全屏是同一件事，为避免两处状态打架，
# 这里不直接调 DisplayServer，而是委托给 GraphicsConfig（单一数据源），
# 并在 on_shown() 里按它的当前值回填勾选框。
#
# 布局注意（与 pause_menu_ui.gd 相同的坑）：
#   _ready 回调里 set_anchors_preset 会得到 0x0（锚点重算不在回调内发生），
#   必须显式给 size 赋值；窗口变化由 UIManager 调 on_viewport_resized() 同步。
# ============================================

class_name SettingsUI
extends Control

const BUS_MASTER := 0

var _dimmer: ColorRect
var _panel: PanelContainer
var _full_check: CheckBox


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
	_panel.name = "SettingsPanel"
	_panel.custom_minimum_size = Vector2(300, 0)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	# ---- 主音量 ----
	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 8)
	vbox.add_child(vol_row)

	var vol_label := Label.new()
	vol_label.text = "主音量"
	vol_label.custom_minimum_size = Vector2(70, 0)
	vol_row.add_child(vol_label)

	var slider := HSlider.new()
	slider.name = "VolumeSlider"
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.custom_minimum_size = Vector2(150, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 当前音量（分贝）转成线性百分比给滑块
	slider.value = roundi(db_to_linear(AudioServer.get_bus_volume_db(BUS_MASTER)) * 100.0)
	slider.value_changed.connect(_on_volume_changed)
	vol_row.add_child(slider)

	# ---- 全屏（快捷开关，等价于图像设置里的全屏） ----
	_full_check = CheckBox.new()
	_full_check.name = "FullscreenCheck"
	_full_check.text = "全屏"
	_full_check.button_pressed = _is_fullscreen_mode()
	_full_check.toggled.connect(_on_fullscreen_toggled)
	vbox.add_child(_full_check)

	vbox.add_child(HSeparator.new())

	# ---- 图像设置入口 ----
	# 与「调试选项」同构：压栈打开一个子面板，返回后回到设置。
	# 不把分辨率/窗口模式直接铺在这里，是为了给后续要加的图像选项留位置
	# （渲染缩放、抗锯齿、阴影质量…），铺开会把设置面板撑很长。
	var graphics_btn := Button.new()
	graphics_btn.name = "GraphicsButton"
	graphics_btn.text = "图像设置…"
	graphics_btn.custom_minimum_size = Vector2(0, 34)
	graphics_btn.pressed.connect(_on_graphics)
	vbox.add_child(graphics_btn)

	# ---- 调试选项入口 ----
	# 单独开一个面板而不是在这里铺开：调试分类有 7 项且以后还会加，
	# 全塞进设置面板会把设置撑得很长、主音量/全屏反而不好找。
	var debug_btn := Button.new()
	debug_btn.name = "DebugButton"
	debug_btn.text = "调试选项…"
	debug_btn.custom_minimum_size = Vector2(0, 34)
	debug_btn.pressed.connect(_on_debug)
	vbox.add_child(debug_btn)

	vbox.add_child(HSeparator.new())

	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(0, 40)
	back.pressed.connect(_on_back)
	vbox.add_child(back)


# ============================================
# 布局（_ready 时与窗口尺寸变化时调用，后者由 UIManager 驱动）
# ============================================

func on_viewport_resized() -> void:
	var vp := get_viewport_rect().size
	size = vp
	position = Vector2.ZERO

	_dimmer.size = vp
	_dimmer.position = Vector2.ZERO

	# 居中面板：锚点全在中心 + 对称 offset，窗口变化时自动跟随。
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
# 回调
# ============================================

func _on_volume_changed(value: float) -> void:
	# 0 表示静音，直接给一个足够低的分贝，避免算出 -inf
	var linear := value / 100.0
	AudioServer.set_bus_volume_db(BUS_MASTER, -80.0 if linear <= 0.0 else linear_to_db(linear))


func _on_fullscreen_toggled(pressed: bool) -> void:
	# 委托给 GraphicsConfig：全屏/分辨率只有一份状态，
	# 图像设置面板与这里的勾选框不会互相覆盖。
	GraphicsConfig.set_fullscreen(pressed)


## 当前是否处于全屏状态
func _is_fullscreen_mode() -> bool:
	return GraphicsConfig.fullscreen


# ============================================
# 每次显示时同步（UIManager.open_panel_impl 会调 on_shown）
# ============================================

func on_shown() -> void:
	# 玩家可能在图像设置里改过全屏，回来时勾选框要跟上。
	# set_pressed_no_signal：否则会反过来触发 toggled → 再写一次配置。
	_full_check.set_pressed_no_signal(_is_fullscreen_mode())


## 打开图像设置面板（压栈，关掉后回到设置）
func _on_graphics() -> void:
	UIManager.open_panel(UIManager.GRAPHICS_PANEL)


## 打开调试选项面板。
## 用 open 而不是替换：设置面板留在栈里，关掉调试后自然回到设置。
func _on_debug() -> void:
	UIManager.open_panel(UIManager.DEBUG_PANEL)


func _on_back() -> void:
	UIManager.close_panel(UIManager.SETTINGS_PANEL)
