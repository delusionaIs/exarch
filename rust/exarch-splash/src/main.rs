//! exarch-splash: Exarch's logo as spinning 3D character art.
//!
//! The logo mask is extruded into a slab, ray-cast every frame, lit, and drawn
//! with an Arch-style character ramp in violet truecolor. Embers drift up, a
//! glow hugs the silhouette, a shine sweeps across, and the title decodes in.
//! Only changed cells are redrawn, so it stays cheap enough to run all day as
//! the live wallpaper.
//!
//! No dependencies: terminal calls go straight to libc.

use std::f32::consts::PI;
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const USAGE: &str = "\
exarch-splash: the Exarch logo as spinning 3D character art

  exarch-splash               spin in, settle, leave the art in the scrollback
  exarch-splash --banner      rotate slowly until a key (the key goes on to your
                              shell); --timeout SECONDS settles it by itself (0 = never)
  exarch-splash --loop        rotate until a key (screensaver; the key is swallowed)
  exarch-splash --static      final frame only
  exarch-splash --wallpaper   full screen, forever (run inside a kitty background panel)
  exarch-splash --export-fastfetch [--size COLS]
                              print the front view as a fastfetch logo ($1-$4 colours)

  options: --mask FILE  --name NAME  --no-info  --size COLS  --fps N  --timeout S

Any key skips the intro. Ctrl-C always restores the terminal.";

// ------------------------------------------------------------------ colour --
#[derive(Clone, Copy, PartialEq, Debug)]
struct Rgb(u8, u8, u8);

const BG: Rgb = Rgb(10, 9, 16);
const BODY: [(f32, Rgb); 6] = [
    (0.00, Rgb(48, 20, 92)),
    (0.22, Rgb(92, 38, 180)),
    (0.42, Rgb(122, 47, 224)),
    (0.62, Rgb(154, 92, 255)),
    (0.82, Rgb(200, 160, 255)),
    (1.00, Rgb(255, 246, 255)),
];
const INJECTOR: [(f32, Rgb); 4] = [
    (0.00, Rgb(110, 80, 170)),
    (0.40, Rgb(200, 160, 255)),
    (0.70, Rgb(232, 212, 255)),
    (1.00, Rgb(255, 255, 255)),
];
const TIP: Rgb = Rgb(255, 140, 214);
const PINK: Rgb = Rgb(255, 95, 162);
const VIOLET: Rgb = Rgb(154, 92, 255);
const WHITE: Rgb = Rgb(255, 255, 255);
const HALO: Rgb = Rgb(58, 26, 110);
const SHADOW: Rgb = Rgb(75, 26, 153);
const EMBER: [Rgb; 4] = [Rgb(90, 40, 170), Rgb(154, 92, 255), Rgb(200, 160, 255), Rgb(255, 95, 162)];
const RAMP: &[u8] = b".`-:/+osyhdmN"; // dim -> bright, the classic Arch fastfetch feel
const EMBER_CHARS: [char; 7] = ['·', '·', '˙', '\'', '.', '•', '✦'];
const GLITCH: &[u8] = b"!<>-_\\/[]{}=+*^?#$%&01";
const BLOCKS: [char; 4] = ['█', '▓', '▒', '░'];

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

fn mix(a: Rgb, b: Rgb, t: f32) -> Rgb {
    let t = t.clamp(0.0, 1.0);
    Rgb(
        lerp(a.0 as f32, b.0 as f32, t) as u8,
        lerp(a.1 as f32, b.1 as f32, t) as u8,
        lerp(a.2 as f32, b.2 as f32, t) as u8,
    )
}

fn grad(stops: &[(f32, Rgb)], t: f32) -> Rgb {
    let t = t.clamp(0.0, 1.0);
    for w in stops.windows(2) {
        let ((t0, c0), (t1, c1)) = (w[0], w[1]);
        if t <= t1 {
            let k = if t1 > t0 { (t - t0) / (t1 - t0) } else { 0.0 };
            return mix(c0, c1, k);
        }
    }
    stops[stops.len() - 1].1
}

// ------------------------------------------------------------------- rng ----
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.max(1))
    }
    fn next(&mut self) -> u64 {
        // xorshift64*
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn f(&mut self, a: f32, b: f32) -> f32 {
        a + (b - a) * ((self.next() >> 40) as f32 / (1u64 << 24) as f32)
    }
    fn pick<T: Copy>(&mut self, xs: &[T]) -> T {
        xs[(self.next() % xs.len() as u64) as usize]
    }
}

// ------------------------------------------------------------------ cells ---
#[derive(Clone, Copy, PartialEq)]
struct Cell {
    ch: char,
    fg: Option<Rgb>,
    bold: bool,
}

const BLANK: Cell = Cell { ch: ' ', fg: None, bold: false };

struct Canvas {
    w: usize,
    h: usize,
    cells: Vec<Cell>,
    solid: Vec<bool>, // logo cells, for the halo and so embers stay behind
}

impl Canvas {
    fn new(w: usize, h: usize) -> Canvas {
        Canvas { w, h, cells: vec![BLANK; w * h], solid: vec![false; w * h] }
    }
    fn set(&mut self, x: usize, y: usize, c: Cell) {
        if x < self.w && y < self.h {
            self.cells[y * self.w + x] = c;
        }
    }
    fn get(&self, x: usize, y: usize) -> Cell {
        self.cells[y * self.w + x]
    }
}

// ------------------------------------------------------------------- logo ---
const DEFAULT_MASK: &str = include_str!("../../../branding/logo-mask.txt");

struct Logo {
    w: usize,
    h: usize,
    grid: Vec<Vec<u8>>,
    dist: Vec<Vec<i32>>,
    spans: Vec<Vec<(f32, f32)>>,
    aspect: f32,
}

