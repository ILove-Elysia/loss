# script/player/build_placer.gd
# ============================================
# 建筑放置控制器 - 挂在 player 根节点下
#
# 为什么单独成组件而不是塞进 physics.gd：
#   physics.gd 已经 300+ 行（移动/攻击/受伤/死亡/视觉插值），
#   放置模式要管幽灵预览、射线求交、合法性校验、点击命中，
#   混进去会让它彻底不可读。独立组件 + 只靠 player 组查找，职责清晰。
#
# 交互方案（刻意避开新键位）：
#   项目里 W/A/S/D 移动、空格采集、F 攻击、Q/E 转视角、C 合成、B 装备、
#   M 地图、Tab 背包、1-9 快捷栏——键盘已经排满，所以建筑交互全部走鼠标：
#     世界里左键 = 放置确认 / 点击建筑使用
#     世界里右键 = 取消放置 / 点击建筑拆除（返还材料）
#   左键本来是空闲的（player_attack 绑的是 F 键），正好用上。
#
# 使用/拆除建筑有双重门槛（2026-09-11 补）：
#   1. 鼠标射线落点要在建筑 click_radius 内（= 点中了它）
#   2. 玩家本人要站在 use_distance 内（= 够得着它）
#   只判 1 的话，隔着半个岛点一下就能开箱/开合成台，与"储物箱必须靠近存取"
#   的设计（见 building_system.gd 顶部注释）矛盾。
#
# 为什么点击判定用「射线打地面 + 水平距离」而不是给建筑挂 Area3D：
#   本项目踩过的坑——资源侧的 Area3D 完全检测不到玩家（见 MEMORY）。
#   这里连射线都不需要打建筑本身：只用相机射线与"玩家脚下高度的水平面"
#   求交得到地面点，再按水平距离找最近建筑。不引入新物理层，零冲突风险。
#
# 鼠标点在 UI 上时必须忽略：否则点背包按钮会顺带在地图里放下个建筑。
# ============================================

extends Node

## 最远放置距离（米）：超出就判非法，防止把建筑放到天边
@export var max_place_distance: float = 8.0
## 最近放置距离：别贴脸放，免得幽灵卡在角色里
@export var min_place_distance: float = 0.6
## 建筑之间的最小间距：防止叠在一起分不清
@export var min_gap: float = 1.8
## 点击建筑的水平判定半径（鼠标射线落点离建筑多近才算"点到它"）
@export var click_radius: float = 1.5
## 建筑有碰撞体（见 building.gd），放置时必须给角色留出身体空间：
## 实际最小距离 = max(min_place_distance, 建筑半宽 + player_clearance)。
## 0.5 ≈ 玩家碰撞半径 0.33 + 一点余量，保证放下后角色不会卡在建筑里。
@export var player_clearance: float = 0.5
## 使用/拆除建筑时，玩家离建筑的最大水平距离。
## 取 3.0 = 与采集距离（ResourceManager._try_harvest_nearest 的 3.0m）一致，
## 手感统一：够得着采的东西，也就够得着开箱/开合成台。
## 注意：click_radius 管"鼠标点没点中"，这个管"人站得够不够近"，两者都要满足。
@export var use_distance: float = 3.0

## 是否处于放置模式
var is_placing: bool = false

var _placing_id: StringName = &""
var _ghost: MeshInstance3D = null
var _ghost_mat: StandardMaterial3D = null
var _ghost_ok := false
var _target := Vector3.ZERO

var _physics: CharacterBody3D = null
var _inventory: Node = null
var _map_gen: Node = null
var _root: Node3D = null
var _hint_layer: CanvasLayer = null
var _hint_label: Label = null
## 上一帧的非法原因（只在变化时打日志，避免每帧刷屏）
var _last_bad_reason: String = ""
## 一次性提示（"太远了"之类）的剩余显示秒数；>0 时底部提示保持可见
var _flash_timer: float = 0.0


# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	set_process(true)
	set_process_input(true)

	_physics = _find_physics()
	_inventory = get_parent().get_node_or_null("Inventory")
	_map_gen = get_tree().get_first_node_in_group("map_gen")

	# 打开任何面板（背包/合成/暂停）都视为"不放置了"——
	# 面板会盖住视线，且 Esc 已被 UIManager 独占，这里是更自然的取消路径。
	if UIManager.instance != null:
		UIManager.instance.panel_opened.connect(_on_panel_opened)


## player 根节点只做分组容器、不移动；真正移动的是 Physics 子节点
func _find_physics() -> CharacterBody3D:
	var p := get_parent()
	if p == null:
		return null
	for c in p.get_children():
		if c is CharacterBody3D:
			return c
	return null


func _on_panel_opened(_panel_name: String) -> void:
	if is_placing:
		cancel_placement()


# ============================================
# 放置模式
# ============================================

## 进入放置模式。id 必须是可放置建筑（BuildingSystem.is_building）
func start_placement(id: StringName) -> bool:
	if not BuildingSystem.is_building(id):
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "进入放置模式失败：%s 不是可放置建筑", [id])
		return false
	# 背包在 _ready 里取过一次；万一当时组件还没挂上，这里再兜一次
	if _inventory == null:
		_inventory = get_parent().get_node_or_null("Inventory")
	if _inventory == null:
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "进入放置模式失败：找不到玩家 Inventory", [])
		return false
	if _inventory.get_item_count(id) <= 0:
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "进入放置模式失败：背包里没有 %s", [id])
		return false
	if _physics == null:
		_physics = _find_physics()
		if _physics == null:
			DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "进入放置模式失败：找不到玩家 Physics", [])
			return false

	_placing_id = id
	is_placing = true
	_build_ghost()
	_show_hint()
	DebugConfig.log_msg(DebugConfig.CAT_BUILD, "进入放置模式：%s（背包 %d 个）",
		[id, _inventory.get_item_count(id)])
	return true


func cancel_placement() -> void:
	if is_placing:
		DebugConfig.log_msg(DebugConfig.CAT_BUILD, "取消放置：%s", [_placing_id])
	_placing_id = &""
	is_placing = false
	_destroy_ghost()
	_hide_hint()


func _build_ghost() -> void:
	_destroy_ghost()

	var def := BuildingSystem.get_def(_placing_id)
	var size: Array = def.get("size", [1.2, 1.0])
	var width := float(size[0])
	var height := float(size[1])

	_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, height, width)
	_ghost.mesh = box

	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.35, 0.9, 0.45, 0.5)
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.set_surface_override_material(0, _ghost_mat)

	# 幽灵纯装饰：不投影、不参与碰撞或拾取。
	# 【坑】MeshInstance3D 没有 set_collision_layer_value —— 那是 CollisionObject3D 的方法。
	#   在纯网格上调它会在运行时抛 "Invalid call. Nonexistent function"，
	#   函数当场中断，后面的 add_child 走不到，幽灵永远不出现（表现为"放不下建筑"）。
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# 挂到场景根下而不是 player 下：
	# 挂在 player 下会跟着 player 的位移漂移（虽然 player 不移动，
	# 但它的子节点受父级变换影响，将来若改结构就会错位）。
	get_tree().current_scene.add_child(_ghost)


func _destroy_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		if _ghost.get_parent() != null:
			_ghost.get_parent().remove_child(_ghost)
		_ghost.queue_free()
	_ghost = null
	_ghost_mat = null


# ============================================
# 每帧：幽灵跟随 + 合法性校验
# ============================================

func _process(delta: float) -> void:
	# 这两件事与放置模式无关，必须在"不在放置就早退"之前处理
	_tick_flash(delta)
	_tick_storage_distance()

	if not is_placing:
		return
	if _physics == null:
		return

	_target = _ground_point_under_mouse()
	var bad := _invalid_reason(_target)
	_ghost_ok = bad.is_empty()
	_update_hint_text(bad)

	if _ghost == null:
		return
	_ghost.global_position = _target
	if _ghost_mat != null:
		_ghost_mat.albedo_color = (
			Color(0.35, 0.9, 0.45, 0.55) if _ghost_ok else Color(0.9, 0.3, 0.3, 0.55))


