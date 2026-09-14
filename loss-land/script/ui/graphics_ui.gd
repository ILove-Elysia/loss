# script/ui/graphics_ui.gd
# ============================================
# 图像设置面板（由 UIManager 懒加载，modal）
#
# 从「设置 → 图像设置」压栈打开，返回后回到设置面板。
# 结构照抄 DebugUI（全屏 dimmer + 居中面板），同样的坑：
#   _ready 里 set_anchors_preset 会得到 0x0，必须显式给 size 赋值；
#   窗口变化由 UIManager 调 on_viewport_resized() 同步。
#
# 本文件只是界面，状态全在 GraphicsConfig（静态类）里，别在这里另存一份。
# 每个控件都用它的"改完立刻生效并落盘"接口，所以没有"应用/取消"按钮：
# 分辨率这类设置多一步确认只会让人犹豫，改错了再改回来即可。
#
# ★ 坐标单位提醒 ★
#   project.godot 的 [display] 用 1280×720 作设计基准 + canvas_items 拉伸，
#   所以 get_viewport_rect() 给的是**设计单位**（恒为 1280×720），
#   控件尺寸/位置一律按这个基准写，不要按实际分辨率算。
#
# 扩展点：加新设置项就写一个 _add_xxx_row()，放在「更多设置」分隔线之上。
# ============================================

class_name GraphicsUI
extends Control

var _dimmer: ColorRect
var _panel: PanelContainer

