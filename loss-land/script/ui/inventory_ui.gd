# script/ui/inventory_ui.gd
# ============================================
# 背包UI - 显示整个背包界面
#
# 功能：
# 1. 显示所有物品槽
# 2. 处理物品拖拽
# 3. 显示物品提示框
# 4. 支持键盘快捷键
# ============================================

class_name InventoryUI
extends Control

# ============================================
# 信号
# ============================================

# 关闭信号
signal closed()

# 物品使用信号
signal item_used(slot: int)

# ============================================
# 导出变量
# ============================================

# 关联的背包
# 注意：不要在编辑器中绑定，运行时会自动查找玩家的背包
@export var inventory: Inventory:
	set(value):
		# 只有在运行时才处理连接
		if Engine.is_editor_hint():
			inventory = value
			return
		# 断开旧背包的信号
		if inventory:
			_disconnect_inventory_signals()
		inventory = value
		# 连接新背包的信号
		if inventory:
			_connect_inventory_signals()
			_create_slots()

# 每行显示的槽位数
@export var columns: int = 5

# 槽位间距
@export var slot_spacing: int = 4

# ============================================
# 私有变量
# ============================================

# 槽位UI数组
var _slot_uis: Array[ItemSlotUI] = []

# 容器节点
var _grid_container: GridContainer

# 物品提示框
var _tooltip: ItemTooltip

# 当前悬停的槽位
var _hovered_slot: int = -1

# 当前选中的槽位
var _selected_slot: int = -1

# 拖拽相关
var _drag_slot: int = -1
var _drag_preview: Control

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	_setup_ui()
	_setup_tooltip()

	# 默认隐藏
	visible = false

	# 动态查找玩家的背包
	_find_player_inventory()

func _input(event: InputEvent) -> void:
	# 按ESC关闭
	if event.is_action_pressed("ui_cancel"):
		if visible:
			close()
			get_viewport().set_input_as_handled()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 打开背包函数
# ----------------------------------------
func open() -> void:
	visible = true
	# 暂停游戏（可选）
	# get_tree().paused = true

# ----------------------------------------
# 关闭背包函数
# ----------------------------------------
func close() -> void:
	visible = false
	_hide_tooltip()
	closed.emit()
	# 恢复游戏
	# get_tree().paused = false

# ----------------------------------------
# 切换显示函数
# ----------------------------------------
func toggle() -> void:
	if visible:
		close()
	else:
		open()

# ----------------------------------------
# 刷新显示函数
# 重新加载所有槽位
# ----------------------------------------
func refresh() -> void:
	if not inventory:
		return

	for i in range(_slot_uis.size()):
		var slot_ui = _slot_uis[i]
		var item = inventory.get_item(i)
		slot_ui.set_item(item)

# ============================================
# 私有方法 - UI设置
# ============================================

# ----------------------------------------
# 设置UI函数
# 创建界面结构
# ----------------------------------------
func _setup_ui() -> void:
	# 设置锚点和大小
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -200
	offset_top = -200
	offset_right = 200
	offset_bottom = 200

	# 创建背景
	var background = PanelContainer.new()
	background.name = "Background"
	add_child(background)

	# 创建垂直布局
	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.add_theme_constant_override("separation", 8)
	background.add_child(vbox)

	# 创建标题
	var title = Label.new()
	title.name = "Title"
	title.text = "背包"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# 创建分隔线
	var separator = HSeparator.new()
	separator.name = "Separator"
	vbox.add_child(separator)

	# 创建网格容器
	_grid_container = GridContainer.new()
	_grid_container.name = "GridContainer"
	_grid_container.columns = columns
	_grid_container.add_theme_constant_override("h_separation", slot_spacing)
	_grid_container.add_theme_constant_override("v_separation", slot_spacing)
	vbox.add_child(_grid_container)

# ----------------------------------------
# 设置提示框函数
# 创建物品提示框
# ----------------------------------------
func _setup_tooltip() -> void:
	_tooltip = ItemTooltip.new()
	_tooltip.name = "Tooltip"
	_tooltip.visible = false
	add_child(_tooltip)

# ----------------------------------------
# 创建槽位函数
# 根据背包大小创建槽位UI
# ----------------------------------------
func _create_slots() -> void:
	if not inventory:
		return

	# 清除现有槽位
	_clear_slots()

	# 创建新槽位
	for i in range(inventory.max_slots):
		var slot_ui = ItemSlotUI.new()
		slot_ui.slot_index = i
		slot_ui.custom_minimum_size = Vector2(64, 64)

		# 连接信号
		slot_ui.clicked.connect(_on_slot_clicked)
		slot_ui.hovered.connect(_on_slot_hovered)
		slot_ui.unhovered.connect(_on_slot_unhovered)

		_grid_container.add_child(slot_ui)
		_slot_uis.append(slot_ui)

	# 刷新显示
	refresh()

# ----------------------------------------
# 清除槽位函数
# 移除所有槽位UI
# ----------------------------------------
func _clear_slots() -> void:
	for slot_ui in _slot_uis:
		if is_instance_valid(slot_ui):
			slot_ui.queue_free()
	_slot_uis.clear()

