# test/player_anim_check.py
# ============================================
# 玩家动画校验 —— 抓"动画播错 / 播不出来"这类跨 .tscn+.gd 的错误
#
# 为什么需要它：
#   玩家的 SpriteFrames 是**手写在 tscn 里的**（一堆 AtlasTexture + 一个矩形数组），
#   帧区写错一个数字（y 写成 56 而不是 168）不会报错，只会默默播成别的动作。
#   另外"砍树借用攻击动画"这种偷懒做法一旦回潮，光看代码也未必注意到，
#   所以这里把两件事一起钉死：
#     1) 数据面：harvest 的帧必须来自劳作行，不能来自 attack 行；
#     2) 代码面：play_harvest_action() 必须播 harvest，且 is_working 标志位配对完整。
#
# 背景（2026-09-23）：精灵表 448×392 / 8 列 × 7 行 / 单帧 56×56，
#   第 4 行（y=168）是「直立抬臂(col 1) + 俯身下劈(col 0)」，正是砍树该有的样子；
#   第 2 行（y=56）是 attack —— 末帧带一大片白色剑光弧，给砍树用非常出戏。
#
# 检查项：
#   1. tscn 里每个 AtlasTexture 帧区都在贴图尺寸内
#   2. 六个动画都在：idle / walk / attack / hurt / die / harvest
#   3. harvest 的帧只取自劳作行（y=168 / 224），不得引用 attack 行（y=56）
#   4. physics.gd 的 play_harvest_action() 播的是 harvest（不是 attack）
#   5. is_working 配对完整（置位 / 播完清零 / 移动让位 / 攻击抢占 / 死亡复活清零）
#   6. 三张角色表逐帧轮廓一致（换装逻辑依赖，形态不一致会取到错帧）
#
# 用法：python test/player_anim_check.py
# ============================================

import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSCN = os.path.join(ROOT, "tscn", "player.tscn")
PHYSICS = os.path.join(ROOT, "script", "player", "physics.gd")

# 精灵表规格（art/player/README.md 是权威，改图必须同步这里）
SHEET_W, SHEET_H = 448, 392
FRAME = 56

# 行 y 坐标 → 语义（不是等差数列，别按 56 的倍数推算）
ROW_NAMES = {0: "idle", 56: "attack", 114: "walk", 168: "carry-walk-A",
             224: "carry-walk-B", 280: "hurt", 336: "die"}
# 劳作行：harvest 只能取自这两行
WORK_ROWS = (168, 224)
# 禁止行：attack 行（带剑光弧）
ATTACK_ROW = 56

REQUIRED_ANIMS = ["idle", "walk", "attack", "hurt", "die", "harvest"]

problems = []


def read(path):
	with open(path, "r", encoding="utf-8") as f:
		return f.read()


def png_size(path):
	"""只读 PNG 头拿尺寸，避免依赖第三方库。"""
	with open(path, "rb") as f:
		head = f.read(24)
	if head[:8] != b"\x89PNG\r\n\x1a\n":
		raise ValueError("不是 PNG: %s" % path)
	return struct.unpack(">II", head[16:24])


def parse_tscn(text):
	"""返回 (atlas_textures, anims, ext_textures)
	atlas_textures: {sub_id: (ext_id, (x, y, w, h))}
	anims: [(name, [sub_id...], loop, speed)]
	ext_textures: {ext_id: res_path}
	"""
	ext_textures = {}
	for m in re.finditer(
			r'\[ext_resource type="Texture2D"[^\]]*?path="([^"]+)"[^\]]*?id="([^"]+)"\]', text):
		ext_textures[m.group(2)] = m.group(1)

	atlas_textures = {}
	for m in re.finditer(
			r'\[sub_resource type="AtlasTexture" id="([^"]+)"\]\n(.*?)(?=\n\[|\Z)', text, re.S):
		sub_id, body = m.group(1), m.group(2)
		ext = re.search(r'atlas = ExtResource\("([^"]+)"\)', body)
		region = re.search(r"region = Rect2\(([^)]*)\)", body)
		if not region:
			continue
		vals = tuple(int(round(float(v))) for v in region.group(1).split(","))
		atlas_textures[sub_id] = (ext.group(1) if ext else "", vals)

	i = text.find('[sub_resource type="SpriteFrames"')
	j = text.find("\n[node", i)
	seg = text[i:j if j > 0 else len(text)]
	anims = []
	for m in re.finditer(
			r'"frames": \[(.*?)\],\n"loop": (\d+),\n"name": &"([^"]+)",\n"speed": ([0-9.]+)',
			seg, re.S):
		frames, loop, name, speed = m.groups()
		ids = re.findall(r'SubResource\("([^"]+)"\)', frames)
		anims.append((name, ids, int(loop), float(speed)))
	return atlas_textures, anims, ext_textures


