# script/ui/storage_ui.gd
# ============================================
# 储物箱界面 - 大纲 3.5.2「储物箱：额外20格存储空间」
#
# 与背包 UI 保持一致的四个约定（照抄 inventory_ui.gd，不另起炉灶）：
#   1. 面板用「显式 anchor + 对称 offset」定位，不用 set_anchors_preset
#      —— 运行时 new() 出来的控件在 _ready 里调 set_anchors_preset 会算成 0×0
#   2. UI 层绝不直接改数据：拖放只发 item_dropped，由本类转调 Inventory.move_item
#   3. 每次显示时刷新（on_shown 钩子），因为 UIManager 只改 visible
#   4. 动态重建的按钮/槽位要清一次键盘焦点，否则按空格会被当成再点一次
#
# 为什么右键是"取回到背包"而不是"使用"：
#   箱子里放的是资源/材料，使用场景几乎一定是"我要把它拿出来用/拿去合成"。
#   右键直接取出一个，比拖到背包格子快得多。
#   （背包里的右键是"使用"，这里是"取出"——两套语义，靠面板区分，不冲突。）
# ============================================

class_name StorageUI
extends Control

signal closed()

## 每行格数
@export var columns: int = 9

## 当前打开的箱子背包（Building 的 storage 子节点）
var storage: Inventory = null
## 当前绑定的建筑节点本身（BuildPlacer 靠它判断"玩家是不是走远了"）。
## 只存 storage 的话拿不到世界坐标，没法算距离。
var bound_building: Node = null
## 玩家自己的背包，用于右键取回
var player_inventory: Inventory = null

var _grid: GridContainer
var _title: Label
var _slots: Array = []


# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	# 加入 storage_ui 组：背包 UI 拖物品进箱子时，通过组找到本面板拿 storage
	add_to_group("storage_ui")

	z_index = 200
	mouse_filter = Control.MOUSE_FILTER_STOP

	_setup_ui()
	visible = false
	_find_player_inventory()


func _setup_ui() -> void:
	# 居中定位：显式 anchor + 对称 offset。
	# 根节点【不要】调 set_anchors_preset——运行时 new() 出来的控件在 _ready 里
	# 调它会按当前尺寸（0×0）算 offset，面板会塌成一个点。
	# 这一条在 inventory_ui / crafting_ui 上都踩过，别再犯。
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -320
	offset_top = -190
	offset_right = 320
	offset_bottom = 190

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# ---- 标题行 ----
	var header := HBoxContainer.new()
	vbox.add_child(header)

	_title = Label.new()
	_title.text = "储物箱"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)

	var close_btn := Button.new()
	close_btn.text = "关闭 (Esc)"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(_on_close_pressed)
	header.add_child(close_btn)

	vbox.add_child(HSeparator.new())

	# ---- 箱子格位 ----
	_grid = GridContainer.new()
	_grid.columns = columns
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(_grid)

	vbox.add_child(HSeparator.new())

	var hint := Label.new()
	hint.text = "拖拽整理/存取 · Shift+左键全取 · Ctrl+左键取半 · 右键取1"
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(hint)


func _find_player_inventory() -> void:
	if player_inventory != null and is_instance_valid(player_inventory):
		return
	var players := get_tree().get_nodes_in_group("player")
	for p in players:
		var inv := p.get_node_or_null("Inventory")
		if inv != null:
			player_inventory = inv
			return


# ============================================
# 公共方法
# ============================================

## 由 BuildPlacer 在打开面板后调用，绑定当前点击的箱子
func bind_storage(building: Node) -> void:
	_disconnect_storage()

	storage = null
	bound_building = null
	if building != null and building.has_method("has_storage"):
		if building.call("has_storage"):
			storage = building.get("storage")
			bound_building = building

	if storage != null and storage.has_signal("item_changed"):
		storage.item_changed.connect(_on_storage_changed)

	refresh()


## UIManager 的通用钩子：每次显示时补绑 + 刷新
func on_shown() -> void:
	_find_player_inventory()
	refresh()
	UIManager.disable_keyboard_focus(self)


func refresh() -> void:
	# 箱子已被拆掉（或被别的脚本释放）→ 直接关掉面板，别留个空壳
	if storage != null and not is_instance_valid(storage):
		storage = null
		bound_building = null
		close()
		return
	_rebuild_slots()
	UIManager.disable_keyboard_focus(self)


func open() -> void:
	visible = true
	refresh()


