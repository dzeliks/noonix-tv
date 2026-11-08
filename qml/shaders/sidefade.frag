#version 440
// a row of cards that runs on past its end: the last stretch fades out
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float edge;        // the fade's share of the width
    float amount;      // 0 = no fade (the row's end is in view)
};
layout(binding = 1) uniform sampler2D source;

void main() {
    float k = mix(1.0, smoothstep(0.0, edge, 1.0 - qt_TexCoord0.x), amount);
    fragColor = texture(source, qt_TexCoord0) * k * qt_Opacity;
}
