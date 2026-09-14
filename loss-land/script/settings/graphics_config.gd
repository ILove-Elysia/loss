# script/settings/graphics_config.gd
# ============================================
# 图像设置后端：分辨率 / 全屏 / 界面缩放 / 垂直同步 / 帧率上限
#
# 为什么是独立的静态类：
#   - 分辨率与全屏必须**在任何 UI 出现之前**生效，而面板是懒加载的
#     （GraphicsUI 要等玩家点开设置才被创建），所以"存"和"用"得放在这里。
#   - 静态类没有 _ready，用一次性守卫（_ensure）延迟读盘。
#     与 DebugConfig（script/debug/debug_config.gd）同一套路，不用 autoload
#     （autoload 在 `godot --script` 下不加载，会让 headless 测试整体编译失败）。
#
# 谁负责在启动时应用：UIManager._ready() —— 主菜单与地图两个场景都有它。
#
# 与 project.godot 的关系（重要）：
#   [display] 里设计基准是 1280×720 + stretch mode = canvas_items + aspect = expand，
#   所以 get_viewport_rect() 拿到的是**设计单位**（恒为 1280×720），引擎负责把
#   整块 2D/UI 缩放到实际窗口大小 —— 换分辨率时 HUD/面板/字号的比例不会变。
#   本类改的是**窗口尺寸**（DisplayServer.window_set_size），不是设计基准，
#   两者是不同层：设计基准动一下全项目 UI 坐标都要重算，窗口尺寸随便改。
#   —— 这也意味着界面坐标永远按 1280×720 来写，别按实际分辨率算。
#
# 扩展点（用户说"其他图像设置待后续补充"）：
#   加 static var + 在 apply_all() 里加一行应用，再到 GraphicsUI 加控件即可。
#   候选：无边框/独占全屏、渲染缩放（viewport scaling_3d_scale）、
#        抗锯齿（MSAA）、阴影质量、草丛/粒子密度、亮度（伽马）。
# ============================================

class_name GraphicsConfig
extends RefCounted

const SAVE_PATH := "user://graphics_config.cfg"
const SECTION := "graphics"

## 分辨率候选（覆盖常见宽高比的常用档位，按宽高比分组）。
## 真正可用的会被屏幕尺寸过滤；当前窗口尺寸若不在表里也会动态补进下拉框。
## 注意：设计基准是 1280×720（16:9），stretch/aspect=expand 会在非 16:9 时
## 保持基准比例铺满并裁掉溢出边（可能切到 HUD），属既有设计，不在本表处理。
const RESOLUTIONS: Array = [
	# --- 16:9 ---
	Vector2i(3840, 2160),  # 4K UHD
	Vector2i(2560, 1440),  # 2K / QHD
	Vector2i(2048, 1152),  # 2K (2048p)
	Vector2i(1920, 1080),  # 1080p FHD
	Vector2i(1600, 900),   # HD+
	Vector2i(1366, 768),   # 笔记本常见
	Vector2i(1280, 720),   # 720p HD
	# --- 16:10 ---
	Vector2i(2560, 1600),  # WQXGA
	Vector2i(1920, 1200),  # WUXGA
	Vector2i(1680, 1050),  # WSXGA+
	Vector2i(1440, 900),   # WXGA+
	Vector2i(1280, 800),   # WXGA
	# --- 4:3 ---
	Vector2i(1600, 1200),  # UXGA
	Vector2i(1400, 1050),  # SXGA+
	Vector2i(1280, 960),   # 4:3
	Vector2i(1024, 768),   # XGA
	# --- 5:4 ---
	Vector2i(1280, 1024),  # SXGA
	# --- 21:9 带鱼屏 ---
	Vector2i(3440, 1440),  # UWQHD
	Vector2i(2560, 1080),  # UW-FHD
	# --- 32:9 超宽带鱼屏 ---
	Vector2i(5120, 1440),  # DQHD
]

## 帧率上限候选。0 = 不限制（交给垂直同步/引擎）。
const FPS_LIMITS: Array = [0, 30, 60, 120, 144]

