#version 440
// the item's uv plus its screen position, so the glass samples the backdrop
// right under it through any move or scale
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(location = 1) out vec2 screenUv;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float w;            // item size, px (floats: no js vector per change)
    float h;
    float radius;
    float bevel;
    float refraction;
    float frost;
    float frostRadius;
    float tint;
    float dim;
    float adapt;
    float rim;
    float rimWidth;
    float sat;
    vec4 wash;
    float texelX;       // 1 / overlay size
    float texelY;
    float backdropOn;
    float soft;
};
#define size vec2(w, h)
#define screenTexel vec2(texelX, texelY)
out gl_PerVertex { vec4 gl_Position; };

void main()
{
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
    // the backdrop's v runs down the screen. ndc is y-up on screen but comes flipped when this
    // glass is drawn into a layer (the backdrop copy itself): the item's own top tells which
    float top = (qt_Matrix * vec4(0.0, 0.0, 0.0, 1.0)).y;
    float bottom = (qt_Matrix * vec4(0.0, size.y, 0.0, 1.0)).y;
    screenUv = vec2(gl_Position.x * 0.5 + 0.5, 0.5 + gl_Position.y * (top > bottom ? -0.5 : 0.5));
}
