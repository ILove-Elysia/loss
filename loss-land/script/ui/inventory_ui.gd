# script/ui/inventory_ui.gd
# ============================================
# 背包UI - 显示整个背包界面
#
# 功能：
# 1. 第一栏固定为「快捷栏」（= 背包前 hotbar_slots 格，与屏幕底部快捷栏同一批槽位）
# 2. 下面才是普通背包格
# 3. 左键拖拽物品到其它格 → 移动/交换位置/同类堆叠
# 4. 右键使用可用物品（电池→电量 等）
# 5. 悬停显示物品提示框
#
# 布局约定（关键）：
#   快捷栏（屏幕底部 HUD，hud_ui.gd）镜像的是**背包的前 9 个槽位**（索引 0-8）。
#   所以"背包第一栏就是快捷栏"在数据上本来就成立——本界面只是把 0..hotbar_slots-1
#   单独排成一行、用金色边框标出来，让玩家一眼看出"这排就是快捷栏"。
#   在背包里拖动物品进出这 9 格，就等于在调整快捷栏内容。
#
# 分层约定：
#   UI 层不发号施令改数据：拖放只发 item_dropped(from, to)，
#   由本脚本调用 Inventory.move_item()；背包再通过信号回刷 UI。
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

# 快捷栏格数（背包第一栏的格数）
# 必须与 HUD 快捷栏（hud_ui.gd 的 hotbar_slots）一致，否则两边对不上
@export var hotbar_slots: int = 9

# 普通背包区每行格数
@export var columns: int = 9

# 槽位间距
@export var slot_spacing: int = 4

# ============================================
# 私有变量
# ============================================

# 槽位UI数组（下标 = 背包槽位索引）
var _slot_uis: Array[ItemSlotUI] = []

# 快捷栏行的容器（背包 0 .. hotbar_slots-1）
var _hotbar_grid: GridContainer

# 普通背包区的容器（背包 hotbar_slots .. max_slots-1）
var _grid_container: GridContainer

# 物品提示框
var _tooltip: ItemTooltip

# 当前悬停的槽位
var _hovered_slot: int = -1

# 当前选中的槽位
var _selected_slot: int = -1

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 注册到 inventory_ui 组，供 HUD 按组查找（不再依赖绝对路径）
	add_to_group("inventory_ui")

	# 盖住 HUD。本节点在场景树中先于 HUDUI 添加，且 HUD 各容器 z_index=100，
	# 不显式抬高的话背包会被压在下面，快捷栏会浮在背包界面之上。
	z_index = 200

	# 根节点收下鼠标，否则点背包空白处会穿透到 3D 世界让角色乱跑。
	# visible=false 时 Control 不接收输入，不影响正常游玩。
	mouse_filter = Control.MOUSE_FILTER_STOP

	_setup_ui()
	_setup_tooltip()

	# 默认隐藏
	visible = false

	# 动态查找玩家的背包
	_find_player_inventory()

# 注意：这里**故意不**自己监听 Esc。
# 原先本类自己处理 ui_cancel 并 set_input_as_handled()，会让 UIManager 收不到 Esc，
# 于是 _stack 里仍留着 "inventory"，表现为"按 Esc 关掉背包后，Tab 再也打不开"。
# Esc 统一由 UIManager 裁决（它会把面板从栈里正确弹出）。

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 打开背包函数
# ----------------------------------------
func open() -> void:
	visible = true
	# 刷新：背包关闭期间拾取的物品（走路自动拾取）需要同步到格子
	refresh()

# ----------------------------------------
# 关闭背包函数
# ----------------------------------------
func close() -> void:
	visible = false
	_hide_tooltip()
	closed.emit()

# ----------------------------------------
# 切换显示函数
# ----------------------------------------
func toggle() -> void:
	if visible:
		close()
	else:
		open()