impl Logo {
    fn parse(text: &str) -> Option<Logo> {
        let rows: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
        let h = rows.len();
        let w = rows.iter().map(|r| r.len()).max()?;
        if h < 4 || w < 4 {
            return None;
        }
        let grid: Vec<Vec<u8>> = rows
            .iter()
            .map(|r| {
                let mut v = r.as_bytes().to_vec();
                v.resize(w, b'.');
                v
            })
            .collect();
        // distance to the nearest empty cell (bevel), 4-neighbour BFS
        let mut dist = vec![vec![i32::MAX; w]; h];
        let mut frontier = Vec::new();
        for y in 0..h {
            for x in 0..w {
                if grid[y][x] == b'.' {
                    dist[y][x] = 0;
                    frontier.push((x, y));
                } else if x == 0 || y == 0 || x == w - 1 || y == h - 1 {
                    dist[y][x] = 1;
                    frontier.push((x, y));
                }
            }
        }
        while !frontier.is_empty() {
            let mut next = Vec::new();
            for &(x, y) in &frontier {
                let d = dist[y][x] + 1;
                let mut visit = |nx: usize, ny: usize| {
                    if dist[ny][nx] > d {
                        dist[ny][nx] = d;
                        next.push((nx, ny));
                    }
                };
                if x + 1 < w { visit(x + 1, y) }
                if x > 0 { visit(x - 1, y) }
                if y + 1 < h { visit(x, y + 1) }
                if y > 0 { visit(x, y - 1) }
            }
            frontier = next;
        }
        let spans = grid
            .iter()
            .map(|row| {
                let mut spans = Vec::new();
                let mut x = 0;
                while x < w {
                    if row[x] != b'.' {
                        let s = x;
                        while x < w && row[x] != b'.' {
                            x += 1;
                        }
                        spans.push((s as f32 / w as f32 - 0.5, x as f32 / w as f32 - 0.5));
                    } else {
                        x += 1;
                    }
                }
                spans
            })
            .collect();
        Some(Logo { w, h, grid, dist, spans, aspect: h as f32 / w as f32 })
    }
}

// --------------------------------------------------------------- renderer ---
const HALF_DEPTH: f32 = 0.055;

fn light() -> (f32, f32, f32) {
    let (x, y, z) = (-0.45f32, 0.55f32, 0.70f32);
    let n = (x * x + y * y + z * z).sqrt();
    (x / n, y / n, z / n)
}

struct Look {
    shine: f32, // position of the diagonal shine band; off-screen = no shine
    pulse: f32, // injector glow towards pink, 0..1
    fade: f32,  // global brightness, 0..1
}

const NO_SHINE: f32 = -9.0;

/// Ray-cast the extruded logo at `angle` into a cols x rows block of cells.
fn render_logo(logo: &Logo, cols: usize, rows: usize, angle: f32, look: &Look) -> Vec<Vec<Cell>> {
    let (ca, sa) = (angle.cos(), angle.sin());
    let (du, dw) = (sa, -ca); // ray direction in object (u, w)
    let (lx, ly, lz) = light();
    let (hx, hy, hz) = (lx, ly, lz + 1.0);
    let hn = (hx * hx + hy * hy + hz * hz).sqrt();
    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        let my = (((r as f32 + 0.5) / rows as f32 * logo.h as f32) as usize).min(logo.h - 1);
        let spans = &logo.spans[my];
        let v = my as f32 / logo.h as f32; // 0 top .. 1 bottom
        let mut line = Vec::with_capacity(cols);
        for c in 0..cols {
            let x = (c as f32 + 0.5) / cols as f32 - 0.5;
            let (ou, ow) = (x * ca, x * sa);
            // (t, is_side, normal sign, side edge u)
            let mut best: Option<(f32, bool, f32, f32)> = None;
            for &(u0, u1) in spans {
                let (tu0, tu1) = if du.abs() > 1e-9 {
                    let (a1, a2) = ((u0 - ou) / du, (u1 - ou) / du);
                    if a1 < a2 { (a1, a2) } else { (a2, a1) }
                } else if u0 <= ou && ou <= u1 {
                    (-1e9, 1e9)
                } else {
                    continue;
                };
                let (tw0, tw1) = if dw.abs() > 1e-9 {
                    let (b1, b2) = ((-HALF_DEPTH - ow) / dw, (HALF_DEPTH - ow) / dw);
                    if b1 < b2 { (b1, b2) } else { (b2, b1) }
                } else if (-HALF_DEPTH..=HALF_DEPTH).contains(&ow) {
                    (-1e9, 1e9)
                } else {
                    continue;
                };
                let enter = tu0.max(tw0);
                if enter <= tu1.min(tw1) && best.is_none_or(|b| enter < b.0) {
                    best = Some(if tu0 > tw0 {
                        (enter, true, if du > 0.0 { -1.0 } else { 1.0 }, if du > 0.0 { u0 } else { u1 })
                    } else {
                        (enter, false, if dw > 0.0 { -1.0 } else { 1.0 }, 0.0)
                    });
                }
            }
            let Some((t, side, sign, edge)) = best else {
                line.push(BLANK);
                continue;
            };
            let hu = ou + t * du;
            let mut mx = (((hu + 0.5) * logo.w as f32) as isize).clamp(0, logo.w as isize - 1) as usize;
            let (nu, nw) = if side {
                let e = ((edge + 0.5) * logo.w as f32) as isize - if sign > 0.0 { 1 } else { 0 };
                mx = e.clamp(0, logo.w as isize - 1) as usize;
                (sign, 0.0)
            } else {
                (0.0, sign)
            };
            let nx = nu * ca + nw * sa;
            let nz = -nu * sa + nw * ca;
            let diff = (nx * lx + nz * lz).max(0.0);
            let spec = ((nx * hx + nz * hz) / hn).max(0.0).powi(24);
            let mat = logo.grid[my][mx];
            let mut lum;
            if !side {
                let bevel = ((logo.dist[my][mx] - 1) as f32 / 3.0).min(1.0);
                let grain = (((mx * 73856093) ^ (my * 19349663)) % 97) as f32 / 97.0 - 0.5;
                lum = 0.10 + 0.62 * diff * (0.30 + 0.70 * bevel) + 0.22 * (1.0 - v) + 0.30 * spec + 0.07 * grain;
                let band = (hu + 0.5) + v * 0.6 - look.shine; // diagonal shine sweep
                lum += 0.9 * (-(band * band) / 0.004).exp();
            } else {
                let grain = (((mx * 83492791) ^ (my * 2654435)) % 89) as f32 / 89.0 - 0.5;
                lum = 0.08 + 0.50 * diff + 0.25 * spec + 0.20 * (1.0 - v) + 0.10 * grain;
            }
            lum = (lum * look.fade).clamp(0.0, 1.0);
            let ch = RAMP[((lum * (RAMP.len() as f32 - 0.01)) as usize).min(RAMP.len() - 1)] as char;
            let tone = lum.powf(0.8);
            let col = if mat == b'2' {
                let c = grad(&INJECTOR, (tone + 0.15).min(1.0));
                if look.pulse > 0.0 { mix(c, PINK, look.pulse * (0.35 + 0.65 * lum)) } else { c }
            } else {
                mix(grad(&BODY, tone), TIP, 0.45 * (1.0 - v).powf(2.2))
            };
            line.push(Cell { ch, fg: Some(col), bold: true });
        }
        out.push(line);
    }
    out
}

