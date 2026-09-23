// A slow fog in the empty cells. Nothing is laid over the glyphs: every pixel
// is keyed against the terminal's own background first, so text is exactly as
// legible as it was.
//
// Chain this FIRST. It reads the pristine screen, which is what the background
// key needs; cursor-halo and shimmer-bloom then run over its output, and
// neither keys on anything this pass touches (3% of luminance on a dark ground
// clears neither the shimmer's saturation test nor the codespan brightness
// gate).

const vec3  BG   = vec3(0.1569, 0.1725, 0.2039);   // #282c34
const float AMP  = 0.052;   // fraction of full luminance, at rest
const float DRIFT = 0.012;  // ~80s to cross the screen

// Raise this and the fog moves faster, spreads warmer and sits brighter, as
// it did under "working" in the preview. Left at 0 it stays at rest.
const float ACTIVITY = 0.0;

// 1 on an empty background pixel, 0 on any glyph.
float bgKey(vec3 c){ return 1.0 - smoothstep(0.015, 0.085, length(c - BG)); }

float hash21(vec2 p){ p = fract(p*vec2(123.34,345.45)); p += dot(p,p+34.345); return fract(p.x*p.y); }

float vnoise(vec2 p){
    vec2 i = floor(p), f = fract(p);
    f = f*f*(3.0-2.0*f);
    float a=hash21(i), b=hash21(i+vec2(1,0)), c=hash21(i+vec2(0,1)), d=hash21(i+vec2(1,1));
    return mix(mix(a,b,f.x), mix(c,d,f.x), f.y);
}

float fbm(vec2 p){
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++){ s += a*vnoise(p); p *= 2.03; a *= 0.5; }
    return s;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 src = texture(iChannel0, uv);
    fragColor = src;

    float mask = bgKey(src.rgb);
    if (mask <= 0.0) return;

    float t = iTime * (DRIFT + 0.055 * ACTIVITY);
    vec2 p = uv * vec2(iResolution.x / iResolution.y, 1.0) * 2.4;

    // Two rounds of domain warping. One round reads as a texture sliding past;
    // two reads as weather, because the field folds into itself.
    vec2 q = vec2(fbm(p + t), fbm(p + vec2(5.2, 1.3) + t*0.9));
    vec2 r = vec2(fbm(p + 2.0*q + vec2(1.7, 9.2) + 0.30*t),
                  fbm(p + 2.0*q + vec2(8.3, 2.8) + 0.26*t));
    float f = smoothstep(0.32, 0.95, fbm(p + 2.2*r));

    vec3 tint = mix(vec3(0.34,0.44,0.80), vec3(0.22,0.88,0.48), ACTIVITY*0.85);
    fragColor.rgb += tint * f * mix(AMP, 0.055, ACTIVITY) * mask;
}