## 控件引用：on_shown 时要按 GraphicsConfig 的当前值回填
var _full_check: CheckBox
var _res_opt: OptionButton
var _scale_slider: HSlider
var _scale_value: Label
var _vsync_opt: OptionButton
var _fps_opt: OptionButton
var _res_row: HBoxContainer
var _res_label: Label
## 内嵌运行（编辑器里 F5）时的提示条：窗口由编辑器管理，分辨率/全屏不可用
var _embed_note: Label
## 分辨率下拉框每一项对应的尺寸（与 OptionButton 的 index 一一对应）
var _res_values: Array = []


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
	_panel.name = "GraphicsPanel"
	_panel.custom_minimum_size = Vector2(560, 0)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "图像设置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "改动即时生效并自动保存。若画面变得异常，删掉 user://graphics_config.cfg 即可恢复默认。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(520, 0)
	hint.add_theme_color_override("font_color", Color(0.72, 0.74, 0.78))
	hint.add_theme_font_size_override("font_size", 13)
	vbox.add_child(hint)

	# ---- 内嵌运行提示（平时隐藏）----
	# 编辑器内嵌窗口由编辑器自己管理，分辨率/全屏改了也不生效；
	# 而且绝不能让后端去改窗口（见 GraphicsConfig._can_control_window 的事故记录）。
	_embed_note = Label.new()
	_embed_note.text = "当前在编辑器的内嵌窗口中运行（F5）：分辨率 / 全屏由编辑器接管，此处改了也只存配置、窗口不会变。想真正改分辨率 / 全屏，请以独立窗口运行游戏——编辑器顶部「运行」按钮旁的下拉选「在单独窗口中运行」，或菜单「项目 → 运行项目」——再改即可生效（配置已存，启动会自动套用）。"
	_embed_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_embed_note.custom_minimum_size = Vector2(520, 0)
	_embed_note.add_theme_color_override("font_color", Color(0.95, 0.76, 0.4))
	_embed_note.add_theme_font_size_override("font_size", 13)
	_embed_note.visible = false
	vbox.add_child(_embed_note)

	vbox.add_child(HSeparator.new())

	# ---- 全屏 ----
	_full_check = CheckBox.new()
	_full_check.name = "FullscreenCheck"
	_full_check.text = "全屏（分辨率由系统决定）"
	_full_check.toggled.connect(_on_fullscreen_toggled)
	vbox.add_child(_full_check)

	# ---- 分辨率 ----
	_res_row = HBoxContainer.new()
	_res_row.add_theme_constant_override("separation", 8)
	vbox.add_child(_res_row)

	_res_label = Label.new()
	_res_label.text = "分辨率"
	_res_label.custom_minimum_size = Vector2(90, 0)
	_res_row.add_child(_res_label)

	_res_opt = OptionButton.new()
	_res_opt.name = "ResolutionOption"
	_res_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_res_opt.item_selected.connect(_on_resolution_selected)
	_res_row.add_child(_res_opt)

	# ---- 界面缩放 ----
	# 高分辨率屏上 HUD/面板偏小时的手动旋钮，走 content_scale_factor，
	# 与分辨率无关（换分辨率不会重置它）。
	var scale_row := HBoxContainer.new()
	scale_row.add_theme_constant_override("separation", 8)
	vbox.add_child(scale_row)

	var scale_label := Label.new()
	scale_label.text = "界面缩放"
	scale_label.custom_minimum_size = Vector2(90, 0)
	scale_row.add_child(scale_label)

	_scale_slider = HSlider.new()
	_scale_slider.name = "UiScaleSlider"
	_scale_slider.min_value = GraphicsConfig.MIN_UI_SCALE
	_scale_slider.max_value = GraphicsConfig.MAX_UI_SCALE
	_scale_slider.step = 0.05
	_scale_slider.custom_minimum_size = Vector2(200, 0)
	_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scale_slider.value_changed.connect(_on_ui_scale_changed)
	scale_row.add_child(_scale_slider)

	_scale_value = Label.new()
	_scale_value.custom_minimum_size = Vector2(56, 0)
	_scale_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	scale_row.add_child(_scale_value)

	# ---- 垂直同步 ----
	_vsync_opt = OptionButton.new()
	_vsync_opt.name = "VSyncOption"
	_add_option_row(vbox, "垂直同步", _vsync_opt)
	for m in GraphicsConfig.VSYNC_MODES:
		_vsync_opt.add_item(GraphicsConfig.vsync_label(int(m)))
	_vsync_opt.item_selected.connect(_on_vsync_selected)

	# ---- 帧率上限 ----
	_fps_opt = OptionButton.new()
	_fps_opt.name = "FpsLimitOption"
	_add_option_row(vbox, "帧率上限", _fps_opt)
	for v in GraphicsConfig.FPS_LIMITS:
		_fps_opt.add_item(GraphicsConfig.fps_label(int(v)))
	_fps_opt.item_selected.connect(_on_fps_selected)

	vbox.add_child(HSeparator.new())

	# ---- 更多设置（待后续补充）----
	# 用户明确说"其他图像设置待后续补充"，这里留一个明确的位置：
	# 新项直接加在本分隔线之上即可。
	var more := Label.new()
	more.text = "更多图像选项（无边框 / 独占全屏、渲染缩放、抗锯齿、阴影质量、亮度等）将在后续补充。"
	more.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	more.custom_minimum_size = Vector2(520, 0)
	more.add_theme_color_override("font_color", Color(0.62, 0.64, 0.68))
	more.add_theme_font_size_override("font_size", 12)
	vbox.add_child(more)

	vbox.add_child(HSeparator.new())

	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(0, 40)
	back.pressed.connect(_on_back)
	vbox.add_child(back)

	_sync_controls()


## 一行「左标签 + 右控件」的通用排版：标签定宽，控件撑满剩余宽度
func _add_option_row(parent: VBoxContainer, label_text: String, opt: OptionButton) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(90, 0)
	row.add_child(label)

	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(opt)


# ============================================
# 布局（_ready 时与窗口尺寸变化时调用，后者由 UIManager 驱动）
# ============================================

func on_viewport_resized() -> void:
	# 注意：开了 canvas_items 拉伸后这里拿到的是设计单位（恒 1280×720），
	# 和 HUD 等其他面板同一套坐标，不需要换算。
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
	_sync_controls()


# ============================================
# 回调
# ============================================

func _on_fullscreen_toggled(pressed: bool) -> void:
	GraphicsConfig.set_fullscreen(pressed)
	_sync_controls()