fn blit_logo(cv: &mut Canvas, cells: &[Vec<Cell>], x0: usize, y0: usize) {
    for (r, row) in cells.iter().enumerate() {
        for (c, cell) in row.iter().enumerate() {
            if cell.fg.is_some() {
                let (x, y) = (x0 + c, y0 + r);
                if x < cv.w && y < cv.h {
                    cv.set(x, y, *cell);
                    cv.solid[y * cv.w + x] = true;
                }
            }
        }
    }
}

fn add_halo(cv: &mut Canvas, t: f32, strength: f32) {
    let (w, h) = (cv.w as isize, cv.h as isize);
    for y in 0..h {
        for x in 0..w {
            if cv.solid[(y * w + x) as usize] {
                continue;
            }
            let mut near = 0;
            for (dy, dx) in [(0, -1), (0, 1), (0, -2), (0, 2), (-1, 0), (1, 0)] {
                let (yy, xx) = (y + dy, x + dx);
                if yy >= 0 && yy < h && xx >= 0 && xx < w && cv.solid[(yy * w + xx) as usize] {
                    near += 1;
                }
            }
            if near > 0 {
                let flick = 0.6 + 0.4 * (t * 7.0 + y as f32 * 1.7 + x as f32 * 0.9).sin();
                let k = (near as f32 / 3.0).min(1.0) * flick * strength;
                let ch = if k > 0.45 { '·' } else { '.' };
                cv.set(x as usize, y as usize, Cell { ch, fg: Some(mix(BG, HALO, k)), bold: false });
            }
        }
    }
}

// ----------------------------------------------------------------- embers ---
struct Ember {
    x: f32,
    y: f32,
    vy: f32,
    drift: f32,
    ch: char,
    col: Rgb,
    life: f32,
    phase: f32,
}

struct Embers {
    x0: f32,
    y0: f32,
    w: f32,
    h: f32,
    rng: Rng,
    p: Vec<Ember>,
}

impl Embers {
    fn new(x0: usize, y0: usize, w: usize, h: usize, n: usize, seed: u64) -> Embers {
        let mut e = Embers { x0: x0 as f32, y0: y0 as f32, w: w as f32, h: h as f32, rng: Rng::new(seed), p: Vec::new() };
        for _ in 0..n {
            let s = e.spawn(true);
            e.p.push(s);
        }
        e
    }
    fn spawn(&mut self, initial: bool) -> Ember {
        let r = &mut self.rng;
        Ember {
            x: r.f(0.0, self.w),
            y: if initial { r.f(0.0, self.h) } else { self.h + r.f(0.0, 3.0) },
            vy: r.f(3.0, 9.0),
            drift: r.f(-1.2, 1.2),
            ch: r.pick(&EMBER_CHARS),
            col: r.pick(&EMBER),
            life: r.f(0.4, 1.0),
            phase: r.f(0.0, std::f32::consts::TAU),
        }
    }
    fn step(&mut self, dt: f32, t: f32) {
        for i in 0..self.p.len() {
            let e = &mut self.p[i];
            e.y -= e.vy * dt;
            e.x += (e.drift + 0.8 * (t * 1.5 + e.phase).sin()) * dt;
            if e.y < -1.0 || e.x < -2.0 || e.x > self.w + 2.0 {
                self.p[i] = self.spawn(false);
            }
        }
    }
    fn draw(&self, cv: &mut Canvas, dim: f32) {
        for e in &self.p {
            if e.x < 0.0 || e.y < 0.0 {
                continue;
            }
            let (x, y) = ((self.x0 + e.x) as usize, (self.y0 + e.y) as usize);
            if x < cv.w && y < cv.h && cv.get(x, y).fg.is_none() {
                let fade = (e.y / self.h.max(1.0)).clamp(0.15, 1.0) * e.life * dim;
                cv.set(x, y, Cell { ch: e.ch, fg: Some(mix(BG, e.col, fade)), bold: false });
            }
        }
    }
}

