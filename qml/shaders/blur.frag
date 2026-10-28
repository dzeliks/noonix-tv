#version 440
// one direction of a gaussian blur (across, then down) over a tiny backdrop copy,
// 25 taps, sigma in texels
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 dir;        // one texel along the blur direction
    float sigma;
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int i = -12; i <= 12; ++i) {
        float w = exp(-0.5 * float(i * i) / (sigma * sigma));
        acc += texture(source, qt_TexCoord0 + dir * float(i)).rgb * w;
        wsum += w;
    }
    fragColor = vec4(acc / wsum, 1.0) * qt_Opacity;
}
