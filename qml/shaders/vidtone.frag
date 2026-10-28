#version 440
// the video copy as sdr for the glass: pq / hlg bt.2020 -> bt.709 gamma 2.2, highlights
// rolled off, sdr video passes through
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float mode;      // 0 sdr, 1 pq, 2 hlg
};
layout(binding = 1) uniform sampler2D source;

vec3 pqNits(vec3 e)
{
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    vec3 p = pow(clamp(e, 0.0, 1.0), vec3(1.0 / m2));
    return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), vec3(1.0 / m1));
}

vec3 hlgScene(vec3 e)
{
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    vec3 lo = e * e / 3.0;
    vec3 hi = (exp((e - c) / a) + b) / 12.0;
    return mix(lo, hi, step(vec3(0.5), e));
}

void main()
{
    vec3 c = texture(source, qt_TexCoord0).rgb;
    if (mode > 0.5) {
        // 1.0 = sdr reference white (203 nits / hlg 75%)
        vec3 lin = mode < 1.5 ? pqNits(c) / 203.0 : hlgScene(c) / 0.2647;
        lin = vec3(dot(lin, vec3(1.6605, -0.5876, -0.0728)),
                   dot(lin, vec3(-0.1246, 1.1329, -0.0083)),
                   dot(lin, vec3(-0.0182, -0.1006, 1.1187)));
        lin = max(lin, 0.0);
        float m = max(max(lin.r, lin.g), lin.b);
        // linear up to 0.6, then an exponential shoulder towards 1
        float t = m <= 0.6 ? m : 0.6 + 0.4 * (1.0 - exp(-(m - 0.6) / 0.4));
        lin *= m > 0.0 ? t / m : 0.0;
        c = pow(clamp(lin, 0.0, 1.0), vec3(1.0 / 2.2));
    }
    fragColor = vec4(c, 1.0) * qt_Opacity;
}
