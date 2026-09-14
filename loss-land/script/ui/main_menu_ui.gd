# script/ui/main_menu_ui.gd
# ============================================
# 主菜单（独立场景 tscn/main_menu.tscn 的根节点）
#
# 三个界面：
#   根菜单    ：继续游戏 / 选择存档 / 新建游戏 / 设置 / 退出游戏
#   选择存档  ：存档列表（载入 / 删除）+ 返回
#   新建游戏  ：输入存档名 + 下一步（选角色）+ 返回
#   选择角色  ：角色卡片列表（数据来自 CharacterRegistry）+ 开始游戏 + 返回
#   设置      ：直接复用游戏内的 SettingsUI（经本场景里的 UIManager 打开），
#               不另写一份音量/全屏逻辑；它的"返回"会关掉自己回到主菜单。
#
# 当前阶段（2026-09-12 起接真存档）：
#   存档列表实时读 user://saves/（SaveManager.list_slots）；
#   "新建游戏" = SaveManager.create_slot（立刻落一个 meta-only 文件并设为激活槽）；
#   "载入/继续" = SaveManager.request_load 登记 pending，进游戏场景后由
#   ResourceManager 延迟应用；存档内容（玩家/资源/时间/建筑）的收集与恢复
#   全部在 SaveManager 里，本脚本只管界面与跳转。
#
# 布局坑（与 pause_menu_ui.gd / settings_ui.gd 同一条）：
#   _ready 里 set_anchors_preset 拿不到尺寸，必须显式赋 size；
#   面板居中**不要自己算 offset**：_ready 时子节点的最小尺寸还没稳定
#   （autowrap 的 Label 在宽度为 0 时会报出虚高的最小高度），算一次就钉死了 →
#   统一挂到 CenterContainer 下，由它负责居中并在尺寸变化后自动重算。
# ============================================

extends Control

# 界面编号（_show_screen 的参数）
const SCREEN_ROOT := 0
const SCREEN_LOAD := 1
const SCREEN_NEW := 2
const SCREEN_CHAR := 3

## 游戏主场景：点"开始游戏/继续游戏"时切过去
const GAME_SCENE := "res://tscn/map.tscn"

## 存档槽上限（0 = 不限制，用户要求可无限新建）
@export var slot_limit: int = 0

var _bg: ColorRect
var _screens: Array[Control] = []

var _screen_root: Control
var _screen_load: Control
var _screen_new: Control
var _screen_char: Control

var _continue_btn: Button
var _slot_list: VBoxContainer
var _name_edit: LineEdit
var _hint_label: Label

# ---- 选择角色 ----
## 当前选中的角色 id（进游戏时传给 SaveManager.create_slot）
var _selected_char_id: String = ""
## 角色卡片：[{ "panel": PanelContainer, "id": String }]
var _char_cards: Array[Dictionary] = []
## 卡片正常 / 选中两套样式（选中态高亮边框，不用改按钮状态机）
var _card_style_normal: StyleBoxFlat
var _card_style_selected: StyleBoxFlat

## 卡片几何。说明文字是 autowrap 的 Label，**必须给它一个正数的确定宽度**：
## 宽度还是 0 时引擎按 0 算换行，报出的最小高度会虚高到几百像素，
## 把整张卡、整个面板一起撑高 → 面板偏移/上下被切。
const CARD_WIDTH: int = 232
## 卡片样式的内容内边距（StyleBoxFlat.set_content_margin_all 的值）。
## 12→10：6 张卡 3 列 2 行后，卡片高度直接决定面板总高，必须压住（见 _build_char_screen）。
const CARD_PADDING: int = 10
## 卡片内部可用宽度 = 卡宽 - 左右内边距
const CARD_CONTENT_WIDTH: int = CARD_WIDTH - CARD_PADDING * 2
## 卡片头像区高度。104→72：每张卡省 32px，两行省 64px，是"面板塞进 720 视口"最大的单项。
const PORTRAIT_H: int = 72


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 场景里根节点是"铺满锚点"（anchor_right/bottom = 1），这种非对称锚点下
	# _ready 里再显式赋 size 会被引擎覆盖并刷一条
	# "Nodes with non-equal opposite anchors will have their size overridden" 警告。
	# 尺寸本来就由 on_viewport_resized 自己算，统一改成左上锚点。
	anchor_right = 0.0
	anchor_bottom = 0.0

	# 本场景里也挂了 UIManager（为了复用设置面板），但主菜单没有"暂停"，
	# 关掉它的 Esc → 暂停菜单 行为，否则按 Esc 会凭空弹出游戏内菜单。
	if UIManager.instance != null:
		UIManager.instance.esc_opens_pause = false

	_build()
	on_viewport_resized()
	get_viewport().size_changed.connect(on_viewport_resized)
	_show_screen(SCREEN_ROOT)
	# 鼠标驱动 UI：统一关键盘聚焦（Button 默认 FOCUS_ALL 会吞空格/回车）
	UIManager.disable_keyboard_focus(self)


