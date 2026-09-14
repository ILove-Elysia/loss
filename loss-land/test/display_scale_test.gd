# test/display_scale_test.gd
# ============================================
# 分辨率适配回归：设计基准 + 拉伸模式必须存在且自洽
#
# 为什么需要这个测试：
#   让"各分辨率下内容比例不变"的东西只写在 project.godot 的 [display] 段里，
#   没有任何代码引用它们 —— 谁手滑删掉或改错，游戏照样能跑、能编译、能过 lint，
#   只是换个分辨率 UI 比例就变了（而且很难当场看出来）。
#   所以这里把它当"不变量"钉住，和 gd_static_lint 一样属于"看不出来的故障"防线。
#
# 三个关键项：
#   stretch/mode   = canvas_items  2D/UI 按设计基准等比缩放（3D 不受影响）
#   stretch/aspect = expand        不拉伸变形：宽屏多看到一些，而不是压扁
#   设计基准 16:9                   与常见显示器一致，四种档位下观感统一
#
# 运行：
#   godot --headless --path . --script res://test/display_scale_test.gd
# ============================================

extends SceneTree

var _fail: int = 0


func _initialize() -> void:
	await process_frame

	print("--- [display] 拉伸配置 ---")
	_test_stretch_config()
	print("--- 界面缩放（GraphicsConfig.ui_scale） ---")
	_test_ui_scale()

	print("---------------------------------------")
	if _fail == 0:
		print("===== 分辨率适配检查全部通过 =====")
	else:
		print("===== 有 %d 项不通过 =====" % _fail)
	quit()


# ----------------------------------------
# 1. project.godot 的 [display] 段
# ----------------------------------------
func _test_stretch_config() -> void:
	# 注意不能写 var mode := ProjectSettings.get_setting(...)：
	# 它返回 Variant，:= 推断会直接让整个脚本解析失败（本项目踩过的坑）。
	var mode: String = str(ProjectSettings.get_setting("display/window/stretch/mode", "disabled"))
	_check(mode == "canvas_items",
		"拉伸模式 = canvas_items（当前 \"%s\"）" % mode)

	var aspect: String = str(ProjectSettings.get_setting("display/window/stretch/aspect", "keep"))
	_check(aspect == "expand",
		"拉伸宽高比 = expand（当前 \"%s\"）" % aspect)

	var scale_mode: String = str(ProjectSettings.get_setting("display/window/stretch/scale_mode", "fractional"))
	_check(scale_mode != "integer",
		"缩放模式不是 integer（integer 会留黑边、填不满屏幕；当前 \"%s\"）" % scale_mode)

	var w: int = int(ProjectSettings.get_setting("display/window/size/viewport_width", 0))
	var h: int = int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	_check(w >= 640 and h >= 360, "设计基准尺寸有效（%d × %d）" % [w, h])

	# 16:9：expand 的语义是"按宽高比扩展可视区域"，基准不是 16:9 时
	# 常见显示器上会多看到/少看到一截，HUD 边角位置也会跟着漂。
	var ratio: float = float(w) / float(h)
	_check(absf(ratio - 16.0 / 9.0) < 0.01,
		"设计基准是 16:9（%d × %d = %.3f）" % [w, h, ratio])


# ----------------------------------------
# 2. 界面缩放：夹取 + 真的落到 Window 上
#
# 会写 user://graphics_config.cfg，所以先备份、结束前原样还原
# （否则玩家跑一次测试就把自己的分辨率设置冲掉了）。
# ----------------------------------------
func _test_ui_scale() -> void:
	var existed: bool = FileAccess.file_exists(GraphicsConfig.SAVE_PATH)
	var backup := PackedByteArray()
	if existed:
		backup = FileAccess.get_file_as_bytes(GraphicsConfig.SAVE_PATH)

	GraphicsConfig.set_ui_scale(5.0)
	_check(is_equal_approx(GraphicsConfig.ui_scale, GraphicsConfig.MAX_UI_SCALE),
		"超过上限被夹取（5.0 → %.2f）" % GraphicsConfig.ui_scale)

	GraphicsConfig.set_ui_scale(0.1)
	_check(is_equal_approx(GraphicsConfig.ui_scale, GraphicsConfig.MIN_UI_SCALE),
		"低于下限被夹取（0.1 → %.2f）" % GraphicsConfig.ui_scale)

	GraphicsConfig.set_ui_scale(1.25)
	_check(is_equal_approx(root.content_scale_factor, 1.25),
		"缩放系数已应用到 Window.content_scale_factor（%.2f）" % root.content_scale_factor)

	# 还原：内存值 + 引擎状态 + 配置文件
	GraphicsConfig.set_ui_scale(1.0)
	if existed:
		var f := FileAccess.open(GraphicsConfig.SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(backup)
			f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GraphicsConfig.SAVE_PATH))


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  [OK] ", what)
	else:
		print("  [FAIL] ", what)
		_fail += 1
