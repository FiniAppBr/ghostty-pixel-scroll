// The whole visible chain in one pass: cursor ring, codespan repaint,
// shimmer glow, fluid smoke.
//
// These were three separate `custom-shader` entries. Each one re-read the
// full-resolution output of the one before it, so at this display's size the
// chain spent roughly 10 M texture fetches a frame doing nothing but handing
// the image along, and cost three render passes where one would do -- and on
// a tile-based GPU a pass boundary is a tile flush, which is worth more than
// the fetches. Merged, the image is read once and each stage works on the
// colour already in hand.
//
// The order below is exactly the order the three files ran in, and it still
// matters: the ring goes under the codespan repaint, and the smoke goes over
// everything. There is no bloom pass any more -- the spinner's glow is green
// smoke emitted into the fluid by dye-advect.glsl and read back out of the
// dye buffer here.

// --- cursor ring ------------------------------------------------------------
const float FADE_SECONDS   = 0.28;
const float RING_WIDTH     = 1.6;   // pixels
const float RING_GROW      = 6.0;   // pixels it expands while fading
const float HALO_INTENSITY = 0.7;

// --- shimmer glow -----------------------------------------------------------
// No bloom. The glow is drawn as what it is -- green smoke -- by mixing the
// image towards the colour rather than screening light over it, so density
// reads as opacity. GLOW_OPACITY is how much glow it takes to go fully solid:
// raise it to make thin glow read stronger, lower it to keep it a haze.
const vec3  GLOW_COLOR   = vec3(0.05, 0.58, 0.20);  // the fringe: a deep green
const vec3  GLOW_HOT     = vec3(0.55, 1.00, 0.66);  // the core, up against the letters
// Negative glow is red (a red spinner); same shape, same density, red palette.
const vec3  RED_COLOR    = vec3(0.62, 0.10, 0.10);  // fringe: a deep red
const vec3  RED_HOT      = vec3(1.00, 0.62, 0.62);  // core: the theme's #FF8A8A
// The edge haze (dye-advect, "the edges"): the dye buffer's alpha is how
// white this glow is, 0..1. Its own palette and trim.
const vec3  WHITE_COLOR  = vec3(0.50, 0.53, 0.58);  // fringe: a cool grey
const vec3  WHITE_HOT    = vec3(0.90, 0.92, 0.95);  // core: near white
const float WHITE_ALPHA  = 0.60;                    // GLOW_ALPHA is 0.80
// Was 11, which reached full opacity by a density of 0.3 and drew the whole
// halo as one flat slab -- every value the solver produced past that landed
// on the same alpha. 4 spends the range: 0.3 of alpha at a density of 0.1,
// 0.8 at the core, so what you see is the field's shape rather than its
// outline, and the verb underneath stays legible through it.
const float GLOW_OPACITY = 4.0;
// A flat trim on the finished alpha, applied after the contrast curve and the
// distance fade. Separate from GLOW_OPACITY for the same reason the smoke's
// trim is separate from its extinction: lowering the extinction reshapes the
// plume, thinning its fringes harder than its core, where this takes the same
// few points off the whole thing.
const float GLOW_ALPHA = 0.80;
// How much of the range is spent separating thin from thick. Beer-Lambert on
// its own is a compressing curve -- past a density or so everything reads the
// same -- so an S-curve in the bounded domain pushes the faint parts fainter
// and the dense parts denser without either end being able to run off. Same
// treatment the smoke gets below.
const float GLOW_CONTRAST = 0.50;
// Where the colour reaches GLOW_HOT. Lower spends more of the density range on
// the way there, so the core is a different green from the fringe instead of
// the whole thing arriving hot at once.
// 0.30 meant the core would only turn hot at a density of 3.3, which never
// happens; the halo was one colour end to end. 2.0 puts the transition inside
// the range that actually occurs, so it runs deep green at the fringe to pale
// at the letters, and the letters are where the eye lands.
const float GLOW_HEAT    = 2.0;
// Brightest at the letter, falling away as it leaves. The dye buffer's blue
// channel is the glow's age, and age is distance here -- green sitting on its
// source is reborn every step so its age stays at zero, and the further it has
// travelled the older it is. So this is a gradient in distance from the glyph
// without anything having to measure a distance.
const float GLOW_FADE    = 0.18;   // the age at which it is down to 1/e

