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
	# 纯展示控件，绝不能拦鼠标：
	# 提示框紧贴鼠标右下方 (+16,+16)，会盖住所在格子的右下半边。
	# 若不设 IGNORE，玩家在那半边上按下左键会被提示框吃掉，
	# 导致"这个格子拖不动"（拖拽起不来）。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_setup_ui()
	_setup_style()
	# 注意：Godot 的命中测试会穿透 IGNORE 的父节点继续检查子节点，
	# 所以必须把整棵子树都设为 IGNORE（Margin/VBox/RichTextLabel 默认是 STOP）。
	_disable_mouse_recursive(self)

# ----------------------------------------
# 递归关闭整棵子树的鼠标拦截（提示框只负责显示）
# ----------------------------------------
func _disable_mouse_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_disable_mouse_recursive(child)

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

	# 设置描述（末尾附上可执行的操作提示，玩家不用猜）
	var desc: String = data.description
	var hint_text := "[color=#9aa0a6][左键拖拽] 移动位置[/color]"

	# 专属权限（大纲 v0.7 · 2.2.4-④ 决策 ⑦）：能被用但带专属加成 → 绿字；
	# 被其他角色拒用 → 红字。**提前告知**，玩家不用靠"右键试试看"才发现用不了。
	var access_hint: String = data.get_access_hint()
	if not access_hint.is_empty():
		var acc_col: String = "#8fd18f" if data.is_usable_by("") else "#ff8a80"
		hint_text = "[color=%s]%s[/color]\n" % [acc_col, access_hint] + hint_text

	# 被拒时不再提示"右键使用"，免得自相矛盾
	var usable_now: bool = data.is_usable_by("")

	# 建筑类：右键是"放置"，不是"使用"
	if BuildingSystem.is_building(data.item_id):
		hint_text = "[color=#ffd479][右键] 放置到地面[/color]\n" + hint_text
	# 只对"真的能直接用"的物品提示右键使用——
	# 若只判断 data.usable，遇到 usable=true 但 use_effect 为空的数据会"骗玩家"。
	elif usable_now and ItemEffects.can_use(data):
		hint_text = "[color=#8fd18f][右键] 使用[/color]\n" + hint_text

	if desc.is_empty():
		_desc_label.text = hint_text
	else:
		_desc_label.text = desc + "\n\n" + hint_text
