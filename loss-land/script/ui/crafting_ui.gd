# script/ui/crafting_ui.gd
# ============================================
# 合成UI - 按大纲 3.4 的合成界面
#
# 布局：
#   标题 + 关闭按钮
#   分类标签：全部 / 材料 / 工具 / 武器 / 护甲 / 建筑
#   左侧：当前分类的配方列表（绿色=材料够，红色=材料不足）
#   右侧：选中配方的详情（图标、名称、说明、材料清单 拥有/需求）+ 合成按钮
#
# 与背包 UI 保持一致的三个约定：
#   1. 面板用「显式 anchor + 对称 offset」定位，不用 set_anchors_preset
#      —— 运行时 new() 出来的控件在 _ready 里调 set_anchors_preset 会算成 0×0
#      （这个坑在暂停/设置面板上已经踩过一次）
#   2. 背包按 "player" 组查找，不依赖绝对路径
#   3. z_index 抬高 + 根节点 MOUSE_FILTER_STOP，避免被 HUD 盖住、点击穿透到 3D
#
# 刷新时机：
#   背包信号（增删改清）+ 面板每次变为可见时（由 UIManager 设 visible 触发）。
# ============================================

class_name CraftingUI
extends Control

signal closed()

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

## 当前分类（-1 = 全部）
var _category: int = -1

## 当前分类下可见的配方
var _visible_recipes: Array[CraftingRecipe] = []
## 与 _visible_recipes 一一对应的列表按钮
var _recipe_buttons: Array[Button] = []

## 当前选中的配方
var _selected: CraftingRecipe = null

# --- UI 节点 ---
var _recipe_list: VBoxContainer
var _detail_icon: TextureRect
var _detail_name: Label
var _detail_desc: Label
var _detail_notes: Label
var _material_list: VBoxContainer
var _craft_button: Button
var _status_label: Label
var _tab_bar: HBoxContainer
## 标题标签（会带上当前角色名与专属栏名）
var _title_label: Label
## 标签页是按哪个角色建的；与当前角色不一致时重建（换档等场景）
var _tabs_char_id: String = ""

# 颜色：材料足够用绿色，不足用红色
const COLOR_OK := Color(0.45, 0.95, 0.45)
const COLOR_BAD := Color(0.95, 0.42, 0.42)
const COLOR_DIM := Color(0.75, 0.75, 0.75)


# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	add_to_group("crafting_ui")
	z_index = 200
	mouse_filter = Control.MOUSE_FILTER_STOP

	_setup_ui()
	visible = false

	# 每次被打开都刷新一次（UIManager 只改 visible，不会调别的方法）
	visibility_changed.connect(_on_visibility_changed)

	_find_player_inventory()
	_build_recipe_list()
	_select_recipe(_visible_recipes[0] if not _visible_recipes.is_empty() else null)


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
	# 居中面板：显式锚点 + 对称偏移（不用 set_anchors_preset）
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -330
	offset_top = -230
	offset_right = 330
	offset_bottom = 230

	var background := PanelContainer.new()
	background.name = "Background"
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.add_theme_constant_override("separation", 6)
	background.add_child(root_vbox)

	# --- 标题行 ---
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	var title := Label.new()
	title.text = "合成"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label = title
	title_row.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "关闭 (C)"
	close_btn.pressed.connect(close)
	title_row.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# --- 分类标签 ---
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	root_vbox.add_child(_tab_bar)
	_build_tabs()

	# --- 主体：左列表 / 右详情 ---
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	root_vbox.add_child(body)

	# 左：配方列表（可滚动）
	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(250, 260)
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(list_scroll)

	_recipe_list = VBoxContainer.new()
	_recipe_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_recipe_list)

	body.add_child(VSeparator.new())

	# 右：详情
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 6)
	body.add_child(detail)

	var detail_head := HBoxContainer.new()
	detail.add_child(detail_head)

	_detail_icon = TextureRect.new()
	_detail_icon.custom_minimum_size = Vector2(48, 48)
	_detail_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	detail_head.add_child(_detail_icon)

	_detail_name = Label.new()
	_detail_name.add_theme_font_size_override("font_size", 17)
	_detail_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_head.add_child(_detail_name)

	_detail_desc = Label.new()
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_desc.custom_minimum_size = Vector2(300, 60)
	_detail_desc.modulate = COLOR_DIM
	detail.add_child(_detail_desc)

	_detail_notes = Label.new()
	_detail_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_notes.custom_minimum_size = Vector2(300, 0)
	_detail_notes.modulate = Color(1.0, 0.85, 0.45)
	detail.add_child(_detail_notes)

	detail.add_child(HSeparator.new())

	var mat_title := Label.new()
	mat_title.text = "所需材料"
	detail.add_child(mat_title)

	_material_list = VBoxContainer.new()
	_material_list.add_theme_constant_override("separation", 2)
	detail.add_child(_material_list)

	# --- 合成按钮 + 状态 ---
	_craft_button = Button.new()
	_craft_button.text = "合成"
	_craft_button.custom_minimum_size = Vector2(0, 40)
	_craft_button.pressed.connect(_on_craft_pressed)
	root_vbox.add_child(_craft_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 24)
	root_vbox.add_child(_status_label)


