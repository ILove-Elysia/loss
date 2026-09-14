from PIL import Image, ImageDraw

SCALE = 4
CELL = 56
PAD = 14
LABEL_H = 18

files = [("char_blue.png", "knight BLUE"), ("char_red.png", "guard RED"), ("char_green.png", "scout GREEN")]
imgs = [Image.open(f"art/player/{f}").convert("RGBA") for f, _ in files]

w = PAD + (CELL * SCALE + PAD) * len(files)
h = PAD + CELL * SCALE + LABEL_H + PAD
out = Image.new("RGB", (w, h), (26, 30, 42))
draw = ImageDraw.Draw(out)

for i, (im, (_, label)) in enumerate(zip(imgs, files)):
    frame = im.crop((0, CELL, CELL, CELL * 2))  # idle 首帧
    frame = frame.resize((CELL * SCALE, CELL * SCALE), Image.NEAREST)
    x = PAD + i * (CELL * SCALE + PAD)
    out.paste(frame, (x, PAD), frame)
    draw.text((x + CELL * SCALE // 2 - len(label) * 3, PAD + CELL * SCALE + 4), label, fill=(200, 210, 230))

out.save("../.workbuddy/tmp/char_preview.png")
print("ok", out.size)
