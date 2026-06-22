# script/ui/hud_ui.gd
# ============================================
# HUD界面 - 游戏主界面显示
#
# 功能：
# 1. 快捷栏（底部中央，9格）
# 2. 状态栏（左侧：电量、生命值、体温）
# 3. 按键提示（底部）
# 4. 小地图按钮（右上角）
# 5. 菜单按钮（右上角）
# ============================================

class_name HUDUI
extends Control

# ============================================
# 导出变量
# ============================================

# 快捷栏槽位数
@export var hotbar_slots: int = 9

# 状态栏显示的数值
@export var current_health: int = 100
@export var max_health: int = 100
@export var current_power: int = 100
@export var current_temperature: int = 30

# ============================================
# 私有变量
# ============================================

# 快捷栏槽位数组
var _hotbar_slots: Array[ItemSlotUI] = []

# 状态栏节点引用
var _health_label: Label
var _power_label: Label
var _temperature_label: Label

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	_setup_ui()

func _input(event: InputEvent) -> void:
	# Tab 切换背包
	if event.is_action_pressed("ui_tab"):
		_toggle_inventory()
	# M 切换小地图
	if event.is_action_pressed("toggle_minimap"):
		_toggle_minimap()
	# ESC 打开菜单
	if event.is_action_pressed("ui_cancel"):
		_open_menu()

# ============================================
# 公共方法 - 更新状态
# ============================================

func update_health(health: int, max_h: int) -> void:
	current_health = health
	max_health = max_h
	if _health_label:
		_health_label.text = "♥ %d/%d" % [health, max_h]

func update_power(power: int) -> void:
	current_power = power
	if _power_label:
		_power_label.text = "⚡ %d" % power

func update_temperature(temp: int) -> void:
	current_temperature = temp
	if _temperature_label:
		_temperature_label.text = "🌡 %d" % temp

# ============================================
# 私有方法 - UI设置
# ============================================

func _setup_ui() -> void:
	# 设置全屏覆盖
	full_anchor()
	
	# 创建快捷栏（底部中央）
	_create_hotbar()
	
	# 创建状态栏（左侧）
	_create_status_panel()
	
	# 创建按键提示（底部中央）
	_create_control_hints()
	
	# 创建右上角按钮
	_create_topright_buttons()

# ----------------------------------------
# 设置全屏锚点
# ----------------------------------------
func full_anchor() -> void:
	anchor_left = 0
	anchor_top = 0
	anchor_right = 1
	anchor_bottom = 1
	offset_left = 0
	offset_top = 0
	offset_right = 0
	offset_bottom = 0

# ----------------------------------------
# 创建快捷栏
# ----------------------------------------
func _create_hotbar() -> void:
	# 创建容器（底部居中）
	var hotbar_container = HBoxContainer.new()
	hotbar_container.name = "HotbarContainer"
	hotbar_container.alignment = BoxContainer.ALIGNMENT_CENTER
	# 底部偏移
	hotbar_container.position = Vector2(0, get_viewport_rect().size.y - 100)
	hotbar_container.custom_minimum_size = Vector2(0, 80)
	add_child(hotbar_container)
	
	# 设置层级（确保在最上层）
	hotbar_container.z_index = 100
	
	# 创建9个槽位
	for i in range(hotbar_slots):
		var slot = _create_hotbar_slot(i)
		_hotbar_slots.append(slot)
		hotbar_container.add_child(slot)
	
	# 设置槽位尺寸
	await ready
	var slot_size = 64
	var total_width = slot_size * hotbar_slots + 8 * (hotbar_slots - 1)
	hotbar_container.position.x = (get_viewport_rect().size.x - total_width) / 2

# ----------------------------------------
# 创建快捷栏单个槽位
# ----------------------------------------
func _create_hotbar_slot(index: int) -> ItemSlotUI:
	var slot = ItemSlotUI.new()
	slot.name = "HotbarSlot%d" % index
	slot.slot_index = index
	slot.custom_minimum_size = Vector2(64, 64)
	return slot

# ----------------------------------------
# 创建状态栏面板
# ----------------------------------------
func _create_status_panel() -> void:
	# 创建面板
	var panel = PanelContainer.new()
	panel.name = "StatusPanel"
	panel.anchor_top = 0
	panel.anchor_bottom = 0
	panel.offset_left = 20
	panel.offset_top = 20
	panel.offset_right = 140
	panel.offset_bottom = 140
	panel.z_index = 100
	
	# 设置背景样式
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	
	add_child(panel)
	
	# 创建垂直布局
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)
	
	# 电量
	_power_label = Label.new()
	_power_label.text = "⚡ %d" % current_power
	_power_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_power_label)
	
	# 生命值
	_health_label = Label.new()
	_health_label.text = "♥ %d/%d" % [current_health, max_health]
	_health_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_health_label)
	
	# 体温
	_temperature_label = Label.new()
	_temperature_label.text = "🌡 %d" % current_temperature
	_temperature_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_temperature_label)

# ----------------------------------------
# 创建按键提示
# ----------------------------------------
func _create_control_hints() -> void:
	var hints = Label.new()
	hints.name = "ControlHints"
	hints.text = "[E] 互动  [F] 攻击  [Tab] 背包"
	hints.anchor_left = 0.5
	hints.anchor_right = 0.5
	hints.anchor_top = 1.0
	hints.anchor_bottom = 1.0
	hints.offset_top = -60
	hints.offset_bottom = -30
	hints.offset_right = 0
	hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hints.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hints.z_index = 100
	add_child(hints)

# ----------------------------------------
# 创建右上角按钮
# ----------------------------------------
func _create_topright_buttons() -> void:
	var vbox = VBoxContainer.new()
	vbox.name = "TopRightButtons"
	vbox.alignment = BoxContainer.ALIGNMENT_END
	vbox.anchor_left = 1.0
	vbox.anchor_right = 1.0
	vbox.anchor_top = 0.0
	vbox.anchor_bottom = 0.0
	vbox.offset_left = -110
	vbox.offset_top = 20
	vbox.offset_right = -20
	vbox.offset_bottom = 100
	vbox.z_index = 100
	add_child(vbox)
	
	# 小地图按钮
	var minimap_btn = _create_button("[M] 小地图")
	vbox.add_child(minimap_btn)
	
	# 菜单按钮
	var menu_btn = _create_button("[Esc] 菜单")
	vbox.add_child(menu_btn)

# ----------------------------------------
# 创建按钮
# ----------------------------------------
func _create_button(text: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(90, 32)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return btn

# ============================================
# 私有方法 - 交互
# ============================================

func _toggle_inventory() -> void:
	# 通知打开/关闭背包UI
	var inventory_ui = get_node_or_null("/root/Map/CanvasLayer/InventoryUI")
	if inventory_ui:
		inventory_ui.toggle()

func _toggle_minimap() -> void:
	# TODO: 小地图功能
	pass

func _open_menu() -> void:
	# TODO: 菜单功能
	pass