// TEMPORARY. 1 renders the raw glow field instead of the terminal: brightness
// is the density through a soft curve, red lines are iso-contours every 0.02
// of density, and blue is exactly zero. It exists to tell a rectangle that is
// really in the field from a smooth field that the opacity curve above has
// flattened into one -- in the first the contours pile up along a straight
// edge, in the second they ring the blob. Set back to 0.
const int DEBUG_FIELD = 0;

// --- fluid smoke ------------------------------------------------------------
// The smoke used to be added to the image and the result allowed to run off
// the top of the range, which is why a thick plume went flat: past a certain
// density every pixel clipped to the same white and all the structure inside
// it was thrown away. Two more ceilings sat under that one -- density itself
// was clamped, and the colour ramp saturated well below the densities the
// solver actually reaches -- so dense smoke hit three plateaus at once.
//
// Extinction instead. Opacity approaches one asymptotically and never
// overshoots, which is both what smoke physically does and what keeps the
// dense end responsive: there is no point at which more density stops
// changing the picture. Nothing is clamped on the way in.
const float SMOKE_EXTINCTION = 0.105; // density that counts as half-opaque-ish

// A flat trim on the result, on top of the curve above. Kept separate from
// the extinction on purpose: lowering the extinction would thin the faint
// fringes proportionally harder than the body, which changes the shape of
// the plume rather than just its weight. This takes the same few points off
// everywhere, and incidentally leaves the densest smoke a little short of
// fully hiding what is behind it.
const float SMOKE_OPACITY = 0.94;
const float SMOKE_MAX        = 0.62;  // never fully opaque, so it keeps depth
const float SMOKE_CONTRAST   = 0.6;   // S-curve on opacity: 0 = off

const vec3  SMOKE_THIN  = vec3(0.52, 0.55, 0.60);
const vec3  SMOKE_THICK = vec3(0.88, 0.90, 0.93);


// --- split edge -------------------------------------------------------------
// Every split is its own surface with its own shader instance, so the edge of
// a split IS the edge of iResolution -- no uniform needed to find it, and no
// texture tap to draw it.
//
// Four bright arcs travelling around the pane's perimeter, each falling off
// symmetrically into nothing in both directions along the border. The trick is to give the border a single coordinate: unroll the
// four sides into one length s running clockwise from the top-left, and the
// whole thing becomes a 1-D pattern scrolling along it, corners included, with
// no special case where one side meets the next.
//
// Nothing is mixed towards a colour: it is added, so where a tail ends the
// image is simply the image again.
const float EDGE_LINE  = 1.0;    // hairline thickness at the border, in pixels
const float EDGE_HALO  = 3.0;    // pixels of faint bloom just inside it
const float EDGE_COUNT = 4.0;    // heads spaced evenly around the perimeter
const float EDGE_HOLD  = 70.0;   // pixels of full strength either side of centre
const float EDGE_REACH = 900.0;  // pixels from centre to fully faded
const float EDGE_SPEED = 25.0;   // pixels along the border per second
const float EDGE_CORE  = 0.30;   // strength of the hairline
const float EDGE_GLOW  = 0.10;   // strength of the bloom
const vec3  EDGE_COLOR = vec3(0.13, 0.95, 0.32);  // the spinner green

// --- the sent prompt ---------------------------------------------------------
// Claude Code fills a band behind a prompt you have sent and has no border
// property for it -- `promptBorder` in the theme drives the composer box, not
// this. So the band is set to a plain neutral in the theme and the outline is
// drawn here, off the same colour and the same two strengths as the split
// border above, so the two read as one idea.
//
// Finding it costs nothing: the band is a flat fill of one exact colour that
// nothing else on screen uses, and the composite has already sampled this
// pixel. Only pixels that ARE that colour go on to take the ring below, which
// is a couple of percent of the screen.
const vec3  PROMPT_BG   = vec3(0.1176, 0.1333, 0.1569);  // #1E2228
const float PROMPT_TOL  = 0.010;   // exact match; #282c34 is only 0.04 away
const vec3  TERM_BG     = vec3(0.1569, 0.1725, 0.2039);  // #282c34, the pane behind

