#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
存档地形自检（不需要 Godot，直接读存档 JSON）

用途：验证"地形快照"这条链路在实机上是通的，并回答一个关键问题 ——
     **存档里的资源 / 敌人 / 掉落物 / 建筑，是否都落在陆地而不是海里？**

检查项：
  1. 存档有没有 map 段（地形快照）
  2. base64 能否解出、DEFLATE 能否解压、字节数是否等于 宽 × 高
  3. tiles_hash 与解压结果的 SHA-256 是否一致（存档有没有被改坏）
  4. 地形取值是否都在已知编号内（7/8/10~15）
  5. 所有实体坐标换算成瓦片后，脚下地形是不是海洋 ——
     这项是整套设计的核心断言：地形与实体坐标必须一致。

用法：
    python test/verify_save_map.py                 # 自动取最新存档
    python test/verify_save_map.py <存档路径>
"""

import base64
import glob
import hashlib
import json
import os
import sys
import zlib

MAP_W = 1600          # 与 map_generator.gd 的 MAP_WIDTH 保持一致
TILE_SIZE = 1         # 单格 1 世界单位
HALF = MAP_W / 2.0    # 世界原点在瓦片 (800, 800)

TERRAIN_NAMES = {
    0: "未开发", 7: "海洋", 8: "沙滩", 10: "草原", 11: "丛林",
    12: "岩石", 13: "沙地", 14: "火山", 15: "雪地",
}

def _roaming() -> str:
    """Windows 的 AppData\\Roaming 目录（APPDATA 有时不在这台机器的环境里）"""
    for key in ("APPDATA", "USERPROFILE"):
        base = os.environ.get(key)
        if not base:
            continue
        if key == "APPDATA":
            return base
        return os.path.join(base, "AppData", "Roaming")
    return ""


DEFAULT_SAVE_DIR = os.path.join(
    _roaming(), "Godot", "app_userdata", "loss_land", "saves")


def newest_save() -> str:
    files = glob.glob(os.path.join(DEFAULT_SAVE_DIR, "slot_*.json"))
    if not files:
        return ""
    return max(files, key=os.path.getmtime)


def inflate(raw: bytes) -> bytes:
    """Godot 的 COMPRESSION_DEFLATE 是 zlib 流；raw/gzip 各兜一次底。"""
    for wbits, tag in ((15, "zlib"), (-15, "raw deflate"), (31, "gzip")):
        try:
            return zlib.decompress(raw, wbits)
        except zlib.error:
            continue
    raise zlib.error("三种 deflate 封装都试过，无法解压")


def world_to_tile(x: float, z: float):
    """世界坐标 → 瓦片下标（与 map_generator_3d 的转换互逆）"""
    tx = int(round(x / TILE_SIZE + HALF))
    ty = int(round(z / TILE_SIZE + HALF))
    return tx, ty


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else newest_save()
    if not path or not os.path.exists(path):
        print("找不到存档文件，请手动传路径：python test/verify_save_map.py <存档路径>")
        return 2
    print("存档： %s（%.1f KB）" % (path, os.path.getsize(path) / 1024))
    data = json.load(open(path, encoding="utf-8"))
    print("格式版本：v%s    顶层键：%s" % (data.get("version"), sorted(data.keys())))

    mapsec = data.get("map") or {}
    if not mapsec:
        print("\n[!] 没有 map 段 —— 这是 v1 老存档（地形靠种子重算）。")
        print("    新建存档并保存一次后，本脚本才能验证地形快照。")
        return 1

    w, h = int(mapsec.get("w", 0)), int(mapsec.get("h", 0))
    size = int(mapsec.get("size", 0))
    print("\n--- 1/4 地形快照 ---")
    print("尺寸 %d × %d = %d 字节 | 存档记录 size=%d | base64 %.1f KB"
          % (w, h, w * h, size, len(mapsec.get("tiles", "")) / 1024))
    assert size == w * h, "size 与 宽×高 不符：%d vs %d" % (size, w * h)

    tiles = inflate(base64.b64decode(mapsec["tiles"]))
    print("解压后 %d 字节（预期 %d）%s"
          % (len(tiles), size, "  OK" if len(tiles) == size else "  ✗ 不符"))
    assert len(tiles) == size

    want = mapsec.get("tiles_hash", "")
    got = hashlib.sha256(tiles).hexdigest()
    print("SHA-256 校验：%s" % ("一致 OK" if want == got else "不一致 ✗（存档可能损坏）"))

    print("\n--- 2/4 地形编号 ---")
    hist = {}
    for b in tiles:
        hist[b] = hist.get(b, 0) + 1
    unknown = [k for k in hist if k not in TERRAIN_NAMES]
    for k in sorted(hist):
        print("  %2d %-6s %9d 格  %5.2f%%"
              % (k, TERRAIN_NAMES.get(k, "未知!"), hist[k], hist[k] * 100.0 / len(tiles)))
    print("  未知编号：%s" % (unknown if unknown else "无 OK"))
    land = len(tiles) - hist.get(7, 0)
    print("  陆地占比 %.1f%%" % (land * 100.0 / len(tiles)))

    print("\n--- 3/4 实体坐标是否落在陆地上（核心断言）---")
    buckets = {
        "资源": data["world"].get("resources", {}).get("resources", []),
        "敌人": data["world"].get("enemies", []),
        "掉落物": data["world"].get("drops", []),
        "建筑": data.get("buildings", []),
    }
    total_bad = 0
    for label, items in buckets.items():
        bad = []
        for it in items:
            pos = it.get("position") or it.get("pos") or {}
            if not pos:
                continue
            tx, ty = world_to_tile(float(pos.get("x", 0)), float(pos.get("z", 0)))
            if not (0 <= tx < w and 0 <= ty < h):
                bad.append((it.get("resource_id") or it.get("id") or "?", tx, ty, "越界"))
                continue
            t = tiles[ty * w + tx]
            if t == 7:
                bad.append((it.get("resource_id") or it.get("id") or "?", tx, ty, "海洋"))
        total_bad += len(bad)
        mark = "OK" if not bad else "✗ %d 个泡在海里" % len(bad)
        print("  %-4s %4d 条  %s" % (label, len(items), mark))
        for b in bad[:5]:
            print("        例：%s 瓦片(%d,%d) = %s" % b)

    print("\n--- 4/4 结论 ---")
    if total_bad == 0:
        print("  地形与实体坐标一致：没有实体落在海里。存档的地形快照可用。")
        return 0
    print("  ✗ 有 %d 个实体落在海洋格上 —— 地形与实体坐标不一致。" % total_bad)
    print("    若这些是 v1 老存档（无 map 段）遗留的坐标，属预期；")
    print("    若 map 段存在却仍不一致，说明地形快照没被真正应用。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
