# script/ui/ui_manager.gd
# ============================================
# UI 管理器（挂在主场景 map.tscn 下，同时加入 "ui_manager" 组）
#
# 为什么需要它：
#   之前 HUD 和背包各自监听 Esc、各自判断可见性，谁也管不了谁，
#   于是出现"关背包的同时又弹一次菜单"这类双触发，也没人负责暂停游戏。
#   集中之后，Esc 的语义只有一处定义：
#     有面板开着 → 关掉最上面那个；没有 → 打开暂停菜单。
#
# 为什么用「静态转发」而不是自动加载：
#   autoload 在 `godot --script` 模式下不会被加载，其全局名在编译期不可见，
#   所有引用它的脚本都会编译失败——headless 测试就跑不了了。
#   改成 class_name + static 转发后，`UIManager.open_panel(...)` 仍是静态调用，
#   编译期合法，运行时由 instance 转发到场景里的那个实例。
#
# 另外三个关键点：
#   1. 面板懒加载：地图和玩家都还没就绪时不能 new 背包（它会找不到玩家的
#      Inventory），所以只有第一次 open 时才创建。
#   2. process_mode = ALWAYS：暂停后普通节点会被冻结，若不显式设置，
#      暂停菜单自己的按钮也点不动了——这是最容易漏的一步。
#   3. modal 标记决定暂停：只有 modal 面板（暂停菜单、设置）打开才暂停游戏；
#      背包、小地图不暂停（饥荒式体验：翻背包时世界照常运转）。
# ============================================

class_name UIManager
extends Node

## 有面板被打开
signal panel_opened(panel_name: String)
## 有面板被关闭
signal panel_closed(panel_name: String)
## 游戏暂停状态变化
signal pause_changed(is_paused: bool)

const INVENTORY_PANEL := "inventory"
const PAUSE_PANEL := "pause"
const SETTINGS_PANEL := "settings"
const CRAFTING_PANEL := "crafting"
const EQUIPMENT_PANEL := "equipment"
const DEBUG_PANEL := "debug"
const GRAPHICS_PANEL := "graphics"
const STORAGE_PANEL := "storage"
const BIGMAP_PANEL := "bigmap"

## 「信息类」面板：**可以同时打开**（2026-09-24 用户需求改版）。
##
## 它们各自占九宫格里的固定区域，互不重叠，所以不需要互斥：
##   背包   x 10..422,  y 10..192   （左列上）
##   箱子   x 10..422,  y 200..362  （左列中）
##   制作栏 x 10..422,  y 370..626  （左列下）
##   装备栏 x 850..1270,y 370..710  （右列下；**anchor 全 1.0 贴视口右下角**）
## 中列（x 510..786）只留 HUD 的短提示，底部 y 634..710 留给快捷栏——
## 所以左列三块都止步于 y=626；**装备栏在右列、与快捷栏（x 148..648）横向不相交，才能用到 710**。
##
## ⚠ 历史：这四块以前是"同刻只开一个"（WINDOW_PANELS），叠在一起会互相遮挡、
##   点击目标也会混。改成九宫格后每个都有自己的地盘，遮挡问题从根上没了。
const LAYOUT_PANELS := [INVENTORY_PANEL, STORAGE_PANEL, CRAFTING_PANEL, EQUIPMENT_PANEL]

## 「全屏覆盖类」面板：打开时顺手收掉所有窗口类面板。
## 它们是铺满屏幕的覆盖层（暂停菜单/设置/调试/大地图），底下留着背包没意义，
## 而且关掉覆盖层后会"凭空冒出一个背包"。
## 注意：覆盖类之间**可以叠**（设置压在暂停菜单上，Esc 逐层关），这与窗口类互斥是两回事。
const FULLSCREEN_PANELS := [PAUSE_PANEL, SETTINGS_PANEL, DEBUG_PANEL, GRAPHICS_PANEL, BIGMAP_PANEL]

## 场景中的唯一实例，由 _ready 写入；未就绪时为 null
static var instance: UIManager

## 承载所有弹出面板的画布层；layer 高于主场景的 CanvasLayer，保证盖住 HUD
var _layer: CanvasLayer

## 是否由本管理器在"没有面板打开时"用 Esc 打开游戏内暂停菜单。
## 主菜单场景（main_menu.tscn）里也会挂一个 UIManager 来复用设置面板，
## 但那里没有"游戏"可暂停，Esc 不该弹暂停菜单——由主菜单把它置 false。
var esc_opens_pause: bool = true

## 当前打开的面板名，末尾为栈顶（Esc 先关它）
var _stack: Array[String] = []
## name -> Callable(): Control
var _factories: Dictionary = {}
## name -> bool（是否暂停游戏）
var _modal: Dictionary = {}
## name -> Control（已创建的实例）
var _instances: Dictionary = {}


