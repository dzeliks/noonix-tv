#version 440
// a line round the inside of a rounded rect: `drain` of it left, clockwise from the top centre,
// so its end backs off counter-clockwise
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    float radius;
    float inset;
    float stroke;
    float drain;
};

void main() {
    vec2 p = qt_TexCoord0 * size - size / 2.0;
    vec2 h = size / 2.0 - inset;
    vec2 q = abs(p) - h + radius;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float line = clamp(stroke / 2.0 + 0.5 - abs(d), 0.0, 1.0);
    // how far along a quarter of the outline, from the top centre to the side's middle
    float w = h.x - radius, t = h.y - radius, arc = 1.5707963 * radius;
    float quarter = w + arc + t;
    vec2 a = abs(p);
    float s = a.x <= w ? a.x
            : a.y <= t ? w + arc + t - a.y
            : w + atan(a.x - w, a.y - t) * radius;
    float along = p.y < 0.0 ? (p.x >= 0.0 ? s : 4.0 * quarter - s)
                            : (p.x >= 0.0 ? 2.0 * quarter - s : 2.0 * quarter + s);
    float left = clamp(drain * 4.0 * quarter - along + 0.5, 0.0, 1.0);
    fragColor = vec4(1.0) * line * left * qt_Opacity;
}