func close() -> void:
	visible = false
	# 关掉就解绑：免得 BuildPlacer 拿着一个已经拆掉的建筑算距离
	bound_building = null
	closed.emit()


# ============================================
# 格位
# ============================================

func _rebuild_slots() -> void:
	_clear_slots()
	if storage == null or not is_instance_valid(storage):
		return

	for i in range(storage.max_slots):
		var slot_ui := ItemSlotUI.new()
		slot_ui.slot_index = i
		slot_ui.custom_minimum_size = Vector2(64, 64)
		# 拖拽数据带上来源标识，背包 UI 靠它区分箱子拖来的物品
		slot_ui.source_id = "storage"
		slot_ui.clicked.connect(_on_slot_clicked)
		slot_ui.item_dropped.connect(_on_slot_item_dropped)
		slot_ui.cross_dropped.connect(_on_cross_dropped)
		_grid.add_child(slot_ui)
		_slots.append(slot_ui)

		if i < storage.get_slot_count():
			slot_ui.set_item(storage.get_item(i))


func _clear_slots() -> void:
	for s in _slots:
		if is_instance_valid(s):
			if s.get_parent() != null:
				s.get_parent().remove_child(s)
			s.queue_free()
	_slots.clear()


# ============================================
# 交互
# ============================================

func _on_slot_clicked(slot_index: int, button: int) -> void:
	match button:
		MOUSE_BUTTON_RIGHT:
			# 右键：取 1 个进背包
			_transfer_to_player(slot_index, 1)
		MOUSE_BUTTON_LEFT:
			# 普通左键留给拖拽（ItemSlotUI 原生 DnD）；带修饰键才是快捷取物
			if Input.is_key_pressed(KEY_CTRL):
				_transfer_to_player(slot_index, _half_count(slot_index))
			elif Input.is_key_pressed(KEY_SHIFT):
				_transfer_to_player(slot_index, -1)


## "拿一半"的数量：向上取整——1 个拿 1 个，51 个拿 26 个
func _half_count(slot_index: int) -> int:
	var item = storage.get_item(slot_index)
	if item == null or item.is_empty():
		return 0
	return maxi(1, int(ceil(item.quantity / 2.0)))


## 从箱子往玩家背包转 count 个（count < 0 = 整堆）。
## 右键取1 / Ctrl取半 / Shift全取 / 拖拽整堆，全部走这里。
func _transfer_to_player(slot_index: int, count: int) -> void:
	if storage == null or player_inventory == null:
		_find_player_inventory()
	if storage == null or player_inventory == null:
		return
	if slot_index < 0 or slot_index >= storage.get_slot_count():
		return

	var item = storage.get_item(slot_index)
	if item == null or item.data == null or item.is_empty():
		return

	var take: int = item.quantity if count < 0 else mini(count, item.quantity)
	if take <= 0:
		return

	# 先试着加进玩家背包，按实际加载数量从箱子扣——背包满时不会吞物品
	var added: int = player_inventory.add_item(item.data, take)
	if added <= 0:
		return

	# 从玩家点的那一格扣，而不是按 id 扣：
	# remove_item(id) 会挑第一个匹配的槽位，玩家会觉得"我点的明明是这格"
	item.remove(added)
	if item.is_empty():
		storage.clear_slot(slot_index)
	else:
		storage.set_slot(slot_index, item)
	refresh()


## 背包拖进箱子：整堆/合并/交换，数据统一走 Inventory.move_between
func _on_cross_dropped(source: String, from_slot: int, to_slot: int) -> void:
	if source != "player":
		return
	if player_inventory == null:
		_find_player_inventory()
	if player_inventory == null or storage == null:
		return
	Inventory.move_between(player_inventory, from_slot, storage, to_slot)
	refresh()


## 箱内拖放：只发信号，数据改动交给 Inventory.move_item
func _on_slot_item_dropped(from_slot: int, to_slot: int) -> void:
	if storage == null or from_slot == to_slot:
		return
	storage.move_item(from_slot, to_slot)
	refresh()


func _on_storage_changed(_slot: int) -> void:
	if visible:
		refresh()


func _on_close_pressed() -> void:
	UIManager.close_panel(UIManager.STORAGE_PANEL)


func _disconnect_storage() -> void:
	if storage != null and is_instance_valid(storage):
		if storage.has_signal("item_changed") and storage.item_changed.is_connected(_on_storage_changed):
			storage.item_changed.disconnect(_on_storage_changed)
