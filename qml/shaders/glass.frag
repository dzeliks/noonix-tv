#version 440
// liquid glass for panels, buttons and pills (from the tv clock's glass), a rounded rect:
//   lens  - rounded edges bend the scene outwards, flat in the middle
//   body  - frosted, colour kept and a little saturated, `tint` lifts, `dim`/`adapt` darken
//   light - a rim lit from the top left, a weaker reflection opposite
//   wash  - optional colour through the glass
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec2 screenUv;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float w;            // item size, px (floats: no js vector per change)
    float h;
    float radius;       // corner radius, px
    float bevel;        // width of the curved edge, px
    float refraction;   // how far the edge bends the scene, px
    float frost;        // backdrop mip level
    float frostRadius;  // px
    float tint;         // lift towards white (clock: 0.40)
    float dim;          // darkening of the body (0 = clock glass)
    float adapt;        // extra darkening over bright scenes
    float rim;          // rim brightness (clock: 0.14)
    float rimWidth;     // px
    float sat;          // saturation of what shows through (clock: 1.45)
    vec4 wash;          // rgb + amount
    float texelX;       // 1 / overlay size
    float texelY;
    float backdropOn;   // 0: no stream yet -> plain dark glass
    float soft;         // 0..1: frost from the Gaussian-blurred copy instead of the mip taps
};
#define size vec2(w, h)
#define screenTexel vec2(texelX, texelY)
layout(binding = 1) uniform sampler2D backdrop;
layout(binding = 2) uniform sampler2D frostTex;   // the backdrop at 1/16 size, Gaussian-blurred

const float CHROMA_KEEP = 0.5;

vec3 scene(vec2 uv, float lod) { return textureLod(backdrop, clamp(uv, vec2(0.0), vec2(1.0)), lod).rgb; }

vec3 frosted(vec2 uv, float lod, float r)
{
    vec3 acc = scene(uv, lod) * 2.0;
    for (int i = 0; i < 12; ++i) {
        float a = float(i) * 0.5235988 + (i >= 6 ? 0.2617994 : 0.0);
        float k = i >= 6 ? 1.0 : 0.5;
        acc += scene(uv + vec2(cos(a), sin(a)) * k * r * screenTexel, lod);
    }
    return acc / 14.0;
}

// the Gaussian frost, magnified 16x: cubic B-spline (4 bilinear taps). Plain
// bilinear leaves a faint 16 px lattice that crawls when the scene moves.
const vec2 FROST_SIZE = vec2(240.0, 135.0);
vec3 frostAt(vec2 uv)
{
    vec2 st = uv * FROST_SIZE - 0.5;
    vec2 i = floor(st);
    vec2 f = st - i;
    vec2 f2 = f * f, f3 = f2 * f;
    vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 s0 = w0 + w1, s1 = w2 + w3;
    vec2 h0 = (i - 0.5 + w1 / s0) / FROST_SIZE;
    vec2 h1 = (i + 1.5 + w3 / s1) / FROST_SIZE;
    return s0.y * (s0.x * texture(frostTex, vec2(h0.x, h0.y)).rgb + s1.x * texture(frostTex, vec2(h1.x, h0.y)).rgb)
         + s1.y * (s0.x * texture(frostTex, vec2(h0.x, h1.y)).rgb + s1.x * texture(frostTex, vec2(h1.x, h1.y)).rgb);
}

// signed distance to a rounded box (negative inside), and its outward normal
float sdBox(vec2 p, vec2 b, float r)
{
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main()
{
    vec2 p = qt_TexCoord0 * size - size * 0.5;
    float r = min(radius, min(size.x, size.y) * 0.5);
    float d = sdBox(p, size * 0.5, r);
    float cov = clamp(0.5 - d, 0.0, 1.0);
    if (cov <= 0.0) { fragColor = vec4(0.0); return; }
    float e = 0.75;
    vec2 n = vec2(sdBox(p + vec2(e, 0.0), size * 0.5, r) - sdBox(p - vec2(e, 0.0), size * 0.5, r),
                  sdBox(p + vec2(0.0, e), size * 0.5, r) - sdBox(p - vec2(0.0, e), size * 0.5, r));
    n = length(n) > 1e-5 ? normalize(n) : vec2(0.0);

    // lens: circular profile across the bevel; flat (no bend) beyond it
    float t = clamp(-d / max(bevel, 1.0), 0.0, 1.0);
    float edge = (1.0 - t) * (1.0 - t);                     // 1 at the rim .. 0 inside: the slab's rounded shoulder
    // the scene outside is pulled in over the rounded shoulder (same frost: the
    // shapes bend, nothing gets clearer)
    vec2 bend = n * refraction * pow(edge, 1.3) * screenTexel;

    vec3 col;
    if (backdropOn > 0.5) {
        vec3 soft3 = frostAt(screenUv + bend);
        vec3 refr = soft > 0.999 ? soft3 : mix(frosted(screenUv + bend, frost, frostRadius), soft3, soft);
        // dispersion where the bend is strongest (from the smooth frost: mip
        // taps here popped as things moved behind the edge)
        float disp = 0.35 * edge * edge;
        if (disp > 0.002) {
            refr.r = mix(refr.r, frostAt(screenUv + bend * 1.10).r, disp);
            refr.b = mix(refr.b, frostAt(screenUv + bend * 0.90).b, disp);
        }
        float lum = dot(refr, vec3(0.2126, 0.7152, 0.0722));
        vec3 body = mix(vec3(lum), refr, sat);
        // the clock's lift: part of the way to hue-preserving, more over dark scenes
        float lift = clamp(tint * (1.0 + 0.75 * (1.0 - lum)) + 0.04 * edge, 0.0, 1.0);
        float target = max(lum, mix(lum, 1.0, lift));
        float gain = min(mix(1.0 - lift, target / max(lum, 1e-3), CHROMA_KEEP), 1.6);
        vec3 c = vec3(target) + (body - vec3(lum)) * gain;
        float peak = max(max(c.r, c.g), c.b);
        if (peak > 1.0)
            c = mix(c, vec3(target), (peak - 1.0) / max(peak - target, 1e-3));
        // legibility: the panel darkens, more where the scene behind is bright
        float area = dot(scene(screenUv, 7.5), vec3(0.2126, 0.7152, 0.0722));
        c *= (1.0 - dim) * (1.0 - adapt * smoothstep(0.35, 0.85, area));
        col = max(c, 0.0);
    } else {
        col = mix(vec3(0.075, 0.075, 0.09), vec3(1.0), tint * 0.85) * (1.0 - dim * 0.4);
    }
    col = mix(col, wash.rgb, wash.a);

    // light: glint on the curve facing the light, crisp rim, internal reflection
    vec2 L = normalize(vec2(-0.55, -0.83));
    float facing = dot(n, L);
    float spec = pow(max(facing, 0.0), 2.0) * edge * 0.10;
    float inner = smoothstep(rimWidth + 0.75, rimWidth - 0.75, -d);
    float rimLight = clamp(inner * rim * (0.55 + 0.45 * max(facing, 0.0) + 0.25 * max(-facing, 0.0)), 0.0, 1.0);
    col = col + vec3(spec * (0.4 + rim));
    col = mix(col, vec3(1.0), rimLight);
    float a = backdropOn > 0.5 ? 1.0 : 0.94;
    fragColor = vec4(clamp(col, 0.0, 1.0) * cov * a, cov * a) * qt_Opacity;
}
