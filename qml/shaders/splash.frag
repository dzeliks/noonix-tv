#version 440
// the launch splash background, as the overlay's launch card draws it (its brand.frag) so the
// handover is invisible: part 0 = brand gradient + dither, part 1 = the top-left light alone,
// alpha-blended over everything (the card lights its art too)
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 c1;
    vec4 c2;
    vec4 glow;          // rgb, a = strength
    float part;
};

float hash(vec2 p)
{
    p = fract(p * vec2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

void main()
{
    vec2 uv = qt_TexCoord0;
    float g = 1.0 - clamp(length((uv - vec2(0.22, 0.0)) / 0.95), 0.0, 1.0);
    float a = glow.a * g * g * (3.0 - 2.0 * g);
    if (part > 0.5) {
        fragColor = vec4(glow.rgb * a, a) * qt_Opacity;
        return;
    }
    vec3 c = mix(c1.rgb, c2.rgb, clamp((uv.x + uv.y) * 0.5, 0.0, 1.0));
    vec2 fc = gl_FragCoord.xy;
    c += (hash(fc) + hash(fc + 37.7) - 1.0) / 255.0;
    fragColor = vec4(c, 1.0) * qt_Opacity;
}
