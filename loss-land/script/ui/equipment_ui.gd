# script/ui/equipment_ui.gd
# ============================================
# 装备UI - 按大纲 3.4 实装的装备系统配套的界面
#
# 布局：
#   标题 + 关闭按钮
#   属性总览：攻击力 / 防御 / 采集加速（按工具类型分列）
#   三个已装备槽位：武器 / 护甲 / 工具（有装备显示图标+名称，点击卸下）
#   外加核心槽：动力核心 / 机械核心的装入与拆除入口
#   背包可装备列表：当前背包里所有可装备物品，点击装备
#
# 与合成 UI / 背包 UI 保持一致的三个约定：
#   1. 面板用「显式 anchor + 绝对 offset」定位，不用 set_anchors_preset
#      —— 本面板的 anchor 是**全 1.0**（右、下贴视口边缘），见 RECT_EQUIPMENT 注释
#   2. 背包 / 装备组件都按 "player" 组查找，不依赖绝对路径
#   3. z_index 抬高 + 根节点 MOUSE_FILTER_STOP，避免被 HUD 盖住、点击穿透到 3D
#
# 位置（2026-09-24 二次改版）：右列底部 420×340（1280×720 视口下 x 850..1270、y 370..710）。
#   四个装备槽**均分内容宽**（不再写死 110px）：面板缩到 420 后，4×110 会溢出。
#
# 刷新时机：
#   装备组件的 equipment_changed + 背包信号 + 面板每次变为可见时。
# ============================================

class_name EquipmentUI
extends Control

signal closed()

## 设计视口尺寸（九宫格坐标都按它写）
const DESIGN_SIZE := Vector2(1280.0, 720.0)

## 面板区域（1280×720 设计空间）：右列底部。
## ⚠ **右、下两侧锚在视口边缘**（anchor 全 1.0 + 负 offset ⇒ 1280×720 视口下
## 正好落在 x 850..1270、y 380..710）。之所以贴边而不写死绝对坐标：
## 界面缩放（GraphicsConfig.ui_scale → content_scale_factor）>1 时，
## canvas_items + expand 会把逻辑视口缩小（1.05 ⇒ 1219×686），
## 此时绝对坐标会被裁到屏幕外，贴边锚定则会跟着往里收。
## 2026-09-24 二次改版：476×426 → 420×340（原尺寸在界面缩放 105% 下右/下都被裁）。
const RECT_EQUIPMENT := Rect2(850, 370, 420, 340)

# ============================================
# 变量
# ============================================

## 关联的玩家背包；赋值时自动（重）连信号
var inventory: Inventory:
	set(value):
		if Engine.is_editor_hint():
			inventory = value
			return
		if inventory:
			_disconnect_inventory_signals()
		inventory = value
		if inventory:
			_connect_inventory_signals()

## 关联的玩家装备组件（PlayerEquipment）；赋值时自动（重）连信号
var equipment: PlayerEquipment:
	set(value):
		if Engine.is_editor_hint():
			equipment = value
			return
		if equipment:
			if equipment.equipment_changed.is_connected(_on_equipment_changed):
				equipment.equipment_changed.disconnect(_on_equipment_changed)
		equipment = value
		if equipment:
			if not equipment.equipment_changed.is_connected(_on_equipment_changed):
				equipment.equipment_changed.connect(_on_equipment_changed)

## 四个槽位枚举
## 核心槽不提供数值加成，但它要出现在这里：装备界面是玩家"装入 / 拆除核心"
## 的唯一入口（点击槽位 = 卸下），漏掉它就只能装、不能拆。
const _SLOTS: Array[int] = [
	ItemData.EquipSlot.WEAPON,
	ItemData.EquipSlot.ARMOR,
	ItemData.EquipSlot.TOOL,
	ItemData.EquipSlot.CORE,
]

# --- UI 节点 ---
var _stat_label: Label
var _slot_boxes: Dictionary = {}        # EquipSlot -> 槽位容器（含图标/名称）
var _slot_icon: Dictionary = {}         # EquipSlot -> TextureRect
var _slot_name: Dictionary = {}         # EquipSlot -> Label
var _equip_list: VBoxContainer

const COLOR_OK := Color(0.45, 0.95, 0.45)
const COLOR_DIM := Color(0.75, 0.75, 0.75)
const COLOR_HEAD := Color(1.0, 0.85, 0.45)


# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	add_to_group("equipment_ui")
	z_index = 200
	mouse_filter = Control.MOUSE_FILTER_STOP

	_setup_ui()
	visible = false

	visibility_changed.connect(_on_visibility_changed)

	_find_player_nodes()
	_refresh_all()


func _on_visibility_changed() -> void:
	if visible:
		_refresh_all()


