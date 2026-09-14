# script/ui/map_view.gd
# ============================================
# 地图视图基类（小地图 MinimapUI / 大地图 BigMapUI 共用）
#
# 两块地图除了"画在多大一块地方"以外完全一样，所以共同逻辑都放这里：
#   1. 底图：同一张按区域配色的地形俯视图。**全类共享一份**（static），
#      小地图先建好大地图就直接用，不会各建一张。
#   2. 视角：缩放 _zoom（1.0 = 基准适配，见 _cover_fit()）+ 平移 _center（视图
#      中心对应的世界坐标）。滚轮以**光标为锚点**缩放，左键按住拖动平移，
#      右键复位。
#   3. 标记：建筑方块 + 玩家箭头，每帧按世界→视图换算现画（底图是静态纹理，
#      所以整帧只是重画一小块，开销可忽略）。
#
# 子类只需要实现三件事：
#   _map_rect()          地图画在哪一块（视图内的像素矩形，不要求正方形）
#   _setup_view()        建自己的装饰（背景样式、标签……）
#   _draw_before_map() / _draw_after_map(rect)   底图前后的额外交付
#
# 适配方式（_cover_fit()）：
#   false = contain（默认，小地图用）：整张地图都看得见，多出来的方向留白。
#   true  = cover（大地图用）：地图铺满整块矩形、不留白，超出的部分靠拖动看。
#   世界是 1600×1600 的正方形，屏幕是 16:9，只有 cover 才能"铺满屏幕"。
#   两种模式都保持**等比**缩放（像素/世界单位是同一个数），不会把地形拉扁。
#
# 底图为什么要分帧生成：
#   TEX_SIZE = 1600 是 256 万次逐像素取色，GDScript 同步跑要一两秒，
#   会明显卡一下。所以拆成"每帧填若干行"，百余帧内填满；未就绪时画深色底
#   + 进度文字（开局那一下本来就有一瞬间没地图数据，观感一致）。
#
# 鼠标：本控件 mouse_filter = STOP，所以鼠标在地图上时滚轮/拖动都归它，
#   同时相机的滚轮缩放会因为 gui_get_hovered_control() != null 自动让位。
# ============================================

class_name MapView
extends Control

## 底图分辨率（纹理边长，像素）：取 1600 = 地图原生格数（TILE_SIZE=1），
## 即 1 像素 = 1 格；1 倍缩放时纹理与地图 1:1，放大后才是插值放大
const TEX_SIZE := 1600
## 每帧最多填多少行（1600 行约 100 帧填完 ≈ 1.7 秒；单帧约 2.5 万次取色，
## 大约是 8~15ms 的额外开销，期间帧率略降但不会卡住）
const BANDS_PER_FRAME := 16
## 缩放范围：1.0 = 基准适配（见 _cover_fit()），5 倍时视图内约 320 世界单位
const MIN_ZOOM := 1.0
const MAX_ZOOM := 5.0
## 滚轮每格缩放倍率
const ZOOM_STEP := 1.15
## 建筑标记刷新间隔（秒）：建筑不会每帧增减，1 秒扫一次足够
const MARKER_INTERVAL := 1.0

# ----------------------------------------
# 共享底图（static：跨实例、跨场景只保留一份）
# ----------------------------------------
## 底图对应的地图生成器；换了地图（新开一局/读档）时旧底图整体作废
static var _s_gen: Node = null
static var _s_tex: ImageTexture = null
## 生成中的字节缓冲与已填行数
static var _s_data: PackedByteArray = PackedByteArray()
static var _s_row: int = 0

# ----------------------------------------
# 视图状态
# ----------------------------------------
## 缩放倍率
var _zoom: float = MIN_ZOOM
## 视图中心的世界坐标（x, z）
var _center: Vector2 = Vector2.ZERO
## 是否正在拖动
var _dragging: bool = false
## 上一帧的鼠标位置（拖动用）
var _drag_last: Vector2 = Vector2.ZERO

