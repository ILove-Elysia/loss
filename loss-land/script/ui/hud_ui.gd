# script/ui/hud_ui.gd
# ============================================
# HUD界面 - 游戏主界面显示
#
# 布局（2026-09-24 三次改版：物品格与贴图整体缩小，左上三块面板跟着收紧）
#
#   左列 x 10..502      中列 x 510..786    右列 x 794..1270
#   ------------------------------------------------------------
#   背包 y 10..192      （无常驻件）       小地图 x 890..1102 y 10..242
#   箱子 y 200..362     吐司 y 556..582    [ 时间 ]  x 890..1102 y 246..274
#   制作 y 370..626                        按钮列    x 1110..1270 y 10..118
#                                          状态栏    x 1110..1270 y 126..~258
#   ------------------------------------------------------------
#   左列三块面板统一宽 412（x 10..422），列边界仍是 502。
#   装备栏 x 850..1270、y 370..710（420×340，右列下半）
#   快捷栏 y 634..710，居中于左列+中列（中心 x≈398）
#
#   **左列 / 中列**的信息面板一律止步于 y=626（`CONTENT_BOTTOM`），
#   底下 y 634..710 这条带子留给快捷栏；**右列例外** —— 装备栏可用到 710。
#
# ⚠ 上面这些是**1280×720 设计视口**下的落点。界面缩放
#   （GraphicsConfig.ui_scale → content_scale_factor）>1 时，canvas_items + expand
#   会把逻辑视口缩小（1.05 ⇒ 1219×686），写死的绝对坐标会被裁到屏幕外。
#   所以**右列与底部一律走贴边锚定**（anchor 1.0 + 负 offset）：
#   按钮列 / 状态栏 / 装备栏 → 视口右边缘；快捷栏 → 视口底边。
#   新增贴右/贴底的元素请照做，别再写绝对 x/y。
#
# 修改提示：位置都走下面那组布局常量，别再散落魔法数字。
# ============================================

class_name HUDUI
extends Control

# ============================================
# 九宫格布局常量（1280×720 固定视口；与 script/ui/* 的 RECT_* 一套）
# ============================================

const MARGIN := 10.0
const LEFT_COL_LEFT := 10.0
const LEFT_COL_RIGHT := 502.0
const MAP_COL_LEFT := 510.0
const MAP_COL_RIGHT := 786.0
const RIGHT_COL_LEFT := 794.0
const RIGHT_COL_RIGHT := 1270.0
## 右列控件距**视口右边缘**的边距（= 1280 − 1270 = 10）。
## 右列三样（按钮列 / 状态栏 / 装备栏）实际都锚在视口右边缘
## （anchor_left = anchor_right = 1.0 + 负 offset），所以在 1280 宽的视口里
## 它们正好落在 RIGHT_COL_RIGHT=1270；而**视口被界面缩放缩小时会跟着往里收**。
## ⚠ 界面缩放（GraphicsConfig.ui_scale → content_scale_factor）>1 时，
## canvas_items + expand 会把**逻辑视口**缩小（1.05 ⇒ 1219×686），
## 所有按 1280 写死的绝对坐标都会被裁到屏幕外 —— 右列/底部的控件必须走贴边锚定。
const RIGHT_MARGIN := 1280.0 - RIGHT_COL_RIGHT
## **左列 / 中列**信息面板的下边界（给快捷栏带上沿留 8px 间隙）。
## 右列不受这条约束 —— 装备栏一路用到 HOTBAR_BOTTOM（见 equipment_ui.gd 的 RECT_EQUIPMENT）。
## 左列三块信息面板的统一宽度（10 列 ×36 + 9×4 间距 = 396，左右各留 8 内边距）
const PANEL_W := 412.0
## 左列三块面板之间的竖向间隙
const PANEL_GAP := 8.0
const CONTENT_BOTTOM := 626.0
const HOTBAR_TOP := 634.0
const HOTBAR_BOTTOM := 710.0

# --- 右上角组合块：左列小地图+时钟、右列三个按钮+状态栏，整体贴着右上角 ---
## 按钮列里的按钮个数（暂停 / 大地图 / 小地图开关）——改这个数，STATUS_TOP 会自动跟着走
const BTN_COUNT := 3
const BTN_W := 160.0
const BTN_H := 32.0
const BTN_SEP := 6.0
## 小地图列与按钮列之间的横向间隙
const BLOCK_GAP := 8.0
## 按钮列底部 = MARGIN + (32+6)×3 − 6 = 118
const BTN_COL_BOTTOM := MARGIN + (BTN_H + BTN_SEP) * BTN_COUNT - BTN_SEP
## 小地图列底部 = 10 + 小地图高 232 + 间隙 4 + 时钟 28 = 274。
## 装备栏顶（380）必须 ≥ 这个值 + MARGIN —— 由 test/ui_grid_layout_check.py 交叉核对。
const CLUSTER_BOTTOM := 274.0
## 状态栏：按钮组**正下方**、与按钮列同宽（= BTN_COL_BOTTOM + BLOCK_GAP = 126）
const STATUS_WIDTH := 160.0
const STATUS_TOP := BTN_COL_BOTTOM + BLOCK_GAP
## 状态栏排版：可用高度 = STATUS_TOP(126)..装备栏顶(380) = 254px（很充裕）。
## 5 行（⚡/🔋/♥/🌡/🍖）按 5×~19 + 4×4 + 2×8 ≈ 127 估，留 ~30px 余量。
## 这三个值是上一版（可用高度只有 138px）为了塞进 5 行收紧出来的，现在有富余也先别动——
## 换字体/加行都会立刻吃掉这点余量，要改先按上面的式子算一遍。
const STATUS_FONT_SIZE := 14
const STATUS_ROW_SEP := 4
const STATUS_PAD := 8

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
## 自身电量（内置电量角色才有）与核心电量（装着带电池的核心才有）是两块电池
@export var current_power: int = 100
@export var current_core_power: int = 0
@export var current_temperature: int = 30
@export var current_hunger: int = 100