# ============================================
# 公共方法
# ============================================

func open() -> void:
	visible = true
	_refresh_all()


func close() -> void:
	visible = false
	closed.emit()


func refresh() -> void:
	_refresh_all()
	# 重建出来的按钮默认会抢键盘焦点，点过之后按空格会被当成"再点一次"
	UIManager.disable_keyboard_focus(self)


# ============================================
# UI 构建
# ============================================

func _setup_ui() -> void:
	# 九宫格右列底部：**右、下贴视口边缘**（anchor 全 1.0 + 负 offset）。
	# 用显式 anchor 数字而不是 set_anchors_preset —— 运行时 new() 的控件
	# 在 _ready 里调它会按当前尺寸（0×0）重算 offset。
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = RECT_EQUIPMENT.position.x - DESIGN_SIZE.x
	offset_top = RECT_EQUIPMENT.position.y - DESIGN_SIZE.y
	offset_right = RECT_EQUIPMENT.end.x - DESIGN_SIZE.x
	offset_bottom = RECT_EQUIPMENT.end.y - DESIGN_SIZE.y

	var background := PanelContainer.new()
	background.name = "Background"
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.add_theme_constant_override("separation", 4)
	background.add_child(root_vbox)

	# --- 标题行 ---
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	var title := Label.new()
	title.text = "装备"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "关闭 (B)"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	title_row.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# --- 属性总览 ---
	var stat_frame := PanelContainer.new()
	stat_frame.add_theme_stylebox_override("panel", _make_dark_style())
	root_vbox.add_child(stat_frame)

	_stat_label = Label.new()
	_stat_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stat_label.custom_minimum_size = Vector2(240, 40)
	stat_frame.add_child(_stat_label)

	# --- 已装备槽位（四个横排，均分内容宽 → 面板 420 下每格约 94）---
	var slot_title := Label.new()
	slot_title.text = "已装备（点击卸下）"
	slot_title.modulate = COLOR_HEAD
	root_vbox.add_child(slot_title)

	var slot_row := HBoxContainer.new()
	slot_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(slot_row)
	_build_slots(slot_row)

	root_vbox.add_child(HSeparator.new())

	# --- 背包可装备列表 ---
	var list_title := Label.new()
	list_title.text = "背包中的装备（点击装备）"
	list_title.modulate = COLOR_HEAD
	root_vbox.add_child(list_title)

	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(0, 60)
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(list_scroll)

	_equip_list = VBoxContainer.new()
	_equip_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_equip_list.add_theme_constant_override("separation", 2)
	list_scroll.add_child(_equip_list)


## 创建深色面板样式（避免默认主题看不清）
func _make_dark_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.16, 0.18, 0.22, 0.9)
	s.set_corner_radius_all(4)
	return s


## 构建装备槽位（武器/护甲/工具/核心）
## 四个横排**均分面板内容宽**（`SIZE_EXPAND_FILL`，不写死宽度）——
## 面板宽 420、内容宽约 396 ⇒ 每格 ≈ 94px（icon 24 + 名字）。
## 以前写死 110 是因为面板固定 476；现在面板要随视口收窄，硬编码会溢出。
func _build_slots(container: Node) -> void:
	for slot in _SLOTS:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 1)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.add_child(box)

		var head := Label.new()
		head.text = _slot_label_text(slot)
		head.modulate = COLOR_DIM
		head.add_theme_font_size_override("font_size", 12)
		box.add_child(head)

		var hbox := HBoxContainer.new()
		box.add_child(hbox)

		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(24, 24)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(icon)

		var name := Label.new()
		name.text = "（空）"
		name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name.add_theme_font_size_override("font_size", 12)
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(name)

		# 整块槽位可点击卸下
		var click := Button.new()
		click.text = ""
		click.flat = true
		click.mouse_filter = Control.MOUSE_FILTER_STOP
		click.focus_mode = Control.FOCUS_NONE
		click.custom_minimum_size = Vector2(0, 34)
		click.pressed.connect(func() -> void: _on_slot_clicked(slot))
		box.add_child(click)

		_slot_boxes[slot] = box
		_slot_icon[slot] = icon
		_slot_name[slot] = name


## 槽位标签文字（武器/护甲/工具/核心）
func _slot_label_text(slot: int) -> String:
	match slot:
		ItemData.EquipSlot.WEAPON: return "武器"
		ItemData.EquipSlot.ARMOR:  return "护甲"
		ItemData.EquipSlot.TOOL:   return "工具"
		ItemData.EquipSlot.CORE:   return "核心"
		_: return "?"


# ============================================
# 刷新
# ============================================

func _refresh_all() -> void:
	if not is_instance_valid(_stat_label):
		return
	_refresh_stats()
	_refresh_slots()
	_refresh_equip_list()