# ============================================
# 界面搭建
# ============================================

func _build() -> void:
	_bg = ColorRect.new()
	_bg.name = "Background"
	_bg.color = Color(0.05, 0.07, 0.13, 1.0)
	add_child(_bg)

	_build_root_screen()
	_build_load_screen()
	_build_new_screen()
	_build_char_screen()

	_screens = [_screen_root, _screen_load, _screen_new, _screen_char]


## 根菜单：标题 + 五个入口
func _build_root_screen() -> void:
	_screen_root = _make_screen("RootScreen")
	var panel := _make_panel(320, _screen_root)
	var vbox := _vbox(panel)

	var title := Label.new()
	title.text = "失落之岛"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	vbox.add_child(title)

	var sub := Label.new()
	sub.text = "L O S S   L A N D"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	vbox.add_child(sub)

	vbox.add_child(HSeparator.new())

	# 没有存档时禁用（并给出原因），比点了没反应清楚
	_continue_btn = _make_button("继续游戏", _on_continue)
	vbox.add_child(_continue_btn)

	vbox.add_child(_make_button("选择存档", _on_open_load))
	vbox.add_child(_make_button("新建游戏", _on_open_new))
	vbox.add_child(_make_button("设置", _on_settings))
	vbox.add_child(_make_button("退出游戏", _on_quit))


## 选择存档：可滚动的存档列表 + 返回
func _build_load_screen() -> void:
	_screen_load = _make_screen("LoadScreen")
	var panel := _make_panel(460, _screen_load)
	var vbox := _vbox(panel)

	var title := Label.new()
	title.text = "选择存档"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	# 状态提示（"暂无存档" / "槽位已满"等）
	_hint_label = Label.new()
	_hint_label.text = ""
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_hint_label)

	# 存档不限量 → 列表要能滚
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, 240)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_slot_list = VBoxContainer.new()
	_slot_list.name = "SlotList"
	_slot_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_slot_list)

	vbox.add_child(HSeparator.new())
	vbox.add_child(_make_button("返回", _on_back_to_root))
	vbox.add_child(_make_button("新建存档", _on_open_new))


## 新建游戏：存档名输入 + 开始
func _build_new_screen() -> void:
	_screen_new = _make_screen("NewScreen")
	var panel := _make_panel(400, _screen_new)
	var vbox := _vbox(panel)

	var title := Label.new()
	title.text = "新建游戏"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	var name_label := Label.new()
	name_label.text = "存档名称"
	vbox.add_child(name_label)

	_name_edit = LineEdit.new()
	_name_edit.name = "NameEdit"
	_name_edit.placeholder_text = "留空则自动命名"
	_name_edit.custom_minimum_size = Vector2(0, 36)
	vbox.add_child(_name_edit)

	vbox.add_child(HSeparator.new())
	vbox.add_child(_make_button("下一步：选择角色", _on_open_char))
	vbox.add_child(_make_button("返回", _on_back_to_root))


