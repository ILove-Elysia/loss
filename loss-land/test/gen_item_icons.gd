# test/gen_item_icons.gd
# ============================================
# 一次性工具：程序化生成物品占位图标
#
# 运行：godot --headless --path . --script res://test/gen_item_icons.gd
# 之后需再跑一次 --editor --quit 触发资源导入。
#
# 产出：
#   art/icons/grass.png      草（绿色叶片）
#   art/icons/slime_gel.png  史莱姆凝胶（青色半圆凝胶块）
#   art/icons/battery.png    电池（深色外壳 + 黄色电量格）
# ============================================

extends SceneTree


const OUT_DIR := "res://art/icons"
const SIZE := 32


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_make_grass()
	_make_slime_gel()
	_make_battery()
	# 基础材料
	_make_log()
	_make_rock()
	_make_stick()
	# 工具（斧头/镐子共用画法，只换头部颜色）
	_make_axe(Color(0.62, 0.45, 0.26), "wooden_axe.png")
	_make_axe(Color(0.58, 0.59, 0.63), "stone_axe.png")
	_make_pick(Color(0.62, 0.45, 0.26), "wooden_pickaxe.png")
	_make_pick(Color(0.58, 0.59, 0.63), "stone_pickaxe.png")
	# 武器
	_make_sword(Color(0.68, 0.52, 0.30), "wooden_sword.png")
	_make_sword(Color(0.72, 0.73, 0.77), "stone_sword.png")
	# 护甲
	_make_armor(Color(0.40, 0.78, 0.28), "grass_armor.png")
	_make_armor(Color(0.58, 0.40, 0.22), "wood_armor.png")
	# 建筑
	_make_workbench()
	_make_furnace()
	_make_storage_box()
	print("图标生成完毕")
	quit()


## 画一条直线（Bresenham 的简化版：按步数插值）
func _line(img: Image, x0: int, y0: int, x1: int, y1: int, color: Color, thickness: int = 1) -> void:
	var steps: int = maxi(absi(x1 - x0), absi(y1 - y0))
	if steps == 0:
		_rect(img, x0, y0, thickness, thickness, color)
		return
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var x: int = int(roundf(lerpf(float(x0), float(x1), t)))
		var y: int = int(roundf(lerpf(float(y0), float(y1), t)))
		_rect(img, x, y, thickness, thickness, color)


## 在 img 上画一个实心圆
func _circle(img: Image, cx: int, cy: int, r: int, color: Color) -> void:
	for y in range(SIZE):
		for x in range(SIZE):
			var dx: int = x - cx
			var dy: int = y - cy
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, color)


## 在 img 上画一个实心矩形
func _rect(img: Image, x0: int, y0: int, w: int, h: int, color: Color) -> void:
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if x >= 0 and x < SIZE and y >= 0 and y < SIZE:
				img.set_pixel(x, y, color)


## 画竖直叶片：底部在 (x_base, y_base)，向左右微弯
func _blade(img: Image, x_base: int, y_base: int, height: int, lean: int, color: Color) -> void:
	for i in range(height):
		var x: int = x_base + int(float(lean) * float(i) / float(height))
		var y: int = y_base - i
		if x >= 0 and x < SIZE and y >= 0 and y < SIZE:
			img.set_pixel(x, y, color)
			# 叶片加一点宽度
			if i < height - 2 and x + 1 < SIZE:
				img.set_pixel(x + 1, y, color.darkened(0.2))


func _make_grass() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	# 透明底
	# 四根叶片
	_blade(img, 8, 28, 20, -3, Color(0.35, 0.75, 0.25))
	_blade(img, 13, 28, 24, -1, Color(0.45, 0.85, 0.30))
	_blade(img, 18, 28, 22, 2, Color(0.40, 0.80, 0.28))
	_blade(img, 23, 28, 18, 4, Color(0.32, 0.70, 0.22))
	# 底部小结
	_rect(img, 7, 26, 18, 3, Color(0.55, 0.45, 0.20))
	img.save_png(OUT_DIR + "/grass.png")
	print("  grass.png")


func _make_slime_gel() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	# 凝胶主体：下半圆
	var base := Color(0.20, 0.80, 0.70)
	var hi := Color(0.45, 0.95, 0.85)
	for y in range(SIZE):
		for x in range(SIZE):
			var dx: float = (x - 15.5) / 11.0
			var dy: float = (y - 19.0) / 10.0
			if dx * dx + dy * dy <= 1.0 and y <= 19:
				img.set_pixel(x, y, base)
	# 顶部高光
	_circle(img, 12, 13, 3, hi)
	# 两个小气泡
	_circle(img, 20, 15, 1, hi)
	_circle(img, 17, 10, 1, hi)
	# 底部阴影
	_rect(img, 8, 27, 16, 2, Color(0.15, 0.55, 0.50, 0.6))
	img.save_png(OUT_DIR + "/slime_gel.png")
	print("  slime_gel.png")


func _make_battery() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	# 外壳（深灰）
	_rect(img, 7, 6, 18, 22, Color(0.20, 0.22, 0.26))
	# 顶部正极
	_rect(img, 13, 3, 6, 3, Color(0.55, 0.58, 0.62))
	# 电量格（黄绿），3 格
	_rect(img, 10, 9, 12, 4, Color(0.95, 0.85, 0.20))
	_rect(img, 10, 15, 12, 4, Color(0.95, 0.85, 0.20))
	_rect(img, 10, 21, 12, 4, Color(0.55, 0.50, 0.15))  # 最后一格半透明感（暗黄）
	# 高光
	_rect(img, 8, 8, 1, 18, Color(0.35, 0.38, 0.42))
	img.save_png(OUT_DIR + "/battery.png")
	print("  battery.png")


