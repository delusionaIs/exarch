//!HOOK OUTPUT
//!BIND HOOKED
//!DESC Exarch wallpaper: neon Exarch logo

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i), b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 5; i++) { v += a * noise(p); p = m * p; a *= 0.5; }
    return v;
}

// twinkling star field, one star per lucky 38px cell
vec3 stars(vec2 fc, float t, float density) {
    vec2 sp = fc / 38.0;
    vec2 id = floor(sp);
    vec2 f = fract(sp) - 0.5;
    float h = hash(id);
    vec2 off = vec2(hash(id + 3.1), hash(id + 7.7)) - 0.5;
    float d = length(f - off * 0.7);
    float tw = 0.55 + 0.45 * sin(t * (1.0 + 2.0 * h) + h * 60.0);
    float s = step(1.0 - density, h) * (0.0016 / (d * d + 0.0016)) * tw;
    return vec3(0.85, 0.8, 1.0) * s;
}

// --- scene ---
// The Exarch "A" as a flickering neon sign, embers rising, faint hex grid.
float seg(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

// the logo outline from branding/logo.svg (512 box, y down) -> centred units
vec2 L(float x, float y) { return vec2(x - 256.0, 253.0 - y) / 446.0; }

float outline(vec2 p) {
    float d = seg(p, L(256.0, 30.0), L(452.0, 476.0));
    d = min(d, seg(p, L(452.0, 476.0), L(346.0, 476.0)));
    d = min(d, seg(p, L(346.0, 476.0), L(256.0, 108.0)));
    d = min(d, seg(p, L(256.0, 108.0), L(166.0, 476.0)));
    d = min(d, seg(p, L(166.0, 476.0), L(60.0, 476.0)));
    d = min(d, seg(p, L(60.0, 476.0), L(256.0, 30.0)));
    d = min(d, seg(p, L(172.0, 183.0), L(340.0, 183.0)));          // crossbar
    return d;
}

float injector(vec2 p) {
    float d = seg(p, L(256.0, 100.0), L(256.0, 178.0));              // plunger
    d = min(d, seg(p, L(230.0, 196.0), L(282.0, 196.0)));             // barrel
    d = min(d, seg(p, L(282.0, 196.0), L(282.0, 352.0)));
    d = min(d, seg(p, L(282.0, 352.0), L(230.0, 352.0)));
    d = min(d, seg(p, L(230.0, 352.0), L(230.0, 196.0)));
    d = min(d, seg(p, L(256.0, 352.0), L(256.0, 476.0)));             // needle
    return d;
}

vec3 neon(float d, vec3 tint, float power) {
    return tint * (smoothstep(0.004, 0.0, d) * 1.4 + power * 0.006 / (d + 0.005));
}

vec3 scene(vec2 fc, vec2 res, float t) {
    vec2 uv = (fc - 0.5 * res) / res.y;
    vec3 col = mix(vec3(0.03, 0.01, 0.07), vec3(0.008, 0.005, 0.02), length(uv));

    // faint hex grid drifting upward
    vec2 hp = uv * 18.0 + vec2(0.0, t * 0.15);
    vec2 a = mod(hp, vec2(1.732, 3.0)) - vec2(0.866, 1.5);
    vec2 b = mod(hp + vec2(0.866, 1.5), vec2(1.732, 3.0)) - vec2(0.866, 1.5);
    vec2 h = dot(a, a) < dot(b, b) ? a : b;
    float hex = max(abs(h.x) * 0.866 + abs(h.y) * 0.5, abs(h.y));
    col += vec3(0.35, 0.15, 0.7) * 0.10 * smoothstep(0.9, 1.0, hex) * smoothstep(0.9, 0.1, length(uv));

    // neon tube flicker: mostly steady, the odd stutter
    float flick = 0.9 + 0.1 * sin(t * 3.0);
    float stutter = step(0.985, hash(vec2(floor(t * 12.0), 3.0)));
    flick *= 1.0 - 0.5 * stutter;
    float breathe = 0.85 + 0.15 * sin(t * 1.1);

    vec2 p = uv / 0.82;
    col += neon(outline(p), vec3(0.62, 0.30, 1.00), 1.0 * breathe) * flick;
    col += neon(injector(p), vec3(1.00, 0.40, 0.75), 0.8 + 0.4 * sin(t * 2.2));

    // embers rising
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        vec2 ep = uv * (6.0 + fi * 3.0) + vec2(fi * 7.3, -t * (0.25 + fi * 0.12));
        vec2 id = floor(ep);
        vec2 f = fract(ep) - 0.5;
        float hh = hash(id + fi * 13.0);
        vec2 off = vec2(hash(id + 1.7), hash(id + 9.1)) - 0.5;
        float d = length(f - off * 0.8);
        float e = step(0.82, hh) * 0.0009 / (d * d + 0.0009);
        col += mix(vec3(0.6, 0.3, 1.0), vec3(1.0, 0.4, 0.7), hh) * e * (0.25 - fi * 0.06);
    }
    col *= 1.0 - 0.4 * dot(uv, uv);
    return col;
}

// --- end scene ---

// Frames per second of the (blank) source video: `exarch wallpaper` rewrites
// this when you change EXARCH_WALLPAPER_FPS.
#define FPS 30.0

vec4 hook() {
    vec2 res = HOOKED_size;
    vec2 fc = vec2(HOOKED_pos.x, 1.0 - HOOKED_pos.y) * res;   // pixels, y up
    float t = float(frame % 216000) / FPS;                      // wraps every 2 h at 30 fps
    return vec4(clamp(scene(fc, res, t), 0.0, 1.0), 1.0);
}
