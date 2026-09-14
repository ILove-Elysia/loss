class_name LegendPanel
extends Panel
## 地形图例面板（纯运行时构建，便于在 .tscn 中作为一个节点挂载）。
## ------------------------------------------------------------
## 职责：
##   · 根据 TerrainPalette 资源渲染 6 种地形的色块 / 名称 / 危险度
##   · 提供 apply_palette() 在运行时切换预设后刷新
##
## 注意：
##   本节点本身是 Panel，已自带背景；内部用 MarginContainer + VBox 布局。

# 内部引用：每行 [ColorRect, Label 名称, Label 危险度]
# 便于切换 palette 后就地更新颜色与文字，无需重建整棵子树
var _rows: Array = []
var _head_label: Label


func _ready() -> void:
	_build_layout()


# ------------------------------------------------------------
# 构建一次性的布局骨架（标题 + 6 行）
# ------------------------------------------------------------
func _build_layout() -> void:
	# 最小宽度，避免在 HBox 中被挤压
	custom_minimum_size = Vector2(260, 0)

	# 外边距容器
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		m.add_theme_constant_override(side, 10)
	add_child(m)

	# 纵向排列
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	m.add_child(vb)

	# 标题
	_head_label = Label.new()
	_head_label.text = "地形图例"
	_head_label.add_theme_font_size_override("font_size", 14)
	vb.add_child(_head_label)

	# 6 行占位：实际内容在 apply_palette() 填入
	_rows.resize(TerrainDefs.T_COUNT)
	for t in range(TerrainDefs.T_COUNT):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(22, 22)
		row.add_child(sw)

		var nm := Label.new()
		nm.custom_minimum_size = Vector2(76, 0)
		row.add_child(nm)

		var dg := Label.new()
		dg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dg.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(dg)

		vb.add_child(row)
		_rows[t] = [sw, nm, dg]


# ------------------------------------------------------------
# 应用 palette：刷新色块、名称、危险度颜色
# ------------------------------------------------------------
func apply_palette(palette: TerrainPalette) -> void:
	for t in range(TerrainDefs.T_COUNT):
		var row: Array = _rows[t]
		var sw: ColorRect = row[0]
		var nm: Label = row[1]
		var dg: Label = row[2]
		sw.color = palette.terrain_colors[t]
		nm.text = palette.terrain_names[t]
		dg.text = palette.terrain_danger[t]
		# 危险度配色：安全=绿，中危=黄，高危=红
		match palette.terrain_danger[t]:
			"安全":
				dg.modulate = Color(0.40, 0.80, 0.45)
			"中危":
				dg.modulate = Color(0.98, 0.72, 0.22)
			"高危":
				dg.modulate = Color(0.92, 0.34, 0.32)
			_:
				dg.modulate = Color(0.90, 0.90, 0.90)
