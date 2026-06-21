# script/ui/item_slot_ui.gd
# ============================================
# 物品槽UI - 单个物品槽的可视化显示
#
# 功能：
# 1. 显示物品图标和数量
# 2. 处理鼠标悬停和点击事件
# 3. 支持拖拽操作
# 4. 显示选中高亮效果
# ============================================

class_name ItemSlotUI
extends PanelContainer

# ============================================
# 信号
# ============================================

# 点击信号
signal clicked(slot_index: int, button: int)

# 悬停信号
signal hovered(slot_index: int)

# 悬停离开信号
signal unhovered(slot_index: int)

# 拖拽开始信号
signal drag_started(slot_index: int)

# 拖拽结束信号
signal drag_ended(slot_index: int)

# ============================================
# 导出变量
# ============================================

# 槽位索引
@export var slot_index: int = -1

# 是否可交互
@export var interactive: bool = true

# ============================================
# 私有变量
# ============================================

# 物品实例引用
var _item: ItemInstance

# UI节点引用
var _icon_rect: TextureRect
var _quantity_label: Label

# 是否正在被拖拽
var _is_dragging: bool = false

# 是否被悬停
var _is_hovered: bool = false

# 是否被选中
var _is_selected: bool = false

# 默认样式
var _normal_style: StyleBoxFlat
var _hovered_style: StyleBoxFlat
var _selected_style: StyleBoxFlat

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	_setup_ui()
	_setup_styles()

# ----------------------------------------
# 设置UI函数
# 创建子节点
# ----------------------------------------
func _setup_ui() -> void:
	# 设置最小尺寸
	custom_minimum_size = Vector2(64, 64)

	# 创建图标容器
	var margin = MarginContainer.new()
	margin.name = "MarginContainer"
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	add_child(margin)

	# 创建图标
	_icon_rect = TextureRect.new()
	_icon_rect.name = "Icon"
	_icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.texture = null
	margin.add_child(_icon_rect)

	# 创建数量标签
	_quantity_label = Label.new()
	_quantity_label.name = "Quantity"
	_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_quantity_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_quantity_label.add_theme_font_size_override("font_size", 14)
	_quantity_label.add_theme_color_override("font_color", Color.WHITE)
	_quantity_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_quantity_label.add_theme_constant_override("outline_size", 2)
	_quantity_label.visible = false
	add_child(_quantity_label)

# ----------------------------------------
# 设置样式函数
# 创建不同的样式
# ----------------------------------------
func _setup_styles() -> void:
	# 普通样式
	_normal_style = StyleBoxFlat.new()
	_normal_style.bg_color = Color(0.2, 0.2, 0.2, 0.8)
	_normal_style.border_color = Color(0.4, 0.4, 0.4)
	_normal_style.set_border_width_all(2)
	_normal_style.set_corner_radius_all(4)

	# 悬停样式
	_hovered_style = StyleBoxFlat.new()
	_hovered_style.bg_color = Color(0.3, 0.3, 0.3, 0.9)
	_hovered_style.border_color = Color(0.6, 0.6, 0.6)
	_hovered_style.set_border_width_all(2)
	_hovered_style.set_corner_radius_all(4)

	# 选中样式
	_selected_style = StyleBoxFlat.new()
	_selected_style.bg_color = Color(0.2, 0.3, 0.4, 0.9)
	_selected_style.border_color = Color(0.4, 0.7, 1.0)
	_selected_style.set_border_width_all(2)
	_selected_style.set_corner_radius_all(4)

	# 应用默认样式
	add_theme_stylebox_override("panel", _normal_style)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置物品函数
# 更新槽位显示
#
# 参数：item - 物品实例
# ----------------------------------------
func set_item(item: ItemInstance) -> void:
	_item = item
	_update_display()

# ----------------------------------------
# 获取物品函数
# 返回当前槽位的物品
# ----------------------------------------
func get_item() -> ItemInstance:
	return _item

# ----------------------------------------
# 清空槽位函数
# 移除物品显示
# ----------------------------------------
func clear_slot() -> void:
	_item = null
	_update_display()

# ----------------------------------------
# 设置选中状态函数
#
# 参数：selected - 是否选中
# ----------------------------------------
func set_selected(selected: bool) -> void:
	_is_selected = selected
	_update_style()

# ----------------------------------------
# 是否为空函数
# ----------------------------------------
func is_empty() -> bool:
	return not _item or _item.is_empty()

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 更新显示函数
# 刷新图标和数量
# ----------------------------------------
func _update_display() -> void:
	if _item and _item.data:
		# 显示图标
		_icon_rect.texture = _item.data.icon
		_icon_rect.modulate = Color.WHITE

		# 显示数量
		if _item.quantity > 1:
			_quantity_label.text = str(_item.quantity)
			_quantity_label.visible = true
		else:
			_quantity_label.visible = false
	else:
		# 清空显示
		_icon_rect.texture = null
		_quantity_label.visible = false

# ----------------------------------------
# 更新样式函数
# 根据状态更新边框颜色
# ----------------------------------------
func _update_style() -> void:
	if _is_selected:
		add_theme_stylebox_override("panel", _selected_style)
	elif _is_hovered:
		add_theme_stylebox_override("panel", _hovered_style)
	else:
		add_theme_stylebox_override("panel", _normal_style)

# ============================================
# 输入处理
# ============================================

func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return

	# 鼠标进入
	if event is InputEventMouseMotion:
		if not _is_hovered:
			_is_hovered = true
			_update_style()
			hovered.emit(slot_index)

	# 鼠标点击
	if event is InputEventMouseButton:
		if event.pressed:
			clicked.emit(slot_index, event.button_index)

# ----------------------------------------
# 鼠标进入检测
# ----------------------------------------
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_ENTER:
			if interactive:
				_is_hovered = true
				_update_style()
				hovered.emit(slot_index)

		NOTIFICATION_MOUSE_EXIT:
			if interactive:
				_is_hovered = false
				_update_style()
				unhovered.emit(slot_index)