## 选择角色：遍历 CharacterRegistry.CHARACTERS 动态生成卡片。
## 加新角色不用动这里——注册表里多一项，面板就多一张卡。
func _build_char_screen() -> void:
	_screen_char = _make_screen("CharScreen")
	var panel := _make_panel(780, _screen_char)
	var vbox := _vbox(panel)

	var title := Label.new()
	title.text = "选择角色"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	var sub := Label.new()
	sub.text = "正式三位（上排）的生命、移速、攻击完全相同 —— 差别在专属系统（电量 / 制作栏）；下排为开发期测试角色。"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# autowrap 的 Label 必须给确定的正宽度，否则最小高度会虚高（见 desc_label 注释）
	sub.custom_minimum_size = Vector2(700, 0)
	sub.max_lines_visible = 2
	sub.add_theme_font_size_override("font_size", 13)
	vbox.add_child(sub)

	# 网格而不是单行 HBox：CHARACTERS 现在是 6 个（3 正式 + 3 测试），
	# 一行排下去 6×232 会远超面板宽度被裁掉。3 列刚好 724px，塞得进 780 的面板。
	# ⚠ 高度预算（唯一硬约束：视口固定 1280×720）：
	#   卡高 ≈ 内边距20 + 头像72 + 名22 + 特性16 + 说明48 + 数值48 + 间隔20 ≈ 246
	#   两行 + 行距10 ≈ 502；加标题 28 + 副标题 19 + 分隔线 4 + 两个按钮 40×2
	#   + vbox 间距与面板边距 ≈ 660 —— 若再加卡片（第 7 个角色）必须改滚动，
	#   不能继续压高度。
	var row := GridContainer.new()
	row.columns = 3
	row.add_theme_constant_override("h_separation", 14)
	row.add_theme_constant_override("v_separation", 10)
	vbox.add_child(row)

	_card_style_normal = _make_card_style(false)
	_card_style_selected = _make_card_style(true)
	_char_cards.clear()
	for item in CharacterRegistry.CHARACTERS:
		var defn: Dictionary = item
		row.add_child(_make_char_card(defn))

	vbox.add_child(HSeparator.new())
	vbox.add_child(_make_button("开始游戏", _on_create_and_start, 40))
	vbox.add_child(_make_button("返回", _on_back_to_new, 40))


