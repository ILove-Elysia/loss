class_name MapRenderer
extends Node
## 地图渲染器。
## ------------------------------------------------------------
## 职责：
##   1. 维护一张 200×200 的 Image + ImageTexture，作为画布
##   2. 提供“海洋填充”“裸岛底色”“按扩散层逐步揭示地形”三类绘制操作
##   3. 增量动画：按 dist 升序排序陆地块，每帧只重绘新增格子，性能稳定
##
## 设计说明：
##   · 颜色来自 TerrainPalette 资源（可在检视面板替换预设）
##   · 噪点（自然质感）由本节点内部生成，纯视觉、不影响边界
##   · 不持有 MapData，每帧从外部传入，避免数据/视图耦合

# 渲染目标
var _image: Image
var _texture: ImageTexture

# 颜色表（运行时由 palette 计算，避免每像素访问 Color 的开销）
# _tc 按 [r,g,b, r,g,b, ...] 平铺，地形 id → 3 字节
var _tc: PackedByteArray = PackedByteArray()

# 噪点表：每格 0~17 的细微亮度偏移，增添自然质感
var _noise: PackedByteArray

# 预计算：每个陆地块的最终颜色（含噪点），扩散完成态直接拷贝
var _final_bytes: PackedByteArray
# 预计算：陆地块索引按 dist 升序（动画揭示顺序）
var _order: PackedInt32Array
# 动画已揭示到 _order 的哪个位置
var _reveal_cursor: int = 0


# ------------------------------------------------------------
# 初始化：创建 Image / Texture，预生成噪点
# ------------------------------------------------------------
func setup(palette: TerrainPalette) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var n: int = W * H

	# 创建空白 RGBA 图像
	_image = Image.create(W, H, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)

	# 重新计算颜色字节表（palette 可能被替换）
	_rebuild_color_table(palette)

	# 预生成每格噪点（基于坐标的稳定哈希，保证同一坐标噪点不变）
	_noise.resize(n)
	for y in range(H):
		for x in range(W):
			_noise[y * W + x] = _hash2(x, y) % 18

	# 分配最终颜色缓冲
	_final_bytes.resize(n * 4)
	_reveal_cursor = 0
	_order.resize(0)


# 返回当前 Texture（供 TextureRect 绑定）
func get_texture() -> ImageTexture:
	return _texture


# ------------------------------------------------------------
# 计算颜色字节表：地形色 → 0~255 三通道平铺
# ------------------------------------------------------------
func _rebuild_color_table(palette: TerrainPalette) -> void:
	var n: int = TerrainDefs.T_COUNT
	_tc.resize(n * 3)
	for t in range(n):
		var c: Color = palette.terrain_colors[t]
		_tc[t * 3 + 0] = int(c.r8)
		_tc[t * 3 + 1] = int(c.g8)
		_tc[t * 3 + 2] = int(c.b8)


# ------------------------------------------------------------
# 阶段 1：海洋填充全图
# 一次性构建字节缓冲再 set_data，比逐像素 set_pixel 快两个数量级。
# ------------------------------------------------------------
func render_ocean(palette: TerrainPalette) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var n: int = W * H
	var r: int = int(palette.ocean_color.r8)
	var g: int = int(palette.ocean_color.g8)
	var b: int = int(palette.ocean_color.b8)
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(n * 4)
	for i in range(n):
		var off: int = i * 4
		buf[off + 0] = r
		buf[off + 1] = g
		buf[off + 2] = b
		buf[off + 3] = 255
	_image.set_data(W, H, false, Image.FORMAT_RGBA8, buf)
	_texture.update(_image)


