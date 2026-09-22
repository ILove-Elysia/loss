# -*- coding: utf-8 -*-
"""
广告牌朝向复算（不依赖 Godot 运行，纯数学等价验证）

背景：
  本作的树 / 角色 / 敌人都是平面贴图，必须"正对镜头"才好看。
  只用水平朝向（billboard = FIXED_Y）时，相机俯角会把竖直贴图按 cos(俯角)
  压扁 —— 推近时高、拉远时矮。script/visual/sprite_facing.gd 的做法是
  "水平朝向相机 + 绕贴图底边做俯角补偿"，让屏幕高度恒定。

这个脚本不调用 GDScript，而是把 sprite_facing.gd 的算法按同样公式复算一遍，
用来做四件事：
  1. 验证旋转矩阵合法（正交、右手系、底边水平），任何 yaw / 俯角组合下都成立；
  2. 验证贴图法线确实指向相机（夹角恒 0）；
  3. 验证**手性没变**（贴图局部 +X == 相机右方向，即"未镜像"），
     并顺带核对 physics.gd / slime.gd 里的 flip_h 符号是否与这套手性配套 ——
     2026-09-22 就是这一层从"镜像"变成"未镜像"时漏改了符号，
     表现为"人物左右方向反了"，所以这条必须常驻；
  4. 量化"补偿前 vs 补偿后"的贴图高度差，改相机参数后一眼看出效果。

相机参数直接从 script/player/camera_3d.gd 的 @export 默认值读取，
所以调完手感不用改这里。

用法：python test/sprite_facing_check.py
"""

import io
import math
import re
import sys
import os

CAMERA_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "script", "player", "camera_3d.gd")


def read_exports(path):
    """从 camera_3d.gd 读出 @export 的默认数值。"""
    text = io.open(path, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^@export(?:_range\([^)]*\))?\s+var\s+(\w+)\s*:\s*float\s*=\s*([-\d.]+)",
                         text, re.M):
        out[m.group(1)] = float(m.group(2))
    return out


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def norm(v):
    n = math.sqrt(sum(c * c for c in v))
    if n < 1e-12:
        return (0.0, 0.0, -1.0)
    return tuple(c / n for c in v)


class Cam:
    def __init__(self, cfg):
        self.near = cfg["pitch_near_degrees"]
        self.far = cfg["pitch_far_degrees"]
        self.min_zoom = cfg["min_zoom"]
        self.max_zoom = cfg["max_zoom"]
        self.dist = cfg["base_distance"]
        self.step = cfg["rotate_step_degrees"]

    def pitch(self, zoom):
        span = self.max_zoom - self.min_zoom
        if span <= 0.0:
            return self.near
        t = max(0.0, min(1.0, (zoom - self.min_zoom) / span))
        return self.near + (self.far - self.near) * t

    def to_camera(self, zoom, yaw_deg):
        """物体 → 相机的单位方向（= 相机 basis 的 +Z 列）。"""
        p = math.radians(self.pitch(zoom))
        y = math.radians(yaw_deg)
        ox, oy, oz = 0.0, math.sin(p), -math.cos(p)
        rx = ox * math.cos(y) + oz * math.sin(y)
        rz = -ox * math.sin(y) + oz * math.cos(y)
        return norm((rx, oy, rz))


def facing_basis(to_camera, tilt_ratio=1.0):
    """与 script/visual/sprite_facing.gd::facing_basis() 逐行等价。"""
    pitch = math.asin(max(-1.0, min(1.0, to_camera[1])))
    flat = (to_camera[0], 0.0, to_camera[2])
    if flat[0] ** 2 + flat[2] ** 2 < 1e-6:
        flat = (0.0, 0.0, -1.0)
    flat = norm(flat)

    tilt = pitch * max(0.0, min(1.0, tilt_ratio))
    c, s = math.cos(tilt), math.sin(tilt)
    up = (0.0, 1.0, 0.0)

    z = norm(tuple(flat[i] * c + up[i] * s for i in range(3)))
    y = norm(tuple(up[i] * c - flat[i] * s for i in range(3)))
    x = norm(cross(y, z))
    return x, y, z