# ============================================
# 私有变量 - 存储节点引用
# ============================================

## 快捷栏槽位数组，存储所有 ItemSlotUI 实例
var _hotbar_slots: Array[ItemSlotUI] = []

## 当前选中的快捷栏槽位索引（-1 表示未选中）
var _selected_hotbar: int = -1

## 绑定的背包（玩家 Inventory）。快捷栏镜像它的前 hotbar_slots 个槽位。
## 原先快捷栏只是空壳、永远不显示任何物品——拾取后"不进快捷栏"就是这个原因。
var _inventory: Inventory = null

## 状态栏的 Label 节点引用（用于更新显示文本）
var _health_label: Label
## 状态栏面板本体：行数会变（有无核心行），需要重算高度
var _status_panel: PanelContainer

## 电量有**两条独立的行**（用户决策 2026-09-16）：
##   ⚡ 自身电量 —— 内置电量（机器人）常驻；两者都没有时退化为灰暗占位
##   🔋 核心电量 —— 装着带电池的核心（动力核心等）时才出现
## 两块电池各算各的，不合并显示。
var _power_label: Label
var _core_power_label: Label

## 自身电量行是否"亮起"（true = 显示真实电量，false = 灰暗占位）。
## 初值取自角色注册表，运行时由 PlayerVitals._push_hud() → set_power_active() 纠正，
## 所以不依赖 HUD 与 Vitals 谁先 _ready。
var _power_row_active: bool = false
## 核心电量行是否显示（装着带电池的核心 → true）。
## 同样由 PlayerVitals._push_hud() → set_core_active() 推过来。
var _core_row_active: bool = false

## 电量行两种配色：亮起时暖黄（能量感），占位时半透明灰（明确"未启用"）
const POWER_ROW_ACTIVE_COLOR: Color = Color(1.0, 0.9, 0.45)
const POWER_ROW_IDLE_COLOR: Color = Color(0.62, 0.62, 0.62, 0.7)
## 核心电量行的配色：青蓝，与自身电量的暖黄区分开，一眼看出是"设备电池"
const CORE_ROW_COLOR: Color = Color(0.45, 0.85, 1.0)
var _temperature_label: Label
var _hunger_label: Label

## 右上角容器（三个按钮竖排：暂停 / 大地图 / 小地图开关）
var _topright: VBoxContainer

## 小地图实例（常驻，默认显示；开关只切它自己的 visible）
var _minimap: MinimapUI = null

## 小地图的固定占位：关掉地图时它仍然占着同一块尺寸，
## 否则 VBox 会塌缩，小地图下方的时钟会往上跳。
var _map_slot: Control = null

## 菜单按钮引用（用于后续功能扩展）
var _menu_button: Button

## 小地图开关按钮引用
var _minimap_button: Button

## 大地图按钮引用（全屏地图，等同 M 键）
var _bigmap_button: Button

## 顶部中央时钟 Label（昼夜系统）
var _clock_label: Label

## 缓存的昼夜节点（"day_night" 组），找不到时每 2 秒重试一次
var _day_night: Node = null

## 时钟刷新计时器（0.25 秒刷一次文本足够，省掉每帧格式化）
var _clock_refresh_timer: float = 0.0

## 死亡 UI：屏幕居中底部的「你已死亡」+ 倒计时/复活按钮（仅死亡时可见）
var _death_panel: VBoxContainer = null
var _death_label: Label = null
var _revive_button: Button = null

## 居中底部的轻提示（物品使用被拒等短反馈，平时隐藏）
var _toast_label: Label = null
var _toast_timer: float = 0.0

# ============================================
# 生命周期函数
# ============================================

## 节点进入场景树时调用，初始化所有UI组件
func _ready() -> void:
	# 注册到 "hud" 组，供玩家等系统按组查找。
	# 不要再用 "/root/Node3D/CanvasLayer/HUDUI" 这类绝对路径——
	# 场景根节点一改名就全线失效（本文件原先写死 /root/Map/... 导致背包打不开）。
	add_to_group("hud")

	# HUD 覆盖全屏，必须显式保持 IGNORE，否则会吞掉 3D 世界的鼠标点击。
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_setup_ui()

	# 视口尺寸变化（改窗口大小 / 改界面缩放）时把 HUD 根重新贴合视口。
	# 各面板由 UIManager 显式调 on_viewport_resized；HUD 靠锚点自动跟随，
	# 但"根控件在视口 size_2d_override 变化时是否自动重排"属于引擎行为，
	# 加一道保险成本极低：full_anchor() 重设锚点并归零 offset，
	# 强制按当前视口矩形重算，底栏/右上簇随之归位。
	get_viewport().size_changed.connect(_fit_to_viewport)

	# 把快捷栏接到玩家的背包上：拾取/合成/使用后快捷栏才实时显示物品。
	_bind_inventory()

	# 血量上限由所选角色决定（CharacterRegistry → physics.gd._apply_character），
	# 本文件 @export 的 current_health/max_health 只是占位默认值。
	# physics 的 _ready 早于 HUD，它那次 update_health 找不到 "hud" 组，
	# 所以这里必须再主动同步一次，否则赤铁守卫(130)开局会显示成 100/100。
	_bind_health()


## 开局从玩家身上同步一次血量（供上面 _ready 调用）
func _bind_health() -> void:
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var phys: Node = player.get_node_or_null("Physics")
	if phys == null:
		return
	var hp: int = int(phys.get("current_health"))
	var hp_max: int = int(phys.get("max_health"))
	if hp_max > 0:
		update_health(hp, hp_max)


## 视口尺寸变化时重新贴合（窗口缩放 / 界面缩放都会触发 size_changed）
func _fit_to_viewport() -> void:
	full_anchor()
	queue_redraw()


## 供 UIManager 统一调用（与各面板同一套入口）
func on_viewport_resized() -> void:
	_fit_to_viewport()