# ----------------------------------------
# 面板被显示时的钩子
# 由 UIManager.open_panel_impl 在每次"真正打开"后面调用（它直接置 visible，
# 不走本类的 open()，所以刷新/补绑要靠这个钩子）。
#
# 为什么需要：背包面板是 UIManager 懒创建的，创建时机可能早于玩家存在，
# _ready 里的 _find_player_inventory 就查不到 Inventory，导致背包永远空白；
# 每次显示时再尝试绑一次，即可自愈。
# ----------------------------------------
func on_shown() -> void:
	if inventory == null:
		_find_player_inventory()
	# UIManager 关闭面板时只置 visible=false，并不会调用本类的 close()，
	# 于是关闭瞬间若正好有提示框在显示，重开时会"残留"一个旧提示框。
	# 这里统一清一下悬停状态。
	_hovered_slot = -1
	_hide_tooltip()
	# 关闭期间走路自动拾取的物品，重新打开时要同步到格子
	refresh()

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
# 创建界面结构：
#   标题
#   「快捷栏」标签 + 第一栏（0..hotbar_slots-1）
#   分隔线
#   「背包」标签 + 其余格
#   底部操作提示
# ----------------------------------------
func _setup_ui() -> void:
	# 设置锚点：屏幕居中
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	# 面板尺寸：9 格 × 68px ≈ 612，留出内边距 → 680 宽
	offset_left = -340
	offset_top = -230
	offset_right = 340
	offset_bottom = 230

	# 创建背景
	var background = PanelContainer.new()
	background.name = "Background"
	add_child(background)
	# 背景也不能拦鼠标事件（后续子控件要能收到点击），只作视觉
	background.mouse_filter = Control.MOUSE_FILTER_PASS

	# 创建垂直布局
	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.add_theme_constant_override("separation", 6)
	background.add_child(vbox)

	# 创建标题
	var title = Label.new()
	title.name = "Title"
	title.text = "背包"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# ---- 快捷栏区（第一栏）----
	vbox.add_child(_make_section_label("快捷栏（数字键 1-9 选择）", true))

	_hotbar_grid = GridContainer.new()
	_hotbar_grid.name = "HotbarGrid"
	_hotbar_grid.columns = hotbar_slots
	_hotbar_grid.add_theme_constant_override("h_separation", slot_spacing)
	_hotbar_grid.add_theme_constant_override("v_separation", slot_spacing)
	vbox.add_child(_hotbar_grid)

	vbox.add_child(HSeparator.new())

	# ---- 普通背包区 ----
	vbox.add_child(_make_section_label("背包", false))

	_grid_container = GridContainer.new()
	_grid_container.name = "GridContainer"
	_grid_container.columns = columns
	_grid_container.add_theme_constant_override("h_separation", slot_spacing)
	_grid_container.add_theme_constant_override("v_separation", slot_spacing)
	vbox.add_child(_grid_container)

	# ---- 底部操作提示 ----
	vbox.add_child(HSeparator.new())
	var hint = Label.new()
	hint.name = "Hint"
	hint.text = "左键拖拽移动位置 · 右键使用物品 · 拖到储物箱可存入 · Esc 关闭"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	vbox.add_child(hint)

# ----------------------------------------
# 生成分区小标题
# 参数：text - 文本；accent - 是否用金色（快捷栏区）
# ----------------------------------------
func _make_section_label(text: String, accent: bool) -> Label:
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color",
		Color(0.95, 0.8, 0.35) if accent else Color(0.8, 0.8, 0.8))
	return label

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
# 前 hotbar_slots 个进"快捷栏"容器，其余进"背包"容器
# ----------------------------------------
func _create_slots() -> void:
	if not inventory:
		return
	# 防御：容器还没建（理论上不会走到，_ready 里先 _setup_ui）
	if _hotbar_grid == null or _grid_container == null:
		return

	# 清除现有槽位
	_clear_slots()

	# 快捷栏格数不能超过背包总格数
	var hot_count: int = mini(hotbar_slots, inventory.max_slots)

	# 创建新槽位
	for i in range(inventory.max_slots):
		var slot_ui = ItemSlotUI.new()
		slot_ui.slot_index = i
		slot_ui.custom_minimum_size = Vector2(64, 64)
		# 前 N 格用金色边框标出来（快捷栏）；务必在 add_child 之前设，
		# 因为 _ready → _setup_styles 会按 accent 决定边框颜色
		slot_ui.accent = i < hot_count

		# 连接信号
		slot_ui.clicked.connect(_on_slot_clicked)
		slot_ui.hovered.connect(_on_slot_hovered)
		slot_ui.unhovered.connect(_on_slot_unhovered)
		# 左键拖拽放下 → 移动/交换/堆叠
		slot_ui.item_dropped.connect(_on_slot_item_dropped)
		# 储物箱拖进背包 → 转调 Inventory.move_between
		slot_ui.cross_dropped.connect(_on_cross_dropped)
		# 拖拽数据带上来源标识（储物箱 UI 靠它区分"背包拖来的"）
		slot_ui.source_id = "player"

		if i < hot_count:
			_hotbar_grid.add_child(slot_ui)
		else:
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
#   左键：选中（高亮）。不再用双击使用——否则"点两下想拖拽"会误把物品用掉，
#         和拖拽操作冲突；使用统一走右键。
#   右键：使用可用物品
# ----------------------------------------
func _on_slot_clicked(slot: int, button: int) -> void:
	match button:
		MOUSE_BUTTON_LEFT:
			_select_slot(slot)
		MOUSE_BUTTON_RIGHT:
			use_item(slot)

# ----------------------------------------
# 槽位拖放回调（来自 ItemSlotUI.item_dropped）
# 把 from 槽的物品放到 to 槽：空槽=移动，同类可堆叠=合并，否则=交换
# 真正的数据操作交给 Inventory.move_item（它会发 item_changed，UI 自动回刷）
# ----------------------------------------
func _on_slot_item_dropped(from_slot: int, to_slot: int) -> void:
	if inventory == null:
		return
	if from_slot == to_slot:
		return
	inventory.move_item(from_slot, to_slot)
	# 兜底刷新：move_item 对两个槽位都发了 item_changed，正常已自动更新；
	# 这里再刷一次，防止外部监听顺序导致的显示不同步。
	refresh()

