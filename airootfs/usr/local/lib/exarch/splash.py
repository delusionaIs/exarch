#!/usr/bin/env python3
"""Exarch terminal splash: the logo as spinning 3D character art.

The logo mask (branding/logo-mask.txt) is extruded into a thin slab,
ray-cast every frame, lit, and drawn with an Arch-style character ramp in
violet truecolor. Embers drift up around it, a glow halo hugs the silhouette,
a shine sweeps across when it lands, and the title decodes in beside it.

  splash.py                 spin in, settle, leave the art in the scrollback
  splash.py --static        final frame only, no animation
  splash.py --loop          keep spinning until a key is pressed (screensaver)
  splash.py --banner        like --loop, but the key that stops it goes on to your
                            shell, and it settles by itself after --timeout SECONDS (120)
  splash.py --export-fastfetch [--size COLS]
                            print the front view as a fastfetch logo ($1-$4 colours)
  options: --mask FILE  --name NAME  --no-info  --size COLS

Any key skips the intro (the key still reaches your shell). Standard library only.
"""
import math
import os
import random
import select
import shutil
import socket
import sys
import termios
import time

# ---------------------------------------------------------------- palette ---
BODY = [(0.00, (48, 20, 92)), (0.22, (92, 38, 180)), (0.42, (122, 47, 224)),
        (0.62, (154, 92, 255)), (0.82, (200, 160, 255)), (1.00, (255, 246, 255))]
INJECTOR = [(0.00, (110, 80, 170)), (0.40, (200, 160, 255)), (0.70, (232, 212, 255)),
            (1.00, (255, 255, 255))]
TIP = (255, 140, 214)            # the top of the logo glows pink, like neon
PINK = (255, 95, 162)
HALO = (58, 26, 110)
EMBER = [(90, 40, 170), (154, 92, 255), (200, 160, 255), (255, 95, 162)]
RAMP = ".`-:/+osyhdmN"          # dim -> bright, the classic Arch fastfetch feel
EMBER_CHARS = "··˙'.•✦"
GLITCH = "!<>-_\\/[]{}=+*^?#$%&01"


def lerp(a, b, t):
    return a + (b - a) * t


def grad(stops, t):
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            k = (t - t0) / (t1 - t0) if t1 > t0 else 0
            return (int(lerp(c0[0], c1[0], k)), int(lerp(c0[1], c1[1], k)), int(lerp(c0[2], c1[2], k)))
    return stops[-1][1]


def mix(c1, c2, t):
    return (int(lerp(c1[0], c2[0], t)), int(lerp(c1[1], c2[1], t)), int(lerp(c1[2], c2[2], t)))


# --------------------------------------------------------------- terminal ---
TRUECOLOR = (os.environ.get("COLORTERM", "") in ("truecolor", "24bit")
             or any(t in os.environ.get("TERM", "") for t in ("kitty", "alacritty", "wezterm", "foot", "ghostty")))


def fg(c):
    r, g, b = c
    if TRUECOLOR:
        return f"\x1b[38;2;{r};{g};{b}m"
    # nearest xterm-256 colour cube entry
    q = lambda v: 0 if v < 48 else 1 if v < 115 else (v - 35) // 40
    return f"\x1b[38;5;{16 + 36 * q(r) + 6 * q(g) + q(b)}m"


# ------------------------------------------------------------------- mask ---
def find_mask(explicit):
    here = os.path.dirname(os.path.realpath(__file__))
    for p in (explicit, os.environ.get("EXARCH_DATA", "") and os.path.join(os.environ["EXARCH_DATA"], "branding/logo-mask.txt"),
              "/usr/share/exarch/branding/logo-mask.txt",
              os.path.join(here, "../../../../../branding/logo-mask.txt")):
        if p and os.path.isfile(p):
            return p
    return None


