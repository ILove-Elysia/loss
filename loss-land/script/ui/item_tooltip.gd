# script/ui/item_tooltip.gd
# ============================================
# 物品提示框 - 显示物品详细信息
#
# 功能：
# 1. 显示物品名称、类型、描述
# 2. 根据稀有度显示不同颜色
# 3. 显示物品属性
# ============================================

class_name ItemTooltip
extends PanelContainer

# ============================================
# 导出变量
# ============================================

# 最大宽度
@export var max_width: int = 250

# ============================================
# 私有变量
# ============================================

# 当前显示的物品
var _item: ItemInstance

# UI节点引用
var _vbox: VBoxContainer
var _name_label: Label
var _type_label: Label
var _desc_label: RichTextLabel

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	_setup_ui()
	_setup_style()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置物品函数
# 显示指定物品的信息
#
# 参数：item - 物品实例
# ----------------------------------------
func set_item(item: ItemInstance) -> void:
	_item = item
	_update_display()

# ----------------------------------------
# 清空显示函数
# ----------------------------------------
func clear() -> void:
	_item = null
	_name_label.text = ""
	_type_label.text = ""
	_desc_label.text = ""

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 设置UI函数
# 创建界面结构
# ----------------------------------------
func _setup_ui() -> void:
	# 设置大小
	custom_minimum_size.x = max_width

	# 创建内边距
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	# 创建垂直布局
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 4)
	margin.add_child(_vbox)

	# 创建名称标签
	_name_label = Label.new()
	_name_label.name = "NameLabel"
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_vbox.add_child(_name_label)

	# 创建类型标签
	_type_label = Label.new()
	_type_label.name = "TypeLabel"
	_type_label.add_theme_font_size_override("font_size", 12)
	_type_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_type_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_vbox.add_child(_type_label)

	# 创建分隔线
	var separator = HSeparator.new()
	separator.name = "Separator"
	_vbox.add_child(separator)

	# 创建描述标签
	_desc_label = RichTextLabel.new()
	_desc_label.name = "DescLabel"
	_desc_label.custom_minimum_size.y = 60
	_desc_label.bbcode_enabled = true
	_desc_label.fit_content = true
	_desc_label.scroll_active = false
	_desc_label.add_theme_font_size_override("normal_font_size", 12)
	_vbox.add_child(_desc_label)

# ----------------------------------------
# 设置样式函数
# ----------------------------------------
func _setup_style() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.95)
	style.border_color = Color(0.3, 0.3, 0.3)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", style)

# ----------------------------------------
# 更新显示函数
# 刷新物品信息
# ----------------------------------------
func _update_display() -> void:
	if not _item or not _item.data:
		clear()
		return

	var data = _item.data

	# 设置名称（带稀有度颜色）
	_name_label.text = data.display_name
	_name_label.add_theme_color_override("font_color", data.get_rarity_color())

	# 设置类型
	_type_label.text = data.get_type_name()

	# 设置描述
	if data.description.is_empty():
		_desc_label.text = ""
	else:
		_desc_label.text = data.description