## 单张角色卡片。
## 节点结构：PanelContainer（画底与边框）
##              ├─ VBoxContainer（内容，容器会自动撑满）
##              └─ Button（flat，撑满且在最上层 → 点整张卡任意位置都算选中）
func _make_char_card(defn: Dictionary) -> PanelContainer:
	var id := String(defn.get("id", ""))

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_WIDTH, 0)
	card.add_theme_stylebox_override("panel", _card_style_normal)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(content)

	var portrait := TextureRect.new()
	portrait.texture = _make_portrait(id)
	portrait.custom_minimum_size = Vector2(0, PORTRAIT_H)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# 像素画放大必须最近邻，否则头像糊成一团
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	content.add_child(portrait)

	var name_label := Label.new()
	name_label.text = String(defn.get("name", "?"))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 16)
	content.add_child(name_label)

	var trait_label := Label.new()
	trait_label.text = String(defn.get("trait", ""))
	trait_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	trait_label.add_theme_font_size_override("font_size", 12)
	trait_label.add_theme_color_override("font_color", Color(0.6, 0.78, 1.0, 1.0))
	content.add_child(trait_label)

	var desc_label := Label.new()
	desc_label.text = String(defn.get("desc", ""))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# autowrap 的 Label 必须给两样东西，否则最小高度不受控：
	#   1) 一个**确定的正宽度**（宽度还是 0 时引擎按 0 算换行，一行一个字，
	#      最小高度能虚高到几百像素 → 卡片、面板一起被撑高 → 面板偏移）；
	#   2) `max_lines_visible`：Label::_update_visible() 里行数会被这个值夹住，
	#      最小高度最多只算 3 行，兜住任何超长文案。
	# 注意别写 `overrun_behavior`——Godot 4 暴露给 GDScript 的属性名是
	# `text_overrun_behavior`（`overrun_behavior` 只是 C++ 里的成员名），
	# 写错会在 _ready 直接抛错，主菜单整个搭不起来（灰屏）。
	# （官方文档另建议给 autowrap 的 Label 配 `custom_maximum_size.x` 让换行宽度
	#   彻底稳定；这里 `max_lines_visible` 已经把最小高度夹住，就不多引一个属性了。）
	desc_label.custom_minimum_size = Vector2(CARD_CONTENT_WIDTH, 48)
	desc_label.max_lines_visible = 3
	desc_label.add_theme_font_size_override("font_size", 12)
	content.add_child(desc_label)

	# 大纲 v0.7：三个正式角色**数值完全相同**，差异在"系统"。
	# 所以这里除了基础三围，重点显示「电量」与「专属制作栏」。
	# 电量一栏要区分两种语义（用户决策）：
	#   内置（机器人）→ 常驻显示、不可关闭
	#   外置（冒险家 / 魔女）→ 装入动力核心后解锁，不影响人物本身
	var st: Dictionary = CharacterRegistry.get_display_stats(id)
	var power_text: String = "无"
	if CharacterRegistry.has_embedded_power(id):
		power_text = "内置 %d（不可关）" % int(st.get("power", 0))
	elif CharacterRegistry.has_power(id):
		power_text = "有 %d" % int(st.get("power", 0))
	elif CharacterRegistry.get_craft_category(id) != &"":
		# 正式角色但默认没电量 → 可装入动力核心解锁（大纲 3.1.3）
		power_text = "外置（装核心解锁）"
	var craft_text: String = CharacterRegistry.get_craft_category_label(id)
	if craft_text.is_empty():
		craft_text = "—"
	var stats_label := Label.new()
	stats_label.text = "生命 %d    移速 ×%.2f\n攻击 ×%.2f    电量 %s\n专属制作 %s" % [
		int(st.get("health", 0)),
		float(defn.get("speed_mult", 1.0)),
		float(defn.get("attack_mult", 1.0)),
		power_text,
		craft_text,
	]
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats_label.add_theme_font_size_override("font_size", 12)
	stats_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9, 1.0))
	content.add_child(stats_label)

	# 点击热区：flat 按钮不画背景，只负责吃鼠标事件
	var hotspot := Button.new()
	hotspot.flat = true
	hotspot.focus_mode = Control.FOCUS_NONE
	hotspot.tooltip_text = "选择 %s" % String(defn.get("name", ""))
	# 正式版（ALL_UNLOCKED = false）只有 default_unlocked 的角色可选；
	# 开发期三者全开，这行恒为 false，不会有任何视觉变化。
	hotspot.disabled = not CharacterRegistry.is_selectable(id)
	hotspot.pressed.connect(_on_select_char.bind(id))
	card.add_child(hotspot)

	_char_cards.append({"panel": card, "id": id})
	return card


## 卡片样式：选中态加亮边框 + 提亮底色
func _make_card_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.15, 0.19, 0.29, 1.0) if selected else Color(0.09, 0.11, 0.18, 1.0)
	sb.set_border_width_all(3 if selected else 1)
	sb.border_color = Color(0.45, 0.72, 1.0, 1.0) if selected else Color(0.24, 0.29, 0.4, 1.0)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(CARD_PADDING)
	return sb


## 角色头像：从精灵表里裁一格待机首帧
func _make_portrait(id: String) -> AtlasTexture:
	var tex: Texture2D = CharacterRegistry.get_sprite(id)
	if tex == null:
		# 贴图缺失（新加的 .png 还没被编辑器导入）时退回默认角色，面板不至于开天窗
		tex = CharacterRegistry.get_sprite(CharacterRegistry.DEFAULT_ID)
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = CharacterRegistry.PORTRAIT_REGION
	return at


# ============================================
# 界面切换
# ============================================

func _show_screen(screen: int) -> void:
	for i in _screens.size():
		if _screens[i] != null:
			_screens[i].visible = (i == screen)
	if screen == SCREEN_ROOT:
		_refresh_continue_state()
	elif screen == SCREEN_LOAD:
		_refresh_slots()
	elif screen == SCREEN_CHAR:
		_refresh_char_selection()


func _on_back_to_root() -> void:
	_show_screen(SCREEN_ROOT)


func _on_back_to_new() -> void:
	_show_screen(SCREEN_NEW)


