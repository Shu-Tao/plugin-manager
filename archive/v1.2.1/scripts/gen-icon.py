#!/usr/bin/env python3
"""纯 Python 生成 App 图标（无第三方库）：渐变底 + 白色开关控件图形。

输出 iOS 传统命名，供 CFBundleIconFiles 使用：
  AppIcon60x60@2x.png (120)  AppIcon60x60@3x.png (180)
  AppIcon76x76@2x.png (152)  AppIcon76x76@2x~ipad? 省略
  AppIcon1024x1024.png       （备用）
"""
import os
import struct
import sys
import zlib


def png(width, height, rgba_rows):
    raw = b"".join(b"\x00" + row for row in rgba_rows)
    comp = zlib.compress(raw, 9)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", comp) + chunk(b"IEND", b""))


def blend(dst, src, alpha):
    return tuple(int(dst[i] * (1 - alpha) + src[i] * alpha) for i in range(3))


def render(size):
    rows = []
    radius = size * 0.22
    track_w = size * 0.62
    track_h = size * 0.34
    track_r = track_h / 2.0
    track_x = (size - track_w) / 2.0
    track_y = (size - track_h) / 2.0
    knob_r = track_h * 0.40
    knob_cx = track_x + track_w - track_r
    knob_cy = track_y + track_r

    for y in range(size):
        row = bytearray()
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            dx = min(px, size - px)
            dy = min(py, size - py)
            inside = True
            if dx < radius and dy < radius:
                ddx, ddy = radius - dx, radius - dy
                inside = (ddx * ddx + ddy * ddy) <= radius * radius
            if not inside:
                row += bytes((0, 0, 0, 0))
                continue

            t = px / size * 0.55 + py / size * 0.45
            color = (int(76 + t * 120), int(94 - t * 20), int(240 - t * 14))

            in_track = False
            if track_x <= px <= track_x + track_w and track_y <= py <= track_y + track_h:
                lx, ly = px - track_x, py - track_y
                if lx < track_r and (ly < track_r or ly > track_h - track_r):
                    ddx = track_r - lx
                    ddy = track_r - ly if ly < track_r else ly - (track_h - track_r)
                    in_track = (ddx * ddx + ddy * ddy) <= track_r * track_r
                elif lx > track_w - track_r and (ly < track_r or ly > track_h - track_r):
                    ddx = lx - (track_w - track_r)
                    ddy = track_r - ly if ly < track_r else ly - (track_h - track_r)
                    in_track = (ddx * ddx + ddy * ddy) <= track_r * track_r
                else:
                    in_track = True
            if in_track:
                color = blend(color, (255, 255, 255), 0.28)

            kdx, kdy = px - knob_cx, py - knob_cy
            dist = (kdx * kdx + kdy * kdy) ** 0.5
            if dist <= knob_r:
                color = blend(color, (255, 255, 255), 0.97)
            elif dist <= knob_r + 1.2:
                color = blend(color, (255, 255, 255), 0.55)

            row += bytes((color[0], color[1], color[2], 255))
        rows.append(bytes(row))
    return rows


TARGETS = [
    ("AppIcon60x60@2x.png", 120),
    ("AppIcon60x60@3x.png", 180),
    ("AppIcon76x76@2x.png", 152),
    ("AppIcon1024x1024.png", 1024),
]


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    for name, size in TARGETS:
        with open(os.path.join(out_dir, name), "wb") as fh:
            fh.write(png(size, size, render(size)))
        print("icon", name, size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