var _map_gen: Node = null
var _player: Node = null
## 玩家朝向（弧度，由移动速度推出；静止时保留上一次朝向）
var _heading: float = 0.0
## 地图旋转角（弧度）。_rotates_with_view() 为 true 时跟随相机 yaw，
## 让"相机视线方向"始终指向视图上方；为 false 时恒为 0（北上）。
var _map_angle: float = 0.0
var _buildings: Array = []
var _marker_timer: float = 0.0


func _ready() -> void:
	# 底图会被放大（1 倍以上），线性过滤比最近邻柔和、不像色块
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# 要收滚轮与拖动，必须吃掉鼠标；代价是地图区域内点不到 3D 世界（预期行为）
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 鼠标拖出控件外再松开时收不到 released，靠 exit 兜底复位
	mouse_exited.connect(_on_mouse_exited)
	resized.connect(_on_view_resized)
	_setup_view()
	queue_redraw()


# ============================================
# 子类钩子
# ============================================

## 地图绘制区域（控件内的像素矩形）。子类给出实际区域，比例不必是正方形。
func _map_rect() -> Rect2:
	return Rect2(Vector2.ZERO, size)


## 子类装饰（背景样式、标签……），在 _ready 末尾调用
func _setup_view() -> void:
	pass


## 适配方式：false = contain（整张可见，可能留白）；true = cover（铺满，可能裁切）
func _cover_fit() -> bool:
	return false


## 是否随相机 yaw 旋转（罗盘式）。小地图 true，大地图保持北上便于看全局。
func _rotates_with_view() -> bool:
	return false


## 底图之前的绘制（例：小地图的面板背板）
func _draw_before_map() -> void:
	pass


## 底图之后的绘制（例：小地图的指北标）
func _draw_after_map(_rect: Rect2) -> void:
	pass


## 视图变化（缩放/平移/复位）后调用，子类可刷新自己的文字
func _on_view_changed() -> void:
	pass


# ============================================
# 生命周期
# ============================================

func _process(delta: float) -> void:
	# 隐藏时也推进底图生成：底图是共享的，谁先就绪都行
	_pump_texture()
	if not visible:
		return

	_marker_timer -= delta
	if _marker_timer <= 0.0:
		_marker_timer = MARKER_INTERVAL
		_buildings = BuildingSystem.get_placed()

	_update_heading(_get_player())
	_update_map_angle()
	queue_redraw()


func _on_view_resized() -> void:
	queue_redraw()


func _on_mouse_exited() -> void:
	_dragging = false


