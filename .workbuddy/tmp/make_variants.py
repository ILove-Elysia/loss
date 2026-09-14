# 调色板换色：把 char_blue.png 里的"蓝色系"整体旋转到红/绿色系，
# 保留皮肤、头发、靴子、木盾的棕色调。输出与原图完全同布局（448x392，8x7 格）。
from PIL import Image
import colorsys
import os
import sys

SRC = r"art/player/char_blue.png"
OUT_DIR = r"art/player"
TMP = r"../.workbuddy/tmp"

# 蓝色系所在的色相区间（度）。185~270 覆盖 #1B47AB(221) / #8B93AF(227) /
# #20255D(235) / #9BADB7(201) 等全部蓝衣蓝甲；#323C39(162) 的暗绿灰不在区间内，保持不动。
HUE_LO, HUE_HI = 185.0, 270.0
SAT_MIN = 0.10


def recolor(im, delta_deg):
    out = Image.new("RGBA", im.size)
    src = im.load()
    dst = out.load()
    w, h = im.size
    cache = {}
    for y in range(h):
        for x in range(w):
            r, g, b, a = src[x, y]
            if a == 0:
                dst[x, y] = (r, g, b, a)
                continue
            key = (r, g, b)
            hit = cache.get(key)
            if hit is None:
                hue, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
                deg = hue * 360.0
                if s >= SAT_MIN and HUE_LO <= deg <= HUE_HI:
                    nh = ((deg + delta_deg) % 360.0) / 360.0
                    nr, ng, nb = colorsys.hsv_to_rgb(nh, s, v)
                    hit = (round(nr * 255), round(ng * 255), round(nb * 255))
                else:
                    hit = (r, g, b)
                cache[key] = hit
            dst[x, y] = (hit[0], hit[1], hit[2], a)
    return out


def main():
    base = Image.open(SRC).convert("RGBA")
    variants = [
        ("char_red.png", -221.0, "红"),
        ("char_green.png", -101.0, "绿"),
    ]
    made = []
    for fname, delta, label in variants:
        im = recolor(base, delta)
        im.save(os.path.join(OUT_DIR, fname))
        im.save(os.path.join(TMP, fname))
        made.append((fname, label, im))
        print("写出", os.path.join(OUT_DIR, fname), im.size)

    # 预览：三张并排（每张只取第 2 行 idle 帧带，横向拼接，放大 3 倍）
    strip = Image.new("RGBA", (448, 56 * 3), (24, 28, 40, 255))
    for i, (fname, label, im) in enumerate([("char_blue", "蓝", base)] + made):
        strip.alpha_composite(im.crop((0, 56, 448, 112)), (0, i * 56))
    strip = strip.resize((448 * 2, 56 * 3 * 2), Image.NEAREST)
    strip.save(os.path.join(TMP, "preview_strip.png"))
    print("预览写出 preview_strip.png")


main()
