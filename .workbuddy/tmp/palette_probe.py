from PIL import Image
from collections import Counter
import colorsys

im = Image.open("art/player/char_blue.png").convert("RGBA")
print("size", im.size)
px = list(im.getdata())
c = Counter(px)
print("unique colors:", len(c))
for col, n in c.most_common(26):
    r, g, b, a = col
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    print(f"#{r:02X}{g:02X}{b:02X} a={a:3d} n={n:6d}  H={h * 360:6.1f} S={s:.2f} V={v:.2f}")