// The corner radius, and also the ring the coverage is measured on -- those
// are the same number. Convolving a shape with a disc and following the
// half-coverage contour leaves a straight edge where it was and cuts a right
// angle off at the radius, so the rounding is not drawn, it falls out of how
// the edge is found.
const float PROMPT_ROUND = 4.0;    // pixels
// Both are in coverage rather than pixels. A pixel of distance is worth about
// 0.08 of coverage at this radius, so these are the same 1 and 3 pixels the
// split border uses.
const float PROMPT_LINE  = 0.10;
const float PROMPT_HALO  = 0.28;
const float PROMPT_CORE  = 0.30;   // matched to EDGE_CORE
const float PROMPT_GLOW  = 0.10;   // matched to EDGE_GLOW

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
// #57D4A0 was hue 155, a mint; the spinner verb (#00FF41 crest, #007A1E base)
// is hue 135. Same lightness and saturation, hue moved to match, so the two
// greens read as one family instead of two.
const vec3  CODE_TO       = vec3(0.341, 0.831, 0.467);  // #57D477
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

// A thin ring around the cursor rather than a filled glow. Nothing is laid
// over the glyphs, so text stays exactly as legible as it was. Returns what
// to add, so that an early out here cannot swallow the stages after it.
vec3 cursorRing(vec2 fragCoord) {
    if (HALO_INTENSITY <= 0.0) return vec3(0.0);

    // Follow the write head while a program is writing. Its cursor is
    // hidden and parked in its own input box, so following the cursor
    // alone means following nothing at all during streamed output.
    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);
    vec2 c = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5);

    float age = max(iTime - changed, 0.0);
    float life = 1.0 - clamp(age / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return vec3(0.0);

    // Distance to the cursor rectangle's edge.
    vec2 halfSize = vec2(cw, ch) * 0.5 + (1.0 - life) * RING_GROW;
    vec2 q = abs(fragCoord - c) - halfSize;
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

    float ring = 1.0 - smoothstep(0.0, RING_WIDTH, abs(dist));
    if (ring <= 0.0) return vec3(0.0);

    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;
    return tint * (ring * life * HALO_INTENSITY);
}

// Returns what to add, so the early-out cannot swallow the stages after it.
vec3 splitEdge(vec2 fragCoord) {
    vec2 e = min(fragCoord, iResolution.xy - fragCoord);
    float d = min(e.x, e.y);            // distance to the nearest border
    if (d > EDGE_HALO) return vec3(0.0);

    // Unroll the perimeter into one coordinate, clockwise from the top-left.
    // The four cases agree at every corner -- top ends at W where right
    // begins, and so on round -- so the pattern crosses a corner without a
    // seam and without knowing a corner is there.
    float W = iResolution.x;
    float H = iResolution.y;
    float s;
    if (e.x < e.y) {
        s = (fragCoord.x < W * 0.5) ? (2.0 * W + H) + (H - fragCoord.y)  // left
                                    : W + fragCoord.y;                   // right
    } else {
        s = (fragCoord.y < H * 0.5) ? fragCoord.x                        // top
                                    : (W + H) + (W - fragCoord.x);       // bottom
    }

    // Distance back along the border to the head in front of this pixel.
    // Signed distance to the nearest arc centre, so the falloff below runs
    // both ways along the border instead of trailing behind a head.
    float seg  = 2.0 * (W + H) / EDGE_COUNT;
    float halfSeg = seg * 0.5;
    float off  = mod(s - iTime * EDGE_SPEED + halfSeg, seg) - halfSeg;
    float away = abs(off);

    // Both lengths are wishes, fitted to whatever perimeter this split
    // actually has: reaching more than half the spacing would run one arc
    // into the next, and the cap also leaves a dark stretch between them so
    // there is a rhythm rather than a continuous ring. A tall thin pane and a
    // wide short one then get the same shape, not the same pixel counts.
    float reach = min(EDGE_REACH, seg * 0.35);
    float hold  = min(EDGE_HOLD, reach * 0.25);
    if (away > reach) return vec3(0.0);

    // A short plateau so the middle of the arc is solid, then the whole rest
    // of the span spent on the gradient, in both directions.
    float t = 1.0 - smoothstep(hold, reach, away);

    float core = (1.0 - smoothstep(0.0, EDGE_LINE, d)) * EDGE_CORE;
    float halo = (1.0 - smoothstep(0.0, EDGE_HALO, d)) * EDGE_GLOW;
    return EDGE_COLOR * ((core + halo) * t);
}