# ============================================
# 私有方法 - 信号处理
# ============================================

# ----------------------------------------
# 连接背包信号函数
# ----------------------------------------
func _connect_inventory_signals() -> void:
	inventory.item_added.connect(_on_inventory_item_added)
	inventory.item_removed.connect(_on_inventory_item_removed)
	inventory.item_changed.connect(_on_inventory_item_changed)
	inventory.inventory_cleared.connect(_on_inventory_cleared)

# ----------------------------------------
# 断开背包信号函数
# ----------------------------------------
func _disconnect_inventory_signals() -> void:
	if inventory.item_added.is_connected(_on_inventory_item_added):
		inventory.item_added.disconnect(_on_inventory_item_added)
	if inventory.item_removed.is_connected(_on_inventory_item_removed):
		inventory.item_removed.disconnect(_on_inventory_item_removed)
	if inventory.item_changed.is_connected(_on_inventory_item_changed):
		inventory.item_changed.disconnect(_on_inventory_item_changed)
	if inventory.inventory_cleared.is_connected(_on_inventory_cleared):
		inventory.inventory_cleared.disconnect(_on_inventory_cleared)

# ============================================
# 信号回调
# ============================================

# ----------------------------------------
# 槽位点击回调
# ----------------------------------------
func _on_slot_clicked(slot: int, button: int) -> void:
	match button:
		MOUSE_BUTTON_LEFT:
			# 左键选中或使用
			if _selected_slot == slot:
				# 双击使用
				item_used.emit(slot)
			else:
				# 选中
				_select_slot(slot)

		MOUSE_BUTTON_RIGHT:
			# 右键使用
			item_used.emit(slot)

# ----------------------------------------
# 槽位悬停回调
# ----------------------------------------
func _on_slot_hovered(slot: int) -> void:
	_hovered_slot = slot
	_show_tooltip(slot)

# ----------------------------------------
# 槽位悬停离开回调
# ----------------------------------------
func _on_slot_unhovered(slot: int) -> void:
	_hovered_slot = -1
	_hide_tooltip()

# ----------------------------------------
# 背包物品添加回调
# ----------------------------------------
func _on_inventory_item_added(item: ItemInstance, slot: int) -> void:
	if slot >= 0 and slot < _slot_uis.size():
		_slot_uis[slot].set_item(item)

# ----------------------------------------
# 背包物品移除回调
# ----------------------------------------
func _on_inventory_item_removed(item_id: StringName, count: int, slot: int) -> void:
	refresh()

# ----------------------------------------
# 背包物品改变回调
# ----------------------------------------
func _on_inventory_item_changed(slot: int) -> void:
	if slot >= 0 and slot < _slot_uis.size():
		var item = inventory.get_item(slot)
		_slot_uis[slot].set_item(item)

# ----------------------------------------
# 背包清空回调
# ----------------------------------------
func _on_inventory_cleared() -> void:
	refresh()

# ============================================
# 私有方法 - 辅助
# ============================================

# ----------------------------------------
# 选中槽位函数
# ----------------------------------------
func _select_slot(slot: int) -> void:
	# 取消之前的选中
	if _selected_slot >= 0 and _selected_slot < _slot_uis.size():
		_slot_uis[_selected_slot].set_selected(false)

	# 选中新槽位
	_selected_slot = slot
	if _selected_slot >= 0 and _selected_slot < _slot_uis.size():
		_slot_uis[_selected_slot].set_selected(true)

# ----------------------------------------
# 显示提示框函数
# ----------------------------------------
func _show_tooltip(slot: int) -> void:
	if not inventory:
		return

	var item = inventory.get_item(slot)
	if item and item.data:
		_tooltip.set_item(item)
		_tooltip.visible = true

		# 定位到鼠标附近
		var mouse_pos = get_global_mouse_position()
		_tooltip.global_position = mouse_pos + Vector2(16, 16)

# ----------------------------------------
# 隐藏提示框函数
# ----------------------------------------
func _hide_tooltip() -> void:
	if _tooltip:
		_tooltip.visible = false

# ----------------------------------------
# 查找玩家背包函数
# 在场景树中查找玩家节点的 Inventory 组件
# 支持两种方式：
# 1. 通过节点名称 "player"
# 2. 通过节点组 "player"
# ----------------------------------------
func _find_player_inventory() -> void:
	# 方式1：通过节点名称查找
	var player = get_tree().get_first_node_in_group("player")
	if player:
		if player.has_node("Inventory"):
			inventory = player.get_node("Inventory")
			return
	
	# 方式2：通过名称查找
	var player_node = get_tree().get_root().find_child("player", true, false)
	if player_node:
		if player_node.has_node("Inventory"):
			inventory = player_node.get_node("Inventory")
			return
	
	# 方式3：直接查找场景中的 Inventory 节点
	var inventory_node = get_tree().get_root().find_child("Inventory", true, false)
	if inventory_node:
		inventory = inventory_node