## 相机射线与"玩家脚下高度的水平面"求交
## 世界是平面无海拔（大纲 4.1），所以直接用玩家当前 y 当平面高度即可，
## 不需要查地形高度图。
func _ground_point_under_mouse() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _physics == null:
		return Vector3.ZERO

	var mouse := get_viewport().get_mouse_position()
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)

	# 射线近乎平行于地面（俯角极小时）会导致交点飞到极远处
	if absf(dir.y) < 0.05:
		return Vector3.ZERO

	var t: float = (_physics.global_position.y - origin.y) / dir.y
	if t < 0.0:
		return Vector3.ZERO
	return origin + dir * t


func _is_valid_spot(pos: Vector3) -> bool:
	return _invalid_reason(pos).is_empty()


## 返回该落点非法的原因；合法时返回 ""。
## 拆出"原因"而不是只给 true/false：玩家点下去没反应时最想知道的就是"为什么"，
## 原因文本直接显示在屏幕底部提示里，不用开调试也能自查。
func _invalid_reason(pos: Vector3) -> String:
	if _physics == null:
		return "玩家未就绪"
	if pos == Vector3.ZERO:
		return "射线没打到地面（把鼠标移到地面上）"

	var dist := _horizontal_dist(pos, _physics.global_position)
	if dist > max_place_distance:
		return "太远了（最远 %.0f 米）" % max_place_distance
	# 建筑有碰撞体：最小距离按"建筑半宽 + 角色余量"算，
	# 否则放下的箱子会把角色卡在里面（或把角色顶开）
	var need := _min_place_distance()
	if dist < need:
		return "太近了（离自己至少 %.1f 米，否则会卡住）" % need

	# 不能建在水里
	if _map_gen == null or not is_instance_valid(_map_gen):
		_map_gen = get_tree().get_first_node_in_group("map_gen")
	if _map_gen != null and _map_gen.has_method("get_terrain_world"):
		if int(_map_gen.get_terrain_world(pos)) == 7:  # 7 = 海洋
			return "不能建在水里"

	# 不能和已有建筑叠在一起
	if BuildingSystem.find_nearest(pos, min_gap) != null:
		return "离已有建筑太近"
	return ""


