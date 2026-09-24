# script/ui/item_slot_ui.gd
# ============================================
# 物品槽UI - 单个物品槽的可视化显示
#
# 功能：
# 1. 显示物品图标和数量
# 2. 处理鼠标悬停和点击事件
# 3. 支持左键拖拽：拖到另一个槽位即可移动/交换位置
# 4. 显示选中高亮效果；作为拖放目标时显示落点高亮
#
# 关于拖放（Drag & Drop）：
#   使用 Godot 的 Control 原生拖放接口 _get_drag_data / _can_drop_data / _drop_data。
#   好处：
#     - 引擎自带"鼠标位移超过阈值才算拖拽"的判断，单纯点一下不会误触发移动；
#     - 拖拽预览由引擎托管（set_drag_preview），不用自己每帧跟随鼠标。
#   本控件**不直接改背包数据**：只把"从哪个槽拖到哪个槽"通过 item_dropped 信号
#   抛给 InventoryUI，由它调用 Inventory.move_item()，保持"UI 不碰数据"的分层。
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

# 拖拽开始信号（由被拖起的源槽位发出）
signal drag_started(slot_index: int)

# 拖拽结束信号
signal drag_ended(slot_index: int)

# 拖拽放下信号：把 from_slot 的物品放到本槽（= to_slot）
# count < 0 = 整堆；> 0 = 只搬这么多个（拖拽时按住 Ctrl）
# 由 InventoryUI 接收并调用 inventory.move_item(from, to)
signal item_dropped(from_slot: int, to_slot: int, count: int)

# 跨面板拖拽放下信号：source 是拖拽来源面板的标识（见 source_id）
# 由接收方面板转调两个 Inventory（如 箱子 ↔ 背包 的整堆搬运/合并/交换）
signal cross_dropped(source: String, from_slot: int, to_slot: int, count: int)

# ============================================
# 导出变量
# ============================================

# 槽位索引
@export var slot_index: int = -1

# 所属面板标识：随拖拽数据一起发出，接收方用它区分"面板内整理"与"跨面板搬运"
# 例如背包 UI 设 "player"、储物箱 UI 设 "storage"；留空 = 行为同旧版（只发 item_dropped）
@export var source_id: String = ""

# 是否可交互
@export var interactive: bool = true

# 是否快捷栏槽位
# 仅影响配色：快捷栏格用金色边框，和普通背包格区分开（第一栏一眼可辨）
@export var accent: bool = false

# ============================================
# 私有变量
# ============================================

# 物品实例引用
var _item: ItemInstance

# UI节点引用
var _icon_rect: TextureRect
var _quantity_label: Label

# 是否正在被拖拽（本槽作为源）
var _is_dragging: bool = false

# 本次"按下 → 松手"之间有没有真的拖起来过。
# 为什么不能直接用 _is_dragging 判断：拖拽结束时引擎先发 NOTIFICATION_DRAG_END
# （那里会把 _is_dragging 清掉），之后若还收到鼠标松开事件，就分不清
# "点了一下"和"拖了一次又松手"。这个标志只在**下一次按下**时才复位，判定可靠。
var _press_dragged: bool = false

# 带修饰键按下时暂存的按键（-1 = 没有待判定事件）。
# 见 _gui_input 里的说明：Ctrl / Shift + 左键要等松手才能确定是"点击"还是"拖拽"。
var _pending_click_button: int = -1

# 是否被悬停
var _is_hovered: bool = false

# 是否被选中
var _is_selected: bool = false

# 是否正作为拖放目标（拖拽悬停在本槽上）
var _is_drop_target: bool = false

# 全局唯一的"当前拖放落点"槽位（静态变量，跨实例共享）
# 为什么需要它：Godot 在拖拽过程中不保证给"上一个被悬停的槽位"发 MOUSE_EXIT，
# 只靠 enter/exit 清理高亮会残留好几个绿框。改为：每次 _can_drop_data 被调用时，
# 由当前被悬停的槽位把自己注册成唯一落点，并主动清掉上一个的高亮。
static var _current_drop_target: ItemSlotUI = null