class Logo:
    """Mask -> per-row solid spans + bevel distances, in object units."""

    def __init__(self, path):
        with open(path, encoding="utf-8") as f:
            self.grid = [line.rstrip("\n") for line in f if line.strip()]
        self.h = len(self.grid)
        self.w = max(len(r) for r in self.grid)
        self.grid = [r.ljust(self.w, ".") for r in self.grid]
        self.aspect = self.h / self.w
        # distance to the nearest empty cell (bevel), 4-neighbour BFS
        inf = 99
        d = [[0 if self.grid[y][x] == "." else inf for x in range(self.w)] for y in range(self.h)]
        frontier = [(x, y) for y in range(self.h) for x in range(self.w) if d[y][x] == 0]
        for y in range(self.h):
            for x in range(self.w):
                if d[y][x] and (x in (0, self.w - 1) or y in (0, self.h - 1)):
                    d[y][x] = 1
                    frontier.append((x, y))
        while frontier:
            nxt = []
            for x, y in frontier:
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < self.w and 0 <= ny < self.h and d[ny][nx] > d[y][x] + 1:
                        d[ny][nx] = d[y][x] + 1
                        nxt.append((nx, ny))
            frontier = nxt
        self.dist = d
        # solid spans per row, u in [-0.5, 0.5]
        self.spans = []
        for row in self.grid:
            spans, x = [], 0
            while x < self.w:
                if row[x] != ".":
                    s = x
                    while x < self.w and row[x] != ".":
                        x += 1
                    spans.append(((s / self.w) - 0.5, (x / self.w) - 0.5))
                else:
                    x += 1
            self.spans.append(spans)


# --------------------------------------------------------------- renderer ---
LIGHT = (-0.45, 0.55, 0.70)
_n = math.sqrt(sum(c * c for c in LIGHT))
LIGHT = tuple(c / _n for c in LIGHT)
HALF_DEPTH = 0.055


def render_logo(logo, cols, rows, angle, t, shine=-9.0, pulse=0.0, fade=1.0):
    """Returns rows of (char, rgb|None) cells for the logo at this angle."""
    ca, sa = math.cos(angle), math.sin(angle)
    du, dw = sa, -ca                       # ray direction in object (u, w)
    out = []
    lx, ly, lz = LIGHT
    for r in range(rows):
        my = min(logo.h - 1, int((r + 0.5) / rows * logo.h))
        spans = logo.spans[my]
        v = my / logo.h                        # 0 top .. 1 bottom
        line = []
        for c in range(cols):
            x = (c + 0.5) / cols - 0.5
            ou, ow = x * ca, x * sa
            best, face = None, None
            # slab intersection with each extruded span
            for u0, u1 in spans:
                if abs(du) > 1e-9:
                    a1, a2 = (u0 - ou) / du, (u1 - ou) / du
                    tu0, tu1 = (a1, a2) if a1 < a2 else (a2, a1)
                elif u0 <= ou <= u1:
                    tu0, tu1 = -1e9, 1e9
                else:
                    continue
                if abs(dw) > 1e-9:
                    b1, b2 = (-HALF_DEPTH - ow) / dw, (HALF_DEPTH - ow) / dw
                    tw0, tw1 = (b1, b2) if b1 < b2 else (b2, b1)
                elif -HALF_DEPTH <= ow <= HALF_DEPTH:
                    tw0, tw1 = -1e9, 1e9
                else:
                    continue
                enter = tu0 if tu0 > tw0 else tw0
                if enter <= min(tu1, tw1) and (best is None or enter < best):
                    best = enter
                    face = ("side", -1.0 if du > 0 else 1.0, u0 if du > 0 else u1) if tu0 > tw0 else ("front", -1.0 if dw > 0 else 1.0, None)
            if best is None:
                line.append((" ", None))
                continue
            hu = ou + best * du
            mx = min(logo.w - 1, max(0, int((hu + 0.5) * logo.w)))
            if face[0] == "front":
                nu, nw = 0.0, face[1]
            else:
                nu, nw = face[1], 0.0
                mx = min(logo.w - 1, max(0, int((face[2] + 0.5) * logo.w) - (1 if face[1] > 0 else 0)))
            # object normal -> world
            nx, nz = nu * ca + nw * sa, -nu * sa + nw * ca
            diff = max(0.0, nx * lx + nz * lz)
            # half vector specular (viewer is +z)
            hx, hy, hz = lx, ly, lz + 1.0
            hn = math.sqrt(hx * hx + hy * hy + hz * hz)
            spec = max(0.0, (nx * hx + nz * hz) / hn) ** 24
            mat = logo.grid[my][mx]
            if face[0] == "front":
                bevel = min(1.0, (logo.dist[my][mx] - 1) / 3.0)
                grain = ((mx * 73856093 ^ my * 19349663) % 97) / 97 - 0.5   # stable texture
                lum = (0.10 + 0.62 * diff * (0.30 + 0.70 * bevel) + 0.22 * (1 - v)
                       + 0.30 * spec + 0.07 * grain)
                band = (hu + 0.5) + v * 0.6 - shine         # diagonal shine sweep
                lum += 0.9 * math.exp(-(band * band) / 0.004)
            else:
                grain = ((mx * 83492791 ^ my * 2654435) % 89) / 89 - 0.5
                lum = 0.08 + 0.50 * diff + 0.25 * spec + 0.20 * (1 - v) + 0.10 * grain
            lum = max(0.0, min(1.0, lum * fade))
            ch = RAMP[min(len(RAMP) - 1, int(lum * (len(RAMP) - 0.01)))]
            tone = lum ** 0.8                              # lift the mids
            if mat == "2":
                col = grad(INJECTOR, min(1.0, tone + 0.15))
                if pulse > 0:
                    col = mix(col, PINK, pulse * (0.35 + 0.65 * lum))
            else:
                col = mix(grad(BODY, tone), TIP, 0.45 * (1 - v) ** 2.2)
            line.append((ch, col))
        out.append(line)
    return out