# ============================================
# 基础材料
# ============================================

func _make_log() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_rect(img, 3, 11, 26, 11, Color(0.55, 0.38, 0.20))   # 木身
	_rect(img, 3, 11, 26, 2, Color(0.68, 0.50, 0.28))    # 顶部高光
	_rect(img, 3, 20, 26, 2, Color(0.40, 0.26, 0.14))    # 底部阴影
	_circle(img, 8, 16, 4, Color(0.72, 0.55, 0.32))      # 左侧年轮
	_circle(img, 8, 16, 2, Color(0.40, 0.26, 0.14))
	img.save_png(OUT_DIR + "/log.png")
	print("  log.png")


func _make_rock() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_circle(img, 15, 18, 9, Color(0.55, 0.56, 0.60))
	_circle(img, 12, 14, 5, Color(0.70, 0.71, 0.75))     # 左上受光面
	_rect(img, 8, 25, 15, 3, Color(0.38, 0.39, 0.43))    # 底部阴影
	img.save_png(OUT_DIR + "/rock.png")
	print("  rock.png")


func _make_stick() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_line(img, 6, 27, 25, 6, Color(0.48, 0.33, 0.17), 3)
	_line(img, 6, 27, 25, 6, Color(0.68, 0.50, 0.28), 1)
	img.save_png(OUT_DIR + "/stick.png")
	print("  stick.png")


# ============================================
# 工具 / 武器 / 护甲（共用画法，换颜色即可）
# ============================================

func _make_axe(head_color: Color, filename: String) -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_line(img, 8, 28, 21, 10, Color(0.52, 0.36, 0.19), 2)      # 木柄
	_rect(img, 16, 5, 9, 9, head_color)                        # 斧头
	_rect(img, 16, 5, 9, 2, head_color.lightened(0.25))        # 刃口高光
	_rect(img, 16, 12, 9, 2, head_color.darkened(0.25))        # 下缘阴影
	img.save_png(OUT_DIR + "/" + filename)
	print("  " + filename)


func _make_pick(head_color: Color, filename: String) -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_line(img, 8, 28, 21, 10, Color(0.52, 0.36, 0.19), 2)      # 木柄
	_line(img, 11, 9, 27, 4, head_color, 2)                    # 镐头（横贯）
	_line(img, 11, 9, 27, 4, head_color.lightened(0.25), 1)
	img.save_png(OUT_DIR + "/" + filename)
	print("  " + filename)


func _make_sword(blade_color: Color, filename: String) -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_line(img, 16, 26, 16, 5, blade_color, 4)                  # 剑身
	_line(img, 15, 25, 15, 6, blade_color.lightened(0.25), 1)  # 剑身高光
	_rect(img, 12, 25, 9, 2, Color(0.42, 0.28, 0.15))          # 护手
	_rect(img, 15, 27, 3, 4, Color(0.42, 0.28, 0.15))          # 握柄
	img.save_png(OUT_DIR + "/" + filename)
	print("  " + filename)


func _make_armor(color: Color, filename: String) -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_rect(img, 8, 7, 16, 19, color)                            # 胸甲主体
	_rect(img, 8, 7, 16, 3, color.lightened(0.22))             # 肩部受光
	_rect(img, 8, 7, 4, 19, color.darkened(0.18))              # 左侧阴影
	_rect(img, 13, 12, 6, 9, color.darkened(0.32))             # 中间凹槽
	img.save_png(OUT_DIR + "/" + filename)
	print("  " + filename)


# ============================================
# 建筑
# ============================================

func _make_workbench() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_rect(img, 3, 10, 26, 6, Color(0.55, 0.38, 0.20))         # 台面
	_rect(img, 3, 10, 26, 2, Color(0.68, 0.50, 0.28))          # 台面高光
	_rect(img, 6, 16, 3, 13, Color(0.40, 0.26, 0.14))          # 左腿
	_rect(img, 23, 16, 3, 13, Color(0.40, 0.26, 0.14))         # 右腿
	_rect(img, 11, 5, 5, 5, Color(0.58, 0.59, 0.63))           # 台上的石块
	_line(img, 21, 27, 27, 21, Color(0.45, 0.47, 0.50), 2)     # 靠着的木板
	img.save_png(OUT_DIR + "/workbench.png")
	print("  workbench.png")


func _make_furnace() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_rect(img, 5, 9, 22, 19, Color(0.52, 0.53, 0.57))          # 炉体
	_rect(img, 5, 9, 22, 3, Color(0.70, 0.71, 0.75))           # 顶部受光
	_rect(img, 10, 17, 12, 9, Color(0.75, 0.28, 0.08))         # 炉口
	_rect(img, 12, 20, 8, 5, Color(1.0, 0.78, 0.22))           # 火焰
	_rect(img, 8, 3, 6, 6, Color(0.40, 0.41, 0.45))            # 烟囱
	img.save_png(OUT_DIR + "/furnace.png")
	print("  furnace.png")


func _make_storage_box() -> void:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	_rect(img, 5, 12, 22, 15, Color(0.55, 0.38, 0.20))         # 箱体
	_rect(img, 5, 9, 22, 4, Color(0.68, 0.50, 0.28))           # 箱盖
	_rect(img, 5, 20, 22, 2, Color(0.40, 0.26, 0.14))          # 箱盖缝隙
	_rect(img, 14, 18, 4, 6, Color(0.78, 0.66, 0.25))          # 锁扣
	img.save_png(OUT_DIR + "/storage_box.png")
	print("  storage_box.png")