# ============================================
# 输入：滚轮缩放 + 左键拖动 + 右键复位
# ============================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var inside: bool = _map_rect().has_point(mb.position)
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if inside:
				zoom_at(mb.position, ZOOM_STEP)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if inside:
				zoom_at(mb.position, 1.0 / ZOOM_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if inside:
					_dragging = true
					_drag_last = mb.position
					accept_event()
			else:
				_dragging = false
				accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and inside:
			reset_view()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_pan_by(mm.position - _drag_last)
		_drag_last = mm.position
		accept_event()


# ============================================
# 视角操作（子类也可主动调用：如"定位玩家"按钮）
# ============================================

## 以 p（控件内像素坐标）为锚点缩放：缩放前后光标下的世界点保持不动
func zoom_at(p: Vector2, factor: float) -> void:
	var before := view_to_world(p)
	var z: float = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(z, _zoom):
		return
	_zoom = z
	var after := view_to_world(p)
	_center += before - after
	_clamp_view()
	_on_view_changed()
	queue_redraw()


## 重新把玩家放到视图中心（缩放不变）
func focus_on_player() -> void:
	var p := _get_player()
	if p == null:
		return
	var pos: Vector3 = p.global_position
	_center = Vector2(pos.x, pos.z)
	_clamp_view()
	_on_view_changed()
	queue_redraw()


## 复位：缩放回 1 倍 + 回到地图中心（大地图 cover 时右键复位就是"看全岛中心"）
func reset_view() -> void:
	_zoom = MIN_ZOOM
	_center = Vector2.ZERO
	_clamp_view()
	_on_view_changed()
	queue_redraw()


## 底图就绪时返回它，否则 null（子类可用来判断要不要画"生成中"）
func has_texture() -> bool:
	return _s_tex != null


## 底图生成进度 0~1（未开始或已完成为 1.0 / 0.0）
static func build_progress() -> float:
	if _s_tex != null:
		return 1.0
	if _s_data.is_empty():
		return 0.0
	return clampf(float(_s_row) / float(TEX_SIZE), 0.0, 1.0)


# ============================================
# 坐标换算
# ============================================

func view_to_world(p: Vector2) -> Vector2:
	var rect := _map_rect()
	var ppw := _px_per_world()
	if ppw <= 0.0:
		return _center
	return _center + _rot2_inv(p - rect.get_center()) / ppw


func world_to_view(world: Vector3) -> Vector2:
	return world2_to_view(Vector2(world.x, world.z))


## Vector2 世界坐标 → 视图像素（含地图旋转）
func world2_to_view(w: Vector2) -> Vector2:
	var rect := _map_rect()
	var ppw := _px_per_world()
	if ppw <= 0.0:
		return rect.get_center()
	return rect.get_center() + _rot2(Vector2(w.x - _center.x, w.y - _center.y) * ppw)


## 当前视图覆盖的世界范围（世界单位）。cover 时某一轴可能小于整张地图。
func visible_span() -> Vector2:
	var rect := _map_rect()
	var ppw := _px_per_world()
	if ppw <= 0.0:
		return Vector2.ZERO
	return rect.size / ppw


## 视图内每世界单位占多少像素。**两轴同值**——等比缩放，地形不会被拉扁；
## 比例差异由 visible_span() 体现（cover 时较窄的那轴看得更远/更近）。
func _px_per_world() -> float:
	var rect := _map_rect()
	var ws := _world_size()
	if ws.x <= 0.0 or ws.y <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return 1.0
	var fit: float
	if _cover_fit():
		fit = maxf(rect.size.x / ws.x, rect.size.y / ws.y)
	else:
		fit = minf(rect.size.x / ws.x, rect.size.y / ws.y)
	return fit * _zoom


func _pan_by(delta_px: Vector2) -> void:
	var ppw := _px_per_world()
	if ppw <= 0.0:
		return
	# 鼠标向右拖 = 视野往左移，内容跟着手走（屏幕位移要逆着地图旋转变回世界位移）
	_center -= _rot2_inv(delta_px) / ppw
	_clamp_view()
	_on_view_changed()
	queue_redraw()


## 限制平移范围：可见区域不能越出地图边界（缩放 1 倍且 contain 时中心只能是地图中心）
func _clamp_view() -> void:
	var ws := _world_size()
	if ws.x <= 0.0 or ws.y <= 0.0:
		return
	var span := visible_span()
	var lim := Vector2(maxf((ws.x - span.x) * 0.5, 0.0), maxf((ws.y - span.y) * 0.5, 0.0))
	_center.x = clampf(_center.x, -lim.x, lim.x)
	_center.y = clampf(_center.y, -lim.y, lim.y)


# ============================================
# 绘制
# ============================================

func _draw() -> void:
	var rect := _map_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return

	_draw_before_map()

	# 旋转（或 cover 拖到边缘）露出的边角先垫深色，别露出面板底色
	draw_rect(rect, Color(0.04, 0.06, 0.09, 0.92))
	if _s_tex != null:
		_draw_map_texture(rect)
	else:
		_draw_loading_text(rect)

	# 底图描边：海陆边界更清楚
	draw_rect(rect, Color(0.55, 0.65, 0.85, 0.35), false, 1.0)

	_draw_after_map(rect)
	_draw_buildings(rect)
	_draw_player(rect)


func _draw_map_texture(rect: Rect2) -> void:
	var ws := _world_size()
	if ws.x <= 0.0 or ws.y <= 0.0:
		return
	# 视口四角 → 世界坐标（含旋转）→ 纹理 UV；
	# 多边形裁到地图世界范围内：旋转/拖动越界时只画地图内的部分，
	# 不画 draw_texture_rect_region 那种"取样区必须是无旋转矩形"的限制。
	var corners := [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]
	var poly := PackedVector2Array()
	for i in corners.size():
		poly.append(view_to_world(corners[i] as Vector2))

	# Sutherland–Hodgman：裁剪到世界方形 [-w/2, w/2]²
	var hx := ws.x * 0.5
	var hy := ws.y * 0.5
	poly = _clip_halfplane(poly, Vector2.RIGHT, -hx)
	poly = _clip_halfplane(poly, Vector2.LEFT, -hx)
	poly = _clip_halfplane(poly, Vector2.DOWN, -hy)
	poly = _clip_halfplane(poly, Vector2.UP, -hy)
	if poly.size() < 3:
		return

	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for i in poly.size():
		var w: Vector2 = poly[i]
		pts.append(world2_to_view(w))
		# uv 是世界坐标的仿射函数，裁剪插值出的顶点直接按公式算即可
		uvs.append(Vector2(w.x / ws.x + 0.5, w.y / ws.y + 0.5))
		cols.append(Color.WHITE)
	draw_polygon(pts, cols, uvs, _s_tex)


## 保留满足 n·p >= d 的半平面（Sutherland–Hodgman 单步）
func _clip_halfplane(poly: PackedVector2Array, n: Vector2, d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var cnt := poly.size()
	if cnt == 0:
		return out
	for i in cnt:
		var a := poly[i]
		var b := poly[(i + 1) % cnt]
		var da := n.dot(a) - d
		var db := n.dot(b) - d
		if da >= 0.0:
			out.append(a)
		if (da >= 0.0) != (db >= 0.0):
			out.append(a.lerp(b, da / (da - db)))
	return out


func _draw_loading_text(rect: Rect2) -> void:
	var f := ThemeDB.fallback_font
	if f == null:
		return
	var pct: int = int(build_progress() * 100.0)
	var text: String = "地图生成中… %d%%" % pct
	var pos := Vector2(rect.position.x + 12.0, rect.get_center().y)
	draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 24.0, 13,
		Color(0.8, 0.85, 0.95, 0.75))


func _draw_buildings(rect: Rect2) -> void:
	if _s_tex == null:
		return
	for b in _buildings:
		if not is_instance_valid(b):
			continue
		var p: Vector3 = b.global_position
		var px := world_to_view(p)
		if not rect.has_point(px):
			continue
		# 先描一圈深色，浅色地块上也看得见
		draw_rect(Rect2(px - Vector2(2.5, 2.5), Vector2(5.0, 5.0)), Color(0, 0, 0, 0.65))
		draw_rect(Rect2(px - Vector2(1.5, 1.5), Vector2(3.0, 3.0)), Color(0.95, 0.98, 1.0, 0.95))


func _draw_player(rect: Rect2) -> void:
	if _s_tex == null:
		return
	var p := _get_player()
	if p == null:
		return
	var pos: Vector3 = p.global_position
	var px := world_to_view(pos)
	# 放大后玩家可能被拖到视野外：夹到边缘并降低不透明度，还知道该往哪找
	var on_screen: bool = rect.has_point(px)
	var edge := Vector2(
		clampf(px.x, rect.position.x + 6.0, rect.position.x + rect.size.x - 6.0),
		clampf(px.y, rect.position.y + 6.0, rect.position.y + rect.size.y - 6.0))
	px = edge
	var alpha: float = 1.0 if on_screen else 0.45

	# 外圈：任何地形颜色上都能一眼找到自己
	draw_arc(px, 5.0, 0.0, TAU, 16, Color(0, 0, 0, 0.55 * alpha), 2.0)
	# 箭头：朝向 = 移动方向（静止时沿用上一次朝向）+ 地图旋转角
	draw_set_transform(px, _heading + _map_angle)
	draw_colored_polygon(
		PackedVector2Array([Vector2(7.5, 0.0), Vector2(-5.0, -4.5), Vector2(-5.0, 4.5)]),
		Color(0.05, 0.05, 0.08, 0.9 * alpha))
	draw_colored_polygon(
		PackedVector2Array([Vector2(6.0, 0.0), Vector2(-4.0, -3.2), Vector2(-4.0, 3.2)]),
		Color(1.0, 0.85, 0.15, alpha))
	draw_set_transform(Vector2.ZERO, 0.0)


# ============================================
# 底图生成（分帧）
# ============================================

## 推进底图生成。地图数据未就绪时什么都不做，下一帧继续调用即可。
func _pump_texture() -> void:
	var gen := _get_map_gen()
	if gen == null:
		return

	# 地图被销毁（退出场景）→ 清掉共享缓存，避免持有死节点
	if _s_gen != null and not is_instance_valid(_s_gen):
		_s_gen = null
		_s_tex = null
		_s_data = PackedByteArray()
		_s_row = 0

	if _s_gen == gen and _s_tex != null:
		return
	if _s_gen != gen:
		# 换了地图（新开一局 / 读档）→ 旧底图整体作废
		_s_gen = gen
		_s_tex = null
		_s_data = PackedByteArray()
		_s_row = 0

	if _s_data.is_empty():
		var data: PackedByteArray = gen.build_minimap_pixels(TEX_SIZE)
		if data.is_empty():
			return
		_s_data = data
		_s_row = 0

	var y0: int = _s_row
	var y1: int = mini(_s_row + BANDS_PER_FRAME, TEX_SIZE)
	if y1 > y0:
		gen.fill_minimap_bands(_s_data, TEX_SIZE, y0, y1)
		_s_row = y1

	if _s_row >= TEX_SIZE:
		var img := Image.create_from_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGB8, _s_data)
		_s_tex = ImageTexture.create_from_image(img)
		_s_data = PackedByteArray()
	queue_redraw()