func _on_open_load() -> void:
	_show_screen(SCREEN_LOAD)


func _on_open_new() -> void:
	_show_screen(SCREEN_NEW)


## 进入选择角色界面：没选过（或选的 id 失效）就默认落在列表第一位
func _on_open_char() -> void:
	if CharacterRegistry.get_character(_selected_char_id).is_empty():
		var ids: Array = CharacterRegistry.all_ids()
		_selected_char_id = String(ids[0]) if not ids.is_empty() else CharacterRegistry.DEFAULT_ID
	_refresh_char_selection()
	_show_screen(SCREEN_CHAR)


func _on_select_char(id: String) -> void:
	_selected_char_id = id
	_refresh_char_selection()


## 选中态刷新：只换卡片样式，不重建节点（重建会丢焦点、也会闪）
func _refresh_char_selection() -> void:
	for entry in _char_cards:
		var panel: PanelContainer = entry.get("panel")
		if panel == null or not is_instance_valid(panel):
			continue
		var selected: bool = String(entry.get("id", "")) == _selected_char_id
		panel.add_theme_stylebox_override("panel",
			_card_style_selected if selected else _card_style_normal)


# ============================================
# 存档列表（实时读 user://saves/）
# ============================================

## 重建存档列表。每行 = 存档按钮（载入）+ 删除按钮
func _refresh_slots() -> void:
	if _slot_list == null:
		return
	# 清空：必须 remove_child + queue_free，只 queue_free 会留下旧节点
	for c in _slot_list.get_children():
		_slot_list.remove_child(c)
		c.queue_free()

	var slots := SaveManager.list_slots()

	# 显式加括号：% 的优先级容易和三元表达式搅在一起
	_hint_label.text = ("暂无存档，请先新建" if slots.is_empty() else "共 %d 个存档" % slots.size())

	for slot in slots:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_slot_list.add_child(row)

		var btn := Button.new()
		# meta-only 的新档（还没在游戏里保存过）照样能进，只是开局从头生成
		var tag := "" if bool(slot.get("has_world", false)) else "（新档）"
		# 存档行带上角色名，一眼能看出这档是谁（老存档没有该字段 → 留空不显示）
		var char_name: String = String(
			CharacterRegistry.get_character(String(slot.get("character_id", ""))).get("name", ""))
		var who := "" if char_name.is_empty() else ("  · %s" % char_name)
		btn.text = "%s%s%s    第 %d 天    %s" % [
			slot.get("name", "存档"), tag, who, int(slot.get("day", 1)), slot.get("saved_at", "")]
		btn.custom_minimum_size = Vector2(0, 40)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_load_slot.bind(int(slot.get("slot_id", -1))))
		row.add_child(btn)

		var del := Button.new()
		del.text = "删除"
		del.custom_minimum_size = Vector2(70, 40)
		del.pressed.connect(_on_delete_slot.bind(int(slot.get("slot_id", -1))))
		row.add_child(del)

	# 动态建出来的按钮也要关键盘聚焦
	UIManager.disable_keyboard_focus(_slot_list)


## 继续游戏：读保存时间最新的那条存档并进入游戏
func _on_continue() -> void:
	var slots := SaveManager.list_slots()
	if slots.is_empty():
		return
	var latest: Dictionary = slots[slots.size() - 1]
	DebugConfig.log_msg(DebugConfig.CAT_UI, "[主菜单] 继续游戏：%s",
		[latest.get("name", "存档")])
	SaveManager.request_load(int(latest.get("slot_id", -1)))
	_start_game()


func _on_load_slot(slot_id: int) -> void:
	if slot_id < 0:
		return
	DebugConfig.log_msg(DebugConfig.CAT_UI, "[主菜单] 载入存档槽 %d", [slot_id])
	SaveManager.request_load(slot_id)
	_start_game()


func _on_delete_slot(slot_id: int) -> void:
	if slot_id < 0:
		return
	DebugConfig.log_msg(DebugConfig.CAT_UI, "[主菜单] 删除存档槽 %d", [slot_id])
	SaveManager.delete_slot(slot_id)
	_refresh_slots()
	_refresh_continue_state()


