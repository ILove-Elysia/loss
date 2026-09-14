# script/ui/big_map_ui.gd
# ============================================
# 大地图（全屏，M 键开关，UIManager 托管）
#
# 与小地图的关系：缩放/平移/底图/标记的实现在基类 MapView，这里只管
#   "铺满屏幕的排版 + 标题/提示/图例"。
#
# 交互：
#   M / Esc  关闭      滚轮  以光标为锚点缩放（1x ~ 5x）
#   左键拖动 平移      右键  复位（回到玩家处）
#
# 铺满屏幕：地形按 cover 方式等比铺满整个视口（不留边），超出部分靠拖动查看。
#   世界是 1600×1600 的正方形，屏幕通常是 16:9——若按"整张可见"来适配，
#   左右必然留两条黑边，看起来就是"没铺满"，所以这里用 cover。
#
# 布局坑（与 pause_menu_ui.gd 同一个，2026-09-12 实机踩到）：
#   运行时 new 出来的全屏面板**不能在 _ready 里用 set_anchors_preset 铺全屏**——
#   布局发生在回调之后，_ready 里拿到的是 0×0。后果不只是画不出来，更隐蔽的是：
#   控件矩形是 0×0 → 鼠标永远悬停不到它 → _gui_input 收不到滚轮/拖动（地图不能缩放），
#   而且鼠标事件直接穿过去点到 3D 世界（点地面照常走位）。
#   正确做法：显式给 position/size 赋值，窗口变化由 UIManager 调 on_viewport_resized()。
#
# 非模态？不——本面板 modal=true（打开即暂停）：
#   看地图时世界停住、鼠标/键盘都不会漏给游戏，关掉再恢复。
# ============================================

class_name BigMapUI
extends MapView

## 顶部标题行 / 提示行高度
const TITLE_H := 30.0
const HINT_H := 20.0
## 顶部整块（标题 + 提示）与底部图例带的高度（同时是压条背景的高度）
const TOP_BAND := 78.0
const BOTTOM_BAND := 58.0

var _title: Label = null
var _hint: Label = null
## 图例缓存（地形名称 + 配色），地图就绪后取一次
var _legend: Array = []


func _setup_view() -> void:
	# 不用 set_anchors_preset：见文件头的布局坑说明。显式 size 才靠得住。
	_build_labels()
	on_viewport_resized()


func _process(delta: float) -> void:
	super._process(delta)
	# 自愈兜底：本面板必须**恰好**铺满视口——尺寸一旦不是视口大小（尤其 0×0），
	# 鼠标就悬停不到它，滚轮/拖动全部失效、事件还会穿过去点世界。
	# 正常路径是 UIManager 的 size_changed → on_viewport_resized()，这里只是保险。
	if size != get_viewport_rect().size:
		on_viewport_resized()


## 铺满整个视口：地图直接铺到屏幕四边，没有留白
func _map_rect() -> Rect2:
	var s := size
	if s.x <= 1.0 or s.y <= 1.0:
		# 兜底：布局还没跑完时 size 可能是 0，直接用视口尺寸，避免整帧画不出来
		s = get_viewport_rect().size
	return Rect2(Vector2.ZERO, s)


## cover：等比放大到刚好盖住整块矩形（不留黑边），宁可裁掉边缘
func _cover_fit() -> bool:
	return true


## 罗盘式旋转：与小地图一致，"相机视线方向"始终朝上。
## （此前大地图固定北上，用户要求旋转功能对大地图同样生效）
func _rotates_with_view() -> bool:
	return true


# ============================================
# 构建
# ============================================

func _build_labels() -> void:
	_title = Label.new()
	_title.name = "BigMapTitle"
	_title.add_theme_font_size_override("font_size", 20)
	_title.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title)

	_hint = Label.new()
	_hint.name = "BigMapHint"
	_hint.text = "滚轮 缩放    ·    按住左键 拖动    ·    Q/E 旋转地图    ·    右键 复位    ·    [M] / [Esc] 关闭（游戏已暂停）"
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.82, 0.92, 0.85))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	_update_title()


