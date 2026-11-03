#version 440
// artwork with rounded corners, cropped to fill (no layer, samples the image directly)
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // plain floats: a vec2 property costs a js value type per card on the qml side
    float w;
    float h;
    float radius;
    float sx;       // crop scale; the crop stays centred
    float sy;
    float shade;
    float inset;    // drawn this far inside its box, same corners (the undo tile pulls the cover in)
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec2 box = vec2(w, h);
    vec2 size = box - 2.0 * inset;
    vec2 uvScale = vec2(sx, sy);
    vec2 p = qt_TexCoord0 * box - box * 0.5;
    float r = min(radius, min(size.x, size.y) * 0.5);
    vec2 q = abs(p) - size * 0.5 + r;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float cov = clamp(0.5 - d, 0.0, 1.0);
    vec2 t = (qt_TexCoord0 * box - inset) / size;
    vec4 c = texture(source, (1.0 - uvScale) * 0.5 + t * uvScale);
    vec3 col = c.rgb * (1.0 - shade);
    fragColor = vec4(col, c.a) * cov * qt_Opacity;
}
