// Real bloom around the spinner's shimmer highlight.
//
// Claude Code animates the spinner as a gradient sweeping between the theme's
// `claude` colour and its `claudeShimmer` colour. Nothing in a terminal can
// glow on its own, so this pass finds the shimmer's peak by colour and blooms
// it: the bright crest of the wave gets a soft halo that travels with it.
//
// The key is a saturation test rather than a distance to one exact colour.
// Over ssh without COLORTERM, Claude Code quantises to the 256-colour cube, so
// the shimmer never lands on its literal hex. What survives quantising is how
// far green leads the other two channels: the crest is pure phosphor green and
// clears the threshold by a wide margin, while the softer greens already in
// the theme - success, planMode, suggestion, the subagent colours - sit well
// under it and stay unbloomed. The dark grey base fails it outright.
//
// Chain this AFTER cursor-halo.glsl; it reads whatever that pass wrote.
//
// The 48-tap blur that used to be in here now lives in shimmer-blur.glsl,
// which runs into the `bloom` buffer at quarter scale. All that is left at
// full resolution is the codespan repaint, which has to be per-pixel, and
// one tap of the finished glow field.

const float KEY_GREEN     = 0.42;  // how far green must lead red and blue
const float KEY_MIN_GREEN = 0.55;  // and how bright that green must be
const vec3  GLOW_TINT     = vec3(0.16, 1.0, 0.35);
const float INTENSITY     = 3.8;
// BLOOM_RADIUS, BLOOM_SPREAD and TAPS moved to shimmer-blur.glsl with the
// loop they belong to.

// --- inline code ------------------------------------------------------------
//
// Claude Code renders a `codespan` with ht("permission", t), and t arrives as
// the theme NAME. The lookup behind it only knows the six built-in presets and
// falls through to built-in dark for anything else, so a custom theme's
// `permission` override never reaches inline code - it always comes out the
// stock rgb(153,204,255). Overriding the token cannot fix it and neither can a
// palette remap any more, since truecolor means exact RGB rather than a slot.
//
// So repaint it here. The match is on chromaticity rather than on the literal
// colour, which keeps antialiased glyph edges - same hue, lower brightness -
// in the match, and CODE_TO is applied at the pixel's own brightness so the
// edges stay smooth instead of turning into a hard cutout.
// The old `palette = 153` remap caught a box in RGB space - everything in
// R 128-178 / G 179-229 / B 230-255 quantised onto that one slot - so inline
// code AND the syntax-highlight blues all came out green together. Matching a
// single colour only brought back the codespan and left the rest blue, so this
// is the same box, expressed as chromaticity so antialiased edges come along.
// Blue must be the brightest channel, which drops the theme's indigos/purples.
const vec2  CODE_R_RANGE  = vec2(0.46, 0.80);   // red, relative to blue
const vec2  CODE_G_RANGE  = vec2(0.70, 0.94);   // green, relative to blue
const float CODE_FEATHER  = 0.015;
// Chromaticity alone is not enough: Ghostty's own background, #282c34, has
// blue as its brightest channel and sits inside the box, so without this the
// whole screen repaints. Glyphs are bright and the background is not, so gate
// on brightness. This also drops the dimmest antialiased edge pixels, which
// are close enough to the background not to read as colour anyway.
const float CODE_MIN_LIGHT = 0.42;
const vec3  CODE_TO       = vec3(0.341, 0.831, 0.627);  // #57D4A0
const float CODE_ENABLE   = 1.0;   // 0 turns the repaint off

float codeKey(vec3 c) {
    float m = max(max(c.r, c.g), c.b);
    if (c.b < m) return 0.0;               // blue must lead
    float lit = smoothstep(CODE_MIN_LIGHT, CODE_MIN_LIGHT + 0.08, m);
    if (lit <= 0.0) return 0.0;
    vec3 n = c / m;
    float rk = smoothstep(CODE_R_RANGE.x - CODE_FEATHER, CODE_R_RANGE.x, n.r)
             * (1.0 - smoothstep(CODE_R_RANGE.y, CODE_R_RANGE.y + CODE_FEATHER, n.r));
    float gk = smoothstep(CODE_G_RANGE.x - CODE_FEATHER, CODE_G_RANGE.x, n.g)
             * (1.0 - smoothstep(CODE_G_RANGE.y, CODE_G_RANGE.y + CODE_FEATHER, n.g));
    return rk * gk * lit;
}

vec3 recolourCodespan(vec3 c) {
    if (CODE_ENABLE <= 0.0) return c;
    float hit = codeKey(c);
    if (hit <= 0.0) return c;
    float m = max(max(c.r, c.g), c.b);
    return mix(c, CODE_TO * m, hit);       // same brightness, new hue
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor.rgb = recolourCodespan(fragColor.rgb);
    if (INTENSITY <= 0.0) return;

    float glow = texture(iChannel3, fragCoord / iResolution.xy).r;
    if (glow <= 0.0) return;

    // Screen rather than add, so the halo saturates towards the tint instead
    // of clipping to white over the glyph itself.
    vec3 g = GLOW_TINT * glow * INTENSITY;
    fragColor.rgb = 1.0 - (1.0 - fragColor.rgb) * (1.0 - clamp(g, 0.0, 1.0));

    // Screen alone tops out at the tint, so the crest stops getting brighter
    // however far INTENSITY is pushed. Whatever is left over spills on top
    // additively, which is what lets the core read as hot rather than merely
    // green.
    fragColor.rgb += GLOW_TINT * max(glow * INTENSITY - 1.0, 0.0) * 0.6;
}