## 清空容器：必须 remove_child 而不只是 queue_free
## queue_free 是延迟到帧末才生效的，若只调它，
## 紧接着 add_child 会让容器里同时存在"待删的旧节点 + 新节点"，
## 于是 get_child_count() 读到旧数据、界面出现重复条目。
func _clear_container(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


## 构建分类标签：全部 + 通用栏 + **当前角色的专属栏**。
## 标签列表来自 CraftingSystem.get_visible_categories()，
## 所以加分类 / 加角色都不用改这里（大纲 2.2.5：专属制作栏按角色切换）。
func _build_tabs() -> void:
	_clear_container(_tab_bar)

	var visible := CraftingSystem.get_visible_categories()
	# 当前分类若因换角色而不可见（例如从机器人切回冒险家），退回"全部"
	if _category != -1 and not visible.has(_category):
		_category = -1

	_add_tab("全部", -1)
	for cat in visible:
		_add_tab(CraftingRecipe.category_name(int(cat)), int(cat))


func _add_tab(text: String, category_value: int) -> void:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.button_pressed = (category_value == _category)
	btn.pressed.connect(func() -> void: _on_tab_pressed(category_value))
	_tab_bar.add_child(btn)


func _on_tab_pressed(category_value: int) -> void:
	_category = category_value
	_build_tabs()
	_build_recipe_list()
	_select_recipe(_visible_recipes[0] if not _visible_recipes.is_empty() else null)


# ============================================
# 配方列表
# ============================================

## 按当前分类重建左侧列表
func _build_recipe_list() -> void:
	_clear_container(_recipe_list)
	_visible_recipes.clear()
	_recipe_buttons.clear()

	if _category == -1:
		_visible_recipes = CraftingSystem.get_all_recipes()
	else:
		_visible_recipes = CraftingSystem.get_recipes(_category)

	var registry := ItemRegistry.get_registry()
	for recipe in _visible_recipes:
		var out: ItemData = registry.get_item(recipe.output_item_id) if registry else null
		var out_name: String = out.display_name if out else str(recipe.output_item_id)

		var btn := Button.new()
		btn.text = "%s x%d" % [out_name, recipe.output_count]
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.custom_minimum_size = Vector2(0, 38)
		btn.pressed.connect(func() -> void: _select_recipe(recipe))
		_recipe_list.add_child(btn)
		_recipe_buttons.append(btn)

	_refresh_recipe_colors()


## 刷新列表配色：材料够=绿，不够=红
func _refresh_recipe_colors() -> void:
	for i in range(_visible_recipes.size()):
		var ok := CraftingSystem.can_craft(_visible_recipes[i], inventory)
		_recipe_buttons[i].modulate = COLOR_OK if ok else COLOR_BAD


# ============================================
# 详情
# ============================================

func _select_recipe(recipe: CraftingRecipe) -> void:
	_selected = recipe
	_refresh_detail()


func _refresh_detail() -> void:
	if _selected == null or not is_instance_valid(_detail_name):
		return

	var registry := ItemRegistry.get_registry()
	var out: ItemData = registry.get_item(_selected.output_item_id) if registry else null

	_detail_name.text = ("%s x%d" % [out.display_name, _selected.output_count]) if out \
		else "%s x%d" % [_selected.output_item_id, _selected.output_count]
	_detail_icon.texture = out.icon if out else null
	_detail_desc.text = out.description if out else ""
	_detail_notes.text = _selected.notes
	_detail_notes.visible = not _selected.notes.is_empty()

	# 材料清单
	_clear_container(_material_list)

	var status := CraftingSystem.get_material_status(_selected, inventory)
	for s in status:
		var mid := StringName(s.get("item_id", &""))
		var need := int(s.get("need", 0))
		var have := int(s.get("have", 0))
		var ok := bool(s.get("ok", false))
		var mdata: ItemData = registry.get_item(mid) if registry else null
		var mname: String = mdata.display_name if mdata else str(mid)

		var line := Label.new()
		line.text = "  %s  %d / %d" % [mname, have, need]
		line.modulate = COLOR_OK if ok else COLOR_BAD
		_material_list.add_child(line)

	# 制作站是"材料够不够"之外的另一道门槛，两者提示要分开，
	# 否则玩家材料齐全却点不动会以为是 bug。
	var missing_station := CraftingSystem.get_missing_station(_selected)
	var can := CraftingSystem.can_craft(_selected, inventory)
	_craft_button.disabled = not can
	if missing_station != &"":
		_craft_button.text = "需要%s" % BuildingSystem.get_display_name(missing_station)
	elif can:
		_craft_button.text = "合成"
	else:
		_craft_button.text = "材料不足"


# ============================================
# 合成
# ============================================

func _on_craft_pressed() -> void:
	if _selected == null or inventory == null:
		return

	var made: int = CraftingSystem.craft(_selected, inventory)
	if made > 0:
		var registry := ItemRegistry.get_registry()
		var out: ItemData = registry.get_item(_selected.output_item_id) if registry else null
		var name_: String = out.display_name if out else str(_selected.output_item_id)
		_status_label.modulate = COLOR_OK
		_status_label.text = "合成成功：%s x%d" % [name_, made]
		DebugConfig.log_msg(DebugConfig.CAT_CRAFTING, "[合成] %s x%d", [name_, made])
	else:
		# craft 返回 0 只有两种可能：材料不够，或产物放不进背包（已自动退回材料）
		if CraftingSystem.can_craft(_selected, inventory):
			_status_label.text = "背包没有空位，材料已退回"
		else:
			_status_label.text = "材料不足"
		_status_label.modulate = COLOR_BAD

	_refresh_all()


# ============================================
# 刷新
# ============================================

func _refresh_all() -> void:
	if not is_instance_valid(_recipe_list):
		return

	# 角色换了（读别的档 / 以后装入动力核心）→ 专属栏标签与配方表都要重建。
	# 平时只刷配色和详情，避免每次背包变动都重建按钮（重建会抢键盘焦点）。
	var cid := CharacterRegistry.get_active_id()
	if cid != _tabs_char_id:
		_tabs_char_id = cid
		_category = -1
		_update_title()
		_build_tabs()
		_build_recipe_list()
		_select_recipe(_visible_recipes[0] if not _visible_recipes.is_empty() else null)
		return

	_refresh_recipe_colors()
	_refresh_detail()


## 标题带上当前角色与他的专属栏，一眼看出"这一栏是谁的"
func _update_title() -> void:
	if not is_instance_valid(_title_label):
		return
	var cid := CharacterRegistry.get_active_id()
	var label := CharacterRegistry.get_craft_category_label(cid)
	if label.is_empty():
		_title_label.text = "合成"
	else:
		var who := String(CharacterRegistry.get_character(cid).get("name", "?"))
		_title_label.text = "合成 · %s（%s）" % [who, label]


# ============================================
# 背包绑定
# ============================================

func _connect_inventory_signals() -> void:
	inventory.item_added.connect(_on_inventory_changed)
	inventory.item_removed.connect(_on_inventory_item_removed)
	inventory.item_changed.connect(_on_inventory_slot_changed)
	inventory.inventory_cleared.connect(_on_inventory_changed)


func _disconnect_inventory_signals() -> void:
	if inventory == null:
		return
	if inventory.item_added.is_connected(_on_inventory_changed):
		inventory.item_added.disconnect(_on_inventory_changed)
	if inventory.item_removed.is_connected(_on_inventory_item_removed):
		inventory.item_removed.disconnect(_on_inventory_item_removed)
	if inventory.item_changed.is_connected(_on_inventory_slot_changed):
		inventory.item_changed.disconnect(_on_inventory_slot_changed)
	if inventory.inventory_cleared.is_connected(_on_inventory_changed):
		inventory.inventory_cleared.disconnect(_on_inventory_changed)


func _on_inventory_changed(_a = null, _b = null) -> void:
	_refresh_all()


func _on_inventory_item_removed(_item_id: StringName, _count: int, _slot: int) -> void:
	_refresh_all()


func _on_inventory_slot_changed(_slot: int) -> void:
	_refresh_all()


## 按 player 组查找玩家的 Inventory（与背包 UI 同一套逻辑）
func _find_player_inventory() -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player and player.has_node("Inventory"):
		inventory = player.get_node("Inventory")
		return

	var player_node := get_tree().get_root().find_child("player", true, false)
	if player_node and player_node.has_node("Inventory"):
		inventory = player_node.get_node("Inventory")
		return

	var inventory_node := get_tree().get_root().find_child("Inventory", true, false)
	if inventory_node:
		inventory = inventory_node
