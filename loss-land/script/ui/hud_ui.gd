# script/ui/hud_ui.gd
# ============================================
# HUD界面 - 游戏主界面显示
#
# 功能说明：
#   1. 快捷栏（底部中央，9格）- 存放当前使用的物品
#   2. 状态栏（左下角：电量、生命值、体温）
#   3. 按键提示（底部中央）- 显示操作提示文字
#   4. 右上角按钮（小地图、菜单）
#
# 连接到其他系统：
#   - Player: 调用 update_health() / update_power() / update_temperature()
#   - Inventory: Tab键切换背包显示
#
# 修改提示：
#   - 快捷栏槽位数：修改 hotbar_slots 导出变量
#   - 状态栏位置：修改 _create_status_panel() 中的 offset 值
#   - 快捷栏位置：修改 _create_hotbar() 中的 position 和 slot_size
#   - 按键绑定：修改 _input() 中的 action 名称
# ============================================

class_name HUDUI
extends Control

# ============================================
# 信号定义
# ============================================

# 当玩家按下快捷栏中的物品时触发
# slot_index: 被按下的槽位索引（0-8）
signal hotbar_slot_pressed(slot_index: int)

# 当玩家打开/关闭背包时触发
signal inventory_toggled(is_open: bool)

# 当玩家打开菜单时触发
signal menu_requested()

# 当玩家切换小地图时触发
signal minimap_toggled()

# ============================================
# 导出变量 - 可在编辑器中修改
# ============================================

## 快捷栏的槽位数量（默认9格，对应键盘数字键1-9）
@export var hotbar_slots: int = 9

## 状态栏初始值（会被 Player 系统的实际值覆盖）
@export var current_health: int = 100
@export var max_health: int = 100
@export var current_power: int = 100
@export var current_temperature: int = 30

# ============================================
# 私有变量 - 存储节点引用
# ============================================

## 快捷栏槽位数组，存储所有 ItemSlotUI 实例
var _hotbar_slots: Array[ItemSlotUI] = []

## 状态栏的 Label 节点引用（用于更新显示文本）
var _health_label: Label
var _power_label: Label
var _temperature_label: Label

## 控制提示 Label 节点
var _hints_label: Label

## 右上角按钮容器
var _topright_vbox: VBoxContainer

## 菜单按钮引用（用于后续功能扩展）
var _menu_button: Button

## 小地图按钮引用（用于后续功能扩展）
var _minimap_button: Button

# ============================================
# 生命周期函数
# ============================================

## 节点进入场景树时调用，初始化所有UI组件
func _ready() -> void:
	_setup_ui()

## 每帧检测输入，处理快捷键
## 按键映射（需在项目设置中配置）：
##   - ui_tab: Tab键 -> 切换背包
##   - toggle_minimap: M键 -> 切换小地图（需自行添加）
##   - ui_cancel: Esc键 -> 打开菜单
func _input(event: InputEvent) -> void:
	# Tab 切换背包显示/隐藏
	if event.is_action_pressed("ui_tab"):
		_toggle_inventory()
	
	# M 切换小地图显示/隐藏
	# 注意：需在项目设置中添加 toggle_minimap 输入映射
	if event.is_action_pressed("toggle_minimap"):
		_toggle_minimap()
	
	# ESC 打开游戏菜单
	if event.is_action_pressed("ui_cancel"):
		_open_menu()

# ============================================
# 公共方法 - 供其他系统调用
# ============================================

## 更新生命值显示
## 调用方式：hud.update_health(current, max)
## @param health 当前生命值
## @param max_h 最大生命值
func update_health(health: int, max_h: int) -> void:
	current_health = health
	max_health = max_h
	if _health_label:
		# ♥ 符号表示生命值，格式：♥ 当前值/最大值
		_health_label.text = "♥ %d/%d" % [health, max_h]

## 更新电量显示
## 调用方式：hud.update_power(current)
## @param power 当前电量值（0-100）
func update_power(power: int) -> void:
	current_power = power
	if _power_label:
		# ⚡ 符号表示电量
		_power_label.text = "⚡ %d" % power

## 更新体温显示
## 调用方式：hud.update_temperature(current)
## @param temp 当前体温值
func update_temperature(temp: int) -> void:
	current_temperature = temp
	if _temperature_label:
		# 🌡 符号表示体温
		_temperature_label.text = "🌡 %d" % temp

## 获取快捷栏槽位
## @param index 槽位索引（0-8）
## @return 对应的 ItemSlotUI 实例，无效索引返回 null
func get_hotbar_slot(index: int) -> ItemSlotUI:
	if index >= 0 and index < _hotbar_slots.size():
		return _hotbar_slots[index]
	return null

## 强制刷新所有状态栏显示（用于初始化或重置）
func refresh_all_status() -> void:
	update_health(current_health, max_health)
	update_power(current_power)
	update_temperature(current_temperature)

# ============================================
# 私有方法 - UI设置与初始化
# ============================================