## 每帧检测输入，处理快捷键
## 按键映射（需在项目设置中配置）：
##   - ui_tab: Tab键 -> 切换背包
##   - ui_cancel: Esc键 -> 打开菜单
##
## 注意：小地图**没有快捷键**（用户 2026-09-12 约定），只由右上角按钮开关。
## M 键（大地图）**不在这里**——大地图是 modal（打开即暂停），暂停后 HUD 被冻结
## 收不到 _input，用 M 关不掉它；所以 M 交给 UIManager._input（process_mode=ALWAYS）。
func _input(event: InputEvent) -> void:
	# Tab 切换背包显示/隐藏
	if event.is_action_pressed("ui_tab"):
		_toggle_inventory()
	
	# C 切换合成界面显示/隐藏（大纲 3.4）
	if event.is_action_pressed("toggle_crafting"):
		_toggle_crafting()
		get_viewport().set_input_as_handled()

	# B 切换装备界面显示/隐藏（大纲 3.4 装备系统）
	if event.is_action_pressed("toggle_equipment"):
		_toggle_equipment()
		get_viewport().set_input_as_handled()
	
	# ESC 不在这里处理：交给 UIManager 统一裁决
	# （有面板就关栈顶，没有才开暂停菜单），避免多处监听互相打架。

	# 数字键 1-9 选择快捷栏槽位（大纲 5.2）
	for i in range(9):
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			_select_hotbar(i)
			get_viewport().set_input_as_handled()
			break

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
	# 残血滤镜：当前血量 / 最大血量 <= 阈值时持续红色暗角呼吸。
	# 与死亡滤镜（apply DEATH）共存：死亡的 _base 优先级更高，这里不会清掉死亡滤镜。
	var low := false
	if max_h > 0:
		low = (float(health) / float(max_h)) <= FilterSystem.LOW_HEALTH_RATIO
	FilterSystem.set_low_health(low)

## 更新电量显示（自身电量：内置电量角色才有）
## 调用方式：hud.update_power(current)
## 占位态（无电量）时数值不外露，所以统一交给 _refresh_power_row 决定文字
## @param power 当前电量值（0-100）
func update_power(power: int) -> void:
	current_power = power
	_refresh_power_row()

## 更新核心电量显示
## 调用方式：hud.update_core_power(current)
## 核心电量行只在装着带电池的核心时可见，文字刷新见 _refresh_core_row
## @param power 核心当前电量（0-100）
func update_core_power(power: int) -> void:
	current_core_power = power
	_refresh_core_row()

## 更新体温显示
## 调用方式：hud.update_temperature(current)
## @param temp 当前体温值
func update_temperature(temp: int) -> void:
	current_temperature = temp
	if _temperature_label:
		# 🌡 符号表示体温
		_temperature_label.text = "🌡 %d" % temp

## 更新饱食度显示
## 调用方式：hud.update_hunger(current)
## @param hunger 当前饱食度（0-100），越低越饿
func update_hunger(hunger: int) -> void:
	current_hunger = hunger
	if _hunger_label:
		# 🍖 符号表示饱食度
		_hunger_label.text = "🍖 %d" % hunger
		# 饥饿时染成橙色、见底时染成红色，不看数字也能察觉该吃东西了
		if hunger <= 0:
			_hunger_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.30))
		elif hunger <= 20:
			_hunger_label.add_theme_color_override("font_color", Color(1.0, 0.68, 0.35))
		else:
			_hunger_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))

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
	update_core_power(current_core_power)
	update_temperature(current_temperature)
	update_hunger(current_hunger)

# ============================================
# 私有方法 - UI设置与初始化
# ============================================

## 初始化所有UI组件的入口方法
## 调用顺序：锚点 -> 快捷栏 -> 状态栏 -> 右上角组合块 -> 死亡 UI -> 吐司
func _setup_ui() -> void:
	# 1. 设置控件全屏覆盖整个视口
	full_anchor()
	
	# 2. 创建底部快捷栏
	_create_hotbar()
	
	# 3. 创建状态栏面板（右上角组合块的下半、按钮组正下方）
	_create_status_panel()
	
	# 4. 右上角组合块：左列小地图+时钟、右列三个按钮
	_create_topright_cluster()

	# 5. 死亡 UI：居中底部的「你已死亡」+ 复活按钮（平时隐藏，玩家死亡才出现）
	_create_death_ui()

	# 6. 居中底部的轻提示条（物品使用被拒等短反馈，平时隐藏）
	_create_toast()

## 每帧刷新时钟文本（节流 0.25 秒一次）
func _process(delta: float) -> void:
	_clock_refresh_timer -= delta
	if _clock_refresh_timer <= 0.0:
		_clock_refresh_timer = 0.25
		_update_clock()
	# 推进滤镜/后处理过渡（死亡灰度、受击红闪、残血呼吸等都由 FilterSystem 驱动）
	FilterSystem.tick(delta)
	_update_death_ui(delta)
	_tick_toast(delta)

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
	
	# 定位：居中于**左列 + 中列**（中心 x≈398），y 634..710。
	# 为什么不是屏幕正中（640）：九宫格把右列下半给了装备栏，
	# 快捷栏压在左+中列下方才和草图一致（见本文件顶部的布局图）。
	# 用锚点而不是绝对像素：窗口缩放时自动跟随。
	# PRESET_CENTER_BOTTOM 把锚点设为 (0.5, 1, 0.5, 1)；
	# 左右锚点重合在中心时，必须 grow_horizontal = BOTH 才会对称向两侧扩展。
	hotbar_container.set_anchors_preset(Control.PRESET_CENTER_BOTTOM, false)
	hotbar_container.grow_horizontal = Control.GROW_DIRECTION_BOTH
	# offset_left == offset_right → 把"中心"从 640 平移到 398
	var hot_center_shift: float = (LEFT_COL_LEFT + MAP_COL_RIGHT) * 0.5 - 640.0
	hotbar_container.offset_left = hot_center_shift
	hotbar_container.offset_right = hot_center_shift
	hotbar_container.offset_top = HOTBAR_TOP - 720.0
	hotbar_container.offset_bottom = HOTBAR_BOTTOM - 720.0

	# 栏本身不收鼠标，只有槽位收；否则底部一整条会吞掉 3D 世界的点击。
	hotbar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 设置容器最小高度为80像素
	hotbar_container.custom_minimum_size = Vector2(0, 64)

	# 添加到 HUD 节点下
	add_child(hotbar_container)

	# 设置 z_index 确保快捷栏显示在其他UI之上
	hotbar_container.z_index = 100

	# 循环创建所有槽位
	for i in range(hotbar_slots):
		var slot = _create_hotbar_slot(i)
		_hotbar_slots.append(slot)
		hotbar_container.add_child(slot)