# 各种状态样式
var _normal_style: StyleBoxFlat
var _hovered_style: StyleBoxFlat
var _selected_style: StyleBoxFlat
var _drop_style: StyleBoxFlat

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 用 PASS 而不是默认值：PASS 时槽位既能收到 _gui_input / 拖放 / 悬停通知，
	# 又不会把事件"吃掉"，父级面板仍能兜底处理。
	# （注意 Control.mouse_filter 默认是 STOP，不是 IGNORE；显式写清避免误改。）
	mouse_filter = Control.MOUSE_FILTER_PASS
	_setup_ui()
	_setup_styles()

# ----------------------------------------
# 设置UI函数
# 创建子节点
# ----------------------------------------
func _setup_ui() -> void:
	# 设置最小尺寸（2026-09-24 缩小：64→52。背包/箱子面板会按自己的 slot_size 覆盖）
	custom_minimum_size = Vector2(52, 52)

	# 创建图标容器
	var margin = MarginContainer.new()
	margin.name = "MarginContainer"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 3)
	margin.add_theme_constant_override("margin_right", 3)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_bottom", 3)
	add_child(margin)

	# 创建图标
	_icon_rect = TextureRect.new()
	_icon_rect.name = "Icon"
	# 图标只是显示，不能拦鼠标，否则 _gui_input 收不到、拖拽起不来
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.texture = null
	margin.add_child(_icon_rect)

	# 创建数量标签
	_quantity_label = Label.new()
	_quantity_label.name = "Quantity"
	_quantity_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_quantity_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_quantity_label.add_theme_font_size_override("font_size", 12)
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
	# 快捷栏格用金色边框，普通背包格用灰色边框
	var normal_border: Color = Color(0.85, 0.7, 0.25) if accent else Color(0.4, 0.4, 0.4)

	# 普通样式
	_normal_style = StyleBoxFlat.new()
	_normal_style.bg_color = Color(0.2, 0.2, 0.2, 0.8)
	_normal_style.border_color = normal_border
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

	# 拖放目标样式（绿框，提示"放这里"）
	_drop_style = StyleBoxFlat.new()
	_drop_style.bg_color = Color(0.2, 0.35, 0.2, 0.9)
	_drop_style.border_color = Color(0.4, 1.0, 0.5)
	_drop_style.set_border_width_all(3)
	_drop_style.set_corner_radius_all(4)

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
# 根据状态更新边框颜色（优先级：选中 > 拖放目标 > 悬停 > 普通）
# ----------------------------------------
func _update_style() -> void:
	if _is_selected:
		add_theme_stylebox_override("panel", _selected_style)
	elif _is_drop_target:
		add_theme_stylebox_override("panel", _drop_style)
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
			_press_dragged = false
			# 先清掉上一次可能残留的待判定按键（比如上次拖拽取消、松手事件没送到本槽），
			# 否则这次松开时会把那个旧值当成"待判定"，凭空触发一次 clicked。
			_pending_click_button = -1
			# 带修饰键（Ctrl / Shift）时**不能**"按下就响应"：
			# 这两个键表示"少量搬运 / 快速搬运"，玩家很可能按着它顺手拖——
			# 若按下瞬间就把整堆搬走了，拖拽就没得拖（2026-09-23 前的实际冲突：
			# 箱子侧 Ctrl+左键按下即"取半"，玩家想 Ctrl 拖 1 个根本拖不动）。
			# 所以：有修饰键 → 先记下按键，等松手时若没发生过拖拽才发 clicked。
			if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_SHIFT):
				_pending_click_button = event.button_index
			else:
				clicked.emit(slot_index, event.button_index)
		else:
			if _pending_click_button >= 0 and not _press_dragged:
				clicked.emit(slot_index, _pending_click_button)
			_pending_click_button = -1

# ----------------------------------------
# 鼠标进入/离开、拖放结束检测
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

		# 拖放结束（含中途取消）：清掉落点高亮/拖拽标记，避免样式卡在"绿框"。
		# 无论成功放下还是拖到非法区域取消，所有槽位都会收到本通知。
		NOTIFICATION_DRAG_END:
			if _is_drop_target or _is_dragging:
				_clear_drop_state()

# ============================================
# 拖拽（Godot 原生 Drag & Drop）
# ============================================

