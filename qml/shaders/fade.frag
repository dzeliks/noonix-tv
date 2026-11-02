#version 440
// soft top and bottom edges for text that scrolls inside a box
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float edge;        // the fade's share of the height
};
layout(binding = 1) uniform sampler2D source;

void main() {
    float y = qt_TexCoord0.y;
    float k = smoothstep(0.0, edge, y) * smoothstep(0.0, edge, 1.0 - y);
    fragColor = texture(source, qt_TexCoord0) * k * qt_Opacity;
}