// ------------------------------------------------------------------- text ---
// "ANSI Shadow" letters for the big title (6 rows, 8 columns each)
fn big_glyph(c: char) -> Option<[&'static str; 6]> {
    Some(match c {
        'E' => ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"],
        'X' => ["██╗  ██╗", "╚██╗██╔╝", " ╚███╔╝ ", " ██╔██╗ ", "██╔╝ ██╗", "╚═╝  ╚═╝"],
        'A' => [" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
        'R' => ["██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██║  ██║", "╚═╝  ╚═╝"],
        'C' => [" ██████╗", "██╔════╝", "██║     ", "██║     ", "╚██████╗", " ╚═════╝"],
        'H' => ["██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
        _ => return None,
    })
}

fn big_title(name: &str) -> Option<Vec<Vec<char>>> {
    let glyphs: Option<Vec<_>> = name.to_uppercase().chars().map(big_glyph).collect();
    let glyphs = glyphs?;
    if glyphs.is_empty() {
        return None;
    }
    Some((0..6).map(|r| glyphs.iter().flat_map(|g| g[r].chars()).collect()).collect())
}

enum Line {
    Big(Vec<char>, usize),
    Title(Vec<char>),
    Plain(Vec<(String, Option<Rgb>)>),
}

impl Line {
    fn width(&self) -> usize {
        match self {
            Line::Big(r, _) | Line::Title(r) => r.len(),
            Line::Plain(segs) => segs.iter().map(|(s, _)| s.chars().count()).sum(),
        }
    }
}

fn read_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn info_lines(name: &str) -> Vec<(String, String)> {
    let user = std::env::var("USER").unwrap_or_else(|_| "user".into());
    let host = read_trim("/proc/sys/kernel/hostname").unwrap_or_else(|| "localhost".into());
    let kernel = read_trim("/proc/sys/kernel/osrelease").unwrap_or_else(|| "?".into());
    let uptime = read_trim("/proc/uptime")
        .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
        .map(|u| {
            let (h, m) = ((u / 3600.0) as u64, (u % 3600.0 / 60.0) as u64);
            if h > 0 { format!("{h}h {m}m") } else { format!("{m}m") }
        })
        .unwrap_or_else(|| "?".into());
    let memory = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| {
            let get = |k: &str| -> Option<f64> {
                s.lines().find(|l| l.starts_with(k))?.split_whitespace().nth(1)?.parse().ok()
            };
            let (total, avail) = (get("MemTotal:")?, get("MemAvailable:")?);
            Some(format!("{:.1} / {:.1} GiB", (total - avail) / 1048576.0, total / 1048576.0))
        })
        .unwrap_or_else(|| "?".into());
    let session = std::env::var("XDG_CURRENT_DESKTOP").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| {
        if std::path::Path::new("/run/archiso").is_dir() { "live ISO".into() } else { "tty".into() }
    });
    let shell = std::env::var("SHELL").ok().and_then(|s| s.rsplit('/').next().map(String::from)).unwrap_or_else(|| "bash".into());
    vec![
        ("user".into(), format!("{user}@{host}")),
        ("\u{f08c7}".into(), format!("{name} Linux")), // nf-md-arch
        ("\u{f17c}".into(), kernel),                   // nf-fa-linux
        ("\u{f2d0}".into(), session),                  // nf-fa-window_maximize
        ("\u{f120}".into(), shell),                    // nf-fa-terminal
        ("\u{f0150}".into(), uptime),                  // nf-md-clock_outline
        ("\u{f035b}".into(), memory),                  // nf-md-memory
    ]
}

fn text_panel(name: &str, info: bool, big: bool) -> Vec<Line> {
    let mut lines = Vec::new();
    let width;
    let rows = if big { big_title(name) } else { None };
    let tagline = "// DEFEND · ATTACK · AUTOMATE";
    if let Some(rows) = rows {
        width = rows[0].len();
        for (i, r) in rows.into_iter().enumerate() {
            lines.push(Line::Big(r, i));
        }
        lines.push(Line::Plain(vec![(format!("  {tagline}"), Some(Rgb(122, 122, 140)))]));
    } else {
        let t: Vec<char> = name.to_uppercase().chars().flat_map(|c| [c, ' ', ' ']).collect();
        let t: Vec<char> = t[..t.len().saturating_sub(2)].to_vec();
        width = t.len();
        lines.push(Line::Title(t));
        lines.push(Line::Plain(vec![(tagline.into(), Some(Rgb(122, 122, 140)))]));
    }
    if info {
        lines.push(Line::Plain(vec![("─".repeat(width.max(30)), Some(Rgb(42, 20, 80)))]));
        for (icon, val) in info_lines(name) {
            if icon == "user" {
                let (u, h) = val.split_once('@').unwrap_or((&val, ""));
                lines.push(Line::Plain(vec![
                    (u.to_string(), Some(VIOLET)),
                    ("@".into(), Some(Rgb(106, 106, 112))),
                    (h.to_string(), Some(Rgb(200, 160, 255))),
                ]));
            } else {
                lines.push(Line::Plain(vec![(format!("{icon}  "), Some(VIOLET)), (val, Some(Rgb(200, 198, 208)))]));
            }
        }
        lines.push(Line::Plain(vec![]));
        let dots = [
            Rgb(42, 20, 80), Rgb(75, 26, 153), Rgb(122, 47, 224), Rgb(154, 92, 255),
            Rgb(200, 160, 255), Rgb(255, 95, 162), Rgb(91, 227, 160), Rgb(77, 217, 255),
        ];
        lines.push(Line::Plain(dots.iter().map(|c| ("● ".to_string(), Some(*c))).collect()));
    }
    lines
}