## 创建单个快捷栏槽位
## @param index 槽位索引（0表示数字键1，8表示数字键9）
## @return 创建的 ItemSlotUI 实例
func _create_hotbar_slot(index: int) -> ItemSlotUI:
	var slot = ItemSlotUI.new()
	slot.name = "HotbarSlot%d" % index
	slot.slot_index = index  # 记录索引，用于识别按下了哪个槽位
	slot.custom_minimum_size = Vector2(52, 52)  # 槽位大小 52x52（2026-09-24 缩小）
	# 容器本身高 76（HOTBAR_TOP..BOTTOM）而槽只有 52：不写这行 HBox 会把槽
	# 沿交叉轴拉伸成 52×76 的长方形。SHRINK_CENTER = 保持正方形 + 垂直居中。
	slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 来源标识 = "player"：快捷栏格就是背包的前 9 格（同一批数据），
	# 标成同一个来源，背包面板和快捷栏之间才能互相拖拽——
	# 之前留空，两边 source 字符串不相等，被当成"跨面板"而各自拒绝（2026-09-23 修）。
	slot.source_id = "player"
	# 原先没有连这根线，槽位纯装饰，点了毫无反应
	slot.clicked.connect(_on_hotbar_slot_clicked)
	# 左键拖拽放下：快捷栏格 = 背包前 9 格，拖拽即调换它们在背包中的位置
	slot.item_dropped.connect(_on_hotbar_slot_dropped)
	return slot

# ============================================
# 快捷栏 ↔ 背包 绑定
# ============================================

## 查找并绑定玩家背包
## 快捷栏只镜像背包的前 hotbar_slots 个槽位（0..8）。
## 玩家节点（"player" 组）在 _ready 时整棵子树已实例化，
## 直接取它的 Inventory 子节点即可，无需等 player._ready。
func _bind_inventory() -> void:
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_node("Inventory"):
		_inventory = player.get_node("Inventory")
		_connect_inventory_signals()
		_refresh_hotbar()

## 连接背包信号 → 更新对应快捷栏槽位
func _connect_inventory_signals() -> void:
	if _inventory == null:
		return
	if not _inventory.item_added.is_connected(_on_inv_item_added):
		_inventory.item_added.connect(_on_inv_item_added)
	if not _inventory.item_changed.is_connected(_on_inv_item_changed):
		_inventory.item_changed.connect(_on_inv_item_changed)
	if not _inventory.item_removed.is_connected(_on_inv_item_removed):
		_inventory.item_removed.connect(_on_inv_item_removed)
	if not _inventory.inventory_cleared.is_connected(_on_inv_cleared):
		_inventory.inventory_cleared.connect(_on_inv_cleared)

## 重新镜像全部快捷栏槽位（打开背包/初始化时调用）
func _refresh_hotbar() -> void:
	if _inventory == null:
		return
	for i in range(_hotbar_slots.size()):
		if i < _inventory.get_slot_count():
			_hotbar_slots[i].set_item(_inventory.get_item(i))
		else:
			_hotbar_slots[i].set_item(null)

## 背包新增物品
func _on_inv_item_added(_item: ItemInstance, slot: int) -> void:
	if slot >= 0 and slot < _hotbar_slots.size():
		_hotbar_slots[slot].set_item(_inventory.get_item(slot))

## 背包某槽位数量/物品变化
func _on_inv_item_changed(slot: int) -> void:
	if slot >= 0 and slot < _hotbar_slots.size():
		_hotbar_slots[slot].set_item(_inventory.get_item(slot))

## 背包移除物品（不确定槽位，整体刷新前 9 格）
func _on_inv_item_removed(_item_id: StringName, _count: int, _slot: int) -> void:
	_refresh_hotbar()

## 背包清空
func _on_inv_cleared() -> void:
	_refresh_hotbar()

# ----------------------------------------
# 状态栏面板相关
# ----------------------------------------

## 本局角色**开局**是否自带（内置）电量（大纲 v0.7 · 2.2.3：仅机器人为 true）。
## 只用来给电量行一个初值；装上 / 拆下核心后的真实状态由 PlayerVitals
## 通过 set_power_active() 推过来，所以这里读静态注册表就够，不必每帧查询。
func _has_embedded_power() -> bool:
	return CharacterRegistry.has_embedded_power(CharacterRegistry.get_active_id())


## 自身电量行「占位 ↔ 亮起」切换。由 PlayerVitals._push_hud() 在状态变化时调用。
## 只有内置电量（机器人）会亮起；冒险家 / 魔女没有自身电量，这行是占位。
func set_power_active(active: bool) -> void:
	if _power_row_active == active:
		return
	_power_row_active = active
	_refresh_status_rows()


## 核心电量行「隐藏 ↔ 显示」切换。装着带电池的核心时为 true。
func set_core_active(active: bool) -> void:
	if _core_row_active == active:
		return
	_core_row_active = active
	_refresh_status_rows()


## 按当前状态把两条电量行一起刷新（行数可能变化，所以顺带重算面板高度）
func _refresh_status_rows() -> void:
	_refresh_power_row()
	_refresh_core_row()
	_update_status_panel_size()