# ----------------------------------------
# 开始拖拽：引擎在"按住左键并移动超过阈值"时调用
# 返回拖拽数据（null = 本槽不参与拖拽）
# ----------------------------------------
func _get_drag_data(_at_position: Vector2) -> Variant:
	if not interactive:
		return null
	if _item == null or _item.data == null or _item.is_empty():
		return null

	# 按住 Ctrl = 只搬 1 个（< 0 = 整堆）。
	# 数量随拖拽数据一起走，由落点那边决定搬几个——而不是"拖起来就整格搬走"。
	var count: int = 1 if Input.is_key_pressed(KEY_CTRL) else -1

	set_drag_preview(_build_drag_preview(count))
	_is_dragging = true
	_press_dragged = true
	drag_started.emit(slot_index)
	return {"from_slot": slot_index, "source": source_id, "count": count}

# ----------------------------------------
# 能否放下：鼠标拖到本槽上方时调用
# 空槽也接受（= 把物品挪过去）；同槽拒绝（无意义）
# 注意：跨面板时（箱子↔背包）两个槽位索引可能相同，
# 所以只有"同一来源面板 + 同一格"才拒绝
# ----------------------------------------
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not interactive:
		return false
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var dict: Dictionary = data
	if not dict.has("from_slot"):
		return false
	if String(dict.get("source", "")) == source_id and int(dict["from_slot"]) == slot_index:
		return false

	# 成为唯一落点：先把上一个落点的高亮清掉，避免残留多个绿框
	if _current_drop_target != null and _current_drop_target != self:
		if is_instance_valid(_current_drop_target):
			_current_drop_target._set_drop_highlight(false)
	_current_drop_target = self
	_set_drop_highlight(true)
	return true

# ----------------------------------------
# 放下：松开鼠标时由引擎在本槽调用
# 同来源面板 → 发 item_dropped（面板内整理，照旧）；
# 跨面板（如 箱子拖进背包）→ 发 cross_dropped，由接收方面板转调两个 Inventory
# ----------------------------------------
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var dict: Dictionary = data
	_clear_drop_state()
	if not dict.has("from_slot"):
		return
	var from_slot := int(dict["from_slot"])
	var src := String(dict.get("source", ""))
	var count: int = int(dict.get("count", -1))
	if src == source_id:
		item_dropped.emit(from_slot, slot_index, count)
	else:
		cross_dropped.emit(src, from_slot, slot_index, count)

# ----------------------------------------
# 设置落点高亮（供其它槽位跨实例调用）
# ----------------------------------------
func _set_drop_highlight(on: bool) -> void:
	if _is_drop_target == on:
		return
	_is_drop_target = on
	_update_style()

# ----------------------------------------
# 清空本槽的拖拽/落点状态
# ----------------------------------------
func _clear_drop_state() -> void:
	if _current_drop_target == self:
		_current_drop_target = null
	_is_dragging = false
	_set_drop_highlight(false)

# ----------------------------------------
# 构建拖拽预览
# 一个小方块：物品图标 + 数量，跟随鼠标（由引擎托管）
#
# 参数：count - < 0 = 整堆（显示物品总数量）；> 0 = 只搬这么多个（显示该数量 + 青色）
# 数量跟着鼠标显示，玩家一眼就知道"这一下会搬走几个"，不用去记修饰键的规则。
# ----------------------------------------
func _build_drag_preview(count: int = -1) -> Control:
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.15, 0.9)
	style.border_color = Color(0.8, 0.8, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	box.add_theme_stylebox_override("panel", style)
	box.custom_minimum_size = Vector2(40, 40)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var icon := TextureRect.new()
	icon.texture = _item.data.icon
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icon)

	var show_qty: int = count if count > 0 else _item.quantity
	if show_qty > 1:
		var qty := Label.new()
		qty.text = str(show_qty)
		qty.add_theme_font_size_override("font_size", 11)
		# 青色 = "只搬这么多"（Ctrl 拖拽），与整堆搬运的白色区分开
		qty.add_theme_color_override("font_color",
			Color(0.55, 0.95, 1.0) if count > 0 else Color.WHITE)
		qty.add_theme_color_override("font_outline_color", Color.BLACK)
		qty.add_theme_constant_override("outline_size", 2)
		qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		qty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(qty)

	return box
