#!/usr/bin/env python3
"""Rebuild branding/logo-mask.txt from branding/logo-512.png (dev only, needs Pillow).

The mask is what `exarch splash` turns into 3D character art:
  .  empty   1  body (violet)   2  injector (lavender)
Usage: python3 scripts/make-logo-mask.py [WIDTH]
"""
import sys
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent.parent
src = root / "branding" / "logo-512.png"
out = root / "branding" / "logo-mask.txt"
width = int(sys.argv[1]) if len(sys.argv) > 1 else 96

im = Image.open(src).convert("RGB")
px = im.load()
W, H = im.size

def kind(r, g, b):
    if r + g + b < 90:
        return 0
    return 2 if g > 120 else 1          # lavender #c8a0ff vs violet #7a2fe0

# bounding box of the logo
xs, ys = [], []
for y in range(H):
    for x in range(W):
        if kind(*px[x, y]):
            xs.append(x); ys.append(y)
x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
cell = (x1 - x0) / width
height = round((y1 - y0) / cell)

rows = []
for j in range(height):
    row = []
    for i in range(width):
        votes = [0, 0, 0]
        sx0, sx1 = x0 + i * cell, x0 + (i + 1) * cell
        sy0, sy1 = y0 + j * cell, y0 + (j + 1) * cell
        for sy in range(int(sy0), max(int(sy0) + 1, int(sy1))):
            for sx in range(int(sx0), max(int(sx0) + 1, int(sx1))):
                if sx < W and sy < H:
                    votes[kind(*px[sx, sy])] += 1
        total = sum(votes) or 1
        if votes[0] / total > 0.55:
            row.append(".")
        else:
            row.append("2" if votes[2] >= votes[1] * 0.6 else "1")
    rows.append("".join(row))

out.write_text("\n".join(rows) + "\n")
print(f"{out}: {width}x{height}")