## 初始化所有UI组件的入口方法
## 调用顺序：锚点设置 -> 快捷栏 -> 状态栏 -> 提示 -> 按钮
func _setup_ui() -> void:
	# 1. 设置控件全屏覆盖整个视口
	full_anchor()
	
	# 2. 创建底部快捷栏
	_create_hotbar()
	
	# 3. 创建左下角状态栏面板
	_create_status_panel()
	
	# 4. 创建底部中央操作提示
	_create_control_hints()
	
	# 5. 创建右上角按钮（小地图、菜单）
	_create_topright_buttons()

# ----------------------------------------
# 全屏锚点设置
# ----------------------------------------

## 设置控件全屏覆盖视口
## 使得 HUD 能够覆盖整个游戏窗口
## 锚点说明：
##   anchor_left/top = 0, anchor_right/bottom = 1 表示相对视口大小
##   offset 用于精确调整位置
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
# 快捷栏相关
# ----------------------------------------

## 创建底部快捷栏容器和所有槽位
## 快捷栏位于屏幕底部居中，包含9个物品槽
## 槽位可通过鼠标点击或数字键1-9选择
func _create_hotbar() -> void:
	# 创建水平布局容器，用于排列多个槽位
	var hotbar_container = HBoxContainer.new()
	hotbar_container.name = "HotbarContainer"
	# CENTER 使得所有子节点水平居中排列
	hotbar_container.alignment = BoxContainer.ALIGNMENT_CENTER
	
	# 设置初始位置：底部，水平居中
	# position.y = 视口高度 - 100，表示距底部100像素
	hotbar_container.position = Vector2(0, get_viewport_rect().size.y - 100)
	
	# 设置容器最小高度为80像素
	hotbar_container.custom_minimum_size = Vector2(0, 80)
	
	# 添加到 HUD 节点下
	add_child(hotbar_container)
	
	# 设置 z_index 确保快捷栏显示在其他UI之上
	hotbar_container.z_index = 100
	
	# 循环创建所有槽位
	for i in range(hotbar_slots):
		var slot = _create_hotbar_slot(i)
		_hotbar_slots.append(slot)
		hotbar_container.add_child(slot)
	
	# 等待 _ready 执行完毕，计算槽位总宽度并居中
	await ready
	# 每个槽位 64x64 像素，槽位间距 8 像素
	var slot_size = 64
	var total_width = slot_size * hotbar_slots + 8 * (hotbar_slots - 1)
	# 居中： (视口宽度 - 总宽度) / 2
	hotbar_container.position.x = (get_viewport_rect().size.x - total_width) / 2

## 创建单个快捷栏槽位
## @param index 槽位索引（0表示数字键1，8表示数字键9）
## @return 创建的 ItemSlotUI 实例
func _create_hotbar_slot(index: int) -> ItemSlotUI:
	var slot = ItemSlotUI.new()
	slot.name = "HotbarSlot%d" % index
	slot.slot_index = index  # 记录索引，用于识别按下了哪个槽位
	slot.custom_minimum_size = Vector2(64, 64)  # 槽位大小 64x64
	return slot

# ----------------------------------------
# 状态栏面板相关
# ----------------------------------------

## 创建左下角状态栏面板
## 显示内容：电量⚡、生命值♥、体温🌡
## 面板采用半透明黑色背景，圆角设计
func _create_status_panel() -> void:
	# 创建面板容器
	var panel = PanelContainer.new()
	panel.name = "StatusPanel"
	
	# 设置面板位置（左上角）
	# offset_left/top = 距左/上边缘的距离
	# offset_right/bottom = 距右/下边缘的距离（正值表示向内缩）
	panel.anchor_top = 0
	panel.anchor_bottom = 0
	panel.offset_left = 20
	panel.offset_top = 20
	panel.offset_right = 140  # 面板宽度 = 140 - 20 = 120
	panel.offset_bottom = 140 # 面板高度 = 140 - 20 = 120
	
	panel.z_index = 100  # 确保在最上层
	
	# 创建半透明黑色背景样式
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)  # RGBA: 黑色60%透明
	style.set_corner_radius_all(8)  # 圆角半径8像素
	style.set_content_margin_all(12)  # 内边距12像素
	panel.add_theme_stylebox_override("panel", style)
	
	add_child(panel)
	
	# 创建垂直布局容器，使标签垂直排列
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)  # 标签间距8像素
	panel.add_child(vbox)
	
	# ----- 电量标签 -----
	_power_label = Label.new()
	_power_label.text = "⚡ %d" % current_power
	_power_label.add_theme_font_size_override("font_size", 18)  # 字体大小18
	vbox.add_child(_power_label)
	
	# ----- 生命值标签 -----
	_health_label = Label.new()
	_health_label.text = "♥ %d/%d" % [current_health, max_health]
	_health_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_health_label)
	
	# ----- 体温标签 -----
	_temperature_label = Label.new()
	_temperature_label.text = "🌡 %d" % current_temperature
	_temperature_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_temperature_label)

# ----------------------------------------
# 操作提示相关
# ----------------------------------------

