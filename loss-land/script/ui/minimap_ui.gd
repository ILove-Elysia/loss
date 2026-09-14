# script/ui/minimap_ui.gd
# ============================================
# 小地图（HUD 常驻组件，右上角）
#
# 交互（用户 2026-09-12 约定）：
#   - **没有快捷键**，只由右上角按钮开关（M 键归大地图用）
#   - 鼠标在小地图内：滚轮缩放、按住左键拖动查看、右键复位
#
# 为什么不做成 UIManager 面板：常驻的前提是"不受 Esc 面板栈影响"。
# 之前它注册进面板栈，Esc 关栈顶时会把它一起关掉。
#
# 与大地图的关系：缩放/平移/底图/标记的实现在基类 MapView 里，
# 这里只负责"200×200 的面板外观 + 坐标行 + 指北标"。
# ============================================

class_name MinimapUI
extends MapView

## 底图边长（像素）
const MAP_PX := 200
## 面板内边距
const PANEL_PAD := 6
## 底图与底部坐标行的间距
const INFO_GAP := 4
## 底部坐标行高度
const INFO_H := 16

var _info: Label = null
var _bg: StyleBoxFlat = null


## 面板宽度（HUD 用它给小地图预留位置，关掉地图时按钮才不会左右乱跳）
static func panel_width() -> float:
	return float(MAP_PX + PANEL_PAD * 2)


## 面板高度（底图 + 坐标行）
static func panel_height() -> float:
	return float(MAP_PX + PANEL_PAD * 2 + INFO_GAP + INFO_H)


func _setup_view() -> void:
	# 位置由 HUD 决定：这里只要求"填满父节点"。
	# 运行时 new 出来的控件在 _ready 里拿到的是 0×0，居中类锚点预设会算错；
	# FULL_RECT 是纯锚点（0→1、offset 归零），不依赖当前尺寸，可以放心用。
	set_anchors_preset(Control.PRESET_FULL_RECT, false)
	custom_minimum_size = Vector2(panel_width(), panel_height())

	_build_style()
	_build_info()


func _map_rect() -> Rect2:
	return Rect2(PANEL_PAD, PANEL_PAD, MAP_PX, MAP_PX)


## 罗盘式：转视角时整张小地图跟着转，屏幕上方永远是你面前看到的方向
func _rotates_with_view() -> bool:
	return true


func _process(delta: float) -> void:
	super._process(delta)
	if not visible:
		return
	_update_info()


# ============================================
# 外观
# ============================================

func _build_style() -> void:
	_bg = StyleBoxFlat.new()
	_bg.bg_color = Color(0.06, 0.08, 0.11, 0.78)
	_bg.set_corner_radius_all(8)
	_bg.set_border_width_all(1)
	_bg.border_color = Color(0.72, 0.80, 0.95, 0.35)


func _build_info() -> void:
	_info = Label.new()
	_info.name = "CoordInfo"
	_info.text = "X 0  Z 0"
	_info.add_theme_font_size_override("font_size", 12)
	_info.add_theme_color_override("font_color", Color(0.85, 0.90, 1.0, 0.9))
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_info)
	_layout_info()


func _layout_info() -> void:
	if _info == null:
		return
	_info.position = Vector2(PANEL_PAD, PANEL_PAD + MAP_PX + INFO_GAP)
	_info.size = Vector2(MAP_PX, INFO_H)


func _draw_before_map() -> void:
	if _bg != null:
		draw_style_box(_bg, Rect2(Vector2.ZERO, size))


func _draw_after_map(rect: Rect2) -> void:
	_draw_north(rect)


func _draw_north(map_rect: Rect2) -> void:
	var f := ThemeDB.fallback_font
	if f == null:
		return
	# 北 = 世界 -Z。地图旋转后，北的屏幕方向 = Rot2(a)·(0,-1)，
	# N 标沿该方向贴着边框内侧走（不随地图倒转，文字始终正立可读）
	var dir := _rot2(Vector2(0.0, -1.0))
	var p := map_rect.get_center() + dir * (minf(map_rect.size.x, map_rect.size.y) * 0.5 - 11.0)
	draw_string(f, p + Vector2(-4.0, 4.0), "N",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))


# ============================================
# 私有
# ============================================

func _update_info() -> void:
	if _info == null:
		return
	var p := _get_player()
	if p == null:
		return
	var pos: Vector3 = p.global_position
	# 缩放 >1 时补一个倍率，否则"拖走了但不知道自己在哪一层"很迷惑
	var suffix: String = "" if _zoom <= 1.001 else "  x%.1f" % _zoom
	_info.text = "X %d  Z %d%s" % [int(pos.x), int(pos.z), suffix]