## 立即开始（或继续）生成底图；UIManager 打开面板时会调同名方法
func refresh_map() -> void:
	_pump_texture()
	_clamp_view()
	queue_redraw()


# ============================================
# 私有
# ============================================

func _world_size() -> Vector2:
	var gen := _get_map_gen()
	if gen == null or not gen.has_method("get_world_size"):
		return Vector2.ZERO
	var ws: Vector2 = gen.get_world_size()
	return ws


func _update_heading(p: Node) -> void:
	if p == null:
		return
	var v: Variant = p.get("velocity")
	if v == null or not (v is Vector3):
		return
	var vel := v as Vector3
	# 站着不动时不改朝向，否则箭头会因为速度归零而乱转
	if vel.x * vel.x + vel.z * vel.z < 0.25:
		return
	_heading = atan2(vel.z, vel.x)


## 地图旋转角：让"相机视线方向"始终指向视图上方。
## 取相机基向量的水平分量当真实视线，不依赖 camera_3d.gd 的私有 yaw 变量。
## 推导：视线（水平）f = (sin yaw, cos yaw)，要 Rot2(a)·f = (0,-1)，解得
## a = atan2(f.x, f.z) + PI（Godot 2D 正角 = 屏幕顺时针，y 轴向下）。
func _update_map_angle() -> void:
	if not _rotates_with_view():
		_map_angle = 0.0
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var fwd := -cam.global_transform.basis.z
	if fwd.x * fwd.x + fwd.z * fwd.z < 0.0001:
		return
	_map_angle = atan2(fwd.x, fwd.z) + PI


## 屏幕向量 → 旋转后的屏幕向量（Rot2(a)，Godot 2D 同款矩阵）
func _rot2(v: Vector2) -> Vector2:
	var c := cos(_map_angle)
	var s := sin(_map_angle)
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)


## _rot2 的逆变换（Rot2(-a)）
func _rot2_inv(v: Vector2) -> Vector2:
	var c := cos(_map_angle)
	var s := sin(_map_angle)
	return Vector2(v.x * c + v.y * s, -v.x * s + v.y * c)


func _get_map_gen() -> Node:
	if _map_gen != null and is_instance_valid(_map_gen):
		return _map_gen
	var gens: Array = get_tree().get_nodes_in_group("map_gen")
	if not gens.is_empty():
		_map_gen = gens[0]
	return _map_gen


func _get_player() -> Node:
	if _player != null and is_instance_valid(_player):
		return _player
	var root := get_tree().get_first_node_in_group("player")
	if root == null:
		return null
	# player 根节点是停在原点的容器，真正在移动的是子节点 Physics
	_player = root.get_node_or_null("Physics")
	if _player == null:
		_player = root
	return _player
