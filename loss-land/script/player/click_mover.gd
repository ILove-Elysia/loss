# script/player/click_mover.gd
# ============================================
# 鼠标点击移动 / 点击采集 控制器 - 挂在 player 根节点下
#
# 功能：
#   左键点空地 → 玩家自动走过去（physics.gd 的自动寻路：直线朝目标走）
#   左键点资源（草/树/石）→
#     - 已在采集范围（3 米）内：停下立即采集
#     - 不在范围内：自动走到资源旁，进入范围后自动采集
#
# 世界点击的分工（与 BuildPlacer 配合，见该文件顶部注释）：
#   放置模式左键 = 确认放置     → ClickMover 不参与
#   点中建筑     = 使用/拆除建筑 → ClickMover 不参与
#   点中资源     = 采集          → 本组件
#   点空地       = 走过去        → 本组件
#   （右侧键保留给建筑拆除/取消放置，不用于移动）
#
# 为什么不给资源挂 Area3D、也不用物理射线点资源：
#   资源侧 Area3D 历史上完全检测不到玩家（见 MEMORY），采集的权威判定
#   一直在 ResourceManager 的水平距离上。这里沿用同一套口径：
#   相机射线打"玩家脚下高度的水平面"得地面点，再按水平距离找最近资源。
#
# 为什么寻路是直线而不是 A*：
#   当前世界没有墙体/障碍实体（物理层 4 只用于射线检测），直线走不会卡；
#   卡死检测（physics.gd：2 秒没位移自动放弃）兜住被围住等异常情况。
#   将来加了障碍物后再升级成网格 A*。
# ============================================

extends Node

## 点击资源的判定半径：鼠标落点离资源多近算"点中它"（与建筑 click_radius 一致）
@export var click_radius: float = 1.5

## 待采集资源（自动寻路去采的目标；null = 纯移动订单）
var _pending_resource: ResourceEntity = null

## 长按左键拖动中：每帧把寻路目标更新为鼠标落点，玩家实时跟着鼠标走
var _hold_moving: bool = false

var _physics: CharacterBody3D = null
var _placer: Node = null
var _resource_manager: ResourceManager = null


func _ready() -> void:
	set_physics_process(true)
	set_process_input(true)
	_physics = _find_physics()
	_placer = get_parent().get_node_or_null("BuildPlacer")


## player 根节点只做分组容器、不移动；真正移动的是 Physics 子节点
func _find_physics() -> CharacterBody3D:
	var p := get_parent()
	if p == null:
		return null
	for c in p.get_children():
		if c is CharacterBody3D:
			return c
	return null


func _input(event: InputEvent) -> void:
	# ===== 长按跟随的打断检测 =====
	# 松开左键 → 结束实时跟随（当前订单保留，玩家走到最后的目标点）
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_hold_moving = false
			return
	# 手动按 WASD → 移动权交还玩家，结束跟随（否则两者每帧互相抢方向盘）
	if event.is_action_pressed("move_forward") or event.is_action_pressed("move_back") \
			or event.is_action_pressed("move_left") or event.is_action_pressed("move_right"):
		_hold_moving = false

	# ===== 单击下单 =====
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return

	# 鼠标悬在任意 UI 控件上时不响应世界点击（点背包按钮不能顺带跑图）
	if get_viewport().gui_get_hovered_control() != null:
		return
	# 其他系统（如放置模式确认）已处理过这次点击
	if get_viewport().is_input_handled():
		return
	if _placer != null and _placer.get("is_placing") == true:
		return
	if _physics == null:
		_physics = _find_physics()
		if _physics == null:
			return

	var ground := _ground_point_under_mouse()
	if ground == Vector3.ZERO:
		return

	# 点中建筑：交给 BuildPlacer 处理（开箱/用合成台/拆除），这里不抢
	if BuildingSystem.find_nearest(ground, click_radius) != null:
		return

	# 点中资源 → 采集订单；点空地 → 移动订单
	var rm := _get_resource_manager()
	var res: ResourceEntity = null
	if rm != null:
		res = rm.find_nearest_resource(ground, click_radius)

	# 工具门槛：树要斧头、大石头/矿要镐子。
	# 没带对工具就不下单、也不自动走过去（走过去同样采不了），直接提示缺什么。
	if res != null and rm != null and not rm.is_tool_sufficient(res):
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击采集] 工具不足，拒绝采集订单：%s",
			[res.resource_data.resource_id])
		rm.flash_hint(rm.get_tool_missing_hint(res))
		_set_pending(null)
		_hold_moving = false
		return

	_set_pending(res)
	if res != null:
		# 采集订单是"点一下"语义：长按不重复下采集单
		_hold_moving = false
		var dist := _horizontal_dist(res.global_position, _physics.global_position)
		if dist <= ResourceManager.INTERACT_RANGE:
			# 已在采集范围内：原地直接采，不用走
			_physics.cancel_auto_move()
			DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击采集] %s 在范围内（%.2f 米），立即采集",
				[res.resource_data.resource_id, dist])
			_set_pending(null)
			rm.harvest_resource(res, get_parent())
		else:
			# 不在范围内：先走到资源旁，进入范围后由 _physics_process 收尾
			_physics.start_auto_move(res.global_position)
			DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击采集] %s 距离 %.2f 米，自动走近后采集",
				[res.resource_data.resource_id, dist])
	else:
		# 空地：走过去；长按住则进入实时跟随（由 _process 逐帧更新目标）
		_hold_moving = true
		_physics.start_auto_move(ground)
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击移动] 前往 (%.1f, %.1f)", [ground.x, ground.z])