/// Draw one panel line at (x, y). `progress` 0..1 drives the decode-in.
#[allow(clippy::too_many_arguments)]
fn draw_line(cv: &mut Canvas, line: &Line, idx: usize, total: usize, x: usize, y: usize, progress: f32, shimmer: Option<f32>, rng: &mut Rng) {
    match line {
        Line::Big(row, ri) => {
            let n = row.len().max(2) as f32 - 1.0;
            for (i, &ch) in row.iter().enumerate() {
                if ch == ' ' {
                    continue;
                }
                let k = i as f32 / n;
                let settle = k * 0.7 + *ri as f32 * 0.015;
                let mut base = mix(VIOLET, PINK, k.powf(1.2) * 0.85);
                base = mix(base, WHITE, 0.18 * (1.0 - *ri as f32 / 5.0)); // lit from above
                if let Some(s) = shimmer {
                    let d = (k - s) * 9.0;
                    base = mix(base, WHITE, 0.65 * (-d * d).exp());
                }
                if ch != '█' {
                    base = mix(SHADOW, base, 0.35); // the ╔═╝ shadow strokes
                }
                let cell = if progress >= settle + 0.22 {
                    Cell { ch, fg: Some(base), bold: true }
                } else if progress >= settle {
                    Cell { ch: rng.pick(&BLOCKS), fg: Some(mix(base, WHITE, 0.4)), bold: true }
                } else {
                    continue;
                };
                cv.set(x + i, y, cell);
            }
        }
        Line::Title(row) => {
            let n = row.len().max(2) as f32 - 1.0;
            for (i, &ch) in row.iter().enumerate() {
                if ch == ' ' {
                    continue;
                }
                let k = i as f32 / n;
                let settle = k * 0.75;
                let col = mix(VIOLET, PINK, k * 0.8);
                let cell = if progress >= settle + 0.25 {
                    Cell { ch, fg: Some(col), bold: true }
                } else if progress >= settle {
                    Cell { ch: rng.pick(GLITCH) as char, fg: Some(mix(col, WHITE, 0.5)), bold: true }
                } else {
                    continue;
                };
                cv.set(x + i, y, cell);
            }
        }
        Line::Plain(segs) => {
            // lines below the title slide in one by one
            if progress < 0.3 + 0.65 * idx as f32 / total.max(1) as f32 {
                return;
            }
            let mut cx = x;
            for (text, col) in segs {
                for ch in text.chars() {
                    cv.set(cx, y, Cell { ch, fg: *col, bold: false });
                    cx += 1;
                }
            }
        }
    }
}

// --------------------------------------------------------------- terminal ---
#[repr(C)]
#[derive(Clone, Copy)]
struct Termios {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [u8; 32],
    ispeed: u32,
    ospeed: u32,
}

#[repr(C)]
struct Winsize {
    rows: u16,
    cols: u16,
    xpx: u16,
    ypx: u16,
}

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

extern "C" {
    fn tcgetattr(fd: i32, t: *mut Termios) -> i32;
    fn tcsetattr(fd: i32, act: i32, t: *const Termios) -> i32;
    fn ioctl(fd: i32, req: std::ffi::c_ulong, ...) -> i32;
    fn poll(fds: *mut PollFd, n: std::ffi::c_ulong, timeout: i32) -> i32;
    fn isatty(fd: i32) -> i32;
    fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
    fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
}

const TIOCGWINSZ: std::ffi::c_ulong = 0x5413;
const ICANON: u32 = 0o2;
const ECHO: u32 = 0o10;
const TCSANOW: i32 = 0;
const POLLIN: i16 = 1;
const SIGHUP: i32 = 1;
const SIGINT: i32 = 2;
const SIGTERM: i32 = 15;
const SIGWINCH: i32 = 28;

static STOP: AtomicBool = AtomicBool::new(false);
static RESIZED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_stop(_: i32) {
    STOP.store(true, Ordering::SeqCst);
}
extern "C" fn on_winch(_: i32) {
    RESIZED.store(true, Ordering::SeqCst);
}

fn term_size() -> (usize, usize) {
    let mut ws = Winsize { rows: 0, cols: 0, xpx: 0, ypx: 0 };
    let ok = unsafe { ioctl(1, TIOCGWINSZ, &mut ws as *mut Winsize) } == 0;
    if ok && ws.cols > 0 && ws.rows > 0 {
        (ws.cols as usize, ws.rows as usize)
    } else {
        let env = |k: &str, d: usize| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
        (env("COLUMNS", 80), env("LINES", 24))
    }
}

fn is_tty(fd: i32) -> bool {
    unsafe { isatty(fd) == 1 }
}

/// Puts stdin in no-echo, char-at-a-time mode; restores on drop.
/// TCSANOW, never TCSAFLUSH: keys typed during the animation stay queued for the shell.
struct RawGuard {
    old: Option<Termios>,
}

impl RawGuard {
    fn new() -> RawGuard {
        if !is_tty(0) {
            return RawGuard { old: None };
        }
        let mut t: Termios = unsafe { std::mem::zeroed() };
        if unsafe { tcgetattr(0, &mut t) } != 0 {
            return RawGuard { old: None };
        }
        let old = t;
        t.lflag &= !(ICANON | ECHO);
        unsafe { tcsetattr(0, TCSANOW, &t) };
        RawGuard { old: Some(old) }
    }
    fn key_waiting(&self) -> bool {
        if self.old.is_none() {
            return false;
        }
        let mut p = PollFd { fd: 0, events: POLLIN, revents: 0 };
        unsafe { poll(&mut p, 1, 0) > 0 && (p.revents & POLLIN) != 0 }
    }
    fn swallow_key(&self) {
        if self.old.is_some() {
            let mut buf = [0u8; 64];
            unsafe { read(0, buf.as_mut_ptr(), buf.len()) };
        }
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        if let Some(old) = self.old {
            unsafe { tcsetattr(0, TCSANOW, &old) };
        }
    }
}

fn truecolor() -> bool {
    let ct = std::env::var("COLORTERM").unwrap_or_default();
    let term = std::env::var("TERM").unwrap_or_default();
    ct == "truecolor" || ct == "24bit" || ["kitty", "alacritty", "wezterm", "foot", "ghostty"].iter().any(|t| term.contains(t))
}