## 垂直同步候选。用数组而不是散落的常量，UI 才能按下标与标签一一对应。
const VSYNC_MODES: Array = [
	DisplayServer.VSYNC_DISABLED,
	DisplayServer.VSYNC_ENABLED,
	DisplayServer.VSYNC_ADAPTIVE,
	DisplayServer.VSYNC_MAILBOX,
]

## 界面缩放范围。1.0 = 完全交给引擎按窗口自动算。
const MIN_UI_SCALE: float = 0.7
const MAX_UI_SCALE: float = 2.0

# ---------------- 内部状态 ----------------

static var fullscreen: bool = false
static var window_size: Vector2i = Vector2i(1280, 720)
static var ui_scale: float = 1.0
static var vsync_mode: int = DisplayServer.VSYNC_ENABLED
static var fps_limit: int = 0
## 是否读到过配置文件。没读到就不去动窗口，直接用 project.godot 的默认值
## （首次进游戏的窗口尺寸应该由项目设置决定，而不是被这里硬改成 1280×720）
static var has_saved_config: bool = false
static var _loaded: bool = false


# ---------------- 读 / 写 ----------------

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true

	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	fullscreen = bool(cfg.get_value(SECTION, "fullscreen", fullscreen))
	window_size = cfg.get_value(SECTION, "window_size", window_size)
	ui_scale = clampf(float(cfg.get_value(SECTION, "ui_scale", ui_scale)),
		MIN_UI_SCALE, MAX_UI_SCALE)
	vsync_mode = int(cfg.get_value(SECTION, "vsync", vsync_mode))
	fps_limit = int(cfg.get_value(SECTION, "fps_limit", fps_limit))
	has_saved_config = true


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "fullscreen", fullscreen)
	cfg.set_value(SECTION, "window_size", window_size)
	cfg.set_value(SECTION, "ui_scale", ui_scale)
	cfg.set_value(SECTION, "vsync", vsync_mode)
	cfg.set_value(SECTION, "fps_limit", fps_limit)
	# 存盘失败（目录不可写等）不该让游戏崩，静默忽略
	cfg.save(SAVE_PATH)
	has_saved_config = true


# ---------------- 应用 ----------------

## 启动时调用：读盘 + 应用一次
static func apply_saved() -> void:
	_ensure()
	apply_all()


static func apply_all() -> void:
	# headless（无窗口）环境下 DisplayServer 调用无意义，直接跳过
	if DisplayServer.get_name() == "headless":
		return
	Engine.max_fps = fps_limit
	DisplayServer.window_set_vsync_mode(vsync_mode)
	_apply_ui_scale()
	# 没存过配置就别动窗口：project.godot 里已经给了合适的初始窗口大小
	if has_saved_config and _can_control_window():
		_apply_window()


## 是否允许改窗口尺寸/位置/模式。
##
## 编辑器"内嵌游戏窗口"必须排除（真实事故 2026-09-12）：
## DisplayServer 会拒绝 resize/move（日志刷 "Embedded window can't be
## resized/moved"），**但 Window.size 在拒绝之前就已经被改成目标值**，
## _update_viewport_size() 照常执行 —— 游戏按 1920×1080 渲染、内嵌区域却只有
## 1280×720，只显示画面左上角：底部快捷栏/右上小地图整体"消失"，
## 居中面板全部偏右下，看起来就像"界面缩放把布局搞坏了"。
static var _embedded_noted: bool = false

## 是否允许改窗口尺寸/位置/模式。
##
## 编辑器里跑（F5 内嵌窗口，或编辑器内单独窗口）都不行：
##   ① root.is_embedded() —— F5 内嵌窗口由编辑器接管，DisplayServer 会拒绝
##      resize/move（日志刷 "Embedded window can't be resized/moved"）且无效；
##   ② Engine.is_editor_hint() —— 比 is_embedded 更稳，能兜住"某些 4.x 版本
##      is_embedded 对根窗口返回不准而漏拦"的情况，也覆盖"编辑器内单独窗口"。
## 注意："项目 → 运行项目" 与导出 exe 都是**独立进程**，is_editor_hint()=false
## 且 is_embedded()=false → 本函数返回 true，分辨率/全屏在那里才会真正生效。
static func _can_control_window() -> bool:
	var embedded := false
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root: Window = (loop as SceneTree).root
		if root != null:
			embedded = root.is_embedded()
	if embedded or Engine.is_editor_hint():
		if not _embedded_noted:
			_embedded_noted = true
			print("GraphicsConfig: 检测到编辑器/内嵌运行，跳过窗口尺寸与全屏设置（仅存盘，独立运行游戏时生效）。")
		return false
	return true


