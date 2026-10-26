//!HOOK OUTPUT
//!BIND HOOKED
//!DESC Exarch wallpaper: violet aurora

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
// Curtains of violet, teal and pink light over a dark ridge.
vec3 curtain(vec2 uv, float t, float seed, vec3 tint) {
    float base = -0.02 + 0.12 * sin(uv.x * 1.3 + t * 0.07 + seed)
               + 0.08 * fbm(vec2(uv.x * 1.5 + seed, t * 0.05));
    float above = uv.y - base;
    float body = smoothstep(-0.015, 0.015, above) * exp(-max(above, 0.0) * 2.6);
    float rays = 0.45 + 0.55 * fbm(vec2(uv.x * 28.0 + seed * 9.0, t * 0.35 + uv.x * 2.0));
    float shimmer = 0.75 + 0.25 * sin(uv.x * 6.0 - t * 0.9 + seed * 3.0);
    return tint * body * rays * shimmer;
}

vec3 scene(vec2 fc, vec2 res, float t) {
    vec2 uv = (fc - 0.5 * res) / res.y;
    vec3 col = mix(vec3(0.05, 0.02, 0.10), vec3(0.005, 0.004, 0.02), smoothstep(-0.4, 0.5, uv.y));
    col += stars(fc, t, 0.07) * 0.9;
    col += curtain(uv, t, 0.0, vec3(0.55, 0.25, 1.00)) * 0.9;
    col += curtain(uv + vec2(0.3, 0.06), t * 1.2, 2.1, vec3(0.20, 0.95, 0.75)) * 0.55;
    col += curtain(uv - vec2(0.5, -0.02), t * 0.8, 4.7, vec3(1.00, 0.35, 0.70)) * 0.45;

    float ridge = -0.36 + 0.07 * fbm(vec2(uv.x * 3.0, 1.0)) + 0.03 * sin(uv.x * 2.0);
    if (uv.y < ridge) {
        col = vec3(0.01, 0.005, 0.02) + vec3(0.25, 0.10, 0.45) * 0.4 * smoothstep(0.01, 0.0, ridge - uv.y);
    }
    col *= 1.0 - 0.35 * dot(uv, uv);
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