## 创建底部中央的操作提示文字
## 显示格式：[E] 互动  [F] 攻击  [Tab] 背包
func _create_control_hints() -> void:
	_hints_label = Label.new()
	_hints_label.name = "ControlHints"
	_hints_label.text = "[E] 互动  [F] 攻击  [Tab] 背包"
	
	# 锚点设置：水平居中，垂直靠上（状态栏下方）
	_hints_label.anchor_left = 0.5   # 左锚点位于视口50%处
	_hints_label.anchor_right = 0.5   # 右锚点位于视口50%处
	_hints_label.anchor_top = 0.0     # 上锚点位于视口0%处（顶部）
	_hints_label.anchor_bottom = 0.0  # 下锚点位于视口0%处（顶部）
	
	# offset 调整相对锚点的位置（距顶部140像素，避开状态栏）
	_hints_label.offset_top = 0     # 距顶部0像素
	_hints_label.offset_bottom = 0  # 高度0像素
	
	# 对齐方式：水平和垂直都居中
	_hints_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hints_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	_hints_label.z_index = 100
	add_child(_hints_label)

## 更新操作提示文字
## @param hints 新的提示文本，例如："[E] 互动  [F] 攻击  [Tab] 背包"
func update_control_hints(hints: String) -> void:
	if _hints_label:
		_hints_label.text = hints

# ----------------------------------------
# 右上角按钮相关
# ----------------------------------------

## 创建右上角按钮容器（小地图、菜单）
func _create_topright_buttons() -> void:
	# 创建垂直布局容器，按钮从上到下排列
	_topright_vbox = VBoxContainer.new()
	_topright_vbox.name = "TopRightButtons"
	_topright_vbox.alignment = BoxContainer.ALIGNMENT_END  # 右对齐
	
	# 锚点：右上角
	_topright_vbox.anchor_left = 1.0
	_topright_vbox.anchor_right = 1.0
	_topright_vbox.anchor_top = 0.0
	_topright_vbox.anchor_bottom = 0.0
	
	# offset 调整位置（负值表示向左/向下）
	_topright_vbox.offset_left = -110  # 距右边缘110像素
	_topright_vbox.offset_top = 20
	_topright_vbox.offset_right = -20  # 距右边缘20像素
	_topright_vbox.offset_bottom = 100
	
	_topright_vbox.z_index = 100
	add_child(_topright_vbox)
	
	# 创建小地图按钮
	_minimap_button = _create_button("[M] 小地图")
	_minimap_button.pressed.connect(_on_minimap_button_pressed)  # 连接信号
	_topright_vbox.add_child(_minimap_button)
	
	# 创建菜单按钮
	_menu_button = _create_button("[Esc] 菜单")
	_menu_button.pressed.connect(_on_menu_button_pressed)  # 连接信号
	_topright_vbox.add_child(_menu_button)

## 创建通用按钮
## @param text 按钮显示文字
## @return 创建的 Button 实例
func _create_button(text: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(90, 32)  # 最小尺寸 90x32
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT   # 文字左对齐
	return btn

# ----------------------------------------
# 按钮信号回调
# ----------------------------------------

## 小地图按钮被按下时的回调
func _on_minimap_button_pressed() -> void:
	_toggle_minimap()

## 菜单按钮被按下时的回调
func _on_menu_button_pressed() -> void:
	_open_menu()

# ============================================
# 私有方法 - 交互逻辑
# ============================================

## 切换背包显示/隐藏
## 通过查找 InventoryUI 节点并调用其 toggle() 方法
func _toggle_inventory() -> void:
	# 尝试获取背包UI节点（路径取决于你的场景结构）
	var inventory_ui = get_node_or_null("/root/Map/CanvasLayer/InventoryUI")
	if inventory_ui:
		inventory_ui.toggle()
		# 发射信号供其他系统监听
		emit_signal("inventory_toggled", inventory_ui.visible)
	else:
		push_warning("HUD: 找不到 InventoryUI 节点，请检查路径是否正确")

## 切换小地图显示/隐藏
## TODO: 需要实现小地图功能
func _toggle_minimap() -> void:
	emit_signal("minimap_toggled")
	# -----------------------
	# TODO: 实现小地图切换逻辑
	# 示例：
	# if minimap.visible:
	#     minimap.hide()
	# else:
	#     minimap.show()
	# -----------------------

## 打开游戏菜单
## TODO: 需要实现菜单功能
func _open_menu() -> void:
	emit_signal("menu_requested")
	# -----------------------
	# TODO: 实现菜单打开逻辑
	# 示例：
	# get_tree().paused = true
	# menu_panel.show()
	# -----------------------

# ============================================
# 工具方法
# ============================================

## 打印当前HUD状态（调试用）
## 可在开发时调用查看各状态值
func debug_print_status() -> void:
	print("========== HUD Status ==========")
	print("Health: %d/%d" % [current_health, max_health])
	print("Power: %d" % current_power)
	print("Temperature: %d" % current_temperature)
	print("Hotbar Slots: %d" % hotbar_slots)
	print("================================")