static func _apply_window() -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED)
	if not fullscreen:
		_apply_window_size()


## 窗口尺寸：先按屏幕夹一次，再居中。
## 夹：4K 屏选的档位若比当前屏还大，直接设过去会得到一个超出屏幕、
##     抓不到标题栏的窗口。
## 居中：不居中时改分辨率窗口会跑到屏幕角落，很容易被误认为"窗口不见了"。
static func _apply_window_size() -> void:
	var usable := _usable_rect()
	var target := clamp_to_screen(window_size, usable)
	# 被屏幕限制时把内存值也改掉，否则界面上显示的档位和实际窗口尺寸对不上
	if target != window_size:
		window_size = target
	DisplayServer.window_set_size(target)
	DisplayServer.window_set_position(usable.position + (usable.size - target) / 2)


## 界面缩放：在引擎"按窗口自动算"的倍率之上再乘一个系数。
## 调大 → 整个 2D/UI 等比变大（3D 不受影响），配合 canvas_items 拉伸模式生效。
static func _apply_ui_scale() -> void:
	var win := _root_window()
	if win != null:
		win.content_scale_factor = ui_scale


## 屏幕可用区域（扣掉任务栏）。
## 用 usable 而不是 screen_get_size：贴着任务栏的窗口在 Windows 上会被算成"最大化"。
static func _usable_rect() -> Rect2i:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		usable = Rect2i(Vector2i.ZERO, DisplayServer.screen_get_size(screen))
	return usable


static func clamp_to_screen(size: Vector2i, usable: Rect2i) -> Vector2i:
	if usable.size.x <= 0 or usable.size.y <= 0:
		return size
	return Vector2i(mini(size.x, usable.size.x), mini(size.y, usable.size.y))


static func _root_window() -> Window:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root
	return null


# ---------------- 对外修改接口（立刻生效并落盘） ----------------

static func set_fullscreen(on: bool) -> void:
	_ensure()
	fullscreen = on
	if _can_control_window():
		_apply_window()
	save()


static func set_window_size(size: Vector2i) -> void:
	_ensure()
	window_size = size
	# 内嵌运行时改不了窗口，但配置值照存——独立运行游戏时会生效
	if not fullscreen and _can_control_window():
		_apply_window_size()
	save()


static func set_ui_scale(value: float) -> void:
	_ensure()
	ui_scale = clampf(value, MIN_UI_SCALE, MAX_UI_SCALE)
	if DisplayServer.get_name() != "headless":
		_apply_ui_scale()
	save()


static func set_vsync(mode: int) -> void:
	_ensure()
	vsync_mode = mode
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(vsync_mode)
	save()


static func set_fps_limit(value: int) -> void:
	_ensure()
	fps_limit = value
	Engine.max_fps = fps_limit
	save()


# ---------------- 下拉框候选与文案 ----------------

## 分辨率候选：预设档位过滤掉超出屏幕的，并把当前尺寸补进去
static func resolution_choices() -> Array:
	_ensure()
	var usable := _usable_rect()
	var out: Array = []
	for r in RESOLUTIONS:
		var v: Vector2i = r
		if v.x <= usable.size.x and v.y <= usable.size.y:
			out.append(v)
	if not out.has(window_size):
		out.insert(0, window_size)
	if out.is_empty():
		out.append(window_size)
	return out


static func resolution_label(size: Vector2i) -> String:
	return "%d × %d" % [size.x, size.y]


static func vsync_label(mode: int) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED: return "关闭（画面可能撕裂）"
		DisplayServer.VSYNC_ADAPTIVE: return "自适应"
		DisplayServer.VSYNC_MAILBOX: return "Mailbox（低延迟）"
		_: return "开启"


static func fps_label(value: int) -> String:
	return "不限制" if value <= 0 else "%d" % value