def main():
    cfg = read_exports(CAMERA_SCRIPT)
    need = ["pitch_near_degrees", "pitch_far_degrees", "min_zoom",
            "max_zoom", "base_distance", "rotate_step_degrees"]
    missing = [k for k in need if k not in cfg]
    if missing:
        print("读不到相机参数：%s（检查 camera_3d.gd 的 @export 写法）" % missing)
        return 1

    cam = Cam(cfg)
    print("相机参数：俯角 %.0f° ~ %.0f° | zoom %.2f ~ %.2f | 机位距离 %.3f | 档位 %.0f°"
          % (cam.near, cam.far, cam.min_zoom, cam.max_zoom, cam.dist, cam.step))
    print()

    failed = []

    # ---- 1. 旋转矩阵合法性：正交 + 右手系 ----
    for zoom in (cam.min_zoom, (cam.min_zoom + cam.max_zoom) / 2.0, cam.max_zoom):
        yaw = 0.0
        while yaw < 360.0:
            x, y, z = facing_basis(cam.to_camera(zoom, yaw))
            for a, b, nm in ((x, y, "x·y"), (y, z, "y·z"), (x, z, "x·z")):
                if abs(dot(a, b)) > 1e-9:
                    failed.append("非正交 %s @ zoom=%.2f yaw=%.0f" % (nm, zoom, yaw))
            if abs(dot(cross(x, y), z) - 1.0) > 1e-9:
                failed.append("手性错误（应为右手系）@ zoom=%.2f yaw=%.0f" % (zoom, yaw))
            # 底边必须水平：贴图左右轴不能有竖直分量
            if abs(x[1]) > 1e-9:
                failed.append("底边不水平 @ zoom=%.2f yaw=%.0f" % (zoom, yaw))
            yaw += cam.step

    # ---- 2. 贴图法线是否真的指向相机 ----
    worst = 0.0
    zoom = cam.min_zoom
    while zoom <= cam.max_zoom + 1e-9:
        yaw = 0.0
        while yaw < 360.0:
            back = cam.to_camera(zoom, yaw)
            _, _, z = facing_basis(back)
            ang = math.degrees(math.acos(max(-1.0, min(1.0, dot(z, back)))))
            worst = max(worst, ang)
            yaw += cam.step
        zoom += 0.2
    print("[1] 旋转矩阵：正交 / 右手系 / 底边水平 —— %s"
          % ("通过" if not failed else "失败"))
    print("[2] 贴图法线与视线夹角：最大 %.4f°（0 = 完全正对镜头）" % worst)
    if worst > 0.01:
        failed.append("法线未正对相机：%.4f°" % worst)
    print()

    # ---- 3. 手性 / 镜像约定 ----
    # 贴图的局部 +X 必须落在"屏幕右"上，也就是 == 相机右方向。
    # 这一条不为 ±0 只是因为"好看"——它决定贴图会不会左右镜像，
    # 而角色/敌人的左右翻转是按某个固定符号调出来的：
    #   局部 +X == 相机右  → 未镜像（与引擎 billboard = ENABLED/FIXED_Y 一致）
    #   局部 +X == -相机右 → 镜像（旧代码 look_at(相机方向) 的结果）
    # 2026-09-22 就是这一层从"镜像"变成"未镜像"时，忘了把
    # physics.gd / slime.gd 的 flip_h 符号跟着取反 → 人物左右方向反了。
    mirror_err = 0.0
    zoom = cam.min_zoom
    while zoom <= cam.max_zoom + 1e-9:
        yaw = 0.0
        while yaw < 360.0:
            back = cam.to_camera(zoom, yaw)
            cam_right = norm(cross((0.0, 1.0, 0.0), back))
            x, _, _ = facing_basis(back)
            mirror_err = max(mirror_err, abs(dot(x, cam_right) - 1.0))
            yaw += cam.step
        zoom += 0.2
    print("[3] 手性：贴图局部 +X 与相机右方向一致（未镜像）—— %s"
          % ("通过" if mirror_err < 1e-9 else "失败"))

    # ---- 4. 两个实体的 flip_h 符号是否对上了这套手性 ----
    # 纯文本核对（改的是常量表达式，不值得为它上解析器）。
    flip_rules = [
        (os.path.join("script", "player", "physics.gd"),
         re.compile(r"not\s+facing_left"),
         "玩家 BaseBody 自带一次水平镜像（180°旋转 + flip_v 抵消后剩镜像）"
         " ⇒ 必须 `not facing_left`"),
        (os.path.join("script", "ai", "enemy", "mob", "slime.gd"),
         re.compile(r"flip_h\s*=\s*_facing_left"),
         "史莱姆 Sprite 是单位变换、没有内置镜像 ⇒ 直接 `= _facing_left`"),
    ]
    print("[4] flip_h 符号是否与这套手性配套（玩家取反、史莱姆不取反）")
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    for rel, pat, why in flip_rules:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print("    失败 找不到 %s" % rel)
            failed.append("找不到 %s" % rel)
            continue
        text = io.open(path, encoding="utf-8").read()
        if pat.search(text):
            print("    OK  %s" % rel)
        else:
            print("    失败 %s —— 没找到预期写法。%s" % (rel, why))
            failed.append("%s 的 flip_h 符号可能反了：%s" % (rel, why))

    if mirror_err >= 1e-9:
        failed.append("贴图局部 +X 不再等于相机右方向 —— 手性变了，"
                      "physics.gd / slime.gd 的 flip_h 必须跟着取反")
    print()

    # ---- 5. 屏幕高度对比 ----
    print("[5] 贴图在屏幕上的高度（以正对镜头为 100%）")
    print("    zoom   俯角     不补偿      补偿后")
    for zoom in (cam.min_zoom, 1.0, cam.max_zoom):
        p = math.radians(cam.pitch(zoom))
        print("    %.2f   %5.1f°   %6.1f%%    %6.1f%%"
              % (zoom, cam.pitch(zoom), math.cos(p) * 100.0, 100.0))
    lo = math.cos(math.radians(cam.pitch(cam.min_zoom))) * 100.0
    hi = math.cos(math.radians(cam.pitch(cam.max_zoom))) * 100.0
    print("    不补偿时高度会在 %.1f%% ~ %.1f%% 之间变化（差 %.0f%%），"
          % (hi, lo, lo - hi))
    print("    也就是同一个东西推近拉远会'忽高忽低'；补偿后恒为 100%。")
    print()

    if failed:
        print("发现 %d 个问题：" % len(failed))
        for f in failed[:20]:
            print("   -", f)
        return 1
    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