fn fg_code(out: &mut String, c: Rgb, tc: bool) {
    use std::fmt::Write as _;
    if tc {
        let _ = write!(out, "\x1b[38;2;{};{};{}m", c.0, c.1, c.2);
    } else {
        let q = |v: u8| -> u8 { if v < 48 { 0 } else if v < 115 { 1 } else { (v - 35) / 40 } };
        let _ = write!(out, "\x1b[38;5;{}m", 16 + 36 * q(c.0) as u16 + 6 * q(c.1) as u16 + q(c.2) as u16);
    }
}

/// Emits only the cells that changed since the last frame.
struct Painter {
    prev: Option<Canvas>,
    tc: bool,
    absolute: bool, // full-screen (alt screen) vs. a block above the cursor
}

impl Painter {
    fn paint(&mut self, cv: &Canvas) -> String {
        use std::fmt::Write as _;
        let mut s = String::with_capacity(cv.w * cv.h * 4);
        s.push_str("\x1b[?2026h"); // synchronized update: no tearing
        let full = self.prev.as_ref().is_none_or(|p| p.w != cv.w || p.h != cv.h);
        if !self.absolute {
            let _ = write!(s, "\x1b[{}F", cv.h);
        }
        for y in 0..cv.h {
            let mut x = 0;
            while x < cv.w {
                let cell = cv.get(x, y);
                let same = !full && self.prev.as_ref().is_some_and(|p| p.get(x, y) == cell);
                if same {
                    x += 1;
                    continue;
                }
                // start of a changed run
                if self.absolute {
                    let _ = write!(s, "\x1b[{};{}H", y + 1, x + 1);
                } else {
                    let _ = write!(s, "\x1b[{}G", x + 1);
                }
                let mut last: Option<(Option<Rgb>, bool)> = None;
                while x < cv.w {
                    let cell = cv.get(x, y);
                    if !full && self.prev.as_ref().is_some_and(|p| p.get(x, y) == cell) {
                        break;
                    }
                    if last != Some((cell.fg, cell.bold)) {
                        s.push_str(if cell.bold { "\x1b[0;1m" } else { "\x1b[0m" });
                        if let Some(c) = cell.fg {
                            fg_code(&mut s, c, self.tc);
                        }
                        last = Some((cell.fg, cell.bold));
                    }
                    s.push(cell.ch);
                    x += 1;
                }
            }
            if !self.absolute {
                s.push_str("\x1b[0m\r\n");
            }
        }
        s.push_str("\x1b[0m\x1b[?2026l");
        self.prev = Some(Canvas { w: cv.w, h: cv.h, cells: cv.cells.clone(), solid: Vec::new() });
        s
    }
}

// ------------------------------------------------------------------ scene ---
const SPIN: f32 = 1.9; // intro: spin-in seconds
const TOTAL: f32 = 2.7; // intro: total seconds
const SPEED: f32 = 0.9; // banner/loop: rad/s, one slow turn every ~7 s

struct Scene {
    logo: Logo,
    panel: Vec<Line>,
    cols: usize,
    rows: usize,
    w: usize,
    h: usize,
    logo_x: usize,
    logo_y: usize,
    text_x: usize,
    text_y: usize,
    rng: Rng,
    embers: Embers,
    centered_text: bool,
}

fn seed() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(7)
}

fn panel_width(panel: &[Line]) -> usize {
    panel.iter().map(Line::width).max().unwrap_or(0)
}

impl Scene {
    /// Logo on the left, title and info on the right (terminal banner).
    fn side_by_side(logo: Logo, tw: usize, th: usize, name: &str, info: bool, size: usize) -> Option<Scene> {
        let gap = 4;
        let max_cols = if size > 0 { size } else { 64.min(((th.saturating_sub(3)) as f32 * 2.0 / logo.aspect) as usize) };
        let mut panel = Vec::new();
        let mut cols = 0;
        for big in [true, false] {
            panel = text_panel(name, info, big);
            let pw = panel_width(&panel) + 2;
            cols = max_cols.min(tw.saturating_sub(gap + pw + 2));
            if cols >= if big { 34 } else { 26 } {
                break;
            }
        }
        if cols < 26 {
            panel = Vec::new(); // no room for text: logo alone
            cols = max_cols.min(tw.saturating_sub(4));
        }
        if cols < 18 {
            return None;
        }
        cols -= cols % 2;
        let rows = ((cols as f32 * logo.aspect / 2.0).round() as usize).max(8);
        let h = rows.max(panel.len()) + 1;
        let text_y = rows.saturating_sub(panel.len()) / 2;
        let w = if panel.is_empty() { cols } else { cols + gap + panel_width(&panel) };
        let embers = Embers::new(0, 0, cols, rows, (cols / 3).max(10), seed());
        Some(Scene { logo, panel, cols, rows, w, h, logo_x: 0, logo_y: 0, text_x: cols + gap, text_y, rng: Rng::new(seed() ^ 0x9e37), embers, centered_text: false })
    }

