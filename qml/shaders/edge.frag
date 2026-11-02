#version 440
// the top of a scrolled page: towards the screen's edge the page blurs and sinks into black, the very
// first pixel row is black
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float band;        // the band's share of the page's height
    float amount;      // 0 at the top of the page, 1 scrolled
};
layout(binding = 1) uniform sampler2D tex;
layout(binding = 2) uniform sampler2D frost;

void main() {
    float y = qt_TexCoord0.y;
    vec2 at = vec2(qt_TexCoord0.x, y * band);
    float k = 1.0 - y;
    // how much of the blurred page shows, softest towards the band's end
    float soft = smoothstep(0.0, 0.85, k);
    vec3 c = mix(texture(tex, at).rgb, texture(frost, at).rgb, smoothstep(0.25, 1.0, k) * 0.8);
    // darkness keeps easing all the way to the edge, nothing flat
    float dark = pow(k, 1.7);
    float a = soft * amount;
    float black = dark * min(1.0, amount * 1.7);
    vec3 rgb = c * a * (1.0 - black);
    fragColor = vec4(rgb, a + (1.0 - a) * black) * qt_Opacity;
}