func _ready() -> void:
	instance = self
	add_to_group("ui_manager")

	# 图像设置要**尽早**生效：分辨率、全屏、界面缩放必须在第一帧画出来之前
	# 定好，否则玩家会先看到一个默认尺寸的窗口再跳一下。
	# UIManager 在主菜单与地图两个场景都存在，是唯一稳定的公共入口
	# （设置面板本身是懒加载的，GraphicsUI 这时候还没被创建）。
	# GraphicsConfig 内部有 has_saved_config 守卫：没存过配置就不动窗口，
	# 沿用 project.godot 里的初始窗口尺寸。
	GraphicsConfig.apply_saved()

	# 暂停时仍需接收输入并处理，否则暂停后就再也唤不出菜单了
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)

	_layer = CanvasLayer.new()
	_layer.name = "UILayer"
	_layer.layer = 128
	add_child(_layer)

	# 窗口尺寸变化时同步所有需要自适应的面板（全屏面板必须显式改 size，
	# 它们在 _ready 里设置的锚点不可靠，见 pause_menu_ui.gd 顶部的坑说明）
	get_viewport().size_changed.connect(_on_viewport_resized)

	_register_panels()


func _on_viewport_resized() -> void:
	for p in _instances.values():
		if p is Control and p.has_method("on_viewport_resized"):
			p.call("on_viewport_resized")


func _register_panels() -> void:
	register_panel(INVENTORY_PANEL, func() -> Control: return InventoryUI.new(), false)
	register_panel(PAUSE_PANEL, func() -> Control: return PauseMenuUI.new(), true)
	register_panel(SETTINGS_PANEL, func() -> Control: return SettingsUI.new(), true)
	# 小地图不在这里注册：它改成 HUD 的常驻子组件（右上角，默认显示），
	# 由 HUD 的按钮/M 键切 visible。若仍作为面板托管，Esc 关栈顶时会把它一起关掉。
	# 合成不暂停游戏（和背包一样，翻面板时世界照常运转）
	register_panel(CRAFTING_PANEL, func() -> Control: return CraftingUI.new(), false)
	# 装备不暂停游戏
	register_panel(EQUIPMENT_PANEL, func() -> Control: return EquipmentUI.new(), false)
	# 调试选项：从设置里压栈打开，跟设置一样暂停游戏
	register_panel(DEBUG_PANEL, func() -> Control: return DebugUI.new(), true)
	# 图像设置：同样从设置里压栈打开（分辨率/窗口模式，modal）
	register_panel(GRAPHICS_PANEL, func() -> Control: return GraphicsUI.new(), true)
	# 储物箱：由 BuildPlacer 点击世界里的箱子打开，不暂停（和背包一致）
	register_panel(STORAGE_PANEL, func() -> Control: return StorageUI.new(), false)
	# 大地图（M 键）：全屏 + **打开即暂停**（modal=true）。
	#   暂停有两个作用：① 看地图时世界停住；② 鼠标/键盘不会漏给游戏——
	#   配合面板自身 mouse_filter=STOP，点地图不会顺手让角色跑过去。
	#   M 键的监听在 UIManager._input 里（不在 HUD）：暂停后 HUD 被冻结收不到
	#   输入，若还由 HUD 处理，按 M 就打不开"再按一次关掉"的回路了。
	register_panel(BIGMAP_PANEL, func() -> Control: return BigMapUI.new(), true)


# ============================================
# 输入：Esc（关面板/开暂停菜单）与 M（开关大地图）的统一入口
# ============================================

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _stack.is_empty():
			# 主菜单场景里没有暂停概念，Esc 不做任何事
			if esc_opens_pause:
				open_panel_impl(PAUSE_PANEL)
				get_viewport().set_input_as_handled()
		else:
			close_top_impl()
			get_viewport().set_input_as_handled()
		return

	# M：开关大地图。
	# 放在这里而不是 HUD，因为大地图是 modal（打开即暂停），暂停后 HUD 被冻结、
	# 收不到 _input，就再也没法用 M 关掉它了；UIManager 是 ALWAYS，暂停也收得到。
	# 没有地图生成器（主菜单场景）时不响应，避免在主菜单弹出一个空地图。
	if event.is_action_pressed("toggle_bigmap") and _has_map():
		toggle_panel_impl(BIGMAP_PANEL)
		get_viewport().set_input_as_handled()


## 当前场景里是否有地图（用于判断大地图能不能开）
func _has_map() -> bool:
	return get_tree().get_first_node_in_group("map_gen") != null


# ============================================
# 静态接口（供其他脚本调用，无需自己找节点）
# ============================================

static func open_panel(name: String) -> Control:
	return instance.open_panel_impl(name) if instance != null else null


static func close_panel(name: String) -> void:
	if instance != null:
		instance.close_panel_impl(name)


static func close_top() -> void:
	if instance != null:
		instance.close_top_impl()


static func close_all() -> void:
	if instance != null:
		instance.close_all_impl()


static func toggle_panel(name: String) -> void:
	if instance != null:
		instance.toggle_panel_impl(name)


static func is_open(name: String) -> bool:
	return instance.is_open_impl(name) if instance != null else false


static func has_any_open() -> bool:
	return instance.has_any_open_impl() if instance != null else false


static func get_panel(name: String) -> Control:
	return instance.get_panel_impl(name) if instance != null else null


static func toggle_inventory() -> void:
	if instance != null:
		instance.toggle_panel_impl(INVENTORY_PANEL)


