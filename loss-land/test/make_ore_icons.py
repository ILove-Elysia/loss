# test/make_ore_icons.py
# 生成矿物链所需的 32x32 物品图标（纯标准库手写 PNG，不依赖 PIL）
# 产出：art/icons/iron_ore.png  coal.png  iron_ingot.png  iron_sword.png  iron_pickaxe.png
# 风格与既有 rock.png 一致：像素块、纯色描边、透明背景

import os
import struct
import zlib

SIZE = 32


class Canvas:
	def __init__(self, size: int = SIZE):
		self.size = size
		# 每个像素 (r, g, b, a)，初始全透明
		self.px = [[(0, 0, 0, 0) for _ in range(size)] for _ in range(size)]

	def set(self, x: int, y: int, c) -> None:
		if 0 <= x < self.size and 0 <= y < self.size:
			self.px[y][x] = c

	def rect(self, x0: int, y0: int, x1: int, y1: int, c) -> None:
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				self.set(x, y, c)

	def line(self, x0: int, y0: int, x1: int, y1: int, c, w: int = 1) -> None:
		# Bresenham，再按 w 加粗（w=2 时向右下各扩 1 像素）
		dx = abs(x1 - x0)
		dy = -abs(y1 - y0)
		sx = 1 if x0 < x1 else -1
		sy = 1 if y0 < y1 else -1
		err = dx + dy
		while True:
			for oy in range(w):
				for ox in range(w):
					self.set(x0 + ox, y0 + oy, c)
			if x0 == x1 and y0 == y1:
				break
			e2 = 2 * err
			if e2 >= dy:
				err += dy
				x0 += sx
			if e2 <= dx:
				err += dx
				y0 += sy

	def cut_corners(self, x0: int, y0: int, x1: int, y1: int, n: int = 2) -> None:
		# 把矩形四角切掉，让石块看起来不是死板的方块
		for i in range(n):
			for j in range(n - i):
				self.set(x0 + i, y0 + j, (0, 0, 0, 0))
				self.set(x1 - i, y0 + j, (0, 0, 0, 0))
				self.set(x0 + i, y1 - j, (0, 0, 0, 0))
				self.set(x1 - i, y1 - j, (0, 0, 0, 0))

	def save(self, path: str) -> None:
		raw = bytearray()
		for row in self.px:
			raw.append(0)  # 过滤类型 0
			for r, g, b, a in row:
				raw += bytes((r, g, b, a))

		def chunk(tag: bytes, data: bytes) -> bytes:
			return (struct.pack(">I", len(data)) + tag + data
				+ struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

		ihdr = struct.pack(">IIBBBBB", self.size, self.size, 8, 6, 0, 0, 0)
		png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
			+ chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
		with open(path, "wb") as f:
			f.write(png)


def rgb(r: float, g: float, b: float) -> tuple:
	return (int(r * 255), int(g * 255), int(b * 255), 255)


def make_iron_ore() -> Canvas:
	c = Canvas()
	base = rgb(0.55, 0.55, 0.60)
	light = rgb(0.68, 0.68, 0.73)
	dark = rgb(0.40, 0.40, 0.45)
	vein = rgb(0.86, 0.52, 0.20)
	vein2 = rgb(0.70, 0.40, 0.15)
	c.rect(7, 9, 24, 23, base)
	c.rect(8, 10, 23, 13, light)
	c.rect(7, 21, 24, 23, dark)
	c.cut_corners(7, 9, 24, 23, 2)
	for x, y in [(11, 13), (12, 13), (11, 14), (13, 16), (19, 17), (20, 17), (19, 18), (14, 20), (15, 20)]:
		c.set(x, y, vein)
	for x, y in [(12, 14), (20, 18), (15, 21)]:
		c.set(x, y, vein2)
	return c


def make_coal() -> Canvas:
	c = Canvas()
	base = rgb(0.15, 0.15, 0.17)
	light = rgb(0.30, 0.30, 0.34)
	lighter = rgb(0.42, 0.42, 0.47)
	c.rect(7, 9, 24, 23, base)
	c.rect(8, 10, 23, 12, light)
	c.cut_corners(7, 9, 24, 23, 2)
	# 煤的玻璃质高光
	for x, y in [(10, 12), (11, 12), (10, 13), (18, 16), (19, 16), (13, 19), (14, 19)]:
		c.set(x, y, lighter)
	return c


def make_ingot() -> Canvas:
	c = Canvas()
	body = rgb(0.72, 0.74, 0.78)
	top = rgb(0.88, 0.90, 0.93)
	side = rgb(0.52, 0.54, 0.59)
	# 梯形铁锭：上窄下宽，逐行外扩
	rows = [(17, 6), (18, 7), (19, 7), (20, 8), (21, 8),
		(22, 9), (23, 9), (24, 10), (25, 10), (26, 10)]
	for y, half in rows:
		for x in range(16 - half, 16 + half + 1):
			c.set(x, y, body)
	# 顶面亮边
	for x in range(10, 23):
		c.set(x, 17, top)
		c.set(x, 18, top)
	# 底部暗边 + 正中竖向凹槽（浇铸缝隙）
	c.rect(6, 26, 26, 26, side)
	c.rect(16, 20, 16, 26, side)
	return c


def make_sword() -> Canvas:
	c = Canvas()
	blade = rgb(0.80, 0.82, 0.86)
	edge = rgb(0.95, 0.96, 0.98)
	guard = rgb(0.45, 0.45, 0.50)
	grip = rgb(0.50, 0.34, 0.20)
	pommel = rgb(0.82, 0.70, 0.30)
	# 剑身
	c.rect(15, 4, 16, 21, blade)
	c.rect(15, 4, 15, 21, edge)
	# 剑尖收窄
	c.rect(15, 3, 16, 3, blade)
	# 护手
	c.rect(11, 22, 20, 23, guard)
	# 握柄
	c.rect(15, 24, 16, 28, grip)
	# 柄头
	c.rect(14, 29, 17, 30, pommel)
	return c


def make_pickaxe() -> Canvas:
	c = Canvas()
	head = rgb(0.78, 0.80, 0.84)
	head_dark = rgb(0.55, 0.57, 0.62)
	grip = rgb(0.50, 0.34, 0.20)
	# 镐头：从左到右略微上扬的粗线
	c.line(13, 9, 27, 13, head, 2)
	c.line(13, 11, 27, 15, head_dark, 1)
	# 木柄：从镐头中心斜向左下
	c.line(20, 12, 8, 27, grip, 2)
	return c


def make_crude_axe() -> Canvas:
	# 粗制石斧：粗糙石片 + 草绳绑扎，开局第一把斧头
	c = Canvas()
	stone = rgb(0.58, 0.58, 0.62)
	stone_dark = rgb(0.42, 0.42, 0.47)
	grip = rgb(0.50, 0.34, 0.20)
	bind = rgb(0.30, 0.62, 0.28)
	# 木柄：左下到右上
	c.line(9, 27, 21, 12, grip, 2)
	# 石刃：绑在柄顶端的粗糙石片
	c.rect(18, 4, 27, 12, stone)
	c.cut_corners(18, 4, 27, 12, 2)
	c.line(18, 12, 27, 12, stone_dark, 1)
	# 草绳绑扎：两道绿色斜线压在石刃与柄的交界处
	c.line(17, 11, 24, 14, bind, 1)
	c.line(19, 13, 26, 16, bind, 1)
	return c


def make_iron_axe() -> Canvas:
	# 铁斧：与粗制石斧同构，但刃是亮铁 + 外沿开刃
	c = Canvas()
	blade = rgb(0.80, 0.82, 0.86)
	edge = rgb(0.95, 0.96, 0.98)
	blade_dark = rgb(0.55, 0.57, 0.62)
	grip = rgb(0.50, 0.34, 0.20)
	# 木柄
	c.line(9, 27, 21, 12, grip, 2)
	# 铁刃
	c.rect(18, 4, 27, 12, blade)
	c.cut_corners(18, 4, 27, 12, 2)
	c.line(18, 4, 18, 12, blade_dark, 1)   # 靠柄一侧的阴影
	c.line(25, 4, 27, 12, edge, 1)          # 外沿开刃亮边
	return c


def make_berry() -> Canvas:
	# 浆果：三颗红果 + 两片绿叶。饱食度的主要来源，要一眼认得出"能吃"
	c = Canvas()
	berry = rgb(0.86, 0.16, 0.22)
	berry_dark = rgb(0.62, 0.10, 0.16)
	berry_light = rgb(0.96, 0.42, 0.44)
	leaf = rgb(0.28, 0.66, 0.30)
	stem = rgb(0.36, 0.52, 0.24)

	def ball(cx: int, cy: int, r: int) -> None:
		for y in range(cy - r, cy + r + 1):
			for x in range(cx - r, cx + r + 1):
				d2 = (x - cx) ** 2 + (y - cy) ** 2
				if d2 <= r * r:
					c.set(x, y, berry)
				elif d2 <= (r + 1) ** 2:
					c.set(x, y, berry_dark)
		# 左上角高光，让果实有体积感
		c.set(cx - 1, cy - r + 1, berry_light)
		c.set(cx - 2, cy - r + 2, berry_light)

	# 三颗果实：两前一后
	ball(12, 20, 5)
	ball(21, 21, 4)
	ball(17, 13, 4)
	# 果柄
	c.line(17, 9, 17, 11, stem, 1)
	# 两片叶子
	c.line(8, 8, 15, 6, leaf, 2)
	c.line(18, 6, 25, 9, leaf, 2)
	return c


def write_import(png_path: str) -> None:
	# 与 rock.png.import 同样的像素风参数：无损压缩 + 关闭 mipmap。
	# 故意不写 uid / path / dest_files：Godot 首次导入时会自动补全并保持这些参数。
	content = """[remap]

importer="texture"
type="CompressedTexture2D"
metadata={
"vram_texture": false
}

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=false
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
"""
	with open(png_path + ".import", "w", encoding="utf-8", newline="\n") as f:
		f.write(content)


def main() -> None:
	out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "art", "icons")
	os.makedirs(out_dir, exist_ok=True)
	jobs = {
		"iron_ore": make_iron_ore,
		"coal": make_coal,
		"iron_ingot": make_ingot,
		"iron_sword": make_sword,
		"iron_pickaxe": make_pickaxe,
		"crude_axe": make_crude_axe,
		"iron_axe": make_iron_axe,
		"berry": make_berry,
	}
	for name, fn in jobs.items():
		path = os.path.join(out_dir, name + ".png")
		fn().save(path)
		write_import(path)
		print("wrote", path)


if __name__ == "__main__":
	main()