## 刷新"自身电量行"的文字与配色。
## 亮起 = 真实数值 + 暖黄；占位 = "⚡ --" + 灰。
##
## 占位行只在**两条行都没有**时出现（没有自身电量、也没有核心）：
## 此时保留这一行是为了维持"未启用"的既有观感；
## 有核心行时自身行直接隐藏，免得面板上挂着一个没意义的 "⚡ --"。
func _refresh_power_row() -> void:
	if _power_label == null:
		return
	_power_label.visible = _power_row_active or not _core_row_active
	if _power_row_active:
		_power_label.text = "⚡ %d" % current_power
		_power_label.add_theme_color_override("font_color", POWER_ROW_ACTIVE_COLOR)
	else:
		_power_label.text = "⚡ --"
		_power_label.add_theme_color_override("font_color", POWER_ROW_IDLE_COLOR)


## 刷新"核心电量行"。没有核心时整行隐藏（不是占位）：
## 它的出现本身就代表"装上了核心"，留着空行反而让人以为坏了。
func _refresh_core_row() -> void:
	if _core_power_label == null:
		return
	_core_power_label.visible = _core_row_active
	if _core_row_active:
		_core_power_label.text = "🔋 %d" % current_core_power
		_core_power_label.add_theme_color_override("font_color", CORE_ROW_COLOR)


## 行数变化后重算面板高度。
##
## PanelContainer 的高度由内容撑开，但它的 size 不会自己重算 ——
## 创建时用 offset_bottom 定死的话，多一行就会溢出、少一行会留一大块空白。
## custom_minimum_size 钉住宽度，reset_size 只负责把高度收到内容尺寸。
func _update_status_panel_size() -> void:
	if _status_panel == null:
		return
	_status_panel.reset_size()
	# 状态栏是**右边缘锚定**（anchor_left = anchor_right = 1.0）。reset_size() 按
	# "左边缘不动"重算 offset_right —— 万一某行内容把宽度撑过 STATUS_WIDTH，
	# 右边缘就会被顶出视口。这里把两条 offset 重新钉回贴边位置（幂等）。
	_status_panel.offset_right = -RIGHT_MARGIN
	_status_panel.offset_left = -(STATUS_WIDTH + RIGHT_MARGIN)


## 创建状态栏面板（右上角组合块的右列、按钮组正下方）
## 显示内容：电量⚡（仅机器人）、生命值♥、体温🌡、饱食度🍖
## 面板采用半透明黑色背景，圆角设计
func _create_status_panel() -> void:
	# 创建面板容器
	_status_panel = PanelContainer.new()
	var panel := _status_panel
	panel.name = "StatusPanel"
	
	# 位置：贴着**视口右边缘**、三个按钮正下方（1280 宽视口下即 x 1110..1270、y 126..）。
	# 走「右边缘锚定」（anchor_left = anchor_right = 1.0 + 负 offset）而不是写死绝对 x，
	# 这样界面缩放把逻辑视口缩小时它会跟着往里收，不会被裁到屏幕外。
	panel.anchor_left = 1.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -(STATUS_WIDTH + RIGHT_MARGIN)
	panel.offset_right = -RIGHT_MARGIN
	panel.offset_top = STATUS_TOP
	# 高度**不写死**：状态栏有 4~5 行（核心电量行可有可无），
	# 由 _update_status_panel_size() 按内容收；这里只钉住宽度。
	panel.custom_minimum_size = Vector2(STATUS_WIDTH, 0)

	# 面板只是显示，不参与点击，否则右列一片区域会挡住 3D 操作
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	panel.z_index = 100  # 确保在最上层
	
	# 创建半透明黑色背景样式
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)  # RGBA: 黑色60%透明
	style.set_corner_radius_all(8)  # 圆角半径8像素
	style.set_content_margin_all(STATUS_PAD)
	panel.add_theme_stylebox_override("panel", style)
	
	add_child(panel)
	
	# 创建垂直布局容器，使标签垂直排列
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", STATUS_ROW_SEP)
	panel.add_child(vbox)
	
	# ----- 自身电量标签（占位或真实数值）-----
	# 大纲 v0.7 · 2.2.3：电量默认只有机器人有，其余角色靠装入「动力核心」获得。
	# 这一行代表"**自身**电量"（机械身体自带的电量，只有机器人有）：
	#   机器人 → 常驻显示真实电量
	#   其余角色 → 灰暗占位 "⚡ --"（有核心行时整行隐藏，避免挂一个没意义的占位）
	# 两块电池是分开的两行，核心那行见下方 _core_power_label。
	_power_label = Label.new()
	_power_label.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	vbox.add_child(_power_label)

	# ----- 核心电量标签（没有核心时整行隐藏）-----
	# 核心是独立单位，电量属于它自己：装上一枚核心就多出这一行，
	# 拆下来这行就消失。它的可见性由 PlayerVitals._push_hud() 推过来。
	_core_power_label = Label.new()
	_core_power_label.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	_core_power_label.add_theme_color_override("font_color", CORE_ROW_COLOR)
	vbox.add_child(_core_power_label)

	_power_row_active = _has_embedded_power()
	
	# ----- 生命值标签 -----
	_health_label = Label.new()
	_health_label.text = "♥ %d/%d" % [current_health, max_health]
	_health_label.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	vbox.add_child(_health_label)
	
	# ----- 体温标签 -----
	_temperature_label = Label.new()
	_temperature_label.text = "🌡 %d" % current_temperature
	_temperature_label.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	vbox.add_child(_temperature_label)

	# ----- 饱食度标签 -----
	_hunger_label = Label.new()
	_hunger_label.text = "🍖 %d" % current_hunger
	_hunger_label.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	vbox.add_child(_hunger_label)

	# 所有行都建好之后再统一刷一次：行数（有没有核心那行）决定面板高度，
	# 早于最后一行调用 reset_size 会量到不完整的内容尺寸。
	_refresh_status_rows()