def add_halo(cells, t, strength=1.0):
    rows, cols = len(cells), len(cells[0]) if cells else 0
    solid = [[col is not None for _, col in row] for row in cells]   # snapshot: halo must not feed itself
    for r in range(rows):
        row = cells[r]
        for c in range(cols):
            if solid[r][c]:
                continue
            near = 0
            for dr, dc in ((0, -1), (0, 1), (0, -2), (0, 2), (-1, 0), (1, 0)):
                rr, cc = r + dr, c + dc
                if 0 <= rr < rows and 0 <= cc < cols and solid[rr][cc]:
                    near += 1
            if near:
                flick = 0.6 + 0.4 * math.sin(t * 7 + r * 1.7 + c * 0.9)
                k = min(1.0, near / 3) * flick * strength
                row[c] = ("·" if k > 0.45 else ".", mix((10, 9, 16), HALO, k))


# ----------------------------------------------------------------- embers ---
class Embers:
    def __init__(self, cols, rows, n, seed=None):
        self.cols, self.rows = cols, rows
        self.rng = random.Random(seed)
        self.p = [self.spawn(initial=True) for _ in range(n)]

    def spawn(self, initial=False):
        rng = self.rng
        return {"x": rng.uniform(0, self.cols), "y": rng.uniform(0, self.rows) if initial else self.rows + rng.uniform(0, 3),
                "vy": rng.uniform(3.0, 9.0), "drift": rng.uniform(-1.2, 1.2),
                "ch": rng.choice(EMBER_CHARS), "col": rng.choice(EMBER),
                "life": rng.uniform(0.4, 1.0), "phase": rng.uniform(0, 6.28)}

    def step(self, dt, t):
        for i, e in enumerate(self.p):
            e["y"] -= e["vy"] * dt
            e["x"] += (e["drift"] + 0.8 * math.sin(t * 1.5 + e["phase"])) * dt
            if e["y"] < -1 or not (-2 < e["x"] < self.cols + 2):
                self.p[i] = self.spawn()

    def draw(self, cells, dim=1.0):
        rows, cols = len(cells), len(cells[0]) if cells else 0
        for e in self.p:
            r, c = int(e["y"]), int(e["x"])
            if 0 <= r < rows and 0 <= c < cols and cells[r][c][1] is None:
                fade = max(0.15, min(1.0, e["y"] / max(1, rows))) * e["life"] * dim
                cells[r][c] = (e["ch"], mix((10, 9, 16), e["col"], fade))