func _horizontal_dist(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


# ============================================
# 距离门槛：使用 / 拆除建筑必须人在旁边
# ============================================

## 开着储物箱面板时走远 → 自动关掉面板。
## 放在 BuildPlacer 而不是 StorageUI：use_distance 是本类的参数，
## 距离判定保持只有一份，StorageUI 只负责"我被绑在哪个建筑上"。
func _tick_storage_distance() -> void:
	if _physics == null:
		return
	var ui := get_tree().get_first_node_in_group("storage_ui") as Control
	if ui == null or not ui.visible:
		return
	var b: Node = ui.get("bound_building")
	if b == null or not is_instance_valid(b):
		return
	if _dist_to_player(b) <= use_distance:
		return
	DebugConfig.log_msg(DebugConfig.CAT_BUILD, "离开储物箱 %.1f 米（> %.1f），自动关闭面板",
		[_dist_to_player(b), use_distance])
	UIManager.close_panel(UIManager.STORAGE_PANEL)


## 玩家是否站在该建筑的可交互范围内（水平距离，忽略高度）
func _is_in_reach(b: Node) -> bool:
	if b == null or _physics == null:
		return false
	return _dist_to_player(b) <= use_distance


## 玩家到建筑的水平距离
func _dist_to_player(b: Node) -> float:
	return _horizontal_dist(b.global_position, _physics.global_position)


## 当前放置建筑所需的最小离身距离 = max(下限, 建筑半宽 + 角色余量)
func _min_place_distance() -> float:
	var def := BuildingSystem.get_def(_placing_id)
	var size: Array = def.get("size", [1.2, 1.0])
	var half_width: float = float(size[0]) * 0.5
	return maxf(min_place_distance, half_width + player_clearance)


# ============================================
# 操作提示（底部一行字，告诉玩家按哪个键）
# ============================================

func _ensure_hint() -> void:
	if _hint_layer != null and is_instance_valid(_hint_layer):
		return

	var scene := get_tree().current_scene
	if scene == null:
		return

	_hint_layer = CanvasLayer.new()
	_hint_layer.name = "BuildHintLayer"
	# 高于 HUD 的 CanvasLayer，盖在快捷栏上方
	_hint_layer.layer = 150
	scene.add_child(_hint_layer)

	_hint_label = Label.new()
	# 显式 anchor + 对称 offset：运行时 new 出来的控件调 set_anchors_preset 会算成 0×0
	_hint_label.anchor_left = 0.5
	_hint_label.anchor_right = 0.5
	_hint_label.anchor_top = 1.0
	_hint_label.anchor_bottom = 1.0
	_hint_label.offset_left = -220
	_hint_label.offset_right = 220
	# 两行（第二行显示"放不下：原因"），高度留够别被裁掉
	_hint_label.offset_top = -110
	_hint_label.offset_bottom = -62
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_layer.add_child(_hint_label)


func _show_hint() -> void:
	_ensure_hint()
	if _hint_label == null:
		return
	_last_bad_reason = ""
	_hint_label.text = "[左键] 放置    [右键] 取消"
	_hint_layer.visible = true


## 短暂显示一条一次性提示（如"离建筑太远"），1.6 秒后自动收起。
## 复用放置提示的 CanvasLayer：两条提示不会同时出现（放置时不会走到这里）。
func _flash_hint(text: String) -> void:
	_ensure_hint()
	if _hint_label == null or _hint_layer == null:
		return
	_hint_label.text = text
	_hint_layer.visible = true
	_flash_timer = 1.6


func _tick_flash(delta: float) -> void:
	if _flash_timer <= 0.0:
		return
	_flash_timer -= delta
	# 放置模式的提示不能被这条倒计时关掉
	if _flash_timer <= 0.0 and not is_placing:
		_hide_hint()


## 把落点合法性写进底部提示：幽灵变红时玩家一眼能看出为什么放不下
func _update_hint_text(bad: String) -> void:
	if _hint_label == null or _hint_layer == null:
		return
	var text := "[左键] 放置    [右键] 取消"
	if not bad.is_empty():
		text += "\n放不下：%s" % bad
	if _hint_label.text != text:
		_hint_label.text = text
	# 只在原因变化时记一条，避免每帧刷屏
	if bad != _last_bad_reason and not bad.is_empty():
		DebugConfig.log_msg(DebugConfig.CAT_BUILD, "落点非法：%s", [bad])
	_last_bad_reason = bad


func _hide_hint() -> void:
	if _hint_layer != null and is_instance_valid(_hint_layer):
		_hint_layer.visible = false


# ============================================
# 输入：左键放置 / 右键取消或拆除
# ============================================

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return

	# 鼠标悬在任意 UI 控件上时不响应世界点击
	if get_viewport().gui_get_hovered_control() != null:
		return

	if mb.button_index == MOUSE_BUTTON_LEFT:
		if is_placing:
			_confirm_placement()
			get_viewport().set_input_as_handled()
		else:
			if _try_use_building():
				get_viewport().set_input_as_handled()

	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		if is_placing:
			cancel_placement()
			get_viewport().set_input_as_handled()
		else:
			if _try_remove_building():
				get_viewport().set_input_as_handled()


func _confirm_placement() -> void:
	if _inventory == null:
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "放置失败：找不到玩家 Inventory", [])
		return
	if not _ghost_ok:
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "放置失败：落点非法（%s）", [_last_bad_reason])
		return

	# 按 id 扣而不是按槽位扣：放置期间玩家可能拖动过背包，槽位会变
	var removed: int = _inventory.remove_item(_placing_id, 1)
	if removed <= 0:
		DebugConfig.warn_msg(DebugConfig.CAT_BUILD, "放置失败：背包里没有 %s", [_placing_id])
		cancel_placement()
		return

	var b := Building.spawn(_placing_id, _target, _building_root())
	DebugConfig.log_msg(DebugConfig.CAT_BUILD, "已放置 %s @ (%.1f, %.1f)%s",
		[_placing_id, _target.x, _target.z, "" if b != null else "  【失败：Building.spawn 返回 null】"])
	cancel_placement()