bool isPromptBg(vec3 c) {
    return all(lessThan(abs(c - PROMPT_BG), vec3(PROMPT_TOL)));
}

// What is OUTSIDE the band is the pane behind it, and nothing else -- so ask
// that, rather than asking what is inside. Testing for the band's own fill
// instead puts every glyph in the prompt outside it, and a chevron sitting
// against the left edge then eats holes in the line running past it. Asking
// for the background makes glyphs, their antialiased edges and the fill all
// one thing, which is what they are.
float insideBand(vec3 c) {
    vec3 d = abs(c - TERM_BG);
    return smoothstep(PROMPT_TOL * 0.5, PROMPT_TOL * 2.5,
                      max(max(d.r, d.g), d.b));
}

vec3 promptEdge(vec2 fragCoord, vec3 raw) {
    if (!isPromptBg(raw)) return vec3(0.0);

    // Sixteen points on a circle of the corner radius. On a straight edge the
    // fraction inside passes through a half exactly at the edge; at a corner
    // it gets there half a radius short of the point, which is the rounding.
    //
    // Sixteen and not twelve, and each sample fractional rather than in-or-
    // out, for the same reason: coverage is a staircase whose tread has to be
    // finer than the line is wide, or the line comes out dotted along the
    // corners, where the distance changes slowly. Twelve binary samples did.
    float n = 1.0;                      // the centre, known to be inside
    for (int i = 0; i < 16; i++) {
        float a = float(i) * 0.3926991;   // 22.5 degrees
        vec2 o = vec2(cos(a), sin(a)) * PROMPT_ROUND;
        n += insideBand(texture(iChannel0, (fragCoord + o) / iResolution.xy).rgb);
    }

    // Half the ring plus the centre is 9 of 17, so that is where the edge is.
    float t = abs(n / 17.0 - 9.0 / 17.0);
    float core = (1.0 - smoothstep(0.0, PROMPT_LINE, t)) * PROMPT_CORE;
    float halo = (1.0 - smoothstep(0.0, PROMPT_HALO, t)) * PROMPT_GLOW;
    return EDGE_COLOR * (core + halo);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    vec3 raw = texture(iChannel0, uv).rgb;
    vec3 col = raw;

    // 1. the cursor ring, under everything else
    col += cursorRing(fragCoord);

    // 2. the codespan repaint
    col = recolourCodespan(col);

    // 2b. the split's border, under the smoke so plumes drift across it
    col += splitEdge(fragCoord);

    // 2c. and the same border around a sent prompt. Keyed on the untouched
    //     image, so the codespan repaint above cannot move the colour it is
    //     looking for.
    col += promptEdge(fragCoord, raw);

    // 3. the shimmer glow. It rides in the dye buffer's green channel, put
    //    there by dye-advect.glsl, so it costs no tap of its own.
    vec4 d = texture(iChannel2, uv);
    // Masked by the glyph coverage the dye buffer already carries in alpha.
    // The glow is deliberately NOT masked where it is stored -- it has to be
    // born on the letters to spread outward from them -- but drawing it over
    // them would fill the gaps between strokes with flat green and cost the
    // text its shape. Off the letters it can be as solid as it likes.
    // Beer-Lambert, not a clamp -- the same curve the smoke below uses, and for
    // the same reason. A clamp makes everything past one density identical, so
    // what you see is a single iso-contour of the field with opaque on one side
    // and nothing on the other. While the green was a blurred blob that contour
    // was smooth; now that it is sharply advected like the smoke, the contour
    // follows the field texel by texel and the hard step turns it into jagged
    // edges. However much piles up, this only ever approaches one, so the edge
    // fades out instead of falling off a cliff.
    float gm = abs(d.g);   // the channel is signed: sign is hue, magnitude is density
    float white = clamp(d.a, 0.0, 1.0);
    float a = 1.0 - exp(-gm * GLOW_OPACITY);
    a = mix(a, a * a * (3.0 - 2.0 * a), GLOW_CONTRAST);
    a *= exp(-max(d.b, 0.0) / GLOW_FADE) * mix(GLOW_ALPHA, WHITE_ALPHA, white);
    if (a > 0.0) {
        vec3 fringe = mix(d.g < 0.0 ? RED_COLOR : GLOW_COLOR, WHITE_COLOR, white);
        vec3 hot    = mix(d.g < 0.0 ? RED_HOT   : GLOW_HOT,   WHITE_HOT,   white);
        col = mix(col, mix(fringe, hot, clamp(gm * GLOW_HEAT, 0.0, 1.0)), a);
    }

    // 4. the fluid smoke, over everything
    // Gated on there being smoke, not on being off a glyph. Gating on the
    // mask skipped glyph pixels entirely, which put a hard edge back in no
    // matter how soft the mask itself was -- and the dye buffer has already
    // thinned the smoke over the letters, so masking here as well squared
    // the mask and sharpened exactly the edge we are trying to soften.
    if (d.r > 0.0) {
        // Beer-Lambert: however much density piles up, opacity only ever
        // approaches one. The whole range the solver produces stays on the
        // curve, so the inside of a plume still varies.
        float a = (1.0 - exp(-max(d.r, 0.0) * SMOKE_EXTINCTION)) * SMOKE_OPACITY;

        // Contrast in the bounded domain, where an S-curve can separate thin
        // from thick without any chance of running off the end.
        a = mix(a, a * a * (3.0 - 2.0 * a), SMOKE_CONTRAST);
        a *= SMOKE_MAX;

        // Thin ink is a dim cool grey, thick lifts toward white -- driven by
        // the same bounded opacity, so the colour ramp cannot saturate early
        // and flatten the dense end on its own.
        col = mix(col, mix(SMOKE_THIN, SMOKE_THICK, a), a);
    }

    if (DEBUG_FIELD == 2) {
        // The red gate, row by row, over the terminal image. Tint: R = the
        // row's third cell keys red, G = the row changed within RED_HOLD,
        // B = that change was small enough. White = all three. Bright dots
        // on cells: the cell key in the sim buffer's alpha, green or red.
        vec2 bsz = vec2(textureSize(iChannel3, 0));
        vec4 row = texelFetch(iChannel3, ivec2(0, int(uv.y * bsz.y)), 0);
        vec3 tint = vec3(row.b > 0.5 ? 1.0 : 0.0,
                         row.r < 1.3 ? 1.0 : 0.0,
                         row.g <= 40.0 ? 1.0 : 0.0);
        col = mix(raw, tint, 0.35);
        vec2 ssz = vec2(textureSize(iChannel1, 0));
        float a = texelFetch(iChannel1, ivec2(uv * ssz), 0).a;
        float key = (a > 3.5 ? a - 4.0 : a) - 1.5;
        if (key > 0.05) col = mix(col, vec3(0.0, 1.0, 0.0), 0.6);
        if (key < -0.05) col = mix(col, vec3(1.0, 0.0, 0.0), 0.6);
        fragColor = vec4(col, 1.0);
        return;
    }
    if (DEBUG_FIELD > 0) {
        // R: glow density. G: |vel.x|, B: |vel.y| from the sim buffer, so a
        // standing jet shows as colour and its direction as which channel.
        // Solid obstacle: white. Contour lines on the glow every 0.02: cyan.
        vec4  sim = texture(iChannel1, uv);
        float g   = abs(d.g);
        // G is the SMOKE density now, so a dead dye pass (both zero) is
        // distinguishable from a live one whose glow happens to be zero.
        vec3  dbg = vec3(1.0 - exp(-g * 3.0),
                         1.0 - exp(-max(d.r, 0.0) * 0.5),
                         1.0 - exp(-abs(sim.g) / 60.0));
        if (g > 0.0 && fract(g * 50.0) < 0.06) dbg = vec3(0.0, 1.0, 1.0);
        if (sim.a > 3.5) dbg = vec3(1.0);
        fragColor = vec4(dbg, 1.0);
        return;
    }

    fragColor = vec4(col, 1.0);
}