func _on_resolution_selected(index: int) -> void:
	if index < 0 or index >= _res_values.size():
		return
	GraphicsConfig.set_window_size(_res_values[index])
	_sync_controls()


func _on_ui_scale_changed(value: float) -> void:
	GraphicsConfig.set_ui_scale(value)
	_scale_value.text = "%d%%" % roundi(value * 100.0)


func _on_vsync_selected(index: int) -> void:
	if index < 0 or index >= GraphicsConfig.VSYNC_MODES.size():
		return
	GraphicsConfig.set_vsync(int(GraphicsConfig.VSYNC_MODES[index]))
	_sync_controls()


func _on_fps_selected(index: int) -> void:
	if index < 0 or index >= GraphicsConfig.FPS_LIMITS.size():
		return
	GraphicsConfig.set_fps_limit(int(GraphicsConfig.FPS_LIMITS[index]))
	_sync_controls()


func _on_back() -> void:
	UIManager.close_panel(UIManager.GRAPHICS_PANEL)


## 当前是否运行在编辑器的内嵌游戏窗口里
func _is_embedded() -> bool:
	# 与 GraphicsConfig._can_control_window 保持一致：编辑器里跑（F5 内嵌或
	# 编辑器内单独窗口）都算"不可改窗口"，把分辨率/全屏控件禁用并提示。
	if Engine.is_editor_hint():
		return true
	var tree := get_tree()
	if tree == null or tree.root == null:
		return false
	return tree.root.is_embedded()


# ============================================
# 私有
# ============================================

## 按 GraphicsConfig 的当前值回填所有控件。
## 下拉框用 select()、滑块与勾选框用 set_*_no_signal：
## 它们只在"用户操作"时才发信号，所以回填不会反向触发写盘
## （比先断开再连信号干净）。
func _sync_controls() -> void:
	if _full_check == null:
		return

	# 内嵌运行：分辨率/全屏改了也不生效，直接禁掉并说明原因，
	# 否则玩家会反复改一个"没反应"的控件，还以为游戏坏了。
	var embedded := _is_embedded()
	_embed_note.visible = embedded
	_full_check.disabled = embedded

	_full_check.set_pressed_no_signal(GraphicsConfig.fullscreen)

	# 分辨率候选要按当前屏幕过滤，每次同步都重建
	_rebuild_resolution_items()
	_res_opt.select(_index_of_resolution(GraphicsConfig.window_size))

	# 全屏时分辨率由系统决定，禁用这一行并说明原因，
	# 否则玩家会反复改一个"没反应"的下拉框。
	var can_res := not GraphicsConfig.fullscreen and not embedded
	_res_opt.disabled = not can_res
	_res_label.modulate = Color(1, 1, 1, 1) if can_res else Color(1, 1, 1, 0.45)

	_scale_slider.set_value_no_signal(GraphicsConfig.ui_scale)
	_scale_value.text = "%d%%" % roundi(GraphicsConfig.ui_scale * 100.0)

	_vsync_opt.select(_index_of(GraphicsConfig.VSYNC_MODES, GraphicsConfig.vsync_mode, 1))
	_fps_opt.select(_index_of(GraphicsConfig.FPS_LIMITS, GraphicsConfig.fps_limit, 0))


func _rebuild_resolution_items() -> void:
	_res_values = GraphicsConfig.resolution_choices()
	_res_opt.clear()
	for v in _res_values:
		# 变量名避开 size：本类是 Control，size 是它的属性名，同名会遮蔽警告
		var sz: Vector2i = v
		_res_opt.add_item(GraphicsConfig.resolution_label(sz))


func _index_of_resolution(target: Vector2i) -> int:
	for i in _res_values.size():
		if _res_values[i] == target:
			return i
	return 0


## 在候选表里找 value 的下标，找不到时返回 fallback
## （后端值可能是手改配置文件写进来的，不该让下拉框落在空项上）
func _index_of(values: Array, value: int, fallback: int) -> int:
	for i in values.size():
		if int(values[i]) == value:
			return i
	return fallback
