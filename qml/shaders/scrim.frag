#version 440
// a soft dark ellipse filling the item: darkest in the middle, gone at the edges
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float strength;
};

void main()
{
    float d = length(qt_TexCoord0 * 2.0 - 1.0);
    float a = strength * (1.0 - smoothstep(0.0, 1.0, d));
    fragColor = vec4(0.0, 0.0, 0.0, a * a / max(strength, 0.001)) * qt_Opacity;
}
