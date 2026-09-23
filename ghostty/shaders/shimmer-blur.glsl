// The blur half of shimmer-bloom, moved off the full-resolution path.
//
// This is a buffer pass: it renders into the `bloom` buffer at a fraction of
// the screen size and writes one number per texel, the glow field. The
// visible half (shimmer-bloom.glsl) just tints and screens what this wrote.
//
// Why it is worth splitting. The blur used to run 48 taps per screen pixel
// per frame -- 238 M texture fetches a frame at this display's size, about
// twelve times the entire fluid simulation, and by a wide margin the most
// expensive thing on screen. A bloom is pure low frequency, so computing it
// at quarter scale throws away nothing the eye can see and costs a sixteenth
// of the pixels. Two further cuts are below.
//
// One behavioural difference from when this lived in the visible chain:
// buffer passes run before any visible shader, so this reads the pristine
// terminal rather than cursor-halo's output. The key is a strict phosphor
// green, which is the spinner's own colour and is in the pristine image, so
// the crest blooms exactly as before -- but if the cursor halo itself ever
// cleared the green test, it no longer contributes.

const float KEY_GREEN     = 0.42;  // how far green must lead red and blue
const float KEY_MIN_GREEN = 0.55;  // and how bright that green must be
const float BLOOM_RADIUS  = 30.0;  // pixels, at screen scale
const float BLOOM_SPREAD  = 0.55;  // falloff, as a fraction of the radius

// Was 48 at full resolution. At quarter scale the same 20 taps land far
// closer together relative to the grid they are filtering, so the halo is
// no grainier than it was.
const int   TAPS          = 20;

// The probe ring that decides whether the full loop runs at all. The crest
// covers several texels at this scale and the ring is spaced tighter than
// that, so nothing glyph-sized can slip between two probes.
const int   PROBE         = 8;
const float PROBE_RADIUS  = 0.45;  // as a fraction of BLOOM_RADIUS

const float GOLDEN_ANGLE = 2.39996323;

// 1 where a pixel is part of the shimmer crest, 0 everywhere else.
float shimmerKey(vec3 c) {
    float green = c.g - max(c.r, c.b);
    return smoothstep(KEY_GREEN, KEY_GREEN + 0.16, green)
         * smoothstep(KEY_MIN_GREEN, KEY_MIN_GREEN + 0.2, c.g);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // This pass renders at the bloom buffer's size; the radius is given in
    // screen pixels, so carry it across in uv and sample iChannel0, which is
    // always full resolution.
    vec2 uv = fragCoord / vec2(textureSize(iChannel3, 0));
    vec2 rad = BLOOM_RADIUS / iResolution.xy;

    // Cheap probe first. Almost the whole screen has no shimmer anywhere
    // near it, and those texels get out for eight taps instead of twenty.
    float probe = shimmerKey(texture(iChannel0, uv).rgb);
    for (int i = 0; i < PROBE; i++) {
        float a = float(i) * (6.2831853 / float(PROBE));
        probe += shimmerKey(texture(iChannel0, uv + vec2(cos(a), sin(a)) * rad * PROBE_RADIUS).rgb);
    }
    if (probe <= 0.0) { fragColor = vec4(0.0); return; }

    // Sunflower sampling: an even disc of taps from a single index, so the
    // halo is round instead of showing the axes of a box blur.
    float sigma = BLOOM_SPREAD;
    float acc = 0.0, wsum = 0.0;
    for (int i = 0; i < TAPS; i++) {
        float fi = float(i) + 0.5;
        float r = sqrt(fi / float(TAPS));
        float a = fi * GOLDEN_ANGLE;
        float w = exp(-(r * r) / (2.0 * sigma * sigma));
        acc += shimmerKey(texture(iChannel0, uv + vec2(cos(a), sin(a)) * r * rad).rgb) * w;
        wsum += w;
    }

    fragColor = vec4(acc / max(wsum, 0.0001), 0.0, 0.0, 1.0);
}
