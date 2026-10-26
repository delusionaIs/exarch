//!HOOK OUTPUT
//!BIND HOOKED
//!DESC Exarch wallpaper: synthwave grid

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
// Neon grid racing to a striped violet sun, mountains, stars.
vec3 scene(vec2 fc, vec2 res, float t) {
    vec2 uv = (fc - 0.5 * res) / res.y;
    float horizon = -0.08;
    vec3 col;
    if (uv.y > horizon) {
        float h = uv.y - horizon;
        col = mix(vec3(0.42, 0.06, 0.42), vec3(0.03, 0.01, 0.08), smoothstep(0.0, 0.45, h));
        col += stars(fc, t, 0.05) * smoothstep(0.12, 0.35, h);

        // the sun, with the classic widening gaps towards the bottom
        vec2 sc = uv - vec2(0.0, horizon + 0.19);
        float sd = length(sc);
        vec3 sun = mix(vec3(1.0, 0.25, 0.65), vec3(1.0, 0.80, 0.35), smoothstep(-0.2, 0.2, sc.y));
        float cut = 1.0;
        if (sc.y < 0.04) {
            float k = (0.04 - sc.y) / 0.24;                   // 0 at the top of the cuts, 1 at the bottom
            cut = step(k * 0.75, fract(sc.y * 22.0 + t * 0.35));
        }
        col = mix(col, sun, smoothstep(0.205, 0.198, sd) * cut);
        col += vec3(1.0, 0.25, 0.6) * 0.30 * exp(-max(sd - 0.2, 0.0) * 7.0);

        // mountains on both sides
        float mx = abs(uv.x);
        float m = horizon + (0.05 + 0.20 * fbm(vec2(uv.x * 2.4, 3.0))) * smoothstep(0.18, 0.75, mx);
        if (uv.y < m) {
            col = vec3(0.04, 0.01, 0.09) + vec3(0.6, 0.2, 0.9) * 0.6 * smoothstep(0.012, 0.0, m - uv.y);
        }
    } else {
        float d = horizon - uv.y;
        float z = 0.30 / d;                                   // depth
        vec2 g = vec2(uv.x * z * 2.2, z + t * 1.4);
        vec2 w = fwidth(g);
        vec2 gl = abs(fract(g) - 0.5) / w;
        float line = 1.0 - min(min(gl.x, gl.y), 1.0);
        float fade = exp(-z * 0.18);
        col = vec3(0.03, 0.0, 0.06) + vec3(0.25, 0.02, 0.35) * smoothstep(0.25, 0.0, d);
        col += vec3(1.0, 0.25, 0.85) * line * (0.35 + 0.9 * fade);
    }
    col += vec3(1.0, 0.3, 0.8) * 0.35 * exp(-abs(uv.y - horizon) * 40.0);   // horizon glow
    col *= 0.94 + 0.06 * sin(fc.y * 3.14159);                                 // scanlines
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