## 新建存档并开始：槽位不限量，名称留空则自动命名。
## create_slot 会写 meta-only 文件并设为激活槽；首次"保存游戏"后才落世界数据。
func _on_create_and_start() -> void:
	if _name_edit == null:
		return
	var name := _name_edit.text.strip_edges()
	if name.is_empty():
		name = "存档 %d" % (SaveManager.list_slots().size() + 1)
	if slot_limit > 0 and SaveManager.list_slots().size() >= slot_limit:
		# 提示行在"选择存档"界面上，切过去玩家才看得见
		_hint_label.text = "槽位已满（上限 %d 个），请先删除旧存档" % slot_limit
		_show_screen(SCREEN_LOAD)
		return
	SaveManager.create_slot(name, true, _selected_char_id)
	DebugConfig.log_msg(DebugConfig.CAT_UI, "[主菜单] 新建存档：%s（角色 %s）",
		[name, CharacterRegistry.get_active_id()])
	_start_game()


## 没有存档时把"继续游戏"置灰并说明原因
func _refresh_continue_state() -> void:
	if _continue_btn == null:
		return
	var has_slots := not SaveManager.list_slots().is_empty()
	_continue_btn.disabled = not has_slots
	_continue_btn.text = "继续游戏（暂无存档）" if not has_slots else "继续游戏"


## 进入游戏：切到主场景（先解除暂停，避免暂停态下切场景出问题）
func _start_game() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_settings() -> void:
	# 复用游戏内设置面板：本场景挂了 UIManager，SettingsUI 的"返回"会关掉自己
	if UIManager.instance == null:
		DebugConfig.warn_msg(DebugConfig.CAT_UI, "[主菜单] 找不到 UIManager，设置面板不可用", [])
		return
	UIManager.open_panel(UIManager.SETTINGS_PANEL)


func _on_quit() -> void:
	get_tree().paused = false
	get_tree().quit()


# ============================================
# 布局工具（规避 _ready 里锚点算成 0x0 的坑）
# ============================================

## 一个界面 = 整屏 Control（挡住下层的鼠标事件）+ 一个 CenterContainer（负责把面板居中）。
## **居中交给 CenterContainer，不要自己算 offset**：面板的最小尺寸在 _ready 里并不可靠
## （autowrap 的 Label 在宽度还是 0 时，引擎会按宽度 0 算换行，报出一个虚高的最小高度），
## 手动算一次的 offset 会把这个错误尺寸永久钉死 → 面板整体偏移、上下被切。
## CenterContainer 会在子节点最小尺寸变化后自动重新居中。
func _make_screen(node_name: String) -> Control:
	var s := Control.new()
	s.name = node_name
	s.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(s)

	var holder := CenterContainer.new()
	holder.name = "Center"
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(holder)
	return s


## 面板统一挂到界面的 CenterContainer 下（尺寸与位置由它算）。
## parent 显式传入：不要靠"当前正在搭哪个界面"去猜，顺序一改就错位
func _make_panel(width: int, parent: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, 0)
	var holder := parent.get_node_or_null("Center")
	if holder != null:
		holder.add_child(panel)
	else:
		parent.add_child(panel)
	return panel


func _vbox(panel: PanelContainer) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)
	return vbox


func _make_button(text: String, callback: Callable, height: int = 44) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, height)
	btn.add_theme_font_size_override("font_size", 16)
	btn.pressed.connect(callback)
	return btn


## 全屏 + 居中：窗口变化时重算（UIManager 也会对已注册面板调同名方法）
func on_viewport_resized() -> void:
	var vp := get_viewport_rect().size
	size = vp
	position = Vector2.ZERO

	if _bg != null:
		_bg.size = vp
		_bg.position = Vector2.ZERO

	for s in _screens:
		if s == null:
			continue
		s.size = vp
		s.position = Vector2.ZERO
		# 只把居中容器铺满整屏；面板自身的位置/尺寸由 CenterContainer 负责
		for c in s.get_children():
			if c is CenterContainer:
				c.size = vp
				c.position = Vector2.ZERO