# 注：右下角（x 794..1270、y 648..700）原先有一行操作提示 Label（ControlHints），
# 2026-09-24 按用户要求**删掉**——那条带子让给了装备栏（RECT_EQUIPMENT 现在用到 y=710）。
# 按键说明改在暂停菜单 / 大纲.md 里查，HUD 上不再常驻提示文字。

# ----------------------------------------
# 昼夜时钟相关
# ----------------------------------------

## 从昼夜节点读取时间并刷新时钟文本
## 昼夜节点按 "day_night" 组查找（HUD 先于/后于它 ready 都能自愈）
func _update_clock() -> void:
	if _day_night == null or not is_instance_valid(_day_night):
		_day_night = get_tree().get_first_node_in_group("day_night")
		if _day_night == null or _clock_label == null:
			return
	if _clock_label == null:
		return
	var icon := "🌙" if _day_night.is_night() else "☀"
	_clock_label.text = "第 %d 天  %02d:%02d  %s" % [
		_day_night.day,
		int(_day_night.hour),
		int(fmod(_day_night.hour, 1.0) * 60.0),
		icon,
	]

# ----------------------------------------
# 右上角按钮相关
# ----------------------------------------

## 右上角组合块的左半：小地图（常驻）+ 正下方时钟
##
## 布局（2026-09-24 二次改版，用户要求"整体放到屏幕右上角"）：
##   [小地图]  [ 暂停 / 大地图 / 小地图开关 ]   ← 按钮列（x 1110..1270）
##   [ 时间 ]  [       状态栏               ]   ← 见 _create_status_panel
##
## 小地图列**紧贴按钮列的左侧**（按钮列自己贴视口右边缘）：
##   右边缘 = 按钮列左边缘 1110 − BLOCK_GAP(8) = 1102
##   左边缘 = 1102 − 212（MinimapUI.panel_width）= 890
## 列底 = MARGIN(10) + 232 + 4 + 28 = CLUSTER_BOTTOM(274)，
## 装备栏为了避让这一列，顶部下移到 370（右列现在可以一路用到 710）。
## ⚠ 这一列也必须**跟着按钮列一起贴右边缘**（anchor_left = anchor_right = 1.0），
## 否则界面缩放把视口缩小时按钮列左移、小地图却钉在原地，两者会叠在一起。
func _create_topright_cluster() -> void:
	var map_w := MinimapUI.panel_width()
	var map_h := MinimapUI.panel_height()
	var sep := 4.0
	var clock_h := 28.0
	# 小地图列贴住按钮列的左侧（按钮列自己贴视口右边缘，见 _create_button_column）
	var map_offset_right: float = -(BTN_W + BLOCK_GAP + RIGHT_MARGIN)

	var map_col := VBoxContainer.new()
	map_col.name = "TopRightMap"
	map_col.anchor_left = 1.0
	map_col.anchor_top = 0.0
	map_col.anchor_right = 1.0
	map_col.anchor_bottom = 0.0
	map_col.offset_left = map_offset_right - map_w
	map_col.offset_right = map_offset_right
	map_col.offset_top = MARGIN
	map_col.offset_bottom = MARGIN + map_h + sep + clock_h
	map_col.add_theme_constant_override("separation", int(sep))
	# 容器本身不收鼠标：空白处照样能点到 3D 世界，只有按钮自己收点击
	map_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_col.z_index = 100
	add_child(map_col)

	# 固定占位：小地图隐藏时它仍占同样尺寸，时钟不会上下跳
	_map_slot = Control.new()
	_map_slot.name = "MapSlot"
	_map_slot.custom_minimum_size = Vector2(map_w, map_h)
	map_col.add_child(_map_slot)

	_minimap = MinimapUI.new()
	_minimap.name = "Minimap"
	_map_slot.add_child(_minimap)

	_clock_label = Label.new()
	_clock_label.name = "DayClock"
	_clock_label.text = ""
	_clock_label.custom_minimum_size = Vector2(map_w, clock_h)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 白字黑描边，亮暗天色下都看得清
	_clock_label.add_theme_font_size_override("font_size", 16)
	_clock_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_clock_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_clock_label.add_theme_constant_override("outline_size", 4)
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_col.add_child(_clock_label)

	_create_button_column()


## 右上角组合块的右半：暂停 / 大地图 / 小地图开关竖排，**贴着视口右边缘**
## （1280 宽视口下即 x 1110..1270）
## 状态栏接在这三个按钮正下方（见 _create_status_panel；y 起点即 STATUS_TOP）。
func _create_button_column() -> void:
	_topright = VBoxContainer.new()
	_topright.name = "TopRightButtons"
	# 右边缘锚定：视口被界面缩放缩小时跟着往里收，不会被裁
	_topright.anchor_left = 1.0
	_topright.anchor_top = 0.0
	_topright.anchor_right = 1.0
	_topright.anchor_bottom = 0.0
	_topright.offset_left = -(BTN_W + RIGHT_MARGIN)
	_topright.offset_right = -RIGHT_MARGIN
	_topright.offset_top = MARGIN
	_topright.offset_bottom = BTN_COL_BOTTOM
	_topright.add_theme_constant_override("separation", int(BTN_SEP))
	_topright.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_topright.z_index = 100
	add_child(_topright)

	_menu_button = _create_button("暂停", BTN_W)
	_menu_button.pressed.connect(_on_menu_button_pressed)
	_topright.add_child(_menu_button)

	_bigmap_button = _create_button("大地图", BTN_W)
	_bigmap_button.pressed.connect(_on_bigmap_button_pressed)
	_topright.add_child(_bigmap_button)

	_minimap_button = _create_button("小地图", BTN_W)
	_minimap_button.pressed.connect(_on_minimap_button_pressed)
	_topright.add_child(_minimap_button)

	_update_minimap_button_text()