## 长按左键拖动：每帧把寻路目标刷成鼠标落点，玩家实时跟着鼠标走。
## 只在"按下的那一瞬间点的是空地"时激活（_hold_moving），
## 采集/建筑订单不会被长按覆盖。
func _process(_delta: float) -> void:
	if not _hold_moving:
		return

	# 鼠标实际已松开（拖到窗口外松开时收不到事件，用轮询兜底）
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_hold_moving = false
		return

	# 长按途中进入了放置模式：跟随让位给放置
	if _placer != null and _placer.get("is_placing") == true:
		_hold_moving = false
		return

	if _physics == null:
		_physics = _find_physics()
		if _physics == null:
			return

	# 鼠标移到 UI 上：保留当前订单，但不再更新目标
	if get_viewport().gui_get_hovered_control() != null:
		return

	var ground := _ground_point_under_mouse()
	if ground == Vector3.ZERO:
		return

	# 拖到建筑/资源上：不改订单（避免长按扫过资源时误触采集/开箱）
	if BuildingSystem.find_nearest(ground, click_radius) != null:
		return
	var rm := _get_resource_manager()
	if rm != null and rm.find_nearest_resource(ground, click_radius) != null:
		return

	_physics.update_auto_move_target(ground)


## 记录"走到资源旁再采集"的订单，并同步钉住标记。
##
## 为什么要钉住（2026-09-12）：
##   ResourceManager 会把离开玩家视野的资源实体退回对象池。而本脚本的
##   _pending_resource 会长期抓着某个实体引用——一旦它被卸载、又被对象池
##   拿去表示别的资源，这个引用就变成幽灵：玩家会朝错误的位置走、采错东西。
##   所以订单目标置 pinned = true，卸载逻辑见到它直接跳过。
func _set_pending(res: ResourceEntity) -> void:
	if _pending_resource != null and is_instance_valid(_pending_resource) and _pending_resource != res:
		_pending_resource.pinned = false
	_pending_resource = res
	if res != null:
		res.pinned = true


func _physics_process(_delta: float) -> void:
	if _pending_resource == null:
		return

	# 资源中途失效（状态变化 / 已被采掉）→ 取消采集订单
	if not is_instance_valid(_pending_resource) or not _pending_resource.can_harvest():
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击采集] 目标资源已失效，取消", [])
		_set_pending(null)
		if _physics != null and _physics.is_auto_moving():
			_physics.cancel_auto_move()
		return

	# 寻路已结束（到达 / 被挡住放弃 / 被手动打断）但始终没进采集范围 → 放弃补刀
	if _physics == null or not _physics.is_auto_moving():
		_set_pending(null)
		return

	# 进入采集范围 → 停下采集（树 0.8 秒采集时长由资源侧 harvest() 自己处理）
	var dist := _horizontal_dist(_pending_resource.global_position, _physics.global_position)
	if dist <= ResourceManager.INTERACT_RANGE:
		var res := _pending_resource
		_set_pending(null)
		_physics.cancel_auto_move()
		var rm := _get_resource_manager()
		if rm != null:
			# 走到半路玩家可能卸了工具（换装备），到点再核一遍工具门槛
			if not rm.is_tool_sufficient(res):
				DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击采集] 到达时工具不足，取消：%s",
					[res.resource_data.resource_id])
				rm.flash_hint(rm.get_tool_missing_hint(res))
				return
			DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[点击采集] 走到 %s 旁边（%.2f 米），采集",
				[res.resource_data.resource_id, dist])
			rm.harvest_resource(res, get_parent())


## 相机射线与"玩家脚下高度的水平面"求交（同 BuildPlacer._ground_point_under_mouse）。
## 世界无海拔，直接用玩家当前 y 当平面高度，不需要查地形高度图。
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


## 懒取 ResourceManager（按 "resource_manager" 组查找，找不到时下帧重试）
func _get_resource_manager() -> ResourceManager:
	if _resource_manager != null and is_instance_valid(_resource_manager):
		return _resource_manager
	_resource_manager = get_tree().get_first_node_in_group("resource_manager") as ResourceManager
	return _resource_manager


## 水平距离（忽略高度差，与采集判定同口径）
func _horizontal_dist(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)