    /// Whole screen: logo centred, big title under it (live wallpaper).
    fn fullscreen(logo: Logo, tw: usize, th: usize, name: &str) -> Scene {
        let mut panel = text_panel(name, false, true);
        let text_h = panel.len() + 2;
        let fit_rows = th.saturating_sub(text_h + 3).max(8);
        let mut cols = ((fit_rows as f32 * 2.0 / logo.aspect) as usize).min(tw.saturating_sub(4)).max(16);
        cols -= cols % 2;
        let rows = ((cols as f32 * logo.aspect / 2.0).round() as usize).max(8);
        if panel_width(&panel) + 4 > tw {
            panel = text_panel(name, false, false);
        }
        let block_h = rows + 2 + panel.len();
        let logo_y = th.saturating_sub(block_h) / 2;
        let logo_x = tw.saturating_sub(cols) / 2;
        let pw = panel_width(&panel);
        let embers = Embers::new(0, 0, tw, th, (tw * th / 90).max(20), seed());
        Scene {
            logo, cols, rows, w: tw, h: th, logo_x, logo_y,
            text_x: tw.saturating_sub(pw) / 2, text_y: logo_y + rows + 2,
            panel, rng: Rng::new(seed() ^ 0x51ed), embers, centered_text: true,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn frame(&mut self, angle: f32, look: &Look, t: f32, dt: f32, halo: f32, progress: f32, shimmer: Option<f32>, ember_dim: f32) -> Canvas {
        let mut cv = Canvas::new(self.w, self.h);
        let cells = render_logo(&self.logo, self.cols, self.rows, angle, look);
        blit_logo(&mut cv, &cells, self.logo_x, self.logo_y);
        add_halo(&mut cv, t, halo);
        if dt > 0.0 {
            self.embers.step(dt, t);
        }
        self.embers.draw(&mut cv, ember_dim);
        let total = self.panel.len();
        let pw = panel_width(&self.panel);
        for (i, line) in self.panel.iter().enumerate() {
            let x = if self.centered_text { self.text_x + (pw - line.width()) / 2 } else { self.text_x };
            // clear behind text so embers never cut through letters
            for cx in x..(x + line.width()).min(self.w) {
                if self.text_y + i < self.h {
                    cv.set(cx, self.text_y + i, BLANK);
                }
            }
            draw_line(&mut cv, line, i, total, x, self.text_y + i, progress, shimmer, &mut self.rng);
        }
        cv
    }

    fn intro(&mut self, t: f32, dt: f32) -> Canvas {
        let ease = 1.0 - (1.0 - (t / SPIN).min(1.0)).powi(3);
        let angle = (1.0 - ease) * 2.5 * PI;
        let shine = if t < SPIN { NO_SHINE } else { lerp(-0.4, 2.2, (t - SPIN) / (TOTAL - SPIN)) };
        let look = Look { shine, pulse: 0.0, fade: (0.25 + t / 0.6).min(1.0) };
        let shimmer = if t > 2.15 { Some(lerp(-0.2, 1.2, (t - 2.15) / 0.55)) } else { None };
        self.frame(angle, &look, t, dt, (t / 1.2).min(1.0), ((t - 1.0) / 1.2).max(0.0), shimmer, 1.0)
    }

    fn spinning(&mut self, t: f32, dt: f32, angle: f32, speed: f32) -> Canvas {
        let lap = (angle + PI).rem_euclid(2.0 * PI) - PI; // -pi..pi, 0 = facing you
        let shine_window = 0.9 * speed / SPEED;
        let shine = if lap > -0.2 && lap < 0.7 { lerp(-0.4, 2.2, (lap + 0.2) / shine_window) } else { NO_SHINE };
        let look = Look { shine, pulse: 0.5 + 0.5 * (t * 2.2).sin(), fade: 1.0 };
        let sweep = (t % 4.0) / 1.2; // title shimmer every 4 s
        let shimmer = if sweep <= 1.0 { Some(lerp(-0.2, 1.2, sweep)) } else { None };
        self.frame(angle, &look, t, dt, 1.0, (t / 1.3).min(1.0), shimmer, 1.0)
    }

    fn final_frame(&mut self) -> Canvas {
        let look = Look { shine: NO_SHINE, pulse: 0.0, fade: 1.0 };
        self.frame(0.0, &look, 0.0, 0.0, 0.7, 1.0, None, 0.6)
    }
}

// ------------------------------------------------------------------- main ---
#[derive(PartialEq, Clone, Copy)]
enum Mode {
    Intro,
    Banner,
    Loop,
    Static,
    Wallpaper,
    Export,
}

struct Opts {
    mode: Mode,
    mask: Option<String>,
    name: String,
    info: bool,
    size: usize,
    fps: f32,
    timeout: f32,
}

fn parse_args() -> Opts {
    let mut o = Opts { mode: Mode::Intro, mask: None, name: "Exarch".into(), info: true, size: 0, fps: 0.0, timeout: 0.0 };
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--banner" => o.mode = Mode::Banner,
            "--loop" => o.mode = Mode::Loop,
            "--static" => o.mode = Mode::Static,
            "--wallpaper" => o.mode = Mode::Wallpaper,
            "--export-fastfetch" => o.mode = Mode::Export,
            "--no-info" => o.info = false,
            "--mask" => o.mask = args.next(),
            "--name" => o.name = args.next().unwrap_or(o.name),
            "--size" => o.size = args.next().and_then(|v| v.parse().ok()).unwrap_or(0),
            "--fps" => o.fps = args.next().and_then(|v| v.parse().ok()).unwrap_or(0.0),
            "--timeout" => o.timeout = args.next().and_then(|v| v.parse().ok()).unwrap_or(0.0),
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            other => {
                eprintln!("exarch-splash: unknown option {other}\n\n{USAGE}");
                std::process::exit(2);
            }
        }
    }
    o
}

fn load_logo(mask: &Option<String>) -> Logo {
    let candidates = [
        mask.clone(),
        std::env::var("EXARCH_DATA").ok().map(|d| format!("{d}/branding/logo-mask.txt")),
        Some("/usr/share/exarch/branding/logo-mask.txt".into()),
    ];
    for p in candidates.into_iter().flatten() {
        if let Some(l) = std::fs::read_to_string(&p).ok().and_then(|t| Logo::parse(&t)) {
            return l;
        }
    }
    Logo::parse(DEFAULT_MASK).expect("built-in mask")
}

