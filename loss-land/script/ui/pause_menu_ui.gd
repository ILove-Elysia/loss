# script/ui/pause_menu_ui.gd
# ============================================
# 暂停菜单（由 UIManager 懒加载，modal：打开时暂停游戏）
#
# 结构：全屏半透明遮罩 + 居中面板。
# 遮罩的作用不只是变暗——它吃掉鼠标，避免暂停时点到后面的 3D 世界。
#
# 按 Esc 由 UIManager 统一处理：本面板在栈顶时会被关掉。
# 从本面板进入设置后，设置压在栈顶，Esc 先关设置、回到这里。
#
# 布局注意（重要坑）：
#   运行时 new() 出来的面板不能在 _ready 里用 set_anchors_preset 铺全屏——
#   实测锚点重算发生在布局阶段而非回调内，_ready 回调里调用会得到 0x0 的尺寸，
#   内部居中面板的中心点因此算到 (0,0)，半个面板落在屏幕外。
#   正确做法：显式给 size 赋值；窗口变化由 UIManager 调 on_viewport_resized() 同步。
#   （主场景 tscn 里配置的 HUDUI 不受影响：场景加载流程由引擎布局，不走这条路。）
# ============================================

class_name PauseMenuUI
extends Control

## 主菜单场景路径
const MAIN_MENU_SCENE := "res://tscn/main_menu.tscn"

var _dimmer: ColorRect
var _panel: PanelContainer
## 菜单本体（标题 + 各按钮）
var _menu_box: VBoxContainer
## 「返回主菜单」的二次确认（默认隐藏，与菜单本体二选一显示）
var _confirm_box: VBoxContainer
## 「返回主菜单」确认框里的说明文字（按是否有激活存档动态变化）
var _confirm_hint: Label
## 保存按钮（保存成功/失败时改文字提示，回 on_shown 复位）
var _save_btn: Button


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	on_viewport_resized()


func _build() -> void:
	# ---- 半透明遮罩 ----
	_dimmer = ColorRect.new()
	_dimmer.name = "Dimmer"
	_dimmer.color = Color(0, 0, 0, 0.55)
	_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dimmer)

	# ---- 居中面板 ----
	_panel = PanelContainer.new()
	_panel.name = "MenuPanel"
	_panel.custom_minimum_size = Vector2(260, 0)
	add_child(_panel)

	_menu_box = _build_menu_box()
	_panel.add_child(_menu_box)

	# 确认框默认隐藏：只在点「返回主菜单」时才顶掉菜单本体
	_confirm_box = _build_confirm_box()
	_panel.add_child(_confirm_box)
	_confirm_box.visible = false


## 菜单本体：继续游戏 / 保存游戏 / 设置 / 返回主菜单 / 退出游戏
func _build_menu_box() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.name = "MenuBox"
	vbox.add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	vbox.add_child(_make_button("继续游戏", _on_resume))
	_save_btn = _make_button("保存游戏", _on_save)
	vbox.add_child(_save_btn)
	vbox.add_child(_make_button("设置", _on_settings))
	vbox.add_child(_make_button("返回主菜单", _on_return_to_menu))
	vbox.add_child(_make_button("退出游戏", _on_quit))
	return vbox


## 「返回主菜单」的二次确认：当前存档不落盘，返回即丢进度，必须问一句
func _build_confirm_box() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.name = "ConfirmBox"
	vbox.add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "返回主菜单？"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	var hint := Label.new()
	# 文字在 on_shown / _on_return_to_menu 里按"有没有激活存档"动态更新
	hint.name = "ConfirmHint"
	hint.text = ""
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(240, 0)
	_confirm_hint = hint
	vbox.add_child(hint)

	vbox.add_child(_make_button("确定返回", _on_return_confirmed))
	vbox.add_child(_make_button("取消", _on_return_cancelled))
	return vbox


func _make_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(callback)
	return btn


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
	# 四个锚点都重合在中心时，必须 BOTH 才会对称向四周扩展，否则会偏到右下
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# ============================================
# 回调
# ============================================

# 每次被 UIManager 显示时调用：
# 若上次停在确认框就关掉了面板，这里把它复位回菜单本体；
# 保存按钮的反馈文字也一并复位
func on_shown() -> void:
	if _save_btn != null:
		_save_btn.text = "保存游戏"
	_show_menu_box()


func _on_resume() -> void:
	UIManager.close_panel(UIManager.PAUSE_PANEL)


## 手动保存到当前激活的存档槽（从主菜单新建/载入时已设好）
func _on_save() -> void:
	if _save_btn == null:
		return
	# 直接运行 map.tscn（没经过主菜单）时没有激活槽位，这里现建一个，
	# 免得玩家点了"保存游戏"却什么都没发生
	if SaveManager.active_slot_id < 0:
		# 第二参数 false：沿用当前这局已生成的地图种子，别再摇一个新的
		SaveManager.create_slot("存档 %s" % Time.get_datetime_string_from_system(false).substr(0, 16), false)
	if SaveManager.save_active_slot():
		_save_btn.text = "已保存 ✓"
		DebugConfig.log_msg(DebugConfig.CAT_UI, "[暂停菜单] 手动保存成功", [])
	else:
		_save_btn.text = "保存失败（无激活存档）"
		DebugConfig.warn_msg(DebugConfig.CAT_UI, "[暂停菜单] 手动保存失败", [])


func _on_settings() -> void:
	# 不关本面板：设置压栈在其上，关闭设置后自然回到这里
	UIManager.open_panel(UIManager.SETTINGS_PANEL)


func _on_quit() -> void:
	# 退出前自动保存（无激活存档时 save_active_slot 内部会安全跳过）
	SaveManager.save_active_slot()
	# 退出前解除暂停，避免部分平台在暂停态下走不到清理流程
	get_tree().paused = false
	get_tree().quit()


# ============================================
# 返回主菜单
# ============================================

func _on_return_to_menu() -> void:
	# 说明文字按"有没有激活存档"给不同的预期：
	# 有 → 返回前自动保存；没有 → 进度真的会丢
	if _confirm_hint != null:
		if SaveManager.active_slot_id >= 0:
			_confirm_hint.text = "返回主菜单前会自动保存当前进度。"
		else:
			_confirm_hint.text = "当前没有激活的存档，返回后进度会丢失。"
	_menu_box.visible = false
	_confirm_box.visible = true
	# 两块内容高度不同，切换后要按新的最小尺寸重新居中
	on_viewport_resized()


func _on_return_cancelled() -> void:
	_show_menu_box()


func _on_return_confirmed() -> void:
	# 返回前自动保存（有激活存档才落盘）
	SaveManager.save_active_slot()
	# 必须先解除暂停再切场景：paused 是 SceneTree 的全局状态，
	# 若带着 paused=true 进主菜单，再点"开始游戏"会发现世界仍是冻结的。
	get_tree().paused = false
	# 旧场景释放后 UIManager.instance 会变成悬空引用；
	# 主菜单场景自己的 UIManager 会在 _ready 里重新赋值。
	UIManager.instance = null
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


## 显示菜单本体、隐藏确认框
func _show_menu_box() -> void:
	_confirm_box.visible = false
	_menu_box.visible = true
	on_viewport_resized()
