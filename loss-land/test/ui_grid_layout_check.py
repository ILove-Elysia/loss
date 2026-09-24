# -*- coding: utf-8 -*-
"""九宫格布局静态校验（不依赖 Godot 运行时）。

为什么要有它：
  `test/ui_grid_layout_test.gd` 要跑 headless Godot（且必须先关编辑器，否则抢 .godot），
  而布局 bug 里绝大多数是**纯算术错**——区域写重了、超出视口、压到快捷栏、
  格子宽度加起来超过面板宽。这些用读源码常量复算就能查出来，
  不必启动引擎。参考 sprite_facing_check.py 的做法。

它查什么：
  1. 四块面板的 `RECT_*` 常量之间的几何关系：两两不相交、都在 1280×720 内、
     左列三块下边不超过 CONTENT_BOTTOM（**装备栏例外**，它一路用到 HOTBAR_BOTTOM）。
  2. 每块面板的 `Rect2` 边界是否和 hud_ui.gd 里的列常量（LEFT/MAP/RIGHT_COL_*）对齐。
  3. 槽位网格宽度是否真塞得进面板：`columns*slot_size + (columns-1)*spacing <= 面板宽 - 内容边距`。
  4. 右上角组合块（小地图列 + 按钮列 + 状态栏）的几何 ——
     `CLUSTER_BOTTOM` 必须与 minimap_ui.gd 的 `MAP_PX/PANEL_PAD/INFO_GAP/INFO_H` 复算一致，
     装备栏顶必须让开这一列，状态栏（按 5 行最坏高度）不许压到装备栏。
  5. HUD 常驻元素互不越界；右下角那行操作提示已删除，这里反向断言源码里不再有 ControlHints。

注意：这里只做**静态算术**，控件实际落点仍以 ui_grid_layout_test.gd 的实机测量为准。
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "script", "ui")

VP_W, VP_H = 1280.0, 720.0


def read(name):
    with open(os.path.join(UI, name), encoding="utf-8") as f:
        return f.read()


def num(text, pattern, label):
    m = re.search(pattern, text)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


fail = []
checked = [0]


def check(cond, name, detail=""):
    checked[0] += 1
    if cond:
        print("  [通过] " + name)
    else:
        print("  [失败] " + name + ("  " + detail if detail else ""))
        fail.append(name)


def R(x, y, w, h):
    return (x, y, x + w, y + h)


def overlaps(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


# ---------------------------------------------------------------- 1. 列常量
# 注：常量里混着**表达式**（例如 `STATUS_TOP := BTN_COL_BOTTOM + BLOCK_GAP`），
# 所以不能只正则数字——把整份 `const X := <表达式>` 抓出来、按文件出现顺序求值，
# 求值环境就是先前已求出的常量表（依赖都写在上面几行，顺序天然够用）。
def read_consts(text):
    consts = {}
    for name, rhs in re.findall(r"^const\s+([A-Z0-9_]+)\s*:=\s*(.+)$", text, re.M):
        try:
            consts[name] = float(eval(rhs.split("#")[0].strip(), {"__builtins__": {}}, consts))
        except Exception:
            pass  # 非数值常量（数组/字符串/颜色）跳过
    return consts


hud = read("hud_ui.gd")
consts = read_consts(hud)
cols = {}
for key in ("LEFT_COL_LEFT", "LEFT_COL_RIGHT", "MAP_COL_LEFT", "MAP_COL_RIGHT",
            "RIGHT_COL_LEFT", "RIGHT_COL_RIGHT", "RIGHT_MARGIN", "CONTENT_BOTTOM",
            "HOTBAR_TOP", "HOTBAR_BOTTOM", "MARGIN", "BTN_COUNT", "BTN_W", "BTN_H",
            "BTN_SEP", "BLOCK_GAP", "BTN_COL_BOTTOM", "CLUSTER_BOTTOM", "STATUS_TOP",
            "STATUS_WIDTH", "PANEL_W", "PANEL_GAP"):
    if key not in consts:
        print("[失败] hud_ui.gd 里找不到（或算不出）常量 %s" % key)
        fail.append(key)
    cols[key] = consts.get(key)

print("列常量：%s" % cols)

L, Rr = cols["LEFT_COL_LEFT"], cols["LEFT_COL_RIGHT"]
M, Mr = cols["MAP_COL_LEFT"], cols["MAP_COL_RIGHT"]
Rg, Rgr = cols["RIGHT_COL_LEFT"], cols["RIGHT_COL_RIGHT"]
BOT, HTOP, HBOT = cols["CONTENT_BOTTOM"], cols["HOTBAR_TOP"], cols["HOTBAR_BOTTOM"]

check(L < Rr <= M <= Mr <= Rg < Rgr <= VP_W,
      "三列常量单调且落在视口内", "L=%s R=%s M=%s Mr=%s Rg=%s Rgr=%s" % (L, Rr, M, Mr, Rg, Rgr))
check(Rr < M and Mr < Rg, "列之间留了间隔（面板不会贴在一起）")
check(HTOP >= BOT, "快捷栏带起点在信息面板下边界之下", "HTOP=%s BOT=%s" % (HTOP, BOT))
check(HBOT <= VP_H, "快捷栏带不超出视口底", "HBOT=%s" % HBOT)

# 右上角组合块：派生常量必须互相自洽（改一个忘一个，这里立刻炸）
bt_bottom = cols["MARGIN"] + (cols["BTN_H"] + cols["BTN_SEP"]) * cols["BTN_COUNT"] - cols["BTN_SEP"]
check(cols["BTN_COL_BOTTOM"] == bt_bottom,
      "BTN_COL_BOTTOM = MARGIN + (BTN_H+BTN_SEP)×BTN_COUNT − BTN_SEP",
      "实际 %s / 期望 %s" % (cols["BTN_COL_BOTTOM"], bt_bottom))
check(cols["STATUS_TOP"] == cols["BTN_COL_BOTTOM"] + cols["BLOCK_GAP"],
      "状态栏紧接按钮列下方（STATUS_TOP = BTN_COL_BOTTOM + BLOCK_GAP）",
      "实际 %s" % cols["STATUS_TOP"])
check(cols["RIGHT_MARGIN"] == VP_W - cols["RIGHT_COL_RIGHT"],
      "RIGHT_MARGIN = 视口宽 − RIGHT_COL_RIGHT（右列贴边距）",
      "实际 %s" % cols["RIGHT_MARGIN"])

# ------------------------------------------------- 2. 四块面板 RECT_* 常量
# 装备栏 2026-09-24 二次改版：顶部让开右上角的小地图列，底部吃下原先"右下角操作提示"
# 那条带子；同时整体缩小 476×426 → 420×340（原尺寸在界面缩放 105% 下右/下都被裁）。
# 右边缘贴 RIGHT_COL_RIGHT(1270)、底边贴 HOTBAR_BOTTOM(710)。
#
# 左列三块 2026-09-24 三次改版（物品格 44→36）：面板宽度跟着网格收窄 492→412，
# 高也各减 16（网格从 2×44+4=92 变 2×36+4=76），三块顺次上移靠拢。
# 宽度不再等于列宽（Rr−L=492）——所以由 hud_ui.gd 的 PANEL_W 统一定义。
EQUIP_W, EQUIP_TOP, EQUIP_BOT = 420.0, 370.0, HBOT
EQUIP_LEFT = Rgr - EQUIP_W                      # 1270 − 420 = 850
PW = cols["PANEL_W"]
specs = [
    ("inventory_ui.gd", "RECT_INVENTORY", "背包", R(L, 10.0, PW, 182.0)),
    ("storage_ui.gd", "RECT_STORAGE", "箱子", R(L, 200.0, PW, 162.0)),
    ("crafting_ui.gd", "RECT_CRAFTING", "制作栏", R(L, 370.0, PW, 256.0)),
    ("equipment_ui.gd", "RECT_EQUIPMENT", "装备栏",
     R(EQUIP_LEFT, EQUIP_TOP, EQUIP_W, EQUIP_BOT - EQUIP_TOP)),
]

rects = {}
for fname, const, label, want in specs:
    src = read(fname)
    m = re.search(r"const\s+%s\s*:=\s*Rect2\(\s*([\-0-9.]+)\s*,\s*([\-0-9.]+)\s*,\s*([\-0-9.]+)\s*,\s*([\-0-9.]+)\s*\)"
                  % const, src)
    if not m:
        print("[失败] %s 里找不到 %s" % (fname, const))
        fail.append(const)
        continue
    x, y, w, h = (float(g) for g in m.groups())
    got = R(x, y, w, h)
    rects[label] = got
    check(all(abs(a - b) < 0.51 for a, b in zip(got, want)),
          "%s 的 %s 与列常量推出的矩形一致（±0.5px）" % (fname, const),
          "实际 %s / 期望 %s" % (got, want))
    check(got[0] >= 0 and got[1] >= 0 and got[2] <= VP_W and got[3] <= VP_H,
          "%s（%s）落在视口内" % (label, const), str(got))
    # 左列三块止步于 CONTENT_BOTTOM；装备栏例外，它一路用到 HOTBAR_BOTTOM
    is_equip = const == "RECT_EQUIPMENT"
    limit = HBOT if is_equip else BOT
    check(got[3] <= limit + 0.51,
          "%s（%s）下边不越过 %s" % (label, const, "HOTBAR_BOTTOM" if is_equip else "CONTENT_BOTTOM"),
          "%s > %s" % (got[3], limit))

# 两两不重叠
labels = list(rects.keys())
for i in range(len(labels)):
    for j in range(i + 1, len(labels)):
        a, b = rects[labels[i]], rects[labels[j]]
        ov_w = min(a[2], b[2]) - max(a[0], b[0])
        ov_h = min(a[3], b[3]) - max(a[1], b[1])
        check(not overlaps(a, b), "%s 与 %s 不重叠" % (labels[i], labels[j]),
              "重叠 %s×%s" % (ov_w, ov_h))

# 左列三块的竖向排布：首块顶 = MARGIN、相邻间隙 = PANEL_GAP、末块底 = CONTENT_BOTTOM
# （物品格缩小后三块要顺次上移靠拢，靠这组断言防止只改一个 RECT 忘了挪另一个）
MGAP = cols["PANEL_GAP"]
check(abs(rects["背包"][1] - cols["MARGIN"]) <= 0.51,
      "左列首块（背包）顶 = MARGIN", "top=%s" % rects["背包"][1])
for upper, lower in (("背包", "箱子"), ("箱子", "制作栏")):
    check(abs(rects[lower][1] - (rects[upper][3] + MGAP)) <= 0.51,
          "%s 紧接 %s 下方（间隙 = PANEL_GAP=%s）" % (lower, upper, MGAP),
          "实际间隙 %s" % (rects[lower][1] - rects[upper][3]))
check(abs(rects["制作栏"][3] - BOT) <= 0.51,
      "制作栏底正好到 CONTENT_BOTTOM（左列铺满）", "bottom=%s" % rects["制作栏"][3])
for lb in ("背包", "箱子", "制作栏"):
    w = rects[lb][2] - rects[lb][0]
    check(abs(w - PW) <= 0.51, "左列 %s 宽 = PANEL_W" % lb, "实际宽 %s" % w)

# ------------------------------------------------- 3. 槽位网格塞不塞得进面板
grid_specs = [
    ("inventory_ui.gd", "inventory_ui", "背包"),
    ("storage_ui.gd", "storage_ui", "箱子"),
]
for fname, tag, label in grid_specs:
    src = read(fname)
    c = num(src, r"@export\s+var\s+columns\s*:\s*int\s*=\s*([0-9]+)", "columns")
    s = num(src, r"@export\s+var\s+slot_size\s*:\s*int\s*=\s*([0-9]+)", "slot_size")
    # 间距优先读 @export，没有就退回网格上写死的 h_separation
    sp = num(src, r"@export\s+var\s+slot_spacing\s*:\s*int\s*=\s*([0-9]+)", "slot_spacing")
    if sp is None:
        sp = num(src, r'h_separation"\s*,\s*([0-9]+)', "h_separation")
    if None in (c, s, sp):
        print("[失败] %s 缺 columns(%s) / slot_size(%s) / 间距(%s)" % (fname, c, s, sp))
        fail.append(fname)
        continue
    inner = rects[label][2] - rects[label][0]
    # 面板两侧各留 ~8px 内边距（对齐 _setup_ui 里的 margin）
    used = c * s + (c - 1) * sp
    check(used <= inner - 8.0,
          "%s 槽位网格塞得进面板（%d 列 ×%d + %d 间距 = %.0f ≤ %.0f）"
          % (label, c, s, sp, used, inner - 8.0))
    # 更严一条：面板宽必须**正好** = 网格宽 + 左右各 8 内边距。
    # 物品格缩小后若忘了同步缩面板，这里会立刻报（留白会越攒越大）。
    check(abs(inner - used - 16.0) <= 0.51,
          "%s 面板宽 = 网格宽 + 16（左右各 8 内边距）" % label,
          "面板 %s / 网格 %s" % (inner, used))

# ---------------------------------------------------------- 4. HUD 常驻元素
# 小地图尺寸不写死：从 minimap_ui.gd 复算，才能和 hud_ui 的 CLUSTER_BOTTOM 交叉核对。
mini_src = read("minimap_ui.gd")
MAP_PX = num(mini_src, r"const\s+MAP_PX\s*:=\s*([0-9.]+)", "MAP_PX")
PANEL_PAD = num(mini_src, r"const\s+PANEL_PAD\s*:=\s*([0-9.]+)", "PANEL_PAD")
INFO_GAP = num(mini_src, r"const\s+INFO_GAP\s*:=\s*([0-9.]+)", "INFO_GAP")
INFO_H = num(mini_src, r"const\s+INFO_H\s*:=\s*([0-9.]+)", "INFO_H")
if None in (MAP_PX, PANEL_PAD, INFO_GAP, INFO_H):
    print("[失败] minimap_ui.gd 缺 MAP_PX / PANEL_PAD / INFO_GAP / INFO_H")
    fail.append("小地图尺寸常量")
    MAP_PX = PANEL_PAD = INFO_GAP = INFO_H = 0.0
MINI_W = MAP_PX + PANEL_PAD * 2
MINI_H = MAP_PX + PANEL_PAD * 2 + INFO_GAP + INFO_H

MG = cols["MARGIN"]
RGr = cols["RIGHT_COL_RIGHT"]
CLOCK_H, CLOCK_SEP = 28.0, 4.0
TOAST_TOP, TOAST_BOT = 556.0, 582.0
SLOT, HSEP, SLOTS = 52.0, 4.0, 9.0

# 右上角组合块：按钮列贴屏幕右边缘；小地图列紧贴它的左侧（中间留 BLOCK_GAP）
btns = R(RGr - cols["BTN_W"], MG, cols["BTN_W"],
         cols["BTN_H"] * cols["BTN_COUNT"] + cols["BTN_SEP"] * (cols["BTN_COUNT"] - 1))
mini_left = btns[0] - cols["BLOCK_GAP"] - MINI_W
mini = R(mini_left, MG, MINI_W, MINI_H)
clock = R(mini_left, MG + MINI_H + CLOCK_SEP, MINI_W, CLOCK_H)
cluster_bottom = clock[3]

# 状态栏高度按**最坏情况**算：5 行（⚡/🔋/♥/🌡/🍖）全出现时才最高。
# 行高估 `ceil(1.37 × font_size)`：Godot 默认字体 Open Sans 的
# (ascent+descent)/em ≈ 2789/2048 = 1.362，取 1.37 留余量。
st_font = num(hud, r"const\s+STATUS_FONT_SIZE\s*:=\s*([0-9.]+)", "STATUS_FONT_SIZE")
st_sep = num(hud, r"const\s+STATUS_ROW_SEP\s*:=\s*([0-9.]+)", "STATUS_ROW_SEP")
st_pad = num(hud, r"const\s+STATUS_PAD\s*:=\s*([0-9.]+)", "STATUS_PAD")
if None in (st_font, st_sep, st_pad):
    print("[失败] hud_ui.gd 缺 STATUS_FONT_SIZE / STATUS_ROW_SEP / STATUS_PAD")
    fail.append("状态栏排版常量")
    status = R(btns[0], cols["STATUS_TOP"], cols["STATUS_WIDTH"], 9999.0)
else:
    import math
    row_h = math.ceil(1.37 * st_font)
    st_h = 5 * row_h + 4 * st_sep + 2 * st_pad
    print("状态栏最坏高度估算：5 行 ×%d + 4×%d 间距 + 2×%d 内边距 = %.0f"
          % (row_h, st_sep, st_pad, st_h))
    status = R(btns[0], cols["STATUS_TOP"], cols["STATUS_WIDTH"], st_h)

toast = R(M, TOAST_TOP, Mr - M, TOAST_BOT - TOAST_TOP)
hot_w = SLOTS * SLOT + (SLOTS - 1) * HSEP
hot_cx = (L + Mr) * 0.5
hotbar = R(hot_cx - hot_w * 0.5, HTOP, hot_w, HBOT - HTOP)

for label, r in (("小地图列", mini), ("时钟", clock), ("按钮列", btns), ("状态栏", status),
                 ("吐司", toast), ("快捷栏", hotbar)):
    check(r[0] >= 0 and r[1] >= 0 and r[2] <= VP_W and r[3] <= VP_H,
          "HUD %s 在视口内" % label, str(r))

# 整块贴右上角
check(abs(btns[2] - RGr) <= 0.51, "按钮列贴住屏幕右边缘", str(btns))
check(abs((btns[0] - mini[2]) - cols["BLOCK_GAP"]) <= 0.51,
      "小地图列在按钮列左侧、间隙正好 BLOCK_GAP",
      "实际间隙 %s / 期望 %s" % (btns[0] - mini[2], cols["BLOCK_GAP"]))
check(cluster_bottom == cols["CLUSTER_BOTTOM"],
      "CLUSTER_BOTTOM 与 minimap_ui.gd 尺寸复算一致",
      "复算 %s / 声明 %s" % (cluster_bottom, cols["CLUSTER_BOTTOM"]))
check(cluster_bottom <= rects["装备栏"][1] + 0.51,
      "小地图列不压装备栏", "cluster_bottom=%s equip_top=%s" % (cluster_bottom, rects["装备栏"][1]))
check(rects["装备栏"][1] >= cluster_bottom + MG - 0.51,
      "装备栏顶让开了组合块（≥ 组合块底 + MARGIN）",
      "equip_top=%s cluster_bottom=%s" % (rects["装备栏"][1], cluster_bottom))
check(abs(rects["装备栏"][3] - HBOT) <= 0.51,
      "装备栏底吃到 HOTBAR_BOTTOM（原操作提示那条带子）",
      "equip_bottom=%s HBOT=%s" % (rects["装备栏"][3], HBOT))

check(btns[3] <= status[1] + 0.51, "按钮列不与状态栏重叠",
      "btn_bottom=%s status_top=%s" % (btns[3], status[1]))
check(abs(status[0] - btns[0]) <= 0.51 and abs(status[2] - btns[2]) <= 0.51,
      "状态栏与按钮列同 x 同宽（右列一竖条）", str(status))
check(status[3] <= rects["装备栏"][1] + 0.51,
      "状态栏（5 行最坏高度）不与装备栏重叠",
      "status_bottom=%s equip_top=%s" % (status[3], rects["装备栏"][1]))
check(rects["装备栏"][0] >= hotbar[2] + 0.51,
      "装备栏与快捷栏横向不相交（所以它能一路用到底）",
      "equip_left=%s hotbar_right=%s" % (rects["装备栏"][0], hotbar[2]))
check(toast[1] >= BOT - 70.0 and toast[3] <= HTOP, "吐司落在中列空档（不压面板也不压快捷栏）", str(toast))
check(hotbar[1] >= BOT, "快捷栏带在信息面板区之下", str(hotbar))

# 右下角操作提示 2026-09-24 已删——源码里不许再创建它（那条带子归装备栏了）
check("func _create_control_hints" not in hud and 'name = "ControlHints"' not in hud,
      "右下角操作提示控件已从 hud_ui.gd 删除")

# ------------------------------------- 5. 右列 / 底部必须走「贴视口边缘」锚定
# 为什么单列一节查它：界面缩放（GraphicsConfig.ui_scale → content_scale_factor）>1 时，
# canvas_items + expand 会把**逻辑视口**缩小（1.05 ⇒ 1219×686）。此时任何写死绝对 x
# （例如 offset_right = 1270）的控件都会被裁到屏幕外 —— 2026-09-24 用户反馈的
# "装备栏 UI 超出屏幕" 就是这个。修法只有一条：anchor 到视口边缘 + 负 offset。
# 这一节把"贴边"固化成断言，防止以后有人图省事又改回绝对坐标。
def func_body(text, fname):
    m = re.search(r"^func\s+%s\b.*?(?=^func\s|\Z)" % re.escape(fname), text, re.M | re.S)
    return m.group(0) if m else ""


eq_src = read("equipment_ui.gd")
eq_setup = func_body(eq_src, "_setup_ui")
check(len(eq_setup) > 0, "equipment_ui.gd 里找得到 _setup_ui")
for side in ("left", "top", "right", "bottom"):
    check(re.search(r"^\s*anchor_%s\s*=\s*1\.0\s*$" % side, eq_setup, re.M) is not None,
          "装备栏 anchor_%s = 1.0（贴视口右下角）" % side)
check("DESIGN_SIZE" in eq_setup and "RECT_EQUIPMENT" in eq_setup,
      "装备栏 offset 由 RECT_EQUIPMENT − DESIGN_SIZE 推出（设计坐标 → 贴边偏移）")
check("Vector2(110, 0)" not in eq_src and "SIZE_EXPAND_FILL" in eq_src,
      "装备栏四槽均分内容宽（写死 110 在 420 宽的面板里会溢出）")

st_body = func_body(hud, "_create_status_panel")
check("panel.anchor_left = 1.0" in st_body and "panel.anchor_right = 1.0" in st_body,
      "状态栏贴视口右边缘（anchor_left / anchor_right = 1.0）")
check("panel.offset_right = -RIGHT_MARGIN" in st_body,
      "状态栏 offset_right = −RIGHT_MARGIN")

bc_body = func_body(hud, "_create_button_column")
check("_topright.anchor_left = 1.0" in bc_body and "_topright.anchor_right = 1.0" in bc_body,
      "按钮列贴视口右边缘（anchor_left / anchor_right = 1.0）")
check("_topright.offset_right = -RIGHT_MARGIN" in bc_body,
      "按钮列 offset_right = −RIGHT_MARGIN")

tc_body = func_body(hud, "_create_topright_cluster")
check("map_col.anchor_left = 1.0" in tc_body and "map_col.anchor_right = 1.0" in tc_body,
      "小地图列跟着按钮列一起贴右边缘（否则视口缩小时两者会叠在一起）")

# ------------------------------------- 6. 物品格与贴图尺寸（2026-09-24 整体缩小）
# 用户要求"所有物品格和相关物品贴图缩小点"：快捷栏 64→52、背包/箱子 44→36、
# 装备图标 28→24、合成详情图标 40→32、槽内边距 4→3、数量字号 14→12。
# 这些数字散在 5 个文件里，最容易只改一半——固化成断言。
islot = read("item_slot_ui.gd")
check("custom_minimum_size = Vector2(52, 52)" in islot,
      "共用槽位（item_slot_ui）默认 52×52")
check("Vector2(64, 64)" not in islot, "共用槽位里不再残留 64×64")
check('margin.add_theme_constant_override("margin_left", 3)' in islot,
      "槽内贴图边距收到 3（原 4）")
check("Vector2(40, 40)" in islot, "拖拽预览缩到 40×40（原 48）")

check("slot.custom_minimum_size = Vector2(52, 52)" in hud, "快捷栏槽 52×52（原 64）")
check("slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER" in hud,
      "快捷栏槽标了 SHRINK_CENTER（否则被 HBox 沿交叉轴拉成 52×76 长方形）")
check("Vector2(24, 24)" in eq_src, "装备槽图标 24×24（原 28）")
check("Vector2(32, 32)" in read("crafting_ui.gd"), "合成详情图标 32×32（原 40）")
for f, nm in (("inventory_ui.gd", "背包"), ("storage_ui.gd", "箱子")):
    check("@export var slot_size: int = 36" in read(f),
          "%s槽 36×36（原 44）" % nm)

print("")
print("---------------------------------------")
if fail:
    print("===== 有 %d 项不通过（共 %d 项）=====" % (len(fail), checked[0]))
    for name in fail:
        print("  - " + name)
    sys.exit(1)
print("===== 九宫格静态布局全部通过（%d 项）=====" % checked[0])