static func toggle_crafting() -> void:
	if instance != null:
		instance.toggle_panel_impl(CRAFTING_PANEL)


static func toggle_equipment() -> void:
	if instance != null:
		instance.toggle_panel_impl(EQUIPMENT_PANEL)


# ============================================
# 实例实现（静态方法转发到这里）
# ============================================

func register_panel(name: String, factory: Callable, modal: bool) -> void:
	_factories[name] = factory
	_modal[name] = modal


func open_panel_impl(name: String) -> Control:
	if not _factories.has(name):
		push_error("UIManager: 未注册的面板 %s" % name)
		return null

	var panel := _get_or_create(name)
	if panel == null:
		return null
	if _stack.has(name):
		return panel

	# 互斥规则（2026-09-24 起只剩一条）：
	#   全屏覆盖类（暂停/设置/调试/大地图）打开时，把四块信息面板统统收掉。
	#   信息类之间**不再互斥**——它们各有九宫格里自己的区域，同开不遮挡。
	# 这里只改可见性与栈，**不**调 _update_pause——统一留到最后算一次，
	# 否则中途 paused 会翻转两次（先关旧后开新），白白甩出无用的信号。
	if FULLSCREEN_PANELS.has(name):
		_close_group(LAYOUT_PANELS, "")

	_stack.append(name)
	panel.visible = true
	# 首次显示时才刷新地图——此时地图数据才一定已生成
	if panel.has_method("refresh_map"):
		panel.refresh_map()
	# 通用"面板被显示"钩子：面板可借此做懒绑定/刷新。
	# 例：背包是懒创建的，若它先于玩家被 new 出来就永远绑不上 Inventory；
	# 每次显示时再绑一次，能自愈"背包空白"。
	if panel.has_method("on_shown"):
		panel.call("on_shown")
	# 显示后再统一清一遍键盘聚焦：面板可能在 on_shown 里重建了按钮
	disable_keyboard_focus(panel)

	_update_pause()
	panel_opened.emit(name)
	return panel


# ----------------------------------------
# 递归关掉一棵子树里所有按钮的键盘聚焦
#
# 为什么需要：Button 默认 focus_mode = FOCUS_ALL，点过之后会一直保持焦点；
# 而被聚焦的按钮会把空格/回车（Godot 内置的 ui_accept）当成"点击"。
# 本项目空格 = 采集/互动，于是"按空格顺带触发上次点过的按钮"。
# 这里的 UI 全是鼠标驱动，不需要键盘导航，所以统一关掉最省事。
# ----------------------------------------
static func disable_keyboard_focus(root: Node) -> void:
	if root == null:
		return
	if root is Button:
		(root as Button).focus_mode = Control.FOCUS_NONE
	for child in root.get_children():
		disable_keyboard_focus(child)


func close_panel_impl(name: String) -> void:
	if not _stack.has(name):
		return
	_stack.erase(name)
	var panel := _instances.get(name) as Control
	if panel != null:
		panel.visible = false

	_update_pause()
	panel_closed.emit(name)


func close_top_impl() -> void:
	if _stack.is_empty():
		return
	close_panel_impl(_stack[-1])


## 收掉 group 里所有已打开的面板（keep 指定的那个除外）。
## 只做"摘栈 + 隐藏 + 发信号"，**不重算暂停**：调用方 open_panel_impl 随后会
## 统一调一次 _update_pause()，避免这里的中间态把 paused 翻转出多余信号。
func _close_group(group: Array, keep: String) -> void:
	for n in group:
		var panel_name: String = n
		if panel_name == keep or not _stack.has(panel_name):
			continue
		_stack.erase(panel_name)
		var panel := _instances.get(panel_name) as Control
		if panel != null:
			panel.visible = false
		panel_closed.emit(panel_name)


func close_all_impl() -> void:
	while not _stack.is_empty():
		close_panel_impl(_stack[-1])


func toggle_panel_impl(name: String) -> void:
	if _stack.has(name):
		close_panel_impl(name)
	else:
		open_panel_impl(name)


func is_open_impl(name: String) -> bool:
	return _stack.has(name)


func has_any_open_impl() -> bool:
	return not _stack.is_empty()


func get_panel_impl(name: String) -> Control:
	return _instances.get(name) as Control


# ============================================
# 私有
# ============================================

func _get_or_create(name: String) -> Control:
	if _instances.has(name):
		return _instances[name] as Control

	var panel := (_factories[name] as Callable).call() as Control
	if panel == null:
		push_error("UIManager: 面板 %s 的工厂没有返回 Control" % name)
		return null

	panel.name = name.capitalize() + "UI"
	panel.visible = false
	# 暂停后仍要能点按钮
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_layer.add_child(panel)
	_instances[name] = panel
	return panel


## 只要栈里还有一个 modal 面板就暂停游戏
func _update_pause() -> void:
	var should_pause := false
	for n in _stack:
		if _modal.get(n, false):
			should_pause = true
			break

	if get_tree().paused != should_pause:
		get_tree().paused = should_pause
		pause_changed.emit(should_pause)