## 创建通用按钮
## @param text 按钮显示文字
## @param width 按钮最小宽度
## @return 创建的 Button 实例
func _create_button(text: String, width: float = 90.0) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(width, BTN_H)  # 最小尺寸 宽x32（BTN_H）
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT   # 文字左对齐
	# 关键：HUD 按钮绝不参与键盘聚焦。
	# Button 默认 focus_mode = FOCUS_ALL，而窗口一获得焦点 Godot 就会自动聚焦
	# 树里第一个可聚焦控件（正好是这个小地图按钮）。被聚焦的按钮会把空格/回车
	# （内置 ui_accept）当成"点击"——于是按空格采集时会顺带打开小地图。
	# 设为 FOCUS_NONE 只影响键盘导航，鼠标点击照常生效。
	btn.focus_mode = Control.FOCUS_NONE
	return btn

# ----------------------------------------
# 死亡 / 复活 UI 相关
# ----------------------------------------

## 创建死亡 UI：屏幕居中底部、平时隐藏，玩家死亡后出现 5 秒倒计时 + 复活按钮。
## 倒计时未到时按钮显示「复活 (N)」且禁用；到 0 才可点，点了回重生点满状态。
## 设计约定（用户 2026-09-13）：按钮只在玩家死亡后可见，5 秒后才可点击。
func _create_death_ui() -> void:
	_death_panel = VBoxContainer.new()
	_death_panel.name = "DeathPanel"
	_death_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	# 居中底部，放在快捷栏/操作提示之上（提示占用 -140~-110，这里 -200~-110）
	_death_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM, false)
	_death_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_death_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_death_panel.offset_top = -240
	_death_panel.offset_bottom = -150
	# 容器不收鼠标（空白区域照样能点 3D），只有按钮自己收点击
	_death_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_panel.visible = false
	_death_panel.z_index = 200
	add_child(_death_panel)

	_death_label = Label.new()
	_death_label.name = "DeathLabel"
	_death_label.text = "你已死亡"
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.add_theme_font_size_override("font_size", 24)
	_death_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	_death_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_death_label.add_theme_constant_override("outline_size", 4)
	_death_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_label.custom_minimum_size = Vector2(0, 30)
	_death_panel.add_child(_death_label)

	_revive_button = Button.new()
	_revive_button.name = "ReviveButton"
	_revive_button.text = "复活"
	_revive_button.custom_minimum_size = Vector2(220, 52)
	_revive_button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	# HUD 按钮统一不抢键盘焦点（同 _create_button 的说明）
	_revive_button.focus_mode = Control.FOCUS_NONE
	_revive_button.disabled = true
	_revive_button.pressed.connect(_on_revive_pressed)
	_death_panel.add_child(_revive_button)

## 每帧同步死亡 UI：死亡态才显示，倒计时归零后按钮才可点。
func _update_death_ui(delta: float) -> void:
	if _death_panel == null:
		return
	if not RespawnSystem.dead:
		if _death_panel.visible:
			_death_panel.visible = false
		return
	_death_panel.visible = true
	RespawnSystem.tick(delta)
	if RespawnSystem.can_revive():
		_revive_button.disabled = false
		_revive_button.text = "复活"
	else:
		_revive_button.disabled = true
		_revive_button.text = "复活 (%d)" % int(ceil(RespawnSystem.countdown))

## 点「复活」：仅在倒计时结束后有效；把玩家传送回重生点并恢复满状态。
func _on_revive_pressed() -> void:
	if not RespawnSystem.can_revive():
		return
	var player = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var phys = player.get_node_or_null("Physics")
	if phys != null and phys.has_method("revive"):
		phys.call("revive")
	_death_panel.visible = false

# ----------------------------------------
# 轻提示条（Toast）
#
# 用途：物品使用被拒等原因的短反馈。项目里原本没有通用提示组件，
# 而"右键了却什么都没发生"对玩家等同于 bug，所以补一个最小的。
# 位置沿用死亡 UI 那套已验证的锚点写法：CENTER_BOTTOM + 显式 offset
#（偏移量算清楚，不依赖 _ready 时的尺寸），放在死亡面板更下方，两者不重叠。
# ----------------------------------------

## 创建轻提示 Label（平时隐藏）
func _create_toast() -> void:
	_toast_label = Label.new()
	_toast_label.name = "ToastLabel"
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", 16)
	_toast_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.4))
	_toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_toast_label.add_theme_constant_override("outline_size", 4)
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_label.custom_minimum_size = Vector2(0, 26)

	# 九宫格里屏幕正下方已经被信息面板和快捷栏占满，吐司挪到**中列的空档**：
	# x 510..786、y 556..582（小地图/时钟之下、快捷栏之上，这一段没有面板）。
	_toast_label.anchor_left = 0.0
	_toast_label.anchor_top = 0.0
	_toast_label.anchor_right = 0.0
	_toast_label.anchor_bottom = 0.0
	_toast_label.offset_left = MAP_COL_LEFT
	_toast_label.offset_right = MAP_COL_RIGHT
	_toast_label.offset_top = 556
	_toast_label.offset_bottom = 582

	_toast_label.z_index = 150
	_toast_label.visible = false
	add_child(_toast_label)


## 显示一条轻提示（默认 2 秒后自动消失）
func show_toast(text: String, duration: float = 2.0) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	_toast_label.visible = true
	_toast_timer = duration


## 每帧推进提示的倒计时
func _tick_toast(delta: float) -> void:
	if _toast_label == null or not _toast_label.visible:
		return
	_toast_timer -= delta
	if _toast_timer <= 0.0:
		_toast_label.visible = false


# ----------------------------------------
# 按钮信号回调
# ----------------------------------------

## 小地图按钮被按下时的回调
func _on_minimap_button_pressed() -> void:
	_toggle_minimap()

## 大地图按钮被按下时的回调
func _on_bigmap_button_pressed() -> void:
	_toggle_big_map()