# ------------------------------------------------------------------- text ---
# "ANSI Shadow" letters for the big title (6 rows, 8 columns each)
BIG_FONT = {
    "E": ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"],
    "X": ["██╗  ██╗", "╚██╗██╔╝", " ╚███╔╝ ", " ██╔██╗ ", "██╔╝ ██╗", "╚═╝  ╚═╝"],
    "A": [" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
    "R": ["██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██║  ██║", "╚═╝  ╚═╝"],
    "C": [" ██████╗", "██╔════╝", "██║     ", "██║     ", "╚██████╗", " ╚═════╝"],
    "H": ["██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
}
BLOCKS = "█▓▒░"
SHADOW = (75, 26, 153)


def big_title_rows(name):
    word = name.upper()
    if not word or any(ch not in BIG_FONT for ch in word):
        return None
    return ["".join(BIG_FONT[ch][r] for ch in word) for r in range(6)]


def info_lines(name):
    lines = []
    try:
        user = os.environ.get("USER") or os.getlogin()
    except OSError:
        user = "user"
    host = socket.gethostname().split(".")[0]
    try:
        with open("/proc/uptime") as f:
            up = float(f.read().split()[0])
        h, m = int(up // 3600), int(up % 3600 // 60)
        uptime = f"{h}h {m}m" if h else f"{m}m"
    except OSError:
        uptime = "?"
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k] = int(v.split()[0])
        used = (mem["MemTotal"] - mem["MemAvailable"]) / 1048576
        memory = f"{used:.1f} / {mem['MemTotal'] / 1048576:.1f} GiB"
    except (OSError, KeyError, ValueError):
        memory = "?"
    session = os.environ.get("XDG_CURRENT_DESKTOP") or ("live ISO" if os.path.isdir("/run/archiso") else "tty")
    lines.append(("user", f"{user}@{host}"))
    lines.append(("\U000f08c7", f"{name} Linux"))                        # nf-md-arch
    lines.append(("", os.uname().release))                         # nf-fa-linux
    lines.append(("", session))                                    # nf-fa-window_maximize
    lines.append(("", os.path.basename(os.environ.get("SHELL", "bash"))))  # nf-fa-terminal
    lines.append(("\U000f0150", uptime))                                 # nf-md-clock_outline
    lines.append(("\U000f035b", memory))                                 # nf-md-memory
    return lines


def text_panel(name, show_info, big=True):
    """Panel lines: ("big", row_text, row_index) | ("title", text) | ("plain", [(text, rgb)])."""
    rows = big_title_rows(name) if big else None
    if rows:
        lines = [("big", row, i) for i, row in enumerate(rows)]
        width = len(rows[0])
    else:
        title = "  ".join(name.upper())
        lines = [("title", title)]
        width = len(title)
    lines.append(("plain", [("  // DEFEND · ATTACK · AUTOMATE" if rows else "// DEFEND · ATTACK · AUTOMATE", (122, 122, 140))]))
    lines.append(("plain", [("─" * max(width, 30), (42, 20, 80))]))
    if show_info:
        for icon, val in info_lines(name):
            if icon == "user":
                u, _, h = val.partition("@")
                lines.append(("plain", [(u, (154, 92, 255)), ("@", (106, 106, 112)), (h, (200, 160, 255))]))
            else:
                lines.append(("plain", [(icon + "  ", (154, 92, 255)), (val, (200, 198, 208))]))
        lines.append(("plain", [("", None)]))
        dots = []
        for c in [(42, 20, 80), (75, 26, 153), (122, 47, 224), (154, 92, 255), (200, 160, 255),
                  (255, 95, 162), (91, 227, 160), (77, 217, 255)]:
            dots.append(("● ", c))
        lines.append(("plain", dots))
    return lines


def panel_width(panel):
    w = 0
    for line in panel:
        if line[0] == "plain":
            w = max(w, sum(len(t) for t, _ in line[1]))
        else:
            w = max(w, len(line[1]))
    return w


def draw_title(title, progress, t, rng):
    """Small title, decode effect: letters settle left to right as progress goes 0 -> 1."""
    segs = []
    n = len(title)
    for i, ch in enumerate(title):
        settle = (i / max(1, n - 1)) * 0.75
        col = mix((154, 92, 255), PINK, (i / max(1, n - 1)) * 0.8)
        if ch == " ":
            segs.append((" ", col))
        elif progress >= settle + 0.25:
            segs.append((ch, col))
        elif progress >= settle:
            segs.append((rng.choice(GLITCH), mix(col, (255, 255, 255), 0.5)))
        else:
            segs.append((" ", col))
    return segs


def draw_big(row, ri, progress, t, rng, shimmer):
    """Big title row: columns materialise left to right through ░▒▓█, violet -> pink."""
    segs = []
    n = len(row)
    for i, ch in enumerate(row):
        k = i / max(1, n - 1)
        if ch == " ":
            segs.append((" ", None))
            continue
        settle = k * 0.7 + ri * 0.015
        base = mix((154, 92, 255), PINK, k ** 1.2 * 0.85)
        base = mix(base, (255, 255, 255), 0.18 * (1 - ri / 5))           # lit from above
        if shimmer is not None:                                           # a light bar sweeping across
            d = (k - shimmer) * 9
            base = mix(base, (255, 255, 255), 0.65 * math.exp(-d * d))
        if ch != "█":                                                     # the ╔═╝ shadow strokes
            base = mix(SHADOW, base, 0.35)
        if progress >= settle + 0.22:
            segs.append((ch, base))
        elif progress >= settle:
            segs.append((rng.choice(BLOCKS), mix(base, (255, 255, 255), 0.4)))
        else:
            segs.append((" ", None))
    return segs


# ------------------------------------------------------------------ frame ---
def compose(cells, panel, panel_progress, t, rng, logo_cols, gap, height, top_logo, top_text, shimmer=None):
    """Join the logo cells and the text panel into terminal lines."""
    out = []
    n_lines = max(1, len(panel))
    for r in range(height):
        buf, last = [], None
        lr = r - top_logo
        if 0 <= lr < len(cells):
            buf.append("\x1b[1m")                     # heavier strokes read brighter
            for ch, col in cells[lr]:
                if col is None:
                    buf.append(" ")
                    continue
                if col != last:
                    buf.append(fg(col))
                    last = col
                buf.append(ch)
        else:
            buf.append(" " * logo_cols)
        tr = r - top_text
        if panel and 0 <= tr < len(panel):
            line = panel[tr]
            buf.append("\x1b[0m" + " " * gap)
            last = None
            if line[0] == "big":
                buf.append("\x1b[1m")
                segs = draw_big(line[1], line[2], panel_progress, t, rng, shimmer)
            elif line[0] == "title":
                buf.append("\x1b[1m")
                segs = draw_title(line[1], panel_progress, t, rng)
            else:
                # lines below the title slide in one by one
                segs = line[1] if panel_progress >= 0.3 + 0.65 * tr / n_lines else []
            for text, col in segs:
                if col is not None and col != last:
                    buf.append(fg(col))
                    last = col
                buf.append(text)
        buf.append("\x1b[0m\x1b[K")
        out.append("".join(buf))
    return out


# ------------------------------------------------------------------- main ---
def parse(argv):
    opts = {"mode": "splash", "mask": None, "name": "Exarch", "info": True, "size": 0, "timeout": 120.0}
    it = iter(argv)
    for a in it:
        if a == "--static":
            opts["mode"] = "static"
        elif a == "--loop":
            opts["mode"] = "loop"
        elif a == "--banner":
            opts["mode"] = "banner"
        elif a == "--timeout":
            opts["timeout"] = float(next(it, "120"))
        elif a == "--mask":
            opts["mask"] = next(it, None)
        elif a == "--name":
            opts["name"] = next(it, "Exarch")
        elif a == "--no-info":
            opts["info"] = False
        elif a == "--size":
            opts["size"] = int(next(it, "0"))
        elif a == "--export-fastfetch":
            opts["mode"] = "export"
        elif a in ("-h", "--help"):
            print(__doc__.strip())
            sys.exit(0)
    return opts


SPIN, TOTAL = 1.9, 2.7          # intro: spin-in seconds, total seconds


class Scene:
    """Layout + one-frame rendering, shared by the terminal loop and previews."""

    def __init__(self, logo, tw, th, name="Exarch", info=True, size=0, seed=None):
        self.logo = logo
        self.gap = 4
        max_cols = size or min(64, int((th - 3) * 2 / logo.aspect))
        # big block title if it fits next to a decent-sized logo, else the small one
        for big in (True, False):
            self.panel = text_panel(name, info, big)
            panel_w = panel_width(self.panel) + 2
            cols = min(max_cols, tw - self.gap - panel_w - 2)
            if cols >= (34 if big else 26):
                break
        if cols < 26:                              # no room for text: logo alone
            self.panel = []
            cols = min(size or 64, tw - 4, int((th - 3) * 2 / logo.aspect))
        self.ok = cols >= 18
        cols -= cols % 2
        self.cols = cols
        self.rows = max(8, round(cols * logo.aspect / 2))
        self.height = max(self.rows, len(self.panel)) + 1
        self.top_text = max(0, (self.rows - len(self.panel)) // 2)
        self.rng = random.Random(seed)
        self.embers = Embers(cols, self.rows, n=max(10, cols // 3), seed=seed)

    def _compose(self, cells, progress, t, shimmer=None):
        return compose(cells, self.panel, progress, t, self.rng, self.cols, self.gap,
                       self.height, 0, self.top_text, shimmer)

    def intro(self, t, dt):
        ease = 1 - (1 - min(1.0, t / SPIN)) ** 3
        angle = (1 - ease) * 2.5 * math.pi
        shine = -9.0 if t < SPIN else lerp(-0.4, 2.2, (t - SPIN) / (TOTAL - SPIN))
        cells = render_logo(self.logo, self.cols, self.rows, angle, t, shine=shine,
                            fade=min(1.0, 0.25 + t / 0.6))
        add_halo(cells, t, min(1.0, t / 1.2))
        self.embers.step(dt, t)
        self.embers.draw(cells)
        shimmer = lerp(-0.2, 1.2, (t - 2.15) / 0.55) if t > 2.15 else None
        return self._compose(cells, max(0.0, (t - 1.0) / 1.2), t, shimmer)

    SPEED = 0.9                                  # rad/s: one slow turn every ~7 s

    def loop(self, t, dt, angle=None):
        angle = t * self.SPEED if angle is None else angle
        lap = (angle + math.pi) % (2 * math.pi) - math.pi    # -pi..pi, 0 = facing you
        shine = lerp(-0.4, 2.2, (lap + 0.2) / 0.9) if -0.2 < lap < 0.7 else -9.0
        cells = render_logo(self.logo, self.cols, self.rows, angle, t, shine=shine,
                            pulse=0.5 + 0.5 * math.sin(t * 2.2))
        add_halo(cells, t)
        self.embers.step(dt, t)
        self.embers.draw(cells)
        sweep = (t % 4.0) / 1.2                    # title shimmer every 4 s
        return self._compose(cells, min(1.0, t / 1.3), t, lerp(-0.2, 1.2, sweep) if sweep <= 1 else None)

    def final(self):
        cells = render_logo(self.logo, self.cols, self.rows, 0.0, 0.0)
        add_halo(cells, 0.0, 0.7)
        self.embers.draw(cells, dim=0.6)
        return self._compose(cells, 1.0, 0.0)


# fastfetch logo colours: $1 deep violet, $2 violet, $3 lavender, $4 pink/white highlights
FASTFETCH_COLORS = {"1": (92, 38, 180), "2": (154, 92, 255), "3": (200, 160, 255), "4": (255, 140, 214)}


def export_fastfetch(logo, cols):
    cells = render_logo(logo, cols, max(8, round(cols * logo.aspect / 2)), 0.0, 0.0)
    out = []
    for row in cells:
        line, cur = [], None
        for ch, col in row:
            if col is None:
                line.append(" ")
                continue
            r, g, b = col
            if r > 225 and g > 130:
                key = "4"
            elif g > 120:
                key = "3"
            elif g > 70:
                key = "2"
            else:
                key = "1"
            if key != cur:
                line.append("$" + key)
                cur = key
            line.append(ch)
        out.append("".join(line).rstrip())
    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"


def main():
    opts = parse(sys.argv[1:])
    if opts["mode"] == "export":
        path = find_mask(opts["mask"])
        if not path:
            return 1
        sys.stdout.write(export_fastfetch(Logo(path), opts["size"] or 40))
        return 0
    if not sys.stdout.isatty():
        return 0
    path = find_mask(opts["mask"])
    if not path:
        print("exarch splash: logo mask not found", file=sys.stderr)
        return 1
    tw, th = shutil.get_terminal_size((80, 24))
    scene = Scene(Logo(path), tw, th, opts["name"], opts["info"], opts["size"])
    if not scene.ok:
        return 0                                   # terminal too small: stay quiet
    height = scene.height

    fd_in = sys.stdin.fileno() if sys.stdin.isatty() else None
    old = None
    if fd_in is not None:
        old = termios.tcgetattr(fd_in)
        new = termios.tcgetattr(fd_in)
        new[3] &= ~(termios.ICANON | termios.ECHO)
        termios.tcsetattr(fd_in, termios.TCSANOW, new)   # NOW, never FLUSH: keep typed keys

    w = sys.stdout.write
    w("\x1b[?25l" + "\n" * height)

    def show(lines):
        w("\x1b[?2026h" + f"\x1b[{height}F" + "\n".join(lines) + "\n\x1b[?2026l")
        sys.stdout.flush()

    def key_waiting():
        return fd_in is not None and select.select([fd_in], [], [], 0)[0]

    dt = 1 / 40
    try:
        if opts["mode"] == "splash":
            t0 = time.monotonic()
            while True:
                t = time.monotonic() - t0
                if t >= TOTAL or key_waiting():
                    break
                show(scene.intro(t, dt))
                time.sleep(max(0.0, dt - ((time.monotonic() - t0) - t)))
        elif opts["mode"] in ("loop", "banner"):
            dt = 1 / 30                           # slow spin: 30 fps is plenty, half the CPU
            t0 = time.monotonic()
            t = 0.0
            while not key_waiting():
                t = time.monotonic() - t0
                # the Python fallback costs ~25% CPU while spinning, so it always stops
                if opts["mode"] == "banner" and t > (opts["timeout"] if opts["timeout"] > 0 else 120):
                    break
                show(scene.loop(t, dt))
                time.sleep(max(0.0, dt - ((time.monotonic() - t0) - t)))
            if opts["mode"] == "loop" and fd_in is not None:
                os.read(fd_in, 64)                # the key ends the screensaver
            # glide to face the front instead of snapping there
            a0 = t * Scene.SPEED
            a1 = math.ceil(a0 / (2 * math.pi)) * 2 * math.pi
            if a1 - a0 > math.pi:                 # closer to go back than all the way round
                a1 -= 2 * math.pi
            s0 = time.monotonic()
            while (k := (time.monotonic() - s0) / 0.45) < 1:
                ease = 1 - (1 - k) ** 3
                show(scene.loop(t + k * 0.45, dt, angle=lerp(a0, a1, ease)))
                time.sleep(dt)
        show(scene.final())
    except KeyboardInterrupt:
        show(scene.final())
    finally:
        w("\x1b[0m\x1b[?25h")
        sys.stdout.flush()
        if old is not None:
            termios.tcsetattr(fd_in, termios.TCSANOW, old)
    return 0


if __name__ == "__main__":
    sys.exit(main())
