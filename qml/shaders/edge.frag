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
layout(binding = 1) uniform sampler2D tex;     // the page, mipmapped
layout(binding = 2) uniform sampler2D frost;   // the page at 240x135, Gaussian-blurred

// the frost magnified: cubic b-spline from 4 bilinear taps (plain bilinear shows its blocks)
const vec2 FROST_SIZE = vec2(240.0, 135.0);
vec3 frostAt(vec2 uv)
{
    vec2 st = uv * FROST_SIZE - 0.5;
    vec2 i = floor(st);
    vec2 f = st - i;
    vec2 f2 = f * f, f3 = f2 * f;
    vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 s0 = w0 + w1, s1 = w2 + w3;
    vec2 h0 = (i - 0.5 + w1 / s0) / FROST_SIZE;
    vec2 h1 = (i + 1.5 + w3 / s1) / FROST_SIZE;
    return s0.y * (s0.x * texture(frost, vec2(h0.x, h0.y)).rgb + s1.x * texture(frost, vec2(h1.x, h0.y)).rgb)
         + s1.y * (s0.x * texture(frost, vec2(h0.x, h1.y)).rgb + s1.x * texture(frost, vec2(h1.x, h1.y)).rgb);
}

void main() {
    float y = qt_TexCoord0.y;
    vec2 at = vec2(qt_TexCoord0.x, y * band);
    float k = 1.0 - y;
    // how much of the blurred page shows, softest towards the band's end
    float soft = smoothstep(0.0, 0.85, k);
    // the page softens step by step (mip levels), then gives way to the gaussian frost
    vec3 page = textureLod(tex, at, 2.5 * smoothstep(0.0, 0.6, k)).rgb;
    vec3 c = mix(page, frostAt(at), smoothstep(0.25, 1.0, k) * 0.8);
    // darkness keeps easing all the way to the edge, nothing flat
    float dark = pow(k, 1.7);
    float a = soft * amount;
    float black = dark * min(1.0, amount * 1.7);
    vec3 rgb = c * a * (1.0 - black);
    fragColor = vec4(rgb, a + (1.0 - a) * black) * qt_Opacity;
}