fn export_fastfetch(logo: &Logo, cols: usize) -> String {
    let rows = ((cols as f32 * logo.aspect / 2.0).round() as usize).max(8);
    let look = Look { shine: NO_SHINE, pulse: 0.0, fade: 1.0 };
    let mut out: Vec<String> = Vec::new();
    for row in render_logo(logo, cols, rows, 0.0, &look) {
        let mut line = String::new();
        let mut cur = ' ';
        for cell in row {
            let Some(Rgb(r, g, _)) = cell.fg else {
                line.push(' ');
                continue;
            };
            let key = if r > 225 && g > 130 { '4' } else if g > 120 { '3' } else if g > 70 { '2' } else { '1' };
            if key != cur {
                line.push('$');
                line.push(key);
                cur = key;
            }
            line.push(cell.ch);
        }
        out.push(line.trim_end().to_string());
    }
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }
    out.join("\n") + "\n"
}

fn sleep_until(next: Instant) {
    let now = Instant::now();
    if next > now {
        std::thread::sleep(next - now);
    }
}

fn run_wallpaper(o: &Opts) {
    let fps = if o.fps > 0.0 { o.fps } else { 20.0 };
    let dt = 1.0 / fps;
    let speed = 0.5; // slower than the banner: it's a backdrop
    let mut out = io::stdout().lock();
    let _ = out.write_all(b"\x1b[?1049h\x1b[?25l\x1b[2J");
    loop {
        let (tw, th) = term_size();
        let mut scene = Scene::fullscreen(load_logo(&o.mask), tw, th, &o.name);
        let mut painter = Painter { prev: None, tc: true, absolute: true };
        let _ = out.write_all(b"\x1b[0m\x1b[2J");
        let t0 = Instant::now();
        let mut next = t0;
        loop {
            if STOP.load(Ordering::SeqCst) {
                let _ = out.write_all(b"\x1b[0m\x1b[?25h\x1b[?1049l");
                let _ = out.flush();
                return;
            }
            if RESIZED.swap(false, Ordering::SeqCst) {
                break; // rebuild the layout for the new size
            }
            let t = t0.elapsed().as_secs_f32();
            let cv = scene.spinning(t, dt, t * speed, speed);
            if out.write_all(painter.paint(&cv).as_bytes()).is_err() || out.flush().is_err() {
                return; // the panel went away
            }
            next += Duration::from_secs_f32(dt);
            sleep_until(next);
        }
    }
}

fn run_terminal(o: &Opts) {
    let (tw, th) = term_size();
    let Some(mut scene) = Scene::side_by_side(load_logo(&o.mask), tw, th, &o.name, o.info, o.size) else {
        return; // terminal too small: stay quiet
    };
    let guard = RawGuard::new();
    let mut painter = Painter { prev: None, tc: truecolor(), absolute: false };
    let mut out = io::stdout().lock();
    let mut show = |cv: &Canvas| {
        let _ = out.write_all(painter.paint(cv).as_bytes());
        let _ = out.flush();
    };
    {
        let mut o2 = io::stdout().lock();
        let _ = o2.write_all(b"\x1b[?25l");
        let _ = o2.write_all("\n".repeat(scene.h).as_bytes());
    }
    let stopped = || STOP.load(Ordering::SeqCst);
    match o.mode {
        Mode::Intro => {
            let dt = 1.0 / if o.fps > 0.0 { o.fps } else { 40.0 };
            let t0 = Instant::now();
            let mut next = t0;
            loop {
                let t = t0.elapsed().as_secs_f32();
                if t >= TOTAL || guard.key_waiting() || stopped() {
                    break;
                }
                show(&scene.intro(t, dt));
                next += Duration::from_secs_f32(dt);
                sleep_until(next);
            }
        }
        Mode::Banner | Mode::Loop => {
            let dt = 1.0 / if o.fps > 0.0 { o.fps } else { 30.0 };
            let t0 = Instant::now();
            let mut next = t0;
            let mut t = 0.0;
            while !guard.key_waiting() && !stopped() {
                t = t0.elapsed().as_secs_f32();
                if o.mode == Mode::Banner && o.timeout > 0.0 && t > o.timeout {
                    break;
                }
                show(&scene.spinning(t, dt, t * SPEED, SPEED));
                next += Duration::from_secs_f32(dt);
                sleep_until(next);
            }
            if o.mode == Mode::Loop && !stopped() {
                guard.swallow_key(); // the key ends the screensaver
            }
            // glide round to face the front instead of snapping there
            let a0 = t * SPEED;
            let mut a1 = (a0 / (2.0 * PI)).ceil() * 2.0 * PI;
            if a1 - a0 > PI {
                a1 -= 2.0 * PI;
            }
            let s0 = Instant::now();
            while !stopped() {
                let k = s0.elapsed().as_secs_f32() / 0.45;
                if k >= 1.0 {
                    break;
                }
                let ease = 1.0 - (1.0 - k).powi(3);
                show(&scene.spinning(t + k * 0.45, dt, lerp(a0, a1, ease), SPEED));
                std::thread::sleep(Duration::from_secs_f32(dt));
            }
        }
        _ => {}
    }
    show(&scene.final_frame());
    let mut o2 = io::stdout().lock();
    let _ = o2.write_all(b"\x1b[0m\x1b[?25h");
    let _ = o2.flush();
    drop(guard);
}

fn main() {
    let o = parse_args();
    unsafe {
        signal(SIGINT, on_stop);
        signal(SIGTERM, on_stop);
        signal(SIGHUP, on_stop);
        signal(SIGWINCH, on_winch);
    }
    match o.mode {
        Mode::Export => {
            let cols = if o.size > 0 { o.size } else { 44 };
            print!("{}", export_fastfetch(&load_logo(&o.mask), cols));
        }
        Mode::Wallpaper => {
            if is_tty(1) {
                run_wallpaper(&o);
            }
        }
        _ => {
            if is_tty(1) {
                run_terminal(&o);
            }
        }
    }
}