## 菜单按钮被按下时的回调
func _on_menu_button_pressed() -> void:
	_open_menu()

# ============================================
# 私有方法 - 交互逻辑
# ============================================

## 选中某个快捷栏槽位：高亮它并对外发信号
## @param index 槽位索引（0-8）
func _select_hotbar(index: int) -> void:
	if index < 0 or index >= _hotbar_slots.size():
		return
	# 取消旧高亮
	if _selected_hotbar >= 0 and _selected_hotbar < _hotbar_slots.size():
		_hotbar_slots[_selected_hotbar].set_selected(false)
	_selected_hotbar = index
	_hotbar_slots[index].set_selected(true)
	hotbar_slot_pressed.emit(index)

## 快捷栏槽位被鼠标点击的回调（由 ItemSlotUI.clicked 触发）
##   左键：选中（高亮，供数字键逻辑一致）
##   右键：直接使用该格中"可用"的物品（电池→回电等），完成快捷栏快速使用闭环
func _on_hotbar_slot_clicked(slot_index: int, button: int) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		_use_hotbar_item(slot_index)
	else:
		_select_hotbar(slot_index)

## 快捷栏槽位拖拽放下回调
## 快捷栏格与背包前 9 格是同一批数据；直接调 Inventory.move_item，
## 背包的信号会回头刷新快捷栏，无需手动同步。
## count > 0 时（Ctrl 拖拽）只搬这么多个，走 transfer_between 的拆堆路径。
func _on_hotbar_slot_dropped(from_slot: int, to_slot: int, count: int) -> void:
	if _inventory == null or from_slot == to_slot:
		return
	if count > 0:
		Inventory.transfer_between(_inventory, from_slot, _inventory, to_slot, count)
	else:
		_inventory.move_item(from_slot, to_slot)

## 使用快捷栏指定槽位的物品
## 与 InventoryUI.use_item 同源：经 ItemEffects 施加 use_effect，成功则按 consume_on_use 扣 1。
func _use_hotbar_item(slot_index: int) -> void:
	if _inventory == null:
		return
	var item = _inventory.get_item(slot_index)
	if item == null or item.data == null:
		return

	# 建筑类物品：右键 = 进入放置模式（和背包里一致）
	if BuildingSystem.is_building(item.data.item_id):
		_try_place_building(item.data.item_id)
		return

	# can_use 同时要求 usable 且 use_effect 非空，避免"可点但无效果"的假提示
	if not ItemEffects.can_use(item.data):
		return

	# 专属物品的使用权限（黑名单 / 白名单）：不满足时明确说明原因。
	# 没有这条反馈的话右键毫无反应，玩家只会当成 bug。
	var denied: String = ItemEffects.access_denied_reason(item.data)
	if not denied.is_empty():
		show_toast(denied)

	var player := get_tree().get_first_node_in_group("player")
	var applied := ItemEffects.apply(item.data, player)
	if applied:
		if item.data.consume_on_use:
			item.remove(1)
			if item.is_empty():
				_inventory.clear_slot(slot_index)
			else:
				_inventory.set_slot(slot_index, item)

## 进入建筑放置模式（与 InventoryUI._try_place_building 同逻辑，
## 这里不需要关面板——HUD 快捷栏本来就只占屏幕底部一小条）
func _try_place_building(item_id: StringName) -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		return
	var placer := player.get_node_or_null("BuildPlacer")
	if placer != null and placer.has_method("start_placement"):
		placer.call("start_placement", item_id)


## 切换背包显示/隐藏
## 通过查找 InventoryUI 节点并调用其 toggle() 方法
func _toggle_inventory() -> void:
	# 交给 UIManager 统一托管：面板的创建、显隐、Esc 层级都在那里。
	# 这里不再自己找节点——原先写死 /root/Map/... 导致 Tab 完全没反应。
	UIManager.toggle_inventory()
	emit_signal("inventory_toggled", UIManager.is_open(UIManager.INVENTORY_PANEL))

## 切换小地图显示/隐藏
## 常驻组件：只切 visible，不走 UIManager 面板栈（Esc 关面板时不会误关它）
## 注意：小地图只有这一个入口（按钮），不再绑快捷键——M 键归大地图。
func _toggle_minimap() -> void:
	if _minimap == null:
		return
	_minimap.visible = not _minimap.visible
	_update_minimap_button_text()
	emit_signal("minimap_toggled")

## 打开/关闭全屏大地图（M 键 / "大地图"按钮）
## 交给 UIManager 托管：面板的创建、Esc 层级、显隐都在那里
func _toggle_big_map() -> void:
	UIManager.toggle_panel(UIManager.BIGMAP_PANEL)

## 让按钮文字反映当前状态，否则"点了一下没反应"看起来像坏了
func _update_minimap_button_text() -> void:
	if _minimap_button == null or _minimap == null:
		return
	_minimap_button.text = "小地图 开" if _minimap.visible else "小地图 关"

## 切换合成界面显示/隐藏（C 键，面板由 UIManager 托管）
func _toggle_crafting() -> void:
	UIManager.toggle_crafting()


## 切换装备界面显示/隐藏（B 键，面板由 UIManager 托管）
func _toggle_equipment() -> void:
	UIManager.toggle_equipment()

## 打开游戏菜单（暂停菜单会暂停游戏，由 UIManager 负责）
func _open_menu() -> void:
	UIManager.open_panel(UIManager.PAUSE_PANEL)
	emit_signal("menu_requested")

# ============================================
# 工具方法
# ============================================

## 打印当前HUD状态（调试用）
## 可在开发时调用查看各状态值
func debug_print_status() -> void:
	if not DebugConfig.is_enabled(DebugConfig.CAT_UI):
		return
	print("========== HUD Status ==========")
	print("Health: %d/%d" % [current_health, max_health])
	print("Power: %d" % current_power)
	print("Temperature: %d" % current_temperature)
	print("Hotbar Slots: %d" % hotbar_slots)
	print("================================")