def func_body(text, name):
	"""取出顶层函数的函数体（GDScript 用 tab 缩进）。"""
	m = re.search(r"\nfunc %s\([^)]*\)[^\n]*:\n(.*?)(?=\nfunc |\Z)" % re.escape(name), text, re.S)
	return m.group(1) if m else None


def main():
	if not os.path.exists(TSCN):
		print("找不到 %s" % TSCN)
		return 1
	if not os.path.exists(PHYSICS):
		print("找不到 %s" % PHYSICS)
		return 1

	tscn = read(TSCN)
	gd = read(PHYSICS)
	atlas_textures, anims, ext_textures = parse_tscn(tscn)
	anims_by_name = {a[0]: a for a in anims}

	print("解析：%d 个 AtlasTexture，%d 个动画" % (len(atlas_textures), len(anims)))

	# ---- 1. 帧区越界 ----
	print("\n[1/6] 帧区必须落在贴图内（448 x 392）")
	before = len(problems)
	sizes = {}
	for sub_id, (ext_id, region) in sorted(atlas_textures.items()):
		res = ext_textures.get(ext_id, "")
		path = os.path.join(ROOT, res.replace("res://", "").replace("/", os.sep))
		if res and path not in sizes:
			try:
				sizes[path] = png_size(path)
			except Exception as e:
				sizes[path] = None
				problems.append("%s 读取失败：%s" % (res, e))
		sheet = sizes.get(path)
		if sheet is None:
			continue
		x, y, w, h = region
		if x < 0 or y < 0 or x + w > sheet[0] or y + h > sheet[1]:
			problems.append("%s 帧区 %s 超出贴图 %s（%s）"
			                % (sub_id, region, sheet, res))
		elif not (52 <= w <= 64 and 52 <= h <= 64):
			problems.append("%s 帧区尺寸 %s 不像单帧（应约 %dx%d）" % (sub_id, region, FRAME, FRAME))
	if len(problems) == before:
		print("  OK  %d 个帧区全部合法（贴图尺寸 %s）"
		      % (len(atlas_textures), sizes.get(list(sizes)[0]) if sizes else "?"))

	# ---- 2. 动画齐全 ----
	print("\n[2/6] 六个动画必须都在")
	before = len(problems)
	for name in REQUIRED_ANIMS:
		if name in anims_by_name:
			_, ids, loop, speed = anims_by_name[name]
			print("  OK  %-8s %d 帧  loop=%d  speed=%.1f" % (name, len(ids), loop, speed))
		else:
			problems.append("SpriteFrames 里没有动画 &\"%s\"" % name)
			print("  缺失 &\"%s\"" % name)

	# ---- 3. harvest 只能取自劳作行 ----
	print("\n[3/6] harvest 的帧必须来自劳作行 y=%s，不得来自 attack 行 y=%d"
	      % (str(WORK_ROWS), ATTACK_ROW))
	before = len(problems)
	hv = anims_by_name.get("harvest")
	if hv is None:
		print("  跳过（动画缺失）")
	else:
		_, ids, loop, speed = hv
		if loop != 0:
			problems.append("harvest 的 loop 应为 0（一次作业播一遍），实际 %d" % loop)
		rows = []
		for sub_id in ids:
			ext_id, region = atlas_textures.get(sub_id, ("", (0, 0, 0, 0)))
			rows.append(region[1])
		print("  harvest 用到的行 y = %s" % rows)
		for y in rows:
			if y == ATTACK_ROW:
				problems.append("harvest 引用了 attack 行（y=%d）——又变回借用攻击动画了" % y)
			elif y not in WORK_ROWS:
				problems.append("harvest 引用了非劳作行 y=%d（劳作行只有 %s）"
				                % (y, str(WORK_ROWS)))
		if len(rows) >= 2 and len(set(rows)) == 1:
			print("  提示：所有帧都在同一行（y=%d），如需换姿势请混用 y=168 / y=224" % rows[0])
		if len(problems) == before:
			print("  OK  全部落在劳作行内")

	# ---- 4. 代码侧：play_harvest_action 播什么 ----
	print("\n[4/6] physics.gd 的 play_harvest_action() 必须播 harvest")
	before = len(problems)
	body = func_body(gd, "play_harvest_action")
	if body is None:
		problems.append("physics.gd 里找不到 play_harvest_action()")
		print("  找不到该函数")
	else:
		m = re.findall(r'spr\.play\("([^"]+)"\)', body)
		print("  函数体里的 spr.play 参数：%s" % m)
		if not m:
			problems.append("play_harvest_action() 里没有任何 spr.play 调用")
		elif m[0] != "harvest":
			problems.append("play_harvest_action() 播的是 \"%s\"，应为 \"harvest\"" % m[0])
		if 'spr.play("attack")' in body:
			problems.append("play_harvest_action() 里还残留 spr.play(\"attack\")（借用攻击动画）")
		if "is_working = true" not in body:
			problems.append("play_harvest_action() 没有置 is_working = true，动画会被 _update_animation 立刻切回 idle")
		if len(problems) == before:
			print("  OK  播 harvest 且置位 is_working")

	# ---- 5. is_working 配对 ----
	print("\n[5/6] is_working 置位 / 清零必须配对")
	before = len(problems)
	checks = [
		("_update_animation", "if is_working:", "作业中要锁住动画，否则本帧就被切回 idle"),
		("_update_animation", "is_working = false", "一移动就让位给 walk（否则卡在弯腰姿势走路）"),
		("_on_attack_animation_finished", "is_working = false", "harvest 播完必须清零，否则动画永久锁死"),
		("perform_attack", "is_working = false", "攻击抢占动画时要清作业状态"),
		("_on_death", "is_working = false", "死亡要清，否则复活后动画卡住"),
		("revive", "is_working = false", "复活要清"),
	]
	for func, needle, why in checks:
		fb = func_body(gd, func) or ""
		if needle in fb:
			print("  OK  %s() 含 `%s`" % (func, needle))
		else:
			problems.append("%s() 缺少 `%s` —— %s" % (func, needle, why))
			print("  失败 %s() 缺少 `%s`" % (func, needle))
	# finished 回调必须真的挂在 harvest 分支上（不是只出现在别处）
	fb = func_body(gd, "_on_attack_animation_finished") or ""
	if 'spr.animation == "harvest"' not in fb:
		problems.append("_on_attack_animation_finished() 里没有 harvest 分支")
		print("  失败 缺 harvest 分支")
	else:
		print("  OK  _on_attack_animation_finished() 有 harvest 分支")

	# ---- 6. 三张角色表轮廓一致 ----
	print("\n[6/6] 三张角色表逐帧轮廓一致（换装逻辑依赖）")
	try:
		from PIL import Image
	except ImportError:
		print("  跳过（没装 Pillow；只是核对美术布局，可忽略）")
	else:
		sheets = {}
		for m in re.finditer(r'path="res://(art/player/[^"]+\.png)"', tscn):
			p = os.path.join(ROOT, m.group(1).replace("/", os.sep))
			sheets[m.group(1)] = p
		# 三张表在 character_registry 里登记，这里按目录名取
		reg = os.path.join(ROOT, "art", "player")
		cands = []
		for d in sorted(os.listdir(reg)):
			full = os.path.join(reg, d)
			if os.path.isdir(full):
				for fn in sorted(os.listdir(full)):
					if fn.endswith(".png"):
						cands.append(os.path.join(full, fn))
		if len(cands) < 2:
			print("  跳过（只找到 %d 张角色表）" % len(cands))
		else:
			ims = [Image.open(p).convert("RGBA") for p in cands]
			names = [os.path.relpath(p, ROOT).replace("\\", "/") for p in cands]
			ref = ims[0]
			worst = 0.0
			worst_where = ""
			for im, nm in zip(ims[1:], names[1:]):
				if im.size != ref.size:
					problems.append("%s 尺寸 %s 与 %s 不一致" % (nm, im.size, names[0]))
					continue
				for y in [0, 56, 114, 168, 224, 280, 336]:
					for c in range(8):
						box = (c * FRAME, y, c * FRAME + FRAME, y + FRAME)
						a = bytes(1 if v > 10 else 0 for v in ref.crop(box).getchannel("A").tobytes())
						b = bytes(1 if v > 10 else 0 for v in im.crop(box).getchannel("A").tobytes())
						d = sum(1 for i in range(len(a)) if a[i] != b[i]) / float(len(a))
						if d > worst:
							worst, worst_where = d, "%s 行 y=%d 第 %d 帧" % (nm, y, c)
			if worst > 0.02:
				problems.append("三张表轮廓不一致：%s 差异 %.2f%%（换装后会取到形状不同的帧）"
				                % (worst_where, worst * 100))
			else:
				print("  OK  %d 张表最大轮廓差异 %.2f%%（%s）" % (len(cands), worst * 100, worst_where or "-"))

	# ---- 汇总 ----
	print("\n" + "=" * 50)
	if problems:
		print("发现 %d 个问题：" % len(problems))
		for p in problems:
			print("  - %s" % p)
		return 1
	print("全部通过。")
	return 0


if __name__ == "__main__":
	sys.exit(main())