# ------------------------------------------------------------
# 阶段 2：基于 data 预计算“最终态颜色”与“揭示顺序”
# ------------------------------------------------------------
func prepare_reveal(data: MapData, palette: TerrainPalette) -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var n: int = W * H

	# —— 1) 每个陆地块的最终颜色（地形色 + 噪点偏移）——
	# 海洋保持海洋蓝；陆地按所属地形上色，并叠加细微亮度变化
	var orr: int = int(palette.ocean_color.r8)
	var og: int = int(palette.ocean_color.g8)
	var ob: int = int(palette.ocean_color.b8)
	var br: int = int(palette.base_color.r8)
	var bg: int = int(palette.base_color.g8)
	var bb: int = int(palette.base_color.b8)

	for i in range(n):
		var off: int = i * 4
		if data.island[i] == 0:
			# 海洋
			_final_bytes[off + 0] = orr
			_final_bytes[off + 1] = og
			_final_bytes[off + 2] = ob
			_final_bytes[off + 3] = 255
		else:
			var t: int = data.grid[i]
			if t == 255:
				# 陆地但未被扩散到达（极端情况）：用岛屿底色
				_final_bytes[off + 0] = br
				_final_bytes[off + 1] = bg
				_final_bytes[off + 2] = bb
				_final_bytes[off + 3] = 255
			else:
				# 地形色 + 噪点（亮度上下浮动 ~7%）
				var nz: int = _noise[i]
				_final_bytes[off + 0] = clampi(_tc[t * 3 + 0] + (nz - 9), 0, 255)
				_final_bytes[off + 1] = clampi(_tc[t * 3 + 1] + (nz - 9), 0, 255)
				_final_bytes[off + 2] = clampi(_tc[t * 3 + 2] + (nz - 9), 0, 255)
				_final_bytes[off + 3] = 255

	# —— 2) 按扩散层排序陆地块（dist 升序）——
	# 用桶排序：O(n)，比 Array.sort() 快且无装箱
	var max_d: int = data.max_dist
	# 每个桶存放该 dist 层的所有陆地块索引
	var buckets: Array = []
	buckets.resize(max_d + 1)
	for d in range(max_d + 1):
		buckets[d] = []
	for i in range(n):
		if data.island[i] == 1 and data.dist[i] >= 0:
			buckets[data.dist[i]].append(i)
	# 拼接成线性揭示顺序
	_order.resize(0)
	for d in range(max_d + 1):
		for idx in buckets[d]:
			_order.append(idx)
	_reveal_cursor = 0

	# —— 3) 把图像初始化为“海洋 + 裸岛底色”（尚未揭示地形）——
	# 裸岛底色让用户先看到岛屿轮廓，再看到地形逐步扩散覆盖
	var img_bytes: PackedByteArray = _image.get_data()
	for i in range(n):
		var off: int = i * 4
		if data.island[i] == 0:
			img_bytes[off + 0] = orr
			img_bytes[off + 1] = og
			img_bytes[off + 2] = ob
			img_bytes[off + 3] = 255
		else:
			img_bytes[off + 0] = br
			img_bytes[off + 1] = bg
			img_bytes[off + 2] = bb
			img_bytes[off + 3] = 255
	_image.set_data(W, H, false, Image.FORMAT_RGBA8, img_bytes)
	_texture.update(_image)


# ------------------------------------------------------------
# 阶段 3：按进度 [0,1] 揭示地形（增量更新）
# ------------------------------------------------------------
func reveal_to(progress: float) -> void:
	if _order.size() == 0:
		return
	var target: int = int(clampf(progress, 0.0, 1.0) * float(_order.size()))
	if target <= _reveal_cursor:
		return
	# 取出当前图像字节缓冲，批量改写新增格子
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	var img_bytes: PackedByteArray = _image.get_data()
	while _reveal_cursor < target:
		var i: int = _order[_reveal_cursor]
		var off: int = i * 4
		img_bytes[off + 0] = _final_bytes[off + 0]
		img_bytes[off + 1] = _final_bytes[off + 1]
		img_bytes[off + 2] = _final_bytes[off + 2]
		img_bytes[off + 3] = 255
		_reveal_cursor += 1
	_image.set_data(W, H, false, Image.FORMAT_RGBA8, img_bytes)
	_texture.update(_image)


# 一次性揭示全部剩余格子（动画结束的保险）。
# 直接把整张最终态颜色拷贝到图像，一步到位。
func reveal_all() -> void:
	var W: int = TerrainDefs.W
	var H: int = TerrainDefs.H
	_image.set_data(W, H, false, Image.FORMAT_RGBA8, _final_bytes.duplicate())
	_texture.update(_image)
	_reveal_cursor = _order.size()


# ------------------------------------------------------------
# 稳定哈希：同一坐标每次返回同一噪点值
# ------------------------------------------------------------
func _hash2(x: int, y: int) -> int:
	var h: int = (x * 73856093) ^ (y * 19349663)
	return absi(h)