## 属性总览：攻击 / 防御
func _refresh_stats() -> void:
	var atk := 0
	var def := 0
	if equipment != null:
		atk = equipment.get_attack_bonus()
		def = equipment.get_defense_bonus()

	var lines := PackedStringArray()
	lines.append("攻击力  +%d" % atk)
	lines.append("防御力  +%d" % def)
	_stat_label.text = "\n".join(lines)


## 已装备槽位显示
func _refresh_slots() -> void:
	for slot in _SLOTS:
		var icon: TextureRect = _slot_icon.get(slot, null)
		var name: Label = _slot_name.get(slot, null)
		if icon == null or name == null:
			continue
		var item: ItemData = equipment.get_item(slot) if equipment != null else null
		if item != null:
			icon.texture = item.icon
			name.text = item.display_name
			name.modulate = COLOR_OK
		else:
			icon.texture = null
			name.text = "（空）"
			name.modulate = COLOR_DIM


## 背包可装备列表（去重：同一物品只显示一行，显示总持有数量）
func _refresh_equip_list() -> void:
	_clear_container(_equip_list)
	if inventory == null:
		var empty := Label.new()
		empty.text = "（无背包）"
		empty.modulate = COLOR_DIM
		_equip_list.add_child(empty)
		return

	# 收集背包里所有可装备的物品
	var seen: Dictionary = {}   # item_id -> ItemData
	for it in inventory.get_all_items():
		if it == null or it.data == null:
			continue
		if it.data.is_equippable():
			seen[it.data.item_id] = it.data

	if seen.is_empty():
		var empty := Label.new()
		empty.text = "（背包里没有可装备的物品）"
		empty.modulate = COLOR_DIM
		_equip_list.add_child(empty)
		return

	for item_id in seen.keys():
		var data: ItemData = seen[item_id]
		var have := inventory.get_item_count(item_id)
		var equipped := equipment != null and equipment.has_equipped(item_id)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 34)
		btn.text = "%s  x%d%s" % [data.display_name, have, "  （已装备）" if equipped else ""]
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.modulate = COLOR_OK if equipped else Color.WHITE
		btn.pressed.connect(func() -> void: _on_equip_clicked(item_id))
		_equip_list.add_child(btn)


# ============================================
# 交互
# ============================================

## 点击已装备槽位 → 卸下
func _on_slot_clicked(slot: int) -> void:
	if equipment == null:
		return
	if equipment.get_item(slot) == null:
		return
	var ok := equipment.unequip(slot)
	if not ok:
		_status_flash("背包已满，无法卸下")
	# equipment_changed 会触发 _refresh_all


## 点击背包装备项 → 装备
func _on_equip_clicked(item_id: StringName) -> void:
	if equipment == null or inventory == null:
		return
	var ok := equipment.equip(item_id)
	if not ok:
		_status_flash("无法装备（背包中没有 / 不可装备）")
	# equipment_changed 会触发 _refresh_all


# ============================================
# 信号
# ============================================

func _on_equipment_changed() -> void:
	_refresh_all()


# ============================================
# 工具
# ============================================

func _clear_container(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _status_flash(_msg: String) -> void:
	# 装备失败信息短暂提示：重刷列表即可，错误已在装备组件里 push_warning
	_refresh_all()


# ============================================
# 节点查找
# ============================================

func _connect_inventory_signals() -> void:
	inventory.item_added.connect(_on_inventory_changed)
	inventory.item_removed.connect(_on_inventory_changed)
	inventory.item_changed.connect(_on_inventory_changed)
	inventory.inventory_cleared.connect(_on_inventory_changed)


func _disconnect_inventory_signals() -> void:
	if inventory == null:
		return
	if inventory.item_added.is_connected(_on_inventory_changed):
		inventory.item_added.disconnect(_on_inventory_changed)
	if inventory.item_removed.is_connected(_on_inventory_changed):
		inventory.item_removed.disconnect(_on_inventory_changed)
	if inventory.item_changed.is_connected(_on_inventory_changed):
		inventory.item_changed.disconnect(_on_inventory_changed)
	if inventory.inventory_cleared.is_connected(_on_inventory_changed):
		inventory.inventory_cleared.disconnect(_on_inventory_changed)


func _on_inventory_changed(_a = null, _b = null, _c = null) -> void:
	_refresh_equip_list()


## 按 player 组查找玩家的 Inventory 与 Equipment（与背包/合成 UI 同一套逻辑）
func _find_player_nodes() -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		player = get_tree().get_root().find_child("player", true, false)

	if player == null:
		return

	if player.has_node("Inventory"):
		inventory = player.get_node("Inventory")
	if player.has_node("Equipment"):
		equipment = player.get_node("Equipment")
