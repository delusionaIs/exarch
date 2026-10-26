//!HOOK OUTPUT
//!BIND HOOKED
//!DESC Exarch wallpaper: violet nebula

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
// Slowly churning violet/pink nebula over a star field (domain-warped fbm).
vec3 scene(vec2 fc, vec2 res, float t) {
    vec2 uv = (fc - 0.5 * res) / res.y;
    vec2 p = uv * 1.7 + vec2(t * 0.006, 0.0);
    vec2 q = vec2(fbm(p + t * 0.020), fbm(p + vec2(5.2, 1.3) - t * 0.016));
    vec2 r = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2) + t * 0.030),
                  fbm(p + 3.0 * q + vec2(8.3, 2.8) - t * 0.024));
    float f = fbm(p + 2.6 * r);

    vec3 col = vec3(0.015, 0.008, 0.045);
    col = mix(col, vec3(0.40, 0.14, 0.85), smoothstep(0.15, 0.75, f));
    col = mix(col, vec3(1.00, 0.36, 0.72), smoothstep(0.40, 0.95, length(q) * f * 1.3));
    col = mix(col, vec3(0.40, 0.80, 1.00), 0.35 * smoothstep(0.50, 0.95, r.y * f * 1.5));
    col *= 0.55 + 2.2 * f * f;

    col += stars(fc, t, 0.06) * (1.0 - smoothstep(0.35, 0.8, f));
    col *= 1.0 - 0.55 * dot(uv, uv);                       // vignette
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