## 建筑容器：懒创建并加入 building_root 组，方便存档/清理时定位
func _building_root() -> Node3D:
	if _root != null and is_instance_valid(_root):
		return _root

	var scene := get_tree().current_scene
	if scene == null:
		return null

	_root = get_tree().get_first_node_in_group("building_root") as Node3D
	if _root == null:
		_root = Node3D.new()
		_root.name = "BuildingContainer"
		_root.add_to_group("building_root")
		scene.add_child(_root)
	return _root


# ============================================
# 点击已有建筑
# ============================================

## 左键点建筑：储物箱开界面，工作台/熔炉打开合成界面
func _try_use_building() -> bool:
	if _physics == null:
		return false
	var ground := _ground_point_under_mouse()
	if ground == Vector3.ZERO:
		return false

	var b := BuildingSystem.find_nearest(ground, click_radius)
	if b == null:
		DebugConfig.log_msg(DebugConfig.CAT_BUILD, "左键地面 (%.1f, %.1f)：%.1f 米内没有建筑",
			[ground.x, ground.z, click_radius])
		return false

	# 人必须站在旁边才能用：否则隔着半个岛点一下就能开箱 / 开合成台
	if not _is_in_reach(b):
		DebugConfig.log_msg(DebugConfig.CAT_BUILD, "使用 %s 被拒：距离 %.1f 米 > %.1f 米",
			[b.get_display_name(), _dist_to_player(b), use_distance])
		_flash_hint("离「%s」太远了（走近到 %.0f 米内才能使用）" % [b.get_display_name(), use_distance])
		return true

	if b.has_storage():
		var panel := UIManager.open_panel(UIManager.STORAGE_PANEL)
		if panel != null and panel.has_method("bind_storage"):
			panel.call("bind_storage", b)
		return true

	# 工作台 / 熔炉：当做制作站，打开合成界面
	if b.get_station() != &"":
		UIManager.open_panel(UIManager.CRAFTING_PANEL)
		return true

	return false


## 右键点建筑：拆除并返还材料
func _try_remove_building() -> bool:
	if _physics == null:
		return false
	var ground := _ground_point_under_mouse()
	if ground == Vector3.ZERO:
		return false

	var b := BuildingSystem.find_nearest(ground, click_radius)
	if b == null:
		return false

	# 拆除同样要求人在旁边：远程拆家不合逻辑，也避免误拆远处建筑
	if not _is_in_reach(b):
		DebugConfig.log_msg(DebugConfig.CAT_BUILD, "拆除 %s 被拒：距离 %.1f 米 > %.1f 米",
			[b.get_display_name(), _dist_to_player(b), use_distance])
		_flash_hint("离「%s」太远了（走近到 %.0f 米内才能拆除）" % [b.get_display_name(), use_distance])
		return true

	# 返还失败（背包满 / 箱子没清空）就不拆，静默失败即可：
	# 玩家会看到建筑还在，比拆了却丢东西好
	var ok: bool = b.remove_and_refund(_inventory)
	if not ok:
		DebugConfig.log_msg(DebugConfig.CAT_BUILD, "拆除被拒：%s（背包满 / 箱子没清空）", [b.get_display_name()])
	return ok