# ----------------------------------------
# 跨面板拖放回调（来自 ItemSlotUI.cross_dropped）
# 目前唯一来源是储物箱：把箱子 from_slot 的物品搬到背包 to_slot
# 整堆/合并/交换统一交给 Inventory.move_between（静态，箱子背包共用）
# ----------------------------------------
func _on_cross_dropped(source: String, from_slot: int, to_slot: int) -> void:
	if source != "storage" or inventory == null:
		return
	var storage_inv := _find_open_storage()
	if storage_inv == null:
		return
	Inventory.move_between(storage_inv, from_slot, inventory, to_slot)
	refresh()

# ----------------------------------------
# 找当前打开的储物箱的 Inventory
# StorageUI 在 _ready 时加入 "storage_ui" 组，这里按组查找，不依赖节点路径
# ----------------------------------------
func _find_open_storage() -> Inventory:
	var ui: Node = get_tree().get_first_node_in_group("storage_ui")
	if ui == null:
		return null
	var s = ui.get("storage")
	if s is Inventory and is_instance_valid(s):
		return s
	return null

# ----------------------------------------
# 轻提示：转交 HUD 显示
#
# 背包面板没有自己的提示组件，而"右键被拒却毫无反馈"对玩家等同于 bug，
# 所以统一借 HUD 的轻提示条。HUD 不在场（headless 测试）时就只记日志，不报错。
# ----------------------------------------
func _show_toast(text: String) -> void:
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("show_toast"):
		hud.call("show_toast", text)

# ----------------------------------------
# 使用物品函数
# 右键槽位触发：
#   1. 经 ItemEffects 施加 use_effect（电池→电量等）
#   2. 成功后按 consume_on_use 扣除 1 个
#   3. 无论成败都广播 item_used 信号供外部系统监听
# ----------------------------------------
func use_item(slot: int) -> void:
	item_used.emit(slot)

	if inventory == null:
		return
	var item = inventory.get_item(slot)
	if item == null or item.data == null:
		return

	# 建筑类物品：右键不是"使用"，而是进入放置模式
	if BuildingSystem.is_building(item.data.item_id):
		_try_place_building(item.data.item_id)
		return

	# 用 can_use 而非裸 usable：usable=true 但 use_effect 为空时不算"能使用"
	if not ItemEffects.can_use(item.data):
		return

	# 专属物品的使用权限（决策 ⑦）：不满足就明确说明原因，别让右键"没反应"。
	# 提示走 HUD 的轻提示条 —— 项目里没有通用提示组件，这里复用 HUD 那个。
	var denied: String = ItemEffects.access_denied_reason(item.data)
	if not denied.is_empty():
		_show_toast(denied)
		return

	var player := get_tree().get_first_node_in_group("player")
	var applied := ItemEffects.apply(item.data, player)
	if applied:
		if item.data.consume_on_use:
			item.remove(1)
			if item.is_empty():
				inventory.clear_slot(slot)
			else:
				inventory.set_slot(slot, item)
			refresh()

# ----------------------------------------
# 进入建筑放置模式
#
# 放置需要看着地面瞄准，所以成功后立刻关掉背包面板——
# 留着背包会挡住大半屏幕，玩家根本不知道自己把建筑放哪了。
# ----------------------------------------
func _try_place_building(item_id: StringName) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		return

	var placer := player.get_node_or_null("BuildPlacer")
	if placer == null or not placer.has_method("start_placement"):
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "找不到 BuildPlacer，无法进入放置模式：%s", [item_id])
		return

	var ok: bool = placer.call("start_placement", item_id)
	if ok:
		UIManager.close_panel(UIManager.INVENTORY_PANEL)
	else:
		# 面板保持打开：玩家能看到物品还在，不至于以为"右键把东西弄丢了"
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "start_placement 返回 false：%s", [item_id])


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

		# 定位到鼠标附近，并夹在视口内：
		# 不夹的话，鼠标靠近屏幕右/下边缘时浮窗会被切掉一截。
		var mouse_pos = get_global_mouse_position()
		var vp: Vector2 = get_viewport_rect().size
		var tsize: Vector2 = _tooltip.get_combined_minimum_size()
		_tooltip.global_position = Vector2(
			minf(mouse_pos.x + 16.0, maxf(0.0, vp.x - tsize.x - 8.0)),
			minf(mouse_pos.y + 16.0, maxf(0.0, vp.y - tsize.y - 8.0))
		)

# ----------------------------------------
# 隐藏提示框函数
# ----------------------------------------
func _hide_tooltip() -> void:
	if _tooltip:
		_tooltip.visible = false

# ----------------------------------------
# 查找玩家背包函数
# 在场景树中查找玩家节点的 Inventory 组件
# ----------------------------------------
func _find_player_inventory() -> void:
	# 方式1：通过节点组查找（项目约定：玩家根节点在 "player" 组）
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