## 显式铺满整个视口 + 摆放标签（不依赖锚点，避免 _ready 里拿到 0×0 的老坑）
func on_viewport_resized() -> void:
	var vp := get_viewport_rect().size
	# 必须显式给：这既决定画多大，也决定鼠标命中区（0×0 就收不到滚轮/拖动）
	position = Vector2.ZERO
	size = vp
	if _title != null:
		_title.position = Vector2(0.0, 14.0)
		_title.size = Vector2(vp.x, TITLE_H)
	if _hint != null:
		_hint.position = Vector2(0.0, 44.0)
		_hint.size = Vector2(vp.x, HINT_H)
	queue_redraw()


## UIManager 在面板被显示时调用：回到玩家所在处（缩放保持不变）
func on_shown() -> void:
	refresh_map()
	focus_on_player()


func _on_view_changed() -> void:
	_update_title()


func _update_title() -> void:
	if _title == null:
		return
	_title.text = "世界地图      x%.1f" % _zoom


# ============================================
# 绘制
# ============================================

func _draw_before_map() -> void:
	# 屏幕底色：底图还没生成好时也有干净的背景，不会漏出 HUD
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.045, 0.065, 1.0))


func _draw_after_map(_rect: Rect2) -> void:
	# 上下压条必须画在底图**之后**：底图是不透明的，画在前面会被整个盖住。
	# 地形铺满屏幕后，标题/图例是直接压在地形上的，不加暗底看不清。
	draw_rect(Rect2(0.0, 0.0, size.x, TOP_BAND), Color(0.025, 0.035, 0.055, 0.78))
	draw_rect(Rect2(0.0, size.y - BOTTOM_BAND, size.x, BOTTOM_BAND), Color(0.025, 0.035, 0.055, 0.78))
	_draw_north()
	_draw_legend()


## 指北标：与小地图同款逻辑（N 沿旋转后的北向绕边框走，文字正立不倒转）。
## 大地图四边被上下压条占了，N 靠到边框时夹进压条内侧，避免被压条盖住。
func _draw_north() -> void:
	var f := ThemeDB.fallback_font
	if f == null:
		return
	var rect := _map_rect()
	# 北 = 世界 -Z。地图旋转后，北的屏幕方向 = Rot2(a)·(0,-1)
	var dir := _rot2(Vector2(0.0, -1.0))
	var p := rect.get_center() + dir * (minf(rect.size.x, rect.size.y) * 0.5 - 24.0)
	# 夹进上下压条之间的可视区
	p.y = clampf(p.y, TOP_BAND + 14.0, size.y - BOTTOM_BAND - 8.0)
	draw_string(f, p + Vector2(-4.0, 4.0), "N",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.9))


func _draw_legend() -> void:
	var f := ThemeDB.fallback_font
	if f == null:
		return
	if _legend.is_empty():
		_ensure_legend()
	if _legend.is_empty():
		return

	var item_gap: float = 18.0
	var swatch: float = 11.0
	var font_size: int = 13
	var y: float = size.y - BOTTOM_BAND * 0.5

	# 先量总宽，再整体居中
	var total: float = 0.0
	for item in _legend:
		var label: String = str(item.get("name", ""))
		total += swatch + 5.0 + f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	total += item_gap * float(maxi(_legend.size() - 1, 0))

	var x: float = (size.x - total) * 0.5
	for item in _legend:
		var label: String = str(item.get("name", ""))
		var col: Color = item.get("color", Color(0.5, 0.5, 0.5))
		draw_rect(Rect2(x, y - swatch * 0.5, swatch, swatch), col)
		draw_rect(Rect2(x, y - swatch * 0.5, swatch, swatch), Color(0, 0, 0, 0.5), false, 1.0)
		x += swatch + 5.0
		draw_string(f, Vector2(x, y + 4.5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			Color(0.85, 0.90, 0.98))
		x += f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + item_gap


func _ensure_legend() -> void:
	var gen := _get_map_gen()
	if gen == null or not gen.has_method("get_terrain_legend"):
		return
	var legend: Array = gen.get_terrain_legend()
	if not legend.is_empty():
		_legend = legend
